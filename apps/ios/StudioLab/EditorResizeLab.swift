import UIKit

/// `--editor-resize <outDir> [--inject ignores-size-class]` — the editor
/// folding and unfolding, as on iPhone Duo (outer display: compact width;
/// inner display: regular width), in the real window chain.
///
/// The editor is hosted at the outer display's size and size classes, given
/// state (a playhead, a selection, an edit on the undo stack, playback
/// running), then resized live to the inner display and back. Each step
/// checks the layout the size classes call for (the editor redesign: stacked
/// with the tool bar along the bottom and panes as panels when compact; an
/// inspector column beside the stage with the tool bar's action row under the
/// timeline when regular; a tool rail and side panel on its side), the ONE
/// transport row, the timeline's playhead centred in its viewport, a pane
/// tool opening its panel caught MID-FLIGHT (never over the stage),
/// that every region stays inside the editor and clear of the others, that
/// History would open in the matching style, and that nothing was lost:
/// project, selection, undo stack, and playback still running and advancing.
/// `--inject ignores-size-class` pins the editor to its compact layout: the
/// unfold checks must then FAIL (proof the gate can see a missed resize);
/// `--inject snap-panel` snaps the panels open: the mid-flight checks FAIL.
///
/// Unfolded, the inner display has a crease (a `.division` reserved region).
/// The simulator can only fold from its window's hardware menu, so the gate
/// puts a crease on the unfolded editor through `FoldingDisplay`'s seam —
/// top to bottom, then side to side — and checks that nothing straddles it:
/// stage and transport on one side, timeline and inspector on the other,
/// the header title off it, state kept. `--inject ignores-crease` makes the
/// editor ignore the crease: those checks must then FAIL.
@MainActor
enum EditorResizeLab {
    private static var lines: [String] = []
    private static var failures = 0
    private static var out: URL!

    /// The two iPhone Duo displays, as hosted sizes + size classes.
    private struct Display {
        let name: String
        let size: CGSize
        let horizontal: UIUserInterfaceSizeClass
        let vertical: UIUserInterfaceSizeClass
    }

    static func start(_ arguments: [String], lab: LabViewController) -> Bool {
        guard let i = arguments.firstIndex(of: "--editor-resize"), arguments.indices.contains(i + 1) else { return false }
        out = URL(fileURLWithPath: arguments[i + 1], isDirectory: true)
        let inject = arguments.firstIndex(of: "--inject").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        lab.stage.isHidden = true
        guard #available(iOS 26, *) else {
            print("EDITOR-RESIZE FAIL the studio needs iOS 26")
            exit(1)
        }
        Task { @MainActor in await run(lab: lab, inject: inject) }
        return true
    }

    @available(iOS 26, *)
    private static func run(lab: LabViewController, inject: String?) async {
        setbuf(stdout, nil)
        UIApplication.shared.isIdleTimerDisabled = true
        let fm = FileManager.default
        try? fm.removeItem(at: out)
        try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        log("EDITOR-RESIZE out=\(out.path) device=\(UIDevice.current.model) \(UIDevice.current.systemVersion)")
        if let inject {
            guard ["ignores-size-class", "ignores-crease", "snap-panel", "panel-over-toolbar", "panel-uncapped",
                   "bar-snap", "no-back", "panel-card", "card-in-card", "stage-card", "keys-block-drag",
                   "flat-chrome", "glass-ignores-reduce-transparency", "glass-no-contrast-border",
                   "glass-on-content"].contains(inject) else {
                log("EDITOR-RESIZE FAIL unknown --inject \(inject)"); exit(1)
            }
            log("EDITOR-RESIZE inject=\(inject)")
            #if DEBUG
            if inject == "keys-block-drag" { CCScrollView.probeKeysBlockDrag = true }
            else if inject == "flat-chrome" { CCGlassView.probeFlat = true }
            else if inject == "glass-ignores-reduce-transparency" { CCGlassView.probeIgnoresReduceTransparency = true }
            else if inject == "glass-no-contrast-border" { CCGlassView.probeNoContrastBorder = true }
            else if inject == "glass-on-content" { EditorStageCardView.probeGlassStage = true }
            else if inject == "bar-snap" { EditorToolBar.probeSnapLevels = true }
            else if inject == "no-back" { EditorToolBar.probeNoBack = true }
            else if inject == "panel-card" { StudioInspectorController.probePanelCard = true }
            else if inject == "card-in-card" { InspectorSectionView.probeBoxedSections = true }
            else if inject == "stage-card" { EditorStageCardView.probeCard = true; EditorViewController.probeInsetStage = true }
            else if inject == "panel-over-toolbar" { EditorViewController.probePanelDefect = .overToolBar }
            else if inject == "panel-uncapped" { EditorViewController.probePanelDefect = .uncapped }
            else if inject == "snap-panel" { EditorViewController.probeSnapPanel = true } else {
                EditorViewController.probeDefect = inject == "ignores-crease" ? .ignoresCrease : .ignoresSizeClass
            }
            #endif
        }

        // The host: a container whose size and size classes we set, the
        // editor a child pinned to it (trait overrides flow to the child).
        let available = lab.view.bounds.size
        let height = min(780, available.height - 40)
        let outer = Display(name: "outer", size: CGSize(width: 390, height: height), horizontal: .compact, vertical: .regular)
        let inner = Display(name: "inner", size: CGSize(width: min(1000, available.width - 40), height: height),
                            horizontal: .regular, vertical: .regular)

        guard let editor = await openEditor() else { finish(); return }
        let host = UIViewController()
        host.modalPresentationStyle = .fullScreen
        host.view.backgroundColor = .black
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.clipsToBounds = true
        host.view.addSubview(container)
        let width = container.widthAnchor.constraint(equalToConstant: outer.size.width)
        let containerHeight = container.heightAnchor.constraint(equalToConstant: outer.size.height)
        NSLayoutConstraint.activate([
            container.centerXAnchor.constraint(equalTo: host.view.centerXAnchor),
            container.centerYAnchor.constraint(equalTo: host.view.centerYAnchor),
            width, containerHeight,
        ])
        apply(outer, to: host)
        host.addChild(editor)
        editor.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(editor.view)
        NSLayoutConstraint.activate([
            editor.view.topAnchor.constraint(equalTo: container.topAnchor),
            editor.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            editor.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            editor.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        editor.didMove(toParent: host)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lab.present(host, animated: false) { c.resume() }
        }
        await settle(1.0)

        // Folded: the outer display.
        checkLayout(editor, display: outer)
        checkSlidable(editor, tag: "outer")
        await checkPanel(editor, tag: "outer", injected: inject == "snap-panel")

        // State: a playhead, a selection, one edit on the undo stack, playing.
        let project = editor.project
        editor.playback.scrub(to: project.effectiveTrimStart + 2.0, for: project, exact: true)
        if let first = project.annotations.first { editor.selection.selectedAnnotationID = first.id }
        let selectedID = editor.selection.selectedAnnotationID
        let blurCount = project.blurRegions.count
        editor.timelineEdits.createBlurRegion(rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1), style: .blur)
        check("edit-registered", project.blurRegions.count == blurCount + 1 && (editor.undoManager?.canUndo ?? false),
              "blur regions \(blurCount) → \(project.blurRegions.count), canUndo=\(editor.undoManager?.canUndo ?? false)")
        let snapshot = encoded(project)
        await settle(0.3)
        editor.playback.setPlaying(true, for: project)
        await settle(0.8)
        let playheadBeforeUnfold = editor.playback.currentTime

        // Unfold: the inner display, mid-playback.
        width.constant = inner.size.width
        containerHeight.constant = inner.size.height
        apply(inner, to: host)
        await settle(1.0)
        checkLayout(editor, display: inner)
        checkState(editor, snapshot: snapshot, selectedID: selectedID, after: playheadBeforeUnfold, step: "unfold")
        await checkBarMorph(editor, tag: "inner", selectedID: selectedID)

        // The crease, top to bottom (the book posture), then side to side.
        for vertical in [true, false] {
            let tag = vertical ? "crease-vertical" : "crease-horizontal"
            let before = editor.playback.currentTime
            FoldingDisplay.creaseOverride = { v in
                vertical ? CGRect(x: v.bounds.midX - 12, y: 0, width: 24, height: v.bounds.height)
                         : CGRect(x: 0, y: v.bounds.midY - 12, width: v.bounds.width, height: 24)
            }
            editor.view.setNeedsLayout()
            await settle(1.0)
            checkCrease(editor, vertical: vertical, tag: tag)
            checkState(editor, snapshot: snapshot, selectedID: selectedID, after: before, step: tag)
        }
        FoldingDisplay.creaseOverride = nil
        editor.view.setNeedsLayout()
        await settle(1.0)
        checkLayout(editor, display: inner)
        let playheadBeforeFold = editor.playback.currentTime

        // Fold again.
        width.constant = outer.size.width
        containerHeight.constant = outer.size.height
        apply(outer, to: host)
        await settle(1.0)
        checkLayout(editor, display: outer)
        checkState(editor, snapshot: snapshot, selectedID: selectedID, after: playheadBeforeFold, step: "fold")

        // On its side: compact height (a landscape phone) — the tool rail
        // and the side panel, mid-playback.
        let landscape = Display(name: "landscape", size: CGSize(width: min(844, available.width - 40), height: 390),
                                horizontal: .compact, vertical: .compact)
        let beforeTurn = editor.playback.currentTime
        width.constant = landscape.size.width
        containerHeight.constant = landscape.size.height
        apply(landscape, to: host)
        await settle(1.0)
        checkLayout(editor, display: landscape)
        checkState(editor, snapshot: snapshot, selectedID: selectedID, after: beforeTurn, step: "landscape")
        // The context keys show for the selection; ‹ clears it, the tools come back.
        if let back = editor.toolBar.key(for: .back) { back.sendActions(for: .touchUpInside) }
        await settle(0.5)
        check("landscape-back-clears", editor.toolBar.mode == .tools && !editor.timeline.hasTimelineSelection,
              "‹ → tools (\(editor.toolBar.probeTitles.prefix(4).joined(separator: " · ")) …)")
        await checkPanel(editor, tag: "landscape", injected: inject == "snap-panel")
        editor.selection.selectedAnnotationID = selectedID
        width.constant = outer.size.width
        containerHeight.constant = outer.size.height
        apply(outer, to: host)
        await settle(1.0)
        checkLayout(editor, display: outer)

        // The edit made before the folds still undoes.
        editor.playback.setPlaying(false, for: project)
        editor.performUndo()
        check("undo-after-folds", project.blurRegions.count == blurCount,
              "blur regions after undo \(project.blurRegions.count) (want \(blurCount))")

        editor.playback.teardown()
        finish()
    }

    // MARK: - Checks

    /// The key rows slide under a finger that lands ON a key: the bottom tool
    /// bar and the timeline's toolbar row are `CCScrollView`s whose drag wins
    /// over a key (a stock scroll view never takes a touch back from a
    /// `UIControl`, so a row of keys could not be slid at all), while the
    /// zoom slider keeps its own drag. `--inject keys-block-drag` turns it red.
    @available(iOS 26, *)
    private static func checkSlidable(_ editor: EditorViewController, tag: String) {
        func controls(in v: UIView) -> [UIView] {
            v.subviews.flatMap { ($0 is UIControl ? [$0] : []) + controls(in: $0) }
        }
        for (name, scroll) in [("tool-bar", editor.toolBar.probeScroll),
                               ("toolbar-row", editor.timeline.probeToolbarScroll)] {
            let all = controls(in: scroll).filter { !$0.isHidden && $0.window != nil }
            let keys = all.filter { $0 is CCButton || $0 is CCIconRailKey }
            let sliders = all.filter { $0 is CCSlider || $0 is UISlider }
            let keysYield = !keys.isEmpty && keys.allSatisfy { scroll.touchesShouldCancel(in: $0) }
            let slidersKeep = sliders.allSatisfy { !scroll.touchesShouldCancel(in: $0) }
            check("\(tag)-\(name)-slides", scroll is CCScrollView && scroll.canCancelContentTouches
                    && keysYield && slidersKeep,
                  "\(type(of: scroll)) keys=\(keys.count) yield=\(keysYield) sliders=\(sliders.count) keep=\(slidersKeep) content=\(Int(scroll.contentSize.width))/\(Int(scroll.bounds.width))")
        }
    }

    @available(iOS 26, *)
    private static func checkLayout(_ editor: EditorViewController, display: Display) {
        let tag = display.name
        let wantRegular = display.horizontal == .regular && display.vertical == .regular
        let wantLandscape = display.vertical == .compact
        check("\(tag)-size-class", editor.usesRegularLayout == wantRegular,
              "usesRegularLayout=\(editor.usesRegularLayout) for \(display.horizontal == .regular ? "regular" : "compact") width")
        let want: EditorViewController.Arrangement = wantRegular ? .sideBySide : wantLandscape ? .landscapeCompact : .stacked
        check("\(tag)-arrangement", editor.activeArrangement == want,
              "arrangement \(editor.activeArrangement?.rawValue ?? "nil") (want \(want.rawValue))")
        let root = editor.view!
        let bounds = root.bounds
        func frame(_ v: UIView) -> CGRect { root.convert(v.bounds, from: v) }
        let header = frame(editor.header)
        let stage = frame(editor.stageCard), transport = frame(editor.transport)
        let timeline = frame(editor.timelineContainer), inspector = frame(editor.inspectorContainer)
        let tools = frame(editor.toolBar)
        var regions = ["stage": stage, "transport": transport, "timeline": timeline, "toolbar": tools]
        if wantRegular { regions["inspector"] = inspector }
        for (name, r) in regions.sorted(by: { $0.key < $1.key }) {
            let inside = bounds.insetBy(dx: -0.5, dy: -0.5).contains(r) && r.width > 1 && r.height > 1
            check("\(tag)-\(name)-inside", inside, "\(name) \(fmt(r)) in \(fmt(bounds))")
        }
        // The Mac's toolbar row heads the timeline region: transport, time,
        // undo / redo and the edit keys, straight under the stage.
        let row = editor.transport
        check("\(tag)-transport-row", abs(transport.height - EditorTransportBar.height) < 0.5 && abs(transport.width - stage.width) < 1
                && abs(transport.minY - stage.maxY) < 0.5
                && !row.playButton.isHidden && !row.playhead.isHidden && row.undoButton.window != nil && row.redoButton.window != nil
                && row.splitButton.window != nil && row.scaleSlider.window != nil,
              "toolbar row \(fmt(transport)) under the stage, as wide as it, with ⏮ ▶ ⏭ · time · undo/redo · edit keys · zoom")
        // Flat: the stage is no card (no corners, no border).
        check("\(tag)-stage-flat", editor.stageCard.layer.cornerRadius < 0.5 && editor.stageCard.layer.borderWidth == 0
                && editor.timeline.view.layer.cornerRadius < 0.5 && editor.timeline.view.layer.borderWidth == 0,
              String(format: "stage radius %.0f border %.1f; lanes radius %.0f", editor.stageCard.layer.cornerRadius,
                     editor.stageCard.layer.borderWidth, editor.timeline.view.layer.cornerRadius))
        // The timeline's playhead: fixed at its viewport's centre, the
        // playhead's time under it (playing or not).
        let tl = editor.timeline
        let marker = tl.centrePlayhead.centreX(in: root)
        let viewport = tl.scrollView.convert(tl.scrollView.bounds, to: root)
        check("\(tag)-centred-playhead", abs(marker - viewport.midX) < 0.75 && abs(tl.playheadOffsetFromCentre) < 1,
              String(format: "marker x %.1f, viewport centre %.1f (%@); playhead %.2f pt from it",
                     marker, viewport.midX, fmt(viewport), tl.playheadOffsetFromCentre))
        if wantRegular {
            // The inspector column beside the stage and timeline; the tool
            // bar's action row under the timeline, no pane tools (the
            // column's rail has them).
            check("\(tag)-inspector-column", abs(inspector.width - 340) < 1 && inspector.minX >= stage.maxX - 0.5
                  && inspector.minX >= timeline.maxX - 0.5 && editor.inspector.presentation == .column,
                  "inspector \(fmt(inspector)), stage \(fmt(stage)), timeline \(fmt(timeline))")
            check("\(tag)-timeline-height", timeline.height >= 219.5, "timeline height \(Int(timeline.height)) (want ≥ 220)")
            check("\(tag)-action-row", tools.minY >= timeline.maxY - 0.5 && abs(tools.width - timeline.width) < 1
                    && !editor.toolBar.showsPaneTools && tools.maxX <= inspector.minX + 0.5,
                  "tool bar \(fmt(tools)) under the timeline \(fmt(timeline)); keys \(editor.toolBar.probeTitles)")
        } else if wantLandscape {
            // A rail down the trailing edge under the header; the stage,
            // transport and timeline in the column beside it.
            check("\(tag)-tool-rail", editor.toolBar.axis == .vertical && abs(tools.maxX - bounds.maxX) < 0.5
                    && tools.minY >= header.maxY - 0.5 && abs(tools.maxY - bounds.maxY) < 0.5
                    && stage.maxX <= tools.minX + 0.5 && timeline.maxX <= tools.minX + 0.5 && editor.toolBar.showsPaneTools,
                  "rail \(fmt(tools)); stage \(fmt(stage)) timeline \(fmt(timeline))")
            check("\(tag)-column", stage.maxY <= transport.minY + 0.5 && transport.maxY <= timeline.minY + 0.5,
                  "stage \(fmt(stage)) transport \(fmt(transport)) timeline \(fmt(timeline))")
        } else {
            // Stacked: stage, transport, timeline, then the tool bar docked
            // to the screen's bottom edge; the stage keeps its share.
            check("\(tag)-stacked", stage.maxY <= transport.minY + 0.5 && transport.maxY <= timeline.minY + 0.5
                  && timeline.maxY <= tools.minY + 0.5,
                  "stage \(fmt(stage)) transport \(fmt(transport)) timeline \(fmt(timeline)) tool bar \(fmt(tools))")
            // Edge to edge: stage, toolbar row and timeline span the width.
            check("\(tag)-full-width", abs(stage.minX) < 0.5 && abs(stage.width - bounds.width) < 0.5
                    && abs(timeline.minX) < 0.5 && abs(timeline.width - bounds.width) < 0.5 && abs(transport.width - bounds.width) < 0.5,
                  "stage \(fmt(stage)), timeline \(fmt(timeline)) across \(Int(bounds.width)) pt")
            // The stage is the canvas at the full width (capped so a panel fits).
            let wantH = editor.stackedStageHeight()
            let canvasH = (bounds.width / editor.canvasAspect).rounded()
            check("\(tag)-stage-aspect", abs(stage.height - wantH) < 1 && (abs(stage.height - canvasH) < 1 || stage.height < canvasH),
                  String(format: "stage %.0f pt high (canvas at full width %.0f; aspect %.3f)", stage.height, canvasH, editor.canvasAspect))
            // Tools: every pane; with a selection: its context keys after ‹.
            let keys = editor.toolBar.probeTitles
            let keysOK: Bool
            switch editor.toolBar.mode {
            case .tools: keysOK = InspectorTab.allCases.allSatisfy { keys.contains($0.rawValue) }
            case .context: keysOK = keys.first == "Back" && keys.contains("Split") && keys.contains("Delete")
            default: keysOK = keys.first == "Back"
            }
            check("\(tag)-tool-bar", abs(tools.maxY - bounds.maxY) < 0.5 && abs(tools.width - bounds.width) < 0.5
                    && editor.toolBar.axis == .horizontal && keysOK
                    && editor.inspector.view.isHidden == !editor.isPanelOpen,
                  "tool bar \(fmt(tools)) to the screen's bottom edge; keys \(keys.joined(separator: " · "))")
        }
        checkGlass(editor, tag: tag)
        let history = HistoryPresentation.style(for: editor)
        check("\(tag)-history-style", (history == .sidePanel) == wantRegular, "History would open as \(history)")
        log("EDITOR-RESIZE \(tag) layout stage=\(fmt(stage)) transport=\(fmt(transport)) timeline=\(fmt(timeline)) toolBar=\(fmt(tools)) inspector=\(fmt(inspector))")
    }

    /// The drill-down bar and its SHORT panels, driven through the keys' own
    /// actions: a pane tool swaps the bar to that pane's sub-options (the
    /// swap caught MID-FLIGHT, ‹ first); a sub-option opens a short panel
    /// above the bar — growing mid-flight, one small group of controls, ≤ 30%
    /// of the height, flat (only its top corners rounded, full width, no card
    /// inside it), never over the stage or the toolbar row (every sample),
    /// the stage never resized, the lanes still showing; a choice applies
    /// through the shared spec; ✓ closes it; ‹ returns to the root tools
    /// (mid-flight). Landscape: a side panel between the column and the rail.
    @available(iOS 26, *)
    private static func checkPanel(_ editor: EditorViewController, tag: String, injected: Bool) async {
        let root = editor.view!
        func frame(_ v: UIView) -> CGRect { root.convert(v.bounds, from: v) }
        let panel = editor.inspector.view!
        let inspector = editor.inspector
        let bar = editor.toolBar
        guard let key = bar.key(for: .pane(.background)) else {
            check("\(tag)-panel-tool", false, "no Background tool (\(bar.probeTitles))"); return
        }
        let side = inspector.presentation == .sidePanel
        let stageBefore = frame(editor.stageCard)
        let transport = frame(editor.transport)
        let timelineTop = frame(editor.timelineContainer).minY

        // 1. The pane tool: the bar drills into its sub-options, mid-flight.
        func sampleLevel(_ seconds: Double) async -> Int {
            var mid = 0
            let t0 = CACurrentMediaTime()
            while CACurrentMediaTime() - t0 < seconds {
                let layer = bar.probeVisibleStack.layer
                let p = layer.presentation() ?? layer
                let tx = (p.value(forKeyPath: "transform.translation.x") as? CGFloat) ?? 0
                let ty = (p.value(forKeyPath: "transform.translation.y") as? CGFloat) ?? 0
                if (p.opacity > 0.05 && p.opacity < 0.95) || abs(tx) > 1 || abs(ty) > 1 { mid += 1 }
                await settle(0.012)
            }
            return mid
        }
        key.sendActions(for: .touchUpInside)
        let inMid = await sampleLevel(0.45)
        let titles = bar.probeTitles
        check("\(tag)-bar-level-midflight", inMid >= 2 && bar.mode == .pane(.background),
              "Background → its sub-options, \(inMid) samples of the swap mid-flight")
        check("\(tag)-bar-level", titles.first == "Back" && bar.key(for: .back)?.accessibilityLabel == "Back"
                && titles.contains("Gradient") && titles.contains("Blur") && !titles.contains("Cursor")
                && !editor.isPanelOpen,
              "keys: \(titles.prefix(9).joined(separator: " · ")) … (\(titles.count))")

        // 2. A slider sub-option (Look ▸ Blur): a SHORT panel of one group.
        guard let blurKey = bar.probeKey("Blur") else { check("\(tag)-panel-option", false, "no Blur key"); return }
        var edges: [CGFloat] = []
        var overlaps = 0, stageMoved = 0
        blurKey.sendActions(for: .touchUpInside)
        let t0 = CACurrentMediaTime()
        while CACurrentMediaTime() - t0 < 0.6 {
            let p = frame(panel), s = frame(editor.stageCard)
            edges.append(side ? p.minX : p.minY)
            let visible = side ? p.intersection(CGRect(x: 0, y: 0, width: frame(bar).minX, height: root.bounds.height)) : p
            if visible.intersects(s.insetBy(dx: 0.5, dy: 0.5)) { overlaps += 1 }
            if !side, visible.intersects(frame(editor.transport).insetBy(dx: 0.5, dy: 0.5)) { overlaps += 1 }
            if !side, s != stageBefore { stageMoved += 1 }
            await settle(0.016)
        }
        let final = frame(panel)
        let start = edges.first ?? 0, end = side ? final.minX : final.minY
        let mid = edges.filter { abs($0 - start) > 2 && abs($0 - end) > 2 }
        _ = injected  // `--inject snap-panel` makes this FAIL: the gate sees motion.
        let shownRows = inspector.visiblePane?.rows.filter { !$0.isHidden }.count ?? 0
        check("\(tag)-panel-open-midflight", mid.count >= 2 && editor.isPanelOpen && blurKey.isSelected,
              String(format: "Blur → %d of %d samples mid-flight (edge %.0f → %.0f)", mid.count, edges.count, start, end))
        check("\(tag)-panel-one-group", inspector.panelTitle.text == "Blur" && shownRows >= 1 && shownRows <= 3
                && !inspector.closeButton.isHidden && inspector.closeButton.accessibilityLabel == "Done",
              "title \"\(inspector.panelTitle.text ?? "")\", \(shownRows) rows, ✓ labelled \"\(inspector.closeButton.accessibilityLabel ?? "")\"")
        checkFlat(editor, tag: tag, side: side)
        checkGlass(editor, tag: "\(tag)-panel", panel: true)
        await checkGlassSettings(editor, tag: tag)
        if side {
            let stage = frame(editor.stageCard), rail = frame(bar)
            check("\(tag)-side-panel", final.minX >= stage.maxX - 0.5 && final.maxX <= rail.minX + 1 && overlaps == 0
                    && stage.width < stageBefore.width - 100,
                  String(format: "panel %@ between the stage %@ and the rail %@; stage %.0f → %.0f pt wide; %d overlapping samples",
                         fmt(final), fmt(stage), fmt(rail), stageBefore.width, stage.width, overlaps))
        } else {
            let tools = frame(bar)
            let lanes = frame(editor.timeline.view)
            let cap = root.bounds.height * EditorViewController.panelMaxShare
            check("\(tag)-panel-above-toolbar", final.maxY <= tools.minY + 0.5 && final.maxY >= tools.minY - 2
                    && !bar.isHidden && abs(tools.maxY - root.bounds.maxY) < 0.5,
                  String(format: "panel %@ ends at %.0f on the tool bar %@", fmt(final), final.maxY, fmt(tools)))
            check("\(tag)-panel-short", final.height <= cap + 0.5 && abs(final.height - editor.fittedPanelHeight()) < 1.5
                    && final.height <= 0.30 * root.bounds.height + 0.5,
                  String(format: "panel %.0f pt = %.0f%% of %.0f (fits %.0f, cap %.0f)", final.height,
                         final.height / root.bounds.height * 100, root.bounds.height, inspector.panelFittingHeight, editor.panelCap()))
            let highest = edges.min() ?? final.minY
            check("\(tag)-panel-preview-clear", overlaps == 0 && stageMoved == 0 && highest >= transport.maxY - 0.5,
                  String(format: "highest top %.0f vs the toolbar row's bottom %.0f; %d samples over stage/toolbar row; stage moved in %d",
                         highest, transport.maxY, overlaps, stageMoved))
            check("\(tag)-panel-timeline-visible", lanes.minY >= timelineTop - 0.5 && lanes.maxY <= final.minY + 0.5
                    && lanes.height >= EditorViewController.minTimelineStrip - 0.5 && !editor.timelineContainer.accessibilityElementsHidden,
                  String(format: "lanes %@ above the panel (≥ %.0f pt)", fmt(lanes), EditorViewController.minTimelineStrip))
        }

        // 3. A choice sub-option (Gradient): applied through the shared
        // spec; its panel shows the rest of its group, in place.
        editor.project.settings.backgroundType = .solid
        await settle(0.2)
        if let gradient = bar.probeKey("Gradient") {
            gradient.sendActions(for: .touchUpInside)
            await settle(0.6)
            check("\(tag)-choice-applies", editor.project.settings.backgroundType == .gradient && editor.isPanelOpen
                    && inspector.panelTitle.text == "Gradient" && (bar.probeKey("Gradient")?.isSelected ?? false),
                  "Gradient → type \(editor.project.settings.backgroundType.rawValue), panel \"\(inspector.panelTitle.text ?? "")\"")
            // One undo step (the shared session's), and it unwinds.
            editor.performUndo()
            await settle(0.2)
            check("\(tag)-choice-undoes", editor.project.settings.backgroundType == .solid,
                  "undo → type \(editor.project.settings.backgroundType.rawValue) (want Solid Color)")
        } else {
            check("\(tag)-choice-applies", false, "no Gradient key")
        }

        // 4. A whole pane opened programmatically is still capped (a pane
        // taller than the cap scrolls inside).
        if !side {
            editor.openPanel(.cursor, animated: false)
            await settle(0.3)
            let h = frame(panel).height
            check("\(tag)-panel-height-cap", h <= editor.panelCap() + 0.5 && h <= root.bounds.height * EditorViewController.panelMaxShare + 0.5,
                  String(format: "whole Cursor pane: panel %.0f pt, fits %.0f, cap %.0f", h, inspector.panelFittingHeight, editor.panelCap()))
            editor.closePanel(animated: false)
            await settle(0.2)
            bar.probeKey("Blur")?.sendActions(for: .touchUpInside)
            await settle(0.6)
        }

        // 5. ✓ closes it (mid-flight), the level stays.
        var closing: [CGFloat] = []
        inspector.closeButton.sendActions(for: .touchUpInside)
        let c0 = CACurrentMediaTime()
        while CACurrentMediaTime() - c0 < 0.45 {
            let p = frame(panel)
            closing.append(side ? p.minX : p.height)
            await settle(0.016)
        }
        await settle(0.3)
        let closeMid = closing.filter { abs($0 - (closing.first ?? 0)) > 2 && abs($0 - (closing.last ?? 0)) > 2 }
        check("\(tag)-panel-done-closes", !editor.isPanelOpen && panel.isHidden && closeMid.count >= 2 && bar.mode == .pane(.background)
                && abs(frame(editor.stageCard).width - stageBefore.width) < 0.5,
              "✓ → closed, \(closeMid.count) samples mid-flight; bar still on Background")

        // 6. ‹ back to the root tools (mid-flight).
        bar.key(for: .back)?.sendActions(for: .touchUpInside)
        let backMid = await sampleLevel(0.45)
        let rootKeys = bar.probeTitles
        check("\(tag)-back-to-root", bar.mode == .tools && backMid >= 2 && InspectorTab.allCases.allSatisfy { rootKeys.contains($0.rawValue) },
              "‹ → \(rootKeys.prefix(4).joined(separator: " · ")) …, \(backMid) samples mid-flight")
    }

    /// The flat look: the stage edge to edge with no rounded card; the
    /// timeline region one full-width surface; the open panel full width
    /// with ONLY its top corners rounded (none for a side panel), no border,
    /// and NO rounded container nested inside it (sections are flat groups).
    @available(iOS 26, *)
    private static func checkFlat(_ editor: EditorViewController, tag: String, side: Bool) {
        let root = editor.view!
        func frame(_ v: UIView) -> CGRect { root.convert(v.bounds, from: v) }
        let surface = editor.inspector.surface
        let p = frame(editor.inspector.view)
        let topOnly: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        let shapeOK = side
            ? surface.layer.cornerRadius < 0.5 && surface.layer.borderWidth == 0
            : surface.layer.cornerRadius > 0.5 && surface.layer.maskedCorners == topOnly && surface.layer.borderWidth == 0
                && abs(p.minX) < 0.5 && abs(p.width - root.bounds.width) < 0.5
        check("\(tag)-panel-flat", shapeOK,
              String(format: "panel %@ radius %.0f corners %@ border %.1f", fmt(p), surface.layer.cornerRadius,
                     surface.layer.maskedCorners == topOnly ? "top-only" : "\(surface.layer.maskedCorners.rawValue)",
                     surface.layer.borderWidth))
        let nested = nestedCards(in: editor.inspector.view, root: editor.inspector.view)
        check("\(tag)-panel-no-card-in-card", nested.isEmpty,
              "\(nested.count) rounded containers inside the panel: \(nested.prefix(3).joined(separator: "; "))")
    }

    /// Rounded, filled (or bordered) containers inside `view` — cards — that
    /// are not controls or the house preview tile.
    static func nestedCards(in view: UIView, root: UIView) -> [String] {
        var out: [String] = []
        func walk(_ v: UIView) {
            guard !v.isHidden, v.alpha > 0.01 else { return }
            if v !== root, v is UIControl || v is CCPreviewPad { return }
            // The panel's own glass sheet IS the surface (its backdrop), not a card in it.
            if v === (root.next as? StudioInspectorController)?.panelGlass { v.subviews.forEach(walk); return }
            let r = v.convert(v.bounds, to: root)
            let filled = (v.backgroundColor.map { $0.cgColor.alpha > 0.01 } ?? false) || v.layer.borderWidth > 0
                || (v.layer.sublayers ?? []).contains { $0.name?.hasPrefix("ccmat") == true }
            if v !== root, v.layer.cornerRadius > 4, filled, r.width > 120, r.height > 40,
               v !== (root.next as? StudioInspectorController)?.surface {
                out.append("\(type(of: v)) \(fmt(r))")
            }
            v.subviews.forEach(walk)
        }
        walk(view)
        return out
    }

    // MARK: - Glass (Liquid Glass on the floating chrome only)

    /// The chrome's glass surfaces, as the app builds them.
    @available(iOS 26, *)
    private static func chromeGlass(_ editor: EditorViewController, panel: Bool) -> [(String, CCGlassView)] {
        var out: [(String, CCGlassView)] = [
            ("tool-bar", editor.toolBar.probeGlass), ("aspect", editor.aspectGlass), ("export", editor.exportGlass),
            ("toolbar-row", editor.transport.glass), ("zoom-chip", editor.stageCard.zoomPill.glass),
        ]
        if let back = editor.header.backGlass { out.append(("back", back)) }
        if panel { out += [("panel", editor.inspector.panelGlass), ("done", editor.inspector.doneGlass)] }
        return out
    }

    /// Structural: each floating surface's keys sit on a REAL `UIGlassEffect`
    /// view in the editor's own window chain (UIKit's view tree, not the
    /// kit's say-so); Export's glass is tinted; the content — stage, lanes,
    /// a panel's rows — is NOT glass and not on glass.
    @available(iOS 26, *)
    private static func checkGlass(_ editor: EditorViewController, tag: String, panel: Bool = false) {
        let window = editor.view.window
        func realGlass(_ v: UIView) -> UIGlassEffect? {
            guard let fx = v as? UIVisualEffectView, window != nil, fx.window === window, !fx.isHidden,
                  fx.bounds.width > 1, fx.bounds.height > 1 else { return nil }
            return fx.effect as? UIGlassEffect
        }
        /// `key` is on glass: an ancestor renders glass, or a glass view in
        /// an ancestor (z-order: under the key) covers the key's centre.
        func onGlass(_ key: UIView) -> Bool {
            guard key.window === window, !key.isHidden else { return false }
            if key.ccIsOnGlass { return true }
            let centre = key.convert(CGPoint(x: key.bounds.midX, y: key.bounds.midY), to: nil)
            var a: UIView? = key.superview
            var child: UIView = key
            while let host = a {
                let below = host.subviews.prefix { $0 !== child }
                for g in below where realGlass(g) != nil {
                    if g.convert(g.bounds, to: nil).contains(centre) { return true }
                }
                child = host
                a = host.superview
            }
            return false
        }
        var keys: [(String, UIView)] = [
            ("back", editor.header.backButton), ("aspect", editor.aspectChip), ("export", editor.exportButton),
            ("toolbar-row", editor.transport.playButton),
        ]
        // The zoom chip's keys (its glass sits under them, inside the chip).
        let pillKey = editor.stageCard.zoomPill.subviews.compactMap { $0 as? UIStackView }.first?.arrangedSubviews.first
        keys.append(("zoom-chip", pillKey ?? editor.stageCard.zoomPill))
        if let first = editor.toolBar.probeVisibleStack.subviews.first(where: { $0 is CCIconRailKey }) {
            keys.append(("tool-bar", first))
        }
        if panel { keys += [("done", editor.inspector.closeButton), ("panel-title", editor.inspector.panelTitle)] }
        let bare = keys.filter { !onGlass($0.1) }.map(\.0)
        let tinted = realGlass(editor.exportGlass)?.tintColor != nil
        check("\(tag)-chrome-glass", keys.count >= (panel ? 8 : 6) && bare.isEmpty && tinted,
              "\(keys.count - bare.count)/\(keys.count) floating keys on UIGlassEffect\(bare.isEmpty ? "" : " — bare: \(bare.joined(separator: ", "))"); Export tinted \(tinted)")
        // Content stays flat: no glass in it, nothing of it on glass.
        let pill = editor.stageCard.zoomPill
        let stageGlass = editor.stageCard.ccGlassEffectViews().filter { !$0.isDescendant(of: pill) }
        let laneGlass = editor.timeline.view.ccGlassEffectViews().filter { !$0.isHidden }
        var rowsGlass = 0, rowsOn = false
        if panel, let pane = editor.inspector.visiblePane {
            rowsGlass = pane.ccGlassEffectViews().count
            rowsOn = pane.ccIsOnGlass
        }
        let contentOK = stageGlass.isEmpty && !editor.stage.ccIsOnGlass && laneGlass.isEmpty
            && !editor.timeline.view.ccIsOnGlass && rowsGlass == 0 && !rowsOn
        check("\(tag)-content-flat", contentOK,
              "glass in stage \(stageGlass.count), lanes \(laneGlass.count), panel rows \(rowsGlass); on glass: stage \(editor.stage.ccIsOnGlass), lanes \(editor.timeline.view.ccIsOnGlass), rows \(rowsOn)")
    }

    /// Reduce Transparency puts the kit's OPAQUE material where the glass
    /// was (and back); Increase Contrast gives the glass a clear 1 pt edge.
    @available(iOS 26, *)
    private static func checkGlassSettings(_ editor: EditorViewController, tag: String) async {
        let surfaces = chromeGlass(editor, panel: true)
        func opaque(_ g: CCGlassView) -> Bool {
            guard g.effect == nil,
                  let base = g.layer.sublayers?.first(where: { $0.name == "ccmat.base" }) as? CAGradientLayer,
                  let colors = base.colors, !colors.isEmpty else { return false }
            let alphas = colors.map { ($0 as! CGColor).alpha }
            return alphas.allSatisfy { $0 > 0.99 } && base.frame.width > 1
        }
        CCAccessibility.forcedReduceTransparency = true
        await settle(0.3)
        let stillGlass = surfaces.filter { $0.1.effect is UIGlassEffect }.map(\.0)
        let notOpaque = surfaces.filter { !opaque($0.1) }.map(\.0)
        CCAccessibility.forcedReduceTransparency = nil
        await settle(0.3)
        let back = surfaces.filter { !($0.1.effect is UIGlassEffect) }.map(\.0)
        check("\(tag)-glass-reduce-transparency", stillGlass.isEmpty && notOpaque.isEmpty && back.isEmpty,
              "Reduce Transparency: \(surfaces.count - notOpaque.count)/\(surfaces.count) on the opaque kit material"
                + (stillGlass.isEmpty ? "" : "; still glass: \(stillGlass.joined(separator: ", "))")
                + (notOpaque.isEmpty ? "" : "; not opaque: \(notOpaque.joined(separator: ", "))")
                + "; off again → glass" + (back.isEmpty ? "" : " except \(back.joined(separator: ", "))"))
        CCAccessibility.forcedIncreaseContrast = true
        await settle(0.3)
        let thin = surfaces.filter { $0.1.probeEdgeWidth < 1 }.map(\.0)
        CCAccessibility.forcedIncreaseContrast = nil
        await settle(0.3)
        let lingering = surfaces.filter { $0.1.layer.borderWidth > 0 }.map(\.0)
        check("\(tag)-glass-increase-contrast", thin.isEmpty && lingering.isEmpty,
              "Increase Contrast: \(surfaces.count - thin.count)/\(surfaces.count) glass surfaces with a ≥ 1 pt edge"
                + (thin.isEmpty ? "" : "; none on \(thin.joined(separator: ", "))")
                + (lingering.isEmpty ? "" : "; border left on \(lingering.joined(separator: ", "))"))
    }

    /// The bar's glass MORPHS with its level: clearing the selection swaps
    /// the context keys for the (fewer) tools and the capsule's length is
    /// caught mid-flight between the two (`--inject bar-snap` snaps it).
    @available(iOS 26, *)
    private static func checkBarMorph(_ editor: EditorViewController, tag: String, selectedID: UUID?) async {
        let glass = editor.toolBar.probeGlass
        let axisLength = { editor.toolBar.axis == .horizontal ? glass.frame.width : glass.frame.height }
        let start = axisLength()
        // ‹ clears the selection (the context keys → the tools).
        editor.toolBar.key(for: .back)?.sendActions(for: .touchUpInside)
        var samples: [CGFloat] = []
        let t0 = CACurrentMediaTime()
        while CACurrentMediaTime() - t0 < 0.6 {
            samples.append(axisLength())
            await settle(0.012)
        }
        await settle(0.2)
        let end = axisLength()
        let mid = samples.filter { abs($0 - start) > 2 && abs($0 - end) > 2 }
        check("\(tag)-bar-morph-midflight", abs(end - start) > 20 && mid.count >= 2 && editor.toolBar.mode == .tools,
              String(format: "capsule %.0f → %.0f pt, %d of %d samples mid-flight; keys %@", start, end, mid.count, samples.count,
                     editor.toolBar.probeTitles.joined(separator: " · ")))
        editor.selection.selectedAnnotationID = selectedID
        await settle(0.6)
    }

    /// Nothing straddles the crease: stage + transport on one side, timeline
    /// over inspector on the other; the header title is off it.
    @available(iOS 26, *)
    private static func checkCrease(_ editor: EditorViewController, vertical: Bool, tag: String) {
        let want: EditorViewController.Arrangement = vertical ? .splitAtVerticalCrease : .splitAtHorizontalCrease
        check("\(tag)-arrangement", editor.activeArrangement == want,
              "arrangement \(editor.activeArrangement?.rawValue ?? "nil") (want \(want.rawValue))")
        let root = editor.view!
        let bounds = root.bounds
        let crease = vertical ? CGRect(x: bounds.midX - 12, y: 0, width: 24, height: bounds.height)
                              : CGRect(x: 0, y: bounds.midY - 12, width: bounds.width, height: 24)
        func frame(_ v: UIView) -> CGRect { root.convert(v.bounds, from: v) }
        let stage = frame(editor.stageCard), transport = frame(editor.transport)
        let timeline = frame(editor.timelineContainer), inspector = frame(editor.inspectorContainer)
        let title = frame(editor.header.probeTitleView)
        let tools = frame(editor.toolBar)
        let regions = ["stage": stage, "transport": transport, "timeline": timeline, "inspector": inspector, "toolbar": tools]
        for (name, r) in regions.sorted(by: { $0.key < $1.key }) {
            let inside = bounds.insetBy(dx: -0.5, dy: -0.5).contains(r) && r.width > 1 && r.height > 1
            check("\(tag)-\(name)-inside", inside, "\(name) \(fmt(r)) in \(fmt(bounds))")
            check("\(tag)-\(name)-off-crease", !r.insetBy(dx: 0.5, dy: 0.5).intersects(crease),
                  "\(name) \(fmt(r)) vs crease \(fmt(crease))")
        }
        if vertical {
            check("\(tag)-stage-side", stage.maxX <= crease.minX + 0.5 && transport.maxX <= crease.minX + 0.5,
                  "stage \(fmt(stage)) transport \(fmt(transport)) left of \(Int(crease.minX))")
            check("\(tag)-panel-side", timeline.minX >= crease.maxX - 0.5 && inspector.minX >= crease.maxX - 0.5
                    && tools.minX >= crease.maxX - 0.5,
                  "timeline \(fmt(timeline)) tool bar \(fmt(tools)) inspector \(fmt(inspector)) right of \(Int(crease.maxX))")
            check("\(tag)-stage-fills-half", stage.width >= crease.minX - 40,
                  "stage width \(Int(stage.width)) of a \(Int(crease.minX)) pt half")
        } else {
            check("\(tag)-stage-side", stage.maxY <= crease.minY + 0.5 && transport.maxY <= crease.minY + 0.5,
                  "stage \(fmt(stage)) transport \(fmt(transport)) above \(Int(crease.minY))")
            check("\(tag)-panel-side", timeline.minY >= crease.maxY - 0.5 && inspector.minY >= crease.maxY - 0.5
                    && tools.minY >= crease.maxY - 0.5,
                  "timeline \(fmt(timeline)) tool bar \(fmt(tools)) inspector \(fmt(inspector)) below \(Int(crease.maxY))")
        }
        check("\(tag)-centred-playhead", abs(editor.timeline.playheadOffsetFromCentre) < 1,
              String(format: "playhead %.2f pt from the timeline's centre", editor.timeline.playheadOffsetFromCentre))
        check("\(tag)-timeline-over-inspector", timeline.maxY <= tools.minY + 0.5 && tools.maxY <= inspector.minY + 0.5 && timeline.height >= 159.5
              && inspector.height >= 120, "timeline \(fmt(timeline)) inspector \(fmt(inspector))")
        check("\(tag)-title-off-crease", !title.isEmpty && !title.intersects(crease),
              "title \(fmt(title)) vs crease \(fmt(crease))")
        log("EDITOR-RESIZE \(tag) stage=\(fmt(stage)) timeline=\(fmt(timeline)) inspector=\(fmt(inspector)) title=\(fmt(title))")
    }

    @available(iOS 26, *)
    private static func checkState(_ editor: EditorViewController, snapshot: String, selectedID: UUID?,
                                   after playhead: TimeInterval, step: String) {
        check("\(step)-project-kept", encoded(editor.project) == snapshot, "project unchanged by the resize")
        check("\(step)-selection-kept", editor.selection.selectedAnnotationID == selectedID,
              "selection \(String(describing: editor.selection.selectedAnnotationID)) (want \(String(describing: selectedID)))")
        check("\(step)-undo-kept", editor.undoManager?.canUndo ?? false, "the pre-fold edit is still on the undo stack")
        check("\(step)-still-playing", editor.playback.isPlaying && editor.playback.currentTime > playhead + 0.2,
              String(format: "playing=%@ playhead %.2f → %.2f", editor.playback.isPlaying ? "yes" : "no", playhead, editor.playback.currentTime))
    }

    // MARK: - Fixture

    @available(iOS 26, *)
    static func openEditor(in folder: URL? = nil) async -> EditorViewController? {
        let dir = (folder ?? out).appendingPathComponent("project", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let project = InspectorValuesTranscript.makeProject(folder: dir)
        guard let poster = poster(),
              (try? await StillMovieWriter.write(image: poster, to: dir.appendingPathComponent("screen.mov"), duration: 20)) != nil,
              (try? await StillMovieWriter.write(image: poster, to: dir.appendingPathComponent("camera.mov"), duration: 20)) != nil,
              let data = try? JSONEncoder().encode(project),
              (try? data.write(to: dir.appendingPathComponent(StudioProjectFolder.documentName))) != nil,
              let folder = try? StudioProjectFolder.open(dir) else {
            check("fixture", false, "could not write or open the fixture project")
            return nil
        }
        let editor = EditorViewController(folder: folder, initialTime: InspectorValuesTranscript.playhead)
        editor.onClose = {}
        return editor
    }

    /// A demo project for screenshots (`--fold-probe --editor --demo`): an
    /// 8 s synthetic screen recording (`DemoMovieWriter` — a real filmstrip),
    /// two zoom blocks on EFFECTS and an annotation on ANNOTATE, like the
    /// Mac editor's marketing shot.
    @available(iOS 26, *)
    static func openDemoEditor(in folder: URL, portrait: Bool = false) async -> EditorViewController? {
        let dir = folder.appendingPathComponent("demo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let movie = dir.appendingPathComponent("screen.mov")
        guard await DemoMovieWriter.write(to: movie, duration: 8, size: portrait ? CGSize(width: 600, height: 1064) : CGSize(width: 960, height: 600)) else { return nil }
        let project = Project(id: UUID(), name: "Q4 launch video", videoURL: movie, cameraVideoURL: nil,
                              duration: 8, recordingSourceKind: .window)
        project.zoomRegions = [
            ZoomRegion(id: UUID(), startTime: 0.8, endTime: 4.1, zoomLevel: 1.6, focalPoint: CGPoint(x: 0.45, y: 0.4)),
            ZoomRegion(id: UUID(), startTime: 5.9, endTime: 7.5, zoomLevel: 1.4, focalPoint: CGPoint(x: 0.6, y: 0.5)),
        ]
        var label = Annotation(id: UUID(), type: .text, startTime: 6.1, endTime: 7.7)
        label.text = "Give it a name"
        project.annotations = [label]
        guard let data = try? JSONEncoder().encode(project),
              (try? data.write(to: dir.appendingPathComponent(StudioProjectFolder.documentName))) != nil,
              let opened = try? StudioProjectFolder.open(dir) else { return nil }
        let editor = EditorViewController(folder: opened, initialTime: 5.0)
        editor.onClose = {}
        return editor
    }

    private static func poster() -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 640, height: 400), format: format).image { ctx in
            UIColor(red: 0.18, green: 0.32, blue: 0.62, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 640, height: 400))
        }.cgImage
    }

    // MARK: - Helpers

    private static func apply(_ display: Display, to host: UIViewController) {
        host.traitOverrides.horizontalSizeClass = display.horizontal
        host.traitOverrides.verticalSizeClass = display.vertical
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
    }

    private static func encoded(_ project: Project) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(project)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    private static func fmt(_ r: CGRect) -> String {
        String(format: "[%.0f,%.0f %.0fx%.0f]", r.minX, r.minY, r.width, r.height)
    }

    private static func settle(_ seconds: Double) async { await LabTime.settle(seconds) }

    private static func check(_ name: String, _ pass: Bool, _ detail: String) {
        if !pass { failures += 1 }
        log("EDITOR-RESIZE \(pass ? "PASS" : "FAIL") \(name) — \(detail)")
    }

    private static func log(_ line: String) {
        lines.append(line)
        print(line)
    }

    private static func finish() {
        try? lines.joined(separator: "\n").write(to: out.appendingPathComponent("run.txt"), atomically: true, encoding: .utf8)
        log(failures == 0 ? "EDITOR-RESIZE-GATE PASS" : "EDITOR-RESIZE-GATE FAIL (\(failures) check(s) failed)")
        exit(failures == 0 ? 0 : 1)
    }
}
