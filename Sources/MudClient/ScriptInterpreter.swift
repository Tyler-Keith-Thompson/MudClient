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
        engine.onKxwt = { line in Container.kxwtHost().handle(line) }
        // AlterAeon-specific builtins backed by the host KXWT state.
        engine.register("recover") { _ in Container.kxwtHost().toggleRecovery(); return [] }
        engine.register("dump_state") { _ in Container.kxwtHost().dumpState(); return [] }
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

    var parser: some Parser<Substring, Void> {
        Parse {
            String.scriptIndicator
            OneOf {
                echo
                load
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
            // A leading `#` command (e.g. `#load {AlterAeon}`) is consumed here.
            if (try? interpreter.parser.parse(input)) != nil {
                return nil
            }
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
            var out = [String]()
            for line in lines where !engine.processLine(line) {
                out.append(line)
            }
            return out.joined(separator: "\n")
        }
        .eraseToAnyAsyncSequence()
    }
}
