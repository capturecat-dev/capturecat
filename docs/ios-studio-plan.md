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
| 2c (part 2) | **Font smoothing off** in every studio text raster (owner decision, below) — `PlatformText.disableFontSmoothing` at each text draw, both platforms; the recipe vectors' oracle and replays follow it | iOS parity: **every text state passes** — `menubar-dark` 3 → 2/255, `subtitle-glow` 4 → 2, `annotations` 8 → 2, `annotation-pop-enter` 6 → 2; 26/31 pass, 5 open (below). Mac (deliberate change): render-baseline moves ONLY text — 4 preview-parity text states, 12 `anno-*` raster entries, 17 web-parity frames in the annotation + subtitle scenes; every other output identical (motion-tilt and a4 audio = the known base variants); web-vectors 140/140 identical to base (`rasterMatchesReal` holds); goldens refrozen for those text entries only; 17 + 12 gates; font table 328/328; iOS vectors 0 failing |
| 2d (part 1) | **Mac preview motion blur now equals the export** — three preview ≠ export bugs, each measured with CARenderer and fixed in `PreviewCompositorCore.renderMotionBlur`: (1) CA applies a layer filter in the layer's LOCAL space, so the zoom group's own scale magnified the smear (radius-10 ramp: 32 px at 1×, 65 px at 2×) → radius ÷ the group's scale; (2) CA reads the filter angle in the layer's geometry, which is Y-down here → MotionBlurMath's angle goes in un-negated (negated, diagonal motion smeared vertically mirrored); (3) CA filters run in LINEAR light, the exporter's working space is the source's gamma-encoded one → the blur is wrapped in linear→sRGB / sRGB→linear tone curves (CA + chain == CI non-linear, Δ 0.000). New gates: `MOTIONBLUR-PIXELS` (the preview's blurred frame vs the exporter's CIMotionBlur of the same frame crisp, interior of the card; each old defect injected and caught) and frozen states `motionblur-pan-t0.10/0.20/0.30` (fast pan at Rapid speed, blur strength 1) and `look-dissolve-mid` (half-way bubble → cutout) — no gate covered blur or a mid-dissolve before | Mac: preview vs exporter blur mean 0.347/255, 0.00% px > 8 (defects: local space 5.15 / 24%, mirrored 1.48 / 4.4%, linear 4.35 / 18%); every existing output identical (render-baseline vs 2c: only the 16 new captures); new states frozen from the corrected renderer (added, nothing refrozen); 17 + 12 gates; core selftest; canary. iOS (before 2d parts 2–3): blur states 27–46/255, pixel check 37% px > 8, `look-dissolve-mid` 21/255 — the targets |
| 2d (part 2) | **iOS paused/scrubbing motion blur — the exporter's exact blur** (owner-approved playback exception: none while playing). iOS CA ignores layer filters, so `PreviewStageMotionBlur` (StudioUI): a TWIN core (same code and input, the main core's motion state copied in via `PreviewMotionModel.copyState` / `adoptMotionState`, so nothing steps) renders ONLY the zoom group off-screen in the same window; `drawHierarchy` reads it back through the render server; Core Image blurs it in the exporter's convention (screen-space radius, along the motion, gamma-encoded values, clamped at the frame edge) and the core shows the still in the zoom group's place (`showZoomGroupStill`). CPU `CALayer.render(in:)` was measured first and rejected: it drops layer shadows (the card's whole drop shadow) and 3D transforms (`tilt-20`: 22% px > 8) — StudioLab `--renderin-probe`. The twin gets no players: iOS renders posters today; when iOS playback lands it must be handed the displayed frame. Blur states are now scored inside a frame-edge band of 2 × the largest radius: the exporter crops the zoomed card to the frame and CLAMPS before blurring (iOS too), CA filters cannot clamp, so the Mac preview's smear at the frame edge pulls in content from beyond it (a CA limit, recorded; those 3 states re-frozen with the band) | iOS: `motionblur-pan` 1 / 2 / 1 /255, MOTIONBLUR-PIXELS mean 0.296/255, 0.00% px > 8, every injected defect caught; iOS parity 6 open = the dissolve (2) + edge anti-aliasing (4). Mac: preview-parity PASS (blur states 0/255), 17 gates; iOS app builds; core selftest; canary |
| 2d (part 3) | **iOS camera-look cross-dissolve — the approved CI pass.** The twin from part 2 becomes `PreviewStageTwin` (StudioUI) with two products: the blurred zoom group, and the dissolve — each visible look stack rendered ALONE by the twin (`cameraStackIsolation`: full weight, plain compositing, camera group untransformed and opaque), read back through the render server, then summed with the exporter's own `VideoExporter.scaleStack` + CIAdditionCompositing on gamma-encoded values; the core shows the sum inside `cameraStacksGroup` in place of the stacks (`hostCameraDissolve`), so the main tree still applies tilt, opacity, mask and the tag. Both stills are now render INPUTS: the twin runs before the main render (adopting the main core's pre-step state, so it steps identically) and the core applies them at the end of its own render, in one transaction — no read-back commit can show a frame without them. `PreviewStageView.render` is not re-entrant (a read-back's layout pass re-rendered mid-render and the nested pass left the twin in the wrong isolation — the outer read-back captured the cutout twice). Plain-bubble path only: stacking layouts (camera inside the card) keep the plain composite | iOS: `crossfade-true-dissolve` 1.000 of 3617 px == lerp (bar 0.95; source-over 0.661), `look-dissolve-mid` 2/255, `crossfade-midflight` PASS; blur states unchanged (1 / 2 / 1); **iOS parity 4 open, all edge anti-aliasing at 3/255**. Mac: every output identical to part 1, 17 + 12 gates |
| 2e | **Reference canvas — persisted `referenceCanvasSize`** (owner-approved Mac behaviour change, decision 3). A project carries a reference BOX (`Project.referenceCanvasSize`, `[w, h]` in project.json, written only when set) and `ReferenceCanvas` (Studio/Models) is the one place that turns it into a canvas: the largest one of the output's aspect inside the box (the editor's own `AspectRatio.letterboxRect`). New projects (recordings, web captures) get the Mac's default editor card, **803×330** → 586.7×330 at 16:9, 185.6×330 at 9:16, 330×330 at 1:1, 770×330 at 21:9 — at every aspect the canvas the default window always showed; duplicates copy it; decode and inits never stamp one, so every pre-2e project renders and exports exactly as before. The exporter scales point-sized settings against it (`Project.exportReferenceCanvas`), so the editor's window size and headless/MCP no longer change an export. The Mac editor draws the reference canvas and the stage's NSScrollView MAGNIFIES it to the card (`ZoomScrollView.fitMagnification`; the user's zoom multiplies, 100% = fit, pinch range scales with it; rasters at backing × fit, `PreviewCompositorView.canvasMagnification`) — at the default window the fit is exactly 1. iOS: `PreviewStageView.virtualCanvas(for:sourceSize:)` gives the same canvas (pre-2e projects get the default box's) | New `--reference-canvas-test` (in run-gates), 55 checks: model (a pre-2e project decodes with no reference and re-encodes to the same JSON — the key is written only when set; unusable boxes fall back); the canvas at 8 aspects, no drift; REAL exports through the lossless frame tap — a reference project's frame is byte-identical from the default window, 1400×800, full screen and headless, AND byte-identical to the pre-2e default-window export, a pre-2e project still follows the window (15.4/255), the reference ignored (injected) is caught; the REAL editor shell at 1100×700 / 1400×800 / 1600×950 — compositor bounds 586.7×330 at all three, filling the card's letterbox, preview canvas == the exporter's canvas, fit 1.000 / 1.303 / 1.755, rasters at backing × fit, user zoom 200% = 2 × fit, 9:16 re-letterboxes, a hit-tested click on the drawn label selects it (the unmagnified point does not), and the card's pixels scaled to one size match across windows (0.76–0.79/255) while a pre-2e project's do not (9.3–16.5). Mac: render-baseline IDENTICAL vs 2d (no fixture has a reference — pre-2e behaviour unchanged); 18 + 12 gates; iOS app builds; core selftest; ios-vectors; canary; iOS parity unchanged (the same 4 edge-AA states at 3/255) |
| 2e (web) | **The web editor adopts the reference canvas.** `core/math/referenceCanvas.ts` ports `ReferenceCanvas` (box, canvas, sanitizer, `exportReferenceCanvas`, the creation stamp); the model reads and writes `referenceCanvasSize` exactly like Swift (`dCGSize` — `[w, h]`, extra elements ignored, any other shape throws; written only when set). The engine carries the sanitized box on `RenderProject`: the STAGE lays a reference project out on its reference canvas at the output's aspect whatever the slot size or zoom (`previewReferenceCanvas` in `engine/layout.ts`, used by `engine.ts reference()`), and the EXPORTER resolves it at each file's own aspect (`export/exporter.ts`) — so stage, export, agents (webmcp) and hit-testing (which reads the engine's `canvasScale`) all follow. Creation sites stamp the box like the Mac's: the web recorder's publish, and the iOS app's `ProjectTemplate.json` (regenerated; its lock test applies the stamp); `newProject()` stays `Project.init` and never stamps | New Mac vector units `referenceCanvas` (220 cases: box, canvas at 14 aspects × 6 boxes, sanitizer, exporter canvas over box × editor canvas × output) and `referenceCanvasDecode` (15 shapes the key can hold — Swift accepts `[w,h]`, `[w,h,x]`, null; rejects the rest); the web matches all of them. `engine/referenceCanvas.test.ts`: the card's normalized geometry is the same at three stage sizes and within 1 px of the export's (headless identical); a pre-2e project still follows the stage. REAL engine in a browser (`/editor-lab`, WebGPU): a reference project's frame scaled to one size matches across 640×360 / 1024×576 / 1600×900 stages (0.49 / 0.83/255) while a pre-2e project's do not (14.7 / 21.6), and preview == export pixel-identical (max 0) at the magnified 1600×900 stage. Web: typecheck clean, 110/110 test files (1,167 tests) incl. parity fixtures regenerated from this build; iOS core selftest (template round-trips byte-for-byte). Mac: web-vectors 140/140 identical + the 2 new units; no product code changed |
| 3a | **iOS export parity.** `StudioHarness/ExportParityHarness` (shared by the Mac app and StudioLab) re-exports the Mac's 23 render-parity fixtures (`--web-parity-fixtures`: the exact `project.json`, media, the Mac exporter's LOSSLESS pre-encode taps and camera path) with THIS platform's `VideoExporter` — same frame tap, same camera dump — and scores frames (mean ≤ 0.5/255 and ≤ 0.1% px > 8) and camera paths (exact). Mac `--export-parity`, StudioLab `--ios-export-parity`, `apps/ios/scripts/ios-export-parity.sh` (Mac control, Mac YUV reference, iOS gate, iOS production path). Two cross-platform causes found and handled: (1) **Core Image context defaults differ by platform** — `highQualityDownsample` is on by default on macOS and off on iOS, so every downscaled source (camera video and person mask in the bubble, the motion-blurred cursor raster) resampled differently; the exporter now pins the Mac's values (`VideoExporter.platformPinnedContextOptions`: high-quality downsample, RGBAh) — a Mac no-op, proven by the control staying byte-identical; (2) **VideoToolbox's YUV→BGRA conversion differs** between the Mac and the iOS Simulator while the decoder's 4:2:0 planes are bit-identical (`--decode-probe`: YUV byte-identical; BGRA 84% of pixels ±1, chroma edges up to 91/255) — outside CaptureCat's code, so the gate compares on equal pixels: a test-only seam (`CAPTURECAT_EXPORT_SOURCE_YUV`, `VideoExporter.sourcePixelFormat`) decodes to raw 4:2:0 and converts in Core Image on BOTH sides; the normal VideoToolbox path is reported, not gated (the Simulator's converter is not a device's) | Mac control (`--export-parity`): 23/23 fixtures, all 222 frames byte-identical, all 23 camera paths exact — also with the context options pinned; `--inject padding` (every project +2 pt) fails 23/23 on the Mac and 22/22 frames on iOS. **iOS gate (equal pixels): 22/23 fixtures, 214/222 frames, every camera path exact**; 184 frames within ±1/255; the one failing fixture is the hand cursor (owner decision, below). Before the context pin: 21/23 (the motion-blurred cursor and the camera-mask edges at up to 89/255). iOS production path (reported): 32/222 frames inside the strict bar, mean 0.38/255 averaged, worst 0.83 — the Simulator's VideoToolbox conversion. Mac: render-baseline vs 2e identical (web-vectors 140/140 + the 2 units added in 2e web; 2 preview-parity motion-tilt frames at the known 1 px / 1/255 jitter); 18 + 12 gates; iOS app builds; core selftest; ios-vectors 108 units, 0 failing (the 2e reference-canvas unit was missing from its build list — fixed); canary; iOS preview parity unchanged (31/35, the same 4 edge-AA states) |
| 3b | **Export tuning.** `ExportTuning` (Studio/Services, pure) decides the exporter's pipeline depth; `PlatformExportResources` (Studio/Platform) supplies `os_proc_available_memory()` on iOS (nil on the Mac). The Mac keeps its depth 8. iOS, from Phase 0's 4K phone measurements (throughput flat across depths 2–8 at 44.5–44.9 fps; peak 757 / 1,112 / 1,272 / 1,590 MB): depth 3 only when its estimated footprint is at most half the available memory, depth 2 otherwise and under thermal pressure (serious/critical — also re-checked every 30 frames mid-export), and a clear `ExportError.insufficientMemory` before the first frame when even depth 2's estimate exceeds what the app may allocate, instead of being terminated mid-export. Footprint model: the 4K measurements, scaled by output pixels above a 479 MB fixed part (the straight-line intercept — over-estimates smaller outputs). The export log names the depth and why; `CAPTURECAT_EXPORT_PIPELINE_DEPTH` overrides it for harnesses | New `--export-tuning-test` (in run-gates): 37 checks — Mac 8 for every memory/thermal input and never adjusted; the model reproduces Phase 0's four 4K figures exactly; the iOS table (4K 3.4 GB → 3, 2.1 GB → 2, hot → 2, unknown → 2, 600 MB → refused; 1080p 1.5 GB → 3, 1 GB → 2); depth never falls as memory grows (4K and 1080p sweeps); mid-export heat 3 → 2 on iOS only. **Depth never changes pixels:** Mac export-parity control 23/23 byte-identical at depth 8 AND forced depth 2; iOS taps byte-identical at depth 8 (3a run) and its tuned depth 2. Mac: export render-baseline vs 3a identical (web-parity 246/246, camera-paths 23/23; web-audio = the known `a4` two-state 1.38e-5 mode), 19 gates, the export extras (cursor-export-parity, export-geometry, export-formats, camera-settle, cameralayout, still-image, keystroke-overlay); iOS app builds; canary |
| 3c | **iOS preview ↔ iOS export** (`--ios-preview-export-parity`, with `--ios-cursor-export-parity`'s measurement folded in). `StudioHarness/PreviewExportParityHarness` (shared) takes the Mac-dumped preview fixture, turns its poster into a still movie and shows the PREVIEW the frame the EXPORTER decodes from it (read the exporter's way), so both sides start from identical pixels; per case it steps the preview at the export's frame times to t = 3 s (springs integrate as the exporter's camera path does — the logged camera states agree), captures it at 2× its canvas and compares the exporter's lossless tap at exactly that 2× size (canvasScale 2): whole frame, plus the cursor's drawn box (on vs off, the Mac `--cursor-export-parity` measurement). Seven cases: base, rounded-shadow, zoom-held, tilt, annotations, inverted cursor 1×, hand cursor 2×. The Mac has never gated whole-frame preview vs export, so the whole-frame bar is RELATIVE: iOS must be no worse than the Mac control (`--preview-export-parity`, the Mac's PreviewCompositorView in a real NSWindow — its CARenderer capture scaled to 2× with a sublayer transform) on the same case; cursor boxes absolute (≤ 4 px size, ≤ 6 px position). `apps/ios/scripts/ios-preview-export-parity.sh` | iOS: **7/7 cases pass against the Mac control**, each within 0.04/255 of the Mac's own preview↔export numbers (base 1.49 vs 1.45, rounded-shadow 2.04 vs 2.01, zoom-held 6.97 vs 7.01, tilt 1.41 vs 1.37, annotations 3.26 vs 3.23), camera states identical to the Mac's (zoom-held: preview z 1.58154 / exporter 1.57977 on both), cursor boxes within 1–3 px (Mac: exact). Injected export-only defect (+4 pt padding, 1.3× cursor): 6/7 cases fail (whole frame 4.8–7.1/255, cursor boxes +3–7 px; zoom-held hides the padding at 1.6×). No product code changed (harness, runner flag, StudioLab mode). Regression: 19 gates, `--cursor-export-parity`, iOS app build, canary |

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

**Font smoothing — OFF in every studio text raster (owner decision, 2c part 2).** macOS bitmap
contexts smooth fonts by default: glyph stems are dilated (~28% more coverage for the same
string), so every Mac text raster (preview AND export) was drawn heavier than the glyphs' true
weight — and iOS has no font smoothing to match it with. Owner: "Yes, turn it off".
`PlatformText.disableFontSmoothing(_:)` now runs at the top of every studio text raster —
`PlatformText.draw`, `AppKitTextLayout.draw`, the subtitle pill, the camera tag, the menu bar art,
the keystroke pill and the annotation renderer — on both platforms. Editor UI text and the MCP
server's renders keep AppKit's default. A deliberate output change on the Mac: the frozen
references were refrozen for the text entries ONLY (PreviewGoldens `menubar-dark`,
`subtitle-glow`, `annotations`, `annotation-pop-enter`; RasterGoldens' 12 `anno-*` text
entries), after reading the artifacts (same glyph positions, thinner stems) — every non-text
state stayed at its old score. `--font-table-test`'s AppKit reference raster turns smoothing off
too, so it compares the studio's actual text.

**Card-edge anti-aliasing (measured 2c part 2).** `flat` (2/255, passes) and `hidden-crop`
(3/255) miss on iOS by the same mechanism: the core sets `allowsEdgeAntialiasing` on the card
groups (for warped borders under tilt), and iOS's render server feathers the card's
axis-aligned edges by ~½ px (outermost row/column ~60% covered) where the Mac's CARenderer
leaves them crisp; the poster's internal tile seams resample within ±8. Geometry is identical
(`videoRect` matches). `cursor-pin` (3/255) is the same class: its >24/255 pixels sit on the
warped grid line and ripple edge under zoom + tilt, not in the cursor art (byte-identical
rasters). Tried in 2d and rejected: edge AA only while the card is non-rectilinear made
iOS match, but changed 25 Mac captures — the Mac's renderer antialiases FRACTIONAL (zoomed)
edges when the flag is on, so turning it off would alias the card's edges through every zoom.
The two render servers simply treat the flag differently (iOS feathers integer edges too;
neither setting reproduces the Mac on iOS). Left as a measured difference of ≤ 3/255.

**Open on `ios-preview-parity` (after 2d):** 4 of 35 fingerprint states — `hidden-crop`,
`cursor-pin`, `motion-zoom-t0.05/0.30`, each 3/255 against a bar of 2 — all card-edge
anti-aliasing (above). Every structural, motion, camera-look, motion-blur and dissolve check
passes on iOS.

**Twin limits (2d), for the playback phase:** the twin gets no players (iOS renders posters
today) — when iOS playback lands it must be handed the DISPLAYED video and camera frames; the
dissolve reads back each stack per rendered frame (paused, scrubbing and the 0.45 s
transition), so playback with live camera video wants a per-frame-cheap path (a read-back
cache keyed on stack geometry, or the exporter's camera compositing extracted into a shared
type); stacking layouts keep the plain composite. **Correction (2d):** the
`motion-zoom` states run with motion blur OFF (the setting's default) — their iOS miss was never
blur; it is the same edge anti-aliasing on a moving card. 2b–2c attributed it to blur. Text is
closed: metrics and layout (2c part 1) + no font smoothing (2c part 2).

**Reference canvas (2e) — choices and limits.** The persisted value is a BOX, not a canvas: a
canvas stored at the project's creation aspect would make a 16:10 recording switched to 16:9
lay out differently from a 16:9 recording (528×297 vs 586.7×330). With the box every project at a
given aspect lays out identically, and aspect changes never write back (no drift). The exporter's
old `min(out.w/canvas.w, out.h/canvas.h)` is only uniform for a canvas of the output's aspect, so
the box is letterboxed first — never divided directly. On-canvas chrome (selection outlines,
handles, the in-place editor) is magnified with the canvas, exactly as the user's zoom already did
and as the iOS stage does; at the default window nothing moves. The **web editor** follows it too
(2e web): the model types the key, the engine's stage and exporter use it, and web recordings and
iOS captures are created with the box; project merge is generic JSON, so the key merges like any
other. Web parity fixtures stay headless pre-2e projects (scale 1), so they are unchanged; the
scale-≠-1 math the reference canvas exercises is locked by the existing layout / cursor / overlay
vectors, which take the editor canvas as an input. The **released Mac app
(1.5.2) drops unknown keys** when it saves, so a 2e-created project opened and edited there loses
its reference (and falls back to the window rule) until a release includes 2e.

## Phase 3 — on-device export (slices)

- **3a — export parity** (done): the Mac's render-parity fixtures re-exported by the iOS `VideoExporter`, scored
  against the Mac's lossless taps and camera paths (row above).
- **3b — export tuning**: pipeline depth by device memory (Phase 0: depth 2 = the same 4K throughput at 757 MB, depth
  8 = 1.59 GB), an `os_proc_available_memory()` preflight, thermal state → depth 2; the export sheet's iPhone default.
- **3c — `--ios-cursor-export-parity` and `--ios-preview-export-parity`**: the iOS preview against the iOS export, in
  StudioLab's real window (the Mac's `--cursor-export-parity` pattern).
- **3d — delivery**: Photos / Files / share sheet, GIF and PNG on iOS, "keep the app open" export UI.
- **On a device (needs Mike's phone)**: verify frames exported in the background without `.gpu` (Phase 0 §3.8), the
  VideoToolbox production path against the Mac (the Simulator's converter is not a device's), and a device bench.

**Preview ↔ export on the Mac — found by 3c (Mac behaviour, NOT changed; owner decision).** The new gate is the first to compare whole preview frames with exported frames, and the Mac control shows three pre-existing preview ≠ export differences (iOS reproduces each exactly, through the shared core): (1) **zoom anchor** — the exporter zooms about the focal point on the actual card (`staticLayout.videoRect`, inside the padding); the preview zooms about the focal point of the video fitted to the FULL canvas without padding (`PreviewCompositorCore.zoomAnchor` → `previewVideoRect`, a SwiftUI-era "replicate PreviewView exactly"; the padded `videoRect` is passed in but unused). Centred focal points coincide; off-centre ones drift by (zoom − 1) × (focal − 0.5) × (unpadded − padded size): at 1.6× and focal (0.35, 0.40) the prediction is (27, 11) px at 2×, measured (26, 12) — whole frame 7.0/255. (2) **text annotation size** — the preview draws the label visibly larger than the export (annotations case 3.2/255, max 255). (3) **corner dots** on a rectangle annotation in the preview only. Cursor geometry matches exactly (all three cursor cases, Δ 0), and base / shadow / tilt sit at 1.4–2.0/255 (CA vs CI resampling of the video and the shadow). Fixing (1)–(3) changes what Mac users see in the preview (and the frozen zoom / annotation goldens), so it waits for the owner.

**Export parity (3a) — results and limits.** iOS renders what the Mac renders: with sources on equal pixels the
iOS export matches the Mac's on 22 of 23 fixtures (214 of 222 frames; 184 frames within ±1/255, the rest ≤ 2 except
the Ring cursor's outline anti-aliasing — 57 px, ≤ 26/255, 0.003% — inside the bar), and every camera path is
identical (zoom, focal, card offset, tilt: all 23, exact). The one failing fixture is `06-cursor-hand-physics`: iOS has
no `NSCursor.pointingHand` and draws the arrow instead (**owner decision pending**: bundle the Mac's hand rasters as
the web editor already does — `apps/web/public/editor/cursors/hand@{1,2,3}x.png`, produced by `--web-cursor-sprites`).
On the normal VideoToolbox path the Simulator's YUV→RGB conversion moves the video area by ±1 and its chroma edges by
up to ~45/255 after compositing (mean 0.38/255 averaged over 222 frames, worst 0.83, ≤ 0.96% px > 8) — the same size
as the Mac's own Core Image vs VideoToolbox conversion difference (0.58 / 0.79%). Whether the device converter
matches the Mac's is a device measurement. If it does not, the fix is to convert YUV→RGB in our own code on every
platform, preview AND export (a Mac output change: owner approval).

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
   change — its own approval.) **Approved; done in 2e** (Mac, iOS and web).
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
