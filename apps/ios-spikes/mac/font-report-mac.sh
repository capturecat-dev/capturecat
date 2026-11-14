#!/usr/bin/env bash
set -euo pipefail
# Spike (e), Mac side: FontCatalog's own resolution on this Mac → results/fonts-mac.json
# Compiles the REAL apps/macos/CaptureCat/Services/FontCatalog.swift (AppKit only, self-contained).
cd "$(dirname "$0")"
tools="${TMPDIR:-/tmp}/ccspikes-tools/font-report"; mkdir -p "$tools"
cp font-report-main.swift "$tools/main.swift"   # top-level code must live in main.swift
xcrun swiftc -O -o "$tools/font-report" ../../macos/CaptureCat/Services/FontCatalog.swift "$tools/main.swift"
"$tools/font-report" > ../results/fonts-mac.json
echo "wrote results/fonts-mac.json"
