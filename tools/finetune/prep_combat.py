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
    "sahrds": "shards", "sharsd": "shards", "shrads": "shards",
    "souslteal": "soulsteal", "soul": "soulsteal",
    "frost": "frostflower", "frostflwoer": "frostflower", "sfrostflower": "frostflower",
    "soothe": "sooth",
}
# Spells that are AoE (thrown early / on groups) — informational tagging only.
AOE_SPELLS = {"frostflower", "shower"}


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

    for obj in rows:
        msgs = obj["messages"]
        user = next((m["content"] for m in msgs if m.get("role") == "user"), "")
        assistant = next((m for m in msgs if m.get("role") == "assistant"), None)
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
