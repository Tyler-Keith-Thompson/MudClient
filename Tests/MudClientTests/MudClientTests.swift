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
