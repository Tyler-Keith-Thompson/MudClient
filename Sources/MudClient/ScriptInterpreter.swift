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
        // Shared buffer-delete engine for `#suppress` + multi-line `#gag`, persisted across chunks so a rule
        // can span a message boundary. Empty (does nothing) unless such a rule is registered.
        var filter = BufferDeleteFilter()
        return map { output in
            // Split on the server's OWN newlines and fire triggers/single-line gags per line — nothing is
            // added, moved, or rewritten. A single-line-gagged line drops out; every surviving line (with its
            // own newline) flows into the multi-line gag filter, which may DELETE spans across lines. (The
            // U+E000 prompt-flush marker the IAC layer inserts is dropped here — its line assembler is gone.)
            let lines = output
                .replacingOccurrences(of: "\u{E000}", with: "")
                .components(separatedBy: CharacterSet.newlines)
            // A trailing "" when the chunk ends in a newline is the line TERMINATOR, not a blank line.
            let endedInNewline = lines.last == ""
            let lastFed = endedInNewline ? lines.count - 2 : lines.count - 1
            let engine = Container.scriptInterpreter().engine
            filter.rules = engine.bufferDeleteRules()   // refresh (a reload can change them); usually empty
            // Mark LIVE (LiveGate) so triggers can tell real-time output from replayed history.
            let rendered: String = LiveGate.shared.live {
                var acc = ""
                for (i, line) in lines.enumerated() {
                    if i == lines.count - 1 && endedInNewline { continue }   // terminator artifact, not a line
                    // processLine fires triggers + single-line gags PER LINE, on time. A gagged line (nil) is
                    // dropped and never enters the buffer; everything else feeds in WITH its own newline (the
                    // last line has none when the chunk didn't end in one — a no-newline prompt tail).
                    guard let display = engine.processLine(line) else { continue }
                    let newline = !(i == lastFed && !endedInNewline)
                    acc += filter.feed(display + (newline ? "\n" : ""))
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

/// Shared buffer-delete engine for `#suppress` and multi-line `#gag`. Both compile to a delete regex (they
/// differ only in HOW: `#suppress` deletes exactly what it matched; multi-line `#gag` extends its regex to eat
/// the whole final line). This engine just deletes every span its rules match from a rolling buffer of
/// rendered text — so `…bard'\n\nkxwq_hud…` collapses rather than leaving the framing blank. Text is fed line
/// by line (each already single-line-processed); it keeps the last `maxSpan - 1` lines buffered so a match
/// straddling a chunk boundary can still complete, and emits everything safely past that window.
struct BufferDeleteFilter {
    /// Enabled delete rules: (compiled delete regex, how many lines its pattern spans). Refreshed by the caller.
    var rules: [(regex: Regex<AnyRegexOutput>, span: Int)] = []
    /// Rendered text accumulated but not yet safe to emit (a match could still form in these trailing lines).
    private var buffer = ""
    private var maxSpan: Int { rules.map(\.span).max() ?? 1 }

    /// Feed the rendered text of one line (its display text plus its own newline, or no newline for a tail).
    /// Returns the text that is now safe to render (matched spans deleted, the last `maxSpan-1` lines held).
    mutating func feed(_ text: String) -> String {
        guard !rules.isEmpty else { return text }            // no delete rules → pure passthrough, no buffering
        buffer += text
        for r in rules { buffer = buffer.replacing(r.regex, with: "") }  // delete every matched span (newlines and all)
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
