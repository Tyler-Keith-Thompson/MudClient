import Foundation
import Testing
import ImageIO

@testable import MudClient

@Test func mapRendererProducesAValidPNGSizedToTheGrid() {
    // A 2x2 block of rooms, one current, with a couple of exits between them.
    let rooms = [
        MapRenderer.Room(gx: 0, gy: 1, exits: ["e", "s"], current: true,  rgb: nil),
        MapRenderer.Room(gx: 1, gy: 1, exits: ["w"],      current: false, rgb: (0.2, 0.8, 0.3)),
        MapRenderer.Room(gx: 0, gy: 0, exits: ["n"],      current: false, rgb: nil),
    ]
    let cell = 20
    guard let png = MapRenderer.renderPNG(rooms: rooms, cell: cell) else {
        Issue.record("renderPNG returned nil"); return
    }
    #expect(png.count > 0)
    // It's a real PNG (magic bytes) …
    #expect(Array(png.prefix(4)) == [0x89, 0x50, 0x4E, 0x47])
    // … and decodes to the expected pixel size: grid span (2 cols x 2 rows) x cell.
    guard let src = CGImageSourceCreateWithData(png as CFData, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        Issue.record("PNG did not decode"); return
    }
    #expect(img.width == 2 * cell)   // gx 0..1 → 2 columns
    #expect(img.height == 2 * cell)  // gy 0..1 → 2 rows
}

@Test func mapRendererEmptyIsNil() {
    #expect(MapRenderer.renderPNG(rooms: [], cell: 20) == nil)
}
