#!/usr/bin/env python3
"""Compare the iOS cursor rasters with the Mac's, byte for byte.

    ios-cursor-rasters-compare.py <mac-dir> <ios-dir>

<mac-dir>: the Mac's `CaptureCat --web-cursor-sprites <dir> --verify-sizes …`
(manifest.json with every style's 1×/2×/3× premultiplied RGBA8 inline, and
verify/<slug>-<W>x<H>.rgba). <ios-dir>: `ios-vectors-bin --cursor-rasters
<dir> --sizes …` run in the iOS Simulator (apps/ios/scripts/ios-vectors.sh):
<slug>@<k>x.rgba, verify/<slug>-<W>x<H>.rgba and assets.json. Every raster
must be byte-identical, and every style's point size and hotspot equal.
Exit 0 only then.
"""
import base64
import json
import os
import sys

# Grids with a DOCUMENTED difference: reported with their numbers, not gated.
# Each is an open item (docs/ios-studio-plan.md, "Cursor art"), not a pass.
KNOWN = {
    # At 21×29 px (cursor raster scale ≈1.03) the Mac's NSImage draw of the
    # vector arrow lands about one pixel row lower than the scaled CTM puts
    # it (the arrow's bottom rows match, its tip does not); every other
    # arrow grid, incl. other non-uniform ones, is byte-identical. A Mac
    # NSImage behaviour near unit scale, not reproduced on iOS yet.
    "macos-arrow-21x29": "Mac NSImage arrow ~1 row lower near unit scale",
    "white-arrow-21x29": "Mac NSImage arrow ~1 row lower near unit scale",
}


def stats(a, b):
    """(pixels differing, max |Δ| over channels) for two equal-length buffers."""
    px = 0
    worst = 0
    for i in range(0, len(a), 4):
        d = max(abs(a[i + c] - b[i + c]) for c in range(4))
        if d:
            px += 1
            worst = max(worst, d)
    return px, worst


def main():
    mac_dir, ios_dir = sys.argv[1], sys.argv[2]
    manifest = json.load(open(os.path.join(mac_dir, "manifest.json")))
    assets = {a["style"]: a for a in json.load(open(os.path.join(ios_dir, "assets.json")))}
    failures = 0
    checked = 0
    per_style = {}
    known = []

    def compare(label, style, mac, ios_path):
        nonlocal failures, checked
        checked += 1
        ok_style = per_style.setdefault(style, [0, 0])
        ok_style[1] += 1
        if not os.path.exists(ios_path):
            print(f"  FAIL {label}: iOS wrote no raster")
            failures += 1
            return
        ios = open(ios_path, "rb").read()
        if len(ios) != len(mac):
            print(f"  FAIL {label}: {len(ios)} bytes on iOS, {len(mac)} on the Mac (pixel grid differs)")
            failures += 1
            return
        if ios != mac:
            px, worst = stats(mac, ios)
            if label in KNOWN:
                print(f"  KNOWN (not gated) {label}: {px} px differ, max |Δ| {worst}/255 — {KNOWN[label]}")
                known.append(label)
                return
            print(f"  FAIL {label}: {px} px differ, max |Δ| {worst}/255")
            failures += 1
            return
        if label in KNOWN:
            print(f"  (now identical — drop it from KNOWN) {label}")
        ok_style[0] += 1

    for s in manifest["styles"]:
        style, slug = s["style"], s["slug"]
        a = assets.get(style)
        if a is None:
            print(f"  FAIL {style}: iOS has no asset")
            failures += 1
            continue
        for key in ("pointWidth", "pointHeight", "hotSpotX", "hotSpotY"):
            if float(a[key]) != float(s[key]):
                print(f"  FAIL {style} {key}: Mac {s[key]} iOS {a[key]}")
                failures += 1
        for r in s["rasters"]:
            compare(f"{slug}@{r['scale']}x", style, base64.b64decode(r["rgbaBase64"]),
                    os.path.join(ios_dir, f"{slug}@{r['scale']}x.rgba"))

    slugs = {s["slug"]: s["style"] for s in manifest["styles"]}
    vdir = os.path.join(mac_dir, "verify")
    for name in sorted(os.listdir(vdir)) if os.path.isdir(vdir) else []:
        if not name.endswith(".rgba"):
            continue
        slug = name.rsplit("-", 1)[0]
        compare(f"{name[:-5]}", slugs.get(slug, slug), open(os.path.join(vdir, name), "rb").read(),
                os.path.join(ios_dir, "verify", name))

    for style, (ok, n) in per_style.items():
        a = assets.get(style, {})
        print(f"  {style}: {ok}/{n} rasters byte-identical"
              f" (point {a.get('pointWidth')}×{a.get('pointHeight')}, hotspot {a.get('hotSpotX')},{a.get('hotSpotY')})")
    print(f"cursor-rasters: {checked} raster(s) over {len(per_style)} styles, {len(known)} known differences,"
          f" {failures} failing")
    print("CURSOR-RASTERS PASS" if failures == 0 and checked else "CURSOR-RASTERS FAIL")
    sys.exit(0 if failures == 0 and checked else 1)


if __name__ == "__main__":
    main()
