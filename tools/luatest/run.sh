#!/usr/bin/env bash
# Run the MUD client's Lua script test suite from the command line — no app or Xcode build needed.
#
# It compiles a tiny Lua 5.4 interpreter from the vendored Sources/CLua (cached in $TMPDIR and rebuilt
# only when the Lua core changes), then loads the real scripts with the host builtins stubbed and runs
# every Scripts/tests/*.lua. This is the same suite the in-app `#test` command runs. Exit code is
# non-zero if any spec fails, so it drops straight into CI or a pre-commit hook.
#
# Usage:  ./tools/luatest/run.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

BIN="${TMPDIR:-/tmp}/mudclient-testlua"
# Rebuild the interpreter if it's missing or the Lua VM source is newer than the cached binary.
if [ ! -x "$BIN" ] || [ Sources/CLua/lvm.c -nt "$BIN" ]; then
  echo "[luatest] building interpreter from Sources/CLua…"
  cc -O1 -std=gnu99 -DLUA_USE_MACOSX -I Sources/CLua/include \
     Sources/CLua/*.c tools/luatest/main.c -o "$BIN" -lm
fi

exec "$BIN" tools/luatest/driver.lua
