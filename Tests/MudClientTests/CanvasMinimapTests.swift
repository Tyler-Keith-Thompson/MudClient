import Foundation
import Testing
import ImageIO
import DependencyInjection

@testable import MudClient

// End-to-end: drive the REAL `canvas` builtin through the Lua renderer (Minimap.lua) and confirm it paints
// a valid image into the top panel. Also dumps the PNG to /tmp for eyeballing parity with the old Swift
// renderer. Uses the repo's baked terrain tiles (CWD = repo root, like the display-pipeline test).
@Test func minimapRendererPaintsThroughCanvasBuiltin() async throws {
    try await withTestContainer {
        Container.terminalService.register { TerminalService() }
        Container.panelHost.register { PanelHost() }
        Container.topPanelHost.register { PanelHost() }
        Container.sessionLog.register { SessionLog() }
        Container.lagMonitor.register { LagMonitor() }
        Container.transcriptStore.register { TranscriptStore() }
        Container.scriptInterpreter.register { ScriptInterpreter() }
        Container.anthropicAPIKeyProvider.register { { nil } }

        let repoRoot = URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        let prev = FileManager.default.currentDirectoryPath
        FileManager.default.changeCurrentDirectoryPath(repoRoot)
        defer { FileManager.default.changeCurrentDirectoryPath(prev) }

        let engine = Container.scriptInterpreter().engine
        engine.onEcho = { _ in }; engine.onSend = { _ in }
        let src = try #require(try? String(contentsOfFile: repoRoot + "/Scripts/AlterAeon/Minimap.lua", encoding: .utf8),
                               "Minimap.lua missing — regen with tl gen")
        try engine.load(source: src)

        // A scene exercising terrain variety, an eastern elevation climb, and a dim floor-above ghost.
        engine.evalREPL("""
          local sc = {
            {gx=0,gy=0,z=0,terrain=2,exits={"n","e","s","w","u"},cur=true},
            {gx=0,gy=1,z=0,terrain=4,exits={"s","n"}}, {gx=0,gy=2,z=0,terrain=5,exits={"s","n"}},
            {gx=0,gy=3,z=0,terrain=5,exits={"s","n"}}, {gx=0,gy=4,z=0,terrain=6,exits={"s","n"}},
            {gx=0,gy=5,z=0,terrain=6,exits={"s"}},
            {gx=0,gy=-1,z=0,terrain=2,exits={"n","s"}}, {gx=0,gy=-2,z=0,terrain=28,exits={"n","s"}},
            {gx=0,gy=-3,z=0,terrain=28,exits={"n"}},
            {gx=1,gy=0,z=0,terrain=15,exits={"w","e"}}, {gx=2,gy=0,z=1,terrain=10,exits={"w","e"}},
            {gx=3,gy=0,z=2,terrain=10,exits={"w","e"}}, {gx=4,gy=0,z=2,terrain=8,exits={"w","e"}},
            {gx=5,gy=0,z=3,terrain=10,exits={"w"}},
            {gx=-1,gy=0,z=0,terrain=32,exits={"e","w"}}, {gx=-2,gy=0,z=0,terrain=18,exits={"e","w"}},
            {gx=-3,gy=0,z=0,terrain=18,exits={"e"}},
            {gx=1,gy=1,z=0,terrain=3,exits={"s"}}, {gx=2,gy=1,z=1,terrain=15,exits={}},
            {gx=-1,gy=-1,z=0,terrain=7,exits={"ne"}}, {gx=1,gy=-2,z=0,terrain=20,exits={}},
            {gx=-1,gy=1,z=0,terrain=3,exits={}}, {gx=2,gy=-1,z=0,terrain=20,exits={}},
            {gx=0,gy=0,z=1,terrain=1,exits={"d"},dim=true}, {gx=0,gy=-1,z=-1,terrain=27,exits={"n"},dim=true},
          }
          minimap_render(sc, 26, 9, 5)
        """)

        let img = try #require(Container.topPanelHost().currentImage(), "canvas painted no image into the panel")
        #expect(img.data.count > 0)
        #expect(Array(img.data.prefix(4)) == [0x89, 0x50, 0x4E, 0x47])   // PNG magic
        #expect(img.cols == 26 && img.rows == 9)
        try? img.data.write(to: URL(fileURLWithPath: "/tmp/minimap_lua.png"))
    }
}
