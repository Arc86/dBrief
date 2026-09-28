#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVELOPER="${DEVELOPER_DIR:-$(xcode-select -p)}"
ACTOOL="$DEVELOPER/usr/bin/actool"
if [ ! -x "$ACTOOL" ]; then
    ACTOOL="/Applications/Xcode.app/Contents/Developer/usr/bin/actool"
fi
if [ ! -x "$ACTOOL" ]; then
    echo "Regenerating the native app icon requires Xcode 26 or later." >&2
    exit 1
fi

OUTPUT="$(mktemp -d "${TMPDIR:-/tmp}/dbrief-icon.XXXXXX")"
trap 'rm -rf "$OUTPUT"' EXIT
"$ACTOOL" "$ROOT/packaging/AppIcon.icon" \
    --compile "$OUTPUT" --platform macosx \
    --minimum-deployment-target 14.0 --target-device mac --app-icon AppIcon \
    --output-partial-info-plist "$OUTPUT/icon-info.plist" --warnings --errors
cp "$OUTPUT/Assets.car" "$ROOT/Sources/dBrief/Resources/Assets.car"
# Preserve the existing .icns for macOS 14/15 and the direct Dock PNG.
echo "Updated native Finder icon catalog."
