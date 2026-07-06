#!/usr/bin/env python3
"""
Combine the CLEANED combat set (prep_combat.py output) with the existing general
dataset (knowledge Q/A + non-combat demos), into train/valid for MLX-LM.

Rationale: a combat-ONLY LoRA overfits and forgets exploration/recovery/navigation.
So we keep the general dataset's non-combat signal and swap its stale, un-weighted
combat demos for the cleaned+weighted ones from combat_clean.jsonl.

Leakage control: the combat split is by FIGHT id (a whole fight goes to train OR
valid, never split), and validation combat rows are unique (weight 1) — never the
weighted duplicates.

Inputs (in --src, default tools/finetune/data/):
  train.jsonl, valid.jsonl  existing general dataset (build_dataset.py output)
  combat_clean.jsonl        cleaned combat decisions (prep_combat.py output)
Output (--out, default tools/finetune/data-combined/):
  train.jsonl, valid.jsonl  ready for `mlx_lm.lora --data <out>`

Usage:
  python3 tools/finetune/build_combined.py
  python3 tools/finetune/build_combined.py --valid-fights 0.1
"""
import argparse
import json
import os
import re
from collections import defaultdict

from prep_combat import label_texts, strip_label_echo   # single source of the label-echo rule

HERE = os.path.dirname(__file__)

# Templated-length budget. mlx_lm.lora truncates the TAIL of any sequence over --max-seq-length,
# and in a chat row the tail is the assistant reply — the label. The combat rows carry a ~1540-token
# system prompt, so at the old 2048 limit ~55% of train rows lost their labels. run_train_35b.sh now
# trains with --max-seq-length 2304; we trim the USER content (the game-output window) so every row
# fits under that intact. Keep the two in sync.
MAX_TOKENS = 2304
TEMPLATE_OVERHEAD = 60      # chat-template scaffolding (im_start/end, role tags, tool wrapper)
PER_MESSAGE_OVERHEAD = 8

_tokenizer = None


def _toklen(text):
    """Token count via the actual Qwen tokenizer when available (the training venv has
    `tokenizers`), else a conservative chars/3 estimate."""
    global _tokenizer
    if _tokenizer is None:
        try:
            from tokenizers import Tokenizer
            path = os.path.expanduser(
                "~/.lmstudio/models/lmstudio-community/Qwen3.6-35B-A3B-MLX-4bit/tokenizer.json")
            _tokenizer = Tokenizer.from_file(path)
        except Exception:
            _tokenizer = False
    if _tokenizer:
        return len(_tokenizer.encode(text).ids)
    return len(text) // 3 + 1


def row_tokens(row):
    n = TEMPLATE_OVERHEAD
    for m in row["messages"]:
        c = m.get("content") or ""
        if m.get("tool_calls"):
            c += json.dumps(m["tool_calls"])
        n += _toklen(c) + PER_MESSAGE_OVERHEAD
    return n


def trim_to_budget(row, budget=MAX_TOKENS):
    """Shrink the user message so the whole templated row fits in `budget` tokens, by dropping
    lines from the MIDDLE of the user content: the head keeps the character-state/map header, the
    tail keeps the most recent game output and the final instruction line (the parts the decision
    actually hangs on). System prompt and assistant label are never touched. Returns the row
    (mutated) and whether it was trimmed."""
    if row_tokens(row) <= budget:
        return row, False
    user = next((m for m in row["messages"] if m.get("role") == "user"), None)
    if user is None:
        return row, False
    # Protect a head (state + map header) and tail (freshest output + instruction) and drop the
    # OLDEST middle lines until the row fits. If the middle runs out before we're under budget,
    # retry with smaller protected regions rather than leave the label to be truncated off.
    for head_keep, tail_keep in ((25, 15), (15, 10), (8, 6), (4, 3)):
        lines = (user.get("content") or "").split("\n")
        excess = row_tokens(row) - budget
        if excess <= 0:
            break
        head_keep, tail_keep = min(head_keep, len(lines) // 3), min(tail_keep, len(lines) // 3)
        cut_from, cut_to = head_keep, len(lines) - tail_keep
        saved, dropped, kept_mid = 0, 0, []
        for i in range(cut_from, cut_to):           # oldest middle lines go first (+48 covers the
            if saved < excess + 48:                 # trim marker and template-estimate slack)
                saved += _toklen(lines[i]) + 1
                dropped += 1
            else:
                kept_mid.append(lines[i])
        if dropped:
            user["content"] = "\n".join(
                lines[:cut_from] + [f"[... {dropped} older output lines trimmed ...]"]
                + kept_mid + lines[cut_to:])
    return row, True


def fix_tool_args(row):
    """The Qwen chat template does `tool_call.arguments|items`, so arguments must be a
    dict, not a JSON string (the OpenAI wire format). Parse every assistant tool call's
    string arguments into an object in-place. Returns the same row."""
    for m in row.get("messages", []):
        if m.get("role") != "assistant":
            continue
        for tc in m.get("tool_calls") or []:
            fn = tc.get("function")
            if fn and isinstance(fn.get("arguments"), str):
                try:
                    fn["arguments"] = json.loads(fn["arguments"])
                except (json.JSONDecodeError, TypeError):
                    fn["arguments"] = {}
    return row


def is_combat(row):
    u = next((m["content"] for m in row["messages"] if m.get("role") == "user"), "")
    m = re.search(r"combat:\s*(.+)", u)
    return bool(m and "not fighting" not in m.group(1) and "fighting" in m.group(1))


def load(path):
    with open(path) as f:
        return [json.loads(ln) for ln in f if ln.strip()]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=os.path.join(HERE, "data"))
    ap.add_argument("--out", default=os.path.join(HERE, "data-combined"))
    ap.add_argument("--valid-fights", type=float, default=0.1,
                    help="fraction of combat FIGHTS held out for validation (default 0.1)")
    args = ap.parse_args()

    gen_train = [r for r in load(os.path.join(args.src, "train.jsonl")) if not is_combat(r)]
    gen_valid = [r for r in load(os.path.join(args.src, "valid.jsonl")) if not is_combat(r)]

    combat = load(os.path.join(args.src, "combat_clean.jsonl"))
    # group by fight, deterministic held-out selection (every Nth fight id)
    by_fight = defaultdict(list)
    for r in combat:
        by_fight[r.get("fight", 0)].append(r)
    fights = sorted(by_fight)
    step = max(1, round(1 / args.valid_fights)) if args.valid_fights > 0 else 0
    valid_fights = set(fights[::step]) if step else set()

    c_train, c_valid = [], []
    for fid in fights:
        rows = by_fight[fid]
        if fid in valid_fights:
            for r in rows:
                c_valid.append({"messages": r["messages"]})          # unique, weight 1
        else:
            for r in rows:
                for _ in range(max(1, r.get("w", 1))):                # weighted expansion
                    c_train.append({"messages": r["messages"]})

    train = gen_train + c_train
    valid = gen_valid + c_valid
    # deterministic shuffle (stable) so batches mix domains
    train.sort(key=lambda r: hash(json.dumps(r, sort_keys=True)) & 0xFFFFFFFF)
    valid.sort(key=lambda r: hash(json.dumps(r, sort_keys=True)) & 0xFFFFFFFF)

    os.makedirs(args.out, exist_ok=True)
    trimmed = {"train": 0, "valid": 0}
    overs = {"train": 0, "valid": 0}
    for name, data in (("train", train), ("valid", valid)):
        with open(os.path.join(args.out, name + ".jsonl"), "w") as f:
            for r in data:
                # belt-and-suspenders: strip any residual label-leaking tail echo (combat rows are
                # cleaned in prep_combat; this also covers the general set). Prior-turn echoes stay.
                labels = label_texts(next(
                    (m for m in r["messages"] if m.get("role") == "assistant"), None))
                for m in r["messages"]:
                    if m.get("role") == "user":
                        m["content"] = strip_label_echo(m.get("content") or "", labels)
                fix_tool_args(r)
                r, was_trimmed = trim_to_budget(r)
                trimmed[name] += was_trimmed
                overs[name] += row_tokens(r) > MAX_TOKENS
                f.write(json.dumps({"messages": r["messages"]}) + "\n")

    print(f"trim:    budget {MAX_TOKENS} toks -> {trimmed['train']} train + {trimmed['valid']} valid rows "
          f"trimmed; still over budget after trim: {overs['train']} train + {overs['valid']} valid")
    print(f"general: {len(gen_train)} train + {len(gen_valid)} valid (non-combat kept)")
    print(f"combat:  {len(fights)} fights -> {len(valid_fights)} held out; "
          f"{len(c_train)} train rows (weighted) + {len(c_valid)} valid rows (unique)")
    print(f"TOTAL:   {len(train)} train + {len(valid)} valid -> {args.out}")


if __name__ == "__main__":
    main()
