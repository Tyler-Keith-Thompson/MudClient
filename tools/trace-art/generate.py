#!/usr/bin/env python3
"""
trace-art: turn "iconic moments" from AlterAeon game traces into AI art.

Forward-only / incremental: keeps a byte-offset cursor into human-traces.jsonl
and only ever processes NEWLY appended lines. The gallery grows; old moments are
never regenerated. Designed to run unattended (launchd, 4 AM). Every external
dependency (ComfyUI, the Claude API) degrades gracefully -- a missing key or a
down server logs and exits non-fatally instead of crashing the cron.

Stdlib only (urllib/json/re) so there is nothing to `pip install` at 4 AM.

Usage:
    generate.py                      # normal incremental run
    generate.py --init               # (re)initialize cursor to current EOF, do nothing else
    generate.py --smoke              # ignore cursor; render the single best moment from the file TAIL
    generate.py --max N              # cap images this run (default 3)
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

CLAUDE_MODEL = os.environ.get("TRACE_ART_MODEL", "claude-sonnet-5")
CLAUDE_URL = "https://api.anthropic.com/v1/messages"
CLAUDE_VERSION = "2023-06-01"


def log(msg):
    print(f"[{datetime.now().isoformat(timespec='seconds')}] {msg}", flush=True)


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
# Higher score == more iconic. Regexes were confirmed against real trace lines.
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
    """Return (score, event_type, detail) for the strongest signal, or None."""
    out = strip_ansi(output_section(text))
    best = None
    for name, prio, rx in SIGNALS:
        m = rx.search(out)
        if not m:
            continue
        score = prio
        detail = (m.group(1).strip() if m.groups() and m.group(1) else m.group(0).strip())
        if name == "kill":
            expm = EXP_RE.search(out)
            exp = int(expm.group(1).replace(",", "")) if expm else 0
            # scale big kills up; 5000xp -> +25, caps so it can't beat a death
            score = prio + min(exp / 200.0, 45)
            detail = f"{detail} (+{exp} xp)" if exp else detail
        if name == "near_death_escape":
            hp = re.search(r"hp:\s*(\d+)\s*/\s*(\d+)", text)
            if hp and int(hp.group(2)) and int(hp.group(1)) / int(hp.group(2)) < 0.25:
                score = prio + 10  # true low-hp escape
            else:
                score = 15         # routine flee, low signal
        if best is None or score > best[0]:
            best = (score, name, detail)
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


def template_prompt(event_type, detail, state, snippet):
    room = _clean(state.get("room", "a dark dungeon")) or "a dark dungeon"
    area = _clean(state.get("area", ""))
    name = _clean(state.get("name", "a lone adventurer")) or "a lone adventurer"
    detail = _clean(detail)
    setting = f"in {room}" + (f", {area}" if area else "")
    scenes = {
        "player_death": f"The fall of {name} {setting}; a fallen hero's final moment, spirit rising, somber and heroic",
        "achievement": f"{name} triumphant {setting}, achievement unlocked: {detail}, glory and light",
        "quest_complete": f"{name} completing an epic quest {setting}: {detail}, victorious",
        "level_up": f"{name} surging with new power {setting}, radiant burst of energy, ascending to level {detail}",
        "level_up2": f"{name} surging with new power {setting}, radiant burst of energy, now {detail}",
        "kill": f"{name} striking the killing blow against {detail} {setting}, dramatic combat, weapons and magic clashing",
        "near_death_escape": f"{name} narrowly escaping death {setting}, bloodied and fleeing through peril, desperate and tense",
    }
    scene = scenes.get(event_type, f"{name} {setting}: {detail}")
    return f"{scene}. {STYLE}."


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


def build_prompt(event_type, detail, state, snippet):
    p = claude_prompt(event_type, detail, state, snippet)
    if p:
        return p, "claude"
    return template_prompt(event_type, detail, state, snippet), "template"


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


def append_gallery(rec):
    with open(GALLERY_PATH, "a") as f:
        f.write(json.dumps(rec) + "\n")


def process_candidates(candidates, max_images, dry_run):
    """candidates: list of dicts with score/event/detail/state/snippet/offset."""
    candidates.sort(key=lambda c: -c["score"])
    capped = len(candidates) > max_images
    picked = candidates[:max_images]
    if capped:
        log(f"{len(candidates)} iconic moments found; capping to {max_images} this run "
            f"(remaining moments are dropped, NOT deferred)")
    generated = 0
    for c in picked:
        prompt, prompt_src = build_prompt(c["event"], c["detail"], c["state"], c["snippet"])
        log(f"MOMENT score={c['score']:.0f} type={c['event']} detail={c['detail']!r} "
            f"prompt_src={prompt_src}")
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
                "trace_offset": c["offset"],
                "event_type": c["event"],
                "detail": c["detail"],
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
    """lines: iterable of (offset, line). Returns candidate list."""
    cands = []
    for offset, line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except ValueError:
            continue
        msgs = d.get("messages", [])
        text = user_text(msgs)
        if not text:
            continue
        m = score_moment(text)
        if not m:
            continue
        score, event, detail = m
        cands.append({"score": score, "event": event, "detail": detail,
                      "state": parse_state(text), "snippet": moment_snippet(text),
                      "offset": offset})
    return cands


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--init", action="store_true", help="set cursor to EOF and exit")
    ap.add_argument("--smoke", action="store_true", help="render best moment from file tail, ignore cursor")
    ap.add_argument("--max", type=int, default=DEFAULT_MAX)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    os.makedirs(IMAGES_DIR, exist_ok=True)

    if not os.path.exists(TRACES):
        log(f"traces file missing: {TRACES}; nothing to do")
        return 0

    if args.init:
        init_cursor()
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
        cands = scan_lines(iter_new_lines(start))
        log(f"smoke: {len(cands)} candidate moments in tail")
        if not cands:
            log("smoke: no iconic moment found in tail")
            return 1
        if not comfy_up() and not args.dry_run:
            return 0
        n = process_candidates(cands, 1, args.dry_run)
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

    cands = scan_lines(lines)
    log(f"found {len(cands)} iconic moment(s) in new data")

    if cands and not args.dry_run and not comfy_up():
        log("ComfyUI down; NOT advancing cursor so moments retry next run")
        return 0

    n = process_candidates(cands, args.max, args.dry_run)

    if not args.dry_run:
        st2 = os.stat(TRACES)
        write_cursor(new_offset, st2)
        log(f"cursor advanced to offset={new_offset}; generated {n} image(s)")
    else:
        log("dry-run: cursor NOT advanced")
    return 0


if __name__ == "__main__":
    sys.exit(main())
