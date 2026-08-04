//
//  TerrainTiles.swift
//  Loads + caches the ComfyUI-generated terrain textures (`Assets/terrain/NN_name.png`) that
//  `IsoMapRenderer` clips onto each iso tile's top face. Resolves relative to the launch CWD (same as
//  `load("Scripts")`), with a fallback search so it works from Bazel/Xcode/`just run`. Missing tiles are
//  fine — the renderer falls back to `IsoMapRenderer.terrainRGB` — so the map degrades gracefully before
//  the tileset is baked and never blocks on I/O twice for the same code.
//

import CoreGraphics
import Foundation
import ImageIO

final class TerrainTiles: @unchecked Sendable {
    /// kxwt terrain code → tile basename (matches `tools`/`gen_terrain.py`). 0–39.
    static let names: [Int: String] = [
        0: "notset", 1: "building", 2: "town", 3: "field", 4: "lforest", 5: "tforest", 6: "dforest",
        7: "swamp", 8: "plateau", 9: "sandy", 10: "mountain", 11: "rock", 12: "desert", 13: "tundra",
        14: "beach", 15: "hill", 16: "dunes", 17: "jungle", 18: "ocean", 19: "stream", 20: "river",
        21: "underwater", 22: "underground", 23: "air", 24: "ice", 25: "lava", 26: "ruins", 27: "cave",
        28: "city", 29: "marsh", 30: "wasteland", 31: "cloud", 32: "water", 33: "metal", 34: "taiga",
        35: "sewer", 36: "shadow", 37: "catacomb", 38: "mire", 39: "crystal",
    ]

    private let dir: URL?
    private let lock = NSLock()
    private var cache: [Int: CGImage?] = [:]   // value nil = looked-up-and-absent (don't re-hit disk)

    /// `baseDir` overrides tile location; nil → search CWD/`Assets/terrain` then a couple of siblings.
    init(baseDir: String? = nil) {
        if let b = baseDir { dir = URL(fileURLWithPath: b, isDirectory: true); return }
        let fm = FileManager.default
        let candidates = [
            fm.currentDirectoryPath + "/Assets/terrain",
            fm.currentDirectoryPath + "/../Assets/terrain",
            (fm.homeDirectoryForCurrentUser.path) + "/Documents/MudClient/tiles",
        ]
        dir = candidates.first { fm.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// True once at least the base dir resolved (tiles may still be individually absent).
    var available: Bool { dir != nil }

    /// Cached terrain texture for `code`, or nil if there is no tile (renderer uses the colour fallback).
    func image(_ code: Int?) -> CGImage? {
        guard let code, let dir else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[code] { return hit }
        let img = TerrainTiles.load(dir: dir, code: code)
        cache[code] = img
        return img
    }

    private static func load(dir: URL, code: Int) -> CGImage? {
        guard let name = names[code] else { return nil }
        let url = dir.appendingPathComponent(String(format: "%02d_%@.png", code, name))
        guard FileManager.default.fileExists(atPath: url.path),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return img
    }
}
