#!/bin/bash
# Build a universal (arm64 + x86_64), ad-hoc-signed release zip:
#   ./scripts/release.sh 1.1.0   ->  build/release/Lumina-v1.1.0.zip
# Version must match CFBundleShortVersionString in Resources/Info-App.plist.
# Per-arch builds + lipo because `swift build --arch a --arch b` needs Xcode's
# XCBuild, which the Command Line Tools don't ship. Always ad-hoc signed: the
# "Lumina Dev" cert is a local self-signed identity, meaningless to other Macs.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: release.sh <version>}"
PLIST_VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info-App.plist)
[[ "$PLIST_VERSION" == "$VERSION" ]] || { echo "Info-App.plist says $PLIST_VERSION, not $VERSION"; exit 1; }

OUT=build/release
rm -rf "$OUT"
mkdir -p "$OUT"
for ARCH in arm64 x86_64; do
    swift build -c release --product LuminaBar --triple "$ARCH-apple-macosx14.0" 2>&1 | tail -1
done
APP=$OUT/Lumina.app
mkdir -p "$APP/Contents/MacOS"
lipo -create .build/arm64-apple-macosx/release/LuminaBar .build/x86_64-apple-macosx/release/LuminaBar \
    -output "$APP/Contents/MacOS/LuminaBar"
cp Resources/Info-App.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
ditto -c -k --keepParent "$APP" "$OUT/Lumina-v$VERSION.zip"
lipo -info "$APP/Contents/MacOS/LuminaBar"
echo "Built $OUT/Lumina-v$VERSION.zip"
