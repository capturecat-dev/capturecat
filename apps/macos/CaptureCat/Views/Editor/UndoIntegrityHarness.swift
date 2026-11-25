import AppKit

/// `--undo-integrity-test [--inject drag-no-undo|append-on-undo|no-redo] [--verbose]`
///
/// Every user edit = exactly ONE undo step that round-trips. For each lane
/// and kind, on a fresh fixture and the REAL `TimelineViewController` in a
/// window (its own undo manager, the lanes' own callbacks, ⌘D / ⌘B / Delete,
/// the FOCUS menu rows, the inspector's shared contexts):
///
///   edit (one undo group)        → the model changed, the step is named
///   undo                         → encoded project JSON byte-equal to before
///   redo                         → byte-equal to after
///   undo, redo again             → still byte-equal (undo/redo alternate)
///
/// Deletes act on a MIDDLE item and also assert it is back at its index after
/// undo (array order is stacking order for annotations).
///
/// `--inject` turns on one of the original defects (`UndoStep.probeDefect`,
/// DEBUG only) — the gate must then FAIL on exactly the cases that defect
/// breaks; the summary names them.
@MainActor
enum UndoIntegrityHarness {
    static func run() -> Never {
        setbuf(stdout, nil)
        NSApplication.shared.setActivationPolicy(.accessory)
        let args = CommandLine.arguments
        let verbose = args.contains("--verbose")
        #if DEBUG
        if let i = args.firstIndex(of: "--inject"), i + 1 < args.count {
            guard let defect = UndoStep.Defect(rawValue: args[i + 1]) else {
                print("unknown defect \(args[i + 1]); one of \(UndoStep.Defect.allCases.map(\.rawValue))")
                exit(2)
            }
            UndoStep.probeDefect = defect
            print("INJECTED DEFECT: \(defect.rawValue)")
        }
        #else
        if args.contains("--inject") {
            print("--inject needs a DEBUG build")
            exit(2)
        }
        #endif

        var failed: [String] = []
        for c in cases {
            let problems = check(c, verbose: verbose)
            if problems.isEmpty {
                print("ok   \(c.name)")
            } else {
                failed.append(c.name)
                print("FAIL \(c.name): " + problems.joined(separator: "; "))
            }
        }
        if failed.isEmpty {
            print("UNDO-INTEGRITY PASS (\(cases.count) edits: one step each; undo == before, redo == after, byte-exact, twice; middle deletes back at their index)")
            exit(0)
        }
        print("UNDO-INTEGRITY FAIL (\(failed.count)/\(cases.count) edits): \(failed.joined(separator: ", "))")
        exit(1)
    }

    // MARK: - Cases

    struct Case {
        let name: String
        var prepare: (Rig) -> Void = { _ in }
        let edit: (Rig) -> Void
        /// A delete of a middle item: (list name, list ids reader, the id).
        var restoresIndex: ((Rig) -> (ids: () -> [UUID], id: UUID, index: Int))?
    }

    static let u = TimelineEditsTranscript.uuid

    static var cases: [Case] {
        var c: [Case] = []
        func add(_ name: String, prepare: @escaping (Rig) -> Void = { _ in }, _ edit: @escaping (Rig) -> Void) {
            c.append(Case(name: name, prepare: prepare, edit: edit))
        }
        func delete(_ name: String, prepare: @escaping (Rig) -> Void = { _ in },
                    ids: @escaping (Project) -> [UUID], index: Int = 1, _ edit: @escaping (Rig, UUID) -> Void) {
            c.append(Case(name: name, prepare: prepare, edit: { rig in edit(rig, ids(rig.project)[index]) },
                          restoresIndex: { rig in (ids: { ids(rig.project) }, id: ids(rig.project)[index], index: index) }))
        }

        // EFFECTS lane
        add("effects.add-zoom") { $0.cb.addZoomAt(6.5) }
        add("effects.add-tilt") { $0.cb.addTiltAt(6.5) }
        add("effects.showcase", prepare: { $0.playhead(6) }) { $0.vc.addShowcaseBlock() }
        add("effects.scale-down", prepare: { $0.playhead(6) }) { $0.vc.addScaleDownBlock() }
        add("effects.zoom-level") { $0.cb.setZoomLevel(u(2), 2.25) }
        add("effects.add-tilt-to-block") { $0.cb.addTiltToBlock(u(2)) }
        add("effects.add-zoom-to-block") { $0.cb.addZoomToBlock(u(102)) }
        add("effects.move-block (joined slide)") { $0.cb.commitEffectTimes(u(1), u(3), 3, 6) }
        add("effects.resize-zoom") { $0.cb.commitEffectTimes(u(2), nil, 7.5, 10.5) }
        add("effects.duplicate-linked (⌘D)", prepare: { $0.cb.selectEffect(u(1), u(3)) }) { _ = $0.vc.handleCommandKey("d") }
        add("effects.duplicate-zoom (⌘D)", prepare: { $0.cb.selectEffect(u(2), nil) }) { _ = $0.vc.handleCommandKey("d") }
        add("effects.duplicate-tilt (⌘D)", prepare: { $0.cb.selectEffect(nil, u(102)) }) { _ = $0.vc.handleCommandKey("d") }
        add("effects.delete-linked-block") { $0.cb.deleteEffectBlock(u(1), u(3)) }
        delete("effects.delete-zoom (middle)", ids: { $0.zoomRegions.map(\.id) }) { $0.cb.removeZoom($1) }
        delete("effects.delete-tilt (middle)", ids: { $0.tiltRegions.map(\.id) }) { $0.cb.removeTilt($1) }
        delete("effects.delete-zoom (Delete key)", prepare: { $0.cb.selectEffect(u(2), nil) },
               ids: { $0.zoomRegions.map(\.id) }) { rig, _ in rig.keyDown(51) }

        // Slide + Curtain chips
        add("chips.enable-slide", prepare: { $0.project.settings.introSlideStyle = .off }) { $0.vc.enableIntroSlide() }
        add("chips.enable-curtain") { $0.vc.enableCurtainUnveil() }
        add("chips.delete-slide") { $0.cb.deleteIntro() }
        add("chips.delete-curtain", prepare: { $0.project.settings.curtainUnveilCorner = .topLeft }) { $0.cb.deleteCurtain() }
        add("chips.resize-slide (drag)") { rig in rig.chipDrag { rig.cb.resizeIntro(4.2) } }
        add("chips.move-slide (drag)") { rig in rig.chipDrag { rig.cb.moveIntro(6) } }
        add("chips.move-curtain (drag)", prepare: { $0.project.settings.curtainUnveilCorner = .topLeft }) { rig in
            rig.chipDrag { rig.cb.moveCurtain(9) }
        }

        // FOCUS lane
        add("focus.add-blur", prepare: { $0.project.blurRegions.removeLast() }) { $0.cb.addBlurAt(18.2) }
        add("focus.add-highlight", prepare: { $0.project.blurRegions.removeLast() }) { $0.cb.addHighlightAt(18.2) }
        add("focus.add-depth", prepare: { $0.project.blurRegions.removeLast(); $0.playhead(18.2) }) { $0.vc.addDepthFocusRegion() }
        add("focus.draw-pixelate", prepare: { $0.project.blurRegions.removeLast(); $0.playhead(18.2) }) {
            $0.vc.createBlurRegion(rect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.25), style: .pixelate)
        }
        add("focus.add-camera-layout", prepare: { $0.project.blurRegions.removeLast(); $0.playhead(18.2) }) {
            $0.vc.addCameraLayoutRegion(mode: .sideBySide)
        }
        add("focus.drag-blur") { $0.cb.commitFocusTimes(u(4), false, 1.25, 2.75) }
        add("focus.drag-highlight") { $0.cb.commitFocusTimes(u(5), true, 6.25, 7.75) }
        add("focus.drag-depth") { $0.cb.commitFocusTimes(u(6), false, 11.25, 12.75) }
        add("focus.drag-camera-layout") { $0.cb.commitFocusTimes(u(7), false, 14.25, 16.75) }
        for title in ["Camera on Left", "Full Height"] {
            add("focus.menu \(title)") { $0.menu(u(7), title) }
        }
        add("focus.menu Paste Layout", prepare: { rig in
            rig.menu(u(7), "Camera on Left")
            rig.menu(u(7), "Copy Layout")
        }) { $0.menu(u(110), "Paste Layout") }
        add("focus.duplicate-blur (⌘D)", prepare: { $0.cb.selectFocus(u(104), false) }) { _ = $0.vc.handleCommandKey("d") }
        add("focus.duplicate-highlight (⌘D)", prepare: { $0.cb.selectFocus(u(5), true) }) { _ = $0.vc.handleCommandKey("d") }
        delete("focus.delete-blur (middle)", ids: { $0.blurRegions.map(\.id) }) { $0.cb.deleteFocus($1, false) }
        delete("focus.delete-highlight (middle)", ids: { $0.highlightRegions.map(\.id) }) { $0.cb.deleteFocus($1, true) }
        delete("focus.delete-depth (middle)", ids: { $0.focusRegions.map(\.id) }) { $0.cb.deleteFocus($1, false) }
        delete("focus.delete-camera-layout (middle)", ids: { $0.cameraLayoutRegions.map(\.id) }) { $0.cb.deleteFocus($1, false) }

        // ANNOTATE lane + the pill's undoable writes
        add("annotate.add-text") { $0.cb.addAnnotationAt(.text, 9) }
        add("annotate.add-arrow") { $0.cb.addAnnotationAt(.arrow, 10) }
        add("annotate.drag") { $0.cb.commitAnnotationTimes(u(9), 5.5, 8.5) }
        add("annotate.recolor", prepare: { $0.cb.selectAnnotation(u(9)) }) {
            $0.vc.applyToolbarColor(NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1))
        }
        delete("annotate.delete (middle, canvas)", ids: { $0.annotations.map(\.id) }) { $0.cb.deleteAnnotation($1) }
        delete("annotate.delete (middle, Delete key)", prepare: { $0.cb.selectAnnotation(u(9)) },
               ids: { $0.annotations.map(\.id) }) { rig, _ in rig.keyDown(51) }
        delete("annotate.delete (middle, inspector)", prepare: { $0.cb.selectAnnotation(u(9)) },
               ids: { $0.annotations.map(\.id) }) { rig, _ in
            AnnotationPane.delete.run(InspectorScope(
                project: rig.project, env: InspectorEnvironment(),
                annotate: InspectorPaneContexts.annotate(selection: rig.selection, currentTime: rig.playback.currentTime,
                                                         undoManager: rig.undo)))
        }

        // Inspector block adds / deletes (shared contexts)
        add("inspector.delete-zoom", prepare: { $0.cb.selectEffect(u(2), nil) }) { $0.motion.onDeleteZoom() }
        add("inspector.delete-tilt", prepare: { $0.cb.selectEffect(nil, u(102)) }) { $0.motion.onDeleteTilt() }
        add("inspector.delete-highlight", prepare: { $0.cb.selectFocus(u(106), true) }) { $0.motion.onDeleteHighlight() }
        add("inspector.delete-blur", prepare: { $0.cb.selectFocus(u(104), false) }) { $0.motion.onDeleteBlurRegion() }
        add("inspector.delete-depth", prepare: { $0.cb.selectFocus(u(108), false) }) { $0.motion.onDeleteFocusRegion() }
        add("inspector.add-zoom-at-playhead", prepare: { $0.playhead(6) }) { $0.motion.onAddZoomBlockAtPlayhead() }
        add("inspector.add-tilt-at-playhead", prepare: { $0.playhead(6) }) { $0.motion.onAddTiltBlockAtPlayhead() }
        add("inspector.add-tilt-to-block", prepare: { $0.cb.selectEffect(u(2), nil) }) { $0.motion.onAddTiltToBlock() }

        // VIDEO lane
        add("video.slice") { $0.video.sliceAt(3) }
        add("video.⌘B", prepare: { $0.playhead(16) }) { _ = $0.vc.handleCommandKey("b") }
        add("video.delete-split") { $0.video.deleteSplit($0.outputTime(12)) }
        delete("video.delete-clip (middle, Delete key)", prepare: { $0.video.selectClip(u(120)) },
               ids: { $0.videoClipSegments.map(\.id) }) { rig, _ in rig.keyDown(51) }
        add("video.trim-head") { $0.video.commitWholeDrag(.resizeLeft, 1, 1, $0.outputDuration) }
        add("video.trim-tail") { rig in rig.video.commitWholeDrag(.resizeRight, -1, 0, rig.outputDuration - 1) }
        add("video.clip-edge") { rig in
            rig.video.commitClipEdge(rig.clipRef(u(120)), .right, rig.outputTime(11))
        }
        add("video.mute") { $0.video.toggleMute() }
        add("speed.add") { $0.video.addSpeedRange(13, 15, 2) }
        add("speed.change") { $0.video.changeSpeed(u(115), 3) }
        add("speed.duplicate (⌘D)", prepare: { $0.vc.selectedSpeedID = u(116) }) { _ = $0.vc.handleCommandKey("d") }
        delete("speed.delete (middle)", ids: { $0.speedRegions.map(\.id) }) { $0.video.deleteSpeed($1) }

        // VOICE lane
        add("voice.move (drag)") { rig in
            var clip = rig.voiceOutputClip(u(117))
            clip.startTime += 0.5
            rig.voice.commitClip(u(117), clip)
        }
        add("voice.trim (drag)") { rig in
            var clip = rig.voiceOutputClip(u(117))
            clip.duration -= 0.5
            rig.voice.commitClip(u(117), clip)
        }
        delete("voice.delete (middle)", ids: { $0.voiceOverClips.map(\.id) }) { $0.voice.deleteClip($1) }
        return c
    }

    // MARK: - Check

    static func check(_ c: Case, verbose: Bool) -> [String] {
        let rig = Rig()
        defer { rig.close() }
        let undo = rig.undo
        undo.beginUndoGrouping()   // set-up edits may register; dropped below
        c.prepare(rig)
        undo.endUndoGrouping()
        rig.settle()
        undo.removeAllActions()
        let before = rig.encoded()
        let restore = c.restoresIndex?(rig)

        undo.beginUndoGrouping()
        c.edit(rig)
        undo.endUndoGrouping()
        rig.settle()
        let after = rig.encoded()
        var problems: [String] = []
        guard after != before else { return ["the edit changed nothing (fixture problem)"] }
        let name = undo.undoActionName
        if name.isEmpty { problems.append("no named undo step registered") }

        for round in 1...2 {
            guard undo.canUndo else { problems.append("round \(round): nothing to undo"); break }
            undo.undo()
            rig.settle()
            if rig.encoded() != before {
                problems.append("round \(round): undo does not restore the model (\(rig.diff(before)))")
                break
            }
            if let restore, round == 1 {
                let ids = restore.ids()
                if ids.firstIndex(of: restore.id) != restore.index {
                    problems.append("undo put the item at index \(ids.firstIndex(of: restore.id).map(String.init) ?? "nil"), not \(restore.index)")
                }
            }
            if undo.canUndo { problems.append("round \(round): more than one undo step") }
            guard undo.canRedo else { problems.append("round \(round): no redo after undo"); break }
            undo.redo()
            rig.settle()
            if rig.encoded() != after {
                problems.append("round \(round): redo does not re-apply the edit (\(rig.diff(after)))")
                break
            }
        }
        if verbose { print("     \(c.name): step \"\(name)\"") }
        return problems
    }

    // MARK: - Rig

    /// A fresh fixture in the real timeline, per case.
    @MainActor
    final class Rig {
        let project: Project
        let playback = EditorPlaybackController(appState: nil)
        let selection = EditorShellSelection()
        let vc: TimelineViewController
        let window: NSWindow

        var undo: UndoManager { window.undoManager! }

        init() {
            project = UndoIntegrityHarness.makeProject()
            vc = TimelineViewController(project: project, playback: playback, selection: selection,
                                        onToggleVoiceOverRecording: {})
            window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1200, height: 420),
                              styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentViewController = vc
            window.setContentSize(NSSize(width: 1200, height: 420))
            window.orderFrontRegardless()
            undo.groupsByEvent = false
            settle()
        }

        func close() {
            undo.removeAllActions()
            window.orderOut(nil)
        }

        private var canvas: TimelineCanvasView { Self.find(TimelineCanvasView.self, in: vc.view)! }
        var cb: TimelineCanvasCallbacks { canvas.callbacks! }
        var video: TimelineVideoCallbacks { canvas.videoCallbacks! }
        var voice: TimelineVoiceCallbacks { canvas.voiceCallbacks! }
        var motion: MotionPaneContext {
            InspectorPaneContexts.motion(project: project, selection: selection, undoManager: undo,
                                         currentTime: { [playback] in playback.currentTime })
        }

        private static func find<T: NSView>(_ type: T.Type, in root: NSView) -> T? {
            if let match = root as? T { return match }
            for sub in root.subviews {
                if let found = find(type, in: sub) { return found }
            }
            return nil
        }

        func settle() {
            vc.view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }

        func playhead(_ t: TimeInterval) {
            playback.currentTime = t
            settle()
        }

        var outputDuration: TimeInterval { vc.outputDuration }
        func outputTime(_ source: TimeInterval) -> TimeInterval { vc.fullTimeMap.outputTime(forSource: source) }

        func clipRef(_ id: UUID) -> VideoClipRef {
            let clip = project.effectiveVideoClipSegments.first { $0.id == id }!
            return VideoClipRef(id: id, sourceStart: clip.startTime, sourceEnd: clip.endTime,
                                outputStart: outputTime(clip.startTime), outputEnd: outputTime(clip.endTime))
        }

        func voiceOutputClip(_ id: UUID) -> VoiceOverClip {
            VoiceTrackCommits(project: project, timeMap: vc.fullTimeMap)
                .outputClip(for: project.voiceOverClips.first { $0.id == id }!)
        }

        /// A Slide / Curtain chip drag as the canvases run it: spans at the
        /// press, live writes, the commit on release.
        func chipDrag(_ live: () -> Void) {
            let before = cb.chipSpans()
            live()
            settle()
            cb.commitChipDrag(before)
        }

        func menu(_ regionID: UUID, _ title: String) {
            cb.focusMenuExtras(regionID).first { $0.title == title }?.action?()
        }

        func keyDown(_ keyCode: UInt16) {
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\u{7f}",
                charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: keyCode
            ) else { return }
            _ = vc.handleKeyDown(event)
        }

        func encoded() -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return (try? encoder.encode(project)) ?? Data()
        }

        /// The top-level keys that differ from `reference` (for the message).
        func diff(_ reference: Data) -> String {
            guard let a = try? JSONSerialization.jsonObject(with: reference) as? [String: Any],
                  let b = try? JSONSerialization.jsonObject(with: encoded()) as? [String: Any] else { return "?" }
            let keys = Set(a.keys).union(b.keys).filter { key in
                let l = a[key].flatMap { try? JSONSerialization.data(withJSONObject: [$0], options: .sortedKeys) }
                let r = b[key].flatMap { try? JSONSerialization.data(withJSONObject: [$0], options: .sortedKeys) }
                return l != r
            }
            return "differs in " + keys.sorted().joined(separator: ",")
        }
    }

    // MARK: - Fixture

    /// The timeline-edits fixture with THREE items in every list (so deletes
    /// can take a middle one), three speed regions, three voice clips and
    /// three video clips.
    static func makeProject() -> Project {
        let p = TimelineEditsTranscript.makeProject()
        p.zoomRegions.append(ZoomRegion(id: u(101), startTime: 14, endTime: 16, zoomLevel: 1.4))
        p.tiltRegions += [TiltRegion(id: u(102), startTime: 11, endTime: 12, pitch: 8, yaw: 2, roll: 0),
                          TiltRegion(id: u(103), startTime: 17, endTime: 18, pitch: 5, yaw: 0, roll: 1)]
        p.blurRegions += [BlurRegion(id: u(104), startTime: 4, endTime: 5),
                          BlurRegion(id: u(105), startTime: 18, endTime: 19)]
        p.highlightRegions += [HighlightRegion(id: u(106), startTime: 9, endTime: 10),
                               HighlightRegion(id: u(107), startTime: 10.2, endTime: 10.8)]
        p.focusRegions += [FocusRegion(id: u(108), startTime: 13.2, endTime: 13.8),
                           FocusRegion(id: u(109), startTime: 19.2, endTime: 19.8)]
        p.cameraLayoutRegions += [CameraLayoutRegion(id: u(110), startTime: 0, endTime: 0.8, mode: .sideBySide),
                                  CameraLayoutRegion(id: u(111), startTime: 17.2, endTime: 17.9, mode: .sideBySide)]
        p.annotations += [Annotation(id: u(112), type: .rectangle, startTime: 10, endTime: 12),
                          Annotation(id: u(113), type: .ellipse, startTime: 12, endTime: 14)]
        p.speedRegions = [VideoSpeedRegion(id: u(114), startTime: 2.5, endTime: 3.5, speed: 2),
                          VideoSpeedRegion(id: u(115), startTime: 5, endTime: 6, speed: 1.5),
                          VideoSpeedRegion(id: u(116), startTime: 9, endTime: 10, speed: 0.5)]
        p.voiceOverClips += [VoiceOverClip(id: u(117), fileName: "undo-integrity-missing-2.m4a", startTime: 8, duration: 2),
                             VoiceOverClip(id: u(118), fileName: "undo-integrity-missing-3.m4a", startTime: 14, duration: 3)]
        p.videoClipSegments = [VideoClipSegment(id: u(119), startTime: 0, endTime: 6),
                               VideoClipSegment(id: u(120), startTime: 6, endTime: 12),
                               VideoClipSegment(id: u(121), startTime: 12, endTime: 20)]
        p.splitPoints = [6, 12]
        return p
    }
}
