//
//  DispatchBundle.swift
//  MudClient
//
//  Builds the context bundle behind the in-game `#claude <feedback>` command: a self-contained folder
//  under /tmp that a Claude Code session (loaded with the `muddispatch` channel) can read to work on the
//  feedback with full context of what just happened in the game.
//
//  The bundle is:
//    * dispatch.md — the freeform feedback, followed by a timestamped, INTERLEAVED transcript of what you
//      typed, what the Lua scripts / AI pilot sent, and what the server displayed. TranscriptStore already
//      holds all three kinds in one chronological ring; we just stamp and render them on one timeline.
//    * raw.log — a copy of the raw wire capture (MUD_RAW_LOG / mud_raw.log), the base64 byte-exact stream,
//      for when the displayed transcript isn't enough (IAC/MSP/gag debugging). Bonus, best-effort.
//
//  Host-level and game-agnostic, like TranscriptStore / RawCapture / SessionLog — nothing here is
//  AlterAeon-specific.
//

import Foundation
import DependencyInjection

enum DispatchBundle {
    /// Build a bundle for `feedback`, rendering the most recent `entries` transcript lines. Returns the
    /// bundle directory and the `dispatch.md` path, or nil if the directory couldn't be created.
    static func build(feedback: String, entries: Int = 400) -> (dir: URL, markdown: URL)? {
        let now = Date()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mud-dispatch", isDirectory: true)
            .appendingPathComponent(stamp(now), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        let log = renderTranscript(Container.transcriptStore().chronological(last: entries))
        let raw = copyRawLog(into: dir)

        var md = "# MudClient dispatch — \(iso(now))\n\n"
        md += "## Feedback\n\n\(feedback.trimmingCharacters(in: .whitespacesAndNewlines))\n\n"
        md += "## Session transcript (interleaved, most recent \(entries) events)\n\n"
        md += "Each line: `HH:MM:SS.mmm  origin  text` — `you` = you typed it, `lua` = a script / the AI "
        md += "pilot sent it, `srv` = displayed server output (ANSI stripped).\n\n"
        md += "```\n\(log.isEmpty ? "(no transcript recorded yet)" : log)\n```\n"
        if let raw {
            md += "\nRaw wire capture (byte-exact, base64 per line) copied alongside as `\(raw)`.\n"
        }

        let markdown = dir.appendingPathComponent("dispatch.md")
        do {
            try md.write(to: markdown, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        return (dir, markdown)
    }

    // MARK: Rendering

    private static func renderTranscript(_ entries: [TranscriptStore.Entry]) -> String {
        entries.map { e in
            let label: String
            switch (e.kind, e.origin) {
            case (.sent, .user):   label = "you"
            case (.sent, .script): label = "lua"
            case (.sent, _):       label = "snd"
            case (.received, _):   label = "srv"
            }
            let text = TranscriptStore.strip(e.text).trimmingCharacters(in: .newlines)
            return "\(clock(e.at))  \(label)  \(text)"
        }.joined(separator: "\n")
    }

    /// Copy the raw wire capture into the bundle. Returns the destination filename, or nil if there was
    /// nothing to copy. Mirrors RawCapture's path resolution (MUD_RAW_LOG, default `mud_raw.log` in CWD).
    private static func copyRawLog(into dir: URL) -> String? {
        let env = ProcessInfo.processInfo.environment["MUD_RAW_LOG"]
        if env == "" || env?.lowercased() == "off" { return nil }
        let src = URL(fileURLWithPath: env ?? "mud_raw.log")
        guard FileManager.default.fileExists(atPath: src.path) else { return nil }
        let dst = dir.appendingPathComponent("raw.log")
        do {
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.copyItem(at: src, to: dst)
            return "raw.log"
        } catch {
            return nil
        }
    }

    // MARK: Timestamps

    /// Bundle directory name: `yyyyMMdd-HHmmss-SSS-<rand>` — sortable, filesystem-safe, and unique even
    /// for two dispatches fired within the same millisecond (the random suffix breaks the tie).
    private static func stamp(_ d: Date) -> String {
        let rand = String(format: "%04x", Int.random(in: 0..<0x10000))
        return "\(fmt("yyyyMMdd-HHmmss-SSS", d))-\(rand)"
    }
    /// `HH:mm:ss.SSS` per transcript line.
    private static func clock(_ d: Date) -> String { fmt("HH:mm:ss.SSS", d) }
    /// ISO-8601-ish header timestamp.
    private static func iso(_ d: Date) -> String { fmt("yyyy-MM-dd HH:mm:ss", d) }

    private static func fmt(_ format: String, _ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f.string(from: d)
    }
}
