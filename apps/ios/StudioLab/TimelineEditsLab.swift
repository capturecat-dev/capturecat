import UIKit

/// `--timeline-edits <outDir> [--inject accordion-snap|selection-snap|touch-offset]`
/// (Studio 4c) — the touch timeline's behaviour gate.
///
/// Hosts the shipping `StudioTimelineViewController` (its own undo manager,
/// the shared selection, a bare playhead) in this real window and replays the
/// Mac `--timeline-edits-test` script: the same fixture, the same 96 ops with
/// the same labels and playheads, the whole undo stack unwound — recorded by
/// the SAME recorder (`TimelineEditsTranscript`) and scored against the SAME
/// frozen golden. Every op that touch can express goes through the view the
/// way a finger does: taps, drags and long presses at canvas points computed
/// from the canvas's own geometry (scrolled into view first) through the
/// recognizers' `perform…` entry points; menu picks by pressing the house
/// sheet's rows; toolbar keys; hardware-key commands; Undo via the toolbar
/// key. Ops whose Mac arguments no gesture can produce (a commit to times a
/// neighbour would refuse, a zoom level the menu does not offer, the preview's
/// drag-to-draw, the floating pill) call the same shared entry point the
/// Mac harness calls; the log says which and why.
///
/// Then the motion checks (CLAUDE.md §3): a lane opening and closing captured
/// as a SEQUENCE with a mid-flight assertion, and the selection outline's
/// glide; each proven able to fail by `--inject`.
@MainActor
enum TimelineEditsLab {
    /// StudioLabApp's hook: claims `--timeline-edits <outDir>` (true = handled).
    static func start(_ arguments: [String], in lab: LabViewController) -> Bool {
        guard let i = arguments.firstIndex(of: "--timeline-edits"), arguments.indices.contains(i + 1) else { return false }
        let out = URL(fileURLWithPath: arguments[i + 1], isDirectory: true)
        let inject = arguments.firstIndex(of: "--inject").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        lab.stage.isHidden = true
        Task { @MainActor in await run(in: lab, out: out, inject: inject) }
        return true
    }

    static func run(in parent: UIViewController, out: URL, inject: String?) async {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        print("TIMELINE-EDITS iOS out=\(out.path)" + (inject.map { " inject=\($0)" } ?? ""))
        let rig = TimelineEditsRig(parent: parent, out: out)
        // `--inject touch-offset`: every touch lands 40 pt (0.4 s) right of
        // its target — a mis-mapped touch geometry the transcript must catch.
        rig.touchOffset = inject == "touch-offset" ? 40 : 0
        await rig.mount()
        await rig.runScript()

        let lines = rig.out
        try? lines.joined(separator: "\n").write(to: out.appendingPathComponent("ios-transcript.txt"), atomically: true, encoding: .utf8)
        try? rig.driveLog.joined(separator: "\n").write(to: out.appendingPathComponent("drive.txt"), atomically: true, encoding: .utf8)
        let failures = TimelineEditsTranscript.failures(for: lines) + rig.problems
        let ops = lines.filter { $0.hasPrefix("timeline.") }.count
        let unwound = lines.filter { $0.hasPrefix("unwind.") }.count
        let touch = rig.driveLog.filter { $0.contains("—  touch ") }.count
        let callback = rig.driveLog.filter { $0.contains("—  callback ") }.count
        print("DRIVE \(touch) op(s) by touch through the view, \(callback) by the shared callback (log: drive.txt)")
        if failures.isEmpty {
            print("TIMELINE-EDITS PASS (\(ops) edits + \(unwound) undo steps, \(lines.count) lines identical to the Mac's frozen transcript)")
        } else {
            for f in failures { print("FAIL " + f) }
            print("TIMELINE-EDITS FAIL (\(failures.count) problem(s))")
        }

        rig.vc.canvas.laneAccordion.probeForceSnap = inject == "accordion-snap"
        #if DEBUG
        rig.vc.canvas.probeSnapSelection = inject == "selection-snap"
        #endif
        let laneOK = await rig.laneMotionCheck()
        let glideOK = await rig.selectionGlideCheck()
        rig.unmount()

        // Real drags through the view on a fresh fixture, against the Mac's values.
        let dragRig = TimelineEditsRig(parent: parent, out: out)
        await dragRig.mount()
        let dragsOK = await dragRig.touchDragChecks()
        let pass = failures.isEmpty && laneOK && glideOK && dragsOK
        print(pass ? "TIMELINE-GATE PASS" : "TIMELINE-GATE FAIL")
        exit(pass ? 0 : 1)
    }
}

@MainActor
private final class TimelineEditsRig {
    let parent: UIViewController
    let outDir: URL
    let project = TimelineEditsTranscript.makeProject()
    let selection = EditorShellSelection()
    let playhead = StudioTimelinePlayhead()
    let undo = UndoManager()
    let vc: StudioTimelineViewController
    let recorder: TimelineEditsTranscript.Recorder
    var out: [String] = []
    var driveLog: [String] = []
    var problems: [String] = []
    private var step = 0
    private var currentDrive = ""
    var touchOffset: CGFloat = 0

    typealias M = TimelineCanvasMetrics
    var canvas: StudioTimelineCanvasView { vc.canvas }

    init(parent: UIViewController, out: URL) {
        self.parent = parent
        self.outDir = out
        vc = StudioTimelineViewController(project: project, selection: selection, playback: playhead, undoManager: undo)
        recorder = TimelineEditsTranscript.Recorder(project: project, host: vc)
    }

    func mount() async {
        parent.addChild(vc)
        let root = parent.view!
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(vc.view)
        NSLayoutConstraint.activate([
            vc.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            vc.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            vc.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            vc.view.heightAnchor.constraint(equalToConstant: vc.intrinsicPanelHeight + 60),
        ])
        vc.didMove(toParent: parent)
        await LabTime.settle(0.4)
        // A wide track (2000 pt for the 20 s fixture) keeps the 16 px snap
        // radius at 0.16 s, so touch edits of 0.25 s land where they aim.
        let visible = vc.scrollView.bounds.width
        vc.setTimelineScale(2000 / max(1, visible))
        await LabTime.settle(0.2)
        print("TIMELINE-EDITS window=\(Int(root.bounds.width))x\(Int(root.bounds.height)) track=\(Int(canvas.bounds.width))pt visible=\(Int(visible))pt")
    }

    func unmount() {
        vc.tearDown()
        vc.willMove(toParent: nil)
        vc.view.removeFromSuperview()
        vc.removeFromParent()
    }

    private func settle(_ seconds: TimeInterval = 0.06) async { await LabTime.settle(seconds) }

    // MARK: - Script (labels, playheads and order: the Mac harness's)

    func runScript() async {
        undo.groupsByEvent = false
        undo.removeAllActions()
        await settle()
        out.append(TimelineEditsTranscript.header)
        out.append(contentsOf: recorder.diffState())
        // Index → id, as the Mac harness does; a diverged run (fewer items
        // than the script expects) gets a dead id and a reported problem,
        // never a crash.
        func pick(_ ids: [UUID], _ i: Int, _ kind: String) -> UUID {
            guard ids.indices.contains(i) else {
                self.fail("\(kind)[\(i)] does not exist (the run has diverged)")
                return UUID()
            }
            return ids[i]
        }
        let z = { (i: Int) in pick(self.project.zoomRegions.map(\.id), i, "zoom") }
        let t = { (i: Int) in pick(self.project.tiltRegions.map(\.id), i, "tilt") }
        let blur = { (i: Int) in pick(self.project.blurRegions.map(\.id), i, "blur") }
        let hl = { (i: Int) in pick(self.project.highlightRegions.map(\.id), i, "hl") }
        let focus = { (i: Int) in pick(self.project.focusRegions.map(\.id), i, "focus") }
        let cam = { (i: Int) in pick(self.project.cameraLayoutRegions.map(\.id), i, "cam") }
        let ann = { (i: Int) in pick(self.project.annotations.map(\.id), i, "ann") }
        let speed = { (i: Int) in pick(self.project.speedRegions.map(\.id), i, "speed") }

        // EFFECTS lane
        await op("add zoom at 11 s (free gap)") { await self.laneMenu(.effects, at: 11, "Add Zoom Region") }
        await op("add tilt at 3 s (inside a block → nearest gap)") {
            self.callback("3 s is inside a block — a press there opens the block's menu") { self.cb.addTiltAt(3) }
        }
        await op("showcase at the playhead", playhead: 15) { await self.toolbarMenu("Effects", "Showcase") }
        await op("scale down at the playhead", playhead: 0.2) { await self.toolbarMenu("Effects", "Scale Down") }
        await op("zoom level on the 8–10 zoom") {
            self.callback("2.25× is not a menu level (1.5…5×)") { self.cb.setZoomLevel(z(1), 2.25) }
        }
        await op("add tilt to block (8–10 zoom)") { await self.effectMenu(zoom: z(1), tilt: nil, "Add Tilt to Block") }
        await op("add zoom to block (the 3 s tilt)") {
            await self.effectMenu(zoom: self.pairedZoom(tilt: t(1)), tilt: t(1), "Add Zoom to Block")
        }
        await op("move linked block 2–5 → 3–6 (joined slide follows)") {
            self.callback("a drag to 3–6 is refused by the 5–8 block (no-overlap clamp)") {
                self.cb.commitEffectTimes(z(0), t(0), 3, 6)
            }
        }
        await op("select linked block") { await self.tapEffect(zoom: z(0), tilt: t(0)) }
        await op("⌘D duplicate linked block") { self.key("d", .command) }
        await op("select zoom only") { await self.tapEffect(zoom: z(2), tilt: nil) }
        await op("⌘D duplicate zoom") { self.key("d", .command) }
        await op("select tilt only") {
            self.callback("tilt[1] is linked to a zoom — a tap selects both halves") { self.cb.selectEffect(nil, t(1)) }
        }
        await op("⌘D duplicate tilt") { self.key("d", .command) }
        await op("delete linked block (canvas)") { await self.effectMenu(zoom: z(0), tilt: t(0), "Delete") }
        await op("remove zoom half") { await self.effectMenu(zoom: z(0), tilt: self.pairedTilt(zoom: z(0)), "Remove Zoom") }
        await op("remove tilt half") { await self.effectMenu(zoom: self.pairedZoom(tilt: t(0)), tilt: t(0), "Remove Tilt") }

        // FOCUS lane
        await op("add blur at 4 s") { await self.laneMenu(.focus, at: 4, "Add Blur") }
        await op("add highlight at 9 s") { await self.laneMenu(.focus, at: 9, "Add Highlight") }
        await op("add depth focus at the playhead", playhead: 18) { await self.toolbarMenu("Focus & Blur", "Add Depth Focus") }
        await op("draw pixelate (preview drag-to-draw)", playhead: 0) {
            self.callback("drag-to-draw is the preview stage's gesture (4b)") {
                self.vc.createBlurRegion(rect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.25), style: .pixelate)
            }
        }
        await op("camera layout at the playhead", playhead: 0.5) {
            self.callback("the fixture has no camera track, so the menu hides camera rows") {
                self.vc.addCameraLayoutRegion(mode: .sideBySide)
            }
        }
        await op("cutout look", playhead: 12) {
            self.callback("no camera track (menu hides camera rows)") { self.vc.addCameraLayoutRegion(mode: .bubble, look: .cutout) }
        }
        await op("playhead to 5 s", playhead: 5) { self.note("harness: playhead only") }
        await op("FOCUS lane full: add blur refuses") {
            self.callback("5 s is covered by a blur — a press opens its menu") { self.cb.addBlurAt(5) }
        }
        await op("select blur via FOCUS") { await self.tapFocus(blur(0)) }
        await op("⌘D duplicate blur") { self.key("d", .command) }
        await op("select highlight via FOCUS") { await self.tapFocus(hl(0)) }
        await op("⌘D duplicate highlight") { self.key("d", .command) }
        await op("select depth via FOCUS") {
            self.callback("a duplicated blur covers the depth block (blurs hit-test first)") { self.cb.selectFocus(focus(0), false) }
        }
        await op("select camera layout via FOCUS") { await self.tapFocus(cam(0)) }
        await op("select nothing via FOCUS") {
            self.callback("a tap on empty lane also seeks the playhead") { self.cb.selectFocus(nil, false) }
        }
        await op("commit highlight times") {
            self.callback(Self.dragSelects) { self.cb.commitFocusTimes(hl(0), true, 6.5, 7.5) }
        }
        await op("commit focus times") {
            self.callback("the duplicated blur on 11–13 blocks the depth block's edges") {
                self.cb.commitFocusTimes(focus(0), false, 11.5, 12.5)
            }
        }
        await op("commit camera times") {
            self.callback("the highlight on 13–15 blocks the camera block's left edge") {
                self.cb.commitFocusTimes(cam(0), false, 14.5, 16)
            }
        }
        await op("commit blur times") {
            self.callback(Self.dragSelects) { self.cb.commitFocusTimes(blur(0), false, 1.25, 2.75) }
        }
        for title in ["Camera on Left", "Full Height", "Copy Layout", "Camera on Right", "Tiles"] {
            await op("menu: \(title)") { await self.focusMenu(cam(0), title) }
        }
        await op("menu: Paste Layout on another block") {
            self.callback("the highlight on 13–15 covers that camera block (highlights hit-test first)") {
                self.menuEntry(cam(1), "Paste Layout")
            }
        }
        await op("delete focus: highlight") { await self.focusMenu(hl(0), "Delete") }
        await op("delete focus: depth") {
            self.callback("the duplicated blur covers the depth block") { self.cb.deleteFocus(focus(0), false) }
        }
        await op("delete focus: camera") { await self.focusMenu(cam(0), "Delete") }
        await op("delete focus: blur") { await self.focusMenu(blur(0), "Delete") }

        // ANNOTATE lane + the floating pill
        for (type, time) in [(AnnotationType.text, 9.0), (.arrow, 10), (.callout, 11), (.rectangle, 12),
                             (.ellipse, 13), (.drawing, 14), (.tap, 19.8)] {
            await op("add \(type.rawValue) at \(time) s") {
                if self.canvas.hit(at: self.lanePoint(.annotate, at: time)).isEmptyLane {
                    let title = StudioTimelineMenus.addAnnotationRows.first { $0.1 == type }!.0
                    await self.laneMenu(.annotate, at: time, title)
                } else {
                    self.callback("\(time) s is covered by an earlier annotation — a press opens its menu") {
                        self.cb.addAnnotationAt(type, time)
                    }
                }
            }
        }
        await op("commit annotation times") {
            self.callback(Self.dragSelects) { self.cb.commitAnnotationTimes(ann(0), 1.5, 3.5) }
        }
        await op("select annotation off-playhead seeks", playhead: 15) { await self.tapAnnotation(ann(1)) }
        await op("select annotation on-playhead stays", playhead: 6) { await self.tapAnnotation(ann(1)) }
        await op("recolor selected") {
            self.callback("the floating annotation pill (4b)") {
                self.vc.applyToolbarColor(UIColor(red: 1, green: 0.5, blue: 0, alpha: 1))
            }
        }
        await op("select text") { await self.tapAnnotation(ann(0)) }
        await op("font") { self.callback("pill") { self.vc.applyToolbarFont("Avenir") } }
        await op("weight") { self.callback("pill") { self.vc.applyToolbarWeight(.bold) } }
        await op("toggle background") { self.callback("pill") { self.vc.toggleToolbarBackground() } }
        await op("background color") {
            self.callback("pill") { self.vc.applyToolbarBackgroundColor(UIColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 0.8)) }
        }
        await op("size on text (line width)") { self.callback("pill") { self.vc.applyToolbarSize(6) } }
        await op("select tap") { await self.tapAnnotation(ann(8)) }
        await op("size on a tap (ripple size)") { self.callback("pill") { self.vc.applyToolbarSize(40) } }
        await op("deselect annotations") {
            self.callback("a tap on empty lane also seeks the playhead") { self.cb.selectAnnotation(nil) }
        }
        await op("pill color with nothing selected") {
            self.callback("pill") { self.vc.applyToolbarColor(UIColor(red: 0.1, green: 0.2, blue: 0.9, alpha: 1)) }
        }
        await op("pill color is the next default", playhead: 16) { await self.toolbarMenu("Add Annotation", "Arrow") }
        await op("delete annotation (canvas)") { await self.annotationMenu(ann(2), "Delete") }

        // VIDEO lane
        await op("slice at 6 s") { await self.slice(at: 6) }
        await op("⌘B at the playhead", playhead: 12) { self.key("b", .command) }
        await op("⌘B on a cut does nothing", playhead: 12) { self.key("b", .command) }
        await op("delete split at 12 s") { await self.videoMenu(atOutput: 13, "Remove Split at Start") }
        await op("select first clip") { await self.tapClip(0) }
        await op("delete clip (Delete key)") { self.key(UIKeyCommand.inputDelete) }
        await op("add speed range 13–16 at 2×") {
            self.callback("Set Speed covers the whole segment (6–20), not 13–16") { self.video.addSpeedRange(13, 16, 2) }
        }
        await op("change speed to 3×") { await self.videoMenu(atOutput: 13.75, "Change Speed", then: "3x") }
        await op("select speed") { self.callback("speed selection has no lane gesture") { self.vc.selectedSpeedID = speed(0) } }
        await op("⌘D duplicate speed") { self.key("d", .command) }
        await op("delete speed (canvas)") { await self.videoMenu(atOutput: 13.5, "Remove Speed") }
        await op("add speed range overlapping the copy") {
            self.callback("arbitrary source range") { self.video.addSpeedRange(15, 18, 0.5) }
        }

        // VOICE lane
        await op("delete voice clip (canvas)") { await self.voiceMenu(0, "Delete Voice Over") }

        // Intro slide + curtain chips
        await op("delete intro (canvas)") { await self.chipMenu(intro: true, "Delete") }
        await op("enable intro (menu)") { await self.toolbarMenu("Effects", "Slide") }
        await op("resize intro") { await self.dragChipEdge(intro: true, toOutput: 2.2) }
        await op("move intro past the end clamps") { await self.dragChipBody(intro: true, byPoints: 2400) }
        await op("open intro") { await self.tapChip(intro: true) }
        await op("delete intro via Delete key") { self.key(UIKeyCommand.inputDelete) }
        await op("enable curtain (menu)") { await self.toolbarMenu("Effects", "Curtain Unveil") }
        await op("resize curtain") {
            self.callback("the 2–3 block stops the edge at 2.0 (chip neighbour clamp)") { self.cb.resizeCurtain(2.4) }
        }
        await op("move curtain") {
            self.callback("the 5–8 block refuses a chip landing on 4–6.4") { self.cb.moveCurtain(4) }
        }
        await op("open curtain") { await self.tapChip(intro: false) }
        await op("delete curtain (canvas)") { await self.chipMenu(intro: false, "Delete") }

        // Generators and the catch-all delete
        await op("auto zoom (no cursor data)") {
            self.callback("no cursor data, so the Effects menu hides Auto Zoom") { self.vc.autoZoom() }
        }
        await op("select zoom then Delete key") {
            await self.tapEffect(zoom: z(0), tilt: nil)
            self.key(UIKeyCommand.inputDelete)
        }
        await op("delete selection with nothing selected") { self.key(UIKeyCommand.inputDelete) }

        // Unwind the whole stack through the toolbar's Undo key.
        var n = 0
        while undo.canUndo && n < 200 {
            n += 1
            let name = undo.undoActionName
            guard let key = vc.probeKey("Undo"), key.isEnabled else {
                problems.append("unwind: the Undo key is disabled while canUndo is true (step \(n))")
                undo.undo()
                await settle()
                continue
            }
            key.sendActions(for: .touchUpInside)
            await settle()
            out.append(String(format: "unwind.%02d undo: %@", n, name))
            out.append(contentsOf: recorder.diffState())
        }
        out.append("== unwound \(n) step(s); canUndo=\(undo.canUndo)")
        if vc.probeKey("Undo")?.isEnabled == true { problems.append("Undo key still enabled with an empty stack") }
    }

    /// Why the script's three commits are not touch drags here.
    static let dragSelects = "a touch drag selects the block first (so does a Mac drag); the script commits "
        + "without selecting — the same edge drags are proven by touch in TOUCH-DRAGS"

    private func op(_ label: String, playhead: TimeInterval? = nil, _ body: () async -> Void) async {
        if let playhead {
            self.playhead.currentTime = playhead
            await settle()
        }
        currentDrive = ""
        let topBefore = undo.canUndo ? undo.undoActionName : "-"
        undo.beginUndoGrouping()
        await body()
        undo.endUndoGrouping()
        await settle()
        step += 1
        let top = undo.canUndo ? undo.undoActionName : "-"
        out.append(String(format: "timeline.%02d %@", step, label)
                   + (playhead.map { String(format: "  (playhead %.2f)", $0) } ?? ""))
        out.append("   undo top: \(top)" + (top == topBefore ? " (unchanged)" : ""))
        let diff = recorder.diffState()
        out.append(diff.isEmpty ? "   events: -" : "   events: changed")
        out.append(contentsOf: diff)
        driveLog.append(String(format: "%02d %@ — %@", step, label, currentDrive.isEmpty ? "harness" : currentDrive))
    }

    // MARK: - Drive helpers

    private var cb: TimelineCanvasCallbacks { canvas.callbacks! }
    private var video: TimelineVideoCallbacks { canvas.videoCallbacks! }

    private func touch(_ how: String) { currentDrive += (currentDrive.isEmpty ? "" : " + ") + " touch \(how) " }
    private func note(_ text: String) { currentDrive += text }
    private func callback(_ why: String, _ body: () -> Void) {
        currentDrive += " callback (\(why)) "
        body()
    }

    private func fail(_ text: String) {
        problems.append("op \(step + 1): \(text)")
        print("PROBLEM op \(step + 1): \(text)")
    }

    private func output(_ source: TimeInterval) -> TimeInterval { vc.fullTimeMap.outputTime(forSource: source) }

    /// Brings canvas x into the visible part of the scroll view (a finger
    /// can only touch what is on screen) and confirms it is there.
    private func reveal(_ point: CGPoint) {
        let scroll = vc.scrollView
        if point.x < scroll.contentOffset.x + 30 || point.x > scroll.contentOffset.x + scroll.bounds.width - 30 {
            let target = max(0, min(scroll.contentSize.width - scroll.bounds.width, point.x - scroll.bounds.width / 2))
            scroll.contentOffset = CGPoint(x: target, y: scroll.contentOffset.y)
        }
        let visible = CGRect(origin: scroll.contentOffset, size: scroll.bounds.size)
        if !visible.contains(point) { fail("point \(point) is not on screen (visible \(visible))") }
    }

    /// Opens a lane the way its label tap does and lets the accordion settle,
    /// so block geometry is the open lane's.
    private func openLane(_ lane: TimelineOverlayLane) async {
        if canvas.openOverlayLane != lane {
            vc.performLaneLabelTap(lane)
            await settle(0.4)
        }
    }

    private func lanePoint(_ lane: TimelineOverlayLane, at sourceTime: TimeInterval) -> CGPoint {
        let layout = canvas.laneLayout
        return CGPoint(x: canvas.x(forOutputTime: output(sourceTime)), y: layout.rowY(lane, row: 0) + layout.rowHeight(lane) / 2)
    }

    /// A point inside `rect` (midline) where `accepts(hit)` holds.
    private func point(in rect: CGRect, accepts: (CGPoint) -> Bool) -> CGPoint? {
        let y = rect.midY
        var x = rect.midX
        if accepts(CGPoint(x: x, y: y)) { return CGPoint(x: x, y: y) }
        x = rect.minX + 10
        while x <= rect.maxX - 10 {
            if accepts(CGPoint(x: x, y: y)) { return CGPoint(x: x, y: y) }
            x += 3
        }
        return nil
    }

    private func tap(_ target: CGPoint, _ what: String) async {
        let point = CGPoint(x: target.x + touchOffset, y: target.y)
        reveal(point)
        vc.performTap(at: point)
        touch("tap \(what)")
        await settle(0.08)
    }

    private func longPressMenu(_ target: CGPoint, _ what: String, _ row: String, then second: String? = nil) async {
        let point = CGPoint(x: target.x + touchOffset, y: target.y)
        reveal(point)
        vc.performLongPress(at: point)
        touch("long-press \(what) → \"\(row)\"" + (second.map { " → \"\($0)\"" } ?? ""))
        await pickRow(row)
        if let second { await pickRow(second) }
    }

    private func drag(from start: CGPoint, to end: CGPoint, _ what: String) async {
        reveal(start)
        guard vc.dragBelongsToTimeline(at: start) else {
            fail("a drag from \(start) would scroll, not edit (\(what))")
            return
        }
        let steps = 4
        let first = CGPoint(x: start.x + (end.x - start.x) / CGFloat(steps), y: start.y)
        vc.performDragBegan(at: start, current: first)
        for i in 2...steps {
            vc.performDragMoved(to: CGPoint(x: start.x + (end.x - start.x) * CGFloat(i) / CGFloat(steps), y: start.y))
            await settle(0.02)
        }
        vc.performDragEnded(at: end)
        touch("drag \(what)")
        await settle(0.08)
    }

    /// Presses a row of the presented house sheet and waits for its handler.
    private func pickRow(_ title: String) async {
        guard let sheet = await waitForSheet() else { fail("no menu appeared for \"\(title)\""); return }
        guard let row = Self.rows(in: sheet.view).first(where: { $0.accessibilityLabel == title }) else {
            let titles = Self.rows(in: sheet.view).compactMap(\.accessibilityLabel)
            fail("menu has no row \"\(title)\" (rows: \(titles))")
            sheet.dismiss(animated: false)
            await settle(0.1)
            return
        }
        row.sendActions(for: .touchUpInside)
        for _ in 0..<60 {
            await settle(0.03)
            if topSheet !== sheet { break }
        }
        await settle(0.08)
    }

    private var topSheet: CCActionSheetController? {
        guard let root = vc.view.window?.rootViewController else { return nil }
        return CCAlert.topmost(from: root) as? CCActionSheetController
    }

    private func waitForSheet() async -> CCActionSheetController? {
        for _ in 0..<60 {
            if let sheet = topSheet, !sheet.isBeingPresented { return sheet }
            await settle(0.03)
        }
        return nil
    }

    private static func rows(in view: UIView) -> [CCActionRow] {
        var found: [CCActionRow] = []
        func walk(_ v: UIView) {
            if let row = v as? CCActionRow, !row.isCancel { found.append(row) }
            v.subviews.forEach(walk)
        }
        walk(view)
        return found
    }

    private func key(_ input: String, _ modifiers: UIKeyModifierFlags = []) {
        guard let command = vc.probeKeyCommand(input, modifiers), let action = command.action else {
            fail("no key command \(input)")
            return
        }
        vc.perform(action, with: command)
        let name = modifiers.contains(.command) ? "⌘\(input.uppercased())" : (input == UIKeyCommand.inputDelete ? "Delete" : input)
        touch("key \(name)")
    }

    private func toolbarMenu(_ keyLabel: String, _ row: String) async {
        guard let button = vc.probeKey(keyLabel) else { fail("no toolbar key \(keyLabel)"); return }
        button.sendActions(for: .touchUpInside)
        touch("toolbar \(keyLabel) → \"\(row)\"")
        await pickRow(row)
    }

    // Lanes

    private func laneMenu(_ lane: TimelineOverlayLane, at time: TimeInterval, _ row: String) async {
        await openLane(lane)
        let p = lanePoint(lane, at: time)
        guard canvas.hit(at: CGPoint(x: p.x + touchOffset, y: p.y)).isEmptyLane else { fail("\(lane) at \(time) s is not empty"); return }
        await longPressMenu(p, "empty \(lane) at \(time) s", row)
    }

    private func effectItem(zoom: UUID?, tilt: UUID?) -> EffectBlockItem? {
        canvas.snapshot.effectItems.first { $0.zoomID == zoom && $0.tiltID == tilt }
    }

    private func pairedZoom(tilt: UUID) -> UUID? { canvas.snapshot.effectItems.first { $0.tiltID == tilt }?.zoomID }
    private func pairedTilt(zoom: UUID) -> UUID? { canvas.snapshot.effectItems.first { $0.zoomID == zoom }?.tiltID }

    private func effectPoint(zoom: UUID?, tilt: UUID?) async -> CGPoint? {
        await openLane(.effects)
        guard let item = effectItem(zoom: zoom, tilt: tilt) else { fail("no effect block \(String(describing: zoom))/\(String(describing: tilt))"); return nil }
        let rect = canvas.effectRect(for: item)
        guard let p = point(in: rect.insetBy(dx: TimelineCanvasMetrics.handleWidth, dy: 0), accepts: {
            let hit = self.canvas.effectItem(at: $0)
            return hit?.zoomID == zoom && hit?.tiltID == tilt
        }) else { fail("effect block has no touchable point"); return nil }
        return p
    }

    private func tapEffect(zoom: UUID?, tilt: UUID?) async {
        guard let p = await effectPoint(zoom: zoom, tilt: tilt) else { return }
        await tap(p, "effect block")
    }

    private func effectMenu(zoom: UUID?, tilt: UUID?, _ row: String) async {
        guard let p = await effectPoint(zoom: zoom, tilt: tilt) else { return }
        await longPressMenu(p, "effect block", row)
    }

    private func focusPoint(_ id: UUID) async -> (CGPoint, CGRect)? {
        await openLane(.focus)
        guard let item = canvas.snapshot.focusItems.first(where: { $0.id == id }) else { fail("no focus block"); return nil }
        let rect = canvas.focusRect(for: item)
        guard let p = point(in: rect.insetBy(dx: TimelineCanvasMetrics.handleWidth, dy: 0),
                            accepts: { self.canvas.focusItem(at: $0)?.id == id }) else {
            fail("focus block \(item.label) is covered — no touchable point"); return nil
        }
        return (p, rect)
    }

    private func tapFocus(_ id: UUID) async {
        guard let (p, _) = await focusPoint(id) else { return }
        await tap(p, "focus block")
    }

    private func focusMenu(_ id: UUID, _ row: String) async {
        guard let (p, _) = await focusPoint(id) else { return }
        await longPressMenu(p, "focus block", row)
    }

    private func menuEntry(_ id: UUID, _ title: String) {
        guard let entry = cb.focusMenuExtras(id).first(where: { $0.title == title }), entry.isEnabled else {
            fail("no enabled menu row \(title)"); return
        }
        entry.action?()
    }

    /// Two edge drags (left edge to `start`, right edge to `end`), each
    /// grabbed inside the 8 pt handle zone.
    private func resizeFocus(_ id: UUID, toStart start: TimeInterval, end: TimeInterval) async {
        guard let item = canvas.snapshot.focusItems.first(where: { $0.id == id }) else { fail("no focus block"); return }
        await openLane(.focus)
        let rect = canvas.focusRect(for: item)
        await drag(from: CGPoint(x: rect.minX + 3, y: rect.midY),
                   to: CGPoint(x: rect.minX + 3 + canvas.x(forOutputTime: output(start)) - canvas.x(forOutputTime: item.startTime), y: rect.midY),
                   "focus left edge → \(start) s")
        guard let moved = canvas.snapshot.focusItems.first(where: { $0.id == id }) else { return }
        let r2 = canvas.focusRect(for: moved)
        await drag(from: CGPoint(x: r2.maxX - 3, y: r2.midY),
                   to: CGPoint(x: r2.maxX - 3 + canvas.x(forOutputTime: output(end)) - canvas.x(forOutputTime: moved.endTime), y: r2.midY),
                   "focus right edge → \(end) s")
    }

    private func annotationPoint(_ id: UUID) async -> CGPoint? {
        await openLane(.annotate)
        guard let item = canvas.snapshot.annotateItems.first(where: { $0.id == id }) else { fail("no annotation"); return nil }
        let rect = canvas.annotateRect(for: item)
        guard let p = point(in: rect.insetBy(dx: min(TimelineCanvasMetrics.handleWidth, rect.width / 3), dy: 0),
                            accepts: { self.canvas.annotateItem(at: $0)?.id == id }) else {
            fail("annotation \(item.label) has no touchable point"); return nil
        }
        return p
    }

    private func tapAnnotation(_ id: UUID) async {
        guard let p = await annotationPoint(id) else { return }
        await tap(p, "annotation block")
    }

    private func annotationMenu(_ id: UUID, _ row: String) async {
        guard let p = await annotationPoint(id) else { return }
        await longPressMenu(p, "annotation block", row)
    }

    private func resizeAnnotation(_ id: UUID, toStart start: TimeInterval, end: TimeInterval) async {
        guard let item = canvas.snapshot.annotateItems.first(where: { $0.id == id }) else { fail("no annotation"); return }
        await openLane(.annotate)
        let rect = canvas.annotateRect(for: item)
        await drag(from: CGPoint(x: rect.minX + 3, y: rect.midY),
                   to: CGPoint(x: rect.minX + 3 + canvas.x(forOutputTime: output(start)) - canvas.x(forOutputTime: item.startTime), y: rect.midY),
                   "annotation left edge → \(start) s")
        guard let moved = canvas.snapshot.annotateItems.first(where: { $0.id == id }) else { return }
        let r2 = canvas.annotateRect(for: moved)
        await drag(from: CGPoint(x: r2.maxX - 3, y: r2.midY),
                   to: CGPoint(x: r2.maxX - 3 + canvas.x(forOutputTime: output(end)) - canvas.x(forOutputTime: moved.endTime), y: r2.midY),
                   "annotation right edge → \(end) s")
    }

    // VIDEO / VOICE

    private func videoPoint(atOutput time: TimeInterval) -> CGPoint? {
        guard let model = canvas.videoModel else { fail("no VIDEO row"); return nil }
        let block = canvas.videoBlockGeometry(model, preview: false)
        return CGPoint(x: canvas.videoOutputOffsetX(time, model: model, block: block),
                       y: TimelineCanvasMetrics.videoLaneY + TimelineCanvasMetrics.trackHeight / 2)
    }

    private func slice(at sourceTime: TimeInterval) async {
        guard let key = vc.probeKey("Slice") else { fail("no Slice key"); return }
        key.sendActions(for: .touchUpInside)
        await settle()
        guard vc.sliceMode, let p = videoPoint(atOutput: output(sourceTime)) else { fail("slice tool did not arm"); return }
        touch("toolbar Slice")
        await tap(p, "VIDEO at \(sourceTime) s with the slice tool")
        if vc.sliceMode { fail("slice tool still armed after the cut") }
    }

    private func videoMenu(atOutput time: TimeInterval, _ row: String, then second: String? = nil) async {
        guard let p = videoPoint(atOutput: time) else { return }
        await longPressMenu(p, "VIDEO at \(time) s", row, then: second)
    }

    private func tapClip(_ index: Int) async {
        guard let model = canvas.videoModel, model.clips.indices.contains(index) else { fail("no clip \(index)"); return }
        let block = canvas.videoBlockGeometry(model, preview: false)
        let rect = canvas.videoClipRect(model.clips[index].ref, model: model, block: block)
        await tap(CGPoint(x: rect.midX, y: rect.minY + 6), "VIDEO clip \(index)")
    }

    private func voiceMenu(_ index: Int, _ row: String) async {
        guard let model = canvas.voiceModel, model.clips.indices.contains(index) else { fail("no voice clip"); return }
        let rect = canvas.voiceClipRect(model.clips[index], model: model)
        await longPressMenu(CGPoint(x: rect.midX, y: rect.midY), "VOICE clip", row)
    }

    // Chips

    private func chipRect(intro: Bool) async -> CGRect? {
        await openLane(.effects)
        guard let rect = intro ? canvas.introChipRect : canvas.curtainChipRect else { fail("no \(intro ? "Slide" : "Curtain") chip"); return nil }
        return rect
    }

    private func chipBodyPoint(_ rect: CGRect) -> CGPoint? {
        point(in: CGRect(x: rect.minX, y: rect.minY, width: max(1, rect.width - 8), height: rect.height)) {
            self.canvas.effectItem(at: $0) == nil && $0.x < rect.maxX - 6
        }
    }

    private func chipMenu(intro: Bool, _ row: String) async {
        guard let rect = await chipRect(intro: intro), let p = chipBodyPoint(rect) else { return }
        await longPressMenu(p, "\(intro ? "Slide" : "Curtain") chip", row)
    }

    private func tapChip(intro: Bool) async {
        guard let rect = await chipRect(intro: intro), let p = chipBodyPoint(rect) else { return }
        await tap(p, "\(intro ? "Slide" : "Curtain") chip")
    }

    private func dragChipEdge(intro: Bool, toOutput end: TimeInterval) async {
        guard let rect = await chipRect(intro: intro) else { return }
        let start = CGPoint(x: rect.maxX - 2, y: rect.midY)
        await drag(from: start, to: CGPoint(x: canvas.x(forOutputTime: end), y: rect.midY), "chip right edge → \(end) s")
    }

    private func dragChipBody(intro: Bool, byPoints dx: CGFloat) async {
        guard let rect = await chipRect(intro: intro), let p = chipBodyPoint(rect) else { return }
        await drag(from: p, to: CGPoint(x: p.x + dx, y: p.y), "chip body +\(Int(dx)) pt (past the end)")
    }

    // MARK: - Touch drags (fresh fixture, real gestures, the Mac's values)

    /// Every drag kind through the view — block move, both block edges on
    /// FOCUS and ANNOTATE, a VOICE clip move, the VIDEO trim edge — each
    /// checked against the value the Mac produces for that edit (the edge
    /// targets are the Mac script's commit values), then the whole stack
    /// unwound through the Undo key back to the fixture.
    func touchDragChecks() async -> Bool {
        var ok = true
        func check(_ name: String, _ pass: Bool, _ detail: String) {
            ok = ok && pass
            print("TOUCH-DRAG \(name) \(pass ? "PASS" : "FAIL") \(detail)")
        }
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-6 }
        let f = { (v: Double) in String(format: "%.6f", v) }
        problems.removeAll()

        // EFFECTS move: the 8–10 zoom, +1 s → 9–11 (its end snaps onto the depth block's 11).
        let zoomID = project.zoomRegions[1].id
        if let p = await effectPoint(zoom: zoomID, tilt: nil) {
            await drag(from: p, to: CGPoint(x: p.x + canvas.x(forOutputTime: 1), y: p.y), "zoom 8–10 body +1 s")
            let z = project.zoomRegions[1]
            check("effect-move", near(z.startTime, 9) && near(z.endTime, 11) && undo.undoActionName == "Move Effect",
                  "zoom \(f(z.startTime))–\(f(z.endTime)) undo=\(undo.undoActionName) (want 9–11, Move Effect)")
        } else { check("effect-move", false, "no block") }

        // FOCUS edges: the highlight 6–8 → 6.5–7.5 (Mac script op 33's values).
        await resizeFocus(project.highlightRegions[0].id, toStart: 6.5, end: 7.5)
        let h = project.highlightRegions[0]
        check("focus-edges", near(h.startTime, 6.5) && near(h.endTime, 7.5) && selection.selectedHighlightID == h.id,
              "highlight \(f(h.startTime))–\(f(h.endTime)) selected=\(selection.selectedHighlightID == h.id) (want 6.5–7.5)")

        // FOCUS edges: the blur 1–3 → 1.25–2.75 (op 36's values — 0.25 s from the 1.0 / 3.0 edges).
        await resizeFocus(project.blurRegions[0].id, toStart: 1.25, end: 2.75)
        let b = project.blurRegions[0]
        check("focus-edges-fine", near(b.startTime, 1.25) && near(b.endTime, 2.75),
              "blur \(f(b.startTime))–\(f(b.endTime)) (want 1.25–2.75)")

        // ANNOTATE edges: the text 1–4 → 1.5–3.5 (op 54's values), undo-registered.
        await resizeAnnotation(project.annotations[0].id, toStart: 1.5, end: 3.5)
        let a = project.annotations[0]
        check("annotate-edges", near(a.startTime, 1.5) && near(a.endTime, 3.5) && undo.undoActionName == "Edit Annotation Timing",
              "text \(f(a.startTime))–\(f(a.endTime)) undo=\(undo.undoActionName) (want 1.5–3.5, Edit Annotation Timing)")

        // VOICE move: the clip at 3 s, +1 s.
        if let model = canvas.voiceModel, let item = model.clips.first {
            let rect = canvas.voiceClipRect(item, model: model)
            await drag(from: CGPoint(x: rect.midX, y: rect.midY),
                       to: CGPoint(x: rect.midX + canvas.x(forOutputTime: 1), y: rect.midY), "voice clip +1 s")
            let v = project.voiceOverClips[0]
            check("voice-move", near(v.startTime, 4) && near(v.duration, 4), "voice start=\(f(v.startTime)) dur=\(f(v.duration)) (want 4, 4)")
        } else { check("voice-move", false, "no voice clip") }

        // VIDEO trim: the whole-track left edge +1 s. (The playhead is a snap
        // target — park it clear of 1 s first; the annotation tap above
        // seeked it to 1.05.)
        playhead.currentTime = 10
        await settle()
        if let model = canvas.videoModel {
            let block = canvas.videoBlockGeometry(model, preview: false)
            let y = TimelineCanvasMetrics.videoLaneY + TimelineCanvasMetrics.trackHeight / 2
            await drag(from: CGPoint(x: block.x + 4, y: y), to: CGPoint(x: block.x + 4 + canvas.x(forOutputTime: 1), y: y),
                       "VIDEO trim edge +1 s")
            check("video-trim", near(project.trimStart, 1) && undo.canUndo,
                  "trimStart=\(f(project.trimStart)) undo=\(undo.undoActionName) (want 1)")
        } else { check("video-trim", false, "no VIDEO row") }

        // The house menu a long press opens, captured in place (artifact).
        if let p = await effectPoint(zoom: zoomID, tilt: nil) {
            reveal(p)
            vc.performLongPress(at: p)
            if let sheet = await waitForSheet() {
                await settle(0.45)
                if let window = vc.view.window, let image = LabCapture.view(window) {
                    try? LabCapture.png(image).write(to: outDir.appendingPathComponent("long-press-menu.png"))
                }
                let rows = Self.rows(in: sheet.view).compactMap(\.accessibilityLabel)
                check("long-press-menu", rows == ["Zoom Level", "Add Tilt to Block", "Remove Zoom", "Delete"],
                      "rows=\(rows) (the Mac's right-click rows for a zoom-only block)")
                sheet.dismiss(animated: false)
                await settle(0.2)
            } else { check("long-press-menu", false, "no menu") }
        }

        // Toolbar keys, touch-only: Duplicate (⌘D's twin) on the selected
        // 9–11 zoom, then Split at the playhead.
        await tapEffect(zoom: zoomID, tilt: nil)
        let zoomsBefore = project.zoomRegions.count
        if let key = vc.probeKey("Duplicate"), key.isEnabled {
            key.sendActions(for: .touchUpInside)
            await settle()
            let copy = project.zoomRegions.last!
            check("duplicate-key", project.zoomRegions.count == zoomsBefore + 1 && undo.undoActionName == "Duplicate Zoom"
                  && selection.selectedZoomID == copy.id,
                  "copy \(f(copy.startTime))–\(f(copy.endTime)) undo=\(undo.undoActionName) (want a new selected zoom, Duplicate Zoom)")
        } else { check("duplicate-key", false, "Duplicate key missing or disabled with a zoom selected") }
        playhead.currentTime = 12
        await settle()
        if let key = vc.probeKey("Split at Playhead") {
            key.sendActions(for: .touchUpInside)
            await settle()
            check("split-key", project.splitPoints.contains { near($0, 12) } && undo.undoActionName == "Split Clip",
                  "splits=\(project.splitPoints.map(f)) undo=\(undo.undoActionName) (want 12, Split Clip)")
        } else { check("split-key", false, "no Split key") }

        // Unwind through the Undo key: every drag's undo, back to the fixture.
        var steps = 0
        while undo.canUndo && steps < 40, let key = vc.probeKey("Undo"), key.isEnabled {
            key.sendActions(for: .touchUpInside)
            steps += 1
            await settle()
        }
        let fixture = TimelineEditsTranscript.makeProject()
        let back = near(project.zoomRegions[1].startTime, fixture.zoomRegions[1].startTime)
            && near(project.annotations[0].startTime, fixture.annotations[0].startTime)
            && near(project.annotations[0].endTime, fixture.annotations[0].endTime)
            && near(project.trimStart, fixture.trimStart)
            && project.zoomRegions.count == fixture.zoomRegions.count && project.splitPoints.isEmpty
        // FOCUS and VOICE commits are not undo-registered on either platform
        // (the old direct binding writes) — they stay; everything else returns.
        check("unwind", back && !undo.canUndo, "\(steps) undo step(s) through the Undo key; undoable edits back at the fixture=\(back)")
        for p in problems { print("PROBLEM " + p) }
        return ok && problems.isEmpty
    }

    // MARK: - Motion checks (sequences, not settled frames)

    /// FOCUS opens on a label tap and closes on a second, checked twice:
    /// (1) LIVE — the real display-link animation sampled every frame (cheap
    /// reads only): some sample must be MID-FLIGHT (openness inside
    /// (0.05, 0.95), the lane between strip and full height), the opening must
    /// overshoot (the growth bounce) and both must settle exactly;
    /// (2) FRAMES — the same animation replayed on the accordion's probe clock
    /// at fixed times and captured through the render server: the blur
    /// block's DRAWN height, measured in pixels, must be strictly between the
    /// strip's and the open lane's at the mid frames.
    func laneMotionCheck() async -> Bool {
        if canvas.openOverlayLane != nil {
            vc.performLaneLabelTap(canvas.openOverlayLane!)
            await settle(0.5)
        }
        var ok = true
        for phase in ["open", "close"] {
            vc.performLaneLabelTap(.focus)
            var samples: [(open: CGFloat, height: CGFloat)] = []
            let began = CACurrentMediaTime()
            while CACurrentMediaTime() - began < 0.5 {
                let layout = canvas.laneLayout
                samples.append((layout.openness(.focus), layout.laneHeight(.focus)))
                await settle(1.0 / 240.0)
            }
            let compact = TimelineLaneLayout.compactRowHeight, full = TimelineCanvasMetrics.trackHeight
            let mid = samples.filter { $0.open > 0.05 && $0.open < 0.95 && $0.height > compact + 1 && $0.height < full - 1 }
            let target: CGFloat = phase == "open" ? 1 : 0
            let settled = abs((samples.last?.open ?? -1) - target) < 0.0001
            let peak = samples.map(\.open).max() ?? 0
            let overshoot = phase == "open" ? peak > 1.001 : true
            let pass = !mid.isEmpty && settled && overshoot
            ok = ok && pass
            let trace = samples.prefix(12).map { String(format: "%.3f", $0.open) }.joined(separator: " ")
            print("LANE-MOTION live \(phase) FOCUS \(pass ? "PASS" : "FAIL") samples=\(samples.count) mid-flight=\(mid.count)"
                  + String(format: " peak=%.3f", peak) + " settled=\(settled) trace=[\(trace) …]"
                  + (mid.isEmpty ? " NOT MID-FLIGHT" : ""))
            await settle(0.2)
        }
        ok = await laneFrames() && ok
        return ok
    }

    /// The opening replayed on the probe clock, captured at fixed times.
    private func laneFrames() async -> Bool {
        let accordion = canvas.laneAccordion
        guard let blur = canvas.snapshot.focusItems.first(where: { !$0.isHighlight }) else {
            print("LANE-MOTION frames FAIL (no blur block)"); return false
        }
        reveal(CGPoint(x: canvas.focusRect(for: blur).midX, y: 1))
        await settle(0.1)
        var clock = CACurrentMediaTime()
        accordion.probeClock = { clock }
        defer { accordion.probeClock = nil }
        let times: [TimeInterval] = [0, 0.02, 0.04, 0.07, 0.28]
        var heights: [CGFloat] = []
        let start = clock
        vc.performLaneLabelTap(.focus)
        for (k, t) in times.enumerated() {
            clock = start + t
            accordion.tick()
            canvas.layoutIfNeeded()
            await settle(0.05)
            guard let image = LabCapture.view(vc.view) else { heights.append(-1); continue }
            try? LabCapture.png(image).write(to: outDir.appendingPathComponent(String(format: "lane-open-%d-t%03d.png", k, Int(t * 1000))))
            // A column clear of the corner radius and of the centred label.
            let rect = canvas.focusRect(for: blur)
            let column = canvas.convert(CGPoint(x: rect.minX + 24, y: 0), to: vc.view).x
            let band = (canvas.convert(CGPoint(x: 0, y: canvas.laneLayout.laneY(.focus) - 4), to: vc.view).y,
                        canvas.convert(CGPoint(x: 0, y: canvas.laneLayout.laneY(.focus) + TimelineCanvasMetrics.trackHeight + 4), to: vc.view).y)
            let scale = CGFloat(image.width) / vc.view.bounds.width
            heights.append(Self.blueRun(in: image, x: column * scale, from: band.0 * scale, to: band.1 * scale) / scale)
        }
        accordion.tick()
        let strip = heights.first ?? 0, open = heights.last ?? 0
        let mids = heights.dropFirst().dropLast().filter { $0 > strip + 1 && $0 < open - 1 }
        let pass = strip > 4 && open > strip + 10 && !mids.isEmpty
        print("LANE-MOTION frames FOCUS \(pass ? "PASS" : "FAIL") drawn blur height (pt) at t="
              + zip(times, heights).map { String(format: "%.2f:%.1f", $0, $1) }.joined(separator: " ")
              + (mids.isEmpty ? " NOT MID-FLIGHT" : " mid-flight=\(mids.count)"))
        // Close it again for whatever runs next.
        vc.performLaneLabelTap(.focus)
        await settle(0.5)
        return pass
    }

    /// Length of the longest vertical run of blur-slate pixels (blue clearly
    /// above red and green) in one column of a capture.
    private static func blueRun(in image: CGImage, x: CGFloat, from y0: CGFloat, to y1: CGFloat) -> CGFloat {
        let width = image.width, height = image.height
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return 0 }
        let col = min(width - 1, max(0, Int(x)))
        var best = 0, run = 0
        for y in max(0, Int(y0))..<min(height, Int(y1)) {
            // CGContext memory is top-row-first for a bitmap drawn this way.
            let i = (y * width + col) * 4
            let r = Int(data[i]), g = Int(data[i + 1]), b = Int(data[i + 2])
            if b > 120 && b > r + 40 && b > g + 25 { run += 1; best = max(best, run) } else { run = 0 }
        }
        return CGFloat(best)
    }

    /// Select one block, then another: the outline must be caught between
    /// the two (strictly), then land on the second.
    func selectionGlideCheck() async -> Bool {
        await openLane(.annotate)
        let items = canvas.snapshot.annotateItems.sorted { $0.startTime < $1.startTime }
        guard items.count >= 2, let a = await annotationPoint(items[0].id), let b = await annotationPoint(items[1].id) else {
            print("SELECTION-GLIDE FAIL (fixture)"); return false
        }
        vc.performTap(at: a)
        await settle(0.8)
        guard let from = canvas.probeRing.rect else { print("SELECTION-GLIDE FAIL (no outline)"); return false }
        vc.performTap(at: b)
        var mids = 0, samples = 0
        let began = CACurrentMediaTime()
        while CACurrentMediaTime() - began < 0.7 {
            await settle(1.0 / 120.0)
            samples += 1
            guard let r = canvas.probeRing.rect else { continue }
            if samples == 3, let image = LabCapture.view(vc.view) {
                try? LabCapture.png(image).write(to: outDir.appendingPathComponent("selection-glide-mid.png"))
            }
            if canvas.probeRing.gliding, r.minX > min(from.minX, finalX()) + 1, r.minX < max(from.minX, finalX()) - 1 { mids += 1 }
        }
        let to = canvas.probeRing.rect ?? .zero
        let landed = abs(to.minX - finalX()) < 0.5
        let pass = mids > 0 && landed
        print("SELECTION-GLIDE \(pass ? "PASS" : "FAIL") samples=\(samples) mid-flight=\(mids)"
              + String(format: " from x=%.1f to x=%.1f", from.minX, to.minX) + (mids == 0 ? " NOT MID-FLIGHT" : ""))
        return pass
    }

    private func finalX() -> CGFloat { canvas.selectedBlockFrame()?.rect.minX ?? 0 }
}

private extension StudioTimelineHit {
    var isEmptyLane: Bool {
        switch self {
        case .emptyEffects, .emptyFocus, .emptyAnnotate: return true
        default: return false
        }
    }
}
