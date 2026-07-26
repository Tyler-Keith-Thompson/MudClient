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

private func run(_ f: inout BufferRewriteFilter, _ texts: [String]) -> String {
  var out = ""
  for t in texts { out += f.feed(t) }
  out += f.drain()
  return out
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

// Serialized: these share the cached Container.scriptInterpreter, so run them one at a time.
@Suite(.serialized) struct GagPlusReplacePipeline {
  private func runPipeline(_ setup: (LuaScriptEngine) -> Void, _ chunks: [String]) async throws -> String {
    try await withTestContainer {
      Container.scriptInterpreter.register { ScriptInterpreter() }
      Container.transcriptStore.register { TranscriptStore() }
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
    let chunks = b64.split(separator: "\n").compactMap { Data(base64Encoded: String($0)) }
    func run(gag: Bool) async throws -> String {
      return try await withTestContainer {
        Container.terminalService.register { TerminalService() }
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
}

