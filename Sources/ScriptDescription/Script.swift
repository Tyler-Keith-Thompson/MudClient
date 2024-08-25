//
//  Script.swift
//  MudClient
//
//  Created by Tyler Thompson on 8/25/24.
//

public struct Script: ScriptDescription {
    public func processLine(input: String) -> [Action] {
        body.flatMap { $0.processLine(input: input) }
    }
    
    public func transform(input: String) -> String {
        input
    }
    
    @ScriptBuilder var body: [any ScriptDescription]
    public init(@ScriptBuilder body: () -> [any ScriptDescription]) {
        self.body = body()
    }
    public enum Action {
        case send(String)
        case echo(String)
    }
}
