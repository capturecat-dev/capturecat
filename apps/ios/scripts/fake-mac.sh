#!/bin/sh
# Run a stand-in Mac (the real WirelessServer) for Simulator testing.
# Usage: apps/ios/scripts/fake-mac.sh [out-dir] [--request-after SECONDS]
set -e
IOS="$(cd "$(dirname "$0")/.." && pwd)"
MAC="$IOS/../macos/CaptureCat"
OUT="${1:-${TMPDIR:-/tmp}/capturecat-fake-mac}"; shift || true
mkdir -p "$OUT"
cp "$IOS/Tests/FakeMac.swift" "$OUT/main.swift"
xcrun --sdk macosx swiftc -swift-version 5 -default-isolation MainActor -target arm64-apple-macos14.0 \
  "$OUT/main.swift" "$IOS/Tests/MacInteropShims.swift" \
  "$MAC/Services/Wireless/WirelessServer.swift" "$MAC/Services/Wireless/WirelessVideoDecoder.swift" \
  "$MAC/Shared/WirelessDeviceProtocol.swift" -o "$OUT/fake-mac" 2>/dev/null
exec "$OUT/fake-mac" "$@"
