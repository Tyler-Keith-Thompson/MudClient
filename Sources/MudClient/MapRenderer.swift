//
//  MapRenderer.swift
//  Renders the room-graph minimap to a PNG for the graphical (inline-image) minimap. This is the pure,
//  game-agnostic RENDERER: it takes a draw-spec (rooms placed on an integer grid, their exit directions,
//  which one is current, an optional per-room colour) and paints a crisp map. The game-specific logic —
//  projecting `AIPilot`'s world-coord room graph onto the visible grid window — lives in Lua and reaches
//  here via the `map_image` builtin. Kept isolated + pure so it's unit-tested without a terminal.
//

import CoreGraphics
import Foundation
import ImageIO

enum MapRenderer {
    /// One room to draw, on an integer grid. `exits` are cardinal/intercardinal directions that have a
    /// graph edge (drawn as a line stub toward the neighbour cell). `current` gets a highlight ring.
    struct Room {
        var gx: Int
        var gy: Int                       // grid y grows NORTH (flipped to screen space at paint time)
        var exits: Set<String>            // "n","s","e","w","ne","nw","se","sw"
        var current: Bool
        var rgb: (Double, Double, Double)? // optional per-room colour; nil → the default room colour
    }

    /// A few named colours → RGB, for per-room tinting (terrain/area/flags). Unknown → nil (default colour).
    static func namedRGB(_ name: String) -> (Double, Double, Double)? {
        switch name.lowercased() {
        case "red":          return (0.90, 0.30, 0.30)
        case "green":        return (0.35, 0.80, 0.40)
        case "blue":         return (0.40, 0.55, 0.95)
        case "yellow":       return (0.95, 0.85, 0.35)
        case "cyan":         return (0.35, 0.85, 0.90)
        case "magenta":      return (0.85, 0.45, 0.85)
        case "white":        return (0.92, 0.92, 0.92)
        case "gray", "grey": return (0.55, 0.58, 0.60)
        case "orange":       return (0.95, 0.60, 0.25)
        default:             return nil
        }
    }

    private static let dirDelta: [String: (Int, Int)] = [
        "n": (0, 1), "s": (0, -1), "e": (1, 0), "w": (-1, 0),
        "ne": (1, 1), "nw": (-1, 1), "se": (1, -1), "sw": (-1, -1),
    ]

    /// Render `rooms` to PNG data. `cell` = pixels per grid cell (render resolution — the terminal scales
    /// the result to the panel's cell area). Returns nil if there are no rooms or the context can't be made.
    static func renderPNG(rooms: [Room], cell: Int = 22, halfX: Int = 0, halfY: Int = 0) -> Data? {
        guard !rooms.isEmpty, cell > 0 else { return nil }
        // FIXED WINDOW (halfX,halfY > 0): the canvas is always a constant grid window centred on the current
        // room (which the caller places at 0,0), so per-room scale never changes no matter how many rooms
        // exist — fixes the "one room zooms way in / a sprawl zooms way out" wobble. Rooms outside the window
        // are clipped. halfX/halfY == 0 → auto-fit to the actual extent (used by tests).
        let fixed = halfX > 0 && halfY > 0
        let minX = fixed ? -halfX : rooms.map(\.gx).min()!, maxX = fixed ? halfX : rooms.map(\.gx).max()!
        let minY = fixed ? -halfY : rooms.map(\.gy).min()!, maxY = fixed ? halfY : rooms.map(\.gy).max()!
        func inWindow(_ r: Room) -> Bool { !fixed || (r.gx >= minX && r.gx <= maxX && r.gy >= minY && r.gy <= maxY) }
        let cols = maxX - minX + 1, rowsN = maxY - minY + 1
        let width = cols * cell, height = rowsN * cell
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        // Grid → pixel centre. CG's origin is bottom-left and grid gy grows NORTH, which is also up in CG —
        // so a HIGHER gy must map to a HIGHER cy (no flip). (Flipping it put north at the bottom.)
        let c = CGFloat(cell)
        func centre(_ gx: Int, _ gy: Int) -> CGPoint {
            CGPoint(x: CGFloat(gx - minX) * c + c / 2, y: CGFloat(gy - minY) * c + c / 2)
        }

        // Transparent background (the panel/terminal shows through).
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))

        // Edges first, behind the rooms.
        ctx.setLineWidth(max(1, c / 11))
        ctx.setStrokeColor(red: 0.42, green: 0.5, blue: 0.5, alpha: 1)
        for r in rooms where inWindow(r) {
            let from = centre(r.gx, r.gy)
            for d in r.exits {
                guard let (dx, dy) = dirDelta[d] else { continue }
                ctx.move(to: from)
                ctx.addLine(to: centre(r.gx + dx, r.gy + dy))
            }
        }
        ctx.strokePath()

        // Rooms as rounded squares; the current room gets a bright ring.
        let box = c * 0.52
        for r in rooms where inWindow(r) {
            let p = centre(r.gx, r.gy)
            let rect = CGRect(x: p.x - box / 2, y: p.y - box / 2, width: box, height: box)
            let (rr, gg, bb) = r.rgb ?? (0.60, 0.72, 0.85)
            ctx.setFillColor(red: rr, green: gg, blue: bb, alpha: 1)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: box / 5, cornerHeight: box / 5, transform: nil))
            ctx.fillPath()
            if r.current {
                let ring = rect.insetBy(dx: -c / 10, dy: -c / 10)
                ctx.setStrokeColor(red: 1.0, green: 0.86, blue: 0.2, alpha: 1)
                ctx.setLineWidth(max(1.5, c / 8))
                ctx.addPath(CGPath(roundedRect: ring, cornerWidth: box / 4, cornerHeight: box / 4, transform: nil))
                ctx.strokePath()
            }
        }

        guard let image = ctx.makeImage() else { return nil }
        return pngData(image)
    }

    private static func pngData(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
