import UIKit

/// `--editor-resize <outDir> [--inject ignores-size-class]` — the editor
/// folding and unfolding, as on iPhone Duo (outer display: compact width;
/// inner display: regular width), in the real window chain.
///
/// The editor is hosted at the outer display's size and size classes, given
/// state (a playhead, a selection, an edit on the undo stack, playback
/// running), then resized live to the inner display and back. Each step
/// checks the layout the size classes call for (stacked with a bottom-sheet
/// inspector when compact; an inspector column beside the stage when regular),
/// that every region stays inside the editor and clear of the others, that
/// History would open in the matching style, and that nothing was lost:
/// project, selection, undo stack, and playback still running and advancing.
/// `--inject ignores-size-class` pins the editor to its compact layout: the
/// unfold checks must then FAIL (proof the gate can see a missed resize).
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
            guard inject == "ignores-size-class" || inject == "ignores-crease" else {
                log("EDITOR-RESIZE FAIL unknown --inject \(inject)"); exit(1)
            }
            log("EDITOR-RESIZE inject=\(inject)")
            #if DEBUG
            EditorViewController.probeDefect = inject == "ignores-crease" ? .ignoresCrease : .ignoresSizeClass
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
        check("\(tag)-size-class", editor.usesRegularLayout == wantRegular,
              "usesRegularLayout=\(editor.usesRegularLayout) for \(display.horizontal == .regular ? "regular" : "compact") width")
        let root = editor.view!
        let bounds = root.bounds
        func frame(_ v: UIView) -> CGRect { root.convert(v.bounds, from: v) }
        let stage = frame(editor.stageCard), transport = frame(editor.transport)
        let timeline = frame(editor.timelineContainer), inspector = frame(editor.inspectorContainer)
        let regions = ["stage": stage, "transport": transport, "timeline": timeline, "inspector": inspector]
        for (name, r) in regions.sorted(by: { $0.key < $1.key }) {
            let inside = bounds.insetBy(dx: -0.5, dy: -0.5).contains(r) && r.width > 1 && r.height > 1
            check("\(tag)-\(name)-inside", inside, "\(name) \(fmt(r)) in \(fmt(bounds))")
        }
        if wantRegular {
            // The inspector column beside the stage and timeline.
            check("\(tag)-inspector-column", abs(inspector.width - 340) < 1 && inspector.minX >= stage.maxX - 0.5
                  && inspector.minX >= timeline.maxX - 0.5, "inspector \(fmt(inspector)), stage \(fmt(stage)), timeline \(fmt(timeline))")
            check("\(tag)-timeline-height", timeline.height >= 219.5, "timeline height \(Int(timeline.height)) (want ≥ 220)")
        } else {
            // Stacked: stage, transport, timeline, then the inspector sheet's dock.
            check("\(tag)-stacked", stage.maxY <= transport.minY + 0.5 && transport.maxY <= timeline.minY + 0.5
                  && timeline.maxY <= inspector.minY + 0.5,
                  "stage \(fmt(stage)) transport \(fmt(transport)) timeline \(fmt(timeline)) inspector \(fmt(inspector))")
            check("\(tag)-full-width", abs(stage.width - timeline.width) < 1 && stage.width > bounds.width - 40,
                  "stage width \(Int(stage.width)) of \(Int(bounds.width))")
        }
        let history = HistoryPresentation.style(for: editor)
        check("\(tag)-history-style", (history == .sidePanel) == wantRegular, "History would open as \(history)")
        log("EDITOR-RESIZE \(tag) layout stage=\(fmt(stage)) timeline=\(fmt(timeline)) inspector=\(fmt(inspector))")
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
        let regions = ["stage": stage, "transport": transport, "timeline": timeline, "inspector": inspector]
        for (name, r) in regions.sorted(by: { $0.key < $1.key }) {
            let inside = bounds.insetBy(dx: -0.5, dy: -0.5).contains(r) && r.width > 1 && r.height > 1
            check("\(tag)-\(name)-inside", inside, "\(name) \(fmt(r)) in \(fmt(bounds))")
            check("\(tag)-\(name)-off-crease", !r.insetBy(dx: 0.5, dy: 0.5).intersects(crease),
                  "\(name) \(fmt(r)) vs crease \(fmt(crease))")
        }
        if vertical {
            check("\(tag)-stage-side", stage.maxX <= crease.minX + 0.5 && transport.maxX <= crease.minX + 0.5,
                  "stage \(fmt(stage)) transport \(fmt(transport)) left of \(Int(crease.minX))")
            check("\(tag)-panel-side", timeline.minX >= crease.maxX - 0.5 && inspector.minX >= crease.maxX - 0.5,
                  "timeline \(fmt(timeline)) inspector \(fmt(inspector)) right of \(Int(crease.maxX))")
            check("\(tag)-stage-fills-half", stage.width >= crease.minX - 40,
                  "stage width \(Int(stage.width)) of a \(Int(crease.minX)) pt half")
        } else {
            check("\(tag)-stage-side", stage.maxY <= crease.minY + 0.5 && transport.maxY <= crease.minY + 0.5,
                  "stage \(fmt(stage)) transport \(fmt(transport)) above \(Int(crease.minY))")
            check("\(tag)-panel-side", timeline.minY >= crease.maxY - 0.5 && inspector.minY >= crease.maxY - 0.5,
                  "timeline \(fmt(timeline)) inspector \(fmt(inspector)) below \(Int(crease.maxY))")
        }
        check("\(tag)-timeline-over-inspector", timeline.maxY <= inspector.minY + 0.5 && timeline.height >= 159.5
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
