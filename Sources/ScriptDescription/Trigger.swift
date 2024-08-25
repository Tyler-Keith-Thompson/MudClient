//
//  Trigger.swift
//  MudClient
//
//  Created by Tyler Thompson on 8/25/24.
//

public struct Trigger<R: RegexComponent>: ScriptDescription {
    let regex: R
    let onMatch: (Regex<R.RegexOutput>.Match) -> [Script.Action]
    public init(_ regex: R, onMatch: @escaping (Regex<R.RegexOutput>.Match) -> [Script.Action]) {
        self.regex = regex
        self.onMatch = onMatch
    }
    
    public func processLine(input: String) -> [Script.Action] {
        if let match = try? regex.regex.firstMatch(in: input) {
            return onMatch(match)
        }
        return []
    }
}
