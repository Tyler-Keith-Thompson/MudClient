//
//  ScriptInterpreter.swift
//  MudClient
//
//  Created by Tyler Thompson on 8/11/24.
//

import Afluent
import DependencyInjection
import Foundation
import Parsing
import ShellOut
import ScriptDescription

struct Trigger {
    let inputRegex: Regex<AnyRegexOutput>
    let response: String
}

final class ScriptInterpreter {
    typealias InitFunction = @convention(c) () -> UnsafeMutableRawPointer
    var scripts: [any ScriptDescription] = []
    
    lazy var echo = Parse {
        "echo "
        Rest().map { print($0) }
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
        Parse {
            parameter
        }
        .map { scriptFolder in
            do {
                print("Building ScriptDescription")
                try shellOut(to: "swift", arguments: ["build", "-c", "debug", "--product", "ScriptDescription"])
                print("Getting script: \(scriptFolder)")
                try shellOut(to: "swift", arguments: ["build"], at: "Scripts/\(scriptFolder)")
                let scriptPath = "Scripts/\(scriptFolder)/.build/debug/lib\(scriptFolder).dylib"
                try shellOut(to: "cp", arguments: [scriptPath, ".build/debug"])
                
                let pathToPlugin = ".build/debug/lib\(scriptFolder).dylib"
                let openRes = dlopen(pathToPlugin, RTLD_NOW|RTLD_LOCAL)
                if openRes != nil {
                    defer {
                        dlclose(openRes)
                    }
                    
                    let symbolName = "createFactory"
                    let sym = dlsym(openRes, symbolName)
                    
                    if sym != nil {
                        let f: InitFunction = unsafeBitCast(sym, to: InitFunction.self)
                        let pluginPointer = f()
                        let plugin = Unmanaged<ScriptFactory>.fromOpaque(pluginPointer).takeRetainedValue()
                        self.lock.lock()
                        self.scripts.append(plugin.getScript())
                        print("Loaded script \(scriptPath)")
                        self.lock.unlock()
                    } else {
                        print("Error loading \(pathToPlugin). \n\tSymbol \(symbolName) not found.")
                    }
                } else {
                    if let err = dlerror() {
                        let errMsg = String(format: "%s", err)
                        print("error opening lib:", errMsg)
                    } else {
                        print("error opening lib: unknown error")
                    }
                }
            } catch {
                print("Failed to get script: \(error)")
            }
        }
    }
    
    private let lock = NSRecursiveLock()
    
    var _triggers = [Trigger]()
    var triggers: [Trigger] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _triggers
        }
    }
    
    func addTrigger(_ trigger: Trigger) {
        lock.lock()
        defer { lock.unlock() }
        _triggers.append(trigger)
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
            let result = Result { try interpreter.parser.parse(input) }
            if case .success = result {
                return nil
            } else {
                for script in interpreter.scripts {
                    let context = _ScriptContext()
                    if try await script.processAlias(input: input, context: context) {
                        return nil
                    }
                }
                return input
            }
        }
        .eraseToAnyAsyncSequence()
    }
    
    func processServerOutputForScripts() -> AnyAsyncSequence<String> {
        map { output in
            let lines = output.replacingOccurrences(of: "\r", with: "").components(separatedBy: CharacterSet.newlines)
            let scripts = Container.scriptInterpreter().scripts
            var out = [String]()
            for line in lines {
                let context = _ScriptContext()
                for script in scripts where try await script.processLine(input: line, context: context) {
                    break
                }
                for script in scripts {
                    if !(try await script.transform(input: line, context: context)) {
                        out.append(line)
                    }
                }
            }
            return out.joined(separator: "\n")
        }
        .eraseToAnyAsyncSequence()
    }
}

struct _ScriptContext: Sendable, ScriptContext {
    func send(_ message: String) throws {
        try Container.inputService().send(verbatim: message)
    }
    
    func echo(_ message: String) {
        Container.terminalService().print(message)
    }
}
