#!/bin/bash
# Unattended overnight LoRA train + fuse for ONLY the 35B-A3B MoE ("fast") base, launched by the
# launchd agent com.mudclient.lora at 3 AM. Trains on the COMBINED dataset (data-combined/: cleaned +
# weighted combat demos + the general knowledge/non-combat set) and fuses into LM Studio's models tree.
#
# 35B-A3B MoE = fast (~1.2s turns, 2.7x decode). ~1.5-2 h. Self-disables the agent once the fused model
# exists; a failure leaves the agent scheduled to retry the next night.
#
# GPU hygiene: training needs the whole GPU, so we SNAPSHOT whatever models LM Studio has loaded (the
# game's brain/memory LLMs), unload everything before training, and RELOAD that exact set afterward.
# The reload runs from an EXIT trap so the game's models come back even if training fails.
set -uo pipefail

REPO="/Users/tylerthompson/workspace/MudClient"
VENV="$REPO/tools/finetune/.venv/bin"
FT="$REPO/tools/finetune"
LOG="$FT/scheduled-train.log"
DATA="$FT/data-combined"
LMS="$HOME/.lmstudio/bin/lms"
SNAP="$FT/loaded-before-train.json"
BASE="$HOME/.lmstudio/models/lmstudio-community/Qwen3.6-35B-A3B-MLX-4bit"
OUT="$HOME/.lmstudio/models/mudclient/Qwen3.6-35B-A3B-AlterAeon-MLX-4bit"
ADAPTERS="$FT/adapters-moe"

exec >>"$LOG" 2>&1
echo "================ 35B combat train start: $(date) ================"

# --- reload whatever we snapshotted; runs on ANY exit so the game's LLMs always come back ---
restore_models() {
  [ -s "$SNAP" ] || { echo "no snapshot to restore."; return 0; }
  echo "---- reloading previously-loaded models: $(date) ----"
  python3 - "$SNAP" "$LMS" <<'PY' | while IFS= read -r cmd; do echo "  + $cmd"; eval "$cmd"; done
import json, shlex, sys
snap, lms = sys.argv[1], sys.argv[2]
try:
    entries = json.load(open(snap))
except Exception as e:
    print(f"echo 'snapshot parse failed: {e}'"); sys.exit(0)
for e in entries or []:
    ref = e.get("modelKey") or e.get("path") or e.get("identifier")
    if not ref:
        continue
    parts = [shlex.quote(lms), "load", shlex.quote(ref), "-y", "--gpu", "max"]
    ident = e.get("identifier")
    if ident and ident != ref:
        parts += ["--identifier", shlex.quote(ident)]
    ctx = e.get("contextLength") or e.get("maxContextLength")
    if ctx:
        parts += ["-c", str(int(ctx))]
    print(" ".join(parts))
PY
}
trap restore_models EXIT

if [ -d "$OUT" ]; then
  echo "fused model already exists ($OUT) — nothing to do; disabling agent."
  launchctl bootout "gui/$(id -u)/com.mudclient.lora" 2>/dev/null || true
  exit 0
fi
if [ ! -f "$DATA/train.jsonl" ]; then
  echo "!!! missing $DATA/train.jsonl — run build_combined.py first. Leaving agent to retry."
  exit 1
fi

# Snapshot currently-loaded models, then free the GPU for training.
echo "---- snapshotting loaded models -> $SNAP : $(date) ----"
"$LMS" ps --json > "$SNAP" 2>/dev/null || echo "[]" > "$SNAP"
echo "snapshot: $(cat "$SNAP")"
"$LMS" unload --all 2>/dev/null || true
sleep 3

echo "---- training on $DATA : $(date) ----"
rm -rf "$ADAPTERS"; mkdir -p "$ADAPTERS"
"$VENV/mlx_lm.lora" \
  --model "$BASE" --train --data "$DATA" \
  --batch-size 1 --num-layers 16 --iters 600 \
  --max-seq-length 2048 --grad-checkpoint \
  --steps-per-report 10 --steps-per-eval 200 --save-every 100 \
  --adapter-path "$ADAPTERS"
rc=$?
if [ $rc -ne 0 ]; then
  echo "!!! training exited $rc — skipping fuse. Leaving agent to retry. $(date)"
  exit $rc   # trap reloads the game's models
fi

echo "---- fusing -> $OUT : $(date) ----"
mkdir -p "$(dirname "$OUT")"
"$VENV/mlx_lm.fuse" --model "$BASE" --adapter-path "$ADAPTERS" --save-path "$OUT"
rc=$?
if [ $rc -ne 0 ]; then
  echo "!!! fuse exited $rc — leaving agent to retry. $(date)"
  exit $rc   # trap reloads the game's models
fi

echo "================ 35B combat train finished: $(date) ================"
echo "Restart LM Studio to index, then load: $OUT"
echo "Serve tuned with: tools/finetune/serve.sh <model-key from 'lms ls'>"

# One-shot: disable the agent now that the fused model exists (trap still reloads on the way out).
echo "fused model present — disabling agent."
launchctl bootout "gui/$(id -u)/com.mudclient.lora" 2>/dev/null || true
