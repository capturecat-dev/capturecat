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

        // Coverage + the golden live in the shared TimelineEditsTranscript —
        // the iOS `--timeline-edits` gate scores against the same ones.
        let failures = TimelineEditsTranscript.failures(for: lines)

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
    private let recorder: TimelineEditsTranscript.Recorder

    var undo: UndoManager { window.undoManager! }

    init() {
        project = TimelineEditsTranscript.makeProject()

        vc = TimelineViewController(project: project, playback: playback, selection: selection,
                                    onToggleVoiceOverRecording: {})
        window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1200, height: 420),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentViewController = vc
        window.setContentSize(NSSize(width: 1200, height: 420))
        recorder = TimelineEditsTranscript.Recorder(project: project, host: vc)
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
        out.append(TimelineEditsTranscript.header)
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
        // Slide chip drags as the canvas runs them (spans at mouse-down, live
        // writes, the one undo step at mouse-up) — iOS drives real drags here.
        op("resize intro") { self.chipDrag { self.cb.resizeIntro(2.2) } }
        op("move intro past the end clamps") { self.chipDrag { self.cb.moveIntro(30) } }
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

    /// A Slide / Curtain chip drag: press-time spans, the live writes, the
    /// release's commit (TimelineCanvasView mouseDown / mouseUp).
    private func chipDrag(_ live: () -> Void) {
        let before = cb.chipSpans()
        live()
        settle()
        cb.commitChipDrag(before)
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

    /// State lines that changed since the last record (shared recorder).
    private func diffState() -> [String] { recorder.diffState() }
}
