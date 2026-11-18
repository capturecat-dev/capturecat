import AVFoundation
import UIKit

/// The iOS studio's editor screen — the UIKit twin of the Mac's
/// `EditorShellViewController` + `EditorStageViewController`, laid out the
/// way mobile video editors are (the editor redesign):
///
///     ┌──────────────────────┐
///     │ ‹  Title       ⟲ ⟳ ⇪ │ header: back, sync dot, title, undo, redo, export
///     │     VIDEO PREVIEW    │ the stage card — the larger share of the height
///     │  0:06 / 0:20  ‹▶›  ⤢ │ ONE transport row (time, frame steps, play, full screen)
///     │ ─────────┃────────── │ the timeline: the playhead FIXED at the centre,
///     │ ▓▓▓▓▓▓▓▓▓┃▓▓▓▓▓▓▓▓▓▓ │ dragging scrolls + scrubs, playback scrolls the
///     │   ▬▬     ┃   ▬▬      │ content under it (pinch zooms)
///     ├──────────────────────┤
///     │ +  ✂  🎨 ↖ 📷 🔊 ✨ … │ the tool bar (`EditorToolBar`)
///     └──────────────────────┘
///
/// A pane tool opens the inspector's pane as a PANEL growing up from
/// the tool bar (which stays) — only that pane, fitted and capped so the
/// preview is never covered; the timeline's lanes compress above it (house
/// growth bounce at the pushed edge; a cross-fade under Reduce Motion). Selecting
/// something swaps the tools for its CONTEXT keys (split, duplicate, delete,
/// speed, its menu, Adjust = its pane). A phone on its side keeps the stage
/// and timeline in a column with the tool bar as a rail on the trailing edge;
/// its panes open as a side panel that pushes the column narrower. iPad and
/// the iPhone Duo's crease layouts keep the inspector COLUMN (it fits) with
/// the same transport row, centred-playhead timeline and the tool bar's
/// action keys under the timeline.
///
/// State flows in through `withObservationTracking` loops (`SurfaceObservation`)
/// over the project, the playback controller and the shared selection
/// (`EditorShellSelection`), and out through callbacks — the house rule.
/// Rendering is the shared compositor (`PreviewStageView`), editing the
/// shared gesture core (`EditorCanvasView`) and the shared timeline edits,
/// playback `StudioPlaybackController`.
@available(iOS 26, *)
final class EditorViewController: UIViewController {
    let folder: StudioProjectFolder
    var project: Project { folder.project }
    let playback = StudioPlaybackController()
    let selection = EditorShellSelection()
    private let editorUndo = UndoManager()

    /// Where the shared timeline edits run for the stage's callbacks.
    lazy var timelineEdits: TimelineEditing = EditorDefaultEdits(
        project: project, selection: selection,
        undoManager: { [weak self] in self?.editorUndo },
        currentTime: { [weak self] in self?.playback.currentTime ?? 0 })

    // Views.
    let header: CCHeaderBar
    let stageCard = EditorStageCardView()
    /// The timeline region's toolbar row (the Mac's): transport, timecode,
    /// undo / redo and the timeline's edit keys.
    let transport = EditorTransportBar()
    /// The timeline (Studio 4c) mounts here.
    let timelineContainer = UIView()
    /// The inspector's COLUMN (iPad, the Duo's crease layouts); zero-sized
    /// where the inspector is a panel the tool bar opens.
    let inspectorContainer = UIView()
    /// Tools / sub-options / context keys (bottom row, landscape rail, or
    /// under the timeline beside an inspector column).
    let toolBar = EditorToolBar()
    /// The inspector (Studio 4d) — its `on…` feature hooks are wired by 4e/4f.
    private(set) lazy var inspector = StudioInspectorController(
        project: project, selection: selection,
        undoManager: { [weak self] in self?.editorUndo },
        currentTime: { [weak self] in self?.playback.currentTime ?? 0 })
    /// The timeline (Studio 4c), mounted in `timelineContainer`. It edits
    /// the same project, selection and undo stack as the stage and inspector.
    private(set) lazy var timelinePlayback = EditorTimelinePlayback(
        playback: playback, project: { [unowned self] in self.project })
    private(set) lazy var timeline = StudioTimelineViewController(
        project: project, selection: selection, playback: timelinePlayback, undoManager: editorUndo,
        chrome: .embedded)
    private let contextPill = EditorContextPill()
    /// The header's aspect chip ("16:9" ↕) — the Mac bar's aspect select.
    let aspectChip = EditorAspectChip()
    /// Studio 3d: the header's "Export…" key — a ghost key on BLUE-TINTED
    /// glass (the primary), white ink; the opaque primary under Reduce Transparency.
    let exportButton = CCButton(title: "Export…", style: .ghost, size: .sm, radius: .full, haptics: true)
    /// The floating chrome's glass (Liquid Glass, iOS 26): the header's keys
    /// ride capsules, the aspect chip and Export in ONE container so they
    /// merge and morph as neighbours. Content (stage, lanes) stays flat.
    private(set) lazy var aspectGlass = CCGlassView.wrapping(aspectChip, shape: .capsule)
    private(set) lazy var exportGlass = CCGlassView.wrapping(exportButton, shape: .capsule, tint: CCTheme.color.primary)
    let headerGlassGroup = CCGlassGroup(spacing: CCSpace.sm)
    /// Stacked: the bottom bar's top (it drops toward the home indicator).
    private var toolBarDock: NSLayoutConstraint!

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
    /// The fresh person mask for the camera looks (Studio 4e, background
    /// removal) — queues the mask job when a look needs it, as the Mac
    /// editor's render does; nil draws every look as the plain bubble.
    var cameraMaskProvider: (Project) -> CameraMaskTrack? = { StudioBackgroundRemoval.cameraMask(for: $0) }

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
    private var constraintSets: [Arrangement: [NSLayoutConstraint]] = [:]
    private var timelineHeights: [Arrangement: NSLayoutConstraint] = [:]
    private(set) var activeArrangement: Arrangement?
    /// The crease, as a layout guide (zero-sized when there is none), and
    /// the equal spaces that centre the stage in its half.
    private let creaseGuide = UILayoutGuide()
    private let stageTopSpace = UILayoutGuide()
    private let stageBottomSpace = UILayoutGuide()
    /// Landscape: the side panel's slot between the column and the rail
    /// (its width grows from 0 as the panel opens — the pushed edge).
    private let sidePanelGuide = UILayoutGuide()
    private var creaseLeft: NSLayoutConstraint!
    private var creaseTop: NSLayoutConstraint!
    private var creaseWidth: NSLayoutConstraint!
    private var creaseHeight: NSLayoutConstraint!
    private var sideSlotWidth: NSLayoutConstraint!
    /// Portrait phone: the stage's height (the canvas's own aspect across
    /// the full width, capped so the timeline and a panel always fit).
    private var stageHeight: NSLayoutConstraint!
    /// The inspector view's constraints per presentation.
    private var inspectorColumn: [NSLayoutConstraint] = []
    private var inspectorBottom: [NSLayoutConstraint] = []
    private var inspectorSide: [NSLayoutConstraint] = []
    /// Bottom panel: its height (0 = closed). It sits on the tool bar and
    /// grows UP (the pushed edge), as tall as its controls, capped by `panelCap`.
    private var panelHeight: NSLayoutConstraint!
    /// The height the panel is heading for (an animation in flight included).
    private var panelTarget: CGFloat = 0
    /// Bottom panel: the timeline's lanes end above the panel (they
    /// compress and scroll; its container — and so the stage — never moves).
    private var timelineSquash: NSLayoutConstraint!
    private var expandedSet: [NSLayoutConstraint] = []
    private var lastShowCamera: Bool
    private var lastTrim: (TimeInterval, TimeInterval)
    private var lastVoiceClips: [VoiceOverClip]?

    /// A panel is open (portrait / landscape phone).
    private(set) var isPanelOpen = false
    /// The option the open panel shows (nil = a whole pane).
    private(set) var openOption: InspectorPanelOption?
    /// The full-screen preview: timeline, tool bar and inspector away.
    private(set) var isPreviewExpanded = false

    /// The side panel's width (landscape phone).
    static let sidePanelWidth: CGFloat = 300

    init(folder: StudioProjectFolder, initialTime: TimeInterval? = nil) {
        self.folder = folder
        self.initialTime = initialTime
        header = CCHeaderBar(title: folder.project.name, style: .editor)
        lastShowCamera = folder.project.settings.showCamera
        lastTrim = (folder.project.trimStart, folder.project.trimEnd)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var undoManager: UndoManager? { editorUndo }
    override var canBecomeFirstResponder: Bool { true }

    #if DEBUG
    /// Probe seam — INJECTED DEFECT (`stage-card`): the stage is inset from
    /// the screen's edges again (with `EditorStageCardView.probeCard`).
    static var probeInsetStage = false
    #endif

    // MARK: - Layout

    override func loadView() {
        let root = UIView()
        root.backgroundColor = CCTheme.color.background
        view = root

        header.showsBack = true
        header.onBack = { [weak self] in self?.close() }
        header.setBack(symbol: "square.grid.2x2", title: "Captures", label: "Captures")
        header.backButton.accessibilityHint = "Saves and returns to your captures."
        exportButton.accessibilityLabelOverride = "Export"
        exportButton.accessibilityIdentifier = "studio.export"
        exportButton.onTap = { [weak self] in self?.presentExport() }
        aspectChip.onSelect = { [weak self] ratio in self?.setAspectRatio(ratio) }
        aspectChip.presenter = self
        aspectChip.layer.cornerRadius = 17
        exportButton.inkOverride = CCTheme.color.primaryForeground
        header.adoptGlassKeys()
        aspectGlass.accessibilityIdentifier = "studio.aspect.glass"
        exportGlass.accessibilityIdentifier = "studio.export.glass"
        let headerKeys = UIStackView(arrangedSubviews: [aspectGlass, exportGlass])
        headerKeys.spacing = CCSpace.sm
        headerKeys.alignment = .center
        headerKeys.translatesAutoresizingMaskIntoConstraints = false
        headerGlassGroup.contentView.addSubview(headerKeys)
        NSLayoutConstraint.activate([
            headerKeys.leadingAnchor.constraint(equalTo: headerGlassGroup.contentView.leadingAnchor),
            headerKeys.trailingAnchor.constraint(equalTo: headerGlassGroup.contentView.trailingAnchor),
            headerKeys.topAnchor.constraint(equalTo: headerGlassGroup.contentView.topAnchor),
            headerKeys.bottomAnchor.constraint(equalTo: headerGlassGroup.contentView.bottomAnchor),
            // 44 pt tall: the keys' expanded touch targets stay inside it
            // (a hit test never reaches a key through a shorter container).
            headerKeys.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        header.setTrailing([headerGlassGroup])

        for container in [timelineContainer, inspectorContainer] {
            container.translatesAutoresizingMaskIntoConstraints = false
        }
        // The timeline region: ONE full-width surface (the toolbar row on
        // top, the lanes under it) — the Mac panel's tone, no card.
        timelineContainer.backgroundColor = CCTheme.color.card
        inspectorContainer.backgroundColor = .clear
        timelineContainer.accessibilityIdentifier = "studio.timelineContainer"
        inspectorContainer.accessibilityIdentifier = "studio.inspectorContainer"
        for v in [header, stageCard, timelineContainer, transport, inspectorContainer, toolBar, contextPill] as [UIView] {
            root.addSubview(v)
        }
        contextPill.isHidden = true

        let guide = root.safeAreaLayoutGuide
        for g in [creaseGuide, stageTopSpace, stageBottomSpace, sidePanelGuide] { root.addLayoutGuide(g) }
        // The crease's frame (zero when there is none), set in layout.
        creaseLeft = creaseGuide.leftAnchor.constraint(equalTo: root.leftAnchor)
        creaseTop = creaseGuide.topAnchor.constraint(equalTo: root.topAnchor)
        creaseWidth = creaseGuide.widthAnchor.constraint(equalToConstant: 0)
        creaseHeight = creaseGuide.heightAnchor.constraint(equalToConstant: 0)
        sideSlotWidth = sidePanelGuide.widthAnchor.constraint(equalToConstant: 0)
        stageHeight = stageCard.heightAnchor.constraint(equalToConstant: 220)
        toolBarDock = toolBar.topAnchor.constraint(equalTo: guide.bottomAnchor, constant: -EditorToolBar.thickness)
        var edge: CGFloat = 0
        #if DEBUG
        if Self.probeInsetStage { edge = CCSpace.md }
        #endif
        NSLayoutConstraint.activate([
            creaseLeft, creaseTop, creaseWidth, creaseHeight,
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            // The toolbar row heads the timeline region, straight under the stage.
            transport.topAnchor.constraint(equalTo: stageCard.bottomAnchor),
            transport.leadingAnchor.constraint(equalTo: stageCard.leadingAnchor),
            transport.trailingAnchor.constraint(equalTo: stageCard.trailingAnchor),
            transport.heightAnchor.constraint(equalToConstant: EditorTransportBar.height),
        ])
        func sixteenByNine() -> NSLayoutConstraint {
            let c = stageCard.heightAnchor.constraint(equalTo: stageCard.widthAnchor, multiplier: 9.0 / 16.0)
            c.priority = .defaultHigh
            return c
        }
        // A zero-sized inspector container where the inspector is a panel
        // (it stays inside the editor, under the tool bar).
        func noColumn() -> [NSLayoutConstraint] {
            [inspectorContainer.leadingAnchor.constraint(equalTo: toolBar.leadingAnchor),
             inspectorContainer.topAnchor.constraint(equalTo: toolBar.topAnchor),
             inspectorContainer.widthAnchor.constraint(equalToConstant: 0),
             inspectorContainer.heightAnchor.constraint(equalToConstant: 0)]
        }
        // The tool bar as a row beside an inspector column: the bottom of
        // the timeline region, as wide as it (flat, a hairline above).
        func actionRow(under view: UIView, bottom: NSLayoutYAxisAnchor) -> [NSLayoutConstraint] {
            [toolBar.topAnchor.constraint(equalTo: view.bottomAnchor),
             toolBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
             toolBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
             toolBar.heightAnchor.constraint(equalToConstant: EditorToolBar.thickness),
             toolBar.bottomAnchor.constraint(lessThanOrEqualTo: bottom)]
        }

        // Portrait phone: the stage EDGE TO EDGE at its canvas's aspect, the
        // timeline region (toolbar row + lanes) full width under it down to
        // the tool bar, docked on the screen's bottom edge.
        constraintSets[.stacked] = [
            stageCard.topAnchor.constraint(equalTo: header.bottomAnchor),
            stageCard.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: edge),
            stageCard.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -edge),
            stageHeight,
            timelineContainer.topAnchor.constraint(equalTo: transport.bottomAnchor),
            timelineContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            timelineContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            timelineContainer.bottomAnchor.constraint(equalTo: toolBar.topAnchor),
            toolBarDock,
            toolBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ] + noColumn()
        // Regular width: the inspector is a 340 pt flat column on the
        // trailing edge (the Mac's), the stage + toolbar row + timeline + the
        // tool bar's action row to its left, edge to edge. The stage takes a
        // 16:9 share of the width when there is room; the timeline keeps at
        // least 220 pt.
        constraintSets[.sideBySide] = [
            stageCard.topAnchor.constraint(equalTo: header.bottomAnchor),
            stageCard.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: edge),
            timelineContainer.topAnchor.constraint(equalTo: transport.bottomAnchor),
            timelineContainer.leadingAnchor.constraint(equalTo: stageCard.leadingAnchor),
            timelineContainer.trailingAnchor.constraint(equalTo: stageCard.trailingAnchor),
            inspectorContainer.topAnchor.constraint(equalTo: header.bottomAnchor),
            inspectorContainer.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            inspectorContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            inspectorContainer.widthAnchor.constraint(equalToConstant: 340),
            stageCard.trailingAnchor.constraint(equalTo: inspectorContainer.leadingAnchor),
            sixteenByNine(),
            stageCard.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            timelineContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
            toolBar.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            toolBar.topAnchor.constraint(equalTo: timelineContainer.bottomAnchor),
            toolBar.leadingAnchor.constraint(equalTo: timelineContainer.leadingAnchor),
            toolBar.trailingAnchor.constraint(equalTo: timelineContainer.trailingAnchor),
            toolBar.heightAnchor.constraint(equalToConstant: EditorToolBar.thickness),
        ]
        // A crease top to bottom (iPhone Duo unfolded): the stage and its
        // toolbar row fill one half, centred in it; the timeline, the action
        // row and the inspector take the other half — nothing straddles it.
        let vTimelineHeight = timelineContainer.heightAnchor.constraint(equalToConstant: 220)
        timelineHeights[.splitAtVerticalCrease] = vTimelineHeight
        constraintSets[.splitAtVerticalCrease] = [
            stageCard.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            stageCard.trailingAnchor.constraint(equalTo: creaseGuide.leadingAnchor),
            sixteenByNine(),
            stageCard.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            stageTopSpace.topAnchor.constraint(equalTo: header.bottomAnchor, constant: CCSpace.sm),
            stageTopSpace.bottomAnchor.constraint(equalTo: stageCard.topAnchor),
            stageBottomSpace.topAnchor.constraint(equalTo: transport.bottomAnchor),
            stageBottomSpace.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -CCSpace.sm),
            stageTopSpace.heightAnchor.constraint(equalTo: stageBottomSpace.heightAnchor),
            timelineContainer.topAnchor.constraint(equalTo: header.bottomAnchor),
            timelineContainer.leadingAnchor.constraint(equalTo: creaseGuide.trailingAnchor),
            timelineContainer.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            vTimelineHeight,
            inspectorContainer.topAnchor.constraint(equalTo: toolBar.bottomAnchor),
            inspectorContainer.leadingAnchor.constraint(equalTo: timelineContainer.leadingAnchor),
            inspectorContainer.trailingAnchor.constraint(equalTo: timelineContainer.trailingAnchor),
            inspectorContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ] + actionRow(under: timelineContainer, bottom: inspectorContainer.topAnchor)
        // A crease side to side: stage and its toolbar row above it;
        // timeline, action row and inspector below.
        let hTimelineHeight = timelineContainer.heightAnchor.constraint(equalToConstant: 180)
        timelineHeights[.splitAtHorizontalCrease] = hTimelineHeight
        constraintSets[.splitAtHorizontalCrease] = [
            stageCard.topAnchor.constraint(equalTo: header.bottomAnchor),
            stageCard.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            stageCard.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            sixteenByNine(),
            transport.bottomAnchor.constraint(lessThanOrEqualTo: creaseGuide.topAnchor, constant: -CCSpace.sm),
            timelineContainer.topAnchor.constraint(equalTo: creaseGuide.bottomAnchor, constant: CCSpace.sm),
            timelineContainer.leadingAnchor.constraint(equalTo: stageCard.leadingAnchor),
            timelineContainer.trailingAnchor.constraint(equalTo: stageCard.trailingAnchor),
            hTimelineHeight,
            inspectorContainer.topAnchor.constraint(equalTo: toolBar.bottomAnchor),
            inspectorContainer.leadingAnchor.constraint(equalTo: stageCard.leadingAnchor),
            inspectorContainer.trailingAnchor.constraint(equalTo: stageCard.trailingAnchor),
            inspectorContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ] + actionRow(under: timelineContainer, bottom: inspectorContainer.topAnchor)
        // A phone on its side (compact height): the height limits the video,
        // so the tool bar is a rail down the trailing edge and the stage,
        // toolbar row and a slim timeline fill the column beside it, edge to
        // edge. A sub-option opens as a side panel between them, pushing the
        // column narrower.
        let lTimelineHeight = timelineContainer.heightAnchor.constraint(equalToConstant: 110)
        timelineHeights[.landscapeCompact] = lTimelineHeight
        constraintSets[.landscapeCompact] = [
            toolBar.topAnchor.constraint(equalTo: header.bottomAnchor),
            toolBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            toolBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolBar.leadingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -EditorToolBar.railWidth),
            sidePanelGuide.trailingAnchor.constraint(equalTo: toolBar.leadingAnchor),
            sidePanelGuide.topAnchor.constraint(equalTo: header.bottomAnchor),
            sidePanelGuide.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sideSlotWidth,
            stageCard.topAnchor.constraint(equalTo: header.bottomAnchor),
            stageCard.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: edge),
            stageCard.trailingAnchor.constraint(equalTo: sidePanelGuide.leadingAnchor),
            stageCard.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),
            timelineContainer.topAnchor.constraint(equalTo: transport.bottomAnchor),
            timelineContainer.leadingAnchor.constraint(equalTo: stageCard.leadingAnchor),
            timelineContainer.trailingAnchor.constraint(equalTo: stageCard.trailingAnchor),
            timelineContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            lTimelineHeight,
        ] + noColumn()
        // The full-screen preview: the stage and its toolbar row take the
        // whole editor under the header (any arrangement without a crease).
        expandedSet = [
            stageCard.topAnchor.constraint(equalTo: header.bottomAnchor),
            stageCard.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stageCard.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            transport.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            timelineContainer.topAnchor.constraint(equalTo: root.bottomAnchor),
            timelineContainer.leadingAnchor.constraint(equalTo: stageCard.leadingAnchor),
            timelineContainer.trailingAnchor.constraint(equalTo: stageCard.trailingAnchor),
            timelineContainer.heightAnchor.constraint(equalToConstant: 1),
            toolBar.topAnchor.constraint(equalTo: root.bottomAnchor),
            toolBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolBar.heightAnchor.constraint(equalToConstant: 1),
        ] + noColumn()
    }

    /// The bottom panel's bottom: on the tool bar's top.
    private func panelBottom(_ v: UIView) -> NSLayoutConstraint {
        #if DEBUG
        if Self.probePanelDefect == .overToolBar {
            return v.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        }
        #endif
        return v.bottomAnchor.constraint(equalTo: toolBar.topAnchor)
    }

    /// Constrains the inspector's view for each presentation (called once
    /// the inspector is installed).
    private func constrainInspector() {
        let v = inspector.view!
        let root = view!
        inspectorColumn = [
            v.leadingAnchor.constraint(equalTo: inspectorContainer.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: inspectorContainer.trailingAnchor),
            v.topAnchor.constraint(equalTo: inspectorContainer.topAnchor),
            v.bottomAnchor.constraint(equalTo: inspectorContainer.bottomAnchor),
        ]
        // The bottom panel spans the width directly ABOVE the tool bar (which
        // stays on screen) and grows up from it; the timeline's lanes give
        // way above it — never the preview or the toolbar row.
        panelHeight = v.heightAnchor.constraint(equalToConstant: 0)
        var inset: CGFloat = 0
        #if DEBUG
        if StudioInspectorController.probePanelCard { inset = CCSpace.sm }
        #endif
        inspectorBottom = [
            v.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            v.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),
            panelBottom(v),
            panelHeight,
        ]
        timelineSquash = timeline.view.bottomAnchor.constraint(lessThanOrEqualTo: v.topAnchor)
        // Strong but not required: the lanes compress, never the panel.
        timelineSquash.priority = .init(999)
        timeline.view.heightAnchor.constraint(greaterThanOrEqualToConstant: 0).isActive = true
        // The side panel rides the slot's leading (pushed) edge, its far
        // side tucked under the rail while the slot is narrow.
        inspectorSide = [
            v.leadingAnchor.constraint(equalTo: sidePanelGuide.leadingAnchor),
            v.widthAnchor.constraint(equalToConstant: Self.sidePanelWidth),
            v.topAnchor.constraint(equalTo: header.bottomAnchor),
            v.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ]
        NSLayoutConstraint.activate(inspectorColumn)
    }

    /// How the editor's regions are laid out.
    enum Arrangement: String {
        /// Compact size classes: one column, the tool bar along the bottom.
        case stacked
        /// Both size classes regular: an inspector column beside the stage.
        case sideBySide
        /// A crease top to bottom: stage | timeline over inspector.
        case splitAtVerticalCrease
        /// A crease side to side: stage over timeline and inspector.
        case splitAtHorizontalCrease
        /// Compact height (a phone on its side): stage over a slim timeline,
        /// the tool bar a rail on the trailing edge.
        case landscapeCompact
    }

    /// The arrangement for the current size classes and fold. A crease
    /// wins: nothing may straddle it, whatever the size classes.
    var arrangement: Arrangement {
        switch crease {
        case .vertical?: return .splitAtVerticalCrease
        case .horizontal?: return .splitAtHorizontalCrease
        case nil:
            if usesRegularLayout { return .sideBySide }
            return traitCollection.verticalSizeClass == .compact ? .landscapeCompact : .stacked
        }
    }

    /// The fold's crease across the editor, if any (`FoldingDisplay`).
    var crease: FoldingDisplay.Crease? {
        #if DEBUG
        if Self.probeDefect == .ignoresCrease { return nil }
        #endif
        return FoldingDisplay.crease(in: view)
    }

    /// The side-by-side layout (inspector column beside the stage): both size
    /// classes regular — iPad full screen and the iPhone Duo's inner display.
    /// Size classes, not a width breakpoint: they follow fold / unfold, Split
    /// View and Stage Manager, and keep a landscape phone (regular width,
    /// compact height) on the layout that fits its height. Read here in
    /// layout, UIKit's automatic trait tracking re-lays out on a change.
    var usesRegularLayout: Bool {
        #if DEBUG
        if Self.probeDefect == .ignoresSizeClass { return false }
        #endif
        return traitCollection.horizontalSizeClass == .regular && traitCollection.verticalSizeClass == .regular
    }

    /// How the inspector shows in an arrangement.
    func inspectorPresentation(for arrangement: Arrangement) -> StudioInspectorController.Presentation {
        switch arrangement {
        case .stacked: return .bottomPanel
        case .landscapeCompact: return .sidePanel
        case .sideBySide, .splitAtVerticalCrease, .splitAtHorizontalCrease: return .column
        }
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        let crease = self.crease
        let arrangement = self.arrangement
        let r = crease?.rect ?? .zero
        if creaseLeft.constant != r.minX { creaseLeft.constant = r.minX }
        if creaseTop.constant != r.minY { creaseTop.constant = r.minY }
        if creaseWidth.constant != r.width { creaseWidth.constant = r.width }
        if creaseHeight.constant != r.height { creaseHeight.constant = r.height }
        // A crease never takes the full-screen preview (it would straddle).
        if isPreviewExpanded, crease != nil { isPreviewExpanded = false; transport.setExpanded(false) }
        if arrangement != activeArrangement {
            let previous = activeArrangement
            if let previous { NSLayoutConstraint.deactivate(constraintSets[previous] ?? []) }
            NSLayoutConstraint.deactivate(expandedSet)
            NSLayoutConstraint.activate(isPreviewExpanded ? expandedSet : constraintSets[arrangement] ?? [])
            activeArrangement = arrangement
            applyPresentation(arrangement, keepPanelOpen: previous != nil && isPanelOpen)
        }
        transport.expandButton.isHidden = crease != nil
        // "Captures" with its label where the bar has room; the icon alone
        // on a phone held upright (VoiceOver reads "Captures" either way).
        let roomy = traitCollection.horizontalSizeClass == .regular || view.bounds.width >= 600
        header.setBack(symbol: "square.grid.2x2", title: roomy ? "Captures" : nil, label: "Captures")
        // The title moves off a vertical crease, over the stage's half.
        if case .vertical(let c)? = crease {
            let rtl = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
            let pane = rtl ? (c.maxX + view.bounds.width - view.safeAreaInsets.right) / 2
                           : (view.safeAreaInsets.left + c.minX) / 2
            header.titleCenterOffset = pane - view.bounds.midX
        } else {
            header.titleCenterOffset = 0
        }
        // The floating bar drops into the home indicator's band, the way
        // the system's bars float (none to drop into without one).
        let dock = -EditorToolBar.thickness + Self.toolBarDrop(safeBottom: view.safeAreaInsets.bottom)
        if toolBarDock.constant != dock { toolBarDock.constant = dock }
        updateStageHeight()
        timelineHeightChanged(timeline.intrinsicPanelHeight)
        if isPanelOpen, inspector.presentation == .bottomPanel, !CCMotion.isAnimating(panelHeight) {
            let target = fittedPanelHeight()
            panelTarget = target
            if abs(panelHeight.constant - target) > 0.5 { panelHeight.constant = target }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        repositionContextPill()
    }

    /// How far the stacked bottom bar drops into the bottom safe band.
    static func toolBarDrop(safeBottom: CGFloat) -> CGFloat {
        safeBottom >= 20 ? 14 : 0
    }

    /// The canvas's width / height (the stage shows it at its own aspect).
    var canvasAspect: CGFloat {
        let c = stage.virtualCanvasSize
        return c.width > 0 && c.height > 0 ? c.width / c.height : 16.0 / 9.0
    }

    /// Portrait phone: the stage is as tall as the canvas at the full
    /// width, up to what leaves the toolbar row, the timeline's strip and
    /// a panel's room above the tool bar (a panel never covers or resizes
    /// the preview). A portrait canvas fills that height, centred.
    func stackedStageHeight() -> CGFloat {
        let h = view.bounds.height, w = view.bounds.width
        let headerBottom = view.safeAreaInsets.top + header.rowHeight
        let budget = h - headerBottom - view.safeAreaInsets.bottom - EditorToolBar.thickness - EditorTransportBar.height
            - Self.minTimelineStrip - h * Self.panelMaxShare
        return max(120, min((w / canvasAspect).rounded(), budget.rounded(.down)))
    }

    private func updateStageHeight() {
        guard let stageHeight else { return }
        let target = stackedStageHeight()
        if abs(stageHeight.constant - target) > 0.5 { stageHeight.constant = target }
    }

    /// The inspector's presentation, the tool bar's shape and the panel's
    /// state for an arrangement.
    private func applyPresentation(_ arrangement: Arrangement, keepPanelOpen: Bool) {
        let presentation = inspectorPresentation(for: arrangement)
        let wasOpen = isPanelOpen
        let reopen = openOption
        NSLayoutConstraint.deactivate(inspectorColumn + inspectorBottom + inspectorSide)
        inspector.setPresentation(presentation)
        switch presentation {
        case .column: NSLayoutConstraint.activate(inspectorColumn)
        case .bottomPanel: NSLayoutConstraint.activate(inspectorBottom)
        case .sidePanel: NSLayoutConstraint.activate(inspectorSide)
        }
        // Z-order: the side panel slides out from under the rail; the
        // bottom panel never overlaps the tool bar (it sits above it).
        if presentation == .sidePanel {
            view.insertSubview(inspector.view, belowSubview: toolBar)
        } else {
            view.insertSubview(inspector.view, aboveSubview: toolBar)
        }
        view.bringSubviewToFront(contextPill)
        toolBar.axis = arrangement == .landscapeCompact ? .vertical : .horizontal
        toolBar.docked = arrangement == .stacked || arrangement == .landscapeCompact
        toolBar.showsPaneTools = presentation != .column
        isPanelOpen = false
        openOption = nil
        panelHeight?.constant = 0
        panelTarget = 0
        updateTimelineSquash()
        sideSlotWidth.constant = 0
        inspector.view.isHidden = presentation != .column
        inspector.view.accessibilityElementsHidden = false
        timelineContainer.accessibilityElementsHidden = false
        toolBar.accessibilityElementsHidden = false
        toolBar.setOpen(nil, animated: false)
        if presentation == .column, case .pane = toolBar.mode { toolBar.setMode(baseMode(), animated: false) }
        if presentation != .column, wasOpen, keepPanelOpen {
            if let reopen { openPanel(option: reopen, animated: false) } else { openPanel(selection.inspectorTab, animated: false) }
        }
        refreshToolBarMode(animated: false)
    }

    // MARK: - Panels (portrait and landscape phone)

    /// The most of the screen's height a bottom panel takes (short panels:
    /// one small group of controls).
    static let panelMaxShare: CGFloat = 0.30
    /// What an open bottom panel always leaves of the timeline above it: the
    /// ruler and the whole VIDEO lane (its label unclipped) under the playhead.
    static let minTimelineStrip: CGFloat = StudioTimelineStyle.canvasTopInset + 22 + 48 + 4

    /// The bottom panel's height cap: ≤ 30% of the screen, and never higher
    /// than leaves `minTimelineStrip` of the timeline above it — so the
    /// preview and the toolbar row are never covered.
    func panelCap() -> CGFloat {
        let toolTop = toolBar.frame.minY
        let floor = timelineContainer.frame.minY + Self.minTimelineStrip
        return max(0, min(view.bounds.height * Self.panelMaxShare, toolTop - floor))
    }

    /// The bottom panel's height for the shown controls: it fits them, up
    /// to the cap (beyond it the rows scroll inside).
    func fittedPanelHeight() -> CGFloat {
        #if DEBUG
        if Self.probePanelDefect == .uncapped { return inspector.panelFittingHeight }
        #endif
        return min(inspector.panelFittingHeight, panelCap()).rounded()
    }

    #if DEBUG
    /// Probe seam — INJECTED DEFECT: panels snap open (no growth).
    static var probeSnapPanel = false
    /// Probe seams — INJECTED DEFECTS for the panel gates: the panel over
    /// the tool bar; no height cap.
    enum PanelDefect { case none, overToolBar, uncapped }
    static var probePanelDefect = PanelDefect.none
    /// The last element a panel change moved VoiceOver to (the gates read it).
    private(set) var probeLastAnnounced: UIView?
    #endif

    /// Bottom panel: the timeline's lanes end above it.
    private func updateTimelineSquash() {
        timelineSquash?.isActive = inspector.presentation == .bottomPanel && !isPreviewExpanded
    }

    private func setPanelHeight(_ target: CGFloat, animated: Bool, curve: CCMotion.Curve = .bounce,
                                duration: TimeInterval = 0.42, completion: (() -> Void)? = nil) {
        panelTarget = target
        if animated {
            CCMotion.animate(panelHeight, to: target, in: view, duration: duration, curve: curve, completion: completion)
        } else {
            panelHeight.constant = target
            view.layoutIfNeeded()
            completion?()
        }
    }

    /// Opens `tab`'s WHOLE pane in the panel (harnesses, a restored layout);
    /// the tool bar's sub-options open one group each (`openPanel(option:)`).
    /// With an inspector column it just switches the pane.
    func openPanel(_ tab: InspectorTab, animated: Bool = true) {
        guard !isPreviewingVersion else { return }
        selection.inspectorTab = tab
        guard inspector.presentation != .column else { return }
        inspector.show(tab, animated: false)
        inspector.setFocus(nil)
        presentPanel(animated: animated, marking: .pane(tab))
    }

    /// Opens a sub-option's SHORT panel above the tool bar (a choice is
    /// applied first; one with nothing more to adjust just applies).
    func openPanel(option: InspectorPanelOption, animated: Bool = true) {
        guard !isPreviewingVersion, inspector.presentation != .column else { return }
        let tab = selection.inspectorTab
        inspector.show(tab, animated: false)
        inspector.setFocus(option, animated: isPanelOpen && animated)
        if case .pane = toolBar.mode { toolBar.setOptions(inspector.panelOptions(for: tab)) }
        guard inspector.optionHasRows(option, in: tab) else {
            // Applied (e.g. Transparent): nothing to adjust — no panel.
            if isPanelOpen { closePanel(animated: animated) }
            return
        }
        openOption = option
        presentPanel(animated: animated, marking: .option(option.id))
    }

    private func presentPanel(animated: Bool, marking tool: EditorToolBar.Tool) {
        canvas.endInlineEdit(commit: true)
        let already = isPanelOpen
        var animate = animated && view.window != nil
        #if DEBUG
        if Self.probeSnapPanel { animate = false }
        #endif
        inspector.view.isHidden = false
        toolBar.setOpen(toolBar.key(for: tool) != nil ? tool : nil, animated: animated)
        // Lay out while still closed (so the layout pass doesn't snap the
        // panel to its target), then grow it.
        view.layoutIfNeeded()
        isPanelOpen = true
        switch inspector.presentation {
        case .bottomPanel:
            let target = fittedPanelHeight()
            if abs(target - panelTarget) > 0.5 || !already { setPanelHeight(target, animated: animate) }
        case .sidePanel:
            guard !already else { break }
            let target = Self.sidePanelWidth
            if animate {
                CCMotion.animate(sideSlotWidth, to: target, in: view, duration: 0.42, curve: .bounce)
            } else {
                sideSlotWidth.constant = target
                view.layoutIfNeeded()
            }
        case .column:
            break
        }
        // VoiceOver lands on the panel's title (a header): announced on
        // open and on every switch.
        announce(inspector.panelTitle)
    }

    /// Closes the panel (✓ / back / the open key again), back to the bar alone.
    func closePanel(animated: Bool = true) {
        guard isPanelOpen else { return }
        isPanelOpen = false
        let closedTool = toolBar.openTool.flatMap { toolBar.key(for: $0) }
        openOption = nil
        toolBar.setOpen(nil, animated: animated)
        let animate = animated && view.window != nil
        let done = { [weak self] in
            guard let self, !self.isPanelOpen, self.inspector.presentation != .column else { return }
            self.inspector.view.isHidden = true
        }
        switch inspector.presentation {
        case .bottomPanel:
            setPanelHeight(0, animated: animate, curve: .settle, duration: 0.3, completion: done)
        case .sidePanel:
            if animate {
                CCMotion.animate(sideSlotWidth, to: 0, in: view, duration: 0.34, curve: .settle, completion: done)
            } else {
                sideSlotWidth.constant = 0
                view.layoutIfNeeded()
                done()
            }
        case .column:
            break
        }
        // Back on the key that opened it.
        announce(closedTool ?? toolBar)
    }

    private func announce(_ element: UIView) {
        #if DEBUG
        probeLastAnnounced = element
        #endif
        UIAccessibility.post(notification: .layoutChanged, argument: element)
    }

    /// The pane level's keys follow the pane's rows (a toggle that reveals a
    /// group adds its sub-options in place); the open option re-focuses.
    private func refreshPaneOptions() {
        guard case .pane(let tab) = toolBar.mode, inspector.presentation != .column,
              tab == inspector.shownTab else { return }
        let options = inspector.panelOptions(for: tab)
        toolBar.setOptions(options)
        if let open = openOption, let fresh = options.first(where: { $0.id == open.id }), fresh != open {
            openOption = fresh
            inspector.setFocus(fresh, apply: false)
        }
    }

    /// The shown pane changed (a selection moved it) or its rows changed: the
    /// pane level's keys follow, the open option re-focuses, the bottom
    /// panel resizes — on the growth curve for a new pane, frame by frame
    /// with a pane's own growth.
    private func panelContentChanged(animated: Bool) {
        refreshPaneOptions()
        guard isPanelOpen, inspector.presentation == .bottomPanel else { return }
        let target = fittedPanelHeight()
        guard abs(target - panelTarget) > 0.5 else { return }
        var animate = animated && view.window != nil
        #if DEBUG
        if Self.probeSnapPanel { animate = false }
        #endif
        if animate || CCMotion.isAnimating(panelHeight) {
            setPanelHeight(target, animated: animate || view.window != nil)
        } else {
            panelTarget = target
            panelHeight.constant = target
            view.setNeedsLayout()
        }
    }

    // MARK: - Full-screen preview

    /// The preview takes the editor (the toolbar row stays under it); again
    /// returns to the arrangement. A cross-fade between the two layouts.
    func setPreviewExpanded(_ expanded: Bool, animated: Bool = true) {
        guard expanded != isPreviewExpanded, crease == nil || !expanded else { return }
        if expanded { closePanel(animated: false) }
        isPreviewExpanded = expanded
        updateTimelineSquash()
        transport.setExpanded(expanded)
        let change = { [self] in
            if let activeArrangement { NSLayoutConstraint.deactivate(constraintSets[activeArrangement] ?? []) }
            NSLayoutConstraint.deactivate(expandedSet)
            NSLayoutConstraint.activate(expanded ? expandedSet : constraintSets[arrangement] ?? [])
            activeArrangement = arrangement
            for v in [timelineContainer, toolBar, inspectorContainer] as [UIView] { v.isHidden = expanded }
            inspector.view.isHidden = expanded || inspector.presentation != .column
            view.layoutIfNeeded()
        }
        if animated, view.window != nil {
            CCMotion.crossFade(view, change)
        } else {
            change()
        }
        UIAccessibility.post(notification: .screenChanged, argument: transport.expandButton)
    }

    // MARK: - Header

    /// The aspect chip: the same setting the Mac bar's aspect select edits,
    /// with its one-time portrait camera-stack rule; one undo step.
    func setAspectRatio(_ ratio: AspectRatio) {
        guard !isPreviewingVersion, project.settings.aspectRatio != ratio else { return }
        inspector.session.perform("aspectRatio", name: "Aspect Ratio") { [project] in
            project.settings.aspectRatio = ratio
            // Vertical stack (docs/camera-cutout.md §12.12) — the Mac bar's rule.
            if (ratio == .vertical || ratio == .tallVertical),
               project.cameraVideoURL != nil, project.settings.cameraPortraitStack == nil {
                project.settings.cameraPortraitStack = true
            }
        }
    }

    // MARK: - Tool bar

    private func wireToolBar() {
        toolBar.onTool = { [weak self] tool, key in self?.runTool(tool, from: key) }
        // Coalesced to the end of the turn: the timeline's canvas has taken
        // the new selection by then (the Options key reads its geometry).
        timeline.onCommandStateChange = { [weak self] in
            guard let self, !self.toolBarRefreshQueued else { return }
            self.toolBarRefreshQueued = true
            DispatchQueue.main.async {
                self.toolBarRefreshQueued = false
                self.refreshToolBarMode(animated: true)
                self.refreshTransportCommands()
            }
        }
        inspector.onClosePanel = { [weak self] in self?.closePanel() }
        inspector.onPanelContentChange = { [weak self] animated in self?.panelContentChanged(animated: animated) }
        inspector.onPaneRefresh = { [weak self] in self?.refreshPaneOptions() }
        transport.onCommand = { [weak self] command, key in self?.runTimelineCommand(command, from: key) }
    }

    private var toolBarRefreshQueued = false

    /// A tool bar key: a pane level, a sub-option, back, the timeline's
    /// commands, History.
    func runTool(_ tool: EditorToolBar.Tool, from key: UIView) {
        guard !isPreviewingVersion else { return }
        switch tool {
        case .add: presentAddSheet(from: key)
        case .split: timeline.splitAtPlayhead()
        case .speed: if !timeline.showSpeedMenu(from: key) { CCHaptics.warning() }
        case .pane(let tab): enterPane(tab)
        case .option(let id):
            guard let option = toolBar.options.first(where: { $0.id == id }) else { return }
            if isPanelOpen, openOption?.id == id { closePanel(); return }
            openPanel(option: option)
        case .history: inspector.onShowHistory?()
        case .back:
            closePanel()
            switch toolBar.mode {
            case .pane:
                toolBar.setMode(baseMode(), animated: true)
            case .context:
                timeline.clearTimelineSelection()
            case .slicing:
                timeline.toggleSliceTool()
            case .tools:
                break
            }
        case .adjust: enterPane(selection.inspectorTab)
        case .duplicate: timeline.duplicateSelectedRegion()
        case .delete:
            timeline.deleteSelection()
            renderStage()
        case .options: if !timeline.showSelectionMenu(from: key) { CCHaptics.warning() }
        }
    }

    /// Drills the bar into `tab`'s sub-options (a pane with one group opens
    /// it straight away).
    func enterPane(_ tab: InspectorTab, animated: Bool = true) {
        guard !isPreviewingVersion else { return }
        closePanel(animated: animated)
        selection.inspectorTab = tab
        guard inspector.presentation != .column else { return }
        inspector.show(tab, animated: false)
        let options = inspector.panelOptions(for: tab)
        toolBar.setOptions(options)
        toolBar.setMode(.pane(tab), animated: animated)
        if options.count == 1 { openPanel(option: options[0], animated: animated) }
    }

    /// The timeline toolbar row's keys: the timeline's own commands.
    private func runTimelineCommand(_ command: EditorTransportBar.Command, from key: UIView) {
        switch command {
        case .toStart: timeline.goToStart()
        case .toEnd: timeline.goToEnd()
        case .undo: performUndo()
        case .redo: performRedo()
        case .delete:
            guard !isPreviewingVersion else { return }
            timeline.deleteSelection()
            renderStage()
        case .effects: if !isPreviewingVersion { timeline.showEffectsMenu(from: key) }
        case .focus: if !isPreviewingVersion { timeline.showFocusMenu(from: key) }
        case .slice: if !isPreviewingVersion { timeline.toggleSliceTool() }
        case .split: if !isPreviewingVersion { timeline.splitAtPlayhead() }
        case .annotate: if !isPreviewingVersion { timeline.showAnnotationMenu(from: key) }
        case .voice: presentVoiceOver()
        case .zoomOut: timeline.zoomTimeline(in: false)
        case .zoomIn: timeline.zoomTimeline(in: true)
        case .scale(let f): timeline.setTimelineScaleFraction(f)
        }
        refreshTransportCommands()
    }

    /// The toolbar row's key states (undo stack, selection, slice, zoom).
    func refreshTransportCommands() {
        guard isViewLoaded else { return }
        var s = EditorTransportBar.CommandState()
        s.canUndo = editorUndo.canUndo
        s.canRedo = editorUndo.canRedo
        s.canDelete = timeline.canDeleteSelection
        s.sliceArmed = timeline.isSliceArmed
        s.recording = timelinePlayback.isRecordingVoiceOver
        s.canZoomOut = timeline.canZoomTimelineOut
        s.canZoomIn = timeline.canZoomTimelineIn
        s.scale = timeline.timelineScaleFraction
        s.editable = !isPreviewingVersion
        transport.setCommandState(s)
    }

    /// The Add sheet: the timeline's add menus (effects, focus, annotation —
    /// the same house sheets its toolbar opened), voice-over and the slice tool.
    private func presentAddSheet(from key: UIView) {
        let sheet = CCActionSheet(title: "Add")
        sheet.addAction("Effect", symbol: "sparkles") { [weak self, weak key] in self?.timeline.showEffectsMenu(from: key) }
        sheet.addAction("Focus or Blur", symbol: "scope") { [weak self, weak key] in self?.timeline.showFocusMenu(from: key) }
        sheet.addAction("Annotation", symbol: "pencil.tip") { [weak self, weak key] in self?.timeline.showAnnotationMenu(from: key) }
        sheet.addAction("Voice Over", symbol: "mic.fill") { [weak self] in self?.presentVoiceOver() }
        sheet.addAction("Slice Tool", symbol: "rectangle.split.2x1") { [weak self] in self?.timeline.toggleSliceTool() }
        sheet.present(from: self, source: key)
    }

    /// What the bar shows with no pane level: the slice tool's keys, the
    /// selection's context keys, or the root tools.
    private func baseMode() -> EditorToolBar.Mode {
        if timeline.isSliceArmed { return .slicing }
        if timeline.hasTimelineSelection {
            let s = selection
            let hasPane = s.selectedZoomID != nil || s.selectedTiltID != nil || s.selectedBlurID != nil
                || s.selectedHighlightID != nil || s.selectedDepthFocusID != nil || s.selectedAnnotationID != nil
            return .context(.init(
                adjust: hasPane && inspector.presentation != .column,
                duplicate: timeline.canDuplicateSelection,
                delete: timeline.canDeleteSelection,
                speed: timeline.selectedClipID != nil || timeline.selectedSpeedID != nil,
                options: timeline.canvas.selectedBlockFrame() != nil))
        }
        return .tools
    }

    /// What's selected, as one value (a new selection takes the bar to its
    /// context keys, even from a pane level).
    private var selectionSignature: String {
        let s = selection
        return [s.selectedZoomID, s.selectedTiltID, s.selectedBlurID, s.selectedHighlightID, s.selectedDepthFocusID,
                s.selectedAnnotationID, timeline.selectedClipID, timeline.selectedVoiceOverID, timeline.selectedSpeedID,
                timeline.selectedCameraLayoutID].map { $0?.uuidString ?? "-" }.joined(separator: ",")
            + "\(s.introSelected)\(s.curtainSelected)\(timeline.isSliceArmed)"
    }
    private var lastSelectionSignature = ""

    /// Tools, or the selection's context keys (or the slice tool's bar); a
    /// pane level stays until back, unless the selection changes.
    private func refreshToolBarMode(animated: Bool) {
        guard isViewLoaded else { return }
        let signature = selectionSignature
        let changed = signature != lastSelectionSignature
        lastSelectionSignature = signature
        if case .pane = toolBar.mode, !changed { return }
        let mode = baseMode()
        guard mode != toolBar.mode else { return }
        closePanel(animated: animated)
        toolBar.setMode(mode, animated: animated)
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        wireCanvas()
        wireTransport()
        installTimeline()
        inspector.install(in: self)
        constrainInspector()
        wireFeatures()
        wireToolBar()
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
        timeline.tearDown()
        if let onClose { onClose() } else { dismiss(animated: true) }
    }

    // MARK: - Timeline (Studio 4c) and feature keys (4e, 4f)

    private func installTimeline() {
        addChild(timeline)
        let v = timeline.view!
        v.translatesAutoresizingMaskIntoConstraints = false
        timelineContainer.addSubview(v)
        // The lanes fill the container unless a bottom panel above the tool
        // bar needs the room (`timelineSquash`): then they compress and
        // scroll, the container (and the stage above it) staying put.
        let fill = v.bottomAnchor.constraint(equalTo: timelineContainer.bottomAnchor)
        fill.priority = .init(998)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: timelineContainer.topAnchor),
            v.leadingAnchor.constraint(equalTo: timelineContainer.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: timelineContainer.trailingAnchor),
            v.bottomAnchor.constraint(lessThanOrEqualTo: timelineContainer.bottomAnchor),
            fill,
        ])
        timeline.didMove(toParent: self)
        // A fresh text / callout opens the in-place label editor, and Add
        // Blur / Pixelate arms drag-to-draw on the stage (the Mac's flow).
        timeline.onBeginInlineEdit = { [weak self] id in self?.canvas.beginInlineEdit(annotationID: id) }
        timeline.onArmBlurDraw = { [weak self] style in self?.canvas.armBlurDraw(style: style) }
        timeline.onPreferredHeightChange = { [weak self] height in self?.timelineHeightChanged(height) }
        timelineHeightChanged(timeline.intrinsicPanelHeight)
    }

    /// The landscape strip, iPad and the crease layouts size the timeline
    /// (portrait: it fills down to the tool bar). Beside a crease it may
    /// take up to half its pane.
    private func timelineHeightChanged(_ height: CGFloat) {
        let h = view.bounds.height
        let caps: [Arrangement: CGFloat] = [
            .splitAtVerticalCrease: max(220, h / 2),
            .splitAtHorizontalCrease: max(160, (h - (crease?.rect.maxY ?? 0)) / 2 - EditorToolBar.thickness),
            .landscapeCompact: max(96, h * 0.32),
        ]
        for (arrangement, constraint) in timelineHeights {
            let floor: CGFloat = arrangement == .splitAtHorizontalCrease ? 160 : arrangement == .landscapeCompact ? 96 : 180
            let constant = min(max(height, floor), caps[arrangement] ?? floor)
            if constraint.constant != constant { constraint.constant = constant }
        }
    }

    /// The feature keys: the inspector's (4d), the tool bar's and the timeline's mic and
    /// camera-mask hooks open the features (4e) and History (4f), each a
    /// sheet over the editor with one undo step on the editor's stack.
    private func wireFeatures() {
        inspector.onShowHistory = { [weak self] in
            guard let self, !self.isPreviewingVersion else { return }
            _ = StudioHistory.present(from: self, project: self.project, undoManager: self.editorUndo)
        }
        inspector.onRecordVoiceOver = { [weak self] in self?.presentVoiceOver() }
        timeline.onToggleVoiceOverRecording = { [weak self] in self?.presentVoiceOver() }
        inspector.onTranscribe = { [weak self] in
            guard let self, !self.isPreviewingVersion else { return }
            StudioTranscription.present(from: self, project: self.project, undoManager: self.editorUndo)
        }
        inspector.onAutoZoom = { [weak self] in
            guard let self, !self.isPreviewingVersion else { return }
            StudioAutoZoom.present(from: self, project: self.project, undoManager: self.editorUndo)
        }
        inspector.onRemoveBackground = { [weak self] in self?.presentBackgroundRemoval() }
        // A Cutout / Pop-out look placed from the inspector or the timeline
        // starts the person mask quietly, as on the Mac (no sheet).
        inspector.onEnsureCameraMask = { [weak self] in self?.startCameraMask() }
        timeline.onNeedsCameraMask = { [weak self] in self?.startCameraMask() }
        // The timeline's VOICE row draws the live take from the one session.
        timelinePlayback.voiceOverState = {
            let session = StudioVoiceOver.session
            return (session.isRecording, session.recordingStartTime, session.liveSamples)
        }
    }

    /// Studio 3d: the export sheet over the editor (never while a History
    /// version is previewed — that would export the live project instead).
    @discardableResult
    func presentExport() -> StudioExportSheetController? {
        guard !isPreviewingVersion, presentedViewController == nil else { return nil }
        canvas.endInlineEdit(commit: true)
        playback.setPlaying(false, for: project)
        saveNow()
        return StudioExport.present(from: self, project: project)
    }

    private func presentVoiceOver() {
        guard !isPreviewingVersion else { return }
        canvas.endInlineEdit(commit: true)
        StudioVoiceOver.present(from: self, project: project, undoManager: editorUndo, transport: playback)
    }

    private func startCameraMask() {
        _ = StudioBackgroundRemoval.cameraMask(for: project)
        renderStage()
    }

    private func presentBackgroundRemoval() {
        guard !isPreviewingVersion, presentedViewController == nil else { return }
        StudioBackgroundRemoval.present(from: self, project: project, undoManager: editorUndo)
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
            // The zoom chip never sits over the camera bubble.
            let camera = self.canvas.context?.cameraRect.map {
                self.stageCard.convert(self.stage.viewRect(fromCanvas: $0.standardized), from: self.stage).standardized
            }
            self.stageCard.keepZoomPillClear(of: camera)
        }
    }

    /// Names ids for the harness log (`EditorShellLab` installs names).
    var eventNames: [UUID: String] = [:]
    private func name(_ id: UUID?) -> String {
        guard let id else { return "nil" }
        return eventNames[id] ?? "?"
    }

    private func wireTransport() {
        // VoiceOver: the timeline's zoom (a pinch) as the playhead's actions.
        transport.playhead.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Zoom in timeline") { [weak self] _ in self?.timeline.zoomTimeline(in: true); return true },
            UIAccessibilityCustomAction(name: "Zoom out timeline") { [weak self] _ in self?.timeline.zoomTimeline(in: false); return true },
            UIAccessibilityCustomAction(name: "Fit timeline") { [weak self] _ in
                guard let self else { return false }
                self.timeline.setTimelineScale(self.timeline.minTimelineScale)
                return true
            },
        ]
        transport.onToggleExpanded = { [weak self] in
            guard let self else { return }
            self.setPreviewExpanded(!self.isPreviewExpanded)
        }
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
            let clips = self.project.voiceOverClips
            if let last = self.lastVoiceClips, last != clips {
                self.playback.scheduleVoiceOverRefresh(for: self.project)
            }
            self.lastVoiceClips = clips
            self.playback.applyCursorSmoothing(settings: self.project.settings, trimEnd: self.project.effectiveTrimEnd)
        })
        // The header's aspect chip shows the setting.
        observations.append(SurfaceObservation { [weak self] in
            guard let self else { return }
            self.aspectChip.setRatio(self.project.settings.aspectRatio)
            self.header.title = self.project.name
        })
        // Canvas size follows the project's reference canvas and aspect.
        observations.append(SurfaceObservation { [weak self] in
            guard let self else { return }
            _ = self.project.referenceCanvasSize
            _ = self.project.settings.aspectRatio
            _ = self.project.settings.exportSettings.resolution
            _ = self.playback.videoSize
            self.updateCanvasSize()
            self.view.setNeedsLayout()
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
            cameraMask: cameraMaskProvider(project),
            cameraSourceLeadIn: playback.cameraSourceLeadIn)
    }

    #if DEBUG
    /// Probe seams — INJECTED DEFECTS for `--editor-shell --inject …`: the
    /// stage told it is paused while playing (the playback exception
    /// broken), or never handed the player (frames frozen on the poster).
    enum ProbeDefect { case none, blurWhilePlaying, frozenFrames, ignoresSizeClass, ignoresCrease }
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
        refreshTransportCommands()
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
        if !editable { closePanel(animated: false) }
        for container in [timelineContainer, inspectorContainer, toolBar] as [UIView] {
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
            UIKeyCommand(title: "Export…", action: #selector(keyExport), input: "e", modifierFlags: .command),
        ]
        if canvas.inlineEditingID == nil {
            commands += [
                UIKeyCommand(title: "Play / Pause", action: #selector(keyPlay), input: " ", modifierFlags: []),
                UIKeyCommand(title: "Previous Frame", action: #selector(keyStepBack), input: UIKeyCommand.inputLeftArrow),
                UIKeyCommand(title: "Next Frame", action: #selector(keyStepForward), input: UIKeyCommand.inputRightArrow),
                UIKeyCommand(title: "Delete Selection", action: #selector(keyDelete), input: UIKeyCommand.inputDelete),
            ]
        }
        return commands
    }

    @objc private func keyEscape() {
        if isPanelOpen { closePanel(); return }
        if isPreviewExpanded { setPreviewExpanded(false); return }
        canvas.escape()
    }
    @objc private func keyExport() { presentExport() }
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
