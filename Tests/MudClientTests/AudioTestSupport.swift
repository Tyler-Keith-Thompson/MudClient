import Afluent
import DependencyInjection
import Foundation
import Mockable
@testable import MudClient

/// Build the three silent audio mocks. Void methods no-op via `.relaxedVoid`; the one non-void method
/// (`MSPServicing.player`, which `processMSP` calls for a `!!SOUND` whose default URL is set) is stubbed
/// to a unit of work that produces nothing (immediately cancels), so no file is ever fetched or played.
private func makeSilentAudioMocks() -> (MockMusicServicing, MockSpeechServicing, MockMSPServicing) {
    let music = MockMusicServicing(policy: .relaxedVoid)
    let speech = MockSpeechServicing(policy: .relaxedVoid)
    let msp = MockMSPServicing(policy: .relaxedVoid)
    given(msp)
        .player(.any, volume: .any, loops: .any)
        .willProduce { _, _, _ in
            DeferredTask<AudioPlayer> { throw CancellationError() }.eraseToAnyUnitOfWork()
        }
    return (music, speech, msp)
}

/// Run `body` with the three audio services replaced by silent relaxed mocks, inside a withTestContainer
/// scope (parallel-safe isolation). Unregistered dependencies resolve to their real prod implementations.
func withSilentAudio<T>(_ body: () throws -> T) rethrows -> T {
    let (music, speech, msp) = makeSilentAudioMocks()
    return try withTestContainer(unregisteredBehavior: .custom { _ in }) {
        Container.musicService.register { music }
        Container.speechService.register { speech }
        Container.mspService.register { msp }
        return try body()
    }
}

/// Async overload of `withSilentAudio`.
func withSilentAudio<T>(_ body: () async throws -> T) async rethrows -> T {
    let (music, speech, msp) = makeSilentAudioMocks()
    return try await withTestContainer(unregisteredBehavior: .custom { _ in }) {
        Container.musicService.register { music }
        Container.speechService.register { speech }
        Container.mspService.register { msp }
        return try await body()
    }
}
