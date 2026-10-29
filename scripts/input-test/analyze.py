"""Decide which speaker input is audible from a webcam-mic recording.

Usage: analyze.py discover|watch <runDir>
  <runDir>/rec.txt     "START <epochSeconds>" when recording began (from micgrab)
  <runDir>/rec.wav     the recording
  <runDir>/tones.txt   "TONE <label> <hz> <device>" per tone (from tonegen)
  <runDir>/events.txt  "<epochSeconds> <event...>" (from input-test.sh)

Each input carries its own sine frequency, so the input that is live is the tone
that rises well above the quiet-room level measured before the tones started.
"""
import array, math, subprocess, sys

mode, run = sys.argv[1], sys.argv[2]
RATE = 16000
BLOCK = RATE // 4      # 0.25 s Goertzel blocks
PRESENT_DB = 15        # a tone this far over the room counts as audible

start = next(float(l.split()[1]) for l in open(f"{run}/rec.txt") if l.startswith("START"))
tones = [(l.split()[1], int(l.split()[2])) for l in open(f"{run}/tones.txt") if l.startswith("TONE")]
events = [(float(l.split()[0]), l.split()[1:]) for l in open(f"{run}/events.txt")]
raw = subprocess.run(["ffmpeg", "-v", "error", "-i", f"{run}/rec.wav", "-f", "s16le", "-ac", "1",
                      "-ar", str(RATE), "-"], capture_output=True, check=True).stdout
pcm = array.array("h", raw)

def goertzel(block, hz):
    k = 2 * math.cos(2 * math.pi * hz / RATE)
    s1 = s2 = 0.0
    for x in block:
        s1, s2 = x + k * s1 - s2, s1
    return s1 * s1 + s2 * s2 - k * s1 * s2

def power(t0, t1):
    """Median per-block power of each tone between two epoch times."""
    a, b = int((t0 - start) * RATE), int((t1 - start) * RATE)
    blocks = [pcm[i:i + BLOCK] for i in range(max(a, 0), min(b, len(pcm)) - BLOCK + 1, BLOCK)]
    if not blocks:
        return None
    out = {}
    for label, hz in tones:
        ps = sorted(goertzel(blk, hz) for blk in blocks)
        out[label] = ps[len(ps) // 2] + 1e-9
    return out

def at(name):
    return next(t for t, e in events if e[0] == name)

room = power(at("baseline"), at("tones-on"))
if room is None:
    sys.exit("recording too short for a baseline")

def heard(t0, t1):
    p = power(t0, t1)
    if p is None:
        return "no-audio", {}
    db = {k: 10 * math.log10(p[k] / room[k]) for k in p}
    live = sorted((k for k in db if db[k] >= PRESENT_DB), key=lambda k: -db[k])
    return ("+".join(live) if live else "silence"), db

def levels(db):
    return "  ".join(f"{k} {v:+.0f}" for k, v in db.items())

if mode == "discover":
    print(f"{'byte':5s} {'write':10s} {'heard':12s} dB over room")
    for i, (t, e) in enumerate(events):
        if e[0] != "acked":
            continue
        end = next(tt for tt, ee in events[i:] if ee[0] == "end")
        name, db = heard(t + 1.0, end)
        print(f"{e[1]:5s} {e[2]:10s} {name:12s} {levels(db)}")
elif mode == "watch":
    t0, t1 = at("watch"), at("watch-end")
    prev = None
    t = t0
    while t + 1 <= t1:
        name, db = heard(t, t + 1)
        if name != prev:
            print(f"{t - t0:6.1f}s  {name:12s} {levels(db)}")
            prev = name
        t += 1
