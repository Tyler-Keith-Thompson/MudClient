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
        case .is, .binary: return String(UnicodeScalar(0))
        case .msdp_array_close: return String(UnicodeScalar(6))
        case .msdp_array_open: return String(UnicodeScalar(5))
        case .msdp_table_close: return String(UnicodeScalar(4))
        case .msdp_table_open: return String(UnicodeScalar(3))
        case .msdp_val: return String(UnicodeScalar(2))
        case .msdp_var, .send, .echo: return String(UnicodeScalar(1))
        case .go_ahead: return String(UnicodeScalar(249))
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
        case .is, .binary: return Data([0])
        case .msdp_array_close: return Data([6])
        case .msdp_array_open: return Data([5])
        case .msdp_table_close: return Data([4])
        case .msdp_table_open: return Data([3])
        case .msdp_val: return Data([2])
        case .msdp_var, .send, .echo: return Data([1])
        case .go_ahead: return Data([249])
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
    }

    /// Builds a `Data` value out of a sequence of telnet control codes.
    static func bytes(_ codes: IAC...) -> Data {
        codes.reduce(into: Data()) { $0.append($1.data) }
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
            negotiationParser().map { iac -> StreamToken in
                switch iac {
                case (.iac, .will, .mssp): return .respond(bytes(.iac, .dont, .mssp))
                case (.iac, .will, .msdp): return .respond(bytes(.iac, .do, .msdp))
                case (.iac, .will, .mccp): return .respond(bytes(.iac, .dont, .mccp))
                case (.iac, .will, .msp): return .respond(bytes(.iac, .do, .msp))
                case (.iac, .will, .zmp): return .respond(bytes(.iac, .dont, .zmp))
                case (.iac, .do, .mxp): return .respond(bytes(.iac, .dont, .mxp))
                case (.iac, .do, .line_mode): return .respond(bytes(.iac, .do, .line_mode))
                case (.iac, .do, .actp): return .respond(bytes(.iac, .dont, .actp))
                case (.iac, .do, .ttype): return .respond(bytes(.iac, .will, .ttype))
                case (.iac, .send, .ttype):
                    return .respond(
                        bytes(.iac, .sb, .ttype, .is) + Data("MudClient".utf8) + bytes(.iac, .se)
                    )
                case (.iac, .do, .unknown(let byte)): return .respond(bytes(.iac, .wont, .unknown(byte)))
                case (.iac, .dont, .unknown(let byte)): return .respond(bytes(.iac, .wont, .unknown(byte)))
                case (.iac, .will, .unknown(let byte)): return .respond(bytes(.iac, .dont, .unknown(byte)))
                case (.iac, .wont, .unknown(let byte)): return .respond(bytes(.iac, .dont, .unknown(byte)))
                default: return .ignore
                }
            }
            IAC.commandParser().map { _ in StreamToken.ignore }
            Prefix(1).map { StreamToken.passthrough($0) }
        }
    }
}

/// Holds the cross-chunk parsing state for ``handleIACCommunication``. Reference semantics let the
/// (sequentially-invoked) async `map` carry the buffer between `Data` chunks. Access is serialized
/// by the asynchronous sequence, so the unchecked `Sendable` is safe.
private final class IACStreamState<P: Parser>: @unchecked Sendable
where P.Input == Substring, P.Output == IAC.StreamToken {
    var driver: StreamingParser<P>

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
                }
            }
            return output
        }
        .eraseToAnyAsyncSequence()
    }
}
