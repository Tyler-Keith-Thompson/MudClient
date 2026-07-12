//
//  TranscriptStore.swift
//  MudClient
//
//  A game-agnostic, in-memory transcript of the session: every line sent to the server (tagged with its
//  origin — typed by the user, or issued by a script/the AI pilot), every line received from it, and every
//  local ECHO (script `echo(...)` output + the `↗/↙ claude` dispatch lines — anything the client printed
//  that never went over the wire either way). Feeds the `#grep` / `#sent` / `#received` REPL commands.
//  Host-level, like SessionLog and the terminal scrollback — nothing in here knows anything about AlterAeon.
//
//  Bounded (a ring, capped at `limit`) so a long session can't grow it without end. Received lines are the
//  DISPLAYED server output (post-gag/rewrite, ANSI intact); ANSI is stripped for matching and on read.
//

import Foundation
import DependencyInjection

final class TranscriptStore: @unchecked Sendable {
    /// `.echo` = a locally-generated line (script `echo(...)`, the `↗/↙ claude` dispatch lines) — printed
    /// to the terminal but never sent to or received from the server. Grep-able like the other two.
    enum Kind: Sendable { case sent, received, echo }

    struct Entry: Sendable {
        let kind: Kind
        /// Origin of a `.sent` line (`.user` = typed manually, `.script` = a script/AI pilot send).
        /// `nil` for `.received` and `.echo`.
        let origin: CommandOrigin?
        /// The line as it went over the wire (sent) or was displayed (received), ANSI intact.
        let text: String
        /// Wall-clock instant the line was recorded. Lets consumers (e.g. the `#claude` dispatch
        /// bundle) render an interleaved, timestamped picture of sends and receives.
        let at: Date
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private let limit: Int

    init(limit: Int = 10_000) { self.limit = limit }

    // MARK: Recording

    func recordSent(_ text: String, origin: CommandOrigin) {
        append(Entry(kind: .sent, origin: origin, text: text, at: Date()))
    }

    func recordReceived(_ text: String) {
        append(Entry(kind: .received, origin: nil, text: text, at: Date()))
    }

    /// Record a locally-echoed line (script `echo(...)`, `↗/↙ claude`) so `#grep` can find it. NOT called
    /// for the `#grep`/`#sent`/`#received` dump output itself — those render straight to the echo sink,
    /// bypassing this, so viewing the transcript never re-appends to it.
    func recordEcho(_ text: String) {
        append(Entry(kind: .echo, origin: nil, text: text, at: Date()))
    }

    private func append(_ entry: Entry) {
        lock.lock(); defer { lock.unlock() }
        entries.append(entry)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
    }

    // MARK: Queries (all return oldest-first, chronological)

    /// The last `n` sent lines (all of them when `n` is nil / non-positive).
    func sent(last n: Int?) -> [Entry] { tail(where: { $0.kind == .sent }, n) }

    /// The last `n` received lines.
    func received(last n: Int?) -> [Entry] { tail(where: { $0.kind == .received }, n) }

    /// The last `n` entries of EVERY kind, interleaved in the order they occurred (oldest-first). This
    /// is the timestamped picture the `#claude` dispatch bundle renders: your sends, script/AI sends,
    /// and displayed server lines, together on one timeline.
    func chronological(last n: Int?) -> [Entry] { tail(where: { _ in true }, n) }

    /// Every entry (sent, received AND echo) whose ANSI-stripped text contains `needle`, case-insensitively.
    func grep(_ needle: String) -> [Entry] {
        let target = needle.lowercased()
        guard !target.isEmpty else { return [] }
        lock.lock(); defer { lock.unlock() }
        return entries.filter { Self.strip($0.text).lowercased().contains(target) }
    }

    private func tail(where predicate: (Entry) -> Bool, _ n: Int?) -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        let matched = entries.filter(predicate)
        if let n = n, n > 0, matched.count > n { return Array(matched.suffix(n)) }
        return matched
    }

    // MARK: ANSI

    private static let ansi = try! Regex(#"\u{1B}\[[0-9;?]*[ -/]*[@-~]"#)
    static func strip(_ s: String) -> String { s.replacing(ansi, with: "") }
}

extension Container {
    static let transcriptStore = Factory(scope: .cached) { TranscriptStore() }
}
