#!/bin/sh
# Compile the iOS sync core's pure-Foundation files for macOS and run the
# headless checks in Tests/CoreSelfTest.swift. Usage: apps/ios/scripts/core-selftest.sh [out-dir]
set -e
IOS="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-${TMPDIR:-/tmp}/capturecat-ios-core-selftest}"
mkdir -p "$OUT"
cat > "$OUT/main.swift" < "$IOS/Tests/CoreSelfTest.swift"
xcrun --sdk macosx swiftc -swift-version 5 -default-isolation MainActor -target arm64-apple-macos14.0 -O \
  "$OUT/main.swift" \
  "$IOS/Core/LosslessJSON.swift" "$IOS/Core/ProjectDocument.swift" "$IOS/Core/TakeInbox.swift" \
  "$IOS/Core/AppGroup.swift" "$IOS/Core/SessionStore.swift" "$IOS/Core/SharedKeychain.swift" \
  "$IOS/Core/CaptureCatAPI.swift" "$IOS/Core/APIClient.swift" "$IOS/Core/Models.swift" \
  "$IOS/Core/CloudUploader.swift" "$IOS/Core/MediaImport.swift" \
  "$IOS/../macos/CaptureCat/Services/StillMovieWriter.swift" \
  "$IOS/../macos/CaptureCat/Shared/WirelessDeviceProtocol.swift" \
  -o "$OUT/core-selftest"
# Bundle.main of a command-line tool is its own directory: put the template there.
cp "$IOS/Core/ProjectTemplate.json" "$OUT/"
"$OUT/core-selftest" "$IOS" "$IOS/Tests/Fixtures"
