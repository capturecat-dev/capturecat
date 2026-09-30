import AppKit
import CoreGraphics
import CoreImage

// Style cluster — CameraStyleMath (Services/CameraStyleMath.swift).
extension WebVectors {
    static var styleCameraUnits: [WebVectorUnit] {
        [
            WebVectorUnit(
                name: "cameraStyleAdjustments",
                notes: "Services/CameraStyleMath.swift — Adjustments.init(settings:), isIdentity, and adjustedImage(_:adjustments:) as ordered CI steps (verbatim oracle, CROSS-CHECKED byte-for-byte against the real adjustedImage on a synthetic frame in an sRGB-working-space CIContext like the exporter's; identity must return the SAME CIImage)",
                build: cameraStyleAdjustmentCases),
            WebVectorUnit(
                name: "cameraStyleShapes",
                notes: "Services/CameraStyleMath.swift — cornerRadius(shape:customRadius:scale:), clipPath(shape:customRadius:rect:scale:) and superellipsePath(in:) element-for-element",
                build: cameraStyleShapeCases),
            WebVectorUnit(
                name: "cameraStyleBorderColor",
                notes: "Services/CameraStyleMath.swift — borderNSColor(_:) converted with usingColorSpace(.sRGB) (what the exporter strokes with)",
                build: cameraStyleBorderColorCases),
            WebVectorUnit(
                name: "cameraStyleRing",
                notes: "Services/CameraStyleMath.swift — ringPadding(for:) + the ringImage(size:shape:customRadius:intensity:scale:) recipe numbers (inline — verbatim oracle, CROSS-CHECKED: nil-ness and bitmap size equal the real ringImage). input.gpuTargets (small cases) = REAL ring bitmap RGBA8, row 0 = top — render-parity targets, not asserted by the TS math gate",
                build: cameraStyleRingCases),
            WebVectorUnit(
                name: "cameraStyleTagRect",
                notes: "Services/CameraStyleMath.swift — tagRect(bubbleRect:pillSize:position:yAxisIsUp:)",
                build: cameraStyleTagRectCases),
            WebVectorUnit(
                name: "cameraStyleTagLayout",
                notes: "Services/CameraStyleMath.swift — REAL tagLayout(settings:bubbleWidth:); the Swift-measured NSAttributedString sizes (private tagFont oracle: NSFont(name:size:) ?? systemFont(.semibold)) are in input.measurements so the TS port can inject them",
                build: cameraStyleTagLayoutCases),
            WebVectorUnit(
                name: "cameraStyleTagBitmap",
                notes: "Services/CameraStyleMath.swift — tagBitmap(settings:bubbleWidth:scale:) non-text numbers (inline — verbatim oracle, CROSS-CHECKED: pill size and bitmap size equal the real tagBitmap); measurements injected as in cameraStyleTagLayout",
                build: cameraStyleTagBitmapCases),
            WebVectorUnit(
                name: "cameraStyleTagTextMetrics",
                notes: "Swift-measured NSAttributedString.size() of representative tag strings in the tag fonts (system semibold = SF Pro, Helvetica, Avenir Next, Menlo, a missing font) + NSFont metrics — targets for the web's text measurement; TS asserts the line-height law height = ascender − descender + leading and the ceil() the layout applies",
                build: cameraStyleTagTextMetricCases),
            WebVectorUnit(
                name: "cameraStyleTagLineHeights",
                notes: "NSAttributedString.size().height of the system SEMIBOLD tag font vs point size, a text-independent integer step function (SF optical sizes; one non-monotone step). Case 0 = the breakpoint table over [7, 300] pt (scan 0.01 pt + bisection to 1e-9); then random sizes and +-1e-6 around breakpoints",
                build: cameraStyleTagLineHeightCases),
        ]
    }

    // MARK: helpers

    /// `tagFont(named:size:)` — CameraStyleMath.swift:298-301 (private).
    static func tagFontOracle(named name: String?, size: CGFloat) -> NSFont {
        if let name, let custom = NSFont(name: name, size: size) { return custom }
        return NSFont.systemFont(ofSize: size, weight: .semibold)
    }

    static let tagStrings: [String] = [
        "Mike Garland", "CaptureCat", "Jo", "i", "W", "🐱 Cat", "山田太郎", "مرحبا بالعالم", "Ünïcødé Ñame",
        "A very long presenter name that will hit the cap", "  padded  ", "\n\tMike\n", "\u{85}NEL\u{85}",
        "\u{FEFF}BOM", "\u{2003}em\u{3000}", "", "   ", "Senior Engineer · Apple", "@capturecat", "123",
    ]
    static let tagFonts: [String?] = [nil, nil, nil, "Helvetica", "Avenir Next", "Menlo-Regular", "NoSuchFont-Bold", "Georgia-Bold"]

    static func trimmedTag(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The (text, font, size) measurements tagLayout / tagBitmap perform, as
    /// Swift measures them (layout: font only; bitmap: font + colour + centred
    /// paragraph — both recorded, the cross-check requires they agree).
    static func tagMeasurements(_ s: ProjectSettings, bubbleWidth: CGFloat) -> [WV] {
        let text = trimmedTag(s.cameraTagText)
        guard !text.isEmpty, bubbleWidth > 8 else { return [] }
        let fontSize = max(8, bubbleWidth * CameraStyleMath.tagFontFraction)
        let subSize = max(7, fontSize * CameraStyleMath.tagSubtextFontScale)
        let sub = trimmedTag(s.cameraTagSubtext)
        var out: [WV] = []
        for (str, size) in [(text, fontSize)] + (sub.isEmpty ? [] : [(sub, subSize)]) {
            let font = tagFontOracle(named: s.cameraTagFontName, size: size)
            let plain = NSAttributedString(string: str, attributes: [.font: font]).size()
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            let styled = NSAttributedString(string: str, attributes: [
                .font: font, .foregroundColor: s.cameraTagTextColor.nsColor, .paragraphStyle: para,
            ]).size()
            if plain != styled { styleOracleFail("cameraStyleTagBitmap: measurement differs with paragraph style for \(str)") }
            out.append(["text": .str(str), "fontName": s.cameraTagFontName.map { WV.str($0) } ?? .null,
                        "fontSize": size.wv, "width": plain.width.wv, "height": plain.height.wv])
        }
        return out
    }

    static func randomTagSettings(_ rng: inout WVRandom) -> ProjectSettings {
        let s = ProjectSettings()
        s.cameraTagText = rng.pick(tagStrings)
        s.cameraTagSubtext = rng.bool(0.5) ? rng.pick(tagStrings) : ""
        s.cameraTagFontName = rng.pick(tagFonts)
        s.cameraTagTextColor = randomCodableColor(&rng, alphaOne: 0.7)
        s.cameraTagBackgroundColor = randomCodableColor(&rng, alphaOne: 0.3)
        s.cameraTagPosition = rng.pick(ProjectSettings.CameraTagPosition.allCases)
        return s
    }

    static func tagSettingsWV(_ s: ProjectSettings) -> WV {
        [
            "cameraTagText": .str(s.cameraTagText), "cameraTagSubtext": .str(s.cameraTagSubtext),
            "cameraTagFontName": s.cameraTagFontName.map { WV.str($0) } ?? .null,
            "cameraTagTextColor": codableColorWV(s.cameraTagTextColor),
            "cameraTagBackgroundColor": codableColorWV(s.cameraTagBackgroundColor),
            "cameraTagPosition": .str(s.cameraTagPosition.rawValue),
        ]
    }

    // MARK: Adjustments

    private static let cameraCheckContext = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        .cacheIntermediates: false,
    ])

    private static func cameraStyleAdjustmentCases() -> [WV] {
        let unit = "cameraStyleAdjustments"
        var rng = WVRandom(seed: unit)
        var cases: [WV] = []
        let frame = syntheticBase(pixelSize: CGSize(width: 24, height: 16))
        let rect = CGRect(x: 0, y: 0, width: 24, height: 16)
        for i in 0..<700 {
            let s = ProjectSettings()
            let neutral = i % 9 == 0
            s.cameraBrightness = neutral || rng.bool(0.4) ? rng.pick([0, -0.0]) : rng.edgy(-1, 1, edges: [1e-12, -1, 1])
            s.cameraContrast = neutral || rng.bool(0.4) ? 1 : rng.edgy(0.5, 1.5, edges: [1.0000000001, 0.5, 1.5])
            s.cameraSaturation = neutral || rng.bool(0.4) ? 1 : rng.edgy(0, 2, edges: [0, 2, 0.9999999])
            s.cameraHue = neutral || rng.bool(0.4) ? rng.pick([0, -0.0]) : rng.edgy(-180, 180, edges: [180, -180, 1e-9])
            s.cameraFilter = neutral ? .none : rng.pick(ProjectSettings.CameraFilterStyle.allCases)
            let a = CameraStyleMath.Adjustments(settings: s)
            let steps = adjustedImageChainOracle(a)
            let real = CameraStyleMath.adjustedImage(frame, adjustments: a)
            if a.isIdentity {
                if real !== frame { styleOracleFail("\(unit): identity did not return the same image (case \(i))") }
            } else {
                let mine = applySteps(steps, to: frame)
                if real.extent != mine.extent
                    || ciRGBABytes(real, rect: rect, context: cameraCheckContext) != ciRGBABytes(mine, rect: rect, context: cameraCheckContext) {
                    styleOracleFail("\(unit): chain diverges case \(i)")
                }
            }
            cases.append(vcase(
                [
                    "settings": [
                        "cameraBrightness": s.cameraBrightness.wv, "cameraContrast": s.cameraContrast.wv,
                        "cameraSaturation": s.cameraSaturation.wv, "cameraHue": s.cameraHue.wv,
                        "cameraFilter": .str(s.cameraFilter.rawValue),
                    ],
                ],
                [
                    "adjustments": [
                        "brightness": a.brightness.wv, "contrast": a.contrast.wv, "saturation": a.saturation.wv,
                        "hue": a.hue.wv, "filter": .str(a.filter.rawValue),
                    ],
                    "isIdentity": a.isIdentity.wv,
                    "steps": stepsWV(steps),
                ]
            ))
        }
        return cases + styleOracleSentinel(unit)
    }

    // MARK: Shapes

    private static func cameraStyleShapeCases() -> [WV] {
        var rng = WVRandom(seed: "cameraStyleShapes")
        var cases: [WV] = []
        for i in 0..<900 {
            let shape = styleShapes[i % styleShapes.count]
            let rect = randomPathRect(&rng, index: i / 4)
            let customRadius = rng.edgy(-10, 300, edges: [0, 12, -1, 1e6], edgeP: 0.2)
            let scale = CGFloat(rng.pick([1, 2, 0.5, 1.3333, 3]))
            let withSuperellipse = shape == .squircle || i % 16 == 1
            cases.append(vcase(
                ["shape": .str(shape.rawValue), "rect": rect.wv, "customRadius": customRadius.wv, "scale": scale.wv,
                 "withSuperellipse": withSuperellipse.wv],
                [
                    "cornerRadius": CameraStyleMath.cornerRadius(shape: shape, customRadius: customRadius, scale: scale).wv,
                    "clipPath": stylePathWV(CameraStyleMath.clipPath(shape: shape, customRadius: customRadius, rect: rect, scale: scale)),
                    "superellipse": withSuperellipse ? stylePathWV(CameraStyleMath.superellipsePath(in: rect)) : .null,
                ]
            ))
        }
        return cases
    }

    // MARK: Border colour

    private static func cameraStyleBorderColorCases() -> [WV] {
        var rng = WVRandom(seed: "cameraStyleBorderColor")
        var cases: [WV] = []
        for i in 0..<200 {
            let s = ProjectSettings()
            s.cameraBorderColor = i % 4 == 0 ? nil : randomCodableColor(&rng, alphaOne: 0.5)
            let c = CameraStyleMath.borderNSColor(s)
            let srgb = c.usingColorSpace(.sRGB) ?? c
            cases.append(vcase(
                ["cameraBorderColor": s.cameraBorderColor.map(codableColorWV) ?? .null],
                ["srgb": ["red": srgb.redComponent.wv, "green": srgb.greenComponent.wv,
                          "blue": srgb.blueComponent.wv, "alpha": srgb.alphaComponent.wv]]
            ))
        }
        return cases
    }

    // MARK: Ring

    struct RingRecipeOracle {
        let level: Double, pad: CGFloat, padded: CGSize, pxW: Int, pxH: Int
        let bubbleRect: CGRect, path: CGPath, sigma: CGFloat, alpha: CGFloat
    }

    /// ringImage recipe numbers — CameraStyleMath.swift:219-279.
    static func ringRecipeOracle(size: CGSize, shape: ProjectSettings.CameraShape, customRadius: Double,
                                 intensity: Double, scale: CGFloat) -> RingRecipeOracle? {
        let level = min(1, max(0, intensity))
        guard level > 0, size.width >= 2, size.height >= 2 else { return nil }
        let pad = CameraStyleMath.ringPadding(for: size)
        let padded = CGSize(width: size.width + 2 * pad, height: size.height + 2 * pad)
        let pxW = Int(ceil(padded.width * scale))
        let pxH = Int(ceil(padded.height * scale))
        guard pxW > 0, pxH > 0 else { return nil }
        let bubbleRect = CGRect(x: pad, y: pad, width: size.width, height: size.height)
        let path = CameraStyleMath.clipPath(shape: shape, customRadius: customRadius, rect: bubbleRect, scale: 1)
        let sigma = pad * CameraStyleMath.ringSigmaFraction * (0.8 + 0.4 * CGFloat(level)) * scale
        let alpha = min(1, 2 * CameraStyleMath.ringPeakAlpha * CGFloat(level))
        return RingRecipeOracle(level: level, pad: pad, padded: padded, pxW: pxW, pxH: pxH,
                                bubbleRect: bubbleRect, path: path, sigma: sigma, alpha: alpha)
    }

    private static func cameraStyleRingCases() -> [WV] {
        let unit = "cameraStyleRing"
        var rng = WVRandom(seed: unit)
        var cases: [WV] = []
        for i in 0..<500 {
            let small = i % 10 == 0
            let size = small
                ? CGSize(width: rng.int(2, 30), height: rng.int(2, 30))
                : CGSize(width: rng.edgy(0, 600, edges: [0, 1.9, 2, 120, -5], edgeP: 0.2),
                         height: rng.edgy(0, 600, edges: [0, 2, 120, 1.99], edgeP: 0.2))
            let shape = rng.pick(styleShapes)
            let customRadius = rng.edgy(0, 80, edges: [0, 12, -3], edgeP: 0.2)
            let intensity = rng.edgy(-0.2, 1.3, edges: [0, 1, 0.5, 2, 1e-9], edgeP: 0.3)
            let scale = CGFloat(small ? rng.pick([1, 2]) : rng.pick([1, 2, 0.5, 3, 1.5]))
            let recipe = ringRecipeOracle(size: size, shape: shape, customRadius: customRadius, intensity: intensity, scale: scale)
            let real = small || size.width * size.height * scale * scale < 250_000
                ? CameraStyleMath.ringImage(size: size, shape: shape, customRadius: customRadius, intensity: intensity, scale: scale)
                : nil
            let checked = small || size.width * size.height * scale * scale < 250_000
            if checked {
                if (real == nil) != (recipe == nil) {
                    styleOracleFail("\(unit): nil-ness diverges case \(i)")
                } else if let real, let recipe, real.width != recipe.pxW || real.height != recipe.pxH {
                    styleOracleFail("\(unit): bitmap size diverges case \(i)")
                }
            }
            var input: [(String, WV)] = [
                ("size", size.wv), ("shape", .str(shape.rawValue)), ("customRadius", customRadius.wv),
                ("intensity", intensity.wv), ("scale", scale.wv),
            ]
            if small, let real {
                input.append(("gpuTargets", ["width": .int(real.width), "height": .int(real.height),
                                             "rgba": pixelsWV(rgbaBytes(real))]))
            }
            cases.append(vcase(
                .obj(input),
                [
                    "ringPadding": CameraStyleMath.ringPadding(for: size).wv,
                    "recipe": recipe.map { r -> WV in
                        [
                            "level": r.level.wv, "pad": r.pad.wv, "padded": r.padded.wv,
                            "pxW": .int(r.pxW), "pxH": .int(r.pxH), "bubbleRect": r.bubbleRect.wv,
                            "path": stylePathWV(r.path), "sigma": r.sigma.wv, "alpha": r.alpha.wv,
                        ]
                    } ?? .null,
                ]
            ))
        }
        return cases + styleOracleSentinel(unit)
    }

    // MARK: Tag

    private static func cameraStyleTagRectCases() -> [WV] {
        var rng = WVRandom(seed: "cameraStyleTagRect")
        var cases: [WV] = []
        for i in 0..<1000 {
            let bubble = i % 11 == 0
                ? CGRect(x: rng.double(-50, 50), y: rng.double(-50, 50), width: rng.double(-300, 300), height: rng.double(-300, 300))
                : rng.rect(origin: -100, 2000, size: 0, 600)
            let pill = CGSize(width: rng.edgy(0, 800, edges: [0], edgeP: 0.05), height: rng.edgy(0, 120, edges: [0], edgeP: 0.05))
            let position = rng.pick(ProjectSettings.CameraTagPosition.allCases)
            let yUp = rng.bool()
            cases.append(vcase(
                ["bubbleRect": bubble.wv, "pillSize": pill.wv, "position": .str(position.rawValue), "yAxisIsUp": yUp.wv],
                ["rect": CameraStyleMath.tagRect(bubbleRect: bubble, pillSize: pill, position: position, yAxisIsUp: yUp).wv]
            ))
        }
        return cases
    }

    private static func randomTagBubbleWidth(_ rng: inout WVRandom) -> CGFloat {
        CGFloat(rng.edgy(0, 600, edges: [8, 8.0000001, 69.56521739130434, 69.5652173913044, 120, 0, -4], edgeP: 0.25))
    }

    private static func cameraStyleTagLayoutCases() -> [WV] {
        var rng = WVRandom(seed: "cameraStyleTagLayout")
        var cases: [WV] = []
        for _ in 0..<700 {
            let s = randomTagSettings(&rng)
            let w = randomTagBubbleWidth(&rng)
            let layout = CameraStyleMath.tagLayout(settings: s, bubbleWidth: w)
            cases.append(vcase(
                ["settings": tagSettingsWV(s), "bubbleWidth": w.wv, "measurements": .arr(tagMeasurements(s, bubbleWidth: w))],
                ["layout": layout.map { l -> WV in
                    ["pillSize": l.pillSize.wv, "fontSize": l.fontSize.wv, "subFontSize": l.subFontSize.wv]
                } ?? .null]
            ))
        }
        return cases + styleOracleSentinel("cameraStyleTagLayout")
    }

    private static func cameraStyleTagBitmapCases() -> [WV] {
        let unit = "cameraStyleTagBitmap"
        var rng = WVRandom(seed: unit)
        var cases: [WV] = []
        for i in 0..<500 {
            let s = randomTagSettings(&rng)
            let w = randomTagBubbleWidth(&rng)
            let scale = CGFloat(rng.pick([1, 2, 1.5, 0.5, 3]))
            // Oracle — CameraStyleMath.swift:365-431 (the numbers; text drawing is AppKit).
            var recipe: WV = .null
            if let layout = CameraStyleMath.tagLayout(settings: s, bubbleWidth: w) {
                let pill = layout.pillSize
                let pxW = Int(ceil(pill.width * scale))
                let pxH = Int(ceil(pill.height * scale))
                if pxW > 0, pxH > 0 {
                    let radius = pill.height / 2
                    let bg = s.cameraTagBackgroundColor.nsColor.usingColorSpace(.sRGB) ?? .black
                    let textColor = s.cameraTagTextColor.nsColor
                    let para = NSMutableParagraphStyle()
                    para.alignment = .center
                    let text = trimmedTag(s.cameraTagText)
                    let sub = trimmedTag(s.cameraTagSubtext)
                    let mainLine = NSAttributedString(string: text, attributes: [
                        .font: tagFontOracle(named: s.cameraTagFontName, size: layout.fontSize),
                        .foregroundColor: textColor, .paragraphStyle: para,
                    ])
                    let subLine: NSAttributedString? = sub.isEmpty ? nil : NSAttributedString(string: sub, attributes: [
                        .font: tagFontOracle(named: s.cameraTagFontName, size: layout.subFontSize),
                        .foregroundColor: textColor.withAlphaComponent(textColor.alphaComponent * 0.75),
                        .paragraphStyle: para,
                    ])
                    let mainH = ceil(mainLine.size().height)
                    let subH = subLine.map { ceil($0.size().height) } ?? 0
                    let totalH = mainH + subH
                    let topY = (pill.height + totalH) / 2
                    let inset = layout.fontSize * 0.3
                    let subColor = textColor.withAlphaComponent(textColor.alphaComponent * 0.75).usingColorSpace(.sRGB) ?? textColor
                    let tc = textColor.usingColorSpace(.sRGB) ?? textColor
                    recipe = [
                        "layout": ["pillSize": pill.wv, "fontSize": layout.fontSize.wv, "subFontSize": layout.subFontSize.wv],
                        "pxW": .int(pxW), "pxH": .int(pxH), "radius": radius.wv,
                        "pillPath": stylePathWV(CGPath(roundedRect: CGRect(origin: .zero, size: pill), cornerWidth: radius, cornerHeight: radius, transform: nil)),
                        "background": ["red": bg.redComponent.wv, "green": bg.greenComponent.wv, "blue": bg.blueComponent.wv, "alpha": bg.alphaComponent.wv],
                        "textColor": ["red": tc.redComponent.wv, "green": tc.greenComponent.wv, "blue": tc.blueComponent.wv, "alpha": tc.alphaComponent.wv],
                        "subTextColor": ["red": subColor.redComponent.wv, "green": subColor.greenComponent.wv, "blue": subColor.blueComponent.wv, "alpha": subColor.alphaComponent.wv],
                        "mainH": mainH.wv, "subH": subH.wv, "topY": topY.wv, "inset": inset.wv,
                        "mainRect": CGRect(x: inset, y: topY - mainH, width: pill.width - 2 * inset, height: mainH).wv,
                        "subRect": subLine == nil ? .null : CGRect(x: inset, y: topY - mainH - subH, width: pill.width - 2 * inset, height: subH).wv,
                    ]
                    // Cross-check against the real bitmap.
                    if pxW * pxH < 400_000 {
                        if let built = CameraStyleMath.tagBitmap(settings: s, bubbleWidth: w, scale: scale) {
                            if built.pillSize != pill || built.image.width != pxW || built.image.height != pxH {
                                styleOracleFail("\(unit): pill/bitmap size diverges case \(i)")
                            }
                        } else {
                            styleOracleFail("\(unit): real tagBitmap nil case \(i)")
                        }
                    }
                }
            } else if CameraStyleMath.tagBitmap(settings: s, bubbleWidth: w, scale: scale) != nil {
                styleOracleFail("\(unit): real tagBitmap non-nil without a layout case \(i)")
            }
            cases.append(vcase(
                ["settings": tagSettingsWV(s), "bubbleWidth": w.wv, "scale": scale.wv,
                 "measurements": .arr(tagMeasurements(s, bubbleWidth: w))],
                ["recipe": recipe]
            ))
        }
        return cases + styleOracleSentinel(unit)
    }

    /// Recorded Swift measurements (input side: data for the web text
    /// layer); the output holds what the TS port derives from them: the ceil()
    /// the tag layout applies and, for the system font, the line height from
    /// the cameraStyleTagLineHeights breakpoint table.
    private static func cameraStyleTagTextMetricCases() -> [WV] {
        var cases: [WV] = []
        let sizes: [CGFloat] = [8, 9.5, 11.5, 13.8, 16, 24, 36.5, 69]
        let fonts: [String?] = [nil, "Helvetica", "Avenir Next", "Menlo-Regular", "NoSuchFont-Bold", "Georgia-Bold"]
        let strings = tagStrings.filter { str in !trimmedTag(str).isEmpty }.map(trimmedTag)
        let systemName = NSFont.systemFont(ofSize: 12, weight: .semibold).fontName
        for font in fonts {
            for size in sizes {
                for str in strings {
                    let f = tagFontOracle(named: font, size: size)
                    let sz = NSAttributedString(string: str, attributes: [.font: f]).size()
                    cases.append(vcase(
                        [
                            "text": .str(str), "fontName": font.map { name in WV.str(name) } ?? .null, "fontSize": size.wv,
                            "resolvedFontName": .str(f.fontName), "isSystemFont": (f.fontName == systemName).wv,
                            "width": sz.width.wv, "height": sz.height.wv,
                            "ascender": f.ascender.wv, "descender": f.descender.wv, "leading": f.leading.wv,
                            "capHeight": f.capHeight.wv, "xHeight": f.xHeight.wv,
                            "defaultLineHeight": NSLayoutManager().defaultLineHeight(for: f).wv,
                        ],
                        [
                            "ceilWidth": ceil(sz.width).wv, "ceilHeight": ceil(sz.height).wv,
                            "systemLineHeight": f.fontName == systemName ? sz.height.wv : .null,
                        ]
                    ))
                }
            }
        }
        return cases
    }

    /// Line height of the system SEMIBOLD tag font (SF Pro, optical sizes):
    /// a text-independent integer step function of the point size with one
    /// non-monotone step (the Text/Display optical switch near 21 pt).
    static func systemTagLineHeight(_ size: CGFloat) -> CGFloat {
        let f = NSFont.systemFont(ofSize: size, weight: .semibold)
        return NSAttributedString(string: "Mike", attributes: [.font: f]).size().height
    }

    /// Breakpoints (start size, height) over [7, 300]: scan at 0.01 pt, then
    /// bisect every change to 1e-9 pt.
    static func systemTagLineHeightTable() -> [(size: CGFloat, height: CGFloat)] {
        var table: [(size: CGFloat, height: CGFloat)] = [(7, systemTagLineHeight(7))]
        var prevSize: CGFloat = 7
        var prev = table[0].height
        var k = 1
        while true {
            let s = 7 + CGFloat(k) * 0.01
            if s > 300 { break }
            let v = systemTagLineHeight(s)
            if v != prev {
                var lo = prevSize, hi = s
                for _ in 0..<60 where hi - lo > 1e-9 {
                    let mid = (lo + hi) / 2
                    if systemTagLineHeight(mid) == prev { lo = mid } else { hi = mid }
                }
                table.append((hi, systemTagLineHeight(hi)))
                prev = v
            }
            prevSize = s
            k += 1
        }
        return table
    }

    private static func cameraStyleTagLineHeightCases() -> [WV] {
        var rng = WVRandom(seed: "cameraStyleTagLineHeights")
        let table = systemTagLineHeightTable()
        var cases: [WV] = [vcase(["table": true], ["table": .arr(table.map { e in ["size": e.size.wv, "height": e.height.wv] })])]
        var queries: [CGFloat] = (0..<2500).map { _ in CGFloat(rng.double(7, 300)) }
        for e in table.dropFirst() where rng.bool(0.5) {
            queries.append(e.size + 1e-6)
            queries.append(e.size - 1e-6)
        }
        for q in queries {
            cases.append(vcase(["fontSize": q.wv], ["height": systemTagLineHeight(q).wv]))
        }
        return cases
    }
}
