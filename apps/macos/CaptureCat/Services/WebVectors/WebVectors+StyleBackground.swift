import AppKit
import CoreGraphics
import CoreImage

// Style cluster — backgrounds: BackgroundLook, OklabGradient,
// BackgroundGradientRenderer, WallpaperCatalog (pure name rules).
extension WebVectors {
    static var styleBackgroundUnits: [WebVectorUnit] {
        [
            WebVectorUnit(
                name: "oklabGradient",
                notes: "Services/OklabGradient.swift — SRGBA, linearize, encode, oklab, srgb, mix, sample, and the 257-stop table gradient(stops:) builds (its inline loop: locations i/resolution, colors sample(stops, at:))",
                build: oklabGradientCases),
            WebVectorUnit(
                name: "backgroundGradientAxis",
                notes: "Services/BackgroundGradientRenderer.swift — draw(in:rect:start:end:axis:) gradient-line endpoints (verbatim oracle of the inline switch, CROSS-CHECKED by rendering real draw() vs drawLinearGradient with the oracle points) + image(start:end:size:axis:scale:) bitmap size; BackgroundLook.gradientAxis(_:)",
                build: backgroundGradientAxisCases),
            WebVectorUnit(
                name: "backgroundLookSpec",
                notes: "Services/BackgroundLook.swift — Spec.init(settings), isPlainLook, isPlainLookExceptNoise, gradientAxis, blurSigma, pixelateScale, halftoneWidth, the cgImage(for:size:scale:) branch + pixel size, and styled(base:spec:pixelSize:) as ordered CI steps (verbatim oracle, CROSS-CHECKED byte-for-byte against the real styled() on a synthetic base for every case up to 160k px)",
                build: backgroundLookSpecCases),
            WebVectorUnit(
                name: "backgroundMeshPools",
                notes: "Services/BackgroundLook.swift meshImage(start:end:pixelSize:) pool list (private — verbatim oracle, CROSS-CHECKED: the oracle-driven render equals the real BackgroundLook.cgImage mesh bitmap byte-for-byte)",
                build: backgroundMeshPoolCases),
            WebVectorUnit(
                name: "backgroundGrain",
                notes: "Services/BackgroundLook.swift noiseRows(width:height:cell:) + grained(_:amount:scale:) per-pixel delta (private — verbatim oracle, CROSS-CHECKED: base bitmap + oracle grain equals the real cgImage output byte-for-byte)",
                build: backgroundGrainCases),
            WebVectorUnit(
                name: "backgroundLookPixels",
                notes: "Services/BackgroundLook.swift cgImage(for:size:scale:) — REAL rendered RGBA8 bitmaps (premultiplied sRGB, row 0 = top) of plain and grain-only looks for every background type at small sizes; the TS CPU reference raster (styleSupport.ts) reproduces them within a stated quantisation tolerance",
                build: backgroundLookPixelCases),
            WebVectorUnit(
                name: "backgroundLookStyledPixels",
                notes: "Services/BackgroundLook.swift cgImage(for:size:scale:) with CoreImage looks (pixelate/halftone/blur/color controls/hue/tint/vignette). Output = the ordered CI steps (asserted). input.gpuTargets = REAL rendered RGBA8 samples: render-parity targets for the WebGPU passes (not asserted by the TS math gate — there is no CPU CoreImage)",
                build: backgroundLookStyledPixelCases),
            WebVectorUnit(
                name: "backgroundAspectFill",
                notes: "Services/BackgroundLook.swift aspectFill(_:pixelSize:) draw rect (private — verbatim oracle) for image/wallpaper backgrounds",
                build: backgroundAspectFillCases),
            WebVectorUnit(
                name: "wallpaperCatalogNames",
                notes: "Services/WallpaperCatalog.swift — baseName(strippingVariant:) and the listItems() name filter (calibration targets skipped, Dark/Light variants hidden when the base exists) over an already-sorted thumbnail list; cache file name \"<name>.heic\" (private — verbatim oracle; the filesystem listing and localizedStandardCompare sort are NOT ported)",
                build: wallpaperCatalogCases),
        ]
    }

    // MARK: helpers

    // srgbaWV(_:) lives in WebVectors+Regions.swift (identical encoding).

    static func codableColorWV(_ c: CodableColor) -> WV {
        ["red": c.red.wv, "green": c.green.wv, "blue": c.blue.wv, "opacity": c.opacity.wv]
    }

    static func randomSRGBA(_ rng: inout WVRandom, alphaOne p: Double = 0.8) -> SRGBA {
        SRGBA(red: rng.cg(0, 1), green: rng.cg(0, 1), blue: rng.cg(0, 1), alpha: rng.bool(p) ? 1 : rng.cg(0, 1))
    }

    static func randomCodableColor(_ rng: inout WVRandom, alphaOne p: Double = 0.85) -> CodableColor {
        let edges: [Double] = [0, 1, 0.5]
        return CodableColor(
            red: rng.edgy(0, 1, edges: edges, edgeP: 0.15),
            green: rng.edgy(0, 1, edges: edges, edgeP: 0.15),
            blue: rng.edgy(0, 1, edges: edges, edgeP: 0.15),
            opacity: rng.bool(p) ? 1 : rng.edgy(0, 1, edges: [0], edgeP: 0.1))
    }

    static func axisWV(_ a: BackgroundGradientRenderer.Axis) -> WV {
        switch a {
        case .diagonal: return ["kind": "diagonal"]
        case .vertical: return ["kind": "vertical"]
        case .angle(let d): return ["kind": "angle", "degrees": d.wv]
        }
    }

    /// Background look fields of ProjectSettings, EXACT doubles (not via
    /// JSONEncoder, which can move a double by one ulp).
    static func backgroundSettingsWV(_ s: ProjectSettings) -> WV {
        [
            "backgroundType": .str(s.backgroundType.rawValue),
            "gradientStartColor": codableColorWV(s.gradientStartColor),
            "gradientEndColor": codableColorWV(s.gradientEndColor),
            "solidColor": codableColorWV(s.solidColor),
            "backgroundImagePath": s.backgroundImagePath.map { WV.str($0) } ?? .null,
            "gradientAngle": s.gradientAngle.wv,
            "backgroundBlur": s.backgroundBlur.wv,
            "backgroundBrightness": s.backgroundBrightness.wv,
            "backgroundSaturation": s.backgroundSaturation.wv,
            "backgroundTintColor": codableColorWV(s.backgroundTintColor),
            "backgroundTintOpacity": s.backgroundTintOpacity.wv,
            "backgroundVignette": s.backgroundVignette.wv,
            "backgroundPixelate": s.backgroundPixelate.wv,
            "backgroundHalftone": s.backgroundHalftone.wv,
            "backgroundNoise": s.backgroundNoise.wv,
            "backgroundContrast": s.backgroundContrast.wv,
            "backgroundHue": s.backgroundHue.wv,
        ]
    }

    static func specWV(_ spec: BackgroundLook.Spec) -> WV {
        [
            "type": .str(spec.type.rawValue),
            "gradientStart": srgbaWV(spec.gradientStart),
            "gradientEnd": srgbaWV(spec.gradientEnd),
            "gradientAngle": spec.gradientAngle.wv,
            "solid": srgbaWV(spec.solid),
            "imagePath": spec.imagePath.map { WV.str($0) } ?? .null,
            "blur": spec.blur.wv, "brightness": spec.brightness.wv, "saturation": spec.saturation.wv,
            "tint": srgbaWV(spec.tint), "tintOpacity": spec.tintOpacity.wv, "vignette": spec.vignette.wv,
            "pixelate": spec.pixelate.wv, "halftone": spec.halftone.wv, "noise": spec.noise.wv,
            "contrast": spec.contrast.wv, "hue": spec.hue.wv,
        ]
    }

    /// Random background settings. `look`: 0 = plain, 1 = grain only, 2 = any.
    static func randomBackgroundSettings(_ rng: inout WVRandom, look: Int, types: [ProjectSettings.BackgroundType]? = nil) -> ProjectSettings {
        let s = ProjectSettings()
        s.backgroundType = rng.pick(types ?? ProjectSettings.BackgroundType.allCases)
        s.gradientStartColor = randomCodableColor(&rng)
        s.gradientEndColor = randomCodableColor(&rng)
        s.solidColor = randomCodableColor(&rng)
        s.gradientAngle = rng.bool(0.3) ? nil : rng.edgy(-360, 720, edges: [0, 45, 90, 135, 180, 270, 360, -90], edgeP: 0.4)
        // Image paths never resolve in the harness — the image branch falls
        // back (wallpaper placeholder ramp / black), which is what is vectored.
        s.backgroundImagePath = rng.bool(0.5) ? "/nonexistent/capturecat-web-vectors.png" : nil
        s.backgroundTintColor = randomCodableColor(&rng)
        switch look {
        case 0:
            break
        case 1:
            s.backgroundNoise = rng.edgy(0, 1, edges: [1, 0.5, 0.01, 2], edgeP: 0.3)
        default:
            if rng.bool(0.3) { s.backgroundBlur = rng.edgy(0, 1, edges: [1, 0.001, 2, -1], edgeP: 0.2) }
            if rng.bool(0.3) { s.backgroundBrightness = rng.edgy(-1, 1, edges: [0.0004, 0.0005, -0.0005, 0], edgeP: 0.2) }
            if rng.bool(0.3) { s.backgroundSaturation = rng.edgy(0, 2, edges: [1.0004, 1.0005, 0.9995, 1], edgeP: 0.2) }
            if rng.bool(0.3) { s.backgroundContrast = rng.edgy(0.5, 1.5, edges: [1.0005, 0.9996, 1], edgeP: 0.2) }
            if rng.bool(0.3) { s.backgroundHue = rng.edgy(-180, 180, edges: [0.0005, -0.0004, 180, -180], edgeP: 0.2) }
            if rng.bool(0.3) { s.backgroundTintOpacity = rng.edgy(0, 1, edges: [1, 2, -1, 0.0001], edgeP: 0.2) }
            if rng.bool(0.3) { s.backgroundVignette = rng.edgy(0, 1, edges: [1, 2, 0.0001], edgeP: 0.2) }
            if rng.bool(0.25) { s.backgroundPixelate = rng.edgy(0, 1, edges: [1, 0.0001, 2], edgeP: 0.2) }
            if rng.bool(0.25) { s.backgroundHalftone = rng.edgy(0, 1, edges: [1, 0.0001, 2], edgeP: 0.2) }
            if rng.bool(0.3) { s.backgroundNoise = rng.edgy(0, 1, edges: [1, 0.3], edgeP: 0.2) }
        }
        return s
    }

    // MARK: OklabGradient

    private static func oklabGradientCases() -> [WV] {
        var rng = WVRandom(seed: "oklabGradient")
        var cases: [WV] = []
        for i in 0..<1500 {
            let a = i % 50 == 0 ? SRGBA(white: 0, alpha: 0) : randomSRGBA(&rng, alphaOne: 0.6)
            let b = i % 37 == 0 ? SRGBA(white: 1, alpha: 0) : randomSRGBA(&rng, alphaOne: 0.6)
            let t = CGFloat(rng.edgy(-0.2, 1.2, edges: [0, 1, 0.5, 0.25, 1e-9], edgeP: 0.2))
            let c = CGFloat(rng.edgy(-0.2, 1.2, edges: [0, 1, 0.04045, 0.0031308, 0.04046, 0.0031309], edgeP: 0.3))
            // Sorted stop list (0–4 stops), occasionally with coincident locations.
            let n = i % 11 == 0 ? rng.int(0, 1) : rng.int(2, 4)
            var locs = (0..<n).map { _ in CGFloat(rng.edgy(0, 1, edges: [0, 1, 0.5], edgeP: 0.3)) }.sorted()
            if n >= 3, rng.bool(0.1) { locs[1] = locs[2] }
            let stops: [(location: CGFloat, color: SRGBA)] = locs.map { ($0, randomSRGBA(&rng, alphaOne: 0.7)) }
            let st = CGFloat(rng.edgy(-0.1, 1.1, edges: locs.map { Double($0) } + [0, 1], edgeP: 0.3))
            let lab = OklabGradient.oklab(a)
            let labIn = (CGFloat(rng.double(0, 1)), CGFloat(rng.double(-0.4, 0.4)), CGFloat(rng.double(-0.4, 0.4)))
            var outCase: [(String, WV)] = [
                ("linearize", OklabGradient.linearize(c).wv),
                ("encode", OklabGradient.encode(c).wv),
                ("oklab", [lab.0.wv, lab.1.wv, lab.2.wv]),
                ("srgb", srgbaWV(OklabGradient.srgb(labIn))),
                ("mix", srgbaWV(OklabGradient.mix(a, b, t))),
                ("sample", srgbaWV(OklabGradient.sample(stops, at: st))),
            ]
            // The full stop table for a subset (it is 257 colours).
            let wantTable = i % 15 == 0 && stops.count >= 2
            if wantTable {
                outCase.append(("table", .arr((0...OklabGradient.resolution).map { k in
                    let tt = CGFloat(k) / CGFloat(OklabGradient.resolution)
                    return ["location": tt.wv, "color": srgbaWV(OklabGradient.sample(stops, at: tt))]
                })))
            }
            cases.append(vcase(
                [
                    "a": srgbaWV(a), "b": srgbaWV(b), "t": t.wv, "c": c.wv,
                    "stops": .arr(stops.map { ["location": $0.location.wv, "color": srgbaWV($0.color)] }),
                    "sampleT": st.wv,
                    "lab": [labIn.0.wv, labIn.1.wv, labIn.2.wv],
                    "wantTable": wantTable.wv,
                ],
                .obj(outCase)
            ))
        }
        return cases
    }

    // MARK: BackgroundGradientRenderer

    private static func backgroundGradientAxisCases() -> [WV] {
        let unit = "backgroundGradientAxis"
        var rng = WVRandom(seed: unit)
        var cases: [WV] = []
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return [] }
        for i in 0..<1200 {
            let rect: CGRect
            switch i % 9 {
            case 0: rect = CGRect(x: rng.double(-20, 20), y: rng.double(-20, 20), width: rng.edgy(-50, 50, edges: [0]), height: rng.edgy(-50, 50, edges: [0]))
            case 1: rect = CGRect(x: 0, y: 0, width: rng.int(1, 40), height: rng.int(1, 40))
            default: rect = rng.rect(origin: -500, 500, size: 0.5, 4000)
            }
            let axis: BackgroundGradientRenderer.Axis
            switch rng.int(0, 5) {
            case 0: axis = .diagonal
            case 1: axis = .vertical
            default: axis = .angle(rng.edgy(-720, 720, edges: [0, 90, 180, 270, 45, -45, 360, 135, 1e-12], edgeP: 0.35))
            }
            let pts = gradientDrawPointsOracle(rect: rect, axis: axis)

            // Cross-check on small integral rects: real draw() == oracle points.
            if let pts, i % 9 == 1 {
                let w = Int(rect.width), h = Int(rect.height)
                let a = randomSRGBA(&rng, alphaOne: 1), b = randomSRGBA(&rng, alphaOne: 1)
                func ctx() -> CGContext? {
                    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
                }
                if let real = ctx(), let mine = ctx(), let grad = OklabGradient.gradient(from: a, to: b) {
                    BackgroundGradientRenderer.draw(in: real, rect: rect, start: a, end: b, axis: axis)
                    mine.drawLinearGradient(grad, start: pts.p0, end: pts.p1, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                    if let ri = real.makeImage(), let mi = mine.makeImage(), rgbaBytes(ri) != rgbaBytes(mi) {
                        styleOracleFail("\(unit): draw() points diverge for rect \(rect) axis \(axis)")
                    }
                }
            }

            let size = CGSize(width: rng.edgy(0, 300, edges: [0, 0.4, 0.5, 1.5, 2.5], edgeP: 0.2),
                              height: rng.edgy(0, 300, edges: [0, 0.4, 0.5, 1.5], edgeP: 0.2))
            let scale = CGFloat(rng.pick([1, 2, 1.5, 3, 0.5, 0.25]))
            let img = BackgroundGradientRenderer.image(start: SRGBA(white: 0.2), end: SRGBA(white: 0.8), size: size, axis: axis, scale: scale)
            let s = ProjectSettings()
            s.gradientAngle = rng.bool(0.3) ? nil : rng.double(-400, 400)
            let specAxis = BackgroundLook.gradientAxis(BackgroundLook.Spec(s))
            cases.append(vcase(
                [
                    "rect": rect.wv, "axis": axisWV(axis), "size": size.wv, "scale": scale.wv,
                    "gradientAngle": s.gradientAngle.wv,
                ],
                [
                    "points": pts.map { ["p0": $0.p0.wv, "p1": $0.p1.wv] as WV } ?? .null,
                    "imageSize": img.map { ["width": .int($0.width), "height": .int($0.height)] as WV } ?? .null,
                    "specAxis": axisWV(specAxis),
                ]
            ))
        }
        return cases + styleOracleSentinel(unit)
    }

    // MARK: BackgroundLook spec + styled chain

    private static let styleCheckContext = CIContext(options: [
        .cacheIntermediates: false,
        .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    ])

    /// Deterministic synthetic base for the chain cross-check (a hard-edged
    /// colour pattern so every filter has something to act on).
    static func syntheticBase(pixelSize: CGSize) -> CIImage {
        let w = Int(pixelSize.width), h = Int(pixelSize.height)
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let p = (y * w + x) * 4
                bytes[p] = UInt8((x * 37 + y * 11) & 0xFF)
                bytes[p + 1] = UInt8((x * 5 + y * 23) & 0xFF)
                bytes[p + 2] = ((x / 7 + y / 5) % 2 == 0) ? 230 : 20
            }
        }
        let data = Data(bytes)
        let img = CIImage(bitmapData: data, bytesPerRow: w * 4, size: pixelSize, format: .RGBA8,
                          colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return img
    }

    private static func backgroundLookSpecCases() -> [WV] {
        let unit = "backgroundLookSpec"
        var rng = WVRandom(seed: unit)
        var cases: [WV] = []
        var checked = 0
        for i in 0..<1200 {
            let s = randomBackgroundSettings(&rng, look: i % 5 == 0 ? rng.int(0, 1) : 2)
            let size: CGSize
            switch i % 6 {
            case 0: size = CGSize(width: rng.edgy(0, 3, edges: [0, 0.4, 0.5, 1]), height: rng.edgy(0, 3, edges: [0, 0.5, 1]))
            case 1: size = CGSize(width: 1920, height: 1080)
            case 2: size = CGSize(width: rng.double(100, 4000), height: rng.double(100, 3000))
            default: size = CGSize(width: rng.int(8, 400), height: rng.int(8, 400))
            }
            let scale = CGFloat(rng.pick([1, 2, 1, 1.5, 3]))
            let spec = BackgroundLook.Spec(s)
            let pixelSize = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
            let steps = pixelSize.width > 0 && pixelSize.height > 0 ? styledChainOracle(spec: spec, pixelSize: pixelSize) : []

            // Cross-check the chain oracle against the REAL styled().
            if pixelSize.width > 0, pixelSize.height > 0, pixelSize.width * pixelSize.height <= 160_000 {
                let base = syntheticBase(pixelSize: pixelSize)
                let rect = CGRect(origin: .zero, size: pixelSize)
                let real = BackgroundLook.styled(base: base, spec: spec, pixelSize: pixelSize)
                let mine = applySteps(steps, to: base)
                if real.extent != mine.extent
                    || ciRGBABytes(real, rect: rect, context: styleCheckContext) != ciRGBABytes(mine, rect: rect, context: styleCheckContext) {
                    styleOracleFail("\(unit): styled chain diverges for case \(i)")
                }
                checked += 1
            }

            // The real cgImage() only for small canvases (it renders).
            var realNil: WV = .null
            if pixelSize.width * pixelSize.height <= 40_000 {
                realNil = .bool(BackgroundLook.cgImage(for: spec, size: size, scale: scale) == nil)
            }
            let path = backgroundRenderPathOracle(spec, size: size, scale: scale)
            if case .bool(let isNil) = realNil, isNil != (path == "nil") {
                styleOracleFail("\(unit): render path \(path) vs real nil=\(isNil) case \(i)")
            }
            cases.append(vcase(
                ["settings": backgroundSettingsWV(s), "size": size.wv, "scale": scale.wv],
                [
                    "spec": specWV(spec),
                    "isPlainLook": spec.isPlainLook.wv,
                    "isPlainLookExceptNoise": spec.isPlainLookExceptNoise.wv,
                    "gradientAxis": axisWV(BackgroundLook.gradientAxis(spec)),
                    "pixelSize": pixelSize.wv,
                    "blurSigma": BackgroundLook.blurSigma(spec.blur, pixelSize: pixelSize).wv,
                    "pixelateScale": BackgroundLook.pixelateScale(spec.pixelate, pixelSize: pixelSize).wv,
                    "halftoneWidth": BackgroundLook.halftoneWidth(spec.halftone, pixelSize: pixelSize).wv,
                    "renderPath": .str(path),
                    "styledSteps": stepsWV(steps),
                    "realIsNil": realNil,
                ]
            ))
        }
        print("WEB-VECTORS note: \(unit) chain cross-checked on \(checked) cases")
        return cases + styleOracleSentinel(unit)
    }

    // MARK: Mesh pools

    private static func backgroundMeshPoolCases() -> [WV] {
        let unit = "backgroundMeshPools"
        var rng = WVRandom(seed: unit)
        var cases: [WV] = []
        for i in 0..<400 {
            let start = randomSRGBA(&rng, alphaOne: 0.8)
            let end = randomSRGBA(&rng, alphaOne: 0.8)
            let pixelSize = i % 3 == 0
                ? CGSize(width: rng.int(1, 64), height: rng.int(1, 64))
                : CGSize(width: rng.int(1, 4000), height: rng.int(1, 3000))
            let pools = meshPoolsOracle(start: start, end: end, pixelSize: pixelSize)
            if i % 3 == 0 {
                // Cross-check: real mesh bitmap == oracle-driven render.
                let s = ProjectSettings()
                s.backgroundType = .mesh
                s.gradientStartColor = CodableColor(red: Double(start.red), green: Double(start.green), blue: Double(start.blue), opacity: Double(start.alpha))
                s.gradientEndColor = CodableColor(red: Double(end.red), green: Double(end.green), blue: Double(end.blue), opacity: Double(end.alpha))
                if let real = BackgroundLook.cgImage(for: BackgroundLook.Spec(s), size: pixelSize, scale: 1),
                   let mine = meshImageFromOracle(start: start, end: end, pixelSize: pixelSize) {
                    if rgbaBytes(real) != rgbaBytes(mine) { styleOracleFail("\(unit): mesh render diverges case \(i)") }
                } else {
                    styleOracleFail("\(unit): mesh image nil case \(i)")
                }
            }
            cases.append(vcase(
                ["start": srgbaWV(start), "end": srgbaWV(end), "pixelSize": pixelSize.wv],
                ["pools": .arr(pools.map { p in
                    [
                        "center": p.center.wv, "radius": p.radius.wv, "color": srgbaWV(p.color),
                        "stops": .arr(p.stops.map { ["location": $0.0.wv, "alpha": $0.1.wv] as WV }),
                    ]
                })]
            ))
        }
        return cases + styleOracleSentinel(unit)
    }

    // MARK: Grain

    private static func backgroundGrainCases() -> [WV] {
        let unit = "backgroundGrain"
        var rng = WVRandom(seed: unit)
        var cases: [WV] = []
        for i in 0..<300 {
            let w = i % 10 == 0 ? rng.int(1, 3) : rng.int(1, 48)
            let h = i % 10 == 0 ? rng.int(1, 3) : rng.int(1, 40)
            let cell = rng.pick([1, 1, 2, 3, 4, 7])
            let rows = noiseRowsOracle(width: w, height: h, cell: cell)
            let amount = rng.edgy(0, 1, edges: [0, 1, 2, -1, 0.5, 0.001], edgeP: 0.3)
            let amplitude = Float(max(0, min(1, amount)) * 14.5)
            let deltas: [[Int]] = rows.map { $0.map { Int($0 * amplitude) } }

            // Cross-check vs the real pipeline: solid (exact base) + noise.
            if i % 2 == 0 {
                let s = ProjectSettings()
                s.backgroundType = .solid
                s.solidColor = CodableColor(red: rng.double(0, 1), green: rng.double(0, 1), blue: rng.double(0, 1))
                s.backgroundNoise = max(0.0001, amount)
                let scale = CGFloat(cell)
                let size = CGSize(width: CGFloat(w) / scale, height: CGFloat(h) / scale)
                let spec = BackgroundLook.Spec(s)
                let s0 = ProjectSettings()
                s0.backgroundType = .solid
                s0.solidColor = s.solidColor
                if let real = BackgroundLook.cgImage(for: spec, size: size, scale: scale),
                   let base = BackgroundLook.cgImage(for: BackgroundLook.Spec(s0), size: size, scale: scale) {
                    let predicted = grainedOracle(rgba: rgbaBytes(base), width: base.width, height: base.height,
                                                  amount: s.backgroundNoise, scale: scale)
                    if predicted != rgbaBytes(real) { styleOracleFail("\(unit): grain diverges case \(i)") }
                } else {
                    styleOracleFail("\(unit): grain image nil case \(i)")
                }
            }
            cases.append(vcase(
                ["width": .int(w), "height": .int(h), "cell": .int(cell), "amount": amount.wv],
                [
                    "rows": .arr(rows.map { .arr($0.map { WV.num(Double($0)) }) }),
                    "amplitude": .num(Double(amplitude)),
                    "deltas": .arr(deltas.map { .arr($0.map { WV.int($0) }) }),
                ]
            ))
        }
        return cases + styleOracleSentinel(unit)
    }

    // MARK: Real pixels

    static func pixelsWV(_ bytes: [UInt8]) -> WV {
        .arr(bytes.map { .int(Int($0)) })
    }

    private static func backgroundLookPixelCases() -> [WV] {
        var rng = WVRandom(seed: "backgroundLookPixels")
        var cases: [WV] = []
        let types = ProjectSettings.BackgroundType.allCases
        for i in 0..<240 {
            let s = randomBackgroundSettings(&rng, look: (i / types.count) % 3 == 0 ? 1 : 0, types: [types[i % types.count]])
            let scale = CGFloat(rng.pick([1, 1, 2, 3, 1.5]))
            let size = CGSize(width: CGFloat(rng.int(1, 40)) / scale, height: CGFloat(rng.int(1, 32)) / scale)
            let spec = BackgroundLook.Spec(s)
            let img = BackgroundLook.cgImage(for: spec, size: size, scale: scale)
            cases.append(vcase(
                ["settings": backgroundSettingsWV(s), "size": size.wv, "scale": scale.wv],
                img.map { im -> WV in
                    ["width": .int(im.width), "height": .int(im.height), "rgba": pixelsWV(rgbaBytes(im))]
                } ?? .null
            ))
        }
        return cases
    }

    private static func backgroundLookStyledPixelCases() -> [WV] {
        var rng = WVRandom(seed: "backgroundLookStyledPixels")
        var cases: [WV] = []
        for i in 0..<80 {
            let s = randomBackgroundSettings(&rng, look: 2, types: [.gradient, .solid, .mesh, .wallpaper])
            // Make sure the CI branch runs.
            if BackgroundLook.Spec(s).isPlainLookExceptNoise { s.backgroundVignette = rng.double(0.1, 1) }
            let scale = CGFloat(rng.pick([1, 2]))
            let size = CGSize(width: CGFloat(rng.int(16, 96)) / scale, height: CGFloat(rng.int(12, 72)) / scale)
            let spec = BackgroundLook.Spec(s)
            let pixelSize = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
            guard let img = BackgroundLook.cgImage(for: spec, size: size, scale: scale) else { continue }
            let bytes = rgbaBytes(img)
            // Sample a fixed 9×7 lattice (Y-down pixel coordinates).
            var samples: [WV] = []
            for sy in 0..<7 {
                for sx in 0..<9 {
                    let x = min(img.width - 1, sx * (img.width - 1) / 8)
                    let y = min(img.height - 1, sy * (img.height - 1) / 6)
                    let p = (y * img.width + x) * 4
                    samples.append(["x": .int(x), "y": .int(y),
                                    "rgba": [.int(Int(bytes[p])), .int(Int(bytes[p + 1])), .int(Int(bytes[p + 2])), .int(Int(bytes[p + 3]))]])
                }
            }
            _ = i
            cases.append(vcase(
                [
                    "settings": backgroundSettingsWV(s), "size": size.wv, "scale": scale.wv,
                    "gpuTargets": ["width": .int(img.width), "height": .int(img.height), "samples": .arr(samples)],
                ],
                ["pixelSize": pixelSize.wv, "styledSteps": stepsWV(styledChainOracle(spec: spec, pixelSize: pixelSize))]
            ))
        }
        return cases
    }

    // MARK: Aspect fill

    private static func backgroundAspectFillCases() -> [WV] {
        var rng = WVRandom(seed: "backgroundAspectFill")
        var cases: [WV] = []
        for _ in 0..<800 {
            let sw = rng.int(1, 6000), sh = rng.int(1, 6000)
            let pixelSize = CGSize(width: rng.int(1, 4000), height: rng.int(1, 3000))
            cases.append(vcase(
                ["sourceWidth": .int(sw), "sourceHeight": .int(sh), "pixelSize": pixelSize.wv],
                ["rect": aspectFillRectOracle(sourceWidth: sw, sourceHeight: sh, pixelSize: pixelSize).wv]
            ))
        }
        return cases
    }

    // MARK: WallpaperCatalog

    /// `baseName(strippingVariant:)` — WallpaperCatalog.swift:65-70.
    static func wallpaperBaseNameOracle(_ name: String) -> String? {
        for suffix in [" Dark", " Light"] where name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return nil
    }

    /// The name filter of `listItems()` — WallpaperCatalog.swift:39-50, over
    /// an already-sorted list of thumbnail base names.
    static func wallpaperListedNamesOracle(_ sortedNames: [String]) -> [String] {
        let names = Set(sortedNames)
        var out: [String] = []
        for name in sortedNames {
            if name.lowercased().hasPrefix("calibrate") { continue }
            if let base = wallpaperBaseNameOracle(name), names.contains(base) { continue }
            out.append(name)
        }
        return out
    }

    private static func wallpaperCatalogCases() -> [WV] {
        var rng = WVRandom(seed: "wallpaperCatalogNames")
        let bases = ["Sonoma", "Sequoia", "Ventura", "Monterey", "Big Sur", "Tahoe", "Macintosh", "Radial Sky Blue",
                     "Calibrate", "calibrate-rgb", "CalibrateGamma", "Dark", "Light", " Dark", "Sonoma Horizon",
                     "Sonoma Clouds", "Moon", "Sky Dark", "Él Dark", "Ünïcødé"]
        var cases: [WV] = []
        for i in 0..<500 {
            let n = i % 40 == 0 ? 0 : rng.int(1, 10)
            var names: [String] = []
            for _ in 0..<n {
                var name = rng.pick(bases)
                switch rng.int(0, 5) {
                case 0: name += " Dark"
                case 1: name += " Light"
                case 2: name += rng.pick([" dark", " Dark Dark", "Dark", " Light "])
                default: break
                }
                names.append(name)
            }
            let sorted = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            cases.append(vcase(
                ["sortedNames": sorted.wv],
                [
                    "baseNames": .arr(sorted.map { wallpaperBaseNameOracle($0).map { WV.str($0) } ?? .null }),
                    "listed": wallpaperListedNamesOracle(sorted).wv,
                    "cacheFileNames": sorted.map { "\($0).heic" }.wv,
                ]
            ))
        }
        return cases
    }
}
