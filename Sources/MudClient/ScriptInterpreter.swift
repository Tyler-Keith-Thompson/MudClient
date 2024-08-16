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

struct Trigger {
    let inputRegex: Regex<AnyRegexOutput>
    let response: String
}

final class ScriptInterpreter {
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
    
    lazy var trigger = Parse {
        "trigger "
        Parse {
            parameter
            Skip { Optionally { CharacterSet.whitespaces } }
            parameter
        }
        .map { triggerRegex, response in
            _ = Result { try Regex(String(triggerRegex)) }.map { regex in
                self.addTrigger(Trigger(inputRegex: regex, response: String(response)))
            }
        }
    }
    
    lazy var load = Parse {
        "load "
        Parse {
            parameter
        }
        .map { fileName in
            _ = Result { try String(contentsOf: URL(fileURLWithPath: fileName)) }.map { contents in
                do {
                    try contents.components(separatedBy: CharacterSet.newlines).forEach {
                        guard !$0.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                        try self.parser.parse($0.trimmingCharacters(in: .whitespaces))
                    }
                } catch {
                    print(error)
                }
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
                trigger
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
                return input
            }
        }
        .eraseToAnyAsyncSequence()
    }
    
    func processServerOutput() -> AnyAsyncSequence<String> {
        map { output in
            let lines = output.components(separatedBy: CharacterSet.newlines)
            let triggers = Container.scriptInterpreter().triggers
            try lines.forEach { line in
                try triggers.forEach { trigger in
                    if let _ = try? trigger.inputRegex.firstMatch(in: line) {
                        try Container.inputService().parse(input: trigger.response)
                    }
                }
            }
            return output
        }
        .eraseToAnyAsyncSequence()
    }
}
