//
//  LuaScriptEngine.swift
//  MudClient
//
//  The host-facing scripting surface. Owns a `Lua` interpreter, installs the
//  builtins scripts call (`send`, `echo`, `trigger`, `alias`, `gag`, `kxwt`),
//  and holds the trigger/alias/gag registry. The heavy swift-parsing machinery
//  (KXWT and friends) stays on the host and is reached through `onKxwt`.
//
//  All Lua access is serialized through `lock` — a lua_State is single-threaded.
//

import DependencyInjection
import Foundation
#if canImport(AppKit)
import AppKit
#endif

final class LuaScriptEngine: @unchecked Sendable {
    /// A registered line-trigger, alias, or gag. A reference type so `rule_enable`/`class_enable`
    /// can flip `enabled` in place. `handler` is nil for gags (they only decide whether a line is
    /// dropped); `oneshot` rules auto-remove after their first fire; `ruleClass` tags a rule so a
    /// whole class can be enabled/removed at once.
    final class Rule {
        let id: Int
        let regex: Regex<AnyRegexOutput>
        /// The original pattern SOURCE string, kept for introspection/listing (`#trigger` with no args) —
        /// the compiled `regex` can't reproduce it. "" only for rules built before this was threaded through.
        let patternSource: String
        let handler: LuaFunctionRef?
        let oneshot: Bool
        let ruleClass: String?
        /// Explicit ordering override (`opts.priority`, default 0). Higher fires/matches first.
        let priority: Int
        /// Pattern specificity, computed once at registration from the pattern source
        /// (see `Self.specificity(of:)`). Higher = more specific. Breaks ties after priority.
        let specificity: Int
        var enabled: Bool = true
        init(id: Int, regex: Regex<AnyRegexOutput>, patternSource: String = "", handler: LuaFunctionRef?,
             oneshot: Bool = false, ruleClass: String? = nil,
             priority: Int = 0, specificity: Int = 0) {
            self.id = id
            self.regex = regex
            self.patternSource = patternSource
            self.handler = handler
            self.oneshot = oneshot
            self.ruleClass = ruleClass
            self.priority = priority
            self.specificity = specificity
        }
    }

    /// Firing/matching order for two rules: explicit `priority` desc, then `specificity` desc,
    /// then `id` asc (registration order — a stable, deterministic tiebreak). Returns true when
    /// `a` should be consulted before `b`. Keeping the rule arrays sorted by this at insertion
    /// time means the hot `processLine`/`processAlias` loops just iterate in order.
    private static func ranksBefore(_ a: Rule, _ b: Rule) -> Bool {
        if a.priority != b.priority { return a.priority > b.priority }
        if a.specificity != b.specificity { return a.specificity > b.specificity }
        return a.id < b.id
    }

    /// Insert `rule` into `rules` keeping it sorted by `ranksBefore`. Because ids are monotonic and
    /// are the final tiebreak, a new rule lands AFTER any equal-ranked rule already present, so
    /// registration order is preserved within a priority/specificity tier.
    private func insertSorted(_ rule: Rule, into rules: inout [Rule]) {
        var i = rules.count
        while i > 0 && Self.ranksBefore(rule, rules[i - 1]) { i -= 1 }
        rules.insert(rule, at: i)
    }

    /// A cheap, deterministic specificity score for a trigger/alias pattern, computed ONCE from the
    /// regex source. The intent: specific parsers/rewriters outrank broad catch-all observers, so a
    /// line's specific handlers run before the `.*` observers that read the state they wrote.
    ///
    /// Formula (documented so scripts can reason about ordering):
    ///   * `+100`  a leading `^` start-anchor (a pattern pinned to the line start is very specific)
    ///   * `+20`   a trailing `$` end-anchor
    ///   * `+1`    per literal character matched (letters/digits/punctuation/space outside a class)
    ///   * `+2`    per escaped literal (`\.`, `\/`, …) — an explicit literal, worth a touch more
    ///   * `+1`    per bounded piece: a char class `[...]` or a class escape (`\d`, `\w`, `\s`)
    ///   * `-50`   per UNBOUNDED wildcard (`.*` or `.+`) — the hallmark of a catch-all observer
    ///   * `-1`    a bare `.` wildcard (matches one of anything)
    /// Groups/alternation/quantifier punctuation are structural and score 0.
    static func specificity(of pattern: String) -> Int {
        var score = 0
        let chars = Array(pattern)
        var i = 0
        var inClass = false
        while i < chars.count {
            let c = chars[i]
            if inClass {
                if c == "]" { inClass = false }
                i += 1
                continue
            }
            switch c {
            case "^" where i == 0:
                score += 100
            case "$" where i == chars.count - 1:
                score += 20
            case "[":
                score += 1          // a bounded character class counts a little
                inClass = true
            case "\\":
                let next = i + 1 < chars.count ? chars[i + 1] : " "
                if "dDwWsS".contains(next) { score += 1 }   // class escape: bounded
                else { score += 2 }                          // escaped literal
                i += 1                                        // consume the escaped char
            case ".":
                if i + 1 < chars.count && (chars[i + 1] == "*" || chars[i + 1] == "+") {
                    score -= 50     // unbounded wildcard — a catch-all
                    i += 1          // consume the quantifier
                } else {
                    score -= 1      // bare single-char wildcard
                }
            case "(", ")", "|", "*", "+", "?", "{", "}":
                break               // structural / quantifier: neutral
            default:
                score += 1          // a literal character
            }
            i += 1
        }
        return score
    }

    private let lua = Lua()
    private let lock = NSRecursiveLock()
    private let llm = LLMClient()
    /// A SECOND, independently-configured client for the "memory head" — a separate model (e.g. a
    /// hosted Claude via Anthropic's OpenAI-compatible endpoint) that maintains structured world
    /// state, leaving the local `llm` to make decisions. Configured by the script via ai_set_memory_*.
    private let memLLM = LLMClient()
    /// A THIRD client pinned to the LOCAL model (defaults to LM Studio at localhost:1234). It is never
    /// pointed at a paid API, so cheap always-on features (e.g. the trivia auto-answerer) get a model
    /// that works even when the decision brain is a hosted API that's down or unconfigured — and using
    /// it never disturbs the pilot's `llm`/`memLLM` config. Exposed via `ai_local_request`.
    private let localLLM = LLMClient()
    /// Retrieval over the prebuilt doc index — gives the decision model relevant game documentation
    /// on demand (see RAGRetriever / tools/finetune/build_rag_index.py).
    private let rag = RAGRetriever()
    private let timerQueue = DispatchQueue(label: "lua.timer")

    private(set) var lineRules: [Rule] = []
    private(set) var aliasRules: [Rule] = []
    private(set) var gags: [Rule] = []
    /// Monotonic id source for rules AND timers (one namespace keeps every handle unique). Guarded
    /// by `lock`.
    private var lastId: Int = 0
    /// Outstanding timers by id (both one-shot `after` and repeating `every`). Presence == armed;
    /// cancel/reload removes the entry, and the fire path checks membership before invoking the
    /// callback so a cancelled timer can't fire into fresh state. Guarded by `lock`.
    private var timers: [Int: DispatchWorkItem] = [:]

    /// Script-registered key macros (via the `bind` builtin), keyed by an auto-incrementing id so
    /// `unbind(id)` can remove exactly one. The stored `key` is the canonical key name (see
    /// `normalizeKeyName`) the terminal decoder produces. Cleared on reload (same path as triggers).
    private var keyBindings: [Int: (key: String, handler: LuaFunctionRef)] = [:]
    /// Monotonic id source for `bind`; never reset so a stale id from before a reload can't collide.
    private var nextBindId = 1

    /// Script-registered raw server-stream filter (via `on_stream`). Given a text chunk, returns the
    /// text to actually display — a script uses it to peel out an in-band protocol it alone understands.
    private var streamFilter: LuaFunctionRef?

    /// Host sinks. The integration layer wires these to the real services.
    var onSend: (String) -> Void = { _ in }
    var onEcho: (String) -> Void = { _ in }
    /// Record a locally-echoed CONTENT line into the searchable transcript (so `#grep` finds it). Wired
    /// by the integration layer to `TranscriptStore.recordEcho`; a no-op in bare-engine unit tests (which
    /// don't stand up a container). Deliberately called ONLY from content echoes (`echo()`, `↗ claude`) —
    /// NOT from the `#grep`/`#sent`/`#received` dump path, so viewing the transcript never re-appends to it.
    var onRecordEcho: (String) -> Void = { _ in }

    /// While the `on_send` hook is being consulted this is non-nil; any `send()` the hook itself calls
    /// is diverted here (instead of the normal `onSend` sink) so those commands go straight to the MUD
    /// without re-entering the hook — that's the "no recursion" guarantee. nil at all other times, so
    /// ordinary sends take the normal path. Only touched under `lock` (the send builtin and the hook
    /// call both run on the locked Lua thread).
    private var hookSends: [String]?

    init() {
        lua.errorHandler = { [weak self] msg in self?.onEcho(msg) }
        // Default the memory head to Anthropic's OpenAI-compatible endpoint; the script picks the
        // model and the key comes from the keychain (or ANTHROPIC_API_KEY, or `#ai memkey`). Harmless
        // if unused — the memory head only runs when the script enables it.
        memLLM.setEndpoint("https://api.anthropic.com/v1")
        memLLM.setAuthKeyProvider(Container.anthropicAPIKeyProvider())  // resolved lazily, at request time
        memLLM.setAnthropic(true)   // native /v1/messages (matches the decision client's format)
        installBuiltins()
        installPrimitives()
        installPanel()
        installTerminal()
        installBootstrap()
    }

    /// Load the Lua bootstrap (`Scripts/bootstrap.lua`): the REPL pretty-printer, the `doc`/`help`
    /// documentation registry, docs for every host builtin, the legacy `command()` bridge, and the
    /// `ai` command router. Runs AFTER every host builtin is registered so its `doc()` calls and the
    /// `panel`/`music` tables it documents already exist. Resolved CWD-relative (the app runs from the
    /// repo root) with a source-relative fallback so unit tests find it regardless of their CWD.
    private func installBootstrap() {
        guard let path = Self.bootstrapPath() else {
            onEcho("[bootstrap] Scripts/bootstrap.lua not found")
            return
        }
        do { try lua.runFile(path) }
        catch { onEcho("[bootstrap] failed: \(error)") }
    }

    private static func bootstrapPath() -> String? {
        let fm = FileManager.default
        let cwd = fm.currentDirectoryPath + "/Scripts/bootstrap.lua"
        if fm.fileExists(atPath: cwd) { return cwd }
        // Fallback: relative to this source file (Sources/MudClient/…) → repo root.
        let fromSource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Scripts/bootstrap.lua").path
        return fm.fileExists(atPath: fromSource) ? fromSource : nil
    }

    // MARK: - Async callbacks into Lua

    /// Call a stored Lua callback with the lock held — used by `ai_request`/`after` when their
    /// async work completes. NSRecursiveLock makes re-entrant calls from a handler safe.
    func fire(_ ref: LuaFunctionRef, _ args: [LuaValue]) {
        lock.lock(); defer { lock.unlock() }
        try? lua.call(ref, args)
    }

    /// Notify the script of a command the user typed (non-swallowing observation). No-op unless the
    /// script defines a global `on_user_input`.
    func notifyUserInput(_ command: String) {
        lock.lock(); defer { lock.unlock() }
        try? lua.callGlobal("on_user_input", [.string(command)])
    }

    /// Run a `|`-pipe: promise-sequenced steps like "recover 95 | attack rat | l". `steps` is the
    /// already-tokenized line (see `InputService.pipeSegments`/`semicolonSegments` — Swift owns both the
    /// `|` and the nested `;` split + escaping). Each step is a `;`-group of commands (usually one). Hands
    /// the nested steps to the Lua `__pipe`, which builds and starts a promise chain where each step waits
    /// for the previous to resolve. The chaining lives in Lua because promises do (Promise.lua); Swift
    /// only tokenizes. The caller has already established there are ≥2 steps.
    func runPipe(_ steps: [[String]]) {
        lock.lock(); defer { lock.unlock() }
        let table = LuaValue.table(steps.map { .table($0.map { .string($0) }, [:]) }, [:])
        try? lua.callGlobal("__pipe", [table])
    }

    /// `+| <cmd…>` — append the steps onto the current in-flight promise (see bootstrap __pipe_append)
    /// rather than starting a fresh chain, so `recover` then `+| explore` behaves like `recover | explore`.
    /// Each step is a `;`-group, exactly like `runPipe`.
    func appendPipe(_ steps: [[String]]) {
        lock.lock(); defer { lock.unlock() }
        let table = LuaValue.table(steps.map { .table($0.map { .string($0) }, [:]) }, [:])
        try? lua.callGlobal("__pipe_append", [table])
    }

    /// `-|` — the inverse of `+|`, an operator on its own: drop the END (last segment) of the current
    /// in-flight promise chain, cancelling it (and running its cancel hook if it had started) while the
    /// earlier segments keep running. See bootstrap `__pipe_pop`.
    func popPipe() {
        lock.lock(); defer { lock.unlock() }
        try? lua.callGlobal("__pipe_pop", [])
    }

    /// Consult the optional Lua `on_send(cmd)` hook for one final, atomic outbound command (already
    /// past alias handling and `;` splitting) and return the commands that should actually be
    /// transmitted, in order. No hook defined → `[command]` unchanged. The hook's return value governs
    /// the ORIGINAL command: nil → unchanged; `false` → suppressed; a string → replacement. Any
    /// `send()` the hook itself calls is transmitted directly (never re-consulted — no recursion) and
    /// precedes the original's disposition.
    func filterOutbound(_ command: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        let previous = hookSends
        hookSends = []                                  // arm the recursion guard for the hook's own send()s
        defer { hookSends = previous }
        let result: LuaValue?
        do { result = try lua.callGlobalReturning("on_send", [.string(command)]) }
        catch { result = nil }                          // errorHandler already reported; send unchanged
        let collected = hookSends ?? []
        switch result {
        case .some(.bool(false)):
            return collected                            // suppress the original
        case .some(.string(let replacement)):
            return collected + [replacement]            // send the replacement instead
        default:
            return collected + [command]                // no hook / nil / any truthy → send unchanged
        }
    }

    /// Call a global Lua function with a single string argument (no-op if undefined). Used to route
    /// `#ai <args>` to the script's `ai_command`.
    func callGlobal(_ name: String, _ arg: String) {
        lock.lock(); defer { lock.unlock() }
        try? lua.callGlobal(name, [.string(arg)])
    }

    /// Give scripts a chance to refresh the status panel after a batch of server output (triggers have
    /// already updated `state`). Calls the optional global `on_update`, which rebuilds the panel model
    /// via `panel.render`. The actual repaint is the screen owner's job (TerminalService), done right
    /// after this returns — so multiple `panel.render` calls within one update coalesce into one paint.
    func notifyUpdate() {
        lock.lock(); defer { lock.unlock() }
        try? lua.callGlobal("on_update", [])
    }

    /// Notify the script that the terminal was resized (after the host has relaid out the screen).
    /// No-op unless the script defines a global `on_resize(cols, rows)`.
    func notifyResize(cols: Int, rows: Int) {
        lock.lock(); defer { lock.unlock() }
        try? lua.callGlobal("on_resize", [.int(Int64(cols)), .int(Int64(rows))])
    }

    /// Offer a mouse event to the script's optional global `on_mouse(event, x, y, button)`. Returns
    /// true iff the handler returned a truthy value (i.e. it consumed the event). No handler → false,
    /// so the host falls through to its default behaviour.
    func notifyMouse(event: String, x: Int, y: Int, button: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let args: [LuaValue] = [.string(event), .int(Int64(x)), .int(Int64(y)), .int(Int64(button))]
        return (try? lua.callGlobalBool("on_mouse", args)) ?? false
    }

    /// Fire the most recently registered `bind` handler for `name` (a canonical key name). Returns
    /// true iff a binding existed (so the host consumes the key instead of line-editing it). The
    /// handler is called with the key name, so one function bound to several keys can tell them apart.
    func handleKey(_ name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        // Highest id wins → last `bind` for a key takes precedence (TinTin `#macro` semantics).
        guard let handler = keyBindings.filter({ $0.value.key == name })
            .max(by: { $0.key < $1.key })?.value.handler else { return false }
        try? lua.call(handler, [.string(name)])
        return true
    }

    /// Canonicalise a user-supplied key name so `bind("F5")`, `bind("f5")` etc. all match what the
    /// terminal decoder emits. Lowercases, normalises modifier order to ctrl-alt-shift-meta, and maps
    /// a few common aliases (pgup/pgdn/ins/del). Must stay in sync with TerminalService's decoder.
    static func normalizeKeyName(_ name: String) -> String {
        var parts = name.lowercased().split(separator: "-").map(String.init)
        guard var base = parts.popLast() else { return name.lowercased() }
        switch base {
        case "pgup": base = "pageup"
        case "pgdn", "pgdown": base = "pagedown"
        case "ins": base = "insert"
        case "del": base = "delete"
        default: break
        }
        let mods = Set(parts.map { m -> String in
            switch m {
            case "control", "ctl": return "ctrl"
            case "option", "opt": return "alt"
            case "cmd", "command", "super": return "meta"
            default: return m
            }
        })
        var out = ""
        if mods.contains("ctrl") { out += "ctrl-" }
        if mods.contains("alt") { out += "alt-" }
        if mods.contains("shift") { out += "shift-" }
        if mods.contains("meta") { out += "meta-" }
        return out + base
    }

    /// The socket just went active. No-op unless the script defines `on_connect`.
    func notifyConnect() {
        lock.lock(); defer { lock.unlock() }
        try? lua.callGlobal("on_connect", [])
    }

    /// Run an incoming server text chunk through the script's on_stream filter; returns the text to
    /// display. Falls back to the chunk unchanged when no filter is registered or it errors.
    func filterStream(_ chunk: String) -> String {
        lock.lock(); defer { lock.unlock() }
        guard let fn = streamFilter,
              let result = try? lua.callReturning(fn, [.string(chunk)]),
              case .string(let filtered) = result
        else { return chunk }
        return filtered
    }

    /// The socket went down. No-op unless the script defines `on_disconnect(reason)`.
    func notifyDisconnect(reason: String) {
        lock.lock(); defer { lock.unlock() }
        try? lua.callGlobal("on_disconnect", [.string(reason)])
    }

    /// Raw bytes arrived on the game-agnostic `NetConnection`. No-op unless the script defines
    /// `on_net(data)`. `data` is delivered byte-exact (see `LuaValue.bytes`/`Lua.push`) so a raw
    /// protobuf/RPC frame survives the round-trip.
    func notifyNet(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        try? lua.callGlobal("on_net", [.bytes(data)])
    }

    /// The `NetConnection` socket just went active. No-op unless the script defines `on_net_connect`.
    func notifyNetConnect() {
        lock.lock(); defer { lock.unlock() }
        try? lua.callGlobal("on_net_connect", [])
    }

    /// The `NetConnection` socket went down. No-op unless the script defines `on_net_disconnect(reason)`.
    func notifyNetDisconnect(reason: String) {
        lock.lock(); defer { lock.unlock() }
        try? lua.callGlobal("on_net_disconnect", [.string(reason)])
    }

    /// A GO-AHEAD prompt boundary flushed `text`. No-op unless the script defines `on_prompt(text)`.
    func notifyPrompt(_ text: String) {
        // A prompt is the server's reply boundary — pair it with the last send for a round-trip sample.
        Container.lagMonitor().notePrompt()
        lock.lock(); defer { lock.unlock() }
        try? lua.callGlobal("on_prompt", [.string(text)])
    }

    /// A telnet subnegotiation arrived. Delivers the numeric `option` and the raw `payload` bytes (as
    /// a byte-exact Lua string) to `on_telnet(option, payload)`. No-op unless the script defines it.
    func notifyTelnet(option: Int, payload: Data) {
        lock.lock(); defer { lock.unlock() }
        try? lua.callGlobal("on_telnet", [.int(Int64(option)), .bytes(payload)])
    }

    /// Consult the optional `on_telnet_negotiate(verb, option)` hook for a WILL/WONT/DO/DONT option.
    /// Returns its string result (expected `"accept"`/`"reject"`), or nil if the hook is absent or
    /// returns a non-string. Called synchronously from the telnet layer to decide a negotiation reply.
    func telnetNegotiate(verb: String, option: Int) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let value = try? lua.callGlobalReturning("on_telnet_negotiate",
                                                       [.string(verb), .int(Int64(option))]) else { return nil }
        if case .string(let s) = value { return s }
        return nil
    }

    // MARK: - Loading scripts

    /// Register an extra game-specific builtin (e.g. `kxwt`, `recover`). Call
    /// during setup, before any script runs.
    func register(_ name: String, _ fn: @escaping LuaHostFunction) {
        lock.lock(); defer { lock.unlock() }
        lua.register(name, fn)
    }

    func load(source: String) throws {
        lock.lock(); defer { lock.unlock() }
        try lua.run(source)
    }

    func load(path: String) throws {
        lock.lock(); defer { lock.unlock() }
        try lua.runFile(path)
    }

    /// Drop all registered triggers/aliases/gags. Used before re-running a script
    /// file so a hot-reload doesn't stack duplicate rules. The host builtins
    /// (send/echo/trigger/...) live on the lua_State and survive.
    func clearRules() {
        lock.lock(); defer { lock.unlock() }
        lineRules.removeAll()
        aliasRules.removeAll()
        gags.removeAll()
        keyBindings.removeAll()
        // Cancel every outstanding timer too, so a hot-reload (`#ai reload`) can't strand ghost
        // `after`/`every` callbacks firing into freshly-loaded state.
        for item in timers.values { item.cancel() }
        timers.removeAll()
    }

    /// Next unique handle for a rule or timer. Safe to call with `lock` already held (recursive).
    private func nextId() -> Int {
        lock.lock(); defer { lock.unlock() }
        lastId += 1
        return lastId
    }

    // MARK: - Dispatch

    /// Strips ANSI/VT control sequences (CSI — colours, cursor moves, etc.) so triggers and gags match
    /// the plain text a player sees, not the escape codes. Without this, a coloured line like
    /// "\u{1B}[37m\u{1B}[0m[Exits: west ]" fails a `^\[Exits:` trigger. Display output keeps its colour;
    /// only the copy used for matching is cleaned.
    private let ansiSequence = try! Regex("\u{1B}\\[[0-9;?]*[ -/]*[@-~]")

    /// Fire matching line triggers (the rewrite stage), then apply the separate gag list. Returns the
    /// line to display, or `nil` if it should be dropped (gagged).
    ///
    /// Each trigger handler runs against the CURRENT line (a previous trigger may have rewritten it)
    /// and is called as `handler(cleanLine, cap1, ..., rawLine)` — the ANSI-stripped text plus its
    /// capture groups, followed by the current raw (coloured) line so scripts can do colour-preserving
    /// rewrites. Its return value controls the displayed line:
    ///   * nil / no return   → unchanged
    ///   * `false` or `""`   → gag the line
    ///   * a string          → replace the displayed line with it (may contain ANSI escapes)
    /// Disabled rules are skipped; `oneshot` rules are removed after they fire. ALL matching rules
    /// fire, in specificity order (priority desc, specificity desc, registration order) — the array
    /// is kept sorted at insertion (see `insertSorted`) — so a line's specific parsers/rewriters run
    /// before broad `.*` observers, and each handler sees the current (possibly rewritten) line.
    func processLine(_ line: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        var current = line
        var gagged = false
        var firedOneshots: [Int] = []
        for rule in lineRules {
            guard rule.enabled, let handler = rule.handler else { continue }
            let clean = current.replacing(ansiSequence, with: "")
            guard let match = try? rule.regex.firstMatch(in: clean) else { continue }
            let result = try? lua.callReturning(handler, callArgs(line: clean, match: match, raw: current))
            if rule.oneshot { firedOneshots.append(rule.id) }
            switch result {
            case .string(let s):
                if s.isEmpty { gagged = true } else { current = s }
            case .bool(false):
                gagged = true
            default:
                break // nil / no-return / any other value → line unchanged
            }
            // A gag is a DISPLAY decision (this line won't render) — it must NOT stop the chain. Every
            // matching handler still fires, in order, so a broad gag (e.g. the `^kxw[tq]_` machine-tag
            // hider) can't supplant a lower-specificity PARSER that needs to read the same line. Parsers
            // that shouldn't touch a machine line filter it themselves (they already do); gagging and
            // parsing are orthogonal. (`gagged` is sticky — once set, the line stays hidden.)
        }
        if !firedOneshots.isEmpty { lineRules.removeAll { firedOneshots.contains($0.id) } }
        if gagged { return nil }
        // The standalone gag list still applies to whatever the line now is.
        let clean = current.replacing(ansiSequence, with: "")
        if gags.contains(where: { $0.enabled && (try? $0.regex.firstMatch(in: clean)) != nil }) { return nil }
        return current
    }

    /// Fire the most-specific matching alias for user input. Returns true if one matched (so the raw
    /// input is swallowed). `aliasRules` is kept sorted (priority desc, specificity desc, registration
    /// order), so the FIRST match in iteration is the most specific — "most specific match wins".
    func processAlias(_ input: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        for rule in aliasRules {
            guard rule.enabled, let handler = rule.handler else { continue }
            guard let match = try? rule.regex.firstMatch(in: input) else { continue }
            try? lua.call(handler, callArgs(line: input, match: match, raw: input))
            if rule.oneshot { aliasRules.removeAll { $0.id == rule.id } }
            return true
        }
        return false
    }

    /// Handler is called as `handler(wholeLine, capture1, capture2, ..., rawLine)`. `rawLine` is the
    /// original (still-coloured) line, appended after the captures for colour-preserving rewrites.
    private func callArgs(line: String, match: Regex<AnyRegexOutput>.Match, raw: String) -> [LuaValue] {
        let output = match.output
        var args: [LuaValue] = [.string(line)]
        if output.count > 1 {
            for i in 1..<output.count {
                args.append(output[i].substring.map { LuaValue.string(String($0)) } ?? .nil)
            }
        }
        args.append(.string(raw))
        return args
    }

    // MARK: - Builtins

    private func installBuiltins() {
        lua.register("send") { [weak self] args in
            guard let self else { return [] }
            // NEVER coerce here: send("function: 0x…") reaching the MUD would be far worse than an
            // error line. A wrong type gets a usage hint instead of a silent no-op.
            guard case .string(let s)? = args.first else {
                self.usage(#"send: expected a command string — e.g. send("look")"#)
                return []
            }
            // A send() issued from within on_send is diverted (see `hookSends`), so it reaches the MUD
            // directly without being fed back through the hook. Every other send takes the normal sink.
            if self.hookSends != nil { self.hookSends?.append(s) } else { self.onSend(s) }
            return []
        }
        // echo(text[, color]) — print a line, optionally styled. `color` is a spec like "red",
        // "bright red" (or "brightred"), "bold red underline" — resolved by sgrCodes against the shared
        // palette. Unknown words print the text anyway (with whatever DID resolve) plus a hint, so a
        // typo'd color is never a silent no-op. Non-string text is coerced by the bootstrap's echo
        // wrapper before it gets here (see Scripts/bootstrap.lua).
        lua.register("echo") { [weak self] args in
            guard let self, case .string(let s)? = args.first else { return [] }
            var text = s
            if args.count > 1, case .string(let colorSpec) = args[1] {
                let (codes, unknown) = Self.sgrCodes(colorSpec)
                if !codes.isEmpty { text = "\u{1B}[\(codes.joined(separator: ";"))m\(s)\u{1B}[0m" }
                for word in unknown {
                    self.usage("echo: unknown color '\(word)' — try help(colors)")
                }
            }
            self.onRecordEcho(text)   // so `#grep` finds script echoes, not just wire lines
            self.onEcho(text)
            return []
        }
        // trigger(pattern, handler [, opts]) -> id. opts = { oneshot = true, class = "combat" }.
        lua.register("trigger") { [weak self] args in
            guard let self else { return [] }
            // Bare `trigger` — no handler given (the `#trigger` REPL passes zero args or a lone ""); show
            // the syntax AND list what's registered. A real registration always has (pattern, handler).
            if args.count < 2 {
                self.usage(#"trigger: expected (pattern, handler[, opts]) with a valid regex — e.g. trigger("^You hit", function(line) end)"#)
                self.listLineRules()
                return []
            }
            guard let rule = self.makeRule(args) else {
                self.usage(#"trigger: expected (pattern, handler[, opts]) with a valid regex — e.g. trigger("^You hit", function(line) end)"#)
                return []
            }
            self.insertSorted(rule, into: &self.lineRules)
            return [.int(Int64(rule.id))]
        }
        // alias(pattern, handler [, opts]) -> id. Same options as trigger().
        lua.register("alias") { [weak self] args in
            guard let self else { return [] }
            // Bare `alias` — no handler (the `#alias` REPL passes zero args or a lone ""); show the syntax
            // AND list what's registered, mirroring bare `#trigger`. A real registration has (pattern, handler).
            if args.count < 2 {
                self.usage(#"alias: expected (pattern, handler[, opts]) with a valid regex — e.g. alias("^gold$", function() send("score gold") end)"#)
                self.listAliasRules()
                return []
            }
            guard let rule = self.makeRule(args) else {
                self.usage(#"alias: expected (pattern, handler[, opts]) with a valid regex — e.g. alias("^gold$", function() send("score gold") end)"#)
                return []
            }
            self.insertSorted(rule, into: &self.aliasRules)
            return [.int(Int64(rule.id))]
        }
        // gag(pattern) -> id. Drops matching lines; removable/toggleable by id like any rule.
        lua.register("gag") { [weak self] args in
            guard let self else { return [] }
            // Bare `gag` — no pattern (the `#gag` REPL passes zero args); show the syntax AND list the
            // registered gags, mirroring bare `#trigger` / `#alias`.
            guard case .string(let pat)? = args.first else {
                self.usage(#"gag: expected a valid regex pattern — e.g. gag("^kxwt_")"#)
                self.listGagRules()
                return []
            }
            guard let rx = try? Regex(pat) else {
                self.usage(#"gag: expected a valid regex pattern — e.g. gag("^kxwt_")"#)
                return []
            }
            let rule = Rule(id: self.nextId(), regex: rx, patternSource: pat, handler: nil)
            self.gags.append(rule)
            return [.int(Int64(rule.id))]
        }
        // untrigger / unalias / ungag <id | regex> — remove matching rules from ONE list (unlike
        // rule_remove(id), which spans all three types). A bare NUMBER removes by id; anything else is
        // compiled as a regex and matched against each rule's patternSource, so `#unalias dsleep` drops
        // the `^dsleep$` alias. Echoes what went (or that nothing matched).
        lua.register("untrigger") { [weak self] args in self?.unregister(args, kind: "trigger"); return [] }
        lua.register("unalias")   { [weak self] args in self?.unregister(args, kind: "alias");   return [] }
        lua.register("ungag")     { [weak self] args in self?.unregister(args, kind: "gag");      return [] }
        // rule_remove(id) — drop the trigger/alias/gag with this id (from wherever it lives).
        lua.register("rule_remove") { [weak self] args in
            guard let self, let id = args.first.flatMap(Self.intArg) else { return [] }
            self.lineRules.removeAll { $0.id == id }
            self.aliasRules.removeAll { $0.id == id }
            self.gags.removeAll { $0.id == id }
            return []
        }
        // rule_enable(id, on) — enable/disable a single rule (disabled rules don't match).
        lua.register("rule_enable") { [weak self] args in
            guard let self, let id = args.first.flatMap(Self.intArg) else { return [] }
            let on = Self.boolArg(args.count > 1 ? args[1] : nil)
            for r in self.lineRules where r.id == id { r.enabled = on }
            for r in self.aliasRules where r.id == id { r.enabled = on }
            for r in self.gags where r.id == id { r.enabled = on }
            return []
        }
        // class_enable(name, on) — enable/disable every trigger/alias tagged with this class.
        lua.register("class_enable") { [weak self] args in
            guard let self, case .string(let name)? = args.first else { return [] }
            let on = Self.boolArg(args.count > 1 ? args[1] : nil)
            for r in self.lineRules where r.ruleClass == name { r.enabled = on }
            for r in self.aliasRules where r.ruleClass == name { r.enabled = on }
            return []
        }
        // class_remove(name) — remove every trigger/alias tagged with this class.
        lua.register("class_remove") { [weak self] args in
            guard let self, case .string(let name)? = args.first else { return [] }
            self.lineRules.removeAll { $0.ruleClass == name }
            self.aliasRules.removeAll { $0.ruleClass == name }
            return []
        }
        // ---- Script-loader primitives (the `load`/`reload`/`loadchunk` globals live in bootstrap.lua) ----
        // The user-facing loader is pure Lua (path resolution, the `.lua` extension rule, directory
        // ordering/exclusions); these `__`-prefixed builtins are the thin host I/O it stands on. All
        // paths resolve relative to the process CWD (the app runs from the repo root).
        //
        // __path_kind(path) -> "file" | "dir" | "missing".
        lua.register("__path_kind") { args in
            guard case .string(let p)? = args.first else { return [.string("missing")] }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir) else {
                return [.string("missing")]
            }
            return [.string(isDir.boolValue ? "dir" : "file")]
        }
        // __list_dir(path) -> array of ALL entry names directly in `path` (files AND subdirectories).
        // The Lua directory loader classifies each entry via __path_kind and decides whether to descend
        // (Scripts/ is now nested — Foundation/, AlterAeon/ — so subdirs MUST be visible here or the
        // recursive walk never sees them and loads nothing).
        lua.register("__list_dir") { args in
            guard case .string(let p)? = args.first,
                  let entries = try? FileManager.default.contentsOfDirectory(atPath: p) else {
                return [.table([], [:])]
            }
            return [.table(entries.map(LuaValue.string), [:])]
        }
        // __run_file(path) — execute one Lua file in the live state. Errors are echoed (a host call
        // can't raise a Lua error across the trampoline); returns true on success, false on failure.
        lua.register("__run_file") { [weak self] args in
            guard case .string(let path)? = args.first, let self else { return [.bool(false)] }
            do { try self.load(path: path); return [.bool(true)] }
            catch { self.onEcho("[load] \(path): \(error)"); return [.bool(false)] }
        }
        // __clear_rules() — drop every trigger/alias/gag/bind/timer (reload() calls this first).
        lua.register("__clear_rules") { [weak self] _ in self?.clearRules(); return [] }
        // ---- Connection lifecycle control (host-generic; the default startup connection is unchanged) ----
        // connect(host, port) — open (or re-open) the connection. `port` defaults to 23 if omitted.
        lua.register("connect") { [weak self] args in
            guard case .string(let host)? = args.first else {
                self?.usage(#"connect: expected (host[, port]) — e.g. connect("alteraeon.com", 3002)"#)
                return []
            }
            let port = UInt16(args.count > 1 ? (Self.intArg(args[1]) ?? 23) : 23)
            Container.connectionManager().connect(host: host, port: port)
            return []
        }
        // disconnect() — close the current connection.
        lua.register("disconnect") { _ in
            Container.connectionManager().disconnect()
            return []
        }
        // is_connected() -> bool.
        lua.register("is_connected") { _ in
            [.bool(Container.connectionManager().isConnected)]
        }
        // telnet_send(option, payload) — send `IAC SB <option> <payload> IAC SE`, escaping IAC bytes in
        // the payload. `option` is numeric; `payload` is a (byte) string.
        lua.register("telnet_send") { [weak self] args in
            guard let option = args.first.flatMap(Self.intArg), option >= 0, option <= 255 else {
                self?.usage(#"telnet_send: expected (option 0-255[, payload]) — e.g. telnet_send(90, "!!SOUND(ding)")"#)
                return []
            }
            let payload: [UInt8] = {
                if args.count > 1, case .string(let s) = args[1] { return Array(s.utf8) }
                return []
            }()
            var data: [UInt8] = [255, 250, UInt8(option)]        // IAC SB <option>
            for b in payload {
                if b == 255 { data.append(255) }                 // escape IAC as IAC IAC
                data.append(b)
            }
            data.append(contentsOf: [255, 240])                  // IAC SE
            Container.connectionManager().sendRaw(Data(data))
            return []
        }
        // Raw server-stream filter. A script registers `on_stream(fn)`; the host hands each incoming
        // text chunk to `fn(chunk)` and displays whatever string it returns. Lets a script strip and act
        // on a custom in-band protocol (e.g. AlterAeon's `;`-framed dclient channel) without the client
        // knowing anything about it — the client only knows "a script may rewrite the stream".
        lua.register("on_stream") { [weak self] args in
            if case .function(let fn)? = args.first { self?.streamFilter = fn }
            return []
        }
        // ---- Generic binary socket (game-agnostic — no protocol/framing knowledge here; that's Lua's
        // job now). Mirrors connect/disconnect/is_connected above, but raw-byte, and a second, wholly
        // independent socket from the telnet ConnectionManager. ----
        // net_connect(host, port[, opts]) — opts.tls (bool, default false).
        lua.register("net_connect") { [weak self] args in
            guard case .string(let host)? = args.first, let port = args.count > 1 ? Self.intArg(args[1]) : nil else {
                self?.usage(#"net_connect: expected (host, port[, {tls=true}]) — e.g. net_connect("example.com", 443, {tls=true})"#)
                return []
            }
            var tls = false
            if args.count > 2, case .table(_, let opts) = args[2], case .bool(let b)? = opts["tls"] { tls = b }
            Container.netConnection().connect(host: host, port: port, tls: tls)
            return []
        }
        // net_send(data) — raw write to the socket, binary-safe (no newline appended, no splitting).
        lua.register("net_send") { [weak self] args in
            guard let data = args.first.flatMap(Self.dataArg) else {
                self?.usage(#"net_send: expected a (byte) string — e.g. net_send("\255\250...")"#)
                return []
            }
            Container.netConnection().send(data)
            return []
        }
        // net_disconnect() — close the socket.
        lua.register("net_disconnect") { _ in
            Container.netConnection().disconnect()
            return []
        }
        // net_is_connected() -> bool.
        lua.register("net_is_connected") { _ in
            [.bool(Container.netConnection().isConnected)]
        }
        // feed_server(data) — inject raw bytes into the SAME inbound display/trigger pipeline the
        // telnet connection uses, so a script can hand decoded game text (e.g. peeled out of a
        // protobuf frame) back to be rendered + trigger-processed. Independent of net_connect/
        // is_connected — works even with no socket open at all.
        lua.register("feed_server") { [weak self] args in
            guard let data = args.first.flatMap(Self.dataArg) else {
                self?.usage(#"feed_server: expected a (byte) string — e.g. feed_server("You are standing here.\n")"#)
                return []
            }
            Container.serverTextFeed().feed(data)
            return []
        }
        installLogReplay()
    }

    // MARK: - Session logging & log replay (TinTin++ #log / #textin)

    private func installLogReplay() {
        // log_start(path, opts?) -> bool. opts = { timestamps=bool, ansi=bool, commands=bool }. Writes
        // each displayed server line (and, with commands=true, each sent command) as plain text; ansi
        // defaults false (escapes stripped), timestamps defaults false. Appends if the file exists.
        lua.register("log_start") { [weak self] args in
            guard case .string(let path)? = args.first else {
                self?.usage(#"log_start: expected a file path — e.g. log_start("session.log", { commands = true })"#)
                return [.bool(false)]
            }
            var timestamps = false, ansi = false, commands = false
            if args.count > 1, case .table(_, let opts) = args[1] {
                if case .bool(let b)? = opts["timestamps"] { timestamps = b }
                if case .bool(let b)? = opts["ansi"] { ansi = b }
                if case .bool(let b)? = opts["commands"] { commands = b }
            }
            let ok = Container.sessionLog().start(path: path, timestamps: timestamps,
                                                  ansi: ansi, commands: commands)
            return [.bool(ok)]
        }
        lua.register("log_stop") { _ in Container.sessionLog().stop(); return [] }
        // log_active() -> (bool, path|nil).
        lua.register("log_active") { _ in
            let (active, path) = Container.sessionLog().status()
            return [.bool(active), path.map(LuaValue.string) ?? .nil]
        }

        // replay(path, opts?) -> bool. Feeds each line of a plain-text file through the SAME server-line
        // pipeline scripts see (triggers/gags fire; non-gagged lines display) with NO network and NO
        // session logging. opts = { speed=N lines/sec (default: as-fast-as-possible, yielding),
        // quiet=bool (fire triggers without printing) }.
        lua.register("replay") { [weak self] args in
            guard let self else { return [.bool(false)] }
            guard case .string(let path)? = args.first else {
                self.usage(#"replay: expected a log-file path — e.g. replay("session.log", { speed = 20 })"#)
                return [.bool(false)]
            }
            var speed = 0.0, quiet = false
            if args.count > 1, case .table(_, let opts) = args[1] {
                if case .some(let v) = opts["speed"], let s = Self.doubleArg(v) { speed = s }
                if case .bool(let b)? = opts["quiet"] { quiet = b }
            }
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
                self.onEcho("[replay] cannot read \(path)")
                return [.bool(false)]
            }
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            self.startReplay(lines: lines, speed: speed, quiet: quiet)
            return [.bool(true)]
        }
    }

    /// Drive a replay off the Lua thread: for each line, fire triggers/gags via `processLine` and (unless
    /// quiet or gagged) print it, refreshing the panel between lines. Paced at `speed` lines/sec, or —
    /// when speed <= 0 — as fast as possible while yielding so the UI stays responsive. Runs on its own
    /// Task so a long file doesn't block the `replay()` call (which holds the Lua lock).
    private func startReplay(lines: [String], speed: Double, quiet: Bool) {
        let interval: Double = speed > 0 ? 1.0 / speed : 0
        Task { [weak self] in
            guard let self else { return }
            for line in lines {
                let display = self.processLine(line)         // fires triggers/gags (takes the lock itself)
                if !quiet, let display { Container.terminalService().print(display, terminator: "\n") }
                self.notifyUpdate()                          // panels may have changed
                if interval > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } else {
                    await Task.yield()
                }
            }
            if !quiet { self.onEcho("[replay] done (\(lines.count) lines)") }
        }
    }

    /// Panel builtins — a generic top-of-screen HUD driven by a declarative spec. `panel.render(spec)`
    /// replaces the panel model (spec = a list of rows, each a line of styled spans or a set of column
    /// cells); `panel.height(n)` pins the panel height. All layout/widget logic lives in the Lua HUD
    /// script; PanelHost just turns the spec into ANSI in a frozen scroll-region at the top.
    private func installPanel() {
        lua.register("panel_render") { args in
            if let first = args.first { Container.panelHost().render(first) }
            return []
        }
        lua.register("panel_height") { args in
            switch args.first {
            case .int(let n)?: Container.panelHost().setPinnedHeight(Int(n))
            case .number(let d)?: Container.panelHost().setPinnedHeight(Int(d))
            default: break
            }
            return []
        }
        // The top panel (group roster, etc.) — same spec, a separate frozen region at the top.
        lua.register("panel_top") { args in
            if let first = args.first { Container.topPanelHost().render(first) }
            return []
        }
        lua.register("panel_top_height") { args in
            switch args.first {
            case .int(let n)?: Container.topPanelHost().setPinnedHeight(Int(n))
            case .number(let d)?: Container.topPanelHost().setPinnedHeight(Int(d))
            default: break
            }
            return []
        }
        // Expose them under a `panel` table: `panel.render{...}` / `panel.height(n)` for the bottom
        // status panel, `panel.top{...}` / `panel.top_height(n)` for the top panel.
        try? lua.run("""
            panel = { render = panel_render, height = panel_height,
                      top = panel_top, top_height = panel_top_height }
            """)

        // Generic layered audio player — scripts just say `music.play("channel", "track")` /
        // `music.stop("channel")`. Swift knows nothing about the MUD; it plays a named file from the
        // configured sound dir (see MusicService), so any protocol parsing stays in Lua.
        lua.register("music_play") { [weak self] args in
            guard case .string(let ch)? = args.first, args.count > 1, case .string(let track) = args[1] else {
                self?.usage(#"music.play: expected (channel, track) strings — e.g. music.play("ambient", "forest")"#)
                return []
            }
            Container.soundService().play(channel: ch, track: track)
            return []
        }
        lua.register("music_stop") { args in
            if case .string(let ch)? = args.first { Container.soundService().stop(channel: ch) }
            return []
        }
        // music.volume(pct) — set the master volume for all channels from a 0-100 percentage.
        lua.register("music_volume") { args in
            if let pct = args.first.flatMap(Self.doubleArg) { Container.soundService().setMusicVolume(percent: pct) }
            return []
        }
        // msp_volume(pct) — master for one-shot sound effects (0-100); scales every NEW effect, 0 silences.
        lua.register("msp_volume") { args in
            if let pct = args.first.flatMap(Self.doubleArg) { Container.soundService().setEffectVolume(percent: pct) }
            return []
        }
        // speech_volume(pct) — TTS voice volume (0-100); at 0 utterances are dropped (no synth/playback).
        lua.register("speech_volume") { args in
            if let pct = args.first.flatMap(Self.doubleArg) { Container.speechService().setVolume(percent: pct) }
            return []
        }
        // Live MIDI performances (kxwt_midi) — a real-time synth fed raw MIDI bytes, distinct from the
        // file-based music.play. Scripts strip the kxwt framing and hand over the hex-byte payload of one
        // MIDI message ("90 4d 32"); Swift parses + dispatches it to the sampler. See LiveMidiService.
        lua.register("music_midi") { [weak self] args in
            guard case .string(let hex)? = args.first else {
                self?.usage(#"music.midi: expected a hex MIDI-byte string — e.g. music.midi("90 4d 32")"#)
                return []
            }
            Container.liveMidiService().send(Self.midiBytes(hex))
            return []
        }
        // music.midi_reset() — All-Notes-Off panic (performer left / socket dropped) so nothing hangs.
        lua.register("music_midi_reset") { _ in
            Container.liveMidiService().reset()
            return []
        }
        try? lua.run("music = { play = music_play, stop = music_stop, volume = music_volume, "
                     + "midi = music_midi, midi_reset = music_midi_reset }")

        // sound_once(path[, volume]) — a ONE-SHOT effect player, distinct from the looping `music.*`
        // above. Routed through SoundService's AVAudioEngine one-shot node pool (see SoundService.swift)
        // so dclient's framed `;ssound;` one-shots (which never arrive as MSP directives — see
        // DClientProbe.lua) actually play — AVAudioPlayer, which the old mspService pipeline used, cannot
        // play the soundpack's Ogg Vorbis files at all. `path` is resolved by SoundService itself (an
        // absolute filesystem path, as DClientProbe.lua builds). The `volume` arg is accepted for
        // signature stability but ignored: one-shot effect volume is controlled globally via
        // `msp_volume`/`volume('sfx N')`, not per call.
        lua.register("sound_once") { [weak self] args in
            guard case .string(let path)? = args.first else {
                self?.usage(#"sound_once: expected (path[, volume]) — e.g. sound_once("/path/to/effect.ogg")"#)
                return []
            }
            Container.soundService().playOnce(track: path)
            return []
        }
    }

    /// Terminal/input capabilities (TinTin++-style): key macros, input-line access, scrollback reads,
    /// and small output niceties. All delegate to the screen owner (TerminalService); none are
    /// game-specific.
    private func installTerminal() {
        // bind(keyname, handler) -> id. Registers a key macro; the handler is called with the key
        // name when that key is pressed (and the key is then consumed, not line-edited).
        lua.register("bind") { [weak self] args in
            guard let self else { return [.nil] }
            guard case .string(let key)? = args.first,
                  args.count > 1, case .function(let handler) = args[1] else {
                self.usage(#"bind: expected (keyname, handler) — e.g. bind("f5", function() send("look") end)"#)
                return [.nil]
            }
            let id = self.nextBindId
            self.nextBindId += 1
            self.keyBindings[id] = (Self.normalizeKeyName(key), handler)
            return [.int(Int64(id))]
        }
        // unbind(id) — remove a binding previously returned by bind().
        lua.register("unbind") { [weak self] args in
            if let id = args.first.flatMap(Self.intArg) { self?.keyBindings.removeValue(forKey: id) }
            return []
        }
        // input_get() -> the current input-line text.
        lua.register("input_get") { _ in [.string(Container.terminalService().currentInput())] }
        // input_set(text) — replace the input line and redraw it.
        lua.register("input_set") { [weak self] args in
            switch args.first {
            case .string(let t)?: Container.terminalService().setInput(t)
            // Text-ish arg: coerce scalars the way Lua's tostring would (input_set(2) is unambiguous).
            case .int(let i)?: Container.terminalService().setInput(String(i))
            case .number(let d)?: Container.terminalService().setInput(String(d))
            default:
                self?.usage(#"input_set: expected text — e.g. input_set("say hello")"#)
            }
            return []
        }
        // scrollback(n) -> array of the last n display lines (ANSI stripped), oldest-first.
        lua.register("scrollback") { args in
            let n = args.first.flatMap(Self.intArg) ?? 0
            let lines = Container.terminalService().scrollbackTail(count: n)
            return [.table(lines.map(LuaValue.string), [:])]
        }
        // scrollback_find(pattern, max) -> array of up-to-max most-recent matching lines (ANSI
        // stripped), oldest-first. `pattern` is a Swift Regex over the stripped text.
        lua.register("scrollback_find") { args in
            guard case .string(let pat)? = args.first else { return [.table([], [:])] }
            let max = args.count > 1 ? (Self.intArg(args[1]) ?? 100) : 100
            let lines = Container.terminalService().scrollbackFind(pattern: pat, max: max)
            return [.table(lines.map(LuaValue.string), [:])]
        }
        // grep(text) — print every transcript line (sent AND received) containing `text` (case-
        // insensitive substring), each labeled by kind/origin. Backs `#grep foo` and `#grep('foo')`.
        lua.register("grep") { [weak self] args in
            guard case .string(let pat)? = args.first, !pat.isEmpty else {
                self?.onEcho("\u{1B}[31musage: #grep <text>\u{1B}[0m"); return []
            }
            self?.echoTranscript(Container.transcriptStore().grep(pat), header: "grep \u{201C}\(pat)\u{201D}")
            return []
        }
        // sent([n]) — print the last n (default 20) commands SENT, labeled by origin (you vs a script).
        // Backs `#sent` and `#sent 10`.
        lua.register("sent") { [weak self] args in
            let n = args.first.flatMap(Self.countArg) ?? 20
            self?.echoTranscript(Container.transcriptStore().sent(last: n), header: "last \(n) sent")
            return []
        }
        // received([n]) — print the last n (default 20) lines RECEIVED from the server. Backs `#received`
        // and `#received 10`.
        lua.register("received") { [weak self] args in
            let n = args.first.flatMap(Self.countArg) ?? 20
            self?.echoTranscript(Container.transcriptStore().received(last: n), header: "last \(n) received")
            return []
        }
        // claude(feedback) — hand freeform developer feedback + a context bundle to a running Claude Code
        // session (via the local `muddispatch` channel). Backs `#claude <freeform feedback>`. Builds a
        // /tmp bundle (feedback + timestamped interleaved transcript + a raw.log copy), then fire-and-
        // forget POSTs it to the channel server; the working session reads the bundle and acts on it.
        // A leading `--chat` / `--bare` / `-c` flag sends a context-FREE bundle (like `#chat`, below).
        lua.register("claude") { [weak self] args in
            guard case .string(let raw)? = args.first,
                  !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
                self?.usage(#"claude: describe what you want — e.g. #claude fix the corpse sac timing  (or #chat <message> to talk with no game context attached)"#)
                return []
            }
            let (feedback, bare) = Self.parseClaudeFlags(raw)
            guard !feedback.isEmpty else {
                self?.usage(#"chat: add a message — e.g. #chat how's the pilot looking?"#)
                return []
            }
            self?.sendToClaude(feedback: feedback, bare: bare)
            return []
        }
        // chat(message) — talk to Claude through the client with NO game context attached (no transcript,
        // no raw capture) — for when you just want to converse, not file a task. Backs `#chat <message>`;
        // exactly `#claude --chat <message>`. The receiving session is told to reply, not spawn work.
        lua.register("chat") { [weak self] args in
            guard case .string(let raw)? = args.first,
                  !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
                self?.usage(#"chat: add a message — e.g. #chat how's the pilot looking?"#)
                return []
            }
            self?.sendToClaude(feedback: raw.trimmingCharacters(in: .whitespaces), bare: true)
            return []
        }
        // bell() — ring the terminal bell.
        lua.register("bell") { _ in Container.terminalService().bell(); return [] }
        // timestamps([on]) -> bool. Toggle (no arg) or set (bool / "on"/"off") the dim per-line arrival-
        // time gutter shown at the start of every scrollback line. Bound to ctrl-T by default. Returns the
        // new state so a bind can echo it.
        lua.register("timestamps") { args in
            let ts = Container.terminalService()
            let now: Bool
            switch args.first {
            case .bool(let b)?:   ts.setTimestamps(b); now = b
            case .string(let s)?: let b = (s == "on" || s == "true" || s == "1"); ts.setTimestamps(b); now = b
            default:              now = ts.toggleTimestamps()
            }
            return [.bool(now)]
        }
        // spellcheck(word) -> suggestion|nil. Native macOS spell-check (NSSpellChecker, local dictionary
        // — no network) of a SINGLE word: returns the top correction if the word is misspelled, else nil
        // (also nil for <2 chars). Fast enough to run per chat word. It only knows English — game jargon
        // must be filtered by the caller (ChatDecode keeps its own allowlist) before calling.
        lua.register("spellcheck") { args in
            guard case .string(let raw)? = args.first else { return [] }
            let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard word.count >= 2 else { return [] }
            let checker = NSSpellChecker.shared
            let misspelled = checker.checkSpelling(of: word, startingAt: 0)
            guard misspelled.location != NSNotFound, misspelled.length > 0 else { return [] }
            let full = NSRange(location: 0, length: (word as NSString).length)
            let guesses = checker.guesses(forWordRange: full, in: word,
                                          language: checker.language(), inSpellDocumentWithTag: 0)
            guard let first = guesses?.first, !first.isEmpty else { return [] }
            return [.string(first)]
        }
        // copy(n) — copy the last n scrollback lines (ANSI-stripped) to the macOS clipboard. n
        // defaults to 20; a non-positive count is a usage error. Echoes a confirmation with the number
        // of lines actually copied (fewer than n if the scrollback is shorter).
        lua.register("copy") { [weak self] args in
            guard let self else { return [] }
            let requested = args.first.flatMap(Self.intArg) ?? 20
            guard requested > 0 else {
                self.usage(#"copy: expected a positive line count — e.g. copy(20)"#)
                return []
            }
            let lines = Container.terminalService().scrollbackTail(count: requested)
            _ = Self.pasteboardWrite(lines.joined(separator: "\n"))
            self.onEcho("copied \(lines.count) line\(lines.count == 1 ? "" : "s")")
            return []
        }
        // __term_cols() -> the terminal width in columns (falls back to 80). Internal (`__`-prefixed):
        // it exists so the Lua help renderer can pack the catalog to the real width.
        lua.register("__term_cols") { _ in [.int(Int64(Container.terminalService().terminalColumns()))] }
    }

    /// The sink `copy(n)` writes the joined scrollback text to. Overridable in tests so the suite can
    /// point at a private NSPasteboard instead of clobbering the developer's real clipboard. Returns
    /// true on success. `nonisolated(unsafe)` because it's a deliberate test seam mutated only from a
    /// single test at a time.
    nonisolated(unsafe) static var pasteboardWrite: (String) -> Bool = { writeToPasteboard($0) }

    /// Put `text` on a pasteboard as a plain string (the general system pasteboard by default; a named
    /// pasteboard when `name` is given, which the tests use to avoid touching the real clipboard).
    @discardableResult
    static func writeToPasteboard(_ text: String, name: Any? = nil) -> Bool {
        #if canImport(AppKit)
        let pb: NSPasteboard = (name as? NSPasteboard.Name).map(NSPasteboard.init(name:)) ?? .general
        pb.clearContents()
        return pb.setString(text, forType: .string)
        #else
        return false
        #endif
    }

    /// The text-attribute vocabulary echo/panels understand → the SGR code each maps to. Broadly
    /// terminal-supported attributes, with generous aliases. This is the SINGLE source of truth for
    /// attribute words (the colours themselves come from `PanelHost.palette`); adding one here makes
    /// it resolvable everywhere the spec layer runs. Kept in sync with the discovery list in
    /// Scripts/bootstrap.lua (colors()/`#colors`).
    static let attributeCodes: [String: String] = [
        "bold": "1",
        "dim": "2", "faint": "2",
        "italic": "3", "italics": "3",
        "underline": "4", "underlined": "4",
        "blink": "5",
        "reversed": "7", "reverse": "7", "inverse": "7", "inverted": "7",
        "strikethrough": "9", "strike": "9", "strikethru": "9", "crossedout": "9",
    ]

    /// An advanced 256-colour escape hatch: a spec word of the form `colorN` (0-255) resolves to the
    /// SGR foreground select "38;5;N". Returns the code fragments, or nil if the word isn't a `colorN`.
    static func color256Codes(_ word: String) -> [String]? {
        guard word.hasPrefix("color"),
              let n = Int(word.dropFirst("color".count)), (0...255).contains(n) else { return nil }
        return ["38", "5", String(n)]
    }

    /// Parse an `echo` colour spec into SGR codes. A spec is space-separated words: at most one base
    /// colour (the 16-colour names from `PanelHost.palette` — the SAME table the panel/minimap layer
    /// uses, so the two surfaces can never disagree), `bright` to brighten it, any number of text
    /// attributes from `attributeCodes` (bold/dim/italic/underline/blink/reversed/strikethrough and
    /// their aliases), and the advanced `colorN` (256-colour) escape hatch. `bright` (as its own word)
    /// brightens the colour, so `"bright red"` and `"brightred"` are equivalent; a lone `bright` with
    /// no colour falls back to bold. Returns the SGR codes to apply and any words that resolved to
    /// nothing (so the caller can hint at `help(colors)`).
    static func sgrCodes(_ spec: String) -> (codes: [String], unknown: [String]) {
        var codes: [String] = []
        var colorIndex: Int?
        var bright = false
        var unknown: [String] = []
        for raw in spec.lowercased().split(separator: " ") {
            let word = String(raw)
            if word == "bright" {
                bright = true
            } else if let attr = Self.attributeCodes[word] {
                codes.append(attr)
            } else if let idx = PanelHost.palette[word] {
                colorIndex = idx
            } else if let c256 = Self.color256Codes(word) {
                codes.append(contentsOf: c256)
            } else {
                unknown.append(word)
            }
        }
        if var i = colorIndex {
            if bright, i < 8 { i += 8 }
            codes.append(String(i < 8 ? 30 + i : 90 + (i - 8)))
        } else if bright {
            codes.append("1")     // "bright" alone: nothing to brighten — bold is the nearest intent
        }
        return (codes, unknown)
    }

    /// Split a leading `--chat` / `--bare` / `-c` flag off a `#claude` argument. Returns the remaining
    /// message (trimmed) and whether context should be omitted (`bare`). The flag is only honored as the
    /// FIRST whitespace-delimited token, so a message that merely mentions "--chat" later is untouched.
    /// Static + pure so the flag parsing is unit-testable without the dispatch machinery.
    static func parseClaudeFlags(_ raw: String) -> (feedback: String, bare: Bool) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let bareFlags: Set<String> = ["--chat", "--bare", "-c"]
        // First token vs. the rest (split on the first run of whitespace).
        if let range = trimmed.rangeOfCharacter(from: .whitespaces) {
            let first = String(trimmed[trimmed.startIndex..<range.lowerBound]).lowercased()
            if bareFlags.contains(first) {
                let rest = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                return (rest, true)
            }
        } else if bareFlags.contains(trimmed.lowercased()) {
            // Flag with no message after it — bare, but empty (caller rejects it with usage).
            return ("", true)
        }
        return (trimmed, false)
    }

    /// Build a dispatch bundle for `feedback` and fire it at the channel server, echoing the outbound
    /// `↗ claude` line (bright-cyan reply comes back via the inbox). `bare` omits the game context — the
    /// shared body behind both `#claude` (optionally `--chat`) and the dedicated `#chat` command.
    private func sendToClaude(feedback: String, bare: Bool) {
        guard let bundle = DispatchBundle.build(feedback: feedback, bare: bare) else {
            onEcho("\u{1B}[31m↗ claude: couldn't build the context bundle\u{1B}[0m")
            return
        }
        let tag = bare ? "↗ claude (chat)" : "↗ claude"
        onRecordEcho("\(tag) \(feedback)")   // grep-able alongside the ↙ reply
        onEcho("\u{1B}[36m\(tag)\u{1B}[0m \(feedback)  \u{1B}[90m(\(bundle.dir.path))\u{1B}[0m")
        Self.dispatchToClaude(feedback: feedback, bundle: bundle) { [weak self] note in
            self?.onEcho(note)
        }
    }

    /// Fire the built context bundle at the local `muddispatch` channel server (see tools/dispatch/).
    /// Fire-and-forget over loopback HTTP; `note` is called (on the main queue) only to report a
    /// delivery problem, so a down/unlaunched server degrades to "bundle written, not delivered" rather
    /// than blocking or erroring the in-game command. Config via env: MUD_DISPATCH_PORT (8788),
    /// MUD_DISPATCH_TOKEN (else ~/Documents/MudClient/dispatch.token).
    private static func dispatchToClaude(feedback: String, bundle: (dir: URL, markdown: URL),
                                         note: @escaping (String) -> Void) {
        let port = ProcessInfo.processInfo.environment["MUD_DISPATCH_PORT"].flatMap(Int.init) ?? 8788
        guard let url = URL(string: "http://127.0.0.1:\(port)/dispatch") else { return }
        let token = dispatchToken()
        let body: [String: String] = [
            "feedback": feedback, "bundle": bundle.markdown.path, "dir": bundle.dir.path,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        if let token { req.setValue(token, forHTTPHeaderField: "x-dispatch-token") }
        req.httpBody = data
        req.timeoutInterval = 5
        func warn(_ why: String) {
            DispatchQueue.main.async {
                note("\u{1B}[33m↗ claude: not delivered (\(why)); bundle saved at \(bundle.dir.path). "
                    + "Is your session running `claude --dangerously-load-development-channels "
                    + "server:muddispatch`?\u{1B}[0m")
            }
        }
        URLSession.shared.dataTask(with: req) { _, response, error in
            if let error { warn(error.localizedDescription); return }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                warn("HTTP \(http.statusCode)")
            }
        }.resume()
    }

    /// The shared dispatch token: MUD_DISPATCH_TOKEN, else the file the channel server writes
    /// (~/Documents/MudClient/dispatch.token). nil if neither is present (server may be tokenless).
    private static func dispatchToken() -> String? {
        if let env = ProcessInfo.processInfo.environment["MUD_DISPATCH_TOKEN"], !env.isEmpty { return env }
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/MudClient/dispatch.token")
        guard let s = try? String(contentsOf: path, encoding: .utf8) else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// One-line usage/typo feedback for a builtin called with the wrong argument types (in yellow, so
    /// it can't be mistaken for game output). The alternative — silently doing nothing — turned out to
    /// be a footgun once `#…` became a REPL (`#echo(test, red)` passing two globals, for example).
    private func usage(_ message: String) {
        onEcho("\u{1B}[33m\(message)\u{1B}[0m")
    }

    // MARK: - REPL (`#…` input)

    /// Evaluate one line of `#`-prefixed REPL input (the `#` already stripped by the caller). The line
    /// is Lua run in the live script state; an expression's results are pretty-printed, a statement's
    /// aren't, and errors echo in red. Two conveniences preserve old habits during the command-language
    /// migration: an empty line means `help()`, and a bare `#word …` whose `word` names a callable
    /// global — a function or a `__call` table like `eq`/`kxwt`/`pilot` — (and whose remainder isn't a
    /// valid Lua expression) is rewritten to `word("…")` — so legacy typed commands like `#eq scan`,
    /// `#load {HUD}`, and `#reload` keep working.
    func evalREPL(_ raw: String) {
        lock.lock(); defer { lock.unlock() }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let chunk = trimmed.isEmpty ? "help()" : legacyRewrite(raw)
        switch lua.evalChunk(chunk) {
        case .values(let vals):
            if !vals.isEmpty { try? lua.callGlobal("__repl_print", vals) }
        case .compileError(let msg), .runtimeError(let msg):
            onEcho("\u{1B}[31m\(Self.cleanLuaError(msg))\u{1B}[0m")
        }
    }

    /// Rewrite legacy typed-command shapes into Lua calls, or return `raw` unchanged for real Lua.
    /// A bare `#word` naming a callable global (function or `__call` table) becomes `word()`; `#word
    /// rest` becomes `word("rest")` — but only when the whole line doesn't already parse as a Lua
    /// expression (so `#panel.height(2)`, `#foo(1, 2)`, or `#load("Scripts")` are left alone). The one
    /// special case is the old `#load {Name}` / `#load Name` habit: it names a single game script, so it
    /// maps to `load("Scripts/Name")` (the loader adds the `.lua`), matching the pre-loader behaviour.
    /// Must be called with the lock held.
    private func legacyRewrite(_ raw: String) -> String {
        let line = raw.trimmingCharacters(in: .whitespaces)
        // Split into leading identifier `word` and the remainder (after the first whitespace run).
        guard let m = try? Self.wordRest.wholeMatch(in: line) else { return raw }
        let word = String(m.1)
        let rest = m.2.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        // `#load {HUD}` / `#load HUD` — a bare/braced script name resolves under Scripts/, as before.
        // A parenthesised `#load(...)` is real Lua (the directory loader, `#load("Scripts")`) and is
        // left untouched — note `load {HUD}` itself compiles as `load({HUD})`, so we can't lean on the
        // generic "already valid Lua" guard here and must special-case the bare/braced shape first.
        if word == "load", !rest.isEmpty, !rest.hasPrefix("(") {
            var name = rest
            if name.hasPrefix("{"), name.hasSuffix("}"), name.count >= 2 {
                name = String(name.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            }
            return "load(\(Self.luaQuote("Scripts/\(name)")))"
        }
        guard lua.globalIsCallable(word) else { return raw }
        if rest.isEmpty { return "\(word)()" }
        // `word rest` — only rewrite if it isn't already a valid Lua expression on its own.
        if lua.compiles("return (\(line))") { return raw }
        return "\(word)(\(Self.luaQuote(rest)))"
    }

    /// `word` = a leading Lua identifier; optional group 2 = the rest of the line after whitespace.
    private static let wordRest = try! Regex<(Substring, Substring, Substring?)>(
        #"^([A-Za-z_][A-Za-z0-9_]*)(?:[ \t]+(.*))?$"#)

    /// Quote an arbitrary string as a Lua double-quoted literal (escaping `\`, `"`, and newlines).
    private static func luaQuote(_ s: String) -> String {
        var out = "\""
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            default: out.append(ch)
            }
        }
        return out + "\""
    }

    /// Strip the `repl:<line>: ` chunk-name prefix Lua prepends to compile/runtime errors, leaving just
    /// the message.
    private static func cleanLuaError(_ msg: String) -> String {
        (try? Regex(#"^repl:\d+:\s*"#)).map { msg.replacing($0, with: "") } ?? msg
    }

    // MARK: - Generic primitives (the LLM bridge + a timer)

    /// Capabilities Lua can't provide itself: an async model call and a one-shot timer. Both invoke
    /// a Lua callback later, via `fire`, under the lock. These are game-agnostic.
    private func installPrimitives() {
        // ai_request(system, user, max_tokens, tools_json, assistant_prefix, callback).
        //   tools_json: a JSON array of OpenAI tool definitions, or nil/"" for a plain completion.
        //   assistant_prefix: an optional trailing assistant-turn prefill (or nil/"" for none).
        //   callback(reply, tool_calls_json, err) — `err` is nil on success; on success `reply` is the
        //   model's text and `tool_calls_json` is a `[{name, arguments}]` JSON string (or nil).
        lua.register("ai_request") { [weak self] args in
            guard let self,
                  case .string(let system)? = args.first,
                  args.count > 5, case .function(let callback) = args[5] else { return [] }
            let user: String = { if case .string(let u) = args[1] { return u }; return "" }()
            let maxTokens = Self.intArg(args[2]) ?? 256
            let tools: String? = { if case .string(let t) = args[3], !t.isEmpty { return t }; return nil }()
            let prefix: String? = { if case .string(let p) = args[4], !p.isEmpty { return p }; return nil }()
            Task {
                do {
                    let result = try await self.llm.complete(system: system, user: user, maxTokens: maxTokens,
                                                             tools: tools, assistantPrefix: prefix)
                    self.fire(callback, [.string(result.content), result.toolCallsJSON.map(LuaValue.string) ?? .nil, .nil])
                } catch {
                    self.fire(callback, [.nil, .nil, .string(error.localizedDescription)])
                }
            }
            return []
        }
        // ai_local_request(system, user, max_tokens, prefix, callback [, model]). callback(reply, err) —
        // a plain completion against the LOCAL model client (never a paid API), for cheap always-on
        // features that must keep working regardless of what brain the pilot selected. No tools; prefix
        // is an optional assistant prefill (e.g. a closed <think> block for Qwen3.x). The optional 6th
        // `model` arg overrides the pinned local model for THIS call only (e.g. a bigger dense model for
        // gear comparison) without touching the client's configured default other callers rely on.
        lua.register("ai_local_request") { [weak self] args in
            guard let self,
                  case .string(let system)? = args.first,
                  args.count > 4, case .function(let callback) = args[4] else { return [] }
            let user: String = { if case .string(let u) = args[1] { return u }; return "" }()
            let maxTokens = Self.intArg(args[2]) ?? 64
            let prefix: String? = { if case .string(let p) = args[3], !p.isEmpty { return p }; return nil }()
            let modelOverride: String? = {
                if args.count > 5, case .string(let m) = args[5], !m.isEmpty { return m }; return nil
            }()
            Task {
                do {
                    let result = try await self.localLLM.complete(system: system, user: user,
                                                                  maxTokens: maxTokens, assistantPrefix: prefix,
                                                                  modelOverride: modelOverride)
                    self.fire(callback, [.string(result.content), .nil])
                } catch {
                    self.fire(callback, [.nil, .string(error.localizedDescription)])
                }
            }
            return []
        }
        // ai_local_tools_request(system, user, max_tokens, prefix, tools_json, callback [, model]).
        //   Like ai_local_request (LOCAL model, never a paid API) but with TOOLS and tool_choice "auto" —
        //   the model may answer directly OR request a tool call. tools_json is a JSON array of OpenAI tool
        //   definitions. callback(reply, tool_calls_json, err): on success `reply` is the text and
        //   `tool_calls_json` is a `[{name, arguments}]` string (or nil when the model answered directly).
        lua.register("ai_local_tools_request") { [weak self] args in
            guard let self,
                  case .string(let system)? = args.first,
                  args.count > 5, case .function(let callback) = args[5] else { return [] }
            let user: String = { if case .string(let u) = args[1] { return u }; return "" }()
            let maxTokens = Self.intArg(args[2]) ?? 128
            let prefix: String? = { if case .string(let p) = args[3], !p.isEmpty { return p }; return nil }()
            let tools: String? = { if case .string(let t) = args[4], !t.isEmpty { return t }; return nil }()
            let modelOverride: String? = {
                if args.count > 6, case .string(let m) = args[6], !m.isEmpty { return m }; return nil
            }()
            Task {
                do {
                    let result = try await self.localLLM.complete(system: system, user: user, maxTokens: maxTokens,
                                                                  tools: tools, toolChoice: "auto",
                                                                  assistantPrefix: prefix, modelOverride: modelOverride)
                    self.fire(callback, [.string(result.content), result.toolCallsJSON.map(LuaValue.string) ?? .nil, .nil])
                } catch {
                    self.fire(callback, [.nil, .nil, .string(error.localizedDescription)])
                }
            }
            return []
        }
        // ai_set_local_endpoint(url) / ai_set_local_model(id) — override the local client's target
        // (defaults to LM Studio at http://localhost:1234/v1). For pointing at ollama, a remote box, etc.
        lua.register("ai_set_local_endpoint") { [weak self] args in
            if case .string(let u)? = args.first { self?.localLLM.setEndpoint(u) }
            return []
        }
        lua.register("ai_set_local_model") { [weak self] args in
            if case .string(let m)? = args.first { self?.localLLM.setModel(m) }
            return []
        }
        // after(seconds, callback) -> id — fire callback() once, later. Returns a cancellable id.
        lua.register("after") { [weak self] args in
            guard let self else { return [] }
            guard args.count > 1, case .function(let callback) = args[1] else {
                self.usage(#"after: expected (seconds, callback) — e.g. after(2, function() echo("later") end)"#)
                return []
            }
            let seconds = Self.doubleArg(args[0]) ?? 0
            return [.int(Int64(self.scheduleTimer(delay: seconds, repeating: nil, callback)))]
        }
        // every(seconds, callback) -> id — fire callback() repeatedly, every `seconds`. Returns a
        // cancellable id.
        lua.register("every") { [weak self] args in
            guard let self else { return [] }
            guard args.count > 1, case .function(let callback) = args[1] else {
                self.usage(#"every: expected (seconds, callback) — e.g. every(60, function() send("save") end)"#)
                return []
            }
            let seconds = Self.doubleArg(args[0]) ?? 0
            return [.int(Int64(self.scheduleTimer(delay: seconds, repeating: seconds, callback)))]
        }
        // cancel(id) — cancel a pending/repeating timer started by after()/every().
        lua.register("cancel") { [weak self] args in
            guard let self, let id = args.first.flatMap(Self.intArg) else { return [] }
            self.lock.lock(); let item = self.timers.removeValue(forKey: id); self.lock.unlock()
            item?.cancel()
            return []
        }
        // lag_status() -> {ui_ms, ui_age_ms, net_ms, net_age_ms} — a latency snapshot separating a LOCAL
        // UI hitch (the terminal main-loop stalling) from SERVER round-trip (last command -> next
        // prompt). Ages are ms since the sample; -1 = never measured. Drives the HUD lag widget.
        lua.register("lag_status") { _ in
            let s = Container.lagMonitor().snapshot()
            return [.table([], [
                "ui_ms": .number(s.uiHitchMs), "ui_age_ms": .number(s.uiHitchAgeMs),
                "net_ms": .number(s.netRttMs), "net_age_ms": .number(s.netRttAgeMs),
            ])]
        }
        // ai_set_endpoint(url) / ai_set_model(id) — let a script implement runtime overrides.
        lua.register("ai_set_endpoint") { [weak self] args in
            if case .string(let u)? = args.first { self?.llm.setEndpoint(u) }
            return []
        }
        lua.register("ai_set_model") { [weak self] args in
            if case .string(let m)? = args.first { self?.llm.setModel(m) }
            return []
        }
        // ai_set_auth(on) — point the DECISION client at Anthropic (keychain key + native /v1/messages
        // for prompt caching), or back to the local model. Key stays in Swift.
        lua.register("ai_set_auth") { [weak self] args in
            let on: Bool = {
                if case .bool(let b)? = args.first { return b }
                if case .int(let i)? = args.first { return i != 0 }
                return false
            }()
            // Resolve lazily at request time (keychain read deferred until an actual API call).
            self?.llm.setAuthKeyProvider(on ? Container.anthropicAPIKeyProvider() : { nil })
            self?.llm.setAnthropic(on)
            return []
        }
        // ---- memory head (the second, separately-configured client) ----
        // ai_memory_request(system, user, max_tokens, callback). callback(reply, err) — a plain
        // completion (no tools, no prefill); used to maintain structured world state.
        lua.register("ai_memory_request") { [weak self] args in
            guard let self,
                  case .string(let system)? = args.first,
                  args.count > 3, case .function(let callback) = args[3] else { return [] }
            let user: String = { if case .string(let u) = args[1] { return u }; return "" }()
            let maxTokens = Self.intArg(args[2]) ?? 512
            Task {
                do {
                    let result = try await self.memLLM.complete(system: system, user: user, maxTokens: maxTokens)
                    self.fire(callback, [.string(result.content), .nil])
                } catch {
                    self.fire(callback, [.nil, .string(error.localizedDescription)])
                }
            }
            return []
        }
        lua.register("ai_set_memory_endpoint") { [weak self] args in
            if case .string(let u)? = args.first { self?.memLLM.setEndpoint(u) }
            return []
        }
        lua.register("ai_set_memory_model") { [weak self] args in
            if case .string(let m)? = args.first { self?.memLLM.setModel(m) }
            return []
        }
        lua.register("ai_set_memory_key") { [weak self] args in
            if case .string(let k)? = args.first { self?.memLLM.setAuthKey(k) }
            return []
        }
        // ---- RAG over the doc index ----
        lua.register("ai_rag_load") { [weak self] args in
            if case .string(let p)? = args.first { self?.rag.load(path: p) }
            return []
        }
        lua.register("ai_rag_count") { [weak self] _ in [.int(Int64(self?.rag.count ?? 0))] }
        // Token usage for cost reporting. ai_usage() = the decision brain, ai_mem_usage() = memory head.
        // Each returns (input, output, cache_read, cache_write).
        lua.register("ai_usage") { [weak self] _ in
            let (i, o, cr, cw) = self?.llm.usageCounts() ?? (0, 0, 0, 0)
            return [.int(Int64(i)), .int(Int64(o)), .int(Int64(cr)), .int(Int64(cw))]
        }
        lua.register("ai_mem_usage") { [weak self] _ in
            let (i, o, cr, cw) = self?.memLLM.usageCounts() ?? (0, 0, 0, 0)
            return [.int(Int64(i)), .int(Int64(o)), .int(Int64(cr)), .int(Int64(cw))]
        }
        lua.register("ai_usage_reset") { [weak self] _ in self?.llm.resetUsage(); self?.memLLM.resetUsage(); return [] }
        // ai_retrieve(query, k, callback). callback(chunks_json, err) — chunks_json is a JSON array
        // of the top-k most relevant doc passages (or nil on error).
        lua.register("ai_retrieve") { [weak self] args in
            guard let self,
                  case .string(let query)? = args.first,
                  args.count > 2, case .function(let callback) = args[2] else { return [] }
            let k = Self.intArg(args[1]) ?? 4
            Task {
                do {
                    let chunks = try await self.rag.retrieve(query: query, k: k)
                    let data = try JSONSerialization.data(withJSONObject: chunks)
                    self.fire(callback, [.string(String(data: data, encoding: .utf8) ?? "[]"), .nil])
                } catch {
                    self.fire(callback, [.nil, .string(error.localizedDescription)])
                }
            }
            return []
        }
    }

    private static func intArg(_ v: LuaValue) -> Int? {
        switch v { case .int(let i): return Int(i); case .number(let d): return Int(d); default: return nil }
    }
    /// Byte-exact extraction for an arg carrying raw data — a Lua string decodes to `.string` when it
    /// happens to be valid UTF-8 and `.bytes` otherwise (see `Lua.decodeString`); accept either so
    /// binary payloads (protobuf, arbitrary bytes) and plain text both work.
    private static func dataArg(_ v: LuaValue) -> Data? {
        switch v {
        case .string(let s): return Data(s.utf8)
        case .bytes(let d): return d
        default: return nil
        }
    }
    private static func doubleArg(_ v: LuaValue) -> Double? {
        switch v { case .number(let d): return d; case .int(let i): return Double(i); default: return nil }
    }
    private static func boolArg(_ v: LuaValue?) -> Bool {
        switch v { case .bool(let b)?: return b; case .int(let i)?: return i != 0; default: return false }
    }
    /// Parse a whitespace-separated hex-byte string ("90 4d 32") into MIDI bytes. Non-hex tokens are
    /// skipped rather than aborting the whole message (a stray token shouldn't drop a note).
    private static func midiBytes(_ hex: String) -> [UInt8] {
        hex.split(whereSeparator: { $0 == " " || $0 == "\t" }).compactMap { UInt8($0, radix: 16) }
    }
    /// A count that may arrive as a number OR a string (`#sent 10` legacy-rewrites to `sent("10")`).
    private static func countArg(_ v: LuaValue) -> Int? {
        switch v {
        case .int(let i): return Int(i)
        case .number(let d): return Int(d)
        case .string(let s): return Int(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    /// Render transcript entries as labeled display lines (sent = origin-tagged, received = dimmed).
    /// Static + pure so the labeling can be unit-tested without the echo sink.
    static func formatTranscript(_ entries: [TranscriptStore.Entry]) -> [String] {
        entries.map { e in
            switch (e.kind, e.origin) {
            case (.sent, .user):   return "\u{1B}[33m» you\u{1B}[0m \(e.text)"
            case (.sent, .script): return "\u{1B}[36m» lua\u{1B}[0m \(e.text)"
            case (.sent, nil):     return "\u{1B}[33m»\u{1B}[0m \(e.text)"
            case (.received, _):   return "\u{1B}[90m«\u{1B}[0m \(e.text)"
            case (.echo, _):       return "\u{1B}[35m‹\u{1B}[0m \(e.text)"
            }
        }
    }

    private func echoTranscript(_ entries: [TranscriptStore.Entry], header: String) {
        onEcho("\u{1B}[1m── \(header) (\(entries.count)) ──\u{1B}[0m")
        let lines = Self.formatTranscript(entries)
        if lines.isEmpty { onEcho("\u{1B}[90m  (nothing)\u{1B}[0m") }
        else { for line in lines { onEcho(line) } }
    }

    // MARK: - Timers

    /// Register a timer and arm it. `repeating` nil = one-shot; otherwise the re-arm interval.
    /// Returns the cancellable id.
    private func scheduleTimer(delay: Double, repeating: Double?, _ callback: LuaFunctionRef) -> Int {
        let id = nextId()
        arm(id: id, delay: delay, repeating: repeating, callback)
        return id
    }

    /// Schedule one firing of timer `id` on `timerQueue`. On fire it re-checks that the timer is still
    /// armed (not cancelled/reloaded) before calling into Lua, and re-arms itself when repeating.
    private func arm(id: Int, delay: Double, repeating: Double?, _ callback: LuaFunctionRef) {
        // Capture the DI container context at SCHEDULE time and re-apply it when the work item fires:
        // `timerQueue` is a GCD queue, which does NOT carry Swift task-local values, so the Lua callback
        // (which resolves services like terminalService via echo, or the LLM clients) would otherwise
        // run against whatever container is ambient on the queue. `withContainer` puts the right one back.
        let container = Container.current
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            withContainer(container) {
                self.lock.lock(); let armed = self.timers[id] != nil; self.lock.unlock()
                guard armed else { return }
                self.fire(callback, [])
                if let interval = repeating {
                    // fire() may have cancelled this timer; only re-arm if it's still live.
                    self.lock.lock(); let live = self.timers[id] != nil; self.lock.unlock()
                    if live { self.arm(id: id, delay: interval, repeating: interval, callback) }
                } else {
                    self.lock.lock(); self.timers[id] = nil; self.lock.unlock()
                }
            }
        }
        lock.lock(); timers[id] = item; lock.unlock()
        timerQueue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// `trigger(pattern, handler [, opts])` / `alias(pattern, handler [, opts])`. `opts` is an optional
    /// trailing table: `{ oneshot = true, class = "combat" }`.
    private func makeRule(_ args: [LuaValue]) -> Rule? {
        guard case .string(let pattern)? = args.first,
              args.count > 1, case .function(let handler) = args[1],
              let regex = try? Regex(pattern) else { return nil }
        var oneshot = false
        var ruleClass: String? = nil
        var priority = 0
        if args.count > 2, case .table(_, let opts) = args[2] {
            if case .bool(let b)? = opts["oneshot"] { oneshot = b }
            if case .string(let c)? = opts["class"] { ruleClass = c }
            if let p = opts["priority"], let n = Self.intArg(p) { priority = n }
        }
        return Rule(id: nextId(), regex: regex, patternSource: pattern, handler: handler, oneshot: oneshot,
                    ruleClass: ruleClass, priority: priority, specificity: Self.specificity(of: pattern))
    }

    /// Echo every registered line-trigger (id, pattern source, class/flags) in FIRING order — the list a
    /// bare `#trigger` prints under the syntax line. `lineRules` is already kept sorted by firing order.
    private func listLineRules() { listRules(lineRules, label: "trigger", kind: "line-trigger") }
    private func listAliasRules() { listRules(aliasRules, label: "alias", kind: "alias") }
    private func listGagRules() { listRules(gags, label: "gag", kind: "gag") }

    /// `untrigger` / `unalias` / `ungag <id | regex>` — remove rules of ONE kind. Bare number → by id;
    /// otherwise the arg is a regex matched against each rule's `patternSource`. Reports what was removed.
    private func unregister(_ args: [LuaValue], kind: String) {
        let needle = { () -> String in if case .string(let s)? = args.first { return s.trimmingCharacters(in: .whitespaces) }; return "" }()
        guard !needle.isEmpty else {
            self.usage("un\(kind): expected an id number or a regex — e.g. un\(kind) 7   or   un\(kind) ^dsleep$")
            return
        }
        let predicate: (Rule) -> Bool
        let matchDesc: String
        if let id = Int(needle) {
            predicate = { $0.id == id }; matchDesc = "#\(id)"
        } else if let rx = try? Regex(needle) {
            predicate = { (try? rx.firstMatch(in: $0.patternSource)) != nil }; matchDesc = "/\(needle)/"
        } else {
            self.usage("un\(kind): '\(needle)' isn't a number or a valid regex.")
            return
        }
        let removed: [Rule]
        switch kind {
        case "trigger": removed = lineRules.filter(predicate); lineRules.removeAll(where: predicate)
        case "alias":   removed = aliasRules.filter(predicate); aliasRules.removeAll(where: predicate)
        default:        removed = gags.filter(predicate); gags.removeAll(where: predicate)
        }
        if removed.isEmpty {
            onEcho("[\(kind)] nothing matched \(matchDesc).")
        } else {
            let list = removed.map { "#\($0.id) \($0.patternSource.isEmpty ? "<compiled regex>" : $0.patternSource)" }.joined(separator: ", ")
            onEcho("[\(kind)] removed \(removed.count): \(list)")
        }
    }

    /// Shared listing for the bare `#trigger` / `#alias` REPL forms. Sorted by id ascending (stable,
    /// == registration order) — the rules are STORED in ranksBefore (priority/specificity) order for
    /// dispatch, but a by-id list is what reads as "sorted" when you're eyeballing what's registered.
    private func listRules(_ rules: [Rule], label: String, kind: String) {
        let sorted = rules.sorted { $0.id < $1.id }
        onEcho("[\(label)] \(sorted.count) \(kind)\(sorted.count == 1 ? "" : "s") registered (by id):")
        for r in sorted {
            var line = "  #\(r.id)  \(r.patternSource.isEmpty ? "<compiled regex>" : r.patternSource)"
            var tags: [String] = []
            if let c = r.ruleClass { tags.append("class: \(c)") }
            if r.oneshot { tags.append("oneshot") }
            if !r.enabled { tags.append("disabled") }
            if !tags.isEmpty { line += "   [\(tags.joined(separator: ", "))]" }
            onEcho(line)
        }
    }
}
