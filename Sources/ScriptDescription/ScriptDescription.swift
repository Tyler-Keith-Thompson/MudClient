//
//  ScriptDescription.swift
//  MudClient
//
//  Created by Tyler Thompson on 8/25/24.
//

public protocol ScriptDescription {
    func transform(input: String, context: ScriptContext) async throws -> Bool
    func processLine(input: String, context: ScriptContext) async throws -> Bool
    func processAlias(input: String, context: ScriptContext) async throws -> Bool
}

extension ScriptDescription {
    public func transform(input: String, context: ScriptContext) async throws -> Bool { false }
    public func processAlias(input: String, context: ScriptContext) async throws -> Bool { false }
    public func processLine(input: String, context: ScriptContext) async throws -> Bool { false }
}
