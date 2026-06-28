#!/usr/bin/env bash
# Generate an Xcode project via rules_xcodeproj.
#
# Usage:
#   ./scripts/generate-xcodeproj.sh             # Generate and open in Xcode
#   ./scripts/generate-xcodeproj.sh --no-open   # Generate without opening
set -euo pipefail

OPEN=true
for arg in "$@"; do
    case "$arg" in
        --no-open) OPEN=false ;;
        *) echo "Unknown argument: $arg"; exit 1 ;;
    esac
done

PROJECT="MudClient.xcodeproj"

echo "Generating Xcode project..."
bazel run //:xcodeproj

# rules_xcodeproj marks generated files read-only; relax so Xcode can write
# user state (schemes, breakpoints, etc.).
chmod -R u+w "$PROJECT"

echo ""
if [ "$OPEN" = true ]; then
    echo "Opening ${PROJECT}..."
    open "$PROJECT"
else
    echo "Done. Open ${PROJECT}"
fi
