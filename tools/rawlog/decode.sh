#!/usr/bin/env bash
# Decode MudClient's raw capture log (mud_raw.log) to readable text.
#
# FORMAT (the thing that trips everyone up): each line is
#     <HH:MM:SS.mmm> <base64>
# where the base64 encodes a CHUNK of raw server bytes — often several \r\n-separated game lines at once.
# THE GOTCHA: the timestamp prefix is NOT part of the base64. Feeding the whole line to `base64 -d` yields
# garbage (this is the mistake that keeps happening). This script splits the prefix off, base64-decodes the
# rest, splits the decoded chunk back into game lines, and re-attaches the timestamp to each.
#
# By default it strips ANSI colour codes and kxwt_/kxwq_ protocol telemetry, so you read what a human saw.
#
# Usage:
#   tools/rawlog/decode.sh [FILE] [--ansi] [--telemetry] [-g PATTERN]
#     FILE         raw log (default: ./mud_raw.log, then ~/Documents/MudClient/mud_raw.log)
#     --ansi       keep ANSI colour codes (default: strip)
#     --telemetry  keep kxwt_/kxwq_ protocol lines (default: strip)
#     -g PATTERN   only print decoded lines matching PATTERN (case-insensitive extended regex)
#
# Examples:
#   tools/rawlog/decode.sh                       # whole current buffer, human-readable
#   tools/rawlog/decode.sh -g 'archery|points'   # just the archery contest lines
#   tools/rawlog/decode.sh /tmp/raw_now.log --telemetry -g '^kxwq_group'
set -uo pipefail

file=""; keep_ansi=0; keep_tel=0; pat=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ansi)      keep_ansi=1 ;;
    --telemetry) keep_tel=1 ;;
    -g)          shift; pat="${1:-}" ;;
    -h|--help)   sed -n '2,26p' "$0"; exit 0 ;;
    -*)          echo "unknown option: $1" >&2; exit 2 ;;
    *)           file="$1" ;;
  esac
  shift
done
if [ -z "$file" ]; then
  for c in ./mud_raw.log "$HOME/Documents/MudClient/mud_raw.log"; do
    [ -f "$c" ] && file="$c" && break
  done
fi
[ -n "$file" ] && [ -f "$file" ] || { echo "raw log not found — pass FILE (looked for ./mud_raw.log, ~/Documents/MudClient/mud_raw.log)" >&2; exit 1; }

KEEP_ANSI=$keep_ansi KEEP_TEL=$keep_tel PAT="$pat" python3 - "$file" <<'PY'
import sys, os, re, base64
ansi      = re.compile(rb'\x1b\[[0-9;?]*[ -/]*[@-~]')
keep_ansi = os.environ.get("KEEP_ANSI") == "1"
keep_tel  = os.environ.get("KEEP_TEL")  == "1"
pat       = os.environ.get("PAT") or ""
rx        = re.compile(pat, re.I) if pat else None
with open(sys.argv[1], "rb") as f:
    for raw in f:
        raw = raw.rstrip(b"\n")
        if b" " not in raw:
            continue
        ts, b64 = raw.split(b" ", 1)          # split off the timestamp prefix — DO NOT decode it
        try:
            dec = base64.b64decode(b64.strip())
        except Exception:
            continue
        for line in dec.replace(b"\r", b"").split(b"\n"):
            if not keep_ansi:
                line = ansi.sub(b"", line)
            if not line.strip():
                continue
            if not keep_tel and (line.startswith(b"kxwt_") or line.startswith(b"kxwq_")):
                continue
            text = line.decode("utf-8", "replace")
            if rx and not rx.search(text):
                continue
            sys.stdout.write(ts.decode(errors="replace") + " " + text + "\n")
PY
