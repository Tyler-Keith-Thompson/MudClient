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

final class LuaScriptEngine: @unchecked Sendable {
    /// A registered line-trigger, alias, or gag. A reference type so `rule_enable`/`class_enable`
    /// can flip `enabled` in place. `handler` is nil for gags (they only decide whether a line is
    /// dropped); `oneshot` rules auto-remove after their first fire; `ruleClass` tags a rule so a
    /// whole class can be enabled/removed at once.
    final class Rule {
        let id: Int
        let regex: Regex<AnyRegexOutput>
        let handler: LuaFunctionRef?
        let oneshot: Bool
        let ruleClass: String?
        var enabled: Bool = true
        init(id: Int, regex: Regex<AnyRegexOutput>, handler: LuaFunctionRef?,
             oneshot: Bool = false, ruleClass: String? = nil) {
            self.id = id
            self.regex = regex
            self.handler = handler
            self.oneshot = oneshot
            self.ruleClass = ruleClass
        }
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

    /// Host sinks. The integration layer wires these to the real services.
    var onSend: (String) -> Void = { _ in }
    var onEcho: (String) -> Void = { _ in }

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

    /// The socket went down. No-op unless the script defines `on_disconnect(reason)`.
    func notifyDisconnect(reason: String) {
        lock.lock(); defer { lock.unlock() }
        try? lua.callGlobal("on_disconnect", [.string(reason)])
    }

    /// A GO-AHEAD prompt boundary flushed `text`. No-op unless the script defines `on_prompt(text)`.
    func notifyPrompt(_ text: String) {
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
    /// Disabled rules are skipped; `oneshot` rules are removed after they fire.
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
            if gagged { break }
        }
        if !firedOneshots.isEmpty { lineRules.removeAll { firedOneshots.contains($0.id) } }
        if gagged { return nil }
        // The standalone gag list still applies to whatever the line now is.
        let clean = current.replacing(ansiSequence, with: "")
        if gags.contains(where: { $0.enabled && (try? $0.regex.firstMatch(in: clean)) != nil }) { return nil }
        return current
    }

    /// Fire the first matching alias for user input. Returns true if one matched
    /// (so the raw input is swallowed).
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
            guard let self, case .string(let s)? = args.first else { return [] }
            // A send() issued from within on_send is diverted (see `hookSends`), so it reaches the MUD
            // directly without being fed back through the hook. Every other send takes the normal sink.
            if self.hookSends != nil { self.hookSends?.append(s) } else { self.onSend(s) }
            return []
        }
        // echo(text) — print a line unchanged. echo(text, color) — wrap it in an ANSI colour from a
        // small named set (red/green/yellow/blue/magenta/cyan/white/dim) before printing; an unknown
        // colour is ignored (prints plain).
        lua.register("echo") { [weak self] args in
            guard case .string(let s)? = args.first else { return [] }
            if args.count > 1, case .string(let color) = args[1], let code = Self.ansiColorCode(color) {
                self?.onEcho("\u{1B}[\(code)m\(s)\u{1B}[0m")
            } else {
                self?.onEcho(s)
            }
            return []
        }
        // trigger(pattern, handler [, opts]) -> id. opts = { oneshot = true, class = "combat" }.
        lua.register("trigger") { [weak self] args in
            guard let self, let rule = self.makeRule(args) else { return [] }
            self.lineRules.append(rule)
            return [.int(Int64(rule.id))]
        }
        // alias(pattern, handler [, opts]) -> id. Same options as trigger().
        lua.register("alias") { [weak self] args in
            guard let self, let rule = self.makeRule(args) else { return [] }
            self.aliasRules.append(rule)
            return [.int(Int64(rule.id))]
        }
        // gag(pattern) -> id. Drops matching lines; removable/toggleable by id like any rule.
        lua.register("gag") { [weak self] args in
            guard let self, case .string(let pat)? = args.first, let rx = try? Regex(pat) else { return [] }
            let rule = Rule(id: self.nextId(), regex: rx, handler: nil)
            self.gags.append(rule)
            return [.int(Int64(rule.id))]
        }
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
        // load_script(name) — load (or hot-reload) Scripts/<name>.lua and remember it so reload()
        // re-runs it. Tolerates the legacy braced form (`{Name}`) the REPL rewrites `#load {Name}` to.
        lua.register("load_script") { args in
            guard case .string(let raw)? = args.first else { return [] }
            var name = raw.trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("{"), name.hasSuffix("}"), name.count >= 2 {
                name = String(name.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            }
            Container.scriptInterpreter().loadScript(named: name)
            return []
        }
        // reload() — re-run every loaded script live (clears rules first). Same as the old `#reload`.
        lua.register("reload") { _ in
            Container.scriptInterpreter().reload()
            return []
        }
        // ---- Connection lifecycle control (host-generic; the default startup connection is unchanged) ----
        // connect(host, port) — open (or re-open) the connection. `port` defaults to 23 if omitted.
        lua.register("connect") { args in
            guard case .string(let host)? = args.first else { return [] }
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
        lua.register("telnet_send") { args in
            guard let option = args.first.flatMap(Self.intArg), option >= 0, option <= 255 else { return [] }
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
        installLogReplay()
    }

    // MARK: - Session logging & log replay (TinTin++ #log / #textin)

    private func installLogReplay() {
        // log_start(path, opts?) -> bool. opts = { timestamps=bool, ansi=bool, commands=bool }. Writes
        // each displayed server line (and, with commands=true, each sent command) as plain text; ansi
        // defaults false (escapes stripped), timestamps defaults false. Appends if the file exists.
        lua.register("log_start") { args in
            guard case .string(let path)? = args.first else { return [.bool(false)] }
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
            guard let self, case .string(let path)? = args.first else { return [.bool(false)] }
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
        lua.register("music_play") { args in
            if case .string(let ch)? = args.first, args.count > 1, case .string(let track) = args[1] {
                Container.musicService().play(channel: ch, track: track)
            }
            return []
        }
        lua.register("music_stop") { args in
            if case .string(let ch)? = args.first { Container.musicService().stop(channel: ch) }
            return []
        }
        // music.volume(pct) — set the master volume for all channels from a 0-100 percentage.
        lua.register("music_volume") { args in
            if let pct = args.first.flatMap(Self.doubleArg) { Container.musicService().setVolume(percent: pct) }
            return []
        }
        try? lua.run("music = { play = music_play, stop = music_stop, volume = music_volume }")
    }

    /// Terminal/input capabilities (TinTin++-style): key macros, input-line access, scrollback reads,
    /// and small output niceties. All delegate to the screen owner (TerminalService); none are
    /// game-specific.
    private func installTerminal() {
        // bind(keyname, handler) -> id. Registers a key macro; the handler is called with the key
        // name when that key is pressed (and the key is then consumed, not line-edited).
        lua.register("bind") { [weak self] args in
            guard let self, case .string(let key)? = args.first,
                  args.count > 1, case .function(let handler) = args[1] else { return [.nil] }
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
        lua.register("input_set") { args in
            if case .string(let t)? = args.first { Container.terminalService().setInput(t) }
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
        // bell() — ring the terminal bell.
        lua.register("bell") { _ in Container.terminalService().bell(); return [] }
    }

    /// Map a named colour to its ANSI SGR code. Small fixed set; unknown names return nil.
    private static func ansiColorCode(_ name: String) -> String? {
        switch name.lowercased() {
        case "red": return "31"
        case "green": return "32"
        case "yellow": return "33"
        case "blue": return "34"
        case "magenta": return "35"
        case "cyan": return "36"
        case "white": return "37"
        case "dim": return "2"
        default: return nil
        }
    }

    // MARK: - REPL (`#…` input)

    /// Evaluate one line of `#`-prefixed REPL input (the `#` already stripped by the caller). The line
    /// is Lua run in the live script state; an expression's results are pretty-printed, a statement's
    /// aren't, and errors echo in red. Two conveniences preserve old habits during the command-language
    /// migration: an empty line means `help()`, and a bare `#word …` whose `word` names a global
    /// function (and whose remainder isn't a valid Lua expression) is rewritten to `word("…")` — so
    /// legacy typed commands like `#eq scan`, `#load {HUD}`, and `#reload` keep working.
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
    /// `#reload` / `#load X` map to the `reload()` / `load_script("X")` builtins; a bare `#word` naming
    /// a global function becomes `word()`; `#word rest` becomes `word("rest")` — but only when the whole
    /// line doesn't already parse as a Lua expression (so `#panel.height(2)` or `#foo(1, 2)` are left
    /// alone). Must be called with the lock held.
    private func legacyRewrite(_ raw: String) -> String {
        let line = raw.trimmingCharacters(in: .whitespaces)
        // Split into leading identifier `word` and the remainder (after the first whitespace run).
        guard let m = try? Self.wordRest.wholeMatch(in: line) else { return raw }
        let word = String(m.1)
        let rest = m.2.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        // Host command words first (stdlib `load` would otherwise shadow the `#load {X}` habit).
        if word == "reload" { return "reload()" }
        if word == "load", !rest.isEmpty { return "load_script(\(Self.luaQuote(rest)))" }
        guard lua.globalIsFunction(word) else { return raw }
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
            guard let self,
                  args.count > 1, case .function(let callback) = args[1] else { return [] }
            let seconds = Self.doubleArg(args[0]) ?? 0
            return [.int(Int64(self.scheduleTimer(delay: seconds, repeating: nil, callback)))]
        }
        // every(seconds, callback) -> id — fire callback() repeatedly, every `seconds`. Returns a
        // cancellable id.
        lua.register("every") { [weak self] args in
            guard let self,
                  args.count > 1, case .function(let callback) = args[1] else { return [] }
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
    private static func doubleArg(_ v: LuaValue) -> Double? {
        switch v { case .number(let d): return d; case .int(let i): return Double(i); default: return nil }
    }
    private static func boolArg(_ v: LuaValue?) -> Bool {
        switch v { case .bool(let b)?: return b; case .int(let i)?: return i != 0; default: return false }
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
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
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
        if args.count > 2, case .table(_, let opts) = args[2] {
            if case .bool(let b)? = opts["oneshot"] { oneshot = b }
            if case .string(let c)? = opts["class"] { ruleClass = c }
        }
        return Rule(id: nextId(), regex: regex, handler: handler, oneshot: oneshot, ruleClass: ruleClass)
    }
}
