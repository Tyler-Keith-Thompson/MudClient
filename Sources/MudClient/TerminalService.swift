//
//  TerminalService.swift
//  MudClient
//
//  Created by Tyler Thompson on 8/16/24.
//

import Foundation
import DependencyInjection
import Parsing
#if canImport(AppKit)
import AppKit
#endif

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
        // Peel off any SGR mouse reports (wheel events) and terminal REPLIES (cursor-position / device-
        // attribute reports) BEFORE line editing — they must never reach the line editor or the MUD.
        // What remains is real keyboard input.
        let keyInput = stripTerminalReports(consumeMouseEvents(in: input))
        guard !keyInput.isEmpty else { return }
        partialInput.append(keyInput)

        // Consume any leading key the script has a macro for (TinTin++ #macro). A recognised-but-
        // unbound special key (e.g. an arrow) leaves the loop and falls through to the line editor,
        // so unbound keys behave exactly as before.
        while let (name, length) = decodeKey(partialInput), engine.handleKey(name) {
            partialInput.removeFirst(length)
        }
        guard !partialInput.isEmpty else { return }

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
            print(sanitizedMessage(String(describing: error)))
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
        // Let scripts react to the new geometry after the layout has settled.
        engine.notifyResize(cols: getTerminalWidth() ?? 80, rows: getTerminalHeight() ?? 24)
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

    /// The terminal width in columns, falling back to 80 when the size can't be read (e.g. no tty).
    /// Exposed to Lua as `__term_cols` so the help renderer can pack output to the real width.
    func terminalColumns() -> Int { getTerminalWidth() ?? 80 }
    
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
        snapToLive()   // if you were reading history, sending a command jumps you back to the live tail
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
            print(sanitizedMessage(String(describing: error)))
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
    /// blank row so vertical spacing is preserved. This low-level splitter does NOT carry colour across
    /// rows — `selfContainedPhysicalRows` layers that on top so the scrolled-back repaint stays coloured.
    static func wrapVisible(_ line: String, width: Int) -> [String] {
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

    /// The SGR escape sequence "active" after processing `text` — the accumulation of colour/attribute
    /// SGR sequences (`ESC[…m`) not yet cancelled by a reset. A reset (`ESC[0m` or the empty `ESC[m`)
    /// clears the set; any other SGR sequence is appended verbatim. Non-SGR escapes are ignored. This
    /// is the carry a scrollback line inherits from everything printed before it — the pure core of the
    /// "colour survives into the next stored/wrapped line" fix, unit-tested directly.
    static func activeSGRState(_ text: String) -> String {
        let chars = Array(text)
        var active: [String] = []
        var i = 0
        while i < chars.count {
            if chars[i] == "\u{1B}", i + 1 < chars.count, chars[i + 1] == "[" {
                var j = i + 2                                  // scan CSI parameter/intermediate bytes
                while j < chars.count, let a = chars[j].asciiValue, (0x20...0x3F).contains(a) { j += 1 }
                guard j < chars.count else { break }           // incomplete sequence at the tail
                let final = chars[j]
                if final == "m" {                              // an SGR sequence
                    let params = String(chars[(i + 2)..<j])
                    if params.isEmpty || params == "0" {
                        active.removeAll()                     // reset clears the carried state
                    } else {
                        active.append(String(chars[i...j]))
                    }
                }
                i = j + 1
            } else {
                i += 1
            }
        }
        return active.joined()
    }

    /// Wrap a sequence of logical lines into physical rows, each made SELF-CONTAINED by prefixing the
    /// SGR state active at that row's start (carried from earlier lines and earlier rows of the same
    /// logical line). This is the fix for the scrolled-back "only the first line keeps its colour" bug:
    /// stored logical lines and wrap continuations otherwise inherit no SGR, so a colour set earlier
    /// renders as default when the row is repainted in isolation (the repaint resets SGR per row).
    static func selfContainedPhysicalRows(_ lines: [String], width: Int) -> [String] {
        var rows: [String] = []
        var carry = ""                                        // SGR active entering the current logical line
        for line in lines {
            let base = wrapVisible(line, width: width)
            var consumed = ""                                 // text seen so far within this line
            for row in base {
                let prefix = activeSGRState(carry + consumed) // SGR active at this row's start
                rows.append(prefix.isEmpty ? row : prefix + row)
                consumed += row
            }
            carry = activeSGRState(carry + consumed)          // state leaving this line → next line's carry
        }
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
        // Each row carries the SGR state active at its start (see selfContainedPhysicalRows), so the
        // scrolled-back repaint keeps colour on continuation rows and on lines after the first — the
        // repaint resets SGR per row, which otherwise dropped every colour set on an earlier line/row.
        return Self.selfContainedPhysicalRows(scrollbackLines + [pendingLine], width: width)
    }

    /// Drop terminal REPLIES from keyboard input: cursor-position reports (`ESC[<n>;<n>R`) and device-
    /// attribute reports (`ESC[?…c` / `ESC[…c`). These arrive on stdin when something writes a query
    /// sequence — e.g. a raw ESC byte embedded in an error/log line makes the terminal answer — and if
    /// not filtered they get inserted into the input line (the "cursor jumps to the far right and my
    /// typing is swallowed" bug). Arrow keys (`ESC[A`–`D`), Home/End, etc. end in other bytes and pass
    /// through; a sequence split across reads (no final byte yet) is left intact for the line parser.
    private func stripTerminalReports(_ input: String) -> String {
        guard input.contains("\u{1B}") else { return input }
        let chars = Array(input)
        var out = ""
        var i = 0
        while i < chars.count {
            if chars[i] == "\u{1B}", i + 1 < chars.count, chars[i + 1] == "[" {
                var j = i + 2                                   // scan CSI parameter/intermediate bytes
                while j < chars.count, let a = chars[j].asciiValue, (0x20...0x3F).contains(a) { j += 1 }
                if j < chars.count, chars[j] == "R" || chars[j] == "c" {
                    i = j + 1                                   // a terminal reply — drop the whole thing
                    continue
                }
            }
            out.append(chars[i]); i += 1
        }
        return out
    }

    /// Strip ESC sequences and other C0 control bytes (keeping newlines/tabs) from a diagnostic message
    /// before printing it, so an error string that quotes raw MUD/ANSI data can't inject cursor moves or
    /// provoke a terminal reply that then corrupts the input line. Normal server output is unaffected.
    private func sanitizedMessage(_ s: String) -> String {
        let chars = Array(s)
        var out = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\u{1B}" {
                var j = i + 1
                if j < chars.count, chars[j] == "[" {
                    j += 1
                    while j < chars.count, let a = chars[j].asciiValue, (0x20...0x3F).contains(a) { j += 1 }
                    if j < chars.count { j += 1 }              // consume the final byte
                } else if j < chars.count {
                    j += 1                                     // simple two-byte escape
                }
                i = j
            } else if let a = c.asciiValue, a < 0x20, c != "\n", c != "\t" {
                i += 1                                         // drop stray control bytes
            } else {
                out.append(c); i += 1
            }
        }
        return out
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

    /// Act on one SGR mouse report. The wheel keeps its existing behaviour (drives in-app scrollback,
    /// never routed through Lua); modifier bits (shift/meta/ctrl) are masked off so a modified wheel
    /// still scrolls. Clicks/drags are offered to the script's optional `on_mouse(event, x, y, button)`
    /// — if it returns true the event is consumed, otherwise we fall through to today's behaviour
    /// (which is to swallow it).
    private func handleMouse(_ body: String, press: Bool) {
        let fields = body.split(separator: ";").map { Int($0) ?? 0 }
        guard fields.count >= 3 else { return }
        let stripped = fields[0] & ~0b0001_1100               // strip shift(4)/meta(8)/ctrl(16) bits
        let x = fields[1], y = fields[2]
        switch stripped {
        case 64:
            if press { adjustScroll(by: wheelStep) }          // wheel up → older history
        case 65:
            if press { adjustScroll(by: -wheelStep) }         // wheel down → toward the live tail
        default:
            // A button click/drag/release. Low two bits: 0=left, 1=middle, 2=right (3 = no-button/move).
            let button = stripped & 0b11
            _ = engine.notifyMouse(event: press ? "press" : "release", x: x, y: y, button: button)
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

    /// Jump straight back to the live tail — used when you ACT (send a command) while scrolled back,
    /// so your command and its reply land at the bottom instead of off-screen. No-op if already live.
    private func snapToLive() {
        guard scrollOffset > 0, let l = layout() else { return }
        scrollOffset = 0
        resumeLive(l, rows: physicalRows(width: l.width))
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
    
    /// When the last Ctrl+C on an empty line was pressed, so a second one in quick succession confirms
    /// the quit. Cleared whenever there's input to discard (that Ctrl+C is a "clear", not a "quit").
    private var lastEmptySigInt: Date?

    func handleSigInt() {
        // Ctrl+C with something typed just clears the input — never quits.
        if !lineBuffer.isEmpty || !partialInput.isEmpty {
            cursor.moveToStartOfLine()
            lineBuffer = ""
            partialInput = ""
            visibleStartColumn = 0
            lastEmptySigInt = nil
            refreshDisplay(cursorColumn: cursor.column)   // clear + redraw the (now empty) input line
            return
        }
        // Empty line: require TWO Ctrl+C in rapid succession to actually exit (a single one is easy to
        // hit by accident). The first arms it and shows a hint; a second within the window quits.
        let now = Date()
        if let last = lastEmptySigInt, now.timeIntervalSince(last) < 1.5 {
            teardownScreen()   // reset the scroll region so the terminal isn't left stuck
            var tattr = termios()
            tcgetattr(STDIN_FILENO, &tattr)
            tattr.c_lflag |= tcflag_t(ECHO | ICANON)
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &tattr)
            Swift.print("\nStopping")
            exit(0)
        }
        lastEmptySigInt = now
        print("(input empty — press Ctrl+C again to exit)")
    }

    // MARK: - Lua terminal/input bridge

    /// The scripting engine, resolved lazily so there's no init-time dependency cycle.
    private var engine: LuaScriptEngine { Container.scriptInterpreter().engine }

    // MARK: Input line access (TinTin++ #cursor)

    /// The current input-buffer text (exposed to Lua as `input_get`).
    func currentInput() -> String { lineBuffer }

    /// Replace the input buffer with `text`, move the cursor to the end, and redraw the input line
    /// (exposed to Lua as `input_set`). Mirrors how history recall (up-arrow) swaps the line in.
    func setInput(_ text: String) {
        partialInput = ""
        lineBuffer = text
        visibleStartColumn = 0
        cursor.moveToEndOf(line: lineBuffer)
        refreshDisplay(cursorColumn: cursor.column)
    }

    // MARK: Scrollback read API (TinTin++ #buffer / #grep)

    /// Strip ANSI/VT control sequences so the scrollback read API returns plain text.
    private static let ansiSequence = try! Regex("\u{1B}\\[[0-9;?]*[ -/]*[@-~]")
    private func stripAnsi(_ s: String) -> String { s.replacing(Self.ansiSequence, with: "") }

    /// Every logical output line seen so far (including the live tail), ANSI-stripped, oldest-first.
    private func strippedHistory() -> [String] {
        var lines = scrollbackLines
        if !pendingLine.isEmpty { lines.append(pendingLine) }
        return lines.map { stripAnsi($0) }
    }

    /// The last `count` display lines, ANSI-stripped, oldest-first (exposed as `scrollback`).
    func scrollbackTail(count: Int) -> [String] {
        guard count > 0 else { return [] }
        return Array(strippedHistory().suffix(count))
    }

    /// Up to `max` most-recent lines matching `pattern` (a Swift Regex over the stripped text),
    /// returned oldest-first (exposed as `scrollback_find`).
    func scrollbackFind(pattern: String, max: Int) -> [String] {
        guard max > 0, let rx = try? Regex(pattern) else { return [] }
        var out: [String] = []
        for line in strippedHistory().reversed() {           // walk newest→oldest, cap at `max`
            if (try? rx.firstMatch(in: line)) != nil {
                out.append(line)
                if out.count >= max { break }
            }
        }
        return out.reversed()                                // hand back oldest-first
    }

    // MARK: Output niceties

    /// Ring the terminal bell (exposed to Lua as `bell`), the audible way AND the visible way.
    ///
    /// First `NSSound.beep()` — the macOS system alert sound. This is what actually makes noise in the
    /// common real-world setup: most terminal emulators ship with the *audible* bell turned OFF (only a
    /// visual flash, or nothing), so a bare BEL byte is silent no matter how reliably it's delivered.
    /// The system beep goes through Core Audio and is heard regardless of the emulator's bell setting.
    ///
    /// Then the BEL byte, for terminals that flash/badge/urgent-hint on a bell: it goes straight to the
    /// CONTROLLING TERMINAL with a raw `write(2)` — deliberately not through `writeToStandardOut`/
    /// FileHandle. That path had two ways to lose a bell silently: a FileHandle write error is swallowed
    /// (the `catch` "reports" it via this class's own `print`, i.e. back into the same output
    /// machinery), and when stdout is wrapped/redirected by a launcher the byte never reaches a terminal
    /// at all. `/dev/tty` is the process's terminal regardless of where stdout points, and `write(2)` is
    /// unbuffered, so the BEL is on the wire the moment this returns. Falls back to STDOUT_FILENO if
    /// `/dev/tty` won't open (e.g. no controlling terminal), matching the previous best case.
    func bell() {
        #if canImport(AppKit)
        NSSound.beep()
        #endif
        var bel: UInt8 = 0x07
        let fd = open("/dev/tty", O_WRONLY)
        if fd >= 0 {
            _ = withUnsafePointer(to: &bel) { write(fd, $0, 1) }
            close(fd)
        } else {
            _ = withUnsafePointer(to: &bel) { write(STDOUT_FILENO, $0, 1) }
        }
    }

    // MARK: Key decoding (TinTin++ #macro)

    /// If `s` begins with a recognised special key, return its canonical name and the number of
    /// characters it occupies; otherwise nil. Only FULLY-formed sequences match — a lone/partial
    /// escape returns nil so the existing line-editor path handles it exactly as before.
    private func decodeKey(_ s: String) -> (name: String, length: Int)? {
        let c = Array(s)
        guard let first = c.first else { return nil }
        if first == "\u{1B}" { return decodeEscape(c) }
        // Control letters, excluding those the line editor / enter / backspace / tab already own.
        if let a = first.asciiValue, (0x01...0x1A).contains(a) {
            let reserved: Set<UInt8> = [0x01, 0x05, 0x08, 0x09, 0x0A, 0x0D] // ctrl-a, ctrl-e, BS, tab, LF, CR
            guard !reserved.contains(a) else { return nil }
            return ("ctrl-\(Character(UnicodeScalar(a + 0x60)))", 1)        // 0x01 -> 'a'
        }
        return nil
    }

    /// Decode an escape-introduced key (`c[0] == ESC`): alt-<letter>, or a CSI/SS3 sequence.
    private func decodeEscape(_ c: [Character]) -> (name: String, length: Int)? {
        guard c.count >= 2 else { return nil }                // lone ESC → not yet a complete key
        let second = c[1]
        if second == "[" || second == "O" { return decodeCSI(c) }
        // alt-<letter>: ESC then a plain ASCII letter.
        if let a = second.asciiValue, (0x41...0x5A).contains(a) || (0x61...0x7A).contains(a) {
            return ("alt-\(Character(UnicodeScalar(a)).lowercased())", 2)
        }
        return nil
    }

    /// Decode a CSI (`ESC[…`) or SS3 (`ESC O…`) key sequence into a canonical name. Handles arrows
    /// (with xterm modifiers), Home/End/Insert/Delete/PageUp/PageDown, and F1–F12.
    private func decodeCSI(_ c: [Character]) -> (name: String, length: Int)? {
        var i = 2
        var paramChars = ""
        while i < c.count, let a = c[i].asciiValue, (0x30...0x3F).contains(a) {  // digits, ';', etc.
            paramChars.append(c[i]); i += 1
        }
        guard i < c.count else { return nil }                 // no final byte yet → incomplete
        let final = c[i]
        let length = i + 1
        let params = paramChars.split(separator: ";").map { Int($0) ?? 0 }
        let base: String?
        switch final {
        case "A": base = "up"
        case "B": base = "down"
        case "C": base = "right"
        case "D": base = "left"
        case "H": base = "home"
        case "F": base = "end"
        case "P": base = "f1"
        case "Q": base = "f2"
        case "R": base = "f3"                                  // SS3 R (ESC O R); ESC[…R reports are pre-stripped
        case "S": base = "f4"
        case "~":
            switch params.first ?? 0 {
            case 1, 7: base = "home"
            case 4, 8: base = "end"
            case 2: base = "insert"
            case 3: base = "delete"
            case 5: base = "pageup"
            case 6: base = "pagedown"
            case 11: base = "f1"
            case 12: base = "f2"
            case 13: base = "f3"
            case 14: base = "f4"
            case 15: base = "f5"
            case 17: base = "f6"
            case 18: base = "f7"
            case 19: base = "f8"
            case 20: base = "f9"
            case 21: base = "f10"
            case 23: base = "f11"
            case 24: base = "f12"
            default: base = nil
            }
        default: base = nil
        }
        guard let base else { return nil }
        let modifier = params.count >= 2 ? params[1] : 1      // xterm "1;<mod>" or "<n>;<mod>~"
        return (modifierPrefix(modifier) + base, length)
    }

    /// Turn an xterm modifier code (2…16) into a canonical prefix ("ctrl-", "alt-", "shift-", "meta-"
    /// in that order). 1 (or absent) → no modifiers. Must match LuaScriptEngine.normalizeKeyName.
    private func modifierPrefix(_ m: Int) -> String {
        guard m >= 2 else { return "" }
        let bits = m - 1
        var p = ""
        if bits & 4 != 0 { p += "ctrl-" }
        if bits & 2 != 0 { p += "alt-" }
        if bits & 1 != 0 { p += "shift-" }
        if bits & 8 != 0 { p += "meta-" }
        return p
    }
}

extension Container {
    static let terminalService = Factory(scope: .cached) { TerminalService() }
}
