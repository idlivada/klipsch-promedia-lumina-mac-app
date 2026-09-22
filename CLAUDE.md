# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A macOS menu-bar app (SwiftPM, macOS 14+, no Xcode project) controlling **Klipsch ProMedia Lumina 2.1** speakers over Bluetooth LE. The BLE protocol was reverse-engineered against real hardware; **PROTOCOL.md is the living protocol document** and is the first thing to read before touching anything BLE-related.

## Commands

```sh
./scripts/build.sh          # build + bundle build/Lumina.app (ad-hoc signed)
./scripts/build.sh --open   # …and launch it
                            # signs with the "Lumina Dev" keychain cert if present
                            # (LUMINA_SIGN_ID overrides), else ad-hoc
./scripts/probe.sh dump lumina            # BLE diagnostic tool (also: scan/read/write/listen)
./scripts/probe.sh write lumina ff2 03    # example: set Static mode
swift build                 # compile-check all targets (fast, no bundling)
```

There are no tests. Verification is compile (`swift build`) plus running against the physical speakers. Ambient mode was tuned with a webcam aimed at the LEDs: running `ffmpeg` on the camera from a shell is silently denied by TCC, so the capture tool must be a bundled `.app` with `NSCameraUsageDescription` launched via `open` (same pattern as the probe).

**Important:** the binaries must run from a bundled `.app` launched via `open` (LaunchServices) — macOS TCC only grants Bluetooth permission that way. Never execute `.build/release/LuminaBar` or `probe` directly; use the scripts, which bundle + codesign + `open`. Probe output lands in `probe-dumps/last-run.txt` (the script tails it until `===DONE===`).

## Architecture

Three SwiftPM targets:

- **`Sources/LuminaProtocol/`** — pure, UI-free protocol layer shared by app and probe.
  - `Chars.swift`: characteristic UUID table (`Lumina.uuid("ff2")` expands 3-hex-digit short ids to the vendor UUID `DA6D0Fxx-...`) and `Lumina.writeDenylist`.
  - `Encodings.swift`: byte ↔ value codecs (volume, EQ blob, sub gain, color pairs, brightness scaling).
- **`Sources/LuminaBar/`** — the menu-bar app.
  - `AppState.swift`: single `@Observable` source of truth. Writes are **optimistic** (state mutates first, BLE write follows, sliders throttled via `Throttler`). Incoming notifications sync external changes (pod buttons, phone app), with two suppression layers: echoes of our own writes within a 1.5 s window, and characteristics whose slider is mid-drag (`setEditing`).
  - `LuminaClient.swift`: CoreBluetooth lifecycle — cached-identifier reconnect with name-scan fallback, notify subscriptions, one initial read for sync, FIFO write queue with one in-flight write and same-characteristic replacement. Enforces the write denylist.
  - `Ambient/`: screen-sync lighting. `ScreenSampler` (ScreenCaptureKit, tiny downscaled frames of one display, own app excluded) feeds `AmbientColor` (pure: letterbox crop → edge-weighted, saturation-weighted hue histogram → dominant hue or blended mean; intensity = √mean value) and `AmbientTracker` (time-based crop/hue gates + EMA, re-run on a 30 Hz tick because ScreenCaptureKit only delivers frames on change).
  - `Views/`: SwiftUI popover, two tabs (Audio / Lighting).
- **`Sources/probe/`** — CLI used for protocol discovery (scan/dump/read/write/listen). Refuses denylisted writes.

## Hardware/protocol invariants (violating these bricks state or misleads users)

- **Never write** `fe8` (factory reset), `fe3` (restarts the device — verified the hard way), `fc6`, `fa5`, `fa6`. Enforced in `Lumina.writeDenylist` and the probe; keep it that way.
- **Single BLE central**: the phone app and the Mac can never be connected simultaneously. The app's "Release to Phone App" exists for this.
- **GATT read-back is stale**: a read right after a write often returns the old value for minutes. Never read to verify a write; only the initial on-connect read is trusted. "No diff" in discovery is inconclusive.
- **`fea` (brightness) is a read-only status mirror** — writes are ACKed and ignored. Brightness is instead applied by RGB-scaling the color written to `ff3`, so it only works in Static/Breathe. Don't "rediscover" fea writability; it was exhaustively tested.
- **`ff3` (mode-color register)**: must be written on the **same connection** as the `ff2` mode write, and mode transitions clear it — always rewrite `ff2` then `ff3` together (`pushColorPayload`). In Music React, only the four exact phone-app byte pairs give fixed gradients; any other pair means cycle-all-presets.
- Because the app writes brightness-**scaled** colors to `ff3`, `AppState.apply()` deliberately ignores inbound solid colors while in Static/Breathe (reading them back would compound the dimming). The UI is authoritative for color/brightness in those modes.
- **EQ (`f17`)**: full 48-byte blob writes only (partials silently ignored). The last blob read from the device is kept as the write template so unknown bytes round-trip.
- `0x06` on `ff2` is lights-**off**, not a mode; `0x00` is rejected on both `ff2` and `f24`.
- **Ambient is app-side**: device stays in Static and the app streams solid `ff3` colors via `AppState.displayedSolidColor` (ambient color vs the user's `staticColor`, which ambient never overwrites). Never emit all-zero — "off" is `RGB(1,1,1)`. Any gate in `AmbientTracker` must be time-based, not frame-counted (static screens produce one frame; frame-counted gates stalled for seconds).
- **Screen Recording TCC** is pinned to the code signature: ad-hoc builds lose the grant on every rebuild (remove Lumina from the list and re-grant). The stable "Lumina Dev" signing identity avoids this.

## Workflow rules

- Protocol changes are a three-place edit, kept in sync: **PROTOCOL.md** tables, **`LuminaProtocol/`** (Chars/Encodings), and the **`ProtocolCapabilities`** flags in `Models.swift` (unverified features stay hidden rather than silently broken).
- A characteristic only counts as verified with **W** — a write from the Mac confirmed by ear/eye. The discovery playbook (listen/dump-diff/write techniques and their pitfalls) is at the bottom of PROTOCOL.md; save new dumps as `probe-dumps/NN-description.txt`.
- `LUMINA_SPEAKER_APP.md` is the original planning/handoff document — historical context; where it conflicts with PROTOCOL.md, PROTOCOL.md wins (e.g. it predates the fea and ff3-second-triplet findings).
