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

// MARK: - Kokoro backend

/// A fake HTTP synthesizer: returns canned WAV bytes or throws, records the last request, and can block
/// (to simulate an in-flight request) until `cancel()` releases it.
private final class FakeSynthesizer: SpeechSynthesizer, @unchecked Sendable {
    private let lock = NSLock()
    private let result: Result<Data, Error>
    private let block: Bool
    private let gate = DispatchSemaphore(value: 0)
    private let started = DispatchSemaphore(value: 0)
    private(set) var lastText: String?
    private(set) var lastVoice: String?
    private(set) var cancelled = false

    init(result: Result<Data, Error>, block: Bool = false) { self.result = result; self.block = block }

    func synthesize(text: String, voice: String?) throws -> Data {
        lock.lock(); lastText = text; lastVoice = voice; lock.unlock()
        started.signal()
        if block { gate.wait() }                    // simulate a slow, cancellable request
        lock.lock(); let c = cancelled; lock.unlock()
        if c { throw NSError(domain: "cancelled", code: -999) }
        return try result.get()
    }
    func cancel() { lock.lock(); cancelled = true; lock.unlock(); gate.signal() }
    func waitUntilStarted() { started.wait() }
}

/// Thread-safe recorder of the argv arrays passed to a process factory.
private final class ArgLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [[String]] = []
    func add(_ a: [String]) { lock.lock(); items.append(a); lock.unlock() }
    var all: [[String]] { lock.lock(); defer { lock.unlock() }; return items }
}

@Test func kokoroSynthesizesThenPlaysViaAfplay() {
    let rec = Recorder()
    let playLog = ArgLog()
    let synth = FakeSynthesizer(result: .success(Data(count: 200)))
    let service = SpeechService(
        makeUtterance: { args in FakeUtterance(text: args.last ?? "", onStart: rec.record) },   // say
        voiceListing: { "" },
        synthesizer: synth,
        makePlayback: { args in playLog.add(args); return FakeUtterance(text: args.last ?? "", onStart: rec.record) },
        tempWriter: { _ in "/tmp/mudclient_test_tts.wav" })

    service.speak(text: "hello there", voice: "af_heart", backend: .kokoro, sayFallbackVoice: "Samantha")
    rec.waitForCount(1)

    #expect(synth.lastText == "hello there")           // POST body carried the text
    #expect(synth.lastVoice == "af_heart")             // ...and the kokoro voice
    #expect(playLog.all == [["/tmp/mudclient_test_tts.wav"]])   // afplay launched with the temp file
    #expect(service.backendStatus().backend == "kokoro")        // healthy, no fallback
    for u in rec.utterances { u.release() }
}

@Test func kokoroFallsBackToSayAndArmsCooldown() {
    let rec = Recorder()
    let sayLog = ArgLog()
    let synth = FakeSynthesizer(result: .failure(NSError(domain: "down", code: 61)))   // ECONNREFUSED-ish
    let service = SpeechService(
        makeUtterance: { args in sayLog.add(args); return FakeUtterance(text: args.last ?? "", onStart: rec.record) },
        voiceListing: { "" },
        synthesizer: synth,
        makePlayback: { args in FakeUtterance(text: args.last ?? "", onStart: rec.record) },
        tempWriter: { _ in "/tmp/never.wav" })

    service.speak(text: "hi", voice: "af_heart", backend: .kokoro, sayFallbackVoice: "Samantha")
    rec.waitForCount(1)

    // Server down -> fell back to `say` with the fallback voice (never touched afplay).
    #expect(sayLog.all == [["-v", "Samantha", "hi"]])
    // Cooldown armed: the effective backend now reports `say` so we don't hammer the dead server.
    #expect(service.backendStatus().backend == "say")
    for u in rec.utterances { u.release() }
}

@Test func stopCancelsInFlightKokoroRequest() {
    let rec = Recorder()
    let synth = FakeSynthesizer(result: .success(Data(count: 200)), block: true)   // blocks mid-request
    let service = SpeechService(
        makeUtterance: { args in FakeUtterance(text: args.last ?? "", onStart: rec.record) },
        voiceListing: { "" },
        synthesizer: synth,
        makePlayback: { args in FakeUtterance(text: args.last ?? "", onStart: rec.record) },
        tempWriter: { _ in "/tmp/never.wav" })

    service.speak(text: "hi", voice: "af_heart", backend: .kokoro, sayFallbackVoice: "Samantha")
    synth.waitUntilStarted()             // the HTTP request is now in flight (blocked)
    service.stop()                       // must abandon it

    Thread.sleep(forTimeInterval: 0.2)
    #expect(synth.cancelled == true)     // in-flight request cancelled
    #expect(rec.spokenText.isEmpty)      // nothing ever played (no afplay, no say fallback)
}

// MARK: - Volume

/// At TTS volume 0 an utterance must be DROPPED at `speak()` time: no synthesis (no HTTP to Kokoro)
/// and no playback (no afplay, no say). This is what makes a master `volume 0` truly silence voices.
@Test func volumeZeroSkipsSynthAndPlaybackEntirely() {
    let rec = Recorder()
    let sayLog = ArgLog()
    let playLog = ArgLog()
    let synth = FakeSynthesizer(result: .success(Data(count: 200)))
    let service = SpeechService(
        makeUtterance: { args in sayLog.add(args); return FakeUtterance(text: args.last ?? "", onStart: rec.record) },
        voiceListing: { "" },
        synthesizer: synth,
        makePlayback: { args in playLog.add(args); return FakeUtterance(text: args.last ?? "", onStart: rec.record) },
        tempWriter: { _ in "/tmp/never.wav" })

    service.setVolume(percent: 0)                       // muted
    service.speak(text: "you should not hear this", voice: "af_heart",
                  backend: .kokoro, sayFallbackVoice: "Samantha")

    Thread.sleep(forTimeInterval: 0.2)                  // give any (wrongly-spawned) worker time to run
    #expect(synth.lastText == nil)                      // NEVER synthesized (no HTTP attempted)
    #expect(playLog.all.isEmpty)                        // NEVER played via afplay
    #expect(sayLog.all.isEmpty)                         // NEVER fell back to say
    #expect(rec.spokenText.isEmpty)                     // nothing spoke at all
}

/// At a partial volume the kokoro playback passes afplay a `-v <0..1>` gain flag (here 50% -> "0.5").
@Test func volumeHalfPassesGainToAfplay() {
    let rec = Recorder()
    let playLog = ArgLog()
    let synth = FakeSynthesizer(result: .success(Data(count: 200)))
    let service = SpeechService(
        makeUtterance: { args in FakeUtterance(text: args.last ?? "", onStart: rec.record) },
        voiceListing: { "" },
        synthesizer: synth,
        makePlayback: { args in playLog.add(args); return FakeUtterance(text: args.last ?? "", onStart: rec.record) },
        tempWriter: { _ in "/tmp/mudclient_test_tts.wav" })

    service.setVolume(percent: 50)
    service.speak(text: "half volume", voice: "af_heart", backend: .kokoro, sayFallbackVoice: "Samantha")
    rec.waitForCount(1)

    #expect(playLog.all == [["-v", "0.5", "/tmp/mudclient_test_tts.wav"]])
    for u in rec.utterances { u.release() }
}

/// The `say` backend carries volume as a `[[volm <0..1>]]` inline prefix on the text (single argv slot).
@Test func volumeHalfPrefixesSayText() {
    let rec = Recorder()
    let sayLog = ArgLog()
    let service = SpeechService(
        makeUtterance: { args in sayLog.add(args); return FakeUtterance(text: args.last ?? "", onStart: rec.record) },
        voiceListing: { "" })

    service.setVolume(percent: 50)
    service.speak(text: "half say", voice: "Samantha", backend: .say)
    rec.waitForCount(1)

    #expect(sayLog.all == [["-v", "Samantha", "[[volm 0.5]] half say"]])
    for u in rec.utterances { u.release() }
}

/// Full volume (the default) leaves both argv paths untouched — no `-v` for afplay, no prefix for say.
@Test func fullVolumeLeavesArgsUnchanged() {
    #expect(SpeechService.afplayArgs(path: "/tmp/a.wav", volume: 1) == ["/tmp/a.wav"])
    #expect(SpeechService.afplayArgs(path: "/tmp/a.wav", volume: 0.5) == ["-v", "0.5", "/tmp/a.wav"])
    #expect(SpeechService.volumeString(0.5) == "0.5")
    #expect(SpeechService.volumeString(0) == "0")
    #expect(SpeechService.volumeString(1) == "1")
}

@Test func kokoroRequestBodyIsCorrect() throws {
    let req = KokoroHTTPSynthesizer.makeRequest(base: "http://127.0.0.1:8880",
                                                text: "true fishing is awesome", voice: "am_adam", timeout: 3)
    #expect(req.url?.absoluteString == "http://127.0.0.1:8880/v1/audio/speech")
    #expect(req.httpMethod == "POST")
    #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let body = try #require(req.httpBody)
    let obj = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(obj["input"] as? String == "true fishing is awesome")
    #expect(obj["voice"] as? String == "am_adam")
}
