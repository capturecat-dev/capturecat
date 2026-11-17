import UIKit

/// `--a11y <outDir> [--inject missing-label|tiny-target|snap-under-reduce-motion|action-not-undoable|truncation]`
/// (Studio 6a) — the studio with assistive technology, in the REAL window
/// chain: the shipping `EditorViewController` presented full screen in
/// StudioLab's real UIWindow (CLAUDE.md §3 — bare windows lied before), every
/// studio screen opened from it the way the app opens it.
///
/// Per screen (`screens`): what VoiceOver can reach (`CCAccessibilityAudit`)
/// — labels, interactive traits, adjustable values, hit targets ≥ 44 pt
/// MEASURED by hit-testing the window, no overlapping focusable frames — at
/// the default size and again at the largest accessibility text size, where
/// every visible label must also fit (no truncation, no overlap, nothing cut
/// off by a non-scrolling clip). Then:
///  • ACTIONS — timeline blocks and stage objects: activation and each custom
///    action against the touch path driven independently (the gesture entry
///    points with points this lab derives from what it sees): the same
///    project change, exactly ONE undo step that restores the opening bytes;
///  • the transport's adjustable playhead; spoken announcements;
///  • REDUCE MOTION, captured mid-flight: opacity between its endpoints and
///    NO change of position, scale or size, for every kit motion kind;
///  • the keyboard (iPad): each command fires its action through the
///    responder chain; inspector controls take keyboard focus; pointer hover;
///  • Increase Contrast, Reduce Transparency, Differentiate Without Color and
///    Bold Text reach the kit's colours, materials, states and type.
/// `--inject` plants one defect; the gate must FAIL on it.
@available(iOS 26, *)
@MainActor
enum A11yLab {
    private static var lines: [String] = []
    private static var failures = 0
    private static var out: URL!
    private static var inject: String?

    /// One studio screen the gate opens and audits.
    struct Screen {
        let name: String
        /// Opens the screen on the editor; returns what to audit (nil = the window).
        let open: (EditorViewController) async -> UIView?
        let close: (EditorViewController) async -> Void
    }

    /// EXPORT HOOK (Studio 6a ↔ the Export sheet, `apps/ios/StudioUI/Export/`):
    /// after the merge, register the sheet here so the gate audits it like
    /// every other screen —
    ///
    ///     A11yLab.extraScreens.append(.init(name: "export",
    ///         open: { editor in StudioExport.present(from: editor, …); return nil },
    ///         close: { editor in await A11yLab.dismissPresented(editor) }))
    ///
    /// and add ⌘E to `keyboard(_:)`'s expected commands.
    static var extraScreens: [Screen] = []

    /// The editor redesign's screens and the Export sheet, through the hook:
    /// the tool bar's Add sheet, its context keys for a selection, a pane's
    /// panel opened from its TOOL (the key's own action), the full-screen
    /// preview, and the Export sheet opened from the header's Export key.
    @available(iOS 26, *)
    static func registerEditorScreens() {
        guard !extraScreens.contains(where: { $0.name == "export" }) else { return }
        extraScreens += [
            Screen(name: "export", open: { editor in
                editor.exportButton.sendActions(for: .touchUpInside)
                await settle(1.0)
                return nil
            }, close: { editor in await dismissPresented(editor) }),
            Screen(name: "tool-add-sheet", open: { editor in
                editor.toolBar.key(for: .add)?.sendActions(for: .touchUpInside)
                await settle(0.8)
                return nil
            }, close: dismissPresented),
            Screen(name: "tool-context-keys", open: { editor in
                editor.timeline.canvas.setOpenLane(.focus, animated: false)
                editor.selection.selectedHighlightID = editor.project.highlightRegions.first?.id
                await settle(0.6)
                return nil
            }, close: { editor in
                editor.timeline.clearTimelineSelection()
                editor.timeline.canvas.setOpenLane(nil, animated: false)
                await settle(0.4)
            }),
            Screen(name: "tool-panel", open: { editor in
                if let key = editor.toolBar.key(for: .pane(.camera)) {
                    key.sendActions(for: .touchUpInside)
                    await settle(0.6)
                    // The pane's level: its first sub-option opens a short panel.
                    if !editor.isPanelOpen, let first = editor.toolBar.options.first,
                       let option = editor.toolBar.key(for: .option(first.id)) {
                        option.sendActions(for: .touchUpInside)
                    }
                } else {
                    editor.selection.inspectorTab = .camera
                }
                await settle(0.8)
                return nil
            }, close: { editor in
                editor.closePanel(animated: false)
                if case .pane = editor.toolBar.mode { editor.toolBar.key(for: .back)?.sendActions(for: .touchUpInside) }
                await settle(0.4)
            }),
            Screen(name: "preview-expanded", open: { editor in
                editor.transport.expandButton.sendActions(for: .touchUpInside)
                await settle(0.6)
                return nil
            }, close: { editor in
                editor.setPreviewExpanded(false, animated: false)
                await settle(0.4)
            }),
        ]
    }

    static func start(_ arguments: [String], lab: LabViewController) -> Bool {
        guard let i = arguments.firstIndex(of: "--a11y"), arguments.indices.contains(i + 1) else { return false }
        out = URL(fileURLWithPath: arguments[i + 1], isDirectory: true)
        inject = arguments.firstIndex(of: "--inject").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        lab.stage.isHidden = true
        guard #available(iOS 26, *) else {
            print("A11Y-GATE FAIL the studio needs iOS 26")
            exit(1)
        }
        Task { @MainActor in await run(lab: lab) }
        return true
    }

    // MARK: - Run

    @available(iOS 26, *)
    static func run(lab: LabViewController) async {
        setbuf(stdout, nil)
        UIApplication.shared.isIdleTimerDisabled = true
        InspectorSounds.muted = true
        let fm = FileManager.default
        try? fm.removeItem(at: out)
        try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        try? fm.createDirectory(at: out.appendingPathComponent("xxxl"), withIntermediateDirectories: true)
        log("A11Y out=\(out.path) device=\(UIDevice.current.model) \(UIDevice.current.systemVersion) "
            + "window=\(Int(lab.view.window?.bounds.width ?? 0))×\(Int(lab.view.window?.bounds.height ?? 0))")
        if let inject {
            log("A11Y inject=\(inject)")
            // Each defect is planted in the shipping kit / views before the
            // editor opens, through a DEBUG probe seam.
            switch inject {
            case "missing-label": CCButton.probeDropIconLabels = true
            case "tiny-target": CCButton.probeNoTargetExpansion = true
            case "truncation": CCHeaderBar.probeTruncateTitle = true
            case "snap-under-reduce-motion": CCMotion.probeReduceSnap = true
            case "action-not-undoable": StudioTimelineCanvasView.probeActionBypassesUndo = true
            default: log("A11Y-GATE FAIL unknown --inject \(inject)"); exit(1)
            }
        }
        lab.view.window?.overrideUserInterfaceStyle = .dark
        // UIKit's own accessibility answers must exist (the script turns the
        // simulator's app-accessibility runtime on), or the audit is blind.
        let axLoaded = lab.view.window.map(CCAccessibilityAudit.runtimeLoaded(in:)) ?? false
        check("ax-runtime", axLoaded, axLoaded
              ? "UIKit accessibility runtime loaded" : "UIKit accessibility runtime NOT loaded (run through ios-a11y.sh)")
        guard let editor = await openEditor(lab: lab) else { finish(); return }
        registerEditorScreens()

        // An injected defect runs only the part it plants into (gate power, fast);
        // a clean run runs everything.
        switch inject {
        case "missing-label"?, "tiny-target"?, "truncation"?:
            await screensAudit(editor, only: ["editor", "inspector-background"])
        case "snap-under-reduce-motion"?:
            await reduceMotion(editor)
        case "action-not-undoable"?:
            await timelineActions(editor)
        default:
            await screensAudit(editor)
            await timelineActions(editor)
            await stageActions(editor)
            await transport(editor)
            await panelVoiceOver(editor)
            await reduceMotion(editor)
            await keyboard(editor)
            await settings(editor)
        }
        await close(editor)
        finish()
    }

    private static func finish() -> Never {
        try? lines.joined(separator: "\n").write(to: out.appendingPathComponent("run.txt"), atomically: true, encoding: .utf8)
        if failures == 0 {
            log("A11Y-GATE PASS")
            exit(0)
        }
        log("A11Y-GATE FAIL (\(failures) check(s) failed)")
        exit(1)
    }

    // MARK: - Editor

    @available(iOS 26, *)
    private static func openEditor(lab: LabViewController) async -> EditorViewController? {
        let dir = out.appendingPathComponent("project", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let project = InspectorValuesTranscript.makeProject(folder: dir)
        guard let poster = poster(size: CGSize(width: 640, height: 400)),
              (try? await StillMovieWriter.write(image: poster, to: dir.appendingPathComponent("screen.mov"), duration: 20)) != nil,
              (try? await StillMovieWriter.write(image: poster, to: dir.appendingPathComponent("camera.mov"), duration: 20)) != nil,
              let data = try? JSONEncoder().encode(project),
              (try? data.write(to: dir.appendingPathComponent(StudioProjectFolder.documentName))) != nil,
              let folder = try? StudioProjectFolder.open(dir) else {
            check("open", false, "could not write or open the fixture project")
            return nil
        }
        let editor = EditorViewController(folder: folder, initialTime: InspectorValuesTranscript.playhead)
        editor.onClose = {}
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lab.present(editor, animated: false) { c.resume() }
        }
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, editor.stage.core.displayedVideoFrame == nil { await settle(0.05) }
        await settle(0.8)
        return editor
    }

    @available(iOS 26, *)
    private static func close(_ editor: EditorViewController) async {
        editor.playback.teardown()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            editor.dismiss(animated: false) { c.resume() }
        }
    }

    private static func poster(size: CGSize) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor(red: 0.18, green: 0.2, blue: 0.26, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor(red: 0.9, green: 0.9, blue: 0.95, alpha: 1).setFill()
            ctx.fill(CGRect(x: 60, y: 60, width: size.width - 120, height: size.height - 120))
        }.cgImage
    }

    // MARK: - 1. Screens (VoiceOver + Dynamic Type)

    @available(iOS 26, *)
    static func screens(_ editor: EditorViewController) -> [Screen] {
        var list: [Screen] = [
            Screen(name: "editor", open: { editor in
                return nil
            }, close: { _ in }),
        ]
        for tab in InspectorTab.allCases {
            list.append(Screen(name: "inspector-\(tab.rawValue.lowercased())", open: { editor in
                editor.selection.inspectorTab = tab
                editor.openPanel(editor.selection.inspectorTab, animated: false)
                await settle(0.5)
                return nil
            }, close: { editor in
                editor.closePanel(animated: false)
                await settle(0.2)
            }))
            // The same pane scrolled to its end: every control is measured
            // fully on screen at least once.
            list.append(Screen(name: "inspector-\(tab.rawValue.lowercased())-end", open: { editor in
                editor.selection.inspectorTab = tab
                editor.openPanel(editor.selection.inspectorTab, animated: false)
                await settle(0.5)
                scrollInspector(editor, toEnd: true)
                await settle(0.3)
                return nil
            }, close: { editor in
                scrollInspector(editor, toEnd: false)
                editor.closePanel(animated: false)
                await settle(0.2)
            }))
        }
        list += [
            Screen(name: "timeline-lane-open", open: { editor in
                editor.timeline.canvas.setOpenLane(.annotate, animated: false)
                await settle(0.4)
                return nil
            }, close: { editor in editor.timeline.canvas.setOpenLane(nil, animated: false) }),
            Screen(name: "zoom-selected", open: { editor in
                editor.selection.selectedZoomID = editor.project.zoomRegions.first?.id
                editor.playback.scrub(to: 3.5, for: editor.project, exact: true)
                await settle(0.6)
                return nil
            }, close: { editor in
                editor.selection.selectedZoomID = nil
                editor.playback.scrub(to: InspectorValuesTranscript.playhead, for: editor.project, exact: true)
                await settle(0.4)
            }),
            Screen(name: "timeline-menu", open: { editor in
                guard let rect = timelineRect(editor, .effect(zoom: editor.project.zoomRegions.first?.id, tilt: nil)) else { return nil }
                editor.timeline.performLongPress(at: CGPoint(x: rect.midX, y: rect.midY))
                await settle(0.8)
                return nil
            }, close: dismissPresented),
            Screen(name: "history", open: { editor in
                StudioHistory.present(in: editor)
                await settle(1.0)
                return nil
            }, close: { editor in
                HistoryPresentation.current(in: editor)?.dismiss()
                await settle(0.6)
                await dismissPresented(editor)
            }),
            Screen(name: "merge-review", open: { editor in
                guard let session = mergeSession(editor.project) else { return nil }
                _ = StudioHistory.reviewMerge(from: editor, session: session, onApply: { _ in })
                await settle(1.0)
                return nil
            }, close: dismissPresented),
            Screen(name: "voice-over", open: { editor in
                _ = StudioVoiceOver.present(from: editor, project: editor.project, undoManager: editor.undoManager)
                await settle(0.9)
                return nil
            }, close: dismissPresented),
            Screen(name: "transcription", open: { editor in
                _ = StudioTranscription.present(from: editor, project: editor.project, undoManager: editor.undoManager)
                await settle(0.9)
                return nil
            }, close: dismissPresented),
            Screen(name: "auto-zoom", open: { editor in
                _ = StudioAutoZoom.present(from: editor, project: editor.project, undoManager: editor.undoManager)
                await settle(0.9)
                return nil
            }, close: dismissPresented),
            Screen(name: "background-removal", open: { editor in
                _ = StudioBackgroundRemoval.present(from: editor, project: editor.project, undoManager: editor.undoManager)
                await settle(0.9)
                return nil
            }, close: dismissPresented),
            Screen(name: "confirm-dialog", open: { editor in
                CCAlert.confirm(title: "Delete this zoom?", message: "You can undo this.", confirmTitle: "Delete",
                                destructive: true, from: editor)
                await settle(0.8)
                return nil
            }, close: dismissPresented),
            Screen(name: "color-picker", open: { editor in
                CCColorPicker.present(from: editor, source: editor.header, title: "Background", color: .systemBlue)
                await settle(0.9)
                return nil
            }, close: dismissPresented),
            Screen(name: "sync-badge", open: { editor in
                let badge = StudioSyncBadge()
                badge.show(.pending, animated: false)
                editor.header.setLeadingAccessory(badge)
                await settle(0.4)
                return nil
            }, close: { editor in editor.header.setLeadingAccessory(nil) }),
        ]
        return list + extraScreens
    }

    /// Scrolls the inspector's pane to its end (or back to the top).
    static func scrollInspector(_ editor: EditorViewController, toEnd: Bool) {
        guard let scroll = firstView(UIScrollView.self, in: editor.inspector.view) else { return }
        scroll.layoutIfNeeded()
        let maxY = max(-scroll.adjustedContentInset.top,
                       scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        scroll.setContentOffset(CGPoint(x: 0, y: toEnd ? maxY : -scroll.adjustedContentInset.top), animated: false)
    }

    @available(iOS 26, *)
    static func dismissPresented(_ editor: EditorViewController) async {
        guard let presented = editor.presentedViewController else { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            presented.dismiss(animated: false) { c.resume() }
        }
        await settle(0.4)
    }

    /// A delete-vs-modify conflict on the fixture's text annotation.
    private static func mergeSession(_ project: Project) -> ProjectMergeSession? {
        guard let data = try? JSONEncoder().encode(project), let base = try? JSONValue.parse(data: data),
              case .object(var mineObj) = base, case .object(var theirsObj) = base,
              case .array(let annotations)? = mineObj["annotations"], !annotations.isEmpty else { return nil }
        mineObj["annotations"] = .array(Array(annotations.dropFirst()))
        var changed = annotations
        if case .object(var first) = changed[0] {
            first["text"] = .string("Hello from the Mac")
            changed[0] = .object(first)
        }
        theirsObj["annotations"] = .array(changed)
        return ProjectMergeSession(base: base, mine: .object(mineObj), theirs: .object(theirsObj), mineWins: true)
    }

    @available(iOS 26, *)
    private static func screensAudit(_ editor: EditorViewController, only: Set<String>? = nil) async {
        guard let window = editor.view.window else { check("window", false, "the editor is not in a window"); return }
        for screen in screens(editor) where only?.contains(screen.name) ?? true {
            let root = await screen.open(editor)
            await settle(0.3)
            audit(screen.name, window: window, root: root ?? window, size: "default")
            let baseFonts = CCAccessibilityAudit.fontSizes(in: window)
            window.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
            await settle(0.7)
            editor.view.layoutIfNeeded()
            audit(screen.name, window: window, root: root ?? window, size: "xxxl", baseFonts: baseFonts)
            if let image = LabCapture.view(window) {
                try? LabCapture.png(image).write(to: out.appendingPathComponent("xxxl/\(screen.name).png"))
            }
            window.traitOverrides.preferredContentSizeCategory = .large
            await settle(0.4)
            await screen.close(editor)
            await settle(0.2)
        }
    }

    /// One screen at one text size: VoiceOver's elements and the text.
    private static func audit(_ name: String, window: UIWindow, root: UIView, size: String,
                              baseFonts: [ObjectIdentifier: CGFloat] = [:]) {
        _ = root
        let report = CCAccessibilityAudit.screen(window, baseFonts: size == "xxxl" ? baseFonts : nil)
        lines.append("== \(name) [\(size)]")
        lines += report.lines
        check("\(name)-\(size == "xxxl" ? "xxxl" : "voiceover")", report.problems.isEmpty, report.summary)
    }

    // MARK: - 2. Actions = the touch path

    private static func encoded(_ project: Project) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(project)) ?? Data()
    }

    /// `after` with every UUID that `before` does not hold replaced by its
    /// order of appearance — a duplicate or a split mints fresh ids, which
    /// can never be equal between two runs.
    private static func canonical(_ after: Data, from before: Data) -> Data {
        guard var text = String(data: after, encoding: .utf8), let old = String(data: before, encoding: .utf8) else { return after }
        let pattern = try! NSRegularExpression(pattern: "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}")
        var fresh: [String: String] = [:]
        for m in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let id = String(text[Range(m.range, in: text)!])
            if !old.contains(id), fresh[id] == nil { fresh[id] = "NEW-\(fresh.count)" }
        }
        for (id, name) in fresh { text = text.replacingOccurrences(of: id, with: name) }
        return Data(text.utf8)
    }

    /// The two documents hold the same model: same structure and strings,
    /// numbers equal to 1e-9 (the probe's own screen ↔ canvas round trip of
    /// a press point moves the last binary digits of a dragged value).
    private static func sameModel(_ a: Data, _ b: Data) -> Bool {
        guard let x = try? JSONSerialization.jsonObject(with: a), let y = try? JSONSerialization.jsonObject(with: b) else { return a == b }
        func eq(_ l: Any, _ r: Any) -> Bool {
            switch (l, r) {
            case let (l as [String: Any], r as [String: Any]):
                return l.keys.sorted() == r.keys.sorted() && l.allSatisfy { eq($0.value, r[$0.key]!) }
            case let (l as [Any], r as [Any]):
                return l.count == r.count && zip(l, r).allSatisfy { eq($0, $1) }
            case let (l as NSNumber, r as NSNumber):
                return abs(l.doubleValue - r.doubleValue) <= 1e-9
            case let (l as String, r as String):
                return l == r
            default:
                return (l is NSNull) && (r is NSNull)
            }
        }
        return eq(x, y)
    }

    /// Top-level keys whose JSON differs (the transcript's change summary).
    private static func changedKeys(_ a: Data, _ b: Data) -> [String] {
        guard let x = try? JSONSerialization.jsonObject(with: a) as? [String: Any],
              let y = try? JSONSerialization.jsonObject(with: b) as? [String: Any] else { return ["?"] }
        return Set(x.keys).union(y.keys).filter { key in
            let l = x[key].flatMap { try? JSONSerialization.data(withJSONObject: [$0], options: .sortedKeys) }
            let r = y[key].flatMap { try? JSONSerialization.data(withJSONObject: [$0], options: .sortedKeys) }
            return l != r
        }.sorted()
    }

    /// Puts the project back to `data` (edits the touch path itself cannot undo).
    private static func restore(_ editor: EditorViewController, _ data: Data) {
        guard let saved = try? JSONDecoder().decode(Project.self, from: data) else { return }
        saved.videoURL = editor.project.videoURL
        saved.cameraVideoURL = editor.project.cameraVideoURL
        editor.project.adoptState(of: saved)
        editor.renderStage()
    }

    @available(iOS 26, *)
    private static func clearSelection(_ editor: EditorViewController) {
        let s = editor.selection
        s.selectedZoomID = nil; s.selectedTiltID = nil; s.selectedHighlightID = nil
        s.selectedAnnotationID = nil; s.selectedBlurID = nil; s.selectedDepthFocusID = nil
        s.introSelected = false; s.curtainSelected = false
        editor.timeline.selectedClipID = nil
        editor.timeline.selectedVoiceOverID = nil
    }

    /// Runs `a11y`, then (after undoing it) `touch`, from the same project
    /// and selection; both must change the project identically, each by ONE
    /// undo step that restores the opening bytes.
    @available(iOS 26, *)
    private static func compare(_ label: String, _ editor: EditorViewController,
                                expectsChange: Bool = true,
                                prepare: () async -> Void = {},
                                a11y: () async -> Bool, touch: () async -> Void) async {
        guard let undo = editor.undoManager else { return }
        clearSelection(editor)
        await prepare()
        await settle(0.25)
        undo.removeAllActions()
        let before = encoded(editor.project)
        let ok = await a11y()
        await settle(0.3)
        let afterA = encoded(editor.project)
        var stepsA = 0
        while undo.canUndo, stepsA < 5 { undo.undo(); stepsA += 1; await settle(0.05) }
        let restoredA = encoded(editor.project) == before
        if !restoredA { restore(editor, before) }
        clearSelection(editor)
        await prepare()
        await settle(0.25)
        undo.removeAllActions()
        await touch()
        await settle(0.3)
        let afterT = encoded(editor.project)
        let same = sameModel(canonical(afterA, from: before), canonical(afterT, from: before))
        var stepsT = 0
        while undo.canUndo, stepsT < 5 { undo.undo(); stepsT += 1; await settle(0.05) }
        let restoredT = encoded(editor.project) == before
        if !restoredT { restore(editor, before) }
        let keys = changedKeys(before, afterA)
        let changedA = afterA != before
        lines.append("   action \(label): ok=\(ok) changed=\(keys.joined(separator: ",")) undo=\(stepsA) touchUndo=\(stepsT) same=\(same)")
        if !same, let key = (keys + changedKeys(before, afterT)).first {
            func value(_ d: Data) -> String {
                guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let v = o[key],
                      let j = try? JSONSerialization.data(withJSONObject: [v], options: .sortedKeys) else { return "-" }
                return String((String(data: j, encoding: .utf8) ?? "").prefix(600))
            }
            lines.append("     a11y  \(key)=\(value(afterA))")
            lines.append("     touch \(key)=\(value(afterT))")
        }
        var problems: [String] = []
        if !ok { problems.append("the action reported failure") }
        if expectsChange {
            if !changedA { problems.append("no project change") }
            // ONE undo step on both paths (since the undo-integrity fix the
            // shared edits register one for every lane, FOCUS drags included).
            if stepsA != 1 { problems.append("\(stepsA) undo steps (want 1)") }
            if stepsT == 0 { problems.append("the touch path registers no undo step") }
        } else if changedA {
            problems.append("changed the project (\(keys.joined(separator: ",")))")
        }
        if !same {
            problems.append("differs from the touch path (a11y: \(keys.joined(separator: ",")); touch: \(changedKeys(before, afterT).joined(separator: ",")))")
        }
        if expectsChange, stepsT > 1 { problems.append("touch path took \(stepsT) undo steps") }
        if restoredA != restoredT {
            problems.append("undo restores the opening project \(restoredA ? "" : "not ")after the action but \(restoredT ? "" : "not ")after the touch")
        } else if stepsA > 0, !restoredA {
            problems.append("undo does not restore the opening bytes on either path")
        }
        check("action \(label)", problems.isEmpty,
              problems.isEmpty ? (expectsChange ? "\(keys.joined(separator: ",")) changed exactly as by touch; \(stepsA) undo step\(stepsA == 1 ? "" : "s") (touch: \(stepsT))" : "selects, as a tap does; no edit")
                               : problems.joined(separator: "; "))
        clearSelection(editor)
        await settle(0.15)
    }

    @available(iOS 26, *)
    private static func timelineRect(_ editor: EditorViewController, _ target: StudioTimelineAccessibilityTarget) -> CGRect? {
        editor.timeline.canvas.accessibilityRect(for: target)
    }

    /// The element VoiceOver reaches for `target` (found by walking the
    /// canvas's elements, as VoiceOver does).
    @available(iOS 26, *)
    private static func timelineItem(_ editor: EditorViewController, _ target: StudioTimelineAccessibilityTarget) -> StudioTimelineAccessibilityItem? {
        (editor.timeline.canvas.accessibilityElements as? [StudioTimelineAccessibilityItem])?.first { $0.target == target }
    }

    /// Fires a custom action the way VoiceOver does: through its handler.
    private static func fire(_ element: NSObject?, _ name: String) -> Bool {
        guard let action = element?.accessibilityCustomActions?.first(where: { $0.name == name }) else { return false }
        return action.actionHandler?(action) ?? false
    }

    @available(iOS 26, *)
    private static func timelineActions(_ editor: EditorViewController) async {
        log("A11Y timeline actions vs touch")
        let tl = editor.timeline
        let canvas = tl.canvas
        let project = editor.project
        guard let zoom = project.zoomRegions.first?.id, let highlight = project.highlightRegions.first?.id,
              let rect = project.annotations.first(where: { $0.type == .rectangle })?.id else {
            check("timeline-fixture", false, "fixture lacks zoom/highlight/rectangle"); return
        }
        let effect = StudioTimelineAccessibilityTarget.effect(zoom: zoom, tilt: nil)
        // The touch path, derived here from what is drawn (not from the
        // element's code): press points from the element's frame, the step
        // from the documented 0.5 s at the canvas's current scale, dragged in
        // the documented four samples (equal inputs must give equal bytes).
        func frame(_ t: StudioTimelineAccessibilityTarget) -> CGRect {
            guard let item = timelineItem(editor, t) else { return .zero }
            let screen = item.accessibilityFrame
            return canvas.convert(canvas.window!.convert(screen, from: canvas.window!.screen.coordinateSpace), from: nil)
        }
        func step() -> CGFloat {
            max(TimelineCanvasMetrics.dragThreshold + 1,
                canvas.bounds.width * CGFloat(StudioTimelineCanvasView.accessibilityStep / max(canvas.snapshot.outputDuration, 0.001)))
        }
        func touchDrag(_ from: CGPoint, _ dx: CGFloat) async {
            tl.performDragBegan(at: from, current: from)
            for i in 1...4 { tl.performDragMoved(to: CGPoint(x: from.x + dx * CGFloat(i) / 4, y: from.y)) }
            tl.performDragEnded(at: CGPoint(x: from.x + dx, y: from.y))
        }
        func center(_ t: StudioTimelineAccessibilityTarget) -> CGPoint { let f = frame(t); return CGPoint(x: f.midX, y: f.midY) }
        func leftEdge(_ t: StudioTimelineAccessibilityTarget) -> CGPoint { let f = frame(t); return CGPoint(x: f.minX + TimelineCanvasMetrics.handleWidth / 2, y: f.midY) }
        func rightEdge(_ t: StudioTimelineAccessibilityTarget) -> CGPoint { let f = frame(t); return CGPoint(x: f.maxX - TimelineCanvasMetrics.handleWidth / 2, y: f.midY) }
        // The touch path's keys are the EDITOR's tool bar (its context keys
        // for the selection — the timeline's own toolbar is not in the editor).
        func key(_ label: String) {
            let names = ["Delete Selected": "Delete", "Split at Playhead": "Split"]
            guard let k = editor.toolBar.probeKey(names[label] ?? label) else {
                log("A11Y note: no tool bar key \(names[label] ?? label) (keys: \(editor.toolBar.probeTitles))"); return
            }
            k.sendActions(for: .touchUpInside)
        }
        let A = StudioTimelineCanvasView.AccessibilityAction.self
        func open(_ lane: TimelineOverlayLane) async { canvas.setOpenLane(lane, animated: false); await settle(0.2) }

        // Activation = a tap (select only).
        await compare("timeline zoom: activate", editor, expectsChange: false, prepare: { await open(.effects) },
                      a11y: { timelineItem(editor, effect)?.accessibilityActivate() ?? false },
                      touch: { tl.performTap(at: center(effect)) })
        let activated = editor.selection.selectedZoomID
        _ = timelineItem(editor, effect)?.accessibilityActivate()
        await settle(0.2)
        check("timeline zoom: activate selects", editor.selection.selectedZoomID == zoom && (timelineItem(editor, effect)?.accessibilityTraits.contains(.selected) ?? false),
              "selection \(editor.selection.selectedZoomID == zoom ? "= the zoom" : "missing"); trait selected; before: \(activated == nil ? "none" : "?")")
        clearSelection(editor)

        for (name, point, dx) in [
            (A.moveLater, { center(effect) }, { step() }),
            (A.moveEarlier, { center(effect) }, { -step() }),
            (A.endLater, { rightEdge(effect) }, { step() }),
            (A.startLater, { leftEdge(effect) }, { step() }),
        ] as [(String, () -> CGPoint, () -> CGFloat)] {
            await compare("timeline zoom: \(name)", editor, prepare: { await open(.effects) },
                          a11y: { fire(timelineItem(editor, effect), name) },
                          touch: { await touchDrag(point(), dx()) })
        }
        await compare("timeline zoom: \(A.duplicate)", editor, prepare: { await open(.effects) },
                      a11y: { fire(timelineItem(editor, effect), A.duplicate) },
                      touch: { tl.performTap(at: center(effect)); await settle(0.25); key("Duplicate") })
        await compare("timeline zoom: \(A.delete)", editor, prepare: { await open(.effects) },
                      a11y: { fire(timelineItem(editor, effect), A.delete) },
                      touch: { tl.performTap(at: center(effect)); await settle(0.25); key("Delete Selected") })
        let hl = StudioTimelineAccessibilityTarget.focus(highlight)
        await compare("timeline highlight: \(A.moveLater)", editor, prepare: { await open(.focus) },
                      a11y: { fire(timelineItem(editor, hl), A.moveLater) },
                      touch: { await touchDrag(center(hl), step()) })
        await compare("timeline highlight: \(A.endEarlier)", editor, prepare: { await open(.focus) },
                      a11y: { fire(timelineItem(editor, hl), A.endEarlier) },
                      touch: { await touchDrag(rightEdge(hl), -step()) })
        let ann = StudioTimelineAccessibilityTarget.annotate(rect)
        await compare("timeline rectangle: \(A.moveLater)", editor, prepare: { await open(.annotate) },
                      a11y: { fire(timelineItem(editor, ann), A.moveLater) },
                      touch: { await touchDrag(center(ann), step()) })
        await compare("timeline rectangle: \(A.startEarlier)", editor, prepare: { await open(.annotate) },
                      a11y: { fire(timelineItem(editor, ann), A.startEarlier) },
                      touch: { await touchDrag(leftEdge(ann), -step()) })
        await compare("timeline rectangle: \(A.delete)", editor, prepare: { await open(.annotate) },
                      a11y: { fire(timelineItem(editor, ann), A.delete) },
                      // A selected annotation's touch Delete is the stage pill's key.
                      touch: { tl.performTap(at: center(ann)); await settle(0.25); editor.deleteSelection() })
        if let clip = canvas.videoModel?.clips.first?.id {
            let video = StudioTimelineAccessibilityTarget.video(clip)
            await compare("timeline video: \(A.split)", editor,
                          a11y: { fire(timelineItem(editor, video), A.split) },
                          touch: { tl.performTap(at: center(video)); await settle(0.25); key("Split at Playhead") })
        }
        // Spoken results.
        CCAccessibility.probeAnnouncements = []
        await open(.effects)
        _ = fire(timelineItem(editor, effect), A.moveLater)
        await settle(0.3)
        let spoken = CCAccessibility.probeAnnouncements.last ?? ""
        check("timeline announces", spoken.contains("seconds") || spoken.hasPrefix("No room"), "after Move later VoiceOver hears “\(spoken)”")
        editor.undoManager?.undo()
        await settle(0.2)
        canvas.setOpenLane(nil, animated: false)
    }

    @available(iOS 26, *)
    private static func stageActions(_ editor: EditorViewController) async {
        log("A11Y stage actions vs touch")
        let canvas = editor.canvas
        editor.playback.scrub(to: InspectorValuesTranscript.playhead, for: editor.project, exact: true)
        await settle(0.4)
        editor.renderStage()
        await settle(0.2)
        guard let rect = editor.project.annotations.first(where: { $0.type == .rectangle })?.id,
              let highlight = editor.project.highlightRegions.first?.id else { return }
        func item(_ t: EditorStageAccessibilityTarget) -> EditorStageAccessibilityItem? {
            canvas.accessibilityItems.compactMap { $0 as? EditorStageAccessibilityItem }.first { $0.target == t }
        }
        func viewFrame(_ t: EditorStageAccessibilityTarget) -> CGRect {
            guard let e = item(t), let w = canvas.window else { return .zero }
            return canvas.convert(w.convert(e.accessibilityFrame, from: w.screen.coordinateSpace), from: nil)
        }
        func center(_ t: EditorStageAccessibilityTarget) -> CGPoint { let f = viewFrame(t); return CGPoint(x: f.midX, y: f.midY) }
        /// The nudge, derived here: 4% of the recording frame as drawn.
        func nudge() -> CGSize {
            guard let ctx = canvas.context, let stage = canvas.stage else { return .zero }
            let video = stage.viewRect(fromCanvas: PreviewHitMath.viewRect(ofContentRect: ctx.videoRect, ctx))
            return CGSize(width: video.width * 0.04, height: video.height * 0.04)
        }
        func tap(_ p: CGPoint) { canvas.touchDown(atView: p, tapCount: 1); canvas.touchUp(atView: p) }
        func drag(_ from: CGPoint, _ dx: CGFloat, _ dy: CGFloat) {
            canvas.touchDown(atView: from, tapCount: 1)
            canvas.touchMoved(toView: (1...4).map { CGPoint(x: from.x + dx * CGFloat($0) / 4, y: from.y + dy * CGFloat($0) / 4) })
            canvas.touchUp(atView: CGPoint(x: from.x + dx, y: from.y + dy))
        }
        let A = EditorCanvasView.AccessibilityAction.self
        let r = EditorStageAccessibilityTarget.annotation(rect)
        guard item(r) != nil else {
            check("stage-elements", false, "the rectangle annotation is not an element at \(InspectorValuesTranscript.playhead) s "
                  + "(elements: \(canvas.accessibilityItems.compactMap { ($0 as? EditorStageAccessibilityItem)?.accessibilityLabel }))")
            return
        }
        await compare("stage rectangle: activate", editor, expectsChange: false,
                      a11y: { item(r)?.accessibilityActivate() ?? false }, touch: { tap(center(r)) })
        await compare("stage rectangle: \(A.right)", editor,
                      a11y: { fire(item(r), A.right) }, touch: { tap(center(r)); drag(center(r), nudge().width, 0) })
        await compare("stage rectangle: \(A.down)", editor,
                      a11y: { fire(item(r), A.down) }, touch: { tap(center(r)); drag(center(r), 0, nudge().height) })
        await compare("stage rectangle: \(A.larger)", editor,
                      a11y: { fire(item(r), A.larger) },
                      touch: {
                          tap(center(r))
                          guard let ctx = canvas.context, let stage = canvas.stage,
                                let a = ctx.project.annotations.first(where: { $0.id == rect }) else { return }
                          let vr = ctx.videoRect
                          let corner = PreviewHitMath.viewRect(ofContentRect: CGRect(x: vr.minX + a.arrowEndX * vr.width, y: vr.minY + a.arrowEndY * vr.height, width: 0, height: 0), ctx).origin
                          let p = canvas.convert(stage.viewPoint(fromCanvas: corner), from: stage)
                          drag(p, nudge().width, nudge().height)
                      })
        let hl = EditorStageAccessibilityTarget.highlight(highlight)
        if item(hl) != nil {
            await compare("stage highlight: \(A.up)", editor,
                          a11y: { fire(item(hl), A.up) }, touch: { tap(center(hl)); drag(center(hl), 0, -nudge().height) })
        }
        if item(.camera) != nil {
            await compare("stage camera: \(A.left)", editor,
                          a11y: { fire(item(.camera), A.left) },
                          touch: { drag(center(.camera), -canvas.bounds.width * 0.25, 0) })
        } else {
            check("stage camera element", false, "the camera bubble is not an element")
        }
        // The zoom focal point, while its block is selected.
        let zoom = editor.project.zoomRegions.first?.id
        await compare("stage zoom focal: \(A.right)", editor,
                      prepare: {
                          editor.selection.selectedZoomID = zoom
                          editor.playback.scrub(to: 3.5, for: editor.project, exact: true)
                          await settle(0.4)
                          editor.renderStage()
                      },
                      a11y: { fire(item(.zoomFocal), A.right) },
                      touch: { drag(center(.zoomFocal), nudge().width, 0) })
        editor.playback.scrub(to: InspectorValuesTranscript.playhead, for: editor.project, exact: true)
        await settle(0.3)
    }

    @available(iOS 26, *)
    private static func transport(_ editor: EditorViewController) async {
        let scrubber = editor.transport.playhead
        let before = editor.playback.currentTime
        scrubber.accessibilityIncrement()
        await settle(0.3)
        let after = editor.playback.currentTime
        let value = scrubber.accessibilityValue ?? ""
        check("transport-scrub", scrubber.accessibilityTraits.contains(.adjustable) && abs((after - before) - 1) < 0.05
                && value.contains("second"),
              String(format: "increment %.2f → %.2f s; VoiceOver reads “%@”", before, after, value))
        scrubber.accessibilityDecrement()
        await settle(0.2)
        let play = editor.transport.playButton
        check("transport-play", play.accessibilityLabel == "Play" && play.accessibilityTraits.contains(.button)
                && play.accessibilityTraits.contains(.startsMediaSession),
              "“\(play.accessibilityLabel ?? "")” [\(CCAccessibilityAudit.names(play.accessibilityTraits))]")
    }

    // MARK: - 3. Reduce Motion — mid-flight

    /// Samples `layer` (and any ghost beside it) after `ms`: the opacity must
    /// sit strictly between its endpoints and the geometry must already be
    /// the final one (no travel, no scale).
    private struct MotionSample {
        var opacity: Float
        var ghostOpacity: Float?
        var moved: CGFloat
        var scaled: CGFloat
    }

    private static func sample(_ layer: CALayer, ghostIn host: CALayer? = nil) -> MotionSample {
        let shown = layer.presentation() ?? layer
        let travel = hypot(shown.position.x - layer.position.x, shown.position.y - layer.position.y)
        let dx = (shown.value(forKeyPath: "transform.translation.x") as? CGFloat) ?? 0
        let dy = (shown.value(forKeyPath: "transform.translation.y") as? CGFloat) ?? 0
        let scale = (shown.value(forKeyPath: "transform.scale") as? CGFloat) ?? 1
        let size = abs(shown.bounds.width - layer.bounds.width) + abs(shown.bounds.height - layer.bounds.height)
        var ghost: Float?
        func findGhost(_ l: CALayer) {
            for sub in l.sublayers ?? [] {
                if sub.name == "ccmotion.reduce.ghost" { ghost = (sub.presentation() ?? sub).opacity; return }
                findGhost(sub)
            }
        }
        if let host { findGhost(host) }
        return MotionSample(opacity: shown.opacity, ghostOpacity: ghost, moved: travel + hypot(dx, dy) + size, scaled: abs(scale - 1))
    }

    private static func midFlight(_ name: String, _ s: MotionSample, target: Float = 1, needsGhost: Bool = false) {
        let fading = s.opacity > 0.02 && s.opacity < target - 0.02
        let ghostFading = s.ghostOpacity.map { $0 > 0.02 && $0 < 0.98 } ?? false
        let pass = (fading || ghostFading) && (!needsGhost || ghostFading) && s.moved < 0.5 && s.scaled < 0.002
        check("reduce-motion \(name)", pass,
              String(format: "mid-flight opacity %.2f%@, travel %.2f pt, scale Δ %.3f", s.opacity,
                     s.ghostOpacity.map { String(format: " (ghost %.2f)", $0) } ?? "", s.moved, s.scaled))
    }

    /// VoiceOver and the drill-down bar (phone): a pane tool swaps in its
    /// sub-options and VoiceOver lands on the level's first key — the back
    /// key, labelled "Back" with a hint, a 44 pt target; a sub-option opens
    /// its short panel and VoiceOver lands on the panel's title (a header);
    /// the tool bar and timeline stay reachable (nothing covered); another
    /// sub-option switches in place, announced again, `.selected` moving
    /// with it; ✓ is labelled "Done" with a hint; VoiceOver's escape closes
    /// and returns focus to the key; back returns to the tools, announced.
    @available(iOS 26, *)
    private static func panelVoiceOver(_ editor: EditorViewController) async {
        guard let camera = editor.toolBar.key(for: .pane(.camera)) else {
            log("A11Y note: no pane tools here (an inspector column) — the panel's VoiceOver is checked on iPhone")
            return
        }
        log("A11Y tool panel")
        clearSelection(editor)
        await settle(0.3)
        let inspector = editor.inspector
        let bar = editor.toolBar
        camera.sendActions(for: .touchUpInside)
        await settle(0.6)
        #if DEBUG
        let announcedLevel = bar.probeLastAnnounced
        #else
        let announcedLevel: UIView? = nil
        #endif
        let back = bar.key(for: .back)
        check("bar-level-announced", back != nil && announcedLevel === back && back?.accessibilityLabel == "Back"
                && !(back?.accessibilityHint ?? "").isEmpty && back?.accessibilityTraits.contains(.button) == true
                && back.map { k in [CGPoint(x: -21.5, y: -21.5), CGPoint(x: 21.5, y: 21.5)].allSatisfy { k.point(inside: CGPoint(x: k.bounds.midX + $0.x, y: k.bounds.midY + $0.y), with: nil) } } == true,
              "Camera → its sub-options, VoiceOver on \"\(announcedLevel?.accessibilityLabel ?? "nil")\" (hint \"\(back?.accessibilityHint ?? "")\")")
        let options = bar.options
        guard options.count >= 2, let firstKey = bar.key(for: .option(options[0].id)),
              let secondKey = bar.key(for: .option(options[1].id)) else {
            check("panel-announced", false, "Camera has \(options.count) sub-options"); return
        }
        if !editor.isPanelOpen { firstKey.sendActions(for: .touchUpInside) }
        await settle(0.6)
        #if DEBUG
        let announcedOpen = editor.probeLastAnnounced
        #else
        let announcedOpen: UIView? = nil
        #endif
        check("panel-announced", editor.isPanelOpen && announcedOpen === inspector.panelTitle
                && inspector.panelTitle.accessibilityTraits.contains(.header) && inspector.panelTitle.text == options[0].title,
              "\(options[0].title) → VoiceOver on the panel's title \"\(inspector.panelTitle.text ?? "")\" (header)")
        check("panel-covers-nothing", !bar.accessibilityElementsHidden && !editor.timelineContainer.accessibilityElementsHidden
                && firstKey.accessibilityTraits.contains(.selected) && !secondKey.accessibilityTraits.contains(.selected),
              "tool bar + timeline reachable while open; \(options[0].title) key .selected")
        let done = inspector.closeButton
        check("panel-done-key", done.isAccessibilityElement && done.accessibilityLabel == "Done"
                && (done.accessibilityHint ?? "").contains("Closes")
                && [CGPoint(x: -21.5, y: -21.5), CGPoint(x: 21.5, y: 21.5)].allSatisfy { done.point(inside: CGPoint(x: done.bounds.midX + $0.x, y: done.bounds.midY + $0.y), with: nil) },
              "✓: \"\(done.accessibilityLabel ?? "nil")\", hint \"\(done.accessibilityHint ?? "")\", \(Int(done.bounds.width))×\(Int(done.bounds.height)) pt drawn, ≥ 44×44 pt hit target")
        secondKey.sendActions(for: .touchUpInside)
        await settle(0.6)
        #if DEBUG
        let announcedSwitch = editor.probeLastAnnounced
        #else
        let announcedSwitch: UIView? = nil
        #endif
        check("panel-switch-announced", editor.isPanelOpen && announcedSwitch === inspector.panelTitle
                && inspector.panelTitle.text == options[1].title && secondKey.accessibilityTraits.contains(.selected)
                && !firstKey.accessibilityTraits.contains(.selected),
              "\(options[1].title) → switches in place, VoiceOver on \"\(inspector.panelTitle.text ?? "")\"")
        let escaped = inspector.accessibilityPerformEscape()
        await settle(0.6)
        #if DEBUG
        let announcedClose = editor.probeLastAnnounced
        #else
        let announcedClose: UIView? = nil
        #endif
        check("panel-escape-closes", escaped && !editor.isPanelOpen && inspector.view.isHidden && announcedClose === secondKey,
              "escape → closed, VoiceOver back on the \(options[1].title) key")
        bar.key(for: .back)?.sendActions(for: .touchUpInside)
        await settle(0.6)
        #if DEBUG
        let announcedRoot = bar.probeLastAnnounced
        #else
        let announcedRoot: UIView? = nil
        #endif
        check("bar-back-announced", bar.mode == .tools && announcedRoot != nil && announcedRoot === bar.key(for: .pane(.background)),
              "Back → the tools, VoiceOver on \"\(announcedRoot?.accessibilityLabel ?? "nil")\"")
    }

    @available(iOS 26, *)
    private static func reduceMotion(_ editor: EditorViewController) async {
        log("A11Y reduce motion")
        CCAccessibility.forcedReduceMotion = true
        defer { CCAccessibility.forcedReduceMotion = nil }
        guard let window = editor.view.window else { return }
        await settle(0.3)

        // a. Inspector rail chip (CCIconRail) — was a spring glide.
        let rail = editor.inspector.rail
        editor.selection.inspectorTab = .background
        await settle(0.5)
        editor.selection.inspectorTab = .motion
        await settle(0.06)
        midFlight("rail-chip", sample(rail.probeChipLayer, ghostIn: rail.layer))

        // b. The pane switch — was a rise + fade.
        await settle(0.5)
        editor.selection.inspectorTab = .camera
        await settle(0.16)
        if let pane = editor.inspector.visiblePane { midFlight("pane-switch", sample(pane.layer)) }
        await settle(0.5)

        // c. A slider value pushed (animated) — the thumb used to glide.
        if let slider = firstView(CCSlider.self, in: editor.inspector.view) {
            let thumb = slider.probeThumbLayer
            let v = slider.value
            slider.setValue(slider.range.lowerBound + (slider.range.upperBound - slider.range.lowerBound) * (v > (slider.range.lowerBound + slider.range.upperBound) / 2 ? 0.1 : 0.9), animated: true)
            slider.layoutIfNeeded()
            await settle(0.06)
            midFlight("slider-thumb", sample(thumb, ghostIn: slider.layer))
            await settle(0.4)
            slider.setValue(v, animated: false)
        } else {
            check("reduce-motion slider-thumb", false, "no slider in the camera pane")
        }

        // d. Timeline lane opening — was the growth bounce.
        let canvas = editor.timeline.canvas
        canvas.setOpenLane(nil, animated: false)
        await settle(0.3)
        let host = canvas.superview?.superview ?? canvas
        canvas.setOpenLane(.focus, animated: true)
        let landed = canvas.laneLayout.openness(.focus)
        await settle(0.07)
        var ghost: Float?
        for v in host.subviews + (host.superview?.subviews ?? []) where v.layer.name == "ccmotion.reduce.ghost" {
            ghost = (v.layer.presentation() ?? v.layer).opacity
        }
        check("reduce-motion lane-open", landed > 0.999 && (ghost.map { $0 > 0.02 && $0 < 0.98 } ?? false),
              String(format: "lane openness %.2f at once (no growth); cross-fade ghost opacity %@", landed, ghost.map { String(format: "%.2f", $0) } ?? "none"))
        await settle(0.4)

        // e. Timeline selection outline between two blocks — was a glide.
        if let a = editor.project.zoomRegions.first?.id, let b = editor.project.tiltRegions.first?.id {
            canvas.setOpenLane(.effects, animated: false)
            editor.selection.selectedZoomID = a
            await settle(0.4)
            editor.selection.selectedZoomID = nil
            editor.timeline.selectedTiltID = b
            await settle(0.06)
            let ring = canvas.selectionRing
            let s = sample(ring)
            let glide = canvas.probeRing.gliding
            log("A11Y note: outline keys \(ring.animationKeys() ?? []) selection zoom=\(editor.selection.selectedZoomID != nil) tilt=\(editor.selection.selectedTiltID != nil)")
            midFlight("selection-outline", s)
            check("reduce-motion selection-outline-lands", !glide, "outline at the new block at once (gliding: \(glide))")
            await settle(0.4)
            clearSelection(editor)
        }

        // f. A dialog entrance — was a scale-in.
        let alert = CCAlert(title: "Probe", message: "Reduce Motion")
        alert.addButton("OK", role: .cancel)
        alert.present(from: editor)
        var card: UIView?
        for _ in 0..<100 {
            if let c = alert.probeCard, c.layer.animation(forKey: "ccmotion.reduce.dissolve") != nil || c.layer.animation(forKey: "ccmotion.alpha") != nil { card = c; break }
            await settle(0.004)
        }
        if let card {
            await settle(0.05)
            midFlight("dialog-entrance", sample(card.layer))
        } else {
            check("reduce-motion dialog-entrance", false, "the card never started its entrance")
        }
        alert.dismiss()
        await settle(0.5)
        await dismissPresented(editor)

        // g. History's entrance — a side panel (iPad) / sheet (iPhone) slide.
        let panel = StudioHistory.present(in: editor)
        await settle(0.05)
        if let presentation = HistoryPresentation.current(in: editor), let c = presentation.probeMovingView {
            midFlight("history-entrance", sample(c.layer))
        } else {
            check("reduce-motion history-entrance", false, "no History card")
        }
        _ = panel
        await settle(0.5)
        HistoryPresentation.current(in: editor)?.dismiss()
        await settle(0.6)
        await dismissPresented(editor)

        // h. A pane's panel opened from its tool — was the growth bounce.
        if editor.toolBar.key(for: .pane(.audio)) != nil {
            editor.enterPane(.audio, animated: false)
            editor.closePanel(animated: false)
            await settle(0.3)
            let key = editor.toolBar.options.first.flatMap { editor.toolBar.key(for: .option($0.id)) } ?? UIControl()
            let host = editor.view.superview?.layer
            let before = editor.inspector.view.convert(editor.inspector.view.bounds, to: nil)
            key.sendActions(for: .touchUpInside)
            await settle(0.06)
            let s = sample(editor.view.layer, ghostIn: host)
            let landed = editor.isPanelOpen && editor.inspector.view.convert(editor.inspector.view.bounds, to: nil) != before
            midFlight("panel-open", s, needsGhost: true)
            check("reduce-motion panel-lands", landed, "the panel is at its open place at once (no growth)")
            await settle(0.5)
            editor.closePanel(animated: false)
            editor.toolBar.key(for: .back)?.sendActions(for: .touchUpInside)
            await settle(0.4)
        } else {
            log("A11Y note: no pane tools here (an inspector column) — the panel cross-fade is checked on iPhone")
        }
        // i. The tool bar's tools ⇄ context keys — a rise + fade.
        editor.selection.selectedHighlightID = editor.project.highlightRegions.first?.id
        await settle(0.02)
        var stack: UIView?
        for _ in 0..<40 {
            if editor.toolBar.mode != .tools { stack = editor.toolBar.probeVisibleStack; break }
            await settle(0.004)
        }
        if let stack {
            await settle(0.06)
            midFlight("toolbar-context", sample(stack.layer))
        } else {
            check("reduce-motion toolbar-context", false, "the context keys never came")
        }
        await settle(0.4)
        clearSelection(editor)
        await settle(0.3)
        _ = window
    }

    // MARK: - 4. Keyboard, focus, pointer

    @available(iOS 26, *)
    private static func keyboard(_ editor: EditorViewController) async {
        log("A11Y keyboard")
        clearSelection(editor)
        _ = editor.becomeFirstResponder()
        await settle(0.2)
        func commands() -> [UIKeyCommand] {
            var out: [UIKeyCommand] = []
            var r: UIResponder? = editor.view.window?.firstResponderForProbe ?? editor
            while let responder = r { out += responder.keyCommands ?? []; r = responder.next }
            return out
        }
        func fire(_ input: String, _ mods: UIKeyModifierFlags = []) async -> Bool {
            guard let cmd = commands().first(where: { $0.input == input && $0.modifierFlags == mods }), let action = cmd.action else { return false }
            let sent = UIApplication.shared.sendAction(action, to: nil, from: cmd, for: nil)
            await settle(0.2)
            return sent
        }
        // Space: play / pause.
        let wasPlaying = editor.playback.isPlaying
        let space = await fire(" ")
        let toggled = editor.playback.isPlaying != wasPlaying
        if editor.playback.isPlaying { editor.playback.togglePlayback(for: editor.project) }
        await settle(0.2)
        check("key space", space && toggled, "play/pause \(toggled ? "toggled" : "did nothing")")
        // ←/→: one frame.
        let t0 = editor.playback.currentTime
        let right = await fire(UIKeyCommand.inputRightArrow)
        let t1 = editor.playback.currentTime
        let left = await fire(UIKeyCommand.inputLeftArrow)
        let t2 = editor.playback.currentTime
        check("key arrows", right && left && t1 > t0 && t1 - t0 < 0.1 && abs(t2 - t0) < 1e-6,
              String(format: "→ %.3f → %.3f s, ← back to %.3f", t0, t1, t2))
        // ⌫ deletes the selection; ⌘Z brings it back.
        editor.undoManager?.removeAllActions()
        _ = editor.becomeFirstResponder()
        await settle(0.2)
        let before = encoded(editor.project)
        let rectangle = editor.project.annotations.first(where: { $0.type == .rectangle })?.id
        editor.selection.selectedAnnotationID = rectangle
        await settle(0.2)
        let del = await fire(UIKeyCommand.inputDelete)
        let deleted = encoded(editor.project) != before
        let countBefore = editor.project.annotations.count
        let undo = await fire("z", .command)
        // The shared delete's undo puts the annotation back AT ITS INDEX
        // (stacking order) — the whole project byte-equal to before.
        let undone = editor.project.annotations.count == countBefore + 1
            && encoded(editor.project) == before
        // Redo needs an edit that registers its inverse: an inspector slider.
        editor.selection.inspectorTab = .background
        await settle(0.4)
        let slider = firstView(CCSlider.self, in: editor.inspector.view)
        let beforeSlider = encoded(editor.project)
        slider?.accessibilityIncrement()
        await settle(0.3)
        let edited = encoded(editor.project)
        _ = await fire("z", .command)
        let sliderUndone = encoded(editor.project) == beforeSlider
        let redo = await fire("z", [.command, .shift])
        let redone = edited != beforeSlider && encoded(editor.project) == edited && sliderUndone
        _ = await fire("z", .command)
        check("key delete-undo-redo", del && deleted && undo && undone && redo && redone,
              "⌫ \(deleted ? "deleted" : "kept") the selection, ⌘Z \(undone ? "restored it" : "did not restore"); a slider edit: ⌘Z \(sliderUndone ? "undid it" : "did not undo"), ⇧⌘Z \(redone ? "redid it" : "did not redo")")
        // Discoverability titles (the iPad ⌘ overlay lists them).
        let titled = commands().filter { !($0.discoverabilityTitle ?? $0.title).isEmpty }.count
        check("key titles", titled >= 6, "\(titled) commands carry a title for the ⌘ overlay")
        // ⌘E: the Export sheet (the header's Export key's twin).
        let exported = await fire("e", .command)
        await settle(0.6)
        let sheetShown = editor.presentedViewController is StudioExportSheetController
        check("key export", exported && sheetShown, "⌘E \(sheetShown ? "opened the Export sheet" : "did not open the Export sheet")")
        await dismissPresented(editor)

        // Tab focus through the inspector (UIFocus): every control focusable,
        // in one focus group per pane.
        var controls: [UIView] = []
        if let pane = editor.inspector.visiblePane {
            walk(pane) { v in if v is UIControl, v.isAccessibilityElement, !v.isHidden, v.alpha > 0.01, v.isUserInteractionEnabled, (v as? UIControl)?.isEnabled == true { controls.append(v) } }
        }
        // A control that hosts its own focusable field (CCField → UITextField) counts.
        func focusable(_ v: UIView) -> Bool { v.canBecomeFocused || v is UITextField || v.subviews.contains(where: focusable) }
        let unfocusable = controls.filter { !focusable($0) }
        let group = editor.inspector.visiblePane?.focusGroupIdentifier
        check("focus inspector", !controls.isEmpty && unfocusable.isEmpty && group != nil,
              "\(controls.count) controls focusable\(unfocusable.isEmpty ? "" : "; not: \(unfocusable.prefix(4).map { String(describing: type(of: $0)) })"), group \(group ?? "none")")
        if let system = UIFocusSystem.focusSystem(for: editor.view), let first = controls.first(where: \.canBecomeFocused) {
            system.requestFocusUpdate(to: first)
            system.updateFocusIfNeeded()
            await settle(0.2)
            // The simulator's focus engine stays idle until a hardware key is pressed
            // (no public way to send one): a request that lands nowhere is noted; one
            // that lands on the WRONG item fails.
            if let focused = system.focusedItem {
                check("focus moves", focused === first, "the focus system put focus on \(type(of: first)) (focused: \(type(of: focused)))")
            } else {
                log("A11Y note: focus engine idle (no hardware key pressed in the simulator) — focusability checked statically")
            }
        } else {
            log("A11Y note: no focus system on this device (iPhone without a keyboard) — focusability checked statically")
        }
        // Pointer hover on the kit's buttons.
        var buttons: [CCButton] = []
        walk(editor.view) { if let b = $0 as? CCButton { buttons.append(b) } }
        let bare = buttons.filter { !$0.interactions.contains { $0 is UIPointerInteraction } }
        check("pointer hover", !buttons.isEmpty && bare.isEmpty, "\(buttons.count) kit buttons carry a pointer effect\(bare.isEmpty ? "" : "; missing \(bare.count)")")
    }

    // MARK: - 5. Contrast, transparency, colour, weight

    @available(iOS 26, *)
    private static func settings(_ editor: EditorViewController) async {
        log("A11Y settings")
        guard let window = editor.view.window else { return }
        let traits = window.traitCollection
        func alpha(_ c: UIColor) -> CGFloat { c.ccComponents(window.traitCollection).a }
        let border0 = alpha(CCTheme.color.border), muted0 = alpha(CCTheme.color.mutedForeground)
        CCAccessibility.forcedIncreaseContrast = true
        await settle(0.3)
        let border1 = alpha(CCTheme.color.border), muted1 = alpha(CCTheme.color.mutedForeground)
        var hairlines: [CGFloat] = []
        walk(editor.view) { v in
            if let base = v.layer.sublayers?.first(where: { $0.name == "ccmat.base" }), v.bounds.width > 12, v.bounds.height > 12 {
                hairlines.append(base.borderWidth)
            }
        }
        CCAccessibility.forcedIncreaseContrast = nil
        await settle(0.3)
        check("increase-contrast", border1 > border0 * 2 && muted1 > muted0 && !hairlines.isEmpty && hairlines.allSatisfy { $0 >= 1 },
              String(format: "border α %.2f → %.2f, secondary ink α %.2f → %.2f, %d dressed surfaces at a 1 pt hairline", border0, border1, muted0, muted1, hairlines.filter { $0 >= 1 }.count))

        let scrim0 = alpha(CCTheme.color.overlay)
        CCAccessibility.forcedReduceTransparency = true
        let scrim1 = alpha(CCTheme.color.overlay)
        CCAccessibility.forcedReduceTransparency = nil
        check("reduce-transparency", scrim1 >= 0.55 && scrim1 > scrim0, String(format: "scrim α %.2f → %.2f", scrim0, scrim1))

        // Differentiate Without Color: selected states carry a shape.
        CCAccessibility.forcedDifferentiateWithoutColor = true
        editor.selection.inspectorTab = .camera
        await settle(0.6)
        var marked: [String] = [], unmarked: [String] = []
        walk(editor.inspector.view) { v in
            if let chip = v as? CCChip, chip.isSelected, !chip.isHidden {
                (chip.probeShowsCheck ? (marked.append("chip")) : unmarked.append("chip \(chip.accessibilityLabel ?? "")"))
            }
            if let seg = v as? CCSegmented, !seg.isHidden {
                (seg.probeShowsCheck ? marked.append("segment") : unmarked.append("segment \(seg.accessibilityLabel ?? "")"))
            }
            if let toggle = v as? CCToggle, !toggle.isHidden {
                (toggle.probeShowsGlyph ? marked.append("switch") : unmarked.append("switch"))
            }
        }
        let badge = StudioSyncBadge()
        badge.show(.failed("Probe"), animated: false)
        let badgeGlyph = badge.probeShowsGlyph
        CCAccessibility.forcedDifferentiateWithoutColor = nil
        await settle(0.3)
        var cleared = true
        walk(editor.inspector.view) { v in if let chip = v as? CCChip, chip.probeShowsCheck { cleared = false } }
        check("differentiate-without-color", !marked.isEmpty && unmarked.isEmpty && badgeGlyph && cleared,
              "\(marked.count) selected/on states carry a shape (\(Set(marked).sorted().joined(separator: ", ")))"
                + (unmarked.isEmpty ? "" : "; colour only: \(unmarked.prefix(4))") + "; sync dot glyph \(badgeGlyph); off again \(cleared)")

        // Bold Text: the type ramp steps up a weight.
        func weight(_ f: UIFont) -> CGFloat {
            ((f.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any])?[.weight] as? CGFloat) ?? 0
        }
        let w0 = weight(CCFont.label)
        CCAccessibility.forcedBoldText = true
        let w1 = weight(CCFont.label), wb1 = weight(CCFont.body)
        CCAccessibility.forcedBoldText = nil
        check("bold-text", w1 > w0 + 0.1 && wb1 > weight(CCFont.body) + 0.1,
              String(format: "label weight %.2f → %.2f, body → %.2f", w0, w1, wb1))
        _ = traits
    }

    // MARK: - Helpers

    static func walk(_ view: UIView, _ visit: (UIView) -> Void) {
        visit(view)
        for sub in view.subviews { walk(sub, visit) }
    }

    static func firstView<T: UIView>(_ type: T.Type, in root: UIView) -> T? {
        var found: T?
        walk(root) { v in if found == nil, let t = v as? T, !t.isHidden, t.window != nil { found = t } }
        return found
    }

    private static func settle(_ s: TimeInterval) async { await LabTime.settle(s) }

    private static func log(_ line: String) {
        print(line)
        lines.append(line)
    }

    private static func check(_ name: String, _ pass: Bool, _ detail: String) {
        if !pass { failures += 1 }
        log("A11Y \(name) \(pass ? "PASS" : "FAIL") — \(detail)")
    }
}

extension UIWindow {
    /// The current first responder (probe only: walks the view tree).
    var firstResponderForProbe: UIResponder? {
        var found: UIResponder?
        func walk(_ v: UIView) {
            if found != nil { return }
            if v.isFirstResponder { found = v; return }
            v.subviews.forEach(walk)
        }
        walk(self)
        if found == nil, let root = rootViewController {
            var vc: UIViewController? = root
            while let c = vc { if c.isFirstResponder { return c }; vc = c.presentedViewController }
        }
        return found
    }
}
