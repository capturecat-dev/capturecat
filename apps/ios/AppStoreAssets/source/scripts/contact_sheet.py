#!/usr/bin/env python3
"""contact-sheet-<locale>.png at the AppStoreAssets root: every still for that
locale plus poster frames of its videos, labelled by placement."""
import json, subprocess, tempfile
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "out"
COPY = json.loads((ROOT / "source" / "copy.json").read_text())
LOCALES = [k for k in COPY if not k.startswith("_")]
ROWS = ["iphone-6.9", "iphone-6.3", "ipad-13", "duo-outer", "duo-inner"]
FONT = "/System/Library/Fonts/SFNS.ttf"


def font(size):
    try: return ImageFont.truetype(FONT, size)
    except OSError: return ImageFont.load_default()


def frame(video, t):
    with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as f:
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", str(t), "-i", str(video), "-frames:v", "1", f.name], check=True)
        return Image.open(f.name).convert("RGB")


def fit(im, h):
    return im.resize((round(im.width * h / im.height), h), Image.LANCZOS)


def main():
    TH, GAP, LABEL, PAD = 520, 18, 46, 40
    for loc in LOCALES:
        rows = []
        for fam in ROWS:
            files = sorted((OUT / loc / fam).glob("*.png"))
            if files: rows.append((fam, [fit(Image.open(f).convert("RGB"), TH) for f in files]))
        wide = []
        for kind in ("header", "search"):
            p = OUT / loc / kind / f"{kind}.png"
            if p.exists(): wide.append((f"{kind} (image)", fit(Image.open(p).convert("RGB"), TH)))
            v = OUT / loc / kind / f"{kind}.mp4"
            if v.exists(): wide.append((f"{kind} (video, 4 s)", fit(frame(v, 4), TH)))
        if wide: rows.append(("header + search", [im for _, im in wide]))
        prev = []
        for name in ("iphone-6.9", "ipad-13"):
            v = OUT / loc / "app-preview" / f"{name}.mp4"
            if v.exists(): prev += [fit(frame(v, t), TH) for t in (1.2, 6.5, 10.5, 14.5, 17.5, 21.5, 26.5)]
        if prev: rows.append(("app previews (stills at 1.2 / 6.5 / 10.5 / 14.5 / 17.5 / 21.5 / 26.5 s): iPhone, then iPad", prev))
        W = max(sum(im.width for im in ims) + GAP * (len(ims) - 1) for _, ims in rows) + PAD * 2
        H = PAD * 2 + 90 + sum(LABEL + TH + GAP * 2 for _ in rows)
        sheet = Image.new("RGB", (W, H), (244, 243, 248))
        d = ImageDraw.Draw(sheet)
        d.text((PAD, PAD), f"CaptureCat — App Store assets — {loc}", fill=(11, 11, 15), font=font(48))
        y = PAD + 90
        for label, ims in rows:
            d.text((PAD, y), label, fill=(92, 92, 104), font=font(30))
            y += LABEL
            x = PAD
            for im in ims:
                sheet.paste(im, (x, y)); x += im.width + GAP
            y += TH + GAP * 2
        out = ROOT / f"contact-sheet-{loc}.png"
        sheet.save(out)
        print("wrote", out.name, sheet.size)


if __name__ == "__main__":
    main()
