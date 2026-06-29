import Foundation
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
    // Debug tool: replay a MUD_RAW_LOG capture through the real IAC + MSP path.
    // Run with: bazel test ... --test_filter=replayCapturedRawLog --test_env=REPLAY_FILE=/path
    guard let path = ProcessInfo.processInfo.environment["REPLAY_FILE"],
          let content = try? String(contentsOfFile: path, encoding: .utf8) else {
        print("REPLAY: set REPLAY_FILE to a capture to run this"); return
    }
    let chunks = content.split(separator: "\n").compactMap { Data(base64Encoded: String($0)) }
    let stream = AsyncStream<Data> { c in for ch in chunks { c.yield(ch) }; c.finish() }
    let buffer = MSPLineBuffer()
    var terminal = "", directives = 0
    for try await text in stream.handleIACCommunication(writeToStream: { _ in }) {
        let r = buffer.process(text); terminal += r.output; directives += r.directives.count
    }
    print("REPLAY chunks=\(chunks.count) directives=\(directives) leakedSOUND=\(terminal.contains("!!SOUND"))")
}
