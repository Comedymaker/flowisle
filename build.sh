#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="${1:-$ROOT/dist/FlowIsle.app}"
SDK="${WORK_ISLAND_SDK:-$(xcrun --show-sdk-path)}"
# Some preview CLT installations include an older stable SDK beside the default.
if [[ -z "${WORK_ISLAND_SDK:-}" && -d "$(dirname "$SDK")/MacOSX26.sdk" ]]; then
    SDK="$(dirname "$SDK")/MacOSX26.sdk"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BUILD_TMP="$(mktemp -d)"
trap 'rm -rf "$BUILD_TMP"' EXIT
for ARCH in arm64 x86_64; do
    swiftc -sdk "$SDK" -module-cache-path "${TMPDIR:-/tmp}/flowisle-$ARCH-module-cache" \
        -target "$ARCH-apple-macos13.0" -swift-version 5 -O \
        -framework AppKit -framework SwiftUI "$ROOT/Sources/WorkIsland.swift" \
        -o "$BUILD_TMP/WorkIsland-$ARCH"
done
lipo -create "$BUILD_TMP/WorkIsland-arm64" "$BUILD_TMP/WorkIsland-x86_64" \
    -output "$APP/Contents/MacOS/WorkIsland"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>WorkIsland</string>
<key>CFBundleIdentifier</key><string>local.workisland.app</string>
<key>CFBundleName</key><string>FlowIsle</string>
<key>CFBundleDisplayName</key><string>FlowIsle</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.7.1</string>
<key>CFBundleVersion</key><string>23</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign "${DEVELOPER_ID_APP:--}" "$APP"
"$APP/Contents/MacOS/WorkIsland" --self-test
codesign --verify --deep --strict "$APP"
lipo -verify_arch arm64 x86_64 "$APP/Contents/MacOS/WorkIsland"
echo "Built: $APP"
