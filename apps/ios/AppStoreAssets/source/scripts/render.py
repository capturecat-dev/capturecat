#!/usr/bin/env python3
"""Render every App Store still (screenshots, product page header, search asset)
for every locale from source/templates/canvas.html with headless Google Chrome
(Playwright, channel="chrome"), then flatten to RGB PNG (no alpha).

    python3 source/scripts/render.py [--only iphone-6.9,header] [--locales en-GB,ja]

Writes out/<locale>/<placement>/NN-<screen>.png and source/build/textfit.json
(textfit-<only>.json: per-render text-fit facts check.py asserts on) and
source/build/layout-<placement>.json (device screen rects the video
compositor reuses).
"""
import argparse, json, os, sys
from pathlib import Path
from PIL import Image
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[2]          # apps/ios/AppStoreAssets
SRC = ROOT / "source"
OUT = ROOT / "out"
BUILD = SRC / "build"
COPY = json.loads((SRC / "copy.json").read_text())
LOCALES = [k for k in COPY if not k.startswith("_")]
SCREENS = ["editor", "background", "captions", "library", "stream", "share"]

# Screenshot device families: canvas size, shot folder, device geometry.
FAMILIES = {
    "iphone-6.9": dict(W=1320, H=2868, shots="iphone", sw=1320, sh=2868, radius=170, bezel=0.030, font=0.085),
    "iphone-6.3": dict(W=1206, H=2622, shots="iphone", sw=1320, sh=2868, radius=170, bezel=0.030, font=0.085),
    "ipad-13": dict(W=2064, H=2752, shots="ipad", sw=2064, sh=2752, radius=74, bezel=0.034, font=0.066, sidePad=0.10),
    "duo-outer": dict(W=1398, H=2034, shots="duo-outer", sw=1398, sh=2034, radius=120, bezel=0.034, font=0.080, sidePad=0.12, headH=0.15),
    "duo-inner": dict(W=2007, H=2853, shots="duo-inner", sw=2007, sh=2853, radius=96, bezel=0.030, font=0.068, sidePad=0.10),
}

HEADER = dict(W=3840, H=1646, safe=dict(x=1097, y=493, w=1646, h=661))
SEARCH = dict(W=3840, H=2560, safe=dict(x=836, y=765, w=2168, h=1030))


def dev(loc, shots, name, **kw):
    # Screens are captured per locale (the app runs in that language).
    f = SRC / "shots" / loc / shots / f"{name}.png"
    return dict(src=f.as_uri(), **kw)


def wide_devices(kind, loc):
    """Header / search composition: an iPad and an iPhone showing the editor."""
    ipad = dict(sw=2064, sh=2752, radius=74, bezel=0.034)
    iphone = dict(sw=1320, sh=2868, radius=170, bezel=0.030)
    if kind == "header":
        # Auxiliary art either side of the safe area (text owns the middle).
        return [dev(loc, "iphone", "captions", cx=600, top=210, height=1560, **iphone),
                dev(loc, "ipad", "editor", cx=3270, top=250, height=1260, **ipad)]
    # Search: iPad behind, iPhone in front, right of the text block.
    return [dev(loc, "ipad", "editor", cx=3170, top=600, height=1460, **ipad),
            dev(loc, "iphone", "captions", cx=2470, top=520, height=1560, **iphone)]


def flatten(path):
    im = Image.open(path)
    if im.mode != "RGB":
        bg = Image.new("RGB", im.size, (251, 251, 253))
        bg.paste(im, mask=im.split()[-1] if im.mode in ("RGBA", "LA") else None)
        im = bg
    im.save(path, compress_level=6)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="")
    ap.add_argument("--locales", default="")
    a = ap.parse_args()
    only = set(filter(None, a.only.split(",")))
    locales = [l for l in LOCALES if not a.locales or l in a.locales.split(",")]
    BUILD.mkdir(parents=True, exist_ok=True)
    fit_path = BUILD / f"textfit-{a.only.replace(',', '+') or 'all'}.json"
    fits = json.loads(fit_path.read_text()) if fit_path.exists() else {}
    template = (SRC / "templates" / "canvas.html").as_uri()

    with sync_playwright() as p:
        browser = p.chromium.launch(channel="chrome", headless=True,
                                    args=["--allow-file-access-from-files", "--font-render-hinting=none"])
        def page_for(W, H):
            pg = browser.new_page(viewport=dict(width=W, height=H), device_scale_factor=1)
            pg.goto(template)
            return pg

        def shoot(pg, cfg, path, key):
            info = pg.evaluate("cfg => window.render(cfg)", cfg)
            pg.wait_for_function("() => [...document.images].every(i => i.complete && i.naturalWidth > 0)")
            pg.evaluate("() => document.fonts.ready")
            path.parent.mkdir(parents=True, exist_ok=True)
            pg.screenshot(path=str(path), clip=dict(x=0, y=0, width=cfg["W"], height=cfg["H"]))
            flatten(path)
            info["file"] = str(path.relative_to(ROOT))
            fits[key] = info
            return info

        for fam, g in FAMILIES.items():
            if only and fam not in only:
                continue
            if not all((SRC / "shots" / l / g["shots"] / "editor.png").exists() for l in locales):
                print(f"skip {fam}: missing shots in source/shots/<locale>/{g['shots']}")
                continue
            pg = page_for(g["W"], g["H"])
            for loc in locales:
                for i, s in enumerate(SCREENS, 1):
                    d = dev(loc, g["shots"], s, sw=g["sw"], sh=g["sh"], radius=g["radius"], bezel=g["bezel"], font=g["font"])
                    for k in ("sidePad", "headH", "headTop"):
                        if k in g: d[k] = g[k]
                    lines = COPY[loc].get(f"{s}_ipad", COPY[loc][s]) if fam == "ipad-13" else COPY[loc][s]
                    cfg = dict(W=g["W"], H=g["H"], kind="shot", lang=loc, lines=lines, device=d)
                    shoot(pg, cfg, OUT / loc / fam / f"{i:02d}-{s}.png", f"{loc}/{fam}/{s}")
                print(f"rendered {loc} {fam}", flush=True)
            pg.close()

        for kind, g in (("header", HEADER), ("search", SEARCH)):
            if only and kind not in only:
                continue
            pg = page_for(g["W"], g["H"])
            layout = None
            for loc in locales:
                cfg = dict(W=g["W"], H=g["H"], kind=kind, lang=loc, lines=COPY[loc][kind],
                           safe=g["safe"], devices=wide_devices(kind, loc))
                if kind == "search":
                    cfg["textBox"] = dict(x=g["safe"]["x"], y=g["safe"]["y"], w=1220, h=g["safe"]["h"])
                info = shoot(pg, cfg, OUT / loc / kind / f"{kind}.png", f"{loc}/{kind}")
                layout = info["devices"]
                print(f"rendered {loc} {kind}", flush=True)
            (BUILD / f"layout-{kind}.json").write_text(json.dumps(layout, indent=1))
            pg.close()
        fit_path.write_text(json.dumps(fits, indent=1, ensure_ascii=False))
        browser.close()


if __name__ == "__main__":
    main()
