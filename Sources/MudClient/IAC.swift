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

struct IAC: OptionSet, CustomDebugStringConvertible {
    let rawValue: Int

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
        default: return elements().map(\.asciiChar).joined()
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
        default: return elements().map(\.data).reduce(into: Data()) { $0.append($1) }
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
        default: return elements().map(\.debugDescription).joined(separator: " ")
        }
    }
    
    static let iac              = Self(rawValue: 1 << 0)
    static let dont             = Self(rawValue: 1 << 1)
    static let `do`             = Self(rawValue: 1 << 2)
    static let wont             = Self(rawValue: 1 << 3)
    static let will             = Self(rawValue: 1 << 4)
    static let sb               = Self(rawValue: 1 << 5)
    static let se               = Self(rawValue: 1 << 6)
    static let ttype            = Self(rawValue: 1 << 7)
    static let window_size      = Self(rawValue: 1 << 8)
    static let line_mode        = Self(rawValue: 1 << 9)
    static let character_set    = Self(rawValue: 1 << 10)
    static let msdp             = Self(rawValue: 1 << 11)
    static let mssp             = Self(rawValue: 1 << 12)
    static let zmp              = Self(rawValue: 1 << 13)
    static let actp             = Self(rawValue: 1 << 14)
    static let mxp              = Self(rawValue: 1 << 15)
    static let msp              = Self(rawValue: 1 << 16)
    static let mccp             = Self(rawValue: 1 << 17)
    static let `is`             = Self(rawValue: 1 << 18) // also binary
    static let binary           = Self(rawValue: 1 << 18)
    static let msdp_array_close = Self(rawValue: 1 << 19)
    static let msdp_array_open  = Self(rawValue: 1 << 20)
    static let msdp_table_close = Self(rawValue: 1 << 21)
    static let msdp_table_open  = Self(rawValue: 1 << 22)
    static let msdp_val         = Self(rawValue: 1 << 23)
    static let msdp_var         = Self(rawValue: 1 << 24) // also send, echo
    static let send             = Self(rawValue: 1 << 24)
    static let echo             = Self(rawValue: 1 << 24)
    
    static let all = [
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
    ]
    
    static func parser() -> some Parser<Substring, [IAC]> {
        Parse {
            Self.iac.asciiChar
            Many {
                OneOf {
                    Parse { Self.dont.asciiChar }.map { _ in Self.dont }
                    Parse { Self.do.asciiChar }.map { _ in Self.do }
                    Parse { Self.wont.asciiChar }.map { _ in Self.wont }
                    Parse { Self.will.asciiChar }.map { _ in Self.will }
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
                }
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

extension AsyncSequence where Self: Sendable, Element == Data {
    func handleIACCommunication(writeToStream: @Sendable @escaping (Data) async throws -> Void) -> AnyAsyncSequence<String> {
        map { input in
            if let str = String(data: input, encoding: .isoLatin1) {
                var commands = [Data]()
                let parser = Many {
                    OneOf {
                        IAC.parser().map { iac in
                            let command = iac.reduce(into: IAC.iac) {
                                $0.update(with: $1)
                            }
                            switch command {
                            case [.iac, .will, .mssp]: commands.append(IAC([.iac, .dont, .mssp]).data)
                            case [.iac, .will, .msdp]: commands.append(IAC([.iac, .dont, .msdp]).data)
                            case [.iac, .will, .mccp]: commands.append(IAC([.iac, .dont, .mccp]).data)
                            case [.iac, .will, .msp]: commands.append(IAC([.iac, .dont, .msp]).data) // TODO: Bring back MSP (will)
                            case [.iac, .will, .zmp]: commands.append(IAC([.iac, .dont, .zmp]).data)
                            case [.iac, .do, .mxp]: commands.append(IAC([.iac, .dont, .mxp]).data)
                            case [.iac, .do, .line_mode]: commands.append(IAC([.iac, .will, .line_mode]).data)
                            case [.iac, .do, .actp]: commands.append(IAC([.iac, .dont, .actp]).data)
                            case [.iac, .do, .ttype]: commands.append(IAC([.iac, .will, .ttype]).data)
                            case [.iac, .send, .ttype]: commands.append(IAC([.iac, .sb, .ttype, .is]).data + Data("MudClient".utf8) + IAC([.iac, .se]).data)
                            default: break
                            }
                            return Substring()
                        }
                        Prefix(1)
                    }
                }
                let val = try parser.parse(str).joined()
            
                for command in commands {
                    Container.terminalService().print("SENDING: \(command.map(String.init(describing:)))")
                    try await writeToStream(command)
                }
                return String(val)
            }
            return ""
        }
        .eraseToAnyAsyncSequence()
    }
}
