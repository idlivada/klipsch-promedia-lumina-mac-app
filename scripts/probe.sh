#!/bin/bash
# Build + bundle + launch the BLE probe via LaunchServices (required for TCC),
# then tail its output. Usage:
#   ./scripts/probe.sh scan 10
#   ./scripts/probe.sh dump lumina
#   ./scripts/probe.sh read lumina ff2
#   ./scripts/probe.sh write lumina ff2 03
#   ./scripts/probe.sh listen lumina 60
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product probe 2>&1 | tail -3
APP=build/LuminaProbe.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/probe "$APP/Contents/MacOS/probe"
cp Resources/Info-Probe.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" 2>/dev/null

mkdir -p probe-dumps
OUT="$PWD/probe-dumps/last-run.txt"
rm -f "$OUT"
open -n "$APP" --args "$@" --out "$OUT"
for _ in $(seq 1 120); do
    sleep 1
    grep -q '===DONE===' "$OUT" 2>/dev/null && break
done
cat "$OUT" 2>/dev/null || echo "(no output file)"
