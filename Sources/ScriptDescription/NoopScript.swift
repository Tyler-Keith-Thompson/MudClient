//
//  NoopScript.swift
//  MudClient
//
//  Created by Tyler Thompson on 8/25/24.
//

public struct Noop: ScriptDescription {
    public init() { }
    public func processLine(input: String) -> [Script.Action] { [] }
}
