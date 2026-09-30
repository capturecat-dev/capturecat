import AppKit
import CoreGraphics

// VERBATIM ORACLE of the exporter's subtitle burn — Services/VideoExporter.swift
// at commit da569841c7b63175bffa46d897457f157224774d:
//   • export(): canvasScale (lines 336–342) and the active-subtitle lookup
//     (lines 1798–1801);
//   • private renderSubtitle(subtitle:at:onto:outputSize:canvasScale:settings:)
//     (lines 3661–3857) — every number up to the CG/CI calls, recorded as a
//     recipe instead of drawn;
//   • private subtitleDropShadow(source:extent:radius:color:) (3862–3885) —
//     its parameters (radius, silhouette colour).
// The text measurement (NSAttributedString.boundingRect) is the REAL AppKit
// call; its result is an INPUT to the TS port (the web measures itself).
enum ExportSubtitleOracle {
    /// Verbatim VideoExporter.swift 336–342.
    static func canvasScale(outputSize: CGSize, previewCanvasSize: CGSize) -> CGFloat {
        let referenceCanvas: CGSize = {
            let previewSize = previewCanvasSize
            guard previewSize.width > 0, previewSize.height > 0 else { return outputSize }
            return previewSize
        }()
        return min(outputSize.width / referenceCanvas.width,
                   outputSize.height / referenceCanvas.height)
    }

    /// Verbatim VideoExporter.swift 1798–1801 (inside `if settings.showSubtitles`).
    static func activeSubtitle(_ subtitles: [SubtitleSegment], at currentTime: TimeInterval,
                               showSubtitles: Bool) -> SubtitleSegment? {
        guard showSubtitles else { return nil }
        return subtitles.first { sub in
            currentTime >= sub.startTime && currentTime <= sub.endTime
        }
    }

    /// Verbatim VideoExporter.swift 3672–3675 (the overlay cache key).
    static func cacheKey(_ subtitle: SubtitleSegment, at currentTime: TimeInterval,
                         settings: ProjectSettings) -> (key: String, activeWordCount: Int) {
        let activeWordCount = settings.highlightWords && !subtitle.words.isEmpty
            ? subtitle.words.lazy.filter { currentTime >= $0.startTime }.count
            : -1
        return ("\(subtitle.id)|\(activeWordCount)", activeWordCount)
    }

    static func rgba(_ c: NSColor) -> WV {
        ["r": c.redComponent.wv, "g": c.greenComponent.wv, "b": c.blueComponent.wv, "a": c.alphaComponent.wv]
    }

    /// Verbatim VideoExporter.swift 3688–3853 as a recipe.
    static func recipe(
        subtitle: SubtitleSegment,
        at currentTime: TimeInterval,
        outputSize: CGSize,
        canvasScale: CGFloat,
        settings: ProjectSettings
    ) -> WV {
        let fontSize = max(1, settings.subtitleFontSize * canvasScale)
        let font = FontCatalog.font(named: settings.subtitleFontName, size: fontSize, weight: settings.subtitleWeight.nsWeight)
        let transform: (String) -> String = settings.subtitleUppercase ? { $0.uppercased() } : { $0 }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        let textColor = NSColor(
            red: settings.subtitleColor.red,
            green: settings.subtitleColor.green,
            blue: settings.subtitleColor.blue,
            alpha: settings.subtitleColor.opacity
        )

        var runs: [WV] = []
        let attrString: NSAttributedString
        if settings.highlightWords && !subtitle.words.isEmpty {
            let highlightColor = NSColor(
                red: settings.subtitleHighlightColor.red,
                green: settings.subtitleHighlightColor.green,
                blue: settings.subtitleHighlightColor.blue,
                alpha: settings.subtitleHighlightColor.opacity
            )
            let dimColor = NSColor(
                red: textColor.redComponent,
                green: textColor.greenComponent,
                blue: textColor.blueComponent,
                alpha: textColor.alphaComponent * 0.4
            )
            let spaceAttrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .paragraphStyle: paragraphStyle,
                .foregroundColor: textColor,
            ]
            let mutable = NSMutableAttributedString()
            for (i, word) in subtitle.words.enumerated() {
                if i > 0 {
                    mutable.append(NSAttributedString(string: " ", attributes: spaceAttrs))
                    runs.append(["text": " ", "color": rgba(textColor), "active": .null])
                }
                let isActive = currentTime >= word.startTime
                let wordAttrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .paragraphStyle: paragraphStyle,
                    .foregroundColor: isActive ? highlightColor : dimColor,
                ]
                mutable.append(NSAttributedString(string: transform(word.text), attributes: wordAttrs))
                runs.append(["text": .str(transform(word.text)),
                             "color": rgba(isActive ? highlightColor : dimColor), "active": isActive.wv])
            }
            attrString = mutable
        } else {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .paragraphStyle: paragraphStyle,
                .foregroundColor: textColor,
            ]
            attrString = NSAttributedString(string: transform(subtitle.text), attributes: attributes)
            runs.append(["text": .str(transform(subtitle.text)), "color": rgba(textColor), "active": .null])
        }

        let pillHPad = 12 * canvasScale
        let pillVPad = 6 * canvasScale
        let pillCorner = 6 * canvasScale
        let outerEdgePad = 20 * canvasScale

        let constraintWidth = max(1, outputSize.width - 2 * (outerEdgePad + pillHPad))
        let textSize = attrString.boundingRect(
            with: CGSize(
                width: constraintWidth,
                height: .greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let bgWidth = textSize.width + pillHPad * 2
        let bgHeight = textSize.height + pillVPad * 2

        let fraction: CGPoint
        if let fx = settings.subtitleCustomX, let fy = settings.subtitleCustomY {
            fraction = CGPoint(x: min(1, max(0, fx)), y: min(1, max(0, fy)))
        } else {
            switch settings.subtitlePosition {
            case .top: fraction = CGPoint(x: 0.5, y: 0)
            case .center: fraction = CGPoint(x: 0.5, y: 0.5)
            case .bottom: fraction = CGPoint(x: 0.5, y: 1)
            }
        }
        let usableW = max(0, outputSize.width - 2 * outerEdgePad - bgWidth)
        let usableH = max(0, outputSize.height - 2 * outerEdgePad - bgHeight)
        let xPosition = outerEdgePad + fraction.x * usableW
        let yPosition = outerEdgePad + (1 - fraction.y) * usableH

        let bitmapWidth = Int(outputSize.width)
        let bitmapHeight = Int(outputSize.height)
        let drawn = bitmapWidth > 0 && bitmapHeight > 0

        var background: WV = .null
        if settings.subtitleStyle == .background {
            let bgColor = NSColor(
                red: settings.subtitleBackgroundColor.red,
                green: settings.subtitleBackgroundColor.green,
                blue: settings.subtitleBackgroundColor.blue,
                alpha: 0.75
            )
            let bgRect = CGRect(x: xPosition, y: yPosition, width: bgWidth, height: bgHeight)
            let bgPath = CGPath(
                roundedRect: bgRect,
                cornerWidth: pillCorner, cornerHeight: pillCorner,
                transform: nil
            )
            background = ["rect": bgRect.wv, "cornerRadius": pillCorner.wv, "color": rgba(bgColor),
                          "path": WebVectors.pathWV(bgPath)]
        }

        let textRect = CGRect(
            x: xPosition + pillHPad,
            y: yPosition + pillVPad,
            width: textSize.width,
            height: textSize.height
        )

        var effect: WV = .null
        switch settings.subtitleStyle {
        case .outline:
            let radius = 2 * canvasScale
            if radius > 0 {
                effect = ["kind": "shadow", "radius": radius.wv, "color": ["r": 0.0, "g": 0.0, "b": 0.0, "a": 1.0]]
            }
        case .glow:
            let glow = CIColor(
                red: settings.subtitleColor.red,
                green: settings.subtitleColor.green,
                blue: settings.subtitleColor.blue,
                alpha: settings.subtitleColor.opacity * 0.8
            )
            let radius = 6 * canvasScale
            if radius > 0 {
                effect = ["kind": "glow", "radius": radius.wv,
                          "color": ["r": glow.red.wv, "g": glow.green.wv, "b": glow.blue.wv, "a": glow.alpha.wv]]
            }
        case .background, .plain:
            break
        }

        let key = cacheKey(subtitle, at: currentTime, settings: settings)
        return [
            "fontSize": fontSize.wv,
            "fontName": settings.subtitleFontName.map { WV.str($0) } ?? .null,
            "weight": .str(settings.subtitleWeight.rawValue),
            "runs": .arr(runs),
            "constraintWidth": constraintWidth.wv,
            "textBounds": textSize.wv,
            "pillHPad": pillHPad.wv, "pillVPad": pillVPad.wv, "pillCorner": pillCorner.wv,
            "outerEdgePad": outerEdgePad.wv,
            "bgWidth": bgWidth.wv, "bgHeight": bgHeight.wv,
            "fraction": fraction.wv,
            "usableW": usableW.wv, "usableH": usableH.wv,
            "xPosition": xPosition.wv, "yPosition": yPosition.wv,
            "bitmapWidth": bitmapWidth.wv, "bitmapHeight": bitmapHeight.wv, "drawn": drawn.wv,
            "background": background,
            "textRect": textRect.wv,
            "effect": effect,
            "cacheKey": .str(key.key), "activeWordCount": key.activeWordCount.wv,
        ]
    }
}

extension WebVectors {
    static let subtitleSentences: [String] = [
        "Hello world", "Click the Export button to render your video.",
        "straße and naïve café", "ὀδυσσεύς istanbul", "", "A",
        "This is a much longer subtitle line that will certainly have to wrap onto two or three lines at narrow widths",
        "⌘⇧S saves a copy — 100% done!", "Emoji 👋🏽 time", "Multi\nline\ntext",
        "Tabs\tand   spaces", "ﬁnal ﬂourish", "日本語のテキスト", "العربية نص", "Ünïcödé",
    ]

    static let subtitleFontNames: [String?] = [nil, nil, "System", "Helvetica Neue", "Georgia", "Menlo", "Avenir Next", "No Such Font"]

    static func randomSubtitleSettings(_ rng: inout WVRandom) -> ProjectSettings {
        let s = ProjectSettings()
        s.subtitleFontSize = rng.edgy(4, 96, edges: [24, 32, 0, 0.5])
        s.subtitleFontName = rng.pick(subtitleFontNames)
        s.subtitleWeight = rng.pick(ProjectSettings.SubtitleWeight.allCases)
        s.subtitleUppercase = rng.bool(0.3)
        s.subtitleStyle = rng.pick(ProjectSettings.SubtitleStyle.allCases)
        s.subtitlePosition = rng.pick(ProjectSettings.SubtitlePosition.allCases)
        if rng.bool(0.35) {
            s.subtitleCustomX = rng.edgy(-0.3, 1.3, edges: [0, 1, 0.5])
            s.subtitleCustomY = rng.edgy(-0.3, 1.3, edges: [0, 1, 0.5])
        } else if rng.bool(0.1) {
            s.subtitleCustomX = rng.double(0, 1) // Y nil → enum anchor
        }
        s.subtitleColor = CodableColor(red: rng.double(0, 1), green: rng.double(0, 1), blue: rng.double(0, 1),
                                       opacity: rng.edgy(0, 1, edges: [1]))
        s.subtitleBackgroundColor = CodableColor(red: rng.double(0, 1), green: rng.double(0, 1),
                                                 blue: rng.double(0, 1), opacity: rng.double(0, 1))
        s.subtitleHighlightColor = CodableColor(red: rng.double(0, 1), green: rng.double(0, 1),
                                                blue: rng.double(0, 1), opacity: rng.edgy(0, 1, edges: [1]))
        s.highlightWords = rng.bool(0.5)
        s.showSubtitles = rng.bool(0.85)
        return s
    }

    static func randomSubtitle(_ rng: inout WVRandom, start: Double) -> SubtitleSegment {
        let text = rng.pick(subtitleSentences)
        let len = rng.edgy(0, 4, edges: [0, 0.5, 2])
        var words: [WordTiming] = []
        if rng.bool(0.7) {
            let parts = text.split(separator: " ").map(String.init)
            var t = start
            for p in parts {
                let d = len / Double(max(1, parts.count))
                words.append(WordTiming(id: rng.uuid(), startTime: t, endTime: t + d, text: p))
                t += d
            }
        }
        return SubtitleSegment(id: rng.uuid(), startTime: start, endTime: start + len, text: text, words: words)
    }

    static func subtitleWV(_ s: SubtitleSegment) -> WV {
        [
            "id": .str(s.id.uuidString), "startTime": s.startTime.wv, "endTime": s.endTime.wv,
            "text": .str(s.text),
            "words": .arr(s.words.map {
                ["id": .str($0.id.uuidString), "startTime": $0.startTime.wv, "endTime": $0.endTime.wv, "text": .str($0.text)] as WV
            }),
        ]
    }

    static func subtitleSettingsWV(_ s: ProjectSettings) -> WV {
        var o: WV = [
            "showSubtitles": s.showSubtitles.wv,
            "subtitleFontSize": s.subtitleFontSize.wv,
            "subtitlePosition": .str(s.subtitlePosition.rawValue),
            "subtitleStyle": .str(s.subtitleStyle.rawValue),
            "subtitleWeight": .str(s.subtitleWeight.rawValue),
            "subtitleUppercase": s.subtitleUppercase.wv,
            "subtitleColor": WVModel.color(s.subtitleColor),
            "subtitleBackgroundColor": WVModel.color(s.subtitleBackgroundColor),
            "highlightWords": s.highlightWords.wv,
            "subtitleHighlightColor": WVModel.color(s.subtitleHighlightColor),
        ]
        if let x = s.subtitleCustomX { o = o.setting("subtitleCustomX", x.wv) }
        if let y = s.subtitleCustomY { o = o.setting("subtitleCustomY", y.wv) }
        if let n = s.subtitleFontName { o = o.setting("subtitleFontName", .str(n)) }
        return o
    }

    static var subtitleUnits: [WebVectorUnit] {
        [
            WebVectorUnit(
                name: "exportSubtitleLayout",
                notes: "Services/VideoExporter.swift renderSubtitle (3661–3857) + subtitleDropShadow (3862–3885) — verbatim oracle: font size, attributed runs (karaoke highlight/dim), constraint width, pill paddings/corner, bg pill (alpha 0.75), custom-XY/anchor 20pt-inset origin interpolation (Y-UP), text rect, outline/glow blur radius + colour, cache key. textBounds = REAL NSAttributedString.boundingRect (TS input)",
                build: exportSubtitleLayoutCases),
            WebVectorUnit(
                name: "exportSubtitleTextMetrics",
                notes: "AppKit text measurement reference for subtitles: FontCatalog.font(named:size:weight:) + NSAttributedString.boundingRect(.usesLineFragmentOrigin,.usesFontLeading) at the exporter's constraint width, plus font ascender/descender/leading/defaultLineHeight — the web's measurement must reproduce these",
                build: exportSubtitleTextMetricsCases),
            WebVectorUnit(
                name: "exportActiveSubtitle",
                notes: "Services/VideoExporter.swift export() — verbatim oracle of the active-subtitle lookup (first segment with start ≤ t ≤ end, gated by showSubtitles, lines 1798–1801), the overlay cache key (3672–3675) and canvasScale (336–342)",
                build: exportActiveSubtitleCases),
        ]
    }

    private static func exportSubtitleLayoutCases() -> [WV] {
        var rng = WVRandom(seed: "exportSubtitleLayout")
        var cases: [WV] = []
        let outputs: [CGSize] = [CGSize(width: 1920, height: 1080), CGSize(width: 1280, height: 720),
                                 CGSize(width: 3840, height: 2160), CGSize(width: 1080, height: 1920),
                                 CGSize(width: 640, height: 480), CGSize(width: 101.5, height: 60.25),
                                 CGSize(width: 0, height: 0), CGSize(width: 300, height: 1080)]
        for i in 0..<900 {
            let settings = randomSubtitleSettings(&rng)
            let sub = randomSubtitle(&rng, start: rng.double(0, 20))
            let out = i % 9 == 0 ? CGSize(width: rng.double(50, 4000), height: rng.double(50, 3000)) : rng.pick(outputs)
            let canvasScale = CGFloat(rng.edgy(0.25, 3, edges: [1, 2, 0.5, 0, 1.3333333333333333]))
            let t = rng.edgy(sub.startTime - 0.2, sub.endTime + 0.2,
                             edges: [sub.startTime, sub.endTime] + sub.words.map(\.startTime))
            let recipe = ExportSubtitleOracle.recipe(subtitle: sub, at: t, outputSize: out, canvasScale: canvasScale,
                                                     settings: settings)
            cases.append(vcase(
                [
                    "subtitle": subtitleWV(sub), "currentTime": t.wv, "outputSize": out.wv,
                    "canvasScale": canvasScale.wv, "settings": subtitleSettingsWV(settings),
                    "textBounds": recipe["textBounds"] ?? .null,
                ],
                recipe))
        }
        return cases
    }

    private static func exportSubtitleTextMetricsCases() -> [WV] {
        var rng = WVRandom(seed: "exportSubtitleTextMetrics")
        var cases: [WV] = []
        var inputs: [(String, Bool, Double, CGFloat, ProjectSettings.SubtitleWeight, String?, CGFloat)] = []
        for text in subtitleSentences {
            for fontName in subtitleFontNames.dropFirst() {
                for weight in ProjectSettings.SubtitleWeight.allCases {
                    inputs.append((text, false, 32, 1, weight, fontName, 1920))
                }
            }
            for size in [8.0, 16, 24, 48, 72] {
                for width in [1920.0, 640, 300] as [CGFloat] {
                    inputs.append((text, rng.bool(0.3), size, 1, .semibold, nil, width))
                }
            }
        }
        for _ in 0..<150 {
            inputs.append((rng.pick(subtitleSentences), rng.bool(0.3), rng.double(6, 90), CGFloat(rng.double(0.5, 2.5)),
                           rng.pick(ProjectSettings.SubtitleWeight.allCases), rng.pick(subtitleFontNames),
                           CGFloat(rng.double(100, 3840))))
        }
        for (text, upper, fontPt, canvasScale, weight, fontName, outputWidth) in inputs {
            let fontSize = max(1, fontPt * canvasScale)
            let font = FontCatalog.font(named: fontName, size: fontSize, weight: weight.nsWeight)
            let string = upper ? text.uppercased() : text
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attr = NSAttributedString(string: string, attributes: [.font: font, .paragraphStyle: paragraph])
            let constraintWidth = max(1, outputWidth - 2 * (20 * canvasScale + 12 * canvasScale))
            // Warm CoreText first: the first measurement at a new font size
            // is ~1e-10 relative off the steady value (WebVectors.textLineWV).
            _ = attr.boundingRect(with: CGSize(width: constraintWidth, height: .greatestFiniteMagnitude),
                                  options: [.usesLineFragmentOrigin, .usesFontLeading])
            _ = attr.size()
            let bounds = attr.boundingRect(with: CGSize(width: constraintWidth, height: .greatestFiniteMagnitude),
                                           options: [.usesLineFragmentOrigin, .usesFontLeading])
            let single = attr.size()
            cases.append(vcase(
                [
                    "text": .str(text), "uppercase": upper.wv, "subtitleFontSize": fontPt.wv,
                    "canvasScale": canvasScale.wv, "weight": .str(weight.rawValue),
                    "fontName": fontName.map { WV.str($0) } ?? .null, "outputWidth": outputWidth.wv,
                ],
                [
                    "fontSize": fontSize.wv,
                    "string": .str(string),
                    "constraintWidth": constraintWidth.wv,
                    "measured": [
                        "boundingRect": bounds.wv,
                        "singleLineSize": single.wv,
                        "resolvedFontName": .str(font.fontName),
                        "familyName": .str(font.familyName ?? ""),
                        "pointSize": font.pointSize.wv,
                        "ascender": font.ascender.wv,
                        "descender": font.descender.wv,
                        "leading": font.leading.wv,
                        "defaultLineHeight": NSLayoutManager().defaultLineHeight(for: font).wv,
                    ],
                ]))
        }
        return cases
    }

    private static func exportActiveSubtitleCases() -> [WV] {
        var rng = WVRandom(seed: "exportActiveSubtitle")
        var cases: [WV] = []
        for i in 0..<700 {
            var subs: [SubtitleSegment] = []
            var t = rng.double(0, 2)
            for _ in 0..<(i % 25 == 0 ? 0 : rng.int(1, 8)) {
                t += rng.edgy(-1, 3, edges: [0, -0.5])
                subs.append(randomSubtitle(&rng, start: t))
            }
            let settings = randomSubtitleSettings(&rng)
            let times: [Double] = (0..<16).map { _ in
                rng.edgy(-1, t + 5, edges: subs.flatMap { [$0.startTime, $0.endTime] } + subs.flatMap { $0.words.map(\.startTime) })
            }
            let out = CGSize(width: rng.edgy(0, 4000, edges: [1920, 1280, 0]), height: rng.edgy(0, 3000, edges: [1080, 720, 0]))
            let preview = CGSize(width: rng.edgy(-10, 2000, edges: [0, 960, -1]), height: rng.edgy(-10, 1200, edges: [0, 540]))
            cases.append(vcase(
                [
                    "subtitles": .arr(subs.map(subtitleWV)), "times": times.wv,
                    "settings": subtitleSettingsWV(settings),
                    "outputSize": out.wv, "previewCanvasSize": preview.wv,
                ],
                [
                    "active": .arr(times.map { time -> WV in
                        guard let s = ExportSubtitleOracle.activeSubtitle(subs, at: time, showSubtitles: settings.showSubtitles) else { return .null }
                        let k = ExportSubtitleOracle.cacheKey(s, at: time, settings: settings)
                        return ["id": .str(s.id.uuidString), "cacheKey": .str(k.key), "activeWordCount": k.activeWordCount.wv]
                    }),
                    "canvasScale": ExportSubtitleOracle.canvasScale(outputSize: out, previewCanvasSize: preview).wv,
                ]))
        }
        return cases
    }
}
