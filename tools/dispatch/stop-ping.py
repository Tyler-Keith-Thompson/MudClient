#!/usr/bin/env python3
"""Stop-hook → game ping.

Claude Code fires this on the Stop event (end of every assistant turn). It reads the turn's
final assistant text from the transcript, condenses it to one line, and drops a reply JSON into
the MudClient inbox (`~/Documents/MudClient/claude-inbox/`). The already-running app's
ClaudeInboxWatcher picks that up and echoes it in-game as a `↙ claude` line — so task
completions surface in the MUD automatically, without me having to remember to call report_to_game.

Contract with the app (see ClaudeReplyRenderer.parse in ClaudeInboxWatcher.swift): the file is
`{message, action?, ts?}` JSON; a blank/absent `message` is ignored. Inbox override env var is
`MUD_DISPATCH_INBOX` (same knob the app and MCP server honor).

Design choices:
  * NEVER fail the turn — any error just exits 0 without writing. A notification hook must not
    be able to break the session.
  * Skip pure no-text turns and turns that only ask the user a question (final line ends in
    '?') — those aren't "done", they're waiting on you, and pinging the game for them is noise.
  * One line, whitespace-collapsed, truncated — a `↙ claude` line is a status blip, not a report.
"""
import json
import os
import sys
import time
import binascii

MAXLEN = 220


def inbox_dir() -> str:
    override = os.environ.get("MUD_DISPATCH_INBOX", "").strip()
    if override:
        return override
    return os.path.expanduser("~/Documents/MudClient/claude-inbox")


def last_assistant_text(transcript_path: str) -> str:
    """The concatenated text blocks of the LAST assistant message that had any text."""
    found = ""
    try:
        with open(transcript_path, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    evt = json.loads(line)
                except Exception:
                    continue
                if evt.get("type") != "assistant":
                    continue
                content = (evt.get("message") or {}).get("content")
                if isinstance(content, str):
                    text = content
                elif isinstance(content, list):
                    text = "".join(
                        b.get("text", "") for b in content
                        if isinstance(b, dict) and b.get("type") == "text"
                    )
                else:
                    text = ""
                text = text.strip()
                if text:
                    found = text        # keep the latest non-empty one
    except Exception:
        return ""
    return found


def condense(text: str) -> str:
    """First non-empty line, whitespace-collapsed, truncated."""
    for raw in text.splitlines():
        line = " ".join(raw.split())
        if line:
            if len(line) > MAXLEN:
                line = line[:MAXLEN - 1].rstrip() + "…"
            return line
    return ""


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0
    text = last_assistant_text(payload.get("transcript_path", ""))
    if not text:
        return 0
    message = condense(text)
    if not message:
        return 0
    # Waiting on the user (a question), not reporting completion → don't ping the game.
    if message.rstrip().endswith("?"):
        return 0

    try:
        d = inbox_dir()
        os.makedirs(d, exist_ok=True)
        ts = time.time()
        name = "%d-%s.json" % (int(ts * 1000), binascii.hexlify(os.urandom(4)).decode())
        tmp = os.path.join(d, "." + name)
        final = os.path.join(d, name)
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump({"message": message, "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(ts))}, fh)
        os.rename(tmp, final)          # atomic: the watcher never sees a half-written file
    except Exception:
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
