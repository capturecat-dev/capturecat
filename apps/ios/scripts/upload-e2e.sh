#!/bin/sh
# iOS client ↔ local mock API, end to end (sign-in, publish, conflict, download).
# Never talks to production. Usage: apps/ios/scripts/upload-e2e.sh [work-dir]
set -e
IOS="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-${TMPDIR:-/tmp}/capturecat-ios-upload-e2e}"
mkdir -p "$OUT"
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
python3 "$IOS/Tests/mock_api.py" "$PORT" 2>"$OUT/mock.log" &
MOCK=$!
trap 'kill $MOCK 2>/dev/null' EXIT
cp "$IOS/Tests/UploadE2E.swift" "$OUT/main.swift"
xcrun --sdk macosx swiftc -swift-version 5 -default-isolation MainActor -target arm64-apple-macos14.0 \
  "$OUT/main.swift" \
  "$IOS/Core/LosslessJSON.swift" "$IOS/Core/ProjectDocument.swift" "$IOS/Core/TakeInbox.swift" \
  "$IOS/Core/AppGroup.swift" "$IOS/Core/SessionStore.swift" "$IOS/Core/SharedKeychain.swift" \
  "$IOS/Core/CaptureCatAPI.swift" "$IOS/Core/APIClient.swift" "$IOS/Core/Models.swift" \
  "$IOS/Core/CloudUploader.swift" "$IOS/Core/MediaImport.swift" \
  "$IOS/../macos/CaptureCat/Studio/Services/StillMovieWriter.swift" \
  "$IOS/../macos/CaptureCat/Services/OAuthPKCE.swift" \
  "$IOS/../macos/CaptureCat/Services/LoopbackAuthServer.swift" \
  "$IOS/Tests/E2EShims.swift" \
  "$IOS/../macos/CaptureCat/Shared/WirelessDeviceProtocol.swift" \
  -o "$OUT/upload-e2e"
cp "$IOS/Core/ProjectTemplate.json" "$OUT/"
"$OUT/upload-e2e" "http://127.0.0.1:$PORT" "$OUT/work"
