#!/usr/bin/env python3
"""Maintain apps/macos/CaptureCat/Resources/Localizable.xcstrings (the Mac app's String Catalog).

Xcode's IDE syncs a catalog with the code on build; xcodebuild does not, so
this does it from the compiler's own output: every `String(localized:)` in a
target compiled with SWIFT_EMIT_LOC_STRINGS leaves a `.stringsdata` file with
the exact key (interpolations already turned into %@ / %lld) and comment.

    l10n-catalog.py harvest <derived-data-dir>   add new keys, mark vanished ones stale
    l10n-catalog.py export <lang> <out.json> [--all]   keys still to translate (key, comment, English, sources)
    l10n-catalog.py import <lang> <in.json>      {key: translation} → the catalog (state translated)
    l10n-catalog.py check                        placeholders, coverage; exit 1 on a problem
    l10n-catalog.py variants                     write the en-GB / en-US spelling overrides
    l10n-catalog.py stats                        per-language coverage
    l10n-catalog.py reuse <other.xcstrings>      copy translations of identical keys (the iOS
                                                 app's catalog) so shared terms read the same

Keys are the English text (the development language, `en`); en-GB and en-US
carry only the strings whose spelling differs. Stale keys (gone from the
code) are dropped by `harvest --prune`.
"""
import glob
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(ROOT, "CaptureCat", "Resources", "Localizable.xcstrings")
LANGS = ["de", "fr", "es", "es-MX", "it", "pt-BR", "nl", "ja", "ko", "zh-Hans"]
VARIANTS = ["en-GB", "en-US"]
TARGETS = ("CaptureCat",)
# Where each key lives (translators' context) — outside the source tree,
# whose every file is copied into the bundle.
SOURCES = os.path.join(os.environ.get("TMPDIR", "/tmp"), "capturecat-mac-l10n-sources.json")


def load():
    if not os.path.exists(CATALOG):
        return {"sourceLanguage": "en", "strings": {}, "version": "1.0"}
    with open(CATALOG) as f:
        return json.load(f)


def save(cat):
    cat["strings"] = dict(sorted(cat["strings"].items(), key=lambda kv: kv[0]))
    text = json.dumps(cat, ensure_ascii=False, indent=2, separators=(",", " : "))
    with open(CATALOG, "w") as f:
        f.write(text + "\n")


def harvest(dd, prune=False):
    files = []
    for target in TARGETS:
        files += glob.glob(os.path.join(dd, "Build", "Intermediates.noindex", "**", f"{target}.build", "**", "*.stringsdata"), recursive=True)
    if not files:
        sys.exit(f"no .stringsdata under {dd} (build the app with SWIFT_EMIT_LOC_STRINGS=YES first)")
    found = {}
    for path in files:
        with open(path) as f:
            data = json.load(f)
        src = os.path.relpath(data.get("source", ""), os.path.dirname(ROOT))
        for entry in data.get("tables", {}).get("Localizable", []):
            key = entry["key"]
            rec = found.setdefault(key, {"comments": set(), "sources": set(), "default": entry.get("defaultValue")})
            if entry.get("comment"):
                rec["comments"].add(entry["comment"])
            rec["sources"].add(src)
    cat = load()
    strings = cat["strings"]
    added = 0
    for key, rec in found.items():
        item = strings.setdefault(key, {})
        if not item:
            added += 1
        comment = " / ".join(sorted(rec["comments"]))
        if comment:
            item["comment"] = comment
        if rec["default"] and rec["default"] != key:
            item.setdefault("localizations", {}).setdefault("en", {"stringUnit": {"state": "translated", "value": rec["default"]}})
        item.pop("extractionState", None)
    stale = [k for k, v in strings.items() if k not in found and v.get("extractionState") != "manual"]
    for k in stale:
        if prune:
            del strings[k]
        else:
            strings[k]["extractionState"] = "stale"
    save(cat)
    # A side file with where each key lives (translators' context).
    side = {k: sorted(v["sources"]) for k, v in found.items()}
    with open(SOURCES, "w") as f:
        json.dump(side, f, ensure_ascii=False, indent=1, sort_keys=True)
    print(f"harvest: {len(found)} keys in code ({added} new), {len(stale)} stale{' (pruned)' if prune else ''}, from {len(files)} files")


def english(key, item):
    return item.get("localizations", {}).get("en", {}).get("stringUnit", {}).get("value", key)


def value(item, lang):
    unit = item.get("localizations", {}).get(lang, {})
    if "stringUnit" in unit:
        return unit["stringUnit"].get("value")
    return None


def export(lang, out, everything=False):
    cat = load()
    try:
        with open(SOURCES) as f:
            sources = json.load(f)
    except FileNotFoundError:
        sources = {}
    rows = []
    for key, item in cat["strings"].items():
        if item.get("extractionState") == "stale" or item.get("shouldTranslate") is False:
            continue
        current = value(item, lang)
        if current and not everything:
            continue
        rows.append({"key": key, "english": english(key, item), "comment": item.get("comment", ""),
                     "where": sources.get(key, [])[:3], **({"current": current} if current else {})})
    with open(out, "w") as f:
        json.dump(rows, f, ensure_ascii=False, indent=1)
    print(f"export {lang}: {len(rows)} strings → {out}")


def import_(lang, path):
    with open(path) as f:
        data = json.load(f)
    if isinstance(data, list):
        data = {r["key"]: r["translation"] for r in data}
    cat = load()
    n = missing = 0
    for key, text in data.items():
        if key not in cat["strings"]:
            missing += 1
            continue
        cat["strings"][key].setdefault("localizations", {})[lang] = {"stringUnit": {"state": "translated", "value": text}}
        n += 1
    save(cat)
    print(f"import {lang}: {n} strings ({missing} unknown keys skipped)")


SPEC = re.compile(r"%(?:(\d+)\$)?[-+ #0']*\d*(?:\.\d+)?(lld|ld|lu|llu|d|i|u|@|f|lf|g|e|s|c|x|X|%)")


def specs(text):
    """Placeholder types in argument order (positional ones placed by index)."""
    out = {}
    nxt = 1
    for m in SPEC.finditer(text):
        if m.group(2) == "%":
            continue
        idx = int(m.group(1)) if m.group(1) else nxt
        nxt = idx + 1 if not m.group(1) else nxt
        kind = {"lld": "int", "ld": "int", "d": "int", "i": "int", "lu": "int", "llu": "int", "u": "int",
                "@": "obj", "f": "dbl", "lf": "dbl", "g": "dbl", "e": "dbl"}.get(m.group(2), m.group(2))
        out[idx] = kind
    return out


# en-GB / en-US: the code's English is mostly US spelling with a few British
# words; each variant overrides only the strings whose spelling differs.
GB = [("colors", "colours"), ("color", "colour"), ("Colors", "Colours"), ("Color", "Colour"),
      ("centered", "centred"), ("centers", "centres"), ("center", "centre"), ("Centered", "Centred"), ("Center", "Centre"),
      ("behaviors", "behaviours"), ("behavior", "behaviour"), ("Behavior", "Behaviour"),
      ("favorites", "favourites"), ("favorite", "favourite"), ("Favorite", "Favourite"),
      ("gray", "grey"), ("Gray", "Grey"), ("canceled", "cancelled"), ("Canceled", "Cancelled"),
      ("canceling", "cancelling"), ("license", "licence"), ("dialog", "dialogue"),
      ("analyze", "analyse"), ("Analyze", "Analyse"), ("analyzing", "analysing"), ("Analyzing", "Analysing"),
      ("customize", "customise"), ("Customize", "Customise"), ("organize", "organise"), ("Organize", "Organise"),
      ("recognize", "recognise"), ("optimize", "optimise"), ("Optimize", "Optimise"), ("optimized", "optimised"),
      ("synchronize", "synchronise"), ("normalize", "normalise"), ("Normalize", "Normalise"), ("normalized", "normalised"),
      ("summarize", "summarise"), ("Summarize", "Summarise"), ("minimize", "minimise"), ("maximize", "maximise"),
      ("authorize", "authorise"), ("Authorize", "Authorise"), ("authorized", "authorised"), ("unauthorized", "unauthorised"),
      ("personalize", "personalise"), ("prioritize", "prioritise"), ("finalize", "finalise"), ("Finalizing", "Finalising"),
      ("finalizing", "finalising"), ("visualize", "visualise"), ("apologize", "apologise")]
US = [("cancelled", "canceled"), ("Cancelled", "Canceled"), ("cancelling", "canceling"), ("centre", "center"),
      ("Centre", "Center"), ("colour", "color"), ("Colour", "Color"), ("favourite", "favorite"), ("grey", "gray"),
      ("Grey", "Gray"), ("behaviour", "behavior"), ("licence", "license"), ("dialogue", "dialog"),
      ("analyse", "analyze"), ("analysing", "analyzing"), ("customise", "customize"), ("organise", "organize"),
      ("recognise", "recognize"), ("optimise", "optimize"), ("normalise", "normalize"), ("summarise", "summarize"),
      ("authorise", "authorize"), ("finalise", "finalize"), ("travelled", "traveled")]


def respell(text, pairs):
    out = text
    for a, b in pairs:
        out = re.sub(r"(?<![A-Za-z%])" + re.escape(a) + r"(?![a-z])", b, out)
    return out


def variants():
    cat = load()
    n = {"en-GB": 0, "en-US": 0}
    for key, item in cat["strings"].items():
        src = english(key, item)
        locs = item.setdefault("localizations", {})
        for lang, pairs in (("en-GB", GB), ("en-US", US)):
            text = respell(src, pairs)
            if text != src:
                locs[lang] = {"stringUnit": {"state": "translated", "value": text}}
                n[lang] += 1
            else:
                locs.pop(lang, None)
        if not locs:
            item.pop("localizations")
    save(cat)
    print(f"variants: en-GB {n['en-GB']} overrides, en-US {n['en-US']}")


def check(quiet=False):
    cat = load()
    problems = []
    live = {k: v for k, v in cat["strings"].items() if v.get("extractionState") != "stale" and v.get("shouldTranslate") is not False}
    for key, item in live.items():
        want = specs(english(key, item))
        for lang in LANGS + VARIANTS:
            text = value(item, lang)
            if text is None:
                if lang in LANGS:
                    problems.append(f"missing {lang}: {key!r}")
                continue
            got = specs(text)
            if got != want:
                problems.append(f"placeholders {lang}: {key!r} → {text!r} ({want} vs {got})")
    if not quiet:
        for p in problems[:200]:
            print("  ! " + p)
    stats(cat, live)
    print("L10N-CATALOG " + ("PASS" if not problems else f"FAIL ({len(problems)} problem(s))"))
    return not problems


def stats(cat=None, live=None):
    cat = cat or load()
    live = live or {k: v for k, v in cat["strings"].items() if v.get("extractionState") != "stale" and v.get("shouldTranslate") is not False}
    total = len(live)
    parts = []
    for lang in LANGS:
        n = sum(1 for v in live.values() if value(v, lang))
        parts.append(f"{lang} {n}/{total}")
    print(f"catalog: {total} strings; " + ", ".join(parts))


def reuse(path, overwrite=False):
    """Shared product terms read the same on Mac and iPhone: every key the
    other catalog has translated is copied (never over a translation already
    here unless --overwrite)."""
    with open(path) as f:
        other = json.load(f)["strings"]
    cat = load()
    n = 0
    for key, item in cat["strings"].items():
        theirs = other.get(key, {}).get("localizations", {})
        for lang in LANGS:
            unit = theirs.get(lang, {}).get("stringUnit")
            if not unit or unit.get("state") != "translated":
                continue
            if value(item, lang) and not overwrite:
                continue
            item.setdefault("localizations", {})[lang] = {"stringUnit": {"state": "translated", "value": unit["value"]}}
            n += 1
    save(cat)
    print(f"reuse: {n} translations copied from {path}")


if __name__ == "__main__":
    args = sys.argv[1:]
    if not args:
        sys.exit(__doc__)
    cmd = args[0]
    if cmd == "harvest":
        harvest(args[1], prune="--prune" in args)
    elif cmd == "export":
        export(args[1], args[2], everything="--all" in args)
    elif cmd == "import":
        import_(args[1], args[2])
    elif cmd == "check":
        sys.exit(0 if check() else 1)
    elif cmd == "variants":
        variants()
    elif cmd == "stats":
        stats()
    elif cmd == "reuse":
        reuse(args[1], overwrite="--overwrite" in args)
    else:
        sys.exit(__doc__)
