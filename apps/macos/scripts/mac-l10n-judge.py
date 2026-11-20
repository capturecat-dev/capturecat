#!/usr/bin/env python3
"""Judge the Mac localization gate's captures (apps/macos/scripts/mac-l10n.sh).

    mac-l10n-judge.py <run-dir> [--expect untranslated|truncate]

<run-dir>/<locale>/<gate>/<screen>.json are CCLocalizationAudit reports
(Views/Shared/DesignKit/CCLocalizationAudit.swift). For every gate and locale:

  untranslated  a text that comes out IDENTICAL in the English run of the same
                screen — unless the catalog's translation for that language is
                itself identical (OK, Zoom, Pro, GIF…), it has no words, or it
                is fixture content listed in mac-l10n-allow.txt (project
                names, the fixture annotation…);
  text problems what the audit measured: truncated or clipped text — in ANY
                language, English included;
  coverage      the same screens as the English run.

--expect <defect>: the run had a defect injected; PASS only if it was caught
(the gate's proof that it can see).
"""
import json
import os
import re
import sys

MAC = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.environ.get("L10N_CATALOG") or os.path.join(MAC, "CaptureCat", "Resources", "Localizable.xcstrings")
ALLOW = os.path.join(MAC, "scripts", "mac-l10n-allow.txt")
# English labels that may legitimately share one translation on a screen
# ("Remove = Delete" is NOT one: those must stay distinct). One pair per
# line: `English A = English B` (optionally `@lang` after B).
SYNONYMS = os.path.join(MAC, "scripts", "mac-l10n-synonyms.txt")


def load_synonyms():
    pairs = set()
    if os.path.exists(SYNONYMS):
        for line in open(SYNONYMS, encoding="utf-8"):
            line = line.strip()
            if not line or line.startswith("#") or " = " not in line:
                continue
            a, b = line.split(" = ", 1)
            lang = None
            if " @" in b:
                b, lang = b.rsplit(" @", 1)
            pairs.add((frozenset((a.strip(), b.strip())), lang))
    return pairs


def translations(catalog, lang):
    out = {}
    for key, item in catalog["strings"].items():
        v = item.get("localizations", {}).get(lang, {}).get("stringUnit", {}).get("value")
        if v:
            en = item.get("localizations", {}).get("en", {}).get("stringUnit", {}).get("value", key)
            out[en] = v
    return out
ENGLISH = {"en", "en-GB", "en-US"}
WORD = re.compile(r"[A-Za-z]{2,}")


SCOPED = []


def load_allow():
    """Exact texts, `re:` patterns, and `<screen-glob>|<text>` entries that
    only apply on matching screens (a brand that is also an app word
    elsewhere — Cursor the editor vs the Cursor tab)."""
    exact, patterns = set(), []
    if os.path.exists(ALLOW):
        for line in open(ALLOW, encoding="utf-8"):
            line = line.rstrip("\n")
            if not line.strip() or line.startswith("#"):
                continue
            if line.startswith("re:"):
                patterns.append(re.compile(line[3:]))
            elif "|" in line:
                SCOPED.append(tuple(line.split("|", 1)))
            else:
                exact.add(line)
    return exact, patterns


SPEC = re.compile(r"%(?:\d+\$)?(?:lld|ld|d|@)")


def same_in(lang, catalog):
    """Texts that are legitimately identical to English in `lang`: strings
    whose translation IS the English (OK, Zoom, Pro, GIF…) — also as an
    uppercase section header — and format strings translated identically
    ("%lld fps"), as patterns."""
    exact, patterns = set(), []
    for key, item in catalog["strings"].items():
        locs = item.get("localizations", {})
        en = locs.get("en", {}).get("stringUnit", {}).get("value", key)
        tr = locs.get(lang, {}).get("stringUnit", {}).get("value")
        if tr is None or tr != en:
            continue
        if SPEC.search(en):
            parts = SPEC.split(en)
            if not WORD.search("".join(parts)):
                continue  # "%@", "%@ · %@": would excuse anything
            patterns.append(re.compile("^" + "(.+)".join(re.escape(p.replace("%%", "%")) for p in parts) + "$", re.S))
        else:
            exact.add(en)
            exact.add(en.upper())
    return exact, patterns


def screens(path):
    out = {}
    if not os.path.isdir(path):
        return out
    for name in sorted(os.listdir(path)):
        if name.endswith(".json"):
            with open(os.path.join(path, name), encoding="utf-8") as f:
                out[name[:-5]] = json.load(f)
    return out


def main():
    args = sys.argv[1:]
    run = args[0]
    expect = args[args.index("--expect") + 1] if "--expect" in args else None
    with open(CATALOG, encoding="utf-8") as f:
        catalog = json.load(f)
    exact, patterns = load_allow()

    import fnmatch

    def allowed(text, lang, screen=""):
        if not WORD.search(text):
            return True
        if any(t == text and fnmatch.fnmatch(screen, g) for g, t in SCOPED):
            return True
        if text in exact or any(p.search(text) for p in patterns):
            return True
        return False

    def content_problem(problem):
        """Truncation of user / fixture content (a project name, a comment,
        a server message) is the design — the app's own copy must fit."""
        m = re.match(r'truncated: "(.*)" (needs|line) ', problem, re.S)
        if not m:
            return False
        text = m.group(1)
        return any(len(c) >= 6 and c in text for c in exact)

    failures = []
    caught = {"untranslated": 0, "truncate": 0, "collision": 0}
    checked = {}
    synonyms = load_synonyms()
    tr_cache = {}
    tr_values = {}
    locales = sorted(l for l in os.listdir(run) if not l.startswith(".") and os.path.isdir(os.path.join(run, l)))
    if "en" not in locales:
        failures.append("no English (en) run to compare against")
        locales = []
    gates = sorted(g for g in os.listdir(os.path.join(run, "en")) if os.path.isdir(os.path.join(run, "en", g))) if locales else []
    for gate in gates:
        base = screens(os.path.join(run, "en", gate))
        for loc in locales:
            lang = loc
            caps = screens(os.path.join(run, loc, gate))
            same, same_patterns = same_in(lang, catalog)
            missing = sorted(set(base) - set(caps)) if loc != "en" else []
            if missing and not expect:
                failures.append(f"{loc} {gate}: screens missing vs English: {', '.join(missing)}")
            n_untr = n_prob = 0
            checked.setdefault(loc, 0)
            checked[loc] += sum(len(r.get("texts", [])) for r in caps.values())
            for name, rep in caps.items():
                for p in rep.get("problems", []):
                    if content_problem(p):
                        continue
                    n_prob += 1
                    if "truncated" in p:
                        caught["truncate"] += 1
                    failures.append(f"{loc} {gate}/{name}: {p}")
                if lang in ENGLISH:
                    continue
                en_texts = {t["text"] for t in base.get(name, {}).get("texts", [])}
                # Any visible text that IS a catalog English source with a
                # different translation is untranslated, whether or not the
                # English run showed it on this screen (a hard-coded label
                # only one language path reaches).
                tr_here = tr_cache.setdefault(lang, translations(catalog, lang))
                own_words = tr_values.setdefault(lang, set(tr_here.values()))
                en_texts = en_texts | {t["text"] for t in rep.get("texts", [])
                                       if t["text"] in tr_here and tr_here[t["text"]] != t["text"]
                                       and t["text"] not in own_words}  # fr "Large" = Wide
                flagged = set()
                for t in rep.get("texts", []):
                    text = t["text"]
                    def fine(piece):
                        return piece in same or any(p.match(piece) for p in same_patterns) or allowed(piece, lang, name)
                    # "Images · 2": a joined label is fine when every part is.
                    pieces = [x.strip() for x in re.split(r" · |, | — ", text) if x.strip()]
                    if text in en_texts and not fine(text) and not (len(pieces) > 1 and all(fine(x) for x in pieces)) \
                            and text not in flagged:
                        flagged.add(text)
                        n_untr += 1
                        caught["untranslated"] += 1
                        failures.append(f"{loc} {gate}/{name}: untranslated [{t['kind']}] “{text}”")
            # Collisions: two different English labels on one screen that
            # come out as the same translation (de Clear/Delete → "Löschen").
            n_coll = 0
            if lang not in ENGLISH:
                tr = tr_cache.setdefault(lang, translations(catalog, lang))
                for name, rep in base.items():
                    shown = {t["text"] for t in caps.get(name, {}).get("texts", [])}
                    by_tr = {}
                    for t in rep.get("texts", []):
                        en = t["text"]
                        if en in tr and len(en) < 40 and tr[en] in shown:
                            by_tr.setdefault(tr[en], set()).add(en)
                    for target, sources in by_tr.items():
                        if len(sources) < 2:
                            continue
                        srcs = sorted(sources)
                        bad = [(a, b) for i, a in enumerate(srcs) for b in srcs[i + 1:]
                               if a.casefold() != b.casefold()
                               and (frozenset((a, b)), None) not in synonyms
                               and (frozenset((a, b)), lang) not in synonyms]
                        for a, b in bad:
                            n_coll += 1
                            caught["collision"] += 1
                            failures.append(f"{loc} {gate}/{name}: collision “{a}” and “{b}” both → “{target}”")
            print(f"  {gate:22s} {loc:8s}: {len(caps):3d} screens, {n_untr} untranslated, {n_prob} text problem(s), {n_coll} collision(s)")

    print("  coverage (texts checked per locale): " + ", ".join(f"{l} {n}" for l, n in sorted(checked.items())))
    if expect:
        ok = caught.get(expect, 0) > 0
        print(f"L10N-JUDGE inject={expect}: {'CAUGHT' if ok else 'MISSED'} ({caught.get(expect, 0)} finding(s))")
        word = {"untranslated": "untranslated", "truncate": "truncated", "collision": "collision"}.get(expect, expect)
        for f in [f for f in failures if word in f][:6]:
            print("    " + f)
        sys.exit(0 if ok else 1)
    for f in failures:
        print("  ! " + f)
    print("L10N-JUDGE " + ("PASS" if not failures else f"FAIL ({len(failures)} finding(s))"))
    sys.exit(0 if not failures else 1)


if __name__ == "__main__":
    main()
