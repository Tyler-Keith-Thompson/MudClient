# MudClient Scripts — conventions

The scripts are hot-reloadable **Teal** (typed Lua). **North star: everything declarative and composable.**
This file governs *how scripts read and compose*; the top-level `CLAUDE.md` covers loading/testing mechanics.

## Layout
- **`Foundation/`** — game-agnostic standard library (all Teal): `_rx` (reactive Observable/Subject),
  `Promise`, `_persist`, `_dsl` (field/replies/on_all registrars), **`Parse`** (parser/printer
  combinators), + `foundation.d.tl` (declarations) and `env.d.tl` (aggregator). MUST NOT reference
  anything AlterAeon-specific.
- **`AlterAeon/`** — the game layer (kxwt/RPC parsing, combat, recovery, pilot, HUD, …) + `alteraeon.d.tl`
  (game declarations). May use Foundation types.
- `bootstrap.lua` and `tests/` stay at the `Scripts/` top level.
- Every script is a **`.tl` (typed source of truth)** compiled to `.lua` (the loaded artifact) — edit the
  `.tl`; the loader / `#reload` recompiles. Declarations live in `*.d.tl` (type-checked via `tlconfig`'s
  `env.d.tl`, never generated to `.lua`).

## THE rule: a declarative, readable top
The **top of every script is a followable, declarative block of what it does**; the imperative "how"
(step functions, parsers, formatting) lives *below*. If you can't read what a script does from its top,
it's wrong. **Declarative and composable is the bar — NOT "reactive" specifically.** Pick the clearest
declarative shape for the script:
- **Event-reactor** (independent lines/events → independent reactions) → a block of `onX:subscribe(...)` /
  `stream:subscribe(...)` chains, or top-of-file `trigger(...)` registrations.
- **State-machine** (a promise/reactive flow) → a marked `-- ══ THE FLOW ══` executable block (the
  pipeline + its subscriptions), with the stages forward-declared and defined below (see AutoFight.tl).
- **Priority-router / message-dispatcher** (ordered first-match) → a declarative **dispatch table**
  (`when <pred> → <handler>`), NOT forced streams and NOT a wall of `if/elseif`.
- **Parser** → a declarative `Parse` grammar (see below).
- Anything with knobs → a declarative **config/spec table**.

Do NOT force reactive where it doesn't fit, and do NOT leave a top imperative because "reactive is wrong
here" — reach for a different *declarative* form. The block must be executable code, never a comment
describing it.

## Event-driven
Domain events are **named, typed, first-class Observables** (`onCombatStart`, `onCombatEnd`,
`onPostureChange`, `onTankDown`, `onManaLow`, `onNewOpponent`, `onSpellLanded`, … — there should be
*lots*), derived reactively from the raw kxwt/RPC/prompt streams in **`AlterAeon/Events.tl`**. Scripts
subscribe declaratively, and events compose like any stream:

```lua
onCombatStart :subscribe(engage_openers)
onTankDown    :subscribe(retank_or_resummon)
onManaLow     :filter(in_fight):subscribe(pause_offense)
```

## Parsing — use `Foundation/Parse.tl` (`__parse`), never hand-rolled scanners
Structured lines (kxwt/prompt/RPC wire formats, compound captures) are parsed with **declarative
parser/printer combinators** — `lit`/`oneOf`/`many1`/`seq2-4`/`:map(Conversion)`/`:take`/`:skip` — NOT
`gmatch`/hand-counted indices. Grammars are **bidirectional** (parse a line ↔ *print* a command). Prefer
`.map(Conversion)` (keeps it printable) over `.mapf` (one-way). `_dsl.field(pat):as(grammar)` accepts a
full `Parser<T>` sub-grammar.

```lua
local sentinel = __parse.oneOf(__parse.lit("kxwq_hud"), __parse.lit("kxwt_hud"))
local grammar  = sentinel:take(pipe):take(__parse.many1(field, pipe)):map(prompt_conv)  -- parses AND prints
```

## The pipeline
**parse** (raw line → values, via `Parse`) → **derive events** (values → named Observables, `Events.tl`)
→ **subscribe** (events → behavior, at each script's top). Every layer declarative and composable.

## Promise aliases — a typed word that runs a multi-step chain
When a typed word should kick off a promise chain (dcast → await an event → act) and show as ONE row in
the promise widget (so `+| <cmd>` appends onto it and `cancelPromises()`/`-|` act on it), use **`palias`**,
NOT a bare `alias()`. A plain alias's returned promise is dropped on the floor (Swift's `processAlias`
ignores the return, so only first-word GLOBAL callables like `recover`/`goto` or an explicit `|` pipe get
auto-tracked) — the widget never sees the chain. `palias(word, build)` registers `^word$`, runs `build()`
(returns the chain tail), and names the whole chain as one row titled `word` via `__name_chain`:
```lua
palias("dsleep", function()
  return dcast("deathly sleep"):andThen(function() return onNextSpellDown("deathly sleep") end):andThen("stand")
end)
```
One-shot event gates compose in the same spirit: `onNextMana(pct)`/`onNextHP`/`onNextMoves`/`onNextTick(pred)`
and `onNextSpellDown(name)`/`onNextSpellUp(name)` (Events.tl) each return a cancelable Promise that resolves
once. For a word that takes args/captures, use `alias()` + `__name_chain(tail, desc)` directly.

## Non-negotiables
- **Never revert to imperative to make something typecheck.** Convert via behavior-specs-then-rewrite.
- **Preserve behavior exactly** on any refactor — the specs (`Scripts/tests/*_spec.lua`, run via
  `./tools/luatest/run.sh`) are the gate; keep them green.
- Reactive/promise infra (`_rx`/`Promise`/`Parse`) is Foundation and **agnostic** — no game logic there.
