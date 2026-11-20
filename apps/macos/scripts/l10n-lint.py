#!/usr/bin/env python3
"""Static localization lint for the Mac app (and the shared Studio code).

    l10n-lint.py [--list] [paths…]

Fails on any string literal that reaches a UI sink without going through the
String Catalog — `title: "Delete"`, `field.stringValue = "Size"`,
`NSTextField(labelWithString: "Font")`, `toolTip = "…"`, `setAccessibilityLabel("…")`,
`NSMenuItem(title: "…")`, CCKit/InspectorKit initialisers, `return "…"` inside a
`displayName` / `title` / `label` / `summary` / `caption` property, etc.

A literal passes when it has no words (symbols, numbers, "%@ · %@", "16:9"),
or it is on the allowlist (scripts/l10n-lint-allow.txt: brand and format
tokens — exact text, or `re:<regex>`), or the line carries `// l10n: verbatim` (or the iOS branch's `// l10n-ok:`)
with a reason (identifiers that happen to sit in a title slot, brand names).

Not scanned: gate/harness/probe/fixture code, the MCP server (agent-facing,
English by design), logs.

Exit 1 with every hit listed; `--list` prints hits without failing.
"""
import os
import re
import sys

MAC = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROOT = os.path.join(MAC, "CaptureCat")
ALLOW = os.path.join(MAC, "scripts", "l10n-lint-allow.txt")

SKIP_FILE = re.compile(r"(Harness|Probe|Shot|Golden|Goldens|Transcript|Selftest|Fixture|Runner|WebVectors|"
                       r"MCPServer|ParityFixture|StubCloudServer|HarnessPixels|RasterFingerprint|"
                       r"CCLocalizationAudit|main\.swift)")
SKIP_DIR = ("StudioHarness",)

LIT = r'"((?:[^"\\]|\\.)*)"'
# A literal argument / assignment right at a UI sink.
SINKS = [
    r'\b(?:stringValue|title|placeholderString|toolTip|informativeText|messageText|subtitle|caption|'
    r'emptyText|detail|message|headline|hint)\s*=\s*' + LIT,
    r'\b(?:labelWithString|wrappingLabelWithString|title|subtitle|caption|message|placeholder|detail|header|'
    r'toolTip|tooltip|withTitle|disabledCaption|emptyText|hint|headline|overline|body|note|badge|'
    r'accessibilityLabel|accessibilityDescription|prompt|confirmTitle|cancelTitle|primaryTitle|actionTitle|'
    r'buttonTitle|segments|label|paragraph|text)\s*:\s*' + LIT,
    r'\bsetAccessibility(?:Label|Help|Title|Value)\(\s*' + LIT,
    r'\b(?:InspectorCaption|InspectorSection|InspectorHeader)\([^"\n]*?,\s*' + LIT,
    r'\baddButton\(\s*' + LIT,
    r'\bsetMenuTitle\([^,\n]+,\s*' + LIT,
]
# `return "…"` inside a property / function whose job is display text.
DISPLAY_PROP = re.compile(r'\b(?:var|func)\s+(displayName|title|shortTitle|label|summary|caption|subtitle|'
                          r'detail|message|errorDescription|failureReason|recoverySuggestion|platformHint|'
                          r'badgeTitle|toastTitle|tooltip|placeholder|headline|description)\b')
RETURN_LIT = re.compile(r'\breturn\s+' + LIT)
CASE_RETURN_LIT = re.compile(r'\bcase\b[^:\n]*:\s*return\s+' + LIT)
# A persisted raw value shown as text: raw values are identity, never copy —
# the display goes through the type's localized displayName/title.
RAW_SINK = re.compile(r'\b(?:stringValue|title|subtitle|label|caption|toolTip|placeholderString)\s*[:=]\s*'
                      r'([\w$.()\[\]]+\.rawValue)\b(?!\s*\.)')
RAW_MAP = re.compile(r'\.map\s*[({]\s*(?:\\\.rawValue|\$0\.rawValue)\s*[)}]')
ARRAY_LIT = re.compile(r'\bsegments\s*:\s*\[([^\]]*)\]')
WORD = re.compile(r"[A-Za-z]{2,}")
VERBATIM = re.compile(r"l10n: verbatim|l10n-ok:")  # the iOS branch writes `// l10n-ok: reason`


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


def strip_interp(text):
    """`\\(n) seconds` → ` seconds`: the words outside interpolations."""
    out, depth, i = [], 0, 0
    while i < len(text):
        if text.startswith("\\(", i):
            depth += 1
            i += 2
            continue
        if depth and text[i] == "(":
            depth += 1
        elif depth and text[i] == ")":
            depth -= 1
            i += 1
            continue
        if not depth:
            out.append(text[i])
        i += 1
    return "".join(out)


def is_text(lit, exact, patterns):
    words = strip_interp(lit)
    if not WORD.search(words):
        return False
    if lit in exact or any(p.search(lit) for p in patterns):
        return False
    return True


def files(paths):
    for base in paths:
        if os.path.isfile(base):
            yield base
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIR]
            for name in filenames:
                if name.endswith(".swift") and not SKIP_FILE.search(name):
                    yield os.path.join(dirpath, name)


def scan(path, exact, patterns):
    hits = []
    with open(path, encoding="utf-8") as f:
        lines = f.read().split("\n")
    in_display = None   # (indent, name) while inside a display property body
    in_debug = 0
    in_block_comment = False
    for n, raw in enumerate(lines, 1):
        line = raw
        stripped = line.strip()
        if in_block_comment:
            if "*/" in line:
                in_block_comment = False
            continue
        if stripped.startswith("/*"):
            in_block_comment = "*/" not in stripped
            continue
        if stripped.startswith("//"):
            continue
        if stripped.startswith("#if DEBUG") or stripped.startswith("#if HARNESS"):
            in_debug += 1
        elif stripped.startswith("#endif") and in_debug:
            in_debug -= 1
        if in_debug:
            continue
        if VERBATIM.search(line):
            continue
        # Drop trailing comments and logging calls.
        code = re.sub(r'\s//(?!/).*$', "", line)
        # Not UI: queue labels and internal codec diagnostics.
        if re.search(r'\b(DispatchQueue|CodecError|OSAllocatedUnfairLock|Logger)\(', code):
            continue
        if re.search(r'\b(print|NSLog|os_log|log\.\w+|logger\.\w+|Logger\(|fatalError|precondition|'
                     r'assert|assertionFailure|preconditionFailure)\s*\(', code):
            continue
        # Literals already inside String(localized: …) are fine: blank them.
        code = re.sub(r'String\(\s*localized:\s*' + LIT, 'String(localized: ""', code)
        code = re.sub(r'LocalizedStringResource\(\s*' + LIT, 'LocalizedStringResource(""', code)

        m = DISPLAY_PROP.search(code)
        if m and "{" in code and "=" not in code.split(m.group(0))[0][-3:]:
            in_display = (len(raw) - len(raw.lstrip()), m.group(1))
        elif in_display and stripped.startswith("}") and (len(raw) - len(raw.lstrip())) <= in_display[0]:
            in_display = None

        found = []
        for sink in SINKS:
            for mm in re.finditer(sink, code):
                found.append(mm.group(mm.lastindex))
        for mm in ARRAY_LIT.finditer(code):
            found += re.findall(LIT, mm.group(1))
        if in_display:
            for mm in RETURN_LIT.finditer(code):
                found.append(mm.group(1))
            for mm in CASE_RETURN_LIT.finditer(code):
                found.append(mm.group(1))
        for mm in RAW_SINK.finditer(code):
            hits.append((n, mm.group(1), stripped[:140]))
        if RAW_MAP.search(code) and re.search(r'\b(items|options|segments|titles|labels)\b', code):
            hits.append((n, "map(\\.rawValue)", stripped[:140]))
        for lit in dict.fromkeys(found):
            if is_text(lit, exact, patterns):
                hits.append((n, lit, stripped[:140]))
    return hits


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    listing = "--list" in sys.argv
    exact, patterns = load_allow()
    total = 0
    scanned = 0
    for path in sorted(files(args or [ROOT])):
        scanned += 1
        for n, lit, ctx in scan(path, exact, patterns):
            total += 1
            print(f"{os.path.relpath(path, MAC)}:{n}: raw “{lit}”  ⟨{ctx}⟩")
    print(f"L10N-LINT {'PASS' if total == 0 else f'FAIL ({total} raw literal(s) at UI sinks)'} — {scanned} files scanned")
    sys.exit(0 if total == 0 or listing else 1)


if __name__ == "__main__":
    main()
