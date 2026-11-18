import CoreGraphics
import Foundation

/// Effects parity (2026-11-18: "all the effect settings on mac must be
/// available on ios — 1:1"), shared by the Mac `--effects-parity` harness
/// (EffectsParityHarness: the REAL Mac Effects + Motion panes in the editor's
/// inspector column) and the iOS `--effects-parity` lab (EffectsParityLab:
/// the REAL editor — on a phone through the drill-down tool bar and its
/// panels, on an iPad through the column).
///
/// 1. **Inventory.** For every fixture state below, each side walks its LIVE
///    control views (not the spec) and lists every effect control in order —
///    section, id, kind, title, range / step / readouts, items, value, the
///    caption's copy, the pad's pill, the preview's mode — with ONE line
///    format (`line`). A control a front end draws that the walker does not
///    recognise is listed as `?<Class>` and never matches, so a Mac-only row
///    cannot hide. The two lists must be identical.
/// 2. **Values.** `valueSteps` sets every effect control to non-default values
///    through the real control (InspectorValuesTranscript's recorder); the
///    iOS transcript must equal the Mac's line for line, live — no frozen
///    golden.
@MainActor
enum EffectsParity {

    // MARK: - Fixture states

    struct State {
        let name: String
        let tab: InspectorTab
        let prepare: (Project, EditorShellSelection) -> Void
    }

    static let zoomTiltID = InspectorValuesTranscript.uuid(13)

    /// The fixture project (InspectorValuesTranscript's) with every effect
    /// OFF, so each state turns on exactly what it names.
    static func makeProject(folder: URL) -> Project {
        let project = InspectorValuesTranscript.makeProject(folder: folder)
        let s = project.settings
        s.introSlideStyle = .off
        s.curtainUnveilCorner = .off
        s.parallaxStrength = 0
        s.motionBlur = false
        return project
    }

    static let curtainLogoName = "curtain-logo-FIXTURE0.png"

    private static func select(_ s: EditorShellSelection, zoom: UUID? = nil, tilt: UUID? = nil,
                               highlight: UUID? = nil, depth: UUID? = nil, blur: UUID? = nil) {
        s.selectedZoomID = zoom
        s.selectedTiltID = tilt
        s.selectedHighlightID = highlight
        s.selectedDepthFocusID = depth
        s.selectedBlurID = blur
        s.selectedAnnotationID = nil
    }

    private static let id = InspectorValuesTranscript.uuid

    static var states: [State] {
        [
            State(name: "nothing selected, every effect off", tab: .effects) { _, s in select(s) },
            State(name: "slide on", tab: .effects) { p, s in
                p.settings.introSlideStyle = .left
                p.settings.introSlideBounce = 0.35
                p.settings.introSlideDepth = true
                select(s)
            },
            State(name: "curtain on, no logo", tab: .effects) { p, s in
                p.settings.curtainUnveilCorner = .bottomRight
                select(s)
            },
            State(name: "curtain on, custom colour, tinted logo", tab: .effects) { p, s in
                p.settings.curtainUnveilCorner = .topRight
                p.settings.curtainColor = CodableColor(red: 0.3, green: 0.1, blue: 0.4, opacity: 1)
                if let folder = p.videoURL?.deletingLastPathComponent() {
                    let logo = folder.appendingPathComponent(curtainLogoName)
                    if !FileManager.default.fileExists(atPath: logo.path) {
                        try? FileManager.default.copyItem(at: InspectorValuesTranscript.logoURL(in: folder), to: logo)
                    }
                }
                p.settings.curtainLogoFileName = curtainLogoName
                p.settings.curtainLogoTint = CodableColor(red: 0.9, green: 0.3, blue: 0.3, opacity: 1)
                select(s)
            },
            State(name: "parallax on", tab: .effects) { p, s in
                p.settings.parallaxStrength = 0.65
                select(s)
            },
            State(name: "motion blur on", tab: .effects) { p, s in
                p.settings.motionBlur = true
                p.settings.motionBlurStrength = 0.8
                select(s)
            },
            State(name: "every effect on", tab: .effects) { p, s in
                p.settings.introSlideStyle = .top
                p.settings.curtainUnveilCorner = .bottomLeft
                p.settings.parallaxStrength = 0.4
                p.settings.motionBlur = true
                select(s)
            },
            State(name: "zoom block selected", tab: .effects) { p, s in
                p.zoomRegions[0].animationStyle = .snappy
                p.zoomRegions[0].cardOffsetX = 0.1
                select(s, zoom: id(1))
            },
            State(name: "tilt block selected", tab: .effects) { _, s in select(s, tilt: id(2)) },
            State(name: "zoomtilt block selected", tab: .effects) { p, s in
                if !p.tiltRegions.contains(where: { $0.id == zoomTiltID }) {
                    p.tiltRegions.append(TiltRegion(id: zoomTiltID, startTime: 2, endTime: 5, pitch: 8, yaw: -25, roll: -2))
                }
                select(s, zoom: id(1), tilt: zoomTiltID)
            },
            State(name: "highlight selected", tab: .effects) { _, s in select(s, highlight: id(3)) },
            State(name: "depth focus (Area) selected", tab: .effects) { p, s in
                p.focusRegions[0].style = .area
                select(s, depth: id(4))
            },
            State(name: "depth focus (Tilt Shift) selected", tab: .effects) { p, s in
                p.focusRegions[0].style = .tiltShift
                select(s, depth: id(4))
            },
            State(name: "blur (Blur) selected", tab: .effects) { p, s in
                p.blurRegions[0].style = .blur
                select(s, blur: id(5))
            },
            State(name: "blur (Pixelate) selected", tab: .effects) { p, s in
                p.blurRegions[0].style = .pixelate
                p.blurRegions[0].animated = true
                select(s, blur: id(5))
            },
            State(name: "motion tab", tab: .motion) { p, s in
                p.settings.animationSpeed = .quick
                select(s)
            },
        ]
    }

    /// Undoes what any state set (each state starts from the clean fixture).
    /// Field by field: the panes hold the settings OBJECT, so it is never
    /// replaced.
    static func reset(_ project: Project, folder: URL) {
        let fresh = makeProject(folder: folder)
        let s = project.settings, f = fresh.settings
        s.introSlideStyle = f.introSlideStyle
        s.introSlideBounce = f.introSlideBounce
        s.introSlideDepth = f.introSlideDepth
        s.introSlideSpeed = f.introSlideSpeed
        s.curtainUnveilCorner = f.curtainUnveilCorner
        s.curtainColor = f.curtainColor
        s.curtainLogoFileName = f.curtainLogoFileName
        s.curtainLogoTint = f.curtainLogoTint
        s.parallaxStrength = f.parallaxStrength
        s.motionBlur = f.motionBlur
        s.motionBlurStrength = f.motionBlurStrength
        s.animationSpeed = f.animationSpeed
        project.zoomRegions = fresh.zoomRegions
        project.tiltRegions = fresh.tiltRegions
        project.highlightRegions = fresh.highlightRegions
        project.focusRegions = fresh.focusRegions
        project.blurRegions = fresh.blurRegions
    }

    // MARK: - Inventory lines

    /// One control as a front end draws it.
    struct Item: Equatable {
        var section: String
        var id: String
        var kind: String
        var title: String
        var detail: String

        var line: String { "\(section) | \(id) | \(kind) | \(title) | \(detail)" }
    }

    static func number(_ v: Double) -> String {
        let s = String(format: "%.3f", v)
        return s == "-0.000" ? "0.000" : s
    }

    /// A slider's line detail: range, step, the readout now and at both ends
    /// and the middle (the value format).
    static func sliderDetail(range: ClosedRange<Double>, step: Double?, value: String,
                             readout: (Double) -> String) -> String {
        let mid = (range.lowerBound + range.upperBound) / 2
        return "range=\(number(range.lowerBound))…\(number(range.upperBound)) step=\(step.map(number) ?? "continuous") "
            + "value=\(value) fmt=\(readout(range.lowerBound))/\(readout(mid))/\(readout(range.upperBound))"
    }

    static func choiceDetail(id: String, items: [String], selected: Int?) -> String {
        let shown = macStaleSelection.contains(id) ? "not-compared" : (selected.map(String.init) ?? "-")
        return "items=\(items.joined(separator: ",")) selected=\(shown)"
    }

    /// Chip rows whose SELECTED chip the Mac never refreshes (a Mac display
    /// defect, reported, not ported): Effects ▸ Tilt's presets keep the
    /// last-clicked chip (Flat at first) whatever the block's angles; iOS
    /// marks the preset the angles match, or none. Their items still compare.
    static let macStaleSelection: Set<String> = ["blocks.tiltPreset"]

    static func colorDetail(r: Double, g: Double, b: Double, a: Double) -> String {
        "color=\(number(r)),\(number(g)),\(number(b)),\(number(a))"
    }

    static func captionDetail(text: String, full: String?) -> String {
        "text=\(text) full=\(full ?? "-")"
    }

    /// Controls the iOS editor has and the Mac pane does not, by design —
    /// listed, never silently dropped: the Mac's Auto Zoom lives on its
    /// timeline toolbar; on a phone the pane is where it is reached.
    static let iosOnly: Set<String> = ["feature.autoZoom"]

    /// The ids the walkers treat as effect-pane rows (everything else in the
    /// pane is chrome) — the spec's rows plus the leaf controls of its custom
    /// rows.
    static func knownIDs(_ tab: InspectorTab) -> Set<String> {
        var ids = InspectorValuesTranscript.comparableIDs(tab)
        for section in tab.sections {
            for row in section.rows {
                if case .custom(let id, _) = row { ids.insert(id) }
                if case .feature(let f, _) = row { ids.insert("feature.\(f.rawValue)") }
            }
        }
        if tab == .effects { ids.formUnion(["effects.curtainLogoChoose", "effects.curtainLogoRemove"]) }
        return ids
    }

    /// The diff of two inventories (empty = parity). iOS-only ids are
    /// reported as notes, not differences.
    static func compare(mac: [String], ios: [String]) -> (diff: [String], notes: [String]) {
        func isIOSOnly(_ line: String) -> Bool {
            let parts = line.components(separatedBy: " | ")
            return parts.count > 1 && iosOnly.contains(parts[1])
        }
        let notes = ios.filter(isIOSOnly).map { "iOS-only (allowed): \($0)" }
        let iosLines = ios.filter { !isIOSOnly($0) }
        var diff: [String] = []
        let count = max(mac.count, iosLines.count)
        for i in 0..<count {
            let a = i < mac.count ? mac[i] : "<missing>"
            let b = i < iosLines.count ? iosLines[i] : "<missing>"
            if a != b { diff.append("line \(i + 1):\n    mac  \(a)\n    ios  \(b)") }
        }
        return (diff, notes)
    }

    // MARK: - Values

    private static func s(_ tab: InspectorTab, _ spec: InspectorSlider, _ f: Double) -> InspectorValuesTranscript.Step {
        .control(tab, spec.id, .slider(InspectorValuesTranscript.sliderTarget(spec, fraction: f)))
    }
    private static func t(_ tab: InspectorTab, _ id: String) -> InspectorValuesTranscript.Step { .control(tab, id, .toggle) }
    private static func c(_ tab: InspectorTab, _ id: String, _ n: Int) -> InspectorValuesTranscript.Step {
        .control(tab, id, .choose(n))
    }
    private static func k(_ tab: InspectorTab, _ id: String, _ r: Double, _ g: Double, _ b: Double,
                          _ a: Double = 1) -> InspectorValuesTranscript.Step {
        .control(tab, id, .color(r, g, b, a))
    }
    private static func b(_ tab: InspectorTab, _ id: String) -> InspectorValuesTranscript.Step { .control(tab, id, .tap) }
    private static func p(_ tab: InspectorTab, _ id: String, _ fx: Double, _ fy: Double) -> InspectorValuesTranscript.Step {
        .control(tab, id, .pad(fx, fy))
    }

    /// Every effect control of both panes, each to non-default values, in
    /// every state that shows it.
    static var valueSteps: [InspectorValuesTranscript.Step] {
        let ef = InspectorTab.effects, mo = InspectorTab.motion
        typealias E = EffectsPane
        typealias B = EffectBlocksPane
        typealias M = MotionFeelPane
        var list: [InspectorValuesTranscript.Step] = [.select(.none)]
        // Motion (feel)
        list += [
            c(mo, "motion.speed", 0), c(mo, "motion.speed", 2), c(mo, "motion.speed", 3),
            s(mo, M.zoomLevel, 0.83), s(mo, M.zoomLevel, 0.04), s(mo, M.follow, 0.15), s(mo, M.follow, 0.96),
        ]
        // Slide
        list += [
            t(ef, "effects.slide"), c(ef, "effects.slideStyle", 0), c(ef, "effects.slideStyle", 2),
            c(ef, "effects.slideStyle", 3), s(ef, E.slideBounce, 0.01), s(ef, E.slideBounce, 0.85),
            s(ef, E.slideSpeed, 0.7), s(ef, E.slideSpeed, 0.02), t(ef, "effects.slideDepth"), t(ef, "effects.slideDepth"),
            t(ef, "effects.slideDepth"), t(ef, "effects.slide"),
        ]
        // Curtain Unveil
        list += [
            t(ef, "effects.curtain"), c(ef, "effects.curtainCorner", 1), c(ef, "effects.curtainCorner", 2),
            s(ef, E.curtainLength, 0.9), s(ef, E.curtainLength, 0.05),
            k(ef, "effects.curtainColor", 0.2, 0.6, 0.3), b(ef, "effects.curtainColorReset"),
            k(ef, "effects.curtainColor", 0.9, 0.8, 0.1, 0.7),
            .control(ef, "effects.curtainLogoChoose", .pickLogo),
            s(ef, E.curtainLogoOpacity, 0.3), s(ef, E.curtainLogoSize, 0.9), s(ef, E.curtainLogoSize, 0.0),
            t(ef, "effects.curtainLogoTint"), k(ef, "effects.curtainLogoTintColor", 0.1, 0.5, 0.9),
            t(ef, "effects.curtainLogoTint"), t(ef, "effects.curtainLogoTint"),
            .control(ef, "effects.curtainLogoChoose", .pickLogo),
            b(ef, "effects.curtainLogoRemove"), t(ef, "effects.curtain"),
        ]
        // Parallax, Motion Blur
        list += [
            t(ef, "effects.parallax"), s(ef, E.parallaxStrength, 0.02), s(ef, E.parallaxStrength, 0.95),
            t(ef, "effects.parallax"), t(ef, "effects.motionBlur"), s(ef, E.motionBlurStrength, 0.15),
            s(ef, E.motionBlurStrength, 0.97), t(ef, "effects.motionBlur"),
        ]
        // Tilt and zoom with nothing selected: blocks at the playhead.
        list += [
            t(ef, "blocks.tilt"),
            p(ef, "blocks.tiltPad", 0.6, -0.4), c(ef, "blocks.tiltPreset", 4), s(ef, B.rotation, 0.9),
            c(ef, "blocks.tiltSpeed", 5), c(ef, "blocks.tiltSpeed", 0), t(ef, "blocks.zoom"),
            s(ef, B.zoomLevel, 0.55), b(ef, "blocks.cinematic"), t(ef, "blocks.zoom"), t(ef, "blocks.tilt"),
        ]
        // The zoom block
        list += [
            .select(.zoom(1)),
            s(ef, B.zoomLevel, 0.03), s(ef, B.zoomLevel, 0.97), c(ef, "blocks.zoomSpeed", 1), c(ef, "blocks.zoomSpeed", 3),
            c(ef, "blocks.zoomSpeed", 5), c(ef, "blocks.zoomSpeed", 0), t(ef, "blocks.followCursor"),
            t(ef, "blocks.followCursor"), t(ef, "blocks.followCursor"),
            p(ef, "blocks.focusPad", 0.15, 0.85), p(ef, "blocks.focusPad", 0.9, 0.1),
            p(ef, "blocks.offsetPad", 0.2, 0.7), p(ef, "blocks.offsetPad", 0.5, 0.5),
            t(ef, "effects.slide"), c(ef, "effects.slideStyle", 1), t(ef, "effects.slide"),
            t(ef, "blocks.tilt"), p(ef, "blocks.tiltPad", -0.8, 0.8), c(ef, "blocks.tiltPreset", 1),
            b(ef, "blocks.cinematic"), t(ef, "blocks.tilt"), t(ef, "blocks.zoom"),
        ]
        // The tilt block
        list += [
            .select(.tilt(2)),
            p(ef, "blocks.tiltPad", 0.9, -0.9), c(ef, "blocks.tiltPreset", 0), c(ef, "blocks.tiltPreset", 3),
            s(ef, B.rotation, 0.05), c(ef, "blocks.tiltSpeed", 2), b(ef, "blocks.cinematic"),
        ]
        list += [
            .select(.tilt(2)), t(ef, "blocks.zoom"), s(ef, B.zoomLevel, 0.25),
        ]
        // Focus lane
        list += [
            .select(.highlight(3)), s(ef, B.highlightOpacity, 0.95), s(ef, B.highlightOpacity, 0.02),
            b(ef, "blocks.removeHighlight"),
            .select(.depth(4)), c(ef, "blocks.depthStyle", 0), s(ef, B.depthCorner, 0.8), s(ef, B.depthStrength, 0.9),
            s(ef, B.depthFalloff, 0.1), c(ef, "blocks.depthStyle", 1), s(ef, B.depthAngle, 0.85),
            s(ef, B.depthAngle, 0.1), b(ef, "blocks.removeDepth"),
            .select(.blur(5)), s(ef, B.blurStrength, 0.2), c(ef, "blocks.blurStyle", 1), t(ef, "blocks.blurAnimated"),
            t(ef, "blocks.blurAnimated"), c(ef, "blocks.blurStyle", 0), b(ef, "blocks.removeBlur"),
            .select(.none),
        ]
        return list
    }

    static let valuesHeader = "== effects values (InspectorValuesTranscript fixture, every effect off)"
}
