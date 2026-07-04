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
  automation, recovery, the `#kxwt`/`#test` commands, the command reference fed to the AI.
- `Scripts/AIPilot.lua` — the AI pilot + the room map/minimap, pathfinding (`navigate`/`explore`/`goto`),
  landmarks (`#mark`), and waypoint/recall bridging. The big one.
- `Scripts/HUD.lua` — the status panels (vitals/gauges, group roster, minimap, compass).

Edit any of them and run `#ai reload` in the app to apply live (no rebuild). Host builtins are registered
in `Sources/MudClient/LuaScriptEngine.swift` (trigger/alias/command/echo/send/after/panel/ai_*/music/…).

## Testing the scripts

Pure Lua logic is unit-tested. Specs live in `Scripts/tests/*_spec.lua`; exposed seams are `_HUD_TEST`,
`_AIP_TEST`, `_AA_TEST`. Three ways to run the SAME suite:

```
./tools/luatest/run.sh          # standalone: compiles a tiny Lua from Sources/CLua, no Xcode needed
just test-lua                   # via Bazel (fast, cached)
#test                           # in-app, in the live Lua state, after `#ai reload`
```

Adding a spec is just dropping a `Scripts/tests/foo_spec.lua` — the Bazel filegroup globs it. Trigger
*regexes* run in Swift's engine (not testable from Lua); test the pure helpers they call instead.

## Build / run

- `just build` / `just run` — Bazel build of `//Sources/MudClient` (runs from repo root; the app shells
  out to `swift build` for Scripts' SwiftPM packages, so CWD matters).
- `just test` — `bazel test //...` (Swift + Lua suites). `just generate` — Xcode project.
- Note: plain `swift build` (SwiftPM CLI) currently fails on strict-concurrency errors in
  `LLMClient.swift`/`RAGRetriever.swift`; build via **Bazel or Xcode**, not the SwiftPM CLI.
