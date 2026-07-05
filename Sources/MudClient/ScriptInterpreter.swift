//
//  ScriptInterpreter.swift
//  MudClient
//
//  Created by Tyler Thompson on 8/11/24.
//
//  Scripts are interpreted Lua (see Lua.swift / LuaScriptEngine.swift). The old
//  pipeline — shelling out to `swift build`, copying a .dylib, and dlopen'ing a
//  `createFactory` symbol — is gone; `#load {Name}` now reads `Scripts/Name.lua`.
//

import Afluent
import DependencyInjection
import Foundation

final class ScriptInterpreter {
    let engine = LuaScriptEngine()

    /// Scripts loaded via `#load {Name}`, in load order (deduped). `reload()` re-runs exactly this
    /// set, so any newly `#load`ed script is automatically picked up by future hot-reloads — there is
    /// no hardcoded script list to keep in sync. Mutated and read only on the input-processing task.
    private(set) var loadedScripts: [String] = []

    init() {
        engine.onSend = { message in try? Container.inputService().send(verbatim: message) }
        engine.onEcho = { message in Container.terminalService().print(message) }
        // All game-specific behavior (KXWT parsing, state, recovery, the AI pilot) now lives in
        // the Lua scripts (Scripts/AlterAeon.lua + Scripts/AIPilot.lua), not the Swift client.
    }

    /// Load (or re-load) a script by bare name and remember it so `reload()` includes it. The single
    /// entry point for `#load {Name}` and startup — keeping the tracked set and the on-disk load in
    /// one place.
    func loadScript(named scriptName: String) {
        let path = "Scripts/\(scriptName).lua"
        do {
            try engine.load(path: path)
            if !loadedScripts.contains(scriptName) { loadedScripts.append(scriptName) }
            Container.terminalService().print("Loaded script \(path)")
        } catch {
            Container.terminalService().print("Failed to load script \(path): \(error)")
        }
    }

    /// Re-run the game scripts live, clearing existing rules first so triggers/aliases aren't
    /// duplicated. This is how `#ai reload` applies edits without a relaunch.
    func reload() {
        engine.clearRules()
        for name in loadedScripts {
            let path = "Scripts/\(name).lua"
            do {
                try engine.load(path: path)
                Container.terminalService().print("[ai] reloaded \(path)")
            } catch {
                Container.terminalService().print("[ai] failed to reload \(path): \(error)")
            }
        }
    }
}

extension Container {
    static let scriptInterpreter = Factory(scope: .cached) { ScriptInterpreter() }
}

extension Character {
    static let scriptIndicator = Character("#")
    var isScriptIndicator: Bool {
        self == .scriptIndicator
    }
}

extension AsyncSequence where Self: Sendable, Element == String {
    func processScriptInput() -> AnyAsyncSequence<String> {
        compactMap { input -> String? in
            let interpreter = Container.scriptInterpreter()
            // Any leading `#` line is a REPL chunk: Lua evaluated in the live script state (with the
            // legacy-command rewrite covering old habits like `#load {X}`, `#reload`, `#ai …`, `#kxwt`).
            if input.first == Character.scriptIndicator {
                interpreter.engine.evalREPL(String(input.dropFirst()))
                return nil
            }
            // Let scripts observe the typed command without swallowing it (e.g. the AI pilot).
            interpreter.engine.notifyUserInput(input)
            // Otherwise let a script alias claim it.
            if interpreter.engine.processAlias(input) {
                return nil
            }
            return input
        }
        .eraseToAnyAsyncSequence()
    }

    func processServerOutputForScripts() -> AnyAsyncSequence<String> {
        map { output in
            let lines = output
                .replacingOccurrences(of: "\r", with: "")
                .components(separatedBy: CharacterSet.newlines)
            let engine = Container.scriptInterpreter().engine
            // Fire triggers (and gags) for every line, in order — scripts (incl. the AI pilot's
            // catch-all) observe here. Each line is passed through the rewrite stage: `processLine`
            // returns the line to display (possibly rewritten by a trigger), or nil if it was gagged.
            //
            // Keep every surviving line verbatim — including blanks, which are the MUD's own spacing.
            // (We used to drop blanks adjacent to a gagged kxwt_ batch as "framing", but that ate real
            // spacing between content during combat's group-status bursts, and isn't needed.)
            let out = lines.compactMap { engine.processLine($0) }
            return out.joined(separator: "\n")
        }
        .eraseToAnyAsyncSequence()
    }
}
