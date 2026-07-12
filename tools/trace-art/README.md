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

## Prompt path
If `ANTHROPIC_API_KEY` is in the environment, `generate.py` asks Claude
(`$TRACE_ART_MODEL`, default `claude-sonnet-5`) to write a cinematic prompt.
Otherwise it uses a built-in template. Both degrade gracefully — a 4 AM headless
run never hard-fails on a missing key or a down ComfyUI.

## Manual use
```
python3 generate.py --init      # (re)set cursor to current EOF; render nothing
python3 generate.py             # normal incremental run
python3 generate.py --dry-run   # detect + build prompt, no image
python3 generate.py --smoke     # render best moment from the file TAIL (ignores cursor)
```

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
