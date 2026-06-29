import Foundation
import Testing

@testable import MudClient

@Test func luaTriggerCallsBackIntoHost() throws {
    let engine = LuaScriptEngine()
    var sent: [String] = []
    var echoed: [String] = []
    engine.onSend = { sent.append($0) }
    engine.onEcho = { echoed.append($0) }

    // A script: a host fn callable from Lua (echo), and a stored handler the host
    // calls back later (trigger), with a capture group passed through.
    try engine.load(source: #"""
        echo("loaded")
        trigger("^(.+) is DEAD!$", function(line, name)
            send("cry")
            echo("killed: " .. name)
        end)
        gag("^kxwt_")
    """#)

    #expect(echoed == ["loaded"])

    // A MUD line arrives — the stored Lua handler fires and calls back into Swift.
    let gagged = engine.processLine("A clay man is DEAD!")
    #expect(gagged == false)
    #expect(sent == ["cry"])
    #expect(echoed == ["loaded", "killed: A clay man"])

    // Gag matches are reported so the caller can suppress them.
    #expect(engine.processLine("kxwt_prompt 100 100") == true)
}

@Test func luaKxwtPatternDispatches() throws {
    // Mocks the AlterAeon kxwt wiring inline rather than loading the real Scripts/AlterAeon.lua,
    // which is game content that may change. This tests the engine's trigger/gag/host-forwarding
    // mechanics, independent of any one script's contents.
    let engine = LuaScriptEngine()
    var sent: [String] = []
    var kxwtPayloads: [String] = []
    engine.onSend = { sent.append($0) }
    engine.register("kxwt") { args in
        if case .string(let s)? = args.first { kxwtPayloads.append(s) }
        return []
    }

    try engine.load(source: #"""
        trigger("^kxwt_supported$", function() send("set kxwt") end)
        trigger("^kxwt_(.+)$", function(line, payload) kxwt(payload) end)
        gag("^kxwt_")
    """#)

    _ = engine.processLine("kxwt_supported")
    #expect(sent.contains("set kxwt"))

    // A kxwt payload line is gagged and forwarded to the host parser.
    #expect(engine.processLine("kxwt_prompt 100 100 50 50 75 75") == true)
    #expect(kxwtPayloads.contains("prompt 100 100 50 50 75 75"))
}

@Test func luaAliasSwallowsMatchingInput() throws {
    let engine = LuaScriptEngine()
    var sent: [String] = []
    engine.onSend = { sent.append($0) }

    try engine.load(source: #"""
        alias("^gold$", function() send("score gold") end)
    """#)

    #expect(engine.processAlias("gold") == true)
    #expect(engine.processAlias("look") == false)
    #expect(sent == ["score gold"])
}
