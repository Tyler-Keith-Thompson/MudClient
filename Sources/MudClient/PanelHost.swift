//
//  PanelHost.swift
//  MudClient
//
//  A generic, frozen panel pinned to the TOP of the terminal, with normal output scrolling
//  underneath it. The mechanism is the DECSTBM scroll region (`ESC[{top};{bottom}r`): the top
//  `height` rows are excluded from the scrolling region, so ordinary output (and the bottom-split
//  input line in TerminalService) only ever moves within the rows below the panel. The panel itself
//  is painted with absolute cursor moves, bracketed by cursor save/restore so the input line is
//  never disturbed.
//
//  This host is deliberately game-agnostic. It renders a declarative model — an ordered list of
//  rows, each a single styled line or a set of columns, each cell a list of styled spans — that
//  scripts hand over via `panel.render` (see LuaScriptEngine). All widget/layout knowledge lives in
//  Lua (Scripts/HUD.lua); this file only knows how to turn spans into ANSI and stack them.
//
//  Threading: `render`/`setPinnedHeight` (engine thread) and `flush`/`teardown` (engine thread and
//  the SIGWINCH handler on main) all take `lock`; terminal writes happen under it so a repaint and a
//  resize can't interleave escape sequences.
//

import Foundation
import DependencyInjection

final class PanelHost: @unchecked Sendable {
    /// A run of text sharing one style. Colours are named (16-colour palette) or truecolour rgb.
    struct Span {
        var text: String
        var fg: Color?
        var bg: Color?
        var bold = false
        var dim = false
        var reverse = false
        var underline = false
    }

    /// One panel row. `cols.count == 1` is a single full-width line; more than one lays the cells out
    /// left-to-right in equal columns. Each cell is a list of spans rendered on one line.
    struct Row { var cols: [[Span]] }

    enum Color { case indexed(Int); case rgb(Int, Int, Int) }

    private let lock = NSLock()
    private var rows: [Row] = []
    private var desiredHeight = 0
    private var pinnedHeight: Int?
    private var dirty = false
    // The scroll region currently set on the terminal, or -1/-1 if none. Tracked so we only re-emit
    // the DECSTBM sequence when the panel height or terminal height actually changes.
    private var regionTop = -1
    private var regionBottom = -1

    // MARK: - Script-facing API

    /// Replace the panel model from a `panel.render(spec)` call. `spec` is a table whose array part is
    /// the rows. Marks the panel dirty; the actual paint happens in `flush` (coalesced per update).
    func render(_ value: LuaValue) {
        guard case .table(let rowArray, _) = value else { return }
        let parsed = rowArray.map(Self.parseRow)
        lock.lock()
        rows = parsed
        desiredHeight = pinnedHeight ?? parsed.count
        dirty = true
        lock.unlock()
    }

    /// Pin the panel to a fixed height (`panel.height(n)`); `n <= 0` unpins (height follows the row
    /// count of each render). Pinning keeps the scroll region stable when a widget's row count varies.
    func setPinnedHeight(_ n: Int) {
        lock.lock()
        pinnedHeight = n > 0 ? n : nil
        if let ph = pinnedHeight { desiredHeight = ph }
        dirty = true
        lock.unlock()
    }

    // MARK: - Rendering

    /// Repaint the panel if it changed (or `force`, e.g. on resize). No-op until a script has rendered
    /// something (so an unloaded HUD leaves the terminal completely untouched).
    func flush(force: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        guard dirty || force else { return }
        guard desiredHeight > 0, let (h, w) = size() else { return }
        // Leave at least a few rows below the panel for scrolling output + the input/divider lines.
        let p = min(desiredHeight, max(0, h - 3))
        guard p > 0 else { return }

        var out = "\u{1B}7"                                  // save cursor + attributes (real input pos)
        if regionTop != p + 1 || regionBottom != h {
            out += "\u{1B}[\(p + 1);\(h)r"                   // freeze rows 1..p (moves cursor home — we saved)
            regionTop = p + 1
            regionBottom = h
        }
        for i in 0..<p {
            out += "\u{1B}[\(i + 1);1H\u{1B}[2K"            // to panel row i, clear it
            if i < rows.count { out += renderRow(rows[i], width: w) }
        }
        out += "\u{1B}8"                                     // restore cursor to the input line
        write(out)
        dirty = false
    }

    /// Reset the scroll region and drop to the bottom of the screen. Call on exit so a quit/crash
    /// doesn't leave the terminal with a stuck region.
    func teardown() {
        lock.lock(); defer { lock.unlock() }
        guard regionTop > 0 else { return }
        var out = "\u{1B}[r"                                 // reset scroll region to the full screen
        if let (h, _) = size() { out += "\u{1B}[\(h);1H" }
        write(out)
        regionTop = -1
        regionBottom = -1
    }

    // MARK: - Row / span layout

    private func renderRow(_ row: Row, width: Int) -> String {
        let cols = row.cols
        if cols.count <= 1 {
            return renderLine(cols.first ?? [], width: width, pad: false)
        }
        let n = cols.count
        let base = width / n
        var out = ""
        for (i, cell) in cols.enumerated() {
            let cw = (i == n - 1) ? (width - base * (n - 1)) : base   // last column absorbs the remainder
            out += renderLine(cell, width: cw, pad: true)
        }
        return out
    }

    /// Render one line of spans, clipping to `width` VISIBLE characters (escape codes never count) and
    /// optionally padding out with spaces so columns stay aligned.
    private func renderLine(_ spans: [Span], width: Int, pad: Bool) -> String {
        guard width > 0 else { return "" }
        var out = ""
        var used = 0
        for span in spans {
            if used >= width { break }
            let text = String(span.text.prefix(width - used))
            if text.isEmpty { continue }
            used += text.count
            out += sgr(span, text)
        }
        if pad && used < width { out += String(repeating: " ", count: width - used) }
        return out
    }

    private func sgr(_ span: Span, _ text: String) -> String {
        var codes: [String] = []
        if span.bold { codes.append("1") }
        if span.dim { codes.append("2") }
        if span.underline { codes.append("4") }
        if span.reverse { codes.append("7") }
        if let fg = span.fg { codes += Self.colorCodes(fg, background: false) }
        if let bg = span.bg { codes += Self.colorCodes(bg, background: true) }
        if codes.isEmpty { return text }
        return "\u{1B}[" + codes.joined(separator: ";") + "m" + text + "\u{1B}[0m"
    }

    private static func colorCodes(_ color: Color, background: Bool) -> [String] {
        switch color {
        case .indexed(let i):
            let base = background ? 40 : 30
            let bright = background ? 100 : 90
            return [String(i < 8 ? base + i : bright + (i - 8))]
        case .rgb(let r, let g, let b):
            return [background ? "48" : "38", "2", String(r), String(g), String(b)]
        }
    }

    // MARK: - Terminal helpers

    private func size() -> (rows: Int, cols: Int)? {
        var w = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0 else { return nil }
        return (Int(w.ws_row), Int(w.ws_col))
    }

    private func write(_ s: String) {
        try? FileHandle.standardOutput.write(contentsOf: Data(s.utf8))
    }

    // MARK: - Spec parsing (LuaValue -> model)

    private static func parseRow(_ value: LuaValue) -> Row {
        if case .table(_, let dict) = value, case .table(let colArray, _)? = dict["cols"] {
            return Row(cols: colArray.map(parseCell))
        }
        return Row(cols: [parseCell(value)])
    }

    /// A cell is either `{ spans = { ... } }` or, for the common single-span case, a table that is
    /// itself the span (`{ text=..., fg=... }`). A bare string is a plain span.
    private static func parseCell(_ value: LuaValue) -> [Span] {
        switch value {
        case .string(let s):
            return [Span(text: s)]
        case .table(_, let dict):
            if case .table(let spanArray, _)? = dict["spans"] {
                return spanArray.compactMap(parseSpanElement)
            }
            return [parseSpan(dict)]
        default:
            return []
        }
    }

    private static func parseSpanElement(_ value: LuaValue) -> Span? {
        switch value {
        case .string(let s): return Span(text: s)
        case .table(_, let dict): return parseSpan(dict)
        default: return nil
        }
    }

    private static func parseSpan(_ dict: [String: LuaValue]) -> Span {
        Span(text: string(dict["text"]) ?? "",
             fg: color(dict["fg"]),
             bg: color(dict["bg"]),
             bold: truthy(dict["bold"]),
             dim: truthy(dict["dim"]),
             reverse: truthy(dict["reverse"]),
             underline: truthy(dict["underline"]))
    }

    private static let palette: [String: Int] = [
        "black": 0, "red": 1, "green": 2, "yellow": 3, "blue": 4, "magenta": 5, "cyan": 6, "white": 7,
        "brightblack": 8, "gray": 8, "grey": 8, "brightred": 9, "brightgreen": 10, "brightyellow": 11,
        "brightblue": 12, "brightmagenta": 13, "brightcyan": 14, "brightwhite": 15,
    ]

    private static func color(_ value: LuaValue?) -> Color? {
        switch value {
        case .string(let s)?:
            let key = s.lowercased()
            if let idx = palette[key] { return .indexed(idx) }
            if key.hasPrefix("#"), let rgb = hex(key) { return .rgb(rgb.0, rgb.1, rgb.2) }
            return nil
        case .table(let array, let dict)?:
            func comp(_ i: Int, _ k: String) -> Int? {
                if i < array.count, let n = int(array[i]) { return n }
                return int(dict[k])
            }
            if let r = comp(0, "r"), let g = comp(1, "g"), let b = comp(2, "b") { return .rgb(r, g, b) }
            return nil
        default:
            return nil
        }
    }

    private static func hex(_ s: String) -> (Int, Int, Int)? {
        let h = s.dropFirst()
        guard h.count == 6, let v = Int(h, radix: 16) else { return nil }
        return ((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF)
    }

    private static func string(_ value: LuaValue?) -> String? {
        if case .string(let s)? = value { return s }
        return nil
    }

    private static func int(_ value: LuaValue?) -> Int? {
        switch value {
        case .int(let i)?: return Int(i)
        case .number(let d)?: return Int(d)
        default: return nil
        }
    }

    private static func truthy(_ value: LuaValue?) -> Bool {
        switch value {
        case .bool(let b)?: return b
        case .int(let i)?: return i != 0
        case .number(let d)?: return d != 0
        case .nil?, .none: return false
        default: return true
        }
    }
}

extension Container {
    static let panelHost = Factory(scope: .cached) { PanelHost() }
}
