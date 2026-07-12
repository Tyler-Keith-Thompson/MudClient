#!/bin/bash
# Wrapper invoked by launchd (com.mudclient.trace-art) once a day at 04:00.
# Self-contained: sets PATH, picks a python, runs the incremental generator.
# All stdout/stderr is captured by launchd into ~/Library/Logs/mudclient-trace-art.log
set -u

export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GEN="$SCRIPT_DIR/generate.py"

# Prefer system python3 (3.13); it only needs the stdlib.
PY="$(command -v python3 || echo /opt/homebrew/bin/python3)"

echo "=== trace-art run $(date) (py=$PY) ==="
exec "$PY" "$GEN" "$@"
