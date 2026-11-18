import UIKit

/// `--effects-parity <outDir> --mac <macDir> [--inject drop-control|values-defect] [--shots]`
/// — the iOS half of the effects parity gate (StudioHarness/EffectsParity;
/// apps/ios/scripts/ios-effects-parity.sh; the Mac half is `CaptureCat
/// --effects-parity`).
///
/// In the REAL editor, in the app's window chain:
///
/// 1. **Inventory.** For every `EffectsParity.states` fixture the pane is
///    reached the way a user reaches it — on a phone through the drill-down
///    tool bar (the pane key, or a selection's Adjust key), then EVERY
///    sub-option key, each opening its short panel; on an iPad through the
///    column — and every control the panels show is listed with the shared
///    line format from the LIVE UIKit control (a section's leading choice,
///    which a phone offers as keys, is listed from those keys). The list
///    must equal the Mac's `mac-inventory.txt` line for line; a control the
///    walker does not know is `?<Class>`.
/// 2. **Values.** `EffectsParity.valueSteps` through the real controls,
///    reached the same way (a phone opens whichever sub-option shows the
///    control); the transcript must equal the Mac's `mac-values.txt` line
///    for line, and every edit must be ONE undo step that undo / redo
///    restore exactly.
///
/// 3. **Panels (a phone).** Every short panel the walk opens — and every
///    sub-option of EVERY pane (a sweep after the states) — shows all its
///    controls: each control's frame lies inside the panel's visible rect and
///    above the floating bar's top, and the rows fit without scrolling
///    (`panel-fits`). No panel's first row repeats its title as an on/off
///    toggle — the feature's switch rides the title strip, a VoiceOver switch
///    labelled with the feature (`panel-title-toggle`). At rest the bar never
///    cuts a key glyph at its edge, and a bar that overflows fades on the side
///    with more (`bar-edge`).
///
/// `--inject drop-control` hides one control (Curtain ▸ Tint Logo) and
/// `--inject values-defect` makes one slider (Parallax ▸ Strength) write a
/// step too far; `--inject panel-clips` sizes panels short of their rows,
/// `title-toggle-row` keeps the feature's switch as a row under its title and
/// `bar-cuts-key` runs the capsule to the room's edge: the gate must turn red
/// for each.
@MainActor
enum EffectsParityLab {
    private static var lines: [String] = []
    private static var failures = 0
    private static var out: URL!
    private static var shots = false

    static func start(_ arguments: [String], lab: LabViewController) -> Bool {
        guard let i = arguments.firstIndex(of: "--effects-parity"), arguments.indices.contains(i + 1) else { return false }
        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        out = URL(fileURLWithPath: arguments[i + 1], isDirectory: true)
        let mac = value("--mac").map { URL(fileURLWithPath: $0, isDirectory: true) }
        let inject = value("--inject")
        shots = arguments.contains("--shots")
        lab.stage.isHidden = true
        guard #available(iOS 26, *) else {
            print("EFFECTS-PARITY-GATE FAIL the studio needs iOS 26")
            exit(1)
        }
        Task { @MainActor in await run(lab: lab, mac: mac, inject: inject) }
        return true
    }

    // MARK: - Run

    @available(iOS 26, *)
    private static func run(lab: LabViewController, mac: URL?, inject: String?) async {
        setbuf(stdout, nil)
        UIApplication.shared.isIdleTimerDisabled = true
        InspectorSounds.muted = true
        let fm = FileManager.default
        try? fm.removeItem(at: out)
        try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        if shots { try? fm.createDirectory(at: out.appendingPathComponent("shots"), withIntermediateDirectories: true) }
        InspectorLab.out = out
        lab.view.window?.overrideUserInterfaceStyle = .dark
        log("EFFECTS-PARITY out=\(out.path) device=\(UIDevice.current.model) \(UIDevice.current.systemVersion)")
        if let inject {
            log("EFFECTS-PARITY inject=\(inject)")
            #if DEBUG
            switch inject {
            case "drop-control": InspectorPaneView.probeDropRowID = EffectsPane.curtainLogoTint.id
            case "values-defect": InspectorSliderRowView.probeSkewWriteID = EffectsPane.parallaxStrength.id
            case "panel-clips": EditorViewController.probePanelDefect = .clips
            case "title-toggle-row": StudioInspectorController.probeNoHeaderToggle = true
            case "bar-cuts-key": EditorToolBar.probeCutsKey = true
            default: log("EFFECTS-PARITY-GATE FAIL unknown --inject \(inject)"); exit(1)
            }
            #endif
        }
        guard let mac,
              let macInventory = try? String(contentsOf: mac.appendingPathComponent("mac-inventory.txt"), encoding: .utf8),
              let macValues = try? String(contentsOf: mac.appendingPathComponent("mac-values.txt"), encoding: .utf8) else {
            log("EFFECTS-PARITY-GATE FAIL no Mac reference (--mac <dir> with mac-inventory.txt + mac-values.txt)")
            exit(1)
        }

        let inventory = await inventory(lab: lab)
        try? inventory.joined(separator: "\n").write(to: out.appendingPathComponent("ios-inventory.txt"),
                                                     atomically: true, encoding: .utf8)
        let inv = EffectsParity.compare(mac: lines(macInventory), ios: inventory)
        for note in inv.notes { log("EFFECTS-PARITY note \(note)") }
        for d in inv.diff.prefix(40) { log("EFFECTS-PARITY diff inventory \(d)") }
        check("inventory", inv.diff.isEmpty,
              inv.diff.isEmpty ? "\(inventory.count) lines: every Mac effect control, in order, with its values, ranges, formats and copy"
                               : "\(inv.diff.count) line(s) differ from the Mac (ios-inventory.txt vs mac-inventory.txt)")

        if !panelLabels.isEmpty || barsChecked > 0 {
            check("panel-fits", panelProblems.isEmpty && !panelLabels.isEmpty,
                  panelProblems.isEmpty ? "\(panelLabels.count) panels: every control inside the panel's visible rect, above the bar, no scrolling"
                                        : "\(panelProblems.count) of \(panelLabels.count) panels clip: " + panelProblems.prefix(8).joined(separator: " | "))
            check("panel-title-toggle", titleProblems.isEmpty && headerToggles > 0,
                  titleProblems.isEmpty ? "\(panelLabels.count) panels: none repeats its title as a toggle row; \(headerToggles) carry the feature's switch in the title strip (a VoiceOver switch)"
                                        : titleProblems.prefix(8).joined(separator: " | "))
            check("bar-edge", barProblems.isEmpty && barsChecked > 0,
                  barProblems.isEmpty ? "\(barsChecked) bar levels at rest: no key glyph cut at the capsule's edge; \(barsFaded) overflowing levels fade on the side with more"
                                      : barProblems.prefix(6).joined(separator: " | "))
        }

        // A panel defect is judged by the panel gates: the values walk is skipped.
        let panelInject = ["panel-clips", "title-toggle-row", "bar-cuts-key"].contains(inject ?? "")
        let values = panelInject ? [] : await values(lab: lab)
        if panelInject {
            log("EFFECTS-PARITY note values skipped (\(inject ?? "") is a panel defect)")
        } else {
            try? values.joined(separator: "\n").write(to: out.appendingPathComponent("ios-values.txt"),
                                                      atomically: true, encoding: .utf8)
            let verdict = InspectorValuesTranscript.verdict(values, against: macValues)
            for d in verdict.report { log("EFFECTS-PARITY diff values \(d)") }
            check("values", verdict.pass,
                  verdict.pass ? "\(values.count) lines identical to the Mac's (every effect control to non-default values)"
                               : "the transcript differs from the Mac's (ios-values.txt vs mac-values.txt)")
        }

        try? lines.joined(separator: "\n").write(to: out.appendingPathComponent("run.txt"), atomically: true, encoding: .utf8)
        if failures == 0 {
            log("EFFECTS-PARITY-GATE PASS")
            exit(0)
        }
        log("EFFECTS-PARITY-GATE FAIL (\(failures) check(s) failed)")
        exit(1)
    }

    private static func lines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    // MARK: - Navigation (the drill-down bar, as a user taps it)

    private static func tap(_ control: UIControl?) async {
        control?.sendActions(for: .touchUpInside)
        await InspectorLab.settle(0.35)
    }

    /// Brings the tool bar to `tab`'s option level (a phone): Adjust from a
    /// selection's context keys, else the pane's key from the root tools.
    @available(iOS 26, *)
    private static func paneLevel(_ editor: EditorViewController, _ tab: InspectorTab) async {
        let bar = editor.toolBar
        for _ in 0..<4 {
            switch bar.mode {
            case .pane(let shown) where shown == tab:
                return
            case .context:
                if let adjust = bar.key(for: .adjust) { await tap(adjust) } else { return }
                if case .pane(let shown) = bar.mode, shown != tab { await tap(bar.key(for: .back)) }
            case .pane, .slicing:
                await tap(bar.key(for: .back))
            case .tools:
                await tap(bar.key(for: .pane(tab)))
            }
        }
    }

    /// The pane's rows a panel (or the column) shows now: index → row.
    @available(iOS 26, *)
    private static func shownRows(_ editor: EditorViewController) -> [(Int, InspectorRowView)] {
        guard let pane = editor.inspector.visiblePane else { return [] }
        if !editor.usesRegularLayout, !editor.isPanelOpen { return [] }
        return pane.rows.enumerated().filter { _, row in
            !row.isHidden && InspectorLab.effectivelyVisible(row, in: pane)
        }.map { ($0.offset, $0.element) }
    }

    /// A section's leading choice offered as keys (a phone): the row it
    /// stands for, with the keys' titles and the current one.
    @available(iOS 26, *)
    private static func choiceKeys(_ editor: EditorViewController) -> [(row: Int, id: String, item: EffectsParity.Item)] {
        guard let pane = editor.inspector.visiblePane else { return [] }
        var bySection: [String: [InspectorPanelOption]] = [:]
        var order: [String] = []
        for o in editor.toolBar.options where o.choice != nil {
            let key = o.section ?? ""
            if bySection[key] == nil { order.append(key) }
            bySection[key, default: []].append(o)
        }
        return order.compactMap { section in
            guard let options = bySection[section], let row = options.first?.choice?.row,
                  let choiceRow = pane.rows[row] as? InspectorChoiceRowView else { return nil }
            let titles = options.map { editor.toolBar.key(for: .option($0.id))?.accessibilityLabel ?? $0.title }
            let sectionTitle = pane.sections.first { $0.spec.id == section }?.view.title ?? "-"
            let item = EffectsParity.Item(section: sectionTitle, id: choiceRow.spec.id, kind: "chips", title: "",
                                          detail: EffectsParity.choiceDetail(id: choiceRow.spec.id, items: titles,
                                                                             selected: options.firstIndex { $0.isCurrent }))
            return (row, choiceRow.spec.id, item)
        }
    }

    /// Opens a sub-option's panel (unless it is the one open).
    @available(iOS 26, *)
    private static func open(_ option: InspectorPanelOption, _ editor: EditorViewController) async {
        if editor.isPanelOpen, editor.openOption?.id == option.id { return }
        await tap(editor.toolBar.key(for: .option(option.id)))
    }

    // MARK: - 1. Inventory

    @available(iOS 26, *)
    private static func inventory(lab: LabViewController) async -> [String] {
        guard let editor = await InspectorLab.openEditor("inventory", lab: lab, make: EffectsParity.makeProject) else {
            check("inventory-open", false, "could not open the fixture project")
            return []
        }
        let folder = out.appendingPathComponent("projects/inventory", isDirectory: true)
        let phone = !editor.usesRegularLayout
        log("EFFECTS-PARITY layout \(phone ? "compact (drill-down bar + panels)" : "regular (side column)")")
        var result: [String] = []
        for (n, state) in EffectsParity.states.enumerated() {
            editor.closePanel(animated: false)
            // Back to the root before the state's selection lands.
            if phone { await tap(editor.toolBar.key(for: .back)) }
            EffectsParity.reset(editor.project, folder: folder)
            state.prepare(editor.project, editor.selection)
            await InspectorLab.settle(0.4)
            result.append("== \(state.name) [\(state.tab.rawValue)]")
            var byRow: [Int: [EffectsParity.Item]] = [:]
            if phone {
                await paneLevel(editor, state.tab)
                guard case .pane(let tab) = editor.toolBar.mode, tab == state.tab else {
                    result.append("<the tool bar did not reach \(state.tab.rawValue): \(editor.toolBar.mode)>")
                    continue
                }
                for key in choiceKeys(editor) { byRow[key.row] = [key.item] }
                await checkBar(editor, label: "\(state.name) [\(state.tab.rawValue)]")
                for option in editor.toolBar.options {
                    if option.choice != nil, !option.isCurrent { continue }
                    await open(option, editor)
                    for (index, row) in shownRows(editor) where byRow[index] == nil {
                        byRow[index] = items(of: row, in: editor.inspector.visiblePane)
                    }
                    // The feature's switch in the title strip stands in for its row.
                    if editor.isPanelOpen, let (index, _) = editor.inspector.headerToggleRow, byRow[index] == nil {
                        byRow[index] = headerToggleItems(editor)
                    }
                    await sampleMotion(editor)
                    await checkPanel(editor, label: "\(state.name) ▸ \(option.title)")
                    if shots, n < 16 {
                        snap(editor, name: String(format: "%02d-%@-%@", n, slug(state.name), slug(option.title)))
                    }
                }
                editor.closePanel(animated: false)
            } else {
                editor.selection.inspectorTab = state.tab
                await InspectorLab.settle(0.4)
                for (index, row) in shownRows(editor) { byRow[index] = items(of: row, in: editor.inspector.visiblePane) }
                await sampleMotion(editor)
                if shots { snap(editor, name: String(format: "%02d-%@", n, slug(state.name))) }
            }
            for index in byRow.keys.sorted() { result += byRow[index]!.map(\.line) }
        }
        if phone { await sweepPanes(editor, folder: folder) }
        let still = moving.filter { !$0.value }.map(\.key).sorted()
        check("previews-animate", !moving.isEmpty && still.isEmpty,
              still.isEmpty ? "\(moving.count) live preview pads caught mid-flight (two samples differ): \(moving.keys.sorted().joined(separator: ", "))"
                            : "frozen: \(still.joined(separator: ", "))")
        await InspectorLab.close(editor)
        return result
    }

    /// Live previews seen (id → moved between two samples).
    private static var moving: [String: Bool] = [:]

    /// Samples every shown live preview twice, 0.3 s apart (the highlight
    /// dim is still on the Mac too).
    @available(iOS 26, *)
    private static func sampleMotion(_ editor: EditorViewController) async {
        let rows = shownRows(editor).compactMap { $0.1 as? InspectorLivePreviewRow }.filter { $0.rowID != "blocks.highlightPad" }
        guard !rows.isEmpty else { return }
        let first = rows.map(\.probeCardSignature)
        await InspectorLab.settle(0.3)
        for (row, a) in zip(rows, first) { moving[row.rowID] = (moving[row.rowID] ?? false) || a != row.probeCardSignature }
    }

    /// Every control a row draws, as inventory items (the live control's
    /// own title, range, readouts, items, colour, copy, pill or mode).
    @available(iOS 26, *)
    private static func items(of row: InspectorRowView, in pane: InspectorPaneView?) -> [EffectsParity.Item] {
        let section = pane?.sections.first { $0.view.rows.contains { $0 === row } }?.view.title ?? "-"
        var out: [EffectsParity.Item] = []
        func add(_ id: String?, _ kind: String, _ title: String, _ detail: String) {
            out.append(.init(section: section, id: id ?? "?", kind: kind, title: title, detail: detail))
        }
        func srgb(_ color: UIColor) -> String {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            let c = UIColor(cgColor: color.cgColor.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent,
                                                              options: nil) ?? color.cgColor)
            c.getRed(&r, green: &g, blue: &b, alpha: &a)
            return EffectsParity.colorDetail(r: Double(r), g: Double(g), b: Double(b), a: Double(a))
        }
        func visit(_ v: UIView) {
            guard !v.isHidden else { return }
            switch v {
            case let s as CCSlider:
                add(s.accessibilityIdentifier, "slider", s.title,
                    EffectsParity.sliderDetail(range: s.range, step: s.step, value: s.probeValueText,
                                               readout: { s.probeDisplayText(for: $0) }))
            case let t as CCToggleRow:
                add(t.accessibilityIdentifier, "toggle", t.probeTitle, "on=\(t.isOn)")
            case let c as CCChipGroup:
                add(c.accessibilityIdentifier, "chips", "",
                    EffectsParity.choiceDetail(id: c.accessibilityIdentifier ?? "?", items: c.items.map(\.title), selected: c.selection.min()))
            case let m as CCSelect:
                add(m.accessibilityIdentifier, "menu", m.prompt ?? "",
                    EffectsParity.choiceDetail(id: m.accessibilityIdentifier ?? "?", items: m.options, selected: m.selectedIndex))
            case let f as InspectorFeatureRowView:
                add(f.rowID, "feature", f.button.title, "")
            case let b as CCButton:
                add(b.accessibilityIdentifier, "button", b.title, "destructive=\(b.style == .destructive)")
            case let w as CCColorWell:
                add(w.accessibilityIdentifier, "color", w.title, srgb(w.color))
            case let c as InspectorCaptionRowView:
                add(c.rowID, "caption", "", EffectsParity.captionDetail(text: c.label.text ?? "", full: c.probeFull))
            case let p as InspectorPadRowView:
                add(p.rowID, "pad", p.probeTitle ?? "", "pill=\(p.pill?.text ?? "")")
            case let p as InspectorLivePreviewRow:
                add(p.rowID, "preview", "", p.probeMode?.probeDescription ?? "<none>")
            case let p as InspectorPreviewRow:
                add(p.rowID, "?static-preview", "", "")
            case let c as UIControl:
                add(c.accessibilityIdentifier, "?\(type(of: c))", "", "")
            case let l as UILabel:
                // Row titles of a form / control row are chrome; any other
                // copy is a control the Mac list must also have.
                if !(l.superview is CCFormRow || l.superview?.superview is CCFormRow || l.superview is CCControlRow
                     || l.superview?.superview is CCControlRow), !(l.text ?? "").isEmpty {
                    add("?label", "?UILabel", l.text ?? "", "")
                }
            default:
                for sub in v.subviews { visit(sub) }
            }
        }
        visit(row)
        return out
    }

    // MARK: - 2. Values

    @available(iOS 26, *)
    private static func values(lab: LabViewController) async -> [String] {
        guard let editor = await InspectorLab.openEditor("values", lab: lab, make: EffectsParity.makeProject) else {
            check("values-open", false, "could not open the fixture project")
            return []
        }
        let inspector = editor.inspector
        let project = editor.project
        let selection = editor.selection
        let phone = !editor.usesRegularLayout
        guard let undo = editor.undoManager else { check("values-undo", false, "no undo manager"); return [] }
        undo.removeAllActions()
        var tab = InspectorTab.effects
        var problems: [String] = []
        var checked = 0
        var lastSteps = inspector.session.registeredSteps
        // The masked snapshot can't see a replaced logo (a fresh name): its raw name.
        var logoName = project.settings.curtainLogoFileName
        func part(_ s: [String: String]) -> [String: String] { s.filter { $0.key != "selection" } }
        func snapshot() -> [String: String] { part(InspectorValuesTranscript.snapshot(project, selection: selection)) }

        /// A phone: shows the control `id` (opening the sub-option whose
        /// panel holds it); true when it is on screen or is a choice the bar
        /// offers as keys.
        func reveal(_ id: String) async -> Bool {
            if !phone {
                guard let pane = inspector.visiblePane, let view = InspectorLab.find(id, in: pane) else { return false }
                return InspectorLab.effectivelyVisible(view, in: pane)
            }
            await paneLevel(editor, tab)
            if choiceKeys(editor).contains(where: { $0.id == id }) { return true }
            func shown() -> Bool {
                if editor.isPanelOpen, inspector.headerToggleRow?.row.rowID == id { return true }
                guard let pane = inspector.visiblePane, let view = InspectorLab.find(id, in: pane) else { return false }
                return editor.isPanelOpen && shownRows(editor).contains { $0.1 === view || view.isDescendant(of: $0.1) }
            }
            if shown() { return true }
            for option in editor.toolBar.options {
                if option.choice != nil, !option.isCurrent { continue }
                await open(option, editor)
                if shown() { return true }
            }
            return false
        }

        let driver = InspectorValuesTranscript.Driver(
            showTab: { t in
                tab = t
                if phone { await paneLevel(editor, t) } else { selection.inspectorTab = t }
                await InspectorLab.settle(0.25)
            },
            select: { pick in
                editor.closePanel(animated: false)
                InspectorLab.apply(pick, to: selection)
                await InspectorLab.settle(0.35)
            },
            isVisible: { id in await reveal(id) },
            visibleIDs: { _ in [] },
            drive: { id, input in
                if phone, case .choose(let n) = input,
                   let key = choiceKeys(editor).first(where: { $0.id == id }) {
                    // A leading choice on a phone: its key.
                    let options = editor.toolBar.options.filter { $0.choice?.row == key.row }
                    guard options.indices.contains(n) else { return false }
                    if editor.isPanelOpen, editor.openOption?.id == options[n].id { return true }
                    await tap(editor.toolBar.key(for: .option(options[n].id)))
                    return true
                }
                // The feature's switch in a panel's title strip: tap IT.
                if phone, editor.isPanelOpen, inspector.headerToggleRow?.row.rowID == id, let pane = inspector.visiblePane {
                    return InspectorLab.drive(inspector.headerToggle, id: id, input: input, project: project, pane: pane)
                }
                guard let pane = inspector.visiblePane, let view = InspectorLab.find(id, in: pane) else { return false }
                return InspectorLab.drive(view, id: id, input: input, project: project, pane: pane)
            },
            settle: { await InspectorLab.settle(0.2) },
            afterStep: { step, before, after in
                let count = inspector.session.registeredSteps
                let delta = count - lastSteps
                lastSteps = count
                let label = InspectorValuesTranscript.describe(step)
                if case .select = step { return }
                checked += 1
                let logoBefore = logoName
                logoName = project.settings.curtainLogoFileName
                if part(before) != part(after) || logoBefore != logoName {
                    if delta != 1 { problems.append("\(label): \(delta) undo steps (want 1)") }
                    undo.undo()
                    await InspectorLab.settle(0.15)
                    if snapshot() != part(before) { problems.append("\(label): undo did not restore the project") }
                    undo.redo()
                    await InspectorLab.settle(0.15)
                    if snapshot() != part(after) { problems.append("\(label): redo did not restore the edit") }
                } else if delta != 0 {
                    problems.append("\(label): no change but \(delta) undo step(s)")
                }
            })
        let transcript = await InspectorValuesTranscript.run(project: project, selection: selection, driver: driver,
                                                             script: EffectsParity.valueSteps,
                                                             title: EffectsParity.valuesHeader)
        check("values-undo", problems.isEmpty,
              problems.isEmpty ? "\(checked) steps: each edit one undo step; undo / redo restore it exactly"
                               : problems.prefix(12).joined(separator: " | "))
        await InspectorLab.close(editor)
        return transcript
    }

    // MARK: - 3. Panels (a phone)

    private static var panelLabels: [String] = []
    private static var panelProblems: [String] = []
    private static var titleProblems: [String] = []
    private static var headerToggles = 0
    private static var barProblems: [String] = []
    private static var barsChecked = 0
    private static var barsFaded = 0

    /// The header switch as the inventory line its row would give (the
    /// live control's label and state, the row's id).
    @available(iOS 26, *)
    private static func headerToggleItems(_ editor: EditorViewController) -> [EffectsParity.Item] {
        guard let (_, row) = editor.inspector.headerToggleRow else { return [] }
        let pane = editor.inspector.visiblePane
        let section = pane?.sections.first { $0.view.rows.contains { $0 === row } }?.view.title ?? "-"
        let toggle = editor.inspector.headerToggle
        return [.init(section: section, id: row.spec.id, kind: "toggle", title: toggle.accessibilityLabel ?? "",
                      detail: "on=\(toggle.isOn)")]
    }

    /// The controls a row draws (leaf controls and copy).
    private static func controls(in view: UIView) -> [UIView] {
        guard !view.isHidden, view.alpha > 0.01 else { return [] }
        // A row's own sideways strip (subtitle presets) is one control: its
        // cards slide inside it by design.
        if view is UIControl || view is CCPadView || view is UIScrollView { return [view] }
        if let label = view as? UILabel { return (label.text ?? "").isEmpty ? [] : [label] }
        let inner = view.subviews.flatMap { controls(in: $0) }
        return inner.isEmpty && view is InspectorRowView ? [view] : inner
    }

    private static func fmt(_ r: CGRect) -> String {
        String(format: "(%.0f,%.0f %.0f×%.0f)", r.minX, r.minY, r.width, r.height)
    }

    private static func name(_ v: UIView) -> String {
        if let l = v as? UILabel { return "\"\(l.text ?? "")\"" }
        return v.accessibilityIdentifier ?? v.accessibilityLabel ?? String(describing: type(of: v))
    }

    /// The open panel shows every control fully, above the bar, without
    /// scrolling; its first row never repeats its title as a toggle.
    @available(iOS 26, *)
    private static func checkPanel(_ editor: EditorViewController, label: String) async {
        guard editor.isPanelOpen, editor.inspector.presentation == .bottomPanel else { return }
        // The panel's growth (0.42 s on the bounce) has landed.
        await InspectorLab.settle(0.3)
        let inspector = editor.inspector
        inspector.view.layoutIfNeeded()
        panelLabels.append(label)
        func w(_ v: UIView) -> CGRect { v.convert(v.bounds, to: nil) }
        let panel = w(inspector.view)
        let scroll = inspector.scroll
        let visible = w(scroll).intersection(panel)
        let barTop = w(editor.toolBar.probeGlass).minY
        var bad: [String] = []
        let rowsHeight = scroll.contentSize.height + scroll.adjustedContentInset.top + scroll.adjustedContentInset.bottom
        let rows = shownRows(editor)
        if !rows.isEmpty, rowsHeight > scroll.bounds.height + 0.5 {
            bad.append(String(format: "rows %.0f pt in a %.0f pt viewport (they scroll)", rowsHeight, scroll.bounds.height))
        }
        if abs(scroll.contentOffset.y + scroll.adjustedContentInset.top) > 0.5 {
            bad.append(String(format: "scrolled to %.0f", scroll.contentOffset.y))
        }
        for (_, row) in rows {
            for c in controls(in: row) {
                let f = w(c)
                if !visible.insetBy(dx: -0.5, dy: -0.5).contains(f) || f.maxY > barTop + 0.5 {
                    bad.append("\(name(c)) \(fmt(f)) not inside \(fmt(visible)) above the bar (\(Int(barTop)))")
                }
            }
        }
        let strip = w(inspector.strip)
        if !inspector.headerToggle.isHidden {
            let f = w(inspector.headerToggle)
            if !strip.insetBy(dx: -0.5, dy: -0.5).contains(f) { bad.append("header switch \(fmt(f)) outside the strip \(fmt(strip))") }
        }
        if !bad.isEmpty, let pane = inspector.visiblePane {
            let est = rows.map { String(format: "%@ %.0f/%.0f", $0.1.rowID, $0.1.bounds.height, pane.fittingHeight($0.0)) }
            log("EFFECTS-PARITY panel-rows \(label): actual/estimate \(est.joined(separator: ", "))")
        }
        if !bad.isEmpty {
            panelProblems.append("\(label): " + bad.prefix(3).joined(separator: "; "))
            log(String(format: "EFFECTS-PARITY panel-problem %@: panel %.0f (fits %.0f, cap %.0f): %@", label,
                       panel.height, inspector.panelFittingHeight, editor.panelCap(), bad.joined(separator: "; ")))
        }

        // The title strip carries the feature's switch; the rows never repeat it.
        let title = inspector.panelTitle.text ?? ""
        if let first = shownRows(editor).first(where: { !StudioInspectorController.isDecoration($0.1) })?.1 as? InspectorToggleRowView,
           StudioInspectorController.sameTitle(first.spec.title, title) {
            titleProblems.append("\(label): title \"\(title)\" over a \"\(first.spec.title)\" toggle row")
        }
        if !inspector.headerToggle.isHidden {
            headerToggles += 1
            let t = inspector.headerToggle
            let row = inspector.headerToggleRow?.row
            let oneRow = abs(w(t).midY - w(inspector.panelTitle).midY) < 2
            let voiceOver = t.isAccessibilityElement && t.accessibilityTraits.contains(.toggleButton)
                && t.accessibilityLabel == row?.spec.title && (t.accessibilityValue == (t.isOn ? "On" : "Off"))
            let scope = inspector.scope
            let same = row.map { t.isOn == $0.spec.read(scope) && t.isEnabled == $0.spec.enabled(scope) } ?? false
            if !oneRow || !voiceOver || !same || row.map({ !StudioInspectorController.sameTitle($0.spec.title, title) }) ?? true {
                titleProblems.append("\(label): header switch one row \(oneRow), VoiceOver switch \"\(t.accessibilityLabel ?? "")\" \(voiceOver), in step with its row \(same)")
            }
        }
    }

    /// At rest the bar's capsule never cuts a key glyph at its edge; a level
    /// that overflows fades on the side with more.
    @available(iOS 26, *)
    private static func checkBar(_ editor: EditorViewController, label: String) async {
        // At rest: the capsule's morph (0.42 s on the bounce) has landed.
        await InspectorLab.settle(0.25)
        let bar = editor.toolBar
        bar.layoutIfNeeded()
        barsChecked += 1
        let (viewport, glyphs) = bar.probeGlyphs
        let scroll = bar.probeScroll
        var bad: [String] = []
        if abs(scroll.contentOffset.x) > 0.5 { bad.append(String(format: "not at rest (offset %.0f)", scroll.contentOffset.x)) }
        for g in glyphs where g.frame.intersects(viewport) && !viewport.insetBy(dx: -0.5, dy: -0.5).contains(g.frame) {
            bad.append("\(g.key) glyph \(fmt(g.frame)) cut by the edge of \(fmt(viewport))")
        }
        let overflows = scroll.contentSize.width > scroll.bounds.width + 0.5
        if overflows {
            if let mask = bar.probeFadeMask, let colors = mask.colors as? [CGColor], colors.count == 4,
               colors[3].alpha < 0.5, colors[0].alpha > 0.99 {
                barsFaded += 1
            } else {
                bad.append("overflows (\(Int(scroll.contentSize.width)) in \(Int(scroll.bounds.width))) with no trailing fade")
            }
        }
        if !bad.isEmpty {
            barProblems.append("\(label): " + bad.prefix(3).joined(separator: "; "))
            log("EFFECTS-PARITY bar-problem \(label): \(bad.joined(separator: "; "))")
        }
    }

    /// Every sub-option of EVERY pane, fixture reset (the states only reach
    /// Effects and Motion): each panel must fit; each pane level's bar must
    /// rest on whole keys.
    @available(iOS 26, *)
    private static func sweepPanes(_ editor: EditorViewController, folder: URL) async {
        editor.closePanel(animated: false)
        await tap(editor.toolBar.key(for: .back))
        EffectsParity.reset(editor.project, folder: folder)
        editor.selection.selectedZoomID = nil
        await InspectorLab.settle(0.4)
        for tab in InspectorTab.allCases {
            await paneLevel(editor, tab)
            guard case .pane(let shown) = editor.toolBar.mode, shown == tab else { continue }
            await checkBar(editor, label: "sweep [\(tab.rawValue)]")
            let ids = editor.toolBar.options.map(\.id)
            for id in ids {
                guard let option = editor.toolBar.options.first(where: { $0.id == id }) else { continue }
                await open(option, editor)
                await checkPanel(editor, label: "sweep \(tab.rawValue) ▸ \(option.title)")
                if shots, editor.isPanelOpen {
                    snap(editor, name: "sweep-\(slug(tab.rawValue))-\(slug(option.title))")
                }
            }
            editor.closePanel(animated: false)
            await tap(editor.toolBar.key(for: .back))
        }
    }

    // MARK: - Helpers

    private static func slug(_ s: String) -> String {
        String(s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }).replacingOccurrences(of: "--", with: "-")
    }

    @available(iOS 26, *)
    private static func snap(_ editor: EditorViewController, name: String) {
        guard let window = editor.view.window else { return }
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try? image.pngData()?.write(to: out.appendingPathComponent("shots/\(name).png"))
    }

    private static func log(_ line: String) {
        print(line)
        lines.append(line)
    }

    private static func check(_ name: String, _ pass: Bool, _ detail: String) {
        if !pass { failures += 1 }
        log("EFFECTS-PARITY \(name) \(pass ? "PASS" : "FAIL") \(detail)")
    }
}
