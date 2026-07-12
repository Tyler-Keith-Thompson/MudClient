//
//  DispatchBundleTests.swift
//  MudClientTests
//
//  The `#claude` context bundle: feedback + a timestamped, interleaved (you / lua / srv) transcript
//  written to a /tmp folder for a Claude Code session to read.
//

import Foundation
import Testing
import DependencyInjection
@testable import MudClient

@Test func dispatchBundleWritesFeedbackAndInterleavedTranscript() throws {
  try withTestContainer {
    let sharedStore = TranscriptStore()
    Container.transcriptStore.register { sharedStore }
    let store = Container.transcriptStore()
    let tag = "zzq\(Int(Date().timeIntervalSince1970))"   // unique marker so we read back OUR lines
    store.recordSent("kill \(tag)", origin: .user)
    store.recordSent("cast '\(tag)bolt'", origin: .script)
    store.recordReceived("The \(tag) dies.")

    let feedback = "the \(tag) sac fires one tick early"
    let bundle = try #require(DispatchBundle.build(feedback: feedback))

    #expect(FileManager.default.fileExists(atPath: bundle.dir.path))
    let md = try String(contentsOf: bundle.markdown, encoding: .utf8)

    // Feedback is present, and each origin is labeled and carries its text — interleaved on one timeline.
    #expect(md.contains(feedback))
    #expect(md.contains("you  kill \(tag)"))
    #expect(md.contains("lua  cast '\(tag)bolt'"))
    #expect(md.contains("srv  The \(tag) dies."))

    try? FileManager.default.removeItem(at: bundle.dir)
  }
}

@Test func dispatchBundleStripsAnsiFromTranscript() throws {
  try withTestContainer {
    let sharedStore = TranscriptStore()
    Container.transcriptStore.register { sharedStore }
    let store = Container.transcriptStore()
    let tag = "ansi\(Int(Date().timeIntervalSince1970))"
    store.recordReceived("A \u{1B}[31mfierce \(tag)\u{1B}[0m snarls.")

    let bundle = try #require(DispatchBundle.build(feedback: "check \(tag)"))
    let md = try String(contentsOf: bundle.markdown, encoding: .utf8)

    #expect(md.contains("A fierce \(tag) snarls."))
    #expect(!md.contains("\u{1B}["))   // no raw escape sequences leaked into the bundle

    try? FileManager.default.removeItem(at: bundle.dir)
  }
}
