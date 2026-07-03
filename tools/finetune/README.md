# Fine-tuning a local model for Alter Aeon

This pipeline builds a fine-tuning dataset from two sources and trains a local model
with **MLX-LM LoRA** (the native Apple-Silicon path). Your M1 Ultra / 128 GB can
train and run comfortably.

```
scrape_help.py   -> tools/finetune/help_raw/*.txt      (game docs as text)
build_dataset.py -> tools/finetune/data/{train,valid}.jsonl   (MLX chat format)
mlx_lm.lora      -> adapters/                            (LoRA fine-tune)
mlx_lm.fuse      -> fused_model/                          (merge -> load in LM Studio)
```

## Two kinds of training data — and which one matters

1. **Knowledge** (from the help docs): teaches the model *facts* about Alter Aeon —
   spells, commands, areas. Useful, but on its own it does **not** make the model a
   better *player*.
2. **Control** (from gameplay traces): teaches the `CMD:`/`SCRIPT:` decision behavior
   the pilot actually uses. This is the higher-leverage data. The client can record
   it for you: set `AI_TRACE_FILE=traces.jsonl` before running, play (or let the pilot
   play), then **curate** — keep the good turns, delete the dumb ones — and feed the
   file to `build_dataset.py --traces`. A few hundred good turns beats a pile of docs.

> Realistic expectation: fine-tuning narrows tone/format and injects niche facts. It
> won't turn a 7B into a savant. The biggest day-one win is **a better base model**
> (below) + the **script-offload design** (deterministic reflexes run in Lua, the LLM
> only makes real choices), not fine-tuning. Fine-tune once you have trace data worth
> distilling.

## 0. Which model to run? — use the newest you have

Run **Qwen3.6-27B (MLX)** — the current Qwen generation. On a 128 GB M1 Ultra the
8-bit fits comfortably; the 4-bit is faster per turn. Train the LoRA on the SAME local
quant you'll run, because the adapter binds to those exact base weights.

| Local model (in `~/.lmstudio/models`) | Use |
|---------------------------------------|-----|
| **Qwen3.6-27B-MLX-8bit** | best judgment; run this if turn latency is acceptable |
| **Qwen3.6-27B-MLX-4bit** | faster turns / faster LoRA training; slightly lower quality |
| gemma-4-E4B-it-MLX-4bit | tiny/fast; follows the contract unreliably (fallback only) |
| Qwen2.5-14B-Instruct-1M-GGUF | superseded by Qwen3.6 — don't bother |

Qwen3 uses a thinking-mode chat template: our terse `CMD:` rows render with an empty
`<think></think>` block, i.e. non-thinking mode, which is what we want (no wasted
reasoning tokens in combat). The pilot auto-discovers the loaded model via `/v1/models`
(or pin with `#ai model <id>`).

> Earlier versions of this README recommended Qwen2.5 — that was outdated advice;
> Qwen3.6 is the current generation and the right base to fine-tune.

Because the design offloads deterministic reflexes to Lua, the model only makes genuine
judgment calls, so a 27B is plenty.

## 1. Scrape the docs

```bash
python3 tools/finetune/scrape_help.py            # polite, rate-limited, ~300 pages
python3 tools/finetune/scrape_help.py --max 600 --delay 0.5   # go wider
```

Stdlib only (no pip). Output lands in `help_raw/`. Re-run anytime; it overwrites.

## 2. Build the dataset

```bash
# knowledge only:
python3 tools/finetune/build_dataset.py
# knowledge + curated gameplay traces:
python3 tools/finetune/build_dataset.py --traces traces.jsonl
```

Produces `data/train.jsonl` and `data/valid.jsonl` as MLX chat rows
(`{"messages":[{role,content}...]}`).

## 3. Fine-tune with MLX-LM LoRA (Apple Silicon native)

This is a **QLoRA** — we train adapters directly on the already-quantized local MLX
model (no re-download, no full-precision base needed). Use the venv set up in
`tools/finetune/.venv`. Point `--model` at the SAME local quant you'll run.

```bash
MODEL="$HOME/.lmstudio/models/lmstudio-community/Qwen3.6-27B-MLX-8bit"   # or -4bit
tools/finetune/.venv/bin/mlx_lm.lora \
  --model "$MODEL" \
  --train \
  --data tools/finetune/data \
  --batch-size 2 \
  --num-layers 16 \
  --iters 600 \
  --adapter-path tools/finetune/adapters
```

Try a prompt against the adapter:

```bash
tools/finetune/.venv/bin/mlx_lm.generate --model "$MODEL" \
  --adapter-path tools/finetune/adapters \
  --prompt "Explain the recall spell in Alter Aeon."
```

## 4. Fuse and load in LM Studio

```bash
tools/finetune/.venv/bin/mlx_lm.fuse \
  --model "$MODEL" \
  --adapter-path tools/finetune/adapters \
  --save-path tools/finetune/fused_model
```

LM Studio loads **MLX models directly** on Apple Silicon — point it at
`fused_model/` (or move it under `~/.cache/lm-studio/models/...`). Prefer GGUF? Convert
`fused_model/` with `llama.cpp`'s `convert_hf_to_gguf.py` then `llama-quantize`.

Load it in LM Studio, start the server, and the pilot picks it up. Tune the goal with
`#ai goal <text>` and watch it play.
