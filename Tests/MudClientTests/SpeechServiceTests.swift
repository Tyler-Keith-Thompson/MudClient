import Foundation
import Testing

@testable import MudClient

// MARK: - Test doubles

/// A fake utterance the tests fully control: it records that it started speaking, then blocks in
/// `wait()` on a per-instance semaphore until the test releases it (or `cancel()` unblocks it). This
/// lets a single-threaded test drive the service's FIFO worker deterministically.
private final class FakeUtterance: SpeechUtterance {
    let text: String
    private let onStart: (FakeUtterance) -> Void
    private let gate = DispatchSemaphore(value: 0)
    private(set) var cancelled = false

    init(text: String, onStart: @escaping (FakeUtterance) -> Void) {
        self.text = text
        self.onStart = onStart
    }
    func wait() {
        onStart(self)          // record "started speaking THIS text" in dequeue order
        gate.wait()            // block until released or cancelled
    }
    func cancel() { cancelled = true; gate.signal() }
    func release() { gate.signal() }
}

/// Thread-safe recorder of the order utterances began speaking.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [FakeUtterance] = []
    private let bumped = DispatchSemaphore(value: 0)
    func record(_ u: FakeUtterance) { lock.lock(); items.append(u); lock.unlock(); bumped.signal() }
    var spokenText: [String] { lock.lock(); defer { lock.unlock() }; return items.map(\.text) }
    var utterances: [FakeUtterance] { lock.lock(); defer { lock.unlock() }; return items }
    /// Block until at least `n` utterances have started (or time out) — makes ordering deterministic.
    func waitForCount(_ n: Int, timeout: TimeInterval = 2) {
        let deadline = Date().addingTimeInterval(timeout)
        while spokenText.count < n, Date() < deadline {
            _ = bumped.wait(timeout: .now() + 0.05)
        }
    }
}

// MARK: - Queue behaviour

@Test func speaksFIFOAndDropsOldestOverBacklog() {
    let rec = Recorder()
    let service = SpeechService(maxBacklog: 3,
                                makeUtterance: { args in FakeUtterance(text: args.last ?? "", onStart: rec.record) },
                                voiceListing: { "" })
    service.speak(text: "1")
    rec.waitForCount(1)                 // "1" is now in flight (blocked in wait())

    // With "1" in flight, enqueue four more. Backlog cap is 3, so when "5" arrives the OLDEST queued
    // ("2") is dropped: queue becomes [3, 4, 5].
    for t in ["2", "3", "4", "5"] { service.speak(text: t) }

    // Release everything (4 that will actually speak: 1, 3, 4, 5).
    for u in rec.utterances { u.release() }              // release "1"
    rec.waitForCount(2); for u in rec.utterances { u.release() }
    rec.waitForCount(3); for u in rec.utterances { u.release() }
    rec.waitForCount(4); for u in rec.utterances { u.release() }

    #expect(rec.spokenText == ["1", "3", "4", "5"])      // FIFO order, "2" dropped
}

@Test func stopFlushesQueueAndCancelsCurrent() {
    let rec = Recorder()
    let service = SpeechService(maxBacklog: 8,
                                makeUtterance: { args in FakeUtterance(text: args.last ?? "", onStart: rec.record) },
                                voiceListing: { "" })
    service.speak(text: "a")
    rec.waitForCount(1)                 // "a" in flight
    service.speak(text: "b")
    service.speak(text: "c")

    service.stop()                      // flush b,c and cancel a

    // Give the worker a moment to settle; nothing new should start speaking.
    Thread.sleep(forTimeInterval: 0.2)
    #expect(rec.spokenText == ["a"])                    // only the in-flight one ever started
    #expect(rec.utterances.first?.cancelled == true)     // and it was cancelled
}

// MARK: - Voice listing

@Test func parseVoicesReadsNameAndLocaleAndFiltersEnglish() {
    // Canned `say -v ?` output: names with spaces/parens, mixed locales, a comment column.
    let canned = """
    Alex                en_US    # Most people recognize me by my voice.
    Samantha            en_US    # Hello, my name is Samantha.
    Daniel              en_GB    # Hello, my name is Daniel.
    Ting-Ting           zh_CN    # 你好，我叫Ting-Ting。
    Grandma (English (UK))  en_GB    # Hi, I'm Grandma.
    """
    let all = SpeechService.parseVoices(canned)
    #expect(all.contains(SpeechService.Voice(name: "Alex", locale: "en_US")))
    #expect(all.contains(SpeechService.Voice(name: "Samantha", locale: "en_US")))
    #expect(all.contains(SpeechService.Voice(name: "Ting-Ting", locale: "zh_CN")))
    #expect(all.contains(SpeechService.Voice(name: "Grandma (English (UK))", locale: "en_GB")))

    // The default (English-only) filter drops the zh_CN voice.
    let service = SpeechService(voiceListing: { canned })
    let en = service.voices()
    #expect(en.allSatisfy { $0.locale.hasPrefix("en") })
    #expect(!en.contains { $0.name == "Ting-Ting" })
    #expect(en.contains { $0.name == "Daniel" })
    #expect(service.voices(all: true).contains { $0.name == "Ting-Ting" })
}

@Test func speakIgnoresEmptyText() {
    let rec = Recorder()
    let service = SpeechService(makeUtterance: { args in FakeUtterance(text: args.last ?? "", onStart: rec.record) },
                                voiceListing: { "" })
    service.speak(text: "   ")           // whitespace only
    Thread.sleep(forTimeInterval: 0.1)
    #expect(rec.spokenText.isEmpty)
}
