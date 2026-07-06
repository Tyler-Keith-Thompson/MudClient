#!/bin/bash
# serve.sh — start the local Kokoro TTS server (mlx-audio) for the MudClient speech backend.
#
# Serves the LOCAL Kokoro weights (no network, independent of LM Studio on :1234) on port 8880:
#   POST http://127.0.0.1:8880/v1/audio/speech   {"input": "...", "voice": "af_heart"} -> WAV bytes
#   GET  http://127.0.0.1:8880/v1/voices          -> voice list
#   GET  http://127.0.0.1:8880/health             -> readiness
#
# Resilience: MLX/Metal can occasionally abort a Python process (a command-buffer error). We serialize
# generation in serve.py to avoid the common (concurrency) cause, but as a belt-and-braces measure this
# wrapper RESTARTS the server on an unexpected exit (bounded retries) and tees all output to server.log,
# so one crash doesn't silently kill speech for the whole session. The Swift client also falls back to
# `say` for any request that hits a dead/restarting server, so a blip is at worst a few say-voiced lines.
#
# Usage:
#   tools/tts/serve.sh                 # foreground, auto-restarting (Ctrl-C to stop)
#   PORT=8880 tools/tts/serve.sh       # override port
#   KOKORO_MODEL=/path tools/tts/serve.sh
set -uo pipefail
cd "$(dirname "$0")"

if [ ! -x .venv/bin/python ]; then
  echo "!! .venv missing — run tools/tts/setup.sh first" >&2
  exit 1
fi

PORT="${PORT:-8880}"
LOG="$(pwd)/server.log"
MAX_RESTARTS="${MAX_RESTARTS:-10}"

# Clean shutdown on Ctrl-C: don't let the trap re-launch.
STOP=0
trap 'STOP=1' INT TERM

echo "$(date '+%F %T') === serve.sh starting on :$PORT (logging to $LOG) ===" | tee -a "$LOG"
n=0
while [ "$STOP" -eq 0 ]; do
  # `exec`-free so we keep the supervisor loop; tee to console + server.log.
  ./.venv/bin/python serve.py --host 127.0.0.1 --port "$PORT" 2>&1 | tee -a "$LOG"
  rc=${PIPESTATUS[0]}
  [ "$STOP" -eq 1 ] && break
  n=$((n + 1))
  if [ "$n" -gt "$MAX_RESTARTS" ]; then
    echo "$(date '+%F %T') !! server exited (rc=$rc); $n restarts exhausted — giving up" | tee -a "$LOG"
    exit 1
  fi
  echo "$(date '+%F %T') !! server exited (rc=$rc); restart $n/$MAX_RESTARTS in 2s" | tee -a "$LOG"
  sleep 2
done
echo "$(date '+%F %T') === serve.sh stopped ===" | tee -a "$LOG"
