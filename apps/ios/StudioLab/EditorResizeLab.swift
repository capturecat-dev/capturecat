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
            guard ["ignores-size-class", "ignores-crease", "snap-panel", "panel-tab-row", "panel-over-toolbar",
                   "panel-uncapped", "drag-grabber-only"].contains(inject) else {
                log("EDITOR-RESIZE FAIL unknown --inject \(inject)"); exit(1)
            }
            log("EDITOR-RESIZE inject=\(inject)")
            #if DEBUG
            if inject == "drag-grabber-only" { StudioInspectorController.probeDragOnlyOnGrabber = true }
            else if inject == "panel-tab-row" { EditorViewController.probePanelDefect = .tabRow }
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
        // The context keys show for the selection; Done brings the tools back.
        if let done = editor.toolBar.key(for: .done) { done.sendActions(for: .touchUpInside) }
        await settle(0.3)
        check("landscape-done-clears", editor.toolBar.mode == .tools && !editor.timeline.hasTimelineSelection,
              "Done → tools (\(editor.toolBar.probeTitles.prefix(4).joined(separator: " · ")) …)")
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
        // ONE transport row: no scrubber, the time + play + full screen.
        check("\(tag)-transport-row", abs(transport.height - 48) < 0.5 && abs(transport.width - stage.width) < 1
                && !editor.transport.playButton.isHidden && !editor.transport.playhead.isHidden,
              "transport \(fmt(transport)) under the stage, as wide as it")
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
            check("\(tag)-full-width", abs(stage.width - timeline.width) < 1 && stage.width > bounds.width - 40,
                  "stage width \(Int(stage.width)) of \(Int(bounds.width))")
            let share = stage.height / bounds.height
            check("\(tag)-stage-share", share >= EditorViewController.stageShare - 0.02,
                  String(format: "stage %.0f of %.0f pt = %.0f%% of the height (want ≥ %.0f%%)", stage.height, bounds.height,
                         share * 100, (EditorViewController.stageShare - 0.02) * 100))
            // Tools: every pane; with a selection: its context keys.
            let keys = editor.toolBar.probeTitles
            let keysOK = editor.toolBar.mode == .tools
                ? InspectorTab.allCases.allSatisfy { keys.contains($0.rawValue) }
                : keys.first == "Done" && keys.contains("Split") && keys.contains("Delete")
            check("\(tag)-tool-bar", abs(tools.maxY - bounds.maxY) < 0.5 && abs(tools.width - bounds.width) < 0.5
                    && editor.toolBar.axis == .horizontal && keysOK
                    && editor.inspector.view.isHidden == !editor.isPanelOpen,
                  "tool bar \(fmt(tools)) to the screen's bottom edge; keys \(keys.joined(separator: " · "))")
        }
        let history = HistoryPresentation.style(for: editor)
        check("\(tag)-history-style", (history == .sidePanel) == wantRegular, "History would open as \(history)")
        log("EDITOR-RESIZE \(tag) layout stage=\(fmt(stage)) transport=\(fmt(transport)) timeline=\(fmt(timeline)) toolBar=\(fmt(tools)) inspector=\(fmt(inspector))")
    }

    /// A pane tool tapped (the key's own action): the panel caught MID-FLIGHT
    /// growing from its pushed edge, landing where the arrangement puts it —
    /// bottom panel: its top on the timeline's top, never over the stage
    /// (overshoot included); side panel: between the column and the rail,
    /// the column pushed narrower, the stage never covered. The close key
    /// brings back the tool bar.
    @available(iOS 26, *)
    private static func checkPanel(_ editor: EditorViewController, tag: String, injected: Bool) async {
        let root = editor.view!
        func frame(_ v: UIView) -> CGRect { root.convert(v.bounds, from: v) }
        let panel = editor.inspector.view!
        guard let key = editor.toolBar.key(for: .pane(.audio)) else {
            check("\(tag)-panel-tool", false, "no Audio tool (\(editor.toolBar.probeTitles))"); return
        }
        let side = editor.inspector.presentation == .sidePanel
        let stageBefore = frame(editor.stageCard)
        let timelineTop = frame(editor.timelineContainer).minY
        var edges: [CGFloat] = [], stageRights: [CGFloat] = []
        var overlaps = 0
        key.sendActions(for: .touchUpInside)
        let t0 = CACurrentMediaTime()
        while CACurrentMediaTime() - t0 < 0.6 {
            let p = frame(panel), s = frame(editor.stageCard)
            edges.append(side ? p.minX : p.minY)
            stageRights.append(s.maxX)
            // The panel's visible part never lies over the stage.
            let visible = side ? p.intersection(CGRect(x: 0, y: 0, width: frame(editor.toolBar).minX, height: root.bounds.height)) : p
            if visible.intersects(s.insetBy(dx: 0.5, dy: 0.5)) { overlaps += 1 }
            await settle(0.016)
        }
        let final = frame(panel)
        let start = edges.first ?? 0, end = side ? final.minX : final.minY
        let mid = edges.filter { abs($0 - start) > 2 && abs($0 - end) > 2 }
        let opened = editor.isPanelOpen && editor.inspector.visiblePane?.tab == .audio && key.isSelected
        let midOK = mid.count >= 2
        // (`--inject snap-panel` makes this FAIL: the gate's proof it sees motion.)
        _ = injected
        check("\(tag)-panel-open-midflight", midOK && opened,
              String(format: "Audio tool → %d of %d samples mid-flight (edge %.0f → %.0f); pane %@", mid.count, edges.count, start, end,
                     editor.inspector.visiblePane?.tab.rawValue ?? "none"))
        if side {
            let stage = frame(editor.stageCard), rail = frame(editor.toolBar)
            check("\(tag)-side-panel", final.minX >= stage.maxX - 0.5 && final.maxX <= rail.minX + 0.5 + 0.5 && overlaps == 0
                    && stage.width < stageBefore.width - 100,
                  String(format: "panel %@ between the stage %@ and the rail %@; stage %.0f → %.0f pt wide; %d overlapping samples",
                         fmt(final), fmt(stage), fmt(rail), stageBefore.width, stage.width, overlaps))
        } else {
            await checkBottomPanel(editor, tag: tag, final: final, edges: edges, overlaps: overlaps,
                                   stageBefore: stageBefore, timelineTop: timelineTop)
        }
        editor.inspector.closeButton.sendActions(for: .touchUpInside)
        await settle(0.6)
        check("\(tag)-panel-closed", !editor.isPanelOpen && panel.isHidden && abs(frame(editor.stageCard).width - stageBefore.width) < 0.5,
              "Done → tool bar alone, stage \(Int(frame(editor.stageCard).width)) pt wide again")
        if !side {
            // Swipe down on the strip closes too.
            if let k = editor.toolBar.key(for: .pane(.audio)) { k.sendActions(for: .touchUpInside) }
            await settle(0.6)
            #if DEBUG
            editor.probeSwipePanel(160)
            #endif
            await settle(0.6)
            check("\(tag)-panel-swipe-closes", !editor.isPanelOpen && panel.isHidden, "a swipe down the strip closes the panel")
        }
    }

    /// Dragging the bottom panel between its detents (COMPACT ⇄ TALL):
    /// where a drag may start (anywhere but a control — not just the pill),
    /// the scroll-top handoff, a ±150 pt pan followed 1:1 then snapped to the
    /// nearest detent, flicks with a short travel picking the next detent —
    /// every snap caught MID-FLIGHT — TALL never over the preview or
    /// transport (rubber band included), and a flick down from COMPACT closing.
    @available(iOS 26, *)
    private static func checkPanelDrag(_ editor: EditorViewController, tag: String) async {
        #if DEBUG
        let root = editor.view!
        func frame(_ v: UIView) -> CGRect { root.convert(v.bounds, from: v) }
        let inspector = editor.inspector
        let stage = frame(editor.stageCard), transport = frame(editor.transport)
        // Where a drag may start: the strip's title, a pane's non-control
        // view (its first label), the pill — never a control.
        let label = firstView(UILabel.self, in: inspector.panes[.audio] ?? inspector.view)
        let control = firstView(UIControl.self, in: inspector.panes[.audio] ?? inspector.view)
        let accepts = (title: inspector.panelDragAccepts(inspector.panelTitle),
                       content: inspector.panelDragAccepts(label),
                       pill: inspector.panelDragAccepts(inspector.probeGrabber),
                       control: inspector.panelDragAccepts(control))
        check("\(tag)-panel-drag-anywhere", accepts.title && accepts.content && accepts.pill && !accepts.control && label != nil,
              "drag starts on: title \(accepts.title), pane label \(accepts.content), pill \(accepts.pill); a control \(accepts.control) (want false)")
        // Scroll-top handoff (the pane content): up grows the panel while
        // COMPACT; at TALL up scrolls the pane; down at scroll-top drags the
        // panel, down while scrolled scrolls.
        let upCompact = inspector.panelDragBegins(onContent: true, upward: true)
        let downTop = inspector.panelDragBegins(onContent: true, upward: false)
        // Height probes.
        let compact = editor.detentHeight(.compact), tall = editor.tallPanelHeight()
        check("\(tag)-panel-detents", editor.hasTallDetent && tall > compact + 12 && editor.panelDetent == .compact,
              String(format: "COMPACT %.0f pt, TALL %.0f pt", compact, tall))
        func sampleSnap(_ seconds: Double) async -> [CGFloat] {
            var hs: [CGFloat] = []
            let t0 = CACurrentMediaTime()
            while CACurrentMediaTime() - t0 < seconds {
                hs.append(frame(inspector.view).height)
                await settle(0.008)
            }
            return hs
        }
        func mid(_ hs: [CGFloat], _ a: CGFloat, _ b: CGFloat) -> Int {
            hs.filter { $0 > min(a, b) + 2 && $0 < max(a, b) - 2 }.count
        }
        var highest = CGFloat.greatestFiniteMagnitude
        // 1:1 follow, then release: −150 pt (up) → rubber-banded past TALL, snaps to TALL.
        let follow = editor.probeFollow(-40)
        let followed = abs((follow.now - follow.start) - 40) < 0.5
        editor.probeDragPanel(-40, velocity: 0)  // re-drive the same drag to release it
        await settle(0.6)
        editor.setPanelDetent(.compact, animated: false)
        await settle(0.2)
        editor.probeDragPanel(-150, velocity: 0)
        highest = min(highest, frame(inspector.view).minY)
        let upSamples = await sampleSnap(0.5)
        for _ in upSamples { highest = min(highest, frame(inspector.view).minY) }
        let atTall = editor.panelDetent == .tall && abs(frame(inspector.view).height - tall) < 1
        let upTallContent = inspector.panelDragBegins(onContent: true, upward: true)
        check("\(tag)-panel-pan-up", followed && atTall && mid(upSamples, tall, upSamples.first ?? tall) >= 2,
              String(format: "drag −40 followed 1:1 (%.0f → %.0f); −150 pt → TALL %.0f, %d samples mid-snap", follow.start, follow.now,
                     frame(inspector.view).height, mid(upSamples, tall, upSamples.first ?? tall)))
        let p = frame(inspector.view)
        check("\(tag)-panel-tall-preview-clear", p.minY >= transport.maxY - 0.5 && highest >= stage.maxY - 0.5 && p.maxY <= frame(editor.toolBar).minY + 0.5,
              String(format: "TALL top %.0f under the transport (%.0f); highest during the drag %.0f vs the stage's bottom %.0f",
                     p.minY, transport.maxY, highest, stage.maxY))
        check("\(tag)-panel-scroll-handoff", upCompact && downTop && !upTallContent,
              "on the pane: up while COMPACT drags \(upCompact); down at scroll-top drags \(downTop); up at TALL drags \(upTallContent) (want false — it scrolls)")
        // +150 pt (down) from TALL → nearest = COMPACT.
        editor.probeDragPanel(150, velocity: 0)
        let downSamples = await sampleSnap(0.55)
        check("\(tag)-panel-pan-down", editor.isPanelOpen && editor.panelDetent == .compact && abs(frame(inspector.view).height - compact) < 1
                && mid(downSamples, compact, tall - 150) >= 2,
              String(format: "+150 pt from TALL → COMPACT %.0f pt, %d samples mid-snap", frame(inspector.view).height, mid(downSamples, compact, tall - 150)))
        // Flicks: 20 pt of travel at 900 pt/s picks the next detent.
        editor.probeDragPanel(-20, velocity: -900)
        let flickUp = await sampleSnap(0.5)
        let flickUpOK = editor.panelDetent == .tall && mid(flickUp, compact + 20, tall) >= 2
        editor.probeDragPanel(20, velocity: 900)
        let flickDown = await sampleSnap(0.55)
        let flickDownOK = editor.isPanelOpen && editor.panelDetent == .compact && mid(flickDown, compact, tall - 20) >= 2
        check("\(tag)-panel-flick", flickUpOK && flickDownOK,
              "flick up 20 pt @ −900 pt/s → TALL (\(mid(flickUp, compact + 20, tall)) mid); flick down → COMPACT (\(mid(flickDown, compact, tall - 20)) mid)")
        // A short slow drag snaps back to where it was.
        editor.probeDragPanel(-15, velocity: 0)
        await settle(0.5)
        check("\(tag)-panel-short-drag-returns", editor.panelDetent == .compact && abs(frame(inspector.view).height - compact) < 1,
              "15 pt slowly → back to COMPACT")
        // VoiceOver: the pill is a button that toggles; the title has the action.
        let pill: UIView? = inspector.probeGrabber
        let pillLabel = pill?.accessibilityLabel ?? ""
        let titleAction = inspector.panelTitle.accessibilityCustomActions?.first?.name ?? ""
        _ = pill?.accessibilityActivate()
        await settle(0.5)
        let expanded = editor.panelDetent == .tall
        _ = pill?.accessibilityActivate()
        await settle(0.6)
        check("\(tag)-panel-voiceover-expand", pill?.isAccessibilityElement == true && pill?.accessibilityTraits.contains(.button) == true
                && pillLabel == "Expand panel" && titleAction == "Expand panel" && expanded && editor.panelDetent == .compact,
              "pill button \"\(pillLabel)\", title action \"\(titleAction)\": activate → TALL \(expanded), again → COMPACT")
        #endif
    }

    private static func firstView<T: UIView>(_ type: T.Type, in root: UIView) -> T? {
        if let v = root as? T, !v.isHidden { return v }
        for sub in root.subviews where !sub.isHidden { if let v = firstView(type, in: sub) { return v } }
        return nil
    }

    /// The bottom panel (portrait): directly ABOVE the tool bar, which stays
    /// visible and marks the tool; ONLY the tool's pane inside (no tab row);
    /// fitted to its pane and capped at ~40% of the height; the stage and
    /// transport never covered (every sample); the timeline's lanes still
    /// showing above it. Then another tool: the content switches in place
    /// (cross-fade caught mid-flight) and the panel resizes (mid-flight when
    /// the heights differ); the active tool again closes it, mid-flight.
    @available(iOS 26, *)
    private static func checkBottomPanel(_ editor: EditorViewController, tag: String, final: CGRect, edges: [CGFloat],
                                         overlaps: Int, stageBefore: CGRect, timelineTop: CGFloat) async {
        let root = editor.view!
        func frame(_ v: UIView) -> CGRect { root.convert(v.bounds, from: v) }
        let tools = frame(editor.toolBar), transport = frame(editor.transport)
        let lanes = frame(editor.timeline.view)
        let inspector = editor.inspector
        // A tab row = any visible pane rail key inside the panel.
        func visibleRailKeys() -> Int {
            var n = 0
            func walk(_ v: UIView, _ shown: Bool) {
                let s = shown && !v.isHidden && v.alpha > 0.01
                if s, v is CCIconRailKey, v.bounds.width > 1, v.bounds.height > 1 { n += 1 }
                v.subviews.forEach { walk($0, s) }
            }
            walk(inspector.view, true)
            return n
        }
        let railKeys = visibleRailKeys()
        let cap = root.bounds.height * EditorViewController.panelMaxShare
        let fit = inspector.panelFittingHeight
        let toolBarShown = !editor.toolBar.isHidden && editor.toolBar.alpha > 0.99 && !editor.toolBar.accessibilityElementsHidden
            && abs(tools.maxY - root.bounds.maxY) < 0.5
        check("\(tag)-panel-above-toolbar", final.maxY <= tools.minY + 0.5 && final.maxY >= tools.minY - 12 && toolBarShown,
              String(format: "panel %@ ends at %.0f, the tool bar %@ starts at %.0f and stays shown (%@)",
                     fmt(final), final.maxY, fmt(tools), tools.minY, toolBarShown ? "yes" : "no"))
        check("\(tag)-panel-no-tab-row", railKeys == 0 && !inspector.panelTitle.isHidden
                && inspector.panelTitle.text == InspectorTab.audio.rawValue,
              "\(railKeys) pane-rail keys inside the panel (want 0); title \"\(inspector.panelTitle.text ?? "")\"")
        check("\(tag)-panel-height-cap", final.height <= cap + 0.5 && final.height <= editor.panelCap() + 0.5
                && (abs(final.height - min(fit, editor.panelCap()).rounded()) < 1.5),
              String(format: "panel %.0f pt high: fits %.0f, cap %.0f (40%% = %.0f)", final.height, fit, editor.panelCap(), cap))
        let highest = edges.min() ?? final.minY
        check("\(tag)-panel-preview-clear", overlaps == 0 && highest >= transport.maxY - 0.5 && highest >= stageBefore.maxY - 0.5,
              String(format: "highest panel top %.0f (overshoot included) vs the transport's bottom %.0f; %d samples over the stage",
                     highest, transport.maxY, overlaps))
        check("\(tag)-panel-timeline-visible", lanes.minY >= timelineTop - 0.5 && lanes.maxY <= final.minY + 0.5
                && lanes.height >= EditorViewController.minTimelineStrip - 0.5 && !editor.timelineContainer.accessibilityElementsHidden,
              String(format: "lanes %@ above the panel (≥ %.0f pt), still VoiceOver-reachable", fmt(lanes), EditorViewController.minTimelineStrip))

        await checkPanelDrag(editor, tag: tag)

        // Switch: Audio → the pane that fits lowest (another height, so the
        // resize is seen), measured with snapped opens first.
        var fits: [(InspectorTab, CGFloat)] = []
        for tab in InspectorTab.allCases where tab != .audio {
            editor.openPanel(tab, animated: false)
            await settle(0.15)
            fits.append((tab, inspector.panelFittingHeight))
        }
        editor.openPanel(.audio, animated: false)
        await settle(0.4)
        let target = fits.min { $0.1 < $1.1 }?.0 ?? .cursor
        log("EDITOR-RESIZE \(tag) pane fits: " + fits.map { "\($0.0.rawValue) \(Int($0.1))" }.joined(separator: ", ")
            + String(format: " — cap %.0f; switching to %@", editor.panelCap(), target.rawValue))
        guard let cursorKey = editor.toolBar.key(for: .pane(target)), let audioKey = editor.toolBar.key(for: .pane(.audio)) else {
            check("\(tag)-panel-switch", false, "no Cursor tool"); return
        }
        var heights: [CGFloat] = [], alphas: [Float] = []
        var overTransport = 0
        cursorKey.sendActions(for: .touchUpInside)
        let t0 = CACurrentMediaTime()
        while CACurrentMediaTime() - t0 < 0.6 {
            heights.append(frame(inspector.view).height)
            if let pane = inspector.panes[target] { alphas.append((pane.layer.presentation() ?? pane.layer).opacity) }
            if frame(inspector.view).minY < transport.maxY - 0.5 { overTransport += 1 }
            await settle(0.016)
        }
        let after = frame(inspector.view)
        check("\(tag)-panel-switch-clear", overTransport == 0, "\(overTransport) samples of the switch with the panel over the transport")
        let startH = heights.first ?? 0
        let midH = heights.filter { abs($0 - startH) > 2 && abs($0 - after.height) > 2 }
        let fadeMid = alphas.contains { $0 > 0.05 && $0 < 0.95 }
        let resized = abs(after.height - startH) > 2
        check("\(tag)-panel-switch", editor.isPanelOpen && inspector.visiblePane?.tab == target && cursorKey.isSelected
                && !audioKey.isSelected && fadeMid && ((fits.map(\.1).min() ?? 0) >= editor.panelCap() - 2 || (resized && midH.count >= 2)) && after.maxY <= tools.minY + 0.5
                && after.height <= min(cap, editor.panelCap()) + 0.5,
              String(format: "%@ tool → content cross-fade mid-flight %@; panel %.0f → %.0f pt (%d samples mid-resize); it is marked %@, Audio %@", target.rawValue,
                     fadeMid ? "yes" : "no", startH, after.height, midH.count, cursorKey.isSelected ? "yes" : "no", audioKey.isSelected ? "still" : "no"))
        // The active tool again closes it (animated).
        var closing: [CGFloat] = []
        cursorKey.sendActions(for: .touchUpInside)
        let c0 = CACurrentMediaTime()
        while CACurrentMediaTime() - c0 < 0.45 {
            closing.append(frame(inspector.view).height)
            await settle(0.016)
        }
        await settle(0.2)
        let closeMid = closing.filter { $0 > 2 && $0 < after.height - 2 }
        check("\(tag)-panel-tool-again-closes", !editor.isPanelOpen && inspector.view.isHidden && closeMid.count >= 2 && !cursorKey.isSelected,
              "the active tool again → closed, \(closeMid.count) of \(closing.count) samples mid-flight")
        // Reopen for the caller's Done check.
        audioKey.sendActions(for: .touchUpInside)
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
