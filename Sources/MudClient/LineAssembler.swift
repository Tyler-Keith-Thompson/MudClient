//
//  LineAssembler.swift
//  MudClient
//
//  Created by Tyler Thompson.
//

import Foundation
import Afluent

/// Private-use scalar the IAC layer injects wherever the server sent a telnet GO-AHEAD (IAC GA).
/// AlterAeon marks the end of a no-newline prompt with GO-AHEAD, so this doubles as the "flush the
/// held partial line now — it's a complete prompt" signal for ``LineAssembler``. It is consumed
/// there and never reaches the display.
let promptGoAheadMarker: Character = "\u{E000}"

/// Reassembles complete lines across the `Data`-sized pieces that reach the async pipeline so that
/// downstream trigger/gag processing (``processServerOutputForScripts``) only ever sees whole lines.
///
/// Without this, a protocol line split across a TCP read — e.g. `kxwt_music channel_play music
/// soundtrack/track_explore_under` + `ground_01` — is processed as two fragments. The head still
/// matches its `^kxwt_` gag and is hidden, but the orphaned tail (`ground_01`) matches nothing and
/// leaks to the terminal (and corrupts the track name a trigger extracts). Holding the trailing
/// partial line until its newline arrives fixes both.
///
/// Genuine prompts have no trailing newline; the server ends them with telnet GO-AHEAD, surfaced as
/// ``promptGoAheadMarker``. Hitting that marker flushes (and drops) the held partial so prompts
/// still display without waiting for a newline that never comes.
final class LineAssembler: @unchecked Sendable {
    /// Text received but not yet terminated by a newline or a GO-AHEAD flush.
    private var carry = ""

    func assemble(_ incoming: String) -> String {
        carry += incoming
        var output = ""
        while let idx = carry.firstIndex(where: { $0 == "\n" || $0 == promptGoAheadMarker }) {
            output += carry[..<idx]
            if carry[idx] == "\n" { output.append("\n") } // keep the newline; drop the GO-AHEAD marker
            carry = String(carry[carry.index(after: idx)...])
        }
        return output
    }
}

extension AsyncSequence where Self: Sendable, Element == String {
    /// Emit only complete (newline- or GO-AHEAD-terminated) lines downstream, holding any trailing
    /// partial line until the rest of it arrives, so a protocol line split across a network read is
    /// never seen — and gagged — in fragments.
    func assembleLines() -> AnyAsyncSequence<String> {
        let assembler = LineAssembler()
        return map { assembler.assemble($0) }.eraseToAnyAsyncSequence()
    }
}
