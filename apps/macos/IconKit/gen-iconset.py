#!/usr/bin/env python3
"""icons.json (the drawn CaptureCat icon kit) → CCIconSet.swift (the app's icon table).

    python3 apps/macos/IconKit/gen-iconset.py            # default paths below
    python3 gen-iconset.py <icons.json> <CCIconSet.swift>

icons.json holds every glyph as an SVG subset on a 24 × 24 grid (see CCIcon.swift
for the renderer contract) plus `aliases` (SF Symbol name a call site asks for →
kit icon). Edit the json, run this, build, then run `CaptureCat --iconkit-test`.
"""
import json, os, re, sys

here = os.path.dirname(os.path.abspath(__file__))
src = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "icons.json")
dst = sys.argv[2] if len(sys.argv) > 2 else os.path.join(
    here, "..", "CaptureCat", "Views", "Shared", "DesignKit", "CCIconSet.swift")
kit = json.load(open(src))
icons, aliases = kit["icons"], kit["aliases"]
missing = sorted({v for v in aliases.values() if v not in icons})
assert not missing, f"aliases point at undrawn icons: {missing}"
# The Swift renderer parses exactly this subset; anything else would be dropped
# silently at runtime, so refuse it here.
for name, markup in icons.items():
    rest = re.sub(r'<(path|circle|rect|line)((?:\s+[a-z0-9]+="[^"]*")*)\s*/>', "", markup)
    assert not rest.strip(), f"{name}: unsupported markup {rest.strip()[:60]!r}"
    for d in re.findall(r'\bd="([^"]*)"', markup):
        bad = re.sub(r"[MmLlHhVvCcSsQqTtAaZz0-9.,\s-]", "", d)
        assert not bad, f"{name}: unsupported path command(s) {bad!r}"


def lit(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


out = [
    "// GENERATED from apps/macos/IconKit/icons.json by IconKit/gen-iconset.py —",
    "// edit the kit json, then regenerate; do not hand-edit. See CCIcon.swift for",
    "// the format and the DesignKit README for the workflow.",
    "",
    "enum CCIconSet {",
    "    /// Kit icon name → SVG-subset markup on a 24 × 24 grid.",
    "    static let icons: [String: String] = [",
]
for name in sorted(icons):
    out.append(f"        {lit(name)}: {lit(' '.join(icons[name].split()))},")
out += ["    ]", "", "    /// SF Symbol name a call site asks for → kit icon name.", "    static let aliases: [String: String] = ["]
for sf in sorted(aliases):
    out.append(f"        {lit(sf)}: {lit(aliases[sf])},")
out += ["    ]", "}", ""]
open(dst, "w").write("\n".join(out))
print(f"{len(icons)} icons, {len(aliases)} aliases → {os.path.relpath(dst)}")
