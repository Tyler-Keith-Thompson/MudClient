#!/usr/bin/env python3
"""
trace-art: turn "iconic moments" from AlterAeon game traces into AI art.

Forward-only / incremental: keeps a byte-offset cursor into human-traces.jsonl
and only ever processes NEWLY appended lines. The gallery grows; old moments are
never regenerated. Designed to run unattended (launchd, 4 AM). Every external
dependency (ComfyUI, the Claude API) degrades gracefully -- a missing key or a
down server logs and exits non-fatally instead of crashing the cron.

Stdlib only (urllib/json/re) so there is nothing to `pip install` at 4 AM.

Selection + prompt-writing are done by a LOCAL LLM (LM Studio, OpenAI-compatible,
no key) using the AlterAeon fine-tuned Qwen model; a heuristic is the fallback.
The Qwen "thinking" mode is disabled (empty <think></think> assistant prefill +
enable_thinking:false) because it empties structured output.

Usage:
    generate.py                      # normal incremental run (forward-only from cursor)
    generate.py --init               # (re)initialize cursor to current EOF, do nothing else
    generate.py --smoke              # ignore cursor; render the single best moment from the file TAIL
    generate.py --backfill           # one-time, resumable pass over the WHOLE file to seed the gallery
    generate.py --max N              # cap images this run (default 3 daily, 25 backfill)
    generate.py --dry-run            # detect + build prompt, but do NOT call ComfyUI
"""

import argparse
import json
import os
import random
import re
import sys
import time
import urllib.request
import urllib.error
from datetime import datetime

# ---------------------------------------------------------------------------
# Paths / config
# ---------------------------------------------------------------------------
HOME = os.path.expanduser("~")
# Paths are env-overridable (used by tests); production uses the defaults.
TRACES = os.environ.get("TRACE_ART_TRACES",
                        os.path.join(HOME, "Documents", "MudClient", "human-traces.jsonl"))
OUT_DIR = os.environ.get("TRACE_ART_OUT",
                         os.path.join(HOME, "Documents", "MudClient", "trace-art"))
IMAGES_DIR = os.path.join(OUT_DIR, "images")
CURSOR_PATH = os.path.join(OUT_DIR, ".cursor.json")
GALLERY_PATH = os.path.join(OUT_DIR, "gallery.jsonl")
PICK_STATE = os.path.join(OUT_DIR, ".badass_pick.json")  # last wallpaper pick, so we rotate to newer art

COMFY = os.environ.get("COMFY_HOST", "http://127.0.0.1:8188")

# Z-Image Turbo model files (verified installed)
UNET = "z_image_turbo_bf16.safetensors"
CLIP = "qwen_3_4b.safetensors"
CLIP_TYPE = "lumina2"           # from the golden template CLIPLoader widget
VAE = "ae.safetensors"

# Turbo sampler settings copied verbatim from the golden template
# (image_z_image_turbo.json): KSampler steps=8 cfg=1 res_multistep/simple,
# ModelSamplingAuraFlow shift=3, 1024x1024.
STEPS = 8
CFG = 1.0
SAMPLER = "res_multistep"
SCHEDULER = "simple"
SHIFT = 3
WIDTH = 1024
HEIGHT = 1024

DEFAULT_MAX = 3
BACKFILL_MAX = 25
# Cap how many top heuristic candidates we hand the LLM to re-rank (bounds LLM cost).
LLM_RANK_POOL = 60

# Character whose own brag-channel moments are weighted highest.
PLAYER = os.environ.get("TRACE_ART_PLAYER", "Vaelith")

# --- Local LLM (LM Studio, OpenAI-compatible) : PRIMARY selection + prompts ---
LLM_BASE = os.environ.get("TRACE_ART_LLM_BASE", "http://localhost:1234/v1")
LLM_MODEL = os.environ.get("TRACE_ART_MODEL", "qwen3.6-27b-alteraeon-mlx")

# --- Anthropic (optional SECONDARY, only if ANTHROPIC_API_KEY is set) ---
CLAUDE_MODEL = os.environ.get("TRACE_ART_ANTHROPIC_MODEL", "claude-sonnet-5")
CLAUDE_URL = "https://api.anthropic.com/v1/messages"
CLAUDE_VERSION = "2023-06-01"


def log(msg):
    # stderr, not stdout — so machine-readable subcommands (e.g. --pick-badass, which prints ONLY a
    # chosen image path to stdout) stay parseable. The launchd job captures both streams to its logfile.
    print(f"[{datetime.now().isoformat(timespec='seconds')}] {msg}", file=sys.stderr, flush=True)


# ---------------------------------------------------------------------------
# Cursor state (byte offset + size/inode sanity)
# ---------------------------------------------------------------------------
def read_cursor():
    try:
        with open(CURSOR_PATH) as f:
            return json.load(f)
    except (FileNotFoundError, ValueError):
        return None


def write_cursor(offset, st):
    tmp = CURSOR_PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump({"offset": offset, "size": st.st_size, "inode": st.st_ino,
                   "updated": datetime.now().isoformat(timespec="seconds")}, f, indent=2)
    os.replace(tmp, CURSOR_PATH)


def init_cursor():
    st = os.stat(TRACES)
    write_cursor(st.st_size, st)
    log(f"cursor initialized to EOF: offset={st.st_size} (backlog NOT rendered)")


# ---------------------------------------------------------------------------
# Iconic-moment detection
# ---------------------------------------------------------------------------
# High-value (notify) brag-channel events (regexes confirmed against real traces).
#   (notify) <name> stole a level <N> soul from <mob> (freak <M>!)
#   (notify) <name> landed a heinous backstab on <mob> for <N> damage, freak <M>!
NOTIFY_SOULSTEAL = re.compile(
    r"\(notify\)\s+(\w+)\s+stole a level\s+(\d+)\s+soul from\s+(.+?)\s+\(freak\s+(\d+)!?\)")
NOTIFY_BACKSTAB = re.compile(
    r"\(notify\)\s+(\w+)\s+landed a heinous backstab on\s+(.+?)\s+for\s+([\d,]+)\s+damage,\s+freak\s+(\d+)!?")
NOTIFY_ANY = re.compile(r"\(notify\)\s+([^\n<]{4,140})")
# First-person soulsteal captures (necromancer soul magic).
FP_SOULSTEAL = re.compile(
    r"separate soul from body,[^\n]*?pull\s+(.+?)'s essence into a\s+(\w+)\s+soulstone", re.I)
FP_LATCH = re.compile(r"latch onto\s+(.+?)'s soul", re.I)

# Higher priority == more iconic. Regexes confirmed against real trace lines.
SIGNALS = [
    # (name, priority, regex)  -- regex captures optional context in group(1)
    ("player_death", 100, re.compile(r"You have been (?:killed|slain)|You are DEAD|You feel your spirit|Your soul (?:leaves|departs)|You have died at the hands", re.I)),
    ("achievement", 90, re.compile(r"You have completed the achievement:\s*([^\n]+)")),
    ("quest_complete", 85, re.compile(r"You have completed (?:the )?(?:quest|task)[^\n]*", re.I)),
    ("level_up", 80, re.compile(r"YOU GAIN A LEVEL!\s*\n?You are now level\s+([^\n]+)")),
    ("level_up2", 78, re.compile(r"You are now level\s+(\d+\s+\w+[^\n]*)")),
    ("kill", 50, re.compile(r"([A-Za-z][\w '\-]+?) is DEAD!")),
    ("near_death_escape", 40, re.compile(r"(?:You flee|You attempt to flee|You panic and flee)", re.I)),
]

# Big-kill bonus: parse the experience reward so boss kills rank above trash.
EXP_RE = re.compile(r"You (?:receive|gain)\s+([\d,]+)\s+experience")


def detect_notify(out, text):
    """Detect the high-value (notify)/soulsteal signals. Returns a moment dict or None.
    (notify) lines are the global brag channel; the PLAYER's own soulsteals, ordered
    by 'freak' rarity, are weighted highest."""
    def is_me(name):
        return name.lower() == PLAYER.lower()

    m = NOTIFY_SOULSTEAL.search(out)
    if m:
        who, lvl, mob, freak = m.group(1), int(m.group(2)), m.group(3).strip(), int(m.group(4))
        mine = is_me(who)
        # Player's own: base 200 + freak (freak64 -> 264, dominates everything).
        # Other players' brags still high but below the player's own.
        score = (200 if mine else 120) + freak
        return {"score": score, "event": "soulsteal", "detail": f"{who} stole a level {lvl} soul from {mob} (freak {freak}!)",
                "meta": {"player": who, "mine": mine, "mob": mob, "level": lvl, "freak": freak}}

    m = NOTIFY_BACKSTAB.search(out)
    if m:
        who, mob, dmg, freak = m.group(1), m.group(2).strip(), int(m.group(3).replace(",", "")), int(m.group(4))
        mine = is_me(who)
        score = (160 if mine else 110) + freak
        return {"score": score, "event": "backstab", "detail": f"{who} landed a heinous backstab on {mob} for {dmg} damage (freak {freak}!)",
                "meta": {"player": who, "mine": mine, "mob": mob, "damage": dmg, "freak": freak}}

    m = FP_SOULSTEAL.search(out)
    if m:
        mob, color = m.group(1).strip(), m.group(2)
        return {"score": 108, "event": "soulsteal", "detail": f"{PLAYER} tore {mob}'s soul into a {color} soulstone",
                "meta": {"player": PLAYER, "mine": True, "mob": mob, "freak": 0}}

    m = NOTIFY_ANY.search(out)
    if m:
        line = m.group(1).strip()
        who = line.split()[0] if line.split() else ""
        mine = is_me(who)
        return {"score": (105 if mine else 100), "event": "notify", "detail": line[:120],
                "meta": {"player": who, "mine": mine}}
    return None


def strip_ansi(s):
    return re.sub(r"\x1b\[[0-9;]*m", "", s)


def user_text(messages):
    for m in messages:
        if m.get("role") == "user":
            c = m.get("content")
            return c if isinstance(c, str) else json.dumps(c)
    return ""


def assistant_action(messages):
    for m in messages:
        if m.get("role") == "assistant":
            for tc in (m.get("tool_calls") or []):
                fn = tc.get("function", {})
                return fn.get("name"), fn.get("arguments")
    return None, None


def output_section(text):
    """Return just the recent-game-OUTPUT portion (best effort)."""
    m = re.search(r"(?:RECENT GAME OUTPUT|GAME OUTPUT|OUTPUT)\s*===", text)
    if m:
        return text[m.end():]
    return text


def parse_state(text):
    st = {}
    for key in ("name", "room", "area", "hp"):
        m = re.search(rf"^{key}:\s*([^\n]+)", text, re.M)
        if m:
            st[key] = m.group(1).strip()
    return st


def score_moment(text):
    """Return the strongest moment as a dict {score,event,detail,meta} or None."""
    out = strip_ansi(output_section(text))
    # (notify)/soulsteal signals dominate and carry their own meta.
    notify = detect_notify(out, text)
    best = notify
    for name, prio, rx in SIGNALS:
        m = rx.search(out)
        if not m:
            continue
        score = prio
        detail = (m.group(1).strip() if m.groups() and m.group(1) else m.group(0).strip())
        meta = {}
        if name == "kill":
            expm = EXP_RE.search(out)
            exp = int(expm.group(1).replace(",", "")) if expm else 0
            # scale big kills up; 5000xp -> +25, caps so it can't beat a death
            score = prio + min(exp / 200.0, 45)
            meta = {"mob": detail, "exp": exp}
            detail = f"{detail} (+{exp} xp)" if exp else detail
        if name == "near_death_escape":
            hp = re.search(r"hp:\s*(\d+)\s*/\s*(\d+)", text)
            if hp and int(hp.group(2)) and int(hp.group(1)) / int(hp.group(2)) < 0.25:
                score = prio + 10  # true low-hp escape
            else:
                score = 15         # routine flee, low signal
        if best is None or score > best["score"]:
            best = {"score": score, "event": name, "detail": detail, "meta": meta}
    return best


def moment_snippet(text, maxlen=900):
    out = strip_ansi(output_section(text)).strip()
    return out[-maxlen:]


# ---------------------------------------------------------------------------
# Prompt building
# ---------------------------------------------------------------------------
STYLE = ("dramatic high-fantasy digital painting, cinematic lighting, dynamic "
         "composition, painterly, epic atmosphere, rich color, highly detailed, "
         "artstation trending")


def _clean(s):
    """Sanitize a fragment for image prompts: drop parentheticals (xp counts),
    numbers, and trailing punctuation so the model doesn't render literal text."""
    s = re.sub(r"\([^)]*\)", "", s)          # (+47514 xp)
    s = re.sub(r"\b\d[\d,]*\b", "", s)        # stray numbers
    s = re.sub(r"^(a|an|the)\s+", "", s.strip(), flags=re.I)
    return s.strip(" .,;:'\"").strip()


def template_prompt(moment, state, snippet):
    event_type, detail = moment["event"], moment["detail"]
    meta = moment.get("meta", {})
    room = _clean(state.get("room", "a dark dungeon")) or "a dark dungeon"
    area = _clean(state.get("area", ""))
    name = _clean(state.get("name", "a lone adventurer")) or "a lone adventurer"
    if meta.get("player"):
        name = _clean(meta["player"]) or name
    mob = _clean(meta.get("mob", "")) or "a fearsome foe"
    freak = meta.get("freak", 0)
    rare = "an incredibly rare, legendary" if freak >= 32 else ("a rare" if freak >= 16 else "a")
    cd = _clean(detail)
    setting = f"in {room}" + (f", {area}" if area else "")
    scenes = {
        "soulsteal": f"{name} the soul-reaver ripping the glowing soul out of {mob} {setting}, {rare} soul-harvest, a spectral essence torn free and swirling into a radiant soulstone, necromantic energy, ghostly light",
        "backstab": f"{name} driving a dagger into {mob} from the shadows {setting}, a devastating {rare} critical strike, blood and steel, shadowy assassin",
        "notify": f"{name} performing a legendary feat {setting}: {cd}, epic and heroic",
        "player_death": f"The fall of {name} {setting}; a fallen hero's final moment, spirit rising, somber and heroic",
        "achievement": f"{name} triumphant {setting}, achievement unlocked: {cd}, glory and light",
        "quest_complete": f"{name} completing an epic quest {setting}: {cd}, victorious",
        "level_up": f"{name} surging with new power {setting}, radiant burst of energy, ascending to a new level",
        "level_up2": f"{name} surging with new power {setting}, radiant burst of energy, {cd}",
        "kill": f"{name} striking the killing blow against {mob} {setting}, dramatic combat, weapons and magic clashing",
        "near_death_escape": f"{name} narrowly escaping death {setting}, bloodied and fleeing through peril, desperate and tense",
    }
    scene = scenes.get(event_type, f"{name} {setting}: {cd}")
    return f"{scene}. {STYLE}."


# ---------------------------------------------------------------------------
# Local LLM (LM Studio, OpenAI-compatible) -- PRIMARY selection + prompts.
# Qwen3.6 "thinking" mode empties structured output; we disable it two ways:
#   1. append an empty "<think></think>" assistant prefill (model continues after it)
#   2. pass chat_template_kwargs.enable_thinking=false
# and we VALIDATE returned JSON, retrying once on garbage.
# ---------------------------------------------------------------------------
def _llm_chat(messages, max_tokens=400, temperature=0.4):
    """POST to LM Studio /chat/completions with thinking disabled. Returns content str or None."""
    body = json.dumps({
        "model": LLM_MODEL,
        "messages": messages + [{"role": "assistant", "content": "<think></think>"}],
        "temperature": temperature,
        "max_tokens": max_tokens,
        "chat_template_kwargs": {"enable_thinking": False},
    }).encode()
    req = urllib.request.Request(f"{LLM_BASE}/chat/completions", data=body, method="POST",
                                 headers={"content-type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            data = json.load(r)
        msg = data["choices"][0]["message"]
        return (msg.get("content") or "").strip()
    except Exception as e:
        log(f"LLM call failed ({e})")
        return None


def _extract_json(text):
    """Pull the first JSON object/array out of a model reply, or None."""
    if not text:
        return None
    text = re.sub(r"^```(?:json)?|```$", "", text.strip(), flags=re.M).strip()
    for open_c, close_c in (("{", "}"), ("[", "]")):
        i = text.find(open_c)
        j = text.rfind(close_c)
        if i >= 0 and j > i:
            try:
                return json.loads(text[i:j + 1])
            except ValueError:
                continue
    return None


def _llm_json(messages, max_tokens=600):
    """Call the LLM expecting JSON; validate + retry once on malformed output."""
    for attempt in range(2):
        content = _llm_chat(messages, max_tokens=max_tokens,
                            temperature=0.0 if attempt else 0.2)
        obj = _extract_json(content)
        if obj is not None:
            return obj
        if attempt == 0:
            log("LLM returned malformed JSON; retrying once")
    return None


def llm_available():
    try:
        urllib.request.urlopen(f"{LLM_BASE}/models", timeout=5).read()
        return True
    except Exception as e:
        log(f"LM Studio not reachable at {LLM_BASE} ({e})")
        return False


# ---------------------------------------------------------------------------
# "Most badass" pick (drives the iTerm2 wallpaper — see `just run` / tools/trace-art README)
# ---------------------------------------------------------------------------
def _badass_heuristic_key(rec):
    """Fallback ranking when the LLM is unavailable: your own steals > rarer freak > higher level."""
    m = rec.get("meta") or {}
    return (1 if m.get("mine") else 0, m.get("freak") or 0, m.get("level") or 0)


def _read_last_pick():
    """The image_path of the wallpaper we showed last time (str), or None."""
    try:
        with open(PICK_STATE) as f:
            return (json.load(f) or {}).get("last")
    except (FileNotFoundError, ValueError):
        return None


def _write_last_pick(image_path):
    """Record the just-shown wallpaper so the next pick rotates past it. Best-effort (never fatal)."""
    tmp = PICK_STATE + ".tmp"
    try:
        with open(tmp, "w") as f:
            json.dump({"last": image_path,
                       "updated": datetime.now().isoformat(timespec="seconds")}, f, indent=2)
        os.replace(tmp, PICK_STATE)
    except OSError:
        pass


def pick_badass(last_n=5):
    """Of the last `last_n` gallery images that still exist on disk, return the path to the single most
    'badass' one — judged by the local LM Studio model from each moment's text (no vision model needed),
    with a heuristic fallback. Returns None if there are no usable images. Prints nothing (path is the
    caller's to emit); all diagnostics go through log() → stderr."""
    records = []
    try:
        with open(GALLERY_PATH) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                p = rec.get("image_path")
                if p and os.path.exists(p):
                    records.append(rec)
    except FileNotFoundError:
        log(f"no gallery at {GALLERY_PATH}")
        return None
    if not records:
        log("no gallery images on disk yet")
        return None

    # Rotate to NEW art: judge among the images added SINCE the one we last showed, not the whole recent
    # window. Otherwise the LLM keeps re-picking its lingering favourite and the wallpaper never changes as
    # fresh moments arrive. `.badass_pick.json` remembers the last pick; candidates are the gallery entries
    # after it (capped at last_n so a burst of new art still judges a bounded set). Fallbacks keep it robust:
    # if the last pick is gone or nothing is newer, use the recent window but still avoid re-picking the very
    # same image when there's any alternative.
    last_path = _read_last_pick()
    idx = next((i for i, r in enumerate(records) if r.get("image_path") == last_path), None)
    if idx is not None and idx + 1 < len(records):
        recent = records[idx + 1:][-last_n:]               # only art newer than the last wallpaper
    else:
        recent = [r for r in records[-last_n:] if r.get("image_path") != last_path] or records[-last_n:]

    if len(recent) == 1:
        pick = 0
    else:
        pick = None
        if llm_available():
            listing = "\n".join(
                "{i}: [{ev}] {detail}  (yours={mine}, freak={freak}, level={level})".format(
                    i=i, ev=r.get("event_type", "?"), detail=(r.get("detail") or "").strip(),
                    mine=bool((r.get("meta") or {}).get("mine")),
                    freak=(r.get("meta") or {}).get("freak"),
                    level=(r.get("meta") or {}).get("level"))
                for i, r in enumerate(recent))
            messages = [
                {"role": "system", "content":
                    "You curate a terminal wallpaper. Pick the single MOST badass, epic, dramatic moment — "
                    "brutal kills, rare soul steals (high freak), your own feats, narrow escapes. "
                    'Reply with ONLY compact JSON: {"pick": <index integer>}.'},
                {"role": "user", "content": "Choose the most badass moment by index:\n" + listing},
            ]
            obj = _llm_json(messages, max_tokens=40)
            if obj is not None:
                try:
                    cand = int(obj.get("pick"))
                    if 0 <= cand < len(recent):
                        pick = cand
                except (TypeError, ValueError):
                    pass
            if pick is None:
                log("LLM pick unusable; falling back to heuristic")

        if pick is None:
            pick = max(range(len(recent)), key=lambda i: _badass_heuristic_key(recent[i]))

    chosen = recent[pick].get("image_path")
    _write_last_pick(chosen)                               # remember it so the next run rotates past it
    log(f"picked #{pick} of {len(recent)} candidate(s): {recent[pick].get('detail','')}")
    return chosen


def llm_prompt(moment, state, snippet):
    """Ask the local fine-tuned model to write a cinematic Z-Image prompt. str or None."""
    sys_prompt = (
        "You write vivid image-generation prompts for a fantasy art model, and you "
        "know the MUD Alter Aeon. Given an iconic moment, output ONE prompt of 40-70 "
        "words describing it as an epic scene: subject, action, setting, mood, lighting. "
        "End with a comma-separated style-tag list. No preamble, no quotes, no game "
        "jargon or UI text. Reply with ONLY a JSON object: {\"prompt\": \"...\"}."
    )
    user_msg = (
        f"Event: {moment['event']}\nWhat happened: {moment['detail']}\n"
        f"Character: {state.get('name', PLAYER)} in {state.get('room','?')} "
        f"({state.get('area','')})\nRaw game log:\n{snippet[-1000:]}"
    )
    msgs = [{"role": "system", "content": sys_prompt},
            {"role": "user", "content": user_msg}]
    obj = _llm_json(msgs, max_tokens=400)
    if isinstance(obj, dict) and isinstance(obj.get("prompt"), str) and len(obj["prompt"]) > 15:
        return obj["prompt"].strip()
    # Robustness: some replies aren't valid JSON. Accept a clean plain-text prompt.
    raw = _llm_chat(msgs, max_tokens=400, temperature=0.3)
    if raw:
        raw = re.sub(r"^```.*?$|```", "", raw, flags=re.M).strip().strip('"')
        raw = re.sub(r'^\s*\{?\s*"?prompt"?\s*:\s*"?', "", raw).strip().strip('",').strip()
        raw = raw.replace("\n", " ").strip()
        if 20 < len(raw) < 900 and "{" not in raw:
            return raw
    return None


def llm_rank(candidates):
    """Ask the LLM to score each candidate 0-100 by how iconic/cool it is.
    Returns {index: score} or None. Player's own soulsteals should score highest."""
    lines = []
    for i, c in enumerate(candidates):
        lines.append(f"{i}: [{c['event']}] {c['detail'][:120]}")
    sys_prompt = (
        f"You are curating an art gallery of the coolest moments from {PLAYER}'s Alter "
        "Aeon adventures. Rate each moment 0-100 by how iconic, rare, and visually epic "
        f"it is. Weight {PLAYER}'s OWN rare soulsteals (higher 'freak' = rarer) and "
        "(notify) brag-channel feats highest; routine kills lowest. Reply with ONLY a "
        "JSON object {\"scores\": [{\"i\": <index>, \"s\": <0-100>}, ...]} covering every index."
    )
    obj = _llm_json([{"role": "system", "content": sys_prompt},
                     {"role": "user", "content": "\n".join(lines)}],
                    max_tokens=min(4000, 40 + 20 * len(candidates)))
    if not isinstance(obj, dict) or not isinstance(obj.get("scores"), list):
        return None
    out = {}
    for item in obj["scores"]:
        try:
            out[int(item["i"])] = float(item["s"])
        except (KeyError, ValueError, TypeError):
            continue
    return out or None


def claude_prompt(event_type, detail, state, snippet):
    """Use the Claude API to write a cinematic prompt. Returns str or None."""
    key = os.environ.get("ANTHROPIC_API_KEY")
    if not key:
        return None
    sys_prompt = (
        "You write vivid, concrete image-generation prompts for a fantasy art model. "
        "Given a moment from a MUD (text RPG) session, output ONE prompt (<=70 words, "
        "no preamble, no quotes) describing the scene cinematically: subject, action, "
        "setting, mood, lighting. End with a comma-separated style tag list. Do not "
        "mention text, UI, or game jargon."
    )
    user_msg = (
        f"Event type: {event_type}\nKey detail: {detail}\n"
        f"Character: {state.get('name','?')} in {state.get('room','?')} "
        f"({state.get('area','')})\nRaw game log:\n{snippet[-1200:]}"
    )
    body = json.dumps({
        "model": CLAUDE_MODEL,
        "max_tokens": 300,
        "system": sys_prompt,
        "messages": [{"role": "user", "content": user_msg}],
    }).encode()
    req = urllib.request.Request(
        CLAUDE_URL, data=body, method="POST",
        headers={"content-type": "application/json", "x-api-key": key,
                 "anthropic-version": CLAUDE_VERSION})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            data = json.load(r)
        parts = [b.get("text", "") for b in data.get("content", []) if b.get("type") == "text"]
        text = " ".join(parts).strip()
        return text or None
    except Exception as e:
        log(f"Claude API prompt failed ({e}); falling back to template")
        return None


def build_prompt(moment, state, snippet):
    """LM Studio (primary) -> Claude (secondary, if key) -> heuristic template."""
    p = llm_prompt(moment, state, snippet)
    if p:
        return p, "llm"
    p = claude_prompt(moment["event"], moment["detail"], state, snippet)
    if p:
        return p, "claude"
    return template_prompt(moment, state, snippet), "template"


# ---------------------------------------------------------------------------
# ComfyUI generation
# ---------------------------------------------------------------------------
def build_workflow(prompt, seed):
    """API-format graph, copied from the golden Z-Image Turbo template."""
    return {
        "28": {"class_type": "UNETLoader",
               "inputs": {"unet_name": UNET, "weight_dtype": "default"}},
        "30": {"class_type": "CLIPLoader",
               "inputs": {"clip_name": CLIP, "type": CLIP_TYPE, "device": "default"}},
        "29": {"class_type": "VAELoader", "inputs": {"vae_name": VAE}},
        "11": {"class_type": "ModelSamplingAuraFlow",
               "inputs": {"shift": SHIFT, "model": ["28", 0]}},
        "27": {"class_type": "CLIPTextEncode",
               "inputs": {"text": prompt, "clip": ["30", 0]}},
        "33": {"class_type": "ConditioningZeroOut",
               "inputs": {"conditioning": ["27", 0]}},
        "13": {"class_type": "EmptySD3LatentImage",
               "inputs": {"width": WIDTH, "height": HEIGHT, "batch_size": 1}},
        "3": {"class_type": "KSampler",
              "inputs": {"seed": seed, "steps": STEPS, "cfg": CFG,
                         "sampler_name": SAMPLER, "scheduler": SCHEDULER, "denoise": 1.0,
                         "model": ["11", 0], "positive": ["27", 0],
                         "negative": ["33", 0], "latent_image": ["13", 0]}},
        "8": {"class_type": "VAEDecode",
              "inputs": {"samples": ["3", 0], "vae": ["29", 0]}},
        "9": {"class_type": "SaveImage",
              "inputs": {"filename_prefix": "trace-art", "images": ["8", 0]}},
    }


def comfy_up():
    try:
        urllib.request.urlopen(f"{COMFY}/system_stats", timeout=5).read()
        return True
    except Exception as e:
        log(f"ComfyUI not reachable at {COMFY} ({e})")
        return False


def comfy_generate(prompt, seed, out_path):
    """Queue a prompt, poll history, fetch the PNG. Returns True on success."""
    wf = build_workflow(prompt, seed)
    body = json.dumps({"prompt": wf, "client_id": "trace-art"}).encode()
    req = urllib.request.Request(f"{COMFY}/prompt", data=body, method="POST",
                                 headers={"content-type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            pid = json.load(r)["prompt_id"]
    except urllib.error.HTTPError as e:
        log(f"/prompt rejected (HTTP {e.code}): {e.read().decode(errors='replace')[:800]}")
        return False
    except Exception as e:
        log(f"/prompt POST failed: {e}")
        return False

    log(f"queued prompt_id={pid}, polling...")
    img_ref = None
    deadline = time.time() + 300
    while time.time() < deadline:
        time.sleep(2)
        try:
            with urllib.request.urlopen(f"{COMFY}/history/{pid}", timeout=15) as r:
                hist = json.load(r)
        except Exception as e:
            log(f"history poll error: {e}")
            continue
        if pid not in hist:
            continue
        entry = hist[pid]
        status = entry.get("status", {})
        if status.get("status_str") == "error":
            log(f"ComfyUI reported error: {json.dumps(status)[:800]}")
            return False
        outs = entry.get("outputs", {})
        for node_out in outs.values():
            for img in node_out.get("images", []):
                img_ref = img
                break
        if img_ref:
            break
    if not img_ref:
        log("timed out waiting for image")
        return False

    q = urllib.parse.urlencode({"filename": img_ref["filename"],
                                "subfolder": img_ref.get("subfolder", ""),
                                "type": img_ref.get("type", "output")})
    try:
        with urllib.request.urlopen(f"{COMFY}/view?{q}", timeout=30) as r:
            data = r.read()
    except Exception as e:
        log(f"/view fetch failed: {e}")
        return False
    if len(data) < 1000:
        log(f"fetched image suspiciously small ({len(data)} bytes)")
        return False
    with open(out_path, "wb") as f:
        f.write(data)
    log(f"saved {out_path} ({len(data)} bytes)")
    return True


# ---------------------------------------------------------------------------
# Line iteration
# ---------------------------------------------------------------------------
def iter_new_lines(start_offset):
    """Yield (byte_offset_of_line_start, line_str) for complete lines from offset."""
    with open(TRACES, "rb") as f:
        f.seek(start_offset)
        pos = start_offset
        for raw in f:
            if not raw.endswith(b"\n"):
                break  # partial trailing line; leave for next run
            yield pos, raw.decode("utf-8", errors="replace")
            pos += len(raw)


def slug(s):
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")[:40] or "moment"


def moment_key(c):
    """Stable identity for a moment so the SAME event (traces are sliding windows,
    so one event recurs across many consecutive lines) generates exactly ONE image.
    Used for dedup within a run and resumable skip across runs."""
    e, meta = c["event"], c.get("meta", {})
    if e in ("soulsteal", "backstab"):
        return f"{e}:{meta.get('player','?').lower()}:{_clean(meta.get('mob','')).lower()}:freak{meta.get('freak',0)}:lvl{meta.get('level','')}"
    if e == "kill":
        return f"kill:{_clean(meta.get('mob','')).lower()}:xp{int(meta.get('exp',0))//1000}"
    if e in ("level_up", "level_up2"):
        return f"levelup:{re.sub(r'[^a-z0-9]+','',c['detail'].lower())[:40]}"
    if e in ("achievement", "quest_complete"):
        return f"{e}:{re.sub(r'[^a-z0-9]+','',c['detail'].lower())[:50]}"
    if e == "notify":
        return f"notify:{re.sub(r'[^a-z0-9]+','',c['detail'].lower())[:60]}"
    return f"{e}:{re.sub(r'[^a-z0-9]+','',c['detail'].lower())[:50]}"


def load_seen_keys():
    """Return set of moment keys already in the manifest (for resumable dedup)."""
    seen = set()
    try:
        with open(GALLERY_PATH) as f:
            for line in f:
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                if rec.get("key"):
                    seen.add(rec["key"])
    except FileNotFoundError:
        pass
    return seen


def append_gallery(rec):
    with open(GALLERY_PATH, "a") as f:
        f.write(json.dumps(rec) + "\n")


def dedup_candidates(candidates, seen_keys):
    """Collapse window-duplicate moments to one per key; drop already-generated keys.
    Keeps the highest-scoring instance of each unique moment."""
    best = {}
    for c in candidates:
        k = moment_key(c)
        if k in seen_keys:
            continue
        if k not in best or c["score"] > best[k]["score"]:
            c["key"] = k
            best[k] = c
    return list(best.values())


def process_candidates(candidates, max_images, dry_run, use_llm_rank=False):
    """candidates: list of moment dicts (already deduped). Optionally LLM-rerank."""
    # Heuristic order first (guarantees player soulsteals / high-freak float up even
    # if the LLM ranker is unavailable or noisy).
    candidates.sort(key=lambda c: -c["score"])

    if use_llm_rank and candidates and llm_available():
        pool = candidates[:LLM_RANK_POOL]
        scores = llm_rank(pool)
        if scores:
            for i, c in enumerate(pool):
                # blend: heuristic dominates (keeps soulsteals on top), LLM refines
                c["llm_score"] = scores.get(i, 0.0)
                c["score"] = c["score"] + c["llm_score"]
            log(f"LLM re-ranked top {len(pool)} candidates")
            candidates.sort(key=lambda c: -c["score"])
        else:
            log("LLM ranking unavailable/malformed; using heuristic order")

    capped = len(candidates) > max_images
    picked = candidates[:max_images]
    if capped:
        log(f"{len(candidates)} unique moments; capping to {max_images} this run "
            f"({len(candidates) - max_images} lower-ranked moments dropped, NOT deferred)")
    generated = 0
    for c in picked:
        prompt, prompt_src = build_prompt(c, c["state"], c["snippet"])
        log(f"MOMENT score={c['score']:.0f} type={c['event']} key={c.get('key')} "
            f"detail={c['detail']!r} prompt_src={prompt_src}")
        log(f"PROMPT: {prompt}")
        if dry_run:
            continue
        seed = random.randint(1, 2**31)
        ts = datetime.now().strftime("%Y%m%d-%H%M%S")
        fname = f"{ts}-{c['event']}-{slug(c['detail'])}.png"
        out_path = os.path.join(IMAGES_DIR, fname)
        if comfy_generate(prompt, seed, out_path):
            append_gallery({
                "timestamp": datetime.now().isoformat(timespec="seconds"),
                "key": c.get("key"),
                "trace_offset": c["offset"],
                "event_type": c["event"],
                "detail": c["detail"],
                "meta": c.get("meta", {}),
                "source_text": c["snippet"][-600:],
                "prompt": prompt,
                "prompt_source": prompt_src,
                "seed": seed,
                "image_path": out_path,
            })
            generated += 1
        else:
            log("generation failed for this moment (non-fatal); continuing")
    return generated


def scan_lines(lines):
    """lines: iterable of (offset, line). Returns candidate moment dicts."""
    cands = []
    for offset, line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except ValueError:
            continue
        text = user_text(d.get("messages", []))
        if not text:
            continue
        m = score_moment(text)
        if not m:
            continue
        m.update({"state": parse_state(text), "snippet": moment_snippet(text),
                  "offset": offset})
        cands.append(m)
    return cands


def scan_whole_file():
    """Stream the ENTIRE traces file (memory-light) for backfill. Returns candidates."""
    cands = []
    n = 0
    with open(TRACES, "rb") as f:
        pos = 0
        for raw in f:
            start = pos
            pos += len(raw)
            n += 1
            if not raw.endswith(b"\n"):
                break
            line = raw.decode("utf-8", errors="replace").strip()
            if not line:
                continue
            try:
                d = json.loads(line)
            except ValueError:
                continue
            text = user_text(d.get("messages", []))
            if not text:
                continue
            m = score_moment(text)
            if not m:
                continue
            m.update({"state": parse_state(text), "snippet": moment_snippet(text),
                      "offset": start})
            cands.append(m)
    log(f"backfill: scanned {n} trace lines, {len(cands)} raw candidate moments")
    return cands


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--init", action="store_true", help="set cursor to EOF and exit")
    ap.add_argument("--smoke", action="store_true", help="render best moment from file tail, ignore cursor")
    ap.add_argument("--backfill", action="store_true", help="one-time resumable pass over the WHOLE file")
    ap.add_argument("--max", type=int, default=None)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--pick-badass", action="store_true",
                    help="print the path to the most 'badass' of the last few gallery images and exit "
                         "(drives the iTerm2 wallpaper). Prints ONLY the path to stdout; nothing if none.")
    ap.add_argument("--last", type=int, default=5, help="how many recent images --pick-badass considers")
    args = ap.parse_args()

    # Pick-only mode: read-only over the existing gallery, no traces/cursor/ComfyUI needed.
    if args.pick_badass:
        path = pick_badass(args.last)
        if not path:
            return 1
        sys.stdout.write(path + "\n")
        return 0

    os.makedirs(IMAGES_DIR, exist_ok=True)

    if not os.path.exists(TRACES):
        log(f"traces file missing: {TRACES}; nothing to do")
        return 0

    if args.init:
        init_cursor()
        return 0

    if args.backfill:
        # One-time, resumable seed of the gallery from the ENTIRE history.
        # The daily cursor is untouched -> the 4 AM job stays forward-only.
        max_images = args.max if args.max is not None else BACKFILL_MAX
        log(f"BACKFILL: mining full history (max {max_images} images, player={PLAYER})")
        raw = scan_whole_file()                       # stage 1: cheap heuristic pre-filter
        seen = load_seen_keys()
        cands = dedup_candidates(raw, seen)           # collapse window dups + skip already-made
        log(f"backfill: {len(cands)} unique NEW moments after dedup "
            f"({len(seen)} already in gallery, skipped)")
        # surface the soulsteals we found so the operator can see freak values
        ss = sorted([c for c in cands if c["event"] in ("soulsteal", "backstab")],
                    key=lambda c: -c["meta"].get("freak", 0))
        for c in ss[:12]:
            mine = "MINE" if c["meta"].get("mine") else "other"
            log(f"  soulsteal/{mine} freak={c['meta'].get('freak',0)}: {c['detail']}")
        if not cands:
            log("backfill: nothing new to generate")
            return 0
        if not args.dry_run and not comfy_up():
            log("ComfyUI down; aborting backfill (rerun later, it resumes)")
            return 0
        n = process_candidates(cands, max_images, args.dry_run, use_llm_rank=True)
        log(f"backfill done, generated {n} image(s)")
        return 0

    if args.smoke:
        log("SMOKE TEST: scanning last ~4MB of traces, ignoring cursor")
        st = os.stat(TRACES)
        start = max(0, st.st_size - 4_000_000)
        # skip partial first line
        with open(TRACES, "rb") as f:
            f.seek(start)
            if start:
                f.readline()
                start = f.tell()
        raw = scan_lines(iter_new_lines(start))
        cands = dedup_candidates(raw, load_seen_keys())
        log(f"smoke: {len(cands)} unique candidate moments in tail")
        if not cands:
            log("smoke: no iconic moment found in tail")
            return 1
        if not comfy_up() and not args.dry_run:
            return 0
        n = process_candidates(cands, args.max or 1, args.dry_run, use_llm_rank=True)
        log(f"smoke done, generated {n} image(s)")
        return 0 if (n or args.dry_run) else 1

    # ---- normal incremental run ----
    st = os.stat(TRACES)
    cur = read_cursor()
    if cur is None:
        log("no cursor found; initializing to EOF (first install -> backlog skipped)")
        init_cursor()
        return 0

    offset = cur.get("offset", 0)
    if st.st_size < offset or (cur.get("inode") not in (None, st.st_ino)):
        log(f"file truncated/rotated (size={st.st_size} < cursor={offset} or inode changed); "
            f"resetting cursor to current EOF")
        write_cursor(st.st_size, st)
        return 0
    if st.st_size == offset:
        log(f"no new data past cursor (offset={offset}, size={st.st_size}); nothing to do")
        return 0

    log(f"scanning new bytes: {offset}..{st.st_size} ({st.st_size - offset} new)")
    lines = list(iter_new_lines(offset))
    # advance offset to the end of the last COMPLETE line we read
    if lines:
        last_off, last_line = lines[-1]
        new_offset = last_off + len(last_line.encode("utf-8"))
    else:
        new_offset = offset

    raw = scan_lines(lines)
    cands = dedup_candidates(raw, load_seen_keys())
    log(f"found {len(raw)} raw / {len(cands)} unique new iconic moment(s)")

    if cands and not args.dry_run and not comfy_up():
        log("ComfyUI down; NOT advancing cursor so moments retry next run")
        return 0

    n = process_candidates(cands, args.max or DEFAULT_MAX, args.dry_run, use_llm_rank=True)

    if not args.dry_run:
        st2 = os.stat(TRACES)
        write_cursor(new_offset, st2)
        log(f"cursor advanced to offset={new_offset}; generated {n} image(s)")
    else:
        log("dry-run: cursor NOT advanced")
    return 0


if __name__ == "__main__":
    sys.exit(main())
