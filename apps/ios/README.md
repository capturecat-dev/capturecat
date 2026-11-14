# CaptureCat for iPhone and iPad

Native UIKit app (iOS 18+) that stays in sync with CaptureCat for Mac and the web app
through the same cloud projects, and turns the iPhone into a wireless screen source for
Mac recordings.

Rules are the Mac app's (see the repo's `CLAUDE.md`): **UIKit only, never SwiftUI**; no
system Liquid Glass chrome (no visible UINavigationBar / UITabBar / UIToolbar /
UIAlertController — in-content bars and house sheets instead); the house kit in `Kit/`
(a UIKit port of the Mac's CCKit tokens, materials, motion and icon kit); state reaches
views through `withObservationTracking` loops over `@Observable` stores.

## What it does

- **Library** — cloud projects (from the Mac, the web, or this phone) and shares; play the
  original recording or the shared export; rename (lossless, conflict-safe), open in the web
  editor, delete; share links and comments. Refreshes on open, on foreground, every 30 s
  while visible, and after uploads.
- **iPhone over Wi-Fi** — start a screen broadcast and a Mac on the same account and Wi-Fi
  records it exactly like a cabled iPhone (`.device` segment, bezel). No pairing: devices
  signed in to the same account share a per-account link key (TLS-PSK). With the app open,
  the Mac lists the phone and can ask it to start; with the app closed, the Mac sends a push.
- **Record on iPhone** — the same broadcast extension records locally; the take uploads as a
  cloud project (`recordingSourceKind: "device"`).
- **Screenshots** — "Save to CaptureCat" in the share sheet, or Import in the app: each
  screenshot becomes a still-capture project (the Mac's 8-second still movie), with the
  iPhone bezel on Mac and web.

## Layout

| Folder | Target(s) | What |
|---|---|---|
| `App/` | app | screens, sign-in (`Auth/`), capture tab + upload center + push routing (`Capture/`) |
| `Kit/` | app, share | UIKit design kit (extension-safe) |
| `Core/` | app, both extensions | API client, session/keychain, lossless project.json, uploads, inbox, Mac link client |
| `Broadcast/` | broadcast extension | ReplayKit: stream to Mac (H.264) or record locally |
| `ShareExtension/` | share extension | "Save to CaptureCat" |
| `../macos/CaptureCat/Shared/` | all three | files that must build for macOS AND iOS — the Wi-Fi wire protocol |
| a few Mac files by reference | see `scripts/gen-xcodeproj.py` | `OAuthPKCE`, `LoopbackAuthServer`, `StillMovieWriter`, `CCIconSet` |

The Xcode project is generated — never hand-edit it:

    python3 apps/ios/scripts/gen-xcodeproj.py

Bundle ids: `so.capturecat.ios`, `.broadcast`, `.share`; App Group `group.so.capturecat.ios`
(also the keychain access group the extensions read the session and link key from).

## Contracts it follows

- **Sign-in** = the Mac's flow: loopback (`127.0.0.1`) + PKCE through
  `/api/desktop/authorize?client=ios` → consent page on app.capturecat.so → the listener
  answers `303 capturecat://auth-done`, which closes the ASWebAuthenticationSession. The code
  never travels through the custom scheme.
- **project.json is never modelled here.** `Core/LosslessJSON.swift` keeps key order,
  unknown keys and number text; edits are surgical. New projects come from
  `Core/ProjectTemplate.json`, generated from the web model's `newProject()` and locked by
  `apps/web/src/editor/core/vectors/iosProjectTemplate.test.ts`.
- **Uploads** = the Mac/web push: hash → stage → presigned PUT → finalize → save with
  `If-Match`. A retry of an already-published take is a no-op (never overwrites edits made
  elsewhere since).
- **Wi-Fi wire protocol**: `apps/macos/CaptureCat/Shared/WirelessDeviceProtocol.swift`.

## Gates

    apps/ios/scripts/core-selftest.sh       # lossless JSON, project docs, link-key vector
    apps/ios/scripts/upload-e2e.sh          # sign-in, publish, conflict/rebase, download — vs Tests/mock_api.py
    apps/ios/scripts/wireless-loopback.sh   # real iOS sender ↔ test Mac listener: Bonjour, TLS-PSK, H.264 decode, rotation, wrong key refused
    apps/ios/scripts/mac-interop.sh         # real iOS sender ↔ the REAL Mac receiver (WirelessServer): presence, requestBroadcast, one phone, keyframe-on-record, 70/70 frames, clock mapping, rotation
    cd apps/web && npx vitest run src/editor/core/vectors/iosProjectTemplate.test.ts

`upload-e2e.sh` never talks to the real API: `wrangler dev` binds R2 to the production
bucket, so upload tests run against the local mock instead.

Debug builds can point at another API: launch with `-apiBaseURL http://127.0.0.1:8799`
(https or loopback only); the app copies it to the App Group so the extensions follow.

## Server side

`/api/wireless/link[/rotate]`, `/api/devices[...]`, push via APNs — `apps/api/README.md`
("iPhone over Wi-Fi"). Deploy order: migration 0042 before the API; APNs secrets
(`APNS_KEY`, `APNS_KEY_ID`, `APNS_TEAM_ID`) are owner-only.
