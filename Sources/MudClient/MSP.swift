//
//  MSP.swift
//  MudClient
//
//  Created by Tyler Thompson on 8/18/24.
//

import AudioStreaming
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

extension AsyncSequence where Self: Sendable, Element == String {
    func processMSP() -> AnyAsyncSequence<String> {
        map { output -> String in
            let mspService = Container.mspService()
            let lines = output.components(separatedBy: "\n")
            return lines.filter { line in
                let mspResult = Result { try MSP.parser.parse(line.trimmingCharacters(in: .whitespacesAndNewlines)) }
                switch mspResult {
                case .success((let fName, let msp)):
                    msp.forEach { parameter in
                        switch parameter {
                        case .u(let url):
                            if fName == .off, let url = URL(string: url) {
                                MSP.defaultURL = url
                            }
                        case .t: break
                        case .v(let volume): break
//                            player.volume = Float(volume)
                        case .l: break
                        case .p: break
                        case .c: break
                        case .unknown: break
                        }
                    }
                    if case .name(let path) = fName, let defaultURL = MSP.defaultURL {
                        mspService.play(defaultURL.appendingPathComponent(path)).run()
//                        player.play(url: defaultURL.appendingPathComponent(path))
                    }
                    return false
                case .failure: return true
                }
            }.joined(separator: "\n")
        }
        .eraseToAnyAsyncSequence()
    }
}
