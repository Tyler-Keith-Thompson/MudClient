#!/usr/bin/env python3
"""
Build a RAG index over the scraped AlterAeon docs (help_raw/) using the LOCAL LM Studio embedding
model. The client loads this index and, each turn, retrieves the few passages most relevant to the
current situation and feeds them to the decision model — so a general model (Sonnet) gets the game's
own manual on demand, for every mechanic, instead of us hardcoding facts.

Writes ~/Documents/MudClient/rag_index.json = [{text, vec}, ...].

Requires the embedding model loaded in LM Studio (it was: text-embedding-nomic-embed-text-v1.5).
nomic uses task prefixes: documents get "search_document: ", queries get "search_query: " (the client
adds the query prefix). Run once after scraping; re-run when the docs change.

  python3 tools/finetune/build_rag_index.py
"""
import glob
import json
import os
import re
import urllib.request

HERE = os.path.dirname(__file__)
RAW = os.path.join(HERE, "help_raw")
OUT = os.path.expanduser("~/Documents/MudClient/rag_index.json")
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
    with open(OUT, "w") as f:
        json.dump(index, f)
    print(f"\nwrote {len(index)} chunks ({len(index[0]['vec'])}-dim) -> {OUT}")


if __name__ == "__main__":
    main()
