import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The inspector-values transcript, shared by the Mac `--inspector-values-test`
/// (InspectorValuesHarness: the real InspectorColumnAppKit in the editor's
/// hosting chain) and the iOS `--inspector` gate (StudioLab: the real
/// StudioInspectorController in the editor). Both replay ONE script — every
/// control of all nine panes, through the real control — and record ONE
/// transcript with this recorder: what each input wrote to the project, the
/// selection after it, and which controls the pane shows. The frozen Mac
/// transcript (`InspectorValuesGoldens`) is the reference; a difference is
/// behaviour, not formatting.
@MainActor
enum InspectorValuesTranscript {
    static func uuid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-C000-%012d", n))!
    }

    static let header = "== inspector values (fixture: 20 s window take with a device segment, camera, shortcut keystrokes; zoom 2–5, tilt 8–10, highlight 6–8, depth 11–13, blur 1–3; text, rectangle, drawing, tap, arrow; two captions)"

    // MARK: - Fixture

    /// Fixture names → ids, for the transcript (Z1, T2 …).
    static let names: [UUID: String] = [
        uuid(1): "Z1", uuid(2): "T2", uuid(3): "H3", uuid(4): "F4", uuid(5): "B5",
        uuid(6): "Text6", uuid(7): "Rect7", uuid(8): "Draw8", uuid(9): "Tap9", uuid(10): "Arrow10",
        uuid(11): "S11", uuid(12): "S12",
    ]

    /// Writes the fixture's files into `folder` (keystrokes with a shortcut,
    /// a 4×2 logo PNG) and returns the project. `folder` must exist.
    static func makeProject(folder: URL) -> Project {
        let project = Project(
            id: uuid(99), name: "Inspector Values",
            videoURL: folder.appendingPathComponent("screen.mov"),
            cameraVideoURL: folder.appendingPathComponent("camera.mov"),
            duration: 20, recordingSourceKind: .window)
        project.sourceSegments = [
            ProjectSourceSegment(startTime: 0, duration: 10, kind: .window,
                                 contentX: 0, contentY: 0, contentWidth: 1, contentHeight: 1),
            ProjectSourceSegment(startTime: 10, duration: 10, kind: .device,
                                 contentX: 0.3, contentY: 0, contentWidth: 0.4, contentHeight: 1),
        ]
        let keys = KeystrokeRecording(version: 1, events: [
            KeystrokeEvent(timestamp: 1, category: .key),
            KeystrokeEvent(timestamp: 2, category: .key, shortcut: "⌘⇧S", frontmostBundleID: "so.capturecat.fixture"),
        ])
        let keysURL = folder.appendingPathComponent("keys.json")
        if let data = try? JSONEncoder().encode(keys) { try? data.write(to: keysURL) }
        project.keystrokeDataURL = keysURL
        writeLogo(to: logoURL(in: folder))

        project.zoomRegions = [ZoomRegion(id: uuid(1), startTime: 2, endTime: 5, zoomLevel: 1.8,
                                          focalPoint: CGPoint(x: 0.4, y: 0.4))]
        project.tiltRegions = [TiltRegion(id: uuid(2), startTime: 8, endTime: 10, pitch: 12, yaw: -4, roll: 1)]
        project.highlightRegions = [HighlightRegion(id: uuid(3), startTime: 6, endTime: 8)]
        project.focusRegions = [FocusRegion(id: uuid(4), startTime: 11, endTime: 13)]
        project.blurRegions = [BlurRegion(id: uuid(5), startTime: 1, endTime: 3)]
        var text = Annotation(id: uuid(6), type: .text, startTime: 1, endTime: 4)
        text.text = "Hello"
        var drawing = Annotation(id: uuid(8), type: .drawing, startTime: 9, endTime: 12)
        drawing.drawingStrokes = [
            [CodablePoint(x: 0.1, y: 0.1), CodablePoint(x: 0.2, y: 0.2)],
            [CodablePoint(x: 0.3, y: 0.3), CodablePoint(x: 0.4, y: 0.5)],
        ]
        project.annotations = [
            text,
            Annotation(id: uuid(7), type: .rectangle, startTime: 5, endTime: 8),
            drawing,
            Annotation(id: uuid(9), type: .tap, startTime: 13, endTime: 15),
            Annotation(id: uuid(10), type: .arrow, startTime: 15, endTime: 17),
        ]
        project.subtitles = [
            SubtitleSegment(id: uuid(11), startTime: 0, endTime: 2, text: "First line"),
            SubtitleSegment(id: uuid(12), startTime: 2, endTime: 4, text: "Second line"),
        ]
        // A freeform card position, so Placement starts on "Custom".
        project.settings.videoCustomX = 0.8
        project.settings.videoCustomY = 0.3
        return project
    }

    static func logoURL(in folder: URL) -> URL { folder.appendingPathComponent("fixture-logo.png") }

    /// The playhead both drivers report (At Playhead, add-at-playhead).
    static let playhead: TimeInterval = 6.5

    private static func writeLogo(to url: URL) {
        let width = 4, height = 2
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) { pixels[i * 4] = 255; pixels[i * 4 + 3] = 255 }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    // MARK: - Script

    /// What a step does to its control — at the user's level, so each
    /// platform drives its own control the way a user would.
    enum Input {
        /// Tap the slider at the position of this value (each platform's
        /// geometry turns it into a point; the control quantizes).
        case slider(Double)
        /// Flip the toggle.
        case toggle
        /// Pick item `n` (chip or menu row).
        case choose(Int)
        /// The color picker commits this sRGB colour.
        case color(Double, Double, Double, Double)
        /// Type this text, then end editing.
        case text(String)
        /// Press the button.
        case tap
        /// Press and release a pad at this fraction of its own geometry
        /// (InspectorPadMath's fractions; tilt pads take −1…1, y up).
        case pad(Double, Double)
        /// Click preset card `n` (Subtitles).
        case preset(Int)
        /// Edit caption `n`'s text in the list (Subtitles).
        case caption(Int, String)
        /// The host's file picker returns the fixture logo (Brand / Curtain).
        case pickLogo
    }

    /// The selection the editor holds (set on the shared EditorShellSelection).
    enum Pick: Equatable {
        case none, zoom(Int), tilt(Int), highlight(Int), depth(Int), blur(Int), annotation(Int)
    }

    enum Step {
        case control(InspectorTab, String, Input)
        case select(Pick)
    }

    /// Slider targets sit 0.3 of a step above a stop, never on a half step,
    /// so geometry noise can't flip the rounding on either platform.
    static func sliderTarget(_ spec: InspectorSlider, fraction f: Double, range: ClosedRange<Double>? = nil) -> Double {
        let r = range ?? spec.range
        let raw = r.lowerBound + f * (r.upperBound - r.lowerBound)
        guard let step = spec.step, step > 0 else { return raw }
        let k = ((raw - r.lowerBound) / step).rounded(.down)
        return min(r.upperBound, r.lowerBound + (k + 0.3) * step)
    }

    private static func s(_ tab: InspectorTab, _ spec: InspectorSlider, _ f: Double) -> Step {
        .control(tab, spec.id, .slider(sliderTarget(spec, fraction: f)))
    }
    private static func t(_ tab: InspectorTab, _ id: String) -> Step { .control(tab, id, .toggle) }
    private static func c(_ tab: InspectorTab, _ id: String, _ n: Int) -> Step { .control(tab, id, .choose(n)) }
    private static func k(_ tab: InspectorTab, _ id: String, _ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> Step {
        .control(tab, id, .color(r, g, b, a))
    }
    private static func x(_ tab: InspectorTab, _ id: String, _ text: String) -> Step { .control(tab, id, .text(text)) }
    private static func b(_ tab: InspectorTab, _ id: String) -> Step { .control(tab, id, .tap) }
    private static func p(_ tab: InspectorTab, _ id: String, _ fx: Double, _ fy: Double) -> Step { .control(tab, id, .pad(fx, fy)) }

    static var steps: [Step] {
        let bg = InspectorTab.background, cu = InspectorTab.cursor, ca = InspectorTab.camera
        let au = InspectorTab.audio, ef = InspectorTab.effects, mo = InspectorTab.motion
        let su = InspectorTab.subtitles, br = InspectorTab.brand, an = InspectorTab.annotations
        var list: [Step] = [.select(.none)]
        // Background
        list += [
            c(bg, "background.type", 2), k(bg, "background.solid", 0.2, 0.4, 0.6),
            c(bg, "background.type", 0), k(bg, "background.gradientStart", 0.9, 0.1, 0.3),
            k(bg, "background.gradientEnd", 0.1, 0.2, 0.9, 0.8), s(bg, BackgroundPane.angle, 0.25),
            s(bg, BackgroundPane.blur, 0.37), s(bg, BackgroundPane.pixelate, 0.21), s(bg, BackgroundPane.halftone, 0.43),
            s(bg, BackgroundPane.grain, 0.65), s(bg, BackgroundPane.brightness, 0.31), s(bg, BackgroundPane.contrast, 0.77),
            s(bg, BackgroundPane.saturation, 0.58), s(bg, BackgroundPane.hue, 0.66),
            k(bg, "background.tint", 0.8, 0.6, 0.1), s(bg, BackgroundPane.tintAmount, 0.52),
            s(bg, BackgroundPane.vignette, 0.48), b(bg, "background.resetLook"),
            c(bg, "background.type", 1), c(bg, "background.type", 5), c(bg, "background.type", 0),
            t(bg, "background.deviceFrame"), b(bg, "background.placementReset"),
            c(bg, "background.placement", 3), p(bg, "background.placementPad", 0.1, 0.9),
            p(bg, "background.placementPad", 0.5, 0.2),
            s(bg, BackgroundPane.padding, 0.4), c(bg, "background.shape", 1), s(bg, BackgroundPane.corners, 0.55),
            s(bg, BackgroundPane.shadow, 0.33), s(bg, BackgroundPane.shadowOpacity, 0.72),
            c(bg, "background.menuBar", 2), x(bg, "background.menuBarTitle", "Studio Demo"),
            c(bg, "background.menuBarAlign", 2), x(bg, "background.menuBarClock", "10:09"),
            t(bg, "background.menuBarIcons"), s(bg, BackgroundPane.menuBarHeight, 0.62),
            c(bg, "background.menuBar", 1), c(bg, "background.menuBar", 0),
        ]
        // Cursor
        list += [
            t(cu, "cursor.show"), t(cu, "cursor.show"), c(cu, "cursor.style", 3), s(cu, CursorPane.size, 0.8),
            s(cu, CursorPane.tension, 0.6), s(cu, CursorPane.friction, 0.6), s(cu, CursorPane.mass, 0.27),
            t(cu, "cursor.fluid"), t(cu, "cursor.fluid"),
            t(cu, "cursor.smooth"), s(cu, CursorPane.smoothing, 0.7),
            t(cu, "cursor.autoHide"), s(cu, CursorPane.hideAfter, 0.45),
            t(cu, "cursor.loop"), t(cu, "cursor.stopEnd"), t(cu, "cursor.stopEnd"),
            s(cu, CursorPane.rippleSize, 0.5), k(cu, "cursor.rippleColor", 0.3, 0.9, 0.4), t(cu, "cursor.ripple"),
            t(cu, "cursor.ripple"),
            t(cu, "cursor.clickSound"), c(cu, "cursor.clickStyle", 2), b(cu, "cursor.clickTest"),
            s(cu, CursorPane.clickVolume, 0.61),
            t(cu, "cursor.keySound"), c(cu, "cursor.keyStyle", 3), b(cu, "cursor.keyTest"), s(cu, CursorPane.keyVolume, 0.39),
            c(cu, "cursor.keystrokePosition", 2), c(cu, "cursor.keystrokeAnimation", 1),
            s(cu, CursorPane.keystrokeSize, 0.44), t(cu, "cursor.keystrokeScope"),
            t(cu, "cursor.keystrokeOverlay"), t(cu, "cursor.keystrokeOverlay"),
        ]
        // Camera
        list += [
            t(ca, "camera.mirror"), c(ca, "camera.position", 1), p(ca, "camera.pad", 0.42, 0.61),
            p(ca, "camera.pad", 0.97, 0.03),
            c(ca, "camera.shape", 2), c(ca, "camera.orientation", 2), s(ca, CameraPane.size, 0.64),
            t(ca, "camera.shrink"), t(ca, "camera.stack"), s(ca, CameraPane.stackHeight, 0.5), s(ca, CameraPane.stackGap, 0.6),
            c(ca, "camera.background", 2), s(ca, CameraPane.edgeSoftness, 0.35), s(ca, CameraPane.edgeInset, 0.2),
            s(ca, CameraPane.popOut, 0.74), c(ca, "camera.cardFill", 0),
            k(ca, "camera.cardGradientStart", 0.95, 0.5, 0.2), k(ca, "camera.cardGradientEnd", 0.2, 0.3, 0.7),
            c(ca, "camera.cardFill", 2), k(ca, "camera.cardColor", 0.1, 0.6, 0.5), c(ca, "camera.cardFill", 1),
            s(ca, CameraPane.backgroundBlur, 0.55), c(ca, "camera.cardBorder", 1), s(ca, CameraPane.cardBorderWidth, 0.4),
            k(ca, "camera.cardBorderColor", 0.9, 0.9, 0.2), c(ca, "camera.cardBorder", 2), c(ca, "camera.background", 1),
            s(ca, CameraPane.brightness, 0.6), s(ca, CameraPane.contrast, 0.3), s(ca, CameraPane.saturation, 0.8),
            s(ca, CameraPane.hue, 0.27), c(ca, "camera.filter", 3), s(ca, CameraPane.ringLight, 0.45),
            s(ca, CameraPane.cornerRadius, 0.5), s(ca, CameraPane.borderWidth, 0.35),
            k(ca, "camera.borderColor", 0.7, 0.2, 0.9, 0.6), b(ca, "camera.borderColorReset"),
            s(ca, CameraPane.opacity, 0.66), p(ca, "camera.tiltPad", 0.4, -0.6),
            x(ca, "camera.tagText", "Ada Lovelace"), x(ca, "camera.tagSubtext", "Analyst"),
            c(ca, "camera.tagPosition", 2), k(ca, "camera.tagTextColor", 1, 0.9, 0.8),
            k(ca, "camera.tagFill", 0.1, 0.1, 0.3, 0.7), c(ca, "camera.background", 0), t(ca, "camera.show"),
            t(ca, "camera.show"),
        ]
        // Audio
        list += [
            s(au, AudioPane.system.slider, 0.43), s(au, AudioPane.microphone.slider, 0.0),
            s(au, AudioPane.microphone.slider, 0.82), s(au, AudioPane.voiceOver.slider, 0.91),
        ]
        // Motion (feel)
        list += [
            c(mo, "motion.speed", 3), s(mo, MotionFeelPane.zoomLevel, 0.48), s(mo, MotionFeelPane.follow, 0.27),
        ]
        // Effects — project-wide list, nothing selected
        list += [
            t(ef, "effects.slide"), c(ef, "effects.slideStyle", 2), s(ef, EffectsPane.slideBounce, 0.6),
            s(ef, EffectsPane.slideSpeed, 0.4), t(ef, "effects.slideDepth"), t(ef, "effects.slide"),
            t(ef, "effects.curtain"), c(ef, "effects.curtainCorner", 3), s(ef, EffectsPane.curtainLength, 0.5),
            k(ef, "effects.curtainColor", 0.3, 0.1, 0.4), b(ef, "effects.curtainColorReset"),
            .control(ef, "effects.curtainLogoChoose", .pickLogo),
            s(ef, EffectsPane.curtainLogoOpacity, 0.7), s(ef, EffectsPane.curtainLogoSize, 0.55),
            t(ef, "effects.curtainLogoTint"), k(ef, "effects.curtainLogoTintColor", 0.9, 0.3, 0.3),
            b(ef, "effects.curtainLogoRemove"), t(ef, "effects.curtain"),
            t(ef, "effects.parallax"), s(ef, EffectsPane.parallaxStrength, 0.55), t(ef, "effects.parallax"),
            t(ef, "effects.motionBlur"), s(ef, EffectsPane.motionBlurStrength, 0.65),
            // Zoom/Tilt toggles with nothing selected drop blocks at the playhead.
            t(ef, "blocks.zoom"),
        ]
        // Effects — the selected blocks
        list += [
            .select(.zoom(1)),
            s(ef, EffectBlocksPane.zoomLevel, 0.37), c(ef, "blocks.zoomSpeed", 4), t(ef, "blocks.followCursor"),
            p(ef, "blocks.focusPad", 0.62, 0.28), p(ef, "blocks.offsetPad", 0.8, 0.35), p(ef, "blocks.offsetPad", 0.505, 0.495),
            t(ef, "blocks.tilt"), p(ef, "blocks.tiltPad", -0.35, 0.5), c(ef, "blocks.tiltPreset", 2),
            s(ef, EffectBlocksPane.rotation, 0.2), c(ef, "blocks.tiltSpeed", 2), b(ef, "blocks.cinematic"),
            t(ef, "effects.slide"), t(ef, "effects.slide"),
            t(ef, "blocks.tilt"), t(ef, "blocks.zoom"),
            .select(.tilt(2)), t(ef, "blocks.zoom"), b(ef, "blocks.cinematic"),
            .select(.highlight(3)), s(ef, EffectBlocksPane.highlightOpacity, 0.6), b(ef, "blocks.removeHighlight"),
            .select(.depth(4)), s(ef, EffectBlocksPane.depthStrength, 0.4), s(ef, EffectBlocksPane.depthFalloff, 0.7),
            s(ef, EffectBlocksPane.depthCorner, 0.25), c(ef, "blocks.depthStyle", 1), s(ef, EffectBlocksPane.depthAngle, 0.3),
            b(ef, "blocks.removeDepth"),
            .select(.blur(5)), c(ef, "blocks.blurStyle", 1), s(ef, EffectBlocksPane.blurStrength, 0.8),
            t(ef, "blocks.blurAnimated"), b(ef, "blocks.removeBlur"),
            .select(.none),
        ]
        // Subtitles
        list += [
            .control(su, "subtitles.presets", .preset(3)), s(su, SubtitlePane.size, 0.45), c(su, "subtitles.font", 2),
            c(su, "subtitles.weight", 4), t(su, "subtitles.uppercase"), k(su, "subtitles.color", 0.9, 0.95, 0.6),
            c(su, "subtitles.position", 0), p(su, "subtitles.positionPad", 0.2, 0.7), p(su, "subtitles.positionPad", 0.52, 0.47),
            c(su, "subtitles.style", 1), k(su, "subtitles.background", 0.2, 0.0, 0.3, 0.8),
            k(su, "subtitles.highlight", 0.4, 1, 0.4), t(su, "subtitles.karaoke"),
            .control(su, "subtitles.captions", .caption(1, "Second line, edited")),
            .control(su, "subtitles.presets", .preset(1)),
            b(su, "subtitles.delete"), t(su, "subtitles.show"),
        ]
        // Brand
        list += [
            t(br, "brand.show"), .control(br, "brand.choose", .pickLogo),
            p(br, "brand.pad", 0.3, 0.97), p(br, "brand.pad", 0.03, 0.5),
            s(br, BrandPane.size, 0.33), s(br, BrandPane.opacity, 0.6), b(br, "brand.remove"),
        ]
        // Annotate
        list += [
            .select(.annotation(6)),
            x(an, "annotate.text", "Tap here"), s(an, AnnotationPane.fontSize, 0.4), c(an, "annotate.font", 3),
            c(an, "annotate.weight", 4), t(an, "annotate.uppercase"), k(an, "annotate.color", 1, 0.8, 0.2),
            t(an, "annotate.fill"), t(an, "annotate.fill"), k(an, "annotate.fillColor", 0.2, 0.2, 0.6, 0.9),
            s(an, AnnotationPane.corners, 0.6), s(an, AnnotationPane.opacity, 0.5), s(an, AnnotationPane.blackout, 0.02),
            s(an, AnnotationPane.blackout, 0.5), c(an, "annotate.buildIn", 5), c(an, "annotate.buildOut", 2),
            t(an, "annotate.shadow"), x(an, "annotate.start", "1.25"), x(an, "annotate.end", "1.5"),
            x(an, "annotate.end", "oops"), b(an, "annotate.atPlayhead"),
            .select(.annotation(7)), s(an, AnnotationPane.border, 0.3), t(an, "annotate.fill"),
            .select(.annotation(8)), .control(an, "annotate.border", .slider(sliderTarget(AnnotationPane.border, fraction: 0.5, range: 1...30))),
            b(an, "annotate.undoStroke"), b(an, "annotate.clearStrokes"),
            .select(.annotation(9)), s(an, AnnotationPane.tapSize, 0.66),
            .select(.annotation(10)), b(an, "annotate.delete"),
            .select(.none),
        ]
        return list
    }

    // MARK: - Recorder

    /// The project as flat `path=value` lines — settings, every region list,
    /// annotations, captions, and the selection — for diffing.
    static func snapshot(_ project: Project, selection: EditorShellSelection) -> [String: String] {
        var out: [String: String] = [:]
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        func add<T: Encodable>(_ name: String, _ value: T) {
            guard let data = try? encoder.encode(value),
                  let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return }
            flatten(json, path: name, into: &out)
        }
        add("settings", project.settings)
        add("zoom", project.zoomRegions)
        add("tilt", project.tiltRegions)
        add("highlight", project.highlightRegions)
        add("depth", project.focusRegions)
        add("blur", project.blurRegions)
        add("annotations", project.annotations)
        add("subtitles", project.subtitles)
        add("cameraLayouts", project.cameraLayoutRegions)
        out["selection"] = selectionLine(selection)
        return out
    }

    static func selectionLine(_ s: EditorShellSelection) -> String {
        func n(_ id: UUID?) -> String { id.map(name) ?? "-" }
        return "zoom=\(n(s.selectedZoomID)) tilt=\(n(s.selectedTiltID)) highlight=\(n(s.selectedHighlightID)) "
            + "depth=\(n(s.selectedDepthFocusID)) blur=\(n(s.selectedBlurID)) annotation=\(n(s.selectedAnnotationID)) "
            + "tab=\(s.inspectorTab.rawValue)"
    }

    static func name(_ id: UUID) -> String { names[id] ?? "new" }

    private static func flatten(_ value: Any, path: String, into out: inout [String: String]) {
        switch value {
        case let dict as [String: Any]:
            for (key, v) in dict { flatten(v, path: "\(path).\(key)", into: &out) }
        case let array as [Any]:
            out["\(path).count"] = "\(array.count)"
            for (i, v) in array.enumerated() { flatten(v, path: "\(path)[\(i)]", into: &out) }
        default:
            out[path] = leaf(value)
        }
    }

    private static func leaf(_ value: Any) -> String {
        if value is NSNull { return "null" }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            let d = number.doubleValue
            let text = String(format: "%.6f", d)
            return text == "-0.000000" ? "0.000000" : text
        }
        if let string = value as? String { return "\"\(mask(string))\"" }
        return "\(value)"
    }

    /// Fresh ids and freshly named media vary run to run: name them stably.
    static func mask(_ string: String) -> String {
        if let id = UUID(uuidString: string) { return name(id) }
        var s = string
        for prefix in ["watermark-", "curtain-logo-"] {
            if let range = s.range(of: prefix + "[0-9A-F]{8}", options: .regularExpression) {
                s.replaceSubrange(range, with: prefix + "XXXXXXXX")
            }
        }
        return s
    }

    /// One step's record: what it wrote, where the selection is, what shows.
    static func describe(_ step: Step) -> String {
        switch step {
        case .select(let pick): return "select \(pick)"
        case .control(let tab, let id, let input):
            let what: String
            switch input {
            case .slider(let v): what = String(format: "slider %.6f", v)
            case .toggle: what = "toggle"
            case .choose(let n): what = "choose \(n)"
            case .color(let r, let g, let b, let a): what = String(format: "color %.3f,%.3f,%.3f,%.3f", r, g, b, a)
            case .text(let t): what = "text \"\(t)\""
            case .tap: what = "tap"
            case .pad(let fx, let fy): what = String(format: "pad %.3f,%.3f", fx, fy)
            case .preset(let n): what = "preset \(n)"
            case .caption(let n, let t): what = "caption \(n) \"\(t)\""
            case .pickLogo: what = "pick logo"
            }
            return "[\(tab.rawValue)] \(id) \(what)"
        }
    }

    static func diff(_ before: [String: String], _ after: [String: String]) -> [String] {
        let keys = Set(before.keys).union(after.keys).filter { $0 != "selection" }.sorted()
        return keys.compactMap { key in
            let a = before[key], b = after[key]
            guard a != b else { return nil }
            return "  \(key)=\(b ?? "<removed>")"
        }
    }

    /// The ids a pane's comparable controls carry (spec'd controls; custom
    /// rows and feature keys are each front end's own).
    static func comparableIDs(_ tab: InspectorTab) -> Set<String> {
        var ids = Set<String>()
        for section in tab.sections {
            for row in section.rows {
                switch row {
                case .slider(let s): ids.insert(s.id)
                case .toggle(let t): ids.insert(t.id)
                case .choice(let c): ids.insert(c.id)
                case .color(let c): ids.insert(c.id)
                case .colorPair(_, let a, let b): ids.insert(a.id); ids.insert(b.id)
                case .text(let t): ids.insert(t.id)
                case .action(let a): ids.insert(a.id)
                case .actions(let list): list.forEach { ids.insert($0.id) }
                case .caption(let c): ids.insert(c.id)
                case .feature, .custom: break
                }
            }
        }
        return ids
    }

    // MARK: - Running

    /// What a front end supplies to replay the script.
    struct Driver {
        /// Show `tab` (and let the pane settle).
        var showTab: (InspectorTab) async -> Void
        /// Apply a selection (the editor's shared selection), then settle.
        var select: (Pick) async -> Void
        /// Is the control with `id` on screen in the shown pane?
        var isVisible: (String) async -> Bool
        /// The comparable ids visible in the shown pane, sorted.
        var visibleIDs: (InspectorTab) -> [String]
        /// Drive the control; false when it could not (not found).
        var drive: (String, Input) async -> Bool
        /// After a step: the edit settles, the pane re-renders.
        var settle: () async -> Void
        /// Per-step hook (iOS checks undo here). Its findings go to the
        /// front end's own log, never into the compared transcript.
        var afterStep: (Step, [String: String], [String: String]) async -> Void = { _, _, _ in }
    }

    /// Replays the script; returns the transcript lines.
    /// `script` / `title` replace the nine-pane script (EffectsParity replays its own).
    static func run(project: Project, selection: EditorShellSelection, driver: Driver,
                    script: [Step]? = nil, title: String? = nil) async -> [String] {
        var lines = [title ?? header]
        var lastVisible: [String] = []
        var lastTab: InspectorTab?
        for step in script ?? steps {
            var line = describe(step)
            let before = snapshot(project, selection: selection)
            switch step {
            case .select(let pick):
                await driver.select(pick)
            case .control(let tab, let id, let input):
                if lastTab != tab {
                    await driver.showTab(tab)
                    lastTab = tab
                }
                if await !driver.isVisible(id) {
                    line += " — HIDDEN"
                } else if await driver.drive(id, input) == false {
                    line += " — NOT DRIVEN"
                }
            }
            await driver.settle()
            let after = snapshot(project, selection: selection)
            lines.append(line)
            lines += diff(before, after)
            if before["selection"] != after["selection"] || !(line.hasPrefix("[")) {
                lines.append("  selection: \(after["selection"] ?? "")")
            }
            if let tab = lastTab {
                let visible = driver.visibleIDs(tab)
                if visible != lastVisible {
                    lines.append("  visible: " + visible.joined(separator: ","))
                    lastVisible = visible
                }
            }
            await driver.afterStep(step, before, after)
        }
        return lines
    }

    /// The source of StudioHarness/InspectorValuesGoldens.swift for a fresh
    /// Mac transcript (what `--refreeze` writes for review).
    static func goldenSource(for transcript: String) -> String {
        let body = transcript.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "    " + $0 }.joined(separator: "\n")
        return """
        // The frozen Mac inspector-values transcript (`--inspector-values-test`), the
        // reference the iOS `--inspector` gate is held to. Regenerate with
        // `CaptureCat --inspector-values-test <dir> --refreeze` and review the diff —
        // never refreeze to make a red gate green.
        enum InspectorValuesGoldens {
            static let transcript = #\"\"\"
        \(body)
            \"\"\"#
        }

        """
    }

    /// Scores a transcript against the frozen Mac reference.
    static func verdict(_ lines: [String], against golden: String) -> (pass: Bool, report: [String]) {
        let reference = golden.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !golden.isEmpty else { return (false, ["no frozen reference — run the Mac --inspector-values-test --refreeze"]) }
        var report: [String] = []
        let count = max(lines.count, reference.count)
        for i in 0..<count {
            let a = i < lines.count ? lines[i] : "<missing>"
            let b = i < reference.count ? reference[i] : "<missing>"
            if a != b {
                report.append("line \(i + 1):\n    got  \(a)\n    want \(b)")
                if report.count >= 25 { report.append("…"); break }
            }
        }
        return (report.isEmpty, report)
    }
}
