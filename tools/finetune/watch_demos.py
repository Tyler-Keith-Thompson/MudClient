#!/usr/bin/env python3
"""
Inspect the human-play demonstrations the AI pilot captures for LoRA training.

Every command you type in-game is appended to ~/Documents/MudClient/human-traces.jsonl as one OpenAI
tool-call SFT example: the full system + game-state prompt the model would have seen, paired with the
tool call your command maps to. The raw file is a wall of prompt text (the system prompt repeats on
every line), so use this to see just YOUR commands.

  python3 tools/finetune/watch_demos.py            # live: print each command as you play (tail -f)
  python3 tools/finetune/watch_demos.py --summary  # totals, command mix, and the last 20 commands
"""
import argparse
import collections
import json
import os
import time

PATH = os.path.expanduser("~/Documents/MudClient/human-traces.jsonl")


def command_of(line):
    """Extract a compact 'tool -> value' string from one JSONL demo record, or None."""
    try:
        fn = json.loads(line)["messages"][2]["tool_calls"][0]["function"]
        args = json.loads(fn["arguments"])
        val = (args.get("direction") or args.get("text") or args.get("target")
               or args.get("method") or args.get("item") or args.get("spell") or json.dumps(args))
        return f"{fn['name']:9} -> {val}"
    except Exception:
        return None


def summary():
    if not os.path.exists(PATH):
        print(f"no demos yet at {PATH}")
        return
    tools = collections.Counter()
    last = collections.deque(maxlen=20)
    total = 0
    with open(PATH) as f:
        for line in f:
            try:
                total += 1
                fn = json.loads(line)["messages"][2]["tool_calls"][0]["function"]
                tools[fn["name"]] += 1
                c = command_of(line)
                if c:
                    last.append(c)
            except Exception:
                pass
    print(f"{PATH}\n{total} demonstrations, {os.path.getsize(PATH) / 1e6:.1f} MB\n")
    print("command mix:")
    for name, n in tools.most_common():
        print(f"  {name:9} {n}")
    print("\nlast 20 commands:")
    for c in last:
        print(f"  {c}")


def follow():
    """tail -f the file, printing each new command. Handles the file being truncated/rotated."""
    print(f"watching {PATH} — play the game; your commands appear here (Ctrl-C to stop)\n")
    while not os.path.exists(PATH):
        time.sleep(0.5)
    with open(PATH) as f:
        f.seek(0, os.SEEK_END)
        while True:
            line = f.readline()
            if not line:
                time.sleep(0.4)
                continue
            c = command_of(line)
            if c:
                print(c, flush=True)


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--summary", action="store_true", help="print totals + command mix instead of following live")
    args = ap.parse_args()
    (summary if args.summary else follow)()
