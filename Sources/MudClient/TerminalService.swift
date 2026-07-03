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

    /// The band geometry (top panel : bottom panel heights) the scroll region is currently sized for.
    /// An empty string forces `setupScreen` to (re)establish the region on the next paint; it's the
    /// mismatch check that lets the region track panels appearing/growing/shrinking.
    private var lastSignature = ""
    /// The previous frozen-band extents, so when a band shrinks/moves we can clear the rows it vacated
    /// (now part of the scrolling output region) instead of leaving stale panel text behind. -1 = none.
    private var lastTopHeight = -1
    private var lastOutputBottom = -1

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
        // Take firm control of a clean, full screen from a known state before we start managing bands:
        //   ESC[?6l  origin mode OFF, so absolute cursor moves address the whole screen rather than
        //            being confined to an inherited scroll region (that offset was leaving the shell
        //            prompt visible up top and lopping a row off our panel);
        //   ESC[r    drop any inherited scroll region;
        //   ESC[2J   clear leftover shell-prompt / build clutter so none lingers in a frozen band.
        writeToStandardOut(data: Data("\u{1B}[?6l\u{1B}[r\u{1B}[2J".utf8))
        setupScreen()
    }

    // MARK: - Screen layout
    //
    // The screen frames a scrolling OUTPUT region with subtle dividers, top-to-bottom:
    //   1. an optional TOP panel (the group roster), frozen at the top;
    //   2. a subtle divider (top edge of the scroll frame);
    //   3. the scrolling OUTPUT region;
    //   4. a subtle divider (bottom edge of the scroll frame);
    //   5. the bottom status panel;
    //   6. a subtle divider directly above the input line;
    //   7. the input line.
    // A DECSTBM scroll region (`ESC[{regionTop};{outputBottom}r`) confines all scrolling output to band
    // 3, so the panels, dividers, and input never move. Output and typing use two separate cursors: the
    // OUTPUT cursor is parked at the bottom of the scroll region and saved/restored with DECSC/DECRC
    // (`ESC7`/`ESC8`) around every write, while the physical cursor rests on the input line. Everything
    // else is painted with absolute moves that never touch the saved slot, so a server line arriving
    // mid-type repaints around the input without disturbing it.

    private struct Layout {
        let height, width, topHeight, bottomHeight: Int
        let topDividerRow, regionTop, outputBottom, scrollDividerRow: Int
        let bottomPanelTop, inputDividerRow, inputRow: Int
    }

    private func layout() -> Layout? {
        guard let h = getTerminalHeight(), let w = getTerminalWidth() else { return nil }
        let topHeight = Container.topPanelHost().height
        let bottomHeight = Container.panelHost().height
        // top band: group panel + one divider framing the scroll's top edge.
        let topReserved = topHeight + 1
        // bottom band: scroll-frame divider + status panel + input divider + input line.
        let bottomReserved = bottomHeight + 3
        let regionTop = topReserved + 1
        let outputBottom = max(regionTop, h - bottomReserved)
        return Layout(height: h, width: w, topHeight: topHeight, bottomHeight: bottomHeight,
                      topDividerRow: topHeight + 1,               // divider below the top panel
                      regionTop: regionTop,
                      outputBottom: outputBottom,
                      scrollDividerRow: outputBottom + 1,         // divider below the scroll region
                      bottomPanelTop: outputBottom + 2,           // status panel below that divider
                      inputDividerRow: h - 1,                     // divider directly above the input
                      inputRow: h)
    }

    /// A compact signature of the band geometry; when it changes (panel heights, top panel appearing)
    /// the scroll region must be re-established.
    private func signature(_ l: Layout) -> String { "\(l.topHeight):\(l.bottomHeight)" }

    /// A subtle (dim) full-width horizontal rule used to frame the scroll region.
    private func dividerLine(width: Int) -> String {
        "\u{1B}[90m" + String(repeating: "─", count: width) + "\u{1B}[0m"
    }

    /// Establish (or re-establish) the scroll region and park + save the output cursor at its bottom,
    /// then paint all furniture. Called at startup, on resize, and whenever a band's height changes.
    private func setupScreen() {
        guard let l = layout() else { return }
        lastSignature = signature(l)
        var out = ""
        // Clear rows that were frozen furniture in the PREVIOUS geometry but now fall inside the scroll
        // region (a band shrank or moved), so no stale panel/divider text is left behind.
        if lastTopHeight > 0 { out += clearRows(from: 1, through: lastTopHeight + 1) }
        if lastOutputBottom >= 0 { out += clearRows(from: lastOutputBottom + 1, through: l.height) }
        out += "\u{1B}[\(l.regionTop);\(l.outputBottom)r"      // scroll region = the output band only
        out += "\u{1B}[\(l.outputBottom);1H\u{1B}7"            // park output cursor at region bottom, save it
        writeToStandardOut(data: Data(out.utf8))
        lastTopHeight = l.topHeight
        lastOutputBottom = l.outputBottom
        drawFurniture(l)
    }

    private func clearRows(from: Int, through: Int) -> String {
        guard through >= from else { return "" }
        return (from...through).reduce("") { $0 + "\u{1B}[\($1);1H\u{1B}[2K" }
    }

    func print(_ string: Any, terminator: String = "\n") {
        guard let l = layout() else { return }
        // Hide the cursor for the whole repaint so its round-trip — up to the output region to write,
        // then back down to the input line — happens invisibly (that jump was the flicker).
        writeToStandardOut(data: Data("\u{1B}[?25l".utf8))
        if lastSignature != signature(l) { setupScreen() }     // band geometry changed → resize region
        var out = "\u{1B}8"                                 // restore output cursor (bottom of region)
        out += String(describing: string) + terminator      // write output; scrolls within the region
        out += "\u{1B}7"                                     // save the new output cursor
        writeToStandardOut(data: Data(out.utf8))
        drawFurniture(l)                                    // repaint furniture; parks cursor on input
        writeToStandardOut(data: Data("\u{1B}[?25h".utf8))  // show the cursor, now back at the input line
    }

    /// Paint one server/output chunk. Empty chunks (a fully-gagged status batch) carry no text but a
    /// panel may still have changed, so just refresh the furniture.
    func render(_ chunk: String) {
        if chunk.isEmpty {
            refreshFurniture()
        } else {
            print(chunk, terminator: "")
        }
    }

    /// Repaint all furniture without writing any output (e.g. after a panel-only state change).
    func refreshFurniture() {
        guard let l = layout() else { return }
        writeToStandardOut(data: Data("\u{1B}[?25l".utf8))   // hide cursor during the repaint (no flicker)
        if lastSignature != signature(l) { setupScreen() } else { drawFurniture(l) }
        writeToStandardOut(data: Data("\u{1B}[?25h".utf8))   // show it, back on the input line
    }

    /// Paint the top panel, the scroll-frame dividers, the bottom status panel, and the input line —
    /// all absolute, none touching the saved output cursor — leaving the physical cursor on the input.
    private func drawFurniture(_ l: Layout) {
        var out = ""
        if l.topHeight > 0 {                                 // top panel (group), rows 1..topHeight
            let rows = Container.topPanelHost().rows(width: l.width)
            for i in 0..<l.topHeight {
                out += "\u{1B}[\(1 + i);1H\u{1B}[2K"
                if i < rows.count { out += rows[i] }
            }
        }
        // subtle divider framing the top of the scroll region
        out += "\u{1B}[\(l.topDividerRow);1H\u{1B}[2K" + dividerLine(width: l.width)
        // subtle divider framing the bottom of the scroll region
        out += "\u{1B}[\(l.scrollDividerRow);1H\u{1B}[2K" + dividerLine(width: l.width)
        if l.bottomHeight > 0 {                              // status panel, below the scroll frame
            let rows = Container.panelHost().rows(width: l.width)
            for i in 0..<l.bottomHeight {
                out += "\u{1B}[\(l.bottomPanelTop + i);1H\u{1B}[2K"
                if i < rows.count { out += rows[i] }
            }
        }
        // subtle divider directly above the input line
        out += "\u{1B}[\(l.inputDividerRow);1H\u{1B}[2K" + dividerLine(width: l.width)
        writeToStandardOut(data: Data(out.utf8))
        drawInputLine(l, cursorColumn: cursor.column)
    }

    /// On resize the region and furniture positions move, so clear and rebuild from scratch.
    func handleResize() {
        writeToStandardOut(data: Data("\u{1B}[2J".utf8))
        lastSignature = ""
        lastTopHeight = -1
        lastOutputBottom = -1
        setupScreen()
    }

    /// Reset the scroll region and drop to the bottom of the screen so we don't leave the terminal in
    /// a weird state on exit.
    func teardownScreen() {
        var out = "\u{1B}[r"                                // reset scroll region to the full screen
        out += "\u{1B}[?25h"                                // make sure the cursor is visible again
        out += "\u{1B}[\(getTerminalHeight() ?? 24);1H"
        writeToStandardOut(data: Data(out.utf8))
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
        let trimmed = echo.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != commandHistory.last {
            commandHistory.append(trimmed)
        }
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

    /// Redraw just the input line (used by the keystroke handlers). Looks up the current layout so the
    /// line always lands on the absolute input row below the panel.
    private func refreshDisplay(cursorColumn: Int) {
        guard let l = layout() else { return }
        drawInputLine(l, cursorColumn: cursorColumn)
    }

    /// Draw the input buffer on the absolute input row, horizontally scrolled to keep the cursor in
    /// view, and leave the physical cursor at the typing column. Never touches the saved output cursor.
    private func drawInputLine(_ l: Layout, cursorColumn: Int) {
        let terminalWidth = l.width

        // Scroll the visible window so the cursor stays on screen.
        if cursorColumn < visibleStartColumn + 1 {
            visibleStartColumn = max(0, cursorColumn - 1)
        } else if cursorColumn > visibleStartColumn + terminalWidth - 1 {
            visibleStartColumn = cursorColumn - terminalWidth + 1
        }

        let start = min(visibleStartColumn, lineBuffer.count)
        let visibleStartIndex = lineBuffer.index(lineBuffer.startIndex, offsetBy: start)
        let length = min(terminalWidth - 1, lineBuffer.distance(from: visibleStartIndex, to: lineBuffer.endIndex))
        let visibleEndIndex = lineBuffer.index(visibleStartIndex, offsetBy: max(0, length))
        let visibleText = String(lineBuffer[visibleStartIndex..<visibleEndIndex])

        let cursorOffset = cursorColumn - visibleStartColumn
        var out = "\u{1B}[\(l.inputRow);1H\u{1B}[2K"        // to input row, clear it
        out += visibleText
        out += "\u{1B}[\(l.inputRow);\(cursorOffset)H"      // park cursor at the typing column
        writeToStandardOut(data: Data(out.utf8))
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
            teardownScreen()   // reset the scroll region so the terminal isn't left stuck
            var tattr = termios()
            tcgetattr(STDIN_FILENO, &tattr)
            tattr.c_lflag |= tcflag_t(ECHO | ICANON)
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &tattr)
            Swift.print("\nStopping")
            exit(0)
        } else {
            cursor.moveToStartOfLine()
            lineBuffer = ""
            partialInput = ""
            visibleStartColumn = 0
            refreshDisplay(cursorColumn: cursor.column)   // clear + redraw the (now empty) input line
        }
    }
}

extension Container {
    static let terminalService = Factory(scope: .cached) { TerminalService() }
}
