//
//  InputServiceTests.swift
//  MudClient
//
//  The `!` "repeat" token and how it composes with `;` (independent commands) and `|` (the promise pipe).
//  `!` repeats the last full LINE — not just the last atomic command — whether it's typed on its own or as
//  a pipe stage.
//

import Foundation
import Testing
@testable import MudClient

@Suite(.serialized)
struct InputServiceTests {

    // MARK: resolveBang — the pure expansion (no state)

    @Test func bangAloneExpandsToTheWholeLastLine() {
        // A bare `!` becomes the ENTIRE last line, `;` commands and all — not just its last segment.
        #expect(InputService.resolveBang("!", last: "drop scroll;sac scroll") == "drop scroll;sac scroll")
    }

    @Test func bangAsAPipeStageExpandsToTheWholeLastLine() {
        // `... | !` — the `!` stage becomes the whole last line (which may itself carry `;`).
        #expect(InputService.resolveBang("kill orc | !", last: "drop scroll;sac scroll")
                == "kill orc |drop scroll;sac scroll")
        #expect(InputService.resolveBang("a;b | c;d | !", last: "drop x;sac x")
                == "a;b | c;d |drop x;sac x")
    }

    @Test func nonBangLinesAndNonStandaloneBangsPassThrough() {
        #expect(InputService.resolveBang("north", last: "whatever") == "north")   // no `!` at all
        #expect(InputService.resolveBang("!foo", last: "x") == "!foo")            // `!foo` is ordinary text
        #expect(InputService.resolveBang("foo!", last: "x") == "foo!")
    }

    @Test func bangWithNoHistoryResolvesToEmpty() {
        #expect(InputService.resolveBang("!", last: nil) == "")
    }

    // MARK: parse → commandStream — the stateful behaviour

    /// Drive `parse` then read the next `n` commands the stream emits.
    private func drain(_ svc: InputService,
                       _ iterator: inout some AsyncIteratorProtocol,
                       count n: Int) async throws -> [String] {
        var out: [String] = []
        for _ in 0..<n {
            if let cmd = try await iterator.next() as? OutboundCommand { out.append(cmd.text) }
        }
        return out
    }

    @Test func bangRepeatsBOTHCommandsOfASemicolonLine() async throws {
        let svc = InputService()
        var it = svc.commandStream.makeAsyncIterator()

        try svc.parse(input: "drop scroll;sac scroll")           // → two independent commands
        #expect(try await drain(svc, &it, count: 2) == ["drop scroll", "sac scroll"])

        try svc.parse(input: "!")                                // repeats the WHOLE line → both again
        #expect(try await drain(svc, &it, count: 2) == ["drop scroll", "sac scroll"])
    }

    @Test func bangPipeStageRunsAfterTheEarlierStages() async throws {
        let svc = InputService()
        var it = svc.commandStream.makeAsyncIterator()

        try svc.parse(input: "drop scroll;sac scroll")
        _ = try await drain(svc, &it, count: 2)

        // `kill orc | !` is a pipe (yielded whole), with the `!` stage expanded to the last line.
        try svc.parse(input: "kill orc | !")
        #expect(try await drain(svc, &it, count: 1) == ["kill orc |drop scroll;sac scroll"])
    }

    @Test func aLaterBangChasesTheResolvedLineNotAnotherBang() async throws {
        let svc = InputService()
        var it = svc.commandStream.makeAsyncIterator()

        try svc.parse(input: "north")
        _ = try await drain(svc, &it, count: 1)
        try svc.parse(input: "!")                                // → north (remembers "north")
        _ = try await drain(svc, &it, count: 1)
        try svc.parse(input: "!")                                // → north again, not "!"
        #expect(try await drain(svc, &it, count: 1) == ["north"])
    }

    @Test func blankLineEmitsABareNewlineToDrivePagers() async throws {
        let svc = InputService()
        var it = svc.commandStream.makeAsyncIterator()

        try svc.parse(input: "")                                 // Enter on empty input → bare newline
        #expect(try await drain(svc, &it, count: 1) == [""])

        try svc.parse(input: "   ")                              // whitespace-only counts as blank too
        #expect(try await drain(svc, &it, count: 1) == [""])
    }

    @Test func blankLineDoesNotClobberTheBangHistory() async throws {
        let svc = InputService()
        var it = svc.commandStream.makeAsyncIterator()

        try svc.parse(input: "north")
        _ = try await drain(svc, &it, count: 1)
        try svc.parse(input: "")                                 // a blank submit in between…
        _ = try await drain(svc, &it, count: 1)
        try svc.parse(input: "!")                                // …still repeats "north", not the blank
        #expect(try await drain(svc, &it, count: 1) == ["north"])
    }
}
