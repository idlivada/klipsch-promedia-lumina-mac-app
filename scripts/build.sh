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
# Sign with a stable identity when available so macOS privacy grants (Screen
# Recording for ambient mode) survive rebuilds; ad-hoc signatures are pinned to
# the binary hash, so every rebuild would need the grant again. Override with
# LUMINA_SIGN_ID; defaults to a self-signed "Lumina Dev" code-signing cert.
SIGN_ID="${LUMINA_SIGN_ID:-Lumina Dev}"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$SIGN_ID\""; then
    codesign --force --sign "$SIGN_ID" "$APP"
else
    codesign --force --sign - "$APP"
fi
echo "Built $APP"
if [[ "${1:-}" == "--open" ]]; then
    open "$APP"
fi
