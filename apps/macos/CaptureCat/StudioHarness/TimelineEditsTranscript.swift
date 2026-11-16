import CoreGraphics
import Foundation

/// The timeline-edits transcript, shared by the Mac `--timeline-edits-test`
/// (TimelineEditsHarness, the real TimelineViewController) and the iOS
/// `--timeline-edits` gate (StudioLab, the real StudioTimelineViewController):
/// the fixture project, the state lines every op records, and the verdict
/// against the frozen golden (`TimelineEditsGoldens`). Both platforms write
/// the transcript with this one recorder, so a difference is behaviour, not
/// formatting. Moved out of TimelineEditsHarness in Studio 4c.
@MainActor
enum TimelineEditsTranscript {
    static func uuid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-B000-%012d", n))!
    }

    /// The first transcript line — names the fixture below.
    static let header = "== timeline edits (fixture: 20 s, linked zoom+tilt 2–5, zoom 8–10, blur 1–3, highlight 6–8, depth 11–13, camera 14–17, intro slide on the linked block)"

    /// 20 s fixture: linked zoom+tilt 2–5, zoom 8–10, blur 1–3, highlight 6–8,
    /// depth 11–13, camera 14–17, a text + an arrow, one voice clip (missing
    /// file) and an intro slide joined to the linked block.
    static func makeProject() -> Project {
        let project = PreviewParityHarness.makeFixtureProject(duration: 20)
        project.previewCanvasSize = CGSize(width: 960, height: 540)
        let p = project
        p.zoomRegions = [
            ZoomRegion(id: uuid(1), startTime: 2, endTime: 5, zoomLevel: 1.8,
                       focalPoint: CGPoint(x: 0.4, y: 0.4)),
            ZoomRegion(id: uuid(2), startTime: 8, endTime: 10, zoomLevel: 1.5),
        ]
        p.tiltRegions = [TiltRegion(id: uuid(3), startTime: 2, endTime: 5, pitch: 12, yaw: -4, roll: 1)]
        p.blurRegions = [BlurRegion(id: uuid(4), startTime: 1, endTime: 3)]
        p.highlightRegions = [HighlightRegion(id: uuid(5), startTime: 6, endTime: 8)]
        p.focusRegions = [FocusRegion(id: uuid(6), startTime: 11, endTime: 13)]
        p.cameraLayoutRegions = [CameraLayoutRegion(id: uuid(7), startTime: 14, endTime: 17, mode: .sideBySide)]
        var text = Annotation(id: uuid(8), type: .text, startTime: 1, endTime: 4)
        text.text = "Hello"
        let arrow = Annotation(id: uuid(9), type: .arrow, startTime: 5, endTime: 8)
        p.annotations = [text, arrow]
        p.voiceOverClips = [VoiceOverClip(id: uuid(10), fileName: "timeline-edits-fixture-missing.m4a",
                                          startTime: 3, duration: 4)]
        p.settings.introSlideStyle = .bottom
        p.settings.introSlideStart = 2
        p.settings.introSlideDuration = 3
        return project
    }

    /// Coverage: (op label, a line its block must contain) — proves the op
    /// really reached its code path rather than silently no-opping.
    static let required: [(String, String)] = [
        ("add zoom at", "undo top: Add Zoom"),
        ("add tilt at", "undo top: Add Tilt"),
        ("showcase", "undo top: Add Showcase"),
        ("scale down", "undo top: Add Scale Down"),
        ("zoom level", "undo top: Zoom Level"),
        ("tilt to block", "undo top: Add Tilt to Block"),
        ("zoom to block", "undo top: Add Zoom to Block"),
        ("move linked block", "intro: Bottom start=3.000000"),
        ("duplicate linked", "undo top: Duplicate Effect"),
        ("duplicate zoom", "undo top: Duplicate Zoom"),
        ("duplicate tilt", "undo top: Duplicate Tilt"),
        ("delete linked block", "undo top: Delete Effect"),
        ("remove zoom", "undo top: Delete Zoom"),
        ("remove tilt", "undo top: Delete Tilt"),
        ("add blur at", "undo top: Add Blur"),
        ("add highlight at", "undo top: Add Highlight"),
        ("depth focus", "undo top: Add Depth Focus"),
        ("draw pixelate", "undo top: Add Pixelate"),
        ("camera layout", "undo top: Add Camera Layout"),
        ("cutout look", "undo top: Add Cutout"),
        ("FOCUS lane full", "events: -"),
        ("duplicate blur", "undo top: Duplicate Blur"),
        ("duplicate highlight", "undo top: Duplicate Highlight"),
        ("commit highlight times", "hl[0]:"),
        ("commit focus times", "focus[0]:"),
        ("commit camera times", "cam[0]:"),
        ("commit blur times", "blur[0]:"),
        ("menu: Camera on Left", "undo top: Camera on Left"),
        ("menu: Full Height", "undo top: Full Height"),
        ("menu: Paste Layout", "undo top: Paste Layout"),
        ("delete focus: highlight", "undo top: Delete Highlight"),
        ("delete focus: depth", "undo top: Delete Depth Focus"),
        ("delete focus: camera", "undo top: Delete Camera Layout"),
        ("delete focus: blur", "undo top: Delete Blur"),
        ("add text", "undo top: Add Label"),
        ("add callout", "undo top: Add Look here"),
        ("add tap", "undo top: Add Tap"),
        ("commit annotation times", "undo top: Edit Annotation Timing"),
        ("select annotation off-playhead seeks", "playhead: 5.050000"),
        ("recolor", "undo top: Recolor Annotation"),
        ("font", "font=Avenir"),
        ("background color", "bg=on"),
        ("size on a tap", "size=40.000000"),
        ("pill color is the next default", "color=0.100,0.200,0.900"),
        ("delete annotation", "undo top: Delete Annotation"),
        ("slice at", "undo top: Split Clip"),
        ("⌘B", "undo top: Split Clip"),
        ("delete split", "undo top: Remove Split"),
        ("delete clip", "undo top: Delete Clip"),
        ("add speed range", "undo top: Add Speed"),
        ("change speed", "undo top: Change Speed"),
        ("duplicate speed", "undo top: Duplicate Speed"),
        ("delete speed", "undo top: Delete Speed"),
        ("delete voice", "undo top: Delete Voice Over"),
        ("enable intro", "intro: Bottom"),
        ("resize intro", "intro:"),
        ("move intro", "intro:"),
        ("delete intro", "undo top: Delete Slide"),
        ("enable curtain", "curtain: Top Left"),
        ("resize curtain", "curtain:"),
        ("delete curtain", "undo top: Delete Curtain Unveil"),
        ("unwind", "undo: "),
    ]

    /// Every coverage miss and golden line difference (at most 40 shown);
    /// empty = the transcript is the frozen one.
    static func failures(for lines: [String]) -> [String] {
        var failures: [String] = []
        for (label, marker) in required where !block(lines, label).contains(where: { $0.contains(marker) }) {
            failures.append("coverage: op \"\(label)\" never shows \"\(marker)\"")
        }
        let golden = TimelineEditsGoldens.transcript
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if golden != lines {
            var shown = 0
            for i in 0..<max(golden.count, lines.count) where shown < 40 {
                let g = i < golden.count ? golden[i] : "<missing>"
                let l = i < lines.count ? lines[i] : "<missing>"
                if g != l {
                    failures.append("line \(i + 1):\n    - \(g)\n    + \(l)")
                    shown += 1
                }
            }
            if golden.count != lines.count {
                failures.append("golden has \(golden.count) lines, live has \(lines.count)")
            }
        }
        return failures
    }

    /// The lines recorded for the first entry whose label contains `label`.
    static func block(_ lines: [String], _ label: String) -> [String] {
        guard let start = lines.firstIndex(where: { !$0.hasPrefix(" ") && $0.contains(label) }) else { return [] }
        let rest = lines[(start + 1)...]
        let end = rest.firstIndex(where: { !$0.hasPrefix(" ") }) ?? lines.endIndex
        return Array(lines[start..<end])
    }

    // MARK: - Recorder

    /// Records the model, the selection and the playhead of a timeline host
    /// as text lines, emitting only what changed since the last record.
    final class Recorder {
        let project: Project
        let host: TimelineEditing
        private var lastState: [(String, String)] = []

        init(project: Project, host: TimelineEditing) {
            self.project = project
            self.host = host
        }

        /// State lines that changed since the last record, in a fixed order.
        func diffState() -> [String] {
            let now = state()
            let before = Dictionary(lastState, uniquingKeysWith: { a, _ in a })
            let nowKeys = Set(now.map(\.0))
            var lines = now.compactMap { key, value in before[key] == value ? nil : "   \(key): \(value)" }
            for (key, _) in lastState where !nowKeys.contains(key) { lines.append("   \(key): <gone>") }
            lastState = now
            return lines
        }

        private func state() -> [(String, String)] {
            let p = project
            let selection = host.selection
            var s: [(String, String)] = []
            for (i, z) in p.zoomRegions.enumerated() {
                s.append(("zoom[\(i)]", "\(span(z.startTime, z.endTime)) level=\(f(z.zoomLevel)) focal=\(pt(z.focalPoint)) "
                          + "anim=\(z.animationStyle?.rawValue ?? "nil") off=\(opt(z.cardOffsetX)),\(opt(z.cardOffsetY))"))
            }
            for (i, t) in p.tiltRegions.enumerated() {
                s.append(("tilt[\(i)]", "\(span(t.startTime, t.endTime)) p=\(f(t.pitch)) y=\(f(t.yaw)) r=\(f(t.roll))"))
            }
            for (i, b) in p.blurRegions.enumerated() {
                s.append(("blur[\(i)]", "\(span(b.startTime, b.endTime)) \(b.label) \(rect(b.rect)) i=\(f(b.intensity)) \(b.style.rawValue)"))
            }
            for (i, h) in p.highlightRegions.enumerated() {
                s.append(("hl[\(i)]", "\(span(h.startTime, h.endTime)) \(h.label) \(rect(h.rect)) o=\(f(h.opacity))"))
            }
            for (i, r) in p.focusRegions.enumerated() {
                s.append(("focus[\(i)]", "\(span(r.startTime, r.endTime)) \(rect(r.rect)) i=\(f(r.intensity))"))
            }
            for (i, c) in p.cameraLayoutRegions.enumerated() {
                s.append(("cam[\(i)]", "\(span(c.startTime, c.endTime)) mode=\(c.mode.rawValue) look=\(c.look?.rawValue ?? "nil") "
                          + "side=\(c.cameraSide?.rawValue ?? "nil") split=\(c.splitStyle?.rawValue ?? "nil")"))
            }
            for (i, a) in p.annotations.enumerated() {
                let size = a.type == .tap ? f(a.fontSize) : f(a.lineWidth)
                s.append(("ann[\(i)]", "\(a.type.rawValue) \(span(a.startTime, a.endTime)) color=\(col(a.color)) "
                          + "font=\(a.fontName ?? "nil") weight=\(a.fontWeight.rawValue) bg=\(a.showBackground ? "on" : "off") "
                          + "bgColor=\(col(a.backgroundColor)) size=\(size) text=\"\(a.text)\""))
            }
            for (i, r) in p.speedRegions.enumerated() {
                s.append(("speed[\(i)]", "\(span(r.startTime, r.endTime)) ×\(f(r.speed))"))
            }
            s.append(("clips", p.videoClipSegments.map { span($0.startTime, $0.endTime) }.joined(separator: " ")
                      + " | effective " + p.effectiveVideoClipSegments.map { span($0.startTime, $0.endTime) }.joined(separator: " ")
                      + " | splits \(p.splitPoints.map { f($0) })"))
            for (i, v) in p.voiceOverClips.enumerated() {
                s.append(("voice[\(i)]", "\(f(v.startTime)) dur=\(f(v.duration)) \(v.fileName)"))
            }
            let st = p.settings
            s.append(("intro", "\(st.introSlideStyle.rawValue) start=\(f(st.introSlideStart)) dur=\(f(st.introSlideDuration))"))
            s.append(("curtain", "\(st.curtainUnveilCorner.rawValue) start=\(f(st.curtainUnveilStart)) dur=\(f(st.curtainUnveilDuration))"))
            s.append(("selection", "zoom=\(label(selection.selectedZoomID)) tilt=\(label(selection.selectedTiltID)) "
                      + "blur=\(label(selection.selectedBlurID)) hl=\(label(selection.selectedHighlightID)) "
                      + "depth=\(label(selection.selectedDepthFocusID)) ann=\(label(selection.selectedAnnotationID)) "
                      + "cam=\(label(host.selectedCameraLayoutID)) voice=\(label(host.selectedVoiceOverID)) "
                      + "speed=\(label(host.selectedSpeedID)) clip=\(label(host.selectedClipID)) "
                      + "intro=\(selection.introSelected) curtain=\(selection.curtainSelected) "
                      + "tab=\(selection.inspectorTab.rawValue) inspector=\(selection.showInspector)"))
            s.append(("playhead", f(host.currentTime)))
            return s
        }

        private func label(_ id: UUID?) -> String {
            guard let id else { return "nil" }
            let p = project
            if let i = p.zoomRegions.firstIndex(where: { $0.id == id }) { return "zoom[\(i)]" }
            if let i = p.tiltRegions.firstIndex(where: { $0.id == id }) { return "tilt[\(i)]" }
            if let i = p.blurRegions.firstIndex(where: { $0.id == id }) { return "blur[\(i)]" }
            if let i = p.highlightRegions.firstIndex(where: { $0.id == id }) { return "hl[\(i)]" }
            if let i = p.focusRegions.firstIndex(where: { $0.id == id }) { return "focus[\(i)]" }
            if let i = p.cameraLayoutRegions.firstIndex(where: { $0.id == id }) { return "cam[\(i)]" }
            if let i = p.annotations.firstIndex(where: { $0.id == id }) { return "ann[\(i)]" }
            if let i = p.speedRegions.firstIndex(where: { $0.id == id }) { return "speed[\(i)]" }
            if let i = p.effectiveVideoClipSegments.firstIndex(where: { $0.id == id }) { return "clip[\(i)]" }
            if let i = p.voiceOverClips.firstIndex(where: { $0.id == id }) { return "voice[\(i)]" }
            return "gone"
        }

        private func f(_ v: Double) -> String { String(format: "%.6f", v) }
        private func f(_ v: CGFloat) -> String { String(format: "%.6f", Double(v)) }
        private func opt(_ v: Double?) -> String { v.map { f($0) } ?? "nil" }
        private func span(_ a: Double, _ b: Double) -> String { "\(f(a))–\(f(b))" }
        private func pt(_ p: CGPoint) -> String { "(\(f(p.x)),\(f(p.y)))" }
        private func rect(_ r: CGRect) -> String { "[\(f(r.minX)),\(f(r.minY)) \(f(r.width))x\(f(r.height))]" }
        private func col(_ c: CodableColor) -> String {
            String(format: "%.3f,%.3f,%.3f,%.3f", c.red, c.green, c.blue, c.opacity)
        }
    }
}
