import Foundation
import Testing
#if canImport(AppKit)
import AppKit
#endif

@testable import MudClient

// MARK: - REPL (`#…` input)

@Test func replExpressionAutoPrints() throws {
    let engine = LuaScriptEngine()
    var echoed: [String] = []
    engine.onEcho = { echoed.append($0) }
    engine.evalREPL("1 + 1")               // an expression → its result is pretty-printed
    #expect(echoed == ["2"])
}

@Test func replStatementPrintsNothingButTakesEffect() throws {
    let engine = LuaScriptEngine()
    var echoed: [String] = []
    engine.onEcho = { echoed.append($0) }
    engine.evalREPL("repl_x = 41")         // a statement → no auto-print
    #expect(echoed.isEmpty)
    engine.evalREPL("repl_x + 1")          // …but it took effect in the live state
    #expect(echoed == ["42"])
}

@Test func replVoidCallPrintsNothing() throws {
    // A side-effecting call returns no values, so the REPL prints nothing (not `nil`).
    let engine = LuaScriptEngine()
    var echoed: [String] = []
    engine.onEcho = { echoed.append($0) }
    engine.register("noteVoid") { _ in [] }
    engine.evalREPL("noteVoid()")
    #expect(echoed.isEmpty)
}

@Test func replCompileErrorEchoesInRed() throws {
    let engine = LuaScriptEngine()
    var echoed: [String] = []
    engine.onEcho = { echoed.append($0) }
    engine.evalREPL("1 +")                 // neither a valid expression nor statement
    #expect(echoed.count == 1)
    #expect(echoed[0].contains("\u{1B}[31m"))          // red
    #expect(!echoed[0].contains("repl:"))              // chunk-name noise stripped
}

@Test func replLegacyWordRestRewritesToCall() throws {
    // `#word rest` where `word` is a global function and the rest isn't a Lua expression → word("rest").
    let engine = LuaScriptEngine()
    var got: [String] = []
    engine.register("recordArg") { args in
        if case .string(let s)? = args.first { got.append(s) }
        return []
    }
    // A global function named `eqcmd`; `#eqcmd scan gear` must call it with "scan gear".
    try engine.load(source: #"function eqcmd(a) recordArg(a) end"#)
    engine.evalREPL("eqcmd scan gear")
    #expect(got == ["scan gear"])
}

@Test func replBareFunctionWordIsCalled() throws {
    // A bare `#word` naming a global function calls it (preserving `#reload`/`#test`-style habits),
    // rather than auto-printing the function value.
    let engine = LuaScriptEngine()
    var fired = 0
    engine.register("bumpCounter") { _ in fired += 1; return [] }
    try engine.load(source: #"function doThing() bumpCounter() end"#)
    engine.evalREPL("doThing")
    #expect(fired == 1)
}

@Test func replRealExpressionCallIsNotRewritten() throws {
    // `#word(args)` is already valid Lua and must be left alone (not treated as legacy `word("(args)")`).
    let engine = LuaScriptEngine()
    var got: [String] = []
    engine.register("recordArg") { args in
        if case .string(let s)? = args.first { got.append(s) }
        return []
    }
    try engine.load(source: #"function callme(a) recordArg(a) end"#)
    engine.evalREPL(#"callme("direct")"#)
    #expect(got == ["direct"])                         // not "(\"direct\")"
}

@Test func replLoadBracedFormRewritesToLoadScript() throws {
    // `#load {Name}` must rewrite to load_script("{Name}") even though stdlib `load` is a function.
    let engine = LuaScriptEngine()
    var loaded: [String] = []
    // Shadow the load_script builtin with a recorder for this test.
    engine.register("load_script") { args in
        if case .string(let s)? = args.first { loaded.append(s) }
        return []
    }
    engine.evalREPL("load {HUD}")
    #expect(loaded == ["{HUD}"])
}

@Test func replBareReloadCallsReload() throws {
    let engine = LuaScriptEngine()
    var reloaded = 0
    engine.register("reload") { _ in reloaded += 1; return [] }
    engine.evalREPL("reload")
    #expect(reloaded == 1)
}

@Test func replEmptyInputShowsHelp() throws {
    // An empty `#` means help(); observe by shadowing the bootstrap's help with a recorder.
    let engine = LuaScriptEngine()
    var echoed: [String] = []
    engine.onEcho = { echoed.append($0) }
    try engine.load(source: #"function help(x) echo("HELP:" .. tostring(x)) end"#)
    engine.evalREPL("   ")                 // whitespace-only → help()
    #expect(echoed == ["HELP:nil"])
}

@Test func replCommandBridgeDefinesGlobalAndLegacyCallWorks() throws {
    // The `command` bridge (bootstrap Lua) defines a real global; the legacy `#name rest` shape then
    // routes through the REPL rewrite to that global.
    let engine = LuaScriptEngine()
    var got: [String] = []
    engine.register("recordArg") { args in
        if case .string(let s)? = args.first { got.append(s) }
        return []
    }
    try engine.load(source: #"command("kx", function(rest) recordArg(rest) end)"#)
    engine.evalREPL("kx dump 5")
    #expect(got == ["dump 5"])
}

// MARK: - echo colors & usage errors

@Test func echoResolvesBrightAndModifierColorSpecs() throws {
    let engine = LuaScriptEngine()
    var echoed: [String] = []
    engine.onEcho = { echoed.append($0) }

    try engine.load(source: #"echo("a", "red")"#)
    #expect(echoed.last == "\u{1B}[31ma\u{1B}[0m")

    try engine.load(source: #"echo("b", "bright red")"#)          // spaced spelling
    #expect(echoed.last == "\u{1B}[91mb\u{1B}[0m")

    try engine.load(source: #"echo("c", "brightred")"#)           // fused spelling — same result
    #expect(echoed.last == "\u{1B}[91mc\u{1B}[0m")

    try engine.load(source: #"echo("d", "bold red underline")"#)  // modifiers + color combine
    #expect(echoed.last == "\u{1B}[1;4;31md\u{1B}[0m")

    try engine.load(source: #"echo("e", "brightmagenta")"#)       // panel-layer name, same palette
    #expect(echoed.last == "\u{1B}[95me\u{1B}[0m")

    try engine.load(source: #"echo("f", "dim")"#)                 // modifier alone (old behaviour kept)
    #expect(echoed.last == "\u{1B}[2mf\u{1B}[0m")

    try engine.load(source: #"echo("g", "reversed")"#)
    #expect(echoed.last == "\u{1B}[7mg\u{1B}[0m")
}

@Test func echoResolvesTheFullAttributeVocabularyAnd256Color() throws {
    let engine = LuaScriptEngine()
    var echoed: [String] = []
    engine.onEcho = { echoed.append($0) }

    try engine.load(source: #"echo("a", "italic")"#)
    #expect(echoed.last == "\u{1B}[3ma\u{1B}[0m")

    try engine.load(source: #"echo("b", "blink")"#)
    #expect(echoed.last == "\u{1B}[5mb\u{1B}[0m")

    try engine.load(source: #"echo("c", "strikethrough")"#)
    #expect(echoed.last == "\u{1B}[9mc\u{1B}[0m")

    try engine.load(source: #"echo("d", "strike")"#)                // alias of strikethrough
    #expect(echoed.last == "\u{1B}[9md\u{1B}[0m")

    try engine.load(source: #"echo("e", "inverse")"#)              // alias of reversed
    #expect(echoed.last == "\u{1B}[7me\u{1B}[0m")

    try engine.load(source: #"echo("f", "color214")"#)            // 256-color escape hatch
    #expect(echoed.last == "\u{1B}[38;5;214mf\u{1B}[0m")

    try engine.load(source: #"echo("g", "bold color39 underline")"#)  // combines with attributes
    // Attributes and colorN are emitted in encounter order (only a NAMED base color is deferred to the end).
    #expect(echoed.last == "\u{1B}[1;38;5;39;4mg\u{1B}[0m")

    // colorN out of range (>255) is unknown, not a 256-color select.
    let (codes, unknown) = LuaScriptEngine.sgrCodes("color999")
    #expect(codes.isEmpty)
    #expect(unknown == ["color999"])
}

@Test func copyWritesJoinedScrollbackToClipboardAndConfirms() throws {
    // Route copy()'s clipboard write into a capture so the test never touches the real pasteboard,
    // then assert it echoes a "copied N lines" confirmation and wrote (the scrollback is empty in a
    // headless test, so N is 0 — the wiring, format, and pasteboard call are what's under test).
    let original = LuaScriptEngine.pasteboardWrite
    defer { LuaScriptEngine.pasteboardWrite = original }
    var captured: String?
    LuaScriptEngine.pasteboardWrite = { captured = $0; return true }

    let engine = LuaScriptEngine()
    var echoed: [String] = []
    engine.onEcho = { echoed.append($0) }
    engine.evalREPL("copy(5)")
    #expect(captured != nil)                                        // the pasteboard write happened
    #expect(echoed.contains { $0.hasPrefix("copied ") && $0.hasSuffix("lines") })
}

@Test func copyRejectsNonPositiveCount() throws {
    let engine = LuaScriptEngine()
    var echoed: [String] = []
    engine.onEcho = { echoed.append($0) }
    engine.evalREPL("copy(0)")
    #expect(echoed.contains { $0.contains("copy: expected a positive line count") })
    echoed.removeAll()
    engine.evalREPL("copy(-3)")
    #expect(echoed.contains { $0.contains("copy: expected a positive line count") })
}

@Test func writeToPasteboardRoundTripsThroughACustomPasteboard() throws {
    // NSPasteboard IS testable in the sandbox via a uniquely-named private pasteboard — it never
    // touches the developer's real clipboard.
    let name = NSPasteboard.Name("mudclient-copy-test-\(UUID().uuidString)")
    let pb = NSPasteboard(name: name)
    defer { pb.releaseGlobally() }
    #expect(LuaScriptEngine.writeToPasteboard("hello\nworld", name: name))
    #expect(pb.string(forType: .string) == "hello\nworld")
}

@Test func echoUnknownColorPrintsTextPlusHint() throws {
    let engine = LuaScriptEngine()
    var echoed: [String] = []
    engine.onEcho = { echoed.append($0) }
    try engine.load(source: #"echo("hello", "purple")"#)
    // The text still prints (plain), and a hint names the unknown word and points at help(colors).
    #expect(echoed.contains("hello"))
    #expect(echoed.contains { $0.contains("unknown color 'purple'") && $0.contains("help(colors)") })
}

@Test func echoWithUnquotedGlobalsCoercesInsteadOfSilence() throws {
    // The footgun: `#echo(test, red)` passes GLOBALS, not strings. `help` is documented, so it renders
    // as "function: help"; an entirely-nil text arg produces the quoting hint. Never a silent no-op.
    let engine = LuaScriptEngine()
    var echoed: [String] = []
    engine.onEcho = { echoed.append($0) }
    engine.evalREPL("echo(help, red)")                 // function + nil color
    #expect(echoed.contains { $0.contains("function: help") })
    echoed.removeAll()
    engine.evalREPL("echo(undefined_thing, red)")      // nil text → usage hint, not "nil"
    #expect(echoed.contains { $0.contains("did you mean quotes") })
    #expect(!echoed.contains("nil"))
}

@Test func sendWithNonStringIsUsageErrorNotASentLine() throws {
    let engine = LuaScriptEngine()
    var echoed: [String] = []
    var sent: [String] = []
    engine.onEcho = { echoed.append($0) }
    engine.onSend = { sent.append($0) }
    try engine.load(source: "send(nil) send(42) send(help)")
    #expect(sent.isEmpty)                              // nothing coerced onto the wire
    #expect(echoed.contains { $0.contains("send: expected a command string") })
}

@Test func triggerWithInvalidRegexReportsUsage() throws {
    let engine = LuaScriptEngine()
    var echoed: [String] = []
    engine.onEcho = { echoed.append($0) }
    try engine.load(source: #"trigger("([", function() end)"#)    // unbalanced — used to no-op silently
    #expect(echoed.contains { $0.contains("trigger: expected") })
}

@Test func colorsIsCallableAndDemosThePalette() throws {
    let engine = LuaScriptEngine()
    var echoed: [String] = []
    engine.onEcho = { echoed.append($0) }
    engine.evalREPL("colors")                          // bare word → callable table → colors()
    let out = echoed.joined(separator: "\n")
    #expect(out.contains("\u{1B}[91m  bright red\u{1B}[0m"))      // each name rendered in its own color
    #expect(out.contains("\u{1B}[34m  blue\u{1B}[0m"))
    #expect(out.contains("underline"))
}

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

@Test func onSendHookPassesReplacesAndSuppresses() throws {
    let engine = LuaScriptEngine()

    // No hook defined → command passes through unchanged.
    #expect(engine.filterOutbound("look") == ["look"])

    try engine.load(source: #"""
        function on_send(cmd)
            if cmd == "drop" then return false end         -- suppress
            if cmd == "n" then return "north" end          -- replace
            return nil                                      -- send unchanged
        end
    """#)

    #expect(engine.filterOutbound("look") == ["look"])   // nil → unchanged
    #expect(engine.filterOutbound("drop") == [])         // false → suppressed
    #expect(engine.filterOutbound("n") == ["north"])     // string → replacement
}

@Test func onSendHookInjectedSendsBypassTheHook() throws {
    // A hook that expands one command into several via send(), suppressing the original. The injected
    // sends must be transmitted (in order) but NOT re-consulted by on_send — no recursion — and they
    // must not leak to the normal `onSend` sink (they ride back in filterOutbound's return value).
    let engine = LuaScriptEngine()
    var sunk: [String] = []
    engine.onSend = { sunk.append($0) }

    try engine.load(source: #"""
        function on_send(cmd)
            if cmd == "combo" then
                send("one")
                send("two")
                return false
            end
            -- Every command reaches the hook, incl. the injected ones if the guard were broken:
            if cmd == "one" or cmd == "two" then send("RECURSED") end
            return nil
        end
    """#)

    #expect(engine.filterOutbound("combo") == ["one", "two"])
    #expect(sunk.isEmpty)   // injected sends returned to the caller, never routed through onSend
}

@Test func sessionLogWritesPlainTextAndAppends() throws {
    let path = NSTemporaryDirectory() + "mudclient-sessionlog-\(UUID().uuidString).log"
    defer { try? FileManager.default.removeItem(atPath: path) }
    let log = SessionLog()

    #expect(log.start(path: path, timestamps: false, ansi: false, commands: true))
    #expect(log.status().0 == true)
    #expect(log.status().1 == path)

    log.logServer("\u{1B}[37mhello\u{1B}[0m\nworld")   // ANSI stripped; two lines
    log.logCommand("north")                             // commands=true → recorded
    log.stop()
    #expect(log.status().0 == false)

    // A command sent while stopped is dropped; a fresh start appends rather than truncating.
    log.logCommand("ignored")
    #expect(log.start(path: path, timestamps: false, ansi: false, commands: false))
    log.logServer("again")
    log.logCommand("suppressed")                        // commands=false → not recorded
    log.stop()

    let written = try String(contentsOfFile: path, encoding: .utf8)
    #expect(written == "hello\nworld\nnorth\nagain\n")
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
