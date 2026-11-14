# CaptureCat Studio on iOS/iPadOS — plan

Status: **approved 2026-11-14** — the phased plan and all six Phase 0 recommendations
(`docs/ios-studio-phase0.md` §5). Phase 0 done; Phase 1 in progress (see Progress).

## Progress

Every Phase 1 slice must leave `apps/macos/scripts/render-baseline.sh compare` IDENTICAL
against a snapshot of the pre-change commit, and pass `run-gates.sh` plus the extra gates
(§ Proof). `apps/ios/scripts/studio-canary.sh` typechecks the extracted set for iOS.

| Slice | What | Proof |
|---|---|---|
| 1a | Pure edit math out of AppKit files (voice/video track math + commits, `VideoSliceMath`, `KeystrokeRecording`, `CursorRecording.load`); exporter + Auto Zoom read recordings through the models; import swaps | baseline identical; 14 + 10 gates pass |
| 1b-i | `Studio/Platform/` seam layer; `Models/` + `Extensions/` compile without AppKit | baseline identical; canary PASS (35 files) |
| 1b-ii | renderers + exporter through Platform (`PlatformText`, `PlatformCGColor`, `PlatformImageIO`, `PlatformFonts`, `MenuBarArt`, `CursorArt`, …); frozen fonts table (decision 5, `--font-table-test`) | baseline identical; 15 + 10 gates pass; canary PASS (80 files) |
| 1c–1g | compositor core/host split, hit math, timeline edits, `git mv` into `Studio/`, iOS target builds it | — |

Audio is the one category with run-to-run noise (AVFoundation's mix, Phase 0 §1). One 1b-ii
snapshot put `a4-muted-dense` at 1.38e-5 from base; the same binary rerun 4× gave 5.96e-8 every
time, and a regenerated audio category compared identical. If an audio fixture ever goes over,
rerun it (`ONLY=web-audio`) before concluding anything — and never raise the tolerance.

iOS-side approximations so far (not parity-gated until Phase 2/3): the Hand cursor uses the
drawn arrow; menu-bar calibrated colours become sRGB; images decode through ImageIO without EXIF
rotation; non-curated font families use UIKit's weight matching; system hue defaults are UIKit's.

The Mac target builds with member import visibility: a file that doesn't import AppKit
can't name `NSColor.white` or `.semibold` at all, so every AppKit member access lives in
`Studio/Platform/`, whose macOS branch is the exact expression the code used before.

Goal: the full Mac editor ("studio") on iPhone and iPad — every feature — at
preview ↔ export parity with the Mac. Constraint from CLAUDE.md: preview must equal
export and math is never forked, so the iOS studio must render through **the same
code** as the Mac (models, shared math, CoreImage exporter, CoreAnimation compositor),
not a reimplementation. UIKit only on iOS (never SwiftUI), house kit, no system glass.

## Decisions for the owner

1. **Approve the phased plan** (below). Phase 0 and the first Phase 1 PRs can start
   immediately; nothing in them touches files the in-flight Mac work (cloud library,
   iPhone over Wi-Fi) is editing.
2. **Studio requires iOS 26** (the companion app stays iOS 18+; the studio is gated with
   `#available`). Buys: one CIDropShadow path, `BGContinuedProcessingTask` with GPU for
   background export, SpeechAnalyzer as an option.
3. **Reference canvas.** The exporter scales every point-sized setting (padding,
   corners, shadow, cursor, annotation/subtitle sizes) by
   `outputSize / project.previewCanvasSize` (`VideoExporter.swift:348-360`). On a ~370 pt
   iPhone stage a 48 pt padding is ~13% of the frame vs ~6% on a ~760 pt Mac stage — an
   iPhone preview and export would both differ from the Mac's. iOS will render at a fixed
   virtual reference canvas and magnify (the Mac's own "preview zoom is pure
   magnification" rule). **Decide:** also persist an optional `referenceCanvasSize` in
   project.json so Mac, web, iOS and headless exports always agree? (A Mac behavior
   change — its own approval.)
4. **Motion blur + camera-look dissolve.** iOS CoreAnimation ignores `CALayer.filters` /
   `compositingFilter`, which the compositor uses (CIMotionBlur on `zoomGroup`,
   CIAdditionCompositing for camera-look cross-dissolves). Options: composite the camera
   stack in the existing per-frame CI pass; show an exporter-rendered still when paused/
   scrubbing; or a documented parity exception during playback. Phase 0 measures the
   delta first.

## Shape of the solution

- A **shared source folder** `apps/macos/CaptureCat/Studio/` compiled by both projects
  (inside the Mac's synchronized root → no Mac pbxproj change; added to the iOS App target
  only by `apps/ios/scripts/gen-xcodeproj.py`). Not a SwiftPM package yet: a package needs
  `public` on ~1,500 declarations and has to recreate the default-MainActor isolation
  settings exactly; promote later once the API is stable.
- ~26k lines of Mac code form the studio core: ~95 files move with an import swap,
  ~28 need platform seams (big three: exporter 4.2k, compositor 3.7k, interaction view
  1.3k lines), ~215 stay Mac-only (AppKit UI, capture, MCP, Sparkle, harness drivers).
- One seam layer, `Studio/Platform/` — the only place with `#if canImport(AppKit)`:
  `PlatformColor/Font/Image`, `PlatformText` (NSGraphicsContext vs UIGraphicsPushContext +
  CTM flip), `LayerContents` (Mac keeps `NSImage(cgImage:size:)` — load-bearing for flipped
  views), `PlatformImageIO`, `SystemColorDefaults` (iOS uses sRGB literals captured on the
  Mac by a new vector unit), `CursorArt` (iOS bundles the byte-exact rasters
  `--web-cursor-sprites` already produces — the Hand cursor is a macOS system bitmap),
  `SymbolImage`, `StudioChromeTheme`.
- The compositor splits into `PreviewCompositorCore` (layers, render, caches; takes canvas
  size + raster scale) and ~100-line NSView / UIView hosts. `PreviewInteractionView`'s hit
  math becomes pure `PreviewHitMath`; mouse vs touch front ends stay per platform.
- Shared math that today lives inside AppKit view files is split out first
  (`VoiceTrackEditMath`, `VideoSliceMath`/`VideoTrackCommits`, `KeystrokeEvent`,
  `CursorRecording.load`, ~1,950 lines of edit ops from `TimelineViewController`).
- Sync is shared too: `CloudProjectSync` (If-Match saves, push/pull/clone),
  `CloudProjectMerge` + `ProjectHistory` three-way merge, `CloudHistoryClient` — with an
  iOS transport. Caveat: the Mac Codable drops unknown keys on save; iOS will merge its
  model onto the raw document to stay lossless.

## Proof of zero Mac behavior change

`apps/macos/scripts/render-baseline.sh snapshot|compare` captures, byte/pixel-exact:
`--web-vectors` output, `--web-parity-fixtures` pre-encode frames
(`CAPTURECAT_EXPORT_FRAME_TAP`), camera paths (`CAPTURECAT_DUMP_CAMERA`),
`--web-cursor-sprites`, `--web-audio-fixtures`, and the `--preview-parity` / `--raster-golden`
artifacts. Same source in the same module ⇒ any diff means behavior changed — stop and
investigate; never refreeze to go green. Plus the full `run-gates.sh` and the gates outside
it on every PR, and `--export-bench` within ±5%.

## Phases

| Phase | What | Size | Risk |
|---|---|---|---|
| 0 | Baseline harness; iOS spikes: IOSurface layer contents at 60 fps, HEVC 3456×2234 / 5120×2880 decode, 4K export memory at pipeline depths 2–8, motion blur/dissolve without CA filters vs goldens, fonts, WhisperKit, background GPU export, reference-canvas size | 1–2 wk | low |
| 1 | Studio core extraction, **Mac only, zero behavior change**: math split-outs, Platform layer, compositor core/host split, hit math, timeline edits (+ `--timeline-edits-test` frozen from current code first), `git mv` into `Studio/`, iOS compiles it (`--ios-vectors` exact / ≤1e-12) | 3–4 wk | medium-high |
| 2 | iOS preview: UIView host, CADisplayLink/ProMotion, virtual canvas, `--ios-preview-parity` against the Mac's frozen goldens in the real window chain, with mid-flight motion asserts and injected-defect proofs | 2–3 wk | high |
| 3 | On-device export: memory/thermal tuning, background export, Photos/Files, GIF/PNG; `--ios-export-parity` over the Mac's 23 parity fixtures, `--ios-cursor-export-parity`, `--ios-preview-export-parity`, device bench | 2–3 wk | medium-high |
| 4 | iOS editor UI: shell, stage, transport, timeline (all lanes; long-press for right-click, tap for hover, pinch zoom), all 9 inspector panes, on-canvas editing + Pencil ink, voice-over, transcription, auto-zoom, background removal, history + merge review; plus the UIKit kit components the companion lacks (slider, chips, toggle, color picker, dialog, …) | 10–14 wk | medium (volume) |
| 5 | Local projects + sync on iOS (shared CloudProjectSync/merge, media path re-pointing, inbox takes become studio projects), `--ios-cloud-sync-test` | 3–4 wk, overlaps 4 | medium |
| 6 | Hardening: device matrix, accessibility, App Store | 2–3 wk | — |

Rough total: **5–7 months** of focused work. Each phase lands on its own; Phase 2 can ship
as a read-only "Preview project" screen on TestFlight.

## Features that need Mac capture data

iPhone-recorded projects have no `cursor.json` / keystrokes: cursor, ripple, click/key
sounds, follow-cursor zoom, shortcut overlay and Auto Zoom stay inert for them (as for web
takes today); zoom blocks use a manual focal point; Tap annotations stand in for touches.
Mac projects opened on iOS render all of it (pure math). macOS wallpapers aren't available
on iOS (uploaded wallpapers travel as project media).

## iOS-specific concerns

- **Memory/thermal:** depth-8 4K BGRA pipeline alone ≈ 265 MB → `ExportTuning` (depth 3
  on ≤6 GB, 5 on 8 GB+, 2 at `.serious`; `os_proc_available_memory()` preflight; 1080p30
  default on iPhone). If 5K HEVC won't decode on the minimum device, edit proxies are needed
  (a cross-team decision).
- **Fonts:** some curated families are absent or differ on iOS (Impact, SF variants) →
  `--ios-font-report` + an in-app warning.
- **Storage:** project.json holds absolute file URLs; iOS container paths change on
  reinstall → re-point to `projectDirectory/lastPathComponent` on load (the clone rule).
- **Type collisions** with the companion app to resolve before Phase 1g: `CloudRemoteFile`,
  `CaptureCatAPI` (companion `JSONValue` already renamed to `LosslessJSON`).

## First three PRs

1. **Render baseline harness** (scripts only) — two snapshots of `main` compare identical.
2. **Studio seams I — pure math out of AppKit files** (video/voice track math + commits,
   KeystrokeEvent, CursorRecording.load, explicit-import swaps). Identical baseline.
3. **Studio seams II — Platform layer; models + renderers compile without AppKit**, with a
   non-shipping iOS `StudioCanary` target proving they build for iOS. Coordinate the
   `Models/` edits with the iPhone-over-Wi-Fi work.

Critical files: `Views/Editor/PreviewCompositor/PreviewCompositorView.swift`,
`Services/VideoExporter.swift`, `Models/ProjectSettings.swift`,
`Views/Editor/TimelineViewController.swift`, `Services/CloudProjectSync.swift`,
`Views/Editor/PreviewCompositor/PreviewParityHarness.swift`, `scripts/run-gates.sh`,
`apps/ios/scripts/gen-xcodeproj.py`.
