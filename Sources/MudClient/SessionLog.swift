//
//  SessionLog.swift
//  MudClient
//
//  A plain-text session log (TinTin++ `#log`): every DISPLAYED server line, and optionally every
//  sent command, appended to a file as it happens. Scripts drive it through the `log_start` /
//  `log_stop` / `log_active` builtins; the host feeds it from the live server-output and outbound
//  paths (see MudClient.swift). Replayed lines are deliberately NOT routed here — a replay must never
//  masquerade as live traffic.
//
//  Writes go straight through a FileHandle (one `write` per line) so the log is effectively
//  line-buffered and survives a crash without an explicit flush. Everything is serialized by `lock`.
//

import DependencyInjection
import Foundation

final class SessionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?
    private var _path: String?
    private var timestamps = false
    private var stripAnsi = true     // opts.ansi == false (the default) → strip escapes to plain text
    private var commands = false     // opts.commands == true → also log outbound commands

    /// Matches CSI escape sequences (colours, cursor moves) so a plain-text log carries no control bytes.
    /// Same shape as the engine's trigger-stripping regex.
    private let ansiSequence = try! Regex("\u{1B}\\[[0-9;?]*[ -/]*[@-~]")

    private let clock: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Open (or reopen) the log at `path`, appending if the file already exists. Returns whether the
    /// log is now active. `ansi == true` keeps escape codes verbatim; the default strips them.
    @discardableResult
    func start(path: String, timestamps: Bool, ansi: Bool, commands: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil)
        }
        guard let h = FileHandle(forWritingAtPath: path) else {
            _path = nil
            return false
        }
        h.seekToEndOfFile()   // append mode
        handle = h
        _path = path
        self.timestamps = timestamps
        self.stripAnsi = !ansi
        self.commands = commands
        return true
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        try? handle?.close()
        handle = nil
        _path = nil
    }

    /// (active, path). `path` is nil when inactive.
    func status() -> (Bool, String?) {
        lock.lock(); defer { lock.unlock() }
        return (handle != nil, _path)
    }

    /// Log a displayed server-output chunk. The chunk may hold several newline-separated lines (or
    /// none); each line is written on its own row so the log stays replay-friendly.
    func logServer(_ chunk: String) {
        lock.lock(); defer { lock.unlock() }
        guard handle != nil, !chunk.isEmpty else { return }
        for line in chunk.split(separator: "\n", omittingEmptySubsequences: false) {
            writeLine(String(line))
        }
    }

    /// Log one outbound command (only when opts.commands was set).
    func logCommand(_ command: String) {
        lock.lock(); defer { lock.unlock() }
        guard handle != nil, commands else { return }
        writeLine(command)
    }

    /// Caller holds `lock`. Strips ANSI (unless configured otherwise), prefixes an ISO-8601 timestamp
    /// (when enabled), and writes the line plus a trailing newline.
    private func writeLine(_ raw: String) {
        guard let handle else { return }
        var text = stripAnsi ? raw.replacing(ansiSequence, with: "") : raw
        if timestamps { text = clock.string(from: Date()) + " " + text }
        handle.write(Data((text + "\n").utf8))
    }
}

extension Container {
    static let sessionLog = Factory(scope: .cached) { SessionLog() }
}
