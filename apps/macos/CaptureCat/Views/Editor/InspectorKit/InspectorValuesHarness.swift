import AppKit

#if DEBUG

/// `CaptureCat --inspector-values-test [outDir] [--refreeze]`
///
/// Replays the shared inspector-values script (StudioHarness/
/// InspectorValuesTranscript) through the REAL Mac inspector — the
/// `EditorInspectorViewController` in a split view, the hosting chain the
/// editor uses (CLAUDE.md §3, "wrong topology") — and records what every
/// control writes. Sliders and pads are pressed with real mouse events at the
/// position of the value (the control does its own quantizing); chips,
/// toggles and buttons are clicked; menus pick their row; colour wells
/// receive the picker's commit; text fields are typed into and ended.
///
/// The transcript is scored against the frozen reference
/// (`InspectorValuesGoldens`), which is also what the iOS `--inspector` gate
/// is held to. `--refreeze` writes a fresh InspectorValuesGoldens.swift into
/// outDir for review — it never edits the source tree. DEBUG tooling.
@MainActor
enum InspectorValuesHarness {
    static var window: NSWindow!
    static var root: NSView!
    static var follower = InspectorTabFollower()

    static func run() -> Never {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // Dynamic system colours resolve the same way every run.
        app.appearance = NSAppearance(named: .darkAqua)
        InspectorSounds.muted = true
        CursorSettingsPaneAppKit.probeKeystrokePermission = true

        let args = CommandLine.arguments
        let refreeze = args.contains("--refreeze")
        let outDir: URL = {
            if let i = args.firstIndex(of: "--inspector-values-test"), args.indices.contains(i + 1),
               !args[i + 1].hasPrefix("--") {
                return URL(fileURLWithPath: args[i + 1])
            }
            return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("capturecat-inspector-values")
        }()
        let fixture = outDir.appendingPathComponent("fixture")
        try? FileManager.default.removeItem(at: fixture)
        try? FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)

        let project = InspectorValuesTranscript.makeProject(folder: fixture)
        let selection = EditorShellSelection()
        let playback = EditorPlaybackController(appState: nil)
        playback.currentTime = InspectorValuesTranscript.playhead

        let inspector = EditorInspectorViewController(project: project, playback: playback, selection: selection)
        let stage = NSViewController()
        stage.view = NSView()
        let split = NSSplitViewController()
        split.addSplitViewItem(NSSplitViewItem(viewController: stage))
        let item = NSSplitViewItem(viewController: inspector)
        item.minimumThickness = 380
        item.maximumThickness = 480
        split.addSplitViewItem(item)
        window = NSWindow(contentViewController: split)
        window.setContentSize(NSSize(width: 900, height: 1100))
        window.orderFrontRegardless()
        root = split.view

        Task { @MainActor in
            await settle()
            let driver = InspectorValuesTranscript.Driver(
                showTab: { tab in
                    selection.inspectorTab = tab
                    await settle()
                },
                select: { pick in
                    apply(pick, to: selection)
                    if let tab = follower.update(selection) { selection.inspectorTab = tab }
                    await settle()
                },
                isVisible: { id in
                    guard let pane = visiblePane(), let view = find(id, in: pane) else { return false }
                    return effectivelyVisible(view, in: pane)
                },
                visibleIDs: { tab in
                    guard let pane = visiblePane() else { return [] }
                    let wanted = InspectorValuesTranscript.comparableIDs(tab)
                    var found = Set<String>()
                    walk(pane) { v in
                        if let id = v.inspectorSpecID, wanted.contains(id), effectivelyVisible(v, in: pane) {
                            found.insert(id)
                        }
                    }
                    return found.sorted()
                },
                drive: { id, input in
                    guard let pane = visiblePane(), let view = find(id, in: pane) else { return false }
                    return drive(view, id: id, input: input, project: project)
                },
                settle: { await settle() }
            )
            let lines = await InspectorValuesTranscript.run(project: project, selection: selection, driver: driver)
            let text = lines.joined(separator: "\n")
            try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            try? text.write(to: outDir.appendingPathComponent("mac-transcript.txt"), atomically: true, encoding: .utf8)
            print("INSPECTOR-VALUES transcript \(outDir.appendingPathComponent("mac-transcript.txt").path) (\(lines.count) lines)")
            for line in lines where line.contains("HIDDEN") || line.contains("NOT DRIVEN") {
                print("INSPECTOR-VALUES note \(line)")
            }
            if refreeze {
                let swift = InspectorValuesTranscript.goldenSource(for: text)
                let url = outDir.appendingPathComponent("InspectorValuesGoldens.swift")
                try? swift.write(to: url, atomically: true, encoding: .utf8)
                print("INSPECTOR-VALUES refreeze → \(url.path) (review, then copy into StudioHarness/)")
            }
            let verdict = InspectorValuesTranscript.verdict(lines, against: InspectorValuesGoldens.transcript)
            for line in verdict.report { print("INSPECTOR-VALUES diff \(line)") }
            print(verdict.pass ? "INSPECTOR-VALUES PASS (\(lines.count) lines identical to the frozen reference)"
                               : "INSPECTOR-VALUES FAIL (transcript differs from the frozen reference)")
            exit(verdict.pass ? 0 : 1)
        }
        app.run()
        exit(0)
    }

    // MARK: - Selection

    static func apply(_ pick: InspectorValuesTranscript.Pick, to s: EditorShellSelection) {
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

    // MARK: - Tree

    static func settle() async {
        for _ in 0..<4 {
            try? await Task.sleep(nanoseconds: 25_000_000)
            root?.layoutSubtreeIfNeeded()
        }
    }

    /// The pane the column shows (the scroll view's one unhidden document child).
    static func visiblePane() -> NSView? {
        var column: InspectorColumnAppKit?
        walk(root) { if column == nil, let c = $0 as? InspectorColumnAppKit { column = c } }
        guard let column else { return nil }
        var scroll: NSScrollView?
        walk(column) { if scroll == nil, let s = $0 as? NSScrollView { scroll = s } }
        return scroll?.documentView?.subviews.first { !$0.isHidden }
    }

    static func walk(_ view: NSView, _ visit: (NSView) -> Void) {
        visit(view)
        for sub in view.subviews { walk(sub, visit) }
    }

    static func find(_ id: String, in root: NSView) -> NSView? {
        var match: NSView?
        walk(root) { if match == nil, $0.inspectorSpecID == id { match = $0 } }
        return match
    }

    static func effectivelyVisible(_ view: NSView, in pane: NSView) -> Bool {
        var v: NSView? = view
        while let current = v, current !== pane {
            if current.isHidden { return false }
            v = current.superview
        }
        return true
    }

    static func first<T: NSView>(_ type: T.Type, in root: NSView) -> T? {
        var match: T?
        walk(root) { if match == nil, let t = $0 as? T { match = t } }
        return match
    }

    // MARK: - Driving

    static func click(_ view: NSView, at point: NSPoint? = nil, down: Bool = true, up: Bool = true) {
        let p = point ?? NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        let location = view.convert(p, to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                               clickCount: 1, pressure: 1)
        }
        if down, let e = event(.leftMouseDown) { view.mouseDown(with: e) }
        if up, let e = event(.leftMouseUp) { view.mouseUp(with: e) }
    }

    static func drive(_ view: NSView, id: String, input: InspectorValuesTranscript.Input,
                              project: Project) -> Bool {
        let scope = InspectorScope(settings: project.settings, project: project)
        switch input {
        case .slider(let value):
            guard let slider = (view as? InspectorSliderRow)?.slider ?? first(CCSlider.self, in: view) else { return false }
            let r = slider.range
            let f = CGFloat((value - r.lowerBound) / (r.upperBound - r.lowerBound))
            // The travel ends where the readout starts, and the readout's
            // width follows the value — so the release is re-aimed at the
            // same value after the press moved it (a finger stays on the
            // value it chose). Both go through the real mouse path.
            var travel = slider.probeTravel
            click(slider, at: NSPoint(x: travel.origin + f * travel.width, y: slider.bounds.midY), up: false)
            slider.layoutSubtreeIfNeeded()
            travel = slider.probeTravel
            click(slider, at: NSPoint(x: travel.origin + f * travel.width, y: slider.bounds.midY), down: false)
            return true
        case .toggle:
            guard let toggle = (view as? CaptureCatToggle) ?? first(CaptureCatToggle.self, in: view) else { return false }
            click(toggle)
            return true
        case .choose(let n):
            if let menu = view as? InspectorMenuControl {
                // The menu's own pick path (selectedIndex, then onSelect).
                menu.selectedIndex = n
                menu.onSelect?(n)
                return true
            }
            var chips: [NSView] = []
            walk(view) { if String(describing: type(of: $0)).contains("ChipButton") { chips.append($0) } }
            guard chips.indices.contains(n) else { return false }
            click(chips[n])
            return true
        case .color(let r, let g, let b, let a):
            guard let well = view as? InspectorColorWellControl else { return false }
            well.setColor?(NSColor(srgbRed: r, green: g, blue: b, alpha: a))
            return true
        case .text(let text):
            guard let field = view as? NSTextField else { return false }
            field.stringValue = text
            field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
            field.delegate?.controlTextDidEndEditing?(Notification(name: NSControl.textDidEndEditingNotification, object: field))
            return true
        case .tap:
            click(view)
            return true
        case .pad(let fx, let fy):
            switch view {
            case let pad as PlacementPadControl:
                click(pad, at: NSPoint(x: CGFloat(fx) * pad.bounds.width, y: CGFloat(fy) * pad.bounds.height), up: false)
            case let pad as CameraPreviewPadControl:
                click(pad, at: pad.probePoint(fx: fx, fy: fy))
            case let pad as TiltPadControl:
                pad.probePress(fx: fx, fy: fy)
            case let pad as ZoomFocusPadControl:
                click(pad, at: pad.probePoint(fx: fx, fy: fy), up: false)
            case let pad as SubtitlePositionPadControl:
                click(pad, at: pad.probePoint(fx: fx, fy: fy))
            case let pad as WatermarkPositionPadControl:
                click(pad, at: pad.probePoint(fx: fx, fy: fy))
            default:
                return false
            }
            return true
        case .preset(let n):
            var cards: [SubtitlePresetCardControl] = []
            walk(view) { if let c = $0 as? SubtitlePresetCardControl { cards.append(c) } }
            guard cards.indices.contains(n) else { return false }
            click(cards[n])
            return true
        case .caption(let n, let text):
            guard project.subtitles.indices.contains(n) else { return false }
            let key = project.subtitles[n].id.uuidString
            var field: NSTextField?
            walk(view) { if field == nil, let f = $0 as? NSTextField, f.identifier?.rawValue == key { field = f } }
            guard let field else { return false }
            field.stringValue = text
            field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
            return true
        case .pickLogo:
            // The pane's picker hands this URL to the shared adopt.
            let logo = InspectorValuesTranscript.logoURL(in: project.videoURL!.deletingLastPathComponent())
            switch id {
            case "brand.choose": try? BrandPane.adoptLogo(scope, from: logo)
            case "effects.curtainLogoChoose": try? EffectsPane.adoptCurtainLogo(scope, from: logo)
            default: return false
            }
            return true
        }
    }
}
#endif
