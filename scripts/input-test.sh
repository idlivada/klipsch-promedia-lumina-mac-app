#!/bin/bash
# Microphone verification harness for input switching (fd2). Feed each speaker
# input from this Mac, put the webcam (BRIO) mic within earshot, quit Lumina, then:
#   ./scripts/input-test.sh discover        # write fd2 = 01..06, report which input plays
#   ./scripts/input-test.sh watch [seconds] # timeline of the live input (default 30 s)
# Every input gets its own sine tone (tonegen), so the mic tells them apart.
# Env: MIC (mic name substring, default BRIO), TONES (label=[transport/]output=hz,...;
# default: pc over USB, analog over the headphone jack, bluetooth over BT).
# Output: build/input-test/<mode>/; discover also saves probe-dumps/08-input-select.txt.
#
# The recorder is a bundled .app launched via `open`: macOS silently denies the
# microphone to shell commands, like the camera (see ambient-test.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-}"
SECS="${2:-30}"
MIC="${MIC:-BRIO}"
TONES="${TONES:-pc=usb/ProMedia Lumina=1000,analog=Headphones=1500,bluetooth=bluetooth/ProMedia Lumina=2200}"
T=build/input-test
command -v ffmpeg >/dev/null || { echo "ffmpeg required (brew install ffmpeg)"; exit 1; }
[[ "$MODE" =~ ^(discover|watch)$ ]] || { sed -n 2,9p "$0"; exit 1; }
if [[ "$MODE" == discover ]] && pgrep -x LuminaBar >/dev/null; then
    echo "Quit Lumina first: the probe needs the single BLE connection."; exit 1
fi

mkdir -p "$T"
APP=$T/LuminaMicGrab.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -o "$APP/Contents/MacOS/micgrab" scripts/input-test/micgrab.swift
cp Resources/Info-MicGrab.plist "$APP/Contents/Info.plist"
# Same stable identity as build.sh so the microphone grant survives rebuilds.
SIGN_ID="${LUMINA_SIGN_ID:-Lumina Dev}"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$SIGN_ID\""; then
    codesign --force --sign "$SIGN_ID" "$APP" 2>/dev/null
else
    codesign --force --sign - "$APP" 2>/dev/null
fi
swiftc -O -o "$T/tonegen" scripts/input-test/tonegen.swift

OUT="$PWD/$T/$MODE"
rm -rf "$OUT"
mkdir -p "$OUT"
ev() { printf '%.3f %s\n' "$(python3 -c 'import time; print(time.time())')" "$*" >> "$OUT/events.txt"; }
wait_for() {  # wait_for <pattern>: poll the recorder log
    for _ in $(seq 1 60); do
        grep -q "$1" "$OUT/rec.txt" 2>/dev/null && break
        sleep 1
    done
    if grep -q '^ERROR' "$OUT/rec.txt" 2>/dev/null; then grep '^ERROR' "$OUT/rec.txt"; exit 1; fi
    grep -q "$1" "$OUT/rec.txt" 2>/dev/null || { echo "recorder never reported $1"; exit 1; }
}

TONE_PID=
cleanup() {
    if [[ -n "$TONE_PID" ]]; then kill "$TONE_PID" 2>/dev/null || true; wait "$TONE_PID" 2>/dev/null || true; fi
    touch "$OUT/stop"
}
trap cleanup EXIT

open -n "$APP" --args "$OUT" 300 "$MIC"
wait_for START
ev baseline
sleep 2
"$T/tonegen" "$TONES" > "$OUT/tones.txt" 2>&1 &
TONE_PID=$!
sleep 1
kill -0 "$TONE_PID" 2>/dev/null || { cat "$OUT/tones.txt"; exit 1; }
ev tones-on
cat "$OUT/tones.txt"

case "$MODE" in
discover)
    ORIG=$(./scripts/probe.sh read lumina fd2 | sed -n 's/^VALUE .*hex=//p' | tail -1)
    echo "fd2 was ${ORIG:-unknown}"
    for b in 01 02 03 04 05 06; do
        ev write "$b"
        ACK=$(./scripts/probe.sh write lumina fd2 "$b" | sed -n 's/^write ack: //p' | tail -1)
        ev acked "$b" "${ACK:-none}"
        echo "fd2 = $b -> ack ${ACK:-none}"
        sleep 4
        ev end "$b"
    done
    [[ -n "$ORIG" ]] && ./scripts/probe.sh write lumina fd2 "$ORIG" >/dev/null && echo "restored fd2 = $ORIG"
    ;;
watch)
    echo "Recording ${SECS}s: switch inputs in the app now."
    ev watch
    sleep "$SECS"
    ev watch-end
    ;;
esac

kill "$TONE_PID" 2>/dev/null || true; wait "$TONE_PID" 2>/dev/null || true
TONE_PID=
touch "$OUT/stop"
wait_for DONE
if [[ "$MODE" == discover ]]; then
    { echo "# fd2 input discovery $(date '+%Y-%m-%d %H:%M') (scripts/input-test.sh discover)"
      cat "$OUT/tones.txt"
      echo "original fd2 = ${ORIG:-unknown}"
      python3 scripts/input-test/analyze.py discover "$OUT"; } | tee probe-dumps/08-input-select.txt
else
    python3 scripts/input-test/analyze.py watch "$OUT"
fi
