//
//  ClaudeInboxWatcher.swift
//  MudClient
//
//  The RETURN leg of the `muddispatch` channel. `#claude <feedback>` (see the `claude` builtin in
//  LuaScriptEngine + DispatchBundle) pushes feedback OUT to a running Claude Code session as a
//  `↗ claude` line. This watches the file inbox Claude writes back to and echoes each reply IN as a
//  `↙ claude` line (mirroring the outbound styling), then archives the file so it renders exactly once.
//
//  Transport is a plain file inbox — no new Lua builtin or `on_*` host hook (which would each need a
//  doc()/driver stub per CLAUDE.md): the MCP tool `report_to_game` (tools/dispatch/mud-channel.mjs)
//  drops a `<ts>-<rand>.json` file into `~/Documents/MudClient/claude-inbox/`; we watch that folder
//  (a DispatchSource vnode notification on the directory plus a startup scan to pick up files written
//  while the app was down, backstopped by a slow main-queue poll), parse `{message, action, ts}`,
//  echo it, and move the file to `claude-inbox/archive/`. All terminal printing is on the main queue.
//

import Foundation
import DependencyInjection

/// One reply Claude wrote back into the game. `action` is an optional single command the player should
/// run next (e.g. `#reload`, `just run`); empty means "no suggested action".
struct ClaudeReply: Equatable {
    var message: String
    var action: String
    var ts: String
}

/// Pure parse + format for a Claude reply — no filesystem, no side effects, so it's unit-testable in
/// isolation (given a reply JSON → the exact styled line(s)).
enum ClaudeReplyRenderer {
    /// Parse a reply JSON payload. Returns nil for corrupt/unparseable data or an empty `message`.
    static func parse(_ data: Data) -> ClaudeReply? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let message = obj["message"] as? String else { return nil }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let action = (obj["action"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let ts = (obj["ts"] as? String) ?? ""
        return ClaudeReply(message: trimmed, action: action, ts: ts)
    }

    /// The styled terminal text for a reply — one `↙ claude` line, plus a second aligned `→ run …` line
    /// when an action is suggested. Bold BRIGHT cyan (1;96) so replies pop out of the game stream; the
    /// whole message line is coloured (not just the arrow) so it's unmistakable at a glance. The action
    /// line is indented 10 cols so it sits under the message text.
    static func render(_ reply: ClaudeReply) -> String {
        var out = "\u{1B}[1;96m↙ claude  \(reply.message)\u{1B}[0m"
        if !reply.action.isEmpty {
            out += "\n          \u{1B}[1;96m→ run \(reply.action)\u{1B}[0m"
        }
        return out
    }
}

/// Watches the Claude reply inbox and echoes each reply into the terminal, once. Filesystem paths are
/// injectable (`inboxDir`) so tests point it at a temp dir; the `emit` sink defaults to the same echo
/// path the outbound `↗ claude` line uses (`terminalService().print(_, isEcho: true)`).
final class ClaudeInboxWatcher: @unchecked Sendable {
    private let inboxDir: URL
    private let archiveDir: URL
    private let emit: (String) -> Void

    private let lock = NSLock()
    private var started = false
    private var source: DispatchSourceFileSystemObject?
    private var dirFD: Int32 = -1

    /// Slow backstop poll: the vnode source catches almost everything, but a coalesced/dropped event
    /// (or an editor's atomic rename) can be missed, so we also sweep on a lazy cadence.
    private let pollInterval: Double = 2.0

    init(inboxDir: URL? = nil, emit: ((String) -> Void)? = nil) {
        let dir = inboxDir ?? Self.defaultInboxDir()
        self.inboxDir = dir
        self.archiveDir = dir.appendingPathComponent("archive", isDirectory: true)
        self.emit = emit ?? { line in
            // Record into the searchable transcript so `#grep claude` surfaces replies, then print. Tests
            // inject their own `emit`, so this recording only runs in the real app.
            Container.transcriptStore().recordEcho(line)
            Container.terminalService().print(line, isEcho: true)
        }
    }

    /// Default inbox: `~/Documents/MudClient/claude-inbox`, overridable via `MUD_DISPATCH_INBOX` (same
    /// knob the MCP server honors).
    static func defaultInboxDir() -> URL {
        if let override = ProcessInfo.processInfo.environment["MUD_DISPATCH_INBOX"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/MudClient/claude-inbox", isDirectory: true)
    }

    /// Ensure the inbox exists, drain anything already waiting, and begin watching. Idempotent.
    func start() {
        lock.lock(); let already = started; started = true; lock.unlock()
        guard !already else { return }
        ensureDirs()
        // Pick up files written while the app was down.
        DispatchQueue.main.async { [weak self] in self?.drain() }
        startVnodeSource()
        schedulePoll()
    }

    // MARK: - Watching

    private func startVnodeSource() {
        let fd = open(inboxDir.path, O_EVTONLY)
        guard fd >= 0 else { return }   // no vnode watch; the poll backstop still drains
        dirFD = fd
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in self?.drain() }
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()
    }

    private func schedulePoll() {
        DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) { [weak self] in
            guard let self else { return }
            self.drain()
            self.schedulePoll()
        }
    }

    // MARK: - Draining (main queue only)

    private func ensureDirs() {
        try? FileManager.default.createDirectory(at: inboxDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)
    }

    /// Process every pending `*.json` reply file in name order, echo it, and archive it. Public so tests
    /// can drive one deterministic pass. Corrupt/unparseable files are logged and archived, never fatal.
    /// Returns the number of files processed.
    @discardableResult
    func drain() -> Int {
        ensureDirs()
        let fm = FileManager.default
        let files: [URL]
        do {
            files = try fm.contentsOfDirectory(at: inboxDir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            return 0
        }
        var processed = 0
        for file in files {
            defer { archive(file) }
            processed += 1
            guard let data = try? Data(contentsOf: file), let reply = ClaudeReplyRenderer.parse(data) else {
                FileHandle.standardError.write(
                    Data("[claude-inbox] skipping unparseable reply \(file.lastPathComponent)\n".utf8))
                continue
            }
            emit(ClaudeReplyRenderer.render(reply))
        }
        return processed
    }

    /// Move a processed file into `archive/` (falling back to delete) so it's never rendered twice.
    private func archive(_ file: URL) {
        let fm = FileManager.default
        let dst = archiveDir.appendingPathComponent(file.lastPathComponent)
        try? fm.removeItem(at: dst)
        do { try fm.moveItem(at: file, to: dst) }
        catch { try? fm.removeItem(at: file) }
    }
}

extension Container {
    static let claudeInboxWatcher = Factory(scope: .cached) { ClaudeInboxWatcher() }
}
