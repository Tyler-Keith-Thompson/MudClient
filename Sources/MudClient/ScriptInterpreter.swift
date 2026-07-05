//
//  ScriptInterpreter.swift
//  MudClient
//
//  Created by Tyler Thompson on 8/11/24.
//
//  Scripts are interpreted Lua (see Lua.swift / LuaScriptEngine.swift). The old
//  pipeline — shelling out to `swift build`, copying a .dylib, and dlopen'ing a
//  `createFactory` symbol — is gone. Scripts are loaded by the Lua `load(path)` loader
//  (Scripts/bootstrap.lua): `load("Scripts")` loads the directory; `reload()` re-runs it.
//

import Afluent
import DependencyInjection
import Foundation

final class ScriptInterpreter {
    let engine = LuaScriptEngine()

    init() {
        engine.onSend = { message in try? Container.inputService().send(verbatim: message) }
        engine.onEcho = { message in Container.terminalService().print(message) }
        // All game-specific behavior (KXWT parsing, state, recovery, the AI pilot) now lives in
        // the Lua scripts (Scripts/*.lua), not the Swift client. There is no hardcoded script list
        // here anymore: `loadScripts()` just runs the Lua `load("Scripts")` loader, which loads the
        // Scripts/ directory (see bootstrap.lua). `reload()` is likewise `load("Scripts")` again.
    }

    /// Load the whole Scripts/ directory via the Lua loader — the single entry point for startup.
    /// Resolving/ordering/exclusions all live in the pure-Lua `load` function (Scripts/bootstrap.lua);
    /// the connection is opened by AlterAeon.lua's own top-level `connect()` during this load, not here.
    func loadScripts() {
        do { try engine.load(source: #"load("Scripts")"#) }
        catch { Container.terminalService().print("Failed to load Scripts/: \(error)") }
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
