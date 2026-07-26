//
//  ScriptInterpreter.swift
//  MudClient
//
//  Created by Tyler Thompson on 8/11/24.
//
//  Scripts are interpreted Lua (see Lua.swift / LuaScriptEngine.swift). The old
//  pipeline — shelling out to `swift build`, copying a .dylib, and dlopen'ing a
//  `createFactory` symbol — is gone. Scripts are loaded by the Lua `load(path)` loader
//  (Scripts/bootstrap.lua): `load("Scripts")` loads the directory; `reload()` re-runs it.
//

import Afluent
import DependencyInjection
import Foundation

final class ScriptInterpreter {
    let engine = LuaScriptEngine()

    init() {
        engine.onSend = { message in try? Container.inputService().send(verbatim: message) }
        // isEcho: re-assert the game's active colour after the echo so a script line's own `ESC[0m`
        // doesn't strip the colour off the game output that follows it (e.g. multi-line coloured chat).
        engine.onEcho = { message in Container.terminalService().print(message, isEcho: true) }
        // Record content echoes (script `echo(...)`, `↗ claude`) into the searchable transcript so `#grep`
        // surfaces them — the wire log only had sent/received before. NOT wired to `onEcho`, so the
        // `#grep`/`#sent`/`#received` dump output (which flows through onEcho) never re-records itself.
        engine.onRecordEcho = { message in Container.transcriptStore().recordEcho(message) }
        // Install the text-to-speech + live/history builtins (speak/speech_stop/speech_voices/is_live).
        // Kept out of LuaScriptEngine/bootstrap; see SpeechBuiltins.swift.
        engine.installSpeech()
        // All game-specific behavior (KXWT parsing, state, recovery, the AI pilot) now lives in
        // the Lua scripts (Scripts/*.lua), not the Swift client. There is no hardcoded script list
        // here anymore: `loadScripts()` just runs the Lua `load("Scripts")` loader, which loads the
        // Scripts/ directory (see bootstrap.lua). `reload()` is likewise `load("Scripts")` again.
    }

    /// Load the whole Scripts/ directory via the Lua loader — the single entry point for startup.
    /// Resolving/ordering/exclusions all live in the pure-Lua `load` function (Scripts/bootstrap.lua);
    /// the connection is opened by AlterAeon.lua's own top-level `connect()` during this load, not here.
    func loadScripts() {
        do { try engine.load(source: #"load("Scripts")"#) }
        catch { Container.terminalService().print("Failed to load Scripts/: \(error)") }
    }
}

extension Container {
    static let scriptInterpreter = Factory(scope: .cached) { ScriptInterpreter() }
}

extension Character {
    static let scriptIndicator = Character("#")
    var isScriptIndicator: Bool {
        self == .scriptIndicator
    }
}

extension AsyncSequence where Self: Sendable, Element == OutboundCommand {
    func processScriptInput() -> AnyAsyncSequence<OutboundCommand> {
        compactMap { command -> OutboundCommand? in
            let rawInput = command.text
            let interpreter = Container.scriptInterpreter()
            // Trim surrounding whitespace once, up front, so every downstream stage sees the clean
            // command: anchored aliases (`^recover$`) match "recover " too, `;`-split segments like the
            // " recover" in "look; recover" work, and a stray leading space before `#` still hits the
            // REPL. Interior spacing is untouched (so `say  hi` keeps its gap); leading/trailing space on
            // a MUD command is never meaningful.
            let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
            // Any leading `#` line is a REPL chunk: Lua evaluated in the live script state (with the
            // legacy-command rewrite covering old habits like `#load {X}`, `#reload`, `#ai …`, `#kxwt`).
            if input.first == Character.scriptIndicator {
                interpreter.engine.evalREPL(String(input.dropFirst()))
                return nil
            }
            // Let scripts observe the typed command without swallowing it (e.g. the AI pilot).
            interpreter.engine.notifyUserInput(input)
            // `-|` on its own — the inverse of `+|`: drop the last segment off the current in-flight
            // promise chain. Checked before the pipe cases since "-|" also contains a pipe.
            if input == "-|" {
                interpreter.engine.popPipe()
                return nil
            }
            // A leading `+|` APPENDS to the current in-flight promise ("recover", then "+| explore" ⇒
            // recover | explore). Checked before the plain `|` case, since "+| x" also contains a pipe.
            if input.hasPrefix("+|") {
                let steps = InputService.pipeSegments(String(input.dropFirst(2)))
                    .map { InputService.semicolonSegments($0) }
                interpreter.engine.appendPipe(steps)
                return nil
            }
            // A `|` sequences commands on promises ("recover 95 | attack rat | l"): each STEP waits for
            // the previous to resolve. `|` binds looser than `;`, so each step is itself a `;`-group of
            // independent commands ("recover | look; score | attack rat" ⇒ recover, then (look; score),
            // then attack). Swift tokenizes both levels (same escaping grammar); >1 step means it's a
            // pipe, so hand the nested steps to Lua's __pipe to build/run the chain and swallow the line.
            // Gated on a cheap contains-check so pipe-free lines skip the parse entirely.
            if input.contains("|") {
                let segments = InputService.pipeSegments(input)
                if segments.count > 1 {
                    interpreter.engine.runPipe(segments.map { InputService.semicolonSegments($0) })
                    return nil
                }
            }
            // Otherwise let a script alias claim it.
            if interpreter.engine.processAlias(input) {
                return nil
            }
            // Surviving command: carry the (trimmed) text plus its origin on to the transmit point.
            return OutboundCommand(text: input, origin: command.origin)
        }
        .eraseToAnyAsyncSequence()
    }
}

extension AsyncSequence where Self: Sendable, Element == String {
    /// Pass each server text chunk through the script's `on_stream` filter (a script may peel out an
    /// in-band protocol like the dclient channel). No filter registered → chunk passes through unchanged.
    func filterServerStream() -> AnyAsyncSequence<String> {
        map { Container.scriptInterpreter().engine.filterStream($0) }
            .eraseToAnyAsyncSequence()
    }

    func processServerOutputForScripts() -> AnyAsyncSequence<String> {
        // Shared buffer-rewrite engine for `#gag`/`#suppress`/`#replace`/`#substitute`, persisted across chunks
        // so a rule can span a message boundary. Empty (does nothing) unless such a rule is registered.
        var filter = BufferRewriteFilter()
        // Did the PREVIOUS chunk end with a no-newline partial that was GAGGED (so nothing is on screen for
        // it)? The RPC frames each idle tick as "\nkxwq_prompt X" — the leading "\n" TERMINATES the previous
        // partial. When that partial was gagged, the "\n" has nothing to terminate, and emitting the empty
        // leading segment paints a blank line — one per gagged tick. Track it so we can drop that segment.
        var lastPartialGagged = false
        return map { output in
            var lines = output
                .replacingOccurrences(of: "\u{E000}", with: "")
                .components(separatedBy: CharacterSet.newlines)
            // Drop a leading empty segment that is really the (invisible) terminator of the previous chunk's
            // gagged partial — not a fresh blank line. This is the fix for "gagging kxwq_prompt adds a blank
            // per tick": each "\nkxwq_prompt X" chunk otherwise contributes the "\n" as a blank once its
            // prompt is gagged and the prior prompt (which the "\n" was terminating) is gagged too.
            if lastPartialGagged, lines.first == "" { lines.removeFirst() }
            lastPartialGagged = false
            // A trailing "" when the chunk ends in a newline is the line TERMINATOR, not a blank line; the last
            // segment otherwise is a no-newline partial (a prompt, or a line split across reads/messages).
            let endedInNewline = lines.last == ""
            let engine = Container.scriptInterpreter().engine
            filter.rules = engine.bufferRewriteRules()   // refresh (a reload can change them); usually empty
            // Mark LIVE (LiveGate) so triggers can tell real-time output from replayed history.
            let rendered: String = LiveGate.shared.live {
                var acc = ""
                for (i, line) in lines.enumerated() {
                    let isLast = i == lines.count - 1
                    if isLast && endedInNewline { continue }   // terminator artifact, not a line
                    let isPartial = isLast && !endedInNewline
                    // processLine fires triggers + single-line gags PER LINE, on time.
                    if let display = engine.processLine(line) {
                        acc += filter.feed(display + (isPartial ? "" : "\n"))
                    } else if isPartial {
                        lastPartialGagged = true   // a gagged partial → its next-chunk terminator is dropped
                    }
                }
                return acc
            }
            // Record the DISPLAYED server output (post-gag) for `#grep`/`#received`, one line per row.
            let store = Container.transcriptStore()
            if !rendered.isEmpty {
                var recLines = rendered.components(separatedBy: "\n")
                if recLines.last == "" { recLines.removeLast() }   // trailing terminator, not a row
                for l in recLines { store.recordReceived(l) }
            }
            return rendered
        }
        .eraseToAnyAsyncSequence()
    }
}

/// Shared buffer-rewrite engine for `#gag`/`#suppress`/`#replace`/`#substitute`. Every rule compiles to a
/// (regex, replacement): delete-style commands replace with "", `#replace`/`#substitute` with the given text;
/// line-rounded commands (`#gag`/`#replace`) extend their regex to eat the whole final matched line, char-
/// exact ones (`#suppress`/`#substitute`) don't. This engine just applies each `regex → replacement` over a
/// rolling buffer of rendered text — so `…bard'\n\nkxwq_hud…` collapses (or gets a newline put back). Text is
/// fed line by line (each already single-line-processed); it keeps the last `maxSpan - 1` lines buffered so a
/// match straddling a chunk boundary can still complete, and emits everything safely past that window.
struct BufferRewriteFilter {
    /// Enabled rules: (compiled regex, replacement text, how many lines its pattern spans). Refreshed by caller.
    var rules: [(regex: Regex<AnyRegexOutput>, replacement: String, span: Int)] = []
    /// Rendered text accumulated but not yet safe to emit (a match could still form in these trailing lines).
    private var buffer = ""
    private var maxSpan: Int { rules.map(\.span).max() ?? 1 }

    /// Feed the rendered text of one line (its display text plus its own newline, or no newline for a tail).
    /// Returns the text now safe to render (each rule's matches rewritten, the last `maxSpan-1` lines held).
    mutating func feed(_ text: String) -> String {
        guard !rules.isEmpty else { return text }            // no rules → pure passthrough, no buffering
        buffer += text
        for r in rules { buffer = buffer.replacing(r.regex, with: r.replacement) }  // apply regex → replacement
        return emitSafePrefix()
    }

    /// Flush whatever is still buffered (e.g. on disconnect) so nothing is stranded.
    mutating func drain() -> String { defer { buffer = "" }; return buffer }

    /// Emit all but the last `maxSpan - 1` complete lines — those trailing lines might still be the start of a
    /// match once more text arrives, so they stay buffered. With no span > 1, emit everything (no holding).
    private mutating func emitSafePrefix() -> String {
        let hold = maxSpan - 1
        guard hold > 0 else { defer { buffer = "" }; return buffer }
        let newlines = buffer.indices.filter { buffer[$0] == "\n" }
        guard newlines.count > hold else { return "" }       // not enough complete lines to emit any safely
        let cut = buffer.index(after: newlines[newlines.count - hold - 1])
        let emit = String(buffer[..<cut])
        buffer = String(buffer[cut...])
        return emit
    }
}
