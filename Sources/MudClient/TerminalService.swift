//
//  TerminalService.swift
//  MudClient
//
//  Created by Tyler Thompson on 8/16/24.
//

import Foundation
import DependencyInjection
import Parsing

final class TerminalService {
    static func setRawTerminal() {
        var tattr = termios()
        tcgetattr(STDIN_FILENO, &tattr)
        tattr.c_lflag &= ~tcflag_t(ECHO | ICANON)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &tattr)
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
                do {
                    try Container.inputService().parse(input: lineBuffer)
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
        
        let parser = Parse {
            "\u{1B}["
            Int.parser()
            ";"
            Int.parser()
            "R"
        }
        
        if let response = String(bytes: buffer.prefix(responseLength), encoding: .utf8),
           let result = try? parser.parse(response) {
            return (row: result.0, column: result.1)
        }
        
        return nil
    }
}

extension Container {
    static let terminalService = Factory(scope: .cached) { TerminalService() }
}
