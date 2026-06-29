#!/usr/bin/env python3
"""
Turn scraped help text (and optional gameplay traces) into a fine-tuning dataset
in MLX-LM chat format: train.jsonl / valid.jsonl, each row {"messages": [...]}.

Two kinds of rows:
  1. KNOWLEDGE — from tools/finetune/help_raw/*.txt. Each doc is chunked and turned
     into a Q/A turn ("Explain <topic> in Alter Aeon." -> passage). Teaches facts.
  2. CONTROL  — from a gameplay-trace JSONL produced by the client (AI_TRACE_FILE).
     Those rows are already chat-format and are passed through (optionally filtered).
     Teaches the CMD:/SCRIPT: behavior, which is what actually improves play.

Usage:
  python3 tools/finetune/build_dataset.py                       # knowledge only
  python3 tools/finetune/build_dataset.py --traces traces.jsonl # + control rows
  python3 tools/finetune/build_dataset.py --out data/
"""
import argparse
import glob
import json
import os
import re

HERE = os.path.dirname(__file__)
RAW_DIR = os.path.join(HERE, "help_raw")

KNOWLEDGE_SYS = (
    "You are a knowledgeable guide to the text MUD Alter Aeon. Answer accurately "
    "and concisely using the game's documentation."
)


def topic_from(path, first_line):
    base = os.path.basename(path).replace(".txt", "")
    base = re.sub(r"\.html?$", "", base)
    # Drop leading section words (help/guides/quests/maps/index) and separators.
    base = re.sub(r"\b(help|guides?|quests?|maps?|index|html)\b", " ", base)
    base = base.replace("_", " ").replace("-", " ")
    base = re.sub(r"\s+", " ", base).strip()
    return base or "the game"


def chunk(text, size=1200, overlap=120):
    text = re.sub(r"\n{3,}", "\n\n", text).strip()
    out, i = [], 0
    while i < len(text):
        out.append(text[i:i + size].strip())
        i += size - overlap
    return [c for c in out if len(c) > 120]


def knowledge_rows():
    rows = []
    for path in sorted(glob.glob(os.path.join(RAW_DIR, "*.txt"))):
        with open(path) as f:
            content = f.read()
        lines = content.splitlines()
        body = "\n".join(lines[2:]) if len(lines) > 2 else content
        topic = topic_from(path, lines[0] if lines else "")
        for i, ch in enumerate(chunk(body)):
            prompt = (f"Explain {topic} in Alter Aeon."
                      if i == 0 else f"Tell me more about {topic} in Alter Aeon.")
            rows.append({"messages": [
                {"role": "system", "content": KNOWLEDGE_SYS},
                {"role": "user", "content": prompt},
                {"role": "assistant", "content": ch},
            ]})
    return rows


def trace_rows(path, min_chars=2):
    rows = []
    if not path or not os.path.exists(path):
        return rows
    with open(path) as f:
        for ln in f:
            ln = ln.strip()
            if not ln:
                continue
            try:
                obj = json.loads(ln)
            except json.JSONDecodeError:
                continue
            msgs = obj.get("messages")
            if not msgs:
                continue
            assistant = next((m["content"] for m in msgs if m.get("role") == "assistant"), "")
            if len(assistant.strip()) >= min_chars:
                rows.append({"messages": msgs})
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--traces", help="gameplay-trace JSONL from AI_TRACE_FILE")
    ap.add_argument("--out", default=os.path.join(HERE, "data"), help="output dir")
    ap.add_argument("--valid-frac", type=float, default=0.1)
    args = ap.parse_args()

    rows = knowledge_rows() + trace_rows(args.traces)
    if not rows:
        raise SystemExit("No data. Run scrape_help.py first (and/or pass --traces).")

    # Deterministic shuffle (stable across runs) so train/valid split is reproducible.
    rows.sort(key=lambda r: hash(json.dumps(r, sort_keys=True)) & 0xFFFFFFFF)
    n_valid = max(1, int(len(rows) * args.valid_frac))
    valid, train = rows[:n_valid], rows[n_valid:]

    os.makedirs(args.out, exist_ok=True)
    for name, data in (("train", train), ("valid", valid)):
        p = os.path.join(args.out, name + ".jsonl")
        with open(p, "w") as f:
            for r in data:
                f.write(json.dumps(r) + "\n")
        print(f"wrote {len(data):5d} rows -> {p}")
    print(f"\nTotal {len(rows)} rows ({len(knowledge_rows())} knowledge + "
          f"{len(trace_rows(args.traces))} control).")


if __name__ == "__main__":
    main()
