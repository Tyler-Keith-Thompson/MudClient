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
    var visibleStartColumn = 0
    var commandHistory: [String] = []
    var currentCommandIndex: Int = 0

    func handle(input: String) {
        partialInput.append(input)
        
        switch Result(catching: { try lineParser.parse(partialInput) }) {
        case .success(let command):
            switch command {
            case .leftArrow:
                cursor.moveLeft()
                refreshDisplay(cursorColumn: cursor.column)
            case .rightArrow:
                cursor.moveRight(line: lineBuffer)
                refreshDisplay(cursorColumn: cursor.column)
            case .upArrow: handleUpArrow()
            case .downArrow: handleDownArrow()
            case .backspace: handleBackspace()
            case .controlA:
                cursor.moveToStartOfLine()
                refreshDisplay(cursorColumn: cursor.column)
            case .controlE:
                cursor.moveToEndOf(line: lineBuffer)
                refreshDisplay(cursorColumn: cursor.column)
            case .enter: handleEnter()
            }
            partialInput = ""
        case .failure where !partialInput.hasPrefix("\u{1B}") || partialInput.count > 2:
            handleOther(input: input)
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
        refreshDisplay(cursorColumn: cursor.column)
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
    
    private func handleUpArrow() {
        if currentCommandIndex > 0 {
            currentCommandIndex -= 1
            let previousCommand = commandHistory[currentCommandIndex]
            lineBuffer = previousCommand
            cursor.moveToEndOf(line: lineBuffer)
            refreshDisplay(cursorColumn: cursor.column)
        } else if currentCommandIndex == 0 && !commandHistory.isEmpty {
            // Special case: When already at the first command
            lineBuffer = commandHistory[currentCommandIndex]
            cursor.moveToEndOf(line: lineBuffer)
            refreshDisplay(cursorColumn: cursor.column)
        }
    }
    
    private func handleDownArrow() {
        if currentCommandIndex < commandHistory.count - 1 {
            currentCommandIndex += 1
            let nextCommand = commandHistory[currentCommandIndex]
            lineBuffer = nextCommand
            cursor.moveToEndOf(line: lineBuffer)
            refreshDisplay(cursorColumn: cursor.column)
        } else if currentCommandIndex == commandHistory.count - 1 {
            // Special case: When at the last command and pressing down
            currentCommandIndex += 1
            cursor.moveToStartOfLine()
            lineBuffer = ""
            visibleStartColumn = 0
            refreshDisplay(cursorColumn: cursor.column)
        }
    }
    
    private func handleBackspace() {
        if cursor.column > 1 {
            let index = lineBuffer.index(lineBuffer.startIndex, offsetBy: cursor.column - 2)
            lineBuffer.remove(at: index)
            
            // Calculate the necessary visibleStartColumn to keep the end aligned with the terminal width
            let terminalWidth = getTerminalWidth() ?? 80
            if lineBuffer.count <= terminalWidth {
                visibleStartColumn = 0  // If the entire input fits, no need to scroll
            } else {
                // Keep the end of the visible text aligned with the right edge of the terminal
                visibleStartColumn = max(0, lineBuffer.count - terminalWidth)
            }
            
            // Refresh display and update cursor position
            refreshDisplay(cursorColumn: cursor.column - 1)
            cursor.update(column: cursor.column - 1)
        }
    }
    
    private func handleEnter() {
        lineBuffer.append(contentsOf: partialInput.dropLast())
        cursor.moveToStartOfLine()
        let echo = lineBuffer
        lineBuffer = ""
        visibleStartColumn = 0
        print("\n\(echo)".utf8)
        cursor.moveToStartOfLine()
        commandHistory.append(echo)
        currentCommandIndex = commandHistory.count
        do {
            try Container.inputService().parse(input: echo)
        } catch {
            print(error)
        }
    }
    
    private func handleOther(input: String) {
        // Handle normal character input
        let index = lineBuffer.index(lineBuffer.startIndex, offsetBy: cursor.column - 1)
        lineBuffer.insert(contentsOf: input, at: index)
        refreshDisplay(cursorColumn: cursor.column)
        cursor.moveRightBy(amount: input.count)
        partialInput = ""
    }

    private func refreshDisplay(cursorColumn: Int) {
        // Get the terminal width
        guard let terminalWidth = getTerminalWidth() else { return }

        // Determine if scrolling is necessary
        if cursorColumn < visibleStartColumn + 1 {
            // Cursor is left of the visible window, so scroll left
            visibleStartColumn = max(0, cursorColumn - 1)
        } else if cursorColumn > visibleStartColumn + terminalWidth - 1 {
            // Cursor is right of the visible window, so scroll right
            visibleStartColumn = cursorColumn - terminalWidth + 1
        }

        // Calculate the starting index for the visible portion of the lineBuffer
        let visibleStartIndex = lineBuffer.index(lineBuffer.startIndex, offsetBy: visibleStartColumn)
        let visibleEndIndex = lineBuffer.index(visibleStartIndex, offsetBy: min(terminalWidth - 1, lineBuffer.distance(from: visibleStartIndex, to: lineBuffer.endIndex)))
        let visibleText = String(lineBuffer[visibleStartIndex..<visibleEndIndex])

        // Move the cursor to the beginning of the line
        writeToStandardOut(data: Data("\u{1B}[1G".utf8))
        // Clear the current line
        writeToStandardOut(data: Data("\u{1B}[2K".utf8))
        // Write the visible portion of the lineBuffer to the terminal
        writeToStandardOut(data: Data(visibleText.utf8))
        
        // Calculate the cursor position within the visible text
        let cursorOffset = cursorColumn - visibleStartColumn
        writeToStandardOut(data: Data("\u{1B}[\(cursorOffset)G".utf8))
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
