#!/bin/bash
# Builds Clipsight.app into ./build. Pass --install to copy it to ~/Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")"

# Universal, so it runs on Apple silicon and Intel Macs.
swift build -c release --arch arm64 --arch x86_64

APP=build/Clipsight.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Clipsight "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"

if [ "${1:-}" = "--install" ]; then
	pkill -x Clipsight || true
	mkdir -p ~/Applications
	rm -rf ~/Applications/Clipsight.app
	cp -R "$APP" ~/Applications/
	open ~/Applications/Clipsight.app
fi

echo "Built $APP"
