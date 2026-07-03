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
import Parsing

final class ScriptInterpreter {
    let engine = LuaScriptEngine()

    init() {
        engine.onSend = { message in try? Container.inputService().send(verbatim: message) }
        engine.onEcho = { message in Container.terminalService().print(message) }
        // All game-specific behavior (KXWT parsing, state, recovery, the AI pilot) now lives in
        // the Lua scripts (Scripts/AlterAeon.lua + Scripts/AIPilot.lua), not the Swift client.
    }

    lazy var echo = Parse {
        "echo "
        Rest().map { Container.terminalService().print(String($0)) }
    }

    lazy var parameter = Parse {
        "{".utf8
        Many(into: "") { string, fragment in
            string.append(contentsOf: fragment)
        } element: {
            OneOf {
                Prefix(1) { $0 != .init(ascii: "}") && $0 != .init(ascii: "\\") }.map(.string)

                Parse {
                    "\\".utf8

                    OneOf {
                        "}".utf8.map { "}" }
                        Prefix(1).map(.string).map { "\\\($0)" }
                    }
                }
            }
        } terminator: {
            "}".utf8
        }
    }

    lazy var load = Parse {
        "load "
        parameter
    }
    .map { (scriptName: String) in
        let path = "Scripts/\(scriptName).lua"
        do {
            try Container.scriptInterpreter().engine.load(path: path)
            Container.terminalService().print("Loaded script \(path)")
        } catch {
            Container.terminalService().print("Failed to load script \(path): \(error)")
        }
    }

    /// `#ai ...` — control surface for the Lua AI pilot. `#ai reload` re-runs the scripts (host
    /// concern); everything else is forwarded to the script's `ai_command` global.
    lazy var ai = Parse {
        "ai"
        Optionally {
            " "
            Rest().map(String.init)
        }
    }
    .map { (arg: String?) in
        let a = (arg ?? "").trimmingCharacters(in: .whitespaces)
        if a.lowercased() == "reload" {
            Container.scriptInterpreter().reload()
        } else {
            Container.scriptInterpreter().engine.callGlobal("ai_command", a)
        }
    }

    var parser: some Parser<Substring, Void> {
        Parse {
            String.scriptIndicator
            OneOf {
                echo
                load
                ai
            }
        }
    }

    /// Re-run the game scripts live, clearing existing rules first so triggers/aliases aren't
    /// duplicated. This is how `#ai reload` applies edits without a relaunch.
    func reload() {
        engine.clearRules()
        for name in ["AlterAeon", "AIPilot", "HUD"] {
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

extension String {
    static let scriptIndicator = String(Character.scriptIndicator)
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
            // A leading `#` command the HOST owns (`#echo`, `#load`, `#ai`) is consumed here.
            if (try? interpreter.parser.parse(input)) != nil {
                return nil
            }
            // Any other `#<word> <rest>` is a script-defined command (registered via the Lua `command`
            // builtin). This keeps game-specific command names (e.g. `#kxwt`) out of the generic client.
            if input.first == Character.scriptIndicator {
                let body = input.dropFirst()
                let word = body.prefix { !$0.isWhitespace }
                let rest = body[word.endIndex...].drop { $0 == " " }
                if interpreter.engine.dispatchCommand(String(word), String(rest)) {
                    return nil
                }
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
            // catch-all) observe here. Record which lines were gagged for the blank-framing pass.
            let gagged = lines.map { engine.processLine($0) }

            // Keep every non-gagged line verbatim — including blanks, which are the MUD's own spacing.
            // (We used to drop blanks adjacent to a gagged kxwt_ batch as "framing", but that ate real
            // spacing between content during combat's group-status bursts, and isn't needed.)
            let out = lines.enumerated().filter { !gagged[$0.offset] }.map(\.element)
            return out.joined(separator: "\n")
        }
        .eraseToAnyAsyncSequence()
    }
}
