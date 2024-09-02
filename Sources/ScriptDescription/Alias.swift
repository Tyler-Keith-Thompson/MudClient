//
//  Alias.swift
//  MudClient
//
//  Created by Tyler Thompson on 9/1/24.
//

public struct Alias<R: RegexComponent>: ScriptDescription {
    let regex: R
    let onMatch: @Sendable (Regex<R.RegexOutput>.Match, ScriptContext) async throws -> Void
    public init(_ regex: R, onMatch: @Sendable @escaping (Regex<R.RegexOutput>.Match, ScriptContext) async throws -> Void) {
        self.regex = regex
        self.onMatch = onMatch
    }
    
    public func processAlias(input: String, context: ScriptContext) async throws -> Bool {
        if let match = try? regex.regex.firstMatch(in: input) {
            try await onMatch(match, context)
            return true
        }
        return false
    }
}
