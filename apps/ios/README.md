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
- **Continue on Mac** — from a project, ask the Mac on the same account and Wi-Fi to open it
  in its editor (message `openProject` on the presence link, acked with control
  `openedProject`); the Mac clones it if it's cloud-only and comes to the front. The detail
  screen also advertises Handoff (`so.capturecat.openProject`, falling back to the web
  editor). No Mac answering → offer the web editor.

Copy that talks about this device ("this iPhone", "Record on iPhone") follows the device
(`ThisDevice.noun`); content badges ("iPhone" on a phone-shaped capture) describe the
recording.

## Layout

| Folder | Target(s) | What |
|---|---|---|
| `App/` | app | screens, sign-in (`Auth/`), capture tab + upload center + push routing (`Capture/`) |
| `Kit/` | app, share, StudioLab | UIKit design kit (extension-safe) — see "Kit" below |
| `Core/` | app, both extensions | API client, session/keychain, lossless project.json, uploads, inbox, Mac link client |
| `Broadcast/` | broadcast extension | ReplayKit: stream to Mac (H.264) or record locally |
| `ShareExtension/` | share extension | "Save to CaptureCat" |
| `../macos/CaptureCat/Shared/` | all three | files that must build for macOS AND iOS — the Wi-Fi wire protocol |
| `../macos/CaptureCat/Studio/` | app | the studio core shared with the Mac app — models, renderers, exporter, compositor, timeline edits (docs/ios-studio-plan.md) |
| a few Mac files by reference | see `scripts/gen-xcodeproj.py` | `OAuthPKCE`, `LoopbackAuthServer`, `CCIconSet`; the extensions also take `StillMovieWriter` |
| `StudioVectors/` | none (script-built) | the iOS runner for `ios-vectors.sh` — never in a shipping target |

The Xcode project is generated — never hand-edit it:

    python3 apps/ios/scripts/gen-xcodeproj.py

Bundle ids: `so.capturecat.ios`, `.broadcast`, `.share`; App Group `group.so.capturecat.ios`
(also the keychain access group the extensions read the session and link key from).

## Kit

The UIKit port of the Mac's CCKit (`apps/macos/CaptureCat/Views/Shared/DesignKit/README.md`):
same tokens (`CCTheme`), material (`CCMaterial`: raised / raisedMatte / recessed), motion
(`CCMotion`: growth lands on the bounce, only the pushed edge moves; press tints in place)
and icon kit (`CCIcon`, which traps on a name it can't draw). Every control is touch-first
(44 pt targets), speaks to VoiceOver, follows Dynamic Type and re-themes live.

The studio's editor controls (Studio 4a — the Mac's InspectorKit at touch scale):

| Component | What | API |
|---|---|---|
| `CCSlider` | label-inside pill slider, ticks, readout | `init(title:value:range:step:format:)`, `value` / `setValue(_:animated:)`, `step` (≤ 10 stops → ticks are the stops), `detents` (soft stops, continuous), `format` (human units only), `symbol`, `haptics`, `onChange`, `onCommit` (once per gesture); relative drag, tap jumps |
| `CCChip` / `CCChipGroup` | choice chips, flow layout | `CCChipGroup(items:mode: .single/.multiple, selected:)`, `Item(_:symbol:isEnabled:)`, `allowsEmpty`, `selection` / `selectedIndex`, `setSelection(_:)`, `onChange(Set<Int>)`; compresses padding before it wraps; growth bounces |
| `CCToggle` / `CCToggleRow` | switch; label + detail + switch row | `CCToggle(isOn:onChange:)`, `setOn(_:animated:)`, `userToggle()`; press stretches the thumb toward its destination. `CCToggleRow(title:detail:isOn:onChange:)` — the whole row is the target and one VoiceOver element |
| `CCControlRow` | label (+ detail) left, any control right | `CCControlRow(title:detail:control:)`; lends its title to an unlabeled control |
| `CCStepper` | −/+ keys around a rolling-digit well | `init(value:min:max:step:)`, `format`, `value`, `onChange`, `onCommit`; hold-to-repeat accelerates, keys dim at bounds; one adjustable element |
| `CCRollingLabel` | odometer text | `setText(_:direction: .up/.down/.none)`, `alignment`, `fontProvider` |
| `CCColorWell` | inspector color swatch → picker | `CCColorWell(title:color:supportsOpacity:)`, `color`, `presets`, `onChange`, `onCommit` (when the picker closes) |
| `CCColorPickerView` / `CCColorPicker` | swatches + SV field, hue, opacity, hex | `CCColorPickerView(color:supportsOpacity:presets:)`, `adopt(_:)`, `commitHex(_:)`, `onChange`; `CCColorPicker.present(from:source:title:color:…)` — bottom sheet on compact width, anchored card on regular. sRGB throughout (`UIColor.ccSRGB(hue:…)`, `ccHSBA`, `ccHex`) |
| `CCAlert` | dialog / confirmation sheet | `addButton(_:role:action:)` (async actions show busy, throws → inline error), `symbol` + `tone: .destructive`, `presentation: .sheet` (docked to the bottom on compact width, grows upward, swipe to cancel); `CCAlert.confirm(…destructive:symbol:presentation:…)` |
| `CCHaptics` | step / detent feedback | `selection()`, `detent()`, `prepare()`, `light()`; DEBUG `probeLog` |

## History (Studio 4f)

`StudioUI/History/` — the Mac's History pane on touch, over an on-device history
(`Studio/ProjectHistory/LocalProjectHistory`: `<project>/.history/`, every editor save
recorded by the API's own version rules). Entry point:
`StudioHistory.present(from:project:undoManager:)` (sheet on iPhone, side panel over the
inspector column on iPad); the editor calls `StudioHistory.attach(_:)` on load. Rows,
words, menus, Compare groups and the three-way merge are the Mac's shared code
(`Studio/ProjectHistory/`). Preview puts a version READ-ONLY on the live stage
(`EditorViewController.stageProjectOverride`); Restore and merges are one undo step.
Cloud history and sync (Phase 5) plug in behind `ProjectHistoryService` and hand Merge
Review (`StudioHistory.reviewMerge`) a `ProjectMergeSession`.

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
    apps/ios/scripts/mac-interop.sh         # real iOS sender ↔ the REAL Mac receiver (WirelessServer): presence, requestBroadcast, one phone, keyframe-on-record, 70/70 frames, clock mapping, rotation, openProject ack
    apps/ios/scripts/studio-canary.sh       # Studio/ typechecks for iOS on its own (fast)
    apps/ios/scripts/ios-vectors.sh         # the Mac's golden vectors run INSIDE the iOS Simulator vs the Mac's output (exact / ≤1e-12; known iOS differences listed)
    apps/ios/scripts/kit-gallery.sh         # the studio controls, every state, both themes, iPhone + iPad: PNGs, structure, behaviour, motion SEQUENCES mid-flight (+ injected-snap self-test)
    apps/ios/scripts/ios-history.sh         # History (Studio 4f): rows, compare, preview, restore, Merge Review vs the Mac's --history-transcript, line for line; motion sequences; INJECT= must FAIL
    cd apps/web && npx vitest run src/editor/core/vectors/iosProjectTemplate.test.ts

`upload-e2e.sh` never talks to the real API: `wrangler dev` binds R2 to the production
bucket, so upload tests run against the local mock instead.

Driving the app in the Simulator by hand:

    python3 apps/ios/Tests/mock_api.py 8791                 # the API (sign-in works; test-only /__seed, /__share, /__rename, /__bump, /__state)
    apps/ios/scripts/fake-mac.sh <out-dir> [--request-after S] # a stand-in Mac (the real WirelessServer): presence, Continue on Mac, requestBroadcast

Debug builds can point at another API: launch with `-apiBaseURL http://127.0.0.1:8799`
(https or loopback only); the app copies it to the App Group so the extensions follow.

## Server side

`/api/wireless/link[/rotate]`, `/api/devices[...]`, push via APNs — `apps/api/README.md`
("iPhone over Wi-Fi"). Deploy order: migration 0042 before the API; APNs secrets
(`APNS_KEY`, `APNS_KEY_ID`, `APNS_TEAM_ID`) are owner-only.
