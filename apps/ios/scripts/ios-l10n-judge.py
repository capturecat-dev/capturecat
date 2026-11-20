#!/usr/bin/env python3
"""Judge the localization gate's captures (apps/ios/scripts/ios-l10n.sh).

    ios-l10n-judge.py <run-dir> [--expect untranslated|truncate]

<run-dir>/<device>/<locale>/{app,lab}/<screen>.json are CCLocalizationAudit
reports. For every device and locale:

  untranslated  a text that comes out IDENTICAL in the English run of the same
                screen — unless the catalog's translation for that language is
                itself identical (OK, Zoom, Pro, GIF…), it has no words, or it
                is fixture content listed in ios-l10n-allow.txt (project
                names, comments, emails…);
  text problems what CCAccessibilityAudit.checkText measured: truncated,
                clipped by a non-scrolling ancestor, overlapping text — in ANY
                language, English included;
  coverage      the same screens as the English run.

--expect <defect>: the run had a defect injected; PASS only if it was caught
(the gate's proof that it can see).
"""
import json
import os
import re
import sys

IOS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(IOS, "Localization", "Localizable.xcstrings")
ALLOW = os.path.join(IOS, "scripts", "ios-l10n-allow.txt")
ENGLISH = {"en", "en-GB", "en-US"}
WORD = re.compile(r"[A-Za-z]{2,}")


def load_allow():
    exact, patterns = set(), []
    if os.path.exists(ALLOW):
        for line in open(ALLOW, encoding="utf-8"):
            line = line.rstrip("\n")
            if not line.strip() or line.startswith("#"):
                continue
            if line.startswith("re:"):
                patterns.append(re.compile(line[3:]))
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


def row_duplicates(rep):
    """Short labels that appear twice in one row (a tool bar, a chip row):
    {text: count of extra copies}."""
    rows = []
    for t in rep.get("texts", []):
        if t["kind"] != "label" or len(t["text"]) > 30 or t["frame"][3] > 30:
            continue
        cy = t["frame"][1] + t["frame"][3] / 2
        for row in rows:
            if abs(row[0] - cy) <= 4:
                row[1].append(t["text"])
                break
        else:
            rows.append([cy, [t["text"]]])
    dups = {}
    for _, texts in rows:
        # Case-folded: "EFFECTS" (a section header) and "Effects" (a tab) are
        # one word in English too — a caseless script writing them alike is
        # no collision.
        folded = [t.casefold() for t in texts]
        for text in set(folded):
            if folded.count(text) > 1:
                dups[text] = dups.get(text, 0) + folded.count(text) - 1
    return dups


def screens(path):
    out = {}
    if not os.path.isdir(path):
        return out
    for name in sorted(os.listdir(path)):
        if name.endswith(".json"):
            with open(os.path.join(path, name), encoding="utf-8") as f:
                out[name[:-5]] = json.load(f)
    return out


def collision_selftest(run):
    """Copy one translated screen with a row of controls, make one control
    read like its neighbour, judge the copy: it must be caught."""
    import shutil, tempfile
    for device in sorted(os.listdir(run)):
        for loc in sorted(os.listdir(os.path.join(run, device))):
            if loc in ENGLISH or not os.path.isdir(os.path.join(run, device, loc, "lab")):
                continue
            for name, rep in screens(os.path.join(run, device, loc, "lab")).items():
                rows = {}
                for t in rep["texts"]:
                    if t["kind"] == "label" and len(t["text"]) <= 30 and t["frame"][3] <= 30:
                        rows.setdefault(round((t["frame"][1] + t["frame"][3] / 2) / 4), []).append(t)
                row = next((r for r in rows.values() if len({t["text"] for t in r}) >= 3), None)
                if not row or not os.path.exists(os.path.join(run, device, "en", "lab", name + ".json")):
                    continue
                tmp = tempfile.mkdtemp()
                for l in ("en", loc):
                    os.makedirs(os.path.join(tmp, device, l, "lab"))
                shutil.copy(os.path.join(run, device, "en", "lab", name + ".json"), os.path.join(tmp, device, "en", "lab"))
                row[1]["text"] = row[0]["text"]
                with open(os.path.join(tmp, device, loc, "lab", name + ".json"), "w") as f:
                    json.dump(rep, f)
                print(f"L10N-JUDGE collision selftest: {device} {loc} {name}: “{row[1]['text']}” twice in one row", flush=True)
                return tmp
    return None


def main():
    args = sys.argv[1:]
    run = args[0]
    if "--collision-selftest" in args:
        tmp = collision_selftest(run)
        if not tmp:
            print("L10N-JUDGE collision selftest: no translated row of controls to inject into")
            sys.exit(1)
        os.execv(sys.executable, [sys.executable, __file__, tmp, "--expect", "collision"])
    expect = args[args.index("--expect") + 1] if "--expect" in args else None
    with open(CATALOG, encoding="utf-8") as f:
        catalog = json.load(f)
    exact, patterns = load_allow()

    def allowed(text, lang):
        if not WORD.search(text):
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
    caught = {"untranslated": 0, "truncate": 0}
    devices = sorted(d for d in os.listdir(run) if os.path.isdir(os.path.join(run, d)))
    for device in devices:
        droot = os.path.join(run, device)
        locales = sorted(l for l in os.listdir(droot) if os.path.isdir(os.path.join(droot, l)))
        if "en" not in locales:
            failures.append(f"{device}: no English (en) run to compare against")
            continue
        for part in ("app", "lab"):
            base = screens(os.path.join(droot, "en", part))
            for loc in locales:
                lang = loc.split("@")[0]
                caps = screens(os.path.join(droot, loc, part))
                if not caps and not base:
                    continue
                same, same_patterns = same_in(lang, catalog)
                missing = sorted(set(base) - set(caps)) if loc != "en" else []
                if missing and not expect:
                    failures.append(f"{device} {loc} {part}: screens missing vs English: {', '.join(missing)}")
                n_untr = n_prob = 0
                for name, rep in caps.items():
                    for p in rep.get("problems", []):
                        if content_problem(p):
                            continue
                        n_prob += 1
                        if "truncated" in p:
                            caught["truncate"] += 1
                        failures.append(f"{device} {loc} {part}/{name}: {p}")
                    if lang in ENGLISH:
                        continue
                    # Two controls side by side that differ in English must not
                    # read the same here (Split / Share → "Teilen").
                    base_dups = sum(row_duplicates(base.get(name, {})).values())
                    here = row_duplicates(rep)
                    if sum(here.values()) > base_dups:
                        for text in here:
                            caught["collision"] = caught.get("collision", 0) + 1
                            failures.append(f"{device} {loc} {part}/{name}: two different controls in one row both read “{text}”")
                    en_texts = {t["text"] for t in base.get(name, {}).get("texts", [])}
                    flagged = set()
                    for t in rep.get("texts", []):
                        text = t["text"]
                        def fine(piece):
                            return piece in same or any(p.match(piece) for p in same_patterns) or allowed(piece, lang)
                        # "Images · 2": a joined label is fine when every part is.
                        pieces = [x.strip() for x in re.split(r" · |, ", text) if x.strip()]
                        if text in en_texts and not fine(text) and not (len(pieces) > 1 and all(fine(x) for x in pieces)) \
                                and text not in flagged:
                            flagged.add(text)
                            n_untr += 1
                            caught["untranslated"] += 1
                            failures.append(f"{device} {loc} {part}/{name}: untranslated [{t['kind']}] “{text}”")
                print(f"  {device:7s} {loc:8s} {part}: {len(caps):3d} screens, {n_untr} untranslated, {n_prob} text problem(s)")

    if expect:
        ok = caught.get(expect, 0) > 0
        print(f"L10N-JUDGE inject={expect}: {'CAUGHT' if ok else 'MISSED'} ({caught.get(expect, 0)} finding(s))")
        for f in failures[:12]:
            print("    " + f)
        sys.exit(0 if ok else 1)
    for f in failures:
        print("  ! " + f)
    print("L10N-JUDGE " + ("PASS" if not failures else f"FAIL ({len(failures)} finding(s))"))
    sys.exit(0 if not failures else 1)


if __name__ == "__main__":
    main()
