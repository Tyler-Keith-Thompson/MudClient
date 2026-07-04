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
    struct Rule {
        let regex: Regex<AnyRegexOutput>
        let handler: LuaFunctionRef
    }

    private let lua = Lua()
    private let lock = NSRecursiveLock()
    private let llm = LLMClient()
    /// A SECOND, independently-configured client for the "memory head" — a separate model (e.g. a
    /// hosted Claude via Anthropic's OpenAI-compatible endpoint) that maintains structured world
    /// state, leaving the local `llm` to make decisions. Configured by the script via ai_set_memory_*.
    private let memLLM = LLMClient()
    /// Retrieval over the prebuilt doc index — gives the decision model relevant game documentation
    /// on demand (see RAGRetriever / tools/finetune/build_rag_index.py).
    private let rag = RAGRetriever()
    private let timerQueue = DispatchQueue(label: "lua.timer")

    private(set) var lineRules: [Rule] = []
    private(set) var aliasRules: [Rule] = []
    private(set) var gags: [Regex<AnyRegexOutput>] = []
    /// Script-registered `#<name>` command handlers (via the `command` builtin). Called with the
    /// text after the command word. Lets game scripts own their own `#` commands host-agnostically.
    private(set) var commands: [String: LuaFunctionRef] = [:]

    /// Host sinks. The integration layer wires these to the real services.
    var onSend: (String) -> Void = { _ in }
    var onEcho: (String) -> Void = { _ in }

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
        commands.removeAll()
    }

    // MARK: - Dispatch

    /// Strips ANSI/VT control sequences (CSI — colours, cursor moves, etc.) so triggers and gags match
    /// the plain text a player sees, not the escape codes. Without this, a coloured line like
    /// "\u{1B}[37m\u{1B}[0m[Exits: west ]" fails a `^\[Exits:` trigger. Display output keeps its colour;
    /// only the copy used for matching is cleaned.
    private let ansiSequence = try! Regex("\u{1B}\\[[0-9;?]*[ -/]*[@-~]")

    /// Fire any matching line triggers, then report whether the line should be gagged. Triggers and
    /// gags see the ANSI-stripped line (and capture groups from it); the caller still displays the
    /// original, coloured line.
    func processLine(_ line: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let clean = line.replacing(ansiSequence, with: "")
        for rule in lineRules {
            guard let match = try? rule.regex.firstMatch(in: clean) else { continue }
            try? lua.call(rule.handler, callArgs(line: clean, match: match))
        }
        return gags.contains { (try? $0.firstMatch(in: clean)) != nil }
    }

    /// Fire the first matching alias for user input. Returns true if one matched
    /// (so the raw input is swallowed).
    func processAlias(_ input: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        for rule in aliasRules {
            guard let match = try? rule.regex.firstMatch(in: input) else { continue }
            try? lua.call(rule.handler, callArgs(line: input, match: match))
            return true
        }
        return false
    }

    /// Handler is called as `handler(wholeLine, capture1, capture2, ...)`.
    private func callArgs(line: String, match: Regex<AnyRegexOutput>.Match) -> [LuaValue] {
        let output = match.output
        var args: [LuaValue] = [.string(line)]
        if output.count > 1 {
            for i in 1..<output.count {
                args.append(output[i].substring.map { LuaValue.string(String($0)) } ?? .nil)
            }
        }
        return args
    }

    // MARK: - Builtins

    private func installBuiltins() {
        lua.register("send") { [weak self] args in
            if case .string(let s)? = args.first { self?.onSend(s) }
            return []
        }
        lua.register("echo") { [weak self] args in
            if case .string(let s)? = args.first { self?.onEcho(s) }
            return []
        }
        lua.register("trigger") { [weak self] args in
            if let rule = self?.makeRule(args) { self?.lineRules.append(rule) }
            return []
        }
        lua.register("alias") { [weak self] args in
            if let rule = self?.makeRule(args) { self?.aliasRules.append(rule) }
            return []
        }
        lua.register("gag") { [weak self] args in
            if case .string(let pat)? = args.first, let rx = try? Regex(pat) {
                self?.gags.append(rx)
            }
            return []
        }
        // command(name, handler) — register a `#<name>` command. The handler is called with the text
        // following the command word (e.g. `#kxwt dump 20` -> handler("dump 20")).
        lua.register("command") { [weak self] args in
            if case .string(let name)? = args.first, args.count > 1, case .function(let handler) = args[1] {
                self?.commands[name.lowercased()] = handler
            }
            return []
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

    /// Dispatch a `#<name> <rest>` command to a script-registered handler. Returns whether one claimed it.
    func dispatchCommand(_ name: String, _ rest: String) -> Bool {
        lock.lock(); let handler = commands[name.lowercased()]; lock.unlock()
        guard let handler else { return false }
        fire(handler, [.string(rest)])
        return true
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
        // after(seconds, callback) — fire callback() once, later.
        lua.register("after") { [weak self] args in
            guard let self,
                  args.count > 1, case .function(let callback) = args[1] else { return [] }
            let seconds = Self.doubleArg(args[0]) ?? 0
            self.timerQueue.asyncAfter(deadline: .now() + seconds) { [weak self] in
                self?.fire(callback, [])
            }
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

    /// `trigger(pattern, handler)` / `alias(pattern, handler)`.
    private func makeRule(_ args: [LuaValue]) -> Rule? {
        guard case .string(let pattern)? = args.first,
              args.count > 1, case .function(let handler) = args[1],
              let regex = try? Regex(pattern) else { return nil }
        return Rule(regex: regex, handler: handler)
    }
}
