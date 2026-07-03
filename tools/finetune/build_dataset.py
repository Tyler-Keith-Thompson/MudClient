#!/usr/bin/env python3
"""
Turn scraped help text (and optional gameplay traces) into a fine-tuning dataset
in MLX-LM chat format: train.jsonl / valid.jsonl, each row {"messages": [...]}.

Three kinds of rows:
  1. KNOWLEDGE — from tools/finetune/help_raw/*.txt. Each doc is chunked and turned
     into a Q/A turn ("Explain <topic> in Alter Aeon." -> passage). Teaches facts.
  2. CONTROL  — from the AI's own gameplay-trace JSONL (ai-traces.jsonl). Already
     chat-format; passed through. Teaches the turn behavior (incl. tool calls).
  3. DEMOS    — from human-traces.jsonl: turns YOU played, captured as tool-call
     examples. The highest-quality signal, so they're upweighted (--human-weight).

Both CONTROL and DEMO rows may carry the action in either assistant `content`
(CMD:/SCRIPT: text) or assistant `tool_calls` (the structured tools) — both are kept.

Usage:
  python3 tools/finetune/build_dataset.py                                  # knowledge only
  python3 tools/finetune/build_dataset.py --traces ~/Documents/MudClient/ai-traces.jsonl
  python3 tools/finetune/build_dataset.py --human  ~/Documents/MudClient/human-traces.jsonl
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


def trace_rows(path, min_chars=2, repeat=1):
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
            assistant = next((m for m in msgs if m.get("role") == "assistant"), None)
            if not assistant:
                continue
            # Keep a row if the assistant did something: free-text content (CMD:/SCRIPT:) OR a
            # structured tool call (content is empty for tool-call demos).
            has_text = len((assistant.get("content") or "").strip()) >= min_chars
            has_call = bool(assistant.get("tool_calls"))
            if has_text or has_call:
                rows.extend({"messages": msgs} for _ in range(repeat))
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--traces", help="the AI's own gameplay-trace JSONL (ai-traces.jsonl)")
    ap.add_argument("--human", help="your human-played demos JSONL (human-traces.jsonl)")
    ap.add_argument("--human-weight", type=int, default=3,
                    help="repeat each human demo N times to upweight gold play (default 3)")
    ap.add_argument("--out", default=os.path.join(HERE, "data"), help="output dir")
    ap.add_argument("--valid-frac", type=float, default=0.1)
    args = ap.parse_args()

    knowledge = knowledge_rows()
    control = trace_rows(args.traces)
    demos = trace_rows(args.human, repeat=max(1, args.human_weight))
    rows = knowledge + control + demos
    if not rows:
        raise SystemExit("No data. Run scrape_help.py first (and/or pass --traces/--human).")

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
    print(f"\nTotal {len(rows)} rows ({len(knowledge)} knowledge + "
          f"{len(control)} control + {len(demos)} your demos x{args.human_weight}).")


if __name__ == "__main__":
    main()
