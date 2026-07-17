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

## Session 0 inventory — 2026-07-17 (`probe-dumps/00-baseline.txt`)

The Lumina does **not** expose the Fives' `f06` (vocal), `f08`, `f12`–`f15`
chars. Its EQ service instead has: `f02/f03/f04` (all read `06`), `f05` (00),
`f09` (00), **`f16` (R only, reads `06`)**, **`f17` (48-byte blob)**, `f24`
(02), `f27` (00), `f2c` (01).

### `f17` — 6-band EQ blob (decoded from baseline, pending W verification)

48 bytes = six 8-byte records `[band, 00, freqLE16, 00, 01, 00, gain]`:

```
00 00 3200 00 01 00 00   band 0:   50 Hz, gain 0x00
01 00 9600 00 01 00 00   band 1:  150 Hz, gain 0x00
02 00 9001 00 01 00 00   band 2:  400 Hz, gain 0x00
03 00 e803 00 01 00 00   band 3: 1000 Hz, gain 0x00
04 00 ac0d 00 01 00 fe   band 4: 3500 Hz, gain 0xfe (-2 if signed dB)
05 00 401f 00 01 00 fe   band 5: 8000 Hz, gain 0xfe (-2 if signed dB)
```

Frequencies match the Lumina app's bands exactly. `f16` = `06` is presumably
the band count. Last byte is the gain candidate (signed dB); the `00 01 00`
run may be enable/Q/filter-type. TODO: confirm gain byte + range by W
(write +gain at 50 Hz, listen), and whether partial writes are allowed or the
full 48-byte blob must be rewritten.

## Candidates (updated after Session 0)

| Char | Read | Working hypothesis | Next step |
|---|---|---|---|
| `fa2` | `18` (24) | Master volume 0..0x24 (24/36 ≈ 67%) | **L**: pod knob sweep; then W |
| `fa3` | `00` | Mute 0/1 | W |
| `fa4` | `16` (22) | **1-byte** sub gain (NOT Fives' 2-byte `[04,raw]`): 22−20 = +2 dB if offset 20 | User states phone-app sub value; W both extremes. App's `subGainData` must switch to 1 byte once confirmed |
| `f05` | `00` | Night mode 0/1 | D or W |
| `f24` | `02` | **Sound mode** — only 3-valued candidate; Fives preset chars absent | User states current phone-app mode → decodes one value; W the other two |
| `f27` | `00` | Unknown (dynamic bass? surround sub-toggle?) | observe during D sessions |
| `f2c` | `01` | Unknown | observe during D sessions |
| `f02/f03/f04` | `06 06 06` | Legacy bass/mid/treble; all-equal reads suggest flat (byte = dB+6?) — possibly vestigial on Lumina | low priority; 6-band EQ is `f17` |
| `fd2` | `02` | Input select (02 = Bluetooth on Fives… but likely USB here) | D (nice-to-have) |
| `fe9` | `8403` | LE 0x0384 = 900 s — auto-standby timer? | ignore |

## Unknown — still needs discovery

| Feature | Hypothesis / method |
|---|---|
| Music React presets 1–4 | **Test in progress**: baseline had `ff3 = ff0000 ff007f` (red→pink/purple) while in Music React — consistent with gradient-endpoints hypothesis. Wrote `00ffff 0040ff` (cyan→blue) on 2026-07-17; awaiting user observation. |
| Breathe color | W: `ff2=02` then `ff3=ff0000ff0000` — does the breathe color turn red? |
| Aurora Cool/Warm | D toggle in phone app; if inconclusive, W-probe R/W/N chars in `da6d0fe1` while in Aurora. Note `fef/ff0/ff1` read empty. |
| EQ gain range | Phone app min/max on one band → D, or W increasing values until rejected. |
| Screen React / streaming | `da6d0fef/f0/f1`, service `da6d0ff1` (chars f9–ff, all empty) — out of scope. |

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
