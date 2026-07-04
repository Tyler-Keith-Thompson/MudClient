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

    // MARK: - Scrollback state
    //
    // A shadow copy of everything that has scrolled through the OUTPUT band, so the mouse wheel can
    // page back through history WITHOUT dragging the frozen panels (which is what the terminal's own
    // scrollback would do). Lines are stored logically (split on newline) with their ANSI SGR codes
    // intact; a scrolled redraw re-wraps them to the current width and repaints only the output rows.

    /// Completed output lines, oldest first, stored without their trailing newline. Bounded so a long
    /// session's memory stays flat.
    private var scrollbackLines: [String] = []
    /// The current incomplete line — text emitted since the last newline. "" when the last output
    /// ended on a newline. Kept separate so the live tail (and the output cursor's column) reproduce
    /// exactly when we snap back to live.
    private var pendingLine = ""
    /// Cap on retained history lines; the oldest are dropped past this.
    private let scrollbackLimit = 5000
    /// How many PHYSICAL (wrapped) rows the view is currently parked above the live tail. 0 = live,
    /// and while 0 every existing behaviour is untouched.
    private var scrollOffset = 0
    /// Rows the wheel moves per notch.
    private let wheelStep = 3

    func handle(input: String) {
        // Peel off any SGR mouse reports (wheel events) BEFORE line editing — they must never reach
        // the line editor or the MUD. What remains is real keyboard input.
        let keyInput = consumeMouseEvents(in: input)
        guard !keyInput.isEmpty else { return }
        partialInput.append(keyInput)

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
        // Enable SGR mouse reporting so the wheel drives our in-app scrollback instead of the
        // terminal's native scrollback (which would drag the frozen panels up/down):
        //   ESC[?1000h  report button press/release (wheel notches arrive as buttons 64/65);
        //   ESC[?1006h  SGR extended encoding, so events read as ESC[<b;x;yM / m (no coordinate cap).
        // Trade-off: with reporting on, the terminal hands clicks to us instead of doing local
        // text selection; most emulators still allow selection while holding Shift/Option.
        writeToStandardOut(data: Data("\u{1B}[?1000h\u{1B}[?1006h".utf8))
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
        scrollOffset = 0   // any (re)establishment of the region snaps back to the live tail

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
        let payload = String(describing: string) + terminator
        // Hide the cursor for the whole repaint so its round-trip — up to the output region to write,
        // then back down to the input line — happens invisibly (that jump was the flicker).
        writeToStandardOut(data: Data("\u{1B}[?25l".utf8))
        if lastSignature != signature(l) { setupScreen() }     // band geometry changed → resize region (snaps to live)

        if scrollOffset > 0 {
            // The user is reading history: don't scroll the live band out from under them. Record the
            // new output, keep the same lines in view by bumping the offset by however many physical
            // rows it added, and repaint the history at the new offset. The live write is deferred —
            // snapping back to the tail repaints the whole band from the buffer anyway.
            let before = physicalRows(width: l.width).count
            recordOutput(payload)
            let rows = physicalRows(width: l.width)
            let outputHeight = l.outputBottom - l.regionTop + 1
            let maxOffset = max(0, rows.count - outputHeight)
            scrollOffset = min(scrollOffset + (rows.count - before), maxOffset)
            drawFurniture(l)                                 // panels may have changed; never touches the band
            paintRegion(l, rows: rows)                       // overwrite the band with history at the offset
            paintScrollIndicator(l)                          // dim marker so the parked view is obvious
            drawInputLine(l, cursorColumn: cursor.column)    // return the physical cursor to the input line
            writeToStandardOut(data: Data("\u{1B}[?25h".utf8))
            return
        }

        recordOutput(payload)                               // keep the scrollback shadow current
        var out = "\u{1B}8"                                 // restore output cursor (bottom of region)
        out += payload                                       // write output; scrolls within the region
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
        if scrollOffset > 0 {                                // keep the scrolled marker & cursor placement
            paintScrollIndicator(l)
            drawInputLine(l, cursorColumn: cursor.column)
        }
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
        scrollOffset = 0   // wrapping changes with width → snap to the live tail and rebuild
        setupScreen()
    }

    /// Reset the scroll region and drop to the bottom of the screen so we don't leave the terminal in
    /// a weird state on exit.
    func teardownScreen() {
        var out = "\u{1B}[?1000l\u{1B}[?1006l"              // disable mouse reporting (restore native wheel/selection)
        out += "\u{1B}[r"                                   // reset scroll region to the full screen
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

    // MARK: - Scrollback buffer & mouse-wheel scrolling

    /// Fold one written output payload into the scrollback shadow. Splits on newlines: every "\n"
    /// completes the pending line into `scrollbackLines`; the remainder becomes the new pending line.
    /// ANSI escape codes are kept verbatim so a scrolled redraw reproduces the original colouring;
    /// bare carriage returns (rare — the connection pipeline normalises line endings) are dropped.
    private func recordOutput(_ text: String) {
        guard !text.isEmpty else { return }
        var segment = pendingLine
        for ch in text {
            switch ch {
            case "\n":
                scrollbackLines.append(segment)
                segment = ""
            case "\r":
                break                                       // ignore stray CR; don't disturb the line
            default:
                segment.append(ch)
            }
        }
        pendingLine = segment
        if scrollbackLines.count > scrollbackLimit {
            scrollbackLines.removeFirst(scrollbackLines.count - scrollbackLimit)
        }
    }

    /// Break one logical line into physical rows of at most `width` VISIBLE characters, copying ANSI
    /// escape sequences verbatim (they never count toward the width). A blank logical line yields one
    /// blank row so vertical spacing is preserved. NOTE: colour state is not carried across a wrap
    /// boundary, so the continuation of a coloured line longer than the terminal width renders
    /// uncoloured — rare in MUD output and purely cosmetic in the scrolled-back view.
    private func wrapVisible(_ line: String, width: Int) -> [String] {
        guard width > 0 else { return [line] }
        let chars = Array(line)
        var rows: [String] = []
        var current = ""
        var visible = 0
        var i = 0
        while i < chars.count {
            if chars[i] == "\u{1B}" {                        // copy an escape sequence without counting it
                var j = i + 1
                if j < chars.count && chars[j] == "[" {      // CSI: params then a final byte 0x40–0x7E
                    j += 1
                    while j < chars.count {
                        let final = chars[j].asciiValue.map { 0x40...0x7E ~= $0 } ?? false
                        j += 1
                        if final { break }
                    }
                } else if j < chars.count {                   // simple two-byte escape
                    j += 1
                }
                current += String(chars[i..<j])
                i = j
            } else {
                if visible == width {                         // hit the edge → start a new physical row
                    rows.append(current)
                    current = ""
                    visible = 0
                }
                current.append(chars[i])
                visible += 1
                i += 1
            }
        }
        rows.append(current)                                  // always flush (preserves a trailing/blank row)
        return rows
    }

    /// The number of VISIBLE characters in a string, skipping ANSI escape sequences.
    private func visibleLength(_ s: String) -> Int {
        let chars = Array(s)
        var count = 0
        var i = 0
        while i < chars.count {
            if chars[i] == "\u{1B}" {
                var j = i + 1
                if j < chars.count && chars[j] == "[" {
                    j += 1
                    while j < chars.count {
                        let final = chars[j].asciiValue.map { 0x40...0x7E ~= $0 } ?? false
                        j += 1
                        if final { break }
                    }
                } else if j < chars.count {
                    j += 1
                }
                i = j
            } else {
                count += 1
                i += 1
            }
        }
        return count
    }

    /// The full ordered list of physical (wrapped) rows the output band has ever shown, ending with
    /// the current live tail. The last element is always the row the live output cursor sits on
    /// (empty when the last write ended on a newline), so index `count-1` is the live bottom row.
    private func physicalRows(width: Int) -> [String] {
        var rows: [String] = []
        for line in scrollbackLines { rows += wrapVisible(line, width: width) }
        rows += wrapVisible(pendingLine, width: width)
        return rows
    }

    /// Peel every SGR mouse report (`ESC[<b;x;yM` / `m`) out of `input`, dispatch it, and return the
    /// remaining real keyboard bytes. A mouse report split across two reads is stashed and completed
    /// on the next call. Only the `ESC[<` prefix is diverted, so arrow keys (`ESC[A`…`ESC[D`) still
    /// flow to the line parser untouched.
    private func consumeMouseEvents(in input: String) -> String {
        let chars = Array(mousePartial + input)
        mousePartial = ""
        var output = ""
        var i = 0
        while i < chars.count {
            if chars[i] == "\u{1B}", i + 2 < chars.count, chars[i + 1] == "[", chars[i + 2] == "<" {
                var j = i + 3
                while j < chars.count && chars[j] != "M" && chars[j] != "m" { j += 1 }
                if j < chars.count {                          // complete report: "b;x;y" + M/m
                    handleMouse(String(chars[(i + 3)..<j]), press: chars[j] == "M")
                    i = j + 1
                } else {                                      // incomplete tail → finish it next read
                    mousePartial = String(chars[i...])
                    break
                }
            } else {
                output.append(chars[i])
                i += 1
            }
        }
        return output
    }

    /// A partial mouse report held between reads (`ESC[<…` with no terminator yet).
    private var mousePartial = ""

    /// Act on one SGR mouse report. We only care about the wheel on press; modifier bits (shift/meta/
    /// ctrl) are masked off so a modified wheel still scrolls. Clicks/drags/releases are swallowed.
    private func handleMouse(_ body: String, press: Bool) {
        guard press, let button = Int(body.split(separator: ";").first ?? "") else { return }
        switch button & ~0b0001_1100 {                        // strip shift(4)/meta(8)/ctrl(16) bits
        case 64: adjustScroll(by: wheelStep)                  // wheel up → older history
        case 65: adjustScroll(by: -wheelStep)                 // wheel down → toward the live tail
        default: break
        }
    }

    /// Move the scroll view by `delta` physical rows (positive = back in history). Clamps to the
    /// buffer, and repaints only the output band — the panels, dividers and input line never move.
    private func adjustScroll(by delta: Int) {
        guard let l = layout() else { return }
        let rows = physicalRows(width: l.width)
        let outputHeight = l.outputBottom - l.regionTop + 1
        let maxOffset = max(0, rows.count - outputHeight)
        let newOffset = max(0, min(scrollOffset + delta, maxOffset))
        guard newOffset != scrollOffset else { return }
        scrollOffset = newOffset
        if scrollOffset == 0 {
            resumeLive(l, rows: rows)                          // snapped to the tail → hand back to live output
        } else {
            paintScrolled(l, rows: rows)
        }
    }

    /// Repaint the frozen furniture, then overwrite the output band with history at the current
    /// offset and stamp the scrolled marker. Leaves the physical cursor on the input line. The saved
    /// OUTPUT cursor (DECSC slot) is never touched, so live output resumes cleanly on `resumeLive`.
    private func paintScrolled(_ l: Layout, rows: [String]) {
        writeToStandardOut(data: Data("\u{1B}[?25l".utf8))
        drawFurniture(l)
        paintRegion(l, rows: rows)
        paintScrollIndicator(l)
        drawInputLine(l, cursorColumn: cursor.column)
        writeToStandardOut(data: Data("\u{1B}[?25h".utf8))
    }

    /// Snap back to the live tail: repaint the band from the buffer's tail, then re-park and DECSC-save
    /// the OUTPUT cursor at the end of the newest row so the next write scrolls the region normally,
    /// and repaint furniture (which clears the scrolled marker). Physical cursor ends on the input line.
    private func resumeLive(_ l: Layout, rows: [String]) {
        writeToStandardOut(data: Data("\u{1B}[?25l".utf8))
        paintRegion(l, rows: rows)                            // scrollOffset == 0 → this is the live tail
        let col = visibleLength(rows.last ?? "") + 1
        writeToStandardOut(data: Data("\u{1B}[\(l.outputBottom);\(col)H\u{1B}7".utf8)) // re-park + save output cursor
        drawFurniture(l)                                      // repaints a plain divider, clearing the marker
        writeToStandardOut(data: Data("\u{1B}[?25h".utf8))
    }

    /// Overwrite the output band with physical rows from `rows`, bottom-aligned so the newest shown
    /// row sits on the region's bottom line (matching how live output grows upward). Uses absolute
    /// cursor moves only — it never scrolls the region and never touches the saved output cursor.
    private func paintRegion(_ l: Layout, rows: [String]) {
        let outputHeight = l.outputBottom - l.regionTop + 1
        let bottomIndex = rows.count - 1 - scrollOffset       // physical row shown on the region's bottom line
        var out = ""
        for k in 0..<outputHeight {
            let screenRow = l.outputBottom - k
            let rowIndex = bottomIndex - k
            out += "\u{1B}[\(screenRow);1H\u{1B}[2K\u{1B}[0m" // position, clear, reset any inherited SGR
            if rowIndex >= 0 && rowIndex < rows.count { out += rows[rowIndex] }
            out += "\u{1B}[0m"
        }
        writeToStandardOut(data: Data(out.utf8))
    }

    /// Replace the scroll-frame's bottom divider with a dim, centred marker while scrolled back, so
    /// it's unmistakable the view is parked above the live tail. `drawFurniture` repaints a plain
    /// divider here the moment we return to live.
    private func paintScrollIndicator(_ l: Layout) {
        let n = scrollOffset
        let label = " scrolled back \(n) line\(n == 1 ? "" : "s") — wheel down to resume "
        let clipped = String(label.prefix(l.width))
        let pad = max(0, l.width - clipped.count)
        let left = pad / 2
        let rule = String(repeating: "─", count: left) + clipped + String(repeating: "─", count: pad - left)
        writeToStandardOut(data: Data("\u{1B}[\(l.scrollDividerRow);1H\u{1B}[2K\u{1B}[90m\(rule)\u{1B}[0m".utf8))
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
