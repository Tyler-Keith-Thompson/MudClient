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
