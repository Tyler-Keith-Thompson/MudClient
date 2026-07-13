//
//  MidiAuditionTests.swift
//  MudClient — MANUAL audio audition (not part of the normal suite)
//
//  Plays the captured Asuka flute performance (docs/protocol/captures/2026-07-12-asuka-flute-performance)
//  THROUGH THE REAL `LiveMidiService` synth so you can HEAR the kxwt_midi player before rebuilding the app.
//  It exercises the exact shipped audio path — LiveMidiService.send([UInt8]) → AVAudioUnitSampler — the
//  only thing the test adds is TIMING: the wire stream carries no delta-time (events play "as they arrive",
//  gated by packet arrival), so here we pace them into an audible melody.
//
//  This is deliberately in its OWN bazel target (tags: manual, no-cache; local = True) so:
//    * `bazel test //...` never plays audio or sleeps in CI (manual = excluded from wildcards),
//    * it runs UNSANDBOXED so it can reach CoreAudio's default output device (local),
//    * repeated runs actually replay instead of returning a cached PASS (no-cache).
//
//  Run it (KEEP --config=debug so it shares `just`'s Bazel cache and doesn't slow the next `just run`):
//      bazel test //Tests/MidiAudition:MidiAudition --config=debug --test_output=streamed
//  (add --test_arg=--fast for a quicker, less musical blast, or set MUD_SOUND_FONT to audition a soundfont.)
//
//  It always PASSES — the point is the sound, not an assertion. If you hear a flute melody, the synth works.
//

import Foundation
import Testing
@testable import MudClient

@Suite(.serialized)
struct MidiAuditionTests {
    /// The 48 `kxwt_midi` events from the reference capture, in wire order (one MIDI message per entry).
    /// C0 49 = Program Change → Flute (GM 73); 90 nn 32 = Note On; 80 nn 00 = Note Off; B0 7B 00 =
    /// All-Notes-Off between phrases (each phrase then re-sends C0 49).
    static let capture: [String] = [
        "C0 49",
        "90 4d 32", "80 4d 00", "90 52 32", "80 52 00", "90 4d 32", "80 4d 00",
        "90 56 32", "80 56 00", "90 52 32", "80 52 00", "90 59 32",
        "B0 7B 00",
        "C0 49",
        "90 4d 32", "80 4d 00", "90 52 32", "80 52 00", "90 4d 32", "80 4d 00",
        "90 56 32", "80 56 00", "90 52 32", "80 52 00", "90 59 32",
        "B0 7B 00",
        "C0 49",
        "90 59 32", "80 59 00", "90 5b 32", "80 5b 00", "90 51 32", "80 51 00",
        "90 5b 32", "80 5b 00", "90 59 32", "80 59 00", "90 56 32",
        "B0 7B 00",
        "C0 49",
        "90 56 32", "80 56 00", "90 56 32", "80 56 00", "90 54 32", "80 54 00",
        "90 52 32",
        "B0 7B 00",
    ]

    private static func bytes(_ s: String) -> [UInt8] {
        s.split(separator: " ").compactMap { UInt8($0, radix: 16) }
    }

    @Test func playCapturedFlutePerformanceAloud() {
        let fast = CommandLine.arguments.contains("--fast")
        // A note held ~one beat; the control/program events (which carry no sound) get a short gap so the
        // phrasing breathes. Tuned to sound like a little flute line rather than a blur.
        let beat: TimeInterval = fast ? 0.05 : 0.22

        let synth = LiveMidiService()
        print("[midi-audition] playing \(Self.capture.count) events — listen for a flute melody…")
        for ev in Self.capture {
            let b = Self.bytes(ev)
            synth.send(b)
            // Note On / Note Off get a full beat; the punctuating C0 program / B0 all-notes-off get a
            // shorter rest so a phrase boundary is a brief breath, not a full beat of silence.
            let isSound = (b.first.map { $0 & 0xF0 } == 0x90) || (b.first.map { $0 & 0xF0 } == 0x80)
            Thread.sleep(forTimeInterval: isSound ? beat : beat * 0.5)
        }
        // Let the final note ring out, then flush any held notes.
        Thread.sleep(forTimeInterval: fast ? 0.2 : 0.8)
        synth.reset()
        Thread.sleep(forTimeInterval: 0.2)
        print("[midi-audition] done.")
    }
}
