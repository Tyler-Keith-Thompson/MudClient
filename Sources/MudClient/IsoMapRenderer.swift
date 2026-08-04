//
//  IsoMapRenderer.swift
//  The 2.5-D minimap renderer. It paints the room graph through an ISOMETRIC camera (2:1 diamonds): each
//  room is a little cube whose top face carries its TERRAIN texture and whose two visible side walls give
//  real volume. Crucially, north maps to the up-LEFT diagonal while ELEVATION (world coord z) maps straight
//  UP — so a raised room (up) is visually distinct from a northern neighbour (up-left), which is what makes
//  "what's on top vs underneath" unambiguous. A small corner COMPASS marks north so the diagonal grid stays
//  intuitive. Floors above/below (reached via up/down) are drawn as faint translucent ghosts.
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
        var exits: Set<String>          // cardinals (for connector links) + "u"/"d" for the chevron
        var terrain: Int?
        var current: Bool
        var dim: Bool                   // a room on ANOTHER floor (reached via up/down) → drawn faint
        var rgb: (Double, Double, Double)?   // optional tint override (waypoint/blocked); nil → terrain colour
    }

    // Shallow-dimetric geometry. The ground grid is rotated `leanDeg` off screen-axes (0 = flat top-down,
    // 45 = full isometric) and foreshortened by `squish` (the "looking-down" tilt): north goes up-and-a-bit-
    // left, east right-and-a-bit-up. 25° keeps north nearly up while still exposing the SE/SW side walls that
    // make elevation read. Elevation (z) always lifts STRAIGHT up, distinct from the north lean.
    private static let leanDeg = 25.0                 // grid rotation off vertical (25 = gentle, 45 = full iso)
    private static let squish = 0.80                  // vertical foreshorten (1 = none, 0.5 = full 2:1 iso)
    private static let cellMag = 34.0                 // centre-to-centre cell step (before scale)
    private static let tileScale = 0.82               // drawn top face vs cell step → gaps between cubes
    private static let cubeH = 12.0                   // side-wall height (block volume)
    private static let levelH = 17.0                  // vertical LIFT per z-level (elevation → straight up)
    private static let zHeadroom = 2                  // z-levels of vertical margin reserved (constant scale)

    /// Render `rooms` to PNG. A FIXED grid window (`halfX,halfY`) centred on the current room (placed at
    /// 0,0) keeps per-room scale constant regardless of how many rooms exist; rooms outside are clipped.
    /// `tiles` supplies terrain textures (nil → flat colour fallback, so it works before tiles are baked).
    static func renderPNG(rooms: [Room], halfX: Int = 6, halfY: Int = 5,
                          scale: Int = 2, tiles: TerrainTiles? = nil) -> Data? {
        guard !rooms.isEmpty, halfX > 0, halfY > 0, scale > 0 else { return nil }
        let s = CGFloat(scale)
        let ch = cubeH * s, lvl = levelH * s
        // Screen basis: rotate the ground axes by leanDeg, foreshorten y by `squish`, scale to cell size.
        let th = leanDeg * .pi / 180.0, m = cellMag * s
        let ex = CGVector(dx: cos(th) * m, dy: sin(th) * squish * m)     // one EAST step (right, slight up)
        let ny = CGVector(dx: -sin(th) * m, dy: cos(th) * squish * m)    // one NORTH step (up, slight left)
        let hex = CGVector(dx: ex.dx * tileScale / 2, dy: ex.dy * tileScale / 2)   // half drawn top-face edges
        let hny = CGVector(dx: ny.dx * tileScale / 2, dy: ny.dy * tileScale / 2)
        let halfSpanX = abs(hex.dx) + abs(hny.dx), halfSpanY = abs(hex.dy) + abs(hny.dy)
        let zPad = lvl * CGFloat(zHeadroom) + ch

        func inWindow(_ r: Room) -> Bool { r.gx >= -halfX && r.gx <= halfX && r.gy >= -halfY && r.gy <= halfY }

        // Constant canvas from the window corners (z=0) + tile extent + z headroom + cube depth + margin.
        var minSx: CGFloat = 0, maxSx: CGFloat = 0, minSy: CGFloat = 0, maxSy: CGFloat = 0
        for gx in [-halfX, halfX] { for gy in [-halfY, halfY] {
            let sx: CGFloat = CGFloat(gx) * ex.dx + CGFloat(gy) * ny.dx
            let sy: CGFloat = CGFloat(gx) * ex.dy + CGFloat(gy) * ny.dy
            minSx = min(minSx, sx); maxSx = max(maxSx, sx); minSy = min(minSy, sy); maxSy = max(maxSy, sy)
        } }
        let margin: CGFloat = 6 * s
        let originX: CGFloat = -minSx + halfSpanX + margin
        let originY: CGFloat = -minSy + halfSpanY + ch + margin
        let spanW: CGFloat = (maxSx - minSx) + 2 * halfSpanX + 2 * margin
        let spanH: CGFloat = (maxSy - minSy) + 2 * halfSpanY + 2 * zPad + 2 * margin
        let width = Int(spanW), height = Int(spanH)
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high

        // Centre (CG y-up): north = up-and-slightly-left, east = right-and-slightly-up, elevation z = UP.
        func centre(_ r: Room) -> CGPoint {
            CGPoint(x: originX + CGFloat(r.gx) * ex.dx + CGFloat(r.gy) * ny.dx,
                    y: originY + CGFloat(r.gx) * ex.dy + CGFloat(r.gy) * ny.dy + CGFloat(r.z) * lvl)
        }

        let placed = rooms.filter(inWindow)
        func backToFront(_ list: [Room]) -> [Room] {
            list.sorted { ($0.gx + $0.gy) != ($1.gx + $1.gy) ? ($0.gx + $0.gy) > ($1.gx + $1.gy) : $0.z < $1.z }
        }
        func quad(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> CGPath {
            let p = CGMutablePath(); p.move(to: a); p.addLine(to: b); p.addLine(to: c); p.addLine(to: d); p.closeSubpath(); return p
        }

        // Draw one cube: SW + SE side walls (visible fronts), then the terrain top face, at `alpha`.
        func drawRoom(_ r: Room, _ alpha: CGFloat) {
            ctx.setAlpha(alpha)
            let c = centre(r)
            let sw = CGPoint(x: c.x - hex.dx - hny.dx, y: c.y - hex.dy - hny.dy)   // front corner (lowest)
            let se = CGPoint(x: c.x + hex.dx - hny.dx, y: c.y + hex.dy - hny.dy)
            let ne = CGPoint(x: c.x + hex.dx + hny.dx, y: c.y + hex.dy + hny.dy)
            let nw = CGPoint(x: c.x - hex.dx + hny.dx, y: c.y - hex.dy + hny.dy)
            let (fr, fg, fb) = r.rgb ?? terrainRGB(r.terrain)
            let dn = ch
            // south-west wall: SW→NW edge? no — the two viewer-facing lower edges are SW→SE and SW→... use
            // the front edges SW→SE (south) and SW→NW is back-left. Visible walls: south (SW→SE) + east (SE→NE).
            let south = quad(sw, se, CGPoint(x: se.x, y: se.y - dn), CGPoint(x: sw.x, y: sw.y - dn))
            let east  = quad(se, ne, CGPoint(x: ne.x, y: ne.y - dn), CGPoint(x: se.x, y: se.y - dn))
            ctx.addPath(east);  ctx.setFillColor(red: fr * 0.62, green: fg * 0.62, blue: fb * 0.62, alpha: 1); ctx.fillPath()
            ctx.addPath(south); ctx.setFillColor(red: fr * 0.44, green: fg * 0.44, blue: fb * 0.44, alpha: 1); ctx.fillPath()
            ctx.addPath(east); ctx.addPath(south); ctx.setStrokeColor(red: 0.07, green: 0.08, blue: 0.09, alpha: 0.85)
            ctx.setLineWidth(max(1, 1 * s)); ctx.strokePath()

            // top face: terrain texture mapped via affine (unit square → SW,SE,NE,NW parallelogram)
            let top = quad(sw, se, ne, nw)
            if let img = tiles?.image(r.terrain) {
                ctx.saveGState(); ctx.addPath(top); ctx.clip()
                ctx.concatenate(CGAffineTransform(a: se.x - sw.x, b: se.y - sw.y, c: nw.x - sw.x, d: nw.y - sw.y, tx: sw.x, ty: sw.y))
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: 1, height: 1)); ctx.restoreGState()
            } else {
                ctx.addPath(top); ctx.setFillColor(red: fr, green: fg, blue: fb, alpha: 1); ctx.fillPath()
            }
            ctx.addPath(top); ctx.setStrokeColor(red: 0.10, green: 0.12, blue: 0.13, alpha: 0.85)
            ctx.setLineWidth(max(1, 1.2 * s)); ctx.strokePath()

            let topMid = CGPoint(x: (nw.x + ne.x) / 2, y: (nw.y + ne.y) / 2)
            let botMid = CGPoint(x: (sw.x + se.x) / 2, y: (sw.y + se.y) / 2 - dn)
            if r.exits.contains("u") { chevron(ctx, at: CGPoint(x: topMid.x, y: topMid.y + 4 * s), up: true, s: s, bright: true) }
            if r.exits.contains("d") { chevron(ctx, at: CGPoint(x: botMid.x, y: botMid.y - 2 * s), up: false, s: s, bright: false) }

            if r.current {
                ctx.addPath(top); ctx.setStrokeColor(red: 0.05, green: 0.06, blue: 0.07, alpha: 1)
                ctx.setLineWidth(max(3, 5 * s)); ctx.strokePath()
                ctx.addPath(top); ctx.setStrokeColor(red: 1.0, green: 0.86, blue: 0.2, alpha: 1)
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
        ctx.setAlpha(1.0); ctx.setLineCap(CGLineCap.round)
        for r in placed where !r.dim {
            let from = centre(r)
            for d in r.exits {
                guard let (dx, dy) = delta[d], let nb = byCell["\(r.gx + dx),\(r.gy + dy)"] else { continue }
                let to = centre(nb)
                let mx = (from.x + to.x) / 2, my = (from.y + to.y) / 2
                let vx = to.x - from.x, vy = to.y - from.y
                let len = max(1, (vx * vx + vy * vy).squareRoot())
                let ux = vx / len, uy = vy / len
                let half = max(3 * s, len * 0.30)
                ctx.setStrokeColor(red: 0.13, green: 0.14, blue: 0.15, alpha: 0.9); ctx.setLineWidth(max(2.5, 4 * s))
                ctx.move(to: CGPoint(x: mx - ux * half, y: my - uy * half)); ctx.addLine(to: CGPoint(x: mx + ux * half, y: my + uy * half)); ctx.strokePath()
                ctx.setStrokeColor(red: 0.95, green: 0.88, blue: 0.55, alpha: 1); ctx.setLineWidth(max(1.5, 2 * s))
                ctx.move(to: CGPoint(x: mx - ux * half, y: my - uy * half)); ctx.addLine(to: CGPoint(x: mx + ux * half, y: my + uy * half)); ctx.strokePath()
            }
        }

        // Floor(s) above last, faint translucent ghost — your (opaque) room stays clear through it.
        for r in backToFront(placed.filter { $0.dim && $0.z > 0 }) { drawRoom(r, 0.26) }
        ctx.setAlpha(1.0)

        drawCompass(ctx, corner: CGPoint(x: 20 * s, y: CGFloat(height) - 20 * s), s: s, north: ny)

        guard let image = ctx.makeImage() else { return nil }
        return pngData(image)
    }

    /// A little corner compass: an arrow toward screen-north (up-left in iso) with an "N", so the diagonal
    /// grid stays readable. `stepX,stepY` give the exact north direction = the +gy screen vector (-,+).
    private static func drawCompass(_ ctx: CGContext, corner: CGPoint, s: CGFloat, north: CGVector) {
        ctx.setAlpha(1.0)
        let len = 13 * s
        let mag = (north.dx * north.dx + north.dy * north.dy).squareRoot()
        let nx = north.dx / mag, ny = north.dy / mag         // north screen unit vector (up, slightly left)
        let tip = CGPoint(x: corner.x + nx * len, y: corner.y + ny * len)
        let tail = CGPoint(x: corner.x - nx * len * 0.5, y: corner.y - ny * len * 0.5)
        // shaft
        ctx.setStrokeColor(red: 0.95, green: 0.9, blue: 0.55, alpha: 1); ctx.setLineWidth(max(1.5, 2 * s)); ctx.setLineCap(CGLineCap.round)
        ctx.move(to: tail); ctx.addLine(to: tip); ctx.strokePath()
        // arrowhead
        let perpx = -ny, perpy = nx, ah = 5 * s
        let a1 = CGPoint(x: tip.x - nx * ah + perpx * ah * 0.6, y: tip.y - ny * ah + perpy * ah * 0.6)
        let a2 = CGPoint(x: tip.x - nx * ah - perpx * ah * 0.6, y: tip.y - ny * ah - perpy * ah * 0.6)
        let head = CGMutablePath(); head.move(to: tip); head.addLine(to: a1); head.addLine(to: a2); head.closeSubpath()
        ctx.addPath(head); ctx.setFillColor(red: 0.95, green: 0.9, blue: 0.55, alpha: 1); ctx.fillPath()
        // "N" glyph past the tip
        let nl = CGPoint(x: tip.x + nx * 8 * s, y: tip.y + ny * 8 * s), g = 3.5 * s
        let glyph = CGMutablePath()
        glyph.move(to: CGPoint(x: nl.x - g, y: nl.y - g)); glyph.addLine(to: CGPoint(x: nl.x - g, y: nl.y + g))
        glyph.addLine(to: CGPoint(x: nl.x + g, y: nl.y - g)); glyph.addLine(to: CGPoint(x: nl.x + g, y: nl.y + g))
        ctx.addPath(glyph); ctx.setStrokeColor(red: 1.0, green: 0.95, blue: 0.7, alpha: 1)
        ctx.setLineWidth(max(1.2, 1.6 * s)); ctx.setLineJoin(CGLineJoin.miter); ctx.strokePath()
    }

    private static func chevron(_ ctx: CGContext, at p: CGPoint, up: Bool, s: CGFloat, bright: Bool) {
        let w = 5 * s, h = 5 * s, dy: CGFloat = up ? h : -h
        let path = CGMutablePath()
        path.move(to: CGPoint(x: p.x - w, y: p.y)); path.addLine(to: CGPoint(x: p.x, y: p.y + dy))
        path.addLine(to: CGPoint(x: p.x + w, y: p.y))
        ctx.addPath(path)
        if bright { ctx.setStrokeColor(red: 0.55, green: 1.0, blue: 0.6, alpha: 1) }
        else { ctx.setStrokeColor(red: 0.95, green: 0.65, blue: 0.35, alpha: 1) }
        ctx.setLineWidth(max(1.5, 2 * s)); ctx.setLineJoin(CGLineJoin.round); ctx.strokePath()
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
