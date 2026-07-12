//
//  ClaudeInboxWatcherTests.swift
//  MudClientTests
//
//  The return leg of the `#claude`/`muddispatch` channel: a reply JSON dropped in the inbox → a styled
//  `↙ claude` line echoed once, then archived. Pure parse+format is tested directly; the process-once
//  behavior uses a temp inbox dir (the watcher takes both as injectable seams — no test sniffing).
//

import Foundation
import Testing
@testable import MudClient

// MARK: - Pure parse + format

@Test func claudeReplyRendersMessageOnlyLine() {
    let reply = ClaudeReply(message: "reload done, corpse timing fixed", action: "", ts: "2026-07-12T00:00:00Z")
    // Bold bright cyan, whole line coloured so it pops out of the game stream.
    #expect(ClaudeReplyRenderer.render(reply) == "\u{1B}[1;96m↙ claude  reload done, corpse timing fixed\u{1B}[0m")
}

@Test func claudeReplyRendersActionOnSecondAlignedLine() {
    let reply = ClaudeReply(message: "fix applied", action: "#reload", ts: "")
    let expected = "\u{1B}[1;96m↙ claude  fix applied\u{1B}[0m"
        + "\n          \u{1B}[1;96m→ run #reload\u{1B}[0m"
    #expect(ClaudeReplyRenderer.render(reply) == expected)
}

@Test func claudeReplyParsesFullPayload() throws {
    let json = #"{"message":"done","action":"just run","ts":"2026-07-12T01:02:03Z"}"#
    let reply = try #require(ClaudeReplyRenderer.parse(Data(json.utf8)))
    #expect(reply == ClaudeReply(message: "done", action: "just run", ts: "2026-07-12T01:02:03Z"))
}

@Test func claudeReplyParseDefaultsMissingActionAndTs() throws {
    let reply = try #require(ClaudeReplyRenderer.parse(Data(#"{"message":"hi"}"#.utf8)))
    #expect(reply.action == "")
    #expect(reply.ts == "")
}

@Test func claudeReplyParseRejectsCorruptOrEmpty() {
    #expect(ClaudeReplyRenderer.parse(Data("not json".utf8)) == nil)
    #expect(ClaudeReplyRenderer.parse(Data("{}".utf8)) == nil)                 // no message
    #expect(ClaudeReplyRenderer.parse(Data(#"{"message":"   "}"#.utf8)) == nil) // blank message
}

// MARK: - Process-once-then-archive (temp inbox)

private func makeTempInbox() -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("claude-inbox-test-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test func drainEchoesEachReplyOnceThenArchives() throws {
    let dir = makeTempInbox()
    defer { try? FileManager.default.removeItem(at: dir) }

    let payload = #"{"message":"built ok","action":"just run","ts":"2026-07-12T00:00:00Z"}"#
    let file = dir.appendingPathComponent("100-abcd.json")
    try payload.write(to: file, atomically: true, encoding: .utf8)

    var emitted: [String] = []
    let watcher = ClaudeInboxWatcher(inboxDir: dir, emit: { emitted.append($0) })

    // First pass: one file processed and echoed with both lines.
    #expect(watcher.drain() == 1)
    #expect(emitted.count == 1)
    #expect(emitted[0].contains("↙ claude"))
    #expect(emitted[0].contains("built ok"))
    #expect(emitted[0].contains("→ run just run"))

    // The source file is gone (moved into archive/) — so a second pass echoes nothing.
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("archive/100-abcd.json").path))
    #expect(watcher.drain() == 0)
    #expect(emitted.count == 1)
}

@Test func drainArchivesCorruptFileWithoutCrashingOrEmitting() throws {
    let dir = makeTempInbox()
    defer { try? FileManager.default.removeItem(at: dir) }

    let bad = dir.appendingPathComponent("200-dead.json")
    try "{ this is not json".write(to: bad, atomically: true, encoding: .utf8)

    var emitted: [String] = []
    let watcher = ClaudeInboxWatcher(inboxDir: dir, emit: { emitted.append($0) })

    #expect(watcher.drain() == 1)          // counted as processed
    #expect(emitted.isEmpty)               // but nothing echoed
    #expect(!FileManager.default.fileExists(atPath: bad.path))
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("archive/200-dead.json").path))
}

@Test func drainProcessesMultipleFilesInNameOrder() throws {
    let dir = makeTempInbox()
    defer { try? FileManager.default.removeItem(at: dir) }

    try #"{"message":"first"}"#.write(to: dir.appendingPathComponent("1-a.json"), atomically: true, encoding: .utf8)
    try #"{"message":"second"}"#.write(to: dir.appendingPathComponent("2-b.json"), atomically: true, encoding: .utf8)

    var emitted: [String] = []
    let watcher = ClaudeInboxWatcher(inboxDir: dir, emit: { emitted.append($0) })
    #expect(watcher.drain() == 2)
    #expect(emitted.count == 2)
    #expect(emitted[0].contains("first"))
    #expect(emitted[1].contains("second"))
}
