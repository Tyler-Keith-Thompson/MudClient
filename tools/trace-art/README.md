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
