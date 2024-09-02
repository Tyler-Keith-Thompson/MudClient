//
//  Gag.swift
//  MudClient
//
//  Created by Tyler Thompson on 9/1/24.
//

public struct Gag<R: RegexComponent>: ScriptDescription {
    let regex: R
    public init(_ regex: R) {
        self.regex = regex
    }
    
    public func transform(input: String, context: any ScriptContext) async throws -> Bool {
        if let _ = try? regex.regex.firstMatch(in: input) {
            return true
        }
        return false
    }
}
