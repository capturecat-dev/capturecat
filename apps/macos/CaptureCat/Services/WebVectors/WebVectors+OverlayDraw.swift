import AppKit
import CoreGraphics
import CoreText

// Draw-recipe units for the OVERLAY cluster (see WebVectors+Overlay.swift).
extension WebVectors {
    /// Deterministic synthetic curtain logo: 40×24, an opaque-ish ellipse on
    /// clear with a colour ramp (so tint vs original colours both show).
    static let syntheticCurtainLogo: CGImage = {
        let w = 40, h = 24
        let ctx = WVReplay.bitmap(width: w, height: h, premultipliedLast: true)!
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let g = CGGradient(colorsSpace: space, colors: [
            CGColor(srgbRed: 0.9, green: 0.2, blue: 0.1, alpha: 1),
            CGColor(srgbRed: 0.1, green: 0.3, blue: 0.95, alpha: 0.8),
        ] as CFArray, locations: [0, 1])!
        ctx.addEllipse(in: CGRect(x: 2, y: 2, width: 36, height: 20))
        ctx.clip()
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 40, y: 24), options: [])
        return ctx.makeImage()!
    }()

    // MARK: Keystroke pill recipe

    static func keystrokeDrawRecipeCases() -> [WV] {
        var rng = WVRandom(seed: "keystrokeOverlayDrawRecipe")
        var cases: [WV] = []
        let positions = KeystrokeOverlayPosition.allCases
        let animations = KeystrokeOverlayAnimation.allCases
        var mismatches = 0
        for i in 0..<360 {
            let position = positions[i % positions.count]
            let animation = animations[(i / positions.count) % animations.count]
            let canvas = CGSize(width: rng.edgy(160, 1280, edges: [640, 1280, 333.5]),
                                height: rng.edgy(90, 720, edges: [360, 720, 187.25]))
            let events = randomKeystrokeEvents(&rng, count: rng.int(1, 6))
            let display = KeystrokeOverlayMath.displayEvents(from: events)
            let anchor = display.isEmpty ? 0 : rng.pick(display).time
            let elapsed = rng.edgy(-0.05, 1.6, edges: [0, 0.01, 0.06, 0.12, 0.2, 0.24, 0.5, 1.22, 1.35, 1.52])
            let time = anchor + elapsed
            let size = rng.edgy(0.5, 2, edges: [1, 0.75, 1.5])
            let scale = CGFloat(rng.edgy(0.5, 2, edges: [1, 2, 0.75]))
            let rasterScale = CGFloat(rng.pick([1.0, 1.0, 2.0, 0.5, 1.5]))
            let pill = KeystrokeOverlayMath.activePill(displayEvents: display, currentTime: time)
            let real = KeystrokeOverlayRenderer.image(
                canvasSize: canvas, displayEvents: display, currentTime: time, position: position,
                size: size, scale: scale, rasterScale: rasterScale, animation: animation)
            let oracle = KeystrokeOverlayOracle.image(
                canvasSize: canvas, displayEvents: display, currentTime: time, position: position,
                size: size, scale: scale, rasterScale: rasterScale, animation: animation)
            var output: WV = .null
            if let oracle {
                var replayImage: CGImage? = nil
                if let ctx = WVReplay.bitmap(width: oracle.width, height: oracle.height) {
                    WVReplay.render(oracle.ops, in: ctx, drawText: KeystrokeOverlayOracle.replayText)
                    replayImage = ctx.makeImage()
                }
                let d1 = WVReplay.diff(real, oracle.image)
                let d2 = WVReplay.diff(real, replayImage)
                if d1 != 0 || d2 != 0 {
                    mismatches += 1
                    print("WEB-VECTORS FAIL keystrokeOverlayDrawRecipe case \(i): oracle Δ=\(d1) replay Δ=\(d2)")
                }
                output = [
                    "pixelWidth": oracle.width.wv, "pixelHeight": oracle.height.wv,
                    "ops": .arr(oracle.ops),
                    "rasterMatchesReal": (d1 == 0 && d2 == 0).wv,
                ]
            } else if real != nil {
                mismatches += 1
                print("WEB-VECTORS FAIL keystrokeOverlayDrawRecipe case \(i): oracle nil, real non-nil")
            }
            let metrics: WV = pill.map { p -> WV in
                let m = KeystrokeOverlayOracle.metrics(text: p.text, size: size, scale: scale)
                return ["width": m.width.wv, "ascent": m.ascent.wv, "descent": m.descent.wv]
            } ?? .null
            cases.append(vcase(
                [
                    "canvasSize": canvas.wv, "displayEvents": .arr(display.map(displayEventWV)),
                    "currentTime": time.wv, "position": .str(position.rawValue),
                    "animation": .str(animation.rawValue), "size": size.wv, "scale": scale.wv,
                    "rasterScale": rasterScale.wv, "textMetrics": metrics,
                ],
                ["image": output]))
        }
        if mismatches == 0 { print("WEB-VECTORS keystrokeOverlayDrawRecipe raster proof OK") }
        return cases
    }

    // MARK: Curtain recipe

    static func curtainDrawRecipeCases() -> [WV] {
        var rng = WVRandom(seed: "curtainUnveilDrawRecipe")
        var cases: [WV] = []
        var mismatches = 0
        let corners = CurtainUnveilCorner.allCases.filter { $0 != .off }
        let shapes = ProjectSettings.FrameShape.allCases
        for i in 0..<420 {
            let corner = i % 37 == 0 ? CurtainUnveilCorner.off : corners[i % corners.count]
            let duration = rng.edgy(0.3, 3, edges: [1.2])
            let p = rng.edgy(-0.05, 1.02, edges: [0, 0.3, 0.6, 0.75, 0.8, 0.85, 0.9, 0.95, 0.99, 0.999])
            let state = CurtainUnveilMath.state(corner: corner, at: p * duration, startTime: 0, duration: duration)
            let size = CGSize(width: rng.edgy(24, 720, edges: [320, 101.5]),
                              height: rng.edgy(24, 540, edges: [180, 60.4]))
            let settings = ProjectSettings()
            if rng.bool(0.5) {
                settings.curtainColor = CodableColor(red: rng.double(0, 1), green: rng.double(0, 1),
                                                     blue: rng.double(0, 1), opacity: rng.edgy(0.2, 1, edges: [1]))
            }
            let useLogo = rng.bool(0.5)
            if rng.bool(0.4) {
                settings.curtainLogoTint = CodableColor(red: rng.double(0, 1), green: rng.double(0, 1),
                                                        blue: rng.double(0, 1), opacity: rng.edgy(0.3, 1, edges: [1]))
            }
            settings.curtainLogoOpacity = rng.edgy(0, 1.2, edges: [1, 0.0005])
            settings.curtainLogoScale = rng.edgy(0.05, 0.6, edges: [0.25])
            var style = CurtainUnveilMath.coverStyle(settings: settings, logo: useLogo ? syntheticCurtainLogo : nil)
            if rng.bool(0.6) {
                let rounded = CGSize(width: size.width.rounded(), height: size.height.rounded())
                let device: (rect: CGRect, cornerRadius: CGFloat)? = rng.bool(0.3)
                    ? (CGRect(x: rng.double(0, 20), y: rng.double(0, 20),
                              width: rng.double(10, Double(rounded.width)), height: rng.double(10, Double(rounded.height))),
                       CGFloat(rng.double(0, 30)))
                    : nil
                style.cardClip = CurtainUnveilMath.cardClip(
                    frameShape: rng.pick(shapes), cornerRadius: CGFloat(rng.edgy(0, 60, edges: [0, 12])),
                    cardSize: rounded, deviceScreen: device)
            }
            let real = CurtainUnveilMath.renderImage(state: state, size: size, style: style)
            let oracle = CurtainUnveilOracle.renderImage(state: state, size: size, style: style)
            var output: WV = .null
            if let oracle {
                let replayImage = CurtainUnveilOracle.replay(
                    oracle.ops, size: CGSize(width: oracle.width, height: oracle.height), logo: style.logo)
                let d1 = WVReplay.diff(real, oracle.image)
                let d2 = WVReplay.diff(real, replayImage)
                if d1 != 0 || d2 != 0 {
                    mismatches += 1
                    print("WEB-VECTORS FAIL curtainUnveilDrawRecipe case \(i): oracle Δ=\(d1) replay Δ=\(d2)")
                }
                output = [
                    "width": oracle.width.wv, "height": oracle.height.wv, "ops": .arr(oracle.ops),
                    "rasterMatchesReal": (d1 == 0 && d2 == 0).wv,
                ]
            } else if real != nil {
                mismatches += 1
                print("WEB-VECTORS FAIL curtainUnveilDrawRecipe case \(i): oracle nil, real non-nil")
            }
            cases.append(vcase(
                [
                    "state": curtainStateWV(state), "size": size.wv,
                    "style": [
                        "baseColor": style.baseColor.map(rgbaWV) ?? .null,
                        "logoSize": style.logo.map { ["width": $0.width.wv, "height": $0.height.wv] as WV } ?? .null,
                        "logoOpacity": style.logoOpacity.wv,
                        "logoScale": style.logoScale.wv,
                        "logoTint": style.logoTint.map(rgbaWV) ?? .null,
                        "cardClip": style.cardClip.map(cardClipWVPublic) ?? .null,
                    ],
                ],
                ["image": output]))
        }
        if mismatches == 0 { print("WEB-VECTORS curtainUnveilDrawRecipe raster proof OK") }
        return cases
    }

    static func cardClipWVPublic(_ c: CurtainUnveilMath.CardClip) -> WV {
        let shape: String
        switch c.shape {
        case .rectangle: shape = "rectangle"
        case .rounded: shape = "rounded"
        case .squircle: shape = "squircle"
        }
        return [
            "shape": .str(shape),
            "cornerRadiusFraction": c.cornerRadiusFraction.wv,
            "screenRectUnit": c.screenRectUnit.wv,
            "screenCornerRadiusFraction": c.screenCornerRadiusFraction.wv,
        ]
    }

    /// Annotation (WebVectors+OverlayAnnotation.swift) + exporter subtitle
    /// (WebVectors+OverlaySubtitle.swift) units.
    static var overlayDrawUnits: [WebVectorUnit] { annotationUnits + subtitleUnits }
}
