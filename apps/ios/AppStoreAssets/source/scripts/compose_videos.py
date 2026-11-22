#!/usr/bin/env python3
"""The product page header and search results videos, from each locale's own
simulator takes (source/footage/<locale>/: the app in that language), so the
app UI playing inside the devices matches the locale. The app previews are made
by source/preview/render.mjs.

  Product page header + search results videos (localized: the rendered still is the
  background, the editor playback loops inside the device screens):
    out/<locale>/header/header.mp4            3840x1646, 30 fps, seamless loop
    out/<locale>/search/search.mp4            3840x2560, 30 fps, seamless loop

    python3 source/scripts/compose_videos.py [--only header,search] [--locales en-GB]

Needs render.py to have run first (stills + source/build/layout-*.json).
"""
import argparse, json, os, re, shutil, subprocess
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[2]
SRC, OUT, BUILD = ROOT / "source", ROOT / "out", ROOT / "source" / "build"
FOOT = SRC / "footage"
COPY = json.loads((SRC / "copy.json").read_text())
LOCALES = [k for k in COPY if not k.startswith("_")]
FFMPEG = shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg"
LEAD = 1.9  # record-tour.sh starts recording 2.0 s before it launches the app


def run(args):
    subprocess.run([FFMPEG, "-hide_banner", "-loglevel", "error", "-y", *args], check=True)


def steps(name, folder=FOOT):
    out = {}
    for line in (folder / f"{name}.steps.txt").read_text().splitlines():
        m = re.match(r"([\d.]+) .*STORETOUR (\S+)", line)
        if m: out[m.group(2)] = float(m.group(1)) + LEAD
    return out


def duration(path):
    r = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)],
                       capture_output=True, text=True, check=True)
    return float(r.stdout.strip())


def loop_clip(name, dest, length=8.0, loc="en-GB"):
    """The editor playing back (captions + zooms), made into a seamless loop:
    the clip's extra last second dissolves into its first."""
    # The editor playing (captions, zooms), then the Background pane and its new
    # gradient: one continuous stretch of the take, long enough to loop.
    s = steps(name, FOOT / loc)
    start = s["play"] + 0.2
    src = FOOT / loc / f"{name}.mov"
    T = length
    graph = (f"[0:v]trim={start}:{start + T + 1},setpts=PTS-STARTPTS,fps=30,split[x][y];"
             f"[x]trim=0:{T},setpts=PTS-STARTPTS,split[h0][t0];"
             f"[h0]trim=0:1,setpts=PTS-STARTPTS[head];"
             f"[t0]trim=1:{T},setpts=PTS-STARTPTS[tail];"
             f"[y]trim={T}:{T + 1},setpts=PTS-STARTPTS[end];"
             f"[end][head]blend=all_expr='A*(1-T)+B*T'[mix];"
             f"[mix][tail]concat=n=2:v=1:a=0,format=yuv420p[v]")
    run(["-i", str(src), "-filter_complex", graph, "-map", "[v]", "-c:v", "libx264", "-crf", "12",
         "-preset", "medium", "-r", "30", str(dest)])


def mask(w, h, r, path):
    im = Image.new("L", (w * 4, h * 4), 0)
    ImageDraw.Draw(im).rounded_rectangle((0, 0, w * 4 - 1, h * 4 - 1), radius=r * 4, fill=255)
    im.resize((w, h), Image.LANCZOS).save(path)


def wide(kind, locales):
    layout = json.loads((BUILD / f"layout-{kind}.json").read_text())
    for loc in locales:
        loops = {d: BUILD / "loops" / loc / f"loop-{d}.mp4" for d in ("iphone", "ipad")}
        for d, f in loops.items():
            if not f.exists():
                f.parent.mkdir(parents=True, exist_ok=True)
                loop_clip(f"{d}-tour", f, loc=loc)
        wide_one(kind, loc, layout, loops)


def wide_one(kind, loc, layout, loops):
    clips = [loops["iphone"], loops["ipad"]] if kind == "header" else [loops["ipad"], loops["iphone"]]
    inputs, graph, last = [], [], "0:v"
    for i, (dev, clip) in enumerate(zip(layout, clips)):
        sc = dev["screen"]
        x, y, w, h = round(sc["x"]), round(sc["y"]), round(sc["w"]), round(sc["h"])
        m = BUILD / f"mask-{kind}-{i}.png"
        mask(w, h, round(sc["r"]), m)
        inputs += ["-i", str(clip), "-loop", "1", "-i", str(m)]
        vi, mi = 1 + i * 2, 2 + i * 2
        graph.append(f"[{vi}:v]scale={w}:{h}:flags=lanczos,format=rgba[s{i}];[{mi}:v]format=gray[m{i}];"
                     f"[s{i}][m{i}]alphamerge[c{i}];[{last}][c{i}]overlay={x}:{y}:shortest=1[o{i}]")
        last = f"o{i}"
    graph.append(f"[{last}]format=yuv420p[v]")
    for loc in [loc]:
        still = OUT / loc / kind / f"{kind}.png"
        dest = OUT / loc / kind / f"{kind}.mp4"
        run(["-loop", "1", "-framerate", "30", "-i", str(still), *inputs,
             "-filter_complex", ";".join(graph), "-map", "[v]", "-t", "8",
             "-c:v", "libx264", "-profile:v", "high", "-pix_fmt", "yuv420p", "-preset", "medium",
             "-b:v", "24M", "-maxrate", "30M", "-bufsize", "60M", "-r", "30", "-movflags", "+faststart", str(dest)])
        print(f"composed {loc} {kind}", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="header,search")
    ap.add_argument("--locales", default="")
    a = ap.parse_args()
    only = set(a.only.split(","))
    locales = [l for l in LOCALES if not a.locales or l in a.locales.split(",")]
    BUILD.mkdir(parents=True, exist_ok=True)
    if only & {"header", "search"}:
        for kind in ("header", "search"):
            if kind in only:
                wide(kind, locales)


if __name__ == "__main__":
    main()
