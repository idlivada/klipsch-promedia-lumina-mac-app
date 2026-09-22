#!/usr/bin/env python3
"""Score webcam frames of the Lumina LEDs against the colorwall schedule.

Usage: analyze.py suite|step <runDir>
  <runDir>/frames.txt  "<index> <epochSeconds>" per frame (from camgrab)
  <runDir>/wall.txt    "<epochSeconds> <scenario>" per switch (from colorwall)
Env: CROP=w:h:x:y  LED region in the webcam frame (ffmpeg crop), default 650:440:450:280

Webcam auto-exposure makes brightness unreliable: judge hue. A near-off LED
reads as a bright panel with the room suddenly visible, so "black" is checked
by eye (see the frame printed for it), not scored.
"""
import colorsys, os, subprocess, sys

mode, run = sys.argv[1], sys.argv[2]
crop = os.environ.get("CROP", "650:440:450:280")
wall = [(float(t), n) for t, n in (l.split() for l in open(f"{run}/wall.txt"))]
frames = [(int(a), float(b)) for a, b in (l.split() for l in open(f"{run}/frames.txt") if l[0].isdigit())]

def led(i):
    raw = subprocess.run(["ffmpeg", "-loglevel", "error", "-i", f"{run}/frame_{i:03d}.jpg",
                          "-vf", f"crop={crop},scale=1:1:flags=area", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
                         capture_output=True, check=True).stdout
    return tuple(raw[:3])

def hsv(c):
    return colorsys.rgb_to_hsv(*(x / 255 for x in c))

# Bucket edges fit how the webcam renders the LEDs: orange ff8000 reads ~49°,
# yellow ~60°.
def name(c):
    h, s, v = hsv(c)
    if v < 0.25: return "dark"
    if s < 0.25: return "white"
    h *= 360
    for lim, n in [(15, "red"), (55, "orange"), (75, "yellow"), (160, "green"), (200, "cyan"),
                   (255, "blue"), (290, "purple"), (340, "magenta"), (361, "red")]:
        if h < lim: return n

col = {i: led(i) for i, _ in frames}

def window(k):
    t = wall[k][0]
    end = wall[k + 1][0] if k + 1 < len(wall) else t + 4
    return t, [(i, ft) for i, ft in frames if t - 0.1 <= ft < end]

if mode == "suite":
    expect = {"red": {"red"}, "green": {"green"}, "blue": {"blue"}, "yellow": {"yellow"}, "cyan": {"cyan"},
              "magenta": {"magenta", "purple"}, "white": {"white"}, "edges": {"red"},
              "letterbox": {"orange"}, "darkmovie": {"cyan", "green"},
              "alternate-red": {"red"}, "alternate-blue": {"blue"}}
    for k, (_, n) in enumerate(wall):
        if n == "alternate": continue
        t, fs = window(k)
        if not fs: continue
        last = fs[-1][0]
        c = col[last]
        settled = f"| settled led={name(c):8s} #{c[0]:02x}{c[1]:02x}{c[2]:02x}  frame_{last:03d}.jpg"
        if n not in expect:
            print(f"{n:15s} (check by eye) {settled}")
            continue
        hit = next((ft - t for i, ft in fs if ft > t and name(col[i]) in expect[n]), None)
        verdict = f"OK   reached in <={hit:.2f}s" if hit is not None else "MISS"
        print(f"{n:15s} {verdict:22s} {settled}")
elif mode == "step":
    for k, (_, n) in enumerate(wall):
        if k == 0: continue
        t, fs = window(k)
        h0 = hsv(col[fs[0][0]])[0] * 360
        ok = (lambda h: h < 25 or h > 340) if n == "red" else (lambda h: 190 < h < 260)
        moved = next((ft - t for i, ft in fs if ft > t and abs((hsv(col[i])[0] * 360 - h0 + 180) % 360 - 180) > 15), None)
        reached = next((ft - t for i, ft in fs if ft > t and ok(hsv(col[i])[0] * 360)), None)
        fmt = lambda x: "never" if x is None else f"{x:.2f}s"
        print(f"-> {n:5s}: LED starts changing after {fmt(moved)}, reaches target hue after {fmt(reached)}")
    fps = (len(frames) - 1) / (frames[-1][1] - frames[0][1])
    print(f"(webcam {fps:.0f} fps — timings include ~1 frame of camera latency)")
else:
    sys.exit(f"unknown mode {mode}")
