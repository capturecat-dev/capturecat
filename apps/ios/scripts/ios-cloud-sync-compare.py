#!/usr/bin/env python3
"""Compare the iOS replay of the Mac's --cloud-sync-test engine sections with
the Mac's own transcript (apps/ios/scripts/ios-cloud-sync.sh).

    ios-cloud-sync-compare.py <mac-transcript> <ios-run-log> <report>

Every line iOS prints for the shared engine sections must be a line the Mac
prints, in the same order (the Mac prints more: its AppKit-only sections —
the web editor URL, its alert words, the cloud library, the top bar and the
progress dialog, the Merge Review dialog). Normalised first, because some
text differs run to run on ANY machine: UUIDs, temp paths, content hashes,
random file-name suffixes, a timing-dependent percentage, and Swift
Dictionary / Set print order (randomised per process).
"""
import re
import sys

UUID = re.compile(r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")


def normalise(line):
    line = UUID.sub("<UUID>", line)
    line = re.sub(r"(/private)?/var/folders/[^ )\]\"]*", "<TMP>", line)
    line = re.sub(r"/Users/[^ )\]\"]*/(data/Containers/Data/Application|tmp)/[^ )\]\"]*", "<TMP>", line)
    line = re.sub(r"[0-9a-f]{64}", "<SHA>", line)
    line = re.sub(r"[0-9a-f]{12}\.", "<SHA12>.", line)
    line = re.sub(r"-[0-9A-Fa-f]{8}\.(png|jpg|m4a|wav)", r"-<H8>.\1", line)
    line = re.sub(r"fetched [0-9]+% of", "fetched N% of", line)
    line = re.sub(r"\((\d+) updates\)", "(N updates)", line)
    line = re.sub(r"\b(StudioLab|CaptureCat)\.", "", line)  # type names in printed values

    # Order-free printing: sort the items of every innermost [...] list.
    def sort_items(match):
        items = [i.strip() for i in match.group(1).split(",")]
        return "[" + ", ".join(sorted(items)) + "]"
    line = re.sub(r"\[([^\[\]]*)\]", sort_items, line)
    return line.rstrip()


def checks(lines):
    out = []
    for l in lines:
        # A system log line (ImageIO's "unrecognised property key", …) can land
        # on the same console line in front of a check: keep the check.
        for mark in ("  ✓ ", "  ✘ "):
            at = l.find(mark)
            if at > 0:
                l = l[at:]
        if l.startswith("  ✓ ") or l.startswith("  ✘ "):
            out.append(normalise(l))
    return out


def main():
    mac_path, ios_path, report_path = sys.argv[1:4]
    mac = open(mac_path, encoding="utf-8", errors="replace").read().splitlines()
    ios_all = open(ios_path, encoding="utf-8", errors="replace").read().splitlines()
    # iOS part A: from "CLOUD SYNC TEST" to its PASS/FAIL line.
    try:
        start = ios_all.index("CLOUD SYNC TEST")
    except ValueError:
        print("COMPARE FAIL: no engine section in the iOS run")
        return 1
    ios = []
    for line in ios_all[start + 1:]:
        if line.startswith("CLOUD SYNC PASS") or line.startswith("CLOUD SYNC FAIL"):
            break
        ios.append(line)
    m = checks(mac[mac.index("CLOUD SYNC TEST") + 1:])
    i = checks(ios)
    # Lines naming randomly-named files print in name order, which differs
    # run to run: those compare as a multiset; every other iOS line must be
    # found in the Mac's, in order (an ordered subsequence).
    def random_named(line):
        return "<UUID>" in line or "<H8>" in line
    from collections import Counter
    pool = Counter(l for l in m if random_named(l))
    j = 0
    missing = []
    matched = set()
    for line in i:
        if random_named(line):
            if pool[line] > 0:
                pool[line] -= 1
            else:
                missing.append(line)
            continue
        k = j
        while k < len(m) and m[k] != line:
            k += 1
        if k == len(m):
            missing.append(line)
        else:
            matched.add(k)
            j = k + 1
    taken = Counter(l for l in i if random_named(l))
    mac_only = []
    for k, line in enumerate(m):
        if random_named(line):
            if taken[line] > 0:
                taken[line] -= 1
                continue
            mac_only.append(line)
        elif k not in matched:
            mac_only.append(line)
    ios_checks = sum(1 for l in i if l.startswith("  ✓") or l.startswith("  ✘"))
    mac_checks = sum(1 for l in m if l.startswith("  ✓") or l.startswith("  ✘"))
    with open(report_path, "w", encoding="utf-8") as out:
        out.write(f"iOS lines {len(i)} (checks {ios_checks}); Mac lines {len(m)} (checks {mac_checks})\n")
        out.write(f"iOS lines not in the Mac transcript (in order): {len(missing)}\n")
        for line in missing:
            out.write(f"  ios  {line}\n")
        out.write(f"Mac-only lines (AppKit sections): {len(mac_only)}\n")
        for line in mac_only:
            out.write(f"  mac  {line}\n")
    failed = [l for l in i if l.startswith("  ✘")]
    if missing or failed:
        print(f"COMPARE FAIL: {len(missing)} iOS line(s) differ from the Mac's, {len(failed)} failed check(s) — see {report_path}")
        for line in missing[:12]:
            print(f"    ios  {line}")
        return 1
    print(f"COMPARE PASS: {ios_checks} engine checks on iOS, every line identical to the Mac's "
          f"({mac_checks - ios_checks} Mac-only checks in its AppKit sections)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
