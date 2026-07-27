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
        // so a rule can span a message boundary. It shows text optimistically and un-prints already-shown lines
        // when a LATER chunk completes a match spanning them — so a telemetry tick that lands seconds after the
        // blank it frames still retroactively removes the gap. Empty (does nothing) unless a rule is registered.
        var filter = BufferRewriteFilter()
        // Did the PREVIOUS chunk end with a no-newline partial that was GAGGED (so nothing is on screen for
        // it)? The RPC frames each idle tick as "\nkxwq_prompt X" — the leading "\n" TERMINATES the previous
        // partial. When that partial was gagged, the "\n" has nothing to terminate, and emitting the empty
        // leading segment paints a blank line — one per gagged tick. Track it so we can drop that segment.
        var lastPartialGagged = false
        // Zero-width ANSI (colour codes) carried forward from gagged lines, so a reset the server glues to a
        // hidden telemetry line still terminates the previous coloured line instead of bleeding into the next.
        var ansiCarry = ""
        return map { output in
            let stripped = output.replacingOccurrences(of: "\u{E000}", with: "")
            // A fully-peeled chunk (e.g. a `;sgroup;…;egroup;` frame the on_stream filter consumed) has no
            // display bytes. Skip it WITHOUT touching cross-chunk state: otherwise it would reset
            // `lastPartialGagged`, so a hidden partial's terminator (a prompt tick, or the hud bar the buffer
            // rule just deleted) arriving in the NEXT real chunk would no longer be dropped and would paint a
            // stray blank — one per telemetry burst.
            if stripped.isEmpty { return "" }
            var lines = stripped.components(separatedBy: CharacterSet.newlines)
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
            // Stage 1: single-line processing (triggers + single-line gags) → this chunk's display text.
            // Mark LIVE (LiveGate) so triggers can tell real-time output from replayed history.
            let processed: String = LiveGate.shared.live {
                var acc = ""
                for (i, line) in lines.enumerated() {
                    let isLast = i == lines.count - 1
                    if isLast && endedInNewline { continue }   // terminator artifact, not a line
                    let isPartial = isLast && !endedInNewline
                    if let display = engine.processLine(line) {
                        // Carry any zero-width colour codes from gagged lines onto this one, then reset.
                        acc += ansiCarry + display + (isPartial ? "" : "\n")
                        ansiCarry = ""
                    } else {
                        // Gagged: drop the visible text but KEEP its zero-width ANSI (e.g. the "\27[0m" reset
                        // the server glues to a telemetry line to end the PRECEDING coloured line — a bold-blue
                        // "It is night."). Without this the colour bleeds into the next shown line.
                        ansiCarry += BufferRewriteFilter.ansiCodes(in: line)
                        if isPartial { lastPartialGagged = true }   // a gagged partial → its terminator is dropped
                    }
                }
                return acc
            }
            // Stage 2: multi-line gag/replace rules. Show optimistically; if a match completed across chunks,
            // un-print the already-shown lines it now covers (retract) before rendering the correction.
            let (retract, emit) = filter.feed(processed)
            // A rule that deleted this chunk's trailing PARTIAL (e.g. the hud bar) leaves its terminator to
            // arrive next chunk as an orphaned leading newline — drop it the same way we drop a gagged
            // partial's terminator, so it never paints a stray blank.
            if filter.droppedTrailingPartial { lastPartialGagged = true }
            let store = Container.transcriptStore()
            if retract > 0 {
                Container.terminalService().retract(retract)
                store.retractReceived(retract)
            }
            if !emit.isEmpty {
                var recLines = emit.components(separatedBy: "\n")
                if recLines.last == "" { recLines.removeLast() }   // trailing terminator, not a row
                for l in recLines { store.recordReceived(l) }
            }
            return emit
        }
        .eraseToAnyAsyncSequence()
    }

}

/// Shared engine for `#gag`/`#suppress`/`#replace`/`#substitute` (each a regex → replacement). A multi-line
/// match may only COMPLETE chunks later (a telemetry tick lands seconds after the blank it frames), so this
/// shows everything OPTIMISTICALLY and, when a later chunk completes a match spanning already-shown lines,
/// reports how many rendered lines to un-print (retract) plus the correction. `shown` mirrors the display's
/// last `maxSpan` lines and PERSISTS across chunks — that persistence is load-bearing: it gives a match its
/// leading context (e.g. the `\n` before a framing blank) even when ticks are seconds apart, so the collapse
/// still happens. Each feed diffs `shown` against the rule-corrected text and returns that (retract, emit).
struct BufferRewriteFilter {
    /// Enabled rules: (compiled regex, replacement text, how many lines its pattern spans). Refreshed by caller.
    var rules: [(regex: Regex<AnyRegexOutput>, replacement: String, span: Int)] = []
    /// The text currently ON SCREEN, windowed to the last `maxSpan` lines (older can't be part of a match).
    private var shown = ""
    private var maxSpan: Int { rules.map(\.span).max() ?? 1 }
    /// Set by the last `feed` when a rule DELETED this chunk's trailing partial (a hidden line with no newline
    /// yet — e.g. the kxwq_hud vitals bar). That partial's own terminator arrives next chunk as an orphaned
    /// leading newline; the caller drops it (same as a gagged partial's terminator) so it never paints a blank.
    private(set) var droppedTrailingPartial = false

    /// Feed a chunk's rendered text. Returns how many previously-shown COMPLETE lines to un-print, and the
    /// text to render now. With no multi-line rules it's a pure passthrough `(0, text)`.
    mutating func feed(_ text: String) -> (retract: Int, emit: String) {
        guard !rules.isEmpty else { droppedTrailingPartial = false; return (0, text) }
        let candidate = shown + text
        var corrected = candidate
        for r in rules {
            if r.replacement.isEmpty {
                // Delete-style rule (#gag/#suppress): remove the SPACING characters but KEEP the zero-width
                // ANSI in the deleted span — "suppression allows ANSI through". Otherwise a colour RESET the
                // server tucks into a hidden telemetry frame (e.g. carried onto the hud line the rule eats)
                // would be deleted, and the previous line's colour would bleed down the screen.
                corrected = corrected.replacing(r.regex) { match in Self.ansiCodes(in: String(match.0)) }
            } else {
                corrected = corrected.replacing(r.regex, with: r.replacement)
            }
        }
        // If this chunk ended in a partial (no trailing newline) and a rule ate it, flag its now-orphaned
        // terminator for the caller to drop next chunk.
        let trailing = text.last == "\n" ? "" : String(text[(text.lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex)...])
        droppedTrailingPartial = !trailing.isEmpty && !corrected.hasSuffix(trailing)
        // Longest common prefix of what's shown and what SHOULD be shown, tracked at both the character level
        // (n) and the last shared line boundary (lastNL).
        var i = shown.startIndex, j = corrected.startIndex, n = 0, lastNL = 0
        while i < shown.endIndex, j < corrected.endIndex, shown[i] == corrected[j] {
            n += 1
            if shown[i] == "\n" { lastNL = n }
            i = shown.index(after: i); j = corrected.index(after: j)
        }
        // Retract the complete lines of `shown` past the last shared boundary; re-render from that boundary.
        // When nothing needs retracting the divergence is a pure append (or an edit inside the pending line),
        // so emit only the character-level delta — never re-emit already-shown text.
        let retract = shown.dropFirst(lastNL).reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
        let emit = String(corrected.dropFirst(retract == 0 ? n : lastNL))
        shown = Self.lastLines(of: corrected, maxSpan)
        return (retract, emit)
    }

    /// Keep only the last `k` newline-delimited lines of `s` (plus any trailing partial).
    private static func lastLines(of s: String, _ k: Int) -> String {
        guard k >= 1 else { return s }
        var count = 0, idx = s.endIndex
        while idx > s.startIndex {
            let prev = s.index(before: idx)
            if s[prev] == "\n" { count += 1; if count > k { return String(s[idx...]) } }
            idx = prev
        }
        return s
    }

    /// Extract only the zero-width ANSI escape sequences from `s` (dropping every spacing character). Used to
    /// keep a hidden line's colour codes — chiefly a `\27[0m` reset the server tucks around a telemetry line to
    /// terminate the preceding coloured line — so gagging/suppressing the line doesn't bleed that colour forward.
    static func ansiCodes(in s: String) -> String {
        let scalars = Array(s.unicodeScalars)
        var result = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            guard scalars[i] == "\u{1B}" else { i += 1; continue }   // not ESC → a spacing char, drop it
            var j = i + 1
            if j < scalars.count, scalars[j] == "[" {                // CSI: ESC [ … final-byte(0x40–0x7E)
                j += 1
                while j < scalars.count {
                    let c = scalars[j]; j += 1
                    if c.value >= 0x40 && c.value <= 0x7E { break }
                }
            } else {
                j = Swift.min(j + 1, scalars.count)                  // other ESC form: keep ESC + next byte
            }
            result.append(contentsOf: scalars[i..<j])
            i = j
        }
        return String(result)
    }
}
