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
    static func takeOverTerminal() {
        var tattr = termios()
        tcgetattr(STDIN_FILENO, &tattr)
        tattr.c_lflag &= ~tcflag_t(ECHO | ICANON)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &tattr)
    }
    
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
            } else {
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
    
    enum KeyCommand {
        case leftArrow
        case rightArrow
        case upArrow
        case downArrow
        case backspace
        case controlA
        case controlE
        case enter
    }
    
    private lazy var lineParser = Parse {
        OneOf {
            controlA
            controlE
            leftArrow
            rightArrow
            upArrow
            downArrow
            backspace
            enter
        }
    }

    private lazy var controlA = Parse {
        "\u{01}".map { KeyCommand.controlA }
    }
    
    private lazy var controlE = Parse {
        "\u{05}".map { KeyCommand.controlE }
    }
    
    private lazy var leftArrow = Parse {
        "\u{1B}[D".map { KeyCommand.leftArrow }
    }
    
    private lazy var rightArrow = Parse {
        "\u{1B}[C".map { KeyCommand.rightArrow }
    }
    
    private lazy var upArrow = Parse {
        "\u{1B}[A".map { KeyCommand.upArrow }
    }
    
    private lazy var downArrow = Parse {
        "\u{1B}[B".map { KeyCommand.downArrow }
    }
    
    private lazy var backspace = Parse {
        "\u{7F}".map { KeyCommand.backspace }
    }
    
    private lazy var enter: AnyParser<Substring, KeyCommand> = Parse {
        Skip { Optionally { Prefix { $0 != "\n" } } }
        "\n".map { KeyCommand.enter }
    }.eraseToAnyParser()
    
    var lineBuffer: String = ""
    var partialInput: String = ""

    func handle(input: String) {
        partialInput.append(input)
        
        switch Result(catching: { try lineParser.parse(partialInput) }) {
        case .success(let command):
            switch command {
            case .leftArrow: moveCursorLeft()
            case .rightArrow: moveCursorRight()
            case .upArrow: break
            case .downArrow: break
            case .backspace:
                if let cursorPosition = getCursorPosition(), cursorPosition.column > 1 {
                    let index = lineBuffer.index(lineBuffer.startIndex, offsetBy: cursorPosition.column - 2)
                    lineBuffer.remove(at: index)
                    refreshDisplay(fromColumn: cursorPosition.column - 1)
                }
            case .controlA: moveToStartOfLine()
            case .controlE: moveToEndOfLine()
            case .enter:
                moveToEndOfLine()
                lineBuffer.append(contentsOf: partialInput.dropLast())
                writeToStandardOut(data: Data("\n".utf8))
                moveToStartOfLine()
                print("Full line: \(lineBuffer)")
                do {
                    try parse(input: lineBuffer)
                } catch {
                    print(error)
                }
                lineBuffer = ""
            }
            partialInput = ""
        case .failure where !partialInput.hasPrefix("\u{1B}") || partialInput.count > 2:
            // Handle normal character input
            if let cursorPosition = getCursorPosition() {
                let index = lineBuffer.index(lineBuffer.startIndex, offsetBy: cursorPosition.column - 1)
                lineBuffer.insert(contentsOf: input, at: index)
                refreshDisplay(fromColumn: cursorPosition.column)
                moveCursorRightBy(amount: input.count)
            }
            partialInput = ""
        case .failure(let error):
            print(error)
        }
    }

    func moveCursorLeft() {
        writeToStandardOut(data: Data("\u{1B}[D".utf8))
    }

    func moveCursorRight() {
        if let cursorPosition = getCursorPosition(), cursorPosition.column <= lineBuffer.count {
            writeToStandardOut(data: Data("\u{1B}[C".utf8))
        }
    }

    func moveCursorRightBy(amount: Int) {
        if amount > 0 {
            writeToStandardOut(data: Data("\u{1B}[\(amount)C".utf8))
        }
    }

    func moveToStartOfLine() {
        writeToStandardOut(data: Data("\u{1B}[1G".utf8))
    }

    func moveToEndOfLine() {
        let endPosition = lineBuffer.count
        writeToStandardOut(data: Data("\u{1B}[\(endPosition+1)G".utf8))
    }

    func refreshDisplay(fromColumn startColumn: Int) {
        writeToStandardOut(data: Data("\u{1B}[\(startColumn)G".utf8))
        writeToStandardOut(data: Data("\u{1B}[K".utf8))
        let startIndex = lineBuffer.index(lineBuffer.startIndex, offsetBy: startColumn - 1)
        let remainder = String(lineBuffer[startIndex...])
        writeToStandardOut(data: Data(remainder.utf8))
        writeToStandardOut(data: Data("\u{1B}[\(startColumn)G".utf8))
    }

    func writeToStandardOut(data: Data) {
        do {
            try FileHandle.standardOutput.write(contentsOf: data)
        } catch {
            print(error)
        }
    }
    
    func getCursorPosition() -> (row: Int, column: Int)? {
        // Request cursor position
        let requestPosition = "\u{1B}[6n"
        writeToStandardOut(data: Data(requestPosition.utf8))
        
        // Read the response from the terminal
        var buffer = [UInt8](repeating: 0, count: 32)
        let responseLength = read(STDIN_FILENO, &buffer, buffer.count)
        
        // Convert response to a string
        
        
        // Match the response format \u{1B}[<row>;<column>R
        let pattern = "\u{1B}\\[([0-9]+);([0-9]+)R"
        if let regex = try? NSRegularExpression(pattern: pattern),
           let response = String(bytes: buffer.prefix(responseLength), encoding: .utf8),
           let match = regex.firstMatch(in: response, range: NSRange(response.startIndex..., in: response)),
           let rowRange = Range(match.range(at: 1), in: response),
           let columnRange = Range(match.range(at: 2), in: response) {
            let row = Int(response[rowRange])
            let column = Int(response[columnRange])
            return (row: row ?? 0, column: column ?? 0)
        }
        
        return nil
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
