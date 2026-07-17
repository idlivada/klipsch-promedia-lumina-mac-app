# ProMedia Lumina BLE protocol — living document

Status of every characteristic the app touches. Update this file **and**
`Sources/LuminaProtocol/` (Chars.swift / Encodings.swift) together as Phase 1
discovery verifies each row, then flip the matching flag in
`Sources/LuminaBar/Models.swift` (`ProtocolCapabilities`).

All UUIDs are `DA6D0Fxx-0D18-442C-BABE-F85B5BAA6F11`. Short ids below are the
last 3 hex digits (usable directly with the probe, e.g. `./scripts/probe.sh read lumina ff2`).

Verification codes: **L** = observed via notifications while using pod
controls · **D** = dump-diff against the phone app · **W** = wrote from the Mac
and heard/saw the result. **W is required before a row counts as verified.**

## Verified (Lumina fw 1.0.1, model 1073451 — from LUMINA_SPEAKER_APP.md, 2026-07-17)

| Char | Name | Format | Verified |
|---|---|---|---|
| `ff2` | Light mode / power | 1 byte: 01 Rainbow, 02 Breathe, 03 Static, 04 Aurora, 05 Music, **06 = off** (00 rejected) | D+W |
| `fea` | Brightness | 2 bytes `[pct, pct]` 0–100, written identical; animated modes only (no effect in Static) | D+W+L |
| `ff3` | Static color | 6 bytes: RGB triplet ×2 (write same triplet twice; first triplet drives both satellites) | D+W |

## Candidates (Fives/Sevens/Nines family — NOT yet verified on Lumina)

| Char | Name | Family format | Phase 1 method |
|---|---|---|---|
| `fa2` | Master volume | 1 byte 0..0x24 (36 steps) | **L**: listen while turning pod knob end-to-end; then W |
| `fa3` | Mute | 1 byte 0/1 | W: write 01/00, listen for silence |
| `fa4` | Channel/sub volume | 2 bytes `[0x04, raw]`; Fives dB = raw − 21; Lumina UI shows −20..+10 → calibrate offset | **D×3**: phone at −20 / 0 / +10, dump each; then W |
| `f05` | Night mode | 1 byte 0/1 | D then W (audible dynamics change) |
| `f06` | Vocal preset | 0..3 — sound-mode candidate | D: cycle Movie/Music/Surround in phone app |
| `f12` | EQ preset | 0..5 — sound-mode candidate | (same session as f06) |
| `f02/f03/f04` | Bass/Mid/Treble | byte = dB + 10, dB −10..+6 — only 3 bands; Lumina has 6 | **D×12**: one band at a time, 0→max→0 |
| `fd2` | Input select | 0..6 | D (nice-to-have) |

## Unknown — needs discovery

| Feature | Hypothesis / method |
|---|---|
| 6-band EQ (50/150/400/1k/3.5k/8k) | Per-band chars (f02.. + new) vs one multi-byte blob. Session 0 inventory narrows it; then per-band dump-diff. |
| Sound modes Movie/Music/Virtual Surround | f06 or f12; **record whether EQ chars co-change** (answers "presets overwrite EQ"). |
| Breathe color | **W only, no phone needed**: write `ff2=02` then `ff3=ff0000ff0000` — does the breathe color turn red? |
| Aurora Cool/Warm | D toggle in phone app; if inconclusive, W-probe R/W/N chars in the `da6d0fe1` service while in Aurora mode. |
| Music React presets 1–4 | **Test first**: ff3 factory value was two *different* triplets (`ff0000 0000ff`) — plausibly gradient endpoints. In Music mode write `ff3=0000ff800080` (blue→purple) and observe. If LEDs follow, presets are free. Else D per preset. |
| Screen React / streaming | `da6d0fef/f0/f1`, service `da6d0ff1` (chars f9–ff) — unexplored, out of scope. |

## Never write

`fe8` (**FACTORY RESET**), `fc6` (likely firmware update), `fa5`, `fa6`, `fe3`
(unidentified write-only). Enforced in code: probe refuses them and
`LuminaClient.write` denylists them (`Lumina.writeDenylist`).

## Discovery playbook

Ground rules (from LUMINA_SPEAKER_APP.md): single BLE central — the phone app
and the Mac can never be connected at once; GATT read-back is stale (a read
right after a write often returns the old value for minutes) so **"no diff" is
inconclusive** — dump twice ~20 s apart, trust the second, and retry with
opposite-extreme values; final proof is always a write from the Mac plus
ears/eyes.

**Techniques**
- **L (listen)** — `./scripts/probe.sh listen lumina 60`, then use the pod's
  physical controls. Timestamped notifications, no contention. Best signal.
- **D (dump-diff)** — `./scripts/probe.sh dump lumina` → save baseline → quit
  probe → phone app: change **one** setting to an **extreme** → force-quit the
  phone app → wait ~10 s (re-advertising) → dump again → diff:
  `diff <(grep '^VALUE' probe-dumps/A.txt | sort) <(grep '^VALUE' probe-dumps/B.txt | sort)`
- **W (write-and-observe)** — `./scripts/probe.sh write lumina <char> <hex>`,
  then listen/look.

**Session order** (lighting first — needs no phone):
1. **Session 0 — inventory**: `dump lumina` (save as `probe-dumps/00-baseline.txt`),
   then `listen lumina 120` touching nothing (note idle chatter to ignore).
   Confirms which family chars exist and lists unknowns.
2. **Breathe color + Music preset hypothesis** (W only, 10 minutes).
3. **Pod-knob session** (L): volume knob, brightness button.
4. **Phone session A** (D): night mode, sub gain ×3, sound modes ×3.
5. **Phone session B** (D): 6 EQ bands ×2 each, Aurora Cool/Warm, and Music
   presets ×4 if the hypothesis failed.

After each finding: update the tables above, encode it in `Encodings.swift`,
flip the `ProtocolCapabilities` flag, save dumps as `probe-dumps/NN-description.txt`.
