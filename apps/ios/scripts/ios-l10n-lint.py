#!/usr/bin/env python3
"""Static localization lint for the iOS app (part of ios-l10n.sh).

No English string literal may reach a UIKit text sink without
`String(localized:)`. Scans the shipping sources — App/, StudioUI/, Kit/,
Core/, ShareExtension/, Broadcast/ and the studio core shared with the Mac
(../macos/CaptureCat/Studio, ../macos/CaptureCat/Shared) — and flags a
literal with words in it that is handed to:

  .text / .title / .placeholder / .string (CATextLayer) / attributedText /
  accessibilityLabel / accessibilityHint / accessibilityValue /
  accessibilityLabelOverride / setTitle( / UIAction(title: / UIMenu(title: /
  UIAccessibilityCustomAction(name: / ccLabel( / CCButton(title: /
  CCBadge( / addAction(" / addButton(" / CCAlert…(title: / message: /
  confirmTitle: / placeholder: / show(title: / announce( / CCNavItem(title: /
  CCHeaderBar(title: / CCEmptyState(…) / setActionName( / localizedDescription /
  errorDescription returns, and `title:` / `subtitle:` / `detail:` / `label:`
  arguments in general.

Skipped: `#if DEBUG` blocks, harness files (App/Fixtures, StudioLab,
*Audit*, *Probe*, *Lab*), comments, print/log/assert/precondition lines,
literals with no letters ("\\(a) · \\(b)", "0:00", "%"), and the tokens in
ALLOW (brand, file formats). A deliberate English literal is marked on its
line with `// l10n-ok: <why>`.

    ios-l10n-lint.py                  # the lint (exit 1 on a finding)
    ios-l10n-lint.py --selftest       # an injected raw literal must be caught
"""
import os
import re
import sys
import tempfile

IOS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROOTS = ["App", "StudioUI", "Kit", "Core", "ShareExtension", "Broadcast",
         "../macos/CaptureCat/Studio", "../macos/CaptureCat/Shared"]
SKIP_PATH = re.compile(r"(/Fixtures/|/StudioLab/|Audit|Probe|Lab\.swift|/StudioHarness/|Debug\.swift$"
                       # codec diagnostics (they ride after a translated sentence, never alone)
                       r"|/CameraMaskTrack\.swift$)")
ALLOW = {"CaptureCat", "CAPTURECAT", "Pro", "Mac", "iPhone", "iPad", "iOS", "macOS", "Web", "MP4", "MOV", "GIF",
         "PNG", "JPEG", "HDR", "HTTP", "fps", "Aa", "AA", "OK", "DELETE", "Wi-Fi", "Mbps", "px", "pt", "x", "×"}

SINK = re.compile(
    r"""(\.(?:text|title|placeholder|string|accessibilityLabel|accessibilityHint|accessibilityValue|
           accessibilityLabelOverride|headerTitle|subtitle|message|caption|hint)\s*=\s*
        |\bsetTitle\(\s*|\bsetActionName\(\s*|\bannounce\(\s*|\bccLabel\(\s*|\bCCBadge\(\s*
        |\b(?:addAction|addButton)\(\s*
        |\b(?:UIAction|UIMenu|CCButton|CCNavItem|CCHeaderBar|CCActionSheet|CCAlert|CCEmptyState|CCCallout|CCToggleRow)\((?:[^()"]*?)\b(?:title|name|message)\s*:\s*
        |\bUIAccessibilityCustomAction\(\s*name\s*:\s*
        |\b(?:title|subtitle|message|detail|confirmTitle|placeholder|label|hint|caption|name)\s*:\s*
        |\breturn\s+(?=")
        )"(?P<lit>(?:[^"\\\n]|\\.)*)" """, re.X)
ARRAY_SINK = re.compile(r"\b(?:items|titles|options|segments|labels|choices|names)\s*:\s*\[")
WORDY = re.compile(r"[A-Za-z]{2,}")
INTERP = re.compile(r"\\\((?:[^()]|\([^()]*\))*\)")
SKIP_LINE = re.compile(r"^\s*(//|\*|///)|\b(print|debugPrint|os_log|Logger|log|assert|assertionFailure|precondition|preconditionFailure|fatalError|NSLog)\(|forKey|withName:|named:|identifier|Identifier|systemName|CCIcon|symbol:|\.png|\.json|\.mov|http|UserDefaults|Notification\.Name|#selector|rawValue|case \.|fileName|pathComponent|appendingPath|contentType|mimeType|header|Header|URL\(|keyPath|codingKey|CodingKeys")
RETURN_CONTEXT = re.compile(r"(errorDescription|localizedDescription|failureReason|recoverySuggestion|displayName|title|label|name|summary|caption|message)\b")


IDENT = re.compile(r"^(?:[a-z][A-Za-z0-9_.\-]*|CI[A-Z][A-Za-z]+|[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+)$")


def strip_interpolations(lit):
    out, i = [], 0
    while i < len(lit):
        if lit.startswith("\\(", i):
            depth, i = 1, i + 2
            while i < len(lit) and depth:
                depth += {"(": 1, ")": -1}.get(lit[i], 0)
                i += 1
            continue
        out.append(lit[i])
        i += 1
    return "".join(out)


def literal_words(lit):
    if IDENT.match(lit):
        return []  # an identifier, key, filter or queue name — not copy
    bare = strip_interpolations(lit)
    words = WORDY.findall(bare)
    return [w for w in words if w not in ALLOW]


def scan_file(path):
    findings = []
    with open(path, encoding="utf-8") as f:
        lines = f.read().split("\n")
    depth_debug = 0
    stack = []
    func_ctx = ""
    for i, line in enumerate(lines, 1):
        s = line.strip()
        if s.startswith("#if"):
            stack.append("DEBUG" in s and "!DEBUG" not in s)
            if stack[-1]:
                depth_debug += 1
            continue
        if s.startswith("#else") and stack:
            if stack[-1]:
                depth_debug -= 1
            stack[-1] = False
            continue
        if s.startswith("#endif") and stack:
            if stack.pop():
                depth_debug -= 1
            continue
        m = re.search(r"\b(var|func)\s+(\w+)", s)
        if m:
            func_ctx = m.group(2)
        if depth_debug > 0 or SKIP_LINE.search(s) or "l10n-ok" in line:
            continue
        # Strip String(localized: …) payloads first so their literals don't count.
        probe = re.sub(r"String\(localized:\s*\"(?:[^\"\\\n]|\\.)*\"", "String(localized: X", line)
        probe = re.sub(r"LocalizedStringResource\(\s*\"(?:[^\"\\\n]|\\.)*\"", "X", probe)
        probe = re.sub(r"comment:\s*\"(?:[^\"\\\n]|\\.)*\"", "comment: X", probe)
        if ARRAY_SINK.search(probe):
            for lit in re.findall(r'"((?:[^"\\\n]|\\.)*)"', probe[ARRAY_SINK.search(probe).end():]):
                if literal_words(lit):
                    findings.append((path, i, lit))
        for m in SINK.finditer(probe):
            lit = m.group("lit")
            if m.group(0).lstrip().startswith("return") and not RETURN_CONTEXT.search(func_ctx):
                continue
            if literal_words(lit):
                findings.append((path, i, lit))
    return findings


def scan(roots):
    out = []
    for root in roots:
        base = os.path.normpath(os.path.join(IOS, root))
        for dirpath, _, files in os.walk(base):
            for name in files:
                path = os.path.join(dirpath, name)
                if not name.endswith(".swift") or SKIP_PATH.search(path):
                    continue
                out += scan_file(path)
    return out


def main():
    if "--selftest" in sys.argv:
        with tempfile.TemporaryDirectory() as tmp:
            bad = os.path.join(tmp, "Injected.swift")
            with open(bad, "w") as f:
                f.write('import UIKit\nfunc f(_ l: UILabel, _ b: UIButton) {\n    l.text = "Delete project"\n'
                        '    b.setTitle("Try again", for: .normal)\n    l.accessibilityLabel = "Close"\n'
                        '    _ = UIAction(title: "Rename") { _ in }\n    l.text = String(localized: "Fine")\n'
                        '    l.text = "\\(1) · \\(2)"\n    _ = CCSegmented(items: ["All", String(localized: "Videos")])\n}\n')
            found = scan_file(bad)
            want = {"Delete project", "Try again", "Close", "Rename", "All"}
            got = {lit for _, _, lit in found}
            ok = want <= got and "Fine" not in got and len(found) == len(want)
            print(f"L10N-LINT selftest: injected {sorted(want)} → caught {sorted(got)}")
            print("L10N-LINT selftest " + ("CAUGHT" if ok else "MISSED"))
            sys.exit(0 if ok else 1)
    findings = scan(ROOTS)
    for path, line, lit in findings:
        print(f"  ! {os.path.relpath(path, os.path.dirname(IOS))}:{line}: \"{lit}\"")
    print("L10N-LINT " + ("PASS (no raw English literal reaches a UI sink)" if not findings else f"FAIL ({len(findings)} raw literal(s))"))
    sys.exit(0 if not findings else 1)


if __name__ == "__main__":
    main()
