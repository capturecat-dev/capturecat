#!/bin/sh
# The real iOS sender ↔ the real Mac receiver (WirelessServer), on this Mac.
# Usage: apps/ios/scripts/mac-interop.sh [out-dir]
set -e
IOS="$(cd "$(dirname "$0")/.." && pwd)"
MAC="$IOS/../macos/CaptureCat"
OUT="${1:-${TMPDIR:-/tmp}/capturecat-mac-interop}"
mkdir -p "$OUT"
cp "$IOS/Tests/MacInterop.swift" "$OUT/main.swift"
xcrun --sdk macosx swiftc -swift-version 5 -default-isolation MainActor -target arm64-apple-macos14.0 \
  "$OUT/main.swift" "$IOS/Tests/MacInteropShims.swift" \
  "$IOS/Core/WirelessMacClient.swift" "$IOS/Broadcast/StreamEncoder.swift" \
  "$MAC/Services/Wireless/WirelessServer.swift" "$MAC/Services/Wireless/WirelessVideoDecoder.swift" \
  "$MAC/Shared/WirelessDeviceProtocol.swift" \
  -o "$OUT/mac-interop"
"$OUT/mac-interop"
