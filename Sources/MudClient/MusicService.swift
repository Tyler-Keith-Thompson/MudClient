//
//  MusicService.swift
//  MudClient
//
//  A small, GAME-AGNOSTIC layered audio player. It knows nothing about the MUD, kxwt, or any track
//  naming scheme — a caller just asks it to "play track <name> on channel <name>" or "stop channel
//  <name>", and it plays the matching file from a configured sound directory. Any protocol parsing
//  (e.g. AlterAeon's `kxwt_music` events) and any bookkeeping about what's currently playing live in
//  the scripts, not here.
//
//  Multiple channels sound at once (each is one looping player); `play` crossfades over whatever the
//  channel held, `stop` fades it out. If a track has no matching file it simply no-ops. Player objects
//  are only touched on the main queue.
//
//  Config (env vars):
//    MUD_SOUND_DIR      directory holding your audio files (default ~/Documents/MudClient/sounds if present)
//    MUD_SOUND_FONT     optional soundfont/DLS for .mid tracks (falls back to the system General MIDI set)
//    MUD_MUSIC_VOLUME   starting master volume as a percentage 0-100 (default 35 — deliberately quiet)
//

import Foundation
import AVFoundation
import DependencyInjection

final class MusicService: @unchecked Sendable {
    private let crossfade: TimeInterval = 1.5
    private let volumeFade: TimeInterval = 0.4
    private let soundDir: URL?
    private let soundFont: URL?
    private var channels: [String: ChannelPlayer] = [:]   // main-queue only
    /// Master volume (0…1) applied to every channel. Set once in `init`, then only touched on the main
    /// queue. Deliberately low by default so ambience sits under the game text rather than over it.
    private var masterVolume: Float

    init() {
        let env = ProcessInfo.processInfo.environment
        func url(_ p: String) -> URL { URL(fileURLWithPath: (p as NSString).expandingTildeInPath) }
        if let p = env["MUD_SOUND_DIR"], !p.isEmpty {
            soundDir = url(p)
        } else {
            let def = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/MudClient/sounds")
            soundDir = FileManager.default.fileExists(atPath: def.path) ? def : nil
        }
        if let f = env["MUD_SOUND_FONT"], !f.isEmpty { soundFont = url(f) } else { soundFont = nil }
        if let v = env["MUD_MUSIC_VOLUME"], let n = Float(v) {
            masterVolume = max(0, min(1, n / 100))
        } else {
            masterVolume = 0.35
        }
    }

    /// Start (or replace) `track` on `channel`, crossfading over whatever was there. `track` may be a
    /// full path the caller resolved itself, or a bare name to look up under the configured sound dir.
    /// No-op if nothing matches.
    func play(channel: String, track: String) {
        guard let file = resolve(track) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let player = self.makePlayer(file) else { return }
            let old = self.channels[channel]
            self.channels[channel] = player
            player.start(volume: 0)
            player.fade(to: self.masterVolume, duration: self.crossfade)
            old?.fadeOutAndStop(duration: self.crossfade)
        }
    }

    /// Fade out and stop `channel`.
    func stop(channel: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.channels.removeValue(forKey: channel)?.fadeOutAndStop(duration: self.crossfade)
        }
    }

    /// Set the master volume for all channels from a 0-100 percentage, fading currently-playing
    /// channels to the new level and applying it to anything started afterward. Clamped to 0…100.
    func setVolume(percent: Double) {
        let v = Float(max(0, min(100, percent)) / 100)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.masterVolume = v
            for player in self.channels.values { player.fade(to: v, duration: self.volumeFade) }
        }
    }

    // MARK: - Internals

    /// Resolve a track to a file. First: a full path the caller already built (absolute or ~-relative).
    /// Otherwise: a bare name under the configured sound dir, trying common audio/MIDI extensions. The
    /// name is just a string — any meaning is the caller's business.
    private func resolve(_ track: String) -> URL? {
        let expanded = (track as NSString).expandingTildeInPath
        if expanded.hasPrefix("/"), FileManager.default.fileExists(atPath: expanded) {
            return URL(fileURLWithPath: expanded)
        }
        guard let dir = soundDir else { return nil }
        let base = dir.appendingPathComponent(track)
        if FileManager.default.fileExists(atPath: base.path) { return base }
        for ext in ["ogg", "mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "mid", "midi"] {
            let u = base.appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    private func makePlayer(_ url: URL) -> ChannelPlayer? {
        switch url.pathExtension.lowercased() {
        case "mid", "midi": return MidiChannelPlayer(url: url, soundFont: soundFont)
        default:            return AudioChannelPlayer(url: url)
        }
    }
}

/// A single channel's looping player. All calls happen on the main queue.
private protocol ChannelPlayer: AnyObject {
    func start(volume: Float)
    func fade(to volume: Float, duration: TimeInterval)
    func fadeOutAndStop(duration: TimeInterval)
}

/// Looping audio (mp3/m4a/wav/aiff/caf…) via AVAudioPlayer — supports true volume crossfades.
private final class AudioChannelPlayer: ChannelPlayer {
    private let player: AVAudioPlayer?
    init(url: URL) {
        player = try? AVAudioPlayer(contentsOf: url)
        player?.numberOfLoops = -1
        player?.prepareToPlay()
    }
    func start(volume: Float) { player?.volume = volume; player?.play() }
    func fade(to volume: Float, duration: TimeInterval) { player?.setVolume(volume, fadeDuration: duration) }
    func fadeOutAndStop(duration: TimeInterval) {
        player?.setVolume(0, fadeDuration: duration)
        let p = player
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { p?.stop() }
    }
}

/// Looping MIDI (.mid/.midi) via AVMIDIPlayer + a soundfont (or the system GM set). AVMIDIPlayer has
/// no volume control, so MIDI channels switch rather than crossfade — good enough for ambience.
private final class MidiChannelPlayer: ChannelPlayer {
    private var player: AVMIDIPlayer?
    private var stopped = false
    init(url: URL, soundFont: URL?) {
        player = try? AVMIDIPlayer(contentsOf: url, soundBankURL: soundFont)
        player?.prepareToPlay()
    }
    func start(volume: Float) { loop() }
    private func loop() {
        guard !stopped, let p = player else { return }
        p.currentPosition = 0
        p.play { [weak self] in DispatchQueue.main.async { self?.loop() } }   // restart on finish = loop
    }
    func fade(to volume: Float, duration: TimeInterval) {}   // no volume on AVMIDIPlayer
    func fadeOutAndStop(duration: TimeInterval) { stopped = true; player?.stop() }
}

extension Container {
    static let musicService = Factory(scope: .cached) { MusicService() }
}
