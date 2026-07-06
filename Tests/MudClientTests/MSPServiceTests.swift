import Foundation
import Testing

@testable import MudClient

// The service-level MSP master. `player(url:volume:)` needs a real audio file/URL to build an
// AVAudioPlayer, so we assert the scaling through `scaledVolume(_:)` — the exact function the player
// path multiplies an effect's own volume by before playback. This proves an effect started at any base
// volume is scaled by the master, and that a master of 0 silences it.
@Test func mspServiceVolumeScalesEffectVolume() {
    let svc = MSPService()
    #expect(svc.scaledVolume(1.0) == 1.0)     // default master = 1 (full): unchanged
    #expect(svc.scaledVolume(0.8) == 0.8)

    svc.setVolume(percent: 50)
    #expect(svc.scaledVolume(1.0) == 0.5)     // 50% master halves a full-volume effect
    #expect(svc.scaledVolume(0.5) == 0.25)

    svc.setVolume(percent: 0)
    #expect(svc.scaledVolume(1.0) == 0.0)     // master 0 => silent regardless of the effect's own volume
    #expect(svc.scaledVolume(0.7) == 0.0)
}

@Test func mspServiceVolumeClampsPercent() {
    let svc = MSPService()
    svc.setVolume(percent: 250)
    #expect(svc.scaledVolume(1.0) == 1.0)     // clamped to 100%
    svc.setVolume(percent: -10)
    #expect(svc.scaledVolume(1.0) == 0.0)     // clamped to 0%
}
