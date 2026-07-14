//
//  SoundService.swift
//  MudClient
//
//  A small, GAME-AGNOSTIC layered audio player. It knows nothing about the MUD, kxwt, or any track
//  naming scheme — a caller just asks it to "play track <name> on channel <name>" (looping ambience),
//  "play track once" (a one-shot effect), or "stop channel <name>", and it plays the matching file
//  from a configured sound directory. Any protocol parsing (e.g. AlterAeon's dclient `sound` tags or
//  `kxwt_music` events) and any bookkeeping about what's currently playing live in the scripts, not here.
//
//  Playback is built on AVAudioEngine, NOT AVAudioPlayer. This matters: AVAudioPlayer opens an Ogg
//  Vorbis file (it reads the header/duration) but `play()` returns false and nothing sounds — Core
//  Audio's high-level player has no Vorbis playback path. AVAudioFile/AVAudioEngine decode the SAME
//  files fine. AlterAeon's soundpack is 100% .ogg, so the engine path is the only one that works.
//
//  Multiple channels sound at once (each is one looping player node); `play` crossfades over whatever
//  the channel held, `stop` fades it out. One-shots overlap everything and self-reap when finished. If
//  a track has no matching file it simply no-ops. All node graph mutations happen on the main queue.
//
//  Config (env vars):
//    MUD_SOUND_DIR      directory holding your audio files (default ~/Documents/MudClient/sounds if present)
//    MUD_SOUND_FONT     optional soundfont/DLS for .mid tracks (falls back to the system General MIDI set)
//    MUD_MUSIC_VOLUME   starting master volume as a percentage 0-100 (default 35 — deliberately quiet)
//

import Foundation
import AVFoundation
import DependencyInjection

final class SoundService: @unchecked Sendable {
    private let crossfade: TimeInterval = 1.5
    private let volumeFade: TimeInterval = 0.4
    private let soundDir: URL?
    private let soundFont: URL?

    /// One shared engine drives every voice. Started lazily on first playback and left running.
    private let engine = AVAudioEngine()
    private var channels: [String: ChannelVoice] = [:]     // main-queue only
    /// A pool of persistent one-shot player nodes, pre-attached and pre-connected ONCE (see
    /// `buildOneShotPool`) so firing an effect never mutates the running engine graph. Attaching/
    /// connecting a node to a live engine reconfigures a mixer input bus, which silently swallows roughly
    /// the first ~0.3s of that input — long effects (a 0.55s door) survive it, but a 0.2s footstep
    /// vanishes entirely. Reusing pre-wired nodes avoids the reconfiguration, so short effects play.
    /// Round-robin; all connected at `oneShotFormat`, so decoded files are converted to it before use.
    private var oneShotPool: [AVAudioPlayerNode] = []       // main-queue only
    private var oneShotFormat: AVAudioFormat?               // the pool's shared connection format
    private var oneShotNext = 0                             // round-robin cursor
    private static let oneShotPoolSize = 12
    /// Looping-music channels reuse a SECOND pre-wired pool, same rationale as the one-shot pool: starting
    /// or swapping music must NEVER attach/connect/detach a node on the running engine. That live graph
    /// mutation on the main thread is what deadlocked the whole app when music kicked in (notably via
    /// dclient's `soundtrack/` sound tags). Pool nodes are wired once at the fixed `channelFormat`; loop
    /// buffers are decoded AND converted to it OFF the main queue, so the main queue only schedules/plays.
    private let channelFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    /// Ogg decode (AVAudioFile read + PCM convert) is heavy — 1–2 MB soundtracks take real time. It MUST NOT
    /// run on the caller's thread: play()/playOnce() are invoked from Lua under the process-wide script lock
    /// on the inbound-processing queue, so a synchronous decode there freezes ALL inbound game data (the
    /// area-exit / post-combat lag — an area change pushes two new soundtracks + effects at once). Decode
    /// here instead, then hop to main to schedule. Serial: decodes are quick individually and this bounds
    /// concurrent memory; a big music decode can't starve the render.
    private let decodeQueue = DispatchQueue(label: "com.mudclient.sound.decode", qos: .userInitiated)
    private var channelPool: [AVAudioPlayerNode] = []       // main-queue only, pre-wired once
    private var channelAssign: [String: Int] = [:]          // channel name -> channelPool index
    private static let channelPoolSize = 4
    /// Two independent volumes (0…1), only touched on the main queue. Looping music sits UNDER the game
    /// text (quieter); one-shot effects (footsteps, spells) are more present so they actually register.
    private var musicVolume: Float
    private var effectVolume: Float

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
            musicVolume = max(0, min(1, n / 100))
        } else {
            musicVolume = 0.6
        }
        effectVolume = 1.0
    }

    /// Start (or replace) `track` on `channel`, crossfading over whatever was there. `track` may be a
    /// full path the caller resolved itself, or a bare name to look up under the configured sound dir.
    /// No-op if nothing matches.
    func play(channel: String, track: String) {
        guard let file = resolve(track) else { return }
        let ext = file.pathExtension.lowercased()
        if ext == "mid" || ext == "midi" {
            // MIDI plays through AVMIDIPlayer, which is independent of the shared engine graph.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let old = self.channels[channel]
                let voice = MidiVoice(url: file, soundFont: self.soundFont)
                self.channels[channel] = voice
                voice.start()
                old?.stop()
            }
            return
        }
        // Decode AND convert to the pool format on the decode queue (NOT the caller's inbound thread — see
        // decodeQueue), then hop to main to schedule the ready buffer on a pooled node. Main never touches
        // the engine graph, so it can't deadlock.
        decodeQueue.async { [weak self] in
            guard let self,
                  let audio = try? AVAudioFile(forReading: file), audio.length > 0,
                  let src = AVAudioPCMBuffer(pcmFormat: audio.processingFormat,
                                             frameCapacity: AVAudioFrameCount(audio.length)),
                  (try? audio.read(into: src)) != nil,
                  let buffer = self.convert(src, to: self.channelFormat)
            else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.startEngine(), let node = self.claimChannelNode(for: channel) else { return }
                self.channels[channel]?.stop()          // stop whatever was on this channel (same pooled node)
                node.stop()
                let voice = PooledChannelVoice(node: node, buffer: buffer)
                self.channels[channel] = voice
                voice.volume = 0
                voice.start()
                self.fade(voice, to: self.musicVolume, duration: self.crossfade)
            }
        }
    }

    /// Play `track` ONCE (a sound effect — footsteps, spell casts, etc.), overlapping anything already
    /// playing. The node is retained until it finishes so it isn't cut off. No-op if nothing matches.
    func playOnce(track: String) {
        guard let file = resolve(track) else { return }
        // Decode the whole file up front into a resident PCM buffer — but on the decode queue, NOT the
        // caller's inbound thread (see decodeQueue: a synchronous decode there stalls all inbound game text
        // behind the sound — the "heard the effect, text arrived seconds later" lag). One-shots are small,
        // so this is quick; then hop to main to schedule.
        decodeQueue.async { [weak self] in
            guard let self,
                  let audio = try? AVAudioFile(forReading: file),
                  audio.length > 0,
                  let src = AVAudioPCMBuffer(pcmFormat: audio.processingFormat,
                                             frameCapacity: AVAudioFrameCount(audio.length)),
                  (try? audio.read(into: src)) != nil
            else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.startEngine(), let fmt = self.oneShotFormat,
                      !self.oneShotPool.isEmpty else { return }
            // The pool's nodes render at `fmt`, so a buffer must match it (source files vary in rate/
            // channel count). Convert if needed; skip the effect rather than risk a format-mismatch crash.
            guard let buffer = self.convert(src, to: fmt) else { return }
            let node = self.oneShotPool[self.oneShotNext % self.oneShotPool.count]
            self.oneShotNext += 1
            // Reset the node (it may still be tailing an earlier effect — with 12 nodes that's long done)
            // then queue and play this buffer. No attach/connect, so the live graph is never reconfigured.
            node.stop()
            node.volume = self.effectVolume
            node.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
            node.play()
            }
        }
    }

    /// Fade out and stop `channel`.
    func stop(channel: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let voice = self.channels.removeValue(forKey: channel) else { return }
            self.fade(voice, to: 0, duration: self.crossfade) { voice.stop() }
        }
    }

    /// Set the looping-music volume (0-100%), fading any currently-playing channels to the new level.
    func setMusicVolume(percent: Double) {
        let v = Float(max(0, min(100, percent)) / 100)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.musicVolume = v
            for voice in self.channels.values { self.fade(voice, to: v, duration: self.volumeFade) }
        }
    }

    /// Set the one-shot sound-effect volume (0-100%). Applies to effects started afterward.
    func setEffectVolume(percent: Double) {
        let v = Float(max(0, min(100, percent)) / 100)
        DispatchQueue.main.async { [weak self] in self?.effectVolume = v }
    }

    /// Cut everything immediately (e.g. on disconnect): stop every channel voice and every pooled
    /// node, then clear the channel bookkeeping. Like `stop(channel:)`, this only stops playback — it
    /// never detaches pool nodes from the engine (see the pool comments above for why).
    func stopAll() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for voice in self.channels.values { voice.stop() }
            self.channels.removeAll()
            self.channelAssign.removeAll()
            for node in self.oneShotPool { node.stop() }
            for node in self.channelPool { node.stop() }
        }
    }

    // MARK: - Internals

    /// Ensure the shared engine is running before wiring up a node. Returns false if it can't start
    /// (no output device, etc.) so callers no-op rather than crash. Main queue only.
    @discardableResult
    private func startEngine() -> Bool {
        if engine.isRunning { buildOneShotPool(); buildChannelPool(); return true }
        _ = engine.mainMixerNode          // instantiating the mixer also connects it to the output node
        do { try engine.start() } catch { return false }
        buildOneShotPool()
        buildChannelPool()
        return true
    }

    /// Pre-wire the looping-channel node pool once, right after the engine starts (same one-time-only
    /// rationale as `buildOneShotPool`). Connected at the fixed `channelFormat` so loop buffers can be
    /// converted to it off the main queue ahead of time — the main queue never mutates the graph.
    private func buildChannelPool() {
        guard channelPool.isEmpty else { return }
        for _ in 0..<Self.channelPoolSize {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: channelFormat)
            channelPool.append(node)
        }
    }

    /// Return the pre-wired pool node dedicated to `channel`, assigning a free slot on first use. Falls
    /// back to slot 0 if more channels are live than the pool holds (rare — usually just "music").
    private func claimChannelNode(for channel: String) -> AVAudioPlayerNode? {
        guard !channelPool.isEmpty else { return nil }
        if let i = channelAssign[channel], i < channelPool.count { return channelPool[i] }
        let used = Set(channelAssign.values)
        let slot = (0..<channelPool.count).first(where: { !used.contains($0) }) ?? 0
        channelAssign[channel] = slot
        return channelPool[slot]
    }

    /// Pre-wire the one-shot node pool exactly once, right after the engine is running. Doing all the
    /// attach/connect here (before any effect fires) means later `playOnce` calls only schedule buffers —
    /// no per-effect graph reconfiguration, which is what was clipping short effects to silence.
    private func buildOneShotPool() {
        guard oneShotPool.isEmpty else { return }
        // The mixer's output format is only meaningful once the engine has started; it's the natural
        // common format for every one-shot (files get converted into it).
        let fmt = engine.mainMixerNode.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0 else { return }
        oneShotFormat = fmt
        for _ in 0..<Self.oneShotPoolSize {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: fmt)
            oneShotPool.append(node)
        }
    }

    /// Convert a decoded buffer into `fmt` (the pool's render format). Returns `src` unchanged when it
    /// already matches. Nil only if a converter can't be built or the conversion errors.
    private func convert(_ src: AVAudioPCMBuffer, to fmt: AVAudioFormat) -> AVAudioPCMBuffer? {
        if src.format == fmt { return src }
        guard let converter = AVAudioConverter(from: src.format, to: fmt) else { return nil }
        let ratio = fmt.sampleRate / src.format.sampleRate
        let capacity = AVAudioFrameCount(Double(src.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inStatus in
            if supplied { inStatus.pointee = .noDataNow; return nil }
            supplied = true; inStatus.pointee = .haveData; return src
        }
        return status == .error ? nil : out
    }

    /// Linearly ramp a voice's volume over `duration`, stepping on the main queue. AVAudioPlayerNode has
    /// no built-in fade (unlike AVAudioPlayer's `setVolume(_:fadeDuration:)`), so we do it by hand.
    private func fade(_ voice: ChannelVoice, to target: Float, duration: TimeInterval, then done: (() -> Void)? = nil) {
        let steps = 20
        let start = voice.volume
        let dt = max(0.001, duration / Double(steps))
        for i in 1...steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + dt * Double(i)) { [weak voice] in
                guard let voice else { return }
                voice.volume = start + (target - start) * Float(i) / Float(steps)
                if i == steps { done?() }
            }
        }
    }

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
}

/// A single channel's looping voice. All calls happen on the main queue. `volume` is the crossfade
/// knob; `start` begins playback; `stop` ends it and releases any engine resources.
private protocol ChannelVoice: AnyObject {
    var volume: Float { get set }
    func start()
    func stop()
}

/// A looping voice on a PRE-WIRED pool node. `stop` only stops playback — it never detaches from the
/// engine (that live graph mutation on the main thread is exactly what deadlocked the app), so the node
/// is reused for the channel's next track.
private final class PooledChannelVoice: ChannelVoice {
    private let node: AVAudioPlayerNode
    private let buffer: AVAudioPCMBuffer
    init(node: AVAudioPlayerNode, buffer: AVAudioPCMBuffer) { self.node = node; self.buffer = buffer }
    var volume: Float {
        get { node.volume }
        set { node.volume = newValue }
    }
    func start() {
        node.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
        node.play()
    }
    func stop() { node.stop() }   // NO detach — the pooled node stays wired to the engine
}

/// Looping MIDI (.mid/.midi) via AVMIDIPlayer + a soundfont (or the system GM set). AVMIDIPlayer has no
/// volume control, so MIDI channels switch rather than crossfade — good enough for ambience.
private final class MidiVoice: ChannelVoice {
    private var player: AVMIDIPlayer?
    private var stopped = false
    init(url: URL, soundFont: URL?) {
        player = try? AVMIDIPlayer(contentsOf: url, soundBankURL: soundFont)
        player?.prepareToPlay()
    }
    var volume: Float {
        get { 1 }
        set { }                              // AVMIDIPlayer exposes no volume; ignore fades
    }
    func start() { loop() }
    private func loop() {
        guard !stopped, let p = player else { return }
        p.currentPosition = 0
        p.play { [weak self] in DispatchQueue.main.async { self?.loop() } }   // restart on finish = loop
    }
    func stop() { stopped = true; player?.stop() }
}

extension Container {
    static let soundService = Factory(scope: .cached) { SoundService() }
}
