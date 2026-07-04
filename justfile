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
    exec ./bazel-bin/Sources/MudClient/MudClient

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
