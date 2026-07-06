#!/bin/bash
# setup.sh — create a Python venv and install mlx-audio for the Kokoro TTS server.
#
# Mirrors tools/finetune conventions: a local .venv (gitignored), pinned deps, Apple-Silicon MLX.
# Kokoro's English G2P is handled by misaki[en], which ships its own data — NO espeak-ng needed for
# English. (Other languages would need espeak; we only speak English chat, so we skip that brew dep.)
#
# Usage:  tools/tts/setup.sh
set -euo pipefail
cd "$(dirname "$0")"

# Kokoro / mlx-audio wants a Python the MLX wheels target. 3.12 is the safe daily driver here.
PY="${TTS_PYTHON:-/opt/homebrew/bin/python3.12}"
if [ ! -x "$PY" ]; then
  echo "!! $PY not found. Install it (brew install python@3.12) or set TTS_PYTHON=/path/to/python3.x" >&2
  exit 1
fi

if [ ! -d .venv ]; then
  echo ">> creating .venv ($("$PY" --version))"
  "$PY" -m venv .venv
fi

echo ">> installing mlx-audio (+ server extras) into .venv"
./.venv/bin/pip install --upgrade pip >/dev/null
# Pin mlx-audio to a known-good release; fastapi/uvicorn back its HTTP server; soundfile for WAV I/O.
./.venv/bin/pip install "mlx-audio==0.2.4" "fastapi>=0.110" "uvicorn>=0.27" "soundfile>=0.12"

# misaki[en] provides English grapheme->phoneme WITHOUT espeak. Install it explicitly so a thin
# mlx-audio wheel still has en G2P. If it (or Kokoro) ever falls back to espeak, the server logs a
# clear "espeak-ng not found" — install with: brew install espeak-ng
./.venv/bin/pip install "misaki[en]>=0.9.4" || {
  echo "!! misaki[en] install failed — English G2P may fall back to espeak-ng." >&2
  echo "   If the server complains about espeak, run: brew install espeak-ng" >&2
}

echo ">> done. Start the server with: tools/tts/serve.sh"
