#!/usr/bin/env python3
"""
Build a CLEAN, combat-focused fine-tuning set from human-traces.jsonl.

Why this exists (and build_dataset.py's --human path isn't enough):
  build_dataset.py flat-repeats every human demo N times. On combat data that
  memorizes junk, because the raw trace has:
    - ~12% exact (state+action) duplicate rows (the capture fires on unchanged state)
    - shower-of-sparks sustain casts drowning out the *interesting* decisions
      (soulsteal finishers, spell switches, recover-when-low) ~15:1
    - typo'd spell labels the model would learn to emit ("choswer", "souslteal")

This script fixes all three: dedupe, normalize labels, then WEIGHT by how much
signal a decision carries (finisher > switch > recover > sustain), and cap
runs of identical sustain casts so one spell can't dominate.

Outputs (into --out, default tools/finetune/data/):
  combat_clean.jsonl  one row per KEPT decision, with extra top-level fields
                      {w, tags, hp, spell} for inspection (NOT for training).
  combat_train.jsonl  training-ready: each clean row emitted `w` times, and
                      stripped to bare {"messages": [...]}. Feed this to MLX-LM,
                      or point build_dataset.py --human at it with --human-weight 1.
  combat_stats.json   the summary also printed to stdout.

The enemy HP% that drives finisher/switch detection comes from the KXWT/state
line  `combat: fighting <mob> (NN%)`  in the === CHARACTER STATE === block, not
from scraping game prose — so it survives prompt/output-format changes.

Usage:
  python3 tools/finetune/prep_combat.py                       # ~/Documents/MudClient/human-traces.jsonl
  python3 tools/finetune/prep_combat.py --scope combat        # combat-only (default: combat+adjacent)
  python3 tools/finetune/prep_combat.py --dry-run             # stats only, write nothing
"""
import argparse
import json
import os
import re
from collections import Counter, defaultdict

HERE = os.path.dirname(__file__)
DEFAULT_TRACES = os.path.expanduser("~/Documents/MudClient/human-traces.jsonl")

# Canonical spell keyword <- observed typos/variants in the human's cast labels.
# We keep the human's short cast form (`c <kw>`) — it works in-game — just fix spelling.
SPELL_FIX = {
    "hower": "shower", "choswer": "shower", "shwoer": "shower", "shoewr": "shower",
    "showerc": "shower", "whoer": "shower", "showe": "shower",
    "sahrds": "shards", "sharsd": "shards", "shrads": "shards",
    "souslteal": "soulsteal", "soul": "soulsteal",
    "frost": "frostflower", "frostflwoer": "frostflower", "sfrostflower": "frostflower",
    "forstflower": "frostflower",
    "soothe": "sooth",
}
# Spells that are AoE (thrown early / on groups) — informational tagging only.
AOE_SPELLS = {"frostflower", "shower"}

# CLIENT-GENERATED command-echo lines in the RECENT GAME OUTPUT window: the client re-displays a
# typed command as `[the human typed] <cmd>` (co-driver echo, AIPilot.lua) and its own past actions
# as `[you] <cmd>`. The live pilot injects these at inference too and the system prompt documents
# the convention, so as PRIOR-turn history they are legitimate context (knowing what was just cast
# drives sustain/switch decisions) and are KEPT. The one poisonous case is the echo of THIS row's
# own label sitting in the tail of the window with no game output after it — the capture fired
# right after the command was typed, so the "context" literally contains the answer (~25% of
# windows). strip_label_echo removes exactly that. Genuine bracketed GAME text — `[event]`,
# `[Exits: ...]`, price/loot tables — starts with a different tag and is never touched.
CLIENT_ECHO_RE = re.compile(r"^\s*\[(?:the human typed|you)\]\s*(.*)$", re.I)
# Client-appended final instruction line(s) — not game output; the tail scan skips them.
INSTRUCTION_RE = re.compile(r"^\s*(?:Decide the single best next action\b|You are IN COMBAT\b)")


DIR_ABBREV = {"north": "n", "south": "s", "east": "e", "west": "w", "up": "u", "down": "d",
              "northeast": "ne", "northwest": "nw", "southeast": "se", "southwest": "sw"}
TOOL_ALIASES = {"look": ["look", "l"], "inventory": ["inventory", "inv", "i"],
                "recover": ["recover"], "flee": ["flee", "fl"], "stand": ["stand"]}


def label_texts(assistant):
    """Every plausible TYPED form of this row's label, for matching against a client echo line:
    the CMD: content, tool-call arg values, and per-tool typed variants (the capture stores the
    canonical tool — move{direction:"south"} — but the human typed 's', 'drop leg', 'recover'...)."""
    out = set()
    if not assistant:
        return out
    c = (assistant.get("content") or "").strip()
    m = re.match(r"CMD:\s*(.+)", c)
    if m:
        out.add(m.group(1).strip())
    elif c:
        out.add(c)
    for tc in assistant.get("tool_calls") or []:
        fn = tc.get("function") or {}
        name = fn.get("name") or ""
        args = fn.get("arguments")
        if isinstance(args, str):
            try:
                args = json.loads(args)
            except (json.JSONDecodeError, TypeError):
                args = {}
        args = args or {}
        vals = [v.strip() for v in args.values() if isinstance(v, str) and v.strip()]
        out.update(vals)
        if name == "move" and vals:
            d = vals[0].lower()
            out.add(DIR_ABBREV.get(d, d))
            out.update(d[:i] for i in range(1, len(d)))       # typed prefixes: s, so, sou...
        elif name == "command":
            pass                                              # text IS the typed form
        elif name == "cast" and vals:
            out.update(("c " + vals[0], "cast " + vals[0]))
        elif name == "attack" and vals:
            out.update(("attack " + vals[0], "kill " + vals[0], "k " + vals[0]))
        elif name in TOOL_ALIASES:
            out.update(TOOL_ALIASES[name])
        elif name and vals:                                   # get/drop/wear/...: "<tool> <item>"
            out.update(f"{name} {v}" for v in vals)
    return {t.lower() for t in out if t}


ANSI_RE = re.compile(r"\x1b\[[0-9;<>]*[A-Za-z]?|\x1b")
# A mouse-tracking fragment masquerading as a command: digits/`;`/`<`/`>`/`M` only
# (pieces of `\x1b[<65;41;27M` wheel events that got split into the input line).
MOUSE_JUNK_RE = re.compile(r"^[\d;<>Mm\s]*$")


def sanitize_command_label(txt):
    """Return a cleaned command text, or None if the label is terminal junk and the row must be
    dropped. Handles the two corruption modes seen in the capture: raw mouse-tracking fragments
    ('38M\\x1b[<65', bare '41'/'60') -> drop; up-arrow history recalls ('\\x1b[A\\nc shards') ->
    salvage the real command after the last escape/newline."""
    if txt is None:
        return None
    if "\x1b" in txt:
        # salvage: strip escapes, take the last non-empty piece; it must look like a command
        clean = ANSI_RE.sub("\n", txt)
        parts = [p.strip() for p in clean.split("\n") if p.strip()]
        cand = parts[-1] if parts else ""
        if cand and not MOUSE_JUNK_RE.match(cand) and re.search(r"[a-zA-Z]{2,}", cand):
            return cand
        return None
    if MOUSE_JUNK_RE.match(txt):
        return None
    return txt


def strip_label_echo(text, labels):
    """Remove ONLY the label-leaking echo lines from a user message: client echo lines
    ([the human typed]/[you]) whose command equals this row's label AND that sit in the TAIL of
    the window — after the last real game-output line (skipping blanks and the client-appended
    instruction line). A mid-window echo of the same command is prior-turn history (its result
    followed it) and is kept, as are all non-label echoes."""
    if not text or "[" not in text or not labels:
        return text
    lines = text.split("\n")
    # find the last real content line, skipping trailing blanks + the instruction line(s)
    j = len(lines) - 1
    while j >= 0 and (lines[j].strip() == "" or INSTRUCTION_RE.match(lines[j])):
        j -= 1
    # tail region: contiguous run of echo/blank lines ending at j
    t = j
    while t >= 0 and (lines[t].strip() == "" or CLIENT_ECHO_RE.match(lines[t])):
        t -= 1
    t += 1
    if t > j:
        return text  # tail is game output — nothing to strip
    keep = []
    for i, ln in enumerate(lines):
        if t <= i <= j:
            m = CLIENT_ECHO_RE.match(ln)
            if m and m.group(1).strip().lower() in labels:
                continue  # the leak: this row's own answer echoed with no result after it
        keep.append(ln)
    return "\n".join(keep)


def load_rows(path, include_old):
    rows = []
    with open(path) as f:
        for ln in f:
            ln = ln.strip()
            if not ln:
                continue
            try:
                obj = json.loads(ln)
            except json.JSONDecodeError:
                continue
            if "ts" not in obj and not include_old:
                continue
            if obj.get("messages"):
                rows.append(obj)
    return rows


def state_block(user):
    m = re.search(r"=== CHARACTER STATE ===(.*?)(?:=== |\Z)", user, re.S)
    return (m.group(1) if m else user[:400]).strip()


def parse_combat(user):
    """Return (in_combat, mob, hp_pct or None) from the structured state line."""
    m = re.search(r"combat:\s*(.+)", user)
    if not m:
        return False, None, None
    line = m.group(1).strip()
    if "not fighting" in line.lower() or not line or line.lower() == "fighting":
        # 'not fighting', or 'fighting' with no target payload
        if "not fighting" in line.lower():
            return False, None, None
    if "fighting" not in line.lower():
        return False, None, None
    hp = None
    hm = re.search(r"\((\d+)%\)", line)
    if hm:
        hp = int(hm.group(1))
    mob = re.sub(r"^fighting\s*", "", line, flags=re.I)
    mob = re.sub(r"\s*\(\d+%\)\s*$", "", mob).strip()
    return True, (mob or None), hp


def parse_vitals(user):
    """hp/mana/stamina current+max fractions, and recovery/position, for recover tagging."""
    out = {}
    m = re.search(r"hp:\s*(\d+)/(\d+),\s*mana:\s*(\d+)/(\d+),\s*stamina:\s*(\d+)/(\d+)", user)
    if m:
        hp_c, hp_m, ma_c, ma_m, st_c, st_m = map(int, m.groups())
        out["hp_frac"] = hp_c / hp_m if hp_m else 1.0
        out["mana_frac"] = ma_c / ma_m if ma_m else 1.0
        out["stam_frac"] = st_c / st_m if st_m else 1.0
    pm = re.search(r"position:\s*(\w+)", user)
    if pm:
        out["position"] = pm.group(1).lower()
    return out


def action_of(assistant):
    """(kind, tool, arg_text, spell_kw) — spell_kw normalized if this is a cast."""
    if not assistant:
        return None
    tcs = assistant.get("tool_calls")
    if tcs:
        tc = tcs[0]["function"]
        name = tc["name"]
        try:
            args = json.loads(tc["arguments"])
        except (json.JSONDecodeError, TypeError):
            args = {}
        if name == "cast":
            kw = (args.get("spell") or args.get("name") or "").strip().lower()
            return ("cast", name, tc["arguments"], normalize_spell(kw))
        if name == "command":
            text = (args.get("text") or "").strip()
            parts = text.lower().split()
            if parts and parts[0] in ("c", "cast", "cs") and len(parts) > 1:
                return ("cast", name, text, normalize_spell(parts[1]))
            return ("command", name, text, None)
        return (name, name, tc["arguments"], None)
    content = (assistant.get("content") or "").strip()
    if content:
        m = re.match(r"CMD:\s*(.+)", content)
        if m:
            parts = m.group(1).lower().split()
            if parts and parts[0] in ("c", "cast") and len(parts) > 1:
                return ("cast", "cmd", m.group(1), normalize_spell(parts[1]))
        return ("text", "cmd", content, None)
    return None


def normalize_spell(kw):
    kw = kw.strip().strip("'\"")
    return SPELL_FIX.get(kw, kw)


def rewrite_spell_label(assistant, canon):
    """Fix a typo'd spell keyword in-place in the assistant action (for training output)."""
    tcs = assistant.get("tool_calls")
    if not tcs:
        return
    tc = tcs[0]["function"]
    if tc["name"] != "command":
        return
    try:
        args = json.loads(tc["arguments"])
    except (json.JSONDecodeError, TypeError):
        return
    text = (args.get("text") or "")
    parts = text.split()
    if len(parts) >= 2 and parts[0].lower() in ("c", "cast", "cs"):
        if parts[1].lower() != canon:
            parts[1] = canon
            args["text"] = " ".join(parts)
            tc["arguments"] = json.dumps(args)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--traces", default=DEFAULT_TRACES)
    ap.add_argument("--out", default=os.path.join(HERE, "data"))
    ap.add_argument("--scope", choices=["combat", "adjacent"], default="adjacent",
                    help="combat: only fighting turns. adjacent: also keep recover/flee/heal "
                         "turns (survival policy), even out of combat. (default adjacent)")
    ap.add_argument("--include-old", action="store_true",
                    help="also use pre-`ts` old-schema rows (default: new-schema only)")
    ap.add_argument("--finisher-hp", type=int, default=15,
                    help="enemy HP%% at/below which a cast counts as a finisher (default 15)")
    ap.add_argument("--w-finisher", type=int, default=4)
    ap.add_argument("--w-switch", type=int, default=3)
    ap.add_argument("--w-recover", type=int, default=2)
    ap.add_argument("--w-sustain", type=int, default=1)
    ap.add_argument("--sustain-cap", type=int, default=3,
                    help="keep at most N identical consecutive sustain casts per fight (default 3)")
    ap.add_argument("--fight-gap", type=int, default=180,
                    help="seconds between turns that starts a new fight for switch/cap logic")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    rows = load_rows(args.traces, args.include_old)

    # ---- pass 1: parse + dedup, carry fight context forward ----
    seen = set()
    parsed = []            # kept, in order
    dup = 0
    last_ts = None
    fight_id = 0
    last_cast = None       # spell kw of previous cast in current fight
    sustain_run = 0        # consecutive identical sustain casts in current fight
    prev_in_combat = False

    stats = Counter()
    spell_raw = Counter()

    junk_labels = 0
    salvaged_labels = 0
    for obj in rows:
        msgs = obj["messages"]
        user = next((m["content"] for m in msgs if m.get("role") == "user"), "")
        assistant = next((m for m in msgs if m.get("role") == "assistant"), None)

        # drop/salvage corrupt command labels (mouse-escape fragments, up-arrow history recalls)
        if assistant and assistant.get("tool_calls"):
            fn = assistant["tool_calls"][0].get("function") or {}
            if fn.get("name") == "command":
                raw = fn.get("arguments")
                try:
                    cargs = json.loads(raw) if isinstance(raw, str) else (raw or {})
                except (json.JSONDecodeError, TypeError):
                    cargs = {}
                clean = sanitize_command_label(cargs.get("text"))
                if clean is None:
                    junk_labels += 1
                    continue
                if clean != cargs.get("text"):
                    salvaged_labels += 1
                    cargs["text"] = clean
                    fn["arguments"] = json.dumps(cargs) if isinstance(raw, str) else cargs

        act = action_of(assistant)
        if not act:
            continue
        kind, tool, arg_text, spell = act
        in_combat, mob, hp = parse_combat(user)
        vit = parse_vitals(user)
        ts = obj.get("ts")

        # fight segmentation
        new_fight = (in_combat and not prev_in_combat)
        if last_ts is not None and ts is not None and (ts - last_ts) > args.fight_gap:
            new_fight = new_fight or in_combat
        if new_fight:
            fight_id += 1
            last_cast = None
            sustain_run = 0
        prev_in_combat = in_combat
        if ts is not None:
            last_ts = ts

        # dedup exact (state+action)
        sig = (state_block(user), kind, tool, arg_text)
        h = hash(sig)
        if h in seen:
            dup += 1
            continue
        seen.add(h)

        # classify + weight
        tags = []
        w = 0
        is_cast = kind == "cast"
        if is_cast and spell:
            spell_raw[spell] += 1

        if in_combat and is_cast:
            is_switch = last_cast is not None and spell != last_cast
            is_finisher = (hp is not None and hp <= args.finisher_hp) or spell == "soulsteal"
            if is_finisher:
                tags.append("finisher")
                w = max(w, args.w_finisher)
            if is_switch:
                tags.append("switch")
                w = max(w, args.w_switch)
            if not tags:
                # sustain: same spell as last, mid-HP. Cap the run.
                if spell == last_cast:
                    sustain_run += 1
                else:
                    sustain_run = 1
                if sustain_run > args.sustain_cap:
                    last_cast = spell
                    continue  # drop over-cap sustain spam entirely
                tags.append("sustain")
                w = max(w, args.w_sustain)
            else:
                sustain_run = 0
            if spell in AOE_SPELLS:
                tags.append("aoe")
            last_cast = spell
        elif in_combat:
            # non-cast combat action (flee/attack/etc.)
            tags.append("combat_" + kind)
            w = max(w, args.w_sustain)
        else:
            # out of combat: only keep survival-relevant actions in adjacent scope
            recover_like = kind in ("recover", "flee") or (
                kind == "cast" and spell in ("sooth", "cure light", "cure serious", "heal"))
            low = vit.get("hp_frac", 1) < 0.5 or vit.get("mana_frac", 1) < 0.3
            if args.scope == "adjacent" and recover_like:
                tags.append("recover" if kind == "recover" else kind)
                w = max(w, args.w_recover if low else 1)
            else:
                continue  # drop non-combat, non-survival turns

        if w == 0:
            continue

        # strip ONLY the label-leaking tail echo from the training context. Labels are collected
        # from the assistant BEFORE the spell-typo rewrite, since the echo shows what was typed.
        labels = label_texts(assistant)
        for m in msgs:
            if m.get("role") == "user":
                m["content"] = strip_label_echo(m.get("content") or "", labels)

        # normalize typo'd spell in the label we'll actually train on
        if is_cast and spell and assistant:
            rewrite_spell_label(assistant, spell)

        parsed.append({
            "messages": msgs, "w": w, "tags": tags,
            "hp": hp, "spell": spell if is_cast else None, "fight": fight_id,
        })
        for t in tags:
            stats[t] += 1

    # ---- summary ----
    kept = len(parsed)
    expanded = sum(r["w"] for r in parsed)
    spell_weighted = Counter()
    spell_kept = Counter()
    for r in parsed:
        if r["spell"]:
            spell_kept[r["spell"]] += 1
            spell_weighted[r["spell"]] += r["w"]

    summary = {
        "input_rows": len(rows),
        "junk_labels_dropped": junk_labels,
        "labels_salvaged_from_escapes": salvaged_labels,
        "duplicates_dropped": dup,
        "kept_decisions": kept,
        "training_rows_after_weighting": expanded,
        "by_tag": dict(stats.most_common()),
        "spell_kept": dict(spell_kept.most_common()),
        "spell_after_weighting": dict(spell_weighted.most_common()),
        "weights": {"finisher": args.w_finisher, "switch": args.w_switch,
                    "recover": args.w_recover, "sustain": args.w_sustain,
                    "sustain_cap": args.sustain_cap, "finisher_hp": args.finisher_hp},
        "scope": args.scope,
    }

    def pct(c):
        tot = sum(c.values()) or 1
        return {k: f"{v} ({100*v/tot:.1f}%)" for k, v in c.most_common()}

    print(f"input rows (schema-filtered): {len(rows)}")
    print(f"junk labels dropped:          {junk_labels} (salvaged from escapes: {salvaged_labels})")
    print(f"exact dupes dropped:          {dup}")
    print(f"kept decisions:               {kept}")
    print(f"training rows after weighting:{expanded}")
    print("\nby tag:")
    for k, v in stats.most_common():
        print(f"  {v:5d}  {k}")
    print("\nspell mix BEFORE weighting:", pct(spell_kept))
    print("spell mix AFTER  weighting:", pct(spell_weighted))

    if args.dry_run:
        print("\n[dry-run] nothing written")
        return

    os.makedirs(args.out, exist_ok=True)
    clean_p = os.path.join(args.out, "combat_clean.jsonl")
    train_p = os.path.join(args.out, "combat_train.jsonl")
    stats_p = os.path.join(args.out, "combat_stats.json")
    with open(clean_p, "w") as f:
        for r in parsed:
            f.write(json.dumps(r) + "\n")
    with open(train_p, "w") as f:
        for r in parsed:
            row = {"messages": r["messages"]}
            for _ in range(r["w"]):
                f.write(json.dumps(row) + "\n")
    with open(stats_p, "w") as f:
        json.dump(summary, f, indent=2)
    print(f"\nwrote {kept} -> {clean_p}")
    print(f"wrote {expanded} -> {train_p}")
    print(f"wrote stats -> {stats_p}")


if __name__ == "__main__":
    main()
