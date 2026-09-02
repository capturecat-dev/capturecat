import AppKit
import AVFoundation
import Metal
import Observation
import QuartzCore
import ScreenCaptureKit

/// Preview compositor regression gate. Run:
///
///   CaptureCat --preview-parity
///
/// Renders OFFSCREEN via CARenderer (Metal) — immune to screen lock, no
/// screen-recording permission needed, captures the real CA compositing
/// (3D transforms, masks, shadows). DEBUG tooling only; never runs in a
/// normal launch.
///
/// # What changed when SwiftUI was removed
///
/// This was a two-pane diff: `PreviewView` (SwiftUI) on the left, the CA
/// compositor on the right, every state scored against a 3/255 mean bar. That
/// is how the compositor was proved correct, and it passed the full matrix
/// (worst 2.201/255, `cursor-pin`) at the commit that deleted the SwiftUI
/// preview.
///
/// With `PreviewView` gone the left pane cannot be re-rendered, so the
/// compositor's own verified output is frozen in `PreviewGoldens` and each
/// state is scored against that instead. NOTHING ELSE CHANGED: the same 24
/// states, the same fixture assembly, the same motion SEQUENCES with the same
/// mid-flight spring assertions, and the same structural blob gate on the
/// device chrome. The matrix is renderer-agnostic — it is a list of `Project`
/// mutations — so it survives the swap intact.
///
/// The mid-flight assertions are the reason the sequences must stay. CLAUDE.md
/// §3: a 17-state pixel matrix once passed while every animation snapped,
/// because each state was a settled frame. `checkSequence` drives real tick
/// histories and asserts the spring is genuinely between rest and target.
@MainActor
enum PreviewParityHarness {
    static let paneSize = CGSize(width: 720, height: 405)
    /// Worst tolerated per-channel fingerprint cell delta. See
    /// `RasterFingerprint` — cells are ~60×58pt averages, so this is far below
    /// any real render change and far above antialiasing noise.
    static let fingerprintBar: Double = 2

    /// `--refreeze` prints a fresh `PreviewGoldens` table instead of asserting.
    private static var refreezing = false
    private static var refrozen: [String] = []
    private static var refrozenBlobs: [String] = []

    // Fixture state driving the compositor.
    @Observable
    final class Fixture {
        var project: Project
        var currentTime: TimeInterval = 0
        var cursorEvents: [CursorEvent] = []
        var coordinateSize: CGSize = .zero
        var videoSize: CGSize = .zero
        var player: AVPlayer?
        var cameraPoster: NSImage?
        var videoPoster: NSImage?
        var cameraAspect: CGFloat = 4.0 / 3.0
        /// True for states that must render as PLAYBACK frames — the paused
        /// editor deliberately settles build effects (Chrome.rendersSettled),
        /// so mid-flight animation states pin isPlaying to stay mid-flight.
        var isPlaying = false

        init(project: Project) { self.project = project }
    }

    static func run() -> Never {
        setbuf(stdout, nil) // line-live output for the external capture driver
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        refreezing = CommandLine.arguments.contains("--refreeze")

        Task { @MainActor in
            do {
                try await runMatrix()
            } catch {
                print("PARITY ERROR \(error)")
                exit(2)
            }
        }
        app.run()
        exit(0)
    }

    private static func emit(_ s: String) { print(s) }

    // MARK: - Matrix

    private static func runMatrix() async throws {
        // FIRST statement on purpose. Several inputs to this gate are dynamic
        // system colours that resolve at CONSTRUCTION time, not at draw time:
        // `ProjectSettings` defaults its subtitle highlight to
        // `NSColor.systemYellow` and its background gradient to
        // systemPurple/systemBlue, and `gradientPoster` draws systemIndigo →
        // systemTeal. Pinning after the fixture is built is too late — the
        // colours are already baked. Dark is the appearance the goldens were
        // frozen under — pinning light here moved EIGHTEEN states by 18/255,
        // which is precisely the evidence that this was never pinned at all.
        NSApp.appearance = NSAppearance(named: .darkAqua)

        let fixtureDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("capturecat-parity-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)

        let project = makeFixtureProject()
        let fixture = Fixture(project: project)

        // Synthetic frame instead of a decoded one. `player` stays nil and the
        // compositor takes the still through `videoPosterImage`, so there is no
        // decode timing, no seek tolerance and no user media in the loop — the
        // three things that made this gate irreproducible.
        let naturalSize = CGSize(width: 1920, height: 1200)
        fixture.videoSize = naturalSize
        fixture.coordinateSize = naturalSize
        fixture.player = nil
        fixture.videoPoster = syntheticVideoFrame(size: naturalSize)

        // Fixture time: 2s past trim start (mid-content, stable frame)
        let t0 = project.effectiveTrimStart + 2.0
        fixture.currentTime = t0

        // Cursor path + one click 0.2s before t0 (ripple mid-cycle at t0)
        fixture.cursorEvents = syntheticCursorEvents(around: t0, size: naturalSize)

        // Camera poster (same object both renderers)
        fixture.cameraPoster = gradientPoster(size: CGSize(width: 400, height: 300))

        // `Project.watermarkImageURL` resolves the logo next to `videoURL`
        // (Project.swift:299), so the fixture needs a videoURL even though no
        // file is decoded — the frame comes from `videoPosterImage`. Without it
        // the `watermark` state rendered nothing and its capture was
        // byte-identical to `flat`, i.e. the golden asserted the ABSENCE of a
        // watermark.
        let logoName = "parity-logo.png"
        project.videoURL = fixtureDir.appendingPathComponent("video.mov")
        try writeLogoPNG(to: fixtureDir.appendingPathComponent(logoName))

        // Single pane. The compositor sits inside a flipped container view
        // because that is the flip context the app gives it: the editor stage
        // hosts it as the documentView of an NSScrollView. A bare
        // `container.addSubview` under an unflipped view resolves
        // `layer.isGeometryFlipped` the other way — which is exactly the class
        // of difference that once hid the duplicated-island bug from a
        // bare-view harness (CLAUDE.md §3, wrong topology).
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: paneSize.width, height: paneSize.height),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.title = "CaptureCat Preview Gate"
        window.appearance = NSAppearance(named: .darkAqua)
        let container = FlippedContainer(frame: NSRect(origin: .zero, size: paneSize))
        container.wantsLayer = true
        let compositor = PreviewCompositorView(frame: NSRect(origin: .zero, size: paneSize))
        // Frames are captured settled and the sequences assert on the spring
        // MODEL, so the preview's implicit interpolation would only add capture
        // timing noise here.
        compositor.suppressImplicitAnimation = true
        compositor.rasterScaleOverride = 2
        container.addSubview(compositor)
        window.contentView = container
        window.orderFrontRegardless()

        await settle(0.3)
        emit("TOPOLOGY compositor superviewFlipped=\(compositor.superview?.isFlipped ?? false) geometryFlipped=\(compositor.layer?.isGeometryFlipped ?? false) contentsFlipped=\(compositor.layer?.contentsAreFlipped() ?? false)")

        await settle(0.3)

        emit("CAPTUREDIR \(fixtureDir.path)")
        var failures = 0
        var worst: (String, Double) = ("-", 0)

        /// Capture the current fixture state and score it against the frozen
        /// reference. Shared by static checks and sequences.
        func capture(_ name: String, cropTo: CGRect? = nil) async {
            // Schedule twice with settles: the standalone CARenderer capture
            // lags one committed frame behind (observed) — the second render
            // guarantees the captured tree is THIS state's. Same-time
            // schedules never step the springs (compositor guards on clock
            // advance), so this is state-safe mid-sequence.
            compositor.schedule(compositorInput(fixture))
            await settle(0.35)
            compositor.schedule(compositorInput(fixture))
            await settle(0.35)

            guard let containerLayer = container.layer,
                  let frame = CARendererSnapshot.render(
                      layer: containerLayer, size: container.bounds.size, scale: 1
                  ) else {
                emit("STATE \(name) capture-failed")
                failures += 1
                return
            }
            savePNG(frame, fixtureDir.appendingPathComponent("\(name)-ca.png"))

            // `cropTo` narrowed the old two-pane diff to a region of interest.
            // A fingerprint is a whole-frame grid, so apply the crop to the
            // image itself and fingerprint that — same intent, same states.
            let scored = cropTo.flatMap { frame.cropping(to: $0) } ?? frame
            let lum = meanLuminance(frame)

            guard let got = RasterFingerprint.make(scored) else {
                emit("STATE \(name) fingerprint-failed")
                failures += 1
                return
            }
            if refreezing {
                refrozen.append("        \"\(name)\": \"\(got)\",")
            } else if let want = PreviewGoldens.fingerprints[name],
                      let delta = RasterFingerprint.worstDelta(want, got) {
                let flag = delta <= fingerprintBar ? "PASS" : "FAIL"
                if delta > worst.1 { worst = (name, delta) }
                if delta > fingerprintBar { failures += 1 }
                emit("STATE \(name) cell=\(String(format: "%.0f", delta))/255 lum=\(String(format: "%.1f", lum)) \(flag)")
            } else {
                emit("STATE \(name) NO FROZEN REFERENCE — add one via --refreeze")
                failures += 1
            }

            // STRUCTURAL gate for device chrome. A mean — and equally a
            // downsampled fingerprint — is BLIND to a duplicated Dynamic
            // Island: a 48×13pt pill is 0.2% of the canvas, so drawing it twice
            // moved the old matrix by 0.07/255 and still reported PASS
            // (measured). The pure-black blobs catch it: the island is one, and
            // only one, of them.
            if name.hasPrefix("device") {
                let blobs = HarnessPixels.darkBlobs(frame)
                let shape = blobs
                    .map { "\($0.area)@\(Int($0.centroid.x)),\(Int($0.centroid.y))" }
                    .joined(separator: " ")
                if refreezing {
                    refrozenBlobs.append("        \"\(name)\": \(blobs.count),")
                    emit("BLOBS \(name) n=\(blobs.count) [\(shape)]")
                } else if let want = PreviewGoldens.blobCounts[name] {
                    if blobs.count == want {
                        emit("BLOBS \(name) n=\(blobs.count) [\(shape)] OK")
                    } else {
                        emit("BLOBS \(name) n=\(blobs.count) expected=\(want) [\(shape)] FAIL")
                        failures += 1
                    }
                } else {
                    emit("BLOBS \(name) NO FROZEN COUNT — add one via --refreeze")
                    failures += 1
                }
            }
        }

        func check(_ name: String, at time: TimeInterval? = nil, cropTo: CGRect? = nil) async {
            // Push identical state into both renderers.
            fixture.currentTime = time ?? t0
            await settle(0.45)
            await capture(name, cropTo: cropTo)
        }

        /// Drive BOTH renderers through the same discrete tick sequence
        /// (springs are stateful — identical tick history ⇒ identical
        /// integration), capturing at the given offsets from `seqStart`.
        /// `midFlight` reads a compositor spring value that must sit inside
        /// `midFlightRange` at the flagged captures, so the test cannot pass
        /// by snapping to rest or target.
        func checkSequence(
            _ name: String,
            seqStart: TimeInterval,
            captureOffsets: [TimeInterval],
            midFlightAt: Set<Int>,
            midFlightRange: ClosedRange<Double>? = nil,
            midFlight: (() -> Double)? = nil
        ) async {
            // Rewind well before the region so both models settle at rest
            // (backwards jump snaps both via the dt guard — deterministic).
            fixture.currentTime = seqStart - 0.8
            await settle(0.4)
            compositor.schedule(compositorInput(fixture))
            await settle(0.2)

            var captureIndex = 0
            var t = seqStart - 0.8
            let tickStep = 1.0 / 30.0
            while captureIndex < captureOffsets.count {
                t += tickStep
                fixture.currentTime = t
                compositor.schedule(compositorInput(fixture))
                // Generous per-tick settle: SwiftUI must COMMIT every tick —
                // a coalesced tick gives its model a doubled dt and the
                // integrations diverge.
                await settle(0.05)
                let target = seqStart + captureOffsets[captureIndex]
                if t + tickStep / 2 >= target {
                    if midFlightAt.contains(captureIndex),
                       let range = midFlightRange, let read = midFlight {
                        let v = read()
                        if range.contains(v) {
                            emit("SEQ \(name)+\(captureOffsets[captureIndex]) midflight=\(String(format: "%.3f", v)) OK")
                        } else {
                            emit("SEQ \(name)+\(captureOffsets[captureIndex]) NOT MID-FLIGHT value=\(String(format: "%.3f", v)) FAIL")
                            failures += 1
                        }
                    }
                    await capture("\(name)-t\(String(format: "%.2f", captureOffsets[captureIndex]))")
                    captureIndex += 1
                }
            }
        }

        func reset(_ mutate: (ProjectSettings) -> Void) {
            let s = fixture.project.settings
            s.backgroundType = .gradient
            s.backgroundPadding = 48
            s.videoPlacement = .center
            s.frameShape = .roundedRect
            s.cornerRadius = 12
            s.windowCornerRadius = 12
            s.shadowRadius = 20
            s.shadowOpacity = 0.5
            s.gradientAngle = nil
            s.backgroundBlur = 0; s.backgroundBrightness = 0; s.backgroundSaturation = 1
            s.backgroundTintOpacity = 0; s.backgroundVignette = 0
            s.backgroundPixelate = 0; s.backgroundHalftone = 0; s.backgroundNoise = 0
            s.backgroundContrast = 1; s.backgroundHue = 0
            s.screenTiltMode = .off
            s.showCamera = false
            s.cameraCustomX = nil; s.cameraCustomY = nil
            s.cameraBrightness = 0; s.cameraContrast = 1
            s.cameraSaturation = 1; s.cameraHue = 0
            s.cameraFilter = .none; s.cameraRingLight = 0
            s.cameraCornerRadius = 12; s.cameraBorderWidth = 2
            s.cameraBorderColor = nil; s.cameraOpacity = 1
            s.cameraTagText = ""; s.cameraTagSubtext = ""
            s.cameraTiltPitch = 0; s.cameraTiltYaw = 0
            s.cameraOrientation = .auto
            s.showCursor = true
            s.showClickRipple = true
            s.showSubtitles = false
            s.subtitleCustomX = nil; s.subtitleCustomY = nil
            s.showWatermark = false
            s.menuBarReplacement = .off
            s.showDeviceFrame = false
            fixture.project.recordingSourceKind = .display
            fixture.project.zoomRegions = []
            fixture.project.tiltRegions = []
            fixture.project.subtitles = []
            fixture.project.blurRegions = []
            fixture.project.highlightRegions = []
            fixture.project.annotations = []
            mutate(s)
        }

        // Debug: one whole-window capture so we can SEE both panes as the
        // renderer sees them.
        reset { _ in }
        fixture.currentTime = t0
        await settle(0.45)
        compositor.schedule(compositorInput(fixture))
        await settle(0.35)
        if let containerLayer = container.layer,
           let whole = CARendererSnapshot.render(layer: containerLayer, size: container.bounds.size, scale: 1) {
            savePNG(whole, fixtureDir.appendingPathComponent("debug-window.png"))
            emit("DEBUGWINDOW saved")
        }

        // 1 — flat
        reset { _ in }
        await check("flat")

        // 2 — tilt 20/0/0 (region active at t0)
        reset { _ in
            fixture.project.tiltRegions = [TiltRegion(startTime: t0 - 1, endTime: t0 + 2, pitch: 20, yaw: 0, roll: 0)]
        }
        await check("tilt-20-0-0")

        // 3 — tilt 0/-17/6
        reset { _ in
            fixture.project.tiltRegions = [TiltRegion(startTime: t0 - 1, endTime: t0 + 2, pitch: 0, yaw: -17, roll: 6)]
        }
        await check("tilt-0--17-6")

        // 4 — zoom 2.0 mid-block
        reset { _ in
            fixture.project.zoomRegions = [ZoomRegion(startTime: t0 - 1.5, endTime: t0 + 2, zoomLevel: 2.0, focalPoint: CGPoint(x: 0.5, y: 0.5))]
        }
        await check("zoom-2")

        // 5 — zoom + tilt
        reset { _ in
            fixture.project.zoomRegions = [ZoomRegion(startTime: t0 - 1.5, endTime: t0 + 2, zoomLevel: 2.0, focalPoint: CGPoint(x: 0.5, y: 0.5))]
            fixture.project.tiltRegions = [TiltRegion(startTime: t0 - 1, endTime: t0 + 2, pitch: 20, yaw: 0, roll: 0)]
        }
        await check("zoom+tilt")

        // 6 — menu bar dark
        reset { s in s.menuBarReplacement = .dark; s.menuBarTitle = "Parity"; s.menuBarClock = "9:41" }
        await check("menubar-dark")

        // 7 — hidden crop
        reset { s in s.menuBarReplacement = .hidden; s.menuBarHeight = 3.8 }
        await check("hidden-crop")

        // 8 — subtitle glow, free position
        reset { s in
            s.showSubtitles = true
            s.subtitleStyle = .glow
            s.subtitleWeight = .heavy
            s.subtitleUppercase = true
            s.subtitleCustomX = 0.3
            s.subtitleCustomY = 0.25
            fixture.project.subtitles = [SubtitleSegment(startTime: t0 - 1, endTime: t0 + 1, text: "Parity check", words: [])]
        }
        await check("subtitle-glow")

        // 9 — watermark corner
        reset { s in
            s.showWatermark = true
            s.watermarkFileName = logoName
            s.watermarkX = 1; s.watermarkY = 1
            s.watermarkSize = 140
            s.watermarkOpacity = 0.85
        }
        await check("watermark")

        // 10 — camera custom position
        reset { s in
            s.showCamera = true
            s.cameraCustomX = 0.2
            s.cameraCustomY = 0.7
            s.cameraSize = 160
            s.cameraShape = .squircle
        }
        await check("camera-custom")

        // 10b — camera styling (CameraStyleMath). The mappings are shared by
        // preview and exporter, so these assert the MATH's contracts directly,
        // then probe the compositor's wiring through its debug hooks — the
        // poster path (no AVPlayer) keeps everything deterministic.
        do {
            var styleFailures = 0
            func expect(_ name: String, _ ok: Bool, _ detail: String) {
                emit("CAMERA-STYLE \(name) \(detail) \(ok ? "PASS" : "FAIL")")
                if !ok { styleFailures += 1 }
            }
            let ciContext = CIContext(options: [
                .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
                .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
            ])
            func pixels(_ image: CIImage, size: Int) -> [UInt8]? {
                guard let cg = ciContext.createCGImage(image, from: CGRect(x: 0, y: 0, width: size, height: size)),
                      let px = HarnessPixels.rgba(cg) else { return nil }
                defer { px.deallocate() }
                var out = [UInt8](repeating: 0, count: size * size * 4)
                for y in 0..<size {
                    for x in 0..<(size * 4) {
                        out[y * size * 4 + x] = (px.bytes + y * px.bytesPerRow)[x]
                    }
                }
                return out
            }

            // 1. Identity adjustments must return the input untouched —
            // structurally the same object, and therefore the same pixels.
            let src = CIImage(color: CIColor(red: 0.6, green: 0.35, blue: 0.2))
                .cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
            let identityOut = CameraStyleMath.adjustedImage(src, adjustments: .identity)
            expect("identity-passthrough", identityOut === src,
                   "defaults must not touch the image")

            // 2. Saturation 0 must actually grey the image; brightness must
            // lift it; hue must rotate channels — i.e. each control DOES
            // something through the shared pipeline.
            let desat = CameraStyleMath.adjustedImage(src, adjustments: .init(
                brightness: 0, contrast: 1, saturation: 0, hue: 0, filter: .none))
            if let p = pixels(desat, size: 16) {
                let (r, g, b) = (Int(p[0]), Int(p[1]), Int(p[2]))
                expect("saturation-0-greys", abs(r - g) < 6 && abs(g - b) < 6,
                       "rgb=(\(r),\(g),\(b))")
            } else { expect("saturation-0-greys", false, "render failed") }
            let bright = CameraStyleMath.adjustedImage(src, adjustments: .init(
                brightness: 0.4, contrast: 1, saturation: 1, hue: 0, filter: .none))
            if let base = pixels(src, size: 16), let p = pixels(bright, size: 16) {
                expect("brightness-lifts", Int(p[2]) > Int(base[2]) + 20,
                       "blue \(base[2]) -> \(p[2])")
            } else { expect("brightness-lifts", false, "render failed") }
            let mono = CameraStyleMath.adjustedImage(src, adjustments: .init(
                brightness: 0, contrast: 1, saturation: 1, hue: 0, filter: .mono))
            if let p = pixels(mono, size: 16) {
                expect("filter-mono-greys", abs(Int(p[0]) - Int(p[2])) < 8,
                       "rgb=(\(p[0]),\(p[1]),\(p[2]))")
            } else { expect("filter-mono-greys", false, "render failed") }

            // 3. Ring light — an OUTER glow: alpha just outside the bubble
            // edge, zero well inside the bubble (the video is never washed),
            // fading out by the padded border; intensity 0 yields no image.
            expect("ring-off-is-nil", CameraStyleMath.ringImage(
                size: CGSize(width: 100, height: 100), shape: .circle,
                customRadius: 12, intensity: 0, scale: 1) == nil, "")
            if let ring = CameraStyleMath.ringImage(
                size: CGSize(width: 100, height: 100), shape: .circle,
                customRadius: 12, intensity: 0.8, scale: 1),
               let px = HarnessPixels.rgba(ring) {
                defer { px.deallocate() }
                func alpha(_ x: Int, _ y: Int) -> Int { Int((px.bytes + y * px.bytesPerRow + x * 4)[3]) }
                // Bubble is 100×100 at (12,12) inside a 124×124 padded raster
                // (ringPadding = 0.12 × 100 = 12). Centre (62,62), rim x=112.
                let pad = Int(CameraStyleMath.ringPadding(for: CGSize(width: 100, height: 100)))
                expect("ring-raster-padded", ring.width == 100 + 2 * pad && ring.height == 100 + 2 * pad,
                       "raster=\(ring.width)x\(ring.height) pad=\(pad)")
                let centre = alpha(62, 62)                       // bubble centre
                let wellInside = alpha(62, 42)                   // inside the circle interior
                let outside = max(alpha(62, 8), alpha(8, 62),    // just outside the rim
                                  alpha(62, 116), alpha(116, 62))
                let corner = alpha(2, 2)                          // dead at the raster corner
                expect("ring-outside-not-inside",
                       centre == 0 && wellInside == 0 && outside > 20 && corner < 6,
                       "centre=\(centre) inside=\(wellInside) outside=\(outside) corner=\(corner)")
                // Soft-diffusion contract: walking outward from the rim the
                // alpha must decay MONOTONICALLY to (near) zero — a local
                // maximum away from the rim is band structure, i.e. the old
                // neon look.
                let trace = (112...123).map { alpha($0, 62) }
                var monotone = true
                var banded = false
                for i in 1..<trace.count {
                    if trace[i] > trace[i - 1] + 2 { monotone = false }
                    if i + 1 < trace.count, trace[i] > trace[i - 1] + 2, trace[i] > trace[i + 1] + 2 {
                        banded = true
                    }
                }
                expect("ring-smooth-decay",
                       monotone && !banded && (trace.first ?? 0) > 20 && (trace.last ?? 255) < 12,
                       "trace=\(trace)")
            } else { expect("ring-outside-not-inside", false, "ring raster failed") }

            // 3b. Squircle is a true superellipse now, structurally: on the
            // corner diagonal it bulges beyond a rounded rect of the SAME
            // corner depth (40% of the short side), and it carves deeper than
            // the legacy ContinuousRoundedRect r=24 it replaced.
            do {
                let rect = CGRect(x: 0, y: 0, width: 200, height: 200)
                let squircle = CameraStyleMath.clipPath(
                    shape: .squircle, customRadius: 12, rect: rect, scale: 1)
                let equalDepth = CGPath(
                    roundedRect: rect, cornerWidth: 80, cornerHeight: 80, transform: nil)
                let legacy = ContinuousRoundedRect.path(rect: rect, cornerRadius: 24)
                // Superellipse n=4.5 reaches (185.7,185.7) on the diagonal;
                // an 80pt arc stops at (176.6,176.6).
                let bulge = CGPoint(x: 181, y: 181)
                expect("squircle-bulges-past-arc",
                       squircle.contains(bulge) && !equalDepth.contains(bulge),
                       "point=\(bulge)")
                // …and near the very corner it carves deeper than legacy r24:
                // the r24 corner reaches ≈(193,193) on the diagonal, while the
                // superellipse boundary sits at ≈(185.7,185.7).
                let deep = CGPoint(x: 189, y: 189)
                expect("squircle-differs-from-legacy",
                       legacy.contains(deep) && !squircle.contains(deep),
                       "point=\(deep)")
                // The squircle now follows the video aspect (landscape tile);
                // circle and square stay 1:1.
                // Squircle leans toward the ~1.2:1 TV tile: wide sources cap
                // at squircleMaxAspect, portrait at its reciprocal; narrower-
                // than-cap sources pass through untouched.
                func aspect(
                    _ shape: ProjectSettings.CameraShape, _ video: Double,
                    _ o: ProjectSettings.CameraOrientation = .auto
                ) -> Double {
                    ReactiveCameraLayout.shapeAspect(shape: shape, videoAspect: video, orientation: o)
                }
                expect("squircle-follows-aspect",
                       aspect(.squircle, 16.0 / 9.0) == ReactiveCameraLayout.squircleMaxAspect
                           && aspect(.squircle, 1.1) == 1.1
                           && aspect(.squircle, 9.0 / 16.0) == 1 / ReactiveCameraLayout.squircleMaxAspect
                           && aspect(.circle, 16.0 / 9.0) == 1
                           && aspect(.square, 16.0 / 9.0) == 1
                           && aspect(.roundedRect, 16.0 / 9.0) == 16.0 / 9.0,
                       "")
                // Orientation override: Vertical forces the 4:5 portrait tile
                // and Wide the 1.2 landscape cap for BOTH aspect-following
                // shapes, regardless of the source aspect; circle/square are
                // immune.
                expect("orientation-truth-table",
                       aspect(.squircle, 16.0 / 9.0, .vertical) == ReactiveCameraLayout.verticalAspect
                           && aspect(.squircle, 9.0 / 16.0, .vertical) == ReactiveCameraLayout.verticalAspect
                           && aspect(.roundedRect, 16.0 / 9.0, .vertical) == ReactiveCameraLayout.verticalAspect
                           && aspect(.roundedRect, 9.0 / 16.0, .vertical) == ReactiveCameraLayout.verticalAspect
                           && aspect(.squircle, 9.0 / 16.0, .wide) == ReactiveCameraLayout.squircleMaxAspect
                           && aspect(.roundedRect, 9.0 / 16.0, .wide) == ReactiveCameraLayout.squircleMaxAspect
                           && aspect(.circle, 16.0 / 9.0, .vertical) == 1
                           && aspect(.circle, 16.0 / 9.0, .wide) == 1
                           && aspect(.square, 9.0 / 16.0, .vertical) == 1
                           && ReactiveCameraLayout.verticalAspect == 0.8,
                       "vertical=\(ReactiveCameraLayout.verticalAspect)")
            }

            // 4. Name tag — hidden while empty; appears with text; the rect
            // moves with the position enum in both axis conventions.
            let tagSettings = ProjectSettings()
            expect("tag-empty-hidden",
                   CameraStyleMath.tagBitmap(settings: tagSettings, bubbleWidth: 160, scale: 1) == nil, "")
            tagSettings.cameraTagText = "Mike"
            tagSettings.cameraTagSubtext = "CaptureCat"
            if let built = CameraStyleMath.tagBitmap(settings: tagSettings, bubbleWidth: 160, scale: 1) {
                expect("tag-renders", built.pillSize.width > 20 && built.pillSize.height > 10,
                       "pill=\(built.pillSize)")
                let bubble = CGRect(x: 100, y: 100, width: 160, height: 160)
                let below = CameraStyleMath.tagRect(bubbleRect: bubble, pillSize: built.pillSize, position: .below, yAxisIsUp: false)
                let above = CameraStyleMath.tagRect(bubbleRect: bubble, pillSize: built.pillSize, position: .above, yAxisIsUp: false)
                let overlap = CameraStyleMath.tagRect(bubbleRect: bubble, pillSize: built.pillSize, position: .overlapBottom, yAxisIsUp: false)
                let centred = abs(below.midX - bubble.midX) < 0.001
                expect("tag-positions",
                       centred && below.minY > bubble.maxY && above.maxY < bubble.minY
                           && abs(overlap.midY - bubble.maxY) < 0.001,
                       "below=\(Int(below.minY)) above=\(Int(above.maxY)) overlapMid=\(Int(overlap.midY))")
                // Y-up (exporter) placement mirrors the Y-down one exactly.
                let belowUp = CameraStyleMath.tagRect(bubbleRect: bubble, pillSize: built.pillSize, position: .below, yAxisIsUp: true)
                expect("tag-yup-mirrors", belowUp.maxY < bubble.minY,
                       "belowUp.maxY=\(Int(belowUp.maxY)) bubble.minY=\(Int(bubble.minY))")
            } else {
                expect("tag-renders", false, "tag raster failed")
            }

            // 5. Compositor wiring — the poster-path bubble must honour the
            // border color/width, ring, tag and group opacity settings.
            reset { s in
                s.showCamera = true
                s.cameraShape = .roundedRect
                s.cameraCornerRadius = 30
                s.cameraBorderColor = CodableColor(red: 1, green: 0, blue: 0, opacity: 1)
                s.cameraBorderWidth = 6
                s.cameraRingLight = 0.7
                s.cameraOpacity = 0.5
                s.cameraTagText = "Mike"
            }
            fixture.currentTime = t0
            compositor.schedule(compositorInput(fixture))
            await settle(0.3)
            let stroke = compositor.debugCameraStroke()
            let strokeColor = stroke.strokeColor.flatMap { NSColor(cgColor: $0) }?.usingColorSpace(.sRGB)
            expect("border-color-honoured",
                   (strokeColor?.redComponent ?? 0) > 0.9 && (strokeColor?.greenComponent ?? 1) < 0.1,
                   "strokeColor=\(String(describing: strokeColor))")
            // At zoom 1 the envelope sizeFactor is exactly 1, so the layer's
            // line width equals the setting.
            expect("border-width-honoured", abs(stroke.lineWidth - 6) < 0.5,
                   "lineWidth=\(stroke.lineWidth)")
            expect("ring-layer-live", !compositor.debugCameraRingLayer().isHidden
                   && compositor.debugCameraRingLayer().contents != nil, "")
            expect("tag-layer-live", !compositor.debugCameraTagLayer().isHidden
                   && compositor.debugCameraTagLayer().contents != nil, "")
            expect("group-opacity", abs(compositor.debugCameraGroupOpacity() - 0.5) < 0.001,
                   "opacity=\(compositor.debugCameraGroupOpacity())")

            // 6. Camera tilt — the bubble group's CATransform3D must be
            // EXACTLY the shared TiltMath projection (same function the
            // exporter's CIPerspectiveTransform corners come from), and a
            // non-zero pitch must visibly change the rendered raster.
            let untiltedFrame = container.layer.flatMap {
                CARendererSnapshot.render(layer: $0, size: container.bounds.size, scale: 1)
            }
            expect("tilt-identity-at-rest",
                   CATransform3DIsIdentity(compositor.debugCameraGroupTransform()), "")
            fixture.project.settings.cameraTiltPitch = 18
            fixture.project.settings.cameraTiltYaw = -12
            compositor.schedule(compositorInput(fixture))
            await settle(0.3)
            compositor.schedule(compositorInput(fixture))
            await settle(0.3)
            if let rect = compositor.debugCameraRect() {
                let got = compositor.debugCameraGroupTransform()
                let want = CATransform3D(TiltMath.projectionTransform(
                    pitchDegrees: 18, yawDegrees: -12, rollDegrees: 0,
                    center: CGPoint(x: rect.width / 2, y: rect.height / 2),
                    distance: TiltMath.perspectiveDistance(for: rect.size)
                ))
                let matches = abs(got.m11 - want.m11) < 1e-9 && abs(got.m12 - want.m12) < 1e-9
                    && abs(got.m14 - want.m14) < 1e-9 && abs(got.m21 - want.m21) < 1e-9
                    && abs(got.m22 - want.m22) < 1e-9 && abs(got.m24 - want.m24) < 1e-9
                    && abs(got.m41 - want.m41) < 1e-9 && abs(got.m42 - want.m42) < 1e-9
                    && abs(got.m44 - want.m44) < 1e-9
                expect("tilt-uses-shared-math", matches,
                       "m14=\(got.m14) want=\(want.m14) m24=\(got.m24) want=\(want.m24)")
                if let before = untiltedFrame,
                   let after = container.layer.flatMap({
                       CARendererSnapshot.render(layer: $0, size: container.bounds.size, scale: 1)
                   }) {
                    let crop = rect.insetBy(dx: -30, dy: -30)
                        .intersection(CGRect(origin: .zero, size: paneSize))
                    let diff = meanAbsDiff(before, after, crop: crop)
                    expect("tilt-changes-raster", diff > 0.5,
                           String(format: "camera-crop diff=%.2f/255", diff))
                } else {
                    expect("tilt-changes-raster", false, "capture failed")
                }
            } else {
                expect("tilt-uses-shared-math", false, "no camera rect")
            }
            fixture.project.settings.cameraTiltPitch = 0
            fixture.project.settings.cameraTiltYaw = 0

            // 7. Vertical orientation — the compositor's bubble rect must be
            // TALLER than wide (4:5 tile) even though the fixture's poster is
            // landscape 4:3, and switch back to landscape under Wide.
            reset { s in
                s.showCamera = true
                s.cameraShape = .squircle
                s.cameraOrientation = .vertical
            }
            fixture.currentTime = t0
            compositor.schedule(compositorInput(fixture))
            await settle(0.3)
            if let rect = compositor.debugCameraRect() {
                let ratio = rect.width / max(1, rect.height)
                expect("vertical-rect-portrait",
                       rect.height > rect.width
                           && abs(ratio - CGFloat(ReactiveCameraLayout.verticalAspect)) < 0.01,
                       String(format: "rect=%.0fx%.0f ratio=%.3f", rect.width, rect.height, ratio))
            } else {
                expect("vertical-rect-portrait", false, "no camera rect")
            }
            fixture.project.settings.cameraOrientation = .wide
            compositor.schedule(compositorInput(fixture))
            await settle(0.3)
            if let rect = compositor.debugCameraRect() {
                expect("wide-rect-landscape", rect.width > rect.height,
                       String(format: "rect=%.0fx%.0f", rect.width, rect.height))
            } else {
                expect("wide-rect-landscape", false, "no camera rect")
            }
            // And back at defaults everything returns to the historical look.
            reset { s in s.showCamera = true }
            fixture.currentTime = t0
            compositor.schedule(compositorInput(fixture))
            await settle(0.3)
            let defaultStroke = compositor.debugCameraStroke()
            let defColor = defaultStroke.strokeColor.flatMap { NSColor(cgColor: $0) }?.usingColorSpace(.sRGB)
            expect("defaults-restore-legacy-border",
                   !defaultStroke.isHidden
                       && abs((defColor?.redComponent ?? 0) - 1) < 0.01
                       && abs((defColor?.greenComponent ?? 0) - 1) < 0.01
                       && abs((defColor?.blueComponent ?? 0) - 1) < 0.01
                       && abs((defColor?.alphaComponent ?? 0) - 0.3) < 0.01
                       && compositor.debugCameraRingLayer().isHidden
                       && compositor.debugCameraTagLayer().isHidden
                       && compositor.debugCameraGroupOpacity() == 1,
                   "color=\(String(describing: defColor)) width=\(defaultStroke.lineWidth)")

            failures += styleFailures
        }

        // 12 — device take, flat (bezel + seam; pad-style for the 16:10 fixture)
        reset { s in
            s.showDeviceFrame = true
            fixture.project.recordingSourceKind = .device
        }
        await check("device-flat")

        // 13 — device + tilt (bezel side faces track the warp)
        reset { s in
            s.showDeviceFrame = true
            fixture.project.recordingSourceKind = .device
            fixture.project.tiltRegions = [TiltRegion(startTime: t0 - 1, endTime: t0 + 2, pitch: 14, yaw: -10, roll: 0)]
        }
        await check("device+tilt")

        // 13b/13c — PHONE-aspect fixture: the Dynamic Island only draws for
        // phone-aspect content, so the 16:10 fixture never exercises it (that
        // gap let an island bug ship). Synthetic, like everything else here.
        do {
            let savedProject = fixture.project
            let savedVideoSize = fixture.videoSize
            let savedCoordinate = fixture.coordinateSize
            let savedPoster = fixture.videoPoster
            let savedEvents = fixture.cursorEvents
            let savedTime = fixture.currentTime

            let phoneSize = CGSize(width: 1179, height: 2556)   // iPhone 15 Pro
            let phoneProject = makeFixtureProject()
            phoneProject.recordingSourceKind = .device
            phoneProject.settings.showDeviceFrame = true
            phoneProject.settings.backgroundType = .gradient
            phoneProject.settings.showSubtitles = false
            phoneProject.settings.showCamera = false
            phoneProject.settings.showWatermark = false
            let pt0 = phoneProject.effectiveTrimStart + 1.0

            fixture.project = phoneProject
            fixture.videoSize = phoneSize
            fixture.coordinateSize = phoneSize
            fixture.videoPoster = syntheticVideoFrame(size: phoneSize)
            fixture.cursorEvents = []
            fixture.currentTime = pt0
            await settle(0.4)

            await check("device-phone-flat", at: pt0)

            phoneProject.tiltRegions = [TiltRegion(startTime: pt0 - 1, endTime: pt0 + 2, pitch: 1, yaw: -37, roll: 0)]
            await check("device-phone+tilt", at: pt0)

            fixture.project = savedProject
            fixture.videoSize = savedVideoSize
            fixture.coordinateSize = savedCoordinate
            fixture.videoPoster = savedPoster
            fixture.cursorEvents = savedEvents
            fixture.currentTime = savedTime
            await settle(0.4)
        }

        // 13d/13e — device SEGMENT fixture: a DISPLAY-kind recording with an
        // embedded `.device` sourceSegment. Here deviceFrameRect is a SUB-RECT
        // of videoRect rather than videoRect itself — a coordinate space the
        // .device-kind fixture never exercises, and the space the island
        // duplication was reported in (tilt yaw −37).
        do {
            let savedProject = fixture.project
            let savedVideoSize = fixture.videoSize
            let savedCoordinate = fixture.coordinateSize
            let savedPoster = fixture.videoPoster
            let savedEvents = fixture.cursorEvents
            let savedTime = fixture.currentTime

            let segSize = CGSize(width: 1920, height: 1200)
            let segProject = makeFixtureProject()
            // A phone-shaped sub-rect centred in a display-shaped frame.
            segProject.sourceSegments = [
                ProjectSourceSegment(
                    startTime: 0, duration: 12, kind: .device,
                    contentX: 0.38, contentY: 0.05, contentWidth: 0.24, contentHeight: 0.90
                )
            ]
            segProject.settings.showDeviceFrame = true
            segProject.settings.backgroundType = .gradient
            segProject.settings.showSubtitles = false
            segProject.settings.showCamera = false
            segProject.settings.showWatermark = false
            segProject.settings.showCursor = false
            segProject.settings.menuBarReplacement = .off
            let st0 = 6.0   // mid-segment, clear of both boundaries (no dip)

            fixture.project = segProject
            fixture.videoSize = segSize
            fixture.coordinateSize = segSize
            fixture.videoPoster = syntheticVideoFrame(size: segSize)
            fixture.cursorEvents = []
            fixture.currentTime = st0
            await settle(0.4)

            await check("device-segment-flat", at: st0)

            // The exact effect block the island duplication was reported with.
            segProject.tiltRegions = [TiltRegion(startTime: st0 - 1.5, endTime: st0 + 1.5, pitch: 1, yaw: -37, roll: 0)]
            await check("device-segment+tilt", at: st0)
            segProject.tiltRegions = []

            fixture.project = savedProject
            fixture.videoSize = savedVideoSize
            fixture.coordinateSize = savedCoordinate
            fixture.videoPoster = savedPoster
            fixture.cursorEvents = savedEvents
            fixture.currentTime = savedTime
            await settle(0.4)
        }

        // 14 — feathered blur region (CI sigma = SwiftUI radius/2 convention)
        reset { _ in
            fixture.project.blurRegions = [BlurRegion(
                startTime: t0 - 1, endTime: t0 + 2,
                rect: CGRect(x: 0.32, y: 0.30, width: 0.36, height: 0.22),
                intensity: 0.7
            )]
        }
        await check("blur-feather")

        // 15 — highlight region (dim + punched hole + idle outline)
        reset { _ in
            fixture.project.highlightRegions = [HighlightRegion(
                startTime: t0 - 1, endTime: t0 + 2,
                rect: CGRect(x: 0.22, y: 0.2, width: 0.4, height: 0.24),
                opacity: 0.6
            )]
        }
        await check("highlight")

        // 16 — annotations: text + rectangle (paused editor chrome included)
        reset { _ in
            var text = Annotation(type: .text, startTime: t0 - 1, endTime: t0 + 2)
            text.text = "Parity note"
            text.x = 0.3; text.y = 0.28
            var rect = Annotation(type: .rectangle, startTime: t0 - 1, endTime: t0 + 2)
            rect.x = 0.55; rect.y = 0.45
            rect.arrowEndX = 0.8; rect.arrowEndY = 0.68
            fixture.project.annotations = [text, rect]
        }
        await check("annotations")

        // 17 — tap indicator mid-ripple (deterministic phase from t−start)
        reset { _ in
            var tap = Annotation(type: .tap, startTime: t0 - 0.2, endTime: t0 + 2)
            tap.x = 0.62; tap.y = 0.55
            fixture.project.annotations = [tap]
        }
        await check("tap-ripple")

        // 18 — MOTION: zoom-region entry sequence. The springs must be
        // verifiably mid-flight (zoom strictly between rest 1.0 and target
        // 2.0 at the +0.15/+0.3 captures) — a snapping renderer cannot pass.
        reset { _ in
            fixture.project.zoomRegions = [ZoomRegion(
                startTime: t0 + 0.4, endTime: t0 + 4,
                zoomLevel: 2.0, focalPoint: CGPoint(x: 0.5, y: 0.5)
            )]
        }
        await checkSequence(
            "motion-zoom", seqStart: t0 + 0.4,
            captureOffsets: [0.05, 0.15, 0.3, 0.6],
            midFlightAt: [1, 2],
            midFlightRange: 1.02...1.95,
            midFlight: { compositor.motion.zoom }
        )

        // 19 — MOTION: tilt-region entry sequence (regionPitch mid-flight
        // between 0 and 20 at +0.15/+0.3).
        reset { _ in
            fixture.project.tiltRegions = [TiltRegion(
                startTime: t0 + 0.4, endTime: t0 + 4,
                pitch: 20, yaw: -10, roll: 0
            )]
        }
        await checkSequence(
            "motion-tilt", seqStart: t0 + 0.4,
            captureOffsets: [0.05, 0.15, 0.3, 0.6],
            midFlightAt: [1, 2],
            midFlightRange: 0.5...19.5,
            midFlight: { compositor.motion.regionPitch }
        )

        // A tilt block that begins at the project head has no pre-roll in
        // which to animate from flat. Frame zero and the first playing tick
        // must therefore both render the authored angle immediately (the
        // exporter initializes its first camera-path frame the same way).
        // Seed the motion model with one PRE-TRIM decoder callback first: real
        // recordings commonly begin at a non-zero first-sample PTS, and this
        // was the path that left the spring flat when Play was pressed.
        do {
            let savedTrimStart = fixture.project.trimStart
            fixture.project.trimStart = 0.17333333333333334
            let head = fixture.project.effectiveTrimStart
            reset { _ in
                fixture.project.tiltRegions = [TiltRegion(
                    startTime: head,
                    endTime: head + 1.5,
                    pitch: 39,
                    yaw: -26,
                    roll: -4
                )]
            }

            fixture.currentTime = head - (1.0 / 60.0)
            compositor.schedule(compositorInput(fixture))
            await settle(0.12)

            fixture.currentTime = head
            compositor.schedule(compositorInput(fixture))
            await settle(0.12)
            let frameZero = compositor.debugTiltAngles()

            fixture.currentTime = head + (1.0 / 60.0)
            compositor.schedule(compositorInput(fixture))
            await settle(0.12)
            let firstTick = compositor.debugTiltAngles()
            let startsTilted = abs(frameZero.pitch - 39) < 0.001
                && abs(frameZero.yaw + 26) < 0.001
                && abs(frameZero.roll + 4) < 0.001
                && abs(firstTick.pitch - 39) < 0.001
                && abs(firstTick.yaw + 26) < 0.001
                && abs(firstTick.roll + 4) < 0.001
            emit("TILT-AT-HEAD trim=\(head) after-pretrim frame0=\(frameZero) firstTick=\(firstTick) \(startsTilted ? "PASS" : "FAIL")")
            if !startsTilted { failures += 1 }
            fixture.project.trimStart = savedTrimStart
        }

        // A HEAD-anchored tilt block is the clip's OPENING STATE: full angle
        // from frame zero (no dead zone, no easing-in-late), then the SAME
        // ramp-out as any mid-timeline block — mid-flight during the release
        // and no cliff at the end (the old whole-span override held 20° right
        // up to endTime and dropped ~18° in one frame). The mid block is
        // sampled at identical phases as the behavioral reference.
        do {
            let head = fixture.project.effectiveTrimStart
            var samples: [String: [Double]] = [:]
            for (name, bs) in [("head", head), ("mid", head + 1.0)] {
                reset { _ in
                    fixture.project.tiltRegions = [TiltRegion(
                        startTime: bs, endTime: bs + 2.4, pitch: 20)]
                }
                var values: [Double] = []
                for off in [0.0, 1.0, 2.0, 2.3, 2.6] {
                    fixture.currentTime = bs + off
                    compositor.schedule(compositorInput(fixture))
                    await settle(0.1)
                    values.append(compositor.debugTiltAngles().pitch)
                }
                samples[name] = values
            }
            fixture.project.tiltRegions = []
            let headS = samples["head"] ?? []
            let midS = samples["mid"] ?? []
            let openingFull = headS.count == 5
                && abs(headS[0] - 20) < 0.5 && abs(headS[1] - 20) < 0.5
            let rampsOut = headS.count == 5
                && headS[2] > 2 && headS[2] < 19
            let noCliff = headS.count == 5 && abs(headS[3] - headS[4]) < 5
            let matchesMid = headS.count == 5 && midS.count == 5
                && abs(headS[2] - midS[2]) < 3
            let ok = openingFull && rampsOut && noCliff && matchesMid
            emit(String(format: "TILT-HEAD-BLOCK full@0=%.2f full@1=%.2f ramp@2=%.2f end=%.2f→%.2f mid@2=%.2f %@",
                        headS.first ?? -1, headS.count > 1 ? headS[1] : -1,
                        headS.count > 2 ? headS[2] : -1,
                        headS.count > 3 ? headS[3] : -1,
                        headS.count > 4 ? headS[4] : -1,
                        midS.count > 2 ? midS[2] : -1,
                        ok ? "PASS" : "FAIL"))
            if !ok { failures += 1 }
        }

        // Scrubbing backward into an animation must reconstruct its in-flight
        // spring state. The old seek path treated a negative time delta as a
        // hard seek and snapped directly to 2×, so zoom/tilt animation was
        // invisible while dragging the playhead backward.
        do {
            let savedZooms = fixture.project.zoomRegions
            let savedTilts = fixture.project.tiltRegions
            fixture.project.zoomRegions = [ZoomRegion(
                startTime: t0,
                endTime: t0 + 2,
                zoomLevel: 2
            )]
            fixture.project.tiltRegions = []

            fixture.currentTime = t0 + 0.8
            compositor.schedule(compositorInput(fixture))
            await settle(0.12)

            fixture.currentTime = t0 + 0.15
            var scrubInput = compositorInput(fixture)
            scrubInput.isScrubbing = true
            compositor.schedule(scrubInput)
            await settle(0.12)

            let scrubZoom = compositor.motion.zoom
            let scrubShowsAnimation = scrubZoom > 1.02 && scrubZoom < 1.95
            emit(String(format: "SCRUB-MOTION backward midflight zoom=%.3f %@",
                        scrubZoom, scrubShowsAnimation ? "PASS" : "FAIL"))
            if !scrubShowsAnimation { failures += 1 }

            fixture.project.zoomRegions = savedZooms
            fixture.project.tiltRegions = savedTilts
        }

        // 20 — annotation build effects: pop mid-enter (t = start + 0.15).
        reset { _ in
            var text = Annotation(type: .text, startTime: t0 - 0.15, endTime: t0 + 2)
            text.text = "Pop build"
            text.x = 0.35; text.y = 0.3
            text.enterEffect = .pop
            fixture.project.annotations = [text]
        }
        // Mid-flight states render as PLAYBACK frames: the paused editor
        // settles builds on purpose, and this state exists precisely to score
        // the ANIMATED frame (rule: assert the animated value is mid-flight).
        fixture.isPlaying = true
        await check("annotation-pop-enter")

        // 21 — annotation build effects: explode mid-exit (t = end − 0.15).
        reset { _ in
            var rect = Annotation(type: .rectangle, startTime: t0 - 2, endTime: t0 + 0.15)
            rect.x = 0.5; rect.y = 0.4
            rect.arrowEndX = 0.75; rect.arrowEndY = 0.6
            rect.exitEffect = .explode
            fixture.project.annotations = [rect]
        }
        await check("annotation-explode-exit")
        fixture.isPlaying = false

        // 22 — backdrop blackout, asserted structurally (not a screenshot):
        // the dim must cover the frame corners AND must leave the rectangle's
        // cutout untouched. A mean-diff golden can't distinguish "no dim" from
        // "dim everywhere" reliably at low opacities; direct pixel samples can.
        do {
            var spot = Annotation(type: .rectangle, startTime: 0, endTime: 10)
            spot.x = 0.3; spot.y = 0.3; spot.arrowEndX = 0.7; spot.arrowEndY = 0.7
            spot.backdropOpacity = 0.8
            spot.enterEffect = .none; spot.exitEffect = .none
            spot.showBackground = false; spot.lineWidth = 0; spot.showShadow = false
            // The video occupies an inset rect, like a padded canvas. The dim
            // must cover the video's own corner, leave the shape cutout clear,
            // AND stop dead at the video's edge — spilling onto the canvas
            // background is the "black slab behind the tilted card" bug.
            let side: CGFloat = 200
            let vr = CGRect(x: 40, y: 40, width: 120, height: 120)
            if let img = AnnotationRenderer.image(
                size: CGSize(width: side, height: side), annotations: [spot],
                currentTime: 5, videoRect: vr, scale: 1, chrome: nil, rasterScale: 1
            ), let px = HarnessPixels.rgba(img) {
                defer { px.deallocate() }
                func alphaAt(_ x: Int, _ y: Int) -> Int {
                    Int((px.bytes + y * px.bytesPerRow + x * 4)[3])
                }
                let videoEdge = alphaAt(44, 44)     // just inside videoRect (0.8 ≈ 204)
                let hole = alphaAt(100, 100)        // centre of the cutout
                let canvas = alphaAt(10, 10)        // canvas background — untouched
                let ok = videoEdge > 150 && hole < 10 && canvas < 10
                emit("BACKDROP video-dim=\(videoEdge) hole=\(hole) canvas=\(canvas) \(ok ? "PASS" : "FAIL")")
                if !ok { failures += 1 }
            } else {
                emit("BACKDROP render failed FAIL")
                failures += 1
            }
        }

        // 11 — cursor pin under zoom+tilt: crop around the compositor's
        // warped cursor position and compare that neighborhood only.
        reset { _ in
            fixture.project.zoomRegions = [ZoomRegion(startTime: t0 - 1.5, endTime: t0 + 2, zoomLevel: 2.0, focalPoint: CGPoint(x: 0.5, y: 0.5))]
            fixture.project.tiltRegions = [TiltRegion(startTime: t0 - 1, endTime: t0 + 2, pitch: 20, yaw: -10, roll: 0)]
        }
        fixture.currentTime = t0
        await settle(0.45)
        compositor.schedule(compositorInput(fixture))
        await settle(0.35)
        if let warped = compositor.debugWarpedCursorCenter() {
            let crop = CGRect(x: warped.x - 40, y: warped.y - 40, width: 80, height: 80)
                .intersection(CGRect(origin: .zero, size: paneSize))
            await check("cursor-pin", cropTo: crop)
        } else {
            emit("STATE cursor-pin no-cursor FAIL")
            failures += 1
        }

        // 13 — a tilt spring must re-rasterize the device chrome ZERO times.
        //
        // Every static device state above passes whether the chrome is cached
        // or redrawn from scratch each frame, because each is a settled frame.
        // The shipped bug lived entirely in the motion: the cache key carried
        // the tilt angles quantized to 0.1 degrees, so a spring sweeping 14
        // degrees threw the cache away ~140 times and redrew the whole chrome
        // at ~53ms a frame — roughly 19fps on device segments while screen
        // segments stayed fluid.
        //
        // So this asserts on the RATE OF WORK across a sequence, and pins the
        // tilt mid-flight so it cannot pass by simply not animating.
        do {
            reset { s in
                s.showDeviceFrame = true
                fixture.project.recordingSourceKind = .device
                fixture.project.tiltRegions = [
                    TiltRegion(startTime: t0 - 1, endTime: t0 + 3, pitch: 14, yaw: -10, roll: 0)
                ]
            }
            fixture.currentTime = t0 - 1.02
            compositor.schedule(compositorInput(fixture))
            await settle(0.05)

            // Warm the cache, then count only the animating frames.
            let before = DeviceBezelRenderer.rasterCount
            var angles: [Double] = []
            for step in 0..<40 {
                fixture.currentTime = t0 - 1.0 + Double(step) * 0.01
                compositor.schedule(compositorInput(fixture))
                await settle(0.016)
                angles.append(compositor.debugTiltAngles().pitch)
            }
            let rasters = DeviceBezelRenderer.rasterCount - before

            // Mid-flight: the spring must actually be moving, and must not have
            // arrived. A frozen tilt would trivially re-raster nothing.
            let moved = zip(angles, angles.dropFirst()).contains { abs($0 - $1) > 0.001 }
            let midFlight = angles.contains { $0 > 0.05 && $0 < 13.9 }
            emit("TILT-MOTION spans \(String(format: "%.2f..%.2f", angles.first ?? 0, angles.last ?? 0)) "
                 + "moving=\(moved) midFlight=\(midFlight) \(moved && midFlight ? "PASS" : "FAIL")")
            if !(moved && midFlight) { failures += 1 }

            emit("TILT-RASTERS \(rasters) across \(angles.count) animating frames "
                 + "\(rasters == 0 ? "PASS" : "FAIL")")
            if rasters != 0 { failures += 1 }
        }

        // 12a — smoothing must not MOVE the cursor.
        //
        // The filter was a causal EMA, so its output could only ever trail the
        // real pointer, and the error grew with speed instead of staying
        // bounded: on a real recording, 35px mean and 564px worst on a 1492px
        // frame. No pixel gate caught it because every static state has a
        // stationary cursor — the failure only exists while moving.
        do {
            var smoothFailures = 0
            func expect(_ name: String, _ ok: Bool, _ detail: String) {
                emit("CURSOR-SMOOTH \(name) \(detail) \(ok ? "PASS" : "FAIL")")
                if !ok { smoothFailures += 1 }
            }

            // Fast diagonal sweep, 60Hz — the motion that exposed it.
            let path = (0..<180).map { i in
                CursorEvent(timestamp: Double(i) / 60.0,
                            x: 40 + Double(i) * 8, y: 30 + Double(i) * 5, isClick: false)
            }
            let smoothed = CursorSmoother(factor: 0.15).smooth(events: path)
            var worst = 0.0
            for (raw, sm) in zip(path, smoothed) {
                worst = max(worst, hypot(raw.x - sm.x, raw.y - sm.y))
            }
            expect("no lag under motion", worst < 12,
                   String(format: "worst deviation %.1fpx over a 1440px sweep", worst))

            // Timestamps must survive: shifting one retimes the whole path.
            expect("timestamps preserved",
                   zip(path, smoothed).allSatisfy { abs($0.timestamp - $1.timestamp) < 1e-9 }, "")

            // Clicks must stay on their own sample or the ripple fires in the
            // wrong place.
            let clicky = [
                CursorEvent(timestamp: 0, x: 0, y: 0, isClick: false),
                CursorEvent(timestamp: 0.1, x: 100, y: 100, isClick: true),
                CursorEvent(timestamp: 0.2, x: 200, y: 200, isClick: false),
            ]
            let smoothedClicks = CursorSmoother(factor: 0.15).smooth(events: clicky)
            expect("clicks preserved",
                   smoothedClicks.map(\.isClick) == [false, true, false]
                    && smoothedClicks[1].x == clicky[1].x
                    && smoothedClicks[1].y == clicky[1].y,
                   "click position must remain raw")

            // Smoothing OFF must be EXACT, not frozen. The old EMA read
            // factor 0 as infinite smoothing and pinned the cursor to its
            // first sample for the whole recording.
            let off = CursorSmoother(factor: 0).smooth(events: path)
            let exact = zip(path, off).allSatisfy { abs($0.x - $1.x) < 1e-9 && abs($0.y - $1.y) < 1e-9 }
            expect("factor 0 is a passthrough", exact,
                   exact ? "" : "output pinned to \(off.first.map { "(\($0.x),\($0.y))" } ?? "?")")

            failures += smoothFailures
        }

        // 12b — cursor mapping is EXACT, at several points across the frame.
        //
        // `cursor-pin` above proves the warp survives zoom and tilt, but it
        // checks ONE position and scores it as pixels, so a systematic offset
        // of a few percent hides inside the crop. This asserts the geometry
        // directly: put the cursor at a known fraction of the recorded
        // coordinate space and require the composited centre to land at the
        // same fraction of the video rect, within a pixel.
        //
        // Uses the one-pixel width difference produced by HEVC's even-dimension
        // requirement after cropping the real 1369px-wide Chrome window.
        do {
            let savedProject = fixture.project
            let savedVideo = fixture.videoSize
            let savedCoord = fixture.coordinateSize
            let savedEvents = fixture.cursorEvents
            let savedTime = fixture.currentTime

            // Fixed Chrome take: the SCK surface was 1492x948, but the actual
            // content/cursor space is 1369x872. HEVC writes the width as 1368.
            let vid = CGSize(width: 1368, height: 872)
            let space = CGSize(width: 1369, height: 872)
            let clean = makeFixtureProject()
            clean.settings.showDeviceFrame = false
            clean.settings.showCamera = false
            clean.settings.showWatermark = false
            clean.settings.showSubtitles = false
            clean.settings.cursorScale = 1.0
            clean.zoomRegions = []
            clean.tiltRegions = []
            fixture.project = clean
            fixture.videoSize = vid
            fixture.coordinateSize = space

            let ct = clean.effectiveTrimStart + 1.0
            var cursorFailures = 0
            for (fx, fy) in [(0.25, 0.25), (0.5, 0.5), (0.75, 0.4), (0.4, 0.8)] {
                fixture.cursorEvents = [
                    CursorEvent(timestamp: ct - clean.effectiveTrimStart,
                                x: space.width * fx, y: space.height * fy, isClick: false)
                ]
                fixture.currentTime = ct
                compositor.schedule(compositorInput(fixture))
                await settle(0.12)

                guard let got = compositor.debugCursorHotspot(),
                      let rect = compositor.debugVideoRect() else {
                    emit("CURSOR-MAP (\(fx),\(fy)) no cursor FAIL")
                    cursorFailures += 1
                    continue
                }
                let want = CGPoint(x: rect.minX + rect.width * fx,
                                   y: rect.minY + rect.height * fy)
                let dx = abs(got.x - want.x), dy = abs(got.y - want.y)
                let ok = dx <= 1.0 && dy <= 1.0
                emit(String(format:
                    "CURSOR-MAP (%.2f,%.2f) want=(%.1f,%.1f) got=(%.1f,%.1f) d=(%.2f,%.2f) %@",
                    fx, fy, want.x, want.y, got.x, got.y, dx, dy, ok ? "PASS" : "FAIL"))
                if !ok { cursorFailures += 1 }
            }

            // Size changes grow the sprite around its hotspot; the recorded
            // point itself must never move. This is an exact structural check,
            // not a visual diff that can hide a few-pixel drift.
            let resizeFraction = CGPoint(x: 0.63, y: 0.57)
            fixture.cursorEvents = [
                CursorEvent(
                    timestamp: ct - clean.effectiveTrimStart,
                    x: space.width * resizeFraction.x,
                    y: space.height * resizeFraction.y,
                    isClick: false
                )
            ]
            var resizeHotspots: [(scale: Double, point: CGPoint)] = []
            var resizeWidths: [(scale: Double, width: CGFloat)] = []
            var contentsPresentOK = true
            for scale in [0.5, 1.0, 1.5, 3.0] {
                clean.settings.cursorScale = scale
                compositor.schedule(compositorInput(fixture))
                await settle(0.12)
                if let point = compositor.debugCursorHotspot() {
                    resizeHotspots.append((scale, point))
                }
                if let layer = compositor.debugCursorLayer() {
                    resizeWidths.append((scale, layer.frame.width))
                    contentsPresentOK = contentsPresentOK && layer.contents != nil
                } else {
                    contentsPresentOK = false
                }
            }
            let referenceHotspot = resizeHotspots.first?.point
            let worstResizeDrift = resizeHotspots.reduce(CGFloat.zero) { worst, sample in
                guard let referenceHotspot else { return .infinity }
                return max(worst, hypot(
                    sample.point.x - referenceHotspot.x,
                    sample.point.y - referenceHotspot.y
                ))
            }
            let sizePinned = resizeHotspots.count == 4 && worstResizeDrift < 0.001
            // The slider must actually change the sprite: width at 3.0× is 6×
            // the width at 0.5×. A layout path that ignores cursorScale (the
            // "resize does nothing" regression) fails this even though every
            // hotspot check above passes trivially on a frozen sprite.
            let sizeScales: Bool = {
                guard resizeWidths.count == 4,
                      let smallest = resizeWidths.first?.width, smallest > 0,
                      let largest = resizeWidths.last?.width else { return false }
                return abs(largest / smallest - 6.0) < 0.01
            }()
            // Motion physics is pure math — assert its contract directly:
            // no motion → identity; the tip is the transform's FIXED POINT
            // (the one thing that must never move); rotation follows the
            // horizontal direction; drag trails opposite the motion; and the
            // exporter's Y-flip mirrors rotation exactly.
            do {
                let space = CGSize(width: 1000, height: 800)
                let vr = CGRect(x: 0, y: 0, width: 500, height: 400)
                let still = (0..<20).map {
                    CursorEvent(timestamp: Double($0) * 0.05, x: 500, y: 400, isClick: false)
                }
                let moving = (0..<20).map {
                    CursorEvent(timestamp: Double($0) * 0.05, x: 100 + Double($0) * 40, y: 400, isClick: false)
                }
                let stillPose = CursorPhysicsMath.pose(
                    events: still, at: 0.5, coordinateSize: space, videoRect: vr,
                    spriteHeight: 28, tilt: 1, stretch: 1, drag: 1, weight: 1)
                let movePose = CursorPhysicsMath.pose(
                    events: moving, at: 0.5, coordinateSize: space, videoRect: vr,
                    spriteHeight: 28, tilt: 1, stretch: 1, drag: 1, weight: 1)
                let tip = CGPoint(x: 2, y: 2)
                let m = CursorPhysicsMath.affineTransform(pose: movePose, tip: tip, spriteHeight: 28)
                let tipMoved = tip.applying(m)
                let tipFixed = hypot(tipMoved.x - tip.x, tipMoved.y - tip.y) < 0.0001
                let flipped = movePose.yFlipped()
                let physicsOK = stillPose.isIdentity
                    && !movePose.isIdentity
                    && movePose.rotation > 0            // rightward motion leans right
                    && movePose.bodyOffset.dx < 0       // body trails the motion
                    && movePose.stretch > 1
                    && tipFixed
                    && flipped.rotation == -movePose.rotation
                emit(String(format: "CURSOR-PHYSICS rest=identity moving(rot=%.3f dx=%.2f stretch=%.3f) tip-drift=%.5f %@",
                            movePose.rotation, movePose.bodyOffset.dx, movePose.stretch,
                            hypot(tipMoved.x - tip.x, tipMoved.y - tip.y),
                            physicsOK ? "PASS" : "FAIL"))
                if !physicsOK { cursorFailures += 1 }
            }

            // Fluid movement: the spring must be deterministic, must settle
            // on the raw endpoint, must actually overshoot a step at low
            // friction (proof it does SOMETHING), and — the invariant — a
            // click must land exactly on the raw click position.
            do {
                var raw: [CursorEvent] = (0..<60).map {
                    CursorEvent(timestamp: Double($0) * 0.05, x: $0 < 10 ? 100 : 600, y: 300, isClick: false)
                }
                raw[40] = CursorEvent(timestamp: 2.0, x: 600, y: 300, isClick: true)
                // Low friction proves the spring physically overshoots a step;
                // a damped run proves it settles. One parameter set cannot
                // honestly show both inside a short trace.
                let a = CursorSpringMath.simulate(events: raw, tension: 300, friction: 8, mass: 1)
                let b = CursorSpringMath.simulate(events: raw, tension: 300, friction: 8, mass: 1)
                let damped = CursorSpringMath.simulate(events: raw, tension: 300, friction: 30, mass: 1)
                let deterministic = a.count == b.count
                    && zip(a, b).allSatisfy { $0.x == $1.x && $0.y == $1.y && $0.timestamp == $1.timestamp }
                let settled = abs((damped.last?.x ?? 0) - 600) < 1.5
                let overshoots = a.contains { $0.x > 605 }
                let click = a.first { $0.isClick }
                let clickPinned = click != nil && abs((click?.x ?? 0) - 600) < 0.001
                // A HELD drag (contiguous click run) must survive resampling
                // as one contiguous run: fragmenting it into isolated clicks
                // is the "ripple storm on every text highlight" bug.
                let dragRaw: [CursorEvent] = (0..<40).map { i in
                    let t = Double(i) * 0.05
                    let held = t >= 0.5 && t <= 1.5
                    return CursorEvent(
                        timestamp: t,
                        x: 100 + Double(i) * 20, y: 300,
                        isClick: held
                    )
                }
                let dragSim = CursorSpringMath.simulate(events: dragRaw, tension: 220, friction: 24, mass: 1)
                let clicks = ClickRippleOverlay.discreteClickTimes(
                    from: dragSim, coordinateSize: CGSize(width: 1000, height: 800))
                let runs = ClickRippleOverlay.dragHighlightRuns(
                    from: dragSim, coordinateSize: CGSize(width: 1000, height: 800))
                let dragSurvives = runs.count == 1 && clicks.isEmpty
                let springOK = deterministic && settled && overshoots && clickPinned && dragSurvives
                emit(String(format: "CURSOR-SPRING deterministic=%@ settled=%.1f overshoot=%@ click-pinned=%@ %@",
                            deterministic ? "yes" : "NO", Double(damped.last?.x ?? 0),
                            overshoots ? "yes" : "NO", clickPinned ? "yes" : "NO",
                            springOK ? "PASS" : "FAIL"))
                if !springOK { cursorFailures += 1 }
            }

            emit(String(format: "CURSOR-SIZE-PIN 0.5x...3.0x drift=%.4fpx %@",
                        worstResizeDrift, sizePinned ? "PASS" : "FAIL"))
            emit(String(format: "CURSOR-SIZE-SCALES 0.5x->3.0x ratio=%.3f %@",
                        resizeWidths.count == 4 && (resizeWidths.first?.width ?? 0) > 0
                            ? Double((resizeWidths.last?.width ?? 0) / (resizeWidths.first?.width ?? 1))
                            : 0,
                        sizeScales ? "PASS" : "FAIL"))
            emit("CURSOR-CONTENTS present \(contentsPresentOK ? "PASS" : "FAIL")")
            if !sizePinned { cursorFailures += 1 }
            if !sizeScales { cursorFailures += 1 }
            if !contentsPresentOK { cursorFailures += 1 }
            failures += cursorFailures

            fixture.project = savedProject
            fixture.videoSize = savedVideo
            fixture.coordinateSize = savedCoord
            fixture.cursorEvents = savedEvents
            fixture.currentTime = savedTime
        }

        // 12c — the raw ScreenCaptureKit geometry from the Chrome repro.
        // This is upstream of the compositor, so pixel goldens alone cannot
        // cover it. The broken take encoded the whole 1492x948 IOSurface even
        // though the visible window occupied (123,46,1369,872).
        do {
            var geometryFailures = 0
            func expect(_ name: String, _ ok: Bool, _ detail: String) {
                let status = ok ? "PASS" : "FAIL"
                emit("WINDOW-GEOMETRY \(name) \(detail) \(status)")
                if !ok { geometryFailures += 1 }
            }

            // SCK reports bounding/content geometry in surface points. This
            // Retina frame's 2x metadata must become the measured pixel box.
            let crop = ScreenRecorder.windowSurfaceCropRectForTesting(
                metadataRects: [CGRect(x: 61.5, y: 23, width: 684.5, height: 436)],
                scaleFactor: 2,
                surfaceSize: CGSize(width: 1492, height: 948)
            )
            let expectedCrop = CGRect(x: 123, y: 46, width: 1369, height: 872)
            expect("chrome crop", crop == expectedCrop,
                   "want=\(expectedCrop) got=\(String(describing: crop))")
            let ciCrop = ScreenRecorder.coreImageCropRectForTesting(
                surfaceCropRect: expectedCrop,
                sourceHeight: 948
            )
            let expectedCICrop = CGRect(x: 123, y: 30, width: 1369, height: 872)
            expect("crop orientation", ciCrop == expectedCICrop,
                   "want=\(expectedCICrop) got=\(ciCrop)")

            // The metadata can ALSO lie by describing the padded surface as
            // content (the Chrome black-frame + offset-cursor recording). The
            // pixel tightener must trim transparent and pure-black borders —
            // and must NOT trim a dark-but-real UI edge (Chrome's #202124).
            func syntheticBuffer(
                width: Int, height: Int, inset: Int,
                border: (b: UInt8, g: UInt8, r: UInt8, a: UInt8)
            ) -> CVPixelBuffer? {
                var pb: CVPixelBuffer?
                CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pb)
                guard let pb, CVPixelBufferLockBaseAddress(pb, []) == kCVReturnSuccess else { return nil }
                let bpr = CVPixelBufferGetBytesPerRow(pb)
                let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
                for y in 0..<height {
                    for x in 0..<width {
                        let p = base + y * bpr + x * 4
                        let isContent = x >= inset && x < width - inset
                            && y >= inset && y < height - inset
                        if isContent { p[0] = 40; p[1] = 40; p[2] = 40; p[3] = 255 }
                        else { p[0] = border.b; p[1] = border.g; p[2] = border.r; p[3] = border.a }
                    }
                }
                CVPixelBufferUnlockBaseAddress(pb, [])
                return pb
            }
            let fullRect = CGRect(x: 0, y: 0, width: 200, height: 160)
            if let transparent = syntheticBuffer(width: 200, height: 160, inset: 20, border: (0, 0, 0, 0)) {
                let tight = ScreenRecorder.tightenCropToOpaqueContent(transparent, within: fullRect)
                expect("padding trim transparent", tight == CGRect(x: 20, y: 20, width: 160, height: 120),
                       "got=\(tight)")
            }
            if let black = syntheticBuffer(width: 200, height: 160, inset: 14, border: (0, 0, 0, 255)) {
                let tight = ScreenRecorder.tightenCropToOpaqueContent(black, within: fullRect)
                expect("padding trim black", tight == CGRect(x: 14, y: 14, width: 172, height: 132),
                       "got=\(tight)")
            }
            if let dark = syntheticBuffer(width: 200, height: 160, inset: 20, border: (36, 33, 32, 255)) {
                let tight = ScreenRecorder.tightenCropToOpaqueContent(dark, within: fullRect)
                expect("dark UI not trimmed", tight == fullRect, "got=\(tight)")
            }

            // The tilt homography inverse must round-trip: project a point
            // forward (exactly what the compositor renders with), invert it,
            // and land back on the original. Hit-testing under a tilted card
            // depends on this — a broken inverse offsets every click.
            do {
                let center = CGPoint(x: 360, y: 202)
                let dist = TiltMath.perspectiveDistance(for: CGSize(width: 720, height: 405))
                let h = TiltMath.projectionTransform(
                    pitchDegrees: 20, yawDegrees: -28, rollDegrees: 4,
                    center: center, distance: dist
                )
                let samples = [CGPoint(x: 100, y: 80), CGPoint(x: 500, y: 300), center]
                var worst: CGFloat = 0
                var forwardAgrees = true
                for p in samples {
                    let projected = h.applied(to: p)
                    let viaPoint = TiltMath.projectedPoint(
                        p, center: center, pitchDegrees: 20, yawDegrees: -28,
                        rollDegrees: 4, distance: dist, yUp: false
                    )
                    forwardAgrees = forwardAgrees
                        && hypot(projected.x - viaPoint.x, projected.y - viaPoint.y) < 0.01
                    if let inv = h.inverted() {
                        let back = inv.applied(to: projected)
                        worst = max(worst, hypot(back.x - p.x, back.y - p.y))
                    } else {
                        worst = .infinity
                    }
                }
                expect("tilt inverse round-trip", worst < 0.01 && forwardAgrees,
                       String(format: "worst=%.5f forward-agrees=%@", worst, forwardAgrees ? "yes" : "NO"))
            }

            // Cover-zoom: a card rolled 36° at zoom 2 must be boosted enough
            // that its rotated extent still spans the canvas on both axes —
            // and the compensation must vanish continuously at zoom ≈ 1.
            do {
                let aspect: CGFloat = 16.0 / 9.0
                let z = TiltMath.effectiveCoverZoom(
                    zoom: 2, pitchDegrees: 0, yawDegrees: 0, rollDegrees: 36, aspect: aspect)
                let r = 36.0 * Double.pi / 180
                let c = CGFloat(cos(r)), s = CGFloat(sin(r))
                let covers = z >= 2 * (c + s / aspect) - 0.001 && z >= 2 * (c + s * aspect) - 0.001
                let restingZoom = TiltMath.effectiveCoverZoom(
                    zoom: 1.0005, pitchDegrees: 0, yawDegrees: 0, rollDegrees: 36, aspect: aspect)
                let continuous = abs(restingZoom - 1.0005) < 0.001
                let noTilt = TiltMath.effectiveCoverZoom(
                    zoom: 2, pitchDegrees: 0, yawDegrees: 0, rollDegrees: 0, aspect: aspect) == 2
                expect("cover zoom", covers && continuous && noTilt,
                       String(format: "z=%.3f covers=%@ continuous=%@ noTilt=%@",
                              z, covers ? "yes" : "NO", continuous ? "yes" : "NO", noTilt ? "yes" : "NO"))
            }

            // Intro slide: starts fully offscreen, is mid-flight partway
            // (the "static frames only" trap — assert the animated value),
            // overshoots past home, and is EXACTLY identity once done.
            do {
                let dur = 0.9
                let start = IntroSlideMath.state(style: .left, at: 0, duration: dur)
                let mid = IntroSlideMath.state(style: .left, at: 0.3, duration: dur)
                let late = IntroSlideMath.state(style: .left, at: 0.62, duration: dur)
                let done = IntroSlideMath.state(style: .left, at: dur + 0.01, duration: dur)
                let offscreen = start.offset.x <= -IntroSlideMath.travel + 0.001
                    && start.scale < 1 && start.active
                let midFlight = mid.active
                    && mid.offset.x > start.offset.x && mid.offset.x < 0
                    && mid.scale > start.scale && mid.scale < 1
                let overshoots = late.offset.x > 0.005 // easeOutBack passes home
                let settled = done == IntroSlideMath.State()
                let off = IntroSlideMath.state(style: .off, at: 0.1, duration: dur)
                    == IntroSlideMath.State()
                // Mid-timeline slide: identity at both ends, offscreen in the
                // middle beat — the anywhere-placement out-and-back gesture.
                let midBefore = IntroSlideMath.state(
                    style: .left, at: 1.99, startTime: 2, duration: 1) == IntroSlideMath.State()
                let midBeat = IntroSlideMath.state(
                    style: .left, at: 2.5, startTime: 2, duration: 1)
                let midOffscreen = midBeat.offset.x <= -IntroSlideMath.travel + 0.001
                let midAfter = IntroSlideMath.state(
                    style: .left, at: 3.01, startTime: 2, duration: 1) == IntroSlideMath.State()
                let anywhere = midBefore && midOffscreen && midAfter
                expect("intro slide", offscreen && midFlight && overshoots && settled && off && anywhere,
                       "offscreen=\(offscreen) mid=\(midFlight) overshoot=\(overshoots) settled=\(settled) off=\(off) anywhere=\(anywhere)")
            }

            // Curtain unveil: full cover at t=0, MID-FLIGHT partial cover with
            // a non-empty flap (the "static frames only" trap — assert the
            // animated value), fold ⟂ diagonal, shadow fading near the end,
            // exact no-op once done or off, and reflection self-consistency
            // (the fold line is its own mirror).
            do {
                let dur = 1.2
                let p0 = CurtainUnveilMath.state(
                    corner: .topLeft, at: 0, startTime: 0, duration: dur)
                let fullCover = p0.active
                    && abs(CurtainUnveilMath.polygonArea(p0.coverPolygon) - 1) < 0.001
                    && p0.flapPolygon.isEmpty
                let mid = CurtainUnveilMath.state(
                    corner: .topLeft, at: dur * 0.5, startTime: 0, duration: dur)
                let midArea = CurtainUnveilMath.polygonArea(mid.coverPolygon)
                let midFlight = mid.active
                    && midArea > 0.001 && midArea < 0.999
                    && CurtainUnveilMath.polygonArea(mid.flapPolygon) > 0.001
                // Top-left peel: diagonal is (1,1)/√2 — the fold must be ⟂.
                let foldDir = CGPoint(x: mid.foldEnd.x - mid.foldStart.x,
                                      y: mid.foldEnd.y - mid.foldStart.y)
                let foldLen = hypot(foldDir.x, foldDir.y)
                let perp = foldLen > 0.001
                    && abs((foldDir.x + foldDir.y) / foldLen) < 0.0001
                let late = CurtainUnveilMath.state(
                    corner: .topLeft, at: dur * 0.97, startTime: 0, duration: dur)
                let shadowFades = late.active && late.shadowStrength < mid.shadowStrength
                let done = !CurtainUnveilMath.state(
                    corner: .topLeft, at: dur + 0.01, startTime: 0, duration: dur).active
                let off = CurtainUnveilMath.state(
                    corner: .off, at: 0.1, startTime: 0, duration: dur) == CurtainUnveilMath.State()
                let ra = CurtainUnveilMath.reflect(
                    mid.foldStart, acrossLineThrough: mid.foldStart, mid.foldEnd)
                let rb = CurtainUnveilMath.reflect(
                    mid.foldEnd, acrossLineThrough: mid.foldStart, mid.foldEnd)
                let selfReflect = hypot(ra.x - mid.foldStart.x, ra.y - mid.foldStart.y) < 0.0001
                    && hypot(rb.x - mid.foldEnd.x, rb.y - mid.foldEnd.y) < 0.0001
                expect("curtain unveil",
                       fullCover && midFlight && perp && shadowFades && done && off && selfReflect,
                       "cover=\(fullCover) mid=\(midFlight) perp=\(perp) shadow=\(shadowFades) done=\(done) off=\(off) reflect=\(selfReflect)")

                // Flick motion: the sweep may NEVER regress (monotonic), must
                // land at EXACTLY 1, and its VELOCITY must peak late — the
                // whip covers more ground in [0.7, 0.95] than the anticipation
                // does in [0.3, 0.5].
                var monotonic = true
                var prev = -0.000001
                for i in 0...100 {
                    let e = CurtainUnveilMath.sweepEase(Double(i) / 100)
                    if e < prev - 0.0000001 { monotonic = false }
                    prev = e
                }
                let landsExactly = CurtainUnveilMath.sweepEase(1) == 1
                    && CurtainUnveilMath.sweepEase(0) == 0
                let lateGain = CurtainUnveilMath.sweepEase(0.95) - CurtainUnveilMath.sweepEase(0.7)
                let earlyGain = CurtainUnveilMath.sweepEase(0.5) - CurtainUnveilMath.sweepEase(0.3)
                let velocityPeaksLate = lateGain > earlyGain
                expect("curtain flick sweep",
                       monotonic && landsExactly && velocityPeaksLate,
                       String(format: "monotonic=%@ lands=%@ late=%.3f early=%.3f",
                              monotonic ? "yes" : "NO", landsExactly ? "yes" : "NO",
                              lateGain, earlyGain))

                // Flap release: the over-fold RISES through the peel and ramps
                // UP through the release (the whip) — no settling back to the
                // mirror — while the flap stays present and FADES OUT over the
                // final window, leaving the surface with momentum. The lift is
                // structural mid-peel: reflecting the flap back across the
                // fold must overshoot into the covered side.
                let overMid = CurtainUnveilMath.flapOverfoldRadians(0.5)
                let overRelease = CurtainUnveilMath.flapOverfoldRadians(0.9)
                let overWhipRises = overRelease > CurtainUnveilMath.flapOverfoldRadians(0.8)
                    && CurtainUnveilMath.flapOverfoldRadians(0.8) >= overMid
                    && overMid > 0.01
                func maxCoveredSideExcursion(_ s: CurtainUnveilMath.State) -> CGFloat {
                    // Signed distance past the fold toward the covered side
                    // (top-left peel: covered is where x+y exceeds the fold's).
                    let foldSum = s.foldStart.x + s.foldStart.y
                    return s.flapPolygon.map {
                        let back = CurtainUnveilMath.reflect(
                            $0, acrossLineThrough: s.foldStart, s.foldEnd)
                        return (back.x + back.y) - foldSum
                    }.max() ?? -1
                }
                let inRelease = CurtainUnveilMath.state(
                    corner: .topLeft, at: dur * 0.92, startTime: 0, duration: dur)
                let deepRelease = CurtainUnveilMath.state(
                    corner: .topLeft, at: dur * 0.97, startTime: 0, duration: dur)
                let flapReleases = !inRelease.flapPolygon.isEmpty
                    && inRelease.flapOpacity < 1 && inRelease.flapOpacity > 0
                    && deepRelease.flapOpacity < inRelease.flapOpacity
                    && mid.flapOpacity == 1
                    && CurtainUnveilMath.flapReleaseOffset(0.95) > 0
                    && CurtainUnveilMath.flapReleaseOffset(0.75) == 0
                let liftPresent = maxCoveredSideExcursion(mid) > 0.005
                expect("curtain flap release",
                       overWhipRises && flapReleases && liftPresent,
                       String(format: "whipRises=%@ releases=%@ midExc=%.4f op92=%.2f op97=%.2f",
                              overWhipRises ? "yes" : "NO", flapReleases ? "yes" : "NO",
                              Double(maxCoveredSideExcursion(mid)),
                              Double(inRelease.flapOpacity), Double(deepRelease.flapOpacity)))

                // Shadow breathing + whip: wider AND softer mid-peel than near
                // the start, INTENSIFIED during the whip, gone with the flap.
                let breathes = CurtainUnveilMath.shadowWidthFraction(0.5)
                    > CurtainUnveilMath.shadowWidthFraction(0.05)
                    && CurtainUnveilMath.shadowStrengthValue(0.5)
                    < CurtainUnveilMath.shadowStrengthValue(0.05)
                let whipIntensifies = CurtainUnveilMath.shadowStrengthValue(0.85)
                    > CurtainUnveilMath.shadowStrengthValue(0.7)
                let vanishes = CurtainUnveilMath.shadowStrengthValue(1) == 0
                expect("curtain shadow breathes", breathes && whipIntensifies && vanishes,
                       String(format: "w(0.5)=%.4f w(0.05)=%.4f s(0.5)=%.3f s(0.05)=%.3f s(0.85)=%.3f s(0.7)=%.3f s(1)=%.3f",
                              Double(CurtainUnveilMath.shadowWidthFraction(0.5)),
                              Double(CurtainUnveilMath.shadowWidthFraction(0.05)),
                              Double(CurtainUnveilMath.shadowStrengthValue(0.5)),
                              Double(CurtainUnveilMath.shadowStrengthValue(0.05)),
                              Double(CurtainUnveilMath.shadowStrengthValue(0.85)),
                              Double(CurtainUnveilMath.shadowStrengthValue(0.7)),
                              Double(CurtainUnveilMath.shadowStrengthValue(1))))

                // Logo on the curtain: the SHARED rasterizer must produce a
                // structurally different cover with a logo than without (a
                // mean-diff-blind gate would miss a silently dropped logo).
                var logoChanges = false
                if let logoCG: CGImage = {
                    guard let ctx = CGContext(
                        data: nil, width: 8, height: 8, bitsPerComponent: 8,
                        bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                    else { return nil }
                    ctx.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             components: [1, 1, 1, 1])!)
                    ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
                    return ctx.makeImage()
                }() {
                    // Early in the peel — the cover must still hold the card
                    // centre, where the logo sits (mid-peel it is clipped out).
                    let early = CurtainUnveilMath.state(
                        corner: .topLeft, at: dur * 0.2, startTime: 0, duration: dur)
                    let plain = CurtainUnveilMath.renderImage(
                        state: early, size: CGSize(width: 64, height: 64))
                    let branded = CurtainUnveilMath.renderImage(
                        state: early, size: CGSize(width: 64, height: 64),
                        style: CurtainUnveilMath.CoverStyle(logo: logoCG, logoScale: 0.4))
                    if let a = plain?.dataProvider?.data as Data?,
                       let b = branded?.dataProvider?.data as Data? {
                        logoChanges = a != b
                    }
                }
                expect("curtain logo raster", logoChanges, "differs=\(logoChanges)")

                // Card clip: with a rounded card the FULL-COVER curtain raster
                // must be transparent at the square corner OUTSIDE the rounded
                // path — and opaque there without the clip (proves the probe
                // bites). Both renderers consume this exact rasterizer, so a
                // green here covers preview AND export.
                func cornerAlpha(_ img: CGImage?) -> Int {
                    guard let img, let data = img.dataProvider?.data as Data? else { return -1 }
                    let bpr = img.bytesPerRow
                    // Pixel (1,1): inside the square bounds, outside a
                    // 16px-radius rounded corner on a 64px card.
                    let offset = 1 * bpr + 1 * 4 + 3 // RGBA8, alpha byte
                    guard offset < data.count else { return -1 }
                    return Int(data[offset])
                }
                let fullCoverState = CurtainUnveilMath.state(
                    corner: .topLeft, at: 0, startTime: 0, duration: dur)
                var roundedStyle = CurtainUnveilMath.CoverStyle()
                roundedStyle.cardClip = CurtainUnveilMath.cardClip(
                    frameShape: .roundedRect, cornerRadius: 16,
                    cardSize: CGSize(width: 64, height: 64), deviceScreen: nil)
                let clippedAlpha = cornerAlpha(CurtainUnveilMath.renderImage(
                    state: fullCoverState, size: CGSize(width: 64, height: 64),
                    style: roundedStyle))
                let squareAlpha = cornerAlpha(CurtainUnveilMath.renderImage(
                    state: fullCoverState, size: CGSize(width: 64, height: 64)))
                expect("curtain card clip",
                       clippedAlpha == 0 && squareAlpha > 200,
                       "clippedCornerAlpha=\(clippedAlpha) squareCornerAlpha=\(squareAlpha)")
            }

            // Removed-feature tolerance: a project saved while the particle
            // bokeh feature existed carries bokeh* keys in its settings JSON.
            // The hand-rolled decoder must IGNORE unknown keys — the file
            // still loads, the values are simply dropped.
            do {
                var decoded = false
                if let base = try? JSONEncoder().encode(ProjectSettings()),
                   var dict = (try? JSONSerialization.jsonObject(with: base)) as? [String: Any] {
                    dict["bokehEnabled"] = true
                    dict["bokehDensity"] = 0.8
                    dict["bokehSize"] = 0.4
                    dict["bokehTint"] = ["red": 1, "green": 0.9, "blue": 0.8, "opacity": 1]
                    dict["bokehSpikeTimes"] = [1.5, 3.25]
                    if let data = try? JSONSerialization.data(withJSONObject: dict) {
                        decoded = (try? JSONDecoder().decode(ProjectSettings.self, from: data)) != nil
                    }
                }
                expect("legacy bokeh keys ignored", decoded, "decoded=\(decoded)")
            }

            // Depth Focus profile: 0 inside the rect, full outside the band,
            // a monotone smooth ramp across it, falloff widening the band —
            // and the tilt-shift band: symmetric about the centre line, blur
            // growing with perpendicular distance, rotating with the angle.
            do {
                let size = CGSize(width: 1600, height: 900)
                let rect = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.3)
                func area(_ p: CGPoint, falloff: Double = 0.4) -> CGFloat {
                    FocusMath.blurAmount(
                        at: p, regionRect: rect, style: .area,
                        angleDegrees: 0, falloff: falloff, videoSize: size)
                }
                let inside = area(CGPoint(x: 0.5, y: 0.45)) == 0
                let farCorner = area(CGPoint(x: 0.02, y: 0.03)) == 1
                // Monotone smooth ramp along a horizontal ray out of the rect.
                var monotone = true
                var sawMid = false
                var prev: CGFloat = -1
                for i in 0...40 {
                    let x = 0.7 + 0.29 * CGFloat(i) / 40
                    let v = area(CGPoint(x: x, y: 0.45))
                    if v < prev - 0.0001 { monotone = false }
                    if v > 0.1 && v < 0.9 { sawMid = true }
                    prev = v
                }
                // Wider falloff → a softer value at the same distance.
                let probe = CGPoint(x: 0.76, y: 0.45)
                let falloffWidens = area(probe, falloff: 0.9) < area(probe, falloff: 0.1)

                func tilt(_ p: CGPoint, angle: Double) -> CGFloat {
                    FocusMath.blurAmount(
                        at: p, regionRect: rect, style: .tiltShift,
                        angleDegrees: angle, falloff: 0.4, videoSize: size)
                }
                // Angle 0: band runs horizontally through (0.5, 0.45) —
                // points far along the band stay sharp, perpendicular blurs.
                let alongSharp = tilt(CGPoint(x: 0.02, y: 0.45), angle: 0) == 0
                let perpBlurred = tilt(CGPoint(x: 0.5, y: 0.95), angle: 0) > 0
                let symmetric = abs(
                    tilt(CGPoint(x: 0.5, y: 0.45 + 0.3), angle: 0)
                    - tilt(CGPoint(x: 0.5, y: 0.45 - 0.3), angle: 0)) < 0.0001
                let grows = tilt(CGPoint(x: 0.5, y: 0.85), angle: 0)
                    > tilt(CGPoint(x: 0.5, y: 0.7), angle: 0)
                // Angle 90: the band is VERTICAL — the same two probes swap
                // roles (x-offset blurs, y-offset along the band stays sharp).
                let rotatedSharp = tilt(CGPoint(x: 0.5, y: 0.95), angle: 90) == 0
                let rotatedBlurred = tilt(CGPoint(x: 0.02, y: 0.45), angle: 90) > 0
                let tiltOK = alongSharp && perpBlurred && symmetric && grows
                    && rotatedSharp && rotatedBlurred

                // Structural mask check: the SHARED raster both renderers
                // blur with must be black at the rect centre, white at the
                // far corner (sharp centre / fully blurred corner).
                var maskOK = false
                if let mask = FocusMath.maskImage(
                    regionRect: rect, style: .area, angleDegrees: 0,
                    falloff: 0.4, videoSize: size),
                   let data = mask.dataProvider?.data as Data? {
                    let bpr = mask.bytesPerRow
                    let cx = mask.width / 2, cy = Int(0.45 * CGFloat(mask.height))
                    let centerV = Int(data[cy * bpr + cx])
                    let cornerV = Int(data[1 * bpr + 1])
                    maskOK = centerV == 0 && cornerV == 255
                }

                expect("depth focus profile",
                       inside && farCorner && monotone && sawMid && falloffWidens && tiltOK && maskOK,
                       "inside=\(inside) corner=\(farCorner) monotone=\(monotone) mid=\(sawMid) falloff=\(falloffWidens) tilt=\(tiltOK) mask=\(maskOK)")

                // Corner radius control: 0 keeps the whole rect sharp (the
                // in-rect corner probe stays 0), 1 rounds it capsule-like
                // (the same probe falls OUTSIDE the sharp shape and blurs),
                // masks differ between the two, and the default reproduces
                // the original fixed 12%-of-short-side look byte-for-byte.
                func areaR(_ p: CGPoint, radius: Double) -> CGFloat {
                    FocusMath.blurAmount(
                        at: p, regionRect: rect, style: .area,
                        angleDegrees: 0, falloff: 0.4,
                        cornerRadius: radius, videoSize: size)
                }
                // Just inside the rect's top-left corner.
                let cornerProbe = CGPoint(x: 0.305, y: 0.305)
                let sharpKeeps = areaR(cornerProbe, radius: 0) == 0
                let capsuleCuts = areaR(cornerProbe, radius: 1) > 0
                func maskBytes(_ radius: Double) -> Data? {
                    FocusMath.maskImage(
                        regionRect: rect, style: .area, angleDegrees: 0,
                        falloff: 0.4, cornerRadius: radius, videoSize: size)
                        .flatMap { $0.dataProvider?.data as Data? }
                }
                let masksDiffer = maskBytes(0) != nil && maskBytes(0) != maskBytes(1)
                // Default stability: the parameter default IS 0.24, and the
                // default-mask bytes equal an explicit 0.24 render (existing
                // regions decode to this value — nothing shifts).
                let defaultStable = FocusMath.defaultCornerRadius == 0.24
                    && maskBytes(FocusMath.defaultCornerRadius) == FocusMath.maskImage(
                        regionRect: rect, style: .area, angleDegrees: 0,
                        falloff: 0.4, videoSize: size)
                        .flatMap { $0.dataProvider?.data as Data? }
                expect("depth focus corner radius",
                       sharpKeeps && capsuleCuts && masksDiffer && defaultStable,
                       "sharp=\(sharpKeeps) capsule=\(capsuleCuts) masksDiffer=\(masksDiffer) default=\(defaultStable)")
            }

            // Blur styles: strength monotone for both styles, legacy regions
            // decode to the untouched gaussian look, the animated-mosaic
            // jitter is deterministic/bounded/step-quantized and vanishes
            // when animation is off — and structurally, the shared pixelate
            // params produce BLOCKS where the gaussian produces smoothness.
            do {
                let weak = BlurRegion(startTime: 0, endTime: 1, intensity: 0.2)
                let strong = BlurRegion(startTime: 0, endTime: 1, intensity: 0.9)
                let size = CGSize(width: 1200, height: 700)
                let blurMonotone = strong.blurRadius(in: size) > weak.blurRadius(in: size)
                let regionSize = CGSize(width: 480, height: 105)
                let pixMonotone = BlurStyleMath.pixelScale(strength: 0.9, regionSize: regionSize)
                    > BlurStyleMath.pixelScale(strength: 0.2, regionSize: regionSize)

                // Legacy JSON (no style/animated keys) → gaussian, static.
                var legacyOK = false
                if let data = try? JSONEncoder().encode(weak),
                   var dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    dict.removeValue(forKey: "style")
                    dict.removeValue(forKey: "animated")
                    if let stripped = try? JSONSerialization.data(withJSONObject: dict),
                       let decoded = try? JSONDecoder().decode(BlurRegion.self, from: stripped) {
                        legacyOK = decoded.style == .blur && decoded.animated == false
                    }
                }

                let block: CGFloat = 24
                let j1 = BlurStyleMath.gridJitter(at: 1.0, animated: true, blockSize: block)
                let j1b = BlurStyleMath.gridJitter(at: 1.0, animated: true, blockSize: block)
                let j2 = BlurStyleMath.gridJitter(at: 1.0 + BlurStyleMath.animationStep,
                                                  animated: true, blockSize: block)
                let sameStep = BlurStyleMath.gridJitter(
                    at: 1.0 + BlurStyleMath.animationStep * 0.4,
                    animated: true, blockSize: block)
                let jitterOK = j1 == j1b                       // deterministic
                    && j1 == sameStep                          // frozen within a step
                    && j1 != j2                                // moves across steps
                    && abs(j1.x) <= block / 2 && abs(j1.y) <= block / 2
                    && BlurStyleMath.gridJitter(at: 1.0, animated: false, blockSize: block) == .zero
                    && BlurStyleMath.quantizedStep(at: 1.0)
                        != BlurStyleMath.quantizedStep(at: 1.0 + BlurStyleMath.animationStep)

                // Structural: a horizontal gradient through the SHARED
                // pixelate params shows flat plateaus (few distinct values on
                // a scanline); the gaussian keeps it smooth (many values).
                var structural = false
                if let space = CGColorSpace(name: CGColorSpace.sRGB),
                   let gctx = CGContext(
                       data: nil, width: 64, height: 64, bitsPerComponent: 8,
                       bytesPerRow: 0, space: space,
                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                    for x in 0..<64 {
                        gctx.setFillColor(CGColor(
                            colorSpace: space,
                            components: [CGFloat(x) / 63, CGFloat(x) / 63, CGFloat(x) / 63, 1])!)
                        gctx.fill(CGRect(x: x, y: 0, width: 1, height: 64))
                    }
                    if let gradCG = gctx.makeImage() {
                        let src = CIImage(cgImage: gradCG)
                        let ctx = CIContext(options: [.workingColorSpace: NSNull()])
                        func scanlineDistinct(_ img: CIImage) -> Int {
                            guard let out = ctx.createCGImage(
                                img, from: CGRect(x: 0, y: 0, width: 64, height: 64)),
                                let data = out.dataProvider?.data as Data? else { return -1 }
                            let bpr = out.bytesPerRow
                            let bpp = out.bitsPerPixel / 8
                            var values = Set<UInt8>()
                            for x in 0..<64 { values.insert(data[32 * bpr + x * bpp]) }
                            return values.count
                        }
                        let blockSize = BlurStyleMath.pixelScale(
                            strength: 0.7, regionSize: CGSize(width: 64, height: 64))
                        let pix = src.clampedToExtent()
                            .applyingFilter("CIPixellate", parameters: [
                                kCIInputScaleKey: blockSize,
                                kCIInputCenterKey: CIVector(x: 0, y: 0),
                            ])
                            .cropped(to: src.extent)
                        let smooth = src.clampedToExtent()
                            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 4])
                            .cropped(to: src.extent)
                        let pixDistinct = scanlineDistinct(pix)
                        let smoothDistinct = scanlineDistinct(smooth)
                        structural = pixDistinct > 0 && smoothDistinct > 0
                            && pixDistinct < smoothDistinct / 2
                    }
                }

                expect("blur styles",
                       blurMonotone && pixMonotone && legacyOK && jitterOK && structural,
                       "blurMono=\(blurMonotone) pixMono=\(pixMonotone) legacy=\(legacyOK) jitter=\(jitterOK) structural=\(structural)")
            }

            // Unified selection chrome: ONE renderer for every selectable
            // region, and chrome exists ONLY while selected. Blur and
            // highlight are asserted explicitly — they were the live
            // offenders with always-on faint outlines.
            do {
                let canvas = CGSize(width: 720, height: 405)
                let container = CGRect(x: 40, y: 24, width: 640, height: 360)
                func region(_ selected: Bool) -> SelectionChromeKit.Region {
                    .init(rect: CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.3),
                          cornerRadius: 10, isSelected: selected,
                          sliderValue: 0.5, sliderRange: 0.1...1,
                          leadingIcon: "eye", trailingIcon: "eye.slash.fill")
                }
                // Unselected blur-style + highlight-style + focus-style
                // regions → NO chrome at all (nil image).
                let unselected = SelectionChromeKit.image(
                    size: canvas,
                    regions: [region(false), region(false), region(false)],
                    containerRect: container, scale: 2)
                let selected = SelectionChromeKit.image(
                    size: canvas, regions: [region(true), region(false)],
                    containerRect: container, scale: 2)
                expect("unified selection chrome",
                       unselected == nil && selected != nil,
                       "unselectedNil=\(unselected == nil) selectedDrawn=\(selected != nil)")
            }

            // Tilt block boundaries must be SMOOTH for every animation style:
            // simulate the exact shared spring recipe (tiltReturnParams +
            // rampOutScale + settleTowardZero — what BOTH renderers consume)
            // at 120Hz across a 20° block's end and assert the value is
            // continuous, the per-frame velocity change stays bounded through
            // the boundary (the old style→floor omega step measured a
            // 1.29°/s-per-frame kick at t=end for Cinematic), and the spring
            // stiffness itself is continuous across the block end.
            do {
                let animDur = 0.8
                let styles: [ZoomAnimationStyle?] = [nil] + ZoomAnimationStyle.allCases.map { $0 }
                var allSmooth = true
                var worstDvel = 0.0
                var worstStyle = "-"
                var omegaContinuous = true
                for style in styles {
                    let region = TiltRegion(
                        startTime: 0, endTime: 2, pitch: 20, animationStyle: style)
                    var memory: (omega: Double, damping: Double) = (1, 0.88)
                    var value = 0.0, vel = 0.0
                    var prevValue = 0.0, prevVel = 0.0
                    let dt = 1.0 / 120.0
                    var t = 0.0
                    var maxDvalue = 0.0, maxDvel = 0.0
                    while t <= 3.0 {
                        let inBlock = t >= region.startTime && t <= region.endTime
                        let target = inBlock
                            ? region.pitch * TiltMath.rampOutScale(
                                time: t, blockStart: region.startTime,
                                blockEnd: region.endTime, animationDuration: animDur)
                            : 0
                        let params = TiltMath.tiltReturnParams(
                            tiltRegions: [region], at: t,
                            animationDuration: animDur, memory: &memory)
                        let omega = 2.5 / animDur * params.omega
                        let acc = omega * omega * (target - value)
                            - 2 * params.damping * omega * vel
                        vel += acc * dt
                        value += vel * dt
                        if params.returning {
                            ZoomFocalMath.settleTowardZero(&value, &vel, dt: dt, band: 1.5)
                        }
                        if t > 1.5 { // across ramp + boundary + release
                            maxDvalue = max(maxDvalue, abs(value - prevValue))
                            maxDvel = max(maxDvel, abs(vel - prevVel))
                        }
                        prevValue = value; prevVel = vel
                        t += dt
                    }
                    // Stiff styles legitimately accelerate harder (acc scales
                    // with ω²) — the bound is style-relative; a boundary STEP
                    // under the old gating exceeded even this (1.29°/s at ω×
                    // 0.35, where the bound is 0.5).
                    let styleOmega = region.animationStyle?.omegaMultiplier ?? 1
                    let dvelBound = 0.5 * max(1, styleOmega * styleOmega)
                    if maxDvalue > 0.6 || maxDvel > dvelBound { allSmooth = false }
                    if maxDvel / dvelBound > worstDvel {
                        worstDvel = maxDvel / dvelBound
                        worstStyle = style?.rawValue ?? "default"
                    }
                    // Stiffness continuity across the block END: end−ε vs
                    // end+ε must agree (the blend's endpoint IS the floor).
                    var m1 = memory, m2 = memory
                    let before = TiltMath.tiltReturnParams(
                        tiltRegions: [region], at: 1.999,
                        animationDuration: animDur, memory: &m1)
                    let after = TiltMath.tiltReturnParams(
                        tiltRegions: [region], at: 2.001,
                        animationDuration: animDur, memory: &m2)
                    if abs(before.omega - after.omega) > 0.02 { omegaContinuous = false }
                }
                // Zoom envelope boundary: the shared ramp-out target reaches
                // EXACTLY 0 at the block end with zero slope (smoothstep), so
                // the zoom side cannot step either.
                let s1 = TiltMath.rampOutScale(
                    time: 2.0, blockStart: 0, blockEnd: 2, animationDuration: animDur)
                let s2 = TiltMath.rampOutScale(
                    time: 1.999, blockStart: 0, blockEnd: 2, animationDuration: animDur)
                let zoomEnvelope = s1 == 0 && s2 < 0.0001
                expect("tilt boundary smooth",
                       allSmooth && omegaContinuous && zoomEnvelope,
                       String(format: "smooth=%@ omegaCont=%@ zoomEnv=%@ worstΔvel=%.3f°/s (%@)",
                              allSmooth ? "yes" : "NO", omegaContinuous ? "yes" : "NO",
                              zoomEnvelope ? "yes" : "NO", worstDvel, worstStyle))
            }

            // Zoom animation styles: the style must ride through regionTargets
            // (including the hold on exit), the ordering must be sane, and
            // parallax must vanish at rest.
            do {
                var memory = ZoomFocalMath.RegionMemory()
                let region = ZoomRegion(
                    startTime: 1, endTime: 2, zoomLevel: 2,
                    animationStyle: .slowGlide,
                    cardOffsetX: 0.1, cardOffsetY: 0.3)
                let inside = ZoomFocalMath.regionTargets(
                    zoomRegions: [region], at: 1.2, currentZoom: 1.8, memory: &memory)
                // The final stretch of a block is the RAMP-OUT: target flips
                // to rest INSIDE the block. Its stiffness blends over TIME:
                // the block's own style at the ramp's start (jerk-free
                // release), the decisive floor by its end — position-keyed
                // blending self-trapped slow styles and never reached centre.
                let rampStart = ZoomFocalMath.regionTargets(
                    zoomRegions: [region], at: 1.51, currentZoom: 2.0, memory: &memory)
                let rampOut = ZoomFocalMath.regionTargets(
                    zoomRegions: [region], at: 1.98, currentZoom: 2.0, memory: &memory)
                let exiting = ZoomFocalMath.regionTargets(
                    zoomRegions: [region], at: 2.5, currentZoom: 1.6, memory: &memory)
                let nearHome = ZoomFocalMath.regionTargets(
                    zoomRegions: [region], at: 2.7, currentZoom: 1.05, memory: &memory)
                let settled = ZoomFocalMath.regionTargets(
                    zoomRegions: [region], at: 3.5, currentZoom: 1.0, memory: &memory)
                let styleHeld = inside.omegaMultiplier == ZoomAnimationStyle.slowGlide.omegaMultiplier
                    && inside.zoom == 2
                    // Ramp-out inside the block: the TARGET eases to rest
                    // (no step — see TiltMath.rampOutScale), focal held.
                    && rampStart.zoom > 1.95
                    && rampOut.zoom < 1.05 && rampOut.zoom > rampStart.zoom - 2
                    && rampOut.focal == inside.focal
                    // Jerk-free release at the ramp's start, decisive floor
                    // by its end, full floor once past the block.
                    && abs(rampStart.omegaMultiplier
                           - ZoomAnimationStyle.slowGlide.omegaMultiplier) < 0.05
                    && rampOut.omegaMultiplier >= 1.2
                    && exiting.omegaMultiplier >= 1.25
                    && nearHome.omegaMultiplier >= 1.25
                    && exiting.damping <= inside.damping
                    && exiting.focal == inside.focal
                    && settled.envelope == 0
                    // Offset excursion: full inside, eased near zero by the
                    // ramp's end, zero at rest.
                    && inside.offset == CGPoint(x: 0.1, y: 0.3)
                    && abs(rampOut.offset.x) < 0.02 && abs(rampOut.offset.y) < 0.02
                    && exiting.offset == .zero
                let ordering = ZoomAnimationStyle.instant.omegaMultiplier
                    > ZoomAnimationStyle.snappy.omegaMultiplier
                    && ZoomAnimationStyle.snappy.omegaMultiplier
                    > ZoomAnimationStyle.smooth.omegaMultiplier
                    && ZoomAnimationStyle.smooth.omegaMultiplier
                    > ZoomAnimationStyle.slowGlide.omegaMultiplier
                    && ZoomAnimationStyle.slowGlide.omegaMultiplier
                    > ZoomAnimationStyle.cinematic.omegaMultiplier
                var tiltMemory: (omega: Double, damping: Double) = (1, 0.88)
                let tiltRegion = TiltRegion(
                    startTime: 1, endTime: 2, pitch: 12, animationStyle: .snappy)
                let tiltInside = TiltMath.tiltStyleParams(
                    tiltRegions: [tiltRegion], at: 1.5, memory: &tiltMemory)
                let tiltAfter = TiltMath.tiltStyleParams(
                    tiltRegions: [tiltRegion], at: 2.5, memory: &tiltMemory)
                let tiltStyleHeld = tiltInside.omega == ZoomAnimationStyle.snappy.omegaMultiplier
                    && tiltAfter.omega == tiltInside.omega
                // Fixed focus: with followCursor off, the blend must return
                // the region focal untouched no matter where the cursor is.
                let fixedFocus = ZoomFocalMath.blendedFocalPoint(
                    regionFocal: CGPoint(x: 0.3, y: 0.7),
                    cursorPosition: CGPoint(x: 900, y: 100),
                    displayWidth: 1000, displayHeight: 600,
                    zoom: 2.5, envelope: 1, followCursor: false)
                    == CGPoint(x: 0.3, y: 0.7)
                let parallaxRest = fixedFocus && tiltStyleHeld
                    && ZoomFocalMath.parallaxScale(zoom: 1, strength: 1) == 1
                let parallaxGrows = ZoomFocalMath.parallaxScale(zoom: 2, strength: 1) > 1.05
                    && ZoomFocalMath.parallaxScale(zoom: 2, strength: 0) == 1
                expect("zoom styles + parallax",
                       styleHeld && ordering && parallaxRest && parallaxGrows,
                       "held=\(styleHeld) order=\(ordering) parallax=\(parallaxRest && parallaxGrows)")
            }

            // Freeform placement is CENTRE-fraction over the full canvas —
            // (0.5, 0.5) centres the card, 0/1 put its centre on an edge, and
            // the extended range lets it hang off-canvas (but never vanish).
            let canvasSize = CGSize(width: 1000, height: 600)
            let cardSize = CGSize(width: 400, height: 300)
            let oMid = PlacementMath.customOrigin(fraction: (0.5, 0.5), canvas: canvasSize, video: cardSize)
            let oEdge = PlacementMath.customOrigin(fraction: (0, 0), canvas: canvasSize, video: cardSize)
            let oOff = PlacementMath.customOrigin(fraction: (1.4, 0.5), canvas: canvasSize, video: cardSize)
            let centered = oMid == CGPoint(x: 300, y: 150)
            let edgeHalfOff = oEdge == CGPoint(x: -200, y: -150)
            let overhangs = oOff.x > canvasSize.width - cardSize.width // past the flush-right position
            expect("custom placement centre+off-canvas",
                   centered && edgeHalfOff && overhangs,
                   "mid=\(oMid) edge=\(oEdge) off=\(oOff)")

            // A click is saved in the cropped coordinate space, not in the
            // padded IOSurface. Assert an arbitrary point and a resized/moved
            // live window to catch both constant offsets and scale drift.
            let screenRect = CGRect(x: 123, y: 46, width: 1369, height: 872)
            let coordinateSize = screenRect.size
            let fx: CGFloat = 0.45, fy: CGFloat = 0.63
            let globalClick = CGPoint(
                x: screenRect.minX + screenRect.width * fx,
                y: screenRect.minY + screenRect.height * fy
            )
            let mapped = CursorTracker.mapWindowPointForTesting(
                globalClick,
                from: screenRect,
                to: coordinateSize
            )
            let wanted = CGPoint(x: coordinateSize.width * fx, y: coordinateSize.height * fy)
            expect("click 1:1", hypot(mapped.x - wanted.x, mapped.y - wanted.y) < 0.001,
                   "want=\(wanted) got=\(mapped)")

            // Even if SCK metadata arrives after tracker startup and the
            // canonical space came from an older 1492x949 window snapshot,
            // normalization must still be exact (the old code forgot this
            // rescale and produced the reported far-left click).
            let fallbackSpace = CGSize(width: 1492, height: 949)
            let fallbackMapped = CursorTracker.mapWindowPointForTesting(
                globalClick,
                from: screenRect,
                to: fallbackSpace
            )
            let fallbackExact = abs(fallbackMapped.x / fallbackSpace.width - fx) < 0.000001
                && abs(fallbackMapped.y / fallbackSpace.height - fy) < 0.000001
            expect("late metadata", fallbackExact,
                   "normalized=(\(fallbackMapped.x / fallbackSpace.width),\(fallbackMapped.y / fallbackSpace.height))")

            let movedRect = CGRect(x: 220, y: 110, width: 1000, height: 700)
            let movedClick = CGPoint(
                x: movedRect.minX + movedRect.width * fx,
                y: movedRect.minY + movedRect.height * fy
            )
            let movedMapped = CursorTracker.mapWindowPointForTesting(
                movedClick,
                from: movedRect,
                to: coordinateSize
            )
            expect("moved/resized click", hypot(movedMapped.x - wanted.x, movedMapped.y - wanted.y) < 0.001,
                   "want=\(wanted) got=\(movedMapped)")

            failures += geometryFailures
        }

        // 12 — the device-segment dip, as a CURVE rather than a settled frame.
        //
        // A dip is invisible to every static-frame check in this harness: pick
        // any single instant and the card is simply at some scale. The bug this
        // guards against shipped exactly that way — the preview ran a wall-clock
        // ramp that STARTED at the cut, so the content swap played at full
        // opacity and popped, while the exporter straddled the boundary. Both
        // sides now evaluate `DeviceSegmentDip`; these assert the properties
        // that make it read as Keynote-smooth, so re-forking one side fails.
        do {
            let cut: TimeInterval = 4.0
            let bounds = [cut]
            func phase(_ dt: TimeInterval) -> Double {
                DeviceSegmentDip.phase(at: cut + dt, boundaries: bounds)
            }
            var dipFailures = 0
            func expect(_ ok: Bool, _ what: String, _ detail: String) {
                emit("DIP \(what) \(detail) \(ok ? "PASS" : "FAIL")")
                if !ok { dipFailures += 1 }
            }

            // Deepest AT the cut. This is the whole trick: the frame where the
            // content swaps is the frame the user can least see.
            expect(abs(phase(0) - 1) < 1e-9, "peak-at-boundary",
                   String(format: "phase=%.4f", phase(0)))

            // Already dipping BEFORE the cut — a ramp that begins at the
            // boundary scores 0 here and lets the swap play at full opacity.
            expect(phase(-0.10) > 0.6, "anticipates-cut",
                   String(format: "phase(-0.10s)=%.4f", phase(-0.10)))

            // Symmetric, so the recovery mirrors the approach.
            expect(abs(phase(-0.12) - phase(0.12)) < 1e-9, "symmetric",
                   String(format: "%.6f vs %.6f", phase(-0.12), phase(0.12)))

            // Zero slope at the peak. A piecewise ease-in-out reverses through
            // a corner here, and that corner is the visible kick at the trough.
            let h = 1.0 / 240.0
            let slope = abs(phase(h) - phase(-h)) / (2 * h)
            expect(slope < 0.05, "smooth-at-peak", String(format: "|d/dt|=%.4f", slope))

            // Curvature is continuous through the peak too — second difference
            // either side agrees. A two-piece curve fails this even if both
            // pieces happen to have zero slope at the join.
            func d2(_ c: TimeInterval) -> Double {
                (phase(c + h) - 2 * phase(c) + phase(c - h)) / (h * h)
            }
            expect(abs(d2(-0.03) - d2(0.03)) < 1.0, "curvature-continuous",
                   String(format: "%.3f vs %.3f", d2(-0.03), d2(0.03)))

            // Decayed well clear of the cut, so back-to-back segments do not
            // leave the card permanently dimmed.
            expect(phase(0.45) < 0.001, "decays",
                   String(format: "phase(0.45s)=%.6f", phase(0.45)))

            failures += dipFailures
        }

        // 13 — MotionBlurMath: the shared radius/angle curve both the
        // preview's layer filter and the exporter's CIMotionBlur consume.
        // Pure math, so assert the contract directly: quiet camera → off,
        // radius grows monotonically with speed, caps at the max fraction,
        // and the angle points along the apparent motion (Y-down).
        do {
            var mbFailures = 0
            func expect(_ ok: Bool, _ what: String, _ detail: String) {
                emit("MOTIONBLUR \(what) \(detail) \(ok ? "PASS" : "FAIL")")
                if !ok { mbFailures += 1 }
            }
            func sample(offX: Double = 0, offY: Double = 0, zoom: Double = 1) -> MotionBlurMath.CameraSample {
                MotionBlurMath.CameraSample(zoom: zoom, focalX: 0.5, focalY: 0.5, offsetX: offX, offsetY: offY)
            }
            let dt = 1.0 / 60.0
            let still = MotionBlurMath.blur(previous: sample(), current: sample(), dt: dt, strength: 1)
            expect(!still.active && still.radius == 0, "quiet-off", "radius=\(still.radius)")
            let slow = MotionBlurMath.blur(
                previous: sample(), current: sample(offX: 0.0005), dt: dt, strength: 1)
            expect(!slow.active, "below-threshold", String(format: "v=%.3f", 0.0005 / dt))
            var lastR = 0.0
            var monotonic = true
            for step in stride(from: 0.002, through: 0.03, by: 0.002) {
                let r = MotionBlurMath.blur(
                    previous: sample(), current: sample(offX: step), dt: dt, strength: 1).radius
                if r < lastR - 1e-12 { monotonic = false }
                lastR = r
            }
            expect(monotonic, "monotonic", String(format: "r(max)=%.5f", lastR))
            let capped = MotionBlurMath.blur(
                previous: sample(), current: sample(offX: 0.2), dt: dt, strength: 1)
            expect(abs(capped.radius - MotionBlurMath.maxRadiusFraction) < 1e-9, "caps",
                   String(format: "r=%.5f cap=%.5f", capped.radius, MotionBlurMath.maxRadiusFraction))
            let half = MotionBlurMath.blur(
                previous: sample(), current: sample(offX: 0.2), dt: dt, strength: 0.5)
            expect(abs(half.radius - capped.radius * 0.5) < 1e-9, "strength-scales",
                   String(format: "r=%.5f", half.radius))
            let down = MotionBlurMath.blur(
                previous: sample(), current: sample(offY: 0.02), dt: dt, strength: 1)
            expect(abs(down.angle - .pi / 2) < 1e-9, "angle-ydown",
                   String(format: "angle=%.4f", down.angle))
            let zoomPush = MotionBlurMath.blur(
                previous: sample(zoom: 1.0), current: sample(zoom: 1.03), dt: dt, strength: 1)
            expect(zoomPush.active, "zoom-engages", String(format: "r=%.5f", zoomPush.radius))
            failures += mbFailures
        }

        if PreviewCompositorView.renderTiming, PreviewCompositorView.renderCount > 0 {
            emit(String(format: "RENDER-COST n=%d mean=%.2fms",
                        PreviewCompositorView.renderCount,
                        PreviewCompositorView.renderTotal / Double(PreviewCompositorView.renderCount) * 1000))
            if DeviceBezelRenderer.rasterCount > 0 {
                emit(String(format: "BEZEL-RASTER n=%d mean=%.2fms total=%.0fms",
                            DeviceBezelRenderer.rasterCount,
                            DeviceBezelRenderer.rasterTotal / Double(DeviceBezelRenderer.rasterCount) * 1000,
                            DeviceBezelRenderer.rasterTotal * 1000))
            }
        }
        emit("ARTIFACTS \(fixtureDir.path)")
        if refreezing {
            emit("// ---- paste into PreviewGoldens.swift ----")
            emit("    static let fingerprints: [String: String] = [")
            for line in refrozen { emit(line) }
            emit("    ]")
            emit("    static let blobCounts: [String: Int] = [")
            for line in refrozenBlobs { emit(line) }
            emit("    ]")
            exit(0)
        }
        emit("WORST \(worst.0) \(String(format: "%.0f", worst.1))/255")
        emit(failures == 0 ? "PARITY PASS" : "PARITY FAIL count=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }

    private static func compositorInput(_ f: Fixture) -> PreviewCompositorView.FrameInput {
        PreviewCompositorView.FrameInput(
            project: f.project,
            currentTime: f.currentTime,
            isPlaying: f.isPlaying,
            cursorEvents: f.cursorEvents,
            cursorCoordinateSize: f.coordinateSize,
            videoSize: f.videoSize,
            player: f.player,
            cameraPlayer: nil,
            cameraPosterImage: f.project.settings.showCamera ? f.cameraPoster : nil,
            cameraVideoAspect: f.cameraAspect,
            videoPosterImage: f.videoPoster
        )
    }

    private static func settle(_ seconds: TimeInterval) async {
        // Run the main run loop so SwiftUI commits, implicit animations
        // finish, and the 60Hz video drivers pull frames.
        let until = Date(timeIntervalSinceNow: seconds)
        while Date() < until {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
            await Task.yield()
        }
    }

    // MARK: - Fixture assembly

    /// A fully synthetic, DETERMINISTIC fixture.
    ///
    /// The harness used to load "the newest project folder in Application
    /// Support" — i.e. whatever the user last touched. That was survivable
    /// while the gate diffed two live renderers inside one run, because both
    /// panes saw the same fixture and the difference between them was still
    /// meaningful. It is fatal once the reference is FROZEN: the gate's input
    /// changed every time the user edited a project, so a golden captured on
    /// Monday failed on Tuesday for reasons that had nothing to do with the
    /// renderer. (Observed: a subtitle state moved 50/255 because a different
    /// project became "newest" between two runs.)
    ///
    /// Everything below is generated, so the only thing that can move a pixel
    /// is the compositor.
    static func makeFixtureProject(duration: TimeInterval = 12) -> Project {
        // A fixed UUID keeps any id-derived value (legacy clip IDs, cache keys)
        // stable across runs.
        let project = Project(
            id: UUID(uuidString: "00000000-0000-4000-A000-0000CA99D000")!,
            name: "parity-fixture",
            duration: duration,
            recordingSourceKind: .display
        )
        project.trimStart = 0
        project.trimEnd = duration
        // Pin every setting the matrix does not explicitly drive. Anything left
        // at a default that later CHANGES would silently invalidate the goldens.
        let s = project.settings
        s.backgroundType = .gradient
        s.backgroundPadding = 48
        s.videoPlacement = .center
        s.cornerRadius = 12
        s.shadowRadius = 24
        s.shadowOpacity = 0.6
        s.subtitleFontName = nil            // system face, not a user-installed one
        s.subtitleFontSize = 34
        s.subtitleWeight = .heavy
        s.subtitleColor = CodableColor(NSColor.white)
        s.subtitleBackgroundColor = CodableColor(NSColor.black)
        s.subtitleHighlightColor = CodableColor(NSColor.systemYellow)
        return project
    }

    /// Deterministic stand-in for a decoded video frame.
    ///
    /// Deliberately structured rather than a flat fill: quadrant colours catch a
    /// flip or a mirrored warp, the grid catches scale and crop errors, and the
    /// black band gives the blob gate something stable to count.
    static func syntheticVideoFrame(size: CGSize) -> NSImage {
        // Drawn into an explicit sRGB bitmap context at 1:1 pixels, NOT via
        // NSImage.lockFocus: lockFocus rasterises at the CURRENT SCREEN's
        // backing scale, so the same fixture produced a 2x image on this
        // machine and a 1x image on a non-Retina one. Colours are literal sRGB
        // rather than NSColor.system*, which resolve differently under aqua and
        // darkAqua — either would have made the frozen goldens machine-specific.
        let w = Int(size.width), h = Int(size.height)
        guard w > 0, h > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return NSImage(size: size) }

        let quadrants: [(CGRect, CGColor)] = [
            (CGRect(x: 0, y: size.height / 2, width: size.width / 2, height: size.height / 2),
             CGColor(srgbRed: 0.35, green: 0.34, blue: 0.84, alpha: 1)),
            (CGRect(x: size.width / 2, y: size.height / 2, width: size.width / 2, height: size.height / 2),
             CGColor(srgbRed: 0.19, green: 0.69, blue: 0.78, alpha: 1)),
            (CGRect(x: 0, y: 0, width: size.width / 2, height: size.height / 2),
             CGColor(srgbRed: 0.91, green: 0.30, blue: 0.44, alpha: 1)),
            (CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height / 2),
             CGColor(srgbRed: 0.22, green: 0.72, blue: 0.40, alpha: 1)),
        ]
        for (rect, color) in quadrants {
            ctx.setFillColor(color)
            ctx.fill(rect)
        }

        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.25))
        ctx.setLineWidth(2)
        for x in stride(from: 0, through: Int(size.width), by: 80) {
            ctx.move(to: CGPoint(x: CGFloat(x), y: 0))
            ctx.addLine(to: CGPoint(x: CGFloat(x), y: size.height))
        }
        for y in stride(from: 0, through: Int(size.height), by: 80) {
            ctx.move(to: CGPoint(x: 0, y: CGFloat(y)))
            ctx.addLine(to: CGPoint(x: size.width, y: CGFloat(y)))
        }
        ctx.strokePath()

        // A pure-black band gives `HarnessPixels.darkBlobs` one stable component
        // that is NOT the device island, so an island appearing or vanishing
        // moves the count by exactly one.
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: size.width * 0.1, y: size.height * 0.06,
                        width: size.width * 0.25, height: size.height * 0.08))

        guard let cg = ctx.makeImage() else { return NSImage(size: size) }
        return NSImage(cgImage: cg, size: size)
    }

    private static func syntheticCursorEvents(around t0: TimeInterval, size: CGSize) -> [CursorEvent] {
        var events: [CursorEvent] = []
        // Straight glide ending at 62%/58% of the frame, parked before t0 so
        // the interpolated position at t0 is deterministic and static.
        let end = CGPoint(x: size.width * 0.62, y: size.height * 0.58)
        for i in 0...60 {
            let f = CGFloat(i) / 60
            let t = t0 - 1.5 + TimeInterval(f) * 1.2 // ends 0.3s before t0
            events.append(CursorEvent(
                timestamp: t,
                x: size.width * 0.3 + (end.x - size.width * 0.3) * f,
                y: size.height * 0.35 + (end.y - size.height * 0.35) * f,
                isClick: false
            ))
        }
        // One click 0.2s before t0 → ripple mid-cycle at t0.
        events.append(CursorEvent(timestamp: t0 - 0.21, x: end.x, y: end.y, isClick: true))
        events.append(CursorEvent(timestamp: t0 - 0.18, x: end.x, y: end.y, isClick: false))
        // Park the cursor at the click point through t0.
        events.append(CursorEvent(timestamp: t0 + 0.5, x: end.x, y: end.y, isClick: false))
        return events
    }

    /// Deterministic camera poster.
    ///
    /// Was `NSImage.lockFocus`, which rasterises at the CURRENT SCREEN's
    /// backing scale — so this fixture silently changed when the Mac was
    /// driving a 1x external display instead of a Retina panel. Fixed pixel
    /// dimensions instead. The colours stay the real system ones; `runMatrix`
    /// pins the app appearance before any fixture is built, which is what makes
    /// them reproducible.
    private static func gradientPoster(size: CGSize) -> NSImage {
        let scale: CGFloat = 2
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return NSImage(size: size) }
        ctx.scaleBy(x: scale, y: scale)
        let nsContext = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext
        NSGradient(colors: [NSColor.systemIndigo, NSColor.systemTeal])?
            .draw(in: NSRect(origin: .zero, size: size), angle: 35)
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = ctx.makeImage() else { return NSImage(size: size) }
        return NSImage(cgImage: cg, size: size)
    }

    private static func writeLogoPNG(to url: URL) throws {
        let size = CGSize(width: 280, height: 120)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.white.withAlphaComponent(0.92).setFill()
        NSBezierPath(roundedRect: NSRect(x: 4, y: 4, width: size.width - 8, height: size.height - 8), xRadius: 24, yRadius: 24).fill()
        NSColor.black.setFill()
        NSBezierPath(ovalIn: NSRect(x: 30, y: 30, width: 60, height: 60)).fill()
        img.unlockFocus()
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "parity", code: 2)
        }
        try png.write(to: url)
    }

    // MARK: - Offscreen capture + diff

    private static func meanAbsDiff(_ a: CGImage, _ b: CGImage, crop: CGRect?) -> Double {
        guard let pa = rgba(a), let pb = rgba(b), pa.width == pb.width, pa.height == pb.height else { return 255 }
        var region = CGRect(x: 0, y: 0, width: pa.width, height: pa.height)
        if let crop {
            // CARenderer captures Y-up at 1× — flip the Y-down canvas crop.
            region = CGRect(x: crop.origin.x,
                            y: CGFloat(pa.height) - crop.maxY,
                            width: crop.width, height: crop.height)
                .intersection(region)
        }
        guard region.width > 1, region.height > 1 else { return 255 }
        var total = 0.0
        var count = 0.0
        let x0 = Int(region.minX), x1 = Int(region.maxX)
        let y0 = Int(region.minY), y1 = Int(region.maxY)
        for y in y0..<y1 {
            let rowA = pa.bytes + y * pa.bytesPerRow
            let rowB = pb.bytes + y * pb.bytesPerRow
            for x in x0..<x1 {
                let ia = rowA + x * 4
                let ib = rowB + x * 4
                total += abs(Double(ia[0]) - Double(ib[0]))
                total += abs(Double(ia[1]) - Double(ib[1]))
                total += abs(Double(ia[2]) - Double(ib[2]))
                count += 3
            }
        }
        pa.free(); pb.free()
        return count > 0 ? total / count : 255
    }

    // MARK: - Structural blob detection (island duplication gate)

    private static func meanLuminance(_ img: CGImage) -> Double {
        guard let p = rgba(img) else { return 0 }
        var total = 0.0
        let stride = 8
        var count = 0.0
        for y in Swift.stride(from: 0, to: p.height, by: stride) {
            let row = p.bytes + y * p.bytesPerRow
            for x in Swift.stride(from: 0, to: p.width, by: stride) {
                let px = row + x * 4
                total += (Double(px[0]) + Double(px[1]) + Double(px[2])) / 3
                count += 1
            }
        }
        p.free()
        return count > 0 ? total / count : 0
    }

    private struct Pixels {
        var bytes: UnsafeMutablePointer<UInt8>
        var width: Int
        var height: Int
        var bytesPerRow: Int
        func free() { bytes.deallocate() }
    }

    private static func rgba(_ image: CGImage) -> Pixels? {
        let w = image.width, h = image.height
        let bpr = w * 4
        let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: bpr * h)
        guard let ctx = CGContext(
            data: bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { bytes.deallocate(); return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return Pixels(bytes: bytes, width: w, height: h, bytesPerRow: bpr)
    }

    private static func savePNG(_ image: CGImage, _ url: URL) {
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
