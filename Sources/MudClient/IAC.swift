//
//  IAC.swift
//  MudClient
//
//  Created by Tyler Thompson on 8/11/24.
//

import Afluent
import Foundation
import Parsing
import DependencyInjection

enum IAC: CustomDebugStringConvertible, CaseIterable, Equatable {
    case iac
    case dont
    case `do`
    case wont
    case will
    case sb
    case se
    case ttype
    case window_size
    case line_mode
    case character_set
    case msdp
    case mssp
    case zmp
    case actp
    case mxp
    case msp
    case mccp
    case gmcp
    case `is` // binary
    case binary // is
    case msdp_array_close
    case msdp_array_open
    case msdp_table_close
    case msdp_table_open
    case msdp_val
    case msdp_var // send, echo
    case send // msdp_var, echo
    case echo // msdp_var, send
    case go_ahead
    case sga // SUPPRESS-GO-AHEAD (option 3)
    case unknown(UInt8)
    
    var asciiChar: String {
        switch self {
        case .iac: return String(UnicodeScalar(255))
        case .dont: return String(UnicodeScalar(254))
        case .do: return String(UnicodeScalar(253))
        case .wont: return String(UnicodeScalar(252))
        case .will: return String(UnicodeScalar(251))
        case .sb: return String(UnicodeScalar(250))
        case .se: return String(UnicodeScalar(240))
        case .ttype: return String(UnicodeScalar(24))
        case .window_size: return String(UnicodeScalar(31))
        case .line_mode: return String(UnicodeScalar(34))
        case .character_set: return String(UnicodeScalar(42))
        case .msdp: return String(UnicodeScalar(69))
        case .mssp: return String(UnicodeScalar(70))
        case .zmp: return String(UnicodeScalar(93))
        case .actp: return String(UnicodeScalar(200))
        case .mxp: return String(UnicodeScalar(91))
        case .msp: return String(UnicodeScalar(90))
        case .mccp: return String(UnicodeScalar(86))
        case .gmcp: return String(UnicodeScalar(201))
        case .is, .binary: return String(UnicodeScalar(0))
        case .msdp_array_close: return String(UnicodeScalar(6))
        case .msdp_array_open: return String(UnicodeScalar(5))
        case .msdp_table_close: return String(UnicodeScalar(4))
        case .msdp_table_open: return String(UnicodeScalar(3))
        case .msdp_val: return String(UnicodeScalar(2))
        case .msdp_var, .send, .echo: return String(UnicodeScalar(1))
        case .go_ahead: return String(UnicodeScalar(249))
        case .sga: return String(UnicodeScalar(3))
        case .unknown(let byte): return String(UnicodeScalar(byte))
        }
    }
    
    var data: Data {
        switch self {
        case .iac: return Data([255])
        case .dont: return Data([254])
        case .do: return Data([253])
        case .wont: return Data([252])
        case .will: return Data([251])
        case .sb: return Data([250])
        case .se: return Data([240])
        case .ttype: return Data([24])
        case .window_size: return Data([31])
        case .line_mode: return Data([34])
        case .character_set: return Data([42])
        case .msdp: return Data([69])
        case .mssp: return Data([70])
        case .zmp: return Data([93])
        case .actp: return Data([200])
        case .mxp: return Data([91])
        case .msp: return Data([90])
        case .mccp: return Data([86])
        case .gmcp: return Data([201])
        case .is, .binary: return Data([0])
        case .msdp_array_close: return Data([6])
        case .msdp_array_open: return Data([5])
        case .msdp_table_close: return Data([4])
        case .msdp_table_open: return Data([3])
        case .msdp_val: return Data([2])
        case .msdp_var, .send, .echo: return Data([1])
        case .go_ahead: return Data([249])
        case .sga: return Data([3])
        case .unknown(let byte): return Data([byte])
        }
    }
    
    var debugDescription: String {
        switch self {
        case .iac: return "IAC"
        case .dont: return "DON'T"
        case .do: return "DO"
        case .wont: return "WON'T"
        case .will: return "WILL"
        case .sb: return "SB"
        case .se: return "SE"
        case .ttype: return "TTYPE"
        case .window_size: return "WINDOW_SIZE"
        case .line_mode: return "LINEMODE"
        case .character_set: return "CHARACTER_SET"
        case .msdp: return "MSDP"
        case .mssp: return "MSSP"
        case .zmp: return "ZMP"
        case .actp: return "ACTP"
        case .mxp: return "MXP"
        case .msp: return "MSP"
        case .mccp: return "MCCP"
        case .gmcp: return "GMCP"
        case .is: return "IS"
        case .binary: return "BINARY"
        case .msdp_array_close: return "MSDP_ARRAY_CLOSE"
        case .msdp_array_open: return "MSDP_ARRAY_OPEN"
        case .msdp_table_close: return "MSDP_TABLE_CLOSE"
        case .msdp_table_open: return "MSDP_TABLE_OPEN"
        case .msdp_val: return "MSDP_VAL"
        case .msdp_var: return "MSDP_VAR"
        case .send: return "SEND"
        case .echo: return "ECHO"
        case .go_ahead: return "GO_AHEAD"
        case .sga: return "SGA"
        case .unknown: return "UNKNOWN"
        }
    }

    static let allCases = [
        Self.dont,
        Self.do,
        Self.wont,
        Self.will,
        Self.sb,
        Self.se,
        Self.ttype,
        Self.window_size,
        Self.line_mode,
        Self.character_set,
        Self.msdp,
        Self.mssp,
        Self.zmp,
        Self.actp,
        Self.mxp,
        Self.msp,
        Self.mccp,
        Self.gmcp,
        Self.is,
        Self.binary,
        Self.msdp_array_close,
        Self.msdp_array_open,
        Self.msdp_table_close,
        Self.msdp_table_open,
        Self.msdp_val,
        Self.msdp_var,
        Self.send,
        Self.echo,
        Self.go_ahead,
        Self.sga,
    ]
    
    static func negotiationParser() -> some Parser<Substring, (IAC, IAC, IAC)> {
        Parse {
            Self.iac.asciiChar.map { _ in Self.iac }
            OneOf {
                Parse { Self.dont.asciiChar }.map { _ in Self.dont }
                Parse { Self.do.asciiChar }.map { _ in Self.do }
                Parse { Self.wont.asciiChar }.map { _ in Self.wont }
                Parse { Self.will.asciiChar }.map { _ in Self.will }
            }
            OneOf {
                // SGA (option 3) must precede msdp_table_open, which aliases the same byte value: in a
                // WILL/WONT/DO/DONT negotiation, byte 3 is SUPPRESS-GO-AHEAD, not an MSDP in-band marker.
                Parse { Self.sga.asciiChar }.map { _ in Self.sga }
                Parse { Self.sb.asciiChar }.map { _ in Self.sb }
                Parse { Self.se.asciiChar }.map { _ in Self.se }
                Parse { Self.ttype.asciiChar }.map { _ in Self.ttype }
                Parse { Self.window_size.asciiChar }.map { _ in Self.window_size }
                Parse { Self.line_mode.asciiChar }.map { _ in Self.line_mode }
                Parse { Self.character_set.asciiChar }.map { _ in Self.character_set }
                Parse { Self.msdp.asciiChar }.map { _ in Self.msdp }
                Parse { Self.mssp.asciiChar }.map { _ in Self.mssp }
                Parse { Self.zmp.asciiChar }.map { _ in Self.zmp }
                Parse { Self.actp.asciiChar }.map { _ in Self.actp }
                Parse { Self.mxp.asciiChar }.map { _ in Self.mxp }
                Parse { Self.msp.asciiChar }.map { _ in Self.msp }
                Parse { Self.mccp.asciiChar }.map { _ in Self.mccp }
                Parse { Self.gmcp.asciiChar }.map { _ in Self.gmcp }
                Parse { Self.is.asciiChar }.map { _ in Self.is }
                Parse { Self.binary.asciiChar }.map { _ in Self.binary }
                Parse { Self.msdp_array_close.asciiChar }.map { _ in Self.msdp_array_close }
                Parse { Self.msdp_array_open.asciiChar }.map { _ in Self.msdp_array_open }
                Parse { Self.msdp_table_close.asciiChar }.map { _ in Self.msdp_table_close }
                Parse { Self.msdp_table_open.asciiChar }.map { _ in Self.msdp_table_open }
                Parse { Self.msdp_val.asciiChar }.map { _ in Self.msdp_val }
                Parse { Self.msdp_var.asciiChar }.map { _ in Self.msdp_var }
                Parse { Self.send.asciiChar }.map { _ in Self.send }
                Parse { Self.echo.asciiChar }.map { _ in Self.echo }
                Prefix(1).map { Self.unknown(UInt8($0.unicodeScalars.first!.value)) }
            }
        }
    }
    
    static func commandParser() -> some Parser<Substring, (IAC, IAC)> {
        Parse {
            Self.iac.asciiChar.map { _ in Self.iac }
            OneOf {
                Self.go_ahead.asciiChar.map { _ in Self.go_ahead }
            }
        }
    }
}

extension OptionSet where RawValue: FixedWidthInteger {
    func elements() -> AnySequence<Self> {
        var remainingBits = rawValue
        var bitMask: RawValue = 1
        return AnySequence {
            return AnyIterator {
                while remainingBits != 0 {
                    defer { bitMask = bitMask &* 2 }
                    if remainingBits & bitMask != 0 {
                        remainingBits = remainingBits & ~bitMask
                        return Self(rawValue: bitMask)
                    }
                }
                return nil
            }
        }
    }
}

extension IAC {
    /// One unit of meaning pulled from the server's byte stream: a negotiation we must answer, an
    /// ignorable in-band command, or a passthrough character bound for the display.
    enum StreamToken: Sendable {
        case respond(Data)
        case passthrough(Substring)
        case ignore
        /// A telnet option negotiation (WILL/WONT/DO/DONT <option>) whose response can be overridden by
        /// the Lua `on_telnet_negotiate(verb, option)` hook. `verb` is the raw telnet verb byte, `option`
        /// the numeric option, and `defaultResponse` the hardcoded reply used when the hook is absent or
        /// declines. Surfaced (rather than pre-answered) so the async layer can consult Lua before replying.
        case negotiate(verb: UInt8, option: UInt8, defaultResponse: Data)
        /// A completed telnet subnegotiation (`IAC SB <option> <payload> IAC SE`). `payload` is the raw
        /// bytes with `IAC IAC` un-escaped to a single `IAC`. Delivered to the Lua `on_telnet` hook.
        case subnegotiation(option: UInt8, payload: Data)
        /// Telnet GO-AHEAD: the server has finished a (typically no-newline) prompt. Surfaced so the
        /// line assembler can flush its held partial line. See ``promptGoAheadMarker``.
        case promptEnd
        /// The server negotiated SUPPRESS-GO-AHEAD for its own transmissions: GA is no longer sent, so
        /// it must stop being treated as a prompt boundary. Carries our agreement to send.
        case suppressGoAhead(Data)
    }

    /// Builds a `Data` value out of a sequence of telnet control codes.
    static func bytes(_ codes: IAC...) -> Data {
        codes.reduce(into: Data()) { $0.append($1.data) }
    }

    /// Resolves the reply to a telnet option negotiation, giving the Lua `on_telnet_negotiate(verb,
    /// option)` hook the chance to override the hardcoded default. The hook may return `"accept"` or
    /// `"reject"`; anything else (including absence) falls back to `defaultResponse`.
    ///
    /// COMPRESS2/MCCP (options 85 and 86) are hard-excluded: the hook is never consulted for them and
    /// any override is ignored, so compression stays negotiated off exactly as before.
    static func telnetNegotiationResponse(verb: UInt8, option: UInt8, defaultResponse: Data) -> Data {
        if option == 85 || option == 86 { return defaultResponse }
        let verbName: String
        switch verb {
        case 251: verbName = "will"
        case 252: verbName = "wont"
        case 253: verbName = "do"
        case 254: verbName = "dont"
        default: return defaultResponse
        }
        guard let decision = Container.scriptInterpreter().engine
            .telnetNegotiate(verb: verbName, option: Int(option)) else { return defaultResponse }
        let opt = IAC.unknown(option)
        switch (verb, decision) {
        case (251, "accept"): return bytes(.iac, .do, opt)     // WILL -> DO
        case (251, "reject"): return bytes(.iac, .dont, opt)   // WILL -> DONT
        case (253, "accept"): return bytes(.iac, .will, opt)   // DO   -> WILL
        case (253, "reject"): return bytes(.iac, .wont, opt)   // DO   -> WONT
        case (252, "accept"), (252, "reject"): return bytes(.iac, .dont, opt) // WONT -> DONT
        case (254, "accept"), (254, "reject"): return bytes(.iac, .wont, opt) // DONT -> WONT
        default: return defaultResponse
        }
    }

    /// A parser that extracts a single ``StreamToken`` from the front of the server stream.
    ///
    /// Because it is driven by a `StreamingParser`, the IAC negotiation and command parsers can
    /// report that they need more input when a telnet sequence is split across the network reads
    /// that produce our `Data` chunks. The driver buffers the partial sequence and resumes once the
    /// remaining bytes arrive — so a negotiation that straddles a packet boundary is no longer
    /// mistaken for stray text.
    static func streamTokenParser() -> some Parser<Substring, StreamToken> {
        OneOf {
            // Subnegotiation (`IAC SB <option> ... IAC SE`) must be tried BEFORE the 3-byte negotiation
            // parser, which would otherwise match `IAC SB <option>` as a triple and leak the payload as
            // display text. Delivered to Lua via `on_telnet`.
            subnegotiationParser()
            negotiationParser().map { iac -> StreamToken in
                // Byte value of an IAC option (named or unknown), for the numeric `option` fields below.
                func opt(_ o: IAC) -> UInt8 { o.data.first ?? 0 }
                switch iac {
                // ---- Structural / special cases: answered here, NOT routed through on_telnet_negotiate. ----
                // SUPPRESS-GO-AHEAD. `WILL SGA` = the server will stop sending GA; accept (DO SGA) and
                // record that GA is no longer a prompt boundary. `DO SGA` only asks us to suppress the
                // GA we never send, so just agree (WILL SGA) without touching GA-reception state.
                case (.iac, .will, .sga): return .suppressGoAhead(bytes(.iac, .do, .sga))
                case (.iac, .do, .sga): return .respond(bytes(.iac, .will, .sga))
                case (.iac, .send, .ttype):
                    return .respond(
                        bytes(.iac, .sb, .ttype, .is) + Data("MudClient".utf8) + bytes(.iac, .se)
                    )
                // MCCP/COMPRESS2 (86): kept exactly as today — refused (DONT) as a plain `respond`, never
                // routed through `negotiate`, so the Lua override hook can never touch it. See the async
                // handler for the matching COMPRESS2 (85) hard-exclusion.
                case (.iac, .will, .mccp): return .respond(bytes(.iac, .dont, .mccp))
                // ---- Overridable option negotiations: default reply preserved, but on_telnet_negotiate wins. ----
                case (.iac, .will, .mssp): return .negotiate(verb: opt(.will), option: opt(.mssp), defaultResponse: bytes(.iac, .dont, .mssp))
                case (.iac, .will, .msdp): return .negotiate(verb: opt(.will), option: opt(.msdp), defaultResponse: bytes(.iac, .do, .msdp))
                case (.iac, .will, .gmcp): return .negotiate(verb: opt(.will), option: opt(.gmcp), defaultResponse: bytes(.iac, .do, .gmcp))
                case (.iac, .will, .msp): return .negotiate(verb: opt(.will), option: opt(.msp), defaultResponse: bytes(.iac, .do, .msp))
                case (.iac, .will, .zmp): return .negotiate(verb: opt(.will), option: opt(.zmp), defaultResponse: bytes(.iac, .dont, .zmp))
                case (.iac, .do, .mxp): return .negotiate(verb: opt(.do), option: opt(.mxp), defaultResponse: bytes(.iac, .dont, .mxp))
                case (.iac, .do, .line_mode): return .negotiate(verb: opt(.do), option: opt(.line_mode), defaultResponse: bytes(.iac, .do, .line_mode))
                case (.iac, .do, .actp): return .negotiate(verb: opt(.do), option: opt(.actp), defaultResponse: bytes(.iac, .dont, .actp))
                case (.iac, .do, .ttype): return .negotiate(verb: opt(.do), option: opt(.ttype), defaultResponse: bytes(.iac, .will, .ttype))
                case (.iac, .do, .unknown(let byte)): return .negotiate(verb: opt(.do), option: byte, defaultResponse: bytes(.iac, .wont, .unknown(byte)))
                case (.iac, .dont, .unknown(let byte)): return .negotiate(verb: opt(.dont), option: byte, defaultResponse: bytes(.iac, .wont, .unknown(byte)))
                case (.iac, .will, .unknown(let byte)): return .negotiate(verb: opt(.will), option: byte, defaultResponse: bytes(.iac, .dont, .unknown(byte)))
                case (.iac, .wont, .unknown(let byte)): return .negotiate(verb: opt(.wont), option: byte, defaultResponse: bytes(.iac, .dont, .unknown(byte)))
                default: return .ignore
                }
            }
            IAC.commandParser().map { _ in StreamToken.promptEnd } // currently only IAC GA
            Prefix(1).map { StreamToken.passthrough($0) }
        }
    }

    /// Parses one complete telnet subnegotiation, `IAC SB <option> <payload> IAC SE`, into a
    /// ``StreamToken/subnegotiation(option:payload:)``. The payload is everything between the option
    /// byte and the closing `IAC SE`, with `IAC IAC` un-escaped back to a single `IAC` byte.
    ///
    /// The payload scan is IAC-escaping-aware (``SubnegotiationPayload``): it treats a doubled
    /// `IAC IAC` as an escaped literal `0xFF` byte and only stops at an *unescaped* `IAC SE`, so a
    /// `0xFF` payload byte (sent on the wire as `IAC IAC`) whose second `IAC` happens to be followed by
    /// `SE` (`0xF0`) is no longer mistaken for the terminator. Like `PrefixUpTo`, it cooperates with the
    /// streaming driver — while the terminator has not yet arrived (including a lone trailing `IAC` that
    /// could still resolve either way) it reports "incomplete", so the driver buffers the partial
    /// subnegotiation across network reads instead of failing.
    static func subnegotiationParser() -> some Parser<Substring, StreamToken> {
        Parse {
            Self.iac.asciiChar
            Self.sb.asciiChar
            Prefix(1).map { UInt8($0.unicodeScalars.first!.value) }   // option byte
            SubnegotiationPayload()                                   // payload up to an unescaped IAC SE
            Self.iac.asciiChar
            Self.se.asciiChar
        }
        .map { (option: UInt8, payload: Substring) -> StreamToken in
            // Un-escape IAC IAC -> IAC and convert the Latin-1 scalars back to raw bytes.
            var bytes = [UInt8]()
            bytes.reserveCapacity(payload.count)
            var iterator = payload.unicodeScalars.makeIterator()
            var pending: UInt8? = iterator.next().map { UInt8($0.value) }
            while let b = pending {
                if b == 255 { // IAC — collapse a doubled IAC IAC into one literal byte
                    let next = iterator.next().map { UInt8($0.value) }
                    bytes.append(255)
                    pending = (next == 255) ? iterator.next().map { UInt8($0.value) } : next
                } else {
                    bytes.append(b)
                    pending = iterator.next().map { UInt8($0.value) }
                }
            }
            return .subnegotiation(option: option, payload: Data(bytes))
        }
    }
}

/// Scans a telnet subnegotiation payload up to (but not consuming) its closing `IAC SE`, respecting
/// telnet's `IAC IAC` escaping. Emitted as its own ``Parser`` — rather than `PrefixUpTo(IAC SE)` — so
/// that a `0xFF` payload byte (transmitted as the doubled `IAC IAC`) whose trailing `IAC` is followed
/// by `SE` (`0xF0`) is not mistaken for the terminator, which is the one case a naive "prefix up to
/// the two-byte marker" scan gets wrong.
///
/// Input is Latin-1 `Substring` (one `Character` == one byte, established by ``handleIACCommunication``).
/// The returned payload is still IAC-escaped; the caller un-escapes `IAC IAC` -> `IAC`.
///
/// Streaming: the incremental ``parse(_:isAtEnd:)`` reports `incompleteInput` (the library's public
/// "need more input" signal) whenever the terminator has not yet been proven — crucially including a
/// *lone trailing `IAC`* at the end of the buffer, which could still resolve to either an escaped
/// `IAC IAC` (payload) or a terminating `IAC SE`. That is exactly the disambiguation `PrefixUpTo`
/// cannot express, and the reason this parser needs the incomplete signal.
struct SubnegotiationPayload: Parser {
    private static let iac: UInt32 = 255   // 0xFF
    private static let se: UInt32 = 240    // 0xF0

    func parse(_ input: inout Substring) throws -> Substring {
        try parse(&input, isAtEnd: true)
    }

    func parse(_ input: inout Substring, isAtEnd: Bool) throws -> Substring {
        var idx = input.startIndex
        while idx < input.endIndex {
            guard input[idx].unicodeScalars.first?.value == Self.iac else {
                idx = input.index(after: idx)                        // ordinary payload byte
                continue
            }
            let next = input.index(after: idx)
            if next == input.endIndex {
                // A lone trailing IAC: it could still become IAC IAC (escaped payload) or IAC SE
                // (terminator). Mid-stream that is "need more"; only at the true end is it a failure.
                if !isAtEnd { throw incompleteInput(at: input) }
                throw SubnegotiationError.unterminated
            }
            switch input[next].unicodeScalars.first?.value {
            case Self.se:                                            // unescaped IAC SE → terminator
                let payload = input[..<idx]
                input = input[idx...]                                // leave IAC SE for the caller
                return payload
            case Self.iac:                                           // escaped IAC IAC → both are payload
                idx = input.index(idx, offsetBy: 2)
            default:                                                 // lone IAC byte (kept as payload)
                idx = input.index(after: idx)
            }
        }
        // Ran off the end without an unescaped IAC SE: mid-stream, wait for more; at end, it's a failure.
        if !isAtEnd { throw incompleteInput(at: input) }
        throw SubnegotiationError.unterminated
    }

    private enum SubnegotiationError: Error { case unterminated }
}

/// Holds the cross-chunk parsing state for ``handleIACCommunication``. Reference semantics let the
/// (sequentially-invoked) async `map` carry the buffer between `Data` chunks. Access is serialized
/// by the asynchronous sequence, so the unchecked `Sendable` is safe.
private final class IACStreamState<P: Parser>: @unchecked Sendable
where P.Input == Substring, P.Output == IAC.StreamToken {
    var driver: StreamingParser<P>
    /// Whether telnet GO-AHEAD is in effect for the server→client direction. True by the NVT default;
    /// set false once the server negotiates SUPPRESS-GO-AHEAD, after which GA is no longer treated as
    /// a prompt boundary. See ``promptGoAheadMarker``.
    var goAheadInEffect = true

    init(_ parser: P) {
        self.driver = StreamingParser(parser)
    }
}

extension AsyncSequence where Self: Sendable, Element == Data {
    func handleIACCommunication(writeToStream: @Sendable @escaping (Data) async throws -> Void) -> AnyAsyncSequence<String> {
        let state = IACStreamState(IAC.streamTokenParser())
        return map { input -> String in
            // Latin-1 maps each byte to a scalar 0...255, so characters line up 1:1 with bytes.
            guard let chunk = String(data: input, encoding: .isoLatin1).map({ Substring($0) }) else {
                return ""
            }
            var output = ""
            for token in try state.driver.feed(chunk) {
                switch token {
                case .passthrough(let text):
                    output += text
                case .respond(let data):
                    try await writeToStream(data)
                case .ignore:
                    break
                case .promptEnd:
                    // Only trust GA as a prompt boundary while it is actually in effect (not suppressed).
                    if state.goAheadInEffect { output.append(promptGoAheadMarker) }
                case .suppressGoAhead(let data):
                    try await writeToStream(data)
                    state.goAheadInEffect = false
                case .negotiate(let verb, let option, let defaultResponse):
                    try await writeToStream(IAC.telnetNegotiationResponse(verb: verb, option: option,
                                                                          defaultResponse: defaultResponse))
                case .subnegotiation(let option, let payload):
                    Container.scriptInterpreter().engine.notifyTelnet(option: Int(option), payload: payload)
                }
            }
            return output
        }
        .eraseToAnyAsyncSequence()
    }
}
