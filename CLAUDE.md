# MudClient

A terminal MUD client (Swift) for AlterAeon, with the game logic, HUD, and an AI auto-pilot written in
hot-reloadable Lua. The Swift side is a generic host (screen/panels, telnet, an embedded Lua 5.4, and a
few builtins); everything game-specific lives in `Scripts/`.

## Answering "how does <game thing> work?" (AlterAeon mechanics)

**Grep the scraped help corpus first — don't guess.** `tools/finetune/help_raw/` is a local (gitignored)
mirror of the game's help/articles/guides/quests (~1900 files). Use the ranked search helper:

```
tools/finetune/game_help.sh waypoint recall        # prints the best-matching help topics in full
TOPN=5 tools/finetune/game_help.sh sacrifice corpse spellcomp
```

Real player logs are also on disk: `~/Documents/MudClient/human-traces.jsonl` (verbatim game output +
the command taken — good for exact wire formats). The embedding RAG index
(`~/Documents/MudClient/rag_index.json`, built by `build_rag_index.py`) is what the in-game AI retrieves
against, but it needs the embedding model and isn't queryable from a shell — use `game_help.sh` instead.

## Scripts (the hot-reloadable Lua)

- `Scripts/AlterAeon.lua` — game/kxwt protocol: parses `kxwt_*` into the shared `state` table, corpse
  automation, recovery, the `kxwt.dump()`/`kxwt.corpse()`/`volume()`/`test()` functions, the command
  reference fed to the AI.
- `Scripts/AIPilot.lua` — the AI pilot + the room map/minimap, pathfinding (`navigate`/`explore`/`goto`),
  landmarks (`mark()`), waypoints (`waypoints()`), routing (`travel()`), and the `pilot.*` control table
  (pilot.on/off/status/…). The big one.
- `Scripts/HUD.lua` — the status panels (vitals/gauges, group roster, minimap, compass).

`#…` input is a live Lua REPL over the loaded scripts (see `Scripts/bootstrap.lua` for the `doc()`/`help()`
registry) — type `#help()` to list everything, `#help(eq)` / `#help("map")` to drill in. The game surface
is first-class Lua now: tables `eq`, `pilot`, `kxwt`, `trivia` (each callable, so legacy `#eq scan` still
works via `eq("scan")`) and functions `mark`/`waypoints`/`reset`/`travel`/`test`/`volume`. Edit any script
and run `#pilot.reload()` (or `#reload`) in the app to apply live (no rebuild). Host builtins are registered
in `Sources/MudClient/LuaScriptEngine.swift` (trigger/alias/command/echo/send/after/panel/ai_*/music/…);
the `#word rest` → `word("rest")` legacy rewrite also fires for callable tables (`globalIsCallable`).

**Docs are enforced.** Every new host builtin (`lua.register`), `on_*` hook (`callGlobal*` call site in
Swift), and public script API (member of eq/pilot/kxwt/trivia/panel/music) MUST get a `doc()` entry —
in `Scripts/bootstrap.lua` for the host surface, in the defining script for script APIs — or the suite
fails naming the offender (`Scripts/tests/doc_coverage_spec.lua` + `DocCoverageTests.swift`). A new
builtin also needs its stub registered in `tools/luatest/driver.lua`. `__`-prefixed names are exempt.

Host hook surface (all optional Lua globals / builtins; see LuaScriptEngine.swift for signatures):
- Rules: `trigger`/`alias`/`gag` return ids; opts `{oneshot=, class=}`; `rule_remove`/`rule_enable`/
  `class_enable`/`class_remove`. A trigger handler's return rewrites the displayed line (string),
  gags it (`false`/`""`), or leaves it (nil); the raw ANSI line is passed as the last handler arg.
- Timers: `after`/`every` return cancellable ids, `cancel(id)`; all timers auto-cancel on reload.
- Lifecycle/telnet: `on_connect`, `on_disconnect(reason)`, `on_prompt(text)` (GA boundary),
  `on_telnet(option, payload)`, `on_telnet_negotiate(verb, option)`, `connect`/`disconnect`/
  `is_connected`, `telnet_send`. MCCP (85/86) is deliberately not negotiable.
- Terminal: `bind`/`unbind` key macros, `input_get`/`input_set`, `on_resize(cols, rows)`,
  `on_mouse(event, x, y, button)` (return true to consume), `scrollback(n)`/`scrollback_find`,
  `bell()`, `echo(text, color)`.
- I/O: `log_start`/`log_stop`/`log_active` session logging; `replay(path, {speed=, quiet=})` feeds a
  saved log through the live trigger pipeline (offline parser regression tests); `on_send(cmd)`
  rewrites/suppresses outbound commands.

## Testing the scripts

Pure Lua logic is unit-tested. Specs live in `Scripts/tests/*_spec.lua`; exposed seams are `_HUD_TEST`,
`_AIP_TEST`, `_AA_TEST`. Three ways to run the SAME suite:

```
./tools/luatest/run.sh          # standalone: compiles a tiny Lua from Sources/CLua, no Xcode needed
just test-lua                   # via Bazel (fast, cached)
#test()                         # in-app, in the live Lua state, after `#pilot.reload()`
```

Adding a spec is just dropping a `Scripts/tests/foo_spec.lua` — the Bazel filegroup globs it. Trigger
*regexes* run in Swift's engine (not testable from Lua); test the pure helpers they call instead.

## Script loading (self-bootstrapping)

`load(path)` (Lua, in `bootstrap.lua`, shadows stdlib `load` — that stays at `loadchunk`) resolves
relative to the launch CWD: a file loads that file (`.lua` assumed if absent, so `load("AlterAeon")` ≡
`load("AlterAeon.lua")`); a directory loads its top-level `*.lua`, non-recursively, excluding
`bootstrap.lua`/`testing.lua`/`_`-prefixed files/subdirs, in **case-insensitive alphabetical** order.
**There is no manifest** — every script runs through `require` (a custom `package.searcher` in
`bootstrap.lua` that resolves names to `Scripts/*.lua` via the host `__path_kind`/`__run_file`
primitives), so a module runs once per session and **load order emerges from `require(...)` deps
declared at the top of a script**, not a sidecar list. In practice there are ~no cross-script
load-time deps: each script that reads the shared `state` table creates it defensively (`state = state
or {}`; `AlterAeon.lua` owns the schema and fills missing keys, order-independently). The other thing
the manifest used to guarantee — **same-line trigger firing order** — is now decided by **pattern
specificity in the Swift engine** (priority desc → specificity desc → registration order): specific
kxwt parsers fire before broad `.*` observers regardless of load order, so the observers read the
state the parsers wrote. `opts.priority` on `trigger()`/`alias()` overrides; aliases resolve
most-specific-match-wins. `load(path)`/`reload()` bust the require cache so an interactive re-load
re-runs (`reload()` = drop script modules from `package.loaded` + clear all rules/timers +
`load("Scripts")`). Scripts are self-bootstrapping: top-level code runs on load, so **`AlterAeon.lua`
opens the connection itself** (a guarded top-level `connect("alteraeon.com", 3002)` — the host no
longer hardcodes it). The host just runs `load("Scripts")` at launch. `#load {Name}` / `#load Name`
still work (rewrite to `load("Scripts/Name")`).

## Build / run

- `just build` / `just run` — Bazel build of `//Sources/MudClient` (runs from repo root; the app shells
  out to `swift build` for Scripts' SwiftPM packages, so CWD matters — and `load("Scripts")` resolves
  against that same CWD).
- `just test` — `bazel test //...` (Swift + Lua suites). `just generate` — Xcode project.
- Note: plain `swift build` (SwiftPM CLI) currently fails on strict-concurrency errors in
  `LLMClient.swift`/`RAGRetriever.swift`; build via **Bazel or Xcode**, not the SwiftPM CLI.
