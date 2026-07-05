#!/usr/bin/env python3
"""
Build a RAG index over the scraped AlterAeon docs (help_raw/) using the LOCAL LM Studio embedding
model. The client loads this index and, each turn, retrieves the few passages most relevant to the
current situation and feeds them to the decision model — so a general model (Sonnet) gets the game's
own manual on demand, for every mechanic, instead of us hardcoding facts.

Writes ~/Documents/MudClient/rag_index.bin — a flat binary index the Swift client loads with a single
bulk copy (the old JSON form boxed every float through NSNumber and took seconds to parse). Layout,
all integers little-endian:
    b"RAGI" | u32 version(=1) | u32 count | u32 dim
    count × [ u32 byteLen | UTF-8 text ]
    count × dim × float32          (one contiguous block)

Requires the embedding model loaded in LM Studio (it was: text-embedding-nomic-embed-text-v1.5).
nomic uses task prefixes: documents get "search_document: ", queries get "search_query: " (the client
adds the query prefix). Run once after scraping; re-run when the docs change.

  python3 tools/finetune/build_rag_index.py
"""
import array
import glob
import json
import os
import re
import struct
import sys
import urllib.request

HERE = os.path.dirname(__file__)
RAW = os.path.join(HERE, "help_raw")
OUT = os.path.expanduser("~/Documents/MudClient/rag_index.bin")
BASE = os.environ.get("LMSTUDIO_BASE_URL", "http://localhost:1234/v1")
EMB_MODEL = os.environ.get("EMB_MODEL", "text-embedding-nomic-embed-text-v1.5")


def chunk(text, size=900, overlap=120):
    text = re.sub(r"\n{3,}", "\n\n", text).strip()
    out, i = [], 0
    while i < len(text):
        c = text[i:i + size].strip()
        if len(c) > 80:
            out.append(c)
        i += size - overlap
    return out


def embed(texts):
    body = json.dumps({"model": EMB_MODEL, "input": texts}).encode()
    req = urllib.request.Request(BASE + "/embeddings", data=body,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=180) as r:
        return [e["embedding"] for e in json.load(r)["data"]]


def main():
    chunks = []
    for path in sorted(glob.glob(os.path.join(RAW, "*.txt"))):
        with open(path) as f:
            body = f.read()
        lines = body.splitlines()
        topic = os.path.basename(path).replace(".html.txt", "").replace(".txt", "")
        text = "\n".join(lines[2:]) if len(lines) > 2 else body   # drop the source-URL header line
        for c in chunk(text):
            chunks.append(f"[{topic}] {c}")
    print(f"{len(chunks)} chunks from {RAW}; embedding via {EMB_MODEL} ...")

    # Cap each input so an over-long passage (e.g. a big ASCII map) can't 400 the embedder.
    CAP = 1600
    index, B, skipped = [], 16, 0
    for i in range(0, len(chunks), B):
        batch = chunks[i:i + B]
        try:
            vecs = embed(["search_document: " + c[:CAP] for c in batch])
            for c, v in zip(batch, vecs):
                index.append({"text": c, "vec": v})
        except Exception:  # noqa: BLE001
            # A batch failed — embed one at a time so a single bad chunk can't kill the build.
            for c in batch:
                try:
                    v = embed(["search_document: " + c[:CAP]])[0]
                    index.append({"text": c, "vec": v})
                except Exception:  # noqa: BLE001
                    skipped += 1
        print(f"  {len(index)}/{len(chunks)} (skipped {skipped})", end="\r")

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    write_bin(OUT, index)
    dim = len(index[0]["vec"]) if index else 0
    print(f"\nwrote {len(index)} chunks ({dim}-dim) -> {OUT}")
    # Drop the old JSON index (superseded, ~4x larger) so a stale copy can't be picked up or confuse.
    legacy = os.path.splitext(OUT)[0] + ".json"
    if os.path.exists(legacy):
        os.remove(legacy)
        print(f"removed legacy {legacy}")


def write_bin(path, index):
    """Flat binary index: header, length-prefixed UTF-8 texts, then one contiguous float32 block."""
    dim = len(index[0]["vec"]) if index else 0
    with open(path, "wb") as f:
        f.write(b"RAGI")
        f.write(struct.pack("<III", 1, len(index), dim))          # version, count, dim
        for c in index:
            b = c["text"].encode("utf-8")
            f.write(struct.pack("<I", len(b)))
            f.write(b)
        for c in index:
            a = array.array("f", c["vec"])
            if sys.byteorder == "big":                            # file is little-endian
                a.byteswap()
            f.write(a.tobytes())


if __name__ == "__main__":
    main()
