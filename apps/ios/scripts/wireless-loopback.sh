#!/bin/sh
# iPhone-over-Wi-Fi on one Mac: the real iOS sender code ↔ a test listener
# playing the Mac's side (TLS-PSK, Bonjour, framing, H.264 decode).
# Usage: apps/ios/scripts/wireless-loopback.sh [out-dir]
set -e
IOS="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-${TMPDIR:-/tmp}/capturecat-wireless-loopback}"
mkdir -p "$OUT"
cp "$IOS/Tests/WirelessLoopback.swift" "$OUT/main.swift"
xcrun --sdk macosx swiftc -swift-version 5 -default-isolation MainActor -target arm64-apple-macos14.0 \
  "$OUT/main.swift" \
  "$IOS/Core/WirelessMacClient.swift" \
  "$IOS/Broadcast/StreamEncoder.swift" \
  "$IOS/../macos/CaptureCat/Shared/WirelessDeviceProtocol.swift" \
  -o "$OUT/wireless-loopback"
"$OUT/wireless-loopback"
