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
    # NOTE: iTerm2 asks you to confirm the background change (a security measure) — expect a prompt on set
    # and on clear. Resizing the window after launch can reintroduce stretch; re-run `just run` to re-fit.
    _art_tmp=""
    _art_done=0
    _art_clear() {
      [ "$_art_done" = 1 ] && return 0; _art_done=1
      printf '\033]1337;SetBackgroundImageFile=\a'
      [ -n "$_art_tmp" ] && rm -f "$_art_tmp"
    }
    if [ "${TERM_PROGRAM:-}" = "iTerm.app" ] && [ "${MUD_NO_ART_BG:-}" != "1" ]; then
      _art_img="$(python3 tools/trace-art/generate.py --pick-badass --last "${MUD_ART_BG_LAST:-5}" 2>/dev/null || true)"
      if [ -n "${_art_img}" ] && [ -f "${_art_img}" ]; then
        _art_tmp="${TMPDIR:-/tmp}/mudclient-bg-$$.png"
        if swift tools/trace-art/prep-bg.swift "${_art_img}" "${_art_tmp}" 2>/dev/null && [ -f "${_art_tmp}" ]; then
          _art_show="${_art_tmp}"
        else
          _art_show="${_art_img}"; _art_tmp=""   # prep failed → show the raw image, nothing to clean up
        fi
        trap _art_clear EXIT INT TERM
        printf '\033]1337;SetBackgroundImageFile=%s\a' "$(printf '%s' "${_art_show}" | base64 | tr -d '\n')"
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

[doc('Generate Xcode project (pass --no-open to skip launching Xcode)')]
generate *args="":
    @bash scripts/generate-xcodeproj.sh {{args}}

[doc('Clean all build artifacts')]
clean:
    {{BAZEL}} clean
