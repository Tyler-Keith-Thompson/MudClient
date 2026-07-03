#!/bin/bash
# Load a model into LM Studio tuned for the single-user MUD pilot:
#   --parallel 1             : one user, not four — frees ~4x the KV cache LM Studio reserves
#   --speculative-draft-mtp  : self-speculative decoding via the model's built-in MTP head.
#                              ~2.4x faster decode and LOSSLESS — identical outputs to plain 8-bit
#                              (the big model still verifies every token; the draft just proposes).
#
# Measured on M1 Ultra / Qwen3.6-35B-A3B-MLX-4bit (MoE, ~3B active): decode ~63 tok/s, steady ~1.2s
# pilot turns — the chosen daily driver.
#
# Usage:
#   tools/finetune/serve.sh                 # loads the 35B-A3B MoE base, tuned
#   tools/finetune/serve.sh fused_model     # after training: load the fine-tuned fused model by key
MODEL="${1:-qwen3.6-35b-a3b-mlx}"
LMS="$HOME/.lmstudio/bin/lms"
"$LMS" unload --all 2>/dev/null
exec "$LMS" load "$MODEL" --parallel 1 --speculative-draft-mtp -y
