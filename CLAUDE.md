# CaptureCat — working rules

## 1. AppKit only. No SwiftUI. Ever.

CaptureCat's macOS app is 100% SwiftUI-free (2026-08-02): zero `import SwiftUI`, zero `NSHostingView`,
zero `NSViewRepresentable`, zero `ImageRenderer`. **All UI is AppKit** — `NSView`,
`NSViewController`, `NSWindow`, CoreAnimation layers, CoreGraphics drawing.

Check it in one line:

    grep -rlE '^import SwiftUI' --include='*.swift' apps/macos/CaptureCat | wc -l   # must be 0

**Never introduce SwiftUI in new or modified code.** That means no `import SwiftUI` in any
UI file, no `View` / `some View` / `@State` / `@Binding` / `@Observable`-driven view bodies,
no `NSHostingView`, no `NSViewRepresentable` bridges, no `ImageRenderer`. If you find yourself
reaching for a SwiftUI construct because it's faster to write, write the AppKit version instead.
(There is no UIKit on macOS either — if you're tempted, you want AppKit.)

The house control kits: `Views/Shared/DesignKit/` (CCKit — tokens, CC* components,
`CCMotion`, `CCMaterial`; see its README.md) and the editor's
`Views/Editor/InspectorKit/` (+ `EditorThemeKit` façade). **Reuse them.**
Don't hand-roll a new control or use a stock `NSButton`/`NSSlider` with default chrome; the app
has a deliberate SKEUOMORPHIC design language (2026-09-01, was flat before) — every surface is
dressed by `CCMaterial` (raised glass / recessed wells, derived from theme tokens) and stock
AppKit controls break it. New components ship dressed AND animated (growth bounces at the
pushed edge only; see `CCMotion`), never bare.

State flows to views via `withObservationTracking` re-arming loops (see any `*PaneAppKit.swift`
or `SurfaceObservation`), and out via explicit callback closures. Not bindings.

## 2. Preview must equal export, exactly. This is the product.

The editor preview (CoreAnimation compositor) and the exporter (CoreImage) must render the same
frame for the same state. Users compare them constantly; a mismatch is a P0 bug.

**Never fork math between the two paths.** Shared sources of truth:
`TiltMath`, `ReactiveCameraLayout`, `VideoTrackEditMath`, `VoiceTrackEditMath`, `VideoSliceMath`,
`AnnotationEffectMath`, `TapRippleMath`, `PreviewMotionModel`, `DeviceFrameLayout`,
`ClickRippleOverlay.discreteClickTimes`, `RecordingClock`.
If a computation is needed on both sides, it goes in a shared type that both consume — not
copied, not "kept in sync by comment."

Conventions worth knowing: CoreImage's `CIGaussianBlur` radius is a *sigma* ≈ half the SwiftUI/CG
shadow radius. Preview space is Y-down, CIImage space is Y-up. Animation phases are derived from
the timeline clock (`currentTime - startTime`), never a wall clock, so scrubbing and export agree.

## 3. Verification gates — the two ways they have lied before

Headless harnesses (run the built binary):
`--preview-parity`, `--raster-golden`, `--videotrack-math-test [--canvas]`, `--voicetrack-test`,
`--keysound-test`, `--playback-observer-test`, `--inspector-probe`, `--editor-shell-shot`,
`--recording-panel-shot`.

`--preview-parity` and `--raster-golden` were SwiftUI-vs-native diffs. With SwiftUI gone they score
against **frozen references** — `PreviewGoldens`, `RasterGoldens`, `SquircleReference` — captured
from renderers that had just passed the live diff. Both accept `--refreeze` to regenerate. Refreezing
a red gate to make it green throws away the only evidence those renderers were ever correct: read the
per-cell deltas and the `-ca.png` / `-cg.png` artifacts first, and only refreeze a change you meant.

A frozen reference is only worth anything if the fixture is deterministic. `--preview-parity` used to
render *the user's most recently edited project*, so its output changed with the user's data; it now
builds a synthetic project and a synthetic video frame (`makeFixtureProject`, `syntheticVideoFrame`).

Two failure modes have shipped bugs to the user despite "passing" gates:

- **Wrong topology.** A view tested in a bare pre-sized `NSWindow` passed, then rendered empty in
  the app, because the real parent chain resolved its constraints differently. Probe views inside
  the *same* hosting chain the app uses.
- **Static frames only.** A 17-state pixel matrix passed while every animation snapped, because
  each state was a settled frame. Capture *sequences* and assert the animated value is mid-flight
  (e.g. zoom ≠ 1.0 and ≠ target).

Also: a mean pixel-diff is blind to small structural defects. A duplicated Dynamic Island scored
1.846/255 (passing) while visibly wrong. When a defect is structural, add a structural assertion
(blob/centroid counts) and prove the gate works by injecting the defect.

## 4. Practical

Build: `cd apps/macos && xcodebuild -project CaptureCat.xcodeproj -scheme CaptureCat -configuration Debug build`
The project uses synchronized filesystem groups — new `.swift` files under `CaptureCat/` compile
automatically. SourceKit single-file diagnostics are noise; `xcodebuild` is the only truth.

Models use hand-rolled `Codable`: a new property needs a `var`, a `CodingKeys` case, a
`decodeIfPresent`-with-default, and an `encode` line. Enum raw values are persistence identity —
never rename one. Old projects must always still load.

If the user is running the app, don't kill or relaunch it without saying so. A process in `SX`
state with a `debugserver` parent is attached to Xcode — ask them to stop it rather than killing it.
