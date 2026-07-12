#!/bin/bash
# Install (or reinstall) the trace-art launchd job. Idempotent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.mudclient.trace-art"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/mudclient-trace-art.log"
RUN_SH="$SCRIPT_DIR/run.sh"

chmod +x "$SCRIPT_DIR/run.sh" "$SCRIPT_DIR/generate.py"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"

sed -e "s#__RUN_SH__#$RUN_SH#g" -e "s#__LOG__#$LOG#g" \
    "$SCRIPT_DIR/$LABEL.plist" > "$PLIST_DST"

# Ensure the cursor starts at EOF so the backlog is not bulk-rendered.
if [ ! -f "$HOME/Documents/MudClient/trace-art/.cursor.json" ]; then
    "$(command -v python3)" "$SCRIPT_DIR/generate.py" --init
fi

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"
echo "installed and bootstrapped $LABEL"
launchctl print "gui/$(id -u)/$LABEL" | grep -E "state|program|Hour|Minute" || true
