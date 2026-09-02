import AppKit
import CoreGraphics
import CoreText

/// Every annotation type, drawn in pure CoreGraphics.
///
/// This is the ONE implementation — the preview compositor rasterizes it for
/// `annotationLayer.contents` and `VideoExporter` calls it per frame — so
/// preview and export cannot disagree. It replaces the old `AnnotationOverlay`
/// (SwiftUI, rasterized through `ImageRenderer`) shape-for-shape.
///
/// # Coordinate space
///
/// Y-DOWN, like the preview canvas: `videoRect.minY` is the top of the video.
/// A y-up caller flips the context first (see `VideoExporter`).
///
/// # The `scale` parameter
///
/// Annotation sizes (`fontSize`, `lineWidth`, `cornerRadius`, paddings) are
/// authored in PREVIEW CANVAS POINTS. `scale` converts them to the target's
/// units: 1 for the preview, `outputWidth / 1920 * 2` for the exporter — the
/// long-standing export convention, kept so existing projects render at the
/// size their authors chose.
///
/// # Divergences this port closes
///
/// The SwiftUI overlay and the exporter's old CG twin had drifted. Where they
/// disagreed, the shared renderer takes the behaviour the UI actually offers:
///
/// * `fontName` is honoured (SwiftUI drew the system face regardless, so a
///   chosen typeface appeared only in the export).
/// * `uppercase` is honoured, via `displayText` (same story).
/// * Pills, callout boxes and rounded rectangles use CONTINUOUS corners; the
///   exporter drew circular ones.
/// * Shape and callout borders are `strokeBorder` (inset), not centred strokes.
/// * Text/callout padding is SwiftUI's fixed 10/6 and 12/8 points, scaled; the
///   exporter approximated it as a fraction of the font size.
enum AnnotationRenderer {
    /// Editor-only decoration — handles, selection rings. Never exported.
    struct Chrome {
        var isPlaying: Bool
        var selectedID: UUID?

        func isSelected(_ a: Annotation) -> Bool { selectedID == a.id }
        var showsHandles: Bool { !isPlaying }

        /// Editing affordance: while PAUSED every annotation renders at its
        /// settled phase instead of the build-effect frame. Build animations
        /// are playback/export behaviour; a parked editor showing a half-built
        /// (small, faint) annotation reads as broken — most visibly when
        /// DESELECTING one whose span the playhead just jumped into.
        /// Chrome never reaches the exporter, so export timing cannot fork.
        func rendersSettled(_ a: Annotation) -> Bool { !isPlaying }

        /// The annotation whose label is open in the in-place editor. It is
        /// NOT drawn — the editor field replaces it pixel-on-pixel (Keynote
        /// behaviour), instead of stacking a second translucent copy on top.
        var editingID: UUID? = nil
    }

    /// The exact pill/box rect drawText/drawCallout give `a`'s label — shared
    /// so the in-place editor sits pixel-on-pixel over the drawn label rather
    /// than approximating it (the old grey-slab-nowhere-near-the-text bug).
    static func labelRect(_ a: Annotation, videoRect: CGRect, scale: CGFloat) -> CGRect? {
        guard a.type == .text || a.type == .callout else { return nil }
        let center = point(a.x, a.y, in: videoRect)
        let line = TextLine(a, scale: scale)
        let hPad = (a.type == .text ? 10 : 12) * scale
        let vPad = (a.type == .text ? 6 : 8) * scale
        return CGRect(
            x: center.x - line.size.width / 2 - hPad,
            y: center.y - line.size.height / 2 - vPad,
            width: line.size.width + hPad * 2,
            height: line.size.height + vPad * 2
        )
    }

    // MARK: - Selection chrome (editor-only, Keynote-style)

    /// macOS selection blue — fixed sRGB (0,122,255); the CG renderer has no
    /// dynamic NSColor plumbing and chrome never ships in an export.
    private static let accent = SRGBA(red: 0, green: 0.478, blue: 1, alpha: 1)

    private static func selectionRing(_ ctx: CGContext, path: CGPath, scale: CGFloat) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setStrokeColor(accent.cgColor)
        ctx.setLineWidth(1.5 * scale)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: - Entry points

    static func image(
        size: CGSize,
        annotations: [Annotation],
        currentTime: TimeInterval,
        videoRect: CGRect,
        scale: CGFloat,
        chrome: Chrome?,
        rasterScale: CGFloat,
        videoCornerRadius: CGFloat = 0
    ) -> CGImage? {
        let w = Int((size.width * rasterScale).rounded())
        let h = Int((size.height * rasterScale).rounded())
        guard w > 0, h > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return nil }
        ctx.scaleBy(x: rasterScale, y: rasterScale)
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        draw(in: ctx, annotations: annotations, currentTime: currentTime,
             videoRect: videoRect, scale: scale, chrome: chrome,
             videoCornerRadius: videoCornerRadius)
        return ctx.makeImage()
    }

    /// Draws every annotation live at `currentTime` into an ALREADY y-down
    /// context.
    static func draw(
        in ctx: CGContext,
        annotations: [Annotation],
        currentTime: TimeInterval,
        videoRect: CGRect,
        scale: CGFloat,
        chrome: Chrome?,
        videoCornerRadius: CGFloat = 0
    ) {
        // Backdrops first, in one pass, so every annotation (not just its own)
        // renders ABOVE the blackout — two annotations on screen must both
        // stay readable when one of them dims the frame.
        for annotation in annotations {
            guard currentTime >= annotation.startTime, currentTime <= annotation.endTime else { continue }
            drawBackdrop(annotation, in: ctx, currentTime: currentTime,
                         videoRect: videoRect, scale: scale, chrome: chrome,
                         videoCornerRadius: videoCornerRadius)
        }
        for annotation in annotations {
            guard currentTime >= annotation.startTime, currentTime <= annotation.endTime else { continue }
            draw(annotation, in: ctx, currentTime: currentTime,
                 videoRect: videoRect, scale: scale, chrome: chrome)
        }
    }

    // MARK: - Backdrop blackout

    /// The full-frame blackout level at `time` — the strongest active
    /// annotation backdrop, scaled by its build-effect phase.
    ///
    /// Consumed by BOTH renderers for the canvas-level dim that sits between
    /// the background and the card (the card-space cutout dim above the video
    /// is drawn separately, in `drawBackdrop`). Together they dim every pixel
    /// of the frame except the annotation's shape.
    /// `settled` is true in the PAUSED editor (see Chrome.rendersSettled):
    /// dims show at full build phase. The exporter never passes it.
    static func backdropAlpha(
        annotations: [Annotation],
        at time: TimeInterval,
        settled: Bool = false
    ) -> CGFloat {
        var strongest: CGFloat = 0
        for a in annotations where time >= a.startTime && time <= a.endTime {
            let dim = max(0, min(0.95, a.backdropOpacity))
            guard dim > 0.001 else { continue }
            let phase = settled ? 1 : max(0, min(1, a.effectPhase(at: time).alpha))
            strongest = max(strongest, CGFloat(dim * phase))
        }
        return strongest
    }

    /// Lightbox dim: black over the SCREEN RECORDING (`videoRect` only, so it
    /// rides the card through tilt/zoom and never spills onto the canvas
    /// background), with the shape region cut out for rectangle/ellipse.
    /// `videoCornerRadius` matches the card's clip so the dim's corners hug
    /// the video's rounded corners. Fades with the annotation's build effects.
    private static func drawBackdrop(
        _ a: Annotation,
        in ctx: CGContext,
        currentTime: TimeInterval,
        videoRect: CGRect,
        scale: CGFloat,
        chrome: Chrome?,
        videoCornerRadius: CGFloat
    ) {
        let dim = max(0, min(0.95, a.backdropOpacity))
        guard dim > 0.001 else { return }
        let phase = (chrome?.rendersSettled(a) ?? false)
            ? AnnotationEffectMath.Phase()
            : a.effectPhase(at: currentTime)
        let alpha = CGFloat(dim * max(0, min(1, phase.alpha)))
        guard alpha > 0.001 else { return }

        ctx.saveGState()
        let cardRadius = min(
            max(0, videoCornerRadius),
            min(videoRect.width, videoRect.height) / 2
        )
        let path = CGMutablePath()
        path.addPath(ContinuousRoundedRect.path(rect: videoRect, cornerRadius: cardRadius))

        switch a.type {
        case .rectangle, .ellipse:
            // Identical rect math to drawShape — the hole must sit exactly
            // under the drawn shape.
            let p1 = point(min(a.x, a.arrowEndX), min(a.y, a.arrowEndY), in: videoRect)
            let p2 = point(max(a.x, a.arrowEndX), max(a.y, a.arrowEndY), in: videoRect)
            let rect = CGRect(x: p1.x, y: p1.y, width: p2.x - p1.x, height: p2.y - p1.y)
            if a.type == .ellipse {
                path.addPath(CGPath(ellipseIn: rect, transform: nil))
            } else {
                path.addPath(ContinuousRoundedRect.path(
                    rect: rect, cornerRadius: max(0, a.cornerRadius) * scale))
            }
        default:
            break // No cutout — plain dim behind the annotation.
        }

        ctx.setFillColor(CGColor(gray: 0, alpha: alpha))
        ctx.addPath(path)
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
    }

    // MARK: - One annotation

    private static func draw(
        _ a: Annotation,
        in ctx: CGContext,
        currentTime: TimeInterval,
        videoRect: CGRect,
        scale: CGFloat,
        chrome: Chrome?
    ) {
        // While its label is open in the in-place editor the annotation is
        // NOT drawn — the field replaces it exactly (Keynote), rather than
        // stacking a translucent twin underneath.
        if chrome?.editingID == a.id { return }

        // The wrapper from AnnotationView: build-effect scale about the
        // annotation's anchor, an unscaled vertical offset, whole-annotation
        // opacity, and an optional group shadow.
        let phase = (chrome?.rendersSettled(a) ?? false)
            ? AnnotationEffectMath.Phase()
            : a.effectPhase(at: currentTime)
        let alpha = CGFloat(max(0, min(1, a.opacity)) * phase.alpha)
        guard alpha > 0.001 else { return }

        ctx.saveGState()
        let anchor = a.effectAnchor
        let ax = videoRect.minX + anchor.x * videoRect.width
        let ay = videoRect.minY + anchor.y * videoRect.height
        // `.scaleEffect(anchor:)` then `.offset(y:)` — the offset is applied
        // OUTSIDE the scale, so it never gets multiplied by it.
        ctx.translateBy(x: ax, y: ay + CGFloat(phase.offsetY) * scale)
        ctx.scaleBy(x: CGFloat(phase.scale), y: CGFloat(phase.scale))
        ctx.translateBy(x: -ax, y: -ay)
        ctx.setAlpha(alpha)
        if a.showShadow {
            SwiftUIShadow.apply(to: ctx, radius: 4 * scale, dy: 1 * scale,
                                color: SRGBA(white: 0, alpha: 0.35))
        }
        // compositingGroup(): the shadow is cast off the finished annotation,
        // not off each shape inside it.
        let unscaled = abs(phase.scale - 1) < 1e-9
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        switch a.type {
        case .text: drawText(a, in: ctx, videoRect: videoRect, scale: scale, chrome: chrome, unscaled: unscaled)
        case .arrow: drawArrow(a, in: ctx, videoRect: videoRect, scale: scale, chrome: chrome)
        case .callout: drawCallout(a, in: ctx, videoRect: videoRect, scale: scale, chrome: chrome, unscaled: unscaled)
        case .drawing: drawDrawing(a, in: ctx, videoRect: videoRect, scale: scale,
                                   progress: phase.strokeProgress)
        case .rectangle, .ellipse: drawShape(a, in: ctx, videoRect: videoRect, scale: scale, chrome: chrome)
        case .tap: drawTap(a, in: ctx, videoRect: videoRect, scale: scale,
                           currentTime: currentTime, chrome: chrome)
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    // MARK: - Text

    private static func drawText(
        _ a: Annotation, in ctx: CGContext, videoRect: CGRect,
        scale: CGFloat, chrome: Chrome?, unscaled: Bool
    ) {
        let center = point(a.x, a.y, in: videoRect)
        let line = TextLine(a, scale: scale)
        // Geometry shared with the in-place editor — see labelRect.
        let pill = labelRect(a, videoRect: videoRect, scale: scale)
            ?? CGRect(origin: center, size: .zero)
        let radius = max(0, a.cornerRadius) * scale

        if a.showBackground {
            ctx.addPath(ContinuousRoundedRect.path(rect: pill, cornerRadius: radius))
            ctx.setFillColor(SRGBA(a.backgroundColor).cgColor)
            ctx.fillPath()
        }
        line.draw(in: ctx, center: center, color: SRGBA(a.color), snapToPixels: unscaled)

        if let chrome, chrome.showsHandles, chrome.isSelected(a) {
            // Accent ring floated just off the pill, Keynote-style.
            let outset = 3 * scale
            selectionRing(ctx, path: ContinuousRoundedRect.path(
                rect: pill.insetBy(dx: -outset, dy: -outset),
                cornerRadius: radius + outset), scale: scale)
        }
    }

    // MARK: - Arrow

    private static func drawArrow(
        _ a: Annotation, in ctx: CGContext, videoRect: CGRect,
        scale: CGFloat, chrome: Chrome?
    ) {
        let tail = point(a.x, a.y, in: videoRect)
        let head = point(a.arrowEndX, a.arrowEndY, in: videoRect)
        let color = SRGBA(a.color).cgColor
        let lineWidth = a.lineWidth * scale

        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.move(to: tail)
        ctx.addLine(to: head)
        ctx.strokePath()

        let angle = atan2(head.y - tail.y, head.x - tail.x)
        let headSize = lineWidth * 5
        ctx.move(to: head)
        ctx.addLine(to: CGPoint(x: head.x - headSize * cos(angle - .pi / 6),
                                y: head.y - headSize * sin(angle - .pi / 6)))
        ctx.addLine(to: CGPoint(x: head.x - headSize * cos(angle + .pi / 6),
                                y: head.y - headSize * sin(angle + .pi / 6)))
        ctx.closePath()
        ctx.fillPath()

        if let chrome, chrome.showsHandles {
            let alpha: CGFloat = chrome.isSelected(a) ? 1 : 0.55
            handle(ctx, at: tail, diameter: 10 * scale, alpha: alpha)
            handle(ctx, at: head, diameter: 10 * scale, alpha: alpha)
        }
    }

    // MARK: - Callout

    private static func drawCallout(
        _ a: Annotation, in ctx: CGContext, videoRect: CGRect,
        scale: CGFloat, chrome: Chrome?, unscaled: Bool
    ) {
        let center = point(a.x, a.y, in: videoRect)
        let tip = point(a.arrowEndX, a.arrowEndY, in: videoRect)
        let color = SRGBA(a.color)
        let line = TextLine(a, scale: scale)
        // Geometry shared with the in-place editor — see labelRect.
        let box = labelRect(a, videoRect: videoRect, scale: scale)
            ?? CGRect(origin: center, size: .zero)
        let radius = max(0, a.cornerRadius) * scale
        let stroke = 1.5 * scale

        // Leader line, stopping at the box edge — drawn UNDER the box.
        let end = boxEdgeIntersection(from: tip, toward: center, box: box) ?? center
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(stroke)
        ctx.setLineCap(.butt)
        ctx.move(to: tip)
        ctx.addLine(to: end)
        ctx.strokePath()

        // Dot at the tail tip.
        let dot = 7 * scale
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: CGRect(x: tip.x - dot / 2, y: tip.y - dot / 2, width: dot, height: dot))

        // Box: fill, border, text.
        ctx.addPath(ContinuousRoundedRect.path(rect: box, cornerRadius: radius))
        ctx.setFillColor(SRGBA(a.backgroundColor).cgColor)
        ctx.fillPath()
        ctx.addPath(ContinuousRoundedRect.path(
            rect: box.insetBy(dx: stroke / 2, dy: stroke / 2),
            cornerRadius: max(0, radius - stroke / 2)))
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(stroke)
        ctx.strokePath()
        line.draw(in: ctx, center: center, color: color, snapToPixels: unscaled)

        if let chrome, chrome.showsHandles, chrome.isSelected(a) {
            let outset = 3 * scale
            selectionRing(ctx, path: ContinuousRoundedRect.path(
                rect: box.insetBy(dx: -outset, dy: -outset),
                cornerRadius: radius + outset), scale: scale)
        }
        if let chrome, chrome.showsHandles {
            handle(ctx, at: tip, diameter: 10 * scale,
                   alpha: chrome.isSelected(a) ? 1 : 0.55)
        }
    }

    // MARK: - Drawing

    /// Draw On trims the strokes: `progress` 0→1 reveals points in DRAWING
    /// ORDER across all strokes (with the last segment interpolated so the
    /// pen tip moves smoothly). 1 = the whole drawing; every effect except
    /// .drawOn passes 1. Shared math — preview and export cannot drift.
    static func trimmedStrokes(
        _ strokes: [[CodablePoint]], progress: Double
    ) -> [[CodablePoint]] {
        let p = min(1, max(0, progress))
        if p >= 1 { return strokes }
        let total = strokes.reduce(0) { $0 + max(1, $1.count) }
        guard total > 0 else { return [] }
        // Fractional "pen position" measured in points drawn.
        var remaining = p * Double(total)
        var out: [[CodablePoint]] = []
        for stroke in strokes {
            let cost = Double(max(1, stroke.count))
            if remaining <= 0 { break }
            if remaining >= cost {
                out.append(stroke)
                remaining -= cost
                continue
            }
            // Partial stroke: whole points, plus an interpolated pen tip.
            let exact = remaining
            let whole = Int(exact)
            var partial = Array(stroke.prefix(max(1, whole)))
            let fraction = exact - Double(whole)
            if whole >= 1, whole < stroke.count, fraction > 0 {
                let a = stroke[whole - 1], b = stroke[whole]
                partial.append(CodablePoint(
                    x: a.x + (b.x - a.x) * fraction,
                    y: a.y + (b.y - a.y) * fraction
                ))
            }
            out.append(partial)
            break
        }
        return out
    }

    private static func drawDrawing(
        _ a: Annotation, in ctx: CGContext, videoRect: CGRect, scale: CGFloat,
        progress: Double = 1
    ) {
        guard !a.drawingStrokes.isEmpty else { return }
        let color = SRGBA(a.color).cgColor
        let lineWidth = a.lineWidth * scale
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        for stroke in trimmedStrokes(a.drawingStrokes, progress: progress) where !stroke.isEmpty {
            if stroke.count == 1 {
                // A single-point stroke is an ellipse of radius lineWidth/2
                // that is STROKED at lineWidth — so the painted disc is twice
                // as wide as a naive fill of that ellipse would be.
                let p = point(stroke[0].x, stroke[0].y, in: videoRect)
                let r = lineWidth / 2
                ctx.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
                ctx.strokePath()
            } else {
                ctx.beginPath()
                ctx.move(to: point(stroke[0].x, stroke[0].y, in: videoRect))
                for p in stroke.dropFirst() {
                    ctx.addLine(to: point(p.x, p.y, in: videoRect))
                }
                ctx.strokePath()
            }
        }
    }

    // MARK: - Rectangle / ellipse

    private static func drawShape(
        _ a: Annotation, in ctx: CGContext, videoRect: CGRect,
        scale: CGFloat, chrome: Chrome?
    ) {
        let p1 = point(min(a.x, a.arrowEndX), min(a.y, a.arrowEndY), in: videoRect)
        let p2 = point(max(a.x, a.arrowEndX), max(a.y, a.arrowEndY), in: videoRect)
        let rect = CGRect(x: p1.x, y: p1.y, width: p2.x - p1.x, height: p2.y - p1.y)
        let isEllipse = a.type == .ellipse
        let radius = max(0, a.cornerRadius) * scale
        let lw = a.lineWidth * scale

        func path(_ r: CGRect, _ cornerRadius: CGFloat) -> CGPath {
            isEllipse
                ? CGPath(ellipseIn: r, transform: nil)
                : ContinuousRoundedRect.path(rect: r, cornerRadius: cornerRadius)
        }

        if a.showBackground {
            ctx.addPath(path(rect, radius))
            ctx.setFillColor(SRGBA(a.backgroundColor).cgColor)
            ctx.fillPath()
        }
        if lw > 0 {
            // `.strokeBorder` — inside the shape, never spilling out of it.
            ctx.addPath(path(rect.insetBy(dx: lw / 2, dy: lw / 2), max(0, radius - lw / 2)))
            ctx.setStrokeColor(SRGBA(a.color).cgColor)
            ctx.setLineWidth(lw)
            ctx.strokePath()
        }

        guard let chrome, chrome.showsHandles else { return }
        if chrome.isSelected(a) {
            let outset = 3 * scale
            selectionRing(ctx, path: path(
                rect.insetBy(dx: -outset, dy: -outset), radius + outset), scale: scale)
        }
        let alpha: CGFloat = chrome.isSelected(a) ? 1 : 0.55
        for (nx, ny) in [(a.x, a.y), (a.arrowEndX, a.y), (a.x, a.arrowEndY), (a.arrowEndX, a.arrowEndY)] {
            handle(ctx, at: point(nx, ny, in: videoRect), diameter: 10 * scale, alpha: alpha)
        }
    }

    // MARK: - Tap ripple

    private static func drawTap(
        _ a: Annotation, in ctx: CGContext, videoRect: CGRect,
        scale: CGFloat, currentTime: TimeInterval, chrome: Chrome?
    ) {
        let center = point(a.x, a.y, in: videoRect)
        let size = max(20, a.fontSize) * scale
        let base = SRGBA(a.color)
        func tinted(_ multiplier: CGFloat) -> CGColor {
            SRGBA(red: base.red, green: base.green, blue: base.blue,
                  alpha: base.alpha * multiplier).cgColor
        }

        // Persistent touch point.
        let dot = size * 0.22
        ctx.setFillColor(tinted(0.4))
        ctx.fillEllipse(in: CGRect(x: center.x - dot / 2, y: center.y - dot / 2, width: dot, height: dot))

        if let progress = TapRippleMath.progress(elapsed: currentTime - a.startTime) {
            let outerScale = CGFloat(0.2 + progress * 0.8)
            let outerOpacity = CGFloat(1.0 - progress)
            let outerD = size * outerScale

            // `.stroke` (not strokeBorder) — centred on the circle's path.
            ctx.setStrokeColor(tinted(outerOpacity * 0.7))
            ctx.setLineWidth(2 * scale)
            ctx.strokeEllipse(in: CGRect(x: center.x - outerD / 2, y: center.y - outerD / 2,
                                         width: outerD, height: outerD))

            let innerProgress = max(0, progress - 0.1) / 0.9
            let innerScale = CGFloat(0.15 + innerProgress * 0.5)
            let innerOpacity = CGFloat(max(0, 1.0 - innerProgress * 1.5))
            let innerD = size * 0.6 * innerScale
            ctx.setStrokeColor(tinted(innerOpacity * 0.5))
            ctx.setLineWidth(1.5 * scale)
            ctx.strokeEllipse(in: CGRect(x: center.x - innerD / 2, y: center.y - innerD / 2,
                                         width: innerD, height: innerD))

            // Soft radial glow. The ramp fades to alpha 0, so the Oklab mix
            // holds the start hue and only alpha travels — see OklabGradient.
            let glow = CGRect(x: center.x - outerD / 2, y: center.y - outerD / 2,
                              width: outerD, height: outerD)
            if outerD > 0, let gradient = OklabGradient.gradient(
                from: SRGBA(red: base.red, green: base.green, blue: base.blue,
                            alpha: base.alpha * outerOpacity * 0.12),
                to: SRGBA(red: base.red, green: base.green, blue: base.blue, alpha: 0)
            ) {
                ctx.saveGState()
                ctx.addEllipse(in: glow)
                ctx.clip()
                ctx.drawRadialGradient(
                    gradient,
                    startCenter: center, startRadius: 0,
                    endCenter: center, endRadius: outerD / 2,
                    options: []
                )
                ctx.restoreGState()
            }
        }

        if let chrome, chrome.showsHandles {
            let lw = 1 * scale
            let ring = CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
                .insetBy(dx: lw / 2, dy: lw / 2)
            ctx.saveGState()
            ctx.setStrokeColor(SRGBA(white: 1, alpha: chrome.isSelected(a) ? 0.8 : 0.3).cgColor)
            ctx.setLineWidth(lw)
            ctx.setLineDash(phase: 0, lengths: [3 * scale, 3 * scale])
            ctx.strokeEllipse(in: ring)
            ctx.restoreGState()
        }
    }

    // MARK: - Helpers

    private static func point(_ nx: Double, _ ny: Double, in videoRect: CGRect) -> CGPoint {
        CGPoint(x: videoRect.minX + nx * videoRect.width,
                y: videoRect.minY + ny * videoRect.height)
    }

    /// Keynote-style grab handle: small white disc, hairline grey rim, soft
    /// drop shadow. `alpha` dims the handles of unselected annotations.
    private static func handle(_ ctx: CGContext, at p: CGPoint, diameter: CGFloat, alpha: CGFloat = 1) {
        let rect = CGRect(x: p.x - diameter / 2, y: p.y - diameter / 2,
                          width: diameter, height: diameter)
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 3,
                      color: CGColor(gray: 0, alpha: 0.35))
        ctx.setFillColor(SRGBA(white: 1, alpha: 1).cgColor)
        ctx.fillEllipse(in: rect)
        // Rim drawn without the shadow, inside the disc.
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.setStrokeColor(SRGBA(white: 0, alpha: 0.2).cgColor)
        ctx.setLineWidth(1)
        ctx.strokeEllipse(in: rect.insetBy(dx: 0.5, dy: 0.5))
        ctx.restoreGState()
    }

    /// Where the line from `from` toward `toward` first meets `box`'s edge.
    static func boxEdgeIntersection(from: CGPoint, toward: CGPoint, box: CGRect) -> CGPoint? {
        let dx = toward.x - from.x, dy = toward.y - from.y
        guard abs(dx) > 0.001 || abs(dy) > 0.001 else { return toward }
        var best = CGFloat.infinity
        func check(_ t: CGFloat, _ x: CGFloat, _ y: CGFloat) {
            guard t > 0, t < best,
                  x >= box.minX - 0.5, x <= box.maxX + 0.5,
                  y >= box.minY - 0.5, y <= box.maxY + 0.5 else { return }
            best = t
        }
        if abs(dx) > 0.001 {
            let t = (box.minX - from.x) / dx; check(t, box.minX, from.y + t * dy)
            let t2 = (box.maxX - from.x) / dx; check(t2, box.maxX, from.y + t2 * dy)
        }
        if abs(dy) > 0.001 {
            let t = (box.minY - from.y) / dy; check(t, from.x + t * dx, box.minY)
            let t2 = (box.maxY - from.y) / dy; check(t2, from.x + t2 * dx, box.maxY)
        }
        guard best < .infinity else { return toward }
        return CGPoint(x: from.x + best * dx, y: from.y + best * dy)
    }

    /// One line of annotation text, laid out the way SwiftUI's `Text` lays it
    /// out.
    ///
    /// Both numbers here were measured against SwiftUI, not assumed:
    ///
    /// * **Line box** = `NSAttributedString.size()`. Probing SwiftUI's own
    ///   pill gives a height identical to `size().height` at every size
    ///   tested, and a width equal to `size().width` within the measurement
    ///   resolution.
    /// * **Baseline** sits `round(font.ascender)` below the top of that box —
    ///   note the ROUNDING. Measured to 1/8 pt against a glyph that rests flat
    ///   on the baseline, at 8 sizes from 9 to 64 pt, it lands on the rounded
    ///   integer every time. Using the raw ascender puts the text up to 0.5 pt
    ///   off, which is plainly visible against the pill.
    struct TextLine {
        let attributed: NSAttributedString
        let size: CGSize
        let baselineFromTop: CGFloat

        init(_ a: Annotation, scale: CGFloat) {
            let font = FontCatalog.font(
                named: a.fontName,
                size: a.fontSize * scale,
                weight: a.fontWeight.nsWeight
            )
            attributed = NSAttributedString(string: a.displayText, attributes: [.font: font])
            size = attributed.size()
            baselineFromTop = font.ascender.rounded()
        }

        /// Draws centred on `center` in a Y-DOWN context.
        ///
        /// `snapToPixels` rounds the horizontal origin onto the device-pixel
        /// grid, which is what SwiftUI does to its text: with it off, glyph
        /// coverage matches exactly but the run sits up to a quarter-point off
        /// (measured -0.231pt on one label). Callers pass `false` while a
        /// build effect is scaling the annotation, because then the CTM's
        /// scale is not the raster scale and the grid would be the wrong one.
        func draw(in ctx: CGContext, center: CGPoint, color: SRGBA, snapToPixels: Bool = true) {
            guard attributed.length > 0 else { return }
            let colored = NSMutableAttributedString(attributedString: attributed)
            colored.addAttribute(
                .foregroundColor,
                value: NSColor(srgbRed: color.red, green: color.green,
                               blue: color.blue, alpha: color.alpha),
                range: NSRange(location: 0, length: colored.length)
            )
            let line = CTLineCreateWithAttributedString(colored)
            ctx.saveGState()
            // CoreText draws baseline-up; the context is y-down, so flip about
            // the baseline and let CT lay the glyphs out normally.
            let baselineY = center.y - size.height / 2 + baselineFromTop
            var originX = center.x - size.width / 2
            if snapToPixels {
                let ctm = ctx.ctm
                let deviceScale = sqrt(abs(ctm.a * ctm.d - ctm.b * ctm.c))
                if deviceScale > 0 {
                    originX = (originX * deviceScale).rounded() / deviceScale
                }
            }
            ctx.textMatrix = .identity
            ctx.translateBy(x: originX, y: baselineY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.textPosition = .zero
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
    }
}
