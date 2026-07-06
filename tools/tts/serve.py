#!/usr/bin/env python
# serve.py — a thin HTTP wrapper around mlx-audio's Kokoro pipeline.
#
# Why our own wrapper instead of `python -m mlx_audio.server`? That built-in server pulls in fastrtc +
# STT + VAD on import (seconds of startup, extra memory we don't need for a play-only client) and uses a
# two-step API (POST /tts -> {filename}, then GET /audio/<filename>). We only ever synthesize English
# chat lines and play them, so we expose ONE request that returns the WAV bytes directly:
#
#   POST /v1/audio/speech   (OpenAI-compatible)  body: {"input": "...", "voice": "af_heart", "speed": 1.0}
#        -> audio/wav bytes
#   GET  /v1/voices        -> {"voices": ["af_heart", ...]}   (from the local weights dir)
#   GET  /health           -> {"ok": true, "model": "...", "voices": N}
#
# The Kokoro model is loaded ONCE at startup from the local weights path (no network, no LM Studio).
# English grapheme->phoneme is handled by misaki (+ spacy en_core_web_sm), so espeak-ng is NOT required.

import argparse
import glob
import io
import os
import threading
import time

import numpy as np
import soundfile as sf
import uvicorn
from fastapi import FastAPI, Response
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from mlx_audio.tts.utils import load_model

DEFAULT_MODEL = os.path.expanduser("~/.lmstudio/models/mlx-community/Kokoro-82M-bf16")

app = FastAPI()
_model = None
_model_path = None
_voices: list[str] = []
# MLX evaluates on a shared Metal command queue that is NOT safe to drive from two threads at once —
# FastAPI runs sync endpoints in a threadpool, so overlapping requests would race the single Kokoro
# model and abort the process in mlx::core::gpu::check_error (a Metal command-buffer error). Serialize
# every generation behind one lock; the client (SpeechService) is already serial, this just makes the
# server robust to a stray concurrent probe.
_gen_lock = threading.Lock()


def _discover_voices(path: str) -> list[str]:
    """The Kokoro voice ids are the .pt/.safetensors basenames next to the weights (af_heart, am_adam…)."""
    names = set()
    for pat in ("*.pt", "*.safetensors"):
        for f in glob.glob(os.path.join(path, pat)):
            base = os.path.splitext(os.path.basename(f))[0]
            # Skip the model weight file itself (kokoro-v1_0.safetensors) — voices are ll_name.
            if base.startswith("kokoro"):
                continue
            names.add(base)
    return sorted(names)


class SpeechRequest(BaseModel):
    input: str = ""
    text: str | None = None          # allow either OpenAI `input` or a bare `text`
    voice: str = "af_heart"
    speed: float = 1.0
    lang_code: str = "a"             # 'a' = American English
    response_format: str | None = None
    model: str | None = None


def _synthesize(text: str, voice: str, speed: float, lang_code: str) -> bytes:
    with _gen_lock:   # one MLX/Metal generation at a time — see _gen_lock note above
        segs = list(_model.generate(text=text, voice=voice, speed=speed, lang_code=lang_code, verbose=False))
        if not segs:
            raise ValueError("no audio generated")
        audio = np.concatenate([s.audio for s in segs], axis=0)
    buf = io.BytesIO()
    sf.write(buf, audio, 24000, format="WAV", subtype="PCM_16")
    return buf.getvalue()


@app.post("/v1/audio/speech")
def speech(req: SpeechRequest):
    text = (req.input or req.text or "").strip()
    if not text:
        return JSONResponse({"error": "empty input"}, status_code=400)
    voice = req.voice if (req.voice and req.voice.strip()) else "af_heart"
    try:
        t0 = time.time()
        wav = _synthesize(text, voice, req.speed, (req.lang_code or "a"))
        dt = time.time() - t0
        return Response(content=wav, media_type="audio/wav",
                        headers={"X-Gen-Seconds": f"{dt:.3f}", "X-Voice": voice})
    except Exception as e:  # noqa: BLE001 — surface any synth error to the client as 500
        return JSONResponse({"error": str(e)}, status_code=500)


# Alias so the OpenAI route and a bare /tts both work.
@app.post("/tts")
def tts(req: SpeechRequest):
    return speech(req)


@app.get("/v1/voices")
def voices():
    return {"voices": _voices}


@app.get("/health")
def health():
    return {"ok": _model is not None, "model": _model_path, "voices": len(_voices)}


def main():
    global _model, _model_path, _voices
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8880)
    ap.add_argument("--model", default=os.environ.get("KOKORO_MODEL", DEFAULT_MODEL))
    args = ap.parse_args()

    _model_path = args.model
    _voices = _discover_voices(args.model)
    print(f">> loading Kokoro from {args.model} ({len(_voices)} voices)", flush=True)
    t0 = time.time()
    _model = load_model(args.model)
    # Warm the English pipeline once so the FIRST real request isn't slow (spacy/misaki init).
    try:
        _synthesize("Ready.", "af_heart", 1.0, "a")
    except Exception as e:  # noqa: BLE001
        print(f"!! warmup failed (non-fatal): {e}", flush=True)
    print(f">> ready in {time.time()-t0:.1f}s — http://{args.host}:{args.port}/v1/audio/speech", flush=True)
    uvicorn.run(app, host=args.host, port=args.port, log_level="warning")


if __name__ == "__main__":
    main()
