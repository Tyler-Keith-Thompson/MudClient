import DependencyInjection
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
  try withTestContainer {
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
}

@Test func echoRestoresTheGameColourSoFollowingOutputSurvives() {
  try withTestContainer {
    // The reported bug: the game set a colour and never reset it (multi-line coloured chat); a dim script
    // annotation echoed in between ends in its own reset, which strips the colour off everything after it.
    let game = "\u{1B}[36m"                               // game set cyan, no reset
    let echo = "\u{1B}[90m  \u{21b3} brb = be right back\u{1B}[0m"   // dim annotation, ends in a reset
    // Un-restored, the carry after the echo is cleared → following game output renders default.
    #expect(TerminalService.activeSGRState(game + echo) == "")
    // Restoring re-asserts the game's SGR after the echo, so the carry is preserved for the next line.
    let restored = TerminalService.echoBodyRestoringSGR(echo, carried: game)
    #expect(TerminalService.activeSGRState(game + restored) == game)
    // When the game is at default there's nothing to restore — the echo is left untouched.
    #expect(TerminalService.echoBodyRestoringSGR(echo, carried: "") == echo)
  }
}

@Test func scrolledBackMultiLineBlockCarriesColourPastTheFirstLine() {
  try withTestContainer {
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
}

@Test func scrolledBackLongWrappedLineKeepsColourOnContinuationRows() {
  try withTestContainer {
    // A single coloured logical line longer than the width wraps into several physical rows; the
    // low-level wrapper copies the colour escape only onto the first row, so continuations used to be
    // uncoloured. Each wrapped row must now carry the colour.
    let long = "\u{1B}[31m" + String(repeating: "x", count: 10)
    let rows = TerminalService.selfContainedPhysicalRows([long], width: 4)
    #expect(rows.count == 3)                          // 10 visible chars / width 4
    for r in rows { #expect(r.hasPrefix("\u{1B}[31m")) }
  }
}

// MARK: - Input decoding (the "error: unexpected input --> input:1:3" display-corruption bug)
//
// The old swift-parsing line grammar printed its PARSE FAILURE to the game display whenever the input
// buffer held an ESC-prefixed fragment it couldn't match (a chunk-boundary-split escape, a focus event,
// an unhandled key). These exercise the escape-aware tokenizer that replaced it: it has no failure
// path, so nothing it can't classify is ever surfaced as text — let alone as an error string.

private typealias E = TerminalService.InputEvent

@Test func tokenizePlainTextAndUTF8InsertsAsText() {
  try withTestContainer {
    #expect(TerminalService.tokenize("hello").events == [E.text("hello")])
    // Multi-byte UTF-8 characters are single Swift Characters → one printable run, inserted verbatim.
    #expect(TerminalService.tokenize("café ☃ 日本").events == [E.text("café ☃ 日本")])
    #expect(TerminalService.tokenize("hello").remaining == "")
  }
}

@Test func tokenizeEditorKeysStillDecode() {
  try withTestContainer {
    #expect(TerminalService.tokenize("\u{1B}[A").events == [E.key("up")])
    #expect(TerminalService.tokenize("\u{1B}[B").events == [E.key("down")])
    #expect(TerminalService.tokenize("\u{1B}[C").events == [E.key("right")])
    #expect(TerminalService.tokenize("\u{1B}[D").events == [E.key("left")])
    #expect(TerminalService.tokenize("\u{01}").events == [E.cursorStart])   // ctrl-A
    #expect(TerminalService.tokenize("\u{05}").events == [E.cursorEnd])     // ctrl-E
    #expect(TerminalService.tokenize("\u{7F}").events == [E.backspace])
    #expect(TerminalService.tokenize("\n").events == [E.enter])
    // Typed text then Enter in one chunk: text is inserted before the submit, so the buffer is right.
    #expect(TerminalService.tokenize("north\n").events == [E.text("north"), E.enter])
  }
}

@Test func tokenizeUnknownEscapeSequencesAreDroppedWhole() {
  try withTestContainer {
    // A focus event (ESC[I) — none of the line-editor keys, and the OLD code printed a parse error for
    // it. It must vanish entirely: no events, no leftover, no text.
    let focusIn = TerminalService.tokenize("\u{1B}[I")
    #expect(focusIn.events.isEmpty)
    #expect(focusIn.remaining == "")
    // Dropped whole even when wedged between real input, without shredding into stray characters:
    // the focus-event CSI has its own final byte ('I'), so the following 'b' survives as text.
    #expect(TerminalService.tokenize("a\u{1B}[Ib").events == [E.text("a"), E.text("b")])
    // A truly foreign CSI (device-attribute-style) is consumed silently, leaving no residue.
    #expect(TerminalService.tokenize("\u{1B}[>1;2c").events.isEmpty)
  }
}

@Test func tokenizeReproducesTheReportedBugFragmentWithoutError() {
  try withTestContainer {
    // The exact reported buffer: a CSI sequence split by a stdin read boundary right after "ESC[".
    // The old grammar's `enter` alt skipped both bytes then failed at column 3 expecting "\n" (the
    // "input:1:3" in the dump). Now it's simply held for the next read — no events, no error text.
    let first = TerminalService.tokenize("\u{1B}[")
    #expect(first.events.isEmpty)
    #expect(first.remaining == "\u{1B}[")             // buffered, not shredded, not errored
    // The completing byte arrives on the next read; reassembled, it's the intended key.
    let second = TerminalService.tokenize(first.remaining + "A")
    #expect(second.events == [E.key("up")])
    #expect(second.remaining == "")
    // A lone ESC is also just buffered.
    #expect(TerminalService.tokenize("\u{1B}").remaining == "\u{1B}")
  }
}

@Test func tokenizeBuffersPartialEscapeShapesAndCompletesWholeOnes() {
  try withTestContainer {
    // Ported from the old `scanEscape` unit: the declarative grammar must BUFFER any escape shape that
    // runs off the end of the read (holding it in `remaining`, emitting no event), and CONSUME a whole
    // one. Covers CSI, SS3 and the two-byte (alt) shape.
    func buffered(_ s: String) { let r = TerminalService.tokenize(s); #expect(r.events.isEmpty); #expect(r.remaining == s) }
    buffered("\u{1B}")            // lone ESC — could still become CSI/SS3/alt
    buffered("\u{1B}[")           // CSI introducer, no params/final yet
    buffered("\u{1B}[12;5")       // CSI params, no final byte yet
    buffered("\u{1B}O")           // SS3 introducer, no final yet
    // Whole shapes are consumed: recognised → a key, unknown-but-complete → dropped (no residue).
    #expect(TerminalService.tokenize("\u{1B}[A").events == [E.key("up")])       // CSI arrow
    #expect(TerminalService.tokenize("\u{1B}[15~").events == [E.key("f5")])     // CSI tilde
    #expect(TerminalService.tokenize("\u{1B}OP").events == [E.key("f1")])       // SS3 F1
    #expect(TerminalService.tokenize("\u{1B}a").events == [E.key("alt-a")])     // two-byte alt-a
    #expect(TerminalService.tokenize("\u{1B}a").remaining == "")
  }
}

@Test func bracketedPasteInsertsAsLiteralText() {
  try withTestContainer {
    // Single-line paste: markers stripped, content extracted, nothing passed to key decoding.
    let single = TerminalService.extractPaste("\u{1B}[200~get all\u{1B}[201~", inPaste: false, partial: "")
    #expect(single.pasted == "get all")
    #expect(single.passthrough == "")
    #expect(single.inPaste == false)
    // Multi-line paste: embedded newlines collapse to spaces so it stays one editable, un-sent line.
    let multi = TerminalService.extractPaste("\u{1B}[200~north\nsouth\neast\u{1B}[201~", inPaste: false, partial: "")
    #expect(multi.pasted == "north south east")
    #expect(multi.inPaste == false)
    // Non-paste text around a paste passes through untouched.
    let around = TerminalService.extractPaste("x\u{1B}[200~y\u{1B}[201~z", inPaste: false, partial: "")
    #expect(around.pasted == "y")
    #expect(around.passthrough == "xz")
  }
}

@Test func bracketedPasteMarkersSplitAcrossReadsReassemble() {
  try withTestContainer {
    // Start marker split mid-way across a read boundary → held, then completed on the next read.
    let r1 = TerminalService.extractPaste("\u{1B}[20", inPaste: false, partial: "")
    #expect(r1.pasted == "")
    #expect(r1.passthrough == "")
    #expect(r1.partial == "\u{1B}[20")                // buffered marker fragment
    let r2 = TerminalService.extractPaste("0~hi\u{1B}[201~", inPaste: false, partial: r1.partial)
    #expect(r2.pasted == "hi")
    #expect(r2.inPaste == false)
    // Paste content itself split across reads: still inside the paste after the first chunk.
    let c1 = TerminalService.extractPaste("\u{1B}[200~foo", inPaste: false, partial: "")
    #expect(c1.pasted == "foo")
    #expect(c1.inPaste == true)                       // still mid-paste, waiting for the end marker
    let c2 = TerminalService.extractPaste("bar\u{1B}[201~", inPaste: c1.inPaste, partial: c1.partial)
    #expect(c2.pasted == "bar")
    #expect(c2.inPaste == false)
    // An ESC[2-prefixed real key (Insert) that only LOOKS like a paste-start prefix is recovered.
    let insert = TerminalService.extractPaste("\u{1B}[2~", inPaste: false, partial: "")
    #expect(insert.passthrough == "\u{1B}[2~")        // not swallowed as paste
    #expect(insert.pasted == "")
  }
}

@Test func handleBuffersReportedFragmentWithoutInsertingOrErroring() {
  try withTestContainer {
    // Drive the real handle() path with the reproducing fragment and assert the line stays clean —
    // the old code printed the parser error here; the new code silently holds the partial sequence.
    let ts = TerminalService()
    ts.lineBuffer = ""
    ts.partialInput = ""
    ts.handle(input: "\u{1B}[")                        // chunk-boundary CSI fragment
    #expect(ts.lineBuffer == "")                       // nothing inserted, nothing printed, no crash
  }
}
