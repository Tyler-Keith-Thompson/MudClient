#!/usr/bin/env python3
"""
Scrape the FULL Alter Aeon server help-file system into plain-text files, one per topic.

Unlike scrape_help.py (which crawls the https://www.alteraeon.com marketing/guide pages), this
targets the live server's help-file database, served as PLAINTEXT over HTTP on port 8080:

    http://alteraeon.com:8080/help                 -> main index, links to helpdir/<section>
    http://alteraeon.com:8080/helpdir/<N>          -> section listing, links to /help/<keywords>
    http://alteraeon.com:8080/help/<keywords>      -> the actual help article

NOTE: it MUST be http (not https) on :8080 -- https there fails with an SSL error.

Enumeration strategy:
  1. GET /help, scrape every helpdir/<N> section link.
  2. GET each helpdir/<N>, scrape every /help/<keywords> topic link.
  3. Fetch each unique topic, strip site nav/footer chrome + the search form + analytics,
     and save the cleaned article body.

The 12 kxwt client-trigger articles and the terrain article all live in section 47 and are
picked up automatically; they are also enqueued explicitly (SEED_TOPICS) as a belt-and-braces
guarantee.

Stdlib only (urllib). Polite: single-threaded, rate-limited, timeout, skips near-empty pages.

Output: tools/finetune/help_raw/help_<slug>.txt
        first line = source URL, blank line, then the cleaned plain-text body.

Usage:
  python3 tools/finetune/scrape_help_topics.py
  python3 tools/finetune/scrape_help_topics.py --delay 0.5 --timeout 20
"""
import argparse
import html
import os
import re
import sys
import time
from urllib.parse import unquote, urljoin
from urllib.request import Request, urlopen

BASE = "http://alteraeon.com:8080"
OUT_DIR = os.path.join(os.path.dirname(__file__), "help_raw")

# Explicit safety net: the 12 kxwt client-trigger topics + terrain must be captured.
SEED_TOPICS = [
    "http://alteraeon.com:8080/help/kxwt+unspoofable+client+triggers+ctriggers",
    "http://alteraeon.com:8080/help/kxwt+misctriggers+mtriggers",
    "http://alteraeon.com:8080/help/kxwt+grouptriggers+gtriggers",
    "http://alteraeon.com:8080/help/kxwt+playertriggers+ptriggers",
    "http://alteraeon.com:8080/help/kxwt+roomtriggers+rtriggers",
    "http://alteraeon.com:8080/help/kxwt%5Fterrain+terrain",
    "http://alteraeon.com:8080/help/kxwt%5Fgroup+group",
    "http://alteraeon.com:8080/help/kxwt+channel+cprefix+prefix",
    "http://alteraeon.com:8080/help/kxwt+combat+kprefix+prefix",
    "http://alteraeon.com:8080/help/kxwt+socketfilter+filter+prefix",
    "http://alteraeon.com:8080/help/kxwt+precipitation",
    "http://alteraeon.com:8080/help/kxwt+midi",
]

# Lines of pure nav/boilerplate to drop from the cleaned body.
DROP_LINE_RE = re.compile(
    r"^(Alter Aeon Help Page Search|Alter Aeon Online Help)\s*$"
    r"|Click here.*random selection"
    r"|Click here.*return to the main help index"
    r"|^Search results for\b"
    r"|^This is a directory of Alter Aeon help pages",
)


def fetch(url, timeout):
    req = Request(url, headers={"User-Agent": "AA-help-scraper/1.0 (personal fine-tune)"})
    with urlopen(req, timeout=timeout) as r:
        return r.read().decode("utf-8", "replace")


def content_region(page):
    """Isolate the main help text between the content div and the side menu."""
    start = page.find('id="text_vframe"')
    if start == -1:
        return page
    end = page.find('menu_border_frame', start)
    return page[start:end if end != -1 else None]


def clean_article(page):
    region = content_region(page)
    # Drop the search form and any <script> (google-analytics) blocks outright.
    region = re.sub(r"<form\b.*?</form>", "", region, flags=re.DOTALL | re.IGNORECASE)
    region = re.sub(r"<script\b.*?</script>", "", region, flags=re.DOTALL | re.IGNORECASE)
    # The article lives inside <pre> where newlines/spacing are meaningful (ASCII tables),
    # so strip tags in place without collapsing internal whitespace.
    text = re.sub(r"<[^>]+>", "", region)
    text = html.unescape(text)
    lines = []
    for ln in text.splitlines():
        ln = ln.rstrip()
        if DROP_LINE_RE.search(ln):
            continue
        lines.append(ln)
    body = "\n".join(lines)
    body = re.sub(r"\n{3,}", "\n\n", body).strip()
    return body


def slug(url):
    path = url.split("/help/", 1)[-1] if "/help/" in url else url
    path = unquote(path)
    s = re.sub(r"[^a-zA-Z0-9]+", "_", path).strip("_").lower()
    return ("help_" + s)[:120] if not s.startswith("help_") else s[:120]


def topic_links(page):
    """All /help/<keywords> article links on a helpdir section page."""
    out = []
    for href in re.findall(r'href="(http://alteraeon\.com:8080/help/[^"]+)"', page):
        out.append(href.split("#")[0])
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--delay", type=float, default=0.5, help="seconds between requests")
    ap.add_argument("--timeout", type=float, default=20)
    ap.add_argument("--min-chars", type=int, default=80, help="skip pages shorter than this")
    args = ap.parse_args()

    os.makedirs(OUT_DIR, exist_ok=True)

    # 1. Discover section directories.
    print("Fetching main help index ...", file=sys.stderr)
    index = fetch(BASE + "/help", args.timeout)
    sections = sorted(set(int(n) for n in re.findall(r"/helpdir/(\d+)", index)))
    print(f"  found {len(sections)} sections: {sections}", file=sys.stderr)
    time.sleep(args.delay)

    # 2. Enumerate topic URLs per section.
    topics = list(SEED_TOPICS)
    for n in sections:
        url = f"{BASE}/helpdir/{n}"
        try:
            page = fetch(url, args.timeout)
        except Exception as e:  # noqa: BLE001
            print(f"  skip section {n}: {e}", file=sys.stderr)
            time.sleep(args.delay)
            continue
        links = topic_links(page)
        topics.extend(links)
        print(f"  section {n}: {len(links)} topics", file=sys.stderr)
        time.sleep(args.delay)

    # Dedupe, preserving order.
    seen_urls, uniq = set(), []
    for u in topics:
        if u not in seen_urls:
            seen_urls.add(u)
            uniq.append(u)
    print(f"\n{len(uniq)} unique topic URLs to fetch.\n", file=sys.stderr)

    # 3. Fetch and save each topic.
    saved, empty, failed, written_slugs = 0, 0, 0, set()
    for url in uniq:
        try:
            page = fetch(url, args.timeout)
        except Exception as e:  # noqa: BLE001
            print(f"  FAIL {url}: {e}", file=sys.stderr)
            failed += 1
            time.sleep(args.delay)
            continue
        body = clean_article(page)
        if len(body) < args.min_chars:
            print(f"  empty {url} ({len(body)} chars)", file=sys.stderr)
            empty += 1
            time.sleep(args.delay)
            continue
        s = slug(url)
        # Avoid clobbering: if two URLs slugify the same, keep the longer body.
        path = os.path.join(OUT_DIR, s + ".txt")
        if s in written_slugs and os.path.exists(path):
            if len(open(path).read()) - len(url) - 2 >= len(body):
                time.sleep(args.delay)
                continue
        with open(path, "w") as f:
            f.write(url + "\n\n" + body)
        written_slugs.add(s)
        saved += 1
        print(f"[{saved}] {url} -> {s}.txt ({len(body)} chars)")
        time.sleep(args.delay)

    print(f"\nDone. Saved {saved} topics ({empty} empty/skipped, {failed} failed) to {OUT_DIR}")


if __name__ == "__main__":
    main()
