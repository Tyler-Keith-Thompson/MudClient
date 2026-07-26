import Foundation
import Testing

@testable import MudClient

// MARK: - multilineSpan (single-line vs multi-line detection)

@Test func multilineSpanIsNilForSingleLine() {
  #expect(LuaScriptEngine.multilineSpan(of: "^kxwq_hud") == nil)
}

@Test func multilineSpanCountsLines() {
  #expect(LuaScriptEngine.multilineSpan(of: #"\n^kxwq_hud"#) == 2)          // one newline → 2 lines
  #expect(LuaScriptEngine.multilineSpan(of: #"\n^\n^kxwq_hud.*"#) == 3)     // two newlines → 3 lines
  #expect(LuaScriptEngine.multilineSpan(of: "^$\n^kxwq_hud") == 2)          // a literal newline counts too
}

// MARK: - MultilineGagFilter: a true multi-line regex that DELETES the matched span

private func mlGag(_ pattern: String, _ span: Int) -> (regex: Regex<AnyRegexOutput>, span: Int) {
  (try! Regex(pattern).anchorsMatchLineEndings(), span)
}

/// Feed a sequence of rendered line-texts, accumulate everything emitted, then drain the tail.
private func run(_ f: inout MultilineGagFilter, _ texts: [String]) -> String {
  var out = ""
  for t in texts { out += f.feed(t) }
  out += f.drain()
  return out
}

@Test func noGagsIsPlainPassthrough() {
  var f = MultilineGagFilter()   // no multi-line gags
  #expect(run(&f, ["a\n", "\n", "b\n"]) == "a\n\nb\n")   // every byte passes through untouched
}

@Test func deletesFramingBlankBeforeTag() {
  var f = MultilineGagFilter()
  f.gags = [mlGag(#"\n^\n^kxwq_hud.*"#, 3)]   // <newline><blank line><newline>kxwq_hud…
  let out = run(&f, ["Draak gossips, 'hi'\n", "\n", "kxwq_hud|1|2|standing\n", "Next line.\n"])
  // The blank AND the tag are deleted; the gossip line keeps exactly ONE newline (no lingering blank).
  #expect(out == "Draak gossips, 'hi'\nNext line.\n")
}

@Test func blankWithoutMatchingTagIsPreserved() {
  var f = MultilineGagFilter()
  f.gags = [mlGag(#"\n^\n^kxwq_hud.*"#, 3)]
  let out = run(&f, ["hello\n", "\n", "world\n"])
  #expect(out == "hello\n\nworld\n")   // no kxwq_hud → nothing matches → genuine spacing kept
}

// The bug the user caught: unrelated consecutive lines held by the buffer must NOT get merged.
@Test func bystanderLinesAreNotMerged() {
  var f = MultilineGagFilter()
  f.gags = [mlGag(#"\n^\n^kxwq_hud.*"#, 3)]
  let out = run(&f, ["East - Adin\n", "West - a dwarven sentinel\n", "(south) closed.\n"])
  #expect(out == "East - Adin\nWest - a dwarven sentinel\n(south) closed.\n")
  #expect(!out.contains("AdinWest"))
}

@Test func matchStraddlingAChunkBoundaryStillDeletes() {
  // The blank arrives in one feed, the tag in the next — the hold window keeps them until they can match.
  var f = MultilineGagFilter()
  f.gags = [mlGag(#"\n^\n^kxwq_hud.*"#, 3)]
  var out = f.feed("Draak gossips.\n")
  out += f.feed("\n")
  out += f.feed("kxwq_hud|x\n")     // completes the match across feeds
  out += f.feed("After.\n")
  out += f.drain()
  #expect(out == "Draak gossips.\nAfter.\n")
}

// The user's exact case: `\n^\n^kxwq_hud.*$` against  Tree\n\nkxwq_hud …\nkxwq_sky…
@Test func dollarAnchorLeavesTheTagLinesOwnNewline() {
  var f = MultilineGagFilter()
  f.gags = [mlGag(#"\n^\n^kxwq_hud.*$"#, 3)]
  let out = run(&f, ["Thiel newbies, 'Tree'\n", "\n", "kxwq_hud the info\n", "kxwq_sky 1 1 0\n"])
  // `.*$` matches "kxwq_hud the info" but NOT the trailing newline ($ is zero-width), so the tag line's
  // OWN newline survives. Result: ONE newline between them — faithful, not merged. This is correct.
  #expect(out == "Thiel newbies, 'Tree'\nkxwq_sky 1 1 0\n")
}

// To ALSO delete the tag line's newline and merge the rows, match it explicitly with \n instead of $.
@Test func matchingTheTrailingNewlineMergesTheRows() {
  var f = MultilineGagFilter()
  f.gags = [mlGag(#"\n^\n^kxwq_hud.*\n"#, 3)]
  let out = run(&f, ["Thiel newbies, 'Tree'\n", "\n", "kxwq_hud the info\n", "kxwq_sky 1 1 0\n"])
  #expect(out == "Thiel newbies, 'Tree'kxwq_sky 1 1 0\n")   // merged, because the \n was matched too
}

@Test func noNewlineTailIsNotGivenAnExtraNewline() {
  var f = MultilineGagFilter()
  f.gags = [mlGag(#"\n^\n^kxwq_hud.*"#, 3)]
  // A no-newline prompt tail flows through without gaining a spurious row break.
  let out = run(&f, ["a\n", "b\n", "HP>"])   // "HP>" has no trailing newline
  #expect(out == "a\nb\nHP>")
}