import AppKit

#if DEBUG

/// `CaptureCat --effects-parity <outDir>` — the Mac half of the effects parity
/// gate (StudioHarness/EffectsParity; apps/ios/scripts/ios-effects-parity.sh).
///
/// The REAL inspector column (`EditorInspectorViewController` in a split
/// view, the editor's hosting chain — the values harness's topology) shows
/// the Effects pane (MotionSettingsPaneAppKit + its embedded
/// EffectsSettingsPaneAppKit) and the Motion pane (MotionFeelPaneAppKit) for
/// every `EffectsParity.states` fixture; the walker lists every LIVE control
/// view that is on screen, in view order: what the control itself holds
/// (its title, range, step, readouts, items, colour, copy, pill, preview
/// mode), never the spec. A control it does not know is listed as
/// `?<Class>` — it can only make the gate red, never vanish.
///
/// Then `EffectsParity.valueSteps` is replayed through the real controls
/// (the values harness's drivers) and recorded with the shared recorder.
/// Writes `mac-inventory.txt` and `mac-values.txt`; the iOS lab is held to
/// both, line for line. Never calls ScreenCaptureKit. DEBUG tooling.
@MainActor
enum EffectsParityHarness {
    static func run() -> Never {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .darkAqua)
        InspectorSounds.muted = true
        CursorSettingsPaneAppKit.probeKeystrokePermission = true

        let args = CommandLine.arguments
        let outDir: URL = {
            if let i = args.firstIndex(of: "--effects-parity"), args.indices.contains(i + 1), !args[i + 1].hasPrefix("--") {
                return URL(fileURLWithPath: args[i + 1])
            }
            return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("capturecat-effects-parity")
        }()
        let fm = FileManager.default
        try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)

        Task { @MainActor in
            let inventory = await inventory(outDir: outDir)
            try? inventory.joined(separator: "\n").write(to: outDir.appendingPathComponent("mac-inventory.txt"),
                                                         atomically: true, encoding: .utf8)
            print("EFFECTS-PARITY mac inventory \(inventory.count) lines → \(outDir.appendingPathComponent("mac-inventory.txt").path)")
            let values = await values(outDir: outDir)
            try? values.joined(separator: "\n").write(to: outDir.appendingPathComponent("mac-values.txt"),
                                                      atomically: true, encoding: .utf8)
            print("EFFECTS-PARITY mac values \(values.count) lines → \(outDir.appendingPathComponent("mac-values.txt").path)")
            let unknown = inventory.filter { $0.contains("| ?") }
            for line in unknown { print("EFFECTS-PARITY mac unknown control \(line)") }
            for line in values where line.contains("HIDDEN") || line.contains("NOT DRIVEN") {
                print("EFFECTS-PARITY mac note \(line)")
            }
            print("EFFECTS-PARITY MAC DONE")
            exit(0)
        }
        app.run()
        exit(0)
    }

    // MARK: - Host

    private static var window: NSWindow?

    /// A fresh project in a fresh editor column (the values harness's chain).
    private static func host(_ name: String, outDir: URL) async -> (Project, EditorShellSelection, URL) {
        window?.orderOut(nil)
        let fixture = outDir.appendingPathComponent("mac-\(name)")
        try? FileManager.default.removeItem(at: fixture)
        try? FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let project = EffectsParity.makeProject(folder: fixture)
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
        let w = NSWindow(contentViewController: split)
        w.setContentSize(NSSize(width: 900, height: 1400))
        w.orderFrontRegardless()
        window = w
        InspectorValuesHarness.window = w
        InspectorValuesHarness.root = split.view
        InspectorValuesHarness.follower = InspectorTabFollower()
        await InspectorValuesHarness.settle()
        return (project, selection, fixture)
    }

    // MARK: - Inventory

    private static func inventory(outDir: URL) async -> [String] {
        let (project, selection, folder) = await host("inventory", outDir: outDir)
        var lines: [String] = []
        for state in EffectsParity.states {
            EffectsParity.reset(project, folder: folder)
            state.prepare(project, selection)
            if let tab = InspectorValuesHarness.follower.update(selection) { selection.inspectorTab = tab }
            selection.inspectorTab = state.tab
            await InspectorValuesHarness.settle()
            await InspectorValuesHarness.settle()
            lines.append("== \(state.name) [\(state.tab.rawValue)]")
            guard let pane = InspectorValuesHarness.visiblePane() else {
                lines.append("<no pane>")
                continue
            }
            lines += walk(pane, tab: state.tab).map(\.line)
        }
        return lines
    }

    /// Every visible effect control under `pane`, in view order.
    static func walk(_ pane: NSView, tab: InspectorTab) -> [EffectsParity.Item] {
        var items: [EffectsParity.Item] = []
        // Labels that title a recognised control in its row (menu, well).
        var rowLabels = Set<ObjectIdentifier>()
        func visible(_ v: NSView) -> Bool { InspectorValuesHarness.effectivelyVisible(v, in: pane) }
        func section(_ v: NSView) -> String {
            var s: NSView? = v.superview
            while let current = s {
                if let box = current as? InspectorSectionBox { return box.probeTitle ?? "-" }
                s = current.superview
            }
            return "-"
        }
        func rowTitle(_ control: NSView) -> String {
            guard let row = control.superview else { return "" }
            for case let label as NSTextField in row.subviews where label !== control {
                rowLabels.insert(ObjectIdentifier(label))
                return label.stringValue
            }
            return ""
        }
        func srgb(_ color: NSColor) -> String {
            let c = color.usingColorSpace(.sRGB) ?? color
            return EffectsParity.colorDetail(r: Double(c.redComponent), g: Double(c.greenComponent),
                                             b: Double(c.blueComponent), a: Double(c.alphaComponent))
        }
        func add(_ v: NSView, _ kind: String, _ title: String, _ detail: String) {
            items.append(.init(section: section(v), id: v.inspectorSpecID ?? "?", kind: kind, title: title, detail: detail))
        }

        func visit(_ v: NSView) {
            guard !v.isHidden else { return }
            switch v {
            case let row as InspectorSliderRow:
                let s = row.slider
                add(v, "slider", s.title, EffectsParity.sliderDetail(range: s.range, step: s.step, value: s.probeValueText,
                                                                      readout: { s.probeDisplayText(for: $0) }))
                return
            case let t as InspectorToggleControl:
                add(v, "toggle", t.probeTitle, "on=\(t.isOn)")
                return
            case let c as InspectorChipsControl:
                add(v, "chips", "", EffectsParity.choiceDetail(id: c.inspectorSpecID ?? "?", items: c.items, selected: c.selectedIndex))
                return
            case let m as InspectorMenuControl:
                add(v, "menu", rowTitle(m), EffectsParity.choiceDetail(id: m.inspectorSpecID ?? "?", items: m.items.map(\.title), selected: m.selectedIndex))
                return
            case let b as InspectorButton:
                add(v, "button", b.title, "destructive=\(b.probeDestructive)")
                return
            case let w as InspectorColorWellControl:
                add(v, "color", rowTitle(w), srgb(w.getColor()))
                return
            case let p as ZoomFocusPadControl:
                add(v, "pad", p.probeTitle, "pill=\(p.probePill)")
                return
            case let p as TiltPadControl:
                add(v, "pad", p.probeTitle, "pill=\(p.probePill)")
                return
            case let p as EffectPreviewPadControl:
                add(v, "preview", "", p.probeMode.probeDescription)
                return
            case let p as PropertyPreviewPadControl:
                add(v, "preview", "", p.probeMode.probeDescription)
                return
            case let p as MotionSpeedPadControl:
                add(v, "preview", "", InspectorPreviewMath.Mode.motionSpeed(duration: p.duration).probeDescription)
                return
            case let f as NSTextField where f.inspectorSpecID != nil:
                add(v, "caption", "", EffectsParity.captionDetail(text: f.stringValue, full: f.toolTip))
                return
            case let box as InspectorSectionBox:
                // The header is chrome; its rows are walked.
                for sub in box.subviews {
                    if let f = sub as? NSTextField, f.stringValue == box.probeTitle { continue }
                    visit(sub)
                }
                return
            case let f as NSTextField:
                if !rowLabels.contains(ObjectIdentifier(f)), !f.stringValue.isEmpty, visible(f),
                   !isRowLabel(f) {
                    items.append(.init(section: section(v), id: "?label", kind: "?NSTextField", title: f.stringValue, detail: ""))
                }
                return
            case let c as NSControl:
                if visible(c) {
                    items.append(.init(section: section(v), id: c.inspectorSpecID ?? "?", kind: "?\(type(of: c))",
                                       title: "", detail: ""))
                }
                return
            default:
                for sub in v.subviews { visit(sub) }
            }
        }
        /// A plain label whose row holds a menu or a colour well (InspectorKitViews.row).
        func isRowLabel(_ f: NSTextField) -> Bool {
            guard let row = f.superview else { return false }
            return row.subviews.contains { $0 is InspectorMenuControl || $0 is InspectorColorWellControl }
        }
        visit(pane)
        return items
    }

    // MARK: - Values

    private static func values(outDir: URL) async -> [String] {
        let (project, selection, _) = await host("values", outDir: outDir)
        let driver = InspectorValuesTranscript.Driver(
            showTab: { tab in
                selection.inspectorTab = tab
                await InspectorValuesHarness.settle()
            },
            select: { pick in
                InspectorValuesHarness.apply(pick, to: selection)
                if let tab = InspectorValuesHarness.follower.update(selection) { selection.inspectorTab = tab }
                await InspectorValuesHarness.settle()
            },
            isVisible: { id in
                guard let pane = InspectorValuesHarness.visiblePane(),
                      let view = InspectorValuesHarness.find(id, in: pane) else { return false }
                return InspectorValuesHarness.effectivelyVisible(view, in: pane)
            },
            visibleIDs: { _ in [] },
            drive: { id, input in
                guard let pane = InspectorValuesHarness.visiblePane(),
                      let view = InspectorValuesHarness.find(id, in: pane) else { return false }
                return InspectorValuesHarness.drive(view, id: id, input: input, project: project)
            },
            settle: { await InspectorValuesHarness.settle() }
        )
        return await InspectorValuesTranscript.run(project: project, selection: selection, driver: driver,
                                                   script: EffectsParity.valueSteps, title: EffectsParity.valuesHeader)
    }
}
#endif
