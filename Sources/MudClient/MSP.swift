//
//  MSP.swift
//  MudClient
//
//  Created by Tyler Thompson on 8/18/24.
//

import DependencyInjection
import Parsing
import Foundation
import Afluent

enum FName: Equatable {
    case off
    case name(String)
}

enum MSPType {
    case sound
    case music
    case unknown(String)
}

enum MSP {
    case u(String) // url
    case v(UInt) // volume, 1-100
    case l(Int) // loops -1, or Integers > 0, -1 == infinite
    case p(Int) // priority 1-100
    case c(Bool) // continue values 0, 1 specifies whether the file should simply continue playing if requested again (1), or if it should restart (0). In either case, the new repeat count should take precedence over the old one, and the "number of plays thus far" counter should be reset to 0. By way of illustration, assume two rooms, room 110, and room 111. Room 110 is set to play bach/fugue.mid 3 times, while room 111 is set to play bach/fugue.mid 5 times. If a character enters room 110, fugue starts playing; if during halfway through the second refrain the character moves to room 111, fugue would either continue or restart based on the continue setting. fugue should play either 4.5 times (if continue was 1) or 5 times (if continue was 0). Similarly, the volume of the most recent MUSIC escape should be used.
    case t(MSPType) // SOUND | MUSIC but can be any string
    case unknown(Character, String)
    
    static var unknownParam: some Parser<Substring, MSP> {
        Parse {
            Prefix(1).map { $0.first! }
            "="
            Prefix { $0 != " " && $0 != ")" }
        }.map {
            MSP.unknown($0, String($1))
        }
    }
    
    static var uParam: some Parser<Substring, MSP> {
        Parse {
            "U"
            "="
            Prefix { $0 != " " && $0 != ")" }
        }.map {
            MSP.u(String($0))
        }
    }
    
    static var vParam: some Parser<Substring, MSP> {
        Parse {
            "V"
            "="
            UInt.parser()
        }.map {
            MSP.v($0)
        }
    }
    
    static var lParam: some Parser<Substring, MSP> {
        Parse {
            "L"
            "="
            Int.parser()
        }.map {
            MSP.l($0)
        }
    }
    
    static var pParam: some Parser<Substring, MSP> {
        Parse {
            "P"
            "="
            Int.parser()
        }.map {
            MSP.p($0)
        }
    }
    
    static var cParam: some Parser<Substring, MSP> {
        Parse {
            "C"
            "="
            OneOf {
                "0".map { MSP.c(false) }
                "1".map { MSP.c(true) }
            }
        }
    }
    
    static var tParam: some Parser<Substring, MSP> {
        Parse {
            "T"
            "="
            OneOf {
                "SOUND".map { MSP.t(.sound) }
                "MUSIC".map { MSP.t(.music) }
                Prefix { $0 != " " && $0 != ")" }.map { MSP.t(.unknown(String($0))) }
            }
        }
    }
    
    static var fName: some Parser<Substring, FName> {
        Parse {
            OneOf {
                "Off".map { FName.off }
                Prefix { $0 != " " && $0 != ")" }.map { FName.name(String($0)) }
            }
        }
    }
    
    nonisolated(unsafe) static var parser: some Parser<Substring, (FName, [MSP])> {
        Parse {
            "!!SOUND"
            "("
            fName
            Skip { Optionally { CharacterSet.whitespaces } }
            Many {
                OneOf {
                    uParam
                    vParam
                    lParam
                    pParam
                    cParam
                    tParam
                    unknownParam
                }
            } separator: {
                CharacterSet.whitespaces
            } terminator: {
                ")"
            }
        }
    }
    
    nonisolated(unsafe) static var defaultURL: URL?
}

/// Reassembles the server's text across the `Data`-sized pieces that reach ``processMSP()`` so that
/// an `!!SOUND(...)` directive split across a network boundary is still recognized.
///
/// MSP directives occupy a whole (trimmed) line, so directives are detected once their line is
/// terminated by a newline. To keep prompts and ordinary text flowing without delay, a trailing
/// partial line is held back only while it could still grow into an `!!SOUND` directive; anything
/// else is emitted immediately, and an offset records how much of the current line has already been
/// shown so nothing is ever emitted twice.
final class MSPLineBuffer: @unchecked Sendable {
    /// The portion of the current line received but not yet terminated by a newline.
    private var carry = ""
    /// How many leading characters of `carry` have already been emitted for display.
    private var carryEmitted = 0

    /// A trimmed line could still become an `!!SOUND` directive if it is empty or a prefix of (or
    /// already begins with) the directive marker.
    private static let marker = "!!SOUND"

    @discardableResult
    func process(_ incoming: String) -> (output: String, directives: [(FName, [MSP])]) {
        carry += incoming
        var output = ""
        var directives: [(FName, [MSP])] = []

        // Resolve every complete, newline-terminated line.
        while let newline = carry.firstIndex(of: "\n") {
            let line = carry[..<newline]
            if carryEmitted == 0,
                let directive = try? MSP.parser.parse(
                    line.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            {
                // A whole, not-yet-shown line that is an MSP directive: act on it, show nothing.
                directives.append(directive)
            } else {
                output += line.dropFirst(carryEmitted)
                output.append("\n")
            }
            carry = String(carry[carry.index(after: newline)...])
            carryEmitted = 0
        }

        // Decide what to do with the trailing partial line (no newline yet).
        if carryEmitted < carry.count {
            let pending = carry.dropFirst(carryEmitted)
            let trimmedLeading = pending.drop(while: { $0 == " " || $0 == "\t" })
            let couldBecomeDirective =
                carryEmitted == 0
                && (trimmedLeading.isEmpty
                    || Self.marker.hasPrefix(trimmedLeading)
                    || trimmedLeading.hasPrefix(Self.marker))
            if !couldBecomeDirective {
                output += pending
                carryEmitted = carry.count
            }
        }

        return (output, directives)
    }
}

extension AsyncSequence where Self: Sendable, Element == String {
    func processMSP() -> AnyAsyncSequence<String> {
        let buffer = MSPLineBuffer()
        return map { incoming -> String in
            let mspService = Container.mspService()
            let (output, directives) = buffer.process(incoming)
            for (fName, msp) in directives {
                var volume: Float = 1
                var loops = 0
                msp.forEach { parameter in
                    switch parameter {
                    case .u(let url):
                        if fName == .off, let url = URL(string: url) {
                            MSP.defaultURL = url
                        }
                    case .t: break
                    case .v(let v):
                        volume = Float(v / 100)
                    case .l(let numberOfLoops):
                        loops = numberOfLoops
                    case .p: break
                    case .c: break
                    case .unknown: break
                    }
                }
                if case .name(let path) = fName, let defaultURL = MSP.defaultURL {
                    mspService.player(defaultURL.appendingPathComponent(path), volume: volume, loops: loops)
                        .map { $0.play() }
                        .run()
                }
            }
            return output
        }
        .eraseToAnyAsyncSequence()
    }
}
