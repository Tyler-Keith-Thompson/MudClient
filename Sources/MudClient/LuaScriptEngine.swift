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

import Foundation

final class LuaScriptEngine: @unchecked Sendable {
    struct Rule {
        let regex: Regex<AnyRegexOutput>
        let handler: LuaFunctionRef
    }

    private let lua = Lua()
    private let lock = NSRecursiveLock()

    private(set) var lineRules: [Rule] = []
    private(set) var aliasRules: [Rule] = []
    private(set) var gags: [Regex<AnyRegexOutput>] = []

    /// Host sinks. The integration layer wires these to the real services.
    var onSend: (String) -> Void = { _ in }
    var onEcho: (String) -> Void = { _ in }
    var onKxwt: (String) -> Void = { _ in }

    init() {
        lua.errorHandler = { [weak self] msg in self?.onEcho(msg) }
        installBuiltins()
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

    // MARK: - Dispatch

    /// Fire any matching line triggers, then report whether the line should be gagged.
    func processLine(_ line: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        for rule in lineRules {
            guard let match = try? rule.regex.firstMatch(in: line) else { continue }
            try? lua.call(rule.handler, callArgs(line: line, match: match))
        }
        return gags.contains { (try? $0.firstMatch(in: line)) != nil }
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
        lua.register("kxwt") { [weak self] args in
            if case .string(let s)? = args.first { self?.onKxwt(s) }
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
    }

    /// `trigger(pattern, handler)` / `alias(pattern, handler)`.
    private func makeRule(_ args: [LuaValue]) -> Rule? {
        guard case .string(let pattern)? = args.first,
              args.count > 1, case .function(let handler) = args[1],
              let regex = try? Regex(pattern) else { return nil }
        return Rule(regex: regex, handler: handler)
    }
}
