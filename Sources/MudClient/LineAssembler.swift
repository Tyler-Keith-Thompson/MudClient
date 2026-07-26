//
//  LineAssembler.swift
//  MudClient
//
//  The line assembler was REMOVED — the inbound pipeline no longer reassembles lines across reads or
//  consumes GO-AHEAD boundaries; server bytes flow to the display exactly as received (see
//  ServerTextFeed / Connection pipelines and processServerOutputForScripts). Only the marker constant
//  remains: the IAC layer (IAC.swift) still maps a telnet GO-AHEAD to this private-use scalar, and
//  processServerOutputForScripts strips it out of the rendered text.
//

import Foundation

/// Private-use scalar the IAC layer inserts wherever the server sent a telnet GO-AHEAD (IAC GA). Nothing
/// consumes it as a prompt boundary anymore; it is simply dropped before display.
let promptGoAheadMarker: Character = "\u{E000}"
