#!/usr/bin/env bash
# game_help.sh <keyword...> — search the scraped AlterAeon help corpus and print the best-matching
# topics in full. This is the practical way to "just know" a game mechanic: grep the real docs.
#
# The corpus (help_raw/) is a local, gitignored mirror of the game's help/articles/guides/quests, built
# by scrape_help_topics.py. The embedding RAG index (~/Documents/MudClient/rag_index.json) is what the
# in-game AI retrieves against, but it needs the embedding model — it isn't queryable from a shell, so
# this keyword search over the same source text is the fast path for answering "how does X work?".
#
# Usage:   tools/finetune/game_help.sh waypoint recall
#          TOPN=5 tools/finetune/game_help.sh sacrifice corpse spellcomp
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
CORPUS="$ROOT/help_raw"
TOPN="${TOPN:-3}"

[ -d "$CORPUS" ] || { echo "no corpus at $CORPUS — run: python3 $ROOT/scrape_help_topics.py" >&2; exit 1; }
[ $# -gt 0 ] || { echo "usage: $(basename "$0") <keyword> [keyword...]  (env: TOPN=$TOPN)" >&2; exit 2; }

# OR-pattern of all keywords, case-insensitive.
pat=$(printf '%s\n' "$@" | paste -sd'|' -)

# Rank files by total keyword hits, then print the top N with HTML tags stripped and blanks squeezed.
grep -rilE "$pat" "$CORPUS" 2>/dev/null | while read -r f; do
  printf '%d\t%s\n' "$(grep -icE "$pat" "$f")" "$f"
done | sort -rn | head -n "$TOPN" | while IFS=$'\t' read -r score f; do
  echo "======== $(basename "$f")  (score $score) ========"
  sed 's/<[^>]*>//g' "$f" | grep -v '^[[:space:]]*$' | head -60
  echo
done
