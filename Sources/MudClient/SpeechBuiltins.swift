//
//  SpeechBuiltins.swift
//  MudClient
//
//  Wires the text-to-speech (SpeechService) and the live-vs-history discriminator into the Lua host
//  surface, as a NEW file so the core LuaScriptEngine/bootstrap stay untouched. `installSpeech()` is the
//  single hook (called from ScriptInterpreter.init); the builtins it registers are documented from
//  Scripts/Speech.lua (via doc()), not bootstrap.lua — the doc-coverage spec checks the registry, and
//  these go through the engine's `register(_:_:)` (not a literal `lua.register("…")`), so the Swift
//  source-scan doc test doesn't demand a bootstrap entry either.
//
//  Builtins registered here:
//    * is_live() -> bool          — true only while the engine is processing lines from the LIVE
//                                    connection right now; false during replay() and outside a live
//                                    batch. Chat TTS guards on this so replayed history is never spoken.
//    * speak(text[, voice[, rate]]) — enqueue an utterance (see SpeechService).
//    * speech_stop()              — cancel the current utterance and flush the queue.
//    * speech_voices([all])       — array of { name=, locale= } voices (English-only unless all=true).
//

import Foundation
import DependencyInjection

/// Tracks whether the host is currently feeding lines from the LIVE connection (depth > 0) versus
/// replayed history or nothing at all (depth == 0). The live server-output pump wraps its per-batch
/// trigger dispatch in `begin()`/`end()` (see ScriptInterpreter); the replay path deliberately does
/// not, so `is_live()` reads false while history is replayed. A depth counter (not a bool) tolerates
/// nesting; a lock keeps it consistent across the pump and any reader.
final class LiveGate: @unchecked Sendable {
    static let shared = LiveGate()
    private let lock = NSLock()
    private var depth = 0

    var isLive: Bool { lock.lock(); defer { lock.unlock() }; return depth > 0 }
    func begin() { lock.lock(); depth += 1; lock.unlock() }
    func end() { lock.lock(); if depth > 0 { depth -= 1 }; lock.unlock() }

    /// Run `body` marked as live (used by the live output pump). Exception-safe.
    func live<T>(_ body: () -> T) -> T {
        begin(); defer { end() }
        return body()
    }
}

extension LuaScriptEngine {
    /// Register the speech + live-discriminator builtins. Idempotent-safe to call once at startup. Uses
    /// the engine's own `register(_:_:)` so the names land in `__host_builtins` (doc-coverage enforced)
    /// while keeping this out of the contested bootstrap/engine files.
    func installSpeech() {
        register("is_live") { _ in [.bool(LiveGate.shared.isLive)] }

        // speak(text[, voice[, rate]]). text is the untrusted game line; SpeechService passes it as a
        // single argv element to `say`, so there's no shell-injection surface.
        register("speak") { args in
            guard case .string(let text)? = args.first, !text.isEmpty else { return [] }
            var voice: String?
            if args.count > 1, case .string(let v) = args[1], !v.isEmpty { voice = v }
            var rate: Int?
            if args.count > 2 {
                switch args[2] {
                case .int(let n): rate = Int(n)
                case .number(let d): rate = Int(d)
                default: break
                }
            }
            Container.speechService().speak(text: text, voice: voice, rate: rate)
            return []
        }

        register("speech_stop") { _ in
            Container.speechService().stop()
            return []
        }

        // speech_voices([all]) -> array of { name=, locale= }. English-only unless a truthy arg asks for
        // every locale.
        register("speech_voices") { args in
            var all = false
            if case .bool(let b)? = args.first { all = b }
            let voices = Container.speechService().voices(all: all)
            let arr: [LuaValue] = voices.map { v in
                .table([], ["name": .string(v.name), "locale": .string(v.locale)])
            }
            return [.table(arr, [:])]
        }
    }
}
