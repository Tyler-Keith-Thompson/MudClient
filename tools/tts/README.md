# tools/tts — local Kokoro TTS server

The primary speech backend for MudClient's per-speaker chat TTS (Scripts/Speech.lua +
Sources/MudClient/SpeechService.swift). Serves the **Kokoro-82M** voice model locally via the MLX
ecosystem (mlx-audio), independent of LM Studio. macOS `say` is the automatic fallback whenever this
server is unreachable.

## Setup (once)

```
tools/tts/setup.sh
```

Creates `.venv` (Python 3.12; gitignored) and installs `mlx-audio` + `fastapi`/`uvicorn`/`soundfile`
and `misaki[en]`. English grapheme-to-phoneme is handled by **misaki** (it auto-downloads a small spaCy
model on first run) — **espeak-ng is NOT required**. If a future non-English voice ever needs it, the
server logs a clear message; install with `brew install espeak-ng`.

The Kokoro weights are read from `~/.lmstudio/models/mlx-community/Kokoro-82M-bf16` (already on disk).
Override with `KOKORO_MODEL=/path tools/tts/serve.sh`.

## Run

```
tools/tts/serve.sh                 # foreground, auto-restarting (Ctrl-C to stop)
PORT=8880 tools/tts/serve.sh       # override port (default 8880 — NOT LM Studio's 1234)
```

`serve.sh` supervises the Python process: it tees all output to `server.log` and **auto-restarts** on an
unexpected exit (bounded retries), so a rare MLX/Metal blip doesn't kill speech for the whole session.

Leave it running in a terminal (or `nohup tools/tts/serve.sh >/dev/null 2>&1 &`). Check readiness:

```
curl -s localhost:8880/health          # {"ok":true,"model":"…","voices":54}
```

## HTTP API (`serve.py`)

One request per utterance — returns the WAV bytes directly (no two-step filename dance):

| method + route            | body / result                                                        |
|---------------------------|----------------------------------------------------------------------|
| `POST /v1/audio/speech`   | `{"input":"…","voice":"af_heart","speed":1.0}` → `audio/wav` bytes (OpenAI-compatible; `/tts` is an alias) |
| `GET /v1/voices`          | `{"voices":["af_heart","am_adam",…]}` (54 ids from the weights dir)  |
| `GET /health`             | `{"ok":true,"model":"…","voices":N}`                                 |

Response header `X-Gen-Seconds` reports raw synth time. Voice ids: `af_/bf_` = female, `am_/bm_` = male;
first letter `a` = American English, `b` = British English (other languages exist but Speech.lua filters
to English).

### Why our own `serve.py` instead of `python -m mlx_audio.server`?

mlx-audio's built-in server pulls in fastrtc + STT + VAD on import (slow startup, extra memory we don't
need for a play-only client) and uses a two-step API. `serve.py` loads only the Kokoro TTS pipeline once
and returns WAV bytes in a single request.

### Concurrency note (the fix for the early crash)

MLX evaluates on a shared Metal command queue that is **not** safe to drive from two threads at once —
overlapping requests abort the process in `mlx::core::gpu::check_error` (a Metal command-buffer error).
`serve.py` serializes every generation behind one lock (`_gen_lock`), so a stray concurrent request can't
crash it. The Swift client is already serial; the lock is belt-and-braces.
