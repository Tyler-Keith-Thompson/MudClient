//
//  Script.swift
//  MudClient
//
//  Created by Tyler Thompson on 8/25/24.
//

public struct Script: ScriptDescription {
    public func processLine(input: String, context: ScriptContext) async throws -> Bool {
        for script in body {
            if try await script.processLine(input: input, context: context) {
                return true
            }
        }
        return false
    }
    
    public func transform(input: String, context: ScriptContext) async throws -> Bool {
        for script in body {
            if try await script.transform(input: input, context: context) {
                return true
            }
        }
        return false
    }
    
    public func processAlias(input: String, context: any ScriptContext) async throws -> Bool {
        for script in body {
            if try await script.processAlias(input: input, context: context) {
                return true
            }
        }
        return false
    }
    
    @ScriptBuilder var body: [any ScriptDescription]
    public init(@ScriptBuilder body: () -> [any ScriptDescription]) {
        self.body = body()
    }
}
