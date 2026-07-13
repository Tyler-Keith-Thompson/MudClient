//
//  LiveMidiService.swift
//  MudClient
//
//  A live MIDI synth for real-time musical performances (AlterAeon's `kxwt_midi` stream — a bard/flute
//  performing, sent as raw MIDI channel-voice events with NO timing, meant to be played AS THEY ARRIVE).
//  This is distinct from MusicService's MidiChannelPlayer, which plays complete `.mid` FILES via
//  AVMIDIPlayer. Here there is no file to assemble: we feed each event straight to an AVAudioUnitSampler
//  the moment it lands. See docs/protocol/kxwt-midi.md.
//
//  Like MusicService this is GAME-AGNOSTIC — it takes raw MIDI bytes and synthesises them; the caller
//  (Audio.lua's kxwt_midi trigger) does the protocol framing. The engine is started lazily on the first
//  event so a session that never hears a performance never spins up CoreAudio.
//
//  Config (env vars):
//    MUD_SOUND_FONT  optional soundfont/DLS to synthesise with; falls back to the macOS system GM set.
//

import Foundation
import AVFoundation
import DependencyInjection
import Mockable

@Mockable
protocol LiveMidiServicing: Sendable {
    /// Feed one MIDI channel-voice message (status byte + its data bytes) to the synth, played live.
    func send(_ bytes: [UInt8])
    /// Panic: All-Notes-Off on every channel (e.g. the performer left / the socket dropped).
    func reset()
}

final class LiveMidiService: LiveMidiServicing, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let sampler = AVAudioUnitSampler()
    /// All synth work runs on this serial queue — never the main queue (stdin keystrokes are serviced
    /// there, and engine/sampler calls synchronise with CoreAudio's IO thread). Serial so the loaded
    /// instrument and `started` need no extra locking and events sound in the order they arrived.
    private let queue = DispatchQueue(label: "LiveMidi.audio", qos: .userInitiated)
    private var started = false
    /// The soundbank we synthesise from: MUD_SOUND_FONT if set, else the macOS system GM set. Without a
    /// bank the sampler has no samples loaded and stays silent (harmless).
    private let bank: URL?
    /// The GM program currently loaded into the (mono-timbral) sampler, so a repeated Program Change for
    /// the same instrument — the stream re-sends C0 at every phrase — doesn't reload samples each time.
    private var loadedProgram: UInt8?

    init() {
        let env = ProcessInfo.processInfo.environment
        if let f = env["MUD_SOUND_FONT"], !f.isEmpty {
            bank = URL(fileURLWithPath: (f as NSString).expandingTildeInPath)
        } else {
            // AVMIDIPlayer falls back to this automatically; AVAudioUnitSampler must be pointed at it.
            let sys = "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls"
            bank = FileManager.default.fileExists(atPath: sys) ? URL(fileURLWithPath: sys) : nil
        }
        engine.attach(sampler)
        engine.connect(sampler, to: engine.mainMixerNode, format: nil)
    }

    /// Lazily start the audio engine and load a default instrument on the first event (Program Change
    /// messages then switch it). No-op once started.
    private func ensureStarted() {
        guard !started else { return }
        loadProgram(0)
        try? engine.start()
        started = true
    }

    /// Load a GM melodic program into the sampler (the reliable way to make Program Change actually
    /// change the timbre for AVAudioUnitSampler). Cached so re-sending the same program is free.
    private func loadProgram(_ program: UInt8) {
        guard let bank, loadedProgram != program else { return }
        try? sampler.loadSoundBankInstrument(at: bank, program: program,
                                             bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB),
                                             bankLSB: UInt8(kAUSampler_DefaultBankLSB))
        loadedProgram = program
    }

    func send(_ bytes: [UInt8]) {
        queue.async { [weak self] in
            guard let self, let status = bytes.first else { return }
            self.ensureStarted()
            let channel = status & 0x0F
            switch status & 0xF0 {
            case 0x90:   // Note On (velocity 0 is the running-status Note Off)
                guard bytes.count >= 3 else { return }
                if bytes[2] == 0 { self.sampler.stopNote(bytes[1], onChannel: channel) }
                else { self.sampler.startNote(bytes[1], withVelocity: bytes[2], onChannel: channel) }
            case 0x80:   // Note Off
                guard bytes.count >= 2 else { return }
                self.sampler.stopNote(bytes[1], onChannel: channel)
            case 0xC0:   // Program Change — select instrument
                guard bytes.count >= 2 else { return }
                self.loadProgram(bytes[1])
            case 0xB0:   // Control Change (incl. CC#123 = All Notes Off, which punctuates each phrase)
                guard bytes.count >= 3 else { return }
                self.sampler.sendController(bytes[1], withValue: bytes[2], onChannel: channel)
            default:     // any other channel-voice message: pass through raw (pitch bend, aftertouch, …)
                if bytes.count >= 3 { self.sampler.sendMIDIEvent(status, data1: bytes[1], data2: bytes[2]) }
                else if bytes.count >= 2 { self.sampler.sendMIDIEvent(status, data1: bytes[1], data2: 0) }
            }
        }
    }

    func reset() {
        queue.async { [weak self] in
            guard let self else { return }
            for ch in 0..<16 { self.sampler.sendController(123, withValue: 0, onChannel: UInt8(ch)) }
        }
    }
}

extension Container {
    static let liveMidiService = Factory(scope: .cached) { LiveMidiService() as any LiveMidiServicing }
}
