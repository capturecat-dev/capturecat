#!/usr/bin/env python3
"""Spike (e): diff FontCatalog's Mac resolution against iOS.

    python3 apps/ios-spikes/mac/merge-font-report.py results/fonts-mac.json results/<label>/e-default.json

Per curated family × SubtitleWeight: the face each platform resolves and the
advance width of the reference string at 48 pt. A "gap" is any pair where the
two platforms would draw different glyphs (different face, or the family is
missing on iOS), so preview/export on iOS would not match the Mac.
"""
import json, sys

mac = json.load(open(sys.argv[1]))
ios = json.load(open(sys.argv[2]))
ios_fam = {f["family"]: f for f in ios["families"]}
ios_sys = {r["weight"]: r for r in ios["system"]}
rows, gaps = [], 0
for f in mac["families"]:
    i = ios_fam.get(f["family"], {})
    for mw in f["weights"]:
        iw = next((r for r in i.get("weights", []) if r["weight"] == mw["weight"]), {})
        mac_sys = mw["postScriptName"].startswith(".")
        ios_fb = iw.get("fellBack", True)
        if mac_sys:
            # The Mac fell back to the system face: compare with iOS's system face.
            ref = ios_sys.get(mw["weight"], {})
            same = True
            ios_name = ref.get("postScriptName", "?") + " (system)"
            ios_w = ref.get("advanceWidth", 0)
        else:
            same = (not ios_fb) and iw.get("postScriptName") == mw["postScriptName"]
            ios_name = iw.get("postScriptName", "?") + (" (FALLBACK)" if ios_fb else "")
            ios_w = iw.get("advanceWidth", 0)
        dw = ios_w - mw["advanceWidth"]
        installed_on_ios = mac_sys or mw["postScriptName"] in i.get("members", [])
        status = "same face" if same else ("GAP — Mac face exists on iOS (name table fixes)" if installed_on_ios else "GAP — face missing on iOS")
        if not same:
            gaps += 1
        rows.append((f["family"], mw["weight"], mw["postScriptName"], ios_name, mw["advanceWidth"], ios_w, dw, status))
print(f"| Family | Weight | Mac face | iOS face | Mac width | iOS width | Δ width | |")
print("|---|---|---|---|---|---|---|---|")
for r in rows:
    print(f"| {r[0]} | {r[1]} | {r[2]} | {r[3]} | {r[4]:.1f} | {r[5]:.1f} | {r[6]:+.1f} | {r[7]} |")
missing = sum(1 for r in rows if "missing" in r[7])
print(f"\n{gaps} gap(s) of {len(rows)} family×weight pairs; {gaps - missing} fixable by resolving the Mac's PostScript name, {missing} need a substitute face.")
mono = ios.get("systemDesigns", {}).get("monospaced", [])
sfmono = next((f for f in mac["families"] if f["family"] == "SF Mono"), None)
if mono and sfmono:
    print("\nSF Mono via iOS .monospaced system design: " + "; ".join(
        f"{m['weight']}: iOS {m['postScriptName']} {m['advanceWidth']:.1f} vs Mac {w['postScriptName']} {w['advanceWidth']:.1f}"
        for m, w in zip(mono, sfmono["weights"])))
sysrows = [(m["weight"], m["postScriptName"], m["advanceWidth"], ios_sys[m["weight"]]["postScriptName"], ios_sys[m["weight"]]["advanceWidth"]) for m in mac["system"]]
print("\nSystem face (nil family): " + "; ".join(f"{w}: Mac {mn} {mw:.1f} / iOS {inn} {iw:.1f} (Δ {iw-mw:+.1f})" for w, mn, mw, inn, iw in sysrows))
