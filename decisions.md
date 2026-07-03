# Plan: move the AI pilot AND the AlterAeon protocol out of Swift into Lua

Decision: **Option B (purist).** The Swift client becomes fully game-agnostic. *All* AlterAeon
knowledge — the KXWT protocol parser, the character/world state, recovery logic, and the AI pilot —
lives in hot-reloadable Lua. Tweaking any of it is "edit script → `#ai reload`", never a recompile.

## End state

**Swift = generic MUD client, no game knowledge:**
- Connection / IAC / MSP / terminal (already generic; CRLF normalized centrally).
- Lua engine + builtins: `send`, `echo`, `trigger`, `alias`, `gag`, `#load`, `#ai reload`.
- THREE new generic builtins (below). Lua's stdlib (`io`, `os`, `string`, `table`) is already open,
  so file persistence + JSON live in Lua.
- **Deleted:** `AIPilotService.swift`, `KXWTHost.swift`, and the game-specific builtins
  (`kxwt`, `recover`, `dump_state`). `ScriptInterpreter` keeps `#load`/`#ai`/`#echo` only.

**Lua = all of AlterAeon:**
- `Scripts/AlterAeon.lua` — KXWT parsing (triggers with capture groups → Lua state tables),
  the state machine, recovery logic, `state`/`recover` aliases.
- `Scripts/AIPilot.lua` — the pilot: prompt, transcript, debounce + staleness, turn builder,
  reply parsing, loop/grace/self-attribution, channel/spell/inventory rules, map + persistence.

## New Swift primitives (the last compile for a while)

All three take a Lua function as a callback and invoke it **under the engine lock** (the engine
already does this for trigger handlers via `LuaFunctionRef`; `NSRecursiveLock` makes re-entrancy
safe). No concurrency is exposed to scripts.

| Builtin | Signature | Notes |
|---|---|---|
| `ai_request` | `ai_request(system, user, max_tokens, cb)` | URLSession async on a Task; on completion `cb(reply, err)`. Endpoint/model from env (`LMSTUDIO_BASE_URL`/`LMSTUDIO_MODEL`), model auto-discovered. |
| `after` | `after(seconds, cb)` | one-shot timer via `asyncAfter`; fires `cb()`. Debounce = Lua compares a generation counter it owns. |
| `on_user_input` | engine calls a Lua global `on_user_input(cmd)` for each typed command | **non-swallowing** observation (aliases still swallow separately). Lets the pilot see human input. |

Engine adds one helper: `fire(_ ref: LuaFunctionRef, _ args:)` — lock, call, unlock — used by the
two async builtins.

## How AlterAeon state works in Lua (replacing KXWTHost)

KXWT lines already reach Lua through triggers, and triggers pass **regex capture groups** to the
handler. So the swift-parsing DSL becomes trigger-regex + Lua handlers writing to a `state` table:

```lua
trigger("^kxwt_prompt (%d+) (%d+) (%d+) (%d+) (%d+) (%d+)$", function(_, chp,mhp,cm,mm,cs,ms)
  state.hp, state.maxhp = tonumber(chp), tonumber(mhp) -- etc.
end)
trigger("^kxwt_rvnum (-?%d+) %d+ %d+ (-?%d+) (-?%d+) (-?%d+) (%d+)$", function(_, vnum,x,y,z,plane) ... end)
trigger("^kxwt_rshort (.+)$",  function(_, name) ... end)
trigger("^kxwt_fighting (.+)$", function(_, f) ... end)
trigger("^kxwt_supported$",     function() send("set kxwt") end)
gag("^kxwt_")
```

(Trigger patterns are Swift regex, not Lua patterns — same as today. `state` is a Lua table the
pilot reads for its state block and `in_combat` check.)

The map (rooms/coords/exits/learned direction deltas) is built the same way from
`kxwt_rvnum`/`rshort`/`walkdir` + `[Exits:]` lines, and persisted with Lua `io` to
`~/Documents/MudClient/explored.json` (path via `os.getenv("HOME")`). Trace logging (`ai-traces.jsonl`)
also becomes Lua `io`.

## Controls

`#ai <args>` routes to a Lua global `ai_command(args)` (on/off/once/reload/status/goal/tell/model/
url/trace). `#ai reload` re-runs the scripts (engine `clearRules()` first, already exists).

## Migration order
1. **Swift, one compile:** add `ai_request`, `after`, `on_user_input` + the `fire` helper. Leave
   `AIPilotService`/`KXWTHost` in place so nothing breaks yet.
2. **Lua:** port KXWT parsing + state + recovery into `AlterAeon.lua`; port the pilot into
   `AIPilot.lua`; wire `#ai` → `ai_command`.
3. **Delete** `AIPilotService.swift`, `KXWTHost.swift`, the `kxwt`/`recover`/`dump_state` builtins,
   and the pilot taps in `ScriptInterpreter`. Update `MudClient.swift` to `#load {AlterAeon}` +
   `#load {AIPilot}`.
4. Verify: build, run, sanity-check a live session.

## Tradeoffs / risks (accepted)
- KXWT parsing moves from the robust swift-parsing DSL to trigger-regex + Lua. Less elegant for
  byte-level parsing, but hot-reloadable and keeps Swift game-free — the point of B.
- A catch-all `trigger(".*", ...)` feeds the transcript; cheap, but it runs per line.
- Async `ai_request`/`after` callbacks run under the engine lock; long Lua work would stall input.
  Keep handlers light (they already are).
- Existing tests for `KXWTHost`/MSP stay; add coverage for the new builtins. The Lua behavior is
  validated live (hot-reload makes that fast).
