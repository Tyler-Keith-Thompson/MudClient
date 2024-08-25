//
//  ScriptDescription.swift
//  MudClient
//
//  Created by Tyler Thompson on 8/25/24.
//

public protocol ScriptDescription {
    func transform(input: String) -> String
    func processLine(input: String) -> [Script.Action]
}

extension ScriptDescription {
    public func transform(input: String) -> String { input }
}
