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
| `StudioUI/` | app, StudioLab | the studio's UIKit surfaces: the stage, the editor (`Editor/`, 4b), the touch timeline (`Timeline/`, 4c), the inspector (`Inspector/`, 4d — see below) |
| `StudioVectors/` | none (script-built) | the iOS runner for `ios-vectors.sh` — never in a shipping target |
| `StudioUI/Features/` | app, StudioLab | the editor's four features (Studio 4e) — see "Editor features" below |

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
| `CCPadView` | 2D drag pad: recessed well + floating knob (Studio 4d) | `init(title:)`, `onTouch(phase, point)` (raw touches; the host maps them), `setKnob(_:animated:)` (springs unless dragging), `knobAreaInset`, `showsKnob`, `contentLayer` (host drawing), `onNudge` + `accessibilityValueProvider` (adjustable, up/down actions), `probePress(at:)` |
| `CCIconRail` | icon + label switcher, vertical rail or horizontal strip, one gliding chip (Studio 4d) | `init(items:selectedIndex:axis:trailing:)`, `axis`, `onSelect`, `onTrailing` (a plain key, never selected), `setSelectedIndex(_:animated:)`; `probeChipLayer`, `probeTap` |

Additive since 4d: `CCSelect.overrideTitle` (shown in place of the choice — "Custom" while a
freeform value supersedes the list) and `CCSlider.keepsOffStepValues` (a pushed model value
between stops stays as it is, the Mac slider's rule, so landing on the nearest stop still writes).

## Studio inspector (4d)

`StudioUI/Inspector/StudioInspectorController` — all nine of the Mac's inspector panes, built
from the SHARED specs in `../macos/CaptureCat/Studio/Editor/Inspector/` (titles, ranges, steps,
readouts, the fields each control writes with its side rules, show/hide rules, pad math). The
Mac panes are built from the same specs, so neither front end can drift: the Mac
`--inspector-values-test` and the iOS `--inspector` gate replay ONE script and are held to ONE
frozen transcript (`StudioHarness/InspectorValuesGoldens`).

- iPad (regular width): a side column in the editor's `inspectorContainer` — pane | rail.
- iPhone (compact): a bottom sheet docked on that container — grabber, rail strip, pane; drag
  or tap the grabber to raise it to the header.
- Selection drives the pane (`InspectorTabFollower`, the Mac shell's rule). State comes in
  through ONE observation loop over the shown pane, goes out through the specs' writes.
- Undo: every edit is one step (`InspectorEditSession`: snapshot at the press, field-level
  restore at undo; `smoothCursor`/`autoHideCursor` — which ProjectSettings' decoder forces off on
  every load — are restored directly).
- Feature keys only call closures, wired by 4e/4f at merge: `onTranscribe`, `onAutoZoom`,
  `onRemoveBackground` (also called when a Cutout/Pop-out look is picked, like the Mac's
  ensureMask), `onRecordVoiceOver`, `onShowHistory`; `transcription` feeds the Subtitles status.

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

## Editor features (Studio 4e)

Each feature is a house `CCAlert` sheet (docked on compact width) with a plain
entry point; the engine behind it is the Mac's, in `../macos/CaptureCat/Studio/`.
The inspector panes (4d) call these from their `onRecordVoiceOver`,
`onTranscribe`, `onAutoZoom` and `onRemoveBackground` closures.

| Feature | Entry point | Shared engine | Undo |
|---|---|---|---|
| Voice-over | `StudioVoiceOver.present(from:project:undoManager:transport:)` — `transport` is the editor's `StudioPlaybackController` (the take starts at its playhead and plays the recording); `StudioVoiceOver.session` is the live take the timeline's VOICE row reads | `VoiceOverSession` + `VoiceOverRecorder` (iOS mic through `Studio/Platform/VoiceOverMic`: a `.playAndRecord` session for the take) | "Record Voice Over" |
| Transcription | `StudioTranscription.present(from:project:undoManager:)` | `TranscriptionService` — WhisperKit `base.en` 0.15.0, the Mac's model and options (the model downloads once into Application Support, then loads offline) | "Generate Subtitles" |
| Auto Zoom | `StudioAutoZoom.present(from:project:undoManager:)`; `StudioAutoZoom.availability(for:)` | `AutoZoomApplier.applyAsEdit` (the Mac timeline's command) | "Auto Zoom" |
| Background removal | `StudioBackgroundRemoval.present(from:project:undoManager:)`; `cameraMask(for:)` feeds the editor stage | `CameraSegmentation` + `CameraSegmenter` (Vision) → `camera-mask.ccmask`; drawn by the shared compositor and exporter | "Background: …" |

Auto Zoom needs Mac capture data (`cursor.json`), so it explains instead of
generating for iPhone and web takes. Vision's person segmentation has no
runtime in the iOS Simulator ("E5RT is not supported") — on a device it runs
as on the Mac. In the Simulator WhisperKit runs on the CPU only: the iOS 27
Simulator transcribes like the Mac (same words; a few word boundaries move
by ≤ 0.14 s), the iOS 26.2 Simulator mostly returns nothing
(`StudioLab --whisper-probe`).

## Cursor art

The studio draws the Mac's cursors. Arrow, White Arrow, Dot and Ring are vector art drawn
by the same paths on both platforms (`Studio/Platform/CursorArt.swift`; the Dot and Ring
build AppKit's own oval, not `UIBezierPath(ovalIn:)`, whose curves differ). The Hand is
macOS's `NSCursor.pointingHand` bitmap (32 × 32 pt, hotspot 13, 8; a 32 px and a 64 px
rep), and iOS has no system cursors, so the app and StudioLab bundle the Mac's own
rasters of it: `StudioResources/Cursors/hand@{1,2}x.rgba`, the premultiplied RGBA8
bytes `CaptureCat --web-cursor-sprites` writes (the web editor ships the same bytes),
added by `gen-xcodeproj.py`. `CursorArt` draws them the way NSImage does (the 32 px rep up
to 32 px, the 64 px rep above, high-quality interpolation), so every exported pixel grid
matches the Mac byte for byte (`ios-vectors.sh`'s cursor-raster check;
`ios-export-parity.sh` fixture `06-cursor-hand-physics`). If the Mac's cursor ever
changes, regenerate them from `--web-cursor-sprites` (the check fails until you do).
Every style is byte-identical to the Mac at every grid that check tries but one: the
arrows at 21 × 29 px (raster scale ≈ 1.03), where the Mac's NSImage draw lands about a
row lower — reported, not gated, and open.

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
    apps/ios/scripts/ios-vectors.sh         # the Mac's golden vectors run INSIDE the iOS Simulator vs the Mac's output (exact / ≤1e-12; known iOS differences listed) + every cursor raster vs the Mac's --web-cursor-sprites, byte for byte
    apps/ios/scripts/kit-gallery.sh         # the studio controls, every state, both themes, iPhone + iPad: PNGs, structure, behaviour, motion SEQUENCES mid-flight (+ injected-snap self-test)
    apps/ios/scripts/ios-inspector.sh       # the inspector: every control of the 9 panes vs the Mac's frozen transcript, one undo step per edit, touch targets, VoiceOver, Dynamic Type, re-theme, column/sheet layout, motion SEQUENCES (+ injected-snap self-test)
    apps/ios/scripts/ios-history.sh         # History (Studio 4f): rows, compare, preview, restore, Merge Review vs the Mac's --history-transcript, line for line; motion sequences; INJECT= must FAIL
    apps/ios/scripts/ios-editor-resize.sh   # iPhone Duo fold / unfold: the real editor resized live between the outer (compact) and inner (regular) displays mid-playback — layout per size class, regions inside and clear, History style, project / selection / undo / playback kept; then a crease (top to bottom, then side to side) through FoldingDisplay's seam: stage + transport on one side, timeline over inspector on the other, nothing and no title on the crease (+ injected ignores-size-class / ignores-crease must FAIL)
    # StudioLab --fold-probe                # logs what UIKit reports on the running display: size classes, safe area, verticalBarEdge + bar regions, reserved regions (run on the iPhone Duo simulator)
    apps/ios/scripts/ios-features.sh        # voice-over, transcription, Auto Zoom, background removal vs the Mac (CaptureCat --features-reference): entries, mix, blocks, subtitles, mask, cutout frames; progress SEQUENCES mid-flight (+ --inject self-tests). WHISPER_BASE=<dir> (model + tokenizer) for transcription; run it on an iOS 27 simulator — the iOS 26.2 Simulator's CPU path decodes base.en to nothing
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
