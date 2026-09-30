import AppKit
import Foundation

/// The ONE table behind `set_style` (the whitelist + validation) and
/// `style_options` (the agent-facing catalog). Enum values come from the real
/// `CaseIterable` types and every setter writes through a key path into
/// `ProjectSettings`, so the catalog can never drift from what set_style
/// accepts or what the app persists.
extension MCPServer {
    struct StyleKey {
        enum Kind {
            case enumeration([String])
            case number(ClosedRange<Double>)
            case boolean
            case text(maxLength: Int)
            case color
        }

        let key: String
        let group: String
        let kind: Kind
        let note: String?
        /// Current value as a JSON-safe object (NSNull for an unset optional).
        let read: (ProjectSettings) -> Any
        /// Validates `value` and writes it; throws an actionable ToolError.
        let write: (ProjectSettings, Any) throws -> Void

        var schemaFragment: [String: Any] {
            var entry: [String: Any] = ["group": group]
            switch kind {
            case .enumeration(let values):
                entry["type"] = "enum"
                entry["values"] = values
            case .number(let range):
                entry["type"] = "number"
                entry["min"] = range.lowerBound
                entry["max"] = range.upperBound
            case .boolean:
                entry["type"] = "boolean"
            case .text(let maxLength):
                entry["type"] = "string"
                entry["maxLength"] = maxLength
            case .color:
                entry["type"] = "color"
                entry["format"] = "#RRGGBB or #RRGGBBAA"
            }
            if let note { entry["note"] = note }
            return entry
        }
    }

    // MARK: - Builders

    private typealias Settings = ProjectSettings

    private static func enumKey<T: RawRepresentable & CaseIterable>(
        _ key: String, _ group: String,
        _ path: ReferenceWritableKeyPath<Settings, T>,
        note: String? = nil,
        then: ((Settings) -> Void)? = nil
    ) -> StyleKey where T.RawValue == String {
        let allowed = T.allCases.map(\.rawValue)
        return StyleKey(
            key: key, group: group, kind: .enumeration(allowed), note: note,
            read: { $0[keyPath: path].rawValue },
            write: { settings, value in
                guard let raw = value as? String, let parsed = T(rawValue: raw) else {
                    throw ToolError("invalid value for \(key): \(value) (allowed: "
                        + allowed.map { "\"\($0)\"" }.joined(separator: ", ")
                        + " — exact, case-sensitive)")
                }
                settings[keyPath: path] = parsed
                then?(settings)
            }
        )
    }

    private static func numberKey(
        _ key: String, _ group: String,
        _ path: ReferenceWritableKeyPath<Settings, Double>,
        _ range: ClosedRange<Double>, note: String? = nil
    ) -> StyleKey {
        StyleKey(
            key: key, group: group, kind: .number(range), note: note,
            read: { round3($0[keyPath: path]) },
            write: { settings, value in
                settings[keyPath: path] = try validatedNumber(key, value, range)
            }
        )
    }

    private static func optionalNumberKey(
        _ key: String, _ group: String,
        _ path: ReferenceWritableKeyPath<Settings, Double?>,
        _ range: ClosedRange<Double>, note: String? = nil
    ) -> StyleKey {
        StyleKey(
            key: key, group: group, kind: .number(range), note: note,
            read: { settings in settings[keyPath: path].map { round3($0) as Any } ?? NSNull() },
            write: { settings, value in
                settings[keyPath: path] = try validatedNumber(key, value, range)
            }
        )
    }

    private static func boolKey(
        _ key: String, _ group: String,
        _ path: ReferenceWritableKeyPath<Settings, Bool>,
        note: String? = nil,
        then: ((Settings) -> Void)? = nil
    ) -> StyleKey {
        StyleKey(
            key: key, group: group, kind: .boolean, note: note,
            read: { $0[keyPath: path] },
            write: { settings, value in
                guard let b = value as? Bool else {
                    throw ToolError("\(key) must be a boolean (true/false), got \(value)")
                }
                settings[keyPath: path] = b
                then?(settings)
            }
        )
    }

    private static func textKey(
        _ key: String, _ group: String,
        _ path: ReferenceWritableKeyPath<Settings, String>,
        maxLength: Int, note: String? = nil
    ) -> StyleKey {
        StyleKey(
            key: key, group: group, kind: .text(maxLength: maxLength), note: note,
            read: { $0[keyPath: path] },
            write: { settings, value in
                settings[keyPath: path] = try validatedText(key, value, maxLength)
            }
        )
    }

    private static func optionalTextKey(
        _ key: String, _ group: String,
        _ path: ReferenceWritableKeyPath<Settings, String?>,
        maxLength: Int, note: String? = nil
    ) -> StyleKey {
        StyleKey(
            key: key, group: group, kind: .text(maxLength: maxLength), note: note,
            read: { settings in settings[keyPath: path].map { $0 as Any } ?? NSNull() },
            write: { settings, value in
                settings[keyPath: path] = try validatedText(key, value, maxLength)
            }
        )
    }

    private static func colorKey(
        _ key: String, _ group: String,
        _ path: ReferenceWritableKeyPath<Settings, CodableColor>, note: String? = nil
    ) -> StyleKey {
        StyleKey(
            key: key, group: group, kind: .color, note: note,
            read: { hexString($0[keyPath: path]) },
            write: { settings, value in
                settings[keyPath: path] = try validatedColor(key, value)
            }
        )
    }

    private static func optionalColorKey(
        _ key: String, _ group: String,
        _ path: ReferenceWritableKeyPath<Settings, CodableColor?>, note: String? = nil
    ) -> StyleKey {
        StyleKey(
            key: key, group: group, kind: .color, note: note,
            read: { settings in settings[keyPath: path].map { hexString($0) as Any } ?? NSNull() },
            write: { settings, value in
                settings[keyPath: path] = try validatedColor(key, value)
            }
        )
    }

    private static func validatedNumber(_ key: String, _ value: Any, _ range: ClosedRange<Double>) throws -> Double {
        guard !isJSONBool(value), let d = doubleValue(value), d.isFinite, range.contains(d) else {
            throw ToolError("invalid value for \(key): \(value) (allowed: a number in "
                + "\(formatNumber(range.lowerBound))...\(formatNumber(range.upperBound)))")
        }
        return d
    }

    private static func validatedText(_ key: String, _ value: Any, _ maxLength: Int) throws -> String {
        guard let s = value as? String, s.count <= maxLength else {
            throw ToolError("\(key) must be a string of at most \(maxLength) characters")
        }
        return s
    }

    private static func validatedColor(_ key: String, _ value: Any) throws -> CodableColor {
        guard let hex = value as? String, let parsed = CodableColor(hex: hex) else {
            throw ToolError("\(key) must be a hex color string, e.g. \"#FF3B30\" or \"#FF3B30CC\" (RRGGBB or RRGGBBAA)")
        }
        return parsed
    }

    static func formatNumber(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    /// "#RRGGBB", or "#RRGGBBAA" when not fully opaque.
    static func hexString(_ color: CodableColor) -> String {
        func byte(_ v: Double) -> Int { Int((min(1, max(0, v)) * 255).rounded()) }
        let rgb = String(format: "#%02X%02X%02X", byte(color.red), byte(color.green), byte(color.blue))
        return color.opacity >= 0.999 ? rgb : rgb + String(format: "%02X", byte(color.opacity))
    }

    // MARK: - The table

    /// Groups in display order (style_options and the set_style description).
    static let styleGroups: [String] = [
        "canvas", "background", "cursor", "clicksAndKeys", "camera", "menuBar",
        "motion", "intro", "audio", "subtitles", "watermark",
    ]

    static let styleKeys: [StyleKey] = [
        // Canvas / frame.
        enumKey("aspectRatio", "canvas", \.aspectRatio,
                note: "\"9:16\" / \"4:5\" for vertical social cuts; \"Auto\" matches the recording"),
        numberKey("backgroundPadding", "canvas", \.backgroundPadding, 0...300,
                  note: "space around the video card, canvas points"),
        enumKey("videoPlacement", "canvas", \.videoPlacement,
                note: "clears any free (dragged) card position",
                then: { $0.videoCustomX = nil; $0.videoCustomY = nil }),
        enumKey("frameShape", "canvas", \.frameShape),
        numberKey("cornerRadius", "canvas", \.cornerRadius, 0...20),
        numberKey("windowCornerRadius", "canvas", \.windowCornerRadius, 0...20),
        numberKey("shadowRadius", "canvas", \.shadowRadius, 0...60),
        numberKey("shadowOpacity", "canvas", \.shadowOpacity, 0...1),
        boolKey("showDeviceFrame", "canvas", \.showDeviceFrame, note: "iPhone/iPad takes: draw the device bezel"),

        // Background.
        enumKey("backgroundType", "background", \.backgroundType,
                note: "\"Image\"/\"Wallpaper\" use the image or wallpaper already picked in the editor"),
        colorKey("gradientStartColor", "background", \.gradientStartColor),
        colorKey("gradientEndColor", "background", \.gradientEndColor),
        optionalNumberKey("gradientAngle", "background", \.gradientAngle, 0...360,
                          note: "degrees, 90 = left→right; null = legacy corner-to-corner diagonal"),
        colorKey("solidColor", "background", \.solidColor),
        numberKey("backgroundBlur", "background", \.backgroundBlur, 0...1),
        numberKey("backgroundBrightness", "background", \.backgroundBrightness, -1...1),
        numberKey("backgroundSaturation", "background", \.backgroundSaturation, 0...2),
        numberKey("backgroundContrast", "background", \.backgroundContrast, 0.5...1.5),
        numberKey("backgroundHue", "background", \.backgroundHue, 0...360),
        colorKey("backgroundTintColor", "background", \.backgroundTintColor),
        numberKey("backgroundTintOpacity", "background", \.backgroundTintOpacity, 0...1),
        numberKey("backgroundVignette", "background", \.backgroundVignette, 0...1),
        numberKey("backgroundPixelate", "background", \.backgroundPixelate, 0...1),
        numberKey("backgroundHalftone", "background", \.backgroundHalftone, 0...1),
        numberKey("backgroundNoise", "background", \.backgroundNoise, 0...1),

        // Cursor.
        boolKey("showCursor", "cursor", \.showCursor),
        enumKey("cursorStyle", "cursor", \.cursorStyle),
        numberKey("cursorScale", "cursor", \.cursorScale, 0.5...3),
        boolKey("cursorFluidEnabled", "cursor", \.cursorFluidEnabled, note: "spring-smoothed movement; clicks stay pinned"),
        numberKey("cursorTension", "cursor", \.cursorTension, 20...600),
        numberKey("cursorFriction", "cursor", \.cursorFriction, 2...80),
        numberKey("cursorMass", "cursor", \.cursorMass, 0.2...6),
        numberKey("cursorTilt", "cursor", \.cursorTilt, 0...1),
        numberKey("cursorStretch", "cursor", \.cursorStretch, 0...1),
        numberKey("cursorDrag", "cursor", \.cursorDrag, 0...1),
        numberKey("cursorWeight", "cursor", \.cursorWeight, 0.5...3),
        boolKey("smoothCursor", "cursor", \.smoothCursor),
        numberKey("smoothingFactor", "cursor", \.smoothingFactor, 0.05...0.5),
        boolKey("autoHideCursor", "cursor", \.autoHideCursor),
        numberKey("autoHideDelay", "cursor", \.autoHideDelay, 1...10),
        boolKey("cursorLoopToStart", "cursor", \.cursorLoopToStart,
                note: "true turns cursorStopAtEnd off",
                then: { if $0.cursorLoopToStart { $0.cursorStopAtEnd = false } }),
        boolKey("cursorStopAtEnd", "cursor", \.cursorStopAtEnd,
                note: "true turns cursorLoopToStart off",
                then: { if $0.cursorStopAtEnd { $0.cursorLoopToStart = false } }),

        // Click ripple, click/key sounds, shortcut overlay.
        boolKey("showClickRipple", "clicksAndKeys", \.showClickRipple),
        colorKey("clickRippleColor", "clicksAndKeys", \.clickRippleColor),
        numberKey("clickRippleSize", "clicksAndKeys", \.clickRippleSize, 20...100),
        boolKey("clickSoundEnabled", "clicksAndKeys", \.clickSoundEnabled),
        numberKey("clickSoundVolume", "clicksAndKeys", \.clickSoundVolume, 0.1...1),
        enumKey("clickSoundStyle", "clicksAndKeys", \.clickSoundStyle),
        boolKey("keySoundEnabled", "clicksAndKeys", \.keySoundEnabled),
        numberKey("keySoundVolume", "clicksAndKeys", \.keySoundVolume, 0.1...1),
        enumKey("keySoundStyle", "clicksAndKeys", \.keySoundStyle),
        boolKey("showKeystrokes", "clicksAndKeys", \.showKeystrokes,
                note: "shortcut pill (⌘⇧S); only renders shortcuts captured at record time"),
        boolKey("keystrokeOverlayScopeToRecordedApp", "clicksAndKeys", \.keystrokeOverlayScopeToRecordedApp,
                note: "window recordings: only shortcuts sent to the recorded app"),

        // Camera bubble.
        boolKey("showCamera", "camera", \.showCamera, note: "no effect without a camera recording"),
        enumKey("cameraPosition", "camera", \.cameraPosition),
        enumKey("cameraShape", "camera", \.cameraShape),
        enumKey("cameraOrientation", "camera", \.cameraOrientation),
        numberKey("cameraSize", "camera", \.cameraSize, 60...240),
        boolKey("cameraMirrored", "camera", \.cameraMirrored),
        numberKey("cameraBrightness", "camera", \.cameraBrightness, -1...1),
        numberKey("cameraContrast", "camera", \.cameraContrast, 0.5...1.5),
        numberKey("cameraSaturation", "camera", \.cameraSaturation, 0...2),
        numberKey("cameraHue", "camera", \.cameraHue, -180...180),
        enumKey("cameraFilter", "camera", \.cameraFilter),
        numberKey("cameraRingLight", "camera", \.cameraRingLight, 0...1),
        numberKey("cameraCornerRadius", "camera", \.cameraCornerRadius, 0...60),
        numberKey("cameraBorderWidth", "camera", \.cameraBorderWidth, 0...8),
        optionalColorKey("cameraBorderColor", "camera", \.cameraBorderColor),
        numberKey("cameraOpacity", "camera", \.cameraOpacity, 0.2...1),
        numberKey("cameraTiltPitch", "camera", \.cameraTiltPitch, -25...25),
        numberKey("cameraTiltYaw", "camera", \.cameraTiltYaw, -25...25),
        textKey("cameraTagText", "camera", \.cameraTagText, maxLength: 60, note: "name tag; empty hides it"),
        textKey("cameraTagSubtext", "camera", \.cameraTagSubtext, maxLength: 60),
        optionalTextKey("cameraTagFontName", "camera", \.cameraTagFontName, maxLength: 80),
        colorKey("cameraTagTextColor", "camera", \.cameraTagTextColor),
        colorKey("cameraTagBackgroundColor", "camera", \.cameraTagBackgroundColor),
        enumKey("cameraTagPosition", "camera", \.cameraTagPosition),

        // Menu bar replacement (display recordings).
        enumKey("menuBarReplacement", "menuBar", \.menuBarReplacement),
        textKey("menuBarTitle", "menuBar", \.menuBarTitle, maxLength: 60),
        enumKey("menuBarTitleAlignment", "menuBar", \.menuBarTitleAlignment),
        boolKey("menuBarShowStatusIcons", "menuBar", \.menuBarShowStatusIcons),
        textKey("menuBarClock", "menuBar", \.menuBarClock, maxLength: 12),
        numberKey("menuBarHeight", "menuBar", \.menuBarHeight, 2...6, note: "% of video height"),

        // Motion feel + global screen tilt.
        enumKey("animationSpeed", "motion", \.animationSpeed,
                note: "default zoom/tilt transition pace for blocks without an animationStyle"),
        numberKey("autoZoomLevel", "motion", \.autoZoomLevel, 1.5...4, note: "auto_zoom's base depth"),
        numberKey("cameraFollowSpeed", "motion", \.cameraFollowSpeed, 0...1,
                  note: "how tightly a zoomed camera chases the cursor"),
        boolKey("motionBlur", "motion", \.motionBlur),
        numberKey("motionBlurStrength", "motion", \.motionBlurStrength, 0...1),
        numberKey("parallaxStrength", "motion", \.parallaxStrength, 0...1),
        enumKey("screenTiltMode", "motion", \.screenTiltMode,
                note: "global 3D tilt while zoomed out (timeline tilt blocks are add_effect type tilt)"),
        numberKey("screenTiltAngle", "motion", \.screenTiltAngle, -60...60),
        numberKey("screenTiltYaw", "motion", \.screenTiltYaw, -60...60),
        numberKey("screenTiltRoll", "motion", \.screenTiltRoll, -30...30),

        // Intro slide + curtain unveil (OUTPUT-time placement).
        enumKey("introSlideStyle", "intro", \.introSlideStyle),
        numberKey("introSlideDuration", "intro", \.introSlideDuration, 0.3...3600),
        numberKey("introSlideStart", "intro", \.introSlideStart, 0...3600, note: "OUTPUT seconds"),
        numberKey("introSlideBounce", "intro", \.introSlideBounce, 0...1),
        numberKey("introSlideSpeed", "intro", \.introSlideSpeed, 1...4),
        enumKey("curtainUnveilCorner", "intro", \.curtainUnveilCorner),
        numberKey("curtainUnveilDuration", "intro", \.curtainUnveilDuration, 0.1...3600),
        numberKey("curtainUnveilStart", "intro", \.curtainUnveilStart, 0...3600, note: "OUTPUT seconds"),
        numberKey("curtainLogoOpacity", "intro", \.curtainLogoOpacity, 0...1),
        numberKey("curtainLogoScale", "intro", \.curtainLogoScale, 0.05...0.8),
        optionalColorKey("curtainColor", "intro", \.curtainColor),
        optionalColorKey("curtainLogoTint", "intro", \.curtainLogoTint),

        // Audio mix.
        numberKey("systemAudioVolume", "audio", \.systemAudioVolume, 0...1),
        numberKey("microphoneVolume", "audio", \.microphoneVolume, 0...1),
        numberKey("voiceOverVolume", "audio", \.voiceOverVolume, 0...1.5),
        boolKey("muteRecordedAudio", "audio", \.muteRecordedAudio),

        // Subtitles (burned in when showSubtitles and the project has any).
        boolKey("showSubtitles", "subtitles", \.showSubtitles,
                note: "burns the project's subtitles (from transcribe) into render/export"),
        numberKey("subtitleFontSize", "subtitles", \.subtitleFontSize, 16...64),
        enumKey("subtitlePosition", "subtitles", \.subtitlePosition),
        enumKey("subtitleStyle", "subtitles", \.subtitleStyle),
        enumKey("subtitleWeight", "subtitles", \.subtitleWeight),
        boolKey("subtitleUppercase", "subtitles", \.subtitleUppercase),

        // Watermark (image picked in the editor).
        boolKey("showWatermark", "watermark", \.showWatermark, note: "needs a watermark image picked in the editor"),
        numberKey("watermarkOpacity", "watermark", \.watermarkOpacity, 0.1...1),
        numberKey("watermarkSize", "watermark", \.watermarkSize, 40...400),
        numberKey("watermarkX", "watermark", \.watermarkX, 0...1),
        numberKey("watermarkY", "watermark", \.watermarkY, 0...1),
    ]

    static let styleKeyIndex: [String: StyleKey] = Dictionary(
        styleKeys.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first }
    )

    // MARK: - Apply / describe

    static func applyStyle(key: String, value: Any, to settings: ProjectSettings) throws {
        guard let entry = styleKeyIndex[key] else {
            var message = "key not whitelisted: \(key)"
            let suggestions = closestStyleKeys(to: key)
            if !suggestions.isEmpty {
                message += " — did you mean " + suggestions.map { "'\($0)'" }.joined(separator: " or ") + "?"
            }
            message += " Call style_options for every settable key with its type, range and current value."
            throw ToolError(message)
        }
        try entry.write(settings, value)
    }

    /// Compact one-line-per-group summary for set_style's description.
    static var styleKeySummary: String {
        styleGroups.map { group in
            let keys = styleKeys.filter { $0.group == group }.map(\.key)
            let shown = keys.prefix(5).joined(separator: ", ")
            return keys.count > 5 ? "\(group): \(shown)… (+\(keys.count - 5))" : "\(group): \(shown)"
        }.joined(separator: "; ")
    }

    static func styleOptions(for project: Project?, group: String?) throws -> [String: Any] {
        if let group, !styleGroups.contains(group) {
            throw ToolError("unknown group '\(group)' (groups: \(styleGroups.joined(separator: ", ")))")
        }
        var groups: [String: Any] = [:]
        for name in styleGroups where group == nil || group == name {
            var keys: [String: Any] = [:]
            for entry in styleKeys where entry.group == name {
                var fragment = entry.schemaFragment
                fragment.removeValue(forKey: "group")
                if let project { fragment["current"] = entry.read(project.settings) }
                keys[entry.key] = fragment
            }
            groups[name] = keys
        }
        return [
            "groups": groups,
            "keyCount": styleKeys.count,
            "note": "Patch any of these with set_style {id, patch: {key: value}} (or an apply_edits "
                + "set_style op). Enum values are exact, case-sensitive raw values. Colors are hex strings.",
        ]
    }

    private static func closestStyleKeys(to query: String) -> [String] {
        let q = query.lowercased()
        let scored = styleKeys.map { entry -> (String, Int) in
            let k = entry.key.lowercased()
            if k.contains(q) || q.contains(k) { return (entry.key, 0) }
            return (entry.key, levenshtein(q, k))
        }
        return scored.filter { $0.1 <= max(2, q.count / 4) }
            .sorted { $0.1 < $1.1 }
            .prefix(2)
            .map(\.0)
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                )
            }
            previous = current
        }
        return previous[b.count]
    }
}
