//
//  TranscriptStoreTests.swift
//  MudClientTests
//
//  The session transcript that backs #grep / #sent / #received: a bounded, origin-tagged log of what
//  was sent to and received from the server.
//

import Foundation
import Testing
@testable import MudClient

@Test func transcriptSeparatesSentAndReceivedNewestLast() {
    let t = TranscriptStore()
    t.recordReceived("You see an orc here.")
    t.recordSent("kill orc", origin: .user)
    t.recordReceived("The orc dies.")
    t.recordSent("c icebolt", origin: .script)

    let sent = t.sent(last: nil)
    #expect(sent.map(\.text) == ["kill orc", "c icebolt"])
    #expect(sent.map(\.origin) == [.user, .script])

    let recv = t.received(last: nil)
    #expect(recv.map(\.text) == ["You see an orc here.", "The orc dies."])
    #expect(recv.allSatisfy { $0.origin == nil })
}

@Test func transcriptSentAndReceivedRespectLastN() {
    let t = TranscriptStore()
    for i in 1...5 { t.recordSent("cmd\(i)", origin: .user) }
    for i in 1...5 { t.recordReceived("line\(i)") }
    #expect(t.sent(last: 2).map(\.text) == ["cmd4", "cmd5"])       // last 2, chronological
    #expect(t.received(last: 3).map(\.text) == ["line3", "line4", "line5"])
    #expect(t.sent(last: 99).count == 5)                           // n > available → all
    #expect(t.sent(last: nil).count == 5)                          // nil → all
}

@Test func transcriptGrepIsCaseInsensitiveAcrossBothKindsAndStripsAnsi() {
    let t = TranscriptStore()
    t.recordReceived("A \u{1B}[31mfierce Orc\u{1B}[0m snarls.")     // ANSI around the match
    t.recordSent("look ORC", origin: .user)
    t.recordReceived("A rabbit hops by.")

    let hits = t.grep("orc")
    #expect(hits.count == 2)                                       // matches the received (through ANSI) + the sent
    #expect(hits.contains { $0.kind == .received })
    #expect(hits.contains { $0.kind == .sent && $0.origin == .user })
    #expect(t.grep("rabbit").count == 1)
    #expect(t.grep("dragon").isEmpty)
    #expect(t.grep("").isEmpty)                                    // empty needle matches nothing
}

@Test func transcriptRingDropsOldestPastLimit() {
    let t = TranscriptStore(limit: 3)
    for i in 1...5 { t.recordSent("s\(i)", origin: .user) }
    let all = t.sent(last: nil)
    #expect(all.count == 3)
    #expect(all.map(\.text) == ["s3", "s4", "s5"])                 // s1/s2 evicted
}

@Test func formatTranscriptLabelsByKindAndOrigin() {
    let entries: [TranscriptStore.Entry] = [
        .init(kind: .sent, origin: .user, text: "kill orc"),
        .init(kind: .sent, origin: .script, text: "c icebolt"),
        .init(kind: .received, origin: nil, text: "The orc dies."),
    ]
    let lines = LuaScriptEngine.formatTranscript(entries)
    #expect(lines.count == 3)
    #expect(lines[0].contains("you") && lines[0].hasSuffix("kill orc"))
    #expect(lines[1].contains("lua") && lines[1].hasSuffix("c icebolt"))
    #expect(lines[2].hasSuffix("The orc dies."))
    #expect(!lines[2].contains("you") && !lines[2].contains("lua"))
}
