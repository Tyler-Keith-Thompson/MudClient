//
//  LagMonitor.swift
//  MudClient
//
//  Distinguishes two very different kinds of "lag" so the HUD can tell them apart:
//
//    1. UI hitch  — the terminal's own event loop (rendering + input) stalling. Everything user-facing
//       runs on the MAIN DispatchQueue (see MudClient.swift: the stdin source, SIGWINCH, and every
//       TerminalService render). A repeating heartbeat scheduled on `.main` measures its own scheduling
//       DRIFT: if a tick due at T actually fires at T+350ms, the main loop was blocked ~350ms — a UI
//       hitch of that duration. This is purely local; the network is irrelevant. (A Lua `every` timer
//       could NOT measure this — those fire on a separate `lua.timer` queue, not main.)
//
//    2. Network round-trip — the server's responsiveness. Measured passively (no extra traffic): stamp
//       the time we send a command, then when the next GO-AHEAD prompt arrives, that delta is roughly
//       the round-trip (plus the server's small per-command processing). See ConnectionManager.send
//       (noteSend) and LuaScriptEngine.notifyPrompt (notePrompt).
//
//  All times use the monotonic uptime clock (DispatchTime), immune to wall-clock changes. Lua pulls a
//  snapshot via the `lag_status()` builtin each HUD repaint; the widget lives in Scripts/AlterAeon/HUD.lua.
//

import Foundation
import DependencyInjection

/// A latency snapshot handed to Lua. Ages are milliseconds since the sample; a negative age means
/// "never measured yet" (so the widget can stay hidden until there's something real to show).
struct LagSnapshot {
    var uiHitchMs: Double
    var uiHitchAgeMs: Double
    var netRttMs: Double
    var netRttAgeMs: Double
}

final class LagMonitor: @unchecked Sendable {
    private let lock = NSLock()

    // UI-hitch (main-queue drift).
    private var uiHitchMs: Double = 0
    private var uiHitchAt: DispatchTime = .now()
    private var hadUIHitch = false

    // Network round-trip (send -> next prompt).
    private var lastSend: DispatchTime?
    private var netRttMs: Double = 0
    private var netRttAt: DispatchTime = .now()
    private var hadRtt = false

    private var started = false

    /// How often the heartbeat ticks. Fast enough to catch a noticeable hitch, slow enough to be free.
    private let interval: Double = 0.25
    /// Only drift beyond this is worth calling a "hitch" (below it is normal scheduler jitter).
    private let hitchThresholdMs: Double = 80

    private static func ms(from a: DispatchTime, to b: DispatchTime) -> Double {
        Double(b.uptimeNanoseconds &- a.uptimeNanoseconds) / 1_000_000
    }

    /// Begin the main-queue heartbeat. Idempotent; call once at launch.
    func start() {
        lock.lock(); let already = started; started = true; lock.unlock()
        guard !already else { return }
        let first = DispatchTime.now() + interval
        DispatchQueue.main.asyncAfter(deadline: first) { [weak self] in self?.tick(due: first) }
    }

    private func tick(due deadline: DispatchTime) {
        let now = DispatchTime.now()
        let driftMs = Self.ms(from: deadline, to: now)   // how late this tick fired = how long main blocked
        if driftMs > hitchThresholdMs {
            lock.lock(); uiHitchMs = driftMs; uiHitchAt = now; hadUIHitch = true; lock.unlock()
        }
        // Re-anchor to `now` (not deadline) so we never chase a backlog after a long stall.
        let next = now + interval
        DispatchQueue.main.asyncAfter(deadline: next) { [weak self] in self?.tick(due: next) }
    }

    /// Stamp the moment we hand a command to the wire (ConnectionManager.send).
    func noteSend() {
        lock.lock(); lastSend = DispatchTime.now(); lock.unlock()
    }

    /// A GO-AHEAD prompt arrived — pair it with the most recent send for a round-trip sample. Prompts
    /// with no pending send (idle server output) are ignored, and each send pairs at most once.
    func notePrompt() {
        let now = DispatchTime.now()
        lock.lock(); defer { lock.unlock() }
        guard let s = lastSend else { return }
        netRttMs = Self.ms(from: s, to: now); netRttAt = now; hadRtt = true; lastSend = nil
    }

    func snapshot() -> LagSnapshot {
        lock.lock(); defer { lock.unlock() }
        let now = DispatchTime.now()
        return LagSnapshot(
            uiHitchMs: hadUIHitch ? uiHitchMs : 0,
            uiHitchAgeMs: hadUIHitch ? Self.ms(from: uiHitchAt, to: now) : -1,
            netRttMs: hadRtt ? netRttMs : 0,
            netRttAgeMs: hadRtt ? Self.ms(from: netRttAt, to: now) : -1)
    }
}

extension Container {
    static let lagMonitor = Factory(scope: .cached) { LagMonitor() }
}
