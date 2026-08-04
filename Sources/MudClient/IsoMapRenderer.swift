//
//  IsoMapRenderer.swift
//  The 2.5-D minimap renderer. Where `MapRenderer` paints a flat top-down grid, this paints the same
//  room graph through an ISOMETRIC camera (2:1 diamonds) so elevation reads at a glance: each room is a
//  little block whose top face carries its TERRAIN texture and whose height/vertical offset encodes its
//  z-level (world coord z, relative to the current room). Higher rooms float up and occlude lower ones;
//  a room that has an up/down exit gets a chevron so "there's something above/below here" is obvious.
//
//  Pure + game-agnostic: it takes a draw-spec (rooms on an integer grid + a z-level + a terrain code) and
//  a tile provider, and returns PNG data. The projection from AIPilot's world-coord graph onto this grid
//  lives in Lua (`minimap_grid`), reaching here via the `map_image` builtin. Terrain textures are the
//  ComfyUI-generated tiles under `Assets/terrain/NN_name.png`, loaded + cached by `TerrainTiles`.
//

import CoreGraphics
import Foundation
import ImageIO

enum IsoMapRenderer {
    /// One room to draw. `gx,gy` = BFS grid (gy grows NORTH). `z` = level relative to the current room
    /// (0 = same level, +1 = one up, -1 = one down). `terrain` = kxwt terrain code (0–39) or nil.
    struct Room {
        var gx: Int
        var gy: Int
        var z: Int
        var exits: Set<String>          // cardinals for edge stubs + "u"/"d" for the vertical chevron
        var terrain: Int?
        var current: Bool
        var rgb: (Double, Double, Double)?   // optional tint override (waypoint/blocked); nil → terrain colour
    }

    // Diamond geometry (2:1 iso). Kept small — the terminal upscales the PNG into the panel rectangle.
    private static let tileW = 40, tileH = 20         // top-face diamond bounding box
    private static let hw = 20.0, hh = 10.0           // half extents
    private static let levelH = 15.0                  // vertical pixels per z-level
    private static let skirt = 12.0                   // block wall thickness (volume under every tile)
    private static let zHeadroom = 3                  // z-levels of vertical margin reserved (constant scale)

    /// Render `rooms` to PNG. A FIXED grid window (`halfX,halfY`) centred on the current room (placed at
    /// 0,0) keeps per-room scale constant regardless of how many rooms exist; rooms outside are clipped.
    /// `tiles` supplies terrain textures (nil → flat colour fallback, so it works before tiles are baked).
    static func renderPNG(rooms: [Room], halfX: Int = 6, halfY: Int = 4,
                          scale: Int = 2, tiles: TerrainTiles? = nil) -> Data? {
        guard !rooms.isEmpty, halfX > 0, halfY > 0, scale > 0 else { return nil }
        let s = CGFloat(scale)
        let hwx = hw * s, hhx = hh * s, lvl = levelH * s, sk = skirt * s
        let twx = CGFloat(tileW) * s, thx = CGFloat(tileH) * s

        func inWindow(_ r: Room) -> Bool { r.gx >= -halfX && r.gx <= halfX && r.gy >= -halfY && r.gy <= halfY }

        // Canvas from the WINDOW corners at z=0 (constant), plus fixed z headroom + skirt margins.
        var minSx = CGFloat.greatestFiniteMagnitude, maxSx = -CGFloat.greatestFiniteMagnitude
        var minSy = CGFloat.greatestFiniteMagnitude, maxSy = -CGFloat.greatestFiniteMagnitude
        for gx in [-halfX, halfX] {
            for gy in [-halfY, halfY] {
                let sx = CGFloat(gx - gy) * hwx, sy = CGFloat(gx + gy) * hhx
                minSx = min(minSx, sx); maxSx = max(maxSx, sx)
                minSy = min(minSy, sy); maxSy = max(maxSy, sy)
            }
        }
        let margin = 6 * s
        let originX = -minSx + twx / 2 + margin
        let originY = -minSy + sk + margin                          // y-up; leaves room for the skirt below
        let width  = Int((maxSx - minSx) + twx + 2 * margin)
        let height = Int((maxSy - minSy) + thx + sk + lvl * CGFloat(zHeadroom) + 2 * margin)
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high

        // Top-face diamond centre (CG y-up: north/east and higher-z all move UP the screen).
        func centre(_ r: Room) -> CGPoint {
            CGPoint(x: originX + CGFloat(r.gx - r.gy) * hwx,
                    y: originY + CGFloat(r.gx + r.gy) * hhx + CGFloat(r.z) * lvl)
        }
        func diamond(_ c: CGPoint) -> CGPath {
            let p = CGMutablePath()
            p.move(to: CGPoint(x: c.x, y: c.y + hhx))            // N
            p.addLine(to: CGPoint(x: c.x + hwx, y: c.y))         // E
            p.addLine(to: CGPoint(x: c.x, y: c.y - hhx))         // S
            p.addLine(to: CGPoint(x: c.x - hwx, y: c.y))         // W
            p.closeSubpath()
            return p
        }

        let placed = rooms.filter(inWindow)
        // Painter's order: far/back (large gx+gy) first, then lower z first so higher blocks overdraw.
        let order = placed.sorted {
            let a = $0.gx + $0.gy, b = $1.gx + $1.gy
            if a != b { return a > b }
            return $0.z < $1.z
        }

        // Faint connective edges between adjacent placed rooms (read as corridors), drawn under the blocks.
        let byCell = Dictionary(placed.map { ("\($0.gx),\($0.gy)", $0) }) { a, _ in a }
        let delta: [String: (Int, Int)] = ["n": (0, 1), "s": (0, -1), "e": (1, 0), "w": (-1, 0),
                                           "ne": (1, 1), "nw": (-1, 1), "se": (1, -1), "sw": (-1, -1)]
        ctx.setLineWidth(max(1, 1.4 * s))
        ctx.setStrokeColor(red: 0.30, green: 0.36, blue: 0.38, alpha: 0.9)
        for r in order {
            let from = centre(r)
            for d in r.exits {
                guard let (dx, dy) = delta[d], let nb = byCell["\(r.gx + dx),\(r.gy + dy)"] else { continue }
                ctx.move(to: from); ctx.addLine(to: centre(nb))
            }
        }
        ctx.strokePath()

        for r in order {
            let c = centre(r)
            let top = diamond(c)
            let (fr, fg, fb) = r.rgb ?? terrainRGB(r.terrain)

            // ── skirt: two wall faces dropping `sk` below the top, giving each tile block volume ──
            let botC = CGPoint(x: c.x, y: c.y - sk)
            // left (SW) face
            let leftFace = CGMutablePath()
            leftFace.move(to: CGPoint(x: c.x - hwx, y: c.y)); leftFace.addLine(to: CGPoint(x: c.x, y: c.y - hhx))
            leftFace.addLine(to: CGPoint(x: botC.x, y: botC.y - hhx)); leftFace.addLine(to: CGPoint(x: botC.x - hwx, y: botC.y))
            leftFace.closeSubpath()
            ctx.addPath(leftFace); ctx.setFillColor(red: fr * 0.45, green: fg * 0.45, blue: fb * 0.45, alpha: 1); ctx.fillPath()
            // right (SE) face
            let rightFace = CGMutablePath()
            rightFace.move(to: CGPoint(x: c.x + hwx, y: c.y)); rightFace.addLine(to: CGPoint(x: c.x, y: c.y - hhx))
            rightFace.addLine(to: CGPoint(x: botC.x, y: botC.y - hhx)); rightFace.addLine(to: CGPoint(x: botC.x + hwx, y: botC.y))
            rightFace.closeSubpath()
            ctx.addPath(rightFace); ctx.setFillColor(red: fr * 0.62, green: fg * 0.62, blue: fb * 0.62, alpha: 1); ctx.fillPath()

            // ── top face: terrain texture clipped to the diamond, else flat colour ──
            if let img = tiles?.image(r.terrain) {
                ctx.saveGState()
                ctx.addPath(top); ctx.clip()
                let box = CGRect(x: c.x - hwx, y: c.y - hhx, width: hwx * 2, height: hhx * 2)
                ctx.draw(img, in: box)
                ctx.restoreGState()
            } else {
                ctx.addPath(top); ctx.setFillColor(red: fr, green: fg, blue: fb, alpha: 1); ctx.fillPath()
            }

            // top-face outline (crisper block edges)
            ctx.addPath(top); ctx.setStrokeColor(red: 0.10, green: 0.12, blue: 0.13, alpha: 0.85)
            ctx.setLineWidth(max(1, 1.2 * s)); ctx.strokePath()

            // vertical exit chevron: up = bright ▲ above the tile, down = dim ▼ on the tile
            if r.exits.contains("u") { chevron(ctx, at: CGPoint(x: c.x, y: c.y + hhx + 3 * s), up: true, s: s, bright: true) }
            if r.exits.contains("d") { chevron(ctx, at: CGPoint(x: c.x, y: c.y - 1 * s), up: false, s: s, bright: false) }

            if r.current {
                ctx.addPath(diamond(CGPoint(x: c.x, y: c.y)))
                ctx.setStrokeColor(red: 1.0, green: 0.86, blue: 0.2, alpha: 1)
                ctx.setLineWidth(max(1.5, 2.2 * s)); ctx.strokePath()
            }
        }

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
        case 1, 33:            return (0.60, 0.52, 0.40)   // building / metal
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
