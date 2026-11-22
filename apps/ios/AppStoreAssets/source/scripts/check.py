#!/usr/bin/env python3
"""Automated gate for every App Store asset in out/.

  python3 source/scripts/check.py            # check everything, write source/build/check-report.txt
  python3 source/scripts/check.py --selftest # prove each check FAILS on an injected defect

Images: exact pixel size per placement, PNG, RGB with no alpha channel (PIL mode and
sips hasAlpha), every expected file present for every locale.
Text: from render.py's text-fit facts (measured in the real Chrome layout): every
headline line fits its box at >= 62 % of the design size, no line wrapped, the text
block inside the canvas, never overlapping the device, and for the header / search
assets wholly inside Apple's art safe area.
Videos (ffprobe): H.264, exact size, 30 fps constant, duration in range, yuv420p;
app previews High profile <= level 4.0 with a stereo 48 kHz AAC track and < 500 MB;
header / search loops seamless (first vs last frame difference no bigger than an
ordinary frame step).
App previews (guideline 2.3.4, the rules Strobia's preview was rejected and then
passed under): one file per locale (not hard links), headline text fits per locale
(source/build/preview/<device>/textfit.json), audio is not silent, no device frame
(no dark bezel ring round the picture) at the start, middle and end, and the last
frame is app UI (structured, not a near-uniform card with a logo).
"""
import json, os, subprocess, sys
import numpy as np
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
SRC, OUT, BUILD = ROOT / "source", ROOT / "out", ROOT / "source" / "build"
COPY = json.loads((SRC / "copy.json").read_text())
LOCALES = [k for k in COPY if not k.startswith("_")]
SCREENS = ["editor", "background", "captions", "library", "stream", "share"]
STILLS = {"iphone-6.9": (1320, 2868), "iphone-6.3": (1206, 2622), "ipad-13": (2064, 2752),
          "duo-outer": (1398, 2034), "duo-inner": (2007, 2853)}
WIDE = {"header": (3840, 1646, dict(x=1097, y=493, w=1646, h=661)),
        "search": (3840, 2560, dict(x=836, y=765, w=2168, h=1030))}
VIDEOS = {"app-preview/iphone-6.9.mp4": (886, 1920, 15, 30, True),
          "app-preview/ipad-13.mp4": (1200, 1600, 15, 30, True),
          "header/header.mp4": (3840, 1646, 5, 30, False),
          "search/search.mp4": (3840, 2560, 5, 30, False)}
MIN_RATIO = 0.62


class Gate:
    def __init__(self): self.fails, self.passes, self.notes = [], 0, []
    def check(self, ok, what):
        if ok: self.passes += 1
        else: self.fails.append(what)
        return ok


def check_image(g, path, W, H):
    if not g.check(path.exists(), f"missing {path.relative_to(ROOT)}"): return
    im = Image.open(path)
    rel = path.relative_to(ROOT)
    g.check(im.format == "PNG", f"{rel}: format {im.format}")
    g.check(im.size == (W, H), f"{rel}: size {im.size} != {(W, H)}")
    g.check(im.mode == "RGB", f"{rel}: mode {im.mode} (alpha or palette)")
    r = subprocess.run(["sips", "-g", "hasAlpha", str(path)], capture_output=True, text=True).stdout
    g.check("hasAlpha: no" in r, f"{rel}: sips reports alpha")


def check_text(g, key, info, safe=None):
    t = info.get("text") or {}
    W, H = info["W"], info["H"]
    g.check(bool(t.get("fits")), f"{key}: headline does not fit its box")
    g.check(t.get("ratio", 0) >= MIN_RATIO, f"{key}: font shrunk to {t.get('ratio', 0):.2f} of design size")
    for ln in t.get("lines", []):
        g.check(ln["h"] < t["size"] * 1.6, f"{key}: line wrapped: {ln['text']!r}")
        g.check(ln["x"] >= 0 and ln["x"] + ln["w"] <= W and ln["y"] >= 0 and ln["y"] + ln["h"] <= H,
                f"{key}: line outside canvas: {ln['text']!r}")
        g.check(ln["x"] >= t["box"]["x"] - 1 and ln["x"] + ln["w"] <= t["box"]["x"] + t["box"]["w"] + 1,
                f"{key}: line wider than its box: {ln['text']!r}")
        if safe:
            g.check(ln["x"] >= safe["x"] and ln["x"] + ln["w"] <= safe["x"] + safe["w"]
                    and ln["y"] >= safe["y"] and ln["y"] + ln["h"] <= safe["y"] + safe["h"],
                    f"{key}: text outside Apple's art safe area: {ln['text']!r}")
    if info["kind"] == "shot" and info.get("devices"):
        d = info["devices"][0]
        r = t["rect"]
        g.check(r["y"] + r["h"] <= d["y"], f"{key}: headline overlaps the device")
        g.check(d["x"] >= 0 and d["x"] + d["w"] <= W and d["y"] + d["h"] <= H, f"{key}: device clipped by canvas")
    if info["kind"] in ("header", "search") and info.get("devices"):
        r = t["rect"]
        for d in info["devices"]:
            overlap = not (r["x"] + r["w"] <= d["x"] or d["x"] + d["w"] <= r["x"] or r["y"] + r["h"] <= d["y"] or d["y"] + d["h"] <= r["y"])
            if overlap:
                # Allowed only when no text line touches the device.
                for ln in t["lines"]:
                    g.check(ln["x"] + ln["w"] <= d["x"] or d["x"] + d["w"] <= ln["x"], f"{key}: text overlaps a device: {ln['text']!r}")


def probe(path):
    r = subprocess.run(["ffprobe", "-v", "error", "-show_entries",
                        "stream=codec_type,codec_name,profile,level,width,height,r_frame_rate,avg_frame_rate,pix_fmt,sample_rate,channels:format=duration,size",
                        "-of", "json", str(path)], capture_output=True, text=True, check=True)
    return json.loads(r.stdout)


def frame_diff(path, at_end):
    """Mean |Δ| (0-255) between first and last frame, and between frames 0 and 1."""
    def grab(args):
        r = subprocess.run(["ffmpeg", "-v", "error", *args, "-i", str(path), "-frames:v", "1", "-vf", "scale=480:-2",
                            "-f", "rawvideo", "-pix_fmt", "gray", "-"], capture_output=True, check=True)
        return r.stdout
    first = grab([])
    second = grab(["-ss", "0.0334"])
    last = grab(["-sseof", "-0.04"])
    mad = lambda a, b: sum(abs(x - y) for x, y in zip(a, b)) / max(1, len(a))
    return mad(first, last), mad(first, second)


def check_video(g, path, W, H, dmin, dmax, preview):
    rel = path.relative_to(ROOT)
    if not g.check(path.exists(), f"missing {rel}"): return None
    p = probe(path)
    v = [s for s in p["streams"] if s["codec_type"] == "video"]
    a = [s for s in p["streams"] if s["codec_type"] == "audio"]
    if not g.check(len(v) == 1, f"{rel}: {len(v)} video streams"): return None
    v = v[0]
    dur = float(p["format"]["duration"])
    g.check(v["codec_name"] == "h264", f"{rel}: codec {v['codec_name']}")
    g.check((v["width"], v["height"]) == (W, H), f"{rel}: {v['width']}x{v['height']} != {W}x{H}")
    g.check(v["r_frame_rate"] == "30/1" and v["avg_frame_rate"] == "30/1", f"{rel}: fps {v['r_frame_rate']} / {v['avg_frame_rate']}")
    g.check(dmin <= dur <= dmax, f"{rel}: duration {dur:.2f}s outside {dmin}-{dmax}s")
    g.check(v["pix_fmt"] == "yuv420p", f"{rel}: pix_fmt {v['pix_fmt']}")
    if preview:
        g.check(v.get("profile") == "High" and int(v.get("level", 99)) <= 40, f"{rel}: profile {v.get('profile')} level {v.get('level')}")
        g.check(len(a) == 1 and a[0]["codec_name"] == "aac" and a[0]["channels"] == 2 and a[0]["sample_rate"] in ("44100", "48000"),
                f"{rel}: audio track must be one stereo AAC 44.1/48 kHz")
        g.check(int(p["format"]["size"]) < 500 * 1024 * 1024, f"{rel}: larger than 500 MB")
        seam = None
    else:
        seam, step = frame_diff(path, True)
        g.check(seam <= max(2.0, step * 3), f"{rel}: loop seam {seam:.2f} vs frame step {step:.2f}")
    return dict(file=str(rel), w=v["width"], h=v["height"], fps=v["avg_frame_rate"], dur=round(dur, 2),
                profile=v.get("profile"), level=v.get("level"), audio=bool(a), seam=None if seam is None else round(seam, 2))


# ---------------------------------------------------------------- keywords (OCR)
# Apple OCRs screenshot text for search: every screenshot / header / search
# image must READ (Vision OCR, as rendered) as containing its locale's
# screen-recorder search term — the stems in copy.json "_keywords".
OCR_LANG = {"en-GB": "en-US", "en-US": "en-US", "de-DE": "de-DE", "fr-FR": "fr-FR", "es-ES": "es-ES", "es-MX": "es-ES",
            "it": "it-IT", "pt-BR": "pt-BR", "nl-NL": "nl-NL", "ja": "ja-JP", "ko": "ko-KR", "zh-Hans": "zh-Hans"}
OCR_BIN = BUILD / "ocr"
CJK = __import__("re").compile(r"[\u3040-\u9fff\uac00-\ud7af]")


def norm_text(t):
    import re, unicodedata
    if not CJK.search(t):
        t = unicodedata.normalize("NFKD", t).encode("ascii", "ignore").decode()
    return re.sub(r"[\s\-’'‘`´]", "", t).lower()


def ocr(files, lang, crop):
    """{file: text} read by Vision from the crop (x, y, w, h fractions)."""
    src = Path(__file__).with_name("ocr.swift")
    if not OCR_BIN.exists() or OCR_BIN.stat().st_mtime < src.stat().st_mtime:
        subprocess.run(["swiftc", "-O", str(src), "-o", str(OCR_BIN)], check=True)
    out = {}
    for i in range(0, len(files), 40):
        r = subprocess.run([str(OCR_BIN), "--languages", lang, "--crop", ",".join(f"{v:.4f}" for v in crop), *map(str, files[i:i + 40])],
                           capture_output=True, text=True, check=True)
        for line in r.stdout.splitlines():
            d = json.loads(line)
            out[d["file"]] = d.get("text", "")
    return out


def text_crop(fits_for_group, W, H):
    """A crop round the headline boxes of a group of renders (with margin)."""
    x0 = min(f["text"]["rect"]["x"] for f in fits_for_group); y0 = min(f["text"]["rect"]["y"] for f in fits_for_group)
    x1 = max(f["text"]["rect"]["x"] + f["text"]["rect"]["w"] for f in fits_for_group)
    y1 = max(f["text"]["rect"]["y"] + f["text"]["rect"]["h"] for f in fits_for_group)
    m = 0.02
    x0, y0 = max(0, x0 / W - m), max(0, y0 / H - m)
    return (x0, y0, min(1 - x0, x1 / W + m - x0), min(1 - y0, y1 / H + m - y0))


def check_keywords(g, loc, items, keywords=None):
    """items: [(path, crop)] for one locale. Every image must read as its keyword."""
    kw = (keywords or COPY["_keywords"])[loc]
    by_crop = {}
    for path, crop in items:
        by_crop.setdefault(crop, []).append(path)
    found = {}
    for crop, paths in by_crop.items():
        found.update(ocr(paths, OCR_LANG[loc], crop))
    for path, _ in items:
        text = found.get(str(path), "")
        ok = all(stem in norm_text(text) for stem in kw["ocr"])
        g.check(ok, f"{path.relative_to(ROOT) if path.is_absolute() and ROOT in path.parents else path}: OCR doesn't read the keyword "
                    f"{kw['keyword']!r} (read {text.replace(chr(10), ' / ')!r})")
    return found


# ---------------------------------------------------------------- localized UI (OCR)
# The app runs in each locale's language, so the app area of a non-English
# screenshot (below the headline) must not read as English UI. A word is allowed
# when the app's own translation for that language uses it too (e.g. "Team").
ENGLISH_UI = ["Export", "Library", "Capture", "Background", "Captions", "Subtitles", "Share", "Delete", "Settings",
              "Account", "Cancel", "Comments", "Search", "Recording", "Copy link", "Start streaming", "New Recording",
              "Videos", "Images", "Shares", "Back", "Options", "Duplicate", "Split", "Gradient", "Start Color"]
APP_LANG = {"en-GB": "en", "en-US": "en", "de-DE": "de", "fr-FR": "fr", "es-ES": "es", "es-MX": "es-MX", "it": "it",
            "pt-BR": "pt-BR", "nl-NL": "nl", "ja": "ja", "ko": "ko", "zh-Hans": "zh-Hans"}
CATALOG = ROOT.parent / "Localization" / "Localizable.xcstrings"


def allowed_words(lang):
    """English UI words this language's own translations also use."""
    import re
    if not CATALOG.exists(): return set()
    values = []
    for entry in json.loads(CATALOG.read_text())["strings"].values():
        unit = entry.get("localizations", {}).get(lang, {}).get("stringUnit", {})
        if unit.get("value"): values.append(unit["value"])
    # Accents stripped: OCR often drops them ("Vídeos" reads as "Videos").
    import unicodedata
    blob = unicodedata.normalize("NFKD", "\n".join(values)).encode("ascii", "ignore").decode()
    return {w for w in ENGLISH_UI if re.search(rf"(?<![A-Za-zÀ-ÿ]){re.escape(w)}(?![A-Za-zÀ-ÿ])", blob)}


_ALLOWED = {}


def check_app_language(g, loc, items, as_locale=None):
    """items: [(path, crop)]: crops of the app area. Fails on English UI words."""
    import re
    loc_ = as_locale or loc
    lang = APP_LANG[loc_]
    if lang == "en": return {}
    allowed = _ALLOWED.setdefault(lang, allowed_words(lang))
    by_crop = {}
    for path, crop in items: by_crop.setdefault(crop, []).append(path)
    found = {}
    for crop, paths in by_crop.items():
        found.update(ocr(paths, f"{OCR_LANG[loc_]},en-US", crop))
    for path, _ in items:
        text = found.get(str(path), "")
        hits = [w for w in ENGLISH_UI if w not in allowed and re.search(rf"(?<![A-Za-zÀ-ÿ]){re.escape(w)}(?![A-Za-zÀ-ÿ])", text)]
        g.check(not hits, f"{path.relative_to(ROOT)}: English UI in a {loc_} screenshot: {', '.join(hits)}")
    return found


def app_crop(rec, W, H):
    """The device screen below the headline, as fractions."""
    d = rec["devices"][0]
    top = max(d["y"], rec["text"]["rect"]["y"] + rec["text"]["rect"]["h"]) + 8
    x0, x1 = max(0, d["x"]), min(W, d["x"] + d["w"])
    return (x0 / W, top / H, (x1 - x0) / W, (min(H, d["y"] + d["h"]) - top) / H)


PREVIEW_DEVICES = {"iphone-6.9.mp4": "iphone", "ipad-13.mp4": "ipad"}


def gray_frame(path, args):
    r = subprocess.run(["ffmpeg", "-v", "error", *args, "-i", str(path), "-frames:v", "1", "-vf", "scale=240:-2",
                        "-f", "rawvideo", "-pix_fmt", "gray", "-"], capture_output=True, check=True)
    probe_w = 240
    a = np.frombuffer(r.stdout, np.uint8)
    return a.reshape(-1, probe_w).astype(np.float32)


def frame_facts(img):
    """Border ring (outer 4 %) luminance and spread; share of pixels on the
    dominant tone; share of strong edges."""
    h, w = img.shape
    b = max(2, int(min(h, w) * 0.04))
    ring = np.concatenate([img[:b].ravel(), img[-b:].ravel(), img[:, :b].ravel(), img[:, -b:].ravel()])
    med = np.median(img)
    uniform = float(np.mean(np.abs(img - med) < 6))
    gy, gx = np.abs(np.diff(img, axis=0))[:, :-1], np.abs(np.diff(img, axis=1))[:-1]
    edges = float(np.mean(np.maximum(gx, gy) > 24))
    return dict(ring_mean=float(ring.mean()), ring_std=float(ring.std()), uniform=uniform, edges=edges)


def loudness(path):
    r = subprocess.run(["ffmpeg", "-v", "info", "-i", str(path), "-vn", "-af", "volumedetect", "-f", "null", "-"],
                       capture_output=True, text=True)
    mean = max_ = -999.0
    for line in r.stderr.splitlines():
        if "mean_volume:" in line: mean = float(line.split("mean_volume:")[1].split()[0])
        if "max_volume:" in line: max_ = float(line.split("max_volume:")[1].split()[0])
    return mean, max_


def check_preview_content(g, path, dur):
    """App footage fills the frame to the last frame; the sound is really there."""
    rel = path.relative_to(ROOT)
    mean, peak = loudness(path)
    g.check(mean > -45 and peak > -25, f"{rel}: audio is silent (mean {mean} dB, max {peak} dB)")
    facts = {}
    for name, args in (("start", ["-ss", "0.5"]), ("middle", ["-ss", f"{dur / 2:.2f}"]), ("last", ["-sseof", "-0.1"])):
        f = frame_facts(gray_frame(path, args))
        facts[name] = f
        g.check(not (f["ring_mean"] < 50 and f["ring_std"] < 14), f"{rel}: {name} frame has a dark border ring (device frame?)")
    last = facts["last"]
    g.check(last["edges"] >= 0.02 and last["uniform"] < 0.8,
            f"{rel}: last frame isn't app UI (edges {last['edges']:.3f}, uniform {last['uniform']:.2f}): an end card?")
    return facts


def check_preview_text(g, device, locale):
    fit_path = BUILD / "preview" / device / locale / "textfit.json"
    if not g.check(fit_path.exists(), f"preview {device}/{locale}: no textfit.json"): return
    fits = json.loads(fit_path.read_text())
    entry = fits.get(locale)
    if not g.check(bool(entry) and entry.get("captions"), f"preview {device}/{locale}: no headline fit record"): return
    for c in entry["captions"]:
        name = f"preview {device}/{locale} {' / '.join(c['lines'])!r}"
        g.check(c["fits"] and c["widest"] <= c["box"] + 0.5, f"{name}: headline wider than its box")
        g.check(c["ratio"] >= MIN_RATIO, f"{name}: headline shrunk to {c['ratio']:.2f}")
        g.check(c["bottom"] <= entry["scrimHeight"], f"{name}: headline runs past its scrim")
        g.check(len(" ".join(c["lines"]).split()) <= 6 or any(ord(ch) > 0x2e80 for ch in "".join(c["lines"])),
                f"{name}: more than 6 words")


def load_fits():
    fits = {}
    for f in sorted(BUILD.glob("textfit-*.json")):
        fits.update(json.loads(f.read_text()))
    return fits


KEYWORD_ROWS = []
UI_ROWS = []


def run_all():
    g = Gate()
    fits = load_fits()
    families = [f for f in STILLS if (OUT / LOCALES[0] / f).exists() or f != "duo-inner"]
    if not (OUT / LOCALES[0] / "duo-inner").exists():
        g.notes.append("duo-inner: NOT RENDERED - the inner (open) display could not be captured (see README)")
    videos = []
    for loc in LOCALES:
        for fam in families:
            W, H = STILLS[fam]
            for i, s in enumerate(SCREENS, 1):
                check_image(g, OUT / loc / fam / f"{i:02d}-{s}.png", W, H)
                key = f"{loc}/{fam}/{s}"
                if g.check(key in fits, f"{key}: no text-fit record"):
                    check_text(g, key, fits[key])
        for kind, (W, H, safe) in WIDE.items():
            check_image(g, OUT / loc / kind / f"{kind}.png", W, H)
            key = f"{loc}/{kind}"
            if g.check(key in fits, f"{key}: no text-fit record"):
                check_text(g, key, fits[key], safe)
        # Keywords: one OCR pass per placement, cropped round its headlines.
        items = []
        for fam in families:
            W, H = STILLS[fam]
            group = [fits[f"{loc}/{fam}/{s}"] for s in SCREENS if f"{loc}/{fam}/{s}" in fits]
            if group:
                crop = text_crop(group, W, H)
                items += [(OUT / loc / fam / f"{i:02d}-{s}.png", crop) for i, s in enumerate(SCREENS, 1)]
        for kind, (W, H, safe) in WIDE.items():
            if f"{loc}/{kind}" in fits:
                items.append((OUT / loc / kind / f"{kind}.png", text_crop([fits[f"{loc}/{kind}"]], W, H)))
        KEYWORD_ROWS.extend((loc, str(p.relative_to(ROOT))) for p, _ in items)
        check_keywords(g, loc, items)
        # The app's own UI is in the locale's language (not English).
        ui = []
        for fam in families:
            W, H = STILLS[fam]
            for i, s_ in enumerate(SCREENS, 1):
                rec = fits.get(f"{loc}/{fam}/{s_}")
                if rec: ui.append((OUT / loc / fam / f"{i:02d}-{s_}.png", app_crop(rec, W, H)))
        UI_ROWS.extend(ui)
        check_app_language(g, loc, ui)
        for rel, (W, H, dmin, dmax, preview) in VIDEOS.items():
            info = check_video(g, OUT / loc / rel, W, H, dmin, dmax, preview)
            if info: videos.append(info)
            if info and preview:
                path = OUT / loc / rel
                g.check(os.stat(path).st_nlink == 1, f"{path.relative_to(ROOT)}: a hard link (each locale needs its own preview)")
                check_preview_content(g, path, info["dur"])
                check_preview_text(g, PREVIEW_DEVICES[path.name], loc)
    return g, fits, videos


def report(g, fits, videos):
    lines = ["CaptureCat App Store assets — automated check", ""]
    shrunk = sorted(((v["text"]["ratio"], k) for k, v in fits.items() if v.get("text")), key=lambda x: x[0])[:8]
    lines.append("Smallest headline scale (rendered size / design size):")
    lines += [f"  {r:.2f}  {k}" for r, k in shrunk]
    lines.append("")
    lines.append(f"Keyword OCR: {len(KEYWORD_ROWS)} screenshot / header / search images read by Vision; each must contain its locale's term.")
    lines.append(f"App UI language OCR: {len(UI_ROWS)} screenshots' app areas read; non-English locales must show no English UI words.")
    lines.append("")
    lines.append("Videos (one row per distinct file spec; every locale checked):")
    seen = set()
    for v in videos:
        sig = (Path(v["file"]).name, v["w"], v["h"])
        if sig in seen: continue
        seen.add(sig)
        lines.append(f"  {Path(v['file']).name:18} {v['w']}x{v['h']}  {v['fps']} fps  {v['dur']}s  h264 {v['profile']} L{v['level']}  audio={v['audio']}  loop-seam={v['seam']}")
    lines.append("")
    for n in g.notes: lines.append("NOTE " + n)
    lines.append(f"checks passed: {g.passes}   failed: {len(g.fails)}")
    lines += ["FAIL " + f for f in g.fails[:60]]
    lines.append("ASSET-CHECK " + ("PASS" if not g.fails else "FAIL"))
    text = "\n".join(lines)
    (BUILD / "check-report.txt").write_text(text + "\n")
    write_keyword_table()
    print(text)
    return not g.fails


def write_keyword_table():
    """source/build/keywords.txt: locale -> search term -> the 8 headlines."""
    keys = ["editor", "background", "captions", "library", "stream", "share", "header", "search"]
    out = ["Locale → keyword → the 8 headlines (screens 1-6, header, search; line 1 / line 2).",
           "On iPad, screen 5 uses the stream_ipad line (iPad for iPhone). The app previews use",
           "the same lines for the same scenes (library, editor, background, captions, share).", ""]
    for loc in LOCALES:
        kw = COPY["_keywords"][loc]
        out.append(f"{loc}  —  keyword: {kw['keyword']}   (OCR must read: {' + '.join(kw['ocr'])})")
        for i, k in enumerate(keys, 1):
            label = f"{i}. {k}" if i <= 6 else k
            out.append(f"    {label:14} {' / '.join(COPY[loc][k])}")
        out.append("")
    (BUILD / "keywords.txt").write_text("\n".join(out))


def selftest():
    """Each check must turn red on its injected defect."""
    tmp = BUILD / "selftest"; tmp.mkdir(parents=True, exist_ok=True)
    ok = True
    def expect_fail(name, fn):
        nonlocal ok
        g = Gate(); fn(g)
        caught = bool(g.fails)
        ok &= caught
        print(f"SELFTEST {'PASS' if caught else 'FAIL'} {name}: {g.fails[:1] if caught else 'not detected'}")
    Image.new("RGBA", (1320, 2868), (255, 255, 255, 255)).save(tmp / "alpha.png")
    Image.new("RGB", (1320, 2867)).save(tmp / "short.png")
    expect_fail("alpha-channel", lambda g: check_image(g, tmp / "alpha.png", 1320, 2868))
    expect_fail("wrong-size", lambda g: check_image(g, tmp / "short.png", 1320, 2868))
    fits = load_fits()
    base = json.loads(json.dumps(fits["en-GB/iphone-6.9/editor"]))
    t = base["text"]
    clip = json.loads(json.dumps(base)); clip["text"]["fits"] = False; clip["text"]["lines"][0]["w"] = t["box"]["w"] + 80
    expect_fail("text-clipped", lambda g: check_text(g, "inject", clip))
    wrap = json.loads(json.dumps(base)); wrap["text"]["lines"][1]["h"] = t["size"] * 2.2
    expect_fail("line-wrapped", lambda g: check_text(g, "inject", wrap))
    over = json.loads(json.dumps(base)); over["devices"][0]["y"] = t["rect"]["y"] + t["rect"]["h"] - 20
    expect_fail("text-over-device", lambda g: check_text(g, "inject", over))
    hdr = json.loads(json.dumps(fits["en-GB/header"])); hdr["text"]["lines"][0]["x"] = 900
    expect_fail("outside-safe-area", lambda g: check_text(g, "inject", hdr, WIDE["header"][2]))
    # Video: a 29.97 fps, 10 s, wrong-size clip with no audio must fail as an app preview.
    bad = tmp / "bad.mp4"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=880x1920:rate=30000/1001", "-t", "10",
                    "-c:v", "libx264", "-pix_fmt", "yuv420p", str(bad)], check=True)
    expect_fail("preview-spec", lambda g: check_video(g, bad, 886, 1920, 15, 30, True))
    # A loop that jumps: testsrc's counter changes between end and start.
    jump = tmp / "jump.mp4"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "mandelbrot=size=640x274:rate=30", "-t", "6",
                    "-c:v", "libx264", "-pix_fmt", "yuv420p", str(jump)], check=True)
    expect_fail("loop-seam", lambda g: check_video(g, jump, 640, 274, 5, 30, False))
    # Keywords: a real en-GB screenshot reads as "screen…"; with its headline painted
    # out, or checked against another locale's term, it must fail.
    shot = OUT / "en-GB" / "iphone-6.9" / "01-editor.png"
    rec = fits.get("en-GB/iphone-6.9/editor")
    if shot.exists() and rec:
        crop = text_crop([rec], 1320, 2868)
        g0 = Gate(); check_keywords(g0, "en-GB", [(shot, crop)])
        print(f"SELFTEST {'PASS' if not g0.fails else 'FAIL'} keyword-present: {g0.fails[:1] or 'reads ' + repr(COPY['en-GB']['editor'])}")
        ok &= not g0.fails
        blank = tmp / "no-headline.png"
        im = Image.open(shot).convert("RGB")
        r = rec["text"]["rect"]
        from PIL import ImageDraw
        ImageDraw.Draw(im).rectangle([r["x"] - 10, r["y"] - 10, r["x"] + r["w"] + 10, r["y"] + r["h"] + 10], fill=(246, 243, 251))
        im.save(blank)
        expect_fail("keyword-missing", lambda g: check_keywords(g, "en-GB", [(blank, crop)]))
        expect_fail("keyword-wrong-locale", lambda g: check_keywords(g, "de-DE", [(shot, crop)]))
    # Localized UI: the English (en-GB) library screenshot checked as a German one
    # must fail; the real German one must pass.
    for loc_, should_fail in (("de-DE", False),):
        rec_de = fits.get(f"{loc_}/iphone-6.9/library")
        de_shot = OUT / loc_ / "iphone-6.9" / "04-library.png"
        if rec_de and de_shot.exists():
            g1 = Gate(); check_app_language(g1, loc_, [(de_shot, app_crop(rec_de, 1320, 2868))])
            print(f"SELFTEST {'PASS' if not g1.fails else 'FAIL'} german-ui-clean: {g1.fails[:1] or 'no English UI read'}")
            ok &= not g1.fails
    rec_en = fits.get("en-GB/iphone-6.9/library")
    en_shot = OUT / "en-GB" / "iphone-6.9" / "04-library.png"
    if rec_en and en_shot.exists():
        expect_fail("english-ui-in-german-shot", lambda g: check_app_language(g, "en-GB", [(en_shot, app_crop(rec_en, 1320, 2868))], as_locale="de-DE"))
    # App previews: the real en-GB iPhone preview with each 2.3.4 defect injected.
    real = OUT / "en-GB" / "app-preview" / "iphone-6.9.mp4"
    if real.exists():
        dur = float(probe(real)["format"]["duration"])
        g0 = Gate(); check_preview_content(g0, real, dur)
        print(f"SELFTEST {'PASS' if not g0.fails else 'FAIL'} real-preview-clean: {g0.fails[:1] or 'no false alarm'}")
        ok &= not g0.fails
        silent = tmp / "silent.mp4"
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(real), "-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=48000",
                        "-map", "0:v", "-map", "1:a", "-c:v", "copy", "-c:a", "aac", "-shortest", str(silent)], check=True)
        expect_fail("silent-audio", lambda g: check_preview_content(g, silent, dur))
        framed = tmp / "framed.mp4"   # the footage shrunk inside a dark phone-like bezel
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(real), "-vf", "scale=736:1596,pad=886:1920:75:162:color=0x111114",
                        "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "copy", str(framed)], check=True)
        expect_fail("device-frame", lambda g: check_preview_content(g, framed, dur))
        card = tmp / "endcard.mp4"    # the preview, then 1.5 s of a logo on a plain card
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(real), "-f", "lavfi", "-i", "color=c=0xfbfbfd:s=886x1920:r=30:d=1.5",
                        "-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=48000:d=1.5",
                        "-filter_complex", "[1:v]drawbox=x=343:y=860:w=200:h=200:color=0x7c5cf0:t=fill,format=yuv420p,setsar=1[c];[0:v]setsar=1[m];[m][0:a][c][2:a]concat=n=2:v=1:a=1[v][a]",
                        "-map", "[v]", "-map", "[a]", "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", str(card)], check=True)
        expect_fail("logo-end-card", lambda g: check_preview_content(g, card, dur + 1.5))
        fit_path = BUILD / "preview" / "iphone" / "en-GB" / "textfit.json"
        if fit_path.exists():
            saved = fit_path.read_text()
            try:
                broken = json.loads(saved)
                broken["en-GB"]["captions"][0].update(fits=False, widest=broken["en-GB"]["captions"][0]["box"] + 60)
                fit_path.write_text(json.dumps(broken))
                expect_fail("preview-headline-overflow", lambda g: check_preview_text(g, "iphone", "en-GB"))
            finally:
                fit_path.write_text(saved)
    print("SELFTEST " + ("PASS (every injected defect caught)" if ok else "FAIL"))
    return ok


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(0 if selftest() else 1)
    g, fits, videos = run_all()
    sys.exit(0 if report(g, fits, videos) else 1)
