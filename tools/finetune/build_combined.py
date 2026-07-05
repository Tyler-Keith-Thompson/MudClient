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

HERE = os.path.dirname(__file__)


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
    for name, data in (("train", train), ("valid", valid)):
        with open(os.path.join(args.out, name + ".jsonl"), "w") as f:
            for r in data:
                fix_tool_args(r)
                f.write(json.dumps({"messages": r["messages"]}) + "\n")

    print(f"general: {len(gen_train)} train + {len(gen_valid)} valid (non-combat kept)")
    print(f"combat:  {len(fights)} fights -> {len(valid_fights)} held out; "
          f"{len(c_train)} train rows (weighted) + {len(c_valid)} valid rows (unique)")
    print(f"TOTAL:   {len(train)} train + {len(valid)} valid -> {args.out}")


if __name__ == "__main__":
    main()
