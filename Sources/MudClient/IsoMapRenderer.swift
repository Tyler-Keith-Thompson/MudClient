//
//  IsoMapRenderer.swift
//  The 2.5-D minimap renderer. Where `MapRenderer` paints a flat top-down grid, this paints the same room
//  graph as ANGLED 3-D BOXES on an axis-aligned grid: NORTH is straight up, EAST straight right (intuitive
//  compass), and each room is a little block — a foreshortened top face carrying its TERRAIN texture plus a
//  shaded front (south) wall for height. A room's z-level lifts its block; floors above/below are drawn as
//  faint translucent ghosts so multi-level structure reads without hiding where you are. (This replaced an
//  isometric-diamond projection whose 45° grid made the compass unintuitive; the type name is kept.)
//
//  Pure + game-agnostic: it takes a draw-spec (rooms on an integer grid + a z-level + a terrain code) and a
//  tile provider, and returns PNG data. The projection from AIPilot's world-coord graph onto this grid lives
//  in Lua (`minimap_grid`), reaching here via the `map_image` builtin. Terrain textures are the
//  ComfyUI-generated tiles under `Assets/terrain/NN_name.png`, loaded + cached by `TerrainTiles`.
//

import CoreGraphics
import Foundation
import ImageIO

enum IsoMapRenderer {
    /// One room to draw. `gx,gy` = BFS grid (gx grows EAST, gy grows NORTH). `z` = level relative to the
    /// current room (0 = same, +1 = one up, -1 = one down). `terrain` = kxwt terrain code (0–39) or nil.
    struct Room {
        var gx: Int
        var gy: Int
        var z: Int
        var exits: Set<String>          // cardinals (unused for placement here) + "u"/"d" for the chevron
        var terrain: Int?
        var current: Bool
        var dim: Bool                   // a room on ANOTHER floor (reached via up/down) → drawn faint
        var rgb: (Double, Double, Double)?   // optional tint override (waypoint/blocked); nil → terrain colour
    }

    // Box geometry. Top face is foreshortened (cellD < cellW) so we read it at an angle; the front wall gives
    // height. Kept small — the terminal upscales the PNG into the panel rectangle.
    private static let cellW = 42.0                   // top-face width
    private static let cellD = 30.0                   // top-face depth (foreshortened → the "tilt")
    private static let wallH = 11.0                   // front-wall height (block thickness)
    private static let gapX  = 11.0, gapY = 10.0      // gaps between blocks (so connectors + fronts show)
    private static let levelH = 20.0                  // vertical pixels per z-level
    private static let zHeadroom = 4                  // z-levels of vertical margin reserved (constant scale)

    /// Render `rooms` to PNG. A FIXED grid window (`halfX,halfY`) centred on the current room (placed at
    /// 0,0) keeps per-room scale constant regardless of how many rooms exist; rooms outside are clipped.
    /// `tiles` supplies terrain textures (nil → flat colour fallback, so it works before tiles are baked).
    static func renderPNG(rooms: [Room], halfX: Int = 7, halfY: Int = 5,
                          scale: Int = 2, tiles: TerrainTiles? = nil) -> Data? {
        guard !rooms.isEmpty, halfX > 0, halfY > 0, scale > 0 else { return nil }
        let s = CGFloat(scale)
        let cw = cellW * s, cd = cellD * s, wh = wallH * s, lvl = levelH * s
        let stepX = (cellW + gapX) * s
        let stepY = (cellD + wallH + gapY) * s        // N-S spacing: clears each block's front wall + a gap
        let zPad = lvl * CGFloat(zHeadroom)

        func inWindow(_ r: Room) -> Bool { r.gx >= -halfX && r.gx <= halfX && r.gy >= -halfY && r.gy <= halfY }

        // Constant canvas from the window extent + fixed z headroom (both directions) + wall/margin.
        let margin = 6 * s
        let spanX = CGFloat(halfX) * stepX, spanY = CGFloat(halfY) * stepY
        let originX = spanX + cw / 2 + margin
        let originY = spanY + wh + zPad + margin
        let width  = Int(2 * spanX + cw + 2 * margin)
        let height = Int(2 * spanY + cd + wh + 2 * zPad + 2 * margin)
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high

        // Top-face centre (CG y-up: north = +gy → up, east = +gx → right, higher z → up).
        func centre(_ r: Room) -> CGPoint {
            CGPoint(x: originX + CGFloat(r.gx) * stepX, y: originY + CGFloat(r.gy) * stepY + CGFloat(r.z) * lvl)
        }
        // Top-face rect (foreshortened): south/front edge at cy-cd/2, north/back edge at cy+cd/2.
        func topRect(_ c: CGPoint) -> CGRect { CGRect(x: c.x - cw / 2, y: c.y - cd / 2, width: cw, height: cd) }

        let placed = rooms.filter(inWindow)
        func backToFront(_ list: [Room]) -> [Room] {
            list.sorted { $0.gy != $1.gy ? $0.gy > $1.gy : $0.z < $1.z }   // north (far) first, lower z first
        }

        // Draw one block: front (south) wall + terrain top face + outline + up/down chevrons, at `alpha`.
        func drawRoom(_ r: Room, _ alpha: CGFloat) {
            ctx.setAlpha(alpha)
            let c = centre(r)
            let rect = topRect(c)
            let (fr, fg, fb) = r.rgb ?? terrainRGB(r.terrain)

            // front (south) wall: hangs below the front edge, shaded darker for depth
            let wall = CGMutablePath()
            wall.move(to: CGPoint(x: rect.minX, y: rect.minY))
            wall.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            wall.addLine(to: CGPoint(x: rect.maxX, y: rect.minY - wh))
            wall.addLine(to: CGPoint(x: rect.minX, y: rect.minY - wh))
            wall.closeSubpath()
            ctx.addPath(wall); ctx.setFillColor(red: fr * 0.5, green: fg * 0.5, blue: fb * 0.5, alpha: 1); ctx.fillPath()
            ctx.addPath(wall); ctx.setStrokeColor(red: 0.08, green: 0.09, blue: 0.10, alpha: 0.8)
            ctx.setLineWidth(max(1, 1 * s)); ctx.strokePath()

            // top face: terrain texture (or flat colour), clipped to the rect
            if let img = tiles?.image(r.terrain) {
                ctx.saveGState(); ctx.addPath(CGPath(rect: rect, transform: nil)); ctx.clip()
                ctx.draw(img, in: rect); ctx.restoreGState()
            } else {
                ctx.addPath(CGPath(rect: rect, transform: nil)); ctx.setFillColor(red: fr, green: fg, blue: fb, alpha: 1); ctx.fillPath()
            }
            ctx.addPath(CGPath(rect: rect, transform: nil)); ctx.setStrokeColor(red: 0.10, green: 0.12, blue: 0.13, alpha: 0.85)
            ctx.setLineWidth(max(1, 1.2 * s)); ctx.strokePath()

            if r.exits.contains("u") { chevron(ctx, at: CGPoint(x: c.x, y: rect.maxY + 4 * s), up: true, s: s, bright: true) }
            if r.exits.contains("d") { chevron(ctx, at: CGPoint(x: c.x, y: rect.minY - wh - 1 * s), up: false, s: s, bright: false) }

            if r.current {
                // dark halo + gold ring so YOU are unmistakable, even under a translucent floor-above ghost.
                ctx.addPath(CGPath(rect: rect, transform: nil)); ctx.setStrokeColor(red: 0.05, green: 0.06, blue: 0.07, alpha: 1)
                ctx.setLineWidth(max(3, 5 * s)); ctx.strokePath()
                ctx.addPath(CGPath(rect: rect, transform: nil)); ctx.setStrokeColor(red: 1.0, green: 0.86, blue: 0.2, alpha: 1)
                ctx.setLineWidth(max(1.5, 2.4 * s)); ctx.strokePath()
            }
        }

        // Clarity-ordered passes: floors below (faint, behind) → this floor → YOU (opaque, on top) →
        // connectors → floor above (faint translucent ghost so overhead shows without washing out your room).
        for r in backToFront(placed.filter { $0.dim && $0.z <= 0 }) { drawRoom(r, 0.30) }
        for r in backToFront(placed.filter { !$0.dim && !$0.current }) { drawRoom(r, 1.0) }
        for r in placed where r.current { drawRoom(r, 1.0) }

        // Connector bars ON TOP so every exit reads as a link. Axis-aligned grid: n=(0,1), e=(1,0), …
        let byCell = Dictionary(placed.filter { !$0.dim }.map { ("\($0.gx),\($0.gy)", $0) }) { a, _ in a }
        let delta: [String: (Int, Int)] = ["n": (0, 1), "s": (0, -1), "e": (1, 0), "w": (-1, 0),
                                           "ne": (1, 1), "nw": (-1, 1), "se": (1, -1), "sw": (-1, -1)]
        ctx.setAlpha(1.0); ctx.setLineCap(.round)
        for r in placed where !r.dim {
            let from = centre(r)
            for d in r.exits {
                guard let (dx, dy) = delta[d], let nb = byCell["\(r.gx + dx),\(r.gy + dy)"] else { continue }
                let to = centre(nb)
                let mx = (from.x + to.x) / 2, my = (from.y + to.y) / 2
                let vx = to.x - from.x, vy = to.y - from.y
                let len = max(1, (vx * vx + vy * vy).squareRoot())
                let ux = vx / len, uy = vy / len
                let half = max(3 * s, len / 2 - 0.55 * cd)      // sit in the gap between the two blocks
                ctx.setStrokeColor(red: 0.13, green: 0.14, blue: 0.15, alpha: 0.9); ctx.setLineWidth(max(2.5, 4 * s))
                ctx.move(to: CGPoint(x: mx - ux * half, y: my - uy * half)); ctx.addLine(to: CGPoint(x: mx + ux * half, y: my + uy * half)); ctx.strokePath()
                ctx.setStrokeColor(red: 0.95, green: 0.88, blue: 0.55, alpha: 1); ctx.setLineWidth(max(1.5, 2 * s))
                ctx.move(to: CGPoint(x: mx - ux * half, y: my - uy * half)); ctx.addLine(to: CGPoint(x: mx + ux * half, y: my + uy * half)); ctx.strokePath()
            }
        }

        // Floor(s) above last, faint translucent ghost — your (opaque) room stays clear through it.
        for r in backToFront(placed.filter { $0.dim && $0.z > 0 }) { drawRoom(r, 0.26) }
        ctx.setAlpha(1.0)

        guard let image = ctx.makeImage() else { return nil }
        return pngData(image)
    }

    private static func chevron(_ ctx: CGContext, at p: CGPoint, up: Bool, s: CGFloat, bright: Bool) {
        let w = 5 * s, h = 5 * s, dy: CGFloat = up ? h : -h
        let path = CGMutablePath()
        path.move(to: CGPoint(x: p.x - w, y: p.y)); path.addLine(to: CGPoint(x: p.x, y: p.y + dy))
        path.addLine(to: CGPoint(x: p.x + w, y: p.y))
        ctx.addPath(path)
        if bright { ctx.setStrokeColor(red: 0.55, green: 1.0, blue: 0.6, alpha: 1) }
        else { ctx.setStrokeColor(red: 0.95, green: 0.65, blue: 0.35, alpha: 1) }
        ctx.setLineWidth(max(1.5, 2 * s)); ctx.setLineJoin(.round); ctx.strokePath()
    }

    /// Flat fallback colour per terrain code (used until the ComfyUI tiles are baked, or if one is missing).
    static func terrainRGB(_ code: Int?) -> (Double, Double, Double) {
        switch code ?? -1 {
        case 3, 15:            return (0.45, 0.72, 0.35)   // field / hill — grass
        case 4, 5, 17, 34:     return (0.20, 0.52, 0.28)   // forests / jungle / taiga
        case 6, 36:            return (0.16, 0.20, 0.24)   // dark/shadow
        case 7, 29, 38:        return (0.40, 0.46, 0.28)   // swamp / marsh / mire
        case 2, 28:            return (0.62, 0.60, 0.55)   // town / city — cobbles
        case 1:                return (0.78, 0.66, 0.48)   // building — light wood interior
        case 33:               return (0.60, 0.62, 0.66)   // metal — steel plate
        case 8, 10, 11:        return (0.55, 0.52, 0.50)   // plateau / mountain / rock
        case 9, 12, 16:        return (0.85, 0.75, 0.45)   // sandy / desert / dunes
        case 13, 24:           return (0.80, 0.86, 0.92)   // tundra / ice
        case 14:               return (0.82, 0.78, 0.55)   // beach
        case 18, 19, 20, 32:   return (0.30, 0.52, 0.82)   // ocean / stream / river / water
        case 21:               return (0.25, 0.55, 0.60)   // underwater
        case 22, 27, 37:       return (0.42, 0.36, 0.32)   // underground / cave / catacomb
        case 23, 31:           return (0.78, 0.85, 0.92)   // air / cloud
        case 25:               return (0.85, 0.35, 0.15)   // lava
        case 26, 30:           return (0.55, 0.50, 0.45)   // ruins / wasteland
        case 35:               return (0.38, 0.44, 0.34)   // sewer
        case 39:               return (0.60, 0.45, 0.85)   // crystal
        default:               return (0.60, 0.64, 0.70)   // notset / unknown
        }
    }

    private static func pngData(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
