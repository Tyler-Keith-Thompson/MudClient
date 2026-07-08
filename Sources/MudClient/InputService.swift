//
//  InputService.swift
//  MudClient
//
//  Created by Tyler Thompson on 8/11/24.
//

import Foundation
import Parsing
import DependencyInjection
import Afluent

final class InputService: @unchecked Sendable {    
    private let lock = NSRecursiveLock()
    private var _lastCommand: String?
    private var lastCommand: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _lastCommand
        } set {
            lock.lock()
            defer { lock.unlock() }
            _lastCommand = newValue
        }
    }
    private let (stream, continuation) = AsyncThrowingStream<String, any Swift.Error>.makeStream()
    private let parser = Many {
        Many(into: "") { string, fragment in
            string.append(contentsOf: fragment)
        } element: {
            OneOf {
                Prefix(1) { $0 != .init(ascii: ";") && $0 != .init(ascii: "\\") }.map(.string)
                
                Parse {
                    "\\".utf8
                    OneOf {
                        ";".utf8.map { ";" }
                        Prefix(1).map(.string).map { "\\\($0)" }
                    }
                }
            }
        }
    } separator: {
        ";".utf8
    }
    
    private var subscriptions = Set<AnyCancellable>()
    
    var commandStream: AnyAsyncSequence<String> {
        stream.map { [weak self] command in
            guard let self else { return command }
            if command == "!", let lastCommand {
                return lastCommand
            } else if !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.lastCommand = command
            }
            return command
        }
        .eraseToAnyAsyncSequence()
    }
    
    fileprivate init() { }
    
    func parse(input: String) throws {
        for command in try parser.parse(input) {
            continuation.yield(command)
        }
    }

    /// Split a command line on the `|` promise-pipe operator into its ordered segments, using the SAME
    /// escaping shape as the `;` separator above: an unescaped `|` splits, `\|` is a literal pipe, and
    /// any other `\x` is left intact. A line with no unescaped `|` yields a single element (itself), so
    /// callers treat `count > 1` as "this is a pipe". Declarative (swift-parsing) so `;` and `|` share
    /// one escaping implementation rather than a second, hand-rolled scanner drifting from this one.
    /// The promise CHAINING of the segments lives in Lua (`__pipe`); this only tokenizes.
    private static let pipeParser = Many {
        Many(into: "") { string, fragment in
            string.append(contentsOf: fragment)
        } element: {
            OneOf {
                Prefix(1) { $0 != .init(ascii: "|") && $0 != .init(ascii: "\\") }.map(.string)

                Parse {
                    "\\".utf8
                    OneOf {
                        "|".utf8.map { "|" }
                        Prefix(1).map(.string).map { "\\\($0)" }
                    }
                }
            }
        }
    } separator: {
        "|".utf8
    }

    static func pipeSegments(_ input: String) -> [String] {
        (try? pipeParser.parse(input)) ?? [input]
    }
    
    func send(verbatim: String) throws {
        continuation.yield(verbatim)
    }
    
    func handleSigInt() {
        print("Stopping")
        var tattr = termios()
        tcgetattr(STDIN_FILENO, &tattr)
        tattr.c_lflag |= tcflag_t(ECHO | ICANON)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &tattr)
        exit(0)
    }
}

extension UTF8.CodeUnit {
    fileprivate var isUnescapedByte: Bool {
        self != .init(ascii: "\"") && self != .init(ascii: "\\")
    }
}

extension Container {
    static let inputService = Factory(scope: .cached) { InputService() }
}
