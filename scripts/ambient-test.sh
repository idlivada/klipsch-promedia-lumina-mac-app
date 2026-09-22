#!/bin/bash
# Webcam verification harness for Ambient mode. Aim a webcam at the speaker
# LEDs, turn Ambient on in Lumina (following the screen under test), then:
#   ./scripts/ambient-test.sh snapshot        # one webcam frame (find the LED region)
#   ./scripts/ambient-test.sh suite  [screen] # color patterns, scored per scenario
#   ./scripts/ambient-test.sh step   [screen] # red/blue step response at full webcam rate
# [screen] = NSScreen index for the patterns (default 0 = main display).
# Patterns cover that whole screen (~1 min for suite, ~15 s for step).
# Env: CAM (webcam name substring, default BRIO), CROP (LED region w:h:x:y in
# webcam frames, default 650:440:450:280). Output: build/ambient-test/<mode>/.
#
# The camera grabber is a bundled .app launched via `open`: macOS silently
# denies camera access to shell commands (ffmpeg -f avfoundation hangs), but a
# bundle with NSCameraUsageDescription gets a real permission prompt.
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-}"
SCREEN="${2:-0}"
CAM="${CAM:-BRIO}"
T=build/ambient-test
command -v ffmpeg >/dev/null || { echo "ffmpeg required (brew install ffmpeg)"; exit 1; }
[[ "$MODE" =~ ^(snapshot|suite|step)$ ]] || { sed -n 2,11p "$0"; exit 1; }

mkdir -p "$T"
APP=$T/LuminaCamGrab.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -o "$APP/Contents/MacOS/camgrab" scripts/ambient-test/camgrab.swift
cp Resources/Info-CamGrab.plist "$APP/Contents/Info.plist"
# Same stable identity as build.sh so the camera grant survives rebuilds.
SIGN_ID="${LUMINA_SIGN_ID:-Lumina Dev}"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$SIGN_ID\""; then
    codesign --force --sign "$SIGN_ID" "$APP" 2>/dev/null
else
    codesign --force --sign - "$APP" 2>/dev/null
fi
[[ "$MODE" == snapshot ]] || swiftc -O -o "$T/colorwall" scripts/ambient-test/colorwall.swift

OUT="$PWD/$T/$MODE"
rm -rf "$OUT"
# grab <count> <intervalSec>: start the webcam grabber in the background.
grab() { open -n "$APP" --args "$OUT" "$1" "$2" "$CAM"; }
wait_done() {
    for _ in $(seq 1 120); do
        grep -q DONE "$OUT/frames.txt" 2>/dev/null && break
        sleep 1
    done
    grep -q '^ERROR' "$OUT/frames.txt" && { grep '^ERROR' "$OUT/frames.txt"; exit 1; }
    return 0
}

case "$MODE" in
snapshot)
    grab 1 0
    wait_done
    echo "$OUT/frame_000.jpg"
    ;;
suite)
    grab 112 0.5
    sleep 3  # grabber warm-up (auto-exposure)
    "$T/colorwall" "$SCREEN" red green blue yellow cyan magenta white edges letterbox darkmovie black alternate:8 > "$OUT/wall.txt"
    wait_done
    python3 scripts/ambient-test/analyze.py suite "$OUT"
    ;;
step)
    grab 420 0
    sleep 3
    "$T/colorwall" "$SCREEN" red:3 blue:3 red:3 blue:3 > "$OUT/wall.txt"
    wait_done
    python3 scripts/ambient-test/analyze.py step "$OUT"
    ;;
esac
