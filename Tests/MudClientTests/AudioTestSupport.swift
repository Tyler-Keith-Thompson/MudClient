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

/// Run `body` with the three audio services replaced by silent relaxed mocks, inside a task-local nested
/// container. Unregistered dependencies fall through the parent chain to their real prod implementations.
///
/// NB: uses `withNestedContainer`, NOT `withTestContainer`. `withTestContainer` additionally sets a
/// *process-global* `Container.default.fatalErrorOnResolve = true` for the scope's duration; because
/// swift-testing runs this suite in parallel, any sibling test resolving a `Container.default` dependency
/// (e.g. `TranscriptStore`, the `anthropicAPIKeyProvider`, at engine construction) during that window
/// hits an unconditional `fatalError`. `withNestedContainer` only swaps the task-local container, so it
/// overrides the (cached) audio factories inside this scope without disturbing any other test.
func withSilentAudio<T>(_ body: () throws -> T) rethrows -> T {
    let (music, speech, msp) = makeSilentAudioMocks()
    return try withNestedContainer {
        Container.musicService.register { music }
        Container.speechService.register { speech }
        Container.mspService.register { msp }
        return try body()
    }
}

/// Async overload of `withSilentAudio`.
func withSilentAudio<T>(_ body: () async throws -> T) async rethrows -> T {
    let (music, speech, msp) = makeSilentAudioMocks()
    return try await withNestedContainer {
        Container.musicService.register { music }
        Container.speechService.register { speech }
        Container.mspService.register { msp }
        return try await body()
    }
}
