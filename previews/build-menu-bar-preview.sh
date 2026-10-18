#!/bin/zsh
set -euo pipefail
preview_root="${0:A:h}"
preview_bundle="$preview_root/build/dBrief UI Preview.app"
mkdir -p "$preview_bundle/Contents/MacOS" "$preview_bundle/Contents/Resources"
swiftc -parse-as-library -swift-version 6 -target arm64-apple-macos14.0 \
  -module-cache-path "$preview_root/build/module-cache" \
  "$preview_root/MenuBarPanelPreview.swift" \
  -o "$preview_bundle/Contents/MacOS/MenuBarPreview"
cp "$preview_root/Assets/zIunb.png" "$preview_bundle/Contents/Resources/dBrief-Icon.png"
cat > "$preview_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MenuBarPreview</string>
<key>CFBundleIdentifier</key><string>com.dbrief.menu-bar-visual-preview</string>
<key>CFBundleName</key><string>dBrief UI Preview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
if [[ "${1:-}" != "--build-only" ]]; then
  "$preview_bundle/Contents/MacOS/MenuBarPreview" --render "$preview_root/renders"
fi
if [[ "${1:-}" == "--open" ]]; then
  open "$preview_bundle"
fi
print "Preview: $preview_bundle"
