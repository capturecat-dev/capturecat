import AppKit
import CoreGraphics
import CoreImage

// VERBATIM ORACLES for the Style cluster — private/inline Swift that the
// golden-vector harness cannot call directly. Each oracle cites file + line
// range at commit da569841c7b63175bffa46d897457f157224774d and is, wherever
// the real code can be driven end-to-end, CROSS-CHECKED against it at
// generation time (a divergence prints `WEB-VECTORS FAIL` via `styleOracleFail`
// and poisons the unit with an `oracleMismatch` case so the TS suite fails).
extension WebVectors {
    /// Set when any oracle cross-check fails during generation.
    nonisolated(unsafe) static var styleOracleFailures: [String] = []

    static func styleOracleFail(_ message: String) {
        print("WEB-VECTORS FAIL oracle: \(message)")
        styleOracleFailures.append(message)
    }

    /// Appended to a unit's cases when its oracle cross-check failed, so the
    /// TS suite (which never produces this key) fails loudly.
    static func styleOracleSentinel(_ unit: String) -> [WV] {
        let mine = styleOracleFailures.filter { $0.hasPrefix(unit) }
        guard !mine.isEmpty else { return [] }
        return [vcase(["oracleMismatch": .str(unit)], ["oracleMismatch": .arr(mine.map { .str($0) })])]
    }

    // MARK: - BackgroundGradientRenderer.draw (Services/BackgroundGradientRenderer.swift:26-55)

    /// The gradient line endpoints `draw(in:rect:start:end:axis:)` hands to
    /// `drawLinearGradient`, in the context's Y-UP space. nil when the guard
    /// `rect.width > 0, rect.height > 0` skips drawing.
    static func gradientDrawPointsOracle(rect: CGRect, axis: BackgroundGradientRenderer.Axis) -> (p0: CGPoint, p1: CGPoint)? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        let p0: CGPoint, p1: CGPoint
        switch axis {
        case .diagonal:
            p0 = CGPoint(x: rect.minX, y: rect.maxY)
            p1 = CGPoint(x: rect.maxX, y: rect.minY)
        case .vertical:
            p0 = CGPoint(x: rect.midX, y: rect.maxY)
            p1 = CGPoint(x: rect.midX, y: rect.minY)
        case .angle(let degrees):
            let theta = degrees * .pi / 180
            let d = CGPoint(x: sin(theta), y: cos(theta))
            let length = abs(rect.width * d.x) + abs(rect.height * d.y)
            let c = CGPoint(x: rect.midX, y: rect.midY)
            p0 = CGPoint(x: c.x - d.x * length / 2, y: c.y - d.y * length / 2)
            p1 = CGPoint(x: c.x + d.x * length / 2, y: c.y + d.y * length / 2)
        }
        return (p0, p1)
    }

    // MARK: - BackgroundLook private helpers (Services/BackgroundLook.swift)

    /// `noiseRows(width:height:cell:)` — BackgroundLook.swift:145-168 (cache
    /// omitted: it only memoizes this exact computation).
    static func noiseRowsOracle(width: Int, height: Int, cell: Int) -> [[Float]] {
        let vw = (width + cell - 1) / cell
        let vh = (height + cell - 1) / cell
        var rows = [[Float]](repeating: [], count: vh)
        for vy in 0..<vh {
            var row = [Float](repeating: 0, count: vw)
            for vx in 0..<vw {
                var v = UInt64(vx) &* 0x9E3779B97F4A7C15 ^ UInt64(vy) &* 0xBF58476D1CE4E5B9
                v ^= v >> 30; v = v &* 0x94D049BB133111EB; v ^= v >> 27
                row[vx] = Float(v & 0xFFFF) / 65535 * 2 - 1
            }
            rows[vy] = row
        }
        return rows
    }

    /// The per-pixel arithmetic of `grained(_:amount:scale:)` —
    /// BackgroundLook.swift:170-194 — applied to an RGBA8 buffer (row 0 = top,
    /// same row order as the CGContext memory the Swift loop walks).
    static func grainedOracle(rgba: [UInt8], width w: Int, height h: Int, amount: Double, scale: CGFloat) -> [UInt8] {
        var data = rgba
        let amplitude = Float(max(0, min(1, amount)) * 14.5)
        let s = max(1, Int(scale.rounded()))
        let rows = noiseRowsOracle(width: w, height: h, cell: s)
        for y in 0..<h {
            let noise = rows[y / s]
            for x in 0..<w {
                let delta = Int(noise[x / s] * amplitude)
                let p = (y * w + x) * 4
                for c in 0..<3 {
                    data[p + c] = UInt8(max(0, min(255, Int(data[p + c]) + delta)))
                }
            }
        }
        return data
    }

    struct MeshPoolOracle {
        let center: CGPoint
        let radius: CGFloat
        let color: SRGBA
        /// (location, alpha) — CGColor.copy(alpha:) REPLACES the colour's alpha.
        let stops: [(CGFloat, CGFloat)]
    }

    /// `meshImage(start:end:pixelSize:)` pool list — BackgroundLook.swift:252-293.
    /// Centers are in the CG context's Y-UP pixel space.
    static func meshPoolsOracle(start: SRGBA, end: SRGBA, pixelSize: CGSize) -> [MeshPoolOracle] {
        func ramp(_ t: CGFloat) -> SRGBA { OklabGradient.mix(start, end, t) }
        let mid = ramp(0.5)
        let lift = OklabGradient.mix(mid, SRGBA(white: 1), 0.18)
        let sink = OklabGradient.mix(mid, SRGBA(white: 0), 0.3)
        let pools: [(Double, Double, Double, SRGBA, Double)] = [
            (0.18, 0.20, 0.85, ramp(0.15), 0.45),
            (0.85, 0.12, 0.75, ramp(0.85), 0.45),
            (0.50, 0.55, 0.80, lift, 0.15),
            (0.15, 0.85, 0.75, sink, 0.45),
            (0.88, 0.82, 0.80, ramp(0.65), 0.45),
            (0.60, 0.32, 0.45, mid, 0.25),
        ]
        let minEdge = min(pixelSize.width, pixelSize.height)
        var out: [MeshPoolOracle] = []
        for (fx, fy, fr, color, alpha) in pools {
            let stops: [(CGFloat, CGFloat)] = [(0, 1), (0.4, 0.7), (0.75, 0.25), (1, 0)]
            let center = CGPoint(x: fx * pixelSize.width, y: (1 - fy) * pixelSize.height)
            out.append(MeshPoolOracle(
                center: center, radius: fr * minEdge, color: color,
                stops: stops.map { ($0.0, $0.1 * alpha) }))
        }
        return out
    }

    /// Renders the mesh from the oracle's pool list with the same CG calls as
    /// meshImage (for the cross-check against the real BackgroundLook bitmap).
    static func meshImageFromOracle(start: SRGBA, end: SRGBA, pixelSize: CGSize) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil, width: Int(pixelSize.width), height: Int(pixelSize.height),
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let rect = CGRect(origin: .zero, size: pixelSize)
        BackgroundGradientRenderer.draw(in: ctx, rect: rect, start: start, end: end, axis: .diagonal)
        for pool in meshPoolsOracle(start: start, end: end, pixelSize: pixelSize) {
            let colors = pool.stops.map { pool.color.cgColor.copy(alpha: $0.1)! } as CFArray
            guard let grad = CGGradient(colorsSpace: space, colors: colors, locations: pool.stops.map(\.0)) else { continue }
            ctx.drawRadialGradient(grad, startCenter: pool.center, startRadius: 0,
                                   endCenter: pool.center, endRadius: pool.radius, options: [])
        }
        return ctx.makeImage()
    }

    /// `aspectFill(_:pixelSize:)` draw rect — BackgroundLook.swift:304-312
    /// (CG Y-up; the centring is symmetric so it is the same rect Y-down).
    static func aspectFillRectOracle(sourceWidth: Int, sourceHeight: Int, pixelSize: CGSize) -> CGRect {
        let sw = CGFloat(sourceWidth), sh = CGFloat(sourceHeight)
        let scale = max(pixelSize.width / sw, pixelSize.height / sh)
        let w = sw * scale, h = sh * scale
        return CGRect(x: (pixelSize.width - w) / 2, y: (pixelSize.height - h) / 2, width: w, height: h)
    }

    /// Which branch `BackgroundLook.cgImage(for:size:scale:)` takes —
    /// BackgroundLook.swift:103-128 (assuming bitmap allocation succeeds).
    static func backgroundRenderPathOracle(_ spec: BackgroundLook.Spec, size: CGSize, scale: CGFloat) -> String {
        guard spec.type != .transparent else { return "nil" }
        let pixelSize = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        guard pixelSize.width > 0, pixelSize.height > 0 else { return "nil" }
        if spec.isPlainLook { return "base" }
        if spec.isPlainLookExceptNoise { return spec.noise > 0 ? "baseGrain" : "base" }
        return spec.noise > 0 ? "styledGrain" : "styled"
    }

    // MARK: - BackgroundLook.styled as data (Services/BackgroundLook.swift:353-422)

    /// One step of a CoreImage chain, as plain data.
    enum CIStep {
        case clamp                                   // clampedToExtent()
        case crop(CGRect)                            // cropped(to:)
        case filter(String, [(String, CIParam)])     // applyingFilter(name, parameters:)
        case compositeColorOver(SRGBA, CGRect)       // CIImage(color:).cropped(to:).composited(over: img)
        case cropToSourceIfInfinite                  // CameraStyleMath: if extent infinite, crop to input extent
    }

    enum CIParam {
        case num(Double)
        case vec([Double])

        var ci: Any {
            switch self {
            case .num(let d): return d
            case .vec(let v):
                switch v.count {
                case 2: return CIVector(x: v[0], y: v[1])
                case 4: return CIVector(x: v[0], y: v[1], z: v[2], w: v[3])
                default: return CIVector(values: v.map { CGFloat($0) }, count: v.count)
                }
            }
        }

        var wv: WV {
            switch self {
            case .num(let d): return d.wv
            case .vec(let v): return v.wv
            }
        }
    }

    static func stepsWV(_ steps: [CIStep]) -> WV {
        .arr(steps.map { step -> WV in
            switch step {
            case .clamp: return ["op": "clamp"]
            case .crop(let r): return ["op": "crop", "rect": r.wv]
            case .filter(let name, let params):
                return ["op": "filter", "name": .str(name), "params": .obj(params.map { ($0.0, $0.1.wv) })]
            case .compositeColorOver(let c, let r):
                return ["op": "compositeColorOver",
                        "color": ["red": c.red.wv, "green": c.green.wv, "blue": c.blue.wv, "alpha": c.alpha.wv],
                        "rect": r.wv]
            case .cropToSourceIfInfinite: return ["op": "cropToSourceIfInfinite"]
            }
        })
    }

    /// Interprets a chain with the same CIImage calls the Swift source makes.
    static func applySteps(_ steps: [CIStep], to image: CIImage) -> CIImage {
        var img = image
        for step in steps {
            switch step {
            case .clamp: img = img.clampedToExtent()
            case .crop(let r): img = img.cropped(to: r)
            case .filter(let name, let params):
                img = img.applyingFilter(name, parameters: Dictionary(uniqueKeysWithValues: params.map { ($0.0, $0.1.ci) }))
            case .compositeColorOver(let t, let r):
                img = CIImage(color: CIColor(red: t.red, green: t.green, blue: t.blue, alpha: t.alpha)).cropped(to: r).composited(over: img)
            case .cropToSourceIfInfinite:
                if img.extent.isInfinite { img = img.cropped(to: image.extent) }
            }
        }
        return img
    }

    /// `BackgroundLook.styled(base:spec:pixelSize:)` as data — verbatim order,
    /// guards and parameter math.
    static func styledChainOracle(spec: BackgroundLook.Spec, pixelSize: CGSize) -> [CIStep] {
        let rect = CGRect(origin: .zero, size: pixelSize)
        var steps: [CIStep] = []

        let block = BackgroundLook.pixelateScale(spec.pixelate, pixelSize: pixelSize)
        if block >= 1 {
            steps += [.clamp, .filter("CIPixellate", [
                (kCIInputCenterKey, .vec([0, 0])),
                (kCIInputScaleKey, .num(block)),
            ]), .crop(rect)]
        }

        if spec.halftone > 0 {
            steps += [.clamp, .filter("CIDotScreen", [
                (kCIInputCenterKey, .vec([0, 0])),
                (kCIInputAngleKey, .num(0)),
                (kCIInputWidthKey, .num(BackgroundLook.halftoneWidth(spec.halftone, pixelSize: pixelSize))),
                (kCIInputSharpnessKey, .num(0.7)),
            ]), .crop(rect)]
        }

        let sigma = BackgroundLook.blurSigma(spec.blur, pixelSize: pixelSize)
        if sigma > 0.01 {
            steps += [.clamp, .filter("CIGaussianBlur", [(kCIInputRadiusKey, .num(sigma))]), .crop(rect)]
        }

        if abs(spec.brightness) >= 0.0005 || abs(spec.saturation - 1) >= 0.0005
            || abs(spec.contrast - 1) >= 0.0005 {
            steps.append(.filter("CIColorControls", [
                (kCIInputBrightnessKey, .num(spec.brightness)),
                (kCIInputSaturationKey, .num(spec.saturation)),
                (kCIInputContrastKey, .num(spec.contrast)),
            ]))
        }

        if abs(spec.hue) >= 0.0005 {
            steps.append(.filter("CIHueAdjust", [(kCIInputAngleKey, .num(spec.hue * .pi / 180))]))
        }

        if spec.tintOpacity > 0 {
            let t = spec.tint
            steps.append(.compositeColorOver(
                SRGBA(red: t.red, green: t.green, blue: t.blue,
                      alpha: t.alpha * CGFloat(max(0, min(1, spec.tintOpacity)))),
                rect))
        }

        if spec.vignette > 0 {
            let v: CGFloat = CGFloat(max(0, min(1, spec.vignette)))
            let radius: CGFloat = hypot(rect.width, rect.height) * 0.5 * (1.1 - 0.5 * v)
            steps.append(.filter("CIVignetteEffect", [
                (kCIInputCenterKey, .vec([Double(rect.midX), Double(rect.midY)])),
                (kCIInputRadiusKey, .num(Double(radius))),
                (kCIInputIntensityKey, .num(Double(v))),
                ("inputFalloff", .num(0.5)),
            ]))
        }

        steps.append(.crop(rect))
        return steps
    }

    // MARK: - CameraStyleMath.adjustedImage as data (Services/CameraStyleMath.swift:58-99)

    static func adjustedImageChainOracle(_ a: CameraStyleMath.Adjustments) -> [CIStep] {
        guard !a.isIdentity else { return [] }
        var steps: [CIStep] = []
        switch a.filter {
        case .none: break
        case .mono: steps.append(.filter("CIPhotoEffectMono", []))
        case .noir: steps.append(.filter("CIPhotoEffectNoir", []))
        case .fade: steps.append(.filter("CIPhotoEffectFade", []))
        case .warm:
            steps.append(.filter("CITemperatureAndTint", [
                ("inputNeutral", .vec([6500, 0])),
                ("inputTargetNeutral", .vec([5100, 0])),
            ]))
        case .cool:
            steps.append(.filter("CITemperatureAndTint", [
                ("inputNeutral", .vec([6500, 0])),
                ("inputTargetNeutral", .vec([8200, 0])),
            ]))
        }
        if a.brightness != 0 || a.contrast != 1 || a.saturation != 1 {
            steps.append(.filter("CIColorControls", [
                (kCIInputBrightnessKey, .num(a.brightness)),
                (kCIInputContrastKey, .num(a.contrast)),
                (kCIInputSaturationKey, .num(a.saturation)),
            ]))
        }
        if a.hue != 0 {
            steps.append(.filter("CIHueAdjust", [(kCIInputAngleKey, .num(a.hue * .pi / 180))]))
        }
        steps.append(.cropToSourceIfInfinite)
        return steps
    }

    // MARK: - Pixel readback

    /// RGBA8 (premultiplied, sRGB) bytes of `image`, row 0 = TOP row (Y-down).
    static func rgbaBytes(_ image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return bytes }
        bytes.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(
                data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.setBlendMode(.copy)
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return bytes
    }

    /// Renders a CIImage (finite extent) to RGBA8 bytes, row 0 = top.
    static func ciRGBABytes(_ image: CIImage, rect: CGRect, context: CIContext) -> [UInt8] {
        let w = Int(rect.width), h = Int(rect.height)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        context.render(image, toBitmap: &bytes, rowBytes: w * 4, bounds: rect,
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return bytes
    }

    // MARK: - Export units (VideoExporter private camera/frame compositing)

    static var styleExportUnits: [WebVectorUnit] { styleExportCameraUnits }
}
