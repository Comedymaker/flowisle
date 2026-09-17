#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
VERSION="1.7.1"
mkdir -p "$DIST"
bash "$ROOT/build.sh" "$DIST/FlowIsle.app"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$DIST/FlowIsle.app" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
DMG="$DIST/FlowIsle-v$VERSION-universal.dmg"
rm -f "$DMG"
hdiutil create -quiet -volname "FlowIsle $VERSION" -srcfolder "$STAGING" -format UDZO "$DMG"
cd "$DIST"
shasum -a 256 "$(basename "$DMG")" | tee SHA256SUMS.txt
echo "Packaged: $DMG"
