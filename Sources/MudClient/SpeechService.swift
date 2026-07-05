//
//  SpeechService.swift
//  MudClient
//
//  Text-to-speech for in-game chat. A small, GAME-AGNOSTIC utterance queue: a caller asks it to
//  `speak(text, voice, rate?)` and it renders the text through macOS `say` (one system voice per
//  utterance). It knows nothing about channels, speakers, or the MUD — deciding WHO gets WHICH voice,
//  and WHICH lines are chat, is the Lua script's job (Scripts/Speech.lua).
//
//  Safety & responsiveness:
//    * `say` is launched with an ARGUMENT ARRAY (never a shell string), so untrusted game text can
//      never be word-split, globbed, or injected — the text is one argv element.
//    * One utterance speaks at a time, FIFO, on a dedicated worker thread (never the main/UI thread).
//    * The backlog is capped (`maxBacklog`): when chat floods, the OLDEST unspoken line is dropped so
//      speech can never build up a minute of lag behind the screen.
//    * `stop()` bumps a generation, flushes the queue, and terminates the in-flight `say` process.
//
//  The process launch is injected (`makeUtterance`) so tests drive the queue without actually speaking,
//  and the voice list source (`voiceListing`) is injected so voice parsing is tested against canned
//  `say -v ?` output.
//

import Foundation
import DependencyInjection

/// One spoken utterance in flight. `wait()` blocks the worker until it finishes; `cancel()` aborts it.
protocol SpeechUtterance: AnyObject {
    func wait()
    func cancel()
}

/// A live `say` invocation backed by a Foundation `Process`. The args are passed as an array so the
/// game text (args.last) is never interpreted by a shell.
private final class ProcessUtterance: SpeechUtterance {
    private let process = Process()
    init(args: [String]) {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = args
    }
    func wait() {
        do { try process.run(); process.waitUntilExit() }
        catch { /* say unavailable — treat as a no-op utterance */ }
    }
    func cancel() { if process.isRunning { process.terminate() } }
}

final class SpeechService: @unchecked Sendable {
    struct Voice: Equatable { let name: String; let locale: String }

    /// One queued item: the argv (minus the executable) for `say`.
    private struct Item { let args: [String] }

    private let cond = NSCondition()
    private var queue: [Item] = []                 // FIFO, guarded by `cond`
    private var current: SpeechUtterance?          // in-flight utterance, guarded by `cond`
    private var generation = 0                     // bumped by stop() to flush; guarded by `cond`
    private var started = false                    // worker-thread lazy start, guarded by `cond`

    /// Cap on queued (not-yet-spoken) utterances. Over this, the OLDEST is dropped so a chat flood
    /// can't make speech lag the screen by a minute. The in-flight utterance is not counted here.
    let maxBacklog: Int

    /// Injectable process factory (defaults to a real `say` Process) and voice-list source (defaults to
    /// running `say -v ?`). Tests substitute both.
    private let makeUtterance: ([String]) -> SpeechUtterance
    private let voiceListing: () -> String

    private var cachedVoices: [Voice]?             // parsed once, guarded by `cond`

    init(maxBacklog: Int = 8,
         makeUtterance: @escaping ([String]) -> SpeechUtterance = { ProcessUtterance(args: $0) },
         voiceListing: @escaping () -> String = SpeechService.runSayVoiceList) {
        self.maxBacklog = maxBacklog
        self.makeUtterance = makeUtterance
        self.voiceListing = voiceListing
    }

    /// Enqueue `text` to be spoken in `voice` (nil = the system default) at `rate` words/min (nil =
    /// default). FIFO; if the backlog is already full the oldest queued line is dropped first.
    func speak(text: String, voice: String? = nil, rate: Int? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var args: [String] = []
        if let voice, !voice.isEmpty { args += ["-v", voice] }
        if let rate, rate > 0 { args += ["-r", String(rate)] }
        args.append(trimmed)                       // the untrusted text: always its own single argv slot

        cond.lock()
        ensureWorkerLocked()
        queue.append(Item(args: args))
        // Drop the OLDEST if we're over the cap (a flood must not build lag).
        while queue.count > maxBacklog { queue.removeFirst() }
        cond.signal()
        cond.unlock()
    }

    /// Cancel everything: flush the pending queue and terminate the current utterance. A generation bump
    /// makes any in-progress dequeue discard its item.
    func stop() {
        cond.lock()
        generation += 1
        queue.removeAll()
        let inflight = current
        current = nil
        cond.unlock()
        inflight?.cancel()
    }

    /// Available voices, parsed once from the injected listing. `all=false` (default) keeps English
    /// (`en_*`) locales only — a sane default for an English MUD; `all=true` returns every voice.
    func voices(all: Bool = false) -> [Voice] {
        cond.lock()
        if cachedVoices == nil { cachedVoices = SpeechService.parseVoices(voiceListing()) }
        let v = cachedVoices ?? []
        cond.unlock()
        if all { return v }
        return v.filter { $0.locale.hasPrefix("en") }
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
            let utt = makeUtterance(item.args)
            // A stop() between dequeue and here bumped the generation — skip this item.
            if gen != generation { cond.unlock(); continue }
            current = utt
            cond.unlock()

            utt.wait()

            cond.lock()
            if current === utt { current = nil }
            cond.unlock()
        }
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
        // name (non-greedy, allows spaces), 2+ spaces, then a language_COUNTRY locale token.
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
    static let speechService = Factory(scope: .cached) { SpeechService() }
}
