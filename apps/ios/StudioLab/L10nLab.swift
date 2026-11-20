import UIKit

/// `--l10n <dir> [--inject untranslated|truncate]` (apps/ios/scripts/ios-l10n.sh):
/// the shipping editor in StudioLab's real window, in whatever language the
/// process runs in (`-AppleLanguages (de)`), and every studio screen the a11y
/// gate opens (A11yLab.screens: all nine inspector panes top and scrolled to
/// the end, an open lane, a selection, the timeline menu, History, Merge
/// Review, the four feature sheets, the sync badge, the tool bar's sheets and
/// panels, the Export sheet) and the AI-edit notice. Each screen goes through `CCLocalizationAudit`;
/// the script judges the texts. Ends with `L10NLAB-DONE`.
@MainActor
enum L10nLab {
    private static var out: URL!

    static func start(_ arguments: [String], lab: LabViewController) -> Bool {
        guard let i = arguments.firstIndex(of: "--l10n"), arguments.indices.contains(i + 1) else { return false }
        out = URL(fileURLWithPath: arguments[i + 1], isDirectory: true)
        let inject = arguments.firstIndex(of: "--inject").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        lab.stage.isHidden = true
        guard #available(iOS 26, *) else { print("L10NLAB-DONE FAIL the studio needs iOS 26"); exit(1) }
        Task { @MainActor in await run(lab: lab, inject: inject) }
        return true
    }

    @available(iOS 26, *)
    private static func run(lab: LabViewController, inject: String?) async {
        setbuf(stdout, nil)
        UIApplication.shared.isIdleTimerDisabled = true
        try? FileManager.default.removeItem(at: out.appendingPathComponent("screens"))
        if inject == "truncate" { CCHeaderBar.probeTruncateTitle = true }
        print("L10NLAB locale=\(Bundle.main.preferredLocalizations.first ?? "?") inject=\(inject ?? "none")")
        guard let editor = await openEditor(lab: lab), let window = editor.view.window else {
            print("L10NLAB-DONE FAIL could not open the editor"); exit(1)
        }
        if inject == "untranslated" {
            let label = ccLabel("Drag to reorder", font: CCFont.label, color: CCTheme.color.foreground)
            label.frame = CGRect(x: 20, y: 120, width: 240, height: 22)
            editor.view.addSubview(label)
        }
        A11yLab.registerEditorScreens()
        // The a11y gate's harness-only dialogs (an English test alert, the
        // colour picker under a test title) are not app copy: the real
        // colour picker is opened with a catalog title instead.
        let skip: Set<String> = ["confirm-dialog", "color-picker"]
        var screens = A11yLab.screens(editor).filter { !skip.contains($0.name) }
        screens.append(A11yLab.Screen(name: "color-picker", open: { editor in
            CCColorPicker.present(from: editor, source: editor.header,
                                  title: String(localized: "Background", comment: "Inspector tab: background"), color: .systemBlue)
            await LabTime.settle(0.9)
            return nil
        }, close: A11yLab.dismissPresented))
        screens += selectionScreens(editor)
        // The "Edited by …" notice an AI agent's edit raises (StudioAgentEdits), named and unnamed.
        for named in [true, false] {
            var notice: CCToast?
            screens.append(A11yLab.Screen(name: named ? "agent-edit-notice" : "agent-edit-notice-unnamed", open: { editor in
                notice = StudioAgentEdits.probeShowNotice(in: editor, named: named)
                await LabTime.settle(0.9)
                return nil
            }, close: { _ in
                notice?.dismiss()
                await LabTime.settle(0.6)
            }))
        }
        let dir = out.appendingPathComponent("screens", isDirectory: true)
        var problems = 0
        for screen in screens {
            _ = await screen.open(editor)
            await LabTime.settle(0.6)
            let found = CCLocalizationAudit.capture(screen.name, window: window, to: dir)
            problems += found.count
            print("L10NLAB screen \(screen.name) \(found.isEmpty ? "ok" : found.joined(separator: " | "))")
            await screen.close(editor)
            await LabTime.settle(0.3)
        }
        print("L10NLAB-DONE \(problems == 0 ? "clean" : "\(problems) text problem(s)")")
        exit(0)
    }

    /// Each object selected, its inspector open (and its on-canvas keys):
    /// every annotation type, highlight, tilt, depth focus, blur, the intro and
    /// the curtain chips.
    @available(iOS 26, *)
    private static func selectionScreens(_ editor: EditorViewController) -> [A11yLab.Screen] {
        func clear(_ editor: EditorViewController) async {
            let s = editor.selection
            s.selectedAnnotationID = nil; s.selectedHighlightID = nil; s.selectedTiltID = nil
            s.selectedZoomID = nil; s.selectedDepthFocusID = nil; s.selectedBlurID = nil
            s.introSelected = false; s.curtainSelected = false
            editor.closePanel(animated: false)
            await LabTime.settle(0.3)
        }
        func screen(_ name: String, at time: TimeInterval, tab: InspectorTab, select: @escaping (EditorShellSelection) -> Void) -> A11yLab.Screen {
            A11yLab.Screen(name: name, open: { editor in
                editor.playback.scrub(to: time, for: editor.project, exact: true)
                select(editor.selection)
                await LabTime.settle(0.5)
                // The tab the selection leads to (InspectorTabFollower), else `tab`.
                if editor.selection.inspectorTab == .background && tab != .background { editor.selection.inspectorTab = tab }
                editor.openPanel(editor.selection.inspectorTab, animated: false)
                await LabTime.settle(0.6)
                return nil
            }, close: clear)
        }
        let project = editor.project
        var list: [A11yLab.Screen] = []
        for type in AnnotationType.allCases {
            guard let a = project.annotations.first(where: { $0.type == type }) else { continue }
            list.append(screen("selected-annotation-\(type.rawValue)", at: a.startTime + 0.5, tab: .annotations) { $0.selectedAnnotationID = a.id })
        }
        if let r = project.highlightRegions.first {
            list.append(screen("selected-highlight", at: r.startTime + 0.5, tab: .effects) { $0.selectedHighlightID = r.id })
        }
        if let r = project.tiltRegions.first {
            list.append(screen("selected-tilt", at: r.startTime + 0.5, tab: .effects) { $0.selectedTiltID = r.id })
        }
        if let r = project.focusRegions.first {
            list.append(screen("selected-depth-focus", at: r.startTime + 0.5, tab: .effects) { $0.selectedDepthFocusID = r.id })
        }
        if let r = project.blurRegions.first {
            list.append(screen("selected-blur", at: r.startTime + 0.5, tab: .effects) { $0.selectedBlurID = r.id })
        }
        list.append(screen("selected-intro", at: 0.2, tab: .effects) { $0.introSelected = true })
        list.append(screen("selected-curtain", at: 0.2, tab: .effects) { $0.curtainSelected = true })
        return list
    }

    @available(iOS 26, *)
    private static func openEditor(lab: LabViewController) async -> EditorViewController? {
        let dir = out.appendingPathComponent("project", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let project = InspectorValuesTranscript.makeProject(folder: dir)
        // Every annotation type, so each one's inspector can be opened selected.
        var slot: TimeInterval = 17.2
        for type in AnnotationType.allCases where !project.annotations.contains(where: { $0.type == type }) {
            // After the last fixture block (it ends at 17 s), one after another,
            // so the ANNOTATE lane keeps its rows.
            var extra = Annotation(type: type, startTime: slot, endTime: slot + 1)
            slot += 1.2
            if type == .callout { extra.text = "Hello from the Mac" }
            project.annotations.append(extra)
        }
        let size = CGSize(width: 640, height: 400)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        guard let poster = UIGraphicsImageRenderer(size: size, format: format).image(actions: { ctx in
                  UIColor(red: 0.18, green: 0.2, blue: 0.26, alpha: 1).setFill()
                  ctx.fill(CGRect(origin: .zero, size: size))
              }).cgImage,
              (try? await StillMovieWriter.write(image: poster, to: dir.appendingPathComponent("screen.mov"), duration: 20)) != nil,
              (try? await StillMovieWriter.write(image: poster, to: dir.appendingPathComponent("camera.mov"), duration: 20)) != nil,
              let data = try? JSONEncoder().encode(project),
              (try? data.write(to: dir.appendingPathComponent(StudioProjectFolder.documentName))) != nil,
              let folder = try? StudioProjectFolder.open(dir) else { return nil }
        let editor = EditorViewController(folder: folder, initialTime: InspectorValuesTranscript.playhead)
        editor.onClose = {}
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lab.present(editor, animated: false) { c.resume() }
        }
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, editor.stage.core.displayedVideoFrame == nil { await LabTime.settle(0.05) }
        await LabTime.settle(0.8)
        return editor
    }
}
