#!/bin/bash
# Builds Clipsight and packages it as build/Clipsight-<version>.dmg for other people to install.
set -euo pipefail
cd "$(dirname "$0")/.."

./build.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
DMG="build/Clipsight-$VERSION.dmg"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

cp -R build/Clipsight.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/How to install.txt" <<'TXT'
1. Drag Clipsight onto the Applications folder.
2. Open Clipsight from Applications.

Clipsight isn't notarised by Apple, so the first time you open it macOS says it
can't verify the developer. To open it anyway:

   System Settings › Privacy & Security › scroll down › "Open Anyway" next to Clipsight

You only need to do this once. Clipsight needs macOS 15 or later.

Press Shift-Command-V anywhere to open Clipsight. To paste straight into the
app you're using, allow Clipsight under Privacy & Security › Accessibility.
TXT

rm -f "$DMG"
hdiutil create -volname "Clipsight $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 "$DMG" >/dev/null
codesign --force --sign - "$DMG"
echo "Built $DMG"
