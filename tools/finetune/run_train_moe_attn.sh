#!/bin/bash
# Attention-only QLoRA train + fuse for the 35B-A3B MoE ("fast") base.
#
# This is a variant of run_train_35b.sh whose ONLY difference is that it drives
# mlx_lm.lora from tools/finetune/lora_moe.yaml (-c) instead of bare CLI flags.
# The config pins LoRA to attention/token-mixing projections ONLY and EXCLUDES
# the 256-expert MoE matrices (mlp.switch_mlp / shared_expert / gates). That is
# the fix for the first-backward-step Metal OOM the plain run hit 4x — see the
# long comment block in lora_moe.yaml for the full root-cause analysis.
#
# Everything else (model/data/paths, iters 600, batch 1, max-seq 2304,
# grad-checkpoint, num-layers 16, save/eval cadence) lives in the YAML so there
# are no CLI overrides to reason about. Launch this ONLY when the GPU is free.
#
# GPU hygiene mirrors run_train_35b.sh: snapshot loaded LM Studio models, unload,
# train, then reload the exact set from an EXIT trap so the game's LLMs return.
set -uo pipefail

REPO="/Users/tylerthompson/workspace/MudClient"
VENV="$REPO/tools/finetune/.venv/bin"
FT="$REPO/tools/finetune"
LOG="$FT/scheduled-train.log"
DATA="$FT/data-combined-short"
CONFIG="$FT/lora_moe.yaml"
LMS="$HOME/.lmstudio/bin/lms"
SNAP="$FT/loaded-before-train.json"
BASE="$HOME/.lmstudio/models/lmstudio-community/Qwen3.6-35B-A3B-MLX-4bit"
OUT="$HOME/.lmstudio/models/mudclient/Qwen3.6-35B-A3B-AlterAeon-MLX-4bit"
ADAPTERS="$FT/adapters-moe"

exec >>"$LOG" 2>&1
echo "================ 35B MoE attention-only train start: $(date) ================"

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
  echo "fused model already exists ($OUT) — nothing to do."
  exit 0
fi
if [ ! -f "$DATA/train.jsonl" ]; then
  echo "!!! missing $DATA/train.jsonl — run build_combined.py first."
  exit 1
fi
if [ ! -f "$CONFIG" ]; then
  echo "!!! missing $CONFIG — cannot run attention-only config."
  exit 1
fi

echo "---- snapshotting loaded models -> $SNAP : $(date) ----"
"$LMS" ps --json > "$SNAP" 2>/dev/null || echo "[]" > "$SNAP"
echo "snapshot: $(cat "$SNAP")"
"$LMS" unload --all 2>/dev/null || true
sleep 3

echo "---- training (attention-only LoRA, experts excluded) on $DATA : $(date) ----"
# All training params come from lora_moe.yaml (model/data/paths/iters/batch/
# max-seq/grad-checkpoint/num-layers AND the attention-only lora_parameters.keys).
rm -rf "$ADAPTERS"; mkdir -p "$ADAPTERS"
"$VENV/mlx_lm.lora" -c "$CONFIG"
rc=$?
if [ $rc -ne 0 ]; then
  echo "!!! training exited $rc — skipping fuse. $(date)"
  exit $rc   # trap reloads the game's models
fi

echo "---- fusing -> $OUT : $(date) ----"
mkdir -p "$(dirname "$OUT")"
"$VENV/mlx_lm.fuse" --model "$BASE" --adapter-path "$ADAPTERS" --save-path "$OUT"
rc=$?
if [ $rc -ne 0 ]; then
  echo "!!! fuse exited $rc. $(date)"
  exit $rc   # trap reloads the game's models
fi

echo "================ 35B MoE attention-only train finished: $(date) ================"
echo "Restart LM Studio to index, then load: $OUT"
