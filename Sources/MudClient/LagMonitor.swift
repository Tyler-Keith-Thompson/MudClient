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

    // Watchdog: the main-queue heartbeat below stops firing the instant the main loop wedges (a stuck
    // stdout write, an engine-lock deadlock). `lastTickAt` is the freshness stamp; an INDEPENDENT thread
    // (not the main queue, not the telnet pump, no engine lock) watches it and force-recovers the tty +
    // exits if it goes stale past `wedgeThresholdMs` — so a hang no longer means Ctrl-C-dead + a dead
    // terminal, it means a clean drop back to the shell to restart.
    private var lastTickAt: DispatchTime = .now()
    private var watchdogStarted = false
    /// Main is considered WEDGED (not merely hitching) once the heartbeat is this stale. Far beyond any
    /// legitimate main-loop pause (a big repaint, a `#reload`) so it never false-fires; the real wedge is
    /// permanent, so any value in the 8–20s range catches it.
    private let wedgeThresholdMs: Double = 15_000
    /// How often the watchdog thread wakes to check freshness.
    private let watchdogPollSec: Double = 1.0

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
        lock.lock(); lastTickAt = .now(); lock.unlock()
        let first = DispatchTime.now() + interval
        DispatchQueue.main.asyncAfter(deadline: first) { [weak self] in self?.tick(due: first) }
        startWatchdog()
    }

    private func tick(due deadline: DispatchTime) {
        let now = DispatchTime.now()
        let driftMs = Self.ms(from: deadline, to: now)   // how late this tick fired = how long main blocked
        lock.lock()
        lastTickAt = now                                 // heartbeat freshness stamp for the watchdog
        if driftMs > hitchThresholdMs { uiHitchMs = driftMs; uiHitchAt = now; hadUIHitch = true }
        lock.unlock()
        // Re-anchor to `now` (not deadline) so we never chase a backlog after a long stall.
        let next = now + interval
        DispatchQueue.main.asyncAfter(deadline: next) { [weak self] in self?.tick(due: next) }
    }

    /// Spin up the independent watchdog thread. A raw `Thread` (not a GCD queue) so it can never be
    /// starved by the very main queue it's watching, and it takes no lock the wedged loop could hold.
    private func startWatchdog() {
        lock.lock(); let already = watchdogStarted; watchdogStarted = true; lock.unlock()
        guard !already else { return }
        let t = Thread { [weak self] in
            var strikes = 0
            while true {
                Thread.sleep(forTimeInterval: self?.watchdogPollSec ?? 1.0)
                guard let self else { return }
                self.lock.lock()
                let ageMs = Self.ms(from: self.lastTickAt, to: .now())
                let threshold = self.wedgeThresholdMs
                self.lock.unlock()
                // Require TWO consecutive stale samples so a clock jump around system sleep/wake (where
                // the heartbeat and this thread were both suspended) can't trip a false recovery.
                if ageMs > threshold {
                    strikes += 1
                    if strikes >= 2 { self.recoverFromWedge(ageMs: ageMs); return }
                } else {
                    strikes = 0
                }
            }
        }
        t.name = "mudclient.watchdog"
        t.stackSize = 512 * 1024
        t.start()
    }

    /// Main has stopped responding. Log where we can, put the terminal back so the shell is usable, and
    /// exit — a clean drop for the user to restart, instead of a frozen client with a dead tty.
    private func recoverFromWedge(ageMs: Double) {
        let secs = Int((ageMs / 1000).rounded())
        let msg = "[watchdog] main loop unresponsive for ~\(secs)s — restoring terminal and exiting."
        // Drop a breadcrumb to a log file (best-effort) BEFORE touching the tty, so we have a record even
        // if the terminal writes below are dropped. This is the diagnostic the live hang never let us grab.
        let logLine = "\(Date()) \(msg)\n"
        let logPath = ("~/Documents/MudClient/watchdog.log" as NSString).expandingTildeInPath
        if let data = logLine.data(using: .utf8) {
            if let fh = FileHandle(forWritingAtPath: logPath) {
                fh.seekToEndOfFile(); try? fh.write(contentsOf: data); try? fh.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: logPath))
            }
        }
        TerminalService.emergencyRestore()
        FileHandle.standardError.write(Data(("\r\n" + msg + "\r\n").utf8))
        // `_exit` (not `exit`): skip atexit/stdio flush, which could itself block on the stuck stdout.
        _exit(75)   // EX_TEMPFAIL — "transient failure, retry" fits "restart me"
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
