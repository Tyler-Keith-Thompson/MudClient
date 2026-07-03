#!/usr/bin/env python3
"""
Turn a RAW terminal capture of human play (e.g. human-driving.txt — a verbatim paste of the MUD
session) into structured gameplay rows that build_dataset.py can train on.

Why this exists: the client's live capture (human-traces.jsonl) only records once the AI is wired in.
A raw paste of you playing is the richest demonstration data we have, but it's just screen text. This
recovers the (what you saw -> what you did) pairs from it.

How it finds your commands: Alter Aeon echoes a prompt, then your typed command, then the result:

    <72hp 158m 157mv>      <- prompt (state)
                           <- blank
    c shower               <- YOUR command (first short, lowercase line after a prompt)
                           <- blanks
    A shower of bright purple sparks ...   <- result

Async combat narration ("A kobold's stab hits you.") starts uppercase, so it never looks like a
command; item-list lines ("a sharp metal spear") only appear inside result blocks, never right after a
prompt. Those two facts make the delimiter reliable.

Each command becomes one row:
    user      = the CHARACTER STATE (parsed from the prompt) + RECENT GAME OUTPUT (what you'd just seen)
    assistant = "CMD: <your command>"   (the text form the pilot already accepts as a fallback)

Output is the same {"messages":[...]} JSONL build_dataset.py reads, so feed it via --human (gold,
upweighted). We keep your literal commands (incl. abbreviations like 'c shower', 'inv', 'w') — the game
accepts them and they're authentically how you play.

Usage:
  python3 tools/finetune/parse_capture.py human-driving.txt -o tools/finetune/human-traces.jsonl
  python3 tools/finetune/parse_capture.py human-driving.txt --print 5     # eyeball the first 5 rows
"""
import argparse
import json
import re

PROMPT_RE = re.compile(r"^<(\d+)hp\s+(\d+)m\s+(\d+)mv(?:\s+(\d+)ac)?>\s*(.*)$")
# A plausible echoed command: short, lowercase-ish, no sentence punctuation. Server narration is
# full sentences starting with a capital ("You", "A kobold", "The sun"), so it's excluded.
COMMAND_RE = re.compile(r"^[a-z0-9][a-z0-9 '+\-]{0,30}$")

CONTEXT_LINES = 30   # how much recent output to show as the situation
SYSTEM = (
    "You are an expert player of the MUD Alter Aeon, driving a character live. Read the character's "
    "STATE and the RECENT GAME OUTPUT, then issue exactly one command on its own line prefixed with "
    "'CMD:'. Use real Alter Aeon commands and short target keywords. One action per turn."
)


def parse(path):
    with open(path, errors="replace") as f:
        lines = [ln.rstrip("\n") for ln in f]

    rows = []
    context = []          # sliding window of recent OUTPUT lines (what the player saw)
    last_state = None     # most recent prompt, as a STATE string
    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]
        m = PROMPT_RE.match(line)
        if m:
            last_state = state_from(m)
            # The command (if any) is the next non-blank line.
            j = i + 1
            while j < n and lines[j].strip() == "":
                j += 1
            if j < n and COMMAND_RE.match(lines[j].strip()) and not PROMPT_RE.match(lines[j]):
                cmd = lines[j].strip()
                rows.append({"messages": [
                    {"role": "system", "content": SYSTEM},
                    {"role": "user", "content": build_user(last_state, context)},
                    {"role": "assistant", "content": "CMD: " + cmd},
                ]})
                # The command echo itself isn't "what you saw" — skip it; its result re-enters context.
                i = j + 1
                continue
            i += 1
            continue
        # Ordinary output line: add to the rolling context (skip blanks and pure map-scale noise).
        if line.strip():
            context.append(line.rstrip())
            if len(context) > CONTEXT_LINES:
                context.pop(0)
        i += 1
    return rows


def state_from(m):
    hp, mana, mv, ac, tail = m.groups()
    parts = [f"hp: {hp}, mana: {mana}, stamina: {mv}"]
    if ac:
        parts.append(f"armor: {ac}")
    tail = (tail or "").strip()
    if tail:
        # e.g. "A kobold <excellent>" — you're in combat with that target.
        parts.append("combat: fighting " + tail)
    else:
        parts.append("combat: not fighting")
    return "\n".join(parts)


def build_user(state, context):
    convo = "\n".join(context[-CONTEXT_LINES:]).strip()
    st = state or "hp: ?, mana: ?, stamina: ?\ncombat: not fighting"
    return ("=== CHARACTER STATE ===\n" + st +
            "\n\n=== RECENT GAME OUTPUT ===\n" + convo +
            "\n\nDecide the single best next action. Reply with one CMD: line.")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("capture", help="raw terminal capture (e.g. human-driving.txt)")
    ap.add_argument("-o", "--out", help="output JSONL (default: stdout count only)")
    ap.add_argument("--print", type=int, default=0, metavar="N",
                    help="pretty-print the first N parsed rows to inspect quality")
    args = ap.parse_args()

    rows = parse(args.capture)
    print(f"parsed {len(rows)} command turns from {args.capture}")

    for r in rows[: args.print]:
        print("-" * 70)
        for msg in r["messages"]:
            print(f"[{msg['role']}]")
            print(msg["content"])

    if args.out:
        with open(args.out, "w") as f:
            for r in rows:
                f.write(json.dumps(r) + "\n")
        print(f"wrote {len(rows)} rows -> {args.out}")


if __name__ == "__main__":
    main()
