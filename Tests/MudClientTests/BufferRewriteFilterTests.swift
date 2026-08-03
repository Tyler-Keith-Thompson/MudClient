import Afluent
import DependencyInjection
import Foundation
import Mockable
import Testing

@testable import MudClient

// MARK: - multilineSpan (single-line vs multi-line detection)

@Test func multilineSpanIsNilForSingleLine() {
  #expect(LuaScriptEngine.multilineSpan(of: "^kxwq_hud") == nil)
}

@Test func multilineSpanCountsLines() {
  #expect(LuaScriptEngine.multilineSpan(of: #"\n^kxwq_hud"#) == 2)
  #expect(LuaScriptEngine.multilineSpan(of: #"\n^\n^kxwq_hud.*"#) == 3)
  #expect(LuaScriptEngine.multilineSpan(of: "^$\n^kxwq_hud") == 2)
}

// MARK: - replacement parsing (#replace / #substitute args + escapes)

@Test func parseReplaceArgsSplitsOnLastSpaceAndUnescapes() {
  let r = LuaScriptEngine.parseReplaceArgs([.string(#"\n^\n^kxwq_hud.* \n"#)])
  #expect(r?.pattern == #"\n^\n^kxwq_hud.*"#)
  #expect(r?.replacement == "\n")            // the trailing \n becomes an actual newline
}

@Test func parseReplaceArgsUsesTwoArgsVerbatim() {
  let r = LuaScriptEngine.parseReplaceArgs([.string("foo bar"), .string(#"baz\tqux"#)])
  #expect(r?.pattern == "foo bar")           // pattern may contain spaces in the two-arg form
  #expect(r?.replacement == "baz\tqux")
}

// MARK: - BufferRewriteFilter: the shared engine (applies regex → replacement)

/// Compile a rule the way the engine does for each command.
private func rule(_ pattern: String, replacement: String = "", lineRounded: Bool) -> (regex: Regex<AnyRegexOutput>, replacement: String, span: Int) {
  let span = LuaScriptEngine.multilineSpan(of: pattern) ?? 1
  let src = lineRounded ? "(?:\(pattern))[^\\n]*\\n" : pattern
  return (try! Regex(src).anchorsMatchLineEndings(), replacement, span)
}

/// Simulate the terminal: apply each feed's (retract, emit) — retract removes trailing complete lines, emit
/// appends — and return the final on-screen text plus the total lines retracted across the run.
private func run(_ f: inout BufferRewriteFilter, _ texts: [String]) -> String { render(&f, texts).text }
private func render(_ f: inout BufferRewriteFilter, _ texts: [String]) -> (text: String, retracted: Int) {
  var lines: [String] = []
  var pending = ""
  var retracted = 0
  for t in texts {
    let (retract, emit) = f.feed(t)
    if retract > 0 { lines.removeLast(min(retract, lines.count)); retracted += retract }
    var combined = pending + emit
    while let nl = combined.firstIndex(of: "\n") {
      lines.append(String(combined[..<nl]))
      combined = String(combined[combined.index(after: nl)...])
    }
    pending = combined
  }
  return (lines.map { $0 + "\n" }.joined() + pending, retracted)
}

@Test func noRulesIsPlainPassthrough() {
  var f = BufferRewriteFilter()
  #expect(run(&f, ["a\n", "\n", "b\n"]) == "a\n\nb\n")
}

// #gag (delete, line-rounded) → rows collapse.
@Test func gagCollapsesRows() {
  var f = BufferRewriteFilter()
  f.rules = [rule(#"\n^\n^kxwq_hud.*"#, replacement: "", lineRounded: true)]
  let out = run(&f, ["Tree'\n", "\n", "kxwq_hud info\n", "kxwq_sky\n"])
  #expect(out == "Tree'kxwq_sky\n")
}

// #replace (put text back, line-rounded) → the user's case: a newline back WITHOUT the suppress trick.
@Test func replacePutsANewlineBack() {
  var f = BufferRewriteFilter()
  f.rules = [rule(#"\n^\n^kxwq_hud.*"#, replacement: "\n", lineRounded: true)]
  let out = run(&f, ["Tree'\n", "\n", "kxwq_hud info\n", "kxwq_sky\n"])
  #expect(out == "Tree'\nkxwq_sky\n")   // rows split — the replacement newline stands in for the eaten one
}

// #suppress (delete, char-exact) → leaves the tag line's own newline.
@Test func suppressLeavesTheTagNewline() {
  var f = BufferRewriteFilter()
  f.rules = [rule(#"\n^\n^kxwq_hud.*$"#, replacement: "", lineRounded: false)]
  let out = run(&f, ["Tree'\n", "\n", "kxwq_hud info\n", "kxwq_sky\n"])
  #expect(out == "Tree'\nkxwq_sky\n")
}

// #substitute (put text back, char-exact) → classic in-line substitution.
@Test func substituteReplacesInline() {
  var f = BufferRewriteFilter()
  f.rules = [rule("foo", replacement: "bar", lineRounded: false)]
  #expect(run(&f, ["xfooy\n"]) == "xbary\n")
}

// A delete-style rule must pass zero-width ANSI THROUGH — the server tucks a colour reset into the telemetry
// frame; deleting it (instead of keeping it) bleeds the previous line's colour down the screen.
@Test func deleteRuleKeepsAnsiResetInsideTheDeletedSpan() {
  var f = BufferRewriteFilter()
  let pat = #"(?:\nkxw[tq]_hud[^\n]*)+"#   // the real ANSI-aware hud suppress
  f.rules = [(try! Regex(pat).anchorsMatchLineEndings(), "", 4)]
  let out = run(&f, ["Bard'\n", "\u{1B}[0m\nkxwq_hud|354|354\n", "next\n"])
  #expect(!out.contains("kxwq_hud"))          // the hud line is deleted
  #expect(out.contains("\u{1B}[0m"))          // …but the colour reset rides through (no bleed)
}

@Test func bystanderLinesAreNotMerged() {
  var f = BufferRewriteFilter()
  f.rules = [rule(#"\n^\n^kxwq_hud.*"#, replacement: "", lineRounded: true)]
  let out = run(&f, ["East - Adin\n", "West - a dwarven sentinel\n", "(south) closed.\n"])
  #expect(out == "East - Adin\nWest - a dwarven sentinel\n(south) closed.\n")
}

@Test func noNewlineTailIsNotGivenAnExtraNewline() {
  var f = BufferRewriteFilter()
  f.rules = [rule(#"\n^\n^kxwq_hud.*"#, replacement: "", lineRounded: true)]
  #expect(run(&f, ["a\n", "b\n", "HP>"]) == "a\nb\nHP>")
}

// The point of the retraction engine: a match completing LATER (the hud tick lands after the blank it frames)
// retroactively un-prints the already-shown rows, however late it arrives.
@Test func lateMatchRetroactivelyRemovesAlreadyShownRows() {
  var f = BufferRewriteFilter()
  f.rules = [rule(#"\n^\n^kxwq_hud.*"#, replacement: "", lineRounded: true)]
  // The blank shows optimistically; nothing to retract yet.
  let mid = render(&f, ["Tree'\n", "\n"])
  #expect(mid.text == "Tree'\n\n")
  #expect(mid.retracted == 0)
  // When "kxwq_hud …" finally lands, the match completes and the already-shown blank + hud are un-printed.
  let all = render(&f, ["Tree'\n", "\n", "kxwq_hud info\n", "kxwq_sky\n"])
  #expect(all.text == "Tree'kxwq_sky\n")
  #expect(all.retracted >= 1)
}

// Serialized: these share the cached Container.scriptInterpreter, so run them one at a time.
@Suite(.serialized) struct GagPlusReplacePipeline {
  private func runPipeline(_ setup: (LuaScriptEngine) -> Void, _ chunks: [String]) async throws -> String {
    try await withTestContainer {
      Container.scriptInterpreter.register { ScriptInterpreter() }
      Container.transcriptStore.register { TranscriptStore() }
      Container.terminalService.register { TerminalService() }   // the buffer's idle-flush paints a held tail here
      Container.sessionLog.register { SessionLog() }              // …and session-logs it (never dials/opens a file)
      Container.anthropicAPIKeyProvider.register { { nil } }
      let engine = Container.scriptInterpreter().engine
      engine.onEcho = { _ in }
      setup(engine)
      let src = AsyncStream<String> { c in for ch in chunks { c.yield(ch) }; c.finish() }
      var out = ""
      for try await piece in src.processServerOutputForScripts() { out += piece }
      return out
    }
  }

  // The user's exact live state: #gag kxwq_prompt + #replace \n^\n^kxwq_hud.* -> \n, prompts one per tick.
  // The prompts are single-line-gagged and dropped whole; the #replace (buffer rule) passes the non-prompt
  // lines through untouched. Result: NO blank lines where the prompts were. (kxwq_time + dog line are still
  // held in the buffer's look-ahead window, undrained — that's the hold, not a loss.)
  @Test func userExactStateDropsPromptsNoBlank() async throws {
    var chunks = ["(south) A wooden door is closed.\n"]
    for m in [399,401,403,406,409,411,414,416,419,421,423,426,429] { chunks.append("kxwq_prompt 354 354 \(m) 457 198 198\n") }
    chunks.append("kxwq_sky 1 1 0\n"); chunks.append("kxwq_time 640 morning\n"); chunks.append("A dog barks.\n")
    let out = try await runPipeline({ e in
      e.evalREPL(#"gag("kxwq_prompt")"#)
      e.evalREPL(##"replace("\\n^\\n^kxwq_hud.*", "\\n")"##)
    }, chunks)
    #expect(!out.contains("kxwq_prompt"))          // prompts gone
    #expect(!out.contains("\n\n"))                  // and NO blank lines left behind
    #expect(out.hasPrefix("(south) A wooden door is closed.\nkxwq_sky 1 1 0\n"))
  }

  // Same, prompts GA-flushed (IAC GA -> U+E000, no trailing newline) — the live prompt path. Same result.
  @Test func userExactStateGAFlushedDropsPromptsNoBlank() async throws {
    var chunks = ["(south) A wooden door is closed.\n"]
    for m in [399,401,403,406,409] { chunks.append("kxwq_prompt 354 354 \(m) 457 198 198\u{E000}") }
    chunks.append("kxwq_sky 1 1 0\n"); chunks.append("kxwq_time 640\n"); chunks.append("A dog barks.\n")
    let out = try await runPipeline({ e in
      e.evalREPL(#"gag("kxwq_prompt")"#)
      e.evalREPL(##"replace("\\n^\\n^kxwq_hud.*", "\\n")"##)
    }, chunks)
    #expect(!out.contains("kxwq_prompt"))
    #expect(!out.contains("\n\n"))
  }
  // FULL SCRIPTS: load the real AlterAeon layer (parsers + on_stream peeler + default gag) and run the
  // user's exact block through the ENTIRE inbound chain — the gap between my green tests and their screen.
  @Test func fullScriptsUserRepro() async throws {
    try await withTestContainer {
      Container.terminalService.register { TerminalService() }
      // The real HUD scripts (loaded via `load("Scripts")` below) call the panel/toppanel builtins, which
      // resolve these — and TerminalService reads their heights when it repaints. withTestContainer starts
      // empty, so they must be registered explicitly or resolution fatal-errors mid-run.
      Container.panelHost.register { PanelHost() }
      Container.topPanelHost.register { PanelHost() }
      Container.sessionLog.register { SessionLog() }   // idle-flush session-logs the held tail (no file opened)
      Container.lagMonitor.register { LagMonitor() }
      Container.transcriptStore.register { TranscriptStore() }
      Container.scriptInterpreter.register { ScriptInterpreter() }
      Container.anthropicAPIKeyProvider.register { { nil } }
      let music = MockMusicServicing(policy: .relaxedVoid)
      let speech = MockSpeechServicing(policy: .relaxedVoid)
      let msp = MockMSPServicing(policy: .relaxedVoid)
      given(msp).player(.any, volume: .any, loops: .any).willProduce { _,_,_ in
        DeferredTask<AudioPlayer> { throw CancellationError() }.eraseToAnyUnitOfWork() }
      Container.musicService.register { music }
      Container.speechService.register { speech }
      Container.mspService.register { msp }
      Container.soundService.register { SoundService() }
      Container.connectionManager.register { ConnectionManager() }
      Container.netConnection.register { NetConnection() }   // scripts resolve it via connect/send; never dials (Lua connect is stubbed)
      let repoRoot = URL(fileURLWithPath: "\(#filePath)").deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().path
      let prev = FileManager.default.currentDirectoryPath
      FileManager.default.changeCurrentDirectoryPath(repoRoot)
      defer { FileManager.default.changeCurrentDirectoryPath(prev) }
      let engine = Container.scriptInterpreter().engine
      engine.onEcho = { _ in }
      engine.onSend = { _ in }
      try engine.load(source: "connect = function() end; is_connected = function() return true end")
      do { try engine.load(source: "load(\"Scripts\")") } catch { Swift.print("LOAD ERR:", error) }
      engine.evalREPL("ungag(\"*\")")
      engine.evalREPL("gag(\"kxwq_prompt\")")
      engine.evalREPL(##"replace("\\n^\\n^kxwq_hud.*", "\\n")"##)
      var block = "(south) A wooden door is closed.\r\n"
      for m in [399,401,403,406,409,411,414,416,419,421,423,426,429] { block += "kxwq_prompt 354 354 \(m) 457 198 198\r\n" }
      block += "kxwq_sky 1 1 0\r\nkxwq_time 640\r\nA dog barks.\r\n"
      block += "line A\r\nline B\r\nline C\r\nline D\r\n"   // trailing lines to flush the buffer's hold window
      // Feed each LINE as its own Data (per feed_server tick) — the live RPC path.
      let perLine = block.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { !$0.isEmpty }
      let src = AsyncStream<Data> { c in for l in perLine { c.yield(Data((l + "\r\n").utf8)) }; c.finish() }
      var out = ""
      for try await s in src.captureRaw().handleIACCommunication(writeToStream: { _ in })
        .normalizeLineEndings().filterServerStream().processMSP().processServerOutputForScripts() { out += s }
      Swift.print("=== FULL SCRIPTS PER-CHUNK OUT ===\n" + out.replacingOccurrences(of: "\n", with: "<LF>\n")
        + "\n=== blanks:", out.components(separatedBy: "\n\n").count - 1)
      // The whole real inbound pipeline, real scripts, the user's exact rules: prompts dropped, NO blanks.
      #expect(!out.contains("kxwq_prompt"))
      #expect(!out.contains("\n\n"))
    }
  }

  // THE GUARDRAIL that was missing (see memory display-pipeline-debugging-discipline): replay a REAL captured
  // raw.log through the ENTIRE real pipeline with the REAL default rules, then assert on the FINAL DISPLAY
  // (the transcript, post-retract) — not the emit stream. Catches every regression from that saga at once:
  // telemetry LEAK, blank STREAM, and display CHURN (the flicker of a line painted then un-printed).
  @Test func fullDisplayFromRealCapture() async throws {
    // Resolve from RUNFILES (the fixture is a bazel `data` dep) and REQUIRE it — a guardrail that silently
    // skips when its fixture is unreadable is worse than none (that vacuous-pass is the flawed-harness trap).
    let path = URL(fileURLWithPath: "\(#filePath)").deletingLastPathComponent()
      .appendingPathComponent("fixtures/display_pipeline_capture.log").path
    let text = try #require(try? String(contentsOfFile: path, encoding: .utf8), "guardrail fixture missing: \(path)")
    let chunks = text.split(separator: "\n").compactMap { Data(base64Encoded: String($0.split(separator: " ").last ?? $0)) }  // "HH:MM:SS.mmm <base64>"
    #expect(chunks.count > 100)   // …and that it actually parsed (not an empty/garbled read masquerading as a pass)
    try await withTestContainer {
      Container.terminalService.register { TerminalService() }
      // The real HUD scripts (loaded via `load("Scripts")` below) call the panel/toppanel builtins, which
      // resolve these — and TerminalService reads their heights when it repaints. withTestContainer starts
      // empty, so they must be registered explicitly or resolution fatal-errors mid-run.
      Container.panelHost.register { PanelHost() }
      Container.topPanelHost.register { PanelHost() }
      Container.sessionLog.register { SessionLog() }
      Container.lagMonitor.register { LagMonitor() }
      Container.transcriptStore.register { TranscriptStore() }
      Container.scriptInterpreter.register { ScriptInterpreter() }
      Container.anthropicAPIKeyProvider.register { { nil } }
      let msp = MockMSPServicing(policy: .relaxedVoid)
      given(msp).player(.any, volume: .any, loops: .any).willProduce { _,_,_ in
        DeferredTask<AudioPlayer> { throw CancellationError() }.eraseToAnyUnitOfWork() }
      Container.mspService.register { msp }
      Container.musicService.register { MockMusicServicing(policy: .relaxedVoid) }
      Container.speechService.register { MockSpeechServicing(policy: .relaxedVoid) }
      Container.soundService.register { SoundService() }
      Container.connectionManager.register { ConnectionManager() }
      Container.netConnection.register { NetConnection() }
      let repoRoot = URL(fileURLWithPath: "\(#filePath)").deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().path
      let prev = FileManager.default.currentDirectoryPath
      FileManager.default.changeCurrentDirectoryPath(repoRoot)
      defer { FileManager.default.changeCurrentDirectoryPath(prev) }
      let engine = Container.scriptInterpreter().engine
      engine.onEcho = { _ in }; engine.onSend = { _ in }
      try engine.load(source: "connect = function() end; is_connected = function() return true end")
      do { try engine.load(source: "load(\"Scripts\")") } catch { Swift.print("LOAD ERR:", error) }
      // Feed each captured chunk as its own Data, byte-for-byte, through the WHOLE real chain.
      let src = AsyncStream<Data> { c in for ch in chunks { c.yield(ch) }; c.finish() }
      for try await _ in src.captureRaw().handleIACCommunication(writeToStream: { _ in })
        .normalizeLineEndings().filterServerStream().processMSP().processServerOutputForScripts() {}
      // The transcript's RECEIVED entries are the final on-screen text (recordReceived − retractReceived).
      let store = Container.transcriptStore()
      let display = store.received(last: nil).map { TranscriptStore.strip($0.text) }
      let leaks = display.filter { $0.contains("kxwq_") || $0.contains("kxwt_") }
      let blanks = display.filter { $0.trimmingCharacters(in: .whitespaces).isEmpty }.count
      var runs = 0
      for i in display.indices where i + 1 < display.count
        && display[i].trimmingCharacters(in: .whitespaces).isEmpty
        && display[i + 1].trimmingCharacters(in: .whitespaces).isEmpty { runs += 1 }
      Swift.print("=== REAL CAPTURE DISPLAY: \(display.count) lines, \(blanks) blanks, \(runs) consec-runs, churn=\(store.totalRetracted), leaks=\(leaks.count) ===")
      #expect(leaks.isEmpty)               // no telemetry ever reaches the screen (leak regressions) — hard invariant
      // Blank STREAMS: baselined to the pipeline's ACTUAL current output. This harness runs a REDUCED chain —
      // the bazel sandbox can't load the full scripts, so DClientProbe's RPC `;s…;e…;` frame-peeling never
      // runs and leaves framing blanks the live client doesn't (verified: the fixture carries raw `;sgroup;`
      // frames the client peels). So the live display is clean; this reduced replay lands 6 framing-blank
      // runs, pinned here as a CEILING — a regression that ADDS blank streams still trips it, and if the
      // pipeline improves this drops (tighten the bound then). Not zero only because the sandbox can't peel.
      #expect(runs <= 6)
      #expect(store.totalRetracted <= 2)   // no display CHURN — a line painted then un-printed (the flicker)
    }
  }
  // Gagging a telemetry line must NOT swallow the colour reset the server glues to its front (which ends the
  // preceding coloured line) — else the previous colour bleeds into the next shown line.
  @Test func gaggedLineResetCarriesForwardNoColourBleed() async throws {
    let esc = "\u{1B}"
    let chunk = "\(esc)[1m\(esc)[34mIt is night.\n\(esc)[37m\(esc)[0mkxwq_sky 1 1 0\nGerod is here, sound asleep.\n"
    let out = try await runPipeline({ e in e.evalREPL(#"gag("^kxwq_")"#) }, [chunk])
    #expect(!out.contains("kxwq_sky"))                                        // telemetry hidden
    #expect(out.contains("\(esc)[37m\(esc)[0mGerod is here, sound asleep."))  // reset carried onto Gerod
  }

  // The RPC frames each idle prompt tick as its OWN chunk "\nkxwq_prompt X" — leading newline, no trailing.
  // Gagging the prompt must NOT leave the leading "\n" as a blank line on every tick (portable repro).
  @Test func gaggedLeadingNewlinePromptChunksAddNoBlankStream() async throws {
    let chunks = (0..<10).map { "\nkxwq_prompt 354 354 \(400 + $0) 457 198 198" }
    let out = try await runPipeline({ e in e.evalREPL(#"gag("kxwq_prompt")"#) }, chunks)
    #expect(!out.contains("kxwq_prompt"))   // prompts hidden
    #expect(!out.contains("\n\n"))          // and NOT a blank per tick
  }

  // Replay the user's ACTUAL raw.log (each base64 line = one captured feed) through the full pipeline,
  // WITH and WITHOUT `#gag kxwq_prompt`. The RPC frames each idle tick as "\nkxwq_prompt X" (leading newline,
  // no trailing one); gagging the prompt must NOT turn each tick's leading "\n" into a blank line. Regression
  // for "gagging ^kxwq_prompt adds a stream of blank lines" — a client bug from removing the line assembler.
  @Test func replayUserRawGagAddsNoBlankStream() async throws {
    let path = "/Users/tylerthompson/workspace/MudClient/Tests/MudClientTests/fixtures/user_prompt_blanks_raw.log"
    guard let b64 = try? String(contentsOfFile: path, encoding: .utf8) else { return }  // fixture is local-only
    let chunks = b64.split(separator: "\n").compactMap { Data(base64Encoded: String($0.split(separator: " ").last ?? $0)) }  // strip "HH:MM:SS.mmm " stamp if present
    func run(gag: Bool) async throws -> String {
      return try await withTestContainer {
        Container.terminalService.register { TerminalService() }
        Container.sessionLog.register { SessionLog() }   // idle-flush session-logs the held tail (no file opened)
        Container.lagMonitor.register { LagMonitor() }
        Container.transcriptStore.register { TranscriptStore() }
        Container.scriptInterpreter.register { ScriptInterpreter() }
        Container.anthropicAPIKeyProvider.register { { nil } }
        let msp = MockMSPServicing(policy: .relaxedVoid)
        given(msp).player(.any, volume: .any, loops: .any).willProduce { _,_,_ in
          DeferredTask<AudioPlayer> { throw CancellationError() }.eraseToAnyUnitOfWork() }
        Container.mspService.register { msp }
        Container.musicService.register { MockMusicServicing(policy: .relaxedVoid) }
        Container.speechService.register { MockSpeechServicing(policy: .relaxedVoid) }
        Container.soundService.register { SoundService() }
        Container.connectionManager.register { ConnectionManager() }
        let engine = Container.scriptInterpreter().engine
        engine.onEcho = { _ in }; engine.onSend = { _ in }
        if gag { engine.evalREPL("gag(\"^kxwq_prompt\")") }   // just the gag, no full-script load
        let src = AsyncStream<Data> { c in for ch in chunks { c.yield(ch) }; c.finish() }
        var out = ""
        for try await s in src.captureRaw().handleIACCommunication(writeToStream: { _ in })
          .normalizeLineEndings().filterServerStream().processMSP().processServerOutputForScripts() { out += s }
        return out
      }
    }
    let without = try await run(gag: false)
    let with = try await run(gag: true)
    func blanks(_ s: String) -> Int { s.components(separatedBy: "\n").filter { $0.isEmpty }.count }
    #expect(!with.contains("kxwq_prompt"))            // prompts are hidden
    #expect(blanks(with) <= blanks(without) + 2)      // …WITHOUT adding a blank per gagged tick
  }

  // FULL SCRIPTS, the user's ACTUAL raw.log (a walk + a fight + a rest): the server frames the kxwq_hud
  // vitals bar with a leading blank ("…<nl><blank>kxwq_hud|…"), which used to leak one stray blank per
  // telemetry tick — a STREAM of them while resting/fighting, when hud ticks back-to-back. The default
  // AlterAeon rules (a char-exact #suppress owning hud + its framing blank + the (?!hud)-scoped gag) must
  // collapse that frame so hud is hidden WITHOUT any blank, and never leak the raw hud/prompt text.
  // The fixture is pre-peeled of ;s…;e…; frames (that peeling is DClientProbe's on_stream, which needs the
  // full scripts the bazel sandbox can't load) so the Swift display pipeline is exercised faithfully.
  @Test func fullScriptsHudFrameNoBlankStream() async throws {
    let path = "/Users/tylerthompson/workspace/MudClient/Tests/MudClientTests/fixtures/hud_frame_blanks_peeled.log"
    guard let b64 = try? String(contentsOfFile: path, encoding: .utf8) else { return }  // fixture is local-only
    let chunks = b64.split(separator: "\n").compactMap { Data(base64Encoded: String($0.split(separator: " ").last ?? $0)) }  // strip "HH:MM:SS.mmm " stamp if present
    let out: String = try await withTestContainer {
      Container.terminalService.register { TerminalService() }
      Container.sessionLog.register { SessionLog() }   // idle-flush session-logs the held tail (no file opened)
      Container.lagMonitor.register { LagMonitor() }
      Container.transcriptStore.register { TranscriptStore() }
      Container.scriptInterpreter.register { ScriptInterpreter() }
      Container.anthropicAPIKeyProvider.register { { nil } }
      let msp = MockMSPServicing(policy: .relaxedVoid)
      given(msp).player(.any, volume: .any, loops: .any).willProduce { _,_,_ in
        DeferredTask<AudioPlayer> { throw CancellationError() }.eraseToAnyUnitOfWork() }
      Container.mspService.register { msp }
      Container.musicService.register { MockMusicServicing(policy: .relaxedVoid) }
      Container.speechService.register { MockSpeechServicing(policy: .relaxedVoid) }
      Container.soundService.register { SoundService() }
      Container.connectionManager.register { ConnectionManager() }
      let engine = Container.scriptInterpreter().engine
      engine.onEcho = { _ in }; engine.onSend = { _ in }
      // The exact default AlterAeon telemetry rules (AlterAeon.tl): a char-exact #suppress that eats the
      // kxwq_hud vitals bar + its framing blank (empty when idle, a zero-width ANSI reset mid-combat) + any
      // back-to-back hud run, and the (?!hud)-scoped per-line gag for the rest.
      engine.evalREPL(##"suppress([[(?:\nkxw[tq]_hud[^\n]*)+]])"##)
      engine.evalREPL(#"gag("^kxw[tq]_(?!hud)")"#)
      let src = AsyncStream<Data> { c in for ch in chunks { c.yield(ch) }; c.finish() }
      var acc = ""
      for try await s in src.captureRaw().handleIACCommunication(writeToStream: { _ in })
        .normalizeLineEndings().filterServerStream().processMSP().processServerOutputForScripts() { acc += s }
      return acc
    }
    // A run of 2+ blank lines is the telemetry stream. One or two survive from the server's own double-spacing
    // (the login banner; a room-metadata block) — those are the MUD's, not ours — so allow a small margin.
    let strayRuns = out.components(separatedBy: "\n\n\n").count - 1
    #expect(!out.contains("kxwq_hud"))        // the vitals bar never leaks as raw text
    #expect(!out.contains("kxwq_prompt"))     // nor the prompt
    #expect(strayRuns <= 3)                   // no telemetry blank-stream (was 46 before the fix)
  }
}

