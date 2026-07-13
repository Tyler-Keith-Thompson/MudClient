//
//  InputService.swift
//  MudClient
//
//  Created by Tyler Thompson on 8/11/24.
//

import Foundation
import Parsing
import DependencyInjection
import Afluent

/// Where an outbound command came from: the user typed it, or a script / the AI pilot issued it. Known
/// unambiguously ONLY at the two InputService entry points (`parse(input:)` = user, `send(verbatim:)` =
/// script); downstream (aliases, pipes, the `on_send` hook) the two are indistinguishable, so we carry
/// the origin through the command stream rather than trying to recover it later.
enum CommandOrigin: Sendable { case user, script }

/// One outbound command plus its origin, flowing through the input pipeline to the transmit point.
struct OutboundCommand: Sendable {
    let text: String
    let origin: CommandOrigin
}

final class InputService: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    /// The last full LINE the user submitted (already `!`-resolved), for the `!` repeat token. A LINE, not
    /// the last atomic command: `drop scroll;sac scroll` is remembered whole, so a later `!` repeats BOTH,
    /// and a `!` pipe stage expands to the whole thing too.
    private var _lastLine: String?
    private var lastLine: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _lastLine
        } set {
            lock.lock()
            defer { lock.unlock() }
            _lastLine = newValue
        }
    }
    private let (stream, continuation) = AsyncThrowingStream<OutboundCommand, any Swift.Error>.makeStream()

    /// Split a command line on the top-level `;` separator, unescaping `\;` → `;` (any other `\x` is left
    /// intact). Mirror of `pipeParser` below — `;` and `|` share ONE declarative escaping implementation
    /// rather than two hand-rolled scanners that could drift. Used both for a plain `a; b` line (each an
    /// independent command) AND for the commands inside a single `|` pipe step (see `semicolonSegments`).
    private static let semicolonParser = Many {
        Many(into: "") { string, fragment in
            string.append(contentsOf: fragment)
        } element: {
            OneOf {
                Prefix(1) { $0 != .init(ascii: ";") && $0 != .init(ascii: "\\") }.map(.string)

                Parse {
                    "\\".utf8
                    OneOf {
                        ";".utf8.map { ";" }
                        Prefix(1).map(.string).map { "\\\($0)" }
                    }
                }
            }
        }
    } separator: {
        ";".utf8
    }

    /// The `;`-separated commands of one line (or one pipe step). A line with no unescaped `;` yields a
    /// single element (itself). Declarative so it shares `semicolonParser`'s escaping with the `;` split
    /// in `parse(input:)`.
    static func semicolonSegments(_ input: String) -> [String] {
        (try? semicolonParser.parse(input)) ?? [input]
    }

    private var subscriptions = Set<AnyCancellable>()
    
    var commandStream: AnyAsyncSequence<OutboundCommand> {
        stream.eraseToAnyAsyncSequence()
    }

    init() { }

    /// Expand the `!` "repeat" token to the last full LINE. It fires whether `!` is the WHOLE line or a
    /// single `|` pipe stage (`drop scroll;sac scroll | !`) — both become `last` (which itself may carry
    /// `;`/`|`, so all of it re-runs). A line with no standalone `!` stage is returned untouched. With no
    /// history yet (`last` nil) a bare `!` resolves to empty (the caller drops it). NOTE: only a stage that
    /// is EXACTLY `!` expands — `!foo` or `foo!` are ordinary text and pass through.
    static func resolveBang(_ input: String, last: String?) -> String {
        let stages = pipeSegments(input)
        func isBang(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines) == "!" }
        guard stages.contains(where: isBang) else { return input }
        let replacement = last ?? ""
        return stages.map { isBang($0) ? replacement : $0 }.joined(separator: "|")
    }

    func parse(input: String) throws {
        // Resolve `!` to the last full line BEFORE any splitting, so `!` repeats the WHOLE thing (all its
        // `;` commands, all its pipe stages) — a whole-line `!` or a `!` pipe stage alike.
        let resolved = InputService.resolveBang(input, last: lastLine)
        // A bare `!` with nothing typed yet resolves to nothing — drop it rather than sending a blank line.
        guard !resolved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Remember what actually ran (already `!`-resolved, so a later `!` never chases another `!`).
        lastLine = resolved
        // `|` (the promise pipe) binds LOOSER than `;` (independent commands): a line with a top-level
        // pipe is ONE unit — the pipe machinery splits it on `|` and then splits each step on `;`, so
        // `a | b; c | d` is `a` then `(b; c)` then `d`. We must NOT pre-split it on `;` here, or that
        // `;` would cut it into `a | b` and `c | d` and break the grouping (the whole bug). Hand the
        // pipe line downstream whole; a pipe-free line splits on `;` as before, each command flowing
        // independently through the rest of the pipeline (aliases, on_send, transmit).
        if InputService.pipeSegments(resolved).count > 1 {
            continuation.yield(OutboundCommand(text: resolved, origin: .user))
            return
        }
        for command in InputService.semicolonSegments(resolved) {
            continuation.yield(OutboundCommand(text: command, origin: .user))
        }
    }

    /// Split a command line on the `|` promise-pipe operator into its ordered segments, using the SAME
    /// escaping shape as the `;` separator above: an unescaped `|` splits, `\|` is a literal pipe, and
    /// any other `\x` is left intact. A line with no unescaped `|` yields a single element (itself), so
    /// callers treat `count > 1` as "this is a pipe". Declarative (swift-parsing) so `;` and `|` share
    /// one escaping implementation rather than a second, hand-rolled scanner drifting from this one.
    /// The promise CHAINING of the segments lives in Lua (`__pipe`); this only tokenizes.
    private static let pipeParser = Many {
        Many(into: "") { string, fragment in
            string.append(contentsOf: fragment)
        } element: {
            OneOf {
                Prefix(1) { $0 != .init(ascii: "|") && $0 != .init(ascii: "\\") }.map(.string)

                Parse {
                    "\\".utf8
                    OneOf {
                        "|".utf8.map { "|" }
                        Prefix(1).map(.string).map { "\\\($0)" }
                    }
                }
            }
        }
    } separator: {
        "|".utf8
    }

    static func pipeSegments(_ input: String) -> [String] {
        (try? pipeParser.parse(input)) ?? [input]
    }
    
    func send(verbatim: String) throws {
        continuation.yield(OutboundCommand(text: verbatim, origin: .script))
    }
    
    func handleSigInt() {
        print("Stopping")
        var tattr = termios()
        tcgetattr(STDIN_FILENO, &tattr)
        tattr.c_lflag |= tcflag_t(ECHO | ICANON)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &tattr)
        exit(0)
    }
}

extension UTF8.CodeUnit {
    fileprivate var isUnescapedByte: Bool {
        self != .init(ascii: "\"") && self != .init(ascii: "\\")
    }
}

extension Container {
    static let inputService = Factory(scope: .cached) { InputService() }
}
