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

// MARK: - BufferDeleteFilter: the shared engine (deletes every span its rules match)

/// Compile a rule the way the engine does. `gag: true` extends the match to eat the whole final line + its
/// newline (Reading B — rows collapse); `gag: false` is #suppress (delete exactly what matched).
private func rule(_ pattern: String, gag: Bool) -> (regex: Regex<AnyRegexOutput>, span: Int) {
  let span = LuaScriptEngine.multilineSpan(of: pattern) ?? 1
  let src = gag && LuaScriptEngine.multilineSpan(of: pattern) != nil ? "(?:\(pattern))[^\\n]*\\n" : pattern
  return (try! Regex(src).anchorsMatchLineEndings(), span)
}

/// Feed a sequence of rendered line-texts, accumulate everything emitted, then drain the tail.
private func run(_ f: inout BufferDeleteFilter, _ texts: [String]) -> String {
  var out = ""
  for t in texts { out += f.feed(t) }
  out += f.drain()
  return out
}

@Test func noRulesIsPlainPassthrough() {
  var f = BufferDeleteFilter()   // no rules
  #expect(run(&f, ["a\n", "\n", "b\n"]) == "a\n\nb\n")   // every byte passes through untouched
}

// ── #gag (Reading B): the whole final matched line goes, so rows collapse ────────────────────────────
@Test func gagMultilineCollapsesRows() {
  var f = BufferDeleteFilter()
  f.rules = [rule(#"\n^\n^kxwq_hud.*"#, gag: true)]
  let out = run(&f, ["Thiel newbies, 'Tree'\n", "\n", "kxwq_hud the info\n", "kxwq_sky 1 1 0\n"])
  #expect(out == "Thiel newbies, 'Tree'kxwq_sky 1 1 0\n")   // blank + hud line consumed THROUGH its newline
}

@Test func gagSingleMatchingTagStillLeavesOtherLines() {
  var f = BufferDeleteFilter()
  f.rules = [rule(#"\n^\n^kxwq_hud.*"#, gag: true)]
  let out = run(&f, ["hello\n", "\n", "world\n"])   // no kxwq_hud
  #expect(out == "hello\n\nworld\n")                 // nothing matches → untouched
}

// ── #suppress (char-exact): deletes exactly the match, leaving the tag line's own newline ────────────
@Test func suppressLeavesTheTagLinesOwnNewline() {
  var f = BufferDeleteFilter()
  f.rules = [rule(#"\n^\n^kxwq_hud.*$"#, gag: false)]
  let out = run(&f, ["Thiel newbies, 'Tree'\n", "\n", "kxwq_hud the info\n", "kxwq_sky 1 1 0\n"])
  // `.*$` matches "kxwq_hud the info" but not the trailing newline ($ is zero-width) → rows stay split.
  #expect(out == "Thiel newbies, 'Tree'\nkxwq_sky 1 1 0\n")
}

@Test func suppressCanCutPartOfALine() {
  var f = BufferDeleteFilter()
  f.rules = [rule("foo", gag: false)]   // single-line suppress (span 1) — char-exact, not whole-line
  #expect(run(&f, ["xfooy\n"]) == "xy\n")
}

// The bug the user caught earlier: unrelated buffered lines must keep their own newlines (no "AdinWest").
@Test func bystanderLinesAreNotMerged() {
  var f = BufferDeleteFilter()
  f.rules = [rule(#"\n^\n^kxwq_hud.*"#, gag: true)]
  let out = run(&f, ["East - Adin\n", "West - a dwarven sentinel\n", "(south) closed.\n"])
  #expect(out == "East - Adin\nWest - a dwarven sentinel\n(south) closed.\n")
  #expect(!out.contains("AdinWest"))
}

@Test func matchStraddlingAChunkBoundaryStillDeletes() {
  var f = BufferDeleteFilter()
  f.rules = [rule(#"\n^\n^kxwq_hud.*"#, gag: true)]
  var out = f.feed("Draak gossips.\n")
  out += f.feed("\n")
  out += f.feed("kxwq_hud|x\n")     // completes the match across feeds
  out += f.feed("After.\n")
  out += f.drain()
  #expect(out == "Draak gossips.After.\n")   // gag collapses the gossip line into what follows
}

@Test func noNewlineTailIsNotGivenAnExtraNewline() {
  var f = BufferDeleteFilter()
  f.rules = [rule(#"\n^\n^kxwq_hud.*"#, gag: true)]
  let out = run(&f, ["a\n", "b\n", "HP>"])   // "HP>" has no trailing newline
  #expect(out == "a\nb\nHP>")
}
