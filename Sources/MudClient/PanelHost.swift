//
//  PanelHost.swift
//  MudClient
//
//  Holds the declarative model for the status panel and renders it to plain (ANSI-styled) strings.
//  It owns NO terminal state — no scroll region, no cursor, no I/O. TerminalService is the single
//  owner of the screen; it asks this host for `height` and `rows(width:)` and paints them into the
//  frozen furniture band above the input line.
//
//  The model is a list of rows handed over by `panel.render(spec)` (see LuaScriptEngine). A row is
//  either a single styled line or a set of columns; each column carries optional layout (`width`,
//  `flex`, `align`) and a list of styled spans. All widget/layout intent lives in the Lua HUD script;
//  this file only knows how to turn the spec into styled, width-clipped strings.
//
//  Threading: `render`/`setPinnedHeight` (engine thread) and `height`/`rows` (the screen owner) all
//  take `lock`, so the model can't change mid-render.
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

    enum Align { case left, right, center }

    /// One cell in a columned row: its styled content plus how it should be sized and aligned.
    /// `width` pins an exact column width; otherwise the column shares the leftover space by `flex`.
    struct Column {
        var spans: [Span]
        var width: Int?
        var flex: Double
        var align: Align
    }

    /// A panel row: either a single full-width line or a set of columns laid out left-to-right.
    enum Row {
        case line([Span])
        case columns([Column])
    }

    enum Color { case indexed(Int); case rgb(Int, Int, Int) }

    private let lock = NSLock()
    private var parsedRows: [Row] = []
    private var pinnedHeight: Int?

    /// The number of terminal rows the panel occupies: the pinned height if set, else the row count of
    /// the last render (0 when nothing has been rendered — so an unloaded HUD reserves no space).
    var height: Int {
        lock.lock(); defer { lock.unlock() }
        return pinnedHeight ?? parsedRows.count
    }

    // MARK: - Script-facing API

    /// Replace the panel model from a `panel.render(spec)` call. `spec` is a table whose array part is
    /// the rows. Pure state update — the screen owner repaints on its own cadence.
    func render(_ value: LuaValue) {
        guard case .table(let rowArray, _) = value else { return }
        let parsed = rowArray.map(Self.parseRow)
        lock.lock()
        parsedRows = parsed
        lock.unlock()
    }

    /// Pin the panel to a fixed height (`panel.height(n)`); `n <= 0` unpins (height follows the row
    /// count of each render). Pinning keeps the layout stable when a widget's row count varies.
    func setPinnedHeight(_ n: Int) {
        lock.lock()
        pinnedHeight = n > 0 ? n : nil
        lock.unlock()
    }

    // MARK: - Rendering (called by the screen owner)

    /// Render the panel to exactly `height` lines, each an ANSI string clipped/padded to `width`.
    /// Rows beyond the model (when a height is pinned larger than the content) come back empty.
    func rows(width: Int) -> [String] {
        lock.lock(); let rs = parsedRows; let h = pinnedHeight ?? rs.count; lock.unlock()
        guard h > 0 else { return [] }
        return (0..<h).map { i in i < rs.count ? renderRow(rs[i], width: width) : "" }
    }

    private func renderRow(_ row: Row, width: Int) -> String {
        switch row {
        case .line(let spans):
            return renderLine(spans, width: width, align: .left, pad: false)
        case .columns(let cols):
            return renderColumns(cols, width: width)
        }
    }

    /// Lay columns out left-to-right: fixed-`width` columns take their size first, and the rest share
    /// the leftover space in proportion to `flex`. The last flexible column absorbs any rounding
    /// remainder so the row always fills exactly `width`.
    private func renderColumns(_ cols: [Column], width: Int) -> String {
        let fixed = cols.reduce(0) { $0 + ($1.width ?? 0) }
        let flexTotal = cols.reduce(0.0) { $0 + ($1.width == nil ? $1.flex : 0) }
        let remaining = max(0, width - fixed)
        let lastFlexIndex = cols.lastIndex { $0.width == nil }

        var widths = [Int](repeating: 0, count: cols.count)
        var flexAssigned = 0
        for (i, c) in cols.enumerated() {
            if let w = c.width {
                widths[i] = w
            } else if flexTotal > 0 {
                if i == lastFlexIndex {
                    widths[i] = remaining - flexAssigned    // last flexible column takes the remainder
                } else {
                    let w = Int(Double(remaining) * c.flex / flexTotal)
                    widths[i] = w
                    flexAssigned += w
                }
            }
        }

        var out = ""
        for (i, c) in cols.enumerated() {
            out += renderLine(c.spans, width: max(0, widths[i]), align: c.align, pad: true)
        }
        return out
    }

    /// Render one line of spans, clipping to `width` VISIBLE characters (escape codes never count) and
    /// optionally padding with spaces per `align` so columns stay aligned.
    private func renderLine(_ spans: [Span], width: Int, align: Align, pad: Bool) -> String {
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
        guard pad, used < width else { return out }
        let padCount = width - used
        switch align {
        case .left:
            return out + String(repeating: " ", count: padCount)
        case .right:
            return String(repeating: " ", count: padCount) + out
        case .center:
            let left = padCount / 2
            return String(repeating: " ", count: left) + out + String(repeating: " ", count: padCount - left)
        }
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

    // MARK: - Spec parsing (LuaValue -> model)

    private static func parseRow(_ value: LuaValue) -> Row {
        if case .table(_, let dict) = value, case .table(let colArray, _)? = dict["cols"] {
            return .columns(colArray.map(parseColumn))
        }
        return .line(parseCell(value))
    }

    private static func parseColumn(_ value: LuaValue) -> Column {
        switch value {
        case .string(let s):
            return Column(spans: [Span(text: s)], width: nil, flex: 1, align: .left)
        case .table(_, let dict):
            let spans: [Span]
            if case .table(let spanArray, _)? = dict["spans"] {
                spans = spanArray.compactMap(parseSpanElement)
            } else {
                spans = [parseSpan(dict)]
            }
            return Column(spans: spans,
                          width: int(dict["width"]),
                          flex: double(dict["flex"]) ?? 1,
                          align: alignment(dict["align"]))
        default:
            return Column(spans: [], width: nil, flex: 1, align: .left)
        }
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

    /// THE named-color table for the whole host: panel/minimap span colors AND `echo(text, color)`
    /// (LuaScriptEngine.sgrCodes) resolve names here, so the palette can never drift between the two.
    /// Indexes are the standard 16-color slots (0-7 normal, 8-15 bright).
    static let palette: [String: Int] = [
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

    private static func alignment(_ value: LuaValue?) -> Align {
        guard case .string(let s)? = value else { return .left }
        switch s.lowercased() {
        case "right": return .right
        case "center", "centre": return .center
        default: return .left
        }
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

    private static func double(_ value: LuaValue?) -> Double? {
        switch value {
        case .number(let d)?: return d
        case .int(let i)?: return Double(i)
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
    /// The bottom status panel (vitals, room, spells) docked above the input line.
    static let panelHost = Factory(scope: .cached) { PanelHost() }
    /// The top panel (e.g. the group roster), frozen at the top of the screen.
    static let topPanelHost = Factory(scope: .cached) { PanelHost() }
}
