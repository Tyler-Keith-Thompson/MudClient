//
//  ScriptFactory.swift
//  MudClient
//
//  Created by Tyler Thompson on 8/25/24.
//

open class ScriptFactory {
    public init() { }
    open func getScript() -> Script { Script { Noop() } }
}
