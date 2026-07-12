# trace-art

Turns "iconic moments" from AlterAeon game traces into AI art (ComfyUI + Z-Image
Turbo), once a day at 04:00, **forward-only**: every run reads only the newly
appended lines of `human-traces.jsonl` and appends to an ever-growing gallery.
Old moments are never regenerated.

## Layout
- `generate.py` — the incremental generator (stdlib only).
- `run.sh` — launchd wrapper (sets PATH, picks python3).
- `com.mudclient.trace-art.plist` — launchd template (installed to `~/Library/LaunchAgents/`).

## Runtime data (not in the repo)
- `~/Documents/MudClient/trace-art/.cursor.json` — byte-offset cursor + size/inode.
- `~/Documents/MudClient/trace-art/images/` — generated PNGs.
- `~/Documents/MudClient/trace-art/gallery.jsonl` — one record per image (the moment list).
- `~/Library/Logs/mudclient-trace-art.log` — run log.

## Model / workflow settings (from the golden Z-Image Turbo template)
UNET `z_image_turbo_bf16.safetensors` · CLIP `qwen_3_4b.safetensors` type `lumina2`
· VAE `ae.safetensors` · ModelSamplingAuraFlow shift 3 · KSampler steps 8, cfg 1.0,
`res_multistep`/`simple`, denoise 1.0 · 1024x1024.

## Selection + prompt path (LOCAL LLM, no API key)
Both the ranking of candidate moments and the image-prompt writing are done by a
**local LM Studio** model (OpenAI-compatible, no auth), the AlterAeon-fine-tuned
Qwen. Config:
- `TRACE_ART_LLM_BASE` (default `http://localhost:1234/v1`)
- `TRACE_ART_MODEL` (default `qwen3.6-27b-alteraeon-mlx`)
- `TRACE_ART_PLAYER` (default `Vaelith`) — this character's own `(notify)` soulsteals are weighted highest, ordered by `freak` rarity.

Qwen3.6 "thinking" mode empties structured output, so it is disabled two ways
(empty `<think></think>` assistant prefill **and** `chat_template_kwargs.enable_thinking=false`)
and returned JSON is validated with one retry. Fallback order for prompt writing:
local LLM → Claude API (only if `ANTHROPIC_API_KEY` set, `$TRACE_ART_ANTHROPIC_MODEL`,
default `claude-sonnet-5`) → built-in heuristic template. Everything degrades
gracefully — a 4 AM run never hard-fails on a missing key, a down LM Studio, or a
down ComfyUI.

## Iconic-moment signals
`(notify)` brag-channel lines are treated as inherently high-value; the player's
own soulsteals rank highest, ordered by `freak N`. Also: heinous backstabs,
first-person soul-magic, player death, achievements/quests, level-ups, big kills
(scaled by xp), low-HP escapes. Each unique moment is generated **once** — traces
are sliding windows so one event recurs across many lines; a stable `moment_key`
dedupes them and is recorded in `gallery.jsonl` for resumable skip.

## Manual use
```
python3 generate.py --init          # (re)set cursor to current EOF; render nothing
python3 generate.py                 # normal FORWARD-ONLY incremental run (the daily job)
python3 generate.py --backfill      # one-time, resumable mine of the WHOLE history (default 25 imgs)
python3 generate.py --backfill --max 30
python3 generate.py --dry-run       # detect + rank + build prompt, no image
python3 generate.py --smoke         # render best moment from the file TAIL (ignores cursor)
python3 generate.py --pick-badass   # print the most "badass" of the last few images (iTerm2 wallpaper)
python3 generate.py --pick-badass --last 8
```

## iTerm2 wallpaper (while the client runs)
`just run` sets the iTerm2 terminal background to the most **badass** of the last few gallery
images while MudClient is running, and clears it on exit (that's why `just run` runs the app as a
child, not `exec` — so its EXIT trap fires). Two stages:

1. **pick** — `generate.py --pick-badass`: the local LM Studio model (same `TRACE_ART_LLM_BASE` /
   `TRACE_ART_MODEL` as everything here) judges the most epic moment from each image's **text**
   metadata — no vision model needed — with a heuristic fallback (your own steals > higher `freak` >
   higher level) when the model is down. Prints ONLY the chosen path to stdout (diagnostics → stderr).
2. **prep** — `prep-bg.swift <src> <out>`: iTerm2's `SetBackgroundImageFile` escape can only set the
   file, not the scaling mode or a blend, so we bake both into a copy. It sizes the output to **this
   terminal's pixel aspect** (queried via the `CSI 14t` escape; falls back to the main display, then
   the source size) and draws the square art aspect-**filled** — so it never stretches regardless of
   iTerm2's image mode — then composites a **semi-transparent black overlay** so text stays readable.

Tunables (env): `MUD_ART_BG_DIM` overlay blackness `0..1` (default `0.55`) · `MUD_ART_BG_FIT`
`cover` (fill+crop, default) or `contain` (letterbox) · `MUD_ART_BG_MAXPX` output long-side cap
(default `2560`) · `MUD_ART_BG_LAST` how many recent images the pick considers (default `5`).

It's a **no-op** outside iTerm2 (`$TERM_PROGRAM != iTerm.app`), when the gallery has no images yet,
or when `MUD_NO_ART_BG=1`; if `prep-bg.swift` fails for any reason it falls back to the raw square
image so the wallpaper still shows. **iTerm2 asks you to confirm** the background change (a security
measure baked into the `SetBackgroundImageFile` escape) — expect a prompt on set and on clear.
Resizing the window after launch can reintroduce stretch (the pre-fit aspect no longer matches) —
re-run `just run` to re-fit.

Manual one-liner (pick + prep + set):
```
img=$(python3 tools/trace-art/generate.py --pick-badass) && \
  out="${TMPDIR:-/tmp}/mudbg.png" && swift tools/trace-art/prep-bg.swift "$img" "$out" && \
  printf '\033]1337;SetBackgroundImageFile=%s\a' "$(printf %s "$out" | base64 | tr -d '\n')"
# clear:  printf '\033]1337;SetBackgroundImageFile=\a'
```
`--backfill` is a separate two-stage pass (cheap heuristic pre-filter over 277 MB,
then LLM ranks the top candidates and writes prompts). It does **not** touch the
daily cursor, so the 4 AM job stays forward-only. Re-running it resumes (skips
anything already in `gallery.jsonl`).

## Install the schedule
```
tools/trace-art/install.sh      # writes the plist, bootstraps the launchd job
```

## Disable the schedule (one-liner)
```
launchctl bootout gui/$(id -u)/com.mudclient.trace-art
```
Re-enable: `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.mudclient.trace-art.plist`
Remove entirely: `launchctl bootout ...` then `rm ~/Library/LaunchAgents/com.mudclient.trace-art.plist`.
