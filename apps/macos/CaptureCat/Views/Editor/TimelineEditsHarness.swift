import AppKit

/// `--timeline-edits-test [--print]`
///
/// Behaviour freeze for the timeline's edit operations. Builds the REAL
/// `TimelineViewController` in a window (its own undo manager, its own
/// selection shims) over a fixture project, and drives every edit family
/// through the paths the app uses — the canvas / VIDEO / VOICE callbacks the
/// lanes call, the keyboard (⌘D, ⌘B, Delete), the FOCUS context menu rows,
/// and the menu actions — recording every model write, selection change and
/// undo action name as text. Then it unwinds the whole undo stack, recording
/// the model after every step, so undo is frozen too.
///
/// The golden (`TimelineEditsGoldens`) was frozen from the pre-extraction
/// timeline (Studio 1d, 3dfa6a1) BEFORE the edit operations moved into the
/// shared `TimelineEditing` extension, so any behaviour change in them is a
/// line diff here. `--print` writes the live transcript to stdout —
/// refreezing is for a change you MEANT; read the diff first.
@MainActor
enum TimelineEditsHarness {
    static func run() -> Never {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let rig = TimelineRig()
        rig.runScript()
        let lines = rig.out

        if CommandLine.arguments.contains("--print") {
            print(lines.joined(separator: "\n"))
            exit(0)
        }

        var failures: [String] = []
        // Coverage: (op label, a line its block must contain) — proves the
        // op really reached its code path rather than silently no-opping.
        let required: [(String, String)] = [
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

        let ops = lines.filter { $0.hasPrefix("timeline.") }.count
        let unwound = lines.filter { $0.hasPrefix("unwind.") }.count
        if failures.isEmpty {
            print("TIMELINE-EDITS PASS (\(ops) edits + \(unwound) undo steps, \(lines.count) lines identical to the frozen pre-extraction transcript)")
            exit(0)
        }
        for f in failures { print("FAIL " + f) }
        print("TIMELINE-EDITS FAIL (\(failures.count) problem(s)) — behaviour changed; do not refreeze, find out why.")
        exit(1)
    }

    /// The lines recorded for the first entry whose label contains `label`.
    private static func block(_ lines: [String], _ label: String) -> [String] {
        guard let start = lines.firstIndex(where: { !$0.hasPrefix(" ") && $0.contains(label) }) else { return [] }
        let rest = lines[(start + 1)...]
        let end = rest.firstIndex(where: { !$0.hasPrefix(" ") }) ?? lines.endIndex
        return Array(lines[start..<end])
    }
}

// MARK: - Rig

@MainActor
private final class TimelineRig {
    let project: Project
    let playback = EditorPlaybackController(appState: nil)
    let selection = EditorShellSelection()
    let vc: TimelineViewController
    let window: NSWindow
    var out: [String] = []
    private var step = 0
    private var lastState: [(String, String)] = []

    var undo: UndoManager { window.undoManager! }

    init() {
        project = PreviewParityHarness.makeFixtureProject(duration: 20)
        project.previewCanvasSize = CGSize(width: 960, height: 540)
        let p = project
        p.zoomRegions = [
            ZoomRegion(id: Self.uuid(1), startTime: 2, endTime: 5, zoomLevel: 1.8,
                       focalPoint: CGPoint(x: 0.4, y: 0.4)),
            ZoomRegion(id: Self.uuid(2), startTime: 8, endTime: 10, zoomLevel: 1.5),
        ]
        p.tiltRegions = [TiltRegion(id: Self.uuid(3), startTime: 2, endTime: 5, pitch: 12, yaw: -4, roll: 1)]
        p.blurRegions = [BlurRegion(id: Self.uuid(4), startTime: 1, endTime: 3)]
        p.highlightRegions = [HighlightRegion(id: Self.uuid(5), startTime: 6, endTime: 8)]
        p.focusRegions = [FocusRegion(id: Self.uuid(6), startTime: 11, endTime: 13)]
        p.cameraLayoutRegions = [CameraLayoutRegion(id: Self.uuid(7), startTime: 14, endTime: 17, mode: .sideBySide)]
        var text = Annotation(id: Self.uuid(8), type: .text, startTime: 1, endTime: 4)
        text.text = "Hello"
        let arrow = Annotation(id: Self.uuid(9), type: .arrow, startTime: 5, endTime: 8)
        p.annotations = [text, arrow]
        p.voiceOverClips = [VoiceOverClip(id: Self.uuid(10), fileName: "timeline-edits-fixture-missing.m4a",
                                          startTime: 3, duration: 4)]
        p.settings.introSlideStyle = .bottom
        p.settings.introSlideStart = 2
        p.settings.introSlideDuration = 3

        vc = TimelineViewController(project: project, playback: playback, selection: selection,
                                    onToggleVoiceOverRecording: {})
        window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1200, height: 420),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentViewController = vc
        window.setContentSize(NSSize(width: 1200, height: 420))
    }

    static func uuid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-B000-%012d", n))!
    }

    // MARK: Access to the real paths

    private var canvas: TimelineCanvasView { Self.find(TimelineCanvasView.self, in: vc.view)! }
    private var cb: TimelineCanvasCallbacks { canvas.callbacks! }
    private var video: TimelineVideoCallbacks { canvas.videoCallbacks! }
    private var voice: TimelineVoiceCallbacks { canvas.voiceCallbacks! }

    private static func find<T: NSView>(_ type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        for sub in root.subviews {
            if let found = find(type, in: sub) { return found }
        }
        return nil
    }

    /// Let the timeline's observation loops rebuild the canvas (fresh
    /// callbacks + time map), exactly as the next runloop turn does in the app.
    private func settle() {
        vc.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    }

    private func id(_ kind: String, _ index: Int) -> UUID {
        switch kind {
        case "zoom": return project.zoomRegions[index].id
        case "tilt": return project.tiltRegions[index].id
        case "blur": return project.blurRegions[index].id
        case "hl": return project.highlightRegions[index].id
        case "focus": return project.focusRegions[index].id
        case "cam": return project.cameraLayoutRegions[index].id
        case "ann": return project.annotations[index].id
        case "speed": return project.speedRegions[index].id
        case "clip": return project.effectiveVideoClipSegments[index].id
        case "voice": return project.voiceOverClips[index].id
        default: fatalError(kind)
        }
    }

    private func keyDown(_ keyCode: UInt16) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{7f}",
            charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: keyCode
        ) else { return }
        _ = vc.handleKeyDown(event)
    }

    // MARK: Script

    func runScript() {
        window.orderFrontRegardless()
        undo.groupsByEvent = false
        undo.removeAllActions()
        settle()
        out.append("== timeline edits (fixture: 20 s, linked zoom+tilt 2–5, zoom 8–10, blur 1–3, highlight 6–8, depth 11–13, camera 14–17, intro slide on the linked block)")
        out.append(contentsOf: diffState())

        // EFFECTS lane
        op("add zoom at 11 s (free gap)") { self.cb.addZoomAt(11) }
        op("add tilt at 3 s (inside a block → nearest gap)") { self.cb.addTiltAt(3) }
        op("showcase at the playhead", playhead: 15) { self.vc.addShowcaseBlock() }
        op("scale down at the playhead", playhead: 0.2) { self.vc.addScaleDownBlock() }
        op("zoom level on the 8–10 zoom") { self.cb.setZoomLevel(self.id("zoom", 1), 2.25) }
        op("add tilt to block (8–10 zoom)") { self.cb.addTiltToBlock(self.id("zoom", 1)) }
        op("add zoom to block (the 3 s tilt)") { self.cb.addZoomToBlock(self.id("tilt", 1)) }
        op("move linked block 2–5 → 3–6 (joined slide follows)") {
            self.cb.commitEffectTimes(self.id("zoom", 0), self.id("tilt", 0), 3, 6)
        }
        op("select linked block") { self.cb.selectEffect(self.id("zoom", 0), self.id("tilt", 0)) }
        op("⌘D duplicate linked block") { _ = self.vc.handleCommandKey("d") }
        op("select zoom only") { self.cb.selectEffect(self.id("zoom", 2), nil) }
        op("⌘D duplicate zoom") { _ = self.vc.handleCommandKey("d") }
        op("select tilt only") { self.cb.selectEffect(nil, self.id("tilt", 1)) }
        op("⌘D duplicate tilt") { _ = self.vc.handleCommandKey("d") }
        op("delete linked block (canvas)") { self.cb.deleteEffectBlock(self.id("zoom", 0), self.id("tilt", 0)) }
        op("remove zoom half") { self.cb.removeZoom(self.id("zoom", 0)) }
        op("remove tilt half") { self.cb.removeTilt(self.id("tilt", 0)) }

        // FOCUS lane
        op("add blur at 4 s") { self.cb.addBlurAt(4) }
        op("add highlight at 9 s") { self.cb.addHighlightAt(9) }
        op("add depth focus at the playhead", playhead: 18) { self.vc.addDepthFocusRegion() }
        op("draw pixelate (preview drag-to-draw)", playhead: 0) {
            self.vc.createBlurRegion(rect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.25), style: .pixelate)
        }
        op("camera layout at the playhead", playhead: 0.5) { self.vc.addCameraLayoutRegion(mode: .sideBySide) }
        op("cutout look", playhead: 12) { self.vc.addCameraLayoutRegion(mode: .bubble, look: .cutout) }
        op("playhead to 5 s", playhead: 5) {}
        // One attempt: the refusal beeps (NSSound) and gates run often.
        op("FOCUS lane full: add blur refuses") { self.cb.addBlurAt(5) }
        op("select blur via FOCUS") { self.cb.selectFocus(self.id("blur", 0), false) }
        op("⌘D duplicate blur") { _ = self.vc.handleCommandKey("d") }
        op("select highlight via FOCUS") { self.cb.selectFocus(self.id("hl", 0), true) }
        op("⌘D duplicate highlight") { _ = self.vc.handleCommandKey("d") }
        op("select depth via FOCUS") { self.cb.selectFocus(self.id("focus", 0), false) }
        op("select camera layout via FOCUS") { self.cb.selectFocus(self.id("cam", 0), false) }
        op("select nothing via FOCUS") { self.cb.selectFocus(nil, false) }
        op("commit highlight times") { self.cb.commitFocusTimes(self.id("hl", 0), true, 6.5, 7.5) }
        op("commit focus times") { self.cb.commitFocusTimes(self.id("focus", 0), false, 11.5, 12.5) }
        op("commit camera times") { self.cb.commitFocusTimes(self.id("cam", 0), false, 14.5, 16) }
        op("commit blur times") { self.cb.commitFocusTimes(self.id("blur", 0), false, 1.25, 2.75) }
        for title in ["Camera on Left", "Full Height", "Copy Layout", "Camera on Right", "Tiles"] {
            op("menu: \(title)") { self.menu(self.id("cam", 0), title) }
        }
        op("menu: Paste Layout on another block") { self.menu(self.id("cam", 1), "Paste Layout") }
        op("delete focus: highlight") { self.cb.deleteFocus(self.id("hl", 0), true) }
        op("delete focus: depth") { self.cb.deleteFocus(self.id("focus", 0), false) }
        op("delete focus: camera") { self.cb.deleteFocus(self.id("cam", 0), false) }
        op("delete focus: blur") { self.cb.deleteFocus(self.id("blur", 0), false) }

        // ANNOTATE lane + the floating pill
        for (type, time) in [(AnnotationType.text, 9.0), (.arrow, 10), (.callout, 11), (.rectangle, 12),
                             (.ellipse, 13), (.drawing, 14), (.tap, 19.8)] {
            op("add \(type.rawValue) at \(time) s") { self.cb.addAnnotationAt(type, time) }
        }
        op("commit annotation times") { self.cb.commitAnnotationTimes(self.id("ann", 0), 1.5, 3.5) }
        op("select annotation off-playhead seeks", playhead: 15) { self.cb.selectAnnotation(self.id("ann", 1)) }
        op("select annotation on-playhead stays", playhead: 6) { self.cb.selectAnnotation(self.id("ann", 1)) }
        op("recolor selected") { self.vc.applyToolbarColor(NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1)) }
        op("select text") { self.cb.selectAnnotation(self.id("ann", 0)) }
        op("font") { self.vc.applyToolbarFont("Avenir") }
        op("weight") { self.vc.applyToolbarWeight(.bold) }
        op("toggle background") { self.vc.toggleToolbarBackground() }
        op("background color") { self.vc.applyToolbarBackgroundColor(NSColor(srgbRed: 0.2, green: 0.3, blue: 0.4, alpha: 0.8)) }
        op("size on text (line width)") { self.vc.applyToolbarSize(6) }
        op("select tap") { self.cb.selectAnnotation(self.id("ann", 8)) }
        op("size on a tap (ripple size)") { self.vc.applyToolbarSize(40) }
        op("deselect annotations") { self.cb.selectAnnotation(nil) }
        op("pill color with nothing selected") { self.vc.applyToolbarColor(NSColor(srgbRed: 0.1, green: 0.2, blue: 0.9, alpha: 1)) }
        op("pill color is the next default", playhead: 16) { _ = self.vc.addAnnotationFromToolbar(.arrow) }
        op("delete annotation (canvas)") { self.cb.deleteAnnotation(self.id("ann", 2)) }

        // VIDEO lane
        op("slice at 6 s") { self.video.sliceAt(6) }
        op("⌘B at the playhead", playhead: 12) { _ = self.vc.handleCommandKey("b") }
        op("⌘B on a cut does nothing", playhead: 12) { _ = self.vc.handleCommandKey("b") }
        op("delete split at 12 s") { self.video.deleteSplit(12) }
        op("select first clip") { self.video.selectClip(self.id("clip", 0)) }
        op("delete clip (Delete key)") { self.keyDown(51) }
        op("add speed range 13–16 at 2×") { self.video.addSpeedRange(13, 16, 2) }
        op("change speed to 3×") { self.video.changeSpeed(self.id("speed", 0), 3) }
        op("select speed") { self.vc.selectedSpeedID = self.id("speed", 0) }
        op("⌘D duplicate speed") { _ = self.vc.handleCommandKey("d") }
        op("delete speed (canvas)") { self.video.deleteSpeed(self.id("speed", 0)) }
        op("add speed range overlapping the copy") { self.video.addSpeedRange(15, 18, 0.5) }

        // VOICE lane
        op("delete voice clip (canvas)") { self.voice.deleteClip(self.id("voice", 0)) }

        // Intro slide + curtain chips
        op("delete intro (canvas)") { self.cb.deleteIntro() }
        op("enable intro (menu)") { self.vc.enableIntroSlide() }
        op("resize intro") { self.cb.resizeIntro(2.2) }
        op("move intro past the end clamps") { self.cb.moveIntro(30) }
        op("open intro") { self.cb.openIntro() }
        op("delete intro via Delete key") { self.keyDown(51) }
        op("enable curtain (menu)") { self.vc.enableCurtainUnveil() }
        op("resize curtain") { self.cb.resizeCurtain(2.4) }
        op("move curtain") { self.cb.moveCurtain(4) }
        op("open curtain") { self.cb.openCurtain() }
        op("delete curtain (canvas)") { self.cb.deleteCurtain() }

        // Generators and the catch-all delete
        op("auto zoom (no cursor data)") { self.vc.autoZoom() }
        op("select zoom then Delete key") {
            self.cb.selectEffect(self.id("zoom", 0), nil)
            self.keyDown(51)
        }
        op("delete selection with nothing selected") { self.cb.deleteSelection() }

        // Unwind the whole undo stack: every registration, newest first.
        var n = 0
        while undo.canUndo && n < 200 {
            n += 1
            let name = undo.undoActionName
            undo.undo()
            settle()
            out.append(String(format: "unwind.%02d undo: %@", n, name))
            out.append(contentsOf: diffState())
        }
        out.append("== unwound \(n) step(s); canUndo=\(undo.canUndo)")
        window.orderOut(nil)
    }

    private func menu(_ regionID: UUID, _ title: String) {
        let entries = cb.focusMenuExtras(regionID)
        guard let entry = entries.first(where: { $0.title == title }) else {
            out.append("   note: no menu row \"\(title)\" (rows: \(entries.map(\.title)))")
            return
        }
        guard entry.isEnabled else {
            out.append("   note: menu row \"\(title)\" is disabled")
            return
        }
        entry.action?()
    }

    private func op(_ label: String, playhead: TimeInterval? = nil, _ body: () -> Void) {
        if let playhead {
            playback.currentTime = playhead
            settle()
        }
        let topBefore = undo.canUndo ? undo.undoActionName : "-"
        undo.beginUndoGrouping()
        body()
        undo.endUndoGrouping()
        settle()
        step += 1
        let top = undo.canUndo ? undo.undoActionName : "-"
        out.append(String(format: "timeline.%02d %@", step, label)
                   + (playhead.map { String(format: "  (playhead %.2f)", $0) } ?? ""))
        out.append("   undo top: \(top)" + (top == topBefore ? " (unchanged)" : ""))
        let diff = diffState()
        out.append(diff.isEmpty ? "   events: -" : "   events: changed")
        out.append(contentsOf: diff)
    }

    // MARK: State

    /// State lines that changed since the last record, in a fixed order.
    private func diffState() -> [String] {
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
                  + "cam=\(label(vc.selectedCameraLayoutID)) voice=\(label(vc.selectedVoiceOverID)) "
                  + "speed=\(label(vc.selectedSpeedID)) clip=\(label(vc.selectedClipID)) "
                  + "intro=\(selection.introSelected) curtain=\(selection.curtainSelected) "
                  + "tab=\(selection.inspectorTab.rawValue) inspector=\(selection.showInspector)"))
        s.append(("playhead", f(playback.currentTime)))
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
