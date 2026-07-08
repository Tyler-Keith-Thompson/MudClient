#!/bin/bash
# One-shot LoRA train + fuse for the 27B DENSE ("smart") base on the COMBINED dataset
# (data-combined/: cleaned + weighted combat demos + general knowledge). Sibling of run_train_35b.sh.
#
# WHY THIS EXISTS: the 35B-A3B MoE base OOMs on its first backward pass under mlx (gradients across the
# quantized expert stack) regardless of --num-layers / --max-seq / wired-limit. The dense 27B has no
# expert explosion and trained+fused cleanly before, so it's the reliable path to a trained combat LoRA.
# This script does NOT touch the launchd agent (that stays pointed at the MoE run); it just produces the
# dense fused model.
#
# GPU hygiene identical to run_train_35b.sh: snapshot LM Studio's loaded models, unload, restore on EXIT.
set -uo pipefail

REPO="/Users/tylerthompson/workspace/MudClient"
VENV="$REPO/tools/finetune/.venv/bin"
FT="$REPO/tools/finetune"
LOG="$FT/scheduled-train.log"
DATA="$FT/data-combined-short"
LMS="$HOME/.lmstudio/bin/lms"
SNAP="$FT/loaded-before-train.json"
BASE="$HOME/.lmstudio/models/lmstudio-community/Qwen3.6-27B-MLX-4bit"
OUT="$HOME/.lmstudio/models/mudclient/Qwen3.6-27B-AlterAeon-MLX-4bit"
ADAPTERS="$FT/adapters-dense"

exec >>"$LOG" 2>&1
echo "================ 27B dense combat train start: $(date) ================"

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
  echo "fused dense model already exists ($OUT) — nothing to do."
  exit 0
fi
if [ ! -f "$DATA/train.jsonl" ]; then
  echo "!!! missing $DATA/train.jsonl — run build_combined.py first."
  exit 1
fi

# Snapshot currently-loaded models, then free the GPU for training.
echo "---- snapshotting loaded models -> $SNAP : $(date) ----"
"$LMS" ps --json > "$SNAP" 2>/dev/null || echo "[]" > "$SNAP"
echo "snapshot: $(cat "$SNAP")"
"$LMS" unload --all 2>/dev/null || true
# Wait for Metal to ACTUALLY release the unloaded models' wired memory before training. A fixed
# `sleep 3` isn't enough — freeing tens of GB of wired GPU memory takes longer, and starting training
# against a still-occupied GPU causes a first-backward-pass Metal command-buffer OOM (the 2026-07-05
# dense failure: 36 GB of LLMs hadn't freed, backward pass OOM'd, validation ran at 231s vs ~50s clean).
for _ in $(seq 1 30); do
  [ -z "$("$LMS" ps 2>/dev/null | grep -iE 'LOADED|IDLE')" ] && break
  sleep 2
done
sleep 3

echo "---- training (dense) on $DATA : $(date) ----"
# num-layers 16 = the proven-stable dense config (~24 GB peak); dense has no MoE expert explosion.
# max-seq 2304 matches the trimmed data (labels intact). 112 GB wired limit gives ample headroom.
rm -rf "$ADAPTERS"; mkdir -p "$ADAPTERS"
"$VENV/mlx_lm.lora" \
  --model "$BASE" --train --data "$DATA" \
  --batch-size 1 --num-layers 16 --iters 600 \
  --max-seq-length 1024 --grad-checkpoint \
  --steps-per-report 10 --steps-per-eval 200 --save-every 100 \
  --adapter-path "$ADAPTERS"
rc=$?
if [ $rc -ne 0 ]; then
  echo "!!! dense training exited $rc — skipping fuse. $(date)"
  exit $rc   # trap reloads the game's models
fi

echo "---- fusing (dense) -> $OUT : $(date) ----"
mkdir -p "$(dirname "$OUT")"
"$VENV/mlx_lm.fuse" --model "$BASE" --adapter-path "$ADAPTERS" --save-path "$OUT"
rc=$?
if [ $rc -ne 0 ]; then
  echo "!!! dense fuse exited $rc. $(date)"
  exit $rc   # trap reloads the game's models
fi

echo "================ 27B dense combat train finished: $(date) ================"
echo "Restart LM Studio to index, then load: $OUT"
echo "Serve tuned with: tools/finetune/serve.sh <model-key from 'lms ls'>"
