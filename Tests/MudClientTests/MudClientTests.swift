import DependencyInjection
import Foundation
import Parsing
import Testing

@testable import MudClient

private actor RecordedWrites {
    var all: [Data] = []
    func add(_ data: Data) { all.append(data) }
}

@Test func iacNegotiationSplitAcrossChunks() async throws {
    // A telnet "IAC WILL MSP" (255, 251, 90) negotiation, deliberately split so the option byte
    // lands in the *next* Data chunk — exactly the case the old per-chunk parser mishandled.
    let chunks: [Data] = [
        Data("Hi".utf8) + Data([255, 251]),  // text, then IAC WILL — option byte missing
        Data([90]) + Data("Bye".utf8),  // MSP option byte arrives here, then more text
    ]
    let stream = AsyncStream<Data> { continuation in
        for chunk in chunks { continuation.yield(chunk) }
        continuation.finish()
    }

    let writes = RecordedWrites()
    var output = ""
    for try await piece in stream.handleIACCommunication(writeToStream: { await writes.add($0) }) {
        output += piece
    }

    // The 3-byte negotiation is consumed across the boundary and stripped from the visible text.
    #expect(output == "HiBye")
    // And we answered it correctly with IAC DO MSP (255, 253, 90).
    let written = await writes.all
    #expect(written == [Data([255, 253, 90])])
}

@Test func iacStreamTokenParserClassifiesText() throws {
    // A plain character is a passthrough token; the parser is the single-token unit the streaming
    // driver repeats.
    var input = Substring("x")
    let token = try IAC.streamTokenParser().parse(&input)
    guard case .passthrough(let text) = token else {
        Issue.record("expected passthrough, got \(token)")
        return
    }
    #expect(text == "x")
}

@Test func mspDirectiveSplitAcrossChunks() throws {
    // An `!!SOUND(...)` directive split across two reads must still be recognized as one directive
    // and stripped from the visible output.
    let buffer = MSPLineBuffer()
    let first = buffer.process("!!SOUND(cow.wav V=100 L=1")
    // Incomplete directive: held back, nothing shown, nothing fired yet.
    #expect(first.output.isEmpty)
    #expect(first.directives.isEmpty)

    let second = buffer.process(")\n")
    // Completed by the newline: recognized as a directive, still nothing shown.
    #expect(second.output.isEmpty)
    #expect(second.directives.count == 1)
}

@Test func mspPassesThroughOrdinaryTextAndPrompts() throws {
    let buffer = MSPLineBuffer()
    // A complete line flows straight through.
    #expect(buffer.process("You see a cow.\n").output == "You see a cow.\n")
    // A prompt with no trailing newline is shown immediately, not held back.
    #expect(buffer.process("HP:100 >").output == "HP:100 >")
    // Text split mid-line is emitted incrementally without duplication.
    let a = buffer.process(" attack")
    let b = buffer.process(" cow\n")
    #expect(a.output == " attack")
    #expect(b.output == " cow\n")
}

@Test func mspMalformedDirectiveIsNotHeldForever() throws {
    // A line that looks like a directive but never closes must be released (shown) once its line
    // ends, rather than swallowing all subsequent output.
    let buffer = MSPLineBuffer()
    #expect(buffer.process("!!SOUND(broken").output.isEmpty)  // held while it could still complete
    let released = buffer.process(" no close\n")
    #expect(released.output == "!!SOUND(broken no close\n")
    #expect(released.directives.isEmpty)
}

@Test func mspDirectiveWithoutTrailingNewlineIsStrippedNotLeaked() throws {
    // Regression: a complete directive that arrives without a trailing newline, followed by a
    // prompt in a *separate* chunk, must be acted on immediately. Otherwise the prompt would be
    // appended to the same buffered line, the combined line would fail to parse as a directive, and
    // the directive text would leak to the display.
    let directive = "!!SOUND(Off U=http://www.alteraeon.com/soundpack/wav_v1/ X=2.0)"
    let buffer = MSPLineBuffer()
    let first = buffer.process(directive)
    #expect(first.directives.count == 1)  // recognized eagerly, before the prompt arrives
    #expect(first.output.isEmpty)
    let second = buffer.process("> ")
    #expect(second.directives.isEmpty)
    #expect(second.output == "> ")  // the prompt still flows to the display
}

@Test func mspRealDirectiveNewlineTerminated() throws {
    let buffer = MSPLineBuffer()
    let result = buffer.process(
        "!!SOUND(Off U=http://www.alteraeon.com/soundpack/wav_v1/ X=2.0)\n"
    )
    #expect(result.directives.count == 1)
    #expect(result.output.isEmpty)
}

@Test func mspCRLFDirectiveIsStripped() throws {
    // Regression for THE real-world bug: AlterAeon ends lines with CRLF, which Swift treats as
    // a single grapheme cluster — line splitting on "\n" silently failed and every directive leaked.
    let buffer = MSPLineBuffer()
    let r = buffer.process("!!SOUND(move/building4.wav)\r\nAn intersection\r\n")
    #expect(r.directives.count == 1)
    #expect(!r.output.contains("!!SOUND"))
    #expect(r.output.contains("An intersection"))
}

@Test func mspLoginCaptureSequenceIsStripped() throws {
    // The exact shape from a raw capture: a no-newline char prompt, then the base-URL directive
    // arriving "\r\n"-prefixed and terminated by IAC GA (so no trailing newline).
    let buffer = MSPLineBuffer()
    _ = buffer.process("Would you like to create a new character?   ")
    let r = buffer.process("\r\n!!SOUND(Off U=http://www.alteraeon.com/soundpack/wav_v1/ X=2.0)")
    #expect(r.directives.count == 1)
    #expect(!r.output.contains("!!SOUND"))
}

@Test func mspParamlessSoundDirectiveIsStripped() throws {
    let buffer = MSPLineBuffer()
    let r = buffer.process("!!SOUND(move/building4.wav)\r\n")
    #expect(r.directives.count == 1)
    #expect(r.output.isEmpty)
}

@Test func replayCapturedRawLog() async throws {
  try await withSilentAudio {
    // Debug tool: replay a MUD_RAW_LOG capture through the real IAC + MSP path.
    // Run with: bazel test ... --test_filter=replayCapturedRawLog --test_env=REPLAY_FILE=/path
    guard let path = ProcessInfo.processInfo.environment["REPLAY_FILE"],
          let content = try? String(contentsOfFile: path, encoding: .utf8) else {
        print("REPLAY: set REPLAY_FILE to a capture to run this"); return
    }
    let chunks = content.split(separator: "\n").compactMap { Data(base64Encoded: String($0)) }
    let stream = AsyncStream<Data> { c in for ch in chunks { c.yield(ch) }; c.finish() }
    // Mirror the REAL display pipeline end to end.
    var terminal = ""
    for try await text in stream.handleIACCommunication(writeToStream: { _ in })
        .normalizeLineEndings().assembleLines().processMSP() {
        terminal += text
    }
    // Apply the AlterAeon gag the way the display consumer does, then hunt for leaked protocol tails.
    let engine = LuaScriptEngine()
    let scriptDir = URL(fileURLWithPath: "\(#filePath)")
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    try? engine.load(source: "is_connected = function() return true end")   // keep test loads from dialing out
    try? engine.load(path: scriptDir.appendingPathComponent("Scripts/AlterAeon.lua").path)
    let display = terminal.components(separatedBy: "\n")
        .compactMap { engine.processLine($0) }.joined(separator: "\n")
    let leakedTails = display.components(separatedBy: "\n")
        .filter { $0.contains("track_") || $0.contains(".wav") || $0.hasPrefix("ground_") }
    print("REPLAY chunks=\(chunks.count) leakedSOUND=\(display.contains("!!SOUND")) "
        + "markerLeak=\(display.contains(promptGoAheadMarker)) leakedTails=\(leakedTails)")
  }
}

@Test func splitProtocolLineDoesNotLeakTailToDisplay() async throws {
  try await withSilentAudio {
    // Regression: a `kxwt_` protocol line split across a TCP read leaks its orphaned tail. The head
    // fragment still matches the `^kxwt_` gag and is hidden, but the tail (here "ground_01") matches
    // nothing and leaks to the terminal — the reported "last bit of the sound path" after a move.
    // The real capture split `...track_explore_under` | `ground_01`.
    func ga(_ s: String) -> Data { Data(s.utf8) + Data([255, 249]) }   // text + IAC GO-AHEAD
    let chunks: [Data] = [
        Data("kxwt_music channel_play music soundtrack/track_explore_under".utf8),  // head, no newline
        Data("ground_01\r\n".utf8),                                                  // tail completes it
        ga("Password: "),   // a genuine no-newline prompt, GA-terminated — must still display
    ]
    let stream = AsyncStream<Data> { c in for ch in chunks { c.yield(ch) }; c.finish() }

    let engine = LuaScriptEngine()
    func repoFile(_ rel: String, file: StaticString = #filePath) -> String {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(rel).path
    }
    try? engine.load(source: "is_connected = function() return true end")   // keep test loads from dialing out
    try engine.load(path: repoFile("Scripts/AlterAeon.lua"))   // installs the ^kxwt_ gag + music trigger

    var text = ""
    for try await piece in stream.handleIACCommunication(writeToStream: { _ in })
        .normalizeLineEndings()
        .assembleLines()
        .processMSP() {
        text += piece
    }
    let lines = text.components(separatedBy: "\n")
    let display = lines.compactMap { engine.processLine($0) }.joined(separator: "\n")

    #expect(!display.contains("ground_01"))        // the tail no longer leaks
    #expect(!display.contains("kxwt_"))            // head still gagged
    #expect(!display.contains(promptGoAheadMarker)) // the GO-AHEAD marker is consumed, never shown
    #expect(display.contains("Password: "))        // the real prompt still reaches the display
  }
}

@Test func goAheadFlushesPromptOnlyWhileNotSuppressed() async throws {
    // GA is a prompt boundary by the telnet NVT default, so `Password: ` + IAC GA flushes the held
    // partial line to the display (the injected marker is consumed by the assembler, not shown).
    func run(_ chunks: [Data]) async throws -> String {
        let stream = AsyncStream<Data> { c in for ch in chunks { c.yield(ch) }; c.finish() }
        var text = ""
        for try await piece in stream.handleIACCommunication(writeToStream: { _ in })
            .normalizeLineEndings().assembleLines() {
            text += piece
        }
        return text
    }
    // Default (no SGA): GA flushes the no-newline prompt.
    let shown = try await run([Data("Password: ".utf8) + Data([255, 249])])
    #expect(shown == "Password: ")
    #expect(!shown.contains(promptGoAheadMarker))

    // After the server negotiates SUPPRESS-GO-AHEAD (IAC WILL SGA, 255 251 3), GA is no longer a
    // prompt boundary: a stray GA must NOT flush, so the partial stays held (nothing emitted yet).
    let suppressed = try await run([
        Data([255, 251, 3]),                                   // IAC WILL SGA
        Data("Password: ".utf8) + Data([255, 249]),            // prompt + (now-meaningless) GA
    ])
    #expect(suppressed.isEmpty)
    #expect(!suppressed.contains(promptGoAheadMarker))
}

@Test func iacSubnegotiationParsesOptionAndPayload() throws {
    // IAC SB GMCP <payload> IAC SE — the payload is delivered verbatim and the whole sequence is
    // consumed (never leaked to the display).
    let payload = Data("Core.Hello { }".utf8)
    let wire = Data([255, 250, 201]) + payload + Data([255, 240])
    var input = Substring(String(data: wire, encoding: .isoLatin1)!)
    let token = try IAC.streamTokenParser().parse(&input)
    guard case .subnegotiation(let option, let got) = token else {
        Issue.record("expected subnegotiation, got \(token)")
        return
    }
    #expect(option == 201)
    #expect(got == payload)
    #expect(input.isEmpty)
}

@Test func iacSubnegotiationUnescapesDoubledIAC() throws {
    // A raw 0xFF inside a subnegotiation is escaped on the wire as IAC IAC (255 255); it must be
    // collapsed back to a single 0xFF in the delivered payload. MSDP option (69) here.
    let wire = Data([255, 250, 69, 1, 255, 255, 2, 255, 240])  // payload bytes: 1, 0xFF, 2
    var input = Substring(String(data: wire, encoding: .isoLatin1)!)
    let token = try IAC.streamTokenParser().parse(&input)
    guard case .subnegotiation(let option, let got) = token else {
        Issue.record("expected subnegotiation, got \(token)")
        return
    }
    #expect(option == 69)
    #expect(got == Data([1, 255, 2]))
}

@Test func iacSubnegotiationEscapedIACBeforeSEIsNotMistakenForTerminator() throws {
    // The edge a naive `PrefixUpTo(IAC SE)` gets wrong: a payload byte 0xFF is escaped on the wire as
    // IAC IAC (255 255); when the very next real payload byte is 0xF0 (240), the bytes read 255 255 240
    // and a two-byte-marker scan stops at the escaped IAC's second byte + that 0xF0, truncating the
    // payload and terminating early. The escaping-aware parser must skip the escaped pair and only stop
    // at the genuinely-unescaped IAC SE. Payload here is the two bytes [0xFF, 0xF0].
    let wire = Data([255, 250, 69, 255, 255, 240, 255, 240])  // IAC SB MSDP  255 255 240  IAC SE
    var input = Substring(String(data: wire, encoding: .isoLatin1)!)
    let token = try IAC.streamTokenParser().parse(&input)
    guard case .subnegotiation(let option, let got) = token else {
        Issue.record("expected subnegotiation, got \(token)")
        return
    }
    #expect(option == 69)
    #expect(got == Data([255, 240]))   // both payload bytes recovered, not truncated to [255]
    #expect(input.isEmpty)             // the whole sequence (incl. the real IAC SE) was consumed
}

@Test func iacSubnegotiationLoneTrailingIACIsBufferedUntilDisambiguated() throws {
    // A chunk boundary can fall right after a payload IAC (255), leaving it ambiguous: the next byte
    // decides whether it was an escaped IAC IAC (payload) or a terminating IAC SE. The parser must
    // report "incomplete" (not terminate, not leak) and wait. This is the disambiguation `PrefixUpTo`
    // cannot express, and the reason the payload scan needs the incomplete signal.
    func latin1(_ bytes: [UInt8]) -> Substring { Substring(String(data: Data(bytes), encoding: .isoLatin1)!) }
    var driver = StreamingParser(IAC.streamTokenParser())
    // Chunk 1 ends on the lone trailing IAC → nothing may be decided yet.
    let first = try driver.feed(latin1([255, 250, 69, 255]))   // IAC SB MSDP + a lone trailing IAC
    #expect(first.isEmpty)
    // Chunk 2 resolves it: the lone IAC + a 255 is an escaped 0xFF, then byte 1, then the real IAC SE,
    // then trailing text "Y".
    let rest = try driver.feed(latin1([255, 1, 255, 240]) + "Y")
    var payloads: [Data] = []
    var text = ""
    for token in rest {
        switch token {
        case .subnegotiation(_, let p): payloads.append(p)
        case .passthrough(let s): text += s
        default: break
        }
    }
    #expect(payloads == [Data([255, 1])])   // escaped IAC un-escaped to 0xFF, then byte 1
    #expect(text == "Y")                     // terminator consumed; only trailing text leaks to display
}

@Test func iacSubnegotiationSplitAcrossChunksIsBuffered() async throws {
    // The closing IAC SE lands in a later chunk. The streaming driver must buffer the partial
    // subnegotiation (not fail, not leak the payload as text), then consume it whole once SE arrives.
    let chunks: [Data] = [
        Data([255, 250, 201]) + Data("Core".utf8),                 // IAC SB GMCP + partial payload
        Data(".Ping".utf8) + Data([255, 240]) + Data("X".utf8),    // rest + IAC SE + trailing text
    ]
    let stream = AsyncStream<Data> { c in for ch in chunks { c.yield(ch) }; c.finish() }
    var output = ""
    for try await piece in stream.handleIACCommunication(writeToStream: { _ in }) {
        output += piece
    }
    #expect(output == "X")  // subnegotiation fully consumed; only the trailing text is visible
}

@Test func iacGmcpWillIsAccepted() async throws {
    // With no on_telnet_negotiate hook, IAC WILL GMCP (255 251 201) must be accepted with IAC DO
    // GMCP (255 253 201) so the server will actually start sending GMCP.
    let stream = AsyncStream<Data> { c in c.yield(Data([255, 251, 201])); c.finish() }
    let writes = RecordedWrites()
    var output = ""
    for try await piece in stream.handleIACCommunication(writeToStream: { await writes.add($0) }) {
        output += piece
    }
    #expect(output.isEmpty)
    #expect(await writes.all == [Data([255, 253, 201])])
}

@Test func gaggedKxwtBatchesRenderNothing() async throws {
  try await withSilentAudio {
    // Regression for "a bunch of blank lines before my command". When the player is idle, AlterAeon
    // streams kxwt_ status batches (group HP, prompt, sky/time) as their OWN network packets. Each
    // is fully gagged, so processServerOutputForScripts returns "" for it. The display consumer
    // (MudClient.swift) must SKIP those empty chunks: TerminalService.print() paints a divider line
    // unconditionally, so print("") leaves a blank line on screen — one per idle kxwt batch.
    //
    // This drives a REAL capture through the REAL pipeline and asserts that every chunk which was
    // nothing but gagged kxwt_ lines renders to "" (so the consumer's `guard !string.isEmpty` drops
    // it, emitting no blank line).
    func repoFile(_ rel: String, file: StaticString = #filePath) -> String {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(rel).path
    }
    let capture = try String(
        contentsOfFile: repoFile("Tests/MudClientTests/fixtures/pellam_kxwt_capture.log"), encoding: .utf8)
    let chunks = capture.split(separator: "\n").compactMap { Data(base64Encoded: String($0)) }
    #expect(!chunks.isEmpty)

    let interp = Container.scriptInterpreter()
    interp.engine.clearRules()
    try? interp.engine.load(source: "is_connected = function() return true end")   // keep test loads from dialing out
    try interp.engine.load(path: repoFile("Scripts/AlterAeon.lua"))   // installs the ^kxwt_ gag
    let stream = AsyncStream<Data> { c in for ch in chunks { c.yield(ch) }; c.finish() }

    // Replicate processServerOutputForScripts per chunk so we can correlate INPUT with rendered
    // OUTPUT, then rebuild the screen the way the consumer does (dropping empty chunks).
    var leaks = [String]()
    var kept = [String]()
    for try await output in stream.handleIACCommunication(writeToStream: { _ in })
        .normalizeLineEndings().assembleLines().processMSP() {
        let lines = output.replacingOccurrences(of: "\r", with: "").components(separatedBy: CharacterSet.newlines)
        let gagged = lines.map { interp.engine.processLine($0) == nil }
        var out = [String]()
        for (i, line) in lines.enumerated() {
            if gagged[i] { continue }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if (i > 0 && gagged[i - 1]) || (i + 1 < lines.count && gagged[i + 1]) { continue }
            }
            out.append(line)
        }
        let rendered = out.joined(separator: "\n")
        // A chunk that was nothing but kxwt_ machinery (+ framing blanks) MUST render to "", so the
        // consumer's `guard !string.isEmpty` drops it. If it renders a stray "\n", it paints a blank.
        let hasKxwt = lines.contains { $0.hasPrefix("kxwt_") }
        let onlyKxwtOrBlank = lines.allSatisfy {
            $0.hasPrefix("kxwt_") || $0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        if hasKxwt && onlyKxwtOrBlank && !rendered.isEmpty { leaks.append(rendered.debugDescription) }
        if !rendered.isEmpty { kept.append(rendered) }    // mirror consumer: skip empty chunks
    }
    #expect(leaks.isEmpty, "kxwt-only batches that still render a (blank) line: \(leaks)")

    // Concretely: the idle updates between the "Tboss" notify and the following "A wide tunnel" room
    // must not introduce a blank-line run. Concatenate kept chunks the way the terminal does.
    let screen = kept.joined()
    if let n = screen.range(of: "Tboss stole"),
       let r = screen.range(of: "A wide tunnel", range: n.upperBound..<screen.endIndex) {
        let between = String(screen[n.upperBound..<r.lowerBound])
        #expect(!between.contains("\n\n\n"), "blank-line run between notify and room: \(between.debugDescription)")
    }
  }
}

@Test func scriptRegisteredCommandsDispatch() throws {
  try withSilentAudio {
    // `#` commands are owned by scripts via the `command` BRIDGE: command("kxwt", h) defines a global
    // `kxwt`, and the REPL's legacy rewrite turns typed `#kxwt dump 5` into `kxwt("dump 5")`.
    func repoFile(_ rel: String, file: StaticString = #filePath) -> String {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(rel).path
    }
    let engine = LuaScriptEngine()
    try? engine.load(source: "is_connected = function() return true end")   // keep test loads from dialing out
    try engine.load(path: repoFile("Scripts/AlterAeon.lua"))
    var echoed = [String]()
    engine.onEcho = { echoed.append($0) }

    // `#kxwt dump N` shows the last N gagged kxwt lines the ring buffer captured.
    _ = engine.processLine("kxwt_mdeath A grey scaled imp")
    _ = engine.processLine("kxwt_prompt 1 2 3 4 5 6")
    echoed.removeAll()
    engine.evalREPL("kxwt dump 5")
    let dump = echoed.joined(separator: "\n")
    #expect(dump.contains("kxwt_mdeath A grey scaled imp"))
    #expect(dump.contains("kxwt_prompt 1 2 3 4 5 6"))

    // `#kxwt corpse on` toggles the harvest→bsac→sac automation.
    echoed.removeAll()
    engine.evalREPL("kxwt corpse on")
    #expect(echoed.contains { $0.lowercased().contains("corpse automation on") })
    echoed.removeAll()
    engine.evalREPL("kxwt corpse status")
    #expect(echoed.contains { $0.contains("corpse ON") })
  }
}

@Test func luaAfterTimerFiresCallback() async throws {
    let engine = LuaScriptEngine()
    var echoed: [String] = []
    engine.onEcho = { echoed.append($0) }
    // `after` is a generic primitive: schedule a Lua callback, which calls back into the host.
    try engine.load(source: #"after(0.05, function() echo("fired") end)"#)
    #expect(echoed.isEmpty)              // not yet
    try await Task.sleep(nanoseconds: 200_000_000)
    #expect(echoed == ["fired"])         // timer fired the Lua callback
}

@Test func luaOnUserInputHookIsCalled() throws {
    let engine = LuaScriptEngine()
    var seen: [String] = []
    engine.onEcho = { seen.append($0) }
    try engine.load(source: #"function on_user_input(cmd) echo("typed:" .. cmd) end"#)
    engine.notifyUserInput("north")
    #expect(seen == ["typed:north"])
}

@Test func luaGameScriptsLoadCleanly() throws {
  try withSilentAudio {
    // Load the real game scripts through the engine to catch syntax errors and missing builtins —
    // they're otherwise only exercised at runtime. Resolved relative to this source file.
    func repoFile(_ rel: String, file: StaticString = #filePath) -> String {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(rel).path
    }
    let engine = LuaScriptEngine()
    try? engine.load(source: "is_connected = function() return true end")   // keep test loads from dialing out
    try engine.load(path: repoFile("Scripts/AlterAeon.lua"))   // throws on syntax/runtime error
    try engine.load(path: repoFile("Scripts/AIPilot.lua"))
  }
}

@Test func aiPilotToolDefinitionsAreValidJSON() throws {
    // The AI pilot hands the model a JSON array of OpenAI tool definitions (built by AIPilot.lua's
    // hand-rolled JSON encoder). `#ai tools` echoes that exact array — parse it and assert the
    // shape LM Studio expects, so an encoder regression can't ship silently malformed tools.
    func repoFile(_ rel: String, file: StaticString = #filePath) -> String {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(rel).path
    }
    let engine = LuaScriptEngine()
    try? engine.load(source: "is_connected = function() return true end")   // keep test loads from dialing out
    try engine.load(path: repoFile("Scripts/AlterAeon.lua"))
    try engine.load(path: repoFile("Scripts/AIPilot.lua"))

    var echoed = [String]()
    engine.onEcho = { echoed.append($0) }
    engine.callGlobal("ai_command", "tools")

    let json = echoed.last ?? ""
    let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8))
    let tools = try #require(parsed as? [[String: Any]])
    #expect(tools.count >= 10)

    var names = Set<String>()
    for tool in tools {
        #expect(tool["type"] as? String == "function")
        let fn = try #require(tool["function"] as? [String: Any])
        let name = try #require(fn["name"] as? String)
        names.insert(name)
        #expect(fn["description"] is String)
        let params = try #require(fn["parameters"] as? [String: Any])
        #expect(params["type"] as? String == "object")
        // Even no-arg tools must carry an object (not array) for `properties`.
        #expect(params["properties"] is [String: Any])
    }
    // The structured actions that replace free-text command parsing must all be present.
    for expected in ["move", "attack", "cast", "get", "drop", "wear", "recover", "command", "wait", "remember"] {
        #expect(names.contains(expected))
    }
}

@Test func humanPlayMapsToToolCallTrainingExamples() throws {
    // "Tune the model on me": a command the human types is captured as an OpenAI tool-call SFT
    // example (system + user prompt, assistant tool_call). `#ai demo <cmd>` builds that record
    // without writing to disk. Assert the JSON shape and that raw commands classify into the right
    // structured tool, with a verbatim `command` fallback for anything unstructured.
    func repoFile(_ rel: String, file: StaticString = #filePath) -> String {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(rel).path
    }
    let engine = LuaScriptEngine()
    try? engine.load(source: "is_connected = function() return true end")   // keep test loads from dialing out
    try engine.load(path: repoFile("Scripts/AlterAeon.lua"))
    try engine.load(path: repoFile("Scripts/AIPilot.lua"))

    var echoed = [String]()
    engine.onEcho = { echoed.append($0) }

    func demo(_ command: String) throws -> (name: String, args: [String: Any]) {
        echoed.removeAll()
        engine.callGlobal("ai_command", "demo \(command)")
        let record = try JSONSerialization.jsonObject(with: Data((echoed.last ?? "").utf8)) as? [String: Any]
        let messages = try #require(record?["messages"] as? [[String: Any]])
        #expect(messages.count == 3)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[1]["role"] as? String == "user")
        let assistant = messages[2]
        #expect(assistant["role"] as? String == "assistant")
        let calls = try #require(assistant["tool_calls"] as? [[String: Any]])
        let fn = try #require(calls.first?["function"] as? [String: Any])
        let name = try #require(fn["name"] as? String)
        // arguments is a JSON *string* per the OpenAI shape — decode it.
        let argsStr = try #require(fn["arguments"] as? String)
        let args = (try? JSONSerialization.jsonObject(with: Data(argsStr.utf8))) as? [String: Any] ?? [:]
        return (name, args)
    }

    let move = try demo("west")
    #expect(move.name == "move"); #expect(move.args["direction"] as? String == "west")

    let abbrev = try demo("ne")
    #expect(abbrev.name == "move"); #expect(abbrev.args["direction"] as? String == "northeast")

    let attack = try demo("kill goblin")
    #expect(attack.name == "attack"); #expect(attack.args["target"] as? String == "goblin")

    let cast = try demo("cast 'shower of sparks' kobold")
    #expect(cast.name == "cast")
    #expect(cast.args["spell"] as? String == "shower of sparks")
    #expect(cast.args["target"] as? String == "kobold")

    let recover = try demo("sleep")
    #expect(recover.name == "recover"); #expect(recover.args["method"] as? String == "sleep")

    // No structured tool fits 'train' -> verbatim command fallback (a still-valid demonstration).
    let train = try demo("train dagger")
    #expect(train.name == "command"); #expect(train.args["text"] as? String == "train dagger")
}

@Test func rawLogPipelineGagsKxwtNoLeak() async throws {
  try await withSilentAudio {
    // Repro from a real raw capture: run actual server bytes through the real text pipeline
    // (IAC strip + CRLF normalize + MSP strip) and the AlterAeon gag, and prove kxwt machinery and
    // IAC Go-Ahead do NOT leak to the display.
    let chunks = RAW_SAMPLE.compactMap { Data(base64Encoded: $0) }
    #expect(!chunks.isEmpty)
    let stream = AsyncStream<Data> { c in for ch in chunks { c.yield(ch) }; c.finish() }

    var text = ""
    for try await piece in stream.handleIACCommunication(writeToStream: { _ in })
        .normalizeLineEndings()
        .assembleLines()
        .processMSP() {
        text += piece
    }

    func repoFile(_ rel: String, file: StaticString = #filePath) -> String {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(rel).path
    }
    let engine = LuaScriptEngine()
    try? engine.load(source: "is_connected = function() return true end")   // keep test loads from dialing out
    try engine.load(path: repoFile("Scripts/AlterAeon.lua"))   // installs the ^kxwt_ gag
    let lines = text.components(separatedBy: "\n")
    let gagged = lines.map { engine.processLine($0) == nil }
    var out = [String]()
    for (i, line) in lines.enumerated() {
        if gagged[i] { continue }
        if line.trimmingCharacters(in: .whitespaces).isEmpty {
            if (i > 0 && gagged[i - 1]) || (i + 1 < lines.count && gagged[i + 1]) { continue }
        }
        out.append(line)
    }
    let display = out.joined(separator: "\n")

    #expect(!display.contains("kxwt_"))   // machinery gagged, not leaked
    #expect(!display.unicodeScalars.contains { $0.value == 0xFF || $0.value == 0xF9 })  // IAC GA stripped
    // sanity: real content survived
    #expect(display.contains("Pellam Cemetery") || display.contains("Exits"))
  }
}

/// A real slice of a server capture (8 network chunks) containing kxwt_ machinery, IAC Go-Ahead
/// terminators, MSP directives, and room text — used by rawLogPipelineGagsKxwtNoLeak.
let RAW_SAMPLE: [String] = [
    "DQpreHd0X3N1cHBvcnRlZA0KISFTT1VORChzeXN0ZW0vbG9naW5fc291bmQud2F2KQ0KDQpMb2dnaW5nIGluIGNoYXJhY3RlciAnZWxtaW5zdGVyJw0KG1sxbVRoZSBQZWxsYW0gQ2VtZXRlcnkgV2F5cG9pbnQNChtbMG1XYXlwb2ludHMgYXJlIGEgcXVpY2sgd2F5IHRvIGdldCBmcm9tIHBsYWNlIHRvIHBsYWNlIHdpdGhvdXQgbmVlZGluZyB0byB3YWxrLg0KWW91IGNhbiB0cmF2ZWwgYmV0d2VlbiB3YXlwb2ludHMgdXNpbmcgdGhlICcbWzFtG1szM213YXlwb2ludBtbMzdtG1swbScgY29tbWFuZC4gIFlvdSBjYW4gdXNlDQp0aGUgJxtbMW0bWzMzbXByYXkgaGVyZRtbMzdtG1swbScgY29tbWFuZCB0byBhZGQgdGhpcyB3YXlwb2ludCB0byB5b3VyIHdheXBvaW50IGxpc3QuDQoNClRoZSBmYXIgbm9ydGggcmltIG9mIHRoZSBwaXQgaXMgbGlnaHRseSBmb3Jlc3RlZCB3aXRoIHRhbGwgY2VkYXJzLiAgVmVyeSBvbGQNCmhlYWRzdG9uZXMsIHNvIHdvcm4gdGhleSBubyBsb25nZXIgYmVhciBhbnkgdGV4dCwgYXJlIGhpZGRlbiB3aXRoaW4gdGhlIHdvb2RlZA0KYXJlYS4gVG8gdGhlIHNvdXRoLCBhIHBhdGggbGVhZHMgZG93biBmcm9tIHRoZSBoaWxscyBpbnRvIHRoZSBjZW1ldGVyeS4NCg0KG1sxbRtbMzRtSXQgaXMgbmlnaHQuDQobWzM3bRtbMG1bRXhpdHM6IGVhc3Qgc291dGggXQ0K//k=",
    "DQpreHd0X215bmFtZSBlbG1pbnN0ZXINCmt4d3RfZ29sZCA5NA0Ka3h3dF9leHAgMTQ5MjANCmt4d3RfZXhwY2FwIDEyNDANCmt4d3Rfc2t5IDEgMSAwDQpreHd0X3RpbWUgMTM1MCBuaWdodCAxMDozMCBwbQ0Ka3h3dF9ydm51bSA1MDE1MSAxIDEgLTEyMTExIDc3IDEgMA0Ka3h3dF90ZXJyYWluIDQNCmt4d3RfcnNob3J0IFRoZSBQZWxsYW0gQ2VtZXRlcnkgV2F5cG9pbnQNCmt4d3RfYXJlYSA1MDExIFRoZSBDZW1ldGVyeSBuZWFyIFBlbGxhbQ0Ka3h3dF9wb3NpdGlvbiBzdGFuZGluZw0KQ2xpZW50IHRyaWdnZXIgbW9kZSBlbmFibGVkLg0K//k=",
    "a3h3dF9wcm9tcHQgNjAgNjAgMTM1IDEzNSAxNDYgMTQ2DQpreHd0X2ZpZ2h0aW5nIC0xDQoNChtbMW08NjBocCAxMzVtIDE0Nm12PhtbMG3/+Q==",
]
