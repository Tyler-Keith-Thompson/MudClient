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
    @LazyInjected(Container.cursor) private var cursor
    let lock = NSRecursiveLock()
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
            case .leftArrow: cursor.moveLeft()
            case .rightArrow: cursor.moveRight(line: lineBuffer)
            case .upArrow: break
            case .downArrow: break
            case .backspace:
                if cursor.column > 1 {
                    let index = lineBuffer.index(lineBuffer.startIndex, offsetBy: cursor.column - 2)
                    lineBuffer.remove(at: index)
                    refreshDisplay(fromColumn: cursor.column - 1)
                    cursor.update(column: cursor.column - 1)
                }
            case .controlA: cursor.moveToStartOfLine()
            case .controlE: cursor.moveToEndOf(line: lineBuffer)
            case .enter:
                lineBuffer.append(contentsOf: partialInput.dropLast())
                cursor.moveToStartOfLine()
                let echo = lineBuffer
                lineBuffer = ""
                print("\n\(echo)".utf8)
                cursor.moveToStartOfLine()
                do {
                    try Container.inputService().parse(input: echo)
                } catch {
                    print(error)
                }
            }
            partialInput = ""
        case .failure where !partialInput.hasPrefix("\u{1B}") || partialInput.count > 2:
            // Handle normal character input
            let index = lineBuffer.index(lineBuffer.startIndex, offsetBy: cursor.column - 1)
            lineBuffer.insert(contentsOf: input, at: index)
            refreshDisplay(fromColumn: cursor.column)
            cursor.moveRightBy(amount: input.count)
            partialInput = ""
        case .failure(let error):
            print(error)
        }
    }
    
    func setup() {
        print("")
    }
    
    func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
        let cursorColumn = cursor.column
        clearInputAndDividerLines()
        
        let output = items.map(String.init(describing:)).joined(separator: separator) + terminator
        writeToStandardOut(data: Data(output.utf8))
        
        let divider = String(repeating: "-", count: getTerminalWidth() ?? 80)
        writeToStandardOut(data: Data("\(output.hasSuffix("\n") ? "" : "\n")\(divider)\n".utf8))
        writeToStandardOut(data: Data(lineBuffer.utf8))
        cursor.moveToStartOfLine()
        if !lineBuffer.isEmpty {
            cursor.moveRightBy(amount: cursorColumn - 1)
        }
    }
    
    private func clearInputAndDividerLines() {
        // Move to the beginning of the input line (assumed to be the current line)
        writeToStandardOut(data: Data("\u{1B}[1G".utf8))
        // Clear the entire line (input line)
        writeToStandardOut(data: Data("\u{1B}[2K".utf8))
        
        // Move cursor up one line to the divider line
        writeToStandardOut(data: Data("\u{1B}[1A".utf8))
        // Move to the beginning of the divider line
        writeToStandardOut(data: Data("\u{1B}[1G".utf8))
        // Clear the entire divider line
        writeToStandardOut(data: Data("\u{1B}[2K".utf8))
        
        // Move cursor back down to the input line (now clear)
        writeToStandardOut(data: Data("\u{1B}[1B".utf8))
    }
    
    private func getTerminalHeight() -> Int? {
        var w = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0 {
            return Int(w.ws_row)
        }
        return nil
    }
    
    private func getTerminalWidth() -> Int? {
        var w = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0 {
            return Int(w.ws_col)
        }
        return nil
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
    
    func handleSigInt() {
        if lineBuffer.isEmpty {
            var tattr = termios()
            tcgetattr(STDIN_FILENO, &tattr)
            tattr.c_lflag |= tcflag_t(ECHO | ICANON)
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &tattr)
            Swift.print("\nStopping")
            exit(0)
        } else {
            cursor.moveToStartOfLine()
            // Clear the entire line (input line)
            writeToStandardOut(data: Data("\u{1B}[2K".utf8))
            lineBuffer = ""
            partialInput = ""
        }
    }
}

extension Container {
    static let terminalService = Factory(scope: .cached) { TerminalService() }
}
