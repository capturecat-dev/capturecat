#!/usr/bin/env python3
"""Compare the iOS replay of the golden vectors against the Mac's.

    ios-vectors-compare.py <mac-dir> <ios-dir>

<mac-dir> holds the Mac's `--web-vectors` output (every unit), <ios-dir> the
same units run inside the iOS Simulator (apps/ios/scripts/ios-vectors.sh).
Every unit the iOS run produced must match the Mac's file: byte-identical, or
— per value — strings, ints, bools and nulls exact and doubles within 1e-12
(absolute). The KNOWN table below names the units with a documented iOS
platform difference; they are reported, not gated. Units the Mac has that iOS did not run are listed by name: they
are not compiled for iOS yet (see apps/ios/StudioVectors/ClusterShims.swift).
Exit 0 only when every iOS unit matches.
"""
import json
import math
import os
import sys

TOL = 1e-12

# Units with a DOCUMENTED iOS platform difference (docs/ios-studio-plan.md,
# "iOS-side approximations"): reported with their counts, not gated. Anything
# else that differs fails. Each entry is a decision to revisit, not a pass.
KNOWN = {
    # The iOS system font is SF UI, not the Mac's .AppleSystemUIFont: ascent,
    # descent and line height differ by ~0.1–1.7 pt, and everything laid out
    # from them follows. Same for any family iOS resolves differently.
    "annotationDrawRecipe": "system font metrics differ on iOS",
    "annotationGeometry": "system font metrics differ on iOS",
    "annotationTextMetrics": "system font metrics differ on iOS",
    "keystrokeOverlayDrawRecipe": "system font metrics differ on iOS",
    "keystrokeOverlayPillMetrics": "system font metrics differ on iOS",
    # iOS rasterizes its own arrow (CursorArt); the Mac uses the real 32×32
    # system cursor bitmap. Plan: bundle the Mac's byte-exact rasters.
    "cursorStyleAssets": "cursor art: iOS draws its own arrow",
    "exportCursorCGFallback": "cursor art: iOS draws its own arrow",
    "exportCursorComposite": "cursor art: iOS draws its own arrow",
    "exportCursorSetup": "cursor art: iOS draws its own arrow",
}
# GPU-rendered 8-bit samples may differ by ±1 between macOS and iOS Core
# Image; every other value in these units must still match exactly.
GPU_PLUS_MINUS_ONE = {"backgroundLookStyledPixels": "gpuTargets"}


def walk(a, b, path, out):
    """Collect (path, mac, ios, delta) for every value that differs."""
    if isinstance(a, bool) or isinstance(b, bool) or a is None or b is None:
        if a != b or type(a) is not type(b):
            out.append((path, a, b, None))
        return
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        if isinstance(a, int) and isinstance(b, int):
            if a != b:
                out.append((path, a, b, None))
            return
        fa, fb = float(a), float(b)
        if fa == fb:
            # Same value, different spelling: only -0.0 vs 0.0 can do that.
            if math.copysign(1, fa) != math.copysign(1, fb):
                out.append((path, a, b, 0.0))
            return
        out.append((path, a, b, abs(fa - fb)))
        return
    if isinstance(a, str) and isinstance(b, str):
        if a != b:
            out.append((path, a, b, None))
        return
    if isinstance(a, list) and isinstance(b, list):
        if len(a) != len(b):
            out.append((path + ".length", len(a), len(b), None))
            return
        for i, (x, y) in enumerate(zip(a, b)):
            walk(x, y, f"{path}[{i}]", out)
        return
    if isinstance(a, dict) and isinstance(b, dict):
        if list(a.keys()) != list(b.keys()):
            out.append((path + ".keys", list(a.keys()), list(b.keys()), None))
            return
        for k in a:
            walk(a[k], b[k], f"{path}.{k}", out)
        return
    out.append((path, a, b, None))


def main():
    mac_dir, ios_dir = sys.argv[1], sys.argv[2]
    mac_units = sorted(f[:-5] for f in os.listdir(mac_dir) if f.endswith(".json"))
    ios_units = sorted(f[:-5] for f in os.listdir(ios_dir) if f.endswith(".json"))
    failures = 0
    identical = within = 0
    worst = 0.0
    known = []
    gpu_units = []
    for unit in ios_units:
        mac_path = os.path.join(mac_dir, unit + ".json")
        ios_path = os.path.join(ios_dir, unit + ".json")
        if not os.path.exists(mac_path):
            print(f"  FAIL {unit}: iOS produced a unit the Mac does not have")
            failures += 1
            continue
        mac_bytes = open(mac_path, "rb").read()
        ios_bytes = open(ios_path, "rb").read()
        if mac_bytes == ios_bytes:
            identical += 1
            continue
        diffs = []
        walk(json.loads(mac_bytes), json.loads(ios_bytes), unit, diffs)
        hard = [d for d in diffs if d[3] is None or d[3] > TOL]
        soft = [d for d in diffs if d[3] is not None and d[3] <= TOL]
        if unit in GPU_PLUS_MINUS_ONE:
            key = GPU_PLUS_MINUS_ONE[unit]
            gpu = [d for d in hard if f".{key}." in d[0] and isinstance(d[1], int)
                   and isinstance(d[2], int) and abs(d[1] - d[2]) <= 1]
            hard = [d for d in hard if d not in gpu]
            if not hard:
                gpu_units.append(f"{unit} ({len(gpu)} 8-bit GPU samples ±1)")
                continue
        if unit in KNOWN and hard:
            known.append((unit, KNOWN[unit], len(hard)))
            continue
        if hard:
            failures += 1
            print(f"  FAIL {unit}: {len(hard)} value(s) differ beyond {TOL:g}"
                  f" ({len(soft)} within)")
            for path, a, b, delta in hard[:6]:
                extra = f" |Δ|={delta:.3g}" if delta is not None else ""
                print(f"      {path}: mac={json.dumps(a)[:80]} ios={json.dumps(b)[:80]}{extra}")
        elif soft:
            within += 1
            worst = max(worst, max(d[3] for d in soft))
            zeros = sum(1 for d in soft if d[3] == 0.0)
            print(f"  (ok) {unit}: {len(soft)} double(s) within {TOL:g},"
                  f" worst |Δ|={max(d[3] for d in soft):.3g}"
                  + (f" ({zeros} are -0.0 vs 0.0)" if zeros else ""))
        else:
            failures += 1
            i = next(k for k in range(min(len(mac_bytes), len(ios_bytes))) if mac_bytes[k] != ios_bytes[k])
            print(f"  FAIL {unit}: bytes differ but no value does (first at byte {i}:"
                  f" mac={mac_bytes[max(0, i - 20):i + 20]!r} ios={ios_bytes[max(0, i - 20):i + 20]!r})")
    not_run = [u for u in mac_units if u not in set(ios_units)]
    for unit, reason, n in known:
        print(f"  KNOWN iOS DIFFERENCE (not gated) {unit}: {n} value(s) — {reason}")
    for line in gpu_units:
        print(f"  (ok) {line}")
    print(f"ios-vectors: {len(ios_units)} unit(s) replayed on iOS — {identical} byte-identical, "
          f"{within} within {TOL:g}" + (f" (worst {worst:.3g})" if within else "")
          + f", {len(gpu_units)} equal but for ±1 GPU samples, {len(known)} known iOS differences, "
          f"{failures} failing")
    print(f"ios-vectors: {len(not_run)} Mac unit(s) not compiled for iOS yet: {', '.join(not_run)}")
    print("IOS-VECTORS PASS" if failures == 0 and ios_units else "IOS-VECTORS FAIL")
    sys.exit(0 if failures == 0 and ios_units else 1)


if __name__ == "__main__":
    main()
