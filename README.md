# Lumina — menu-bar control for Klipsch ProMedia Lumina 2.1

A lightweight macOS menu-bar app that controls **Klipsch ProMedia Lumina 2.1**
speakers over Bluetooth LE — volume, EQ, sound modes, subwoofer gain, and the
full RGB lighting system — from a small popover in your menu bar.

<!-- Add a screenshot here once you have one:
![Lumina popover](docs/screenshot.png) -->

## What it does

Once connected, Lumina gives you a two-tab popover:

**Audio**
- **Volume** with a mute button
- **Sound modes** — Movie, Music, Virtual Surround
- **Night mode** on/off
- **Subwoofer gain** from −20 dB to +10 dB
- **6-band equalizer** (50 Hz · 150 Hz · 400 Hz · 1 kHz · 3.5 kHz · 8 kHz), each −6…+6 dB, with a **Flat** reset

**Lighting**
- **Lights** on/off (remembers your last mode)
- **Modes** — Rainbow, Breathe, Static, Aurora, Music React
- **Brightness** (Static and Breathe)
- **Static / Breathe** — color swatches plus a full color picker
- **Aurora** — Cool or Warm tone
- **Music React** — four gradient presets (Blue→Purple, Cyan→Blue, Red→Purple, Yellow→Orange)

Changes you make on the speaker's control pod (like the brightness button) are
reflected back in the app automatically.

## Why it's needed

Klipsch ships control apps for **phones** (Klipsch Connect Plus) and for
**Windows** (Klipsch Control), but there is no native app for macOS — Mac users
otherwise can't adjust the speakers' EQ, sound modes, or lighting at all. Lumina
fills that gap and keeps everything a single click away in the menu bar.

The speakers accept only **one Bluetooth connection at a time**, so while Lumina
is connected your phone app can't be, and vice-versa. Lumina includes a
**Release to Phone App** menu item to hand the connection back without quitting.

## Requirements

- macOS 14 (Sonoma) or later
- A Mac with Bluetooth
- Xcode Command Line Tools (for the Swift compiler) — install with:
  ```sh
  xcode-select --install
  ```

There is no pre-built download yet, so you build it from source (one command).

## Install

```sh
git clone https://github.com/idlivada/klipsch-promedia-lumina-mac-app.git
cd klipsch-promedia-lumina-mac-app
./scripts/build.sh --open
```

`build.sh` compiles the app, bundles it as `build/Lumina.app`, ad-hoc code-signs
it, and (`--open`) launches it. To run it again later, just open `build/Lumina.app`
or drag it to your Applications folder.

### First launch

1. macOS will ask for **Bluetooth permission** — click **Allow**. (The app can't
   find the speakers without it.)
2. Make sure the **Klipsch phone app is closed** so the speakers are free to
   connect.
3. The status dot in the popover turns **green** when connected.

The app lives only in the menu bar (no Dock icon). Quit it from the gear menu
inside the popover.

## Using it

- Click the **speaker icon** in the menu bar to open the popover.
- Switch between the **Audio** and **Lighting** tabs.
- The **gear menu** (top-right) has **Release to Phone App / Reconnect** and **Quit**.

### Notes

- **Brightness** is adjustable in **Static** and **Breathe** modes. Rainbow,
  Aurora, and Music React render their own colors on the speaker and can't be
  dimmed from a computer.
- If the app is stuck **Searching…**, close the Klipsch app on your phone — the
  speakers only allow one connection at a time.

## Troubleshooting

| Problem | Fix |
|---|---|
| Stays "Searching…" | Close the Klipsch phone app; the speakers only accept one connection. |
| No Bluetooth prompt / can't connect | Grant Bluetooth access in **System Settings → Privacy & Security → Bluetooth**. |
| Want to use the phone app | Gear menu → **Release to Phone App**, then reconnect later. |
| `swift: command not found` | Run `xcode-select --install`. |

## How it works

The Lumina's Bluetooth protocol isn't published by Klipsch; it was
reverse-engineered by observing the official app and testing against the
hardware. The full characteristic map and findings are documented in
[PROTOCOL.md](PROTOCOL.md). This project is an independent, unofficial tool and
is not affiliated with or endorsed by Klipsch.
