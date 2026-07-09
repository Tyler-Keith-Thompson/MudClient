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
        engine.onEcho = { message in Container.terminalService().print(message) }
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

extension AsyncSequence where Self: Sendable, Element == String {
    func processScriptInput() -> AnyAsyncSequence<String> {
        compactMap { rawInput -> String? in
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
            // A leading `+|` APPENDS to the current in-flight promise ("recover", then "+| explore" ⇒
            // recover | explore). Checked before the plain `|` case, since "+| x" also contains a pipe.
            if input.hasPrefix("+|") {
                let segments = InputService.pipeSegments(String(input.dropFirst(2)))
                interpreter.engine.appendPipe(segments)
                return nil
            }
            // A `|` sequences commands on promises ("recover 95 | attack rat | l"): each segment waits
            // for the previous to resolve. Swift tokenizes (same escaping grammar as `;`); >1 segment
            // means it's a pipe, so hand the segments to Lua's __pipe to build/run the chain and swallow
            // the line. Gated on a cheap contains-check so pipe-free lines skip the parse entirely.
            if input.contains("|") {
                let segments = InputService.pipeSegments(input)
                if segments.count > 1 {
                    interpreter.engine.runPipe(segments)
                    return nil
                }
            }
            // Otherwise let a script alias claim it.
            if interpreter.engine.processAlias(input) {
                return nil
            }
            return input
        }
        .eraseToAnyAsyncSequence()
    }

    func processServerOutputForScripts() -> AnyAsyncSequence<String> {
        map { output in
            let lines = output
                .replacingOccurrences(of: "\r", with: "")
                .components(separatedBy: CharacterSet.newlines)
            let engine = Container.scriptInterpreter().engine
            // Fire triggers (and gags) for every line, in order — scripts (incl. the AI pilot's
            // catch-all) observe here. Each line is passed through the rewrite stage: `processLine`
            // returns the line to display (possibly rewritten by a trigger), or nil if it was gagged.
            //
            // Keep every surviving line verbatim — including blanks, which are the MUD's own spacing.
            // (We used to drop blanks adjacent to a gagged kxwt_ batch as "framing", but that ate real
            // spacing between content during combat's group-status bursts, and isn't needed.)
            //
            // Mark this batch LIVE (LiveGate) so triggers can tell real-time output from replayed
            // history via is_live() — the replay() path deliberately doesn't set this, so speech and
            // other live-only reactions stay silent on history.
            let out = LiveGate.shared.live { lines.compactMap { engine.processLine($0) } }
            return out.joined(separator: "\n")
        }
        .eraseToAnyAsyncSequence()
    }
}
