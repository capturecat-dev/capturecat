import UIKit

/// `--inspector <outDir> [--inject snap]` (Studio 4d) — the iOS inspector in
/// the real editor, in the real window chain (CLAUDE.md §3, "wrong topology").
///
/// 1. **Values.** The shared inspector-values script (StudioHarness/
///    InspectorValuesTranscript): every control of all nine panes, driven
///    through the REAL controls — slider taps at the value's x through the
///    slider's own touch path, chip taps, toggle-row presses, select picks,
///    colour-well commits, typed-and-ended fields, pad presses, preset taps,
///    picked logos (the host picker returns the fixture's) — recorded with
///    the shared recorder and held to the frozen Mac transcript
///    (`InspectorValuesGoldens`). Every step that changes the project must
///    register exactly ONE undo step, and undo must restore the pre-step
///    project byte for byte, redo the post-step one; a step that changes
///    nothing registers none.
/// 2. **Structure**, per pane on a second editor (sections revealed): touch
///    targets (≥ 44 pt), VoiceOver labels / values / traits, Dynamic Type
///    (accessibility sizes grow the type, nothing leaves the pane, rows
///    never overlap), live re-theme (every dressed surface re-resolves), and
///    the layout: a side column on a regular width, a docked bottom sheet on
///    a compact one (raised and lowered).
/// 3. **Motion**, captured as SEQUENCES and asserted mid-flight: a pane
///    switch (crossfade + rise), a growth (a toggle revealing rows lands on
///    the bounce), the rail's chip glide. `--inject snap` snaps the pane
///    switch and the growth: the motion checks must then FAIL.
@MainActor
enum InspectorLab {
    private static var lines: [String] = []
    private static var failures = 0
    private static var out: URL!

    static func start(_ arguments: [String], lab: LabViewController) -> Bool {
        guard let i = arguments.firstIndex(of: "--inspector"), arguments.indices.contains(i + 1) else { return false }
        out = URL(fileURLWithPath: arguments[i + 1], isDirectory: true)
        let inject = arguments.firstIndex(of: "--inject").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        lab.stage.isHidden = true
        guard #available(iOS 26, *) else {
            print("INSPECTOR-GATE FAIL the studio needs iOS 26")
            exit(1)
        }
        Task { @MainActor in await run(lab: lab, inject: inject) }
        return true
    }

    // MARK: - Run

    @available(iOS 26, *)
    static func run(lab: LabViewController, inject: String?) async {
        setbuf(stdout, nil)
        UIApplication.shared.isIdleTimerDisabled = true
        InspectorSounds.muted = true
        let fm = FileManager.default
        try? fm.removeItem(at: out)
        try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        for sub in ["dark", "light", "xl", "motion"] {
            try? fm.createDirectory(at: out.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        log("INSPECTOR out=\(out.path) device=\(UIDevice.current.model) \(UIDevice.current.systemVersion)")
        if let inject {
            log("INSPECTOR inject=\(inject)")
            guard inject == "snap" else { log("INSPECTOR-GATE FAIL unknown --inject \(inject)"); exit(1) }
            #if DEBUG
            StudioInspectorController.probeSnapPaneSwitch = true
            InspectorPaneView.probeSnapGrowth = true
            #endif
        }
        lab.view.window?.overrideUserInterfaceStyle = .dark

        if inject == nil {
            await values(lab: lab)
        }
        await structureAndMotion(lab: lab, injected: inject != nil)

        try? lines.joined(separator: "\n").write(to: out.appendingPathComponent("run.txt"), atomically: true, encoding: .utf8)
        if failures == 0 {
            log("INSPECTOR-GATE PASS")
            exit(0)
        }
        log("INSPECTOR-GATE FAIL (\(failures) check(s) failed)")
        exit(1)
    }

    // MARK: - Editor

    @available(iOS 26, *)
    private static func openEditor(_ name: String, lab: LabViewController,
                                   prepare: (Project) -> Void = { _ in }) async -> EditorViewController? {
        let dir = out.appendingPathComponent("projects/\(name)", isDirectory: true)
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let project = InspectorValuesTranscript.makeProject(folder: dir)
        prepare(project)
        guard let poster = poster(size: CGSize(width: 640, height: 400)),
              (try? await StillMovieWriter.write(image: poster, to: dir.appendingPathComponent("screen.mov"), duration: 20)) != nil,
              (try? await StillMovieWriter.write(image: poster, to: dir.appendingPathComponent("camera.mov"), duration: 20)) != nil,
              let data = try? JSONEncoder().encode(project),
              (try? data.write(to: dir.appendingPathComponent(StudioProjectFolder.documentName))) != nil,
              let folder = try? StudioProjectFolder.open(dir) else {
            check("\(name)-open", false, "could not write or open the fixture project")
            return nil
        }
        let editor = EditorViewController(folder: folder, initialTime: InspectorValuesTranscript.playhead)
        editor.onClose = {}
        editor.inspector.imagePicker = { _, completion in
            completion(InspectorValuesTranscript.logoURL(in: dir))
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lab.present(editor, animated: false) { c.resume() }
        }
        await settle(0.6)
        return editor
    }

    @available(iOS 26, *)
    private static func close(_ editor: EditorViewController) async {
        editor.playback.teardown()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            editor.dismiss(animated: false) { c.resume() }
        }
        await settle(0.2)
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

    // MARK: - 1. Values

    @available(iOS 26, *)
    private static func values(lab: LabViewController) async {
        guard let editor = await openEditor("values", lab: lab) else { return }
        let inspector = editor.inspector
        let project = editor.project
        let selection = editor.selection
        guard let undo = editor.undoManager else { check("values-undo", false, "no undo manager"); return }
        undo.removeAllActions()
        var undoProblems: [String] = []
        var stepsChecked = 0
        var lastChange: (before: [String: String], after: [String: String])?
        var lastStepCount = inspector.session.registeredSteps

        func projectPart(_ s: [String: String]) -> [String: String] { s.filter { $0.key != "selection" } }

        let driver = InspectorValuesTranscript.Driver(
            showTab: { tab in
                selection.inspectorTab = tab
                await settle(0.25)
            },
            select: { pick in
                apply(pick, to: selection)
                await settle(0.3)
            },
            isVisible: { id in
                guard let pane = inspector.visiblePane, let view = find(id, in: pane) else { return false }
                return effectivelyVisible(view, in: pane)
            },
            visibleIDs: { tab in
                guard let pane = inspector.visiblePane else { return [] }
                let wanted = InspectorValuesTranscript.comparableIDs(tab)
                var found = Set<String>()
                walk(pane) { v in
                    if let id = v.accessibilityIdentifier, wanted.contains(id), effectivelyVisible(v, in: pane) { found.insert(id) }
                }
                return found.sorted()
            },
            drive: { id, input in
                guard let pane = inspector.visiblePane, let view = find(id, in: pane) else { return false }
                return drive(view, id: id, input: input, project: project, pane: pane)
            },
            settle: { await settle(0.15) },
            afterStep: { step, before, after in
                let changed = projectPart(before) != projectPart(after)
                let count = inspector.session.registeredSteps
                let delta = count - lastStepCount
                lastStepCount = count
                let label = InspectorValuesTranscript.describe(step)
                if case .select = step {
                    if delta != 0 { undoProblems.append("\(label): a selection registered \(delta) undo step(s)") }
                    return
                }
                stepsChecked += 1
                if changed {
                    if delta != 1 { undoProblems.append("\(label): \(delta) undo steps (want 1)") }
                    undo.undo()
                    await settle(0.15)
                    let undone = projectPart(InspectorValuesTranscript.snapshot(project, selection: selection))
                    if undone != projectPart(before) {
                        let keys = Set(undone.keys).union(before.keys).filter { $0 != "selection" && undone[$0] != before[$0] }.sorted()
                        undoProblems.append("\(label): undo left \(keys.prefix(4).joined(separator: ", "))")
                    }
                    let canRedo = undo.canRedo, redoName = undo.redoActionName
                    undo.redo()
                    let immediate = projectPart(InspectorValuesTranscript.snapshot(project, selection: selection))
                    await settle(0.15)
                    if immediate != projectPart(InspectorValuesTranscript.snapshot(project, selection: selection)) {
                        let now = projectPart(InspectorValuesTranscript.snapshot(project, selection: selection))
                        let keys = Set(now.keys).filter { now[$0] != immediate[$0] }.sorted()
                        undoProblems.append("\(label): after redo something rewrote \(keys.prefix(4).joined(separator: ", ")) (redo itself matched: \(immediate == projectPart(after)))")
                    }
                    let redone = projectPart(InspectorValuesTranscript.snapshot(project, selection: selection))
                    if redone != projectPart(after) {
                        let keys = Set(redone.keys).union(after.keys).filter { $0 != "selection" && redone[$0] != after[$0] }.sorted()
                        undoProblems.append("\(label): redo left \(keys.prefix(4).joined(separator: ", ")) (canRedo \(canRedo) '\(redoName)')")
                    }
                    lastChange = (before, after)
                } else {
                    if delta != 0 { undoProblems.append("\(label): no change but \(delta) undo step(s)") }
                    // Nothing empty sits on top: undo still reverts the last real edit.
                    if let last = lastChange, undo.canUndo {
                        undo.undo()
                        await settle(0.15)
                        let undone = projectPart(InspectorValuesTranscript.snapshot(project, selection: selection))
                        if undone != projectPart(last.before) { undoProblems.append("\(label): an empty undo step sits on top") }
                        undo.redo()
                        await settle(0.15)
                    }
                }
            })

        let transcript = await InspectorValuesTranscript.run(project: project, selection: selection, driver: driver)
        try? transcript.joined(separator: "\n").write(to: out.appendingPathComponent("ios-transcript.txt"),
                                                    atomically: true, encoding: .utf8)
        for line in transcript where line.contains("HIDDEN") || line.contains("NOT DRIVEN") { log("INSPECTOR note \(line)") }
        let verdict = InspectorValuesTranscript.verdict(transcript, against: InspectorValuesGoldens.transcript)
        for line in verdict.report { log("INSPECTOR diff \(line)") }
        check("values-transcript", verdict.pass,
              verdict.pass ? "\(transcript.count) lines identical to the frozen Mac transcript"
                           : "differs from the frozen Mac transcript (ios-transcript.txt)")
        check("values-undo", undoProblems.isEmpty,
              undoProblems.isEmpty ? "\(stepsChecked) steps: each edit one undo step; undo/redo restore byte for byte"
                                   : undoProblems.prefix(12).joined(separator: " | "))
        // The undo restore decodes settings: every field must round-trip
        // except the ones the decoder forces (restored directly) — and that
        // list must be exactly the session's.
        let probe = InspectorEditSession.json(project.settings)
        var lost = Set<String>()
        var decodedAny = false
        for setting in [true, false] {
            var variant = probe
            for (key, value) in probe where CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() { variant[key] = setting }
            let data = (try? JSONSerialization.data(withJSONObject: variant)) ?? Data()
            guard let decoded = (try? JSONDecoder().decode(ProjectSettings.self, from: data)).map(InspectorEditSession.json) else { continue }
            decodedAny = true
            lost.formUnion(variant.keys.filter { InspectorEditSession.canonical(variant[$0]!) != decoded[$0].map(InspectorEditSession.canonical) })
        }
        let decoded: [String: Any] = decodedAny ? probe : [:]
        let forced = Set(InspectorEditSession.decoderForcedBools.keys)
        check("settings-roundtrip", !decoded.isEmpty && lost == forced,
              "every ProjectSettings field round-trips through the undo restore except the decoder-forced \(lost.sorted()) (restored directly; listed: \(forced.sorted()))")
        await close(editor)
    }

    private static func apply(_ pick: InspectorValuesTranscript.Pick, to s: EditorShellSelection) {
        s.selectedZoomID = nil
        s.selectedTiltID = nil
        s.selectedHighlightID = nil
        s.selectedDepthFocusID = nil
        s.selectedBlurID = nil
        s.selectedAnnotationID = nil
        let id = InspectorValuesTranscript.uuid
        switch pick {
        case .none: break
        case .zoom(let n): s.selectedZoomID = id(n)
        case .tilt(let n): s.selectedTiltID = id(n)
        case .highlight(let n): s.selectedHighlightID = id(n)
        case .depth(let n): s.selectedDepthFocusID = id(n)
        case .blur(let n): s.selectedBlurID = id(n)
        case .annotation(let n): s.selectedAnnotationID = id(n)
        }
    }

    // MARK: Driving

    private static func drive(_ view: UIView, id: String, input: InspectorValuesTranscript.Input,
                              project: Project, pane: UIView) -> Bool {
        switch input {
        case .slider(let value):
            guard let slider = view as? CCSlider else { return false }
            slider.layoutIfNeeded()
            let r = slider.range
            let travel = slider.probeTravel
            let x = travel.origin + CGFloat((value - r.lowerBound) / (r.upperBound - r.lowerBound)) * travel.width
            slider.probeTrack(.began, x: x)
            slider.probeTrack(.ended, x: x)
            return true
        case .toggle:
            if let row = view as? CCToggleRow {
                guard row.isEnabled else { return true }
                row.sendActions(for: .touchUpInside)
                return true
            }
            if let toggle = view as? CCToggle {
                guard toggle.isEnabled else { return true }
                toggle.sendActions(for: .touchUpInside)
                return true
            }
            return false
        case .choose(let n):
            if let chips = view as? CCChipGroup {
                guard chips.items.indices.contains(n) else { return false }
                chips.probeTap(n)
                return true
            }
            if let select = view as? CCSelect {
                // The sheet's row action: select, then report.
                select.setSelectedIndex(n)
                select.onSelect?(n)
                return true
            }
            return false
        case .color(let r, let g, let b, let a):
            guard let well = view as? CCColorWell else { return false }
            let color = UIColor(red: r, green: g, blue: b, alpha: a)
            well.onChange?(color)
            well.onCommit?(color)
            return true
        case .text(let text):
            guard let field = view as? CCField else { return false }
            field.text = text
            field.sendActions(for: .editingChanged)
            field.sendActions(for: .editingDidEnd)
            return true
        case .tap:
            guard let button = view as? CCButton else { return false }
            button.sendActions(for: .touchUpInside)
            return true
        case .pad(let fx, let fy):
            var row: InspectorPadRowView?
            var v: UIView? = view
            while let current = v, row == nil { row = current as? InspectorPadRowView; v = current.superview }
            guard let row else { return false }
            row.probePress(fx: fx, fy: fy)
            return true
        case .preset(let n):
            guard let presets = view as? InspectorPresetRow, presets.probeCards.indices.contains(n) else { return false }
            presets.probeCards[n].sendActions(for: .touchUpInside)
            return true
        case .caption(let n, let text):
            guard let list = view as? InspectorCaptionListRow, project.subtitles.indices.contains(n),
                  let field = list.fields[project.subtitles[n].id] else { return false }
            field.text = text
            field.sendActions(for: .editingChanged)
            field.sendActions(for: .editingDidEnd)
            return true
        case .pickLogo:
            guard let button = view as? CCButton else { return false }
            button.sendActions(for: .touchUpInside)
            return true
        }
    }

    // MARK: - 2 + 3. Structure and motion

    @available(iOS 26, *)
    private static func structureAndMotion(lab: LabViewController, injected: Bool) async {
        guard let editor = await openEditor("structure", lab: lab, prepare: { p in
            let s = p.settings
            s.cameraLook = .popOut
            s.cameraCardFill = .gradient
            s.cameraCardBorder = .solid
            s.clickSoundEnabled = false
            s.keySoundEnabled = true
            s.menuBarReplacement = .dark
            s.introSlideStyle = .bottom
            s.curtainUnveilCorner = .topLeft
            s.motionBlur = true
            s.showWatermark = true
        }) else { return }
        let inspector = editor.inspector
        let window = editor.view.window!
        let regular = editor.view.bounds.width >= 700
        log("INSPECTOR layout \(regular ? "regular (side column)" : "compact (bottom sheet)") window=\(Int(window.bounds.width))×\(Int(window.bounds.height))")

        if !injected {
            layoutChecks(editor, regular: regular)
            if !regular { await sheetChecks(editor) }
            for tab in InspectorTab.allCases {
                switch tab {
                case .effects: apply(.zoom(1), to: editor.selection); editor.selection.selectedTiltID = nil
                case .annotations: apply(.annotation(6), to: editor.selection)
                default: apply(.none, to: editor.selection)
                }
                editor.selection.inspectorTab = tab
                await settle(0.5)
                guard let pane = inspector.visiblePane, pane.tab == tab else {
                    check("\(tab)-shown", false, "pane did not show")
                    continue
                }
                if !regular { inspector.setSheetRaised(true, animated: false); await settle(0.3) }
                structure(pane, tab: tab, inspector: inspector)
                await dynamicType(pane, tab: tab, inspector: inspector, window: window)
                await retheme(pane, tab: tab, inspector: inspector, window: window)
                if !regular { inspector.setSheetRaised(false, animated: false) }
            }
        }
        await motion(editor, injected: injected)
        await close(editor)
    }

    @available(iOS 26, *)
    private static func layoutChecks(_ editor: EditorViewController, regular: Bool) {
        let inspector = editor.inspector
        let frame = inspector.view.convert(inspector.view.bounds, to: editor.view)
        let container = editor.inspectorContainer.convert(editor.inspectorContainer.bounds, to: editor.view)
        if regular {
            check("layout-column", frame.equalTo(container) && inspector.rail.axis == .vertical && frame.width >= 300,
                  String(format: "side column %.0f×%.0f fills the inspector container; rail vertical", frame.width, frame.height))
        } else {
            check("layout-sheet", abs(frame.maxY - container.maxY) < 0.5 && abs(frame.minY - container.minY) < 0.5
                    && inspector.rail.axis == .horizontal,
                  String(format: "docked sheet %.0f×%.0f on the container; rail across the top", frame.width, frame.height))
        }
    }

    @available(iOS 26, *)
    private static func sheetChecks(_ editor: EditorViewController) async {
        let inspector = editor.inspector
        let docked = inspector.view.convert(inspector.view.bounds, to: editor.view)
        inspector.setSheetRaised(true, animated: true)
        await settle(0.12)
        let mid = (inspector.view.layer.presentation() ?? inspector.view.layer).frame
        await settle(0.6)
        let raised = inspector.view.convert(inspector.view.bounds, to: editor.view)
        let header = editor.header.convert(editor.header.bounds, to: editor.view)
        check("sheet-raise", raised.minY < docked.minY - 100 && raised.minY >= header.maxY - 0.5,
              String(format: "raised from y=%.0f to y=%.0f (header ends %.0f); mid-flight frame y=%.0f",
                     docked.minY, raised.minY, header.maxY, mid.minY))
        inspector.setSheetRaised(false, animated: true)
        await settle(0.7)
        let lowered = inspector.view.convert(inspector.view.bounds, to: editor.view)
        check("sheet-lower", abs(lowered.minY - docked.minY) < 0.5, String(format: "back to y=%.0f", lowered.minY))
    }

    // MARK: Structure

    private static func structure(_ pane: InspectorPaneView, tab: InspectorTab, inspector: StudioInspectorController) {
        var views: [UIView] = []
        func collect(_ v: UIView) {
            guard !v.isHidden, v.alpha > 0.01 else { return }
            views.append(v)
            v.subviews.forEach(collect)
        }
        collect(pane)
        let controls = views.compactMap { $0 as? UIControl }.filter { $0.isUserInteractionEnabled && $0.isEnabled }
        var small: [String] = []
        for c in controls {
            let center = CGPoint(x: c.bounds.midX, y: c.bounds.midY)
            let corners = [CGPoint(x: -21.5, y: -21.5), CGPoint(x: 21.5, y: -21.5), CGPoint(x: -21.5, y: 21.5), CGPoint(x: 21.5, y: 21.5)]
            if !corners.allSatisfy({ c.point(inside: CGPoint(x: center.x + $0.x, y: center.y + $0.y), with: nil) }) {
                small.append("\(type(of: c))[\(c.accessibilityIdentifier ?? c.accessibilityLabel ?? "?")] \(Int(c.bounds.width))×\(Int(c.bounds.height))")
            }
        }
        check("\(tab)-touch-targets", small.isEmpty && !controls.isEmpty,
              "\(controls.count) controls ≥ 44×44 pt" + (small.isEmpty ? "" : "; too small: \(small.prefix(5))"))
        var problems: [String] = []
        for v in views {
            let label = v.accessibilityLabel ?? ""
            switch v {
            case let s as CCSlider:
                if label.isEmpty || !s.accessibilityTraits.contains(.adjustable) || (s.accessibilityValue ?? "").isEmpty { problems.append("slider \(label)") }
            case let c as CCChip:
                if label.isEmpty || c.accessibilityTraits.contains(.selected) != c.isSelected { problems.append("chip \(label)") }
            case let r as CCToggleRow:
                if label.isEmpty || !["On", "Off"].contains(r.accessibilityValue ?? "") { problems.append("toggle \(label)") }
            case let t as CCToggle where t.isAccessibilityElement:
                if label.isEmpty || !["On", "Off"].contains(t.accessibilityValue ?? "") { problems.append("toggle \(label)") }
            case let w as CCColorWell:
                if label.isEmpty || !(w.accessibilityValue ?? "").contains("#") { problems.append("well \(label)") }
            case let s as CCSelect:
                if label.isEmpty || (s.accessibilityValue ?? "").isEmpty { problems.append("select \(label)") }
            case let p as CCPadView:
                if label.isEmpty || (p.accessibilityValue ?? "").isEmpty { problems.append("pad \(label)") }
            case let b as CCButton:
                if (b.accessibilityLabel ?? b.title).isEmpty { problems.append("button") }
            case let f as CCField:
                if label.isEmpty { problems.append("field \(f.placeholderText)") }
            default:
                break
            }
        }
        check("\(tab)-voiceover", problems.isEmpty,
              problems.isEmpty ? "labels, values and traits on every control" : "missing: \(problems.prefix(6))")
    }

    // MARK: Dynamic Type

    private static func dynamicType(_ pane: InspectorPaneView, tab: InspectorTab, inspector: StudioInspectorController,
                                    window: UIWindow) async {
        func fontSum() -> CGFloat {
            var sum: CGFloat = 0
            walk(pane) { if let l = $0 as? UILabel, !l.isHidden, l.adjustsFontForContentSizeCategory { sum += l.font.pointSize } }
            return sum
        }
        let base = fontSum()
        window.traitOverrides.preferredContentSizeCategory = .accessibilityLarge
        await settle(0.6)
        inspector.view.layoutIfNeeded()
        let grown = fontSum()
        // Nothing leaves the pane sideways; rows never overlap.
        var outside: [String] = [], overlaps: [String] = []
        let paneWidth = pane.bounds.width
        for row in pane.rows where !row.isHidden {
            let f = row.convert(row.bounds, to: pane)
            if f.minX < -0.5 || f.maxX > paneWidth + 0.5 { outside.append(row.rowID) }
        }
        for (_, section) in pane.sections where !section.isHidden {
            let rows = section.rows.filter { !$0.isHidden }.map { ($0.rowID, $0.convert($0.bounds, to: pane)) }
            for (a, b) in zip(rows, rows.dropFirst()) where b.1.minY < a.1.maxY - 0.5 { overlaps.append("\(a.0)/\(b.0)") }
        }
        if let image = LabCapture.view(inspector.view) {
            try? LabCapture.png(image).write(to: out.appendingPathComponent("xl/\(tab).png"))
        }
        window.traitOverrides.preferredContentSizeCategory = .large
        await settle(0.4)
        check("\(tab)-dynamic-type", grown > base * 1.15 && outside.isEmpty && overlaps.isEmpty,
              String(format: "type %.0f → %.0f pt summed at accessibility L", base, grown)
                + (outside.isEmpty ? "" : "; outside: \(outside.prefix(4))") + (overlaps.isEmpty ? "" : "; overlap: \(overlaps.prefix(4))"))
    }

    // MARK: Re-theme

    private static func retheme(_ pane: InspectorPaneView, tab: InspectorTab, inspector: StudioInspectorController,
                                window: UIWindow) async {
        func baseColors() -> [ObjectIdentifier: CGColor] {
            var map: [ObjectIdentifier: CGColor] = [:]
            walk(inspector.view) { v in
                guard !v.isHidden else { return }
                if let base = v.layer.sublayers?.first(where: { $0.name == "ccmat.base" }) as? CAGradientLayer,
                   let last = (base.colors as? [CGColor])?.last { map[ObjectIdentifier(v)] = last }
            }
            return map
        }
        window.overrideUserInterfaceStyle = .dark
        await settle(0.3)
        let dark = baseColors()
        let darkImage = LabCapture.view(inspector.view)
        if let darkImage { try? LabCapture.png(darkImage).write(to: out.appendingPathComponent("dark/\(tab).png")) }
        window.overrideUserInterfaceStyle = .light
        await settle(0.4)
        let light = baseColors()
        let lightImage = LabCapture.view(inspector.view)
        if let lightImage { try? LabCapture.png(lightImage).write(to: out.appendingPathComponent("light/\(tab).png")) }
        let stale = dark.filter { id, color in light[id].map { $0 == color } ?? false }.count
        let diff = (darkImage != nil && lightImage != nil) ? meanDiff(darkImage!, lightImage!) : 0
        window.overrideUserInterfaceStyle = .dark
        await settle(0.3)
        check("\(tab)-retheme", dark.count > 3 && stale == 0 && diff > 20,
              String(format: "%d dressed surfaces re-resolved live (stale %d); dark vs light mean diff %.0f/255", dark.count, stale, diff))
    }

    // MARK: Motion

    @available(iOS 26, *)
    private static func motion(_ editor: EditorViewController, injected: Bool) async {
        let inspector = editor.inspector
        let selection = editor.selection
        apply(.none, to: selection)
        if editor.view.bounds.width < 700 { inspector.setSheetRaised(true, animated: false) }
        selection.inspectorTab = .background
        await settle(0.6)

        // Pane switch: Background → Cursor, sampled on the presentation tree.
        var opacities: [Float] = [], rises: [CGFloat] = [], chipXs: [CGFloat] = []
        var frames: [CGImage] = []
        let chipStart = (inspector.rail.probeChipLayer.presentation() ?? inspector.rail.probeChipLayer).position
        selection.inspectorTab = .cursor
        await settle(0.001)
        guard let cursorPane = inspector.panes[.cursor] else { check("motion-pane-switch", false, "no cursor pane"); return }
        let t0 = CACurrentMediaTime()
        while CACurrentMediaTime() - t0 < 0.45 {
            let p = cursorPane.layer.presentation() ?? cursorPane.layer
            opacities.append(p.opacity)
            rises.append((p.value(forKeyPath: "transform.translation.y") as? CGFloat) ?? 0)
            let chip = inspector.rail.probeChipLayer.presentation() ?? inspector.rail.probeChipLayer
            chipXs.append(abs(chip.position.y - chipStart.y) + abs(chip.position.x - chipStart.x))
            if frames.count < 8, let image = presentationSnap(inspector.view) { frames.append(image) }
            await settle(0.016)
        }
        writeStrip(frames, to: out.appendingPathComponent("motion/pane-switch.png"))
        let midOpacity = opacities.contains { $0 > 0.05 && $0 < 0.95 }
        let midRise = rises.contains { $0 > 0.5 && $0 < 13.5 }
        let finalOpacity = (cursorPane.layer.presentation() ?? cursorPane.layer).opacity
        let paneSwitchOK = midOpacity && midRise && finalOpacity > 0.99
        report("motion-pane-switch", paneSwitchOK, injected: injected,
               "\(opacities.count) samples; mid-flight opacity \(midOpacity) (\(fmt(opacities.map { CGFloat($0) }))), rise \(midRise) (\(fmt(rises))) → settles at \(String(format: "%.2f", finalOpacity))")
        let chipTravel = chipXs.max() ?? 0
        let chipEnd = chipXs.last ?? 0
        let chipMid = chipXs.contains { $0 > 2 && $0 < chipEnd - 2 }
        check("motion-rail-glide", chipMid && chipTravel > 20,
              String(format: "the rail chip glided %.0f pt, %d samples mid-flight", chipTravel, chipXs.filter { $0 > 2 && $0 < chipEnd - 2 }.count))

        // Growth: Click Sound on reveals its rows; the section grows on the bounce.
        await settle(0.4)
        guard let toggle = find("cursor.clickSound", in: cursorPane) as? CCToggleRow,
              let section = cursorPane.sections.first(where: { $0.spec.id == "cursor.section.click" })?.view else {
            check("motion-growth", false, "Click Sound toggle not found")
            return
        }
        let startHeight = section.bounds.height
        var heights: [CGFloat] = [], alphas: [Float] = []
        frames = []
        toggle.sendActions(for: .touchUpInside)
        await settle(0.001)
        let revealed = cursorPane.rows.first { $0.rowID == "cursor.clickVolume" }
        let g0 = CACurrentMediaTime()
        while CACurrentMediaTime() - g0 < 0.55 {
            heights.append((section.layer.presentation() ?? section.layer).bounds.height)
            if let revealed { alphas.append((revealed.layer.presentation() ?? revealed.layer).opacity) }
            if frames.count < 8, let image = presentationSnap(cursorPane) { frames.append(image) }
            await settle(0.016)
        }
        writeStrip(frames, to: out.appendingPathComponent("motion/growth.png"))
        let endHeight = section.bounds.height
        let grew = endHeight > startHeight + 40
        let midHeight = heights.contains { $0 > startHeight + 2 && $0 < endHeight - 2 }
        let overshoot = heights.contains { $0 > endHeight + 0.5 }
        let midAlpha = alphas.contains { $0 > 0.05 && $0 < 0.95 }
        report("motion-growth", grew && midHeight && midAlpha, injected: injected,
               String(format: "section %.0f → %.0f pt; mid-flight height %@ (bounce overshoot %@), revealed row fades %@ (%@)",
                      startHeight, endHeight, midHeight ? "yes" : "no", overshoot ? "yes" : "no", midAlpha ? "yes" : "no",
                      fmt(alphas.map { CGFloat($0) })))
    }

    /// Motion checks: normally they must pass; injected (snapped) they must FAIL.
    private static func report(_ name: String, _ pass: Bool, injected: Bool, _ detail: String) {
        if injected {
            check("\(name)-catches-snap", !pass, (pass ? "STILL PASSED with the snap injected — the check is blind: " : "failed as it must with the snap injected: ") + detail)
        } else {
            check(name, pass, detail)
        }
    }

    // MARK: - Helpers

    private static func settle(_ seconds: Double) async { await LabTime.settle(seconds) }

    private static func walk(_ view: UIView, _ visit: (UIView) -> Void) {
        visit(view)
        view.subviews.forEach { walk($0, visit) }
    }

    private static func find(_ id: String, in root: UIView) -> UIView? {
        var match: UIView?
        walk(root) { if match == nil, $0.accessibilityIdentifier == id { match = $0 } }
        return match
    }

    private static func effectivelyVisible(_ view: UIView, in pane: UIView) -> Bool {
        var v: UIView? = view
        while let current = v, current !== pane {
            if current.isHidden { return false }
            v = current.superview
        }
        return true
    }

    private static func presentationSnap(_ view: UIView) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { ctx in
            (view.layer.presentation() ?? view.layer).render(in: ctx.cgContext)
        }.cgImage
    }

    private static func writeStrip(_ images: [CGImage], to url: URL) {
        guard !images.isEmpty else { return }
        let gap = 6
        let width = images.reduce(0) { $0 + $1.width } + gap * (images.count - 1)
        let height = images.map(\.height).max() ?? 1
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let strip = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { ctx in
            UIColor(white: 0.5, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            var x = 0
            for image in images {
                UIImage(cgImage: image).draw(in: CGRect(x: x, y: 0, width: image.width, height: image.height))
                x += image.width + gap
            }
        }
        try? strip.pngData()?.write(to: url)
    }

    private static func meanDiff(_ a: CGImage, _ b: CGImage) -> Double {
        func pixels(_ image: CGImage) -> [UInt8] {
            let w = 64, h = 64
            var data = [UInt8](repeating: 0, count: w * h * 4)
            let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return data
        }
        let pa = pixels(a), pb = pixels(b)
        var sum = 0
        for i in 0..<pa.count where i % 4 != 3 { sum += abs(Int(pa[i]) - Int(pb[i])) }
        return Double(sum) / Double(pa.count / 4 * 3)
    }

    private static func fmt(_ values: [CGFloat]) -> String {
        let picks = stride(from: 0, to: values.count, by: max(1, values.count / 8)).map { values[$0] }
        return picks.map { String(format: "%.2f", $0) }.joined(separator: ",")
    }

    private static func log(_ line: String) {
        print(line)
        lines.append(line)
    }

    private static func check(_ name: String, _ pass: Bool, _ detail: String) {
        if !pass { failures += 1 }
        log("INSPECTOR \(name) \(pass ? "PASS" : "FAIL") \(detail)")
    }
}
