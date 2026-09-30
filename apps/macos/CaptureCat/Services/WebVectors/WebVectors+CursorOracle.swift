import Foundation
import CoreGraphics
import CoreImage
import AppKit

/// VERBATIM ORACLES for the cursor cluster's golden vectors — private or
/// inline Swift that the harness cannot call:
///
/// - Services/VideoExporter.swift (commit da569841c7b63175bffa46d897457f157224774d):
///   `CursorAsset` (L70–74), `export` locals L345–408 (fullCursorCoordinateSize,
///   sourceToOutputScale, maximumZoom, cursorRasterScale, menuBarCrop,
///   effectiveNaturalSize, resolvedCursorCoordinateSize, the event shift),
///   the per-frame cursor gate L1486–1490 + L1736–1781, `shouldHideCursor`
///   L3240–3258, `renderClickRipple` L3290–3350 (skip predicate + arguments),
///   `renderCursorCI` L3354–3467, `manualDropShadow` L3470–3490,
///   `renderCursor` L3492–3555, `makeCursorAsset` L3557–3591,
///   `drawFallbackCursor` L3593–3613.
/// - Views/Editor/ClickRippleOverlay.swift: `clickDragThreshold` L176–180
///   (private) and the numbers `renderForExport` L183–253 hands CoreGraphics.
/// - Services/CursorStyleProvider.swift: private `drawnArrow` / `drawnDot`
///   L121–176 geometry, and the rasterization body of `rasterizedCGImage`
///   L50–117 (minus its cache).
///
/// Each oracle copies the Swift expressions verbatim; where a copy RECORDS the
/// numbers a drawing call receives (renderForExport, the cursor artwork), the
/// harness re-draws the recorded numbers with the identical CoreGraphics /
/// AppKit calls and requires the BYTES to equal the real function's output —
/// so the recorded numbers are provably the ones the app draws.
/// Real shared types (CursorOverlayLayout, CursorPhysicsMath,
/// ClickRippleOverlay, CursorSmoother, CursorStyleProvider, CGRect.applying)
/// are called for real wherever the original code calls them.
enum CursorOracle {

    // MARK: VideoExporter.shouldHideCursor (L3240–3258) — verbatim

    static func shouldHideCursor(
        at currentTime: TimeInterval,
        cursorEvents: [CursorEvent],
        settings: ProjectSettings
    ) -> Bool {
        if !settings.autoHideCursor { return false }
        guard cursorEvents.count > 1 else { return false }

        let recentEvents = cursorEvents.filter {
            $0.timestamp >= currentTime - settings.autoHideDelay && $0.timestamp <= currentTime
        }
        guard recentEvents.count > 1,
              let first = recentEvents.first,
              let last = recentEvents.last else { return false }

        let dist = hypot(last.x - first.x, last.y - first.y)
        return dist < 5
    }

    // MARK: export() locals L331–339 (canvasScale) — verbatim

    static func canvasScale(outputSize: CGSize, previewCanvasSize: CGSize) -> CGFloat {
        let referenceCanvas: CGSize = {
            let previewSize = previewCanvasSize
            guard previewSize.width > 0, previewSize.height > 0 else { return outputSize }
            return previewSize
        }()
        return min(outputSize.width / referenceCanvas.width,
                   outputSize.height / referenceCanvas.height)
    }

    // MARK: export() locals L345–408 — verbatim

    struct Setup {
        let fullCursorCoordinateSize: CGSize
        let sourceToOutputScale: CGFloat
        let maximumZoom: Double
        let cursorRasterScale: CGFloat
        let menuBarCrop: CGFloat
        let effectiveNaturalSize: CGSize
        let resolvedCursorCoordinateSize: CGSize
        let shiftedEvents: [CursorEvent]
        let displayWidth: CGFloat
        let displayHeight: CGFloat
    }

    static func setup(
        project: Project,
        settings: ProjectSettings,
        cursorCoordinateSize: CGSize,
        naturalSize: CGSize,
        outputSize: CGSize,
        cursorEvents inputEvents: [CursorEvent]
    ) -> Setup {
        var cursorEvents = inputEvents
        let fullCursorCoordinateSize = CursorOverlayLayout.resolveCoordinateSize(
            recordedSize: cursorCoordinateSize,
            fallbackSourceSize: naturalSize
        )
        let sourceToOutputScale = min(
            outputSize.width / max(1, fullCursorCoordinateSize.width),
            outputSize.height / max(1, fullCursorCoordinateSize.height)
        )
        let maximumZoom = max(1, project.zoomRegions.map(\.zoomLevel).max() ?? 1)
        let cursorRasterScale = max(
            1,
            sourceToOutputScale * CGFloat(settings.cursorScale * maximumZoom) * 1.25
        )

        let menuBarCrop: CGFloat = {
            guard settings.menuBarReplacement == .hidden,
                  project.recordingSourceKind != .device,
                  !project.sourceSegments.contains(where: { $0.kind == .device }) else { return 0 }
            return min(0.12, max(0, settings.menuBarHeight / 100))
        }()
        let effectiveNaturalSize = CGSize(
            width: naturalSize.width,
            height: naturalSize.height * (1 - menuBarCrop)
        )

        let resolvedCursorCoordinateSize = CGSize(
            width: fullCursorCoordinateSize.width,
            height: fullCursorCoordinateSize.height * (1 - menuBarCrop)
        )
        if menuBarCrop > 0 {
            let shift = fullCursorCoordinateSize.height * menuBarCrop
            cursorEvents = cursorEvents.map {
                CursorEvent(timestamp: $0.timestamp, x: $0.x, y: $0.y - shift, isClick: $0.isClick)
            }
        }
        let displayWidth = resolvedCursorCoordinateSize.width
        let displayHeight = resolvedCursorCoordinateSize.height
        return Setup(
            fullCursorCoordinateSize: fullCursorCoordinateSize,
            sourceToOutputScale: sourceToOutputScale,
            maximumZoom: maximumZoom,
            cursorRasterScale: cursorRasterScale,
            menuBarCrop: menuBarCrop,
            effectiveNaturalSize: effectiveNaturalSize,
            resolvedCursorCoordinateSize: resolvedCursorCoordinateSize,
            shiftedEvents: cursorEvents,
            displayWidth: displayWidth,
            displayHeight: displayHeight)
    }

    // MARK: CursorAsset (L70–74) + makeCursorAsset (L3557–3591) — verbatim

    struct CursorAsset {
        let cgImage: CGImage?
        let baseSize: CGSize
        let hotSpot: CGPoint
    }

    static func makeCursorAsset(
        style: ProjectSettings.CursorStyle,
        rasterScale: CGFloat
    ) -> CursorAsset {
        let asset = CursorStyleProvider.asset(for: style)
        let cursorImage = asset.image
        let imageSize = cursorImage.size
        let hotSpot = asset.hotSpot
        if imageSize.width > 0,
           imageSize.height > 0,
           let cgImage = CursorStyleProvider.rasterizedCGImage(
               for: style,
               pixelSize: CGSize(
                   width: imageSize.width * rasterScale,
                   height: imageSize.height * rasterScale
               )
           ) {
            return CursorAsset(
                cgImage: cgImage,
                baseSize: imageSize,
                hotSpot: hotSpot
            )
        }

        // Rasterization failed — keep the provider's point size and hotspot so
        // the drawn fallback still occupies exactly the preview cursor's rect.
        return CursorAsset(
            cgImage: nil,
            baseSize: imageSize.width > 0 && imageSize.height > 0
                ? imageSize : CGSize(width: 20, height: 28),
            hotSpot: hotSpot
        )
    }

    // MARK: renderCursorCI (L3354–3467) + manualDropShadow (L3470–3490) — numbers

    struct Composite {
        let videoRectInViewSpace: CGRect
        let layout: CursorOverlayLayout
        let drawRect: CGRect
        let scaleX: CGFloat
        let scaleY: CGFloat
        let placeTransform: CGAffineTransform
        let pose: CursorPhysicsMath.Pose
        let ciPose: CursorPhysicsMath.Pose
        let poseIsIdentity: Bool
        let tipCI: CGPoint
        let physicsTransform: CGAffineTransform
        let spriteTransform: CGAffineTransform
        let spriteTransformYDown: CGAffineTransform
        /// `CGRect(origin: .zero, size: raster).applying(spriteTransform)` —
        /// CoreGraphics bounds of the placed sprite (Y-up). NOTE: CoreImage's
        /// own `positioned.extent` is the INTEGRAL version of this box (with a
        /// ~1e-3 px snap, CGRect.null for a zero-scale sprite); it only sizes
        /// the transparent shadow border and never reaches pixels, so it is
        /// deliberately not vectored.
        let spriteBounds: CGRect
        let shadowPad: CGFloat
        let paddedBounds: CGRect
        let dropShadowRadius: CGFloat
        let dropShadowOpacity: CGFloat
        let dropShadowOffset: CGVector
        let manualAlpha: CGFloat
        let manualSigma: CGFloat
        let manualOffset: CGVector
    }

    /// `renderCursorCI` with its CIImage operations applied to a stand-in
    /// sprite of the raster's pixel extent, recording every number it
    /// computes (sprite bounds via CGRect.applying). Returns nil exactly where
    /// the exporter returns `image` untouched.
    static func renderCursorCI(
        at currentTime: TimeInterval,
        cursorPosition: CGPoint,
        cursorEvents: [CursorEvent],
        cursorAsset: CursorAsset,
        rasterPixelSize: CGSize,
        cursorCoordinateSize: CGSize,
        layoutVideoRect: CGRect,
        outputSize: CGSize,
        settings: ProjectSettings,
        canvasScale: CGFloat
    ) -> Composite? {
        if shouldHideCursor(at: currentTime, cursorEvents: cursorEvents, settings: settings) {
            return nil
        }
        let resolvedCursorSpace = cursorCoordinateSize
        guard resolvedCursorSpace.width > 0, resolvedCursorSpace.height > 0 else { return nil }

        let videoRectInViewSpace = CursorOverlayLayout.viewRect(
            from: layoutVideoRect,
            canvasHeight: outputSize.height
        )
        guard let cursorLayout = CursorOverlayLayout.make(
            cursorPosition: cursorPosition,
            coordinateSize: resolvedCursorSpace,
            videoRect: videoRectInViewSpace,
            cursorSize: cursorAsset.baseSize,
            hotSpot: cursorAsset.hotSpot,
            cursorScale: settings.cursorScale
        ) else { return nil }

        let drawRect = cursorLayout.imageSpaceRect(in: outputSize.height)

        // Stand-in for `scaledCursorCI` (CIImage(cgImage:) has extent 0,0,w,h).
        let scaledCursorCI = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
            .cropped(to: CGRect(origin: .zero, size: rasterPixelSize))
        let scaleX = drawRect.width  / max(1, scaledCursorCI.extent.width)
        let scaleY = drawRect.height / max(1, scaledCursorCI.extent.height)
        var positioned = scaledCursorCI
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .transformed(by: CGAffineTransform(translationX: drawRect.minX, y: drawRect.minY))
        let placeTransform = CGAffineTransform(scaleX: scaleX, y: scaleY)
            .concatenating(CGAffineTransform(translationX: drawRect.minX, y: drawRect.minY))

        let rawPose = CursorPhysicsMath.pose(
            events: cursorEvents,
            at: currentTime,
            coordinateSize: resolvedCursorSpace,
            videoRect: videoRectInViewSpace,
            spriteHeight: cursorLayout.imageRect.height,
            tilt: settings.cursorTilt,
            stretch: settings.cursorStretch,
            drag: settings.cursorDrag,
            weight: settings.cursorWeight
        )
        let pose = rawPose.yFlipped()
        let tipCI = CGPoint(
            x: cursorLayout.hotspotPoint.x,
            y: outputSize.height - cursorLayout.hotspotPoint.y
        )
        var physics = CGAffineTransform.identity
        var sprite = placeTransform
        if !pose.isIdentity {
            physics = CursorPhysicsMath.affineTransform(
                pose: pose,
                tip: tipCI,
                spriteHeight: drawRect.height
            )
            positioned = positioned.transformed(by: physics)
            sprite = placeTransform.concatenating(physics)
        }
        let ph = rasterPixelSize.height
        let spriteYDown = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: ph)
            .concatenating(sprite)
            .concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: outputSize.height))

        let shadowPad = (CursorOverlayLayout.shadowBlurRadius
            + max(abs(CursorOverlayLayout.shadowOffset.width),
                  abs(CursorOverlayLayout.shadowOffset.height))) * canvasScale + 2
        _ = positioned  // CI extent: integral + snapped, see `spriteBounds`
        let spriteBounds = CGRect(origin: .zero, size: rasterPixelSize).applying(sprite)
        let paddedBounds = spriteBounds.insetBy(dx: -shadowPad, dy: -shadowPad)

        return Composite(
            videoRectInViewSpace: videoRectInViewSpace,
            layout: cursorLayout,
            drawRect: drawRect,
            scaleX: scaleX,
            scaleY: scaleY,
            placeTransform: placeTransform,
            pose: rawPose,
            ciPose: pose,
            poseIsIdentity: pose.isIdentity,
            tipCI: tipCI,
            physicsTransform: physics,
            spriteTransform: sprite,
            spriteTransformYDown: spriteYDown,
            spriteBounds: spriteBounds,
            shadowPad: shadowPad,
            paddedBounds: paddedBounds,
            // CIDropShadow parameters (L3451–3459)
            dropShadowRadius: CursorOverlayLayout.shadowBlurRadius * canvasScale,
            dropShadowOpacity: CursorOverlayLayout.shadowOpacity,
            dropShadowOffset: CGVector(
                dx: CursorOverlayLayout.shadowOffset.width * canvasScale,
                dy: -CursorOverlayLayout.shadowOffset.height * canvasScale
            ),
            // manualDropShadow parameters (L3473–3488)
            manualAlpha: CursorOverlayLayout.shadowOpacity,
            manualSigma: CursorOverlayLayout.shadowBlurRadius * canvasScale * 0.5,
            manualOffset: CGVector(
                dx: CursorOverlayLayout.shadowOffset.width * canvasScale,
                dy: -CursorOverlayLayout.shadowOffset.height * canvasScale
            )
        )
    }

    // MARK: renderCursor (L3492–3555) + drawFallbackCursor (L3593–3613) — numbers

    struct CGFallback {
        let drawRect: CGRect
        let shadowOffset: CGSize
        let shadowBlur: CGFloat
        let shadowAlpha: CGFloat
        let fallbackPath: [CGPoint]?
        let fallbackLineWidth: CGFloat?
    }

    static func renderCursor(
        at currentTime: TimeInterval,
        cursorPosition: CGPoint,
        cursorEvents: [CursorEvent],
        cursorAsset: CursorAsset,
        cursorCoordinateSize: CGSize,
        layoutVideoRect: CGRect,
        outputSize: CGSize,
        settings: ProjectSettings,
        canvasScale: CGFloat
    ) -> CGFallback? {
        if shouldHideCursor(at: currentTime, cursorEvents: cursorEvents, settings: settings) {
            return nil
        }
        let resolvedCursorSpace = cursorCoordinateSize
        guard resolvedCursorSpace.width > 0, resolvedCursorSpace.height > 0 else { return nil }

        let videoRectInViewSpace = CursorOverlayLayout.viewRect(
            from: layoutVideoRect,
            canvasHeight: outputSize.height
        )
        guard let cursorLayout = CursorOverlayLayout.make(
            cursorPosition: cursorPosition,
            coordinateSize: resolvedCursorSpace,
            videoRect: videoRectInViewSpace,
            cursorSize: cursorAsset.baseSize,
            hotSpot: cursorAsset.hotSpot,
            cursorScale: settings.cursorScale
        ) else {
            return nil
        }
        let drawRect = cursorLayout.imageSpaceRect(in: outputSize.height)

        let shadowOffset = CGSize(
            width: CursorOverlayLayout.shadowOffset.width * canvasScale,
            height: -CursorOverlayLayout.shadowOffset.height * canvasScale
        )
        let shadowBlur = CursorOverlayLayout.shadowBlurRadius * canvasScale
        var path: [CGPoint]?
        var lineWidth: CGFloat?
        if cursorAsset.cgImage == nil {
            let rect = drawRect
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: rect.minX + x * rect.width, y: rect.maxY - y * rect.height)
            }
            path = [
                point(0.00, 0.00),
                point(0.00, 1.00),
                point(0.35, 0.72),
                point(0.55, 1.00),
                point(0.72, 0.92),
                point(0.52, 0.65),
                point(1.00, 0.62),
            ]
            lineWidth = max(1, rect.width * 0.08)
        }
        return CGFallback(
            drawRect: drawRect,
            shadowOffset: shadowOffset,
            shadowBlur: shadowBlur,
            shadowAlpha: CursorOverlayLayout.shadowOpacity,
            fallbackPath: path,
            fallbackLineWidth: lineWidth)
    }

    // MARK: renderClickRipple (L3290–3350) — skip predicate

    static func renderClickRippleDraws(
        at currentTime: TimeInterval,
        cursorEvents: [CursorEvent],
        cursorCoordinateSize: CGSize,
        layoutVideoRect: CGRect
    ) -> (hasRipple: Bool, dragStrength: Double, draws: Bool) {
        let hasRipple = !ClickRippleOverlay.activeRipples(
            cursorEvents: cursorEvents,
            currentTime: currentTime,
            coordinateSize: cursorCoordinateSize,
            videoRect: layoutVideoRect
        ).isEmpty
        let dragStrength = ClickRippleOverlay.dragHighlightStrength(
            runs: ClickRippleOverlay.dragHighlightRuns(
                from: cursorEvents, coordinateSize: cursorCoordinateSize),
            at: currentTime
        )
        return (hasRipple, dragStrength, hasRipple || dragStrength > 0.01)
    }

    // MARK: ClickRippleOverlay.clickDragThreshold (L176–180, private) — verbatim

    static func clickDragThreshold(for coordinateSize: CGSize) -> CGFloat {
        let shortSide = min(coordinateSize.width, coordinateSize.height)
        guard shortSide > 0 else { return 12 }
        return max(10, min(24, shortSide * 0.006))
    }

    // MARK: ClickRippleOverlay.renderForExport (L183–253) — recorded numbers

    struct RippleOp {
        let fill: Bool
        let rect: CGRect
        let lineWidth: CGFloat?
        let alpha: CGFloat
    }

    /// The exact numbers renderForExport passes to CoreGraphics, in order.
    static func renderForExportOps(
        cursorEvents: [CursorEvent],
        currentTime: Double,
        videoRect: CGRect,
        sourceSize: CGSize,
        rippleSize: Double,
        rippleDuration: Double = 0.45
    ) -> (ops: [RippleOp], dragStrength: Double) {
        var ops: [RippleOp] = []
        guard videoRect.width > 0, videoRect.height > 0,
              sourceSize.width > 0, sourceSize.height > 0 else { return (ops, 0) }

        let clicks = ClickRippleOverlay.discreteClicks(from: cursorEvents, coordinateSize: sourceSize)
        for event in clicks {
            let elapsed = currentTime - event.timestamp
            guard elapsed >= 0, elapsed <= rippleDuration else { continue }

            let progress = elapsed / rippleDuration

            let screenX = event.x / sourceSize.width
            let screenY = event.y / sourceSize.height

            // In CG coordinates, Y is flipped
            let cx = videoRect.minX + screenX * videoRect.width
            let cy = videoRect.maxY - screenY * videoRect.height

            let outerScale = CGFloat(0.2 + progress * 0.8)
            let outerOpacity = CGFloat(1.0 - progress)
            let radius = CGFloat(rippleSize) * outerScale / 2

            // Outer ring
            ops.append(RippleOp(
                fill: false,
                rect: CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2),
                lineWidth: 2.5, alpha: outerOpacity * 0.7))

            // Inner ring
            let innerProgress = max(0, progress - 0.1) / 0.9
            let innerScale = CGFloat(0.15 + innerProgress * 0.5)
            let innerOpacity = CGFloat(max(0, 1.0 - innerProgress * 1.5))
            let innerRadius = CGFloat(rippleSize) * 0.6 * innerScale / 2

            ops.append(RippleOp(
                fill: false,
                rect: CGRect(x: cx - innerRadius, y: cy - innerRadius, width: innerRadius * 2, height: innerRadius * 2),
                lineWidth: 1.5, alpha: innerOpacity * 0.5))

            // Center dot
            let dotOpacity = CGFloat(max(0, 1.0 - progress * 3))
            let dotRadius: CGFloat = 3
            ops.append(RippleOp(
                fill: true,
                rect: CGRect(x: cx - dotRadius, y: cy - dotRadius, width: dotRadius * 2, height: dotRadius * 2),
                lineWidth: nil, alpha: dotOpacity * 0.6))
        }

        let runs = ClickRippleOverlay.dragHighlightRuns(from: cursorEvents, coordinateSize: sourceSize)
        let strength = ClickRippleOverlay.dragHighlightStrength(runs: runs, at: currentTime)
        if strength > 0.01 {
            let pos = CursorSmoother().interpolate(events: cursorEvents, at: currentTime)
            let cx = videoRect.minX + (pos.x / sourceSize.width) * videoRect.width
            let cy = videoRect.maxY - (pos.y / sourceSize.height) * videoRect.height
            let ringD = CGFloat(rippleSize) * 0.33
            let rect = CGRect(x: cx - ringD / 2, y: cy - ringD / 2, width: ringD, height: ringD)
            ops.append(RippleOp(fill: false, rect: rect, lineWidth: 2, alpha: 0.55 * strength))
            ops.append(RippleOp(fill: true, rect: rect, lineWidth: nil, alpha: 0.15 * strength))
        }
        return (ops, strength)
    }

    /// Re-draws recorded ops with renderForExport's exact CG calls.
    static func draw(_ ops: [RippleOp], into context: CGContext, rippleColor: CGColor) {
        for op in ops {
            if op.fill {
                context.setFillColor(rippleColor.copy(alpha: op.alpha)!)
                context.fillEllipse(in: op.rect)
            } else {
                context.setStrokeColor(rippleColor.copy(alpha: op.alpha)!)
                context.setLineWidth(op.lineWidth!)
                context.strokeEllipse(in: op.rect)
            }
        }
    }

    static func rippleContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
    }

    /// True when the recorded ops re-draw to the same bytes as the REAL
    /// ClickRippleOverlay.renderForExport.
    static func rippleOpsMatchReal(
        cursorEvents: [CursorEvent],
        currentTime: Double,
        videoRect: CGRect,
        sourceSize: CGSize,
        rippleColor: CGColor,
        rippleSize: Double,
        outputSize: CGSize,
        ops: [RippleOp]
    ) -> Bool {
        let w = Int(outputSize.width), h = Int(outputSize.height)
        guard let real = rippleContext(width: w, height: h),
              let mine = rippleContext(width: w, height: h) else { return false }
        ClickRippleOverlay.renderForExport(
            into: real,
            cursorEvents: cursorEvents,
            currentTime: currentTime,
            videoRect: videoRect,
            sourceSize: sourceSize,
            rippleColor: rippleColor,
            rippleSize: rippleSize
        )
        draw(ops, into: mine, rippleColor: rippleColor)
        guard let a = real.data, let b = mine.data else { return false }
        return memcmp(a, b, real.bytesPerRow * h) == 0
    }

    // MARK: CursorStyleProvider drawnArrow / drawnDot (L121–176) — geometry as data

    struct RGBA {
        let r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat
        /// The NSColor the provider uses for this value (black/white ± alpha).
        var nsColor: NSColor {
            let base: NSColor = r == 0 ? .black : .white
            return a == 1 ? base : base.withAlphaComponent(a)
        }
    }

    enum ArtOp {
        case strokePath(points: [CGPoint], lineWidth: CGFloat, color: RGBA)
        case fillPath(points: [CGPoint], color: RGBA)
        case strokeOval(rect: CGRect, lineWidth: CGFloat, color: RGBA)
        case fillOval(rect: CGRect, color: RGBA)
    }

    struct Artwork {
        let flipped: Bool
        let size: CGSize
        let ops: [ArtOp]
    }

    static let arrowPoints: [CGPoint] = [
        CGPoint(x: 2, y: 2),
        CGPoint(x: 2, y: 23.6),
        CGPoint(x: 7.0, y: 19.0),
        CGPoint(x: 10.6, y: 26.4),
        CGPoint(x: 14.2, y: 24.7),
        CGPoint(x: 10.6, y: 17.5),
        CGPoint(x: 17.2, y: 17.5),
    ]

    static let black = RGBA(r: 0, g: 0, b: 0, a: 1)
    static let white = RGBA(r: 1, g: 1, b: 1, a: 1)

    static func artwork(for style: ProjectSettings.CursorStyle) -> Artwork? {
        switch style {
        case .system:
            // drawnArrow(fill: .black, outline: .white, outerOutline: .black)
            return Artwork(flipped: true, size: CGSize(width: 20, height: 28), ops: [
                .strokePath(points: arrowPoints, lineWidth: 4, color: black),
                .strokePath(points: arrowPoints, lineWidth: 2.4, color: white),
                .fillPath(points: arrowPoints, color: black),
            ])
        case .inverted:
            // drawnArrow(fill: .white, outline: .black)
            return Artwork(flipped: true, size: CGSize(width: 20, height: 28), ops: [
                .strokePath(points: arrowPoints, lineWidth: 2.4, color: black),
                .fillPath(points: arrowPoints, color: white),
            ])
        case .dot:
            return Artwork(flipped: false, size: CGSize(width: 24, height: 24), ops: [
                .strokeOval(rect: NSRect(x: 1.5, y: 1.5, width: 21, height: 21), lineWidth: 1.5,
                            color: RGBA(r: 0, g: 0, b: 0, a: 0.55)),
                .fillOval(rect: NSRect(x: 2.5, y: 2.5, width: 19, height: 19), color: white),
                .fillOval(rect: NSRect(x: 8.5, y: 8.5, width: 7, height: 7),
                          color: RGBA(r: 0, g: 0, b: 0, a: 0.25)),
            ])
        case .ring:
            return Artwork(flipped: false, size: CGSize(width: 24, height: 24), ops: [
                .strokeOval(rect: NSRect(x: 3, y: 3, width: 18, height: 18), lineWidth: 5,
                            color: RGBA(r: 0, g: 0, b: 0, a: 0.55)),
                .strokeOval(rect: NSRect(x: 3, y: 3, width: 18, height: 18), lineWidth: 3, color: white),
            ])
        case .hand:
            return nil
        }
    }

    /// Draws `artwork` with the provider's exact AppKit calls. The arrow path
    /// is rebuilt per op exactly like drawnArrow's single NSBezierPath (same
    /// move/line/close sequence, round joins).
    static func image(for artwork: Artwork) -> NSImage {
        NSImage(size: artwork.size, flipped: artwork.flipped) { _ in
            var arrowPath: NSBezierPath?
            func arrow(_ points: [CGPoint]) -> NSBezierPath {
                if let arrowPath { return arrowPath }
                let path = NSBezierPath()
                path.move(to: points[0])
                for p in points.dropFirst() { path.line(to: p) }
                path.close()
                path.lineJoinStyle = .round
                arrowPath = path
                return path
            }
            for op in artwork.ops {
                switch op {
                case let .strokePath(points, lineWidth, color):
                    let path = arrow(points)
                    color.nsColor.setStroke()
                    path.lineWidth = lineWidth
                    path.stroke()
                case let .fillPath(points, color):
                    let path = arrow(points)
                    color.nsColor.setFill()
                    path.fill()
                case let .strokeOval(rect, lineWidth, color):
                    let oval = NSBezierPath(ovalIn: rect)
                    color.nsColor.setStroke()
                    oval.lineWidth = lineWidth
                    oval.stroke()
                case let .fillOval(rect, color):
                    color.nsColor.setFill()
                    NSBezierPath(ovalIn: rect).fill()
                }
            }
            return true
        }
    }

    /// `rasterizedCGImage(for:pixelSize:)`'s body (L54–108) for any NSImage.
    static func rasterize(_ image: NSImage, pixelSize: CGSize) -> CGImage? {
        let pixelWidth = max(1, Int(ceil(pixelSize.width)))
        let pixelHeight = max(1, Int(ceil(pixelSize.height)))
        guard image.size.width > 0,
              image.size.height > 0,
              let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixelWidth,
                pixelsHigh: pixelHeight,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bitmapFormat: [],
                bytesPerRow: 0,
                bitsPerPixel: 0
              ),
              let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap)
        else { return nil }
        bitmap.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        graphicsContext.imageInterpolation = .high
        graphicsContext.cgContext.setShouldAntialias(true)
        graphicsContext.cgContext.setAllowsAntialiasing(true)
        graphicsContext.cgContext.scaleBy(
            x: CGFloat(pixelWidth) / image.size.width,
            y: CGFloat(pixelHeight) / image.size.height
        )
        image.draw(
            in: CGRect(origin: .zero, size: image.size),
            from: CGRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        graphicsContext.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.cgImage
    }

    /// Raw pixel bytes of a CGImage (for byte-equality self-checks).
    static func bytes(_ image: CGImage) -> Data? {
        guard let data = image.dataProvider?.data else { return nil }
        return data as Data
    }
}
