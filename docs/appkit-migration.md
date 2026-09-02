# The SwiftUI → AppKit migration

CaptureCat's macOS app is 100% SwiftUI-free as of 2026-08-02.

```
grep -rlE '^import SwiftUI' --include='*.swift' apps/macos/CaptureCat | wc -l   # 0
```

No `NSHostingView`, no `NSHostingController`, no `NSViewRepresentable`, no `ImageRenderer`,
no `View` / `some View` anywhere in the target.

## Why this document exists

Most of the app's renderers were built by writing a CoreGraphics/CoreAnimation twin of a SwiftUI
view and diffing the two, pixel for pixel, until they agreed. That diff was the proof of
correctness — and deleting the SwiftUI side deletes the ability to re-run it.

So the last passing numbers are recorded here, and each gate keeps the strongest reference that
survives the deletion. Nothing below is re-derivable.

## Final SwiftUI-vs-native numbers

Captured on macOS 26.2 immediately before the SwiftUI sources were removed.

### `--preview-parity` — SwiftUI `PreviewView` vs `PreviewCompositorView`

24 states, bar 3.0/255 mean. **PASS**, worst `cursor-pin` at **2.201/255**.

Motion sequences, which assert the spring is genuinely mid-flight rather than settled:

| sequence | value at capture |
|---|---|
| `motion-zoom+0.15` | 1.125 |
| `motion-zoom+0.3` | 1.289 |
| `motion-tilt+0.15` | 2.496 |
| `motion-tilt+0.3` | 5.776 |

These four are unchanged after the migration — the compositor's spring integration is bit-identical.

### `--raster-golden` — SwiftUI rasterisations vs CoreGraphics renderers

45 comparisons, bar 1.0/255 mean. **PASS**. Worst per family:

| family | worst mean | what it proved |
|---|---|---|
| gradients (7) | 0.433 | `BackgroundGradientRenderer` reproduces SwiftUI's Oklab ramp |
| device bezel (6) | 0.433 | `DeviceBezelRenderer` |
| annotations (24) | 0.206 | `AnnotationRenderer`, incl. mid-build/mid-exit effect frames |
| focus chrome (4) | 0.270 | `FocusChromeRenderer` |
| squircle | 1e-5 pt | `ContinuousRoundedRect` vs SwiftUI's `.continuous` corner |
| homography | 0.0 | `TiltMath` vs `ProjectionTransform`, 630 cases |

### Colour picker — SwiftUI `ColorPickerPopover` vs `ColorPickerPopoverView`

Ported and diffed against the original before deleting it: **0.39–0.58/255** across four states,
hosted in a real window on both sides so `.onAppear` actually ran.

## What each gate asserts now

| gate | reference now | strength |
|---|---|---|
| `squircleCheck` | `SquircleReference` — SwiftUI's own bezier element list, frozen | **full** |
| `homographyCheck` | the pre-refactor expression, with `Mat3` replacing `ProjectionTransform` | **full** |
| `gradientRampCheck` | `OklabGradient.sample` directly | **stronger** than before |
| `bezelCheck` / `annotationCheck` / `focusChromeCheck` | `RasterGoldens` fingerprints + blob counts | regression only |
| `--preview-parity` | `PreviewGoldens` fingerprints + blob counts + live mid-flight spring assertions | regression + motion |
| `exporterOrientationCheck` | unchanged — never involved SwiftUI | full |

"Regression only" means: it proves the renderer still does what it did when it was proved correct.
It cannot re-derive correctness. That is the part that died with SwiftUI, and it is why refreezing a
red gate to make it green is destroying evidence rather than fixing a test.

## Things the migration found

- **`--preview-parity` was not reproducible.** It rendered *whichever project the user had edited
  most recently*, so its output changed with the user's data. Harmless while it diffed two live
  renderers in one run; fatal for a frozen reference. It now builds a synthetic project and a
  synthetic video frame.
- **The parity harness was testing the wrong flip context.** It hosted the compositor in an
  `NSHostingView`, which resolved `geometryFlipped=true`; the shipping shell resolves
  `superviewFlipped=true, geometryFlipped=false`. Correct when the preview was SwiftUI-hosted,
  stale once it stopped being. Now asserted against `--editor-shell-shot`.
- **Three implicit animations were lost when the preview moved to CoreAnimation.** `render()` wraps
  everything in `CATransaction.setDisableActions(true)`, which is right for the ~200 layer
  properties that must land exactly, but the SwiftUI preview had animated three of them: the card's
  0.18s ease-out glide between placement anchors, and 0.08s linear bridges on zoom/focal and tilt
  between spring ticks. Dragging the recording snapped between the nine anchors and zoom/tilt
  staircased during playback. Restored in `PreviewCompositorView.interpolate`.
- **`CodableColor` was not round-trip safe.** `init(_ color: Color)` stored `.deviceRGB` components
  while the `nsColor` accessor read them back as `.sRGB`, so a colour picked on a wide-gamut display
  was written in one space and read in another. Every caller now uses the sRGB initialiser.
- **The colour picker's hex readout disagreed with its own swatch.** It composed the colour in sRGB
  but formatted the hex through `NSColor(hue:…)`, which is calibrated RGB. Both are sRGB now.

## Found by the post-migration review

An adversarial review over six lenses caught these; all are fixed unless marked.

Regressions introduced by the timeline port, now fixed:

- `setTimelineScale` and `viewDidLayout` resized the canvas without rebuilding the callbacks, which
  bake the track width in **by value** — the first playhead grab after a zoom or resize jumped to the
  end of the video.
- The zoom-out / Fit buttons and the scale slider were only refreshed from the playback observation
  loop, so after clicking "+" on a paused project they stayed greyed and dead.
- `performKeyEquivalent` matched `.deviceIndependentFlagsMask == .command`, which includes Caps Lock
  — ⌘D and ⌘B silently stopped working with Caps Lock on.
- The slice tool was bound to key **code** 11 rather than the character "b", so it moved with the
  keyboard layout.
- The canvas stored callback closures capturing the controller strongly: opening project after
  project leaked every previous timeline, and because `deinit` never ran, its three `object: nil`
  undo observers accumulated and fanned every edit out to the zombies.
- Closing the editor cancelled the thumbnail/audio/waveform tasks but left their signatures set, so
  reopening never restarted them — the filmstrip stayed blank for the session.
- Disarming the slice tool left the playhead red (the canvas can only self-clear while armed).
- The trash button stayed enabled and red after deselecting.

Regressions in the restored animations, now fixed:

- `interpolate` re-animated from the PRESENTATION value on every render. Since render runs per
  ~16 ms tick, an 80 ms bridge composed into a permanent ~70 ms lag filter — it would have made
  motion feel *worse*, not better. It now only re-animates when the target actually moves.
- The card glided in from the centre on first render, because `lastVideoPlacement` started nil.

Holes in the new frozen gates, now fixed:

- `syntheticVideoFrame` used `NSColor.system*` (which resolve differently under aqua vs darkAqua,
  Δ39/255 against a 2/255 bar) and `NSImage.lockFocus` (which rasterises at the current screen's
  backing scale). The goldens would not have reproduced on another machine. Now an explicit sRGB
  bitmap context with literal colours.
- `HarnessPixels.darkBlobs` tested only `r+g+b < 12`, so fully **transparent** pixels counted as
  black: a bezel render resolved as one blob covering 87 % of the canvas. It now requires alpha too,
  and the phone states resolve the 2 blobs they should.
- The `watermark` state rendered nothing — `Project.watermarkImageURL` resolves next to `videoURL`,
  which the synthetic fixture did not set, so its capture was byte-identical to `flat` and the
  golden asserted the *absence* of a watermark.
- The fingerprint grid was too coarse: two genuinely different states scored exactly 2/255 against a
  bar of 2. Raised from 12×7 to 24×14.

Proven by injection: duplicating the Dynamic Island capsule in the compositor now fails
`--preview-parity` on both arms — blob count 2→3 and fingerprint 64/255.

## Still open — all pre-existing, none caused by this migration

Ordered by how much they hurt.

1. **The subtitle is composited on different sides of the camera transform.** The compositor parents
   `subtitleLayer` to `root` (`PreviewCompositorView.swift:281`), outside tilt and zoom; the exporter
   burns it into the card at `VideoExporter.swift:1242`, *before* the tilt (`:1288`) and zoom
   (`:1296`). With a 2× zoom region the export scales and translates the caption toward the focal
   anchor — a bottom caption can be pushed off-frame — while the preview shows it pinned flat. The
   deleted SwiftUI preview had the same split, so this is old, but it is a direct CLAUDE.md §2
   violation. Decide which side is right and move one.

2. **The exported click ripple is the wrong size.** `VideoExporter.swift:2306` passes
   `settings.clickRippleSize`, both ring widths and the dot radius as raw points into a
   full-resolution context, while every other spatial setting is multiplied by `canvasScale`. On a
   1920-wide export from a ~960 pt preview the ripple is half the relative size it shows in the
   editor, with hairline rings.

3. **`VideoExporter.swift:312-460` holds a forked copy of `PreviewMotionModel`'s spring
   integrator**, including a local `springStep` closure, kept in sync by comment. I diffed them: ω,
   ζ, the 0.85 floor, the `dt > 0.35` snap guard and the target functions all agree today, and
   `CursorSmoother` is a stateless struct so the persistent-vs-fresh instance makes no difference.
   The risk is drift, not a live bug — but `reset()` already diverges: the model re-derives the
   focal at the new zoom in a second pass (`PreviewMotionModel.swift:60-65`), the exporter computes
   it once at `springZoom == 1.0` (`VideoExporter.swift:379-391`).

   Fix in this order: a numeric gate that steps both over identical ticks and asserts every channel
   agrees to 1e-9 at *every* tick, then collapse the exporter onto `PreviewMotionModel`.

4. **Three preview gestures have no implementation.** These went out with `AnnotationOverlay.swift`,
   but that view had already stopped rendering when the CA compositor took over, so they were
   unreachable before this migration deleted the file:
   - freehand **Drawing** capture — nothing in the tree writes `Annotation.drawingStrokes`, so the
     annotation is permanently blank and the inspector reads "0 strokes";
   - body-dragging an **arrow / rectangle / ellipse** moves only `x`/`y`, never
     `arrowEndX`/`arrowEndY`, so the shape deforms instead of translating;
   - the **callout** tail handle is still painted (`AnnotationRenderer.swift:269`) but
     `annotationHandleHit` has no `.callout` case, so the tail is uneditable.

5. **Committing an inspector text field strands the window with no first responder.**
   `InspectorKitExtras.swift:216` calls `makeFirstResponder(nil)`, which makes the *window* the
   responder — so after typing a subtitle value and pressing Return, Space no longer plays.

6. `--raster-golden`'s `exporterOrientationCheck` re-derives the exporter's y-flip inline rather than
   calling into `VideoExporter`, so it verifies its own copy. And no gate anywhere instantiates
   `VideoExporter`: with the SwiftUI arms gone, nothing renders the same state through two
   independent paths. The shared-math types are now the only thing enforcing preview == export.

## Post-migration fixes (2026-08-03)

Two motion regressions reported as "laggy, and the screen→iPhone transition
isn't smooth".

**Zoom/tilt lag.** The port carried over the SwiftUI preview's
`.animation(.linear(0.08), value: [zoom, focalX, focalY])` and the matching one
on the tilt effect. In SwiftUI those bridged a spring that stepped on a coarse
observer tick. The compositor already renders once per tick and the spring
produces a new target every tick, so an 80ms animation toward each new target
never completes — every frame restarts it from the current presentation value.
That composes into a first-order lag filter, tau ~= 70ms, felt as floaty
behind-the-cursor motion. Removed; the spring is the smoothing. Measured render
cost is 2.80ms/frame (Debug, `CAPTURECAT_RENDER_TIMING=1 CaptureCat --preview-parity`).

**Device-segment transition.** Live §2 violation, now closed. The exporter
dipped with a Gaussian in timeline time centred ON the cut, so the content swap
happened at minimum opacity. The preview ran a *different* curve: a wall-clock
piecewise ease-in-out started by a 60Hz `Timer` when the active segment index
changed — so it began AT the cut (swap played at full opacity, fully visible
pop), turned around through a derivative corner at the trough, and beat against
vsync. Both sides now call `DeviceSegmentDip`, evaluated per frame off the
timeline clock, so no timer or edge-detection state is involved and scrubbing
agrees with export.

Guarded by the `DIP` block in `--preview-parity`, which asserts the curve
properties a settled frame cannot see: peak at the boundary, non-zero dip
*before* it, symmetry, zero slope and continuous curvature through the peak, and
decay between segments. Injecting the old ramp fails 5 of its 6 checks
(`peak-at-boundary phase=0.0000`).

**Device-segment lag (the big one).** Device segments ran at roughly 19fps while
screen segments stayed fluid. The preview cached exactly one chrome raster,
keyed on the tilt angles quantized to 0.1 degrees, so a tilt spring sweeping 14
degrees discarded and redrew the whole chrome ~140 times — measured at 45ms per
frame of pure bezel work during animation.

The angles never belonged in that key. `drawSideButtons` and `drawBody` take no
angles at all, and tilt enters `drawSideSlab` purely as a TRANSLATION of the
same pixels — the exporter already knew this ("bakes this once with offset .zero
and translates it per frame"). The preview now splits the chrome into three
separately-cached rasters (buttons / slab / body) and applies tilt as a layer
move, so a tilt animation rasterizes nothing at all.

Cost of the split: compositing three 8-bit premultiplied sub-rasters in CA
rather than one flat CG context costs 1-2/255 against the device goldens (was
0/255). Under the 2/255 bar, so the goldens were NOT refrozen and the original
evidence stands. Cropping the raster to the bezel's own bounds was also tried
and rejected — it looks free but clips the drop shadow's tail, which the
full-canvas transparency layer gave room for (measured 1-2/255 on its own).

Guarded by `TILT-RASTERS` in `--preview-parity`, which counts rasters across 40
animating frames and requires zero, paired with `TILT-MOTION` pinning the spring
mid-flight so a frozen tilt cannot pass it trivially. Restoring the angles to
the cache key fails it at 114 rasters / 1803ms.

### Still open
The double render per drag event (`requestRender` renders synchronously and the
observation then renders again) is pre-existing and was left alone rather than
risk freezing playback mid-drag; revisit with `CAPTURECAT_RENDER_TIMING` if lag
persists.
