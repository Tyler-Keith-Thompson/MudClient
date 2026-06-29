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

## 0. Which model to run? (you're on gemma-4-e4b — step up)

`gemma-4-e4b` is ~4B effective; it follows the `CMD:`/`SCRIPT:` contract unreliably
(in testing it answered `CMD: look around` instead of resting at low HP). On a 128 GB
M1 Ultra you have huge headroom. Recommended, in order of latency↔quality tradeoff —
and remember the loop *waits* on each turn, so latency is real:

| Model | ~Q4 size | Feel on M1 Ultra | Use |
|-------|----------|------------------|-----|
| **Qwen2.5-14B-Instruct** | ~9 GB | ~40–60 tok/s, snappy | **recommended daily driver** |
| Qwen2.5-32B-Instruct | ~19 GB | ~20–30 tok/s | sharper judgment, still fine for turns |
| Llama-3.3-70B-Instruct / Qwen2.5-72B | ~40 GB | ~10–15 tok/s | best play, slower turns |
| Qwen2.5-7B-Instruct | ~5 GB | very fast | low-latency, fine once Lua handles reflexes |

The Qwen2.5-Instruct family is the strongest pick here: excellent instruction-following
and concise output. Grab one in LM Studio (search "Qwen2.5 14B Instruct", MLX or GGUF),
load it, and the pilot auto-discovers it via `/v1/models` (or pin with `#ai model <id>`).

Because the design offloads deterministic reflexes to Lua, you don't need a giant model
to play well — a 14B reserved for genuine judgment is plenty.

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

```bash
pip install mlx-lm
# Pick a base you'll actually run; 7B/14B iterate fastest.
mlx_lm.lora \
  --model Qwen/Qwen2.5-7B-Instruct \
  --train \
  --data tools/finetune/data \
  --batch-size 4 \
  --num-layers 16 \
  --iters 600 \
  --adapter-path tools/finetune/adapters
```

Try a prompt against the adapter:

```bash
mlx_lm.generate --model Qwen/Qwen2.5-7B-Instruct \
  --adapter-path tools/finetune/adapters \
  --prompt "Explain the recall spell in Alter Aeon."
```

## 4. Fuse and load in LM Studio

```bash
mlx_lm.fuse \
  --model Qwen/Qwen2.5-7B-Instruct \
  --adapter-path tools/finetune/adapters \
  --save-path tools/finetune/fused_model
```

LM Studio loads **MLX models directly** on Apple Silicon — point it at
`fused_model/` (or move it under `~/.cache/lm-studio/models/...`). Prefer GGUF? Convert
`fused_model/` with `llama.cpp`'s `convert_hf_to_gguf.py` then `llama-quantize`.

Load it in LM Studio, start the server, and the pilot picks it up. Tune the goal with
`#ai goal <text>` and watch it play.
