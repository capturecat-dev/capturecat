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
| 1c | `PreviewCompositorCore` (AppKit-free; adopts the host's backing layer as its root — same layer tree) + `PreviewCompositorView` NSView host; `StudioChromeTheme`, `LayerContents`, `SymbolImage` | every output byte-identical to a base-binary variant (below); 15 + 12 gates pass; canary PASS (90 files) |
| 1d | `PreviewHitMath` (targets, drag mapping, clamps, inline-edit geometry — pure) + `PreviewGestureCore` (the press → drag → release cascade) behind `PreviewGestureHost`; `PreviewInteractionView` is the mouse front end (NSCursor, marquee, notch hover, undo manager, NSTextField). New `--preview-gesture-test`: 58 gestures through the real compositor, transcript frozen from the 1c view BEFORE the extraction (commit a4f6f50) | gesture transcript byte-identical; flagged baseline outputs byte-identical to base-binary variants; 16 + 12 gates pass; canary PASS (92 files); gate power proven (a 4 pt pill-width change fails it) |
| 1e | `TimelineEditing` protocol extension (`TimelineEdits.swift`): every lane add/delete/commit/split/speed/duplicate, slot search and undo registration, moved verbatim out of `TimelineViewController` (−1,360 lines), plus the FOCUS/EFFECTS/chip routing the canvas callbacks did inline; seams `timelineEditRefused()` (NSSound) and `timelineEditNeedsCameraMask()`; `EditorShellSelection` in its own file. New `--timeline-edits-test`: 96 edits through the real controller (lane callbacks, ⌘D/⌘B/Delete, FOCUS menu rows, menu actions) + the whole undo stack unwound, frozen BEFORE the move (commit b2039ce) | timeline transcript byte-identical; the one flagged baseline frame byte-identical to a base-binary variant; 17 + 12 gates pass; canary PASS (101 files, incl. Auto Zoom + Motion generators); gate power proven (an undo that appends instead of re-inserting fails it) |
| 1f | `git mv` of the 86 shared files into `Studio/` (`Models/`, `Extensions/`, `Services/`, `Editor/`, `Compositor/`, beside `Platform/`) — all R100; iOS project / scripts follow the paths; canary typechecks `Studio/` ALONE (103 files → self-contained); comment + doc path references updated separately (vector `notes` strings left as frozen output) | debug-dylib symbol table identical but for 2 equivalent closure manglings (one `setActionName` expression; same overload, same text); flagged baseline audio byte-identical to a base-binary variant; 17 + 12 gates; iOS app builds; core selftest PASS |
| 1g | iOS App target compiles `Studio/` (synchronized folder via `gen-xcodeproj.py`; Studio builds at the companion's iOS 18 floor with zero errors, so the studio screens can be `#available`-gated rather than split into a framework); no type collisions — the predicted `CloudRemoteFile`/`CaptureCatAPI` clashes live in the sync core, which arrives in Phase 5. `apps/ios/scripts/ios-vectors.sh`: the Mac's own `--web-vectors` unit files built for the iOS Simulator and run inside it (`simctl spawn`), compared with the Mac's output (see below) | iOS app builds + launches; 106/140 units replay on iOS — 92 byte-identical, 4 equal but for −0.0/0.0, 1 equal but for ±1 GPU samples, 9 known iOS differences, 0 failing; gate power proven (a 1e-7 easing change fails it); Mac vectors byte-identical after the harness's import guards; render-baseline: only the known motion-tilt frame, byte-identical to a base-binary variant; 17 + 12 gates; core selftest; canary PASS |
| **Phase 1** | **done** — the studio core is one shared folder, compiled by both apps, Mac behaviour proven unchanged slice by slice | |
| 2a | iOS compositor host `PreviewStageView` (apps/ios/StudioUI/, shared by the app and the harness): the core renders at a VIRTUAL canvas and the view magnifies it to fit (screen scale × magnification for rasters); **StudioLab**, a non-shipping iOS harness app (gen-xcodeproj, own scheme) hosting it in a real UIWindow; `--preview-parity-fixtures` dumps the Mac's parity fixture as data (StudioHarness/ParityFixtureFile — Mac-resolved project JSON + the Mac's own rasters) so iOS inputs are the Mac's bit for bit. Core fix: the video poster went through `LayerContents` (iOS layers ignore a UIImage) | smoke render on iOS 27: card, shadow, background, cursor and ripple at the Mac's geometry (videoRect identical); orientation matches the Mac's real window (the Mac gate's CARenderer captures are Y-flipped — iOS captures flip into that row order to score); Mac preview-parity + gesture/timeline freezes + shell shot pass |
| 2b | `apps/ios/scripts/ios-preview-parity.sh`: the Mac's preview-parity SCRIPT (moved to StudioHarness/ with HarnessPixels, RasterFingerprint, PreviewGoldens; AppKit setup/rasters/recorder checks behind `#if canImport(AppKit)`) runs in StudioLab against the shipping PreviewStageView in a real UIWindow (iPad, 720×405 at magnification 1) and scores against the Mac's frozen goldens with the Mac's bar; iOS captures go through `drawHierarchy`, flipped into CARenderer's row order. Mid-script `makeFixtureProject()` returns the Mac's dumped construction on iOS | iOS: **22/31 fingerprint states pass**, every mid-flight motion assert, every camera-style and camera-look structural probe incl. injected-defect self-tests; 9 open (below). Mac: render-baseline identical but for the two known base variants (byte-identical), 17 + 12 gates |
| 2c (part 1) | Text on the Mac's rules: `AppKitTextLayout` (Studio/Platform) holds the one frozen row that differs — the Mac system designs' metrics (ascent 1980/2048, descent 432/2048; iOS reports 1950/494; named families and New York are identical) — and AppKit's layout rules, measured: line box `round(a)+round(d)`, wrapped `boundingRect` n·(that + leading), `draw(in:)` first baseline `round(a)` below the top and lines `round(a)+round(d)` apart (no leading). PlatformText's iOS branches, the subtitle pill, camera tag, keystroke pill and the menu bar's iOS twin measure and draw through it. Two iOS-only bugs fixed: the menu bar never drew (a platform image assigned as raw layer contents — same class as 2a's poster) and the preview cursor was a stretched fixed-scale raster (iOS now redraws the vector art at the layer's pixel grid, as CA does with the Mac's NSImage) | `--font-table-test` + 328 text-layout cases on the Mac: the frozen row == live macOS fonts, and the emulation == AppKit exactly (size, wrapped bounds, pixel-identical draws) across 8 font configs × 6 sizes × left/centre; iOS parity `menubar-dark` 60 → 3/255, `subtitle-glow` 5 → 4. Mac: render-baseline identical but for base variants (audio within 1.5e-7 of base runs), 17 + 12 gates |

**Two-state noise in the base code itself (measured 2026-11-14).** The pre-Phase-1 base binary,
compared against its own earlier snapshot, gives `a4-muted-dense/mix.f32` either ~6e-8 or exactly
1.38e-5 (3 of 3 base reruns hit the 1.38e-5 mode), and `motion-tilt-t0.60-ca.png` either 2 px or a
3 px variant (bbox x106–282 y45–160; 1 of 3 base reruns). Phase 0's five runs missed both variants,
so `compare` can report DIFFERS on an unchanged binary. When it does: rerun the category on the new
build AND on a fresh base build (`ONLY=preview-parity,web-audio`), and accept only if every new
output is byte-identical (audio: ≤1e-6) to an output the base binary also produces — that is how
1b-ii, 1c, 1d, 1e, 1f and 1g were cleared. Never raise a tolerance or refreeze to make it pass.

iOS-side approximations so far (not parity-gated until Phase 2/3): the Hand cursor uses the
drawn arrow; menu-bar calibrated colours become sRGB; images decode through ImageIO without EXIF
rotation; non-curated font families use UIKit's weight matching; system hue defaults are UIKit's.

**Font smoothing (found in 2c, owner decision):** macOS bitmap contexts smooth fonts by default —
glyph stems are dilated (~28% more coverage for the same string); nothing in the studio turns it
off, so every Mac text raster (preview AND export) is drawn heavier than the glyphs' true weight.
iOS has no font smoothing. With metrics and placement now the Mac's, this is what the remaining
text states (`annotations` 8/255, `annotation-pop-enter` 6, `subtitle-glow` 4, menu bar 3) measure.

**Open on `ios-preview-parity` (2b → 2c/2d):** text (`subtitle-glow` 5/255, `annotations` 8,
`annotation-pop-enter` 5, `menubar-dark` 60, `hidden-crop` 3 — iOS system-font vertical metrics,
and the menu bar's glyphs/colours) → 2c: freeze ascent/descent/leading in the shared font table
(Mac reads back its live values, provably unchanged); `cursor-pin` 3 → 2c: bundle the Mac's cursor
rasters; `motion-zoom-t0.05/0.30` 3 (iOS CA ignores the CIMotionBlur filter) and
`crossfade-true-dissolve` (iOS ignores additive compositing) → 2d: the approved CI passes.

**Measured by `ios-vectors.sh` (1g)** — what the same Studio code produces differently on iOS:
- **System font metrics.** iOS resolves the system face to SF UI (`.SFUI-*`), the Mac to
  `.AppleSystemUIFont*`; ascent/descent/line height differ by ~0.1–1.7 pt, so annotation labels
  and the keystroke pill lay out slightly differently (5 units). iOS preview and iOS export
  still agree with each other; Mac ↔ iOS cross-device parity for text does not, yet. Options for
  Phase 2: ship the font table's metrics, or pin text annotations to a bundled face.
- **Cursor art.** iOS rasterizes its own 20×28 arrow; the Mac uses the real 32×32 system cursor
  (hotspot 13,8), so cursor size/hotspot differ (4 units). The plan's fix stands: bundle the
  Mac's byte-exact rasters (`--web-cursor-sprites`) as iOS `CursorArt`.
- **GPU samples.** Core Image GPU renders differ by ±1 in 8-bit samples (1 unit) — the
  tolerance class Phase 2/3's pixel gates need anyway.
- **Signed zero.** CoreGraphics returns −0.0 where the Mac returns 0.0 in a few region/frame
  rects (4 units; equal values).

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
  math becomes pure `PreviewHitMath`, and its press → drag → release cascade becomes
  `PreviewGestureCore` (done in 1d), so a tap and a click grab the same target and write the
  same values; only the event front ends (mouse + NSCursor + NSTextField vs touch + UIKit
  editor) stay per platform, behind `PreviewGestureHost`.
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
- **Type collisions** with the companion app: none in Phase 1 (checked by the 1g app build).
  `CloudRemoteFile` and `CaptureCatAPI` will collide when the sync core joins `Studio/` in
  Phase 5 — resolve them then (companion `JSONValue` already renamed to `LosslessJSON`).

## First three PRs

1. **Render baseline harness** (scripts only) — two snapshots of `main` compare identical.
2. **Studio seams I — pure math out of AppKit files** (video/voice track math + commits,
   KeystrokeEvent, CursorRecording.load, explicit-import swaps). Identical baseline.
3. **Studio seams II — Platform layer; models + renderers compile without AppKit**, with a
   non-shipping iOS `StudioCanary` target proving they build for iOS. Coordinate the
   `Models/` edits with the iPhone-over-Wi-Fi work.

Critical files: `Views/Editor/PreviewCompositor/PreviewCompositorView.swift`,
`Studio/Services/VideoExporter.swift`, `Studio/Models/ProjectSettings.swift`,
`Views/Editor/TimelineViewController.swift`, `Services/CloudProjectSync.swift`,
`Views/Editor/PreviewCompositor/PreviewParityHarness.swift`, `scripts/run-gates.sh`,
`apps/ios/scripts/gen-xcodeproj.py`.
