//
//  ScriptContext.swift
//  MudClient
//
//  Created by Tyler Thompson on 9/1/24.
//

public protocol ScriptContext: Sendable {
    func send(_ message: String) throws
    func echo(_ message: String)
}
