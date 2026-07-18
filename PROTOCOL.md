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
| `fea` | Brightness **status mirror (read-only in practice)** | 2 bytes `[pct, pct]` 0–100. Reflects the pod/phone brightness and notifies on pod-button changes, BUT **a BLE central cannot drive it** — writes (with/without response, 1-byte/2-byte, in Static and in Rainbow) are ACKed and ignored; LEDs never change (verified exhaustively 2026-07-17, watched). The phone's dumps 05/06 showing fea change were misleading — the phone updates it internally, not via a writable GATT path we can use. **Brightness is instead applied by RGB-scaling the color** (see ff3): works for Static/Breathe; Rainbow/Aurora/Music render their own colors and can't be dimmed from a central. | read/notify only |
| `ff3` | **Universal mode-color register** | 6 bytes = two RGB triplets, meaning depends on active mode: **Static/Breathe** = `[color, 000000]` (the phone app writes black as the second triplet — not the color twice as the handoff doc suggested; dump 05: static red = `ff0000 000000`); **Music React** = gradient pair; **Aurora** = tone pair. Brightness is NOT encoded here — it lives in `fea` for every mode. Rules: (1) the ff3 write must arrive on the **same connection** as the ff2 mode write — per-write reconnects don't apply, and mode transitions clear ff3, so always rewrite ff2 then ff3 together; (2) in Music React only the four official byte-pairs give a fixed gradient — **any other pair = cycle-through-all-presets** (usable as a bonus fifth option). Pairs (captured from phone app): Music P1 Blue→Purple `0000ff/ff00ff`, P2 Cyan→Blue `00ffff/0000ff`, P3 Red→Purple `ff0000/ff007f`, P4 Yellow→Orange `ffff00/ff7f00`; Aurora Cool `0000ff/00ffff`, Warm `ff0000/ff7f00`. | D+W |
| `fa4` | Sub gain | 1 byte, dB = raw − 20, range −20..+10 (raw 0..30). NOT the Fives' 2-byte format. Cross-checked: phone app +2 dB ↔ raw 22. | D+W |
| `f17` | 6-band EQ | 48-byte blob (six 8-byte records, gain = last byte, signed dB −6..+6; layout below). Wrote +6 @ 50 Hz → audibly boomier; user's phone-app settings (−2 @ 3.5k/8k) matched the baseline decode. Full-blob writes only (a 32-byte partial write was silently ignored). | D+W |
| `f24` | Sound mode | 1 byte: **01 Movie, 02 Music, 03 Virtual Surround** (00 rejected, like ff2). Music=02 cross-checked against phone app; 03 confirmed surround-like by ear; Movie=01 by elimination. | D+W |

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

## Remaining unknowns (all requested features are now decoded)

| Item | Notes |
|---|---|
| `f27`, `f2c`, `fd5`, `fe7` | Unidentified readable chars; harmless to leave alone. |
| `fef/ff0/ff1` | R/W/N, read empty, writes ack but don't retain — likely Screen React streaming; out of scope. |
| Screen React / streaming | Service `da6d0ff1` (chars f9–ff, all empty) — out of scope. |

## Never write

`fe8` (**FACTORY RESET**). `fe3` — **verified dangerous 2026-07-17: writing
`01` RESTARTS the device** (audio drops, lighting engine resets). `fc6`
(likely firmware update), `fa5`, `fa6` (unidentified write-only). Enforced in
code: probe refuses them and `LuminaClient.write` denylists them
(`Lumina.writeDenylist`).

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
