#!/usr/bin/env bash
#
# Invoked by the MUD client (AIPilotService) when the in-game AI pilot requests a
# persistent script change. The client sets these env vars and runs us via `sh -c`:
#   AI_SCRIPT_REQUEST  - plain-English description of the standing rule wanted
#   AI_SCRIPT_FILE     - path to the Lua script to edit (Scripts/AlterAeon.lua)
#
# We delegate the actual edit to a headless Claude Code session. On exit 0 the
# client hot-reloads the script. To enable, before `just run`:
#   export AI_SCRIPT_AGENT="$PWD/tools/ai-script-agent.sh"
#
set -euo pipefail

: "${AI_SCRIPT_REQUEST:?no request}" "${AI_SCRIPT_FILE:?no file}"

read -r -d '' PROMPT <<EOF || true
You maintain ${AI_SCRIPT_FILE}, the Lua script for an Alter Aeon MUD client.

The in-game AI pilot has requested this standing rule:
  "${AI_SCRIPT_REQUEST}"

Add or adjust ONLY trigger()/alias()/gag() declarations to satisfy it, using only the
existing host builtins: send, echo, kxwt, recover, dump_state. Match the file's existing
style, keep the change minimal, and do not touch unrelated lines.

IMPORTANT: only make a change if this is a genuinely RECURRING reflex (a pattern that
will happen many times with an always-identical response). If it reads like a one-off
event — a tutorial step, a unique quest line, a one-time message — make NO change and
explain why instead.
EOF

exec claude -p "$PROMPT" \
  --allowedTools "Read" "Edit" \
  --permission-mode acceptEdits
