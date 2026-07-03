#!/bin/bash
# Unattended overnight DUAL LoRA train + fuse, launched by the launchd agent com.mudclient.lora at
# 5 AM. Trains the gameplay LoRA on BOTH candidate bases and fuses each into LM Studio's models tree,
# so in the morning you load both and KEEP whichever fine-tuned model plays best:
#   - 35B-A3B MoE  (fast: ~1.2s turns, 2.7x decode — but weaker base judgment)
#   - 27B dense    (smarter base, ~1.8s turns — the safe fallback)
#
# Config is the PROVEN-STABLE one (batch 1 + grad-checkpoint, ~24 GB peak). MoE first (the speed bet,
# ready earliest ~6:30 AM), then the dense (~8:30 AM). Each ~1.5-2 h. Self-disables once BOTH are done;
# a failure leaves the agent so it retries next day, skipping whichever already finished.
set -uo pipefail

REPO="/Users/tylerthompson/workspace/MudClient"
VENV="$REPO/tools/finetune/.venv/bin"
FT="$REPO/tools/finetune"
LOG="$FT/scheduled-train.log"
BASES="$HOME/.lmstudio/models/lmstudio-community"
OUT="$HOME/.lmstudio/models/mudclient"

MOE_OUT="$OUT/Qwen3.6-35B-A3B-AlterAeon-MLX-4bit"
DENSE_OUT="$OUT/Qwen3.6-27B-AlterAeon-MLX-4bit"

exec >>"$LOG" 2>&1
echo "================ scheduled dual-train start: $(date) ================"

# Free the GPU (prevents the OOM we hit running inference + training together).
"$HOME/.lmstudio/bin/lms" unload --all 2>/dev/null || true
sleep 3

# train_one <label> <base-model-dir> <fused-output-dir>
train_one() {
  local name="$1" model="$2" out="$3"
  if [ -d "$out" ]; then echo "[$name] fused model already exists — skipping."; return 0; fi
  local adapters="$FT/adapters-$name"
  rm -rf "$adapters"; mkdir -p "$adapters"
  echo "---- [$name] training: $(date) ----"
  "$VENV/mlx_lm.lora" \
    --model "$model" --train --data "$FT/data" \
    --batch-size 1 --num-layers 16 --iters 600 \
    --max-seq-length 2048 --grad-checkpoint \
    --steps-per-report 10 --steps-per-eval 200 --save-every 100 \
    --adapter-path "$adapters"
  local rc=$?
  if [ $rc -ne 0 ]; then echo "!!! [$name] training exited $rc — skipping fuse. $(date)"; return $rc; fi
  echo "---- [$name] fusing -> $out : $(date) ----"
  mkdir -p "$(dirname "$out")"
  "$VENV/mlx_lm.fuse" --model "$model" --adapter-path "$adapters" --save-path "$out"
  echo "---- [$name] done: $(date) ----"
}

# MoE first (ready earliest), then the dense fallback. `|| true` so one failure doesn't abort the other.
train_one "moe"   "$BASES/Qwen3.6-35B-A3B-MLX-4bit" "$MOE_OUT"   || true
train_one "dense" "$BASES/Qwen3.6-27B-MLX-4bit"     "$DENSE_OUT" || true

echo "================ dual-train finished: $(date) ================"
echo "Restart LM Studio to index, then load each and keep the smarter one:"
echo "  MoE (fast):    $MOE_OUT"
echo "  dense (smart): $DENSE_OUT"
echo "Serve tuned with: tools/finetune/serve.sh <model-key from 'lms ls'>"

# One-shot: only disable the agent once BOTH fused models exist; otherwise leave it to retry tomorrow
# (train_one skips whichever already succeeded).
if [ -d "$MOE_OUT" ] && [ -d "$DENSE_OUT" ]; then
  echo "both models present — disabling agent."
  launchctl bootout "gui/$(id -u)/com.mudclient.lora" 2>/dev/null || true
else
  echo "one or both missing — leaving agent scheduled to retry."
fi
