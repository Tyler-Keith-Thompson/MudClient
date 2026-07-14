PROJECT_ROOT := justfile_directory()
APP_NAME := "MudClient"
# Bazel config for builds/tests.
BAZEL_CONFIG := "debug"
BAZEL := "bazel"
MUDCLIENT_TARGET := "//Sources/MudClient:MudClient"

# Pin Bazel's Apple toolchain to the currently-selected Xcode for both building
# and running tests. Without this, with multiple Xcodes installed, the build and
# the test runtime can resolve different Xcodes and a swift-testing/XCTest
# dylib mismatch crashes the test runner. `.bazelrc` forwards this via
# --action_env / --test_env DEVELOPER_DIR.
export DEVELOPER_DIR := `xcode-select -p`

[doc('Build everything (default)')]
all: build

[doc('Build the MudClient executable')]
build:
    @echo "Building MudClient..."
    {{BAZEL}} build {{MUDCLIENT_TARGET}} --config={{BAZEL_CONFIG}}

[doc('Build and run MudClient')]
run:
    #!/usr/bin/env bash
    set -euo pipefail
    # Build with Bazel, then run the binary from the repo root. The runtime
    # plugin loader (ScriptInterpreter) shells out to `swift build` against the
    # SwiftPM packages in Scripts/, so it must execute with the working
    # directory at the repo root — not inside Bazel's runfiles tree.
    {{BAZEL}} build {{MUDCLIENT_TARGET}} --config={{BAZEL_CONFIG}}
    cd "{{PROJECT_ROOT}}"
    # iTerm2 wallpaper: while the client runs (and ONLY while it runs), set the terminal background to the
    # most "badass" of the last few trace-art images — the local LM Studio model judges from each moment's
    # text (tools/trace-art). prep-bg.swift resizes the pick to THIS terminal's aspect (no stretch) and
    # bakes in a dark overlay (readable text); if it fails we fall back to the raw image. Cleared on exit
    # via the EXIT trap, which is why we run the app as a CHILD rather than `exec`. No-op outside iTerm2,
    # when the picker finds nothing (LM Studio down / empty gallery), or when MUD_NO_ART_BG=1. Tunables:
    # MUD_ART_BG_DIM (overlay 0..1, default 0.55), MUD_ART_BG_FIT (cover|contain), MUD_ART_BG_LAST (5).
    # NOTE: iTerm2 asks you to confirm the background change (a security measure). It remembers "always
    # allow" PER FILENAME, so we write to ONE fixed path (bg-cache/wallpaper.png) — a name that changed
    # each run (e.g. a per-pid temp) makes the prompt reappear every time. Resizing the window after launch
    # can reintroduce stretch; re-run `just run` to re-fit.
    # The pick is expensive (a local LM Studio judge, ~10s) + a Swift prep compile (~1s), so we CACHE the
    # finished wallpaper and only rebuild it when there's actually a NEW image to show. The gallery
    # (trace-art/gallery.jsonl) gains a line each time generate.py mints an image, so its mtime is our
    # freshness signal: cache validity is keyed by (gallery mtime, terminal size). New image generated →
    # gallery mtime advances → next `just run` re-picks immediately (not on some calendar boundary); a
    # resized window re-preps for the new aspect. The image PATH stays fixed for iTerm's "always allow"
    # sake; a sidecar `.stamp` records the (gallery-mtime,size) it was built for. When it does rebuild it
    # pays the full cost with a progress line; otherwise the relaunch is instant.
    _art_done=0
    _art_clear() {
      [ "$_art_done" = 1 ] && return 0; _art_done=1
      printf '\033]1337;SetBackgroundImageFile=\a'   # cache file is persistent — clear the wallpaper only
    }
    if [ "${TERM_PROGRAM:-}" = "iTerm.app" ] && [ "${MUD_NO_ART_BG:-}" != "1" ]; then
      _art_dir="${HOME}/Documents/MudClient/bg-cache"; mkdir -p "$_art_dir"
      _art_cached="${_art_dir}/wallpaper.png"        # FIXED path so iTerm2's per-file "always allow" sticks
      _art_stamp="${_art_dir}/wallpaper.stamp"
      _art_cols="$(tput cols 2>/dev/null || echo 80)"; _art_lines="$(tput lines 2>/dev/null || echo 24)"
      # Freshness = newest gallery write. stat the gallery mtime (0 if it's not there yet).
      _art_gen="$(stat -f %m "${HOME}/Documents/MudClient/trace-art/gallery.jsonl" 2>/dev/null || echo 0)"
      _art_key="${_art_gen} ${_art_cols}x${_art_lines}"
      if [ ! -f "$_art_cached" ] || [ "$(cat "$_art_stamp" 2>/dev/null || true)" != "$_art_key" ]; then
        printf 'preparing terminal wallpaper (~10s)' >&2
        _art_pick="$(mktemp)"
        ( python3 tools/trace-art/generate.py --pick-badass --last "${MUD_ART_BG_LAST:-5}" >"$_art_pick" 2>/dev/null || true ) &
        _art_pid=$!
        while kill -0 "$_art_pid" 2>/dev/null; do printf '.' >&2; sleep 0.5; done
        wait "$_art_pid" 2>/dev/null || true
        _art_img="$(cat "$_art_pick" 2>/dev/null || true)"; rm -f "$_art_pick"
        if [ -n "${_art_img}" ] && [ -f "${_art_img}" ]; then
          printf ' rendering' >&2
          # prep to this terminal's aspect; if prep fails, cache the raw image so we don't re-pay the pick.
          if swift tools/trace-art/prep-bg.swift "${_art_img}" "${_art_cached}" 2>/dev/null || cp -f "${_art_img}" "${_art_cached}" 2>/dev/null; then
            printf '%s' "$_art_key" > "$_art_stamp"   # stamp what (day,size) this cache is valid for
          fi
        fi
        printf ' done\n' >&2
      fi
      if [ -f "$_art_cached" ]; then
        trap _art_clear EXIT INT TERM
        printf '\033]1337;SetBackgroundImageFile=%s\a' "$(printf '%s' "${_art_cached}" | base64 | tr -d '\n')"
      fi
    fi
    ./bazel-bin/Sources/MudClient/MudClient

[doc('Run all tests (Bazel caches unchanged targets)')]
test:
    @echo "Running all tests..."
    {{BAZEL}} test //... --config={{BAZEL_CONFIG}}
    @echo ""
    @echo "All tests passed."

[doc('Run only the Lua script tests (fast; also included in `just test`)')]
test-lua:
    {{BAZEL}} test //tools/luatest:lua_scripts_test --config={{BAZEL_CONFIG}} --test_output=errors

[doc('Regenerate the protobuf descriptor set Lua reads via pb.load()')]
regen-rpc-descriptor:
    protoc --descriptor_set_out=Scripts/rpc_descriptor.pb --proto_path=Sources/MudClient/RPC/proto Sources/MudClient/RPC/proto/*.proto

[doc('Generate Xcode project (pass --no-open to skip launching Xcode)')]
generate *args="":
    @bash scripts/generate-xcodeproj.sh {{args}}

[doc('Clean all build artifacts')]
clean:
    {{BAZEL}} clean
