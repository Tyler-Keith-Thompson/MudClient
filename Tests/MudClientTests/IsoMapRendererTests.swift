import Foundation
import Testing
import ImageIO

@testable import MudClient

// A sample scene exercising terrain variety, z-levels, up/down chevrons, and the current-room ring.
// gy grows north; z is relative to the current room.
private func sampleScene() -> [IsoMapRenderer.Room] {
    func r(_ gx: Int, _ gy: Int, _ z: Int, _ terr: Int, _ exits: [String], cur: Bool = false) -> IsoMapRenderer.Room {
        IsoMapRenderer.Room(gx: gx, gy: gy, z: z, exits: Set(exits), terrain: terr, current: cur, rgb: nil)
    }
    return [
        r(0, 0, 0, 3, ["n", "s", "e", "w"], cur: true),   // current — grassy field
        // east: climbing terrain, ending on a mountain with an up exit
        r(1, 0, 0, 15, ["w", "e"]),                        // hill
        r(2, 0, 1, 10, ["w", "e", "u"]),                   // mountain, has UP
        r(3, 0, 2, 10, ["w"]),                             // higher mountain
        // north: forest deepening
        r(0, 1, 0, 4, ["s", "n"]),                         // light forest
        r(0, 2, 0, 5, ["s"]),                              // thick forest
        // west + down into a cave
        r(-1, 0, -1, 27, ["e", "w", "d"]),                 // cave, has DOWN
        r(-2, 0, -1, 32, ["e"]),                           // water
        // south: town → city
        r(0, -1, 0, 2, ["n", "s"]),                        // town cobbles
        r(0, -2, 0, 28, ["n"]),                            // city
        // a lower-left lava pocket to show colour + depth
        r(-1, 1, -1, 25, []),                              // lava
    ]
}

@Test func isoMapRendererProducesValidPNG() {
    guard let png = IsoMapRenderer.renderPNG(rooms: sampleScene(), halfX: 6, halfY: 4, scale: 3) else {
        Issue.record("iso renderPNG returned nil"); return
    }
    #expect(png.count > 0)
    #expect(Array(png.prefix(4)) == [0x89, 0x50, 0x4E, 0x47])   // PNG magic
    guard let src = CGImageSourceCreateWithData(png as CFData, nil),
          CGImageSourceCreateImageAtIndex(src, 0, nil) != nil else {
        Issue.record("PNG did not decode"); return
    }
}

@Test func isoMapRendererEmptyIsNil() {
    #expect(IsoMapRenderer.renderPNG(rooms: [], halfX: 6, halfY: 4) == nil)
}

// Dumps a rendered sample to /tmp so the look can be eyeballed. Uses the repo's baked terrain tiles when
// present (falls back to flat colours otherwise). Always "passes"; it's a visual aid, not an assertion.
@Test func isoMapRendererVisualDump() {
    let repo = URL(fileURLWithPath: #filePath)                    // …/Tests/MudClientTests/IsoMapRendererTests.swift
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let tiles = TerrainTiles(baseDir: repo.appendingPathComponent("Assets/terrain").path)
    guard let png = IsoMapRenderer.renderPNG(rooms: sampleScene(), halfX: 6, halfY: 4, scale: 4, tiles: tiles) else {
        Issue.record("visual dump render returned nil"); return
    }
    try? png.write(to: URL(fileURLWithPath: "/tmp/iso_sample.png"))
    #expect(png.count > 0)
}
