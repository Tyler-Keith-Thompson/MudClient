#!/usr/bin/env python3
"""
Scrape the Alter Aeon help system into plain-text files, one per topic.

Stdlib only (urllib + html.parser) so there's nothing to pip install. Polite:
single-threaded, rate-limited, restricted to alteraeon help paths, depth-limited.

Sources crawled (seed set, expand with --seed):
  - https://www.alteraeon.com/help/index.html      (portal + guide links)
  - https://www.alteraeon.com/spells_and_skills.html
  - https://www.alteraeon.com/guides/                (new-player guides)

Output: tools/finetune/help_raw/<slug>.txt  (first line = source URL)

Usage:
  python3 tools/finetune/scrape_help.py                 # default crawl
  python3 tools/finetune/scrape_help.py --max 400 --delay 0.5
  python3 tools/finetune/scrape_help.py --seed https://www.alteraeon.com/help/index.html
"""
import argparse
import os
import re
import sys
import time
from html.parser import HTMLParser
from urllib.parse import urljoin, urlparse
from urllib.request import Request, urlopen

OUT_DIR = os.path.join(os.path.dirname(__file__), "help_raw")
DEFAULT_SEEDS = [
    "https://www.alteraeon.com/help/index.html",
    "https://www.alteraeon.com/spells_and_skills.html",
    "https://www.alteraeon.com/guides/new-player-guide.html",
]
# Only follow links whose path starts with one of these (keeps us in the docs).
ALLOW_PREFIXES = ("/help", "/guides", "/spells", "/quests", "/maps")
DENY_EXT = (".css", ".js", ".png", ".jpg", ".jpeg", ".gif", ".ico", ".exe",
            ".zip", ".pdf", ".mp3", ".mp4", ".svg")


class TextExtractor(HTMLParser):
    """Collect visible text + hyperlinks, skipping script/style/nav chrome."""
    SKIP = {"script", "style", "head", "noscript"}

    def __init__(self):
        super().__init__()
        self.chunks, self.links = [], []
        self._skip_depth = 0

    def handle_starttag(self, tag, attrs):
        if tag in self.SKIP:
            self._skip_depth += 1
        if tag == "a":
            for k, v in attrs:
                if k == "href" and v:
                    self.links.append(v)
        if tag in ("p", "br", "div", "li", "tr", "h1", "h2", "h3", "pre"):
            self.chunks.append("\n")

    def handle_endtag(self, tag):
        if tag in self.SKIP and self._skip_depth:
            self._skip_depth -= 1

    def handle_data(self, data):
        if self._skip_depth == 0:
            self.chunks.append(data)

    def text(self):
        raw = "".join(self.chunks)
        raw = re.sub(r"[ \t]+", " ", raw)
        raw = re.sub(r"\n\s*\n\s*\n+", "\n\n", raw)
        return raw.strip()


def slug(url):
    p = urlparse(url)
    s = (p.path + ("_" + p.query if p.query else "")).strip("/")
    s = re.sub(r"[^a-zA-Z0-9._-]+", "_", s) or "index"
    return s[:120]


def allowed(url):
    p = urlparse(url)
    if p.netloc and "alteraeon.com" not in p.netloc:
        return False
    if any(p.path.lower().endswith(e) for e in DENY_EXT):
        return False
    return any(p.path.startswith(pre) for pre in ALLOW_PREFIXES)


def fetch(url, timeout):
    req = Request(url, headers={"User-Agent": "AA-help-scraper/1.0 (personal fine-tune)"})
    with urlopen(req, timeout=timeout) as r:
        ctype = r.headers.get("Content-Type", "")
        if "text/html" not in ctype and "text/plain" not in ctype:
            return None
        return r.read().decode("utf-8", "replace")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", action="append", default=[], help="extra seed URL(s)")
    ap.add_argument("--max", type=int, default=300, help="max pages to fetch")
    ap.add_argument("--delay", type=float, default=0.6, help="seconds between requests")
    ap.add_argument("--depth", type=int, default=2, help="max link depth from seeds")
    ap.add_argument("--timeout", type=float, default=15)
    args = ap.parse_args()

    os.makedirs(OUT_DIR, exist_ok=True)
    seeds = DEFAULT_SEEDS + args.seed
    queue = [(u, 0) for u in seeds]
    seen, saved = set(), 0

    while queue and saved < args.max:
        url, depth = queue.pop(0)
        url = url.split("#")[0]
        if url in seen:
            continue
        seen.add(url)
        try:
            html = fetch(url, args.timeout)
        except Exception as e:  # noqa: BLE001
            print(f"  skip {url}: {e}", file=sys.stderr)
            continue
        if not html:
            continue

        parser = TextExtractor()
        try:
            parser.feed(html)
        except Exception:  # noqa: BLE001
            continue
        text = parser.text()
        if len(text) > 200:  # ignore near-empty shells
            path = os.path.join(OUT_DIR, slug(url) + ".txt")
            with open(path, "w") as f:
                f.write(url + "\n\n" + text)
            saved += 1
            print(f"[{saved}] {url} -> {os.path.basename(path)} ({len(text)} chars)")

        if depth < args.depth:
            for href in parser.links:
                nxt = urljoin(url, href).split("#")[0]
                if allowed(nxt) and nxt not in seen:
                    queue.append((nxt, depth + 1))
        time.sleep(args.delay)

    print(f"\nDone. Saved {saved} pages to {OUT_DIR}")


if __name__ == "__main__":
    main()
