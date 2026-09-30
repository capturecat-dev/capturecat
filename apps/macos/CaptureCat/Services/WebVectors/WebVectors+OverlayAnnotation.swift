import AppKit
import CoreGraphics
import CoreText

// VERBATIM ORACLE of Services/AnnotationRenderer.swift at commit
// da569841c7b63175bffa46d897457f157224774d — the private drawing functions
// (selectionRing 84–91, image 95–122, draw 126–149, drawBackdrop 182–228,
// draw(_:) 232–284, drawText 288–313, drawArrow 317–349, drawCallout
// 353–403, drawDrawing 447–478, drawShape 482–522, drawTap 526–596, point
// 600–603, handle 607–622, TextLine.draw 685–713) plus SwiftUIShadow.apply
// (Services/SwiftUIShadow.swift 20–28). The internal helpers the originals
// call (labelRect, trimmedStrokes, boxEdgeIntersection, TextLine,
// OklabGradient, TapRippleMath) are called for REAL. Drawing goes through
// WVRecCtx: the real CGContext draws the same pixels while the ops are
// recorded; `annotationDrawRecipe` proves oracle pixels == real
// AnnotationRenderer.image pixels == replay(ops) pixels.
enum AnnotationRendererOracle {
    typealias Chrome = AnnotationRenderer.Chrome
    typealias TextLine = AnnotationRenderer.TextLine

    private static let accent = SRGBA(red: 0, green: 0.478, blue: 1, alpha: 1)

    /// Verbatim SwiftUIShadow.apply(to:radius:dy:color:).
    static func swiftUIShadow(_ ctx: WVRecCtx, radius: CGFloat, dy: CGFloat, color: SRGBA) {
        let ctm = ctx.ctm
        let deviceScale = sqrt(abs(ctm.a * ctm.d - ctm.b * ctm.c))
        ctx.setShadow(
            offset: CGSize(width: 0, height: dy),
            blur: radius * SwiftUIShadow.blurFactor * deviceScale,
            color: color.cgColor
        )
    }

    private static func selectionRing(_ ctx: WVRecCtx, path: CGPath, scale: CGFloat) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setStrokeColor(accent.cgColor)
        ctx.setLineWidth(1.5 * scale)
        ctx.strokePath()
        ctx.restoreGState()
    }

    static func image(
        size: CGSize,
        annotations: [Annotation],
        currentTime: TimeInterval,
        videoRect: CGRect,
        scale: CGFloat,
        chrome: Chrome?,
        rasterScale: CGFloat,
        videoCornerRadius: CGFloat = 0
    ) -> (image: CGImage?, ops: [WV], width: Int, height: Int)? {
        let w = Int((size.width * rasterScale).rounded())
        let h = Int((size.height * rasterScale).rounded())
        guard w > 0, h > 0, let raw = WVReplay.bitmap(width: w, height: h) else { return nil }
        let ctx = WVRecCtx(raw)
        ctx.scaleBy(x: rasterScale, y: rasterScale)
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        draw(in: ctx, annotations: annotations, currentTime: currentTime,
             videoRect: videoRect, scale: scale, chrome: chrome,
             videoCornerRadius: videoCornerRadius)
        return (raw.makeImage(), ctx.ops, w, h)
    }

    static func draw(
        in ctx: WVRecCtx,
        annotations: [Annotation],
        currentTime: TimeInterval,
        videoRect: CGRect,
        scale: CGFloat,
        chrome: Chrome?,
        videoCornerRadius: CGFloat = 0
    ) {
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

    private static func drawBackdrop(
        _ a: Annotation,
        in ctx: WVRecCtx,
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
            break
        }

        ctx.setFillColor(CGColor(gray: 0, alpha: alpha))
        ctx.addPath(path)
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
    }

    private static func draw(
        _ a: Annotation,
        in ctx: WVRecCtx,
        currentTime: TimeInterval,
        videoRect: CGRect,
        scale: CGFloat,
        chrome: Chrome?
    ) {
        if chrome?.editingID == a.id { return }
        let phase = (chrome?.rendersSettled(a) ?? false)
            ? AnnotationEffectMath.Phase()
            : a.effectPhase(at: currentTime)
        let alpha = CGFloat(max(0, min(1, a.opacity)) * phase.alpha)
        guard alpha > 0.001 else { return }

        ctx.saveGState()
        let anchor = a.effectAnchor
        let ax = videoRect.minX + anchor.x * videoRect.width
        let ay = videoRect.minY + anchor.y * videoRect.height
        ctx.translateBy(x: ax, y: ay + CGFloat(phase.offsetY) * scale)
        ctx.scaleBy(x: CGFloat(phase.scale), y: CGFloat(phase.scale))
        ctx.translateBy(x: -ax, y: -ay)
        ctx.setAlpha(alpha)
        if a.showShadow {
            swiftUIShadow(ctx, radius: 4 * scale, dy: 1 * scale, color: SRGBA(white: 0, alpha: 0.35))
        }
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

    /// Verbatim TextLine.draw(in:center:color:snapToPixels:) — the REAL
    /// TextLine draws on the backing context; the op records its placement.
    private static func drawLine(
        _ line: TextLine, _ a: Annotation, scale: CGFloat, in ctx: WVRecCtx,
        center: CGPoint, color: SRGBA, snapToPixels: Bool = true
    ) {
        guard line.attributed.length > 0 else { return }
        let baselineY = center.y - line.size.height / 2 + line.baselineFromTop
        var originX = center.x - line.size.width / 2
        if snapToPixels {
            let ctm = ctx.ctm
            let deviceScale = sqrt(abs(ctm.a * ctm.d - ctm.b * ctm.c))
            if deviceScale > 0 {
                originX = (originX * deviceScale).rounded() / deviceScale
            }
        }
        line.draw(in: ctx.ctx, center: center, color: color, snapToPixels: snapToPixels)
        ctx.record([
            "op": "text", "text": .str(a.displayText),
            "fontName": a.fontName.map { WV.str($0) } ?? .null,
            "fontSize": (a.fontSize * scale).wv, "weight": .str(a.fontWeight.rawValue),
            "color": WVRGBA(color).wv,
            "originX": originX.wv, "baselineY": baselineY.wv,
            "width": line.size.width.wv, "height": line.size.height.wv,
            "baselineFromTop": line.baselineFromTop.wv,
            "center": center.wv, "snapToPixels": snapToPixels.wv,
        ])
    }

    /// Replays a `text` op exactly like TextLine.draw.
    static func replayText(_ op: WV, _ ctx: CGContext) {
        let weight = ProjectSettings.SubtitleWeight(rawValue: WVReplay.str(op["weight"]) ?? "") ?? .semibold
        let font = FontCatalog.font(named: WVReplay.str(op["fontName"]), size: WVReplay.num(op["fontSize"]),
                                    weight: weight.nsWeight)
        let c = WVReplay.rgba(op["color"])
        let attributed = NSAttributedString(string: WVReplay.str(op["text"]) ?? "", attributes: [
            .font: font,
            .foregroundColor: NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a),
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: WVReplay.num(op["originX"]), y: WVReplay.num(op["baselineY"]))
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    private static func drawText(
        _ a: Annotation, in ctx: WVRecCtx, videoRect: CGRect,
        scale: CGFloat, chrome: Chrome?, unscaled: Bool
    ) {
        let center = point(a.x, a.y, in: videoRect)
        let line = TextLine(a, scale: scale)
        let pill = AnnotationRenderer.labelRect(a, videoRect: videoRect, scale: scale)
            ?? CGRect(origin: center, size: .zero)
        let radius = max(0, a.cornerRadius) * scale

        if a.showBackground {
            ctx.addPath(ContinuousRoundedRect.path(rect: pill, cornerRadius: radius))
            ctx.setFillColor(SRGBA(a.backgroundColor).cgColor)
            ctx.fillPath()
        }
        drawLine(line, a, scale: scale, in: ctx, center: center, color: SRGBA(a.color), snapToPixels: unscaled)

        if let chrome, chrome.showsHandles, chrome.isSelected(a) {
            let outset = 3 * scale
            selectionRing(ctx, path: ContinuousRoundedRect.path(
                rect: pill.insetBy(dx: -outset, dy: -outset),
                cornerRadius: radius + outset), scale: scale)
        }
    }

    private static func drawArrow(
        _ a: Annotation, in ctx: WVRecCtx, videoRect: CGRect,
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

    private static func drawCallout(
        _ a: Annotation, in ctx: WVRecCtx, videoRect: CGRect,
        scale: CGFloat, chrome: Chrome?, unscaled: Bool
    ) {
        let center = point(a.x, a.y, in: videoRect)
        let tip = point(a.arrowEndX, a.arrowEndY, in: videoRect)
        let color = SRGBA(a.color)
        let line = TextLine(a, scale: scale)
        let box = AnnotationRenderer.labelRect(a, videoRect: videoRect, scale: scale)
            ?? CGRect(origin: center, size: .zero)
        let radius = max(0, a.cornerRadius) * scale
        let stroke = 1.5 * scale

        let end = AnnotationRenderer.boxEdgeIntersection(from: tip, toward: center, box: box) ?? center
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(stroke)
        ctx.setLineCap(.butt)
        ctx.move(to: tip)
        ctx.addLine(to: end)
        ctx.strokePath()

        let dot = 7 * scale
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: CGRect(x: tip.x - dot / 2, y: tip.y - dot / 2, width: dot, height: dot))

        ctx.addPath(ContinuousRoundedRect.path(rect: box, cornerRadius: radius))
        ctx.setFillColor(SRGBA(a.backgroundColor).cgColor)
        ctx.fillPath()
        ctx.addPath(ContinuousRoundedRect.path(
            rect: box.insetBy(dx: stroke / 2, dy: stroke / 2),
            cornerRadius: max(0, radius - stroke / 2)))
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(stroke)
        ctx.strokePath()
        drawLine(line, a, scale: scale, in: ctx, center: center, color: color, snapToPixels: unscaled)

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

    private static func drawDrawing(
        _ a: Annotation, in ctx: WVRecCtx, videoRect: CGRect, scale: CGFloat,
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

        for stroke in AnnotationRenderer.trimmedStrokes(a.drawingStrokes, progress: progress) where !stroke.isEmpty {
            if stroke.count == 1 {
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

    private static func drawShape(
        _ a: Annotation, in ctx: WVRecCtx, videoRect: CGRect,
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

    private static func drawTap(
        _ a: Annotation, in ctx: WVRecCtx, videoRect: CGRect,
        scale: CGFloat, currentTime: TimeInterval, chrome: Chrome?
    ) {
        let center = point(a.x, a.y, in: videoRect)
        let size = max(20, a.fontSize) * scale
        let base = SRGBA(a.color)
        func tinted(_ multiplier: CGFloat) -> CGColor {
            SRGBA(red: base.red, green: base.green, blue: base.blue,
                  alpha: base.alpha * multiplier).cgColor
        }

        let dot = size * 0.22
        ctx.setFillColor(tinted(0.4))
        ctx.fillEllipse(in: CGRect(x: center.x - dot / 2, y: center.y - dot / 2, width: dot, height: dot))

        if let progress = TapRippleMath.progress(elapsed: currentTime - a.startTime) {
            let outerScale = CGFloat(0.2 + progress * 0.8)
            let outerOpacity = CGFloat(1.0 - progress)
            let outerD = size * outerScale

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

            let glow = CGRect(x: center.x - outerD / 2, y: center.y - outerD / 2,
                              width: outerD, height: outerD)
            let from = SRGBA(red: base.red, green: base.green, blue: base.blue,
                             alpha: base.alpha * outerOpacity * 0.12)
            let to = SRGBA(red: base.red, green: base.green, blue: base.blue, alpha: 0)
            if outerD > 0, let gradient = OklabGradient.gradient(from: from, to: to) {
                ctx.saveGState()
                ctx.addEllipse(in: glow)
                ctx.clip()
                ctx.drawRadialGradient(
                    WVGradient(kind: .oklab(from: from, to: to), cg: gradient),
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

    private static func point(_ nx: Double, _ ny: Double, in videoRect: CGRect) -> CGPoint {
        CGPoint(x: videoRect.minX + nx * videoRect.width,
                y: videoRect.minY + ny * videoRect.height)
    }

    private static func handle(_ ctx: WVRecCtx, at p: CGPoint, diameter: CGFloat, alpha: CGFloat = 1) {
        let rect = CGRect(x: p.x - diameter / 2, y: p.y - diameter / 2,
                          width: diameter, height: diameter)
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 3,
                      color: CGColor(gray: 0, alpha: 0.35))
        ctx.setFillColor(SRGBA(white: 1, alpha: 1).cgColor)
        ctx.fillEllipse(in: rect)
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.setStrokeColor(SRGBA(white: 0, alpha: 0.2).cgColor)
        ctx.setLineWidth(1)
        ctx.strokeEllipse(in: rect.insetBy(dx: 0.5, dy: 0.5))
        ctx.restoreGState()
    }
}

// MARK: - Units

extension WebVectors {
    static let annotationTextSamples: [String] = [
        "Label", "Look here", "Click Export", "straße", "Ünïcödé àéîõü", "", "A", "👋🏽 hi",
        "Two words", "A much longer annotation label", "⌘⇧S", "ﬁnal", "ὀδυσσεύς", "日本語", "x",
    ]
    static let annotationFontNames: [String?] = [nil, nil, "Helvetica Neue", "Georgia", "Menlo", "Avenir Next", "No Such Font"]

    static func randomAnnotation(_ rng: inout WVRandom, time: Double, types: [AnnotationType] = AnnotationType.allCases) -> Annotation {
        let type = rng.pick(types)
        let start = time - rng.edgy(0, 3, edges: [0, 0.05, 0.15, 0.3, 0.6, 1.0])
        let len = rng.edgy(0, 5, edges: [0.3, 1, 2])
        var a = Annotation(id: rng.uuid(), type: type, startTime: start, endTime: max(start + len, time + rng.double(0, 0.4)))
        if rng.bool(0.15) { a.endTime = time + rng.pick([0, 0.05, 0.15, 0.29]) }
        a.x = rng.edgy(0.05, 0.95, edges: [0.5, 0])
        a.y = rng.edgy(0.05, 0.95, edges: [0.5, 1])
        a.arrowEndX = rng.edgy(0.05, 0.95, edges: [a.x, 0.9])
        a.arrowEndY = rng.edgy(0.05, 0.95, edges: [a.y, 0.1])
        a.text = rng.pick(annotationTextSamples)
        a.fontSize = rng.edgy(8, 64, edges: [18, 60, 10])
        a.showBackground = rng.bool(0.7)
        a.color = CodableColor(red: rng.double(0, 1), green: rng.double(0, 1), blue: rng.double(0, 1),
                               opacity: rng.edgy(0.3, 1, edges: [1]))
        a.backgroundColor = CodableColor(red: rng.double(0, 1), green: rng.double(0, 1), blue: rng.double(0, 1),
                                         opacity: rng.edgy(0.2, 1, edges: [0.55]))
        a.lineWidth = rng.edgy(0, 12, edges: [4, 0, 1])
        if type == .drawing {
            let strokes = rng.int(0, 4)
            a.drawingStrokes = (0..<strokes).map { _ in
                let n = rng.int(1, 12)
                var p = rng.point(0.1, 0.9)
                return (0..<n).map { _ in
                    p = CGPoint(x: p.x + rng.double(-0.05, 0.05), y: p.y + rng.double(-0.05, 0.05))
                    return CodablePoint(p)
                }
            }
        }
        a.fontWeight = rng.pick(ProjectSettings.SubtitleWeight.allCases)
        a.uppercase = rng.bool(0.3)
        a.fontName = rng.pick(annotationFontNames)
        a.opacity = rng.edgy(0.2, 1, edges: [1, 0.0005])
        a.cornerRadius = rng.edgy(-2, 30, edges: [8, 0, 100])
        a.showShadow = rng.bool(0.6)
        a.enterEffect = rng.pick(AnnotationEffect.allCases)
        a.exitEffect = rng.pick(AnnotationEffect.allCases)
        a.backdropOpacity = rng.bool(0.3) ? rng.edgy(0, 1.2, edges: [0.5, 0.95, 0.0005]) : 0
        return a
    }

    /// Steady-state TextLine measurement. NSAttributedString.size() at a
    /// font size CoreText has not seen yet returns a width ~1e-10 relative
    /// off the value every later call returns (cache warm-up artifact,
    /// measured: 118.13285583496297 then 118.13285592022063 forever), so
    /// measure once to warm the cache and record the second, stable value —
    /// the one every renderer call after the first sees.
    static func textLineWV(_ a: Annotation, scale: CGFloat) -> WV {
        _ = AnnotationRenderer.TextLine(a, scale: scale)
        let line = AnnotationRenderer.TextLine(a, scale: scale)
        return ["width": line.size.width.wv, "height": line.size.height.wv, "baselineFromTop": line.baselineFromTop.wv]
    }

    static var annotationUnits: [WebVectorUnit] {
        [
            WebVectorUnit(
                name: "annotationTextMetrics",
                notes: "Services/AnnotationRenderer.swift TextLine(a, scale:) — REAL size (NSAttributedString.size()) + baselineFromTop (round(font.ascender)) over strings × fontSize × scale × weight × fontName × uppercase; the web's text-measurement reference (font via FontCatalog.font(named:size: fontSize·scale, weight:))",
                build: annotationTextMetricsCases),
            WebVectorUnit(
                name: "annotationGeometry",
                notes: "Services/AnnotationRenderer.swift — REAL labelRect (over recorded TextLine sizes), boxEdgeIntersection, trimmedStrokes, backdropAlpha(annotations:at:settled:); VideoExporter.renderAnnotations (3631–3659) verbatim: videoRect Y-flip + scale = outputWidth/1920·2",
                build: annotationGeometryCases),
            WebVectorUnit(
                name: "annotationDrawRecipe",
                notes: "Services/AnnotationRenderer.swift image/draw/drawBackdrop/draw(_:)/drawText/drawArrow/drawCallout/drawDrawing/drawShape/drawTap/handle/selectionRing + TextLine.draw + SwiftUIShadow.apply as an ordered op list — verbatim oracle; rasterMatchesReal proves oracle pixels == REAL AnnotationRenderer.image and replay(ops) == real, byte for byte (export chrome nil + editor chrome)",
                build: annotationDrawRecipeCases),
            WebVectorUnit(
                name: "annotationTapRipple",
                notes: "Views/Editor/ClickRippleOverlay.swift TapRippleMath.progress(elapsed:), period, rippleDuration",
                build: annotationTapRippleCases),
            WebVectorUnit(
                name: "oklabGradientStops",
                notes: "Services/OklabGradient.swift — sample(_:at:) at every stop location of gradient(stops:) (resolution 256), mix, oklab, srgb, linearize, encode",
                build: oklabGradientCases),
        ]
    }

    private static func annotationTextMetricsCases() -> [WV] {
        var rng = WVRandom(seed: "annotationTextMetrics")
        var cases: [WV] = []
        var inputs: [(String, Double, CGFloat, ProjectSettings.SubtitleWeight, String?, Bool)] = []
        for text in annotationTextSamples {
            for fontName in annotationFontNames.dropFirst() {
                for weight in ProjectSettings.SubtitleWeight.allCases {
                    inputs.append((text, 18, 1, weight, fontName, false))
                }
            }
            for size in [9.0, 12, 18, 24, 36, 64] {
                for scale in [1.0, 2.0, 0.6666666666666666, 1.5] as [CGFloat] {
                    inputs.append((text, size, scale, .semibold, nil, rng.bool(0.3)))
                }
            }
        }
        for _ in 0..<150 {
            inputs.append((rng.pick(annotationTextSamples), rng.double(6, 90), CGFloat(rng.double(0.3, 3)),
                           rng.pick(ProjectSettings.SubtitleWeight.allCases), rng.pick(annotationFontNames), rng.bool(0.3)))
        }
        for (text, size, scale, weight, fontName, upper) in inputs {
            var a = Annotation(id: rng.uuid(), type: .text, startTime: 0, endTime: 1)
            a.text = text; a.fontSize = size; a.fontWeight = weight; a.fontName = fontName; a.uppercase = upper
            let font = FontCatalog.font(named: fontName, size: size * scale, weight: weight.nsWeight)
            cases.append(vcase(
                ["text": .str(text), "fontSize": size.wv, "scale": scale.wv, "fontWeight": .str(weight.rawValue),
                 "fontName": fontName.map { WV.str($0) } ?? .null, "uppercase": upper.wv],
                [
                    "displayText": .str(a.displayText),
                    "pointSize": (size * scale).wv,
                    "measured": textLineWV(a, scale: scale).setting("resolvedFont", .str(font.fontName))
                        .setting("familyName", .str(font.familyName ?? ""))
                        .setting("ascender", font.ascender.wv).setting("descender", font.descender.wv)
                        .setting("leading", font.leading.wv),
                ]))
        }
        return cases
    }

    private static func annotationGeometryCases() -> [WV] {
        var rng = WVRandom(seed: "annotationGeometry")
        var cases: [WV] = []
        for i in 0..<900 {
            let time = rng.double(0, 20)
            let a = randomAnnotation(&rng, time: time, types: i % 3 == 0 ? [.text, .callout] : AnnotationType.allCases)
            let videoRect = CGRect(x: rng.double(-50, 300), y: rng.double(-50, 300),
                                   width: rng.edgy(0, 1600, edges: [1280, 0]), height: rng.edgy(0, 900, edges: [720]))
            let scale = CGFloat(rng.edgy(0.3, 4, edges: [1, 2, 1.3333333333333333]))
            let from = rng.point(-200, 1800), toward = rng.bool(0.1) ? from : rng.point(-200, 1800)
            let box = rng.bool(0.1) ? CGRect(origin: toward, size: .zero)
                : CGRect(x: rng.double(-100, 1500), y: rng.double(-100, 900), width: rng.edgy(0, 400, edges: [0]),
                         height: rng.edgy(0, 200, edges: [0]))
            var strokes: [[CodablePoint]] = []
            for _ in 0..<(i % 17 == 0 ? 0 : rng.int(1, 5)) {
                strokes.append((0..<rng.int(0, 9)).map { _ in CodablePoint(rng.point()) })
            }
            let progress = rng.edgy(-0.2, 1.2, edges: [0, 1, 0.5, 0.999, 1e-9])
            var anns = [a]
            for _ in 0..<rng.int(0, 4) { anns.append(randomAnnotation(&rng, time: time)) }
            let times: [Double] = (0..<6).map { _ in rng.edgy(time - 1, time + 1, edges: [time, a.startTime, a.endTime]) }
            let outputSize = CGSize(width: rng.edgy(0, 4000, edges: [1920, 3840, 1280]), height: rng.edgy(0, 3000, edges: [1080]))
            let yUpRect = CGRect(x: rng.double(-10, 400), y: rng.double(-10, 400),
                                 width: rng.edgy(-100, 1600, edges: [0]), height: rng.edgy(-100, 900, edges: [0]))
            cases.append(vcase(
                [
                    "annotation": WVModel.annotation(a), "videoRect": videoRect.wv, "scale": scale.wv,
                    "textLine": textLineWV(a, scale: scale),
                    "from": from.wv, "toward": toward.wv, "box": box.wv,
                    "strokes": .arr(strokes.map { .arr($0.map { ["x": $0.x.wv, "y": $0.y.wv] as WV }) }),
                    "progress": progress.wv,
                    "annotations": .arr(anns.map(WVModel.annotation)), "times": times.wv,
                    "outputSize": outputSize.wv, "exportVideoRect": yUpRect.wv,
                ],
                [
                    "labelRect": AnnotationRenderer.labelRect(a, videoRect: videoRect, scale: scale).wv,
                    "boxEdgeIntersection": AnnotationRenderer.boxEdgeIntersection(from: from, toward: toward, box: box).wv,
                    "trimmedStrokes": .arr(AnnotationRenderer.trimmedStrokes(strokes, progress: progress).map {
                        .arr($0.map { ["x": $0.x.wv, "y": $0.y.wv] as WV })
                    }),
                    "backdropAlpha": times.map { AnnotationRenderer.backdropAlpha(annotations: anns, at: $0) }.wv,
                    "backdropAlphaSettled": times.map { AnnotationRenderer.backdropAlpha(annotations: anns, at: $0, settled: true) }.wv,
                    // VideoExporter.renderAnnotations 3639–3644 + 3652 (verbatim).
                    "exportVideoRectYDown": CGRect(
                        x: yUpRect.minX,
                        y: outputSize.height - yUpRect.maxY,
                        width: yUpRect.width,
                        height: yUpRect.height
                    ).wv,
                    "exportScale": (outputSize.width / 1920.0 * 2).wv,
                ]))
        }
        return cases
    }

    private static func annotationDrawRecipeCases() -> [WV] {
        var rng = WVRandom(seed: "annotationDrawRecipe")
        var cases: [WV] = []
        var mismatches = 0
        for i in 0..<520 {
            let time = rng.double(0.5, 30)
            let n = i % 40 == 0 ? 0 : rng.int(1, 4)
            var anns: [Annotation] = []
            let focusType = AnnotationType.allCases[i % AnnotationType.allCases.count]
            for k in 0..<n {
                anns.append(randomAnnotation(&rng, time: time, types: k == 0 ? [focusType] : AnnotationType.allCases))
            }
            // A few inactive ones (outside their span) must be skipped.
            if rng.bool(0.2) {
                var late = randomAnnotation(&rng, time: time + 10)
                late.startTime = time + 1
                anns.append(late)
            }
            let size = CGSize(width: rng.edgy(160, 800, edges: [640, 333.5]), height: rng.edgy(90, 450, edges: [360, 187.25]))
            let videoRect = CGRect(x: rng.double(-20, 80), y: rng.double(-20, 60),
                                   width: rng.double(80, Double(size.width)), height: rng.double(50, Double(size.height)))
            let scale = CGFloat(rng.edgy(0.4, 2.5, edges: [1, 2, 640.0 / 1920 * 2]))
            let rasterScale = CGFloat(rng.pick([1.0, 1.0, 2.0, 1.5]))
            let corner = CGFloat(rng.edgy(0, 60, edges: [0, 12]))
            var chrome: AnnotationRenderer.Chrome? = nil
            if rng.bool(0.35) {
                var c = AnnotationRenderer.Chrome(isPlaying: rng.bool(0.4),
                                                  selectedID: rng.bool(0.6) ? anns.first?.id : nil)
                if rng.bool(0.15) { c.editingID = anns.first?.id }
                chrome = c
            }
            let real = AnnotationRenderer.image(
                size: size, annotations: anns, currentTime: time, videoRect: videoRect, scale: scale,
                chrome: chrome, rasterScale: rasterScale, videoCornerRadius: corner)
            let oracle = AnnotationRendererOracle.image(
                size: size, annotations: anns, currentTime: time, videoRect: videoRect, scale: scale,
                chrome: chrome, rasterScale: rasterScale, videoCornerRadius: corner)
            var output: WV = .null
            if let oracle {
                var replayImage: CGImage? = nil
                if let ctx = WVReplay.bitmap(width: oracle.width, height: oracle.height) {
                    WVReplay.render(oracle.ops, in: ctx, drawText: AnnotationRendererOracle.replayText)
                    replayImage = ctx.makeImage()
                }
                let d1 = WVReplay.diff(real, oracle.image)
                let d2 = WVReplay.diff(real, replayImage)
                if d1 != 0 || d2 != 0 {
                    mismatches += 1
                    print("WEB-VECTORS FAIL annotationDrawRecipe case \(i): oracle Δ=\(d1) replay Δ=\(d2)")
                }
                output = [
                    "pixelWidth": oracle.width.wv, "pixelHeight": oracle.height.wv, "ops": .arr(oracle.ops),
                    "rasterMatchesReal": (d1 == 0 && d2 == 0).wv,
                ]
            } else if real != nil {
                mismatches += 1
                print("WEB-VECTORS FAIL annotationDrawRecipe case \(i): oracle nil, real non-nil")
            }
            var metrics: [(String, WV)] = []
            for a in anns where a.type == .text || a.type == .callout {
                metrics.append((a.id.uuidString, textLineWV(a, scale: scale)))
            }
            cases.append(vcase(
                [
                    "size": size.wv, "annotations": .arr(anns.map(WVModel.annotation)), "currentTime": time.wv,
                    "videoRect": videoRect.wv, "scale": scale.wv, "rasterScale": rasterScale.wv,
                    "videoCornerRadius": corner.wv,
                    "chrome": chrome.map { c -> WV in
                        ["isPlaying": c.isPlaying.wv,
                         "selectedID": c.selectedID.map { WV.str($0.uuidString) } ?? .null,
                         "editingID": c.editingID.map { WV.str($0.uuidString) } ?? .null]
                    } ?? .null,
                    "textMetrics": .obj(metrics),
                ],
                ["image": output]))
        }
        if mismatches == 0 { print("WEB-VECTORS annotationDrawRecipe raster proof OK") }
        return cases
    }

    private static func annotationTapRippleCases() -> [WV] {
        var rng = WVRandom(seed: "annotationTapRipple")
        var es: [Double] = [-1, -0.0, 0, 1e-12, 0.2, 0.45, 0.4500001, 0.5, 1.19999, 1.2, 1.2000001, 1.65, 1.6500001,
                            2.4, 3.6, 36.0, 1e9, .nan, .infinity]
        for _ in 0..<700 { es.append(rng.edgy(-0.5, 12, edges: [])) }
        return es.map { e in
            vcase(["elapsed": e.wv],
                  ["progress": TapRippleMath.progress(elapsed: e).wv,
                   "period": TapRippleMath.period.wv, "rippleDuration": TapRippleMath.rippleDuration.wv])
        }
    }

    private static func overlaySrgbaWV(_ c: SRGBA) -> WV { WVRGBA(c).wv }

    private static func oklabGradientCases() -> [WV] {
        var rng = WVRandom(seed: "oklabGradientStops")
        var cases: [WV] = []
        for i in 0..<120 {
            let n = i % 10 == 0 ? rng.int(3, 5) : 2
            var locs: [CGFloat] = (0..<n).map { _ in CGFloat(rng.double(0, 1)) }.sorted()
            if n == 2 && rng.bool(0.7) { locs = [0, 1] }
            let stops: [(location: CGFloat, color: SRGBA)] = locs.map { l in
                (l, SRGBA(red: rng.edgy(0, 1, edges: [0, 1]), green: rng.edgy(0, 1, edges: [0, 1]),
                          blue: rng.edgy(0, 1, edges: [0, 1]), alpha: rng.edgy(0, 1, edges: [0, 1, 0.12])))
            }
            let ts: [CGFloat] = (0...OklabGradient.resolution).map { CGFloat($0) / CGFloat(OklabGradient.resolution) }
                + [-0.1, 1.1]
            let a = stops[0].color, b = stops[stops.count - 1].color
            let c = rng.double(-0.2, 1.2)
            cases.append(vcase(
                ["stops": .arr(stops.map { ["location": $0.location.wv, "color": overlaySrgbaWV($0.color)] as WV }),
                 "ts": ts.wv, "c": c.wv],
                [
                    "samples": .arr(ts.map { overlaySrgbaWV(OklabGradient.sample(stops, at: $0)) }),
                    "mix": overlaySrgbaWV(OklabGradient.mix(a, b, CGFloat(c))),
                    "oklab": { let l = OklabGradient.oklab(a); return [l.0.wv, l.1.wv, l.2.wv] as WV }(),
                    "srgb": overlaySrgbaWV(OklabGradient.srgb(OklabGradient.oklab(b))),
                    "linearize": OklabGradient.linearize(CGFloat(c)).wv,
                    "encode": OklabGradient.encode(CGFloat(c)).wv,
                    "resolution": OklabGradient.resolution.wv,
                ]))
        }
        return cases
    }
}
