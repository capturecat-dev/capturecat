import AppKit
import CoreGraphics
import CoreImage
import CoreText
import UniformTypeIdentifiers

/// Rasterisation regression gate for the CoreGraphics renderers. Run:
///
///   CaptureCat --raster-golden <dir>
///
/// `<dir>` receives `<name>-cg.png` for every matrix state so a failure can be
/// eyeballed, not just scored.
///
/// # What this used to be, and what it is now
///
/// This started as the de-SwiftUI-fication gate: every renderer was drawn twice,
/// once by SwiftUI and once by CoreGraphics, and the two were diffed. That is
/// how `DeviceBezelRenderer`, `AnnotationRenderer`, `SelectionChromeKit`,
/// `BackgroundGradientRenderer` and `ContinuousRoundedRect` were proved correct
/// in the first place, and every one of them passed under a 1.0/255 mean bar at
/// the commit that removed the last `import SwiftUI`.
///
/// With SwiftUI gone there is no oracle left to re-render, so each check keeps
/// the strongest reference that survives deletion:
///
/// - `squircleCheck` / `homographyCheck` — FULL strength. The reference is the
///   SwiftUI-era math itself, frozen exactly (`SquircleReference`'s bezier
///   element list; `Mat3` replacing `ProjectionTransform` in a copy of the old
///   expression). These assert what they always asserted.
/// - `gradientRampCheck` — STRONGER. Instead of diffing against a SwiftUI
///   rasterisation it now asserts the drawn ramp against `OklabGradient`'s
///   model directly, which is the invariant SwiftUI was only ever evidence for.
/// - `bezelCheck` / `annotationCheck` / `focusChromeCheck` — REGRESSION only.
///   The frozen `RasterGoldens` fingerprints say "this still renders what it
///   rendered when it was proved correct". They cannot re-derive correctness.
/// - `exporterOrientationCheck` — unchanged; it never involved SwiftUI.
///
/// DEBUG tooling only; never runs in a normal launch.
@MainActor
enum RasterGoldenHarness {
    /// Worst tolerated per-channel delta on a fingerprint cell. Cells are
    /// ~40×40pt averages, so antialiasing and dithering wash out entirely and a
    /// real change moves a cell by tens of levels; 2 is comfortably above the
    /// former and far below the latter.
    static let fingerprintBar: Double = 2
    static let scale: CGFloat = 2

    private static var failures: [String] = []
    private static var outputDir = URL(fileURLWithPath: NSTemporaryDirectory())

    /// `--refreeze` prints a new `RasterGoldens` table instead of asserting.
    private static var refreezing = false
    private static var refrozen: [String] = []
    private static var refrozenBlobs: [String] = []

    static func run() -> Never {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        refreezing = CommandLine.arguments.contains("--refreeze")

        // The app is sandboxed, so PNGs land in the container's tmp unless a
        // writable directory is named explicitly.
        outputDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("capturecat-raster-golden", isDirectory: true)
        if let i = CommandLine.arguments.firstIndex(of: "--raster-golden"),
           i + 1 < CommandLine.arguments.count,
           !CommandLine.arguments[i + 1].hasPrefix("--"),
           FileManager.default.isWritableFile(atPath: CommandLine.arguments[i + 1]) {
            outputDir = URL(fileURLWithPath: CommandLine.arguments[i + 1], isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        Task { @MainActor in
            squircleCheck()
            homographyCheck()
            gradientRampCheck()
            backgroundLookCheck()
            bezelCheck()
            annotationCheck()
            focusChromeCheck()
            colorPickerCheck()
            exporterOrientationCheck()
            print("RASTER-GOLDEN dir=\(outputDir.path)")
            if refreezing {
                print("// ---- paste into RasterGoldens.swift ----")
                print("    static let fingerprints: [String: String] = [")
                for line in refrozen { print(line) }
                print("    ]")
                print("    static let blobCounts: [String: Int] = [")
                for line in refrozenBlobs { print(line) }
                print("    ]")
                exit(0)
            }
            if failures.isEmpty {
                print("RASTER-GOLDEN OK")
                exit(0)
            } else {
                for f in failures { print("RASTER-GOLDEN FAIL \(f)") }
                exit(1)
            }
        }
        app.run()
        exit(0)
    }

    // MARK: - Color picker

    /// `ColorPickerPopoverView` was ported from a SwiftUI popover and verified
    /// against it at a mean 0.39–0.58/255 across four states before the original
    /// was deleted. What survives is the part that does not need the original:
    /// the row geometry and the hex readout, both asserted as numbers.
    private static func colorPickerCheck() {
        for (name, opacity) in [("picker-opacity", true), ("picker-noopacity", false)] {
            let view = ColorPickerPopoverView(
                color: NSColor(srgbRed: 0.62, green: 0.66, blue: 0.92, alpha: 1),
                supportsOpacity: opacity
            )
            assertPickerGeometry(view, name: name, supportsOpacity: opacity)
        }
        colorPickerHexCheck()
    }

    /// Row geometry, checked as numbers so a collapsed or reordered stack fails
    /// even when every pixel bar would have passed.
    private static func assertPickerGeometry(
        _ view: ColorPickerPopoverView, name: String, supportsOpacity: Bool
    ) {
        view.frame = NSRect(origin: .zero, size: view.intrinsicContentSize)
        view.layoutSubtreeIfNeeded()
        let rows = view.debugRowFrames()
        let expectedRows = supportsOpacity ? 5 : 4
        guard rows.count == expectedRows else {
            failures.append("\(name): \(rows.count) rows, expected \(expectedRows)")
            return
        }
        // 208 wide with 11pt padding — the geometry the SwiftUI popover had.
        if view.intrinsicContentSize.width != 208 {
            failures.append("\(name): width \(view.intrinsicContentSize.width) != 208")
        }
        if abs(view.intrinsicContentSize.height - (supportsOpacity ? 223 : 204)) > 0.5 {
            failures.append("\(name): height \(view.intrinsicContentSize.height) unexpected")
        }
        for (i, r) in rows.enumerated() {
            if abs(r.minX - 11) > 0.01 || abs(r.width - 186) > 0.01 {
                failures.append("\(name): row \(i) x/width = \(r.minX)/\(r.width), expected 11/186")
            }
            if i > 0, r.minY < rows[i - 1].maxY {
                failures.append("\(name): row \(i) overlaps row \(i - 1)")
            }
        }
        let swatches = view.debugPresetFrames()
        if swatches.count != 12 {
            failures.append("\(name): \(swatches.count) presets, expected 12")
        } else if let first = swatches.first, let last = swatches.last {
            // `HStack(spacing: 0)` + `Spacer(minLength: 0)`: flush at both ends.
            if abs(first.minX) > 0.01 || abs(last.maxX - 186) > 0.01 {
                failures.append("\(name): presets span \(first.minX)…\(last.maxX), expected 0…186")
            }
        }
        print(String(
            format: "PICKER-GEOM %@ size=%.0fx%.0f rows=%d presets=%d",
            name, view.intrinsicContentSize.width, view.intrinsicContentSize.height,
            rows.count, swatches.count
        ))
    }

    /// The hex readout is the one place the port deliberately CHANGES behaviour:
    /// the SwiftUI original formatted through `NSColor(hue:…)` (calibrated RGB)
    /// while composing the color in sRGB, so its readout disagreed with its own
    /// swatch. Assert the native readout against sRGB truth.
    private static func colorPickerHexCheck() {
        let cases: [(NSColor, String)] = [
            (NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1), "FFFFFF"),
            (NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1), "000000"),
            (NSColor(srgbRed: 0.62, green: 0.66, blue: 0.92, alpha: 1), "9EA8EB"),
            (NSColor(srgbRed: 0.25, green: 0.85, blue: 0.62, alpha: 0.45), "40D99E"),
        ]
        for (color, expected) in cases {
            let view = ColorPickerPopoverView(color: color, supportsOpacity: true)
            let hex = view.debugHexText()
            if hex != expected {
                failures.append("picker-hex: \(expected) round-tripped to \(hex)")
            }
            print("PICKER-HEX \(expected) -> \(hex)")
        }
    }

    // MARK: - Squircle

    /// Asserts the pure-CG continuous rounded rect still traces the outline
    /// SwiftUI's own `.continuous` corner traced, using the reference points
    /// frozen in `SquircleReference` (see that file for why they are stored
    /// rather than regenerated). Bar: 0.5pt sampled deviation; measured ~1e-5pt.
    ///
    /// The frozen cases cover both corner regimes — under the cap
    /// (`402×874 r=62.31`, the real phone screen) and fully capped
    /// (`200×200 r=150`, `37.5×12.5 r=6.25`) — which is where a naive
    /// `CGPath(roundedRect:)` substitution diverges most.
    private static func squircleCheck() {
        var worst = 0.0
        var worstCase = ""
        for c in SquircleReference.cases {
            let cg = ContinuousRoundedRect.path(rect: c.rect, cornerRadius: c.radius)
            let d = maxDeviation(cg, c.path)
            if d > worst { worst = d; worstCase = "\(c.width)x\(c.height) r=\(c.radius)" }
            if d > 0.5 {
                failures.append(String(
                    format: "squircle %.0fx%.0f r=%.2f deviation %.4fpt",
                    c.width, c.height, c.radius, d
                ))
            }
        }
        print(String(
            format: "SQUIRCLE cases=%d worst=%.6fpt (%@) bar=0.5pt",
            SquircleReference.cases.count, worst, worstCase
        ))
    }

    /// Symmetric max sampled deviation between two paths, in points.
    private static func maxDeviation(_ a: CGPath, _ b: CGPath) -> Double {
        let pa = flatten(a), pb = flatten(b)
        guard pa.count > 1, pb.count > 1 else { return .infinity }
        return max(oneWay(pa, pb), oneWay(pb, pa))
    }

    private static func oneWay(_ from: [CGPoint], _ to: [CGPoint]) -> Double {
        var worst = 0.0
        for p in from {
            var best = Double.infinity
            for i in 0..<(to.count - 1) {
                best = min(best, distance(p, to[i], to[i + 1]))
                if best == 0 { break }
            }
            worst = max(worst, best)
        }
        return worst
    }

    private static func distance(_ p: CGPoint, _ s: CGPoint, _ e: CGPoint) -> Double {
        let dx = e.x - s.x, dy = e.y - s.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return Double(hypot(p.x - s.x, p.y - s.y)) }
        var t = ((p.x - s.x) * dx + (p.y - s.y) * dy) / len2
        t = max(0, min(1, t))
        return Double(hypot(p.x - (s.x + t * dx), p.y - (s.y + t * dy)))
    }

    // MARK: - InsettableShape semantics

    // MARK: - Tilt homography

    /// `TiltMath.Homography` replaced SwiftUI's `ProjectionTransform` in the
    /// shared tilt math. That matrix feeds BOTH the preview's CATransform3D
    /// and the exporter's perspective warp, so assert the replacement is
    /// element-identical to what SwiftUI computed, across the angle matrix and
    /// the concatenation order.
    private static func homographyCheck() {
        var worst = 0.0
        var count = 0
        let centers = [CGPoint(x: 0, y: 0), CGPoint(x: 360, y: 202.5), CGPoint(x: -40.5, y: 91.25)]
        for pitch in [-24.0, -7.5, 0.0, 0.01, 3.0, 18.0, 31.0] as [Double] {
            for yaw in [-19.0, -2.0, 0.0, 5.5, 27.0] as [Double] {
                for roll in [-12.0, 0.0, 9.25] as [Double] {
                    for center in centers {
                        for distance in [600.0, 1400.0] as [CGFloat] {
                            let h = TiltMath.projectionTransform(
                                pitchDegrees: pitch, yawDegrees: yaw, rollDegrees: roll,
                                center: center, distance: distance)
                            let p = swiftUIProjection(
                                pitchDegrees: pitch, yawDegrees: yaw, rollDegrees: roll,
                                center: center, distance: distance)
                            let pairs: [(CGFloat, CGFloat)] = [
                                (h.m11, p.m11), (h.m12, p.m12), (h.m13, p.m13),
                                (h.m21, p.m21), (h.m22, p.m22), (h.m23, p.m23),
                                (h.m31, p.m31), (h.m32, p.m32), (h.m33, p.m33),
                            ]
                            for (a, b) in pairs { worst = max(worst, Double(abs(a - b))) }
                            count += 1
                        }
                    }
                }
            }
        }
        print(String(format: "HOMOGRAPHY cases=%d worst element delta=%.3e", count, worst))
        if worst > 1e-9 {
            failures.append(String(format: "homography differs from ProjectionTransform by %.3e", worst))
        }
    }

    /// The pre-refactor implementation, kept verbatim as the oracle.
    ///
    /// This was always a hand-written copy of the old code — SwiftUI supplied
    /// only the `ProjectionTransform` container and its `concatenating`, which
    /// `Mat3` now provides. So this gate loses nothing to the SwiftUI removal:
    /// the reference math is the same expression it always was.
    private static func swiftUIProjection(
        pitchDegrees: Double, yawDegrees: Double, rollDegrees: Double,
        center: CGPoint, distance: CGFloat
    ) -> Mat3 {
        guard max(abs(pitchDegrees), abs(yawDegrees), abs(rollDegrees)) > 0.01 else {
            return Mat3()
        }
        let sa = CGFloat(sin(pitchDegrees * .pi / 180))
        let ca = CGFloat(cos(pitchDegrees * .pi / 180))
        let sb = CGFloat(sin(yawDegrees * .pi / 180))
        let cb = CGFloat(cos(yawDegrees * .pi / 180))

        var m = Mat3()
        m.m11 = cb
        m.m21 = -sa * sb
        m.m12 = 0
        m.m22 = ca
        m.m13 = -sb / distance
        m.m23 = -sa * cb / distance

        let roll = Mat3(CGAffineTransform(rotationAngle: rollDegrees * .pi / 180))
        let toCenter = Mat3(CGAffineTransform(translationX: -center.x, y: -center.y))
        let fromCenter = Mat3(CGAffineTransform(translationX: center.x, y: center.y))
        return toCenter.concatenating(roll).concatenating(m).concatenating(fromCenter)
    }

    /// `ProjectionTransform`'s replacement: a plain row-vector 3×3, with the
    /// same element names and the same `concatenating` order (`self` then
    /// `other`, i.e. `self × other`) SwiftUI used.
    struct Mat3 {
        var m11: CGFloat = 1, m12: CGFloat = 0, m13: CGFloat = 0
        var m21: CGFloat = 0, m22: CGFloat = 1, m23: CGFloat = 0
        var m31: CGFloat = 0, m32: CGFloat = 0, m33: CGFloat = 1

        init() {}

        init(_ t: CGAffineTransform) {
            m11 = t.a;  m12 = t.b;  m13 = 0
            m21 = t.c;  m22 = t.d;  m23 = 0
            m31 = t.tx; m32 = t.ty; m33 = 1
        }

        func concatenating(_ o: Mat3) -> Mat3 {
            var r = Mat3()
            r.m11 = m11 * o.m11 + m12 * o.m21 + m13 * o.m31
            r.m12 = m11 * o.m12 + m12 * o.m22 + m13 * o.m32
            r.m13 = m11 * o.m13 + m12 * o.m23 + m13 * o.m33
            r.m21 = m21 * o.m11 + m22 * o.m21 + m23 * o.m31
            r.m22 = m21 * o.m12 + m22 * o.m22 + m23 * o.m32
            r.m23 = m21 * o.m13 + m22 * o.m23 + m23 * o.m33
            r.m31 = m31 * o.m11 + m32 * o.m21 + m33 * o.m31
            r.m32 = m31 * o.m12 + m32 * o.m22 + m33 * o.m32
            r.m33 = m31 * o.m13 + m32 * o.m23 + m33 * o.m33
            return r
        }
    }

    // MARK: - Text metrics

    /// Bounding box of non-transparent pixels.
    private static func paintedBox(_ image: CGImage) -> CGRect? {
        guard let p = rgba(image) else { return nil }
        defer { p.free() }
        var minX = p.width, minY = p.height, maxX = -1, maxY = -1
        for y in 0..<p.height {
            let row = p.bytes + y * p.bytesPerRow
            for x in 0..<p.width where (row + x * 4)[3] > 8 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    // MARK: - Background gradient

    /// The rendered ramp vs `OklabGradient`'s model, across colour pairs chosen
    /// so gamma-vs-perceptual interpolation differs as much as possible
    /// (saturated complements are the worst case; a `CAGradientLayer` misses
    /// these by ~15/255 mid-ramp).
    ///
    /// This used to rasterise a SwiftUI `LinearGradient` as the oracle. It now
    /// samples the drawn image along its own axis and compares each sample to
    /// `OklabGradient.sample` — the model SwiftUI was measured to follow. That
    /// is a STRONGER assertion than the pixel diff it replaces: a stored PNG
    /// golden would only prove the renderer had not changed, whereas this proves
    /// it still implements Oklab interpolation, which is the actual invariant.
    /// It also drops 2.8 MB of would-be golden PNGs.
    /// BackgroundLook is the single source of the backdrop bitmap for preview
    /// AND export. This proves (a) a plain look is byte-identical to the bare
    /// gradient renderer — old projects render exactly as before; (b) each
    /// look control actually changes the pixels in the direction it claims;
    /// (c) the 2× preview and 1× export bitmaps agree proportionally.
    private static func backgroundLookCheck() {
        let settings = ProjectSettings()
        settings.gradientStartColor = CodableColor(red: 1, green: 0, blue: 0)
        settings.gradientEndColor = CodableColor(red: 0, green: 0, blue: 1)
        let size = CGSize(width: 320, height: 180)

        func pixel(_ img: CGImage, _ fx: Double, _ fy: Double) -> (r: Double, g: Double, b: Double)? {
            guard let px = rgba(img) else { return nil }
            defer { px.free() }
            let x = min(px.width - 1, Int(fx * Double(px.width)))
            let y = min(px.height - 1, Int(fy * Double(px.height)))
            let row = px.bytes + y * px.bytesPerRow + x * 4
            let a = max(0.001, Double(row[3]) / 255)
            return (Double(row[0]) / 255 / a, Double(row[1]) / 255 / a, Double(row[2]) / 255 / a)
        }
        func check(_ name: String, _ ok: Bool, _ detail: String) {
            print("BACKGROUND-LOOK \(name) \(detail) \(ok ? "PASS" : "FAIL")")
            if !ok { failures.append("background-look \(name): \(detail)") }
        }

        // (a) Plain look == bare renderer, byte for byte.
        let plain = BackgroundLook.cgImage(for: .init(settings), size: size, scale: 1)
        let bare = BackgroundGradientRenderer.image(
            start: SRGBA(settings.gradientStartColor), end: SRGBA(settings.gradientEndColor),
            size: size, axis: .diagonal, scale: 1)
        if let plain, let bare, let a = rgba(plain), let b = rgba(bare) {
            defer { a.free(); b.free() }
            let same = a.width == b.width && a.height == b.height
                && memcmp(a.bytes, b.bytes, a.bytesPerRow * a.height) == 0
            check("plain-is-bare-gradient", same, "\(a.width)x\(a.height)")
        } else {
            check("plain-is-bare-gradient", false, "render failed")
        }

        // (b) Angle 90° runs left→right: left edge ≈ start, right edge ≈ end.
        settings.gradientAngle = 90
        if let img = BackgroundLook.cgImage(for: .init(settings), size: size, scale: 1),
           let l = pixel(img, 0.01, 0.5), let r = pixel(img, 0.99, 0.5) {
            check("angle-90-left-to-right", l.r > 0.9 && l.b < 0.1 && r.b > 0.9 && r.r < 0.1,
                  String(format: "left=%.2f,%.2f right=%.2f,%.2f", l.r, l.b, r.r, r.b))
        }
        settings.gradientAngle = nil

        // (b) Tint: 100% black tint → black.
        settings.backgroundTintOpacity = 1
        if let img = BackgroundLook.cgImage(for: .init(settings), size: size, scale: 1),
           let c = pixel(img, 0.5, 0.5) {
            check("tint-full-black", c.r < 0.02 && c.g < 0.02 && c.b < 0.02,
                  String(format: "centre=%.2f,%.2f,%.2f", c.r, c.g, c.b))
        }
        settings.backgroundTintOpacity = 0

        // (b) Saturation 0 → grey (r ≈ g ≈ b) somewhere the ramp is pure red.
        settings.backgroundSaturation = 0
        if let img = BackgroundLook.cgImage(for: .init(settings), size: size, scale: 1),
           let c = pixel(img, 0.02, 0.02) {
            check("saturation-zero-grey", abs(c.r - c.g) < 0.03 && abs(c.g - c.b) < 0.03,
                  String(format: "corner=%.2f,%.2f,%.2f", c.r, c.g, c.b))
        }
        settings.backgroundSaturation = 1

        // (b) Vignette darkens corners, keeps the centre.
        settings.backgroundVignette = 1
        if let styled = BackgroundLook.cgImage(for: .init(settings), size: size, scale: 1),
           let plain, let cs = pixel(styled, 0.02, 0.02), let cp = pixel(plain, 0.02, 0.02),
           let ms = pixel(styled, 0.5, 0.5), let mp = pixel(plain, 0.5, 0.5) {
            let cornerDim = (cs.r + cs.b) < (cp.r + cp.b) * 0.7
            let centreKept = abs((ms.r + ms.b) - (mp.r + mp.b)) < 0.1
            check("vignette-corners-only", cornerDim && centreKept,
                  String(format: "corner %.2f→%.2f centre %.2f→%.2f", cp.r + cp.b, cs.r + cs.b, mp.r + mp.b, ms.r + ms.b))
        }
        settings.backgroundVignette = 0

        // (b) Blur softens a hard edge: solid-colour picture with a seam.
        settings.backgroundType = .solid
        settings.backgroundBlur = 0.5
        settings.gradientAngle = 90
        // A solid is uniform, so use the 90° gradient + blur: blur must NOT
        // change the mid-ramp value (symmetry) and must keep the extent full.
        settings.backgroundType = .gradient
        if let img = BackgroundLook.cgImage(for: .init(settings), size: size, scale: 1),
           let m = pixel(img, 0.5, 0.5), let l = pixel(img, 0.0, 0.5) {
            check("blur-keeps-edges-filled", l.r > 0.5 && abs(m.r - m.b) < 0.15 && img.width == 320,
                  String(format: "edge r=%.2f mid=%.2f,%.2f w=%d", l.r, m.r, m.b, img.width))
        }

        // (b) Hue 180° on a red corner → cyan-ish (red drops, blue/green rise).
        settings.backgroundHue = 180
        if let img = BackgroundLook.cgImage(for: .init(settings), size: size, scale: 1),
           let c = pixel(img, 0.02, 0.02) {
            check("hue-180-flips-red", c.r < 0.4 && (c.g + c.b) > 0.8,
                  String(format: "corner=%.2f,%.2f,%.2f", c.r, c.g, c.b))
        }
        settings.backgroundHue = 0

        // (b) Pixelate: two neighbours inside one block are identical while
        // the plain ramp differs between them.
        settings.backgroundPixelate = 1
        if let img = BackgroundLook.cgImage(for: .init(settings), size: size, scale: 1),
           // Full pixelate = 14px blocks at 180px tall: x=3 and x=10 share one.
           let plain, let a = pixel(img, 0.01, 0.5), let b = pixel(img, 0.03, 0.5),
           let pa = pixel(plain, 0.01, 0.5), let pb = pixel(plain, 0.03, 0.5) {
            check("pixelate-blocks", abs(a.r - b.r) < 0.01 && abs(pa.r - pb.r) > 0.01,
                  String(format: "block %.3f/%.3f plain %.3f/%.3f", a.r, b.r, pa.r, pb.r))
        }
        settings.backgroundPixelate = 0

        // (b) Grain: adds per-pixel variance the plain ramp lacks, but keeps
        // the mean — sample a row and compare neighbour deltas.
        settings.backgroundNoise = 1
        if let img = BackgroundLook.cgImage(for: .init(settings), size: size, scale: 1), let plain {
            var grainDelta = 0.0, plainDelta = 0.0
            for i in 0..<40 {
                let fx = 0.3 + Double(i) / 400
                if let a = pixel(img, fx, 0.5), let b = pixel(img, fx + 0.0025, 0.5) { grainDelta += abs(a.g - b.g) }
                if let a = pixel(plain, fx, 0.5), let b = pixel(plain, fx + 0.0025, 0.5) { plainDelta += abs(a.g - b.g) }
            }
            check("grain-adds-texture", grainDelta > plainDelta * 3 + 0.2,
                  String(format: "grain=%.2f plain=%.2f", grainDelta, plainDelta))
        }
        settings.backgroundNoise = 0

        // (b) Halftone: darkens the ramp on average (dots on a lighter field
        // are net ink) and stays within the canvas.
        settings.backgroundHalftone = 0.5
        if let img = BackgroundLook.cgImage(for: .init(settings), size: size, scale: 1),
           let c = pixel(img, 0.5, 0.5) {
            check("halftone-renders", img.width == 320 && (c.r + c.g + c.b) < 3,
                  String(format: "mid=%.2f,%.2f,%.2f", c.r, c.g, c.b))
        }
        settings.backgroundHalftone = 0

        // Artifact: mesh + fine grain sample for eyeballing the aesthetic
        // (not asserted — the look is a design call).
        settings.backgroundType = .mesh
        settings.backgroundNoise = 0.6
        settings.gradientStartColor = CodableColor(red: 0.45, green: 0.47, blue: 0.85)
        settings.gradientEndColor = CodableColor(red: 0.98, green: 0.62, blue: 0.45)
        if let img = BackgroundLook.cgImage(for: .init(settings), size: CGSize(width: 960, height: 640), scale: 1) {
            let url = outputDir.appendingPathComponent("background-mesh-grain.png")
            if let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, img, nil)
                CGImageDestinationFinalize(dest)
                print("BACKGROUND-LOOK artifact \(url.path)")
            }
        }
        settings.backgroundType = .gradient
        settings.backgroundNoise = 0
        settings.gradientStartColor = CodableColor(red: 1, green: 0, blue: 0)
        settings.gradientEndColor = CodableColor(red: 0, green: 0, blue: 1)

        // (c) Preview (2×) vs export (1×) agree proportionally with blur +
        // vignette + tint active — the whole chain, not just the base.
        settings.backgroundTintColor = CodableColor(red: 0, green: 1, blue: 0)
        settings.backgroundTintOpacity = 0.3
        settings.backgroundVignette = 0.6
        if let x1 = BackgroundLook.cgImage(for: .init(settings), size: size, scale: 1),
           let x2 = BackgroundLook.cgImage(for: .init(settings), size: size, scale: 2) {
            var worst = 0.0
            for (fx, fy) in [(0.05, 0.05), (0.5, 0.5), (0.95, 0.95), (0.2, 0.8), (0.8, 0.2)] {
                guard let a = pixel(x1, fx, fy), let b = pixel(x2, fx, fy) else { continue }
                worst = max(worst, abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b))
            }
            check("preview-scale-vs-export-scale", worst * 255 < 6 && x2.width == 640,
                  String(format: "worst=%.1f/255 w2x=%d", worst * 255, x2.width))
        }
    }

    private static func gradientRampCheck() {
        let pairs: [(String, SRGBA, SRGBA, BackgroundGradientRenderer.Axis)] = [
            ("grad-blue-purple",
             .init(red: 0.29, green: 0.42, blue: 0.93), .init(red: 0.62, green: 0.30, blue: 0.87), .diagonal),
            ("grad-red-cyan-saturated",
             .init(red: 1, green: 0, blue: 0), .init(red: 0, green: 1, blue: 1), .diagonal),
            ("grad-black-white",
             .init(white: 0), .init(white: 1), .diagonal),
            ("grad-green-magenta",
             .init(red: 0, green: 1, blue: 0), .init(red: 1, green: 0, blue: 1), .diagonal),
            ("grad-orange-navy",
             .init(red: 1, green: 0.58, blue: 0), .init(red: 0.04, green: 0.05, blue: 0.28), .diagonal),
            ("grad-wallpaper-vertical",
             .init(white: 0.16), .init(white: 0.09), .vertical),
        ]
        let size = CGSize(width: 480, height: 270)
        // 2/255 absorbs 8-bit quantisation, the renderer's dithering and the
        // chord error of OklabGradient's 256-step stop table (measured worst
        // 1.66, on fully-saturated red→cyan at the very end of the ramp).
        // A gamma-sRGB ramp — the thing this exists to catch — misses by ~15.
        let bar = 2.0
        for (name, start, end, axis) in pairs {
            guard let native = BackgroundGradientRenderer.image(
                start: start, end: end, size: size, axis: axis, scale: scale
            ), let px = rgba(native) else {
                failures.append("\(name): CG render failed"); continue
            }
            defer { px.free() }

            let stops = [(CGFloat(0), start), (CGFloat(1), end)]
            var worst = 0.0
            var worstAt = 0.0
            // Sample along the ramp's own axis. `.vertical` runs top→bottom;
            // `.diagonal` runs corner to corner, so the main diagonal of the
            // image is exactly the ramp parameter.
            for i in 1..<32 {
                let t = Double(i) / 32
                let x = axis == .vertical ? px.width / 2 : Int(t * Double(px.width - 1))
                let y = Int(t * Double(px.height - 1))
                let row = px.bytes + y * px.bytesPerRow + x * 4
                // `rgba` builds its buffer premultipliedLast, i.e. R,G,B,A.
                let a = Double(row[3]) / 255
                guard a > 0.001 else { continue }
                let got = (
                    r: Double(row[0]) / 255 / a,
                    g: Double(row[1]) / 255 / a,
                    b: Double(row[2]) / 255 / a
                )
                let want = OklabGradient.sample(stops, at: CGFloat(t))
                let d = max(
                    abs(got.r - Double(want.red)),
                    abs(got.g - Double(want.green)),
                    abs(got.b - Double(want.blue))
                ) * 255
                if d > worst { worst = d; worstAt = t }
                if CommandLine.arguments.contains("--gradient-trace"), i % 8 == 1 {
                    print(String(
                        format: "  TRACE %@ t=%.3f xy=%d,%d got=%.3f,%.3f,%.3f want=%.3f,%.3f,%.3f",
                        name, t, x, y, got.r, got.g, got.b,
                        Double(want.red), Double(want.green), Double(want.blue)
                    ))
                }
            }
            print(String(format: "GRADIENT %-26@ worst=%.3f/255 at t=%.2f (bar %.1f)", name, worst, worstAt, bar))
            if worst > bar {
                failures.append(String(format: "%@ ramp off Oklab by %.3f/255", name, worst))
            }
        }
    }

    // MARK: - Device bezel

    private struct BezelState {
        var name: String
        var canvas: CGSize
        var videoRect: CGRect
        var shadowRadius: CGFloat = 12
        var shadowOpacity: CGFloat = 0.6
        var pitch: Double = 0
        var yaw: Double = 0
    }

    private static let bezelStates: [BezelState] = [
        // Phone aspect, flat — the full chrome: buttons, band, rim, AO, glass.
        .init(name: "bezel-phone-flat",
              canvas: CGSize(width: 420, height: 640),
              videoRect: CGRect(x: 150, y: 60, width: 120, height: 260)),
        // Tilted: the extruded side slab slides out from behind the body.
        .init(name: "bezel-phone-tilt",
              canvas: CGSize(width: 420, height: 640),
              videoRect: CGRect(x: 150, y: 60, width: 120, height: 260),
              pitch: 11, yaw: -17),
        // A device SEGMENT: the frame is a sub-rect of a wider canvas.
        .init(name: "bezel-segment",
              canvas: CGSize(width: 720, height: 405),
              videoRect: CGRect(x: 300, y: 24, width: 92, height: 200),
              shadowRadius: 20, shadowOpacity: 0.85, pitch: -8, yaw: 9),
        // iPad aspect: thin flat frame, no buttons, no glass margin.
        .init(name: "bezel-pad-flat",
              canvas: CGSize(width: 520, height: 420),
              videoRect: CGRect(x: 110, y: 70, width: 300, height: 225)),
        // Shadow extremes.
        .init(name: "bezel-phone-noshadow",
              canvas: CGSize(width: 420, height: 640),
              videoRect: CGRect(x: 150, y: 60, width: 120, height: 260),
              shadowRadius: 0, shadowOpacity: 0),
        .init(name: "bezel-phone-bigshadow",
              canvas: CGSize(width: 420, height: 640),
              videoRect: CGRect(x: 150, y: 60, width: 120, height: 260),
              shadowRadius: 34, shadowOpacity: 1),
    ]

    /// SwiftUI `DeviceBezelView` vs `DeviceBezelRenderer`.
    private static func bezelCheck() {
        for state in bezelStates {
            guard let native = DeviceBezelRenderer.image(
                size: state.canvas, videoRect: state.videoRect,
                shadowRadius: state.shadowRadius, shadowOpacity: state.shadowOpacity,
                pitchDegrees: state.pitch, yawDegrees: state.yaw, scale: scale
            ) else {
                failures.append("\(state.name): CG render failed"); continue
            }
            compare(name: state.name, cg: native)
            // A downsampled fingerprint cannot see a duplicated Dynamic Island
            // (CLAUDE.md §3's own example: 1.846/255, visibly wrong), so the
            // bezel states additionally assert their dark-blob structure.
            assertBlobs(name: state.name, image: native)
        }
    }

    // MARK: - Annotations

    private static let annotationCanvas = CGSize(width: 720, height: 405)
    private static let annotationVideoRect = CGRect(x: 40, y: 24, width: 640, height: 360)

    /// Builds one annotation of `type` with everything else pinned, so a state
    /// differs from its neighbours only in the way it is named.
    private static func annotation(
        _ type: AnnotationType,
        _ mutate: (inout Annotation) -> Void = { _ in }
    ) -> Annotation {
        var a = Annotation(type: type, startTime: 0, endTime: 10)
        // The SwiftUI overlay ignores fontName/uppercase (the shared renderer
        // honours both), so the comparison pins them to the values where the
        // two agree — the divergence is called out in AnnotationRenderer.
        a.fontName = nil
        a.uppercase = false
        a.enterEffect = .none
        a.exitEffect = .none
        a.showShadow = false
        mutate(&a)
        return a
    }

    private static func annotationStates() -> [(String, [Annotation], TimeInterval, Bool, UUID?)] {
        var states: [(String, [Annotation], TimeInterval, Bool, UUID?)] = []

        // Every type, played (no editor chrome).
        states.append(("anno-text", [annotation(.text) {
            $0.text = "Ship it"; $0.x = 0.5; $0.y = 0.4
        }], 5, true, nil))
        states.append(("anno-text-nobg", [annotation(.text) {
            $0.text = "No pill"; $0.showBackground = false; $0.color = CodableColor(red: 1, green: 0.85, blue: 0.2, opacity: 1)
        }], 5, true, nil))
        states.append(("anno-text-bigradius", [annotation(.text) {
            $0.text = "Rounded"; $0.cornerRadius = 40; $0.fontSize = 28
        }], 5, true, nil))
        states.append(("anno-arrow", [annotation(.arrow) {
            $0.x = 0.2; $0.y = 0.25; $0.arrowEndX = 0.72; $0.arrowEndY = 0.7
            $0.color = CodableColor(red: 0.99, green: 0.32, blue: 0.28, opacity: 1)
            $0.lineWidth = 6
        }], 5, true, nil))
        states.append(("anno-callout", [annotation(.callout) {
            $0.text = "Look here"; $0.x = 0.62; $0.y = 0.3
            $0.arrowEndX = 0.25; $0.arrowEndY = 0.75
        }], 5, true, nil))
        states.append(("anno-rectangle", [annotation(.rectangle) {
            $0.x = 0.15; $0.y = 0.2; $0.arrowEndX = 0.6; $0.arrowEndY = 0.7
            $0.cornerRadius = 14; $0.lineWidth = 5
            $0.color = CodableColor(red: 0.2, green: 0.9, blue: 0.6, opacity: 1)
            $0.backgroundColor = CodableColor(red: 0, green: 0.2, blue: 0.15, opacity: 0.45)
        }], 5, true, nil))
        states.append(("anno-ellipse", [annotation(.ellipse) {
            $0.x = 0.2; $0.y = 0.25; $0.arrowEndX = 0.7; $0.arrowEndY = 0.8
            $0.lineWidth = 4
        }], 5, true, nil))
        states.append(("anno-drawing", [annotation(.drawing) {
            $0.lineWidth = 5
            $0.color = CodableColor(red: 0.4, green: 0.7, blue: 1, opacity: 1)
            $0.drawingStrokes = [
                (0...24).map { i in
                    let t = Double(i) / 24
                    return CodablePoint(x: 0.15 + t * 0.7, y: 0.5 + 0.22 * sin(t * .pi * 3))
                },
                [CodablePoint(x: 0.5, y: 0.15)],   // single-point stroke → dot
            ]
        }], 5, true, nil))

        // Tap ripple, sampled across its loop.
        for (label, t) in [("early", 0.1), ("mid", 0.45), ("late", 0.8)] as [(String, TimeInterval)] {
            states.append(("anno-tap-\(label)", [annotation(.tap) {
                $0.fontSize = 90
                $0.color = CodableColor(red: 1, green: 1, blue: 1, opacity: 0.9)
            }], t, true, nil))
        }

        // Mid-build effects — the frames the analytic phase math actually
        // moves through, not just the settled state.
        states.append(("anno-pop-midbuild", [annotation(.text) {
            $0.text = "Pop"; $0.enterEffect = .pop; $0.fontSize = 30
        }], 0.12, true, nil))
        states.append(("anno-explode-midexit", [annotation(.text) {
            $0.text = "Explode"; $0.exitEffect = .explode; $0.fontSize = 30
        }], 9.85, true, nil))
        states.append(("anno-slideup-midbuild", [annotation(.text) {
            $0.text = "Slide"; $0.enterEffect = .slideUp; $0.fontSize = 26
        }], 0.15, true, nil))
        states.append(("anno-drop-midbuild", [annotation(.callout) {
            $0.text = "Drop"; $0.enterEffect = .drop
            $0.arrowEndX = 0.25; $0.arrowEndY = 0.8
        }], 0.1, true, nil))

        // Shadow + partial opacity — exercises the group shadow path.
        states.append(("anno-shadow", [annotation(.text) {
            $0.text = "Shadowed"; $0.showShadow = true; $0.fontSize = 26
        }], 5, true, nil))
        states.append(("anno-opacity", [annotation(.rectangle) {
            $0.x = 0.2; $0.y = 0.25; $0.arrowEndX = 0.7; $0.arrowEndY = 0.75
            $0.opacity = 0.45; $0.showShadow = true; $0.lineWidth = 6
        }], 5, true, nil))

        // Editor chrome: handles + selection rings (paused).
        let selText = annotation(.text) { $0.text = "Selected" }
        states.append(("anno-chrome-text", [selText], 5, false, selText.id))
        let selArrow = annotation(.arrow) {
            $0.x = 0.25; $0.y = 0.3; $0.arrowEndX = 0.7; $0.arrowEndY = 0.65
        }
        states.append(("anno-chrome-arrow", [selArrow], 5, false, selArrow.id))
        let selShape = annotation(.rectangle) {
            $0.x = 0.2; $0.y = 0.25; $0.arrowEndX = 0.7; $0.arrowEndY = 0.75; $0.cornerRadius = 10
        }
        states.append(("anno-chrome-shape", [selShape], 5, false, selShape.id))
        let selTap = annotation(.tap) { $0.fontSize = 80 }
        states.append(("anno-chrome-tap", [selTap], 5, false, selTap.id))
        let selCallout = annotation(.callout) {
            $0.text = "Pick me"; $0.arrowEndX = 0.28; $0.arrowEndY = 0.78
        }
        states.append(("anno-chrome-callout", [selCallout], 5, false, selCallout.id))

        // Several at once — ordering and independent transforms.
        states.append(("anno-multi", [
            annotation(.text) { $0.text = "One"; $0.x = 0.25; $0.y = 0.2 },
            annotation(.arrow) { $0.x = 0.3; $0.y = 0.4; $0.arrowEndX = 0.7; $0.arrowEndY = 0.6 },
            annotation(.ellipse) { $0.x = 0.55; $0.y = 0.55; $0.arrowEndX = 0.85; $0.arrowEndY = 0.85 },
        ], 5, true, nil))

        return states
    }

    /// SwiftUI `AnnotationOverlay` vs `AnnotationRenderer`.
    private static func annotationCheck() {
        for (name, annotations, time, isPlaying, selected) in annotationStates() {
            let project = Project(name: "golden")
            project.annotations = annotations
            _ = project
            guard let native = AnnotationRenderer.image(
                size: annotationCanvas,
                annotations: annotations,
                currentTime: time,
                videoRect: annotationVideoRect,
                scale: 1,
                chrome: .init(isPlaying: isPlaying, selectedID: selected),
                rasterScale: scale
            ) else {
                failures.append("\(name): CG render failed"); continue
            }
            compare(name: name, cg: native)
        }
    }

    // MARK: - Focus region chrome

    /// SwiftUI `FocusChromeView` vs `SelectionChromeKit` — the fifth
    /// rasterization source (blur/highlight outlines, resize dots, value
    /// pills).
    private static func focusChromeCheck() {
        let canvas = CGSize(width: 720, height: 405)
        let container = CGRect(x: 40, y: 24, width: 640, height: 360)

        let blur = BlurRegion(
            startTime: 0, endTime: 10,
            rect: CGRect(x: 0.08, y: 0.12, width: 0.34, height: 0.3), intensity: 0.7)
        let blur2 = BlurRegion(
            startTime: 0, endTime: 10,
            rect: CGRect(x: 0.55, y: 0.62, width: 0.3, height: 0.25), intensity: 0.35)
        let highlight = HighlightRegion(
            startTime: 0, endTime: 10,
            rect: CGRect(x: 0.3, y: 0.35, width: 0.42, height: 0.34), opacity: 0.6)

        let states: [(String, [BlurRegion], [HighlightRegion], UUID?, UUID?)] = [
            ("chrome-unselected", [blur, blur2], [highlight], nil, nil),
            ("chrome-blur-selected", [blur, blur2], [highlight], blur.id, nil),
            ("chrome-highlight-selected", [blur], [highlight], nil, highlight.id),
            // Region pinned to the bottom edge: the pill flips INSIDE it.
            ("chrome-pill-flip", [BlurRegion(
                startTime: 0, endTime: 10,
                rect: CGRect(x: 0.3, y: 0.72, width: 0.4, height: 0.26), intensity: 0.9)],
             [], nil, nil),
        ]

        for (name, blurs, highlights, selBlur, selHighlight) in states {
            var blursForState = blurs
            var selectedBlur = selBlur
            if name == "chrome-pill-flip" {
                selectedBlur = blursForState[0].id
                blursForState[0].intensity = 0.9
            }
            var regions: [SelectionChromeKit.Region] = blursForState.map {
                .init(rect: $0.rect, cornerRadius: 10,
                      isSelected: selectedBlur == $0.id,
                      sliderValue: $0.intensity, sliderRange: 0.1...1.0,
                      leadingIcon: "eye", trailingIcon: "eye.slash.fill")
            }
            regions += highlights.map {
                let rendered = $0.rectInViewSpace(in: container)
                return .init(rect: $0.rect,
                             cornerRadius: HighlightRegion.cornerRadius(for: rendered, in: container),
                             isSelected: selHighlight == $0.id,
                             sliderValue: $0.opacity, sliderRange: 0.1...0.9,
                             leadingIcon: "circle.lefthalf.filled", trailingIcon: "circle.fill")
            }
            // Unified contract: chrome exists ONLY for selected objects. The
            // all-unselected state must render NOTHING — a structural
            // assertion now, since an empty image has no fingerprint.
            if name == "chrome-unselected" {
                if SelectionChromeKit.image(
                    size: canvas, regions: regions, containerRect: container, scale: scale
                ) != nil {
                    failures.append("\(name): expected NO chrome for unselected regions")
                }
                continue
            }
            guard let native = SelectionChromeKit.image(
                size: canvas, regions: regions, containerRect: container, scale: scale
            ) else { failures.append("\(name): CG render failed"); continue }
            compare(name: name, cg: native)
        }
    }

    // MARK: - Exporter orientation

    /// The preview draws annotations y-DOWN; the exporter hands the renderer a
    /// CoreImage y-UP `videoRect` and wraps the result in a `CIImage`. Nothing
    /// in `--preview-parity` exercises that flip, and getting it wrong mirrors
    /// every annotation vertically — a failure that would ship silently. So
    /// assert it end-to-end: run the exporter's exact conversion, rasterize
    /// the resulting CIImage the way the export pipeline does, and check the
    /// annotation lands where CI-space geometry says it should.
    private static func exporterOrientationCheck() {
        let outputSize = CGSize(width: 640, height: 360)
        // y-UP rect, as CoreImage hands it over.
        let videoRectYUp = CGRect(x: 40, y: 30, width: 560, height: 300)
        var a = Annotation(type: .text, startTime: 0, endTime: 10)
        a.text = "X"; a.x = 0.5; a.y = 0.25       // a quarter down from the TOP
        a.enterEffect = .none; a.exitEffect = .none; a.showShadow = false
        a.fontName = nil; a.uppercase = false

        // Verbatim copy of VideoExporter.renderAnnotations' conversion.
        let videoRectYDown = CGRect(
            x: videoRectYUp.minX,
            y: outputSize.height - videoRectYUp.maxY,
            width: videoRectYUp.width,
            height: videoRectYUp.height
        )
        guard let overlay = AnnotationRenderer.image(
            size: outputSize, annotations: [a], currentTime: 5,
            videoRect: videoRectYDown, scale: 1, chrome: nil, rasterScale: 1
        ) else { failures.append("exporter-orientation: render failed"); return }

        let ci = CIImage(cgImage: overlay)
        let ciContext = CIContext(options: [.useSoftwareRenderer: true])
        guard let flat = ciContext.createCGImage(ci, from: CGRect(origin: .zero, size: outputSize)),
              let box = paintedBox(flat) else {
            failures.append("exporter-orientation: CI rasterize failed"); return
        }
        // paintedBox is measured from the TOP of the CGImage.
        let centerFromTop = box.midY
        let expectedFromTop = outputSize.height - (videoRectYUp.maxY - 0.25 * videoRectYUp.height)
        let err = abs(centerFromTop - expectedFromTop)
        print(String(format: "EXPORT-ORIENT annotation centre y=%.1f expected=%.1f err=%.1fpt",
                     centerFromTop, expectedFromTop, err))
        if err > 2 {
            failures.append(String(
                format: "exporter orientation: annotation at y=%.1f, expected %.1f (vertical flip?)",
                centerFromTop, expectedFromTop))
        }
    }

    // MARK: - Compare

    /// Scores a render against its frozen fingerprint, writes the PNG for
    /// eyeballing, and records a failure past `fingerprintBar`.
    ///
    /// `--refreeze` prints a fresh table instead of asserting. Use it ONLY when
    /// a render change is intended, and read the printed deltas first — this is
    /// the only thing standing between a deliberate change and a silent one.
    private static func compare(name: String, cg: CGImage) {
        savePNG(cg, outputDir.appendingPathComponent("\(name)-cg.png"))
        guard let got = RasterFingerprint.make(cg) else {
            failures.append("\(name): fingerprint failed")
            return
        }
        if refreezing {
            refrozen.append("        \"\(name)\": \"\(got)\",")
            return
        }
        guard let want = RasterGoldens.fingerprints[name] else {
            failures.append("\(name): no frozen fingerprint — add one via --refreeze")
            return
        }
        guard let worst = RasterFingerprint.worstDelta(want, got) else {
            failures.append("\(name): fingerprint shape mismatch")
            return
        }
        print(String(format: "RASTER %-30@ worst cell=%.0f/255  (bar %.0f)", name, worst, fingerprintBar))
        if worst > fingerprintBar {
            failures.append(String(format: "%@ fingerprint off by %.0f/255", name, worst))
        }
    }

    /// Dark-blob structure: count and centroids.
    ///
    /// NOTE the counts here are 0: `DeviceBezelRenderer.image()` draws the body,
    /// glass and shadow but NOT the Dynamic Island — that is composited a layer
    /// up, by `DeviceFrameRenderer.drawIsland`. So this asserts "the bezel path
    /// still draws no pure-black component", which catches an island leaking
    /// into the wrong renderer but is not the island gate.
    ///
    /// The real island gate is in `--preview-parity`, where the phone states
    /// resolve 2 blobs (the frame's black band + the island) and the segment
    /// states 1. CLAUDE.md §3: a duplicated island scored 1.846/255 and passed a
    /// mean while being visibly wrong.
    private static func assertBlobs(name: String, image: CGImage) {
        let blobs = HarnessPixels.darkBlobs(image, minArea: 200)
        let summary = blobs
            .map { String(format: "%d@%.0f,%.0f", $0.area, $0.centroid.x, $0.centroid.y) }
            .joined(separator: " ")
        print("BLOBS \(name) n=\(blobs.count) [\(summary)]")
        if refreezing {
            refrozenBlobs.append("        \"\(name)\": \(blobs.count),")
            return
        }
        guard let want = RasterGoldens.blobCounts[name] else {
            failures.append("\(name): no frozen blob count — add one via --refreeze")
            return
        }
        if blobs.count != want {
            failures.append("\(name): \(blobs.count) dark blobs, expected \(want)")
        }
    }

    /// `mean` is the raw per-channel mean abs diff. `smoothed` is the same
    /// figure after 4x4 box-averaging BOTH images, which cancels SwiftUI's
    /// gradient/text dithering: a SwiftUI gradient carries ~1.0/255 of ordered
    /// dither noise that no native renderer reproduces, so `mean` has an
    /// irreducible ~0.45 floor while `smoothed` shows the true ramp error.
    private static func diff(_ a: CGImage, _ b: CGImage) -> (mean: Double, smoothed: Double, max: Double, image: CGImage?)? {
        guard let pa = rgba(a), let pb = rgba(b) else { return nil }
        defer { pa.free(); pb.free() }
        guard pa.width == pb.width, pa.height == pb.height else { return nil }
        var total = 0.0, count = 0.0, worst = 0.0
        let w = pa.width, h = pa.height
        let bpr = w * 4
        let out = UnsafeMutablePointer<UInt8>.allocate(capacity: bpr * h)
        for y in 0..<h {
            let ra = pa.bytes + y * pa.bytesPerRow
            let rb = pb.bytes + y * pb.bytesPerRow
            let ro = out + y * bpr
            for x in 0..<w {
                let ia = ra + x * 4, ib = rb + x * 4, io = ro + x * 4
                var localMax = 0.0
                // All FOUR channels count. Premultiplied RGB alone is blind to
                // the drop shadow: black over transparency is (0,0,0) at every
                // alpha, so a completely wrong blur would score zero.
                for c in 0..<4 {
                    let d = abs(Double(ia[c]) - Double(ib[c]))
                    total += d; count += 1
                    localMax = Swift.max(localMax, d)
                }
                worst = Swift.max(worst, localMax)
                // ×16 amplification so sub-1/255 drift is actually visible.
                let v = UInt8(Swift.min(255, localMax * 16))
                io[0] = v; io[1] = v; io[2] = v; io[3] = 255
            }
        }
        var image: CGImage?
        if let ctx = CGContext(
            data: out, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) { image = ctx.makeImage() }
        out.deallocate()

        // Dither-cancelled pass.
        let k = 4
        var sTotal = 0.0, sCount = 0.0
        for by in stride(from: 0, to: h - k + 1, by: k) {
            for bx in stride(from: 0, to: w - k + 1, by: k) {
                var sa = [0.0, 0.0, 0.0, 0.0], sb = [0.0, 0.0, 0.0, 0.0]
                for y in by..<(by + k) {
                    let ra = pa.bytes + y * pa.bytesPerRow
                    let rb = pb.bytes + y * pb.bytesPerRow
                    for x in bx..<(bx + k) {
                        for c in 0..<4 {
                            sa[c] += Double((ra + x * 4)[c])
                            sb[c] += Double((rb + x * 4)[c])
                        }
                    }
                }
                let n = Double(k * k)
                for c in 0..<4 { sTotal += abs(sa[c] - sb[c]) / n; sCount += 1 }
            }
        }
        return (
            count > 0 ? total / count : 255,
            sCount > 0 ? sTotal / sCount : 255,
            worst, image
        )
    }

    private struct Pixels {
        var bytes: UnsafeMutablePointer<UInt8>
        var width: Int
        var height: Int
        var bytesPerRow: Int
        func free() { bytes.deallocate() }
    }

    /// Normalizes any CGImage into straight-alpha device RGBA8 so two images
    /// from different pipelines are byte-comparable.
    private static func rgba(_ image: CGImage) -> Pixels? {
        let w = image.width, h = image.height
        let bpr = w * 4
        let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: bpr * h)
        bytes.update(repeating: 0, count: bpr * h)
        guard let ctx = CGContext(
            data: bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { bytes.deallocate(); return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return Pixels(bytes: bytes, width: w, height: h, bytesPerRow: bpr)
    }

    private static func savePNG(_ image: CGImage, _ url: URL) {
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Polyline sampling of a path — 64 samples per cubic.
    private static func flatten(_ path: CGPath, per: Int = 64) -> [CGPoint] {
        var out: [CGPoint] = []
        var current = CGPoint.zero
        var start = CGPoint.zero
        path.applyWithBlock { el in
            let e = el.pointee
            switch e.type {
            case .moveToPoint:
                current = e.points[0]; start = current; out.append(current)
            case .addLineToPoint:
                current = e.points[0]; out.append(current)
            case .addQuadCurveToPoint:
                let c: CGPoint = e.points[0]
                let p: CGPoint = e.points[1]
                let p0: CGPoint = current
                for i in 1...per {
                    let t = CGFloat(i) / CGFloat(per)
                    let u: CGFloat = 1 - t
                    let wa: CGFloat = u * u
                    let wb: CGFloat = 2 * u * t
                    let wc: CGFloat = t * t
                    let x: CGFloat = wa * p0.x + wb * c.x + wc * p.x
                    let y: CGFloat = wa * p0.y + wb * c.y + wc * p.y
                    out.append(CGPoint(x: x, y: y))
                }
                current = p
            case .addCurveToPoint:
                let c1: CGPoint = e.points[0]
                let c2: CGPoint = e.points[1]
                let p: CGPoint = e.points[2]
                let p0: CGPoint = current
                for i in 1...per {
                    let t = CGFloat(i) / CGFloat(per)
                    let u: CGFloat = 1 - t
                    let wa: CGFloat = u * u * u
                    let wb: CGFloat = 3 * u * u * t
                    let wc: CGFloat = 3 * u * t * t
                    let wd: CGFloat = t * t * t
                    let x: CGFloat = wa * p0.x + wb * c1.x + wc * c2.x + wd * p.x
                    let y: CGFloat = wa * p0.y + wb * c1.y + wc * c2.y + wd * p.y
                    out.append(CGPoint(x: x, y: y))
                }
                current = p
            case .closeSubpath:
                out.append(start); current = start
            @unknown default:
                break
            }
        }
        return out
    }
}
