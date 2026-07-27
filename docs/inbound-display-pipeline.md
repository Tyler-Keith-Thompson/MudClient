# Inbound display pipeline: server bytes → rendered screen

**This is the authoritative map of how a byte from the socket becomes a character on screen.** When a display
bug is reported — a blank line, colour bleed, leaked telemetry, a flicker, a merged line — the cause is one of
the stages below, and (almost always) the **display-editing** stage (`#gag`/`#suppress`/`#replace`/`#substitute`).
Read this before theorising. Don't argue with the user about whether it's a "client bug" — it's a client bug;
this is the client.

## The chain (one line)

```
socket → captureRaw → handleIACCommunication → normalizeLineEndings → filterServerStream → processMSP → processServerOutputForScripts → [consumer] → TerminalService.render
```

Both transports use the SAME chain: `ServerTextFeed.swift` (1.105 single-socket RPC) and `Connection.swift`
(telnet) each build it; the consumer is `ConnectionManager.pumpTask` (`for try await string in conn { … render }`).

## Stage by stage (file · function · what it does · what it must NOT do)

1. **Transport** — `ServerTextFeed` / `Connection`. Raw bytes off the socket, chunked exactly as they arrive.
   Chunk boundaries are arbitrary and load-bearing: a single logical line (or a telemetry frame) is routinely
   split across chunks, and idle telemetry ticks arrive seconds apart. Never assume a chunk is a whole line.

2. **captureRaw** — `RawCapture.swift · captureRaw()`. Tees every chunk to `mud_raw.log` as
   `HH:MM:SS.mmm <base64>` (one line per chunk; timestamped so inter-chunk timing is legible — see
   [raw-log-format]). Pure debug tap; passes the chunk through unchanged. On by default; `MUD_RAW_LOG=off` disables.

3. **handleIACCommunication** — `IAC.swift`. Telnet IAC negotiation; a GA (go-ahead) becomes the U+E000 marker
   downstream. MCCP (85/86) is deliberately not negotiable.

4. **normalizeLineEndings** — `RawCapture.swift · LineEndingNormalizer`. CRLF / lone-CR / LF → a single `\n`,
   statefully across chunk boundaries (a CRLF split across two reads becomes one `\n`, not two). Everything
   downstream may assume `\n`-only.

5. **filterServerStream** — `ScriptInterpreter.swift · filterServerStream()` → `engine.filterStream()` → the Lua
   `on_stream` hook (`dclient_feed` in `AlterAeon/DClientProbe.tl`). PEELS the in-band RPC frames
   `;s<tag>;…;e<tag>;` (sgroup / smap / …) and passes everything else **UNCHANGED — no newline munging, no
   reordering**. A fully-peeled chunk collapses to `""`. (Historically, adding/removing newlines here invented
   blanks and merged lines — don't.)

6. **processMSP** — `MSP.swift · processMSP()`. Strips MSP `!!SOUND(…)` tags out of the display stream.

7. **processServerOutputForScripts** — `ScriptInterpreter.swift`. **THE display-editing stage.** Everything about
   blanks / gagging / colour / flicker lives here. Per chunk, in order:
   - **skip empty**: a fully-peeled chunk (`""`) is skipped WITHOUT touching cross-chunk state (else it resets
     the flags below and orphaned newlines leak as blanks).
   - **`lastPartialGagged`**: the RPC frames an idle tick as `"\nkxwq_prompt X"` — leading `\n`, no trailing one;
     that `\n` is the *terminator of the previous* hidden partial. When the previous chunk ended in a gagged
     (or rule-deleted) partial, drop this chunk's leading empty segment so it doesn't paint a blank.
   - **Stage 1 — per line** (`engine.processLine`): fires TRIGGERS (parsing/observers) and applies **single-line
     gags**. Gags are matched against the **ANSI-STRIPPED** text (`clean`). A gagged line is dropped from display
     but its zero-width ANSI is CARRIED FORWARD (`ansiCarry`) onto the next shown line — so a colour reset the
     server glues to a hidden line still lands (no bleed). Builds `processed` (this chunk's display text).
   - **Stage 2 — buffer rules** (`BufferRewriteFilter`): the MULTI-line display-edit rules. Applies each
     `regex → replacement` to a rolling window (`shown` = last few displayed lines, PERSISTED across chunks so a
     match has its cross-chunk context). Shows optimistically and, when a match completes chunks later,
     returns `(retract, emit)` — `retract` un-prints already-shown lines (via `TerminalService.retract` +
     `TranscriptStore.retractReceived`). `droppedTrailingPartial` flags a rule-deleted trailing partial so its
     orphaned newline (arriving next chunk) is dropped like a gagged partial's.
   - **record**: the displayed lines go to `TranscriptStore` (`recordReceived` / `retractReceived`). **The
     transcript IS the on-screen text** (`received` − retracted) — it's the display oracle for tests/debugging.

8. **Consumer** — `ConnectionManager.pumpTask`. For each emitted string: `engine.notifyUpdate()` (repaint panels
   from the `state` triggers filled), `sessionLog.logServer(...)`, `TerminalService.render(...)`.

9. **TerminalService.render** — `TerminalService.swift`. Appends to `scrollbackLines` and paints. `retract(n)`
   un-prints the last `n` completed lines and repaints the region.

## The display-edit 2×2 (where display bugs live)

All four are `regex → replacement`, registered by `LuaScriptEngine.registerDisplayRule`, listed by a bare
`#gag` / `#suppress` / `#replace` / `#substitute`, removed by `#un…`. Group `display` in `#help`.

| command | match style | action | runs in |
|---|---|---|---|
| `#gag` | line-oriented | DELETE the whole matched line(s) | stage 1 (single-line) / stage 2 (multi-line) |
| `#suppress` | char-exact | DELETE exactly what matched | stage 2 |
| `#replace` | line-oriented | put text back | stage 2 |
| `#substitute` | char-exact | put text back | stage 2 |

**Patterns are ANSI-FREE.** They never mention `\x1b`. The engine strips ANSI before matching (delete rules use
`BufferRewriteFilter.deleteMatchingVisible` — match the visible text, remove only the matched visible scalars,
KEEP every ANSI code). "Suppression passes ANSI through": a colour reset in a deleted span survives, so colour
never bleeds. If you ever find `\x1b` in a gag/suppress pattern, that's the bug — fix the engine, not the pattern.

**The AlterAeon telemetry defaults** (`AlterAeon/AlterAeon.tl`): `gag([[^kxw[tq]_(?!hud)]])` hides every
telemetry tag EXCEPT `kxwq_hud`; `suppress([[(?:\nkxw[tq]_hud[^\n]*)+]])` collapses the hud vitals bar + its
framing blank. The `(?!hud)` scope is deliberate: hud must reach the stage-2 buffer rule (a per-line gag would
orphan its framing blank). The Swift side has ZERO game-specific strings — grep `Sources/MudClient` for `kxwq`
and you get nothing; the rules are 100% Lua.

## How to debug a display bug (do THIS, not a sim)

1. **Believe the report.** "Blanks stream in then get retracted", "the prompt carries the reset", "it's `#gag`"
   — the user is looking at the screen; that's ground truth. Reproduce it, don't argue it.
2. **Replay the ACTUAL `mud_raw.log`** through the REAL pipeline — never a hand-rolled re-implementation (a sim
   that skips empty chunks or ignores retract/ANSI will confidently tell you the wrong thing; that is exactly
   how the multi-hour argument happened). The transcript is the display oracle.
3. **The gate:** `Tests/MudClientTests/BufferRewriteFilterTests.swift · fullDisplayFromRealCapture` replays a real
   captured fight through the whole chain and asserts on the FINAL display: no telemetry leak, no blank stream,
   no churn (`TranscriptStore.totalRetracted`). Add your capture to it. See memory
   `display-pipeline-debugging-discipline`.
