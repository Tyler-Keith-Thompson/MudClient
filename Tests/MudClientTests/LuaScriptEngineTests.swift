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

    // A MUD line arrives — the stored Lua handler fires and calls back into Swift. A handler that
    // returns nothing leaves the line unchanged, so processLine returns it verbatim.
    #expect(engine.processLine("A clay man is DEAD!") == "A clay man is DEAD!")
    #expect(sent == ["cry"])
    #expect(echoed == ["loaded", "killed: A clay man"])

    // Gag matches are dropped: processLine returns nil so the caller can suppress them.
    #expect(engine.processLine("kxwt_prompt 100 100") == nil)
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

    // A kxwt payload line is gagged (nil) and forwarded to the host parser.
    #expect(engine.processLine("kxwt_prompt 100 100 50 50 75 75") == nil)
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

// MARK: - Line rewrite stage

@Test func triggerReturnRewritesGagsOrLeavesLine() throws {
    let engine = LuaScriptEngine()
    try engine.load(source: #"""
        trigger("HELLO", function() return "GOODBYE" end)   -- string → replace
        trigger("SPAM",  function() return "" end)            -- "" → gag
        trigger("HIDE",  function() return false end)         -- false → gag
        trigger("KEEP",  function() end)                      -- no return → unchanged
    """#)
    #expect(engine.processLine("say HELLO there") == "GOODBYE")
    #expect(engine.processLine("SPAM SPAM SPAM") == nil)
    #expect(engine.processLine("please HIDE me") == nil)
    #expect(engine.processLine("KEEP this") == "KEEP this")
    #expect(engine.processLine("unmatched") == "unmatched")
}

@Test func triggersChainEachSeeingRewrittenLine() throws {
    let engine = LuaScriptEngine()
    var seen: [String] = []
    engine.onEcho = { _ in }
    try engine.load(source: #"""
        trigger("foo", function(line) return (line:gsub("foo", "bar")) end)
        trigger("bar", function(line) note(line); return (line:gsub("bar", "baz")) end)
    """#)
    engine.register("note") { args in
        if case .string(let s)? = args.first { seen.append(s) }
        return []
    }
    // Re-load so `note` exists before the trigger fires (registration after load is fine here since
    // the trigger only runs at processLine time).
    #expect(engine.processLine("foo") == "baz")   // foo→bar→baz through the chain
    #expect(seen == ["bar"])                        // the 2nd trigger saw the rewritten "bar"
}

@Test func triggerReceivesRawColouredLineAfterCaptures() throws {
    let engine = LuaScriptEngine()
    var rawSeen: String?
    engine.register("capture") { args in
        if case .string(let s)? = args.last { rawSeen = s }
        return []
    }
    try engine.load(source: #"""
        trigger("^([A-Za-z]+) hits", function(line, who, raw) capture(raw) end)
    """#)
    let coloured = "\u{1B}[31mGoblin\u{1B}[0m hits you"
    _ = engine.processLine(coloured)
    #expect(rawSeen == coloured)   // raw (still-coloured) original arrives after the captures
}

// MARK: - Rule lifecycle

@Test func rulesReturnIdsAndCanBeRemovedAndToggled() throws {
    let engine = LuaScriptEngine()
    var fired = 0
    engine.register("bump") { _ in fired += 1; return [] }
    try engine.load(source: #"""
        _id = trigger("^ping$", function() bump() end)
    """#)
    _ = engine.processLine("ping"); #expect(fired == 1)

    // Disable it → no longer matches.
    try engine.load(source: "rule_enable(_id, false)")
    _ = engine.processLine("ping"); #expect(fired == 1)

    // Re-enable → matches again.
    try engine.load(source: "rule_enable(_id, true)")
    _ = engine.processLine("ping"); #expect(fired == 2)

    // Remove → gone for good.
    try engine.load(source: "rule_remove(_id)")
    _ = engine.processLine("ping"); #expect(fired == 2)
}

@Test func oneshotTriggerAutoRemovesAfterFirstFire() throws {
    let engine = LuaScriptEngine()
    var fired = 0
    engine.register("bump") { _ in fired += 1; return [] }
    try engine.load(source: #"""
        trigger("^once$", function() bump() end, { oneshot = true })
    """#)
    _ = engine.processLine("once")
    _ = engine.processLine("once")
    #expect(fired == 1)
}

@Test func classEnableAndRemoveAffectTaggedRules() throws {
    let engine = LuaScriptEngine()
    var fired = 0
    engine.register("bump") { _ in fired += 1; return [] }
    try engine.load(source: #"""
        trigger("^hit$", function() bump() end, { class = "combat" })
        trigger("^hit$", function() bump() end, { class = "combat" })
    """#)
    _ = engine.processLine("hit"); #expect(fired == 2)

    try engine.load(source: #"class_enable("combat", false)"#)
    _ = engine.processLine("hit"); #expect(fired == 2)

    try engine.load(source: #"class_enable("combat", true)"#)
    _ = engine.processLine("hit"); #expect(fired == 4)

    try engine.load(source: #"class_remove("combat")"#)
    _ = engine.processLine("hit"); #expect(fired == 4)
}

// MARK: - Timers

@Test func afterFiresOnceAndEveryRepeatsUntilCancelled() async throws {
    let engine = LuaScriptEngine()
    var afterFired = 0
    var everyFired = 0
    engine.register("onAfter") { _ in afterFired += 1; return [] }
    engine.register("onEvery") { _ in everyFired += 1; return [] }
    try engine.load(source: #"""
        after(0.05, function() onAfter() end)
        _t = every(0.05, function() onEvery() end)
    """#)
    try await Task.sleep(nanoseconds: 180_000_000)  // ~3 intervals
    try engine.load(source: "cancel(_t)")
    let everyAtCancel = everyFired
    try await Task.sleep(nanoseconds: 150_000_000)

    #expect(afterFired == 1)                 // one-shot fired exactly once
    #expect(everyAtCancel >= 2)              // repeater fired several times
    #expect(everyFired == everyAtCancel)     // and stopped firing after cancel
}

@Test func reloadCancelsOutstandingTimers() async throws {
    let engine = LuaScriptEngine()
    var fired = 0
    engine.register("tick") { _ in fired += 1; return [] }
    try engine.load(source: #"""
        every(0.05, function() tick() end)
        after(0.05, function() tick() end)
    """#)
    engine.clearRules()                       // same path `#ai reload` uses
    try await Task.sleep(nanoseconds: 150_000_000)
    #expect(fired == 0)                        // no ghost timers fired into fresh state
}
