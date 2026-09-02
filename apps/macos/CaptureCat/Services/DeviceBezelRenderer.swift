import CoreGraphics
import Foundation

/// The iPhone 16 Pro chrome, drawn in pure CoreGraphics.
///
/// This is the ONE implementation — the preview compositor rasterizes it for
/// `bezelLayer.contents` and `DeviceFrameRenderer` calls it for the exporter,
/// so the two cannot drift. It replaces the old `DeviceBezelView` (SwiftUI,
/// rasterized through `ImageRenderer`) shape-for-shape.
///
/// # Coordinate space
///
/// Everything is expressed Y-DOWN — the screen's TOP is `videoRect.minY` —
/// which is how the layout constants in `DeviceFrameLayout` read. A y-up
/// caller (CoreImage) passes `yUp: true` and the context is flipped on entry,
/// so there is only one set of geometry to keep straight.
///
/// # Fidelity notes
///
/// * Corners are `ContinuousRoundedRect`, never circular arcs.
/// * `strokeBorder(lineWidth: w)` on a rounded rect is `rect.insetBy(w/2)`
///   with `cornerRadius - w/2` — SwiftUI's `inset(by:)` takes the radius down
///   by the inset amount (probed, not assumed). The AO ring is built as
///   `RoundedRectangle(r - 1.5·rim).inset(by: 1.5·rim)`, so its radius is
///   `r - 3·rim`, not `r - 1.5·rim`.
/// * Every gradient interpolates in Oklab — see `OklabGradient`.
enum DeviceBezelRenderer {
    /// SwiftUI's `.shadow(radius:)` versus `CGContext.setShadow(blur:)`.
    ///
    /// Measured, not derived: sweeping the bezel against its SwiftUI golden
    /// puts the L1 optimum at 2.2 — and at 2.2 independently at 1x, 2x and 3x
    /// once the blur carries the device scale (see below). The minimum is
    /// shallow (0.33 at 2.2, 0.37 at 2.0), which is what you expect when the
    /// two kernels are near-Gaussian but not identical.
    static var shadowBlurFactor: CGFloat = 2.2

    /// How many chrome rasters happened, and (under `CAPTURECAT_RENDER_TIMING=1`)
    /// what they cost. The COUNT is always maintained — `--preview-parity`
    /// asserts on it to prove a tilt spring re-rasterizes nothing.
    nonisolated(unsafe) static var rasterCount = 0
    nonisolated(unsafe) static var rasterTotal: Double = 0

    // MARK: - Entry points

    static func image(
        size: CGSize,
        videoRect: CGRect,
        shadowRadius: CGFloat,
        shadowOpacity: CGFloat,
        pitchDegrees: Double,
        yawDegrees: Double,
        scale: CGFloat
    ) -> CGImage? {
        let w = Int((size.width * scale).rounded()), h = Int((size.height * scale).rounded())
        guard w > 0, h > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        let t0 = PreviewCompositorView.renderTiming ? CFAbsoluteTimeGetCurrent() : 0
        draw(in: ctx, size: size, videoRect: videoRect,
             shadowRadius: shadowRadius, shadowOpacity: shadowOpacity,
             pitchDegrees: pitchDegrees, yawDegrees: yawDegrees, yUp: true)
        let image = ctx.makeImage()
        if PreviewCompositorView.renderTiming {
            rasterCount += 1
            rasterTotal += CFAbsoluteTimeGetCurrent() - t0
        }
        return image
    }

    /// - Parameter yUp: `true` when the context's origin is bottom-left (a raw
    ///   `CGContext` or CoreImage); `false` for an already-flipped context.
    static func draw(
        in ctx: CGContext,
        size: CGSize,
        videoRect: CGRect,
        shadowRadius: CGFloat,
        shadowOpacity: CGFloat,
        pitchDegrees: Double,
        yawDegrees: Double,
        yUp: Bool
    ) {
        ctx.saveGState()
        if yUp {
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        drawYDown(in: ctx, videoRect: videoRect,
                  shadowRadius: shadowRadius, shadowOpacity: shadowOpacity,
                  pitchDegrees: pitchDegrees, yawDegrees: yawDegrees)
        ctx.restoreGState()
    }

    /// Rasterizes an arbitrary y-DOWN drawing block into a y-up image.
    ///
    /// The preview splits the chrome into three separately-cached rasters
    /// (buttons, side slab, body) rather than baking one image per tilt angle.
    /// That is not an optimization detail — `drawSideButtons` and `drawBody`
    /// take no angles at all, and tilt enters `drawSideSlab` purely as a
    /// TRANSLATION of the same pixels. So the whole chrome is tilt-independent
    /// up to moving one layer, and re-rasterizing it per 0.1 degree of tilt was
    /// pure waste. The exporter already worked this way ("bakes this once with
    /// offset .zero and translates it per frame"); this brings the preview to
    /// the same structure, which is also what §2 wants.
    ///
    /// Compositing is unchanged: source-over is associative, and the body's
    /// drop shadow is drawn inside the body's own raster, so it still darkens
    /// the slab and buttons underneath exactly as it did in one flat context.
    static func layerImage(
        size: CGSize,
        scale: CGFloat,
        _ body: (CGContext) -> Void
    ) -> CGImage? {
        let w = Int((size.width * scale).rounded()), h = Int((size.height * scale).rounded())
        guard w > 0, h > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        let t0 = PreviewCompositorView.renderTiming ? CFAbsoluteTimeGetCurrent() : 0
        withYDown(ctx, height: size.height) { body($0) }
        let image = ctx.makeImage()
        rasterCount += 1
        if PreviewCompositorView.renderTiming { rasterTotal += CFAbsoluteTimeGetCurrent() - t0 }
        return image
    }

    /// Flips an already-y-up context so the y-DOWN drawing routines below can
    /// be used directly. Pass the full canvas height.
    static func withYDown(_ ctx: CGContext, height: CGFloat, _ body: (CGContext) -> Void) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: height)
        ctx.scaleBy(x: 1, y: -1)
        body(ctx)
        ctx.restoreGState()
    }

    // MARK: - Body

    private static func drawYDown(
        in ctx: CGContext,
        videoRect: CGRect,
        shadowRadius: CGFloat,
        shadowOpacity: CGFloat,
        pitchDegrees: Double,
        yawDegrees: Double
    ) {
        // ZStack order: side buttons, extruded side slab, body (+ its drop
        // shadow, cast over both), then the black glass margin.
        drawSideButtons(in: ctx, videoRect: videoRect)
        drawSideSlab(in: ctx, videoRect: videoRect, offset: TiltMath.deviceSideOffset(
            pitchDegrees: pitchDegrees,
            yawDegrees: yawDegrees,
            videoWidth: videoRect.width
        ))
        drawBody(in: ctx, videoRect: videoRect,
                 shadowRadius: shadowRadius, shadowOpacity: shadowOpacity)
    }

    /// Side buttons peeking out from behind the band — Action + volume on the
    /// left rail, side button + Camera Control on the right.
    static func drawSideButtons(in ctx: CGContext, videoRect: CGRect) {
        let m = DeviceFrameLayout.metrics(forVideoRect: videoRect)
        let bezelRect = m.bodyRect
        guard bezelRect.width > 0, bezelRect.height > 0 else { return }
        if m.isPhone {
            for button in DeviceFrameLayout.sideButtons {
                let thickness = max(1, m.value(button.thicknessFraction))
                let w = thickness + 1
                let h = bezelRect.height * button.lengthFraction
                let cx = button.isLeft
                    ? bezelRect.minX - w / 2 + 1
                    : bezelRect.maxX + w / 2 - 1
                let cy = bezelRect.minY + bezelRect.height * button.centerFraction
                let rect = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
                // Corner radius is thickness/2 — the button's own thickness,
                // not the +1 frame width.
                let path = ContinuousRoundedRect.path(rect: rect, cornerRadius: thickness / 2)

                ctx.saveGState()
                ctx.addPath(path)
                ctx.clip()
                fillVertical(ctx, rect: rect,
                             top: DeviceFrameLayout.buttonTop,
                             mid: DeviceFrameLayout.RGB.mix(DeviceFrameLayout.buttonTop,
                                                            DeviceFrameLayout.buttonBottom),
                             bottom: DeviceFrameLayout.buttonBottom)
                ctx.restoreGState()

                // Hairline highlight (strokeBorder → inset by half its width).
                let lw = max(0.75, thickness * 0.16)
                ctx.addPath(ContinuousRoundedRect.path(
                    rect: rect.insetBy(dx: lw / 2, dy: lw / 2),
                    cornerRadius: max(0, thickness / 2 - lw / 2)))
                ctx.setLineWidth(lw)
                ctx.setStrokeColor(SRGBA(white: 1, alpha: DeviceFrameLayout.buttonRim).cgColor)
                ctx.strokePath()
            }
        }
    }

    /// The extruded SIDE faces: the body silhouette offset opposite the tilt,
    /// so the faces rotating toward the viewer are the ones that show. Drawn
    /// UNDER the body. The exporter bakes this once with `offset: .zero` and
    /// translates it per frame.
    static func drawSideSlab(in ctx: CGContext, videoRect: CGRect, offset: CGSize) {
        let m = DeviceFrameLayout.metrics(forVideoRect: videoRect)
        let sideRect = m.bodyRect.offsetBy(dx: offset.width, dy: offset.height)
        guard sideRect.width > 0, sideRect.height > 0 else { return }
        ctx.saveGState()
        ctx.addPath(ContinuousRoundedRect.path(rect: sideRect, cornerRadius: m.bodyCornerRadius))
        ctx.clip()
        fillVertical(ctx, rect: sideRect,
                     top: DeviceFrameLayout.sideTop,
                     mid: DeviceFrameLayout.RGB.mix(DeviceFrameLayout.sideTop,
                                                    DeviceFrameLayout.sideBottom),
                     bottom: DeviceFrameLayout.sideBottom)
        ctx.restoreGState()
    }

    /// The titanium body: band gradient, polished rim, ambient-occlusion line,
    /// and the black glass margin. `shadowOpacity: 0` skips the drop shadow —
    /// the exporter draws its own shadow layer.
    static func drawBody(
        in ctx: CGContext,
        videoRect: CGRect,
        shadowRadius: CGFloat,
        shadowOpacity: CGFloat
    ) {
        let m = DeviceFrameLayout.metrics(forVideoRect: videoRect)
        let bezelRect = m.bodyRect
        let radius = m.bodyCornerRadius
        guard bezelRect.width > 0, bezelRect.height > 0 else { return }

        // Body: band gradient, polished rim, ambient-occlusion line.
        //
        // The three are composited INSIDE a transparency layer so the drop
        // shadow is cast off the finished group exactly once — matching
        // SwiftUI, where `.shadow` applies to the whole styled shape. Drawing
        // them separately would both re-cast the shadow and compound
        // antialiased coverage along the shared outer edge (measured: the
        // edge alpha climbed from 8% to 15% and the outline visibly thickened).
        let bodyPath = ContinuousRoundedRect.path(rect: bezelRect, cornerRadius: radius)
        let rimWidth = m.rimWidth
        ctx.saveGState()
        // setShadow's blur is in DEVICE PIXELS — unlike the offset, it is not
        // transformed by the CTM (verified by sweeping at 1x/2x/3x: the
        // optimum tracked the scale exactly). So carry the scale explicitly.
        let ctm = ctx.ctm
        let deviceScale = sqrt(abs(ctm.a * ctm.d - ctm.b * ctm.c))
        ctx.setShadow(
            offset: CGSize(width: 0, height: shadowRadius / 3),
            blur: shadowRadius * shadowBlurFactor * deviceScale,
            color: SRGBA(white: 0, alpha: 0.45 * shadowOpacity).cgColor
        )
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)

        ctx.saveGState()
        ctx.addPath(bodyPath)
        ctx.clip()
        fillVertical(ctx, rect: bezelRect,
                     top: DeviceFrameLayout.bandTop,
                     mid: DeviceFrameLayout.bandMid,
                     bottom: DeviceFrameLayout.bandBottom)
        ctx.restoreGState()

        // Polished titanium rim: white gradient stroked INSIDE the body edge,
        // brightest top-leading.
        ctx.saveGState()
        ctx.addPath(ContinuousRoundedRect.path(
            rect: bezelRect.insetBy(dx: rimWidth / 2, dy: rimWidth / 2),
            cornerRadius: max(0, radius - rimWidth / 2)))
        ctx.setLineWidth(rimWidth)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        if let gradient = OklabGradient.gradient(stops: [
            (0, SRGBA(white: 1, alpha: DeviceFrameLayout.rimHighlight)),
            (0.5, SRGBA(white: 1, alpha: DeviceFrameLayout.rimMid)),
            (1, SRGBA(white: 1, alpha: DeviceFrameLayout.rimShadowSide)),
        ]) {
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: bezelRect.minX, y: bezelRect.minY),  // topLeading
                end: CGPoint(x: bezelRect.maxX, y: bezelRect.maxY),    // bottomTrailing
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }
        ctx.restoreGState()

        // Ambient-occlusion line: the step between polished edge and matte
        // body. Built as RoundedRectangle(r - 1.5·rim).inset(by: 1.5·rim), so
        // the radius drops twice.
        let aoInset = rimWidth * 1.5
        ctx.addPath(ContinuousRoundedRect.path(
            rect: bezelRect.insetBy(dx: aoInset, dy: aoInset),
            cornerRadius: max(0, radius - 2 * aoInset)))
        ctx.setLineWidth(max(1, rimWidth * 0.6))
        ctx.setStrokeColor(SRGBA(white: 0, alpha: DeviceFrameLayout.innerShadow).cgColor)
        ctx.strokePath()

        ctx.endTransparencyLayer()
        ctx.restoreGState()

        // 4. Black glass margin between band and screen pixels.
        if m.isPhone, m.glassRect != m.screenRect {
            ctx.addPath(ContinuousRoundedRect.path(
                rect: m.glassRect, cornerRadius: m.glassCornerRadius))
            ctx.setFillColor(DeviceFrameLayout.glassColor.srgba.cgColor)
            ctx.fillPath()
        }
    }

    /// Screen seam + Dynamic Island — the layer that sits ABOVE the video.
    static func drawIsland(in ctx: CGContext, videoRect: CGRect) {
        guard DeviceFrameLayout.isPhoneAspect(videoRect.size) else { return }
        let m = DeviceFrameLayout.metrics(forVideoRect: videoRect)

        // Dark seam so the glass reads as recessed.
        let seamWidth = m.seamWidth
        ctx.addPath(ContinuousRoundedRect.path(
            rect: videoRect.insetBy(dx: seamWidth / 2, dy: seamWidth / 2),
            cornerRadius: m.screenCornerRadius))
        ctx.setLineWidth(seamWidth)
        ctx.setStrokeColor(SRGBA(white: 0, alpha: 0.55).cgColor)
        ctx.strokePath()

        // Dynamic Island: a true capsule inset from the screen's top edge.
        let size = DeviceFrameLayout.islandSize(forVideoWidth: videoRect.width)
        let topInset = DeviceFrameLayout.islandTopInset(forVideoWidth: videoRect.width)
        let rect = CGRect(
            x: videoRect.midX - size.width / 2,
            y: videoRect.minY + topInset,
            width: size.width, height: size.height
        )
        ctx.addPath(CGPath(roundedRect: rect,
                           cornerWidth: size.height / 2, cornerHeight: size.height / 2,
                           transform: nil))
        ctx.setFillColor(SRGBA(white: 0).cgColor)
        ctx.fillPath()

        // Front-camera lens + faint ring.
        let dot = m.value(DeviceFrameLayout.cameraDotFraction)
        let dotRect = CGRect(
            x: rect.midX + m.value(DeviceFrameLayout.cameraDotOffsetFraction) - dot / 2,
            y: rect.midY - dot / 2,
            width: dot, height: dot
        )
        ctx.setFillColor(SRGBA(red: 0.07, green: 0.08, blue: 0.11).cgColor)
        ctx.fillEllipse(in: dotRect)
        ctx.setLineWidth(max(0.5, dot * 0.10))
        ctx.setStrokeColor(SRGBA(white: 1, alpha: 0.13).cgColor)
        ctx.strokeEllipse(in: dotRect.insetBy(dx: dot * 0.05, dy: dot * 0.05))
    }

    // MARK: - Helpers

    /// Three-stop top→bottom band gradient over `rect`, in the y-DOWN space.
    private static func fillVertical(
        _ ctx: CGContext,
        rect: CGRect,
        top: DeviceFrameLayout.RGB,
        mid: DeviceFrameLayout.RGB,
        bottom: DeviceFrameLayout.RGB
    ) {
        guard let gradient = OklabGradient.gradient(stops: [
            (0, top.srgba), (0.5, mid.srgba), (1, bottom.srgba),
        ]) else {
            ctx.setFillColor(mid.srgba.cgColor)
            ctx.fill(rect)
            return
        }
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.midX, y: rect.minY),
            end: CGPoint(x: rect.midX, y: rect.maxY),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }
}
