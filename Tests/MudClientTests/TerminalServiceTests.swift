import Foundation
import Testing

@testable import MudClient

// MARK: - Scrollback SGR carry (the "only the first line keeps its colour" bug)
//
// When the user scrolls back, the output band is repainted from stored logical lines: it's cleared and
// SGR-reset per physical row, so any colour set on an EARLIER line (or an earlier wrap-row of the same
// long line) rendered as default. The fix makes each physical row self-contained by prefixing the SGR
// state active at its start. These exercise the pure core directly (no tty needed).

@Test func activeSGRStateAccumulatesUntilAReset() {
    #expect(TerminalService.activeSGRState("\u{1B}[31mfoo") == "\u{1B}[31m")
    // A reset clears everything carried before it.
    #expect(TerminalService.activeSGRState("\u{1B}[31mfoo\u{1B}[0mbar") == "")
    // Several SGR sequences accumulate in order.
    #expect(TerminalService.activeSGRState("\u{1B}[1m\u{1B}[31m") == "\u{1B}[1m\u{1B}[31m")
    // The empty `ESC[m` is a reset too.
    #expect(TerminalService.activeSGRState("\u{1B}[31m\u{1B}[m") == "")
    // Non-SGR escapes (a cursor move) don't count.
    #expect(TerminalService.activeSGRState("\u{1B}[2Kplain") == "")
    // Nothing styled → empty.
    #expect(TerminalService.activeSGRState("just text") == "")
}

@Test func scrolledBackMultiLineBlockCarriesColourPastTheFirstLine() {
    // The reported case: colour set on line one, reset only after line two (a coloured echo/server
    // block split into two stored logical lines). Both must render coloured in the scrolled-back view.
    let rows = TerminalService.selfContainedPhysicalRows(
        ["\u{1B}[36mline one", "line two\u{1B}[0m"], width: 80)
    #expect(rows.count == 2)
    #expect(rows[0].hasPrefix("\u{1B}[36m"))
    #expect(rows[1].hasPrefix("\u{1B}[36m"))          // carried onto the second line, not default
    // And once the block's reset is seen, a following line is back to default (no stale carry).
    let rows2 = TerminalService.selfContainedPhysicalRows(
        ["\u{1B}[36ma", "b\u{1B}[0m", "c"], width: 80)
    #expect(rows2[2] == "c")                          // no SGR prefix on the post-reset line
}

@Test func scrolledBackLongWrappedLineKeepsColourOnContinuationRows() {
    // A single coloured logical line longer than the width wraps into several physical rows; the
    // low-level wrapper copies the colour escape only onto the first row, so continuations used to be
    // uncoloured. Each wrapped row must now carry the colour.
    let long = "\u{1B}[31m" + String(repeating: "x", count: 10)
    let rows = TerminalService.selfContainedPhysicalRows([long], width: 4)
    #expect(rows.count == 3)                          // 10 visible chars / width 4
    for r in rows { #expect(r.hasPrefix("\u{1B}[31m")) }
}
