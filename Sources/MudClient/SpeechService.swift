//
//  SpeechService.swift
//  MudClient
//
//  Text-to-speech for in-game chat. A small, GAME-AGNOSTIC utterance queue: a caller asks it to
//  `speak(text, voice, …)` and it renders the text either through a local Kokoro TTS server (mlx-audio,
//  see tools/tts/) or macOS `say`. It knows nothing about channels, speakers, or the MUD — deciding WHO
//  gets WHICH voice, WHICH lines are chat, and which BACKEND to prefer is the Lua script's job
//  (Scripts/Speech.lua).
//
//  Two backends, same queue:
//    * say    — /usr/bin/say with an ARGUMENT ARRAY (game text is one argv slot, never shell-parsed).
//    * kokoro — POST the text+voice to the local server (WAV bytes back), write a temp file, and play it
//               with /usr/bin/afplay (again an arg array). If the server is unreachable/errors/times out
//               the utterance TRANSPARENTLY falls back to `say` and a short cooldown is armed so a dead
//               server isn't hammered once per line; the cooldown re-probes on expiry.
//
//  Safety & responsiveness:
//    * One utterance speaks at a time, FIFO, on a dedicated worker thread (never the main/UI thread).
//    * The backlog is capped (`maxBacklog`): a chat flood drops the OLDEST unspoken line.
//    * `stop()` bumps a generation, flushes the queue, and cancels the in-flight utterance — for kokoro
//      that abandons the in-flight HTTP request AND kills afplay.
//    * Voice-list queries never block the caller: the `say -v ?` list is pre-warmed at init on a
//      background thread, and `kokoroVoices()` returns a cached snapshot while refreshing off-thread.
//      So a Lua trigger resolving a speaker's voice can never stall the UI on a subprocess/network wait.
//
//  Everything external is injected so tests drive the queue without speaking or hitting the network:
//  the say-process factory (`makeUtterance`), the voice-list source (`voiceListing`), the Kokoro HTTP
//  transport (`synthesizer`), the playback-process factory (`makePlayback`), the temp-file writer
//  (`tempWriter`), and the clock (`now`).
//

import Foundation
import DependencyInjection
import Mockable

@Mockable
protocol SpeechServicing: Sendable {
    func speak(text: String, voice: String?, rate: Int?, backend: SpeechBackend, sayFallbackVoice: String?)
    func stop()
    func setVolume(percent: Double)
    func backendStatus() -> (backend: String, detail: String)
    func kokoroVoices() -> [String]
    func voices(all: Bool) -> [SpeechService.Voice]
}

/// One spoken utterance in flight. `wait()` blocks the worker until it finishes; `cancel()` aborts it.
protocol SpeechUtterance: AnyObject {
    func wait()
    func cancel()
}

/// A live process invocation (say or afplay) backed by a Foundation `Process`. Args are passed as an
/// array so game text (or a temp path) is never interpreted by a shell.
private final class ProcessUtterance: SpeechUtterance {
    private let process = Process()
    init(executable: String, args: [String]) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
    }
    func wait() {
        do { try process.run(); process.waitUntilExit() }
        catch { /* binary unavailable — treat as a no-op utterance */ }
    }
    func cancel() { if process.isRunning { process.terminate() } }
}

/// Which backend an utterance is REQUESTED to use. `say` is the always-available fallback.
enum SpeechBackend: String, Sendable { case say, kokoro }

/// Blocking HTTP transport to the local Kokoro server. `synthesize` returns WAV bytes (or throws on
/// timeout/error/unreachable); `cancel` abandons an in-flight request so `stop()` is immediate.
protocol SpeechSynthesizer: AnyObject {
    func synthesize(text: String, voice: String?) throws -> Data
    func cancel()
}

/// Default Kokoro transport: POST /v1/audio/speech {input, voice} -> audio/wav, ~timeout seconds.
final class KokoroHTTPSynthesizer: SpeechSynthesizer, @unchecked Sendable {
    private let base: String
    private let timeout: TimeInterval
    private let session: URLSession
    private let lock = NSLock()
    private weak var task: URLSessionDataTask?

    init(base: String? = nil, timeout: TimeInterval = 3.0) {
        let env = ProcessInfo.processInfo.environment
        self.base = base ?? env["TTS_BASE_URL"] ?? "http://127.0.0.1:8880"
        self.timeout = timeout
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout
        self.session = URLSession(configuration: cfg)
    }

    /// Build the POST request for a text+voice (exposed for tests: asserts the JSON body).
    static func makeRequest(base: String, text: String, voice: String?, timeout: TimeInterval) -> URLRequest {
        var req = URLRequest(url: URL(string: base + "/v1/audio/speech")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = timeout
        var body: [String: Any] = ["input": text]
        if let voice, !voice.isEmpty { body["voice"] = voice }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }

    func synthesize(text: String, voice: String?) throws -> Data {
        let req = Self.makeRequest(base: base, text: text, voice: voice, timeout: timeout)
        let sem = DispatchSemaphore(value: 0)
        var out: Data?
        var err: Error?
        var status = 0
        let t = session.dataTask(with: req) { data, resp, e in
            out = data; err = e
            status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            sem.signal()
        }
        lock.lock(); task = t; lock.unlock()
        t.resume()
        sem.wait()
        lock.lock(); task = nil; lock.unlock()
        if let err { throw err }
        guard status == 200, let out, out.count > 44 else {   // 44 = minimal WAV header
            throw NSError(domain: "Kokoro", code: status, userInfo: [NSLocalizedDescriptionKey: "bad response (\(status))"])
        }
        return out
    }

    func cancel() { lock.lock(); let t = task; lock.unlock(); t?.cancel() }
}

/// A Kokoro utterance: synthesize over HTTP, write a temp WAV, play it with afplay; on any synth error
/// fall back to `say`. `cancel()` abandons the HTTP request and kills whatever is playing. `wait()` runs
/// on the service worker thread, so the (slow) HTTP happens off the main thread as usual.
private final class KokoroUtterance: SpeechUtterance {
    private let text: String
    private let voice: String?
    private let synth: SpeechSynthesizer
    private let makePlayback: ([String]) -> SpeechUtterance
    private let makeSay: ([String]) -> SpeechUtterance
    private let sayFallbackArgs: [String]
    private let tempWriter: (Data) -> String?
    private let onFallback: (Error) -> Void
    private let volume: Float

    private let lock = NSLock()
    private var cancelled = false
    private var player: SpeechUtterance?

    init(text: String, voice: String?, synth: SpeechSynthesizer,
         makePlayback: @escaping ([String]) -> SpeechUtterance,
         makeSay: @escaping ([String]) -> SpeechUtterance,
         sayFallbackArgs: [String], tempWriter: @escaping (Data) -> String?,
         volume: Float, onFallback: @escaping (Error) -> Void) {
        self.text = text; self.voice = voice; self.synth = synth
        self.makePlayback = makePlayback; self.makeSay = makeSay
        self.sayFallbackArgs = sayFallbackArgs; self.tempWriter = tempWriter
        self.volume = volume
        self.onFallback = onFallback
    }

    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func wait() {
        if isCancelled { return }
        do {
            let data = try synth.synthesize(text: text, voice: voice)
            if isCancelled { return }
            guard let path = tempWriter(data) else { throw NSError(domain: "Kokoro", code: -1) }
            defer { try? FileManager.default.removeItem(atPath: path) }
            let p = makePlayback(SpeechService.afplayArgs(path: path, volume: volume))
            lock.lock(); if cancelled { lock.unlock(); return }; player = p; lock.unlock()
            p.wait()
        } catch {
            onFallback(error)                 // arm the cooldown so we don't hammer a dead server
            if isCancelled { return }
            let p = makeSay(sayFallbackArgs)
            lock.lock(); if cancelled { lock.unlock(); return }; player = p; lock.unlock()
            p.wait()
        }
    }

    func cancel() {
        lock.lock(); cancelled = true; let p = player; lock.unlock()
        synth.cancel()
        p?.cancel()
    }
}

final class SpeechService: SpeechServicing, @unchecked Sendable {
    struct Voice: Equatable, Sendable { let name: String; let locale: String }

    /// One queued item: the text plus the resolved voice(s), requested backend, and a snapshot of the
    /// TTS volume at enqueue time (0…1).
    private struct Item {
        let text: String
        let backend: SpeechBackend
        let voice: String?          // voice for the requested backend
        let sayFallbackVoice: String?  // say voice to use if a kokoro synth fails
        let rate: Int?
        let volume: Float
    }

    private let cond = NSCondition()
    private var queue: [Item] = []                 // FIFO, guarded by `cond`
    private var current: SpeechUtterance?          // in-flight utterance, guarded by `cond`
    private var generation = 0                     // bumped by stop() to flush; guarded by `cond`
    private var started = false                    // worker-thread lazy start, guarded by `cond`

    // Backend health, guarded by `cond`.
    private var lastRequestedBackend: SpeechBackend = .kokoro
    private var cooldownUntil: Date?               // while set & future, kokoro is skipped (server dead)
    private var lastError: String?                 // last kokoro failure reason (for speech_backend())
    private let cooldownInterval: TimeInterval

    /// TTS voice volume, 0…1 (default 1). At 0 an utterance is DROPPED at `speak()` time — no synth, no
    /// playback — which is what makes a master `volume 0` truly silence voices. Otherwise it is applied
    /// to playback: afplay via `-v <volume>` and `say` via a `[[volm <volume>]]` inline prefix. Guarded
    /// by `cond`.
    private var _volume: Float = 1

    /// Cap on queued (not-yet-spoken) utterances. Over this, the OLDEST is dropped.
    let maxBacklog: Int

    // Injectable seams (all default to the real thing; tests substitute).
    private let makeUtterance: ([String]) -> SpeechUtterance     // the `say` player (args = say argv)
    private let voiceListing: () -> String
    private let synthesizer: SpeechSynthesizer
    private let makePlayback: ([String]) -> SpeechUtterance      // the afplay player (args = [path])
    private let tempWriter: (Data) -> String?
    private let now: () -> Date

    private var cachedVoices: [Voice]?             // parsed once, guarded by `cond`

    // Kokoro voice-id cache. `kokoroVoices()` returns this snapshot IMMEDIATELY (never blocking the
    // caller) and refreshes it on a background thread; `refreshing` keeps a single fetch in flight.
    // Both guarded by `cond`.
    private var cachedKokoroVoices: [String] = []
    private var kokoroRefreshing = false

    init(maxBacklog: Int = 8,
         makeUtterance: @escaping ([String]) -> SpeechUtterance = { ProcessUtterance(executable: "/usr/bin/say", args: $0) },
         voiceListing: @escaping () -> String = SpeechService.runSayVoiceList,
         synthesizer: SpeechSynthesizer = KokoroHTTPSynthesizer(),
         makePlayback: @escaping ([String]) -> SpeechUtterance = { ProcessUtterance(executable: "/usr/bin/afplay", args: $0) },
         tempWriter: @escaping (Data) -> String? = SpeechService.writeTempWav,
         now: @escaping () -> Date = Date.init,
         cooldownInterval: TimeInterval = 15) {
        self.maxBacklog = maxBacklog
        self.makeUtterance = makeUtterance
        self.voiceListing = voiceListing
        self.synthesizer = synthesizer
        self.makePlayback = makePlayback
        self.tempWriter = tempWriter
        self.now = now
        self.cooldownInterval = cooldownInterval
        // Pre-warm the (static) say voice list off the caller thread so no chat line ever pays for the
        // `say -v ?` subprocess synchronously. Uses the injected listing (instant/empty in tests).
        warmVoiceListInBackground()
    }

    /// Populate `cachedVoices` on a detached thread. The real default runs the `say -v ?` subprocess
    /// here (never on a caller); tests inject a trivial listing so this is an instant no-op.
    private func warmVoiceListInBackground() {
        Thread.detachNewThread { [weak self] in
            guard let self else { return }
            let parsed = SpeechService.parseVoices(self.voiceListing())
            self.cond.lock(); if self.cachedVoices == nil { self.cachedVoices = parsed }; self.cond.unlock()
        }
    }

    /// Enqueue `text` to be spoken. `backend` picks the renderer (default `.say`); `voice` is the voice
    /// for that backend; `sayFallbackVoice` is the `say` voice used if a kokoro synth fails. FIFO; if the
    /// backlog is full the oldest queued line is dropped first.
    func speak(text: String, voice: String? = nil, rate: Int? = nil,
               backend: SpeechBackend = .say, sayFallbackVoice: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        cond.lock()
        // Muted: drop the utterance entirely — no enqueue, so no synth (no HTTP to Kokoro) and no
        // playback ever happens. This is what makes `volume 0` truly silence voices.
        if _volume <= 0 { cond.unlock(); return }
        let vol = _volume
        lastRequestedBackend = backend
        ensureWorkerLocked()
        queue.append(Item(text: trimmed, backend: backend, voice: voice,
                          sayFallbackVoice: sayFallbackVoice, rate: rate, volume: vol))
        while queue.count > maxBacklog { queue.removeFirst() }
        cond.signal()
        cond.unlock()
    }

    /// Set the TTS voice volume from a 0-100 percentage. Clamped to 0…100. At 0 subsequent utterances
    /// are dropped (never synthesized or played).
    func setVolume(percent: Double) {
        let v = Float(max(0, min(100, percent)) / 100)
        cond.lock(); _volume = v; cond.unlock()
    }

    /// Cancel everything: flush the pending queue and cancel the current utterance.
    func stop() {
        cond.lock()
        generation += 1
        queue.removeAll()
        let inflight = current
        current = nil
        cond.unlock()
        inflight?.cancel()
    }

    /// The effective backend + a human detail string, for the `speech_backend()` builtin. Reflects the
    /// last requested backend, downgraded to `say` while a kokoro cooldown is in effect.
    func backendStatus() -> (backend: String, detail: String) {
        cond.lock(); defer { cond.unlock() }
        let cooling = cooldownUntil.map { $0 > now() } ?? false
        if lastRequestedBackend == .kokoro {
            if cooling {
                let secs = Int((cooldownUntil!.timeIntervalSince(now())).rounded(.up))
                return ("say", "kokoro unreachable (\(lastError ?? "error")); retrying in \(secs)s")
            }
            return ("kokoro", "ready")
        }
        return ("say", "say backend selected")
    }

    /// The Kokoro server's voice ids — returned from a cached snapshot IMMEDIATELY so a caller (the Lua
    /// trigger thread) never blocks on the network. The first call returns whatever's cached (empty
    /// until the first fetch lands — the Lua side then uses its curated set) and kicks a single
    /// background refresh; later calls see the warmed list. The actual GET (with its timeout wait) only
    /// ever runs on the detached refresh thread, never on the caller.
    func kokoroVoices() -> [String] {
        cond.lock()
        let snapshot = cachedKokoroVoices
        let alreadyRefreshing = kokoroRefreshing
        if !alreadyRefreshing { kokoroRefreshing = true }
        cond.unlock()
        if !alreadyRefreshing {
            Thread.detachNewThread { [weak self] in
                guard let self else { return }
                let ids = self.fetchKokoroVoices()
                self.cond.lock(); self.cachedKokoroVoices = ids; self.kokoroRefreshing = false; self.cond.unlock()
            }
        }
        return snapshot
    }

    /// Blocking GET /v1/voices (short timeout). ONLY called from the background refresh in
    /// `kokoroVoices()` — never on a caller thread — so its semaphore wait can't stall the UI.
    private func fetchKokoroVoices() -> [String] {
        guard let base = ProcessInfo.processInfo.environment["TTS_BASE_URL"] ?? Optional("http://127.0.0.1:8880"),
              let url = URL(string: base + "/v1/voices") else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        let sem = DispatchSemaphore(value: 0)
        var result: [String] = []
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 2
        let task = URLSession(configuration: cfg).dataTask(with: req) { data, _, _ in
            defer { sem.signal() }
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = obj["voices"] as? [String] else { return }
            result = arr
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 2.5)
        return result
    }

    /// Available `say` voices. Normally served from the cache pre-warmed at init (see
    /// `warmVoiceListInBackground`), so no caller pays for the `say -v ?` subprocess. If a call somehow
    /// races ahead of the warm, it parses the injected listing ONCE — off the `cond` lock, so it never
    /// stalls `speak()` or the worker. `all=false` keeps English only.
    func voices(all: Bool = false) -> [Voice] {
        cond.lock(); var v = cachedVoices; cond.unlock()
        if v == nil {
            let parsed = SpeechService.parseVoices(voiceListing())   // off-lock; pre-warmed in production
            cond.lock(); if cachedVoices == nil { cachedVoices = parsed }; v = cachedVoices; cond.unlock()
        }
        let list = v ?? []
        return all ? list : list.filter { $0.locale.hasPrefix("en") }
    }

    // MARK: - Worker

    private func ensureWorkerLocked() {
        guard !started else { return }
        started = true
        let thread = Thread { [weak self] in self?.runLoop() }
        thread.name = "SpeechService.worker"
        thread.start()
    }

    private func runLoop() {
        while true {
            cond.lock()
            while queue.isEmpty { cond.wait() }
            let gen = generation
            let item = queue.removeFirst()
            let utt = buildUtteranceLocked(item)
            if gen != generation { cond.unlock(); continue }   // stop() raced the dequeue — skip
            current = utt
            cond.unlock()

            utt.wait()

            cond.lock()
            if current === utt { current = nil }
            cond.unlock()
        }
    }

    /// Build the utterance for `item` (called with `cond` held). Chooses kokoro vs say honoring the
    /// cooldown, and wires the fallback closure that arms the cooldown on a kokoro failure.
    private func buildUtteranceLocked(_ item: Item) -> SpeechUtterance {
        let cooling = cooldownUntil.map { $0 > now() } ?? false
        let wantKokoro = (item.backend == .kokoro) && !cooling
        if wantKokoro {
            return KokoroUtterance(
                text: item.text, voice: item.voice, synth: synthesizer,
                makePlayback: makePlayback, makeSay: makeUtterance,
                sayFallbackArgs: sayArgs(voice: item.sayFallbackVoice, rate: item.rate,
                                         text: item.text, volume: item.volume),
                tempWriter: tempWriter, volume: item.volume,
                onFallback: { [weak self] err in self?.armCooldown(err) })
        }
        // say backend (or kokoro requested but cooling down): pick the right voice for say.
        let v = (item.backend == .kokoro) ? item.sayFallbackVoice : item.voice
        return makeUtterance(sayArgs(voice: v, rate: item.rate, text: item.text, volume: item.volume))
    }

    private func armCooldown(_ err: Error) {
        cond.lock()
        cooldownUntil = now().addingTimeInterval(cooldownInterval)
        lastError = (err as NSError).localizedDescription
        cond.unlock()
    }

    /// Build the `say` argv (voice/rate flags + the untrusted text as its own single argv slot). When
    /// `volume` < 1 the text carries a `[[volm <volume>]]` inline command prefix (say's own volume
    /// control); the game text stays a single argv element, never shell-parsed.
    private func sayArgs(voice: String?, rate: Int?, text: String, volume: Float = 1) -> [String] {
        var args: [String] = []
        if let voice, !voice.isEmpty { args += ["-v", voice] }
        if let rate, rate > 0 { args += ["-r", String(rate)] }
        let body = volume < 1 ? "[[volm \(Self.volumeString(volume))]] \(text)" : text
        args.append(body)
        return args
    }

    /// afplay argv for a WAV `path` at `volume`. Below full volume, prepends `-v <volume>` (afplay's
    /// playback-gain flag); at full volume it's just the path (keeps the default argv minimal).
    static func afplayArgs(path: String, volume: Float) -> [String] {
        volume < 1 ? ["-v", volumeString(volume), path] : [path]
    }

    /// Format a 0…1 volume for a CLI flag: shortest clean decimal (0.5, 0.35), never scientific.
    static func volumeString(_ v: Float) -> String {
        let clamped = max(0, min(1, v))
        if clamped == clamped.rounded() { return String(Int(clamped)) }   // 0 -> "0", 1 -> "1"
        return String(clamped)
    }

    // MARK: - Temp file

    /// Write WAV bytes to a unique temp file and return its path (nil on failure).
    static func writeTempWav(_ data: Data) -> String? {
        let dir = NSTemporaryDirectory()
        let path = (dir as NSString).appendingPathComponent("mudclient_tts_\(UUID().uuidString).wav")
        do { try data.write(to: URL(fileURLWithPath: path)); return path }
        catch { return nil }
    }

    // MARK: - Voice listing

    /// Run `say -v ?` and return its stdout (empty on failure). Only used for the real default.
    static func runSayVoiceList() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", "?"]
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        } catch { return "" }
    }

    /// Parse `say -v ?` output. Each line looks like:
    ///   `Samantha            en_US    # Hello, my name is Samantha.`
    /// The name may contain spaces/parens; it ends at the run of 2+ spaces before the `ll_CC` locale.
    static func parseVoices(_ text: String) -> [Voice] {
        guard let rx = try? Regex(#"^(.+?)\s{2,}([A-Za-z]{2,3}[-_][A-Za-z]{2,})"#) else { return [] }
        var out: [Voice] = []
        var seen = Set<String>()
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            guard let m = try? rx.firstMatch(in: line),
                  let name = m.output[1].substring.map(String.init),
                  let locale = m.output[2].substring.map(String.init) else { continue }
            let n = name.trimmingCharacters(in: .whitespaces)
            if n.isEmpty || seen.contains(n) { continue }
            seen.insert(n)
            out.append(Voice(name: n, locale: locale.replacingOccurrences(of: "-", with: "_")))
        }
        return out
    }
}

extension Container {
    static let speechService = Factory(scope: .cached) { SpeechService() as any SpeechServicing }
}
