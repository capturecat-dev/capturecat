import AppKit
import CoreGraphics
import CoreText

// VERBATIM ORACLES for the OVERLAY cluster — copies of private/inline Swift
// that the golden vectors cannot reach, at commit
// da569841c7b63175bffa46d897457f157224774d. Each copy keeps the original's
// arithmetic and call order; the only change is that drawing goes through a
// recorder (WVRecCtx or an explicit `ops` list) as well as the real context.
// Every recipe unit proves the copy by comparing its pixels against the REAL
// renderer (see WebVectors+OverlayDraw.swift).

// MARK: - KeystrokeOverlayRenderer (Services/KeystrokeOverlay.swift)

enum KeystrokeOverlayOracle {
    struct Metrics {
        var width: CGFloat
        var ascent: CGFloat
        var descent: CGFloat
        var fontName: String
        var familyName: String
        var pointSize: CGFloat
        var kern: CGFloat
    }

    /// Verbatim KeystrokeOverlay.swift 351–359 (private makeLine).
    static func makeLine(text: String, size: Double, scale: CGFloat, color: NSColor) -> CTLine {
        let font = NSFont.systemFont(ofSize: 17 * CGFloat(size) * scale, weight: .semibold)
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
            .kern: 1.2 * CGFloat(size) * scale,
        ])
        return CTLineCreateWithAttributedString(attributed)
    }

    static func metrics(text: String, size: Double, scale: CGFloat) -> Metrics {
        let line = makeLine(text: text, size: size, scale: scale, color: .white)
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        let font = NSFont.systemFont(ofSize: 17 * CGFloat(size) * scale, weight: .semibold)
        return Metrics(width: width, ascent: ascent, descent: descent,
                       fontName: font.fontName, familyName: font.familyName ?? "",
                       pointSize: font.pointSize, kern: 1.2 * CGFloat(size) * scale)
    }

    /// Verbatim KeystrokeOverlay.swift 213–220 (pillSize) over the oracle line.
    static func pillSize(text: String, size: Double, scale: CGFloat) -> CGSize {
        let line = makeLine(text: text, size: size, scale: scale, color: .white)
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        let padH = 14 * CGFloat(size) * scale
        let padV = 8 * CGFloat(size) * scale
        return CGSize(width: ceil(width) + padH * 2, height: ceil(ascent + descent) + padV * 2)
    }

    /// Verbatim KeystrokeOverlay.swift 223–251 (draw).
    static func draw(
        in ctx: WVRecCtx,
        pill: KeystrokeOverlayMath.Pill,
        canvasSize: CGSize,
        position: KeystrokeOverlayPosition,
        size: Double,
        scale: CGFloat,
        animation: KeystrokeOverlayAnimation = .slideUp
    ) {
        let box = pillSize(text: pill.text, size: size, scale: scale)
        let rect = KeystrokeOverlayMath.pillRect(
            position: position, canvasSize: canvasSize,
            pillSize: box, entry: pill.entry, scale: scale, animation: animation
        )
        ctx.saveGState()
        ctx.setAlpha(CGFloat(pill.alpha))
        let pop = KeystrokeOverlayMath.popScale(animation: animation, entry: pill.entry)
        if pop != 1 {
            ctx.translateBy(x: rect.midX, y: rect.midY)
            ctx.scaleBy(x: pop, y: pop)
            ctx.translateBy(x: -rect.midX, y: -rect.midY)
        }
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        drawPill(in: ctx, text: pill.text, rect: rect, size: size, scale: scale)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    /// Verbatim KeystrokeOverlay.swift 256–287 (drawPill). The text block is
    /// recorded as ONE `ctText` op (origin = the translate it applies).
    static func drawPill(in ctx: WVRecCtx, text: String, rect: CGRect, size: Double, scale: CGFloat) {
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: rect.height / 2, cornerHeight: rect.height / 2,
            transform: nil
        )
        ctx.addPath(path)
        ctx.setFillColor(CGColor(srgbRed: 0.07, green: 0.07, blue: 0.08, alpha: 0.82))
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.14))
        ctx.setLineWidth(1 * scale)
        ctx.strokePath()

        let line = makeLine(text: text, size: size, scale: scale, color: .white)
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        let x = rect.midX - width / 2
        let y = rect.midY + (ascent - descent) / 2
        let real = ctx.ctx
        real.saveGState()
        real.textMatrix = .identity
        real.translateBy(x: x, y: y)
        real.scaleBy(x: 1, y: -1)
        real.textPosition = .zero
        CTLineDraw(line, real)
        real.restoreGState()
        ctx.record([
            "op": "ctText", "text": .str(text),
            "fontSize": (17 * CGFloat(size) * scale).wv, "weight": "semibold",
            "kern": (1.2 * CGFloat(size) * scale).wv,
            "color": WVRGBA(r: 1, g: 1, b: 1, a: 1).wv,
            "x": x.wv, "y": y.wv,
            "width": width.wv, "ascent": ascent.wv, "descent": descent.wv,
            "size": size.wv, "scale": scale.wv,
        ])
    }

    /// Replays a `ctText` op exactly like drawPill's text block.
    static func replayText(_ op: WV, _ ctx: CGContext) {
        let line = makeLine(text: WVReplay.str(op["text"]) ?? "", size: Double(WVReplay.num(op["size"])),
                            scale: WVReplay.num(op["scale"]), color: .white)
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: WVReplay.num(op["x"]), y: WVReplay.num(op["y"]))
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// Verbatim KeystrokeOverlay.swift 320–349 (image), recording the base
    /// transform too. Returns nil when no pill is active / the canvas is empty.
    static func image(
        canvasSize: CGSize,
        displayEvents: [KeystrokeOverlayMath.DisplayEvent],
        currentTime: TimeInterval,
        position: KeystrokeOverlayPosition,
        size: Double,
        scale: CGFloat,
        rasterScale: CGFloat,
        animation: KeystrokeOverlayAnimation = .slideUp
    ) -> (image: CGImage?, ops: [WV], width: Int, height: Int)? {
        guard let pill = KeystrokeOverlayMath.activePill(
            displayEvents: displayEvents, currentTime: currentTime
        ) else { return nil }
        let w = Int((canvasSize.width * rasterScale).rounded())
        let h = Int((canvasSize.height * rasterScale).rounded())
        guard w > 0, h > 0, let raw = WVReplay.bitmap(width: w, height: h) else { return nil }
        let ctx = WVRecCtx(raw)
        ctx.scaleBy(x: rasterScale, y: rasterScale)
        ctx.translateBy(x: 0, y: canvasSize.height)
        ctx.scaleBy(x: 1, y: -1)
        draw(in: ctx, pill: pill, canvasSize: canvasSize,
             position: position, size: size, scale: scale, animation: animation)
        return (raw.makeImage(), ctx.ops, w, h)
    }
}

// MARK: - CurtainUnveilMath.draw (Services/CurtainUnveilMath.swift)

enum CurtainUnveilOracle {
    typealias RGBA = CurtainUnveilMath.RGBA
    typealias State = CurtainUnveilMath.State

    /// Verbatim CurtainUnveilMath.swift 461–466 (private centroid).
    static func centroid(_ poly: [CGPoint]) -> CGPoint {
        guard !poly.isEmpty else { return .zero }
        var c = CGPoint.zero
        for p in poly { c.x += p.x; c.y += p.y }
        return CGPoint(x: c.x / CGFloat(poly.count), y: c.y / CGFloat(poly.count))
    }

    /// Verbatim CurtainUnveilMath.swift 470–482 (private revealedDirection).
    static func revealedDirection(state: State) -> CGPoint {
        let fd = CGPoint(x: state.foldEnd.x - state.foldStart.x,
                         y: state.foldEnd.y - state.foldStart.y)
        let len = hypot(fd.x, fd.y)
        guard len > 0.000001 else { return .zero }
        var n = CGPoint(x: -fd.y / len, y: fd.x / len)
        guard state.coverPolygon.count >= 3 else { return .zero }
        let mid = CGPoint(x: (state.foldStart.x + state.foldEnd.x) / 2,
                          y: (state.foldStart.y + state.foldEnd.y) / 2)
        let toCover = sub(centroid(state.coverPolygon), mid)
        if dot(toCover, n) > 0 { n = CGPoint(x: -n.x, y: -n.y) }
        return n
    }

    static func dot(_ a: CGPoint, _ b: CGPoint) -> CGFloat { a.x * b.x + a.y * b.y }
    static func sub(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }

    /// Verbatim CurtainUnveilMath.swift 492–503 (renderImage) + 510–713 (draw),
    /// recording UNIT-space ops alongside the real CG drawing.
    static func renderImage(state: State, size: CGSize, style: CurtainUnveilMath.CoverStyle)
        -> (image: CGImage?, ops: [WV], width: Int, height: Int)? {
        let w = Int(size.width.rounded()), h = Int(size.height.rounded())
        guard w > 0, h > 0, state.active,
              let ctx = WVReplay.bitmap(width: w, height: h, premultipliedLast: true)
        else { return nil }
        var ops: [WV] = []
        draw(state: state, in: ctx, size: CGSize(width: w, height: h), style: style, ops: &ops)
        return (ctx.makeImage(), ops, w, h)
    }

    static func draw(state: State, in ctx: CGContext, size: CGSize, style: CurtainUnveilMath.CoverStyle, ops: inout [WV]) {
        guard state.active, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if let clip = style.cardClip, let clipPath = CurtainUnveilMath.cardClipPath(clip, size: size) {
            ctx.addPath(clipPath)
            ctx.clip()
            ops.append(["op": "cardClip", "path": WebVectors.pathWV(clipPath)])
        }
        func map(_ u: CGPoint) -> CGPoint {
            CGPoint(x: u.x * size.width, y: (1 - u.y) * size.height)
        }
        func path(_ poly: [CGPoint]) -> CGPath? {
            guard poly.count >= 3 else { return nil }
            let p = CGMutablePath()
            p.addLines(between: poly.map(map))
            p.closeSubpath()
            return p
        }
        func color(_ c: RGBA) -> CGColor? {
            CGColor(colorSpace: space, components: [c.r, c.g, c.b, c.a])
        }
        func gradient(_ stops: [RGBA], locations: [CGFloat]) -> (cg: CGGradient, wv: WV)? {
            let colors = stops.compactMap(color)
            guard colors.count == stops.count else { return nil }
            guard let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations) else { return nil }
            return (g, ["colors": .arr(stops.map(WebVectors.rgbaWV)), "locations": locations.wv])
        }
        func fill(
            _ poly: [CGPoint], _ g: (cg: CGGradient, wv: WV)?, from a: CGPoint, to b: CGPoint,
            extend: Bool = true, ops: inout [WV]
        ) {
            guard let p = path(poly), let g else { return }
            ctx.saveGState()
            ctx.addPath(p)
            ctx.clip()
            ctx.drawLinearGradient(
                g.cg, start: map(a), end: map(b),
                options: extend ? [.drawsBeforeStartLocation, .drawsAfterEndLocation] : [])
            ctx.restoreGState()
            ops.append([
                "op": "linearGradient", "polygon": poly.wv,
                "colors": g.wv["colors"] ?? .null, "locations": g.wv["locations"] ?? .null,
                "start": a.wv, "end": b.wv, "before": extend.wv, "after": extend.wv,
            ])
        }

        let fade = state.flapOpacity
        let mid = CGPoint(x: (state.foldStart.x + state.foldEnd.x) / 2,
                          y: (state.foldStart.y + state.foldEnd.y) / 2)
        let revealDir = revealedDirection(state: state)
        let coverDir: CGPoint = {
            if revealDir != .zero { return CGPoint(x: -revealDir.x, y: -revealDir.y) }
            guard state.coverPolygon.count >= 3 else { return .zero }
            let c = centroid(state.coverPolygon)
            let v = CGPoint(x: c.x - mid.x, y: c.y - mid.y)
            let len = hypot(v.x, v.y)
            guard len > 0.000001 else { return .zero }
            return CGPoint(x: v.x / len, y: v.y / len)
        }()

        let stops = CurtainUnveilMath.coverStops(base: style.baseColor)
        fill(state.coverPolygon, gradient([stops.top, stops.bottom], locations: [0, 1]),
             from: CGPoint(x: 0.5, y: 0), to: CGPoint(x: 0.5, y: 1), ops: &ops)

        if state.coverPolygon.count >= 3, coverDir != .zero {
            let clear = RGBA(r: 1, g: 1, b: 1, a: 0)
            let lit = RGBA(r: 1, g: 1, b: 1, a: CurtainUnveilMath.sheenOpacity)
            let drift = 0.3 + 0.4 * state.progress
            let center = CGPoint(x: mid.x + coverDir.x * drift, y: mid.y + coverDir.y * drift)
            fill(state.coverPolygon,
                 gradient([clear, lit, clear], locations: [0, 0.5, 1]),
                 from: CGPoint(x: center.x - coverDir.x * CurtainUnveilMath.sheenHalfWidth,
                               y: center.y - coverDir.y * CurtainUnveilMath.sheenHalfWidth),
                 to: CGPoint(x: center.x + coverDir.x * CurtainUnveilMath.sheenHalfWidth,
                             y: center.y + coverDir.y * CurtainUnveilMath.sheenHalfWidth),
                 extend: false, ops: &ops)

            let outer = state.coverPolygon.max {
                dot(sub($0, mid), coverDir) < dot(sub($1, mid), coverDir)
            } ?? mid
            if let g = gradient(
                [RGBA(r: 0, g: 0, b: 0, a: CurtainUnveilMath.vignetteOpacity), RGBA(r: 0, g: 0, b: 0, a: 0)],
                locations: [0, 1]),
                let p = path(state.coverPolygon) {
                ctx.saveGState()
                ctx.addPath(p)
                ctx.clip()
                let endRadius = CurtainUnveilMath.vignetteRadiusFraction * max(size.width, size.height)
                ctx.drawRadialGradient(
                    g.cg, startCenter: map(outer), startRadius: 0,
                    endCenter: map(outer),
                    endRadius: endRadius,
                    options: [.drawsAfterEndLocation])
                ctx.restoreGState()
                ops.append([
                    "op": "radialGradient", "polygon": state.coverPolygon.wv,
                    "colors": g.wv["colors"] ?? .null, "locations": g.wv["locations"] ?? .null,
                    "center": outer.wv, "startRadius": 0.0, "endRadius": endRadius.wv,
                    "before": false, "after": true,
                ])
            }
        }

        if let logo = style.logo, style.logoOpacity > 0.001, style.logoScale > 0.001,
           logo.width > 0, logo.height > 0,
           let coverPath = path(state.coverPolygon) {
            let lw = size.width * style.logoScale
            let lh = lw * CGFloat(logo.height) / CGFloat(logo.width)
            let rect = CGRect(x: (size.width - lw) / 2, y: (size.height - lh) / 2,
                              width: lw, height: lh)
            ctx.saveGState()
            ctx.addPath(coverPath)
            ctx.clip()
            let alpha = max(0, min(1, style.logoOpacity))
            ctx.setAlpha(alpha)
            var tinted: RGBA? = nil
            if let tint = style.logoTint, let tc = color(tint) {
                ctx.clip(to: rect, mask: logo)
                ctx.setFillColor(tc)
                ctx.fill(rect)
                tinted = tint
            } else {
                ctx.draw(logo, in: rect)
            }
            ctx.restoreGState()
            ops.append([
                "op": "logo", "polygon": state.coverPolygon.wv, "rect": rect.wv, "alpha": alpha.wv,
                "tint": tinted.map(WebVectors.rgbaWV) ?? .null,
            ])
        }

        let ambientPoly = CurtainUnveilMath.ambientShadowPolygon(state: state)
        if ambientPoly.count >= 3, revealDir != .zero, state.shadowStrength > 0.001 {
            let a = CurtainUnveilMath.ambientShadowMaxOpacity * min(1, state.shadowStrength)
            fill(ambientPoly,
                 gradient([RGBA(r: 0, g: 0, b: 0, a: a), RGBA(r: 0, g: 0, b: 0, a: 0)],
                          locations: [0, 1]),
                 from: mid,
                 to: CGPoint(
                     x: mid.x + revealDir.x * CurtainUnveilMath.ambientShadowWidthFraction * CGFloat(2).squareRoot(),
                     y: mid.y + revealDir.y * CurtainUnveilMath.ambientShadowWidthFraction * CGFloat(2).squareRoot()),
                 ops: &ops)
        }

        if state.flapPolygon.count >= 3, fade > 0.001 {
            let c = centroid(state.flapPolygon)
            let dir = CGPoint(x: c.x - mid.x, y: c.y - mid.y)
            let len = hypot(dir.x, dir.y)
            if len > 0.000001 {
                let n = CGPoint(x: dir.x / len, y: dir.y / len)
                var far: CGFloat = 0.001
                for p in state.flapPolygon {
                    far = max(far, (p.x - mid.x) * n.x + (p.y - mid.y) * n.y)
                }
                fill(state.flapPolygon,
                     gradient([CurtainUnveilMath.flapColorNear.withAlpha(fade), CurtainUnveilMath.flapColorFar.withAlpha(fade)],
                              locations: [0, 1]),
                     from: mid, to: CGPoint(x: mid.x + n.x * far, y: mid.y + n.y * far), ops: &ops)
                let foldDirLen = hypot(state.foldEnd.x - state.foldStart.x,
                                       state.foldEnd.y - state.foldStart.y)
                if foldDirLen > 0.000001 {
                    let fdir = CGPoint(x: (state.foldEnd.x - state.foldStart.x) / foldDirLen,
                                       y: (state.foldEnd.y - state.foldStart.y) / foldDirLen)
                    let clear = RGBA(r: 1, g: 1, b: 1, a: 0)
                    let lit = RGBA(r: 1, g: 1, b: 1, a: CurtainUnveilMath.flapSheenOpacity * fade)
                    fill(state.flapPolygon,
                         gradient([clear, lit, clear], locations: [0, 0.5, 1]),
                         from: CGPoint(x: c.x - fdir.x * 0.25, y: c.y - fdir.y * 0.25),
                         to: CGPoint(x: c.x + fdir.x * 0.25, y: c.y + fdir.y * 0.25),
                         extend: false, ops: &ops)
                }
            }
        }

        let shadowPoly = CurtainUnveilMath.shadowPolygon(state: state)
        if shadowPoly.count >= 3, revealDir != .zero, state.shadowStrength > 0.001 {
            let alpha = CurtainUnveilMath.foldShadowMaxOpacity * state.shadowStrength
            fill(shadowPoly,
                 gradient([RGBA(r: 0, g: 0, b: 0, a: alpha), RGBA(r: 0, g: 0, b: 0, a: 0)],
                          locations: [0, 1]),
                 from: mid, to: CGPoint(x: mid.x + revealDir.x * state.shadowWidth,
                                        y: mid.y + revealDir.y * state.shadowWidth), ops: &ops)
        }

        if state.flapPolygon.count >= 3, coverDir != .zero, fade > 0.001,
           state.shadowStrength > 0.001 {
            let w = state.shadowWidth * CurtainUnveilMath.foldSpecularWidthFactor
            let alpha = CurtainUnveilMath.foldSpecularOpacity * min(1, state.shadowStrength) * fade
            if let p = path(state.flapPolygon),
               let g = gradient(
                   [RGBA(r: 1, g: 1, b: 1, a: alpha), RGBA(r: 1, g: 1, b: 1, a: 0)],
                   locations: [0, 1]) {
                ctx.saveGState()
                ctx.addPath(p)
                ctx.clip()
                let end = CGPoint(x: mid.x + coverDir.x * w, y: mid.y + coverDir.y * w)
                ctx.drawLinearGradient(
                    g.cg, start: map(mid),
                    end: map(end),
                    options: [.drawsAfterEndLocation])
                ctx.restoreGState()
                ops.append([
                    "op": "linearGradient", "polygon": state.flapPolygon.wv,
                    "colors": g.wv["colors"] ?? .null, "locations": g.wv["locations"] ?? .null,
                    "start": mid.wv, "end": end.wv, "before": false, "after": true,
                ])
            }
        }
    }

    /// Replays a curtain op list into a Y-UP raster of `size` (the unit →
    /// raster map is the one in CurtainUnveilMath.draw).
    static func replay(_ ops: [WV], size: CGSize, logo: CGImage?) -> CGImage? {
        let w = Int(size.width), h = Int(size.height)
        guard let ctx = WVReplay.bitmap(width: w, height: h, premultipliedLast: true),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        func map(_ u: CGPoint) -> CGPoint { CGPoint(x: u.x * size.width, y: (1 - u.y) * size.height) }
        func path(_ v: WV?) -> CGPath {
            let poly = WVReplay.arr(v).map { WVReplay.point($0) }
            let p = CGMutablePath()
            p.addLines(between: poly.map(map))
            p.closeSubpath()
            return p
        }
        func gradient(_ op: WV) -> CGGradient? {
            let colors = WVReplay.arr(op["colors"]).map { c -> CGColor in
                let r = WVReplay.rgba(c)
                return CGColor(colorSpace: space, components: [r.r, r.g, r.b, r.a])!
            }
            return CGGradient(colorsSpace: space, colors: colors as CFArray,
                              locations: WVReplay.arr(op["locations"]).map { WVReplay.num($0) })
        }
        ctx.saveGState()
        for op in ops {
            var options: CGGradientDrawingOptions = []
            if WVReplay.bool(op["before"]) { options.insert(.drawsBeforeStartLocation) }
            if WVReplay.bool(op["after"]) { options.insert(.drawsAfterEndLocation) }
            switch WVReplay.str(op["op"]) ?? "" {
            case "cardClip":
                ctx.addPath(WVReplay.path(op["path"]))
                ctx.clip()
            case "linearGradient":
                guard let g = gradient(op) else { continue }
                ctx.saveGState()
                ctx.addPath(path(op["polygon"]))
                ctx.clip()
                ctx.drawLinearGradient(g, start: map(WVReplay.point(op["start"])), end: map(WVReplay.point(op["end"])),
                                       options: options)
                ctx.restoreGState()
            case "radialGradient":
                guard let g = gradient(op) else { continue }
                ctx.saveGState()
                ctx.addPath(path(op["polygon"]))
                ctx.clip()
                let c = map(WVReplay.point(op["center"]))
                ctx.drawRadialGradient(g, startCenter: c, startRadius: WVReplay.num(op["startRadius"]),
                                       endCenter: c, endRadius: WVReplay.num(op["endRadius"]), options: options)
                ctx.restoreGState()
            case "logo":
                guard let logo else { continue }
                let rect = WVReplay.rect(op["rect"])
                ctx.saveGState()
                ctx.addPath(path(op["polygon"]))
                ctx.clip()
                ctx.setAlpha(WVReplay.num(op["alpha"]))
                if case .obj? = op["tint"] {
                    let t = WVReplay.rgba(op["tint"])
                    ctx.clip(to: rect, mask: logo)
                    ctx.setFillColor(CGColor(colorSpace: space, components: [t.r, t.g, t.b, t.a])!)
                    ctx.fill(rect)
                } else {
                    ctx.draw(logo, in: rect)
                }
                ctx.restoreGState()
            default:
                print("WEB-VECTORS FAIL curtain replay: unknown op")
            }
        }
        ctx.restoreGState()
        return ctx.makeImage()
    }
}
