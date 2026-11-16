import AVFoundation
import UIKit

/// The iOS studio's editor screen (docs/ios-studio-plan.md Phase 4b) — the
/// UIKit twin of the Mac's `EditorShellViewController` +
/// `EditorStageViewController`:
///
///     [ top bar: close · title · undo · redo                          ]
///     [ stage card (live preview + touch editing)  │                  ]
///     [ transport (step · play · scrub · time)     │   inspector      ]
///     [ timeline container                         │   container      ]
///
/// On a compact width (iPhone portrait) the column stacks under the
/// timeline. The two containers are EMPTY here: the timeline (4c) and the
/// inspector panes (4d) mount into `timelineContainer` / `inspectorContainer`.
///
/// State flows in through `withObservationTracking` loops (`SurfaceObservation`)
/// over the project, the playback controller and the shared selection
/// (`EditorShellSelection`), and out through callbacks — the house rule.
/// Rendering is the shared compositor (`PreviewStageView`), editing the
/// shared gesture core (`EditorCanvasView`), playback `StudioPlaybackController`.
@available(iOS 26, *)
final class EditorViewController: UIViewController {
    let folder: StudioProjectFolder
    var project: Project { folder.project }
    let playback = StudioPlaybackController()
    let selection = EditorShellSelection()
    private let editorUndo = UndoManager()

    /// Where the shared timeline edits run (TODO(4c): the iOS timeline).
    lazy var timelineEdits: TimelineEditing = EditorDefaultEdits(
        project: project, selection: selection,
        undoManager: { [weak self] in self?.editorUndo },
        currentTime: { [weak self] in self?.playback.currentTime ?? 0 })

    // Views.
    let header: CCHeaderBar
    let stageCard = EditorStageCardView()
    let transport = EditorTransportBar()
    /// 4c mounts the timeline here.
    let timelineContainer = UIView()
    /// 4d mounts the inspector panes here.
    let inspectorContainer = UIView()
    /// The inspector (Studio 4d) — its `on…` feature hooks are wired by 4e/4f.
    private(set) lazy var inspector = StudioInspectorController(
        project: project, selection: selection,
        undoManager: { [weak self] in self?.editorUndo },
        currentTime: { [weak self] in self?.playback.currentTime ?? 0 })
    private let contextPill = EditorContextPill()
    private let undoButton = CCButton(symbol: "undo", style: .ghost, size: .regular, radius: .full)
    private let redoButton = CCButton(symbol: "redo", style: .ghost, size: .regular, radius: .full)

    var stage: PreviewStageView { stageCard.stage }
    var canvas: EditorCanvasView { stageCard.canvas }

    /// Called after the editor saved and wants to close (the presenter
    /// dismisses; nil = dismiss self).
    var onClose: (() -> Void)?
    /// Harness seam (`--editor-shell`): pins the virtual canvas instead of
    /// the project's reference canvas.
    var canvasOverride: CGSize? { didSet { updateCanvasSize() } }
    /// Harness seam: every canvas callback as a line (the Mac
    /// `--preview-gesture-test` transcript's `events:` vocabulary).
    var canvasEventLog: ((String) -> Void)?

    /// Studio 4f — History ▸ Preview: an earlier version shown READ-ONLY on
    /// the live stage (a separate, never-saved model; nil = the project).
    /// While set, editing is off: canvas, timeline, inspector, undo.
    var stageProjectOverride: Project? { didSet { stageOverrideChanged() } }
    var isPreviewingVersion: Bool { stageProjectOverride != nil }
    /// What the stage and transport show: the preview, else the project.
    var shownProject: Project { stageProjectOverride ?? project }

    private let initialTime: TimeInterval?
    private lazy var toaster = CCToaster(host: view)
    private var observations: [SurfaceObservation] = []
    private var renderQueued = false
    private var autosaveWork: DispatchWorkItem?
    private var dirty = false
    private var lastSnapshot = ""
    private var regularConstraints: [NSLayoutConstraint] = []
    private var compactConstraints: [NSLayoutConstraint] = []
    private var lastShowCamera: Bool
    private var lastTrim: (TimeInterval, TimeInterval)

    init(folder: StudioProjectFolder, initialTime: TimeInterval? = nil) {
        self.folder = folder
        self.initialTime = initialTime
        header = CCHeaderBar(title: folder.project.name, style: .inline)
        lastShowCamera = folder.project.settings.showCamera
        lastTrim = (folder.project.trimStart, folder.project.trimEnd)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var undoManager: UndoManager? { editorUndo }
    override var canBecomeFirstResponder: Bool { true }

    // MARK: - Layout

    override func loadView() {
        let root = UIView()
        root.backgroundColor = CCTheme.color.background
        view = root

        header.showsBack = true
        header.onBack = { [weak self] in self?.close() }
        undoButton.accessibilityLabelOverride = "Undo"
        redoButton.accessibilityLabelOverride = "Redo"
        undoButton.onTap = { [weak self] in self?.performUndo() }
        redoButton.onTap = { [weak self] in self?.performRedo() }
        header.setTrailing([undoButton, redoButton])

        for container in [timelineContainer, inspectorContainer] {
            container.translatesAutoresizingMaskIntoConstraints = false
            container.backgroundColor = .clear
        }
        timelineContainer.accessibilityIdentifier = "studio.timelineContainer"
        inspectorContainer.accessibilityIdentifier = "studio.inspectorContainer"
        for v in [header, stageCard, transport, timelineContainer, inspectorContainer, contextPill] as [UIView] {
            root.addSubview(v)
        }
        contextPill.isHidden = true

        let guide = root.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stageCard.topAnchor.constraint(equalTo: header.bottomAnchor, constant: CCSpace.sm),
            stageCard.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: CCSpace.md),
            transport.topAnchor.constraint(equalTo: stageCard.bottomAnchor, constant: CCSpace.sm),
            transport.leadingAnchor.constraint(equalTo: stageCard.leadingAnchor),
            transport.trailingAnchor.constraint(equalTo: stageCard.trailingAnchor),
            transport.heightAnchor.constraint(equalToConstant: 48),
            timelineContainer.topAnchor.constraint(equalTo: transport.bottomAnchor, constant: CCSpace.sm),
            timelineContainer.leadingAnchor.constraint(equalTo: stageCard.leadingAnchor),
            timelineContainer.trailingAnchor.constraint(equalTo: stageCard.trailingAnchor),
        ])
        // Regular width: the inspector is a 340 pt column (the Mac's 340…480,
        // ideal 380, scaled to a tablet), stage + timeline to its left. The
        // card takes a 16:9 share of the width when there is room; the
        // timeline keeps at least 220 pt and takes what is left.
        let regularStageHeight = stageCard.heightAnchor.constraint(equalTo: stageCard.widthAnchor, multiplier: 9.0 / 16.0)
        regularStageHeight.priority = .defaultHigh
        regularConstraints = [
            inspectorContainer.topAnchor.constraint(equalTo: header.bottomAnchor, constant: CCSpace.sm),
            inspectorContainer.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -CCSpace.md),
            inspectorContainer.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -CCSpace.sm),
            inspectorContainer.widthAnchor.constraint(equalToConstant: 340),
            stageCard.trailingAnchor.constraint(equalTo: inspectorContainer.leadingAnchor, constant: -CCSpace.md),
            regularStageHeight,
            stageCard.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            timelineContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
            timelineContainer.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -CCSpace.sm),
        ]
        // Compact: one column — stage, transport, timeline, inspector.
        let stageHeight = stageCard.heightAnchor.constraint(equalTo: stageCard.widthAnchor, multiplier: 9.0 / 16.0)
        stageHeight.priority = .defaultHigh
        compactConstraints = [
            stageCard.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -CCSpace.md),
            stageHeight,
            stageCard.heightAnchor.constraint(lessThanOrEqualTo: guide.heightAnchor, multiplier: 0.45),
            timelineContainer.heightAnchor.constraint(equalToConstant: 180),
            inspectorContainer.topAnchor.constraint(equalTo: timelineContainer.bottomAnchor, constant: CCSpace.sm),
            inspectorContainer.leadingAnchor.constraint(equalTo: stageCard.leadingAnchor),
            inspectorContainer.trailingAnchor.constraint(equalTo: stageCard.trailingAnchor),
            inspectorContainer.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -CCSpace.sm),
        ]
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        let regular = view.bounds.width >= 700
        if regular, regularConstraints.first?.isActive != true {
            NSLayoutConstraint.deactivate(compactConstraints)
            NSLayoutConstraint.activate(regularConstraints)
        } else if !regular, compactConstraints.first?.isActive != true {
            NSLayoutConstraint.deactivate(regularConstraints)
            NSLayoutConstraint.activate(compactConstraints)
        }
        inspector.setRegularWidth(regular)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        repositionContextPill()
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        wireCanvas()
        wireTransport()
        inspector.install(in: self)
        contextPill.onEditText = { [weak self] in
            guard let self, let id = self.selection.selectedAnnotationID else { return }
            self.canvas.beginInlineEdit(annotationID: id)
        }
        contextPill.onDelete = { [weak self] in self?.deleteSelection() }
        stageCard.onZoomChange = { [weak self] z in
            self?.selection.previewZoom = z
            self?.repositionContextPill()
        }
        updateCanvasSize()
        // The first frame is already at the opening time (no flash of the
        // head, and the springs reset there — not stepped from 0).
        playback.currentTime = min(max(initialTime ?? project.effectiveTrimStart, project.effectiveTrimStart),
                                   project.effectiveTrimEnd)
        startObserving()
        // Studio 4f: every save is kept in the project's on-device History.
        StudioHistory.attach(self)
        let center = NotificationCenter.default
        for name in [NSNotification.Name.NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange,
                     .NSUndoManagerDidRedoChange] {
            center.addObserver(self, selector: #selector(undoStackChanged), name: name, object: editorUndo)
        }
        undoStackChanged()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.playback.setup(for: self.project, initialTime: self.initialTime)
            self.updateCanvasSize()
            self.renderStage()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // However the editor left the screen, the players stop with it.
        if isBeingDismissed || isMovingFromParent { playback.teardown() }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Saves (if anything changed) and closes.
    func close() {
        canvas.endInlineEdit(commit: true)
        playback.setPlaying(false, for: project)
        saveNow()
        playback.teardown()
        if let onClose { onClose() } else { dismiss(animated: true) }
    }

    // MARK: - Canvas wiring (the Mac stage's compositor callbacks)

    private func wireCanvas() {
        let g = canvas.gestures
        canvas.undoManagerProvider = { [weak self] in self?.editorUndo }
        g.onSelectAnnotation = { [weak self] id in
            self?.canvasEventLog?("selAnn=\(self?.name(id) ?? "nil")")
            self?.selection.selectedAnnotationID = id
        }
        g.onSelectHighlight = { [weak self] id in
            self?.canvasEventLog?("selHl=\(self?.name(id) ?? "nil")")
            self?.selection.selectedHighlightID = id
        }
        g.onSelectDepthFocus = { [weak self] id in
            self?.canvasEventLog?("selDepth=\(self?.name(id) ?? "nil")")
            self?.selection.selectedDepthFocusID = id
        }
        g.onSelectBlur = { [weak self] id in
            guard let self else { return }
            self.canvasEventLog?("selBlur=\(self.name(id))")
            self.selection.selectedBlurID = id
            self.renderStage()
        }
        g.onSetZoomFocal = { [weak self] point in
            guard let self else { return }
            self.canvasEventLog?("focal=\(EditorEventFormat.point(point))")
            guard let id = self.selection.selectedZoomID,
                  let index = self.project.zoomRegions.firstIndex(where: { $0.id == id }) else { return }
            self.project.zoomRegions[index].focalPoint = point
            // Aiming the shot by hand means the aim must hold: fixed focus.
            self.project.zoomRegions[index].followsCursor = false
        }
        g.onCreateBlurRegion = { [weak self] rect, style in
            guard let self else { return }
            self.canvasEventLog?("create=\(EditorEventFormat.rect(rect)) \(style.rawValue)")
            self.timelineEdits.createBlurRegion(rect: rect, style: style)
            self.renderStage()
        }
        g.onDragEnded = { [weak self] in
            self?.canvasEventLog?("dragEnded")
            self?.repositionContextPill()
        }
        // Coalesced to one render per run-loop turn, as on the Mac: touches
        // arrive faster than a full render pass completes.
        g.requestRender = { [weak self] in self?.requestRender() }
        canvas.onContextMenu = { [weak self] point in self?.showContextMenu(at: point) }
        canvas.onInlineEditChanged = { [weak self] _ in self?.repositionContextPill() }
        stage.onRender = { [weak self] frame in
            guard let self else { return }
            self.canvas.context = self.stage.core.hitContext(for: frame, selectedBlurID: self.selection.selectedBlurID)
        }
    }

    /// Names ids for the harness log (`EditorShellLab` installs names).
    var eventNames: [UUID: String] = [:]
    private func name(_ id: UUID?) -> String {
        guard let id else { return "nil" }
        return eventNames[id] ?? "?"
    }

    private func wireTransport() {
        transport.onTogglePlay = { [weak self] in
            guard let self else { return }
            self.canvas.endInlineEdit(commit: true)
            self.playback.togglePlayback(for: self.project)
        }
        transport.onStep = { [weak self] frames in
            guard let self else { return }
            self.playback.step(frames: frames, for: self.project)
        }
        transport.onScrub = { [weak self] output, exact in
            guard let self else { return }
            self.playback.scrub(to: self.timeMap.sourceTime(forOutput: output), for: self.project, exact: exact)
        }
    }

    /// Output ↔ source over the trim window and speed regions (shared map).
    private var timeMap: SpeedTimeMap { SpeedTimeMap(trimmedOutputOf: shownProject) }

    // MARK: - Observation

    private func startObserving() {
        // The stage — the Mac stage's preview observation: everything the
        // frame reads registers here (the render runs inside the loop).
        observations.append(SurfaceObservation { [weak self] in self?.renderStage() })
        // Transport + chrome.
        observations.append(SurfaceObservation { [weak self] in
            guard let self else { return }
            let map = self.timeMap
            let output = map.outputTime(forSource: self.playback.currentTime)
            self.transport.update(isPlaying: self.playback.isPlaying, outputTime: output,
                                  outputDuration: map.outputDuration)
            _ = self.selection.selectedAnnotationID
            self.repositionContextPill()
        })
        // Playback side effects (the Mac shell's playback observation).
        observations.append(SurfaceObservation { [weak self] in
            guard let self else { return }
            let show = self.project.settings.showCamera
            let trim = (self.project.trimStart, self.project.trimEnd)
            if show != self.lastShowCamera {
                self.lastShowCamera = show
                self.playback.setCameraEnabled(show, for: self.project)
            }
            if trim != self.lastTrim {
                self.lastTrim = trim
                self.playback.syncToTrimRange(for: self.project)
            }
            self.playback.player?.isMuted = self.project.settings.muteRecordedAudio
            self.playback.applyCursorSmoothing(settings: self.project.settings, trimEnd: self.project.effectiveTrimEnd)
        })
        // Canvas size follows the project's reference canvas and aspect.
        observations.append(SurfaceObservation { [weak self] in
            guard let self else { return }
            _ = self.project.referenceCanvasSize
            _ = self.project.settings.aspectRatio
            _ = self.project.settings.exportSettings.resolution
            _ = self.playback.videoSize
            self.updateCanvasSize()
        })
        // Autosave: the Mac's full persisted-state signature, debounced.
        observations.append(SurfaceObservation { [weak self] in
            guard let self else { return }
            let snapshot = self.projectSnapshot()
            defer { self.lastSnapshot = snapshot }
            guard !self.lastSnapshot.isEmpty, snapshot != self.lastSnapshot else { return }
            self.scheduleAutosave()
        })
    }

    private func updateCanvasSize() {
        guard isViewLoaded else { return }
        stage.virtualCanvasSize = canvasOverride
            ?? PreviewStageView.virtualCanvas(for: project, sourceSize: playback.videoSize)
    }

    // MARK: - Rendering

    /// Everything one frame needs — the Mac stage's `FrameInput`.
    func frameInput() -> PreviewCompositorCore.FrameInput {
        let project = shownProject
        let showCameraPlayer = playback.showsCameraPlayer(for: project)
        var isPlaying = playback.isPlaying
        var player = playback.player
        #if DEBUG
        if Self.probeDefect == .blurWhilePlaying { isPlaying = false }
        if Self.probeDefect == .frozenFrames { player = nil }
        #endif
        return PreviewCompositorCore.FrameInput(
            project: project,
            currentTime: playback.currentTime,
            isPlaying: isPlaying,
            isScrubbing: playback.isScrubbing,
            cursorEvents: playback.cursorEvents,
            scrollTimes: playback.keystrokeEvents.lazy.filter { $0.category == .scroll }.map(\.timestamp).sorted(),
            keystrokeEvents: playback.keystrokeEvents,
            cursorCoordinateSize: playback.cursorCoordinateSize,
            videoSize: playback.videoSize,
            player: player,
            cameraPlayer: showCameraPlayer ? playback.cameraPlayer : nil,
            cameraPosterImage: project.settings.showCamera ? playback.cameraPosterImage : nil,
            cameraVideoAspect: playback.cameraVideoAspect,
            videoPosterImage: playback.videoPosterImage,
            selectedAnnotationID: selection.selectedAnnotationID,
            selectedHighlightID: selection.selectedHighlightID,
            selectedBlurID: selection.selectedBlurID,
            selectedDepthFocusID: selection.selectedDepthFocusID,
            selectedZoomID: selection.selectedZoomID,
            cameraMask: nil,
            cameraSourceLeadIn: playback.cameraSourceLeadIn)
    }

    #if DEBUG
    /// Probe seams — INJECTED DEFECTS for `--editor-shell --inject …`: the
    /// stage told it is paused while playing (the playback exception
    /// broken), or never handed the player (frames frozen on the poster).
    enum ProbeDefect { case none, blurWhilePlaying, frozenFrames }
    static var probeDefect = ProbeDefect.none
    #endif

    /// Renders now (the stage keeps the input for its next layout).
    func renderStage() {
        guard isViewLoaded else { return }
        stage.schedule(frameInput())
    }

    private func requestRender() {
        guard !renderQueued else { return }
        renderQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.renderQueued = false
            self.renderStage()
        }
    }

    // MARK: - Contextual pill + long-press menu

    private func repositionContextPill() {
        guard isViewLoaded else { return }
        guard !playback.isPlaying, !canvas.isActivelyDragging, canvas.inlineEditingID == nil,
              let id = selection.selectedAnnotationID,
              let annotation = project.annotations.first(where: { $0.id == id }),
              let rect = canvas.selectedAnnotationRect() else {
            contextPill.isHidden = true
            return
        }
        contextPill.configure(for: annotation)
        let r = view.convert(rect, from: canvas)
        let card = view.convert(stageCard.bounds, from: stageCard)
        let size = contextPill.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        let gap: CGFloat = 10
        var y = r.minY - gap - size.height
        if y < card.minY + 8 { y = min(card.maxY - size.height - 8, r.maxY + gap) }
        let x = min(max(r.midX - size.width / 2, card.minX + 8), max(card.minX + 8, card.maxX - size.width - 8))
        contextPill.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        contextPill.isHidden = false
    }

    private func showContextMenu(at point: CGPoint) {
        let sheet = CCActionSheet()
        var any = false
        if let id = selection.selectedAnnotationID, let a = project.annotations.first(where: { $0.id == id }) {
            if a.type == .text || a.type == .callout {
                sheet.addAction("Edit Text", symbol: "pencil") { [weak self] in self?.canvas.beginInlineEdit(annotationID: id) }
            }
            sheet.addAction("Delete \(TimelineEdits.annotationLaneLabel(for: a))", symbol: "trash", destructive: true) {
                [weak self] in self?.deleteSelection()
            }
            any = true
        } else if selection.selectedBlurID != nil || selection.selectedHighlightID != nil
                    || selection.selectedDepthFocusID != nil {
            sheet.addAction("Delete Region", symbol: "trash", destructive: true) { [weak self] in self?.deleteSelection() }
            any = true
        }
        guard any else { return }
        sheet.present(from: self, source: stageCard)
    }

    /// Deletes the selected annotation or region through the shared timeline
    /// edits (their undo registration, their values).
    func deleteSelection() {
        guard !isPreviewingVersion else { return }
        if let id = selection.selectedAnnotationID {
            timelineEdits.deleteAnnotation(id: id)
        } else if let id = selection.selectedBlurID {
            timelineEdits.deleteBlurRegion(id: id)
        } else if let id = selection.selectedHighlightID {
            timelineEdits.deleteHighlightRegion(id: id)
        } else if let id = selection.selectedDepthFocusID {
            timelineEdits.deleteDepthFocusRegion(id: id)
        }
        renderStage()
    }

    // MARK: - Undo

    func performUndo() {
        canvas.endInlineEdit(commit: true)
        guard editorUndo.canUndo, !isPreviewingVersion else { return }
        editorUndo.undo()
        renderStage()
    }

    func performRedo() {
        guard editorUndo.canRedo, !isPreviewingVersion else { return }
        editorUndo.redo()
        renderStage()
    }

    @objc private func undoStackChanged() {
        undoButton.isEnabled = editorUndo.canUndo && !isPreviewingVersion
        redoButton.isEnabled = editorUndo.canRedo && !isPreviewingVersion
    }

    /// Read-only while a History version is on the stage.
    private func stageOverrideChanged() {
        guard isViewLoaded else { return }
        let editable = !isPreviewingVersion
        canvas.endInlineEdit(commit: true)
        if !editable {
            selection.selectedAnnotationID = nil
            selection.selectedBlurID = nil
            selection.selectedHighlightID = nil
            selection.selectedDepthFocusID = nil
            selection.selectedZoomID = nil
            selection.selectedTiltID = nil
        }
        canvas.isUserInteractionEnabled = editable
        for container in [timelineContainer, inspectorContainer] {
            container.isUserInteractionEnabled = editable
            container.alpha = editable ? 1 : 0.45
        }
        contextPill.isHidden = contextPill.isHidden || !editable
        undoStackChanged()
        renderStage()
    }

    // MARK: - Keyboard (hardware keyboards; iPad)

    override var keyCommands: [UIKeyCommand]? {
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(keyEscape))
        escape.wantsPriorityOverSystemBehavior = true
        var commands = [
            escape,
            UIKeyCommand(title: "Undo", action: #selector(keyUndo), input: "z", modifierFlags: .command),
            UIKeyCommand(title: "Redo", action: #selector(keyRedo), input: "z", modifierFlags: [.command, .shift]),
        ]
        if canvas.inlineEditingID == nil {
            commands += [
                UIKeyCommand(title: "Play / Pause", action: #selector(keyPlay), input: " ", modifierFlags: []),
                UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(keyStepBack)),
                UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(keyStepForward)),
                UIKeyCommand(input: UIKeyCommand.inputDelete, modifierFlags: [], action: #selector(keyDelete)),
            ]
        }
        return commands
    }

    @objc private func keyEscape() { canvas.escape() }
    @objc private func keyUndo() { performUndo() }
    @objc private func keyRedo() { performRedo() }
    @objc private func keyPlay() { transport.onTogglePlay?() }
    @objc private func keyStepBack() { playback.step(frames: -1, for: project) }
    @objc private func keyStepForward() { playback.step(frames: 1, for: project) }
    @objc private func keyDelete() { deleteSelection() }

    // MARK: - Saving

    private func projectSnapshot() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(project)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    private func scheduleAutosave() {
        dirty = true
        autosaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        autosaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    /// Writes project.json now if anything changed since the last save (the
    /// folder merges onto the document) — dirty-gated like the Mac's
    /// `saveIfDirty`, so opening and closing never rewrites a project.
    func saveNow() {
        autosaveWork?.cancel()
        autosaveWork = nil
        guard dirty else { return }
        do {
            try folder.save()
            dirty = false
        } catch {
            toaster.show(title: "Couldn't save this project", message: error.localizedDescription, variant: .destructive)
        }
    }
}

/// Number formats of the Mac `--preview-gesture-test` transcript (`%.6f`).
enum EditorEventFormat {
    static func f(_ v: CGFloat) -> String { String(format: "%.6f", Double(v)) }
    static func point(_ p: CGPoint) -> String { "(\(f(p.x)),\(f(p.y)))" }
    static func rect(_ r: CGRect) -> String { "[\(f(r.minX)),\(f(r.minY)) \(f(r.width))x\(f(r.height))]" }
}

/// The contextual pill over a selected annotation — the Mac's floating
/// annotation pill, docked iOS-edit-menu style above the selection.
///
/// TODO(4d): the annotation's colour / font / weight / size controls (the
/// Mac pill's) mount here from the inspector's annotation pane.
final class EditorContextPill: CCSurface {
    var onEditText: (() -> Void)?
    var onDelete: (() -> Void)?

    private let edit = CCButton(title: "Edit", symbol: "pencil", style: .ghost, size: .sm, radius: .full)
    private let delete = CCButton(symbol: "trash", style: .ghost, size: .sm, radius: .full)

    init() {
        super.init(.raised, tint: CCTheme.color.popover, radius: .full)
        translatesAutoresizingMaskIntoConstraints = true
        delete.accessibilityLabelOverride = "Delete"
        edit.onTap = { [weak self] in self?.onEditText?() }
        delete.onTap = { [weak self] in self?.onDelete?() }
        let row = UIStackView(arrangedSubviews: [edit, delete])
        row.spacing = 0
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(for annotation: Annotation) {
        edit.isHidden = !(annotation.type == .text || annotation.type == .callout)
    }
}
