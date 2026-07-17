#!/bin/bash
# Build + bundle the menu-bar app. Pass --open to launch it.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product LuminaBar 2>&1 | tail -3
APP=build/Lumina.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/LuminaBar "$APP/Contents/MacOS/LuminaBar"
cp Resources/Info-App.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP"
if [[ "${1:-}" == "--open" ]]; then
    open "$APP"
fi
