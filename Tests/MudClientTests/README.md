# Test conventions: `withTestContainer` around every test

**Every test wraps its body in `withTestContainer { … }` directly** — no wrapper/alias/setup helpers, and
the DEFAULT (strict) behavior. Tests are individual and transferable: each **registers inline every
dependency it resolves** (it's fine — wanted, even — for a test to get long doing so), and no test can
interfere with another.

```swift
@Test func doesTheThing() throws {
    try withTestContainer {                       // default = .fatalError on any UNREGISTERED resolve
        Container.someService.register { MockSomeServicing(policy: .relaxedVoid) }
        // ...register every OTHER Container dep this test resolves...
        // ...the whole test body...
    }
}
```

Because the default `unregisteredBehavior` is `.fatalError`, a test that resolves something it didn't set
up **traps** — which is the point: it forces the test to declare everything it depends on. Don't reach for
`unregisteredBehavior: .custom` to make a test "just resolve real"; register what it needs.

## Why `withTestContainer` (and not plain `register` / `withNestedContainer`)

`withTestContainer` (from `DependencyInjection`, written in-house) does two things:

1. **Installs a fresh task-local `TestContainer`** for the scope. This lets `Container.x.register { mock }`
   override a factory **even if its `.cached` singleton is already warm**. A plain `Container.register`
   or `withNestedContainer` defers to the shared cached scope, so it keeps handing back the real,
   already-resolved instance — which is why audio kept playing in tests until we switched to
   `withTestContainer` (the real MSP/music/speech services are resolved when the game scripts load).

2. **Flips `Container.default.fatalErrorOnResolve = true` for the scope.** This is a *strict harness*:
   any DI resolution that happens **without** the container context — i.e. one that fell back to
   `Container.default` — traps with a `fatalError`. That deliberately catches two bug classes:
   - a test that leaked (didn't set up its container), and
   - a **task-local leak** in prod: code that resolves DI on an execution context that dropped Swift
     task-locals.

## The rule — why interference becomes impossible

> If **everybody uses a test container** and **nobody leaks task-locals**, tests can't interfere.

Each test resolves through its own `TestContainer`; nothing reaches the shared `Container.default`.

- **Wrap them all.** The `fatalErrorOnResolve` flag is process-global for the scope, and tests run in
  parallel — so a single *unwrapped* test resolving DI during another test's window traps. It's
  all-or-nothing: if one test wraps, they all must. (`--no-parallel` is not honored by the Bazel xctest
  runner, so serialization is not an escape hatch.)

- **No task-local leaks.** Swift task-locals (which carry the container) propagate into a child `Task {}`
  but **not** into `Task.detached`, a GCD queue (`DispatchQueue.async` / `asyncAfter`), or
  `Thread.detachNewThread`. When prod hands work to one of those **and resolves DI inside it**, re-apply
  the container:

  ```swift
  let ref = Container.current            // capture at schedule time (still in-context)
  someQueue.async {
      withContainer(ref) {               // re-apply — the queue dropped the task-local
          … resolve DI …
      }
  }
  ```

  Prefer **not** using `Task.detached`. If the context loss is under Apple's covers (GCD/`Thread`),
  `withContainer(ref)` is the remedy — that's exactly what it's for.

### Fixes made so far
- **`LuaScriptEngine.arm`** (backing `after`/`every`): timer callbacks fire on a GCD `timerQueue`, which
  drops task-locals, and the Lua callback resolves services (`terminalService` via `echo`, the LLM
  clients). Fixed by capturing `Container.current` when the timer is armed and wrapping the fired
  `DispatchWorkItem` in `withContainer(container)`. (The reactive scripts schedule many `after` timers,
  so this path is hot.)

## Silencing audio

No special wrapper — a test that drives the game pipeline registers the silent audio mocks inline in its
own `withTestContainer`, like any other dependency it sets up:

```swift
@Test func replaysARealCapture() async throws {
    try await withTestContainer {
        let music = MockMusicServicing(policy: .relaxedVoid)
        let speech = MockSpeechServicing(policy: .relaxedVoid)
        let msp = MockMSPServicing(policy: .relaxedVoid)
        given(msp).player(.any, volume: .any, loops: .any).willProduce { _, _, _ in
            DeferredTask<AudioPlayer> { throw CancellationError() }.eraseToAnyUnitOfWork()
        }
        Container.musicService.register { music }
        Container.speechService.register { speech }
        Container.mspService.register { msp }
        // ...plus every other dep this pipeline test resolves...
        // ...feed the base64 raw capture through the pipeline...
    }
}
```

This matters because real-capture replay tests (`rawLogPipelineGagsKxwtNoLeak`,
`gaggedKxwtBatchesRenderNothing`, `replayCapturedRawLog`, …) feed base64 raw MUD logs whose decoded bytes
contain MSP `!!SOUND` directives; without the mocks the real `MSPService` fetches and plays them (audible
during tests). It must be `withTestContainer` (not `withNestedContainer` / plain `register`) because the
real services are already cached from script load.
