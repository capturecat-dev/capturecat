#!/usr/bin/env python3
"""Maintain apps/ios/Localization/Localizable.xcstrings (the app's String Catalog).

Xcode's IDE syncs a catalog with the code on build; xcodebuild does not, so
this does it from the compiler's own output: every `String(localized:)` in a
target compiled with SWIFT_EMIT_LOC_STRINGS leaves a `.stringsdata` file with
the exact key (interpolations already turned into %@ / %lld) and comment.

    l10n-catalog.py harvest <derived-data-dir>   add new keys, mark vanished ones stale
    l10n-catalog.py export <lang> <out.json> [--all]   keys still to translate (key, comment, English, sources)
    l10n-catalog.py import <lang> <in.json>      {key: translation} → the catalog (state translated)
    l10n-catalog.py check                        placeholders, coverage; exit 1 on a problem
    l10n-catalog.py stats                        per-language coverage

Keys are the English text (the development language, `en`); en-GB and en-US
use it as is (it is the Mac app's English too). Stale keys (gone from the
code) are dropped by `harvest --prune`.
"""
import glob
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(ROOT, "Localization", "Localizable.xcstrings")
LANGS = ["de", "fr", "es", "es-MX", "it", "pt-BR", "nl", "ja", "ko", "zh-Hans"]
VARIANTS = ["en-GB", "en-US"]
TARGETS = ("CaptureCat", "CaptureCatShare", "CaptureCatBroadcast")
# Where each key lives (translators' context) — never inside Localization/,
# whose every file is copied into the bundles.
SOURCES = os.path.join(os.environ.get("TMPDIR", "/tmp"), "capturecat-l10n-sources.json")


def load():
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
    # Keep the newest output per (target, file): a build for another arch or
    # an older configuration leaves stale copies behind.
    newest = {}
    for path in files:
        target = next((t for t in TARGETS if f"/{t}.build/" in path), "")
        key = (target, os.path.basename(path))
        if key not in newest or os.path.getmtime(path) > os.path.getmtime(newest[key]):
            newest[key] = path
    files = list(newest.values())
    found = {}
    for path in files:
        with open(path) as f:
            data = json.load(f)
        src = os.path.relpath(data.get("source", ""), os.path.dirname(ROOT))
        for entry in data.get("tables", {}).get("Localizable", []):
            key = entry["key"]
            rec = found.setdefault(key, {"comments": set(), "sources": set(), "default": entry.get("value") or entry.get("defaultValue")})
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


# en-GB / en-US read the app's English exactly as written — the same words
# the Mac app shows, which the iOS↔Mac parity gates compare byte for byte. No
# spelling overrides ("Colour") for that reason.


# English labels that may share one translation on the same surface: true
# synonyms, or the same thing named two ways.
SYNONYMS = [{"captions", "subtitles"}, {"retry", "try again"}, {"delete", "remove"}, {"delete", "discard"},
            {"card color", "card colors"}, {"curtain", "curtain unveil"}, {"closed", "collapsed"},
            {"%@, %@", "%@, at %@"}, {"comment by %@ at %@", "comment from %@, %@"}]


def collisions(live):
    """Two different English labels on one surface (the comment's prefix:
    "Tool bar key", "Inspector ▸ Camera", "Action sheet" …) must not read the
    same in a language — "Split" and "Share" both "Teilen" is how a reader
    loses a control."""
    groups = {}
    for key, item in live.items():
        for seg in item.get("comment", "").split(" / "):
            if ":" in seg:
                groups.setdefault(seg.split(":")[0].strip(), set()).add(key)
    out = []
    norm = lambda t: t.rstrip(" …").lower()
    for surface, keys in groups.items():
        if len(keys) < 2:
            continue
        for lang in LANGS:
            seen = {}
            for key in keys:
                text = value(live[key], lang)
                if text is None:
                    continue
                seen.setdefault(norm(text), set()).add(norm(english(key, live[key])))
            for text, ens in seen.items():
                if len(ens) > 1 and not any(ens <= syn for syn in SYNONYMS):
                    out.append(f"collision {lang} on “{surface}”: {sorted(ens)} all read “{text}”")
    return out


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
    problems += collisions(live)
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
    elif cmd == "collision-selftest":
        # Inject "Split" reading like another key of its surface; must be caught.
        cat = load()
        live = {k: v for k, v in cat["strings"].items() if v.get("extractionState") != "stale"}
        surface = next(seg.split(":")[0].strip() for seg in live["Split"].get("comment", "").split(" / ") if ":" in seg)
        other = next(k for k, v in live.items() if k != "Split" and any(seg.split(":")[0].strip() == surface for seg in v.get("comment", "").split(" / ") if ":" in seg))
        live["Split"]["localizations"]["de"]["stringUnit"]["value"] = value(live[other], "de")
        found = [c for c in collisions(live) if " de " in c]
        print(f"L10N-COLLISION selftest: de “Split” forced to read like “{other}” on “{surface}” → " + ("CAUGHT" if found else "MISSED"))
        sys.exit(0 if found else 1)
    elif cmd == "check":
        sys.exit(0 if check() else 1)
    elif cmd == "stats":
        stats()
    else:
        sys.exit(__doc__)
