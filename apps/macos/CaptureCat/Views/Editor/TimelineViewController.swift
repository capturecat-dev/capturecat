import AppKit
import AVFoundation
import CoreMedia

/// The timeline panel as native AppKit — toolbar, track labels, the horizontal
/// scroller around `TimelineCanvasView`, keyboard, undo state and the async
/// asset loaders.
///
/// This replaces `TimelineView`, the last SwiftUI surface in the app. The track
/// area itself was already `TimelineCanvasView`; what moved here is the chrome
/// around it and the ~1,400 lines of edit logic, which came across verbatim —
/// same snapping, same undo registration, same commit paths. Since Studio 1e
/// that edit logic is the shared `TimelineEditing` extension
/// (TimelineEdits.swift) the iOS timeline drives too; this controller hosts it.
///
/// # Focus
///
/// There is now exactly ONE first responder for the whole panel:
/// `TimelineRootView`. Under SwiftUI the canvas called
/// `makeFirstResponder(self)` on every click, which starved the `.onKeyPress`
/// chain, and six `isFocused = true` repairs were scattered through the
/// selection callbacks to claw focus back. The canvas now focuses the root
/// instead, and the repairs collapse into `focusTimeline()`.
@MainActor
final class TimelineViewController: NSViewController {
    let project: Project
    private let playback: EditorPlaybackController
    let selection: EditorShellSelection
    private let onToggleVoiceOverRecording: () -> Void

    // MARK: Shims onto shared state
    //
    // The ported logic reads and writes these as plain properties, exactly as
    // it did when they were `@Binding`s, so the bodies needed no edits.

    var currentTime: TimeInterval {
        get { playback.currentTime }
        set { playback.currentTime = newValue }
    }
    private var isPlaying: Bool {
        get { playback.isPlaying }
        set { playback.isPlaying = newValue }
    }
    var selectedHighlightID: UUID? {
        get { selection.selectedHighlightID }
        set { selection.selectedHighlightID = newValue; applySelectionExclusivity(.highlight, newValue) }
    }
    var selectedDepthFocusID: UUID? {
        get { selection.selectedDepthFocusID }
        set { selection.selectedDepthFocusID = newValue; applySelectionExclusivity(.depthFocus, newValue) }
    }
    var selectedTiltID: UUID? {
        get { selection.selectedTiltID }
        set { selection.selectedTiltID = newValue; applySelectionExclusivity(.tilt, newValue) }
    }
    var selectedZoomID: UUID? {
        get { selection.selectedZoomID }
        set { selection.selectedZoomID = newValue; applySelectionExclusivity(.zoom, newValue) }
    }
    var selectedAnnotationID: UUID? {
        get { selection.selectedAnnotationID }
        set { selection.selectedAnnotationID = newValue; applySelectionExclusivity(.annotation, newValue) }
    }
    private var player: AVPlayer? { playback.player }
    private var isRecordingVoiceOver: Bool { playback.isRecordingVoiceOver }
    private var voiceOverRecordingStartTime: Double? { playback.voiceOverRecordingStartTime }
    private var liveVoiceOverSamples: [Float] { playback.liveVoiceOverSamples }

    /// Resolved LAZILY at every call site. `@Environment(\.undoManager)`
    /// re-resolved on each body pass; `view.window?.undoManager` is nil until
    /// the view enters a window, so capturing it once at construction would
    /// silently no-op every registration made before that.
    override var undoManager: UndoManager? { view.window?.undoManager }

    // MARK: Owned state (was @State)

    var selectedBlurID: UUID? {
        get { selection.selectedBlurID }
        set { selection.selectedBlurID = newValue; applySelectionExclusivity(.blur, newValue) }
    }
    /// Camera layout blocks ride the FOCUS lane; the ID picks the array,
    /// exactly like Depth Focus — including selection exclusivity, without
    /// which a layout block and an EFFECTS block showed drag handles at the
    /// same time.
    var selectedCameraLayoutID: UUID? {
        didSet { applySelectionExclusivity(.cameraLayout, selectedCameraLayoutID); rebuildCanvas() }
    }
    var selectedVoiceOverID: UUID? {
        didSet { applySelectionExclusivity(.voiceOver, selectedVoiceOverID); rebuildCanvas(); refreshTransport() }
    }
    var selectedSpeedID: UUID? {
        didSet { applySelectionExclusivity(.speed, selectedSpeedID); rebuildCanvas(); refreshTransport() }
    }
    var selectedClipID: UUID? {
        didSet { applySelectionExclusivity(.clip, selectedClipID); rebuildCanvas(); refreshTransport() }
    }
    private var sliceMode = false { didSet { rebuildCanvas() } }
    private var audioSamples: [Float] = [] { didSet { rebuildCanvas() } }
    private var thumbnails: [TimelineThumbnail] = [] { didSet { rebuildCanvas() } }
    private var voiceWaveforms: [UUID: [Float]] = [:] { didSet { rebuildCanvas() } }
    private var timelineScale: CGFloat = 1.0
    private var pinchBaseScale: CGFloat?
    private var pinchAccumulated: CGFloat = 0
    private var visibleTrackWidth: CGFloat = 0

    private let minTimelineScale: CGFloat = 1.0
    private let maxTimelineScale: CGFloat = 30.0

    // 84, not 70: "ANNOTATE" measures ~66pt, and a block starting at t=0 sat
    // flush against the text — reading as the track colliding with its label.
    private let labelWidth: CGFloat = 84
    private let rulerHeight: CGFloat = 22
    private let trackHeight: CGFloat = 48
    private let trackSpacing: CGFloat = 4
    private let rulerBottomSpacing: CGFloat = 6
    private let timelineBottomInset: CGFloat = 12
    /// Updated when EFFECTS sub-rows appear/disappear (dynamic lane height).
    private var canvasAreaHeightConstraint: NSLayoutConstraint?
    /// EFFECTS / FOCUS / ANNOTATE label rows — driven every accordion frame
    /// from the canvas's `TimelineLaneLayout` so labels track their lanes.
    private var overlayLabelHeightConstraints: [TimelineOverlayLane: NSLayoutConstraint] = [:]
    private var overlayLabelViews: [TimelineOverlayLane: NSView] = [:]

    // MARK: Views

    private var rootView: TimelineRootView { view as! TimelineRootView }
    private let toolbar = NSStackView()
    private let canvasArea = NSView()
    private let labelColumn = NSStackView()
    private let scrollView = TimelineScrollView()
    private let canvas = TimelineCanvasView()

    private var playButton: TimelineToolbarButton!
    private var undoButton: TimelineToolbarButton!
    private var redoButton: TimelineToolbarButton!
    private var deleteButton: TimelineToolbarButton!
    private var sliceButton: TimelineToolbarButton!
    private var voiceButton: TimelineToolbarButton!
    private var annotationButton: TimelineToolbarButton!
    private var zoomOutButton: TimelineToolbarButton!
    private var zoomInButton: TimelineToolbarButton!
    private var fitButton: TimelineToolbarButton!
    private var zoomMenuButton: TimelineToolbarButton!
    private var focusMenuButton: TimelineToolbarButton!
    private let scaleSlider = InspectorSliderControl()
    private let timecodeCurrent = NSTextField(labelWithString: "")
    private let timecodeTotal = NSTextField(labelWithString: "")

    private var openPopover: CaptureCatPopover?
    private var observation: SurfaceObservation?
    private var themeObservation: CCThemeObservation?
    // Chrome the theme pass restyles — panel slab, toolbar separators,
    // timecode divider.
    private var separatorLines: [NSView] = []
    private weak var timecodeDivider: NSTextField?
    private var undoTokens: [NSObjectProtocol] = []
    private var thumbnailTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?
    private var voiceTask: Task<Void, Never>?
    private var lastVideoURL: URL??
    private var lastTrimSignature: String?
    private var lastVoiceSignature: String?
    private var lastCurrentTime: TimeInterval?

    /// Total intrinsic height: 42 toolbar + 10 top + canvas + 8 bottom.
    /// LOAD-BEARING — `EditorStageViewController` gives the preview card no
    /// height of its own and derives it from this. A wrong value collapses the
    /// whole stage, and a single-window-size screenshot can still pass.
    var intrinsicPanelHeight: CGFloat { 42 + 10 + timelineCanvasHeight + 8 }

    init(
        project: Project,
        playback: EditorPlaybackController,
        selection: EditorShellSelection,
        onToggleVoiceOverRecording: @escaping () -> Void
    ) {
        self.project = project
        self.playback = playback
        self.selection = selection
        self.onToggleVoiceOverRecording = onToggleVoiceOverRecording
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        for token in undoTokens { NotificationCenter.default.removeObserver(token) }
    }

    // MARK: - Layout

    override func loadView() {
        let root = TimelineRootView()
        root.controller = self
        root.wantsLayer = true
        root.layer?.cornerRadius = EditorThemeKit.panelRadius
        root.layer?.cornerCurve = .continuous
        // `.editorPanel(bottomBleed: true)`: only the TOP corners are rounded —
        // the panel bleeds into the window edge at the bottom.
        root.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        root.layer?.borderWidth = 1
        view = root

        buildToolbar()
        buildCanvasArea()

        toolbar.translatesAutoresizingMaskIntoConstraints = false
        canvasArea.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(toolbar)
        root.addSubview(canvasArea)

        let hairline = CALayer()
        root.layer?.addSublayer(hairline)
        root.toolbarHairline = hairline

        // One observation for all the panel's chrome; fires once now, then on
        // every theme flip. Lane BLOCK colors are content and stay fixed.
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }

        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 42),

            canvasArea.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            canvasArea.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            canvasArea.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 10),
            {
                let hc = canvasArea.heightAnchor.constraint(equalToConstant: timelineCanvasHeight)
                canvasAreaHeightConstraint = hc
                return hc
            }(),
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        startObserving()
        installUndoObservers()
        refreshUndoState()
        focusTimeline()

        // pendingSeekOutputTime (deep links, search hits) is consumed by
        // EditorShellViewController, NOT here: this viewDidAppear raced the
        // player load — the scrub's currentTime was clobbered by
        // setupPlayer's trim-start reset and warm-up re-anchor, so the seek
        // silently vanished. The shell feeds it to setupPlayer(initialTime:)
        // on load and scrubs after readiness for an already-open editor.
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        observation?.cancel()
        observation = nil
        thumbnailTask?.cancel(); audioTask?.cancel(); voiceTask?.cancel()
        // The signatures were written when those tasks were LAUNCHED, so
        // leaving them set means `restartLoadersIfNeeded` sees no change on
        // reappear and the filmstrip/waveforms never reload.
        lastVideoURL = nil; lastTrimSignature = nil; lastVoiceSignature = nil

        // Break the controller ⇄ canvas retain cycle: the canvas stores the
        // callback structs, and those capture self strongly. Without this the
        // controller (and its Project, thumbnails and sample buffers) outlives
        // the window, and `deinit` — the only place the undo observers are
        // removed — never runs.
        canvas.releaseCallbacks()
        for token in undoTokens { NotificationCenter.default.removeObserver(token) }
        undoTokens.removeAll()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let width = max(0, canvasArea.bounds.width - labelWidth)
        guard width != visibleTrackWidth else { return }
        visibleTrackWidth = width
        layoutCanvasDocument()
        // `canvasCallbacks(scaledWidth:)` bakes the track width into the
        // scrub/seek closures BY VALUE, so a resize that does not rebuild them
        // leaves those closures dividing by the old width — the playhead then
        // jumps on the first grab. SwiftUI recomputed the width from the
        // GeometryReader on every body pass; here it has to be explicit.
        rebuildCanvas()
    }

    /// The document view is sized explicitly: `max(visible, visible * scale)`,
    /// the same expression the SwiftUI `GeometryReader` used.
    private func layoutCanvasDocument() {
        let width = scaledTrackWidth
        // Annotate sub-rows make the DOCUMENT taller than the panel — the
        // panel keeps its height and the extra rows scroll vertically.
        let height = max(
            timelineCanvasHeight,
            TimelineLaneLayout.maxTracksBottom(
                effectsRows: effectsLaneRowCount, annotateRows: canvas.annotateRowCount)
                + timelineBottomInset
        )
        if canvas.frame.size != CGSize(width: width, height: height) {
            canvas.frame = CGRect(x: 0, y: 0, width: width, height: height)
        }
    }

    private func buildCanvasArea() {
        labelColumn.orientation = .vertical
        labelColumn.alignment = .leading
        labelColumn.spacing = 0
        labelColumn.translatesAutoresizingMaskIntoConstraints = false

        // Ruler gutter, then one label per lane.
        let gutter = NSView()
        gutter.translatesAutoresizingMaskIntoConstraints = false
        gutter.heightAnchor.constraint(equalToConstant: rulerHeight + rulerBottomSpacing).isActive = true
        gutter.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true
        labelColumn.addArrangedSubview(gutter)

        let lanes: [(String, TimelineOverlayLane?)] = [
            (String(localized: "VIDEO", comment: "Timeline: lane label in the left column (shown in caps); the video clips lane"), nil),
            (String(localized: "VOICE", comment: "Timeline: lane label in the left column (shown in caps); the voice-over lane"), nil),
            (String(localized: "EFFECTS", comment: "Timeline: lane label in the left column (shown in caps); zoom/tilt/transition blocks lane"), .effects),
            (String(localized: "FOCUS", comment: "Timeline: lane label in the left column (shown in caps); blur/highlight/camera-layout regions lane"), .focus),
            (String(localized: "ANNOTATE", comment: "Timeline: lane label in the left column (shown in caps); annotations lane (text, arrows, shapes)"), .annotate),
        ]
        for (index, (name, overlayLane)) in lanes.enumerated() {
            let label = makeTrackLabel(name, storeHeightAs: overlayLane)
            labelColumn.addArrangedSubview(label)
            if index > 0 {
                labelColumn.setCustomSpacing(trackSpacing, after: labelColumn.arrangedSubviews[index])
            }
        }

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasHorizontalScroller = true
        // Vertical scrolling exists for grown lanes (stacked ANNOTATE rows,
        // EFFECTS sub-rows) — the canvas gets taller than the viewport and
        // must scroll, not clip.
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .automatic
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        // Pinch must reach the root view's `magnify(with:)`, not be eaten as
        // scroll-view magnification (which would scale the pixels instead of
        // re-laying out the timeline).
        scrollView.allowsMagnification = false
        scrollView.documentView = canvas

        canvasArea.addSubview(labelColumn)
        canvasArea.addSubview(scrollView)
        NSLayoutConstraint.activate([
            labelColumn.leadingAnchor.constraint(equalTo: canvasArea.leadingAnchor),
            labelColumn.topAnchor.constraint(equalTo: canvasArea.topAnchor),
            labelColumn.widthAnchor.constraint(equalToConstant: labelWidth),

            scrollView.leadingAnchor.constraint(equalTo: labelColumn.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: canvasArea.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: canvasArea.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: canvasArea.bottomAnchor),
        ])

        canvas.onFocusRequested = { [weak self] in self?.focusTimeline() }
        canvas.onLaneLayoutChange = { [weak self] layout in self?.applyLaneLabelLayout(layout) }
    }

    /// Lane accordion frame: each overlay label row takes its lane's current
    /// height (same layout object the canvas drew with), and a closed lane's
    /// label recedes a little with it.
    private func applyLaneLabelLayout(_ layout: TimelineLaneLayout) {
        for lane in TimelineOverlayLane.allCases {
            overlayLabelHeightConstraints[lane]?.constant = layout.laneHeight(lane)
            let open = min(1, max(0, layout.openness(lane)))
            overlayLabelViews[lane]?.alphaValue = 0.7 + 0.3 * open
        }
    }

    /// `kerning: 0.6` has no NSTextField property — it has to go on the
    /// attributed string.
    private func makeTrackLabel(_ text: String, storeHeightAs lane: TimelineOverlayLane? = nil) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithAttributedString: NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: EditorThemeKit.textTertiary,
                .kern: 0.6,
            ]
        ))
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        let heightConstraint = container.heightAnchor.constraint(equalToConstant: trackHeight)
        if let lane {
            overlayLabelHeightConstraints[lane] = heightConstraint
            overlayLabelViews[lane] = container
        }
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: labelWidth),
            heightConstraint,
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    /// EFFECTS lane height changed (sub-rows added/removed): resize the canvas
    /// area, the document view, and the panel's intrinsic height so the stage
    /// re-lays out around the taller timeline. (The label row follows through
    /// the canvas's lane-layout callback.)
    private func applyEffectsLaneRowCount(_ rowCount: Int) {
        let clamped = max(1, min(TimelineCanvasMetrics.maxEffectsRows, rowCount))
        guard clamped != effectsLaneRowCount else { return }
        effectsLaneRowCount = clamped
        canvasAreaHeightConstraint?.constant = timelineCanvasHeight
        layoutCanvasDocument()
        view.invalidateIntrinsicContentSize()
        view.needsLayout = true
    }

    // MARK: - Toolbar

    private func buildToolbar() {
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 4
        toolbar.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)

        // Transport cluster — three raised keys, no grouping pill behind
        // them (Mike, 2026-09-01: every icon is its own key now).
        let toStart = TimelineToolbarButton(icon: "backward.end.fill") { [weak self] in
            guard let self else { return }
            let startTime = project.effectiveTrimStart
            currentTime = startTime
            player?.seek(to: CMTime(seconds: startTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        toStart.toolTip = String(localized: "Go to Start", comment: "Timeline toolbar: tooltip; moves the playhead to the beginning")
        playButton = TimelineToolbarButton(icon: "play.fill", pointSize: 17) { [weak self] in
            self?.togglePlayback()
        }
        let toEnd = TimelineToolbarButton(icon: "forward.end.fill") { [weak self] in
            guard let self, let player else { return }
            let endTime = max(project.effectiveTrimStart, project.effectiveTrimEnd - 0.01)
            currentTime = endTime
            player.seek(to: CMTime(seconds: endTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        toEnd.toolTip = String(localized: "Go to End", comment: "Timeline toolbar: tooltip; moves the playhead to the end")

        let transport = NSStackView(views: [toStart, playButton, toEnd])
        transport.orientation = .horizontal
        transport.spacing = 4
        toolbar.addArrangedSubview(transport)

        toolbar.addArrangedSubview(makeSeparator())

        // Timecode readout — the timeline's primary number.
        timecodeCurrent.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        let divider = NSTextField(labelWithString: "/")
        divider.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        timecodeDivider = divider
        timecodeTotal.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let timecode = NSStackView(views: [timecodeCurrent, divider, timecodeTotal])
        timecode.orientation = .horizontal
        timecode.spacing = 4
        timecode.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        toolbar.addArrangedSubview(timecode)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addArrangedSubview(spacer)

        undoButton = TimelineToolbarButton(icon: "arrow.uturn.backward") { [weak self] in
            self?.undoManager?.undo()
        }
        undoButton.toolTip = String(localized: "Undo", comment: "Timeline toolbar: tooltip; verb, undoes the last edit")
        redoButton = TimelineToolbarButton(icon: "arrow.uturn.forward") { [weak self] in
            self?.undoManager?.redo()
        }
        redoButton.toolTip = String(localized: "Redo", comment: "Timeline toolbar: tooltip; verb, redoes the last undone edit")
        toolbar.addArrangedSubview(undoButton)
        toolbar.addArrangedSubview(redoButton)
        toolbar.addArrangedSubview(makeSeparator())

        deleteButton = TimelineToolbarButton(icon: "trash", tint: .systemRed) { [weak self] in
            self?.deleteSelectedRegion()
        }
        deleteButton.toolTip = String(localized: "Delete Selected", comment: "Timeline toolbar: tooltip; deletes the selected timeline item")
        toolbar.addArrangedSubview(deleteButton)
        toolbar.addArrangedSubview(makeSeparator())

        zoomMenuButton = TimelineToolbarButton(icon: "sparkles") { [weak self] in
            self?.showZoomMenu()
        }
        zoomMenuButton.toolTip = String(localized: "Zoom", comment: "Timeline toolbar: tooltip; opens the effects picker (zoom, tilt, transitions, camera layouts)")
        toolbar.addArrangedSubview(zoomMenuButton)

        focusMenuButton = TimelineToolbarButton(icon: "scope") { [weak self] in
            self?.showFocusMenu()
        }
        focusMenuButton.toolTip = String(localized: "Focus & Blur", comment: "Timeline toolbar: tooltip; opens the blur/highlight/depth-focus picker")
        toolbar.addArrangedSubview(focusMenuButton)

        sliceButton = TimelineToolbarButton(icon: "scissors") { [weak self] in
            guard let self else { return }
            sliceMode.toggle()
            if !sliceMode { clearSliceHover() }
            refreshSliceButton()
        }
        toolbar.addArrangedSubview(sliceButton)
        refreshSliceButton()

        let split = TimelineToolbarButton(icon: "rectangle.split.2x1") { [weak self] in
            self?.splitAtPlayhead()
        }
        split.toolTip = String(localized: "Split at Playhead (⌘B)", comment: "Timeline toolbar: tooltip; splits the clip at the playhead; ⌘B is the shortcut")
        toolbar.addArrangedSubview(split)

        annotationButton = TimelineToolbarButton(icon: "pencil.tip") { [weak self] in
            self?.showAnnotationMenu()
        }
        annotationButton.toolTip = String(localized: "Add Annotation", comment: "Timeline toolbar: tooltip; opens the annotation picker")
        toolbar.addArrangedSubview(annotationButton)
        toolbar.addArrangedSubview(makeSeparator())

        voiceButton = TimelineToolbarButton(icon: "mic.fill") { [weak self] in
            self?.onToggleVoiceOverRecording()
        }
        toolbar.addArrangedSubview(voiceButton)
        toolbar.addArrangedSubview(makeSeparator())

        zoomOutButton = TimelineToolbarButton(icon: "minus.magnifyingglass", pointSize: 12) { [weak self] in
            guard let self else { return }
            setTimelineScale(timelineScale / 1.5)
        }
        zoomOutButton.toolTip = String(localized: "Zoom Out Timeline", comment: "Timeline toolbar: tooltip; shows more of the timeline (not a video zoom)")
        toolbar.addArrangedSubview(zoomOutButton)

        // The SwiftUI toolbar used the bare `InspectorSliderTrack`; its AppKit
        // twin is `InspectorSliderControl` (same rail, knob and commit math).
        scaleSlider.range = Double(log2(minTimelineScale))...Double(log2(maxTimelineScale))
        scaleSlider.onChange = { [weak self] value in
            self?.setTimelineScale(pow(2, CGFloat(value)))
        }
        scaleSlider.translatesAutoresizingMaskIntoConstraints = false
        scaleSlider.widthAnchor.constraint(equalToConstant: 72).isActive = true
        toolbar.addArrangedSubview(scaleSlider)

        zoomInButton = TimelineToolbarButton(icon: "plus.magnifyingglass", pointSize: 12) { [weak self] in
            guard let self else { return }
            setTimelineScale(timelineScale * 1.5)
        }
        zoomInButton.toolTip = String(localized: "Zoom In Timeline", comment: "Timeline toolbar: tooltip; magnifies the timeline (not a video zoom)")
        toolbar.addArrangedSubview(zoomInButton)

        fitButton = TimelineToolbarButton(icon: "arrow.down.right.and.arrow.up.left", pointSize: 11) { [weak self] in
            self?.setTimelineScale(1)
        }
        fitButton.toolTip = String(localized: "Fit Timeline", comment: "Timeline toolbar: tooltip; fits the whole timeline in view")
        toolbar.addArrangedSubview(fitButton)

        // No gliding hover wash here any more — each key carries its own
        // hover tint (TimelineToolbarButton.refreshFill).
        toolbar.wantsLayer = true
    }

    private func makeSeparator() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let line = NSView()
        line.wantsLayer = true
        line.translatesAutoresizingMaskIntoConstraints = false
        separatorLines.append(line)
        container.addSubview(line)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 11),   // 1 + 5pt each side
            line.widthAnchor.constraint(equalToConstant: 1),
            line.heightAnchor.constraint(equalToConstant: 18),
            line.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            line.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    /// Re-applies the panel's THEMED chrome. Timeline lane blocks
    /// (effect/blur/highlight/annotate gradients, grips, snap guide) are
    /// content colors and deliberately not touched here.
    private func applyTheme() {
        let root = view as? TimelineRootView
        root?.layer?.backgroundColor = EditorThemeKit.panel.cgColor
        root?.layer?.borderColor = EditorThemeKit.hairline.cgColor
        root?.toolbarHairline?.backgroundColor = EditorThemeKit.hairline.cgColor
        for line in separatorLines {
            line.layer?.backgroundColor = EditorThemeKit.hairline.cgColor
        }
        timecodeCurrent.textColor = EditorThemeKit.textPrimary
        timecodeDivider?.textColor = EditorThemeKit.textTertiary
        timecodeTotal.textColor = EditorThemeKit.textSecondary
    }

    private func refreshSliceButton() {
        sliceButton.isActive = sliceMode
        sliceButton.tint = sliceMode ? .systemCyan : nil
        sliceButton.toolTip = sliceMode
            ? String(localized: "Exit Slice Tool", comment: "Timeline toolbar: tooltip; turns off the slice (scissors) tool")
            : String(localized: "Slice clip — click to split", comment: "Timeline toolbar: tooltip; slice (scissors) tool: click a clip to split it")
    }

    // MARK: - Popovers

    private func present(_ popover: CaptureCatPopover, from button: TimelineToolbarButton) {
        openPopover?.close()
        button.isActive = true
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        openPopover = popover
        // `.popover(isPresented:)` cleared the button's active state on dismiss.
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(
            forName: CaptureCatPopover.didCloseNotification, object: popover, queue: .main
        ) { [weak self, weak button] _ in
            MainActor.assumeIsolated {
                button?.isActive = false
                if self?.openPopover === popover { self?.openPopover = nil }
                if let token { NotificationCenter.default.removeObserver(token) }
            }
        }
    }

    /// Set by the shell: opens the in-place label editor on a fresh
    /// text/callout so it lands ready to overtype (add, then type straight away).
    var onBeginInlineEdit: ((UUID) -> Void)?

    /// Set by the shell: arms the preview's drag-to-draw pass so the user can
    /// drag over the thing to censor; the drawn rect comes back through
    /// createBlurRegion(rect:style:).
    var onArmBlurDraw: ((BlurStyle) -> Void)?

    private func addForInlineEditing(_ type: AnnotationType) {
        addAnnotation(type: type)
        if let id = selectedAnnotationID, type == .text || type == .callout {
            onBeginInlineEdit?(id)
        }
    }

    private func showAnnotationMenu() {
        // The ADD entry point. The floating pill is contextual-only (it
        // appears above the SELECTED annotation for editing) — a permanently
        // docked pill over the preview was removed on purpose.
        let popover = TimelinePickerPopover.make(rows: [
            .init(icon: "text.bubble", title: String(localized: "Text Label", comment: "Annotation picker: row title"), detail: String(localized: "Add a text overlay", comment: "Annotation picker: row detail for Text Label")) { [weak self] in self?.addForInlineEditing(.text) },
            .init(icon: "arrow.up.right", title: String(localized: "Arrow", comment: "Annotation picker: row title (noun)"), detail: String(localized: "Draw a directional arrow", comment: "Annotation picker: row detail for Arrow")) { [weak self] in self?.addAnnotation(type: .arrow) },
            .init(icon: "pencil.tip", title: String(localized: "Callout", comment: "Annotation picker: row title; a line pointing to a labelled box"), detail: String(localized: "Line with labelled box", comment: "Annotation picker: row detail for Callout")) { [weak self] in self?.addForInlineEditing(.callout) },
            .init(icon: "pencil.and.scribble", title: String(localized: "Drawing", comment: "Annotation picker: row title (noun, freehand drawing)"), detail: String(localized: "Freehand brush strokes", comment: "Annotation picker: row detail for Drawing")) { [weak self] in self?.addAnnotation(type: .drawing) },
            .init(icon: "rectangle", title: String(localized: "Rectangle", comment: "Annotation picker: row title (shape)"), detail: String(localized: "Box with optional fill", comment: "Annotation picker: row detail for Rectangle")) { [weak self] in self?.addAnnotation(type: .rectangle) },
            .init(icon: "oval", title: String(localized: "Ellipse", comment: "Annotation picker: row title (shape)"), detail: String(localized: "Circle / oval with optional fill", comment: "Annotation picker: row detail for Ellipse")) { [weak self] in self?.addAnnotation(type: .ellipse) },
            .init(icon: "hand.tap", title: String(localized: "Tap Indicator", comment: "Annotation picker: row title; a touch ripple marker"), detail: String(localized: "Looping touch ripple for iPhone takes", comment: "Annotation picker: row detail for Tap Indicator; a take = a recording")) { [weak self] in self?.addAnnotation(type: .tap) },
        ])
        present(popover, from: annotationButton)
    }

    // MARK: - Harness seams (`--menu-shot`)

    /// Opens the REAL Effects picker exactly as the toolbar button does and
    /// hands back the presented popover.
    func probeOpenEffectsMenu() -> CaptureCatPopover? {
        showZoomMenu()
        return openPopover
    }

    /// Opens the REAL annotation picker (the other rich-row menu).
    func probeOpenAnnotationMenu() -> CaptureCatPopover? {
        showAnnotationMenu()
        return openPopover
    }

    private func showZoomMenu() {
        // The one Effects menu: every effect starts here, drops at the
        // playhead pre-configured, and lands selected so the on-canvas focal
        // target and inspector are immediately live.
        let motionRows: [TimelinePickerPopover.Row] = project.isImageCapture ? [
            .init(icon: "wand.and.stars", title: String(localized: "Motion", comment: "Timeline add-effect picker: row title for image captures; generated camera movement"),
                  detail: String(localized: "Cinematic corner tour across the image", comment: "Timeline add-effect picker: row detail for Motion")) { [weak self] in self?.stillMotion() },
        ] : []
        let zoomAndMotion = TimelinePickerPopover.Section(title: String(localized: "Zoom & motion", comment: "Timeline add-effect picker: section header"), rows: motionRows + [
            .init(icon: "sparkle.magnifyingglass", title: String(localized: "Auto Zoom", comment: "Timeline add-effect picker: row title"),
                  detail: String(localized: "Generate zooms from cursor movement", comment: "Timeline add-effect picker: row detail for Auto Zoom"),
                  isEnabled: hasCursorData,
                  disabledDetail: String(localized: "Needs cursor data from a CaptureCat recording", comment: "Timeline add-effect picker: shown when Auto Zoom is unavailable")) { [weak self] in self?.autoZoom() },
            .init(icon: "plus.magnifyingglass", title: String(localized: "Zoom In", comment: "Timeline add-effect picker: row title; adds a zoom-in block to the video"),
                  detail: String(localized: "Push in at the playhead — drag the target to aim", comment: "Timeline add-effect picker: row detail for Zoom In")) { [weak self] in self?.addZoomRegion() },
            .init(icon: "sparkles.rectangle.stack", title: String(localized: "Showcase", comment: "Timeline add-effect picker: row title; an effect preset name"),
                  detail: String(localized: "Gentle zoom + 3D skew, returns to centre", comment: "Timeline add-effect picker: row detail for Showcase")) { [weak self] in self?.addShowcaseBlock() },
            .init(icon: "arrow.down.right.and.arrow.up.left", title: String(localized: "Scale Down", comment: "Timeline add-effect picker: row title"),
                  detail: String(localized: "Shrink the card for a beat, then back", comment: "Timeline add-effect picker: row detail for Scale Down; card = the framed video")) { [weak self] in self?.addScaleDownBlock() },
            .init(icon: "rotate.3d", title: String(localized: "Tilt", comment: "Timeline add-effect picker: row title (3D tilt effect)"),
                  detail: String(localized: "Skew the screen in 3D for a span", comment: "Timeline add-effect picker: row detail for Tilt")) { [weak self] in self?.addTiltRegion() },
        ])
        let transitions = TimelinePickerPopover.Section(title: String(localized: "Transitions", comment: "Timeline add-effect picker: section header"), rows: [
            .init(icon: "arrow.up.to.line", title: String(localized: "Slide", comment: "Timeline add-effect picker: row title; slide-in transition"),
                  detail: String(localized: "Card slides from an edge — place it anywhere", comment: "Timeline add-effect picker: row detail for Slide")) { [weak self] in self?.enableIntroSlide() },
            .init(icon: Self.symbol("book.pages", fallback: "rectangle.portrait.and.arrow.forward"),
                  title: String(localized: "Curtain Unveil", comment: "Timeline add-effect picker: row title; a transition name"),
                  detail: String(localized: "A curtain peels from a corner to reveal the screen", comment: "Timeline add-effect picker: row detail for Curtain Unveil")) { [weak self] in self?.enableCurtainUnveil() },
        ])
        // The header carries "Camera", so the rows drop the old prefix; when
        // there is no camera track the whole group dims and ONE caption says
        // why (instead of five unexplained dead rows).
        let camera = hasRecordedCamera
        let cameraSection = TimelinePickerPopover.Section(title: String(localized: "Camera", comment: "Timeline add-effect picker: section header for webcam layouts"), rows: [
            .init(icon: "person.crop.rectangle", title: String(localized: "Full Screen", comment: "Timeline add-effect picker: camera layout row title"),
                  detail: String(localized: "Webcam fills the card for a span — talking head", comment: "Timeline add-effect picker: row detail for Full Screen camera layout"),
                  isEnabled: camera) { [weak self] in self?.addCameraLayoutRegion(mode: .cameraOnly) },
            .init(icon: "rectangle.split.2x1", title: String(localized: "Side by Side", comment: "Timeline add-effect picker: camera layout row title"),
                  detail: String(localized: "Screen shrinks left, webcam fills the right", comment: "Timeline add-effect picker: row detail for Side by Side"),
                  isEnabled: camera) { [weak self] in self?.addCameraLayoutRegion(mode: .sideBySide) },
            .init(icon: "rectangle.split.2x1", title: String(localized: "Side by Side, Camera Left", comment: "Timeline add-effect picker: camera layout row title"),
                  detail: String(localized: "Webcam on the left, screen shrinks right", comment: "Timeline add-effect picker: row detail for Side by Side, Camera Left"),
                  isEnabled: camera) { [weak self] in self?.addCameraLayoutRegion(mode: .sideBySide, side: .leading) },
            .init(icon: Self.symbol("rectangle.lefthalf.inset.filled", fallback: "rectangle.split.2x1.fill"),
                  title: CameraSplitStyle.full.displayName,
                  detail: String(localized: "Two full-height columns — screen fills the left, webcam the right", comment: "Timeline add-effect picker: row detail for the full-height split camera layout"),
                  isEnabled: camera) { [weak self] in self?.addCameraLayoutRegion(mode: .sideBySide, split: .full) },
            .init(icon: Self.symbol("person.and.background.dotted", fallback: "person.fill"),
                  title: CameraBubbleLook.cutout.displayName,
                  detail: String(localized: "Background removed — you, right over the screen", comment: "Timeline add-effect picker: row detail for the Cutout camera look"),
                  isEnabled: camera) { [weak self] in self?.addCameraLayoutRegion(mode: .bubble, look: .cutout) },
            .init(icon: Self.symbol("person.crop.artframe", fallback: "person.crop.square"),
                  title: CameraBubbleLook.popOut.displayName,
                  detail: String(localized: "You on a gradient card, head popping out the top", comment: "Timeline add-effect picker: row detail for the Pop-out camera look"),
                  isEnabled: camera) { [weak self] in self?.addCameraLayoutRegion(mode: .bubble, look: .popOut) },
            .init(icon: "person.crop.rectangle.badge.xmark", title: String(localized: "Hide Camera", comment: "Timeline add-effect picker: camera layout row title"),
                  detail: String(localized: "No webcam for a span — screen only", comment: "Timeline add-effect picker: row detail for Hide Camera"),
                  isEnabled: camera) { [weak self] in self?.addCameraLayoutRegion(mode: .screenOnly) },
        ], disabledCaption: String(localized: "Needs a camera recording", comment: "Timeline add-effect picker: caption when the project has no webcam track"))
        let popover = TimelinePickerPopover.make(sections: [zoomAndMotion, transitions, cameraSection])
        present(popover, from: zoomMenuButton)
    }

    private func showFocusMenu() {
        let popover = TimelinePickerPopover.make(rows: [
            .init(icon: "eye.slash", title: String(localized: "Add Blur", comment: "Focus picker: row title"),
                  detail: String(localized: "Drag over an area to blur it", comment: "Focus picker: row detail for Add Blur")) { [weak self] in
                guard let self else { return }
                if let arm = self.onArmBlurDraw { arm(.blur) } else { self.addBlurRegion() }
            },
            .init(icon: "squareshape.split.3x3", title: String(localized: "Add Pixelate", comment: "Focus picker: row title"),
                  detail: String(localized: "Drag over an area to pixelate it", comment: "Focus picker: row detail for Add Pixelate")) { [weak self] in
                guard let self else { return }
                if let arm = self.onArmBlurDraw { arm(.pixelate) } else { self.addBlurRegion() }
            },
            .init(icon: "highlighter", title: String(localized: "Add Highlight", comment: "Focus picker: row title"),
                  detail: String(localized: "Highlight a region of the video", comment: "Focus picker: row detail for Add Highlight")) { [weak self] in self?.addHighlightRegion() },
            .init(icon: "camera.aperture", title: String(localized: "Add Depth Focus", comment: "Focus picker: row title"),
                  detail: String(localized: "Keep a region sharp, blur the rest", comment: "Focus picker: row detail for Add Depth Focus")) { [weak self] in self?.addDepthFocusRegion() },
        ])
        present(popover, from: focusMenuButton)
    }

    // MARK: - Focus + keyboard

    func focusTimeline() {
        guard view.window?.firstResponder !== rootView else { return }
        view.window?.makeFirstResponder(rootView)
    }

    /// Window-wide equivalents of `.keyboardShortcut(_:modifiers: .command)`.
    func handleCommandKey(_ characters: String?) -> Bool {
        switch characters {
        case "d": duplicateSelectedRegion(); return true
        case "b": splitAtPlayhead(); return true
        default: return false
        }
    }

    /// Port of the `.onKeyPress` chain. Returns false for anything it does not
    /// consume so the responder chain continues.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 49:  // space
            togglePlayback()
        case 123, 124:  // ←, →
            let direction: Double = event.keyCode == 123 ? -1 : 1
            let step: Double = shift ? 1.0 : 1.0 / 30.0
            stepPlayhead(byOutput: direction * step)
        case 115:  // home
            seekToSource(project.effectiveTrimStart)
        case 119:  // end
            seekToSource(max(project.effectiveTrimStart, project.effectiveTrimEnd - 0.01))
        case 53:   // esc
            guard selectedClipID != nil else { return false }
            selectedClipID = nil
        case 51, 117:  // delete, forward delete
            return deleteSelectedRegion()
        default:
            // Slice tool. Matched by CHARACTER, not key code: `keyCode 11` is
            // "b" only on an ANSI layout, and the old binding was
            // `.keyboardShortcut("b", modifiers: [])`.
            guard event.charactersIgnoringModifiers == "b",
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty
            else { return false }
            sliceMode.toggle()
            if !sliceMode { clearSliceHover() }
            refreshSliceButton()
        }
        return true
    }

    /// Pinch. `NSEvent.magnification` is a per-event DELTA, unlike SwiftUI's
    /// `MagnifyGesture.magnification` which is cumulative since the gesture
    /// began — so it has to be accumulated to reproduce the same feel.
    func handleMagnify(_ event: NSEvent) {
        // Image treatment: the timeline is timeless and its zoom is pinned.
        guard !project.presentsTimelessTimeline else { return }
        switch event.phase {
        case .began:
            pinchBaseScale = timelineScale
            pinchAccumulated = 0
        case .changed:
            pinchAccumulated += event.magnification
            setTimelineScale((pinchBaseScale ?? timelineScale) * (1 + pinchAccumulated))
        case .ended, .cancelled:
            pinchBaseScale = nil
            pinchAccumulated = 0
        default:
            break
        }
    }

    // MARK: - Selection exclusivity

    private typealias SelectionLane = TimelineSelectionLane

    private var applyingExclusivity = false

    /// Port of `SelectionExclusivity`. ONE selected object at a time — the
    /// single deliberate exception is zoom/tilt not clearing each other (a
    /// linked EFFECTS block selects both halves), and blur/voice-over keeping
    /// `speed`. Annotations are fully exclusive both ways: a selected drawing
    /// annotation arms the canvas pen, so leaving it selected while a region
    /// is selected turned "move the blur" into ink strokes.
    private func applySelectionExclusivity(_ lane: SelectionLane, _ value: UUID?) {
        guard value != nil, !applyingExclusivity else { return }
        applyingExclusivity = true
        defer { applyingExclusivity = false }
        focusTimeline()
        // The rules themselves are shared with the iOS timeline
        // (TimelineHostRouting.swift).
        clearSelections(exclusiveTo: lane)
    }

    // MARK: - Observation, undo, loaders

    private func startObserving() {
        observation?.cancel()
        observation = SurfaceObservation { [weak self] in
            guard let self else { return }
            // Explicit reads so every field the timeline consumes re-arms the
            // loop, matching the `let _ = (...)` reads the hosted view needed.
            _ = (playback.currentTime, playback.isPlaying, playback.isRecordingVoiceOver)
            _ = playback.liveVoiceOverSamples.count
            _ = (project.zoomRegions.count, project.tiltRegions.count, project.blurRegions.count)
            _ = (project.highlightRegions.count, project.annotations.count, project.voiceOverClips.count)
            _ = (project.speedRegions.count, project.splitPoints.count, project.videoClipSegments.count)
            _ = (project.trimStart, project.trimEnd, project.duration)
            _ = (selection.selectedZoomID, selection.selectedTiltID)
            _ = (selection.selectedHighlightID, selection.selectedAnnotationID)
            self.syncFromModel()
        }
    }

    private func syncFromModel() {
        // Flipping a still to Image treatment (or opening one) pins the
        // timeline zoom so the video block spans the full visible width.
        if project.presentsTimelessTimeline, timelineScale != minTimelineScale {
            setTimelineScale(minTimelineScale)
        }
        refreshTransport()
        rebuildCanvas()
        restartLoadersIfNeeded()
        if lastCurrentTime != playback.currentTime {
            lastCurrentTime = playback.currentTime
            followPlayheadIfNeeded()
        }
    }

    private func refreshTransport() {
        playButton?.icon = isPlaying ? "pause.fill" : "play.fill"
        playButton?.toolTip = isPlaying
            ? String(localized: "Pause", comment: "Timeline toolbar: tooltip; verb, pauses playback")
            : String(localized: "Play", comment: "Timeline toolbar: tooltip; verb, starts playback")
        voiceButton?.icon = isRecordingVoiceOver ? "stop.fill" : "mic.fill"
        voiceButton?.tint = isRecordingVoiceOver ? .systemRed : nil
        voiceButton?.toolTip = isRecordingVoiceOver
            ? String(localized: "Stop Recording", comment: "Timeline toolbar: tooltip; stops the voice-over recording")
            : String(localized: "Record Voice Over", comment: "Timeline toolbar: tooltip; starts recording a voice-over")
        // Image treatment: zooming the time axis stays pinned (full-span
        // block) in BOTH sub-states, but the timecodes only hide while there
        // is truly nothing timed to read — the moment a timed effect exists,
        // scrub/transport read exactly as video.
        let timeless = project.presentsTimelessTimeline
        let hidesTime = project.hidesTimelinePlayhead
        timecodeCurrent.isHidden = hidesTime
        timecodeTotal.isHidden = hidesTime
        timecodeCurrent.stringValue = visibleCurrentTime.formattedTimecode
        timecodeTotal.stringValue = visibleDuration.formattedTimecode
        deleteButton?.isEnabled = hasDeletableSelection
        deleteButton?.tint = hasDeletableSelection ? .systemRed : EditorThemeKit.textPrimary
        zoomOutButton?.isEnabled = !timeless && timelineScale > minTimelineScale
        zoomInButton?.isEnabled = !timeless && timelineScale < maxTimelineScale
        fitButton?.isEnabled = !timeless && timelineScale > minTimelineScale
        scaleSlider.doubleValue = Double(log2(timelineScale))
    }

    /// The AppKit twin of `updateNSView`: re-derive every snapshot and push it
    /// into the canvas in one call.
    private func rebuildCanvas() {
        guard isViewLoaded else { return }
        let snapshot = canvasSnapshot()
        applyEffectsLaneRowCount(TimelineCanvasView.effectsRowCount(snapshot: snapshot))
        canvas.apply(
            snapshot: snapshot,
            callbacks: canvasCallbacks(scaledWidth: scaledTrackWidth),
            videoModel: canvasVideoModel(),
            videoAssets: canvasVideoAssets(),
            videoCallbacks: canvasVideoCallbacks(),
            voiceModel: canvasVoiceModel(),
            voiceAssets: canvasVoiceAssets(),
            voiceCallbacks: canvasVoiceCallbacks()
        )
        // The snapshot may have changed how many annotate sub-rows exist.
        layoutCanvasDocument()
    }

    private func installUndoObservers() {
        guard undoTokens.isEmpty else { return }
        for name in [
            NSNotification.Name.NSUndoManagerDidUndoChange,
            NSNotification.Name.NSUndoManagerDidRedoChange,
            NSNotification.Name.NSUndoManagerWillCloseUndoGroup,
        ] {
            // `object: nil` deliberately — the SwiftUI observer had no filter,
            // and the window's undo manager is not resolvable at install time.
            let token = NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshUndoState() }
            }
            undoTokens.append(token)
        }
    }

    private func refreshUndoState() {
        undoButton?.isEnabled = undoManager?.canUndo ?? false
        redoButton?.isEnabled = undoManager?.canRedo ?? false
    }

    /// The AppKit twin of `.task(id:)`: cancel the in-flight task and restart it
    /// when the identity changes.
    private func restartLoadersIfNeeded() {
        if lastVideoURL != project.videoURL {
            lastVideoURL = project.videoURL
            thumbnailTask?.cancel()
            thumbnailTask = Task { @MainActor [weak self] in await self?.loadThumbnails() }
        }
        let trimSignature = "\(project.videoURL?.path ?? "")|\(project.trimStart)|\(project.trimEnd)"
        if lastTrimSignature != trimSignature {
            lastTrimSignature = trimSignature
            audioTask?.cancel()
            audioTask = Task { @MainActor [weak self] in await self?.loadAudioSamples() }
        }
        let voiceSignature = voiceWaveformSignature
        if lastVoiceSignature != voiceSignature {
            lastVoiceSignature = voiceSignature
            voiceTask?.cancel()
            voiceTask = Task { @MainActor [weak self] in await self?.loadVoiceWaveforms() }
        }
    }

    // MARK: - Scroll helpers

    private var visibleScrollRect: CGRect { scrollView.contentView.bounds }

    private func scrollTimeline(toX x: CGFloat) {
        scrollView.contentView.scroll(to: NSPoint(x: x, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: - Lane layout
    //
    // The edit operations that used to follow ("ported edit logic") live in
    // the shared TimelineEditing extension, TimelineEdits.swift (Studio 1e).

    /// EFFECTS sub-rows currently required (≥ 1) — overlapping effects stack
    /// instead of hiding each other. Updated from the snapshot on every
    /// canvas rebuild; the same shared row math the canvas draws with.
    private var effectsLaneRowCount = 1

    /// Ruler + every lane, sized for the TALLEST accordion state (whichever
    /// overlay lane is open), so hovering lanes never re-lays out the stage —
    /// the lanes animate inside a fixed panel. ANNOTATE sub-rows scroll in
    /// the document instead of growing the panel (see `layoutCanvasDocument`).
    private var timelineTrackAreaHeight: CGFloat {
        TimelineLaneLayout.maxTracksBottom(effectsRows: effectsLaneRowCount, annotateRows: 1)
    }

    private var timelineCanvasHeight: CGFloat {
        timelineTrackAreaHeight + timelineBottomInset
    }

    private func canvasVideoModel() -> TimelineVideoRowModel {
        timelineVideoRowModel(hasAudio: !audioSamples.isEmpty, hasThumbnails: !thumbnails.isEmpty)
    }

    private func canvasVideoAssets() -> TimelineVideoAssets {
        TimelineVideoAssets(
            thumbnails: thumbnails,
            audioSamples: audioSamples,
            sourceSegments: project.sourceSegments,
            trimSourceStart: project.effectiveTrimStart,
            trimSourceEnd: project.effectiveTrimEnd
        )
    }

    private func canvasVideoCallbacks() -> TimelineVideoCallbacks {
        timelineVideoCallbacks()
    }

    // MARK: - Native VOICE row inputs

    /// Presentation-ready VOICE row snapshot for the AppKit canvas. The
    /// derivation is shared with the screenshot harness (see
    /// `TimelineVoiceRowModel.make`).
    private func canvasVoiceModel() -> TimelineVoiceRowModel {
        timelineVoiceRowModel(
            isRecordingVoiceOver: isRecordingVoiceOver,
            recordingStartTime: voiceOverRecordingStartTime,
            liveSamples: liveVoiceOverSamples
        )
    }

    private func canvasVoiceAssets() -> TimelineVoiceAssets {
        TimelineVoiceAssets(waveforms: voiceWaveforms, signature: voiceWaveformSignature)
    }

    private func canvasVoiceCallbacks() -> TimelineVoiceCallbacks {
        timelineVoiceCallbacks()
    }

    /// Identity of every voice clip's waveform input — the concatenation of the
    /// per-block signatures the SwiftUI block keyed its `.task` on.
    private var voiceWaveformSignature: String {
        project.voiceOverClips
            .map { "\($0.id.uuidString)|\(TimelineVoiceAssets.signature(for: $0))" }
            .joined(separator: ";")
    }

    /// Loads (and prunes) the per-clip waveforms the native VOICE row draws.
    /// The hosted SwiftUI block did this itself in `.task(id: blockSignature)`;
    /// the native row has no per-block view to hang a task on, so ownership
    /// moves here. Same generator, same sample count, same time range.
    private func loadVoiceWaveforms() async {
        let clips = project.voiceOverClips
        let directory = project.projectDirectory
        var next: [UUID: [Float]] = [:]

        for clip in clips {
            let url = clip.resolvedURL(in: directory)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let timeRange = CMTimeRange(
                start: CMTime(seconds: clip.sourceStartTime, preferredTimescale: 600),
                duration: CMTime(seconds: max(0.1, clip.duration), preferredTimescale: 600)
            )
            let samples = await WaveformGenerator.generate(from: url, sampleCount: 72, timeRange: timeRange)
            guard !samples.isEmpty else { continue }
            next[clip.id] = samples
        }
        voiceWaveforms = next
    }

    // MARK: - AppKit timeline island

    /// The lane snapshot, effect pairing and callback tables are shared with
    /// the iOS timeline (TimelineHostRouting.swift).
    private func canvasSnapshot() -> TimelineCanvasSnapshot {
        timelineCanvasSnapshot(sliceArmed: sliceMode)
    }

    /// Block caption on the ANNOTATE lane — the text/label for text-bearing
    /// types, the type name otherwise.
    static func annotationLaneLabel(for annotation: Annotation) -> String {
        TimelineEdits.annotationLaneLabel(for: annotation)
    }

    static func annotationLaneIcon(for type: AnnotationType) -> String {
        TimelineEdits.annotationLaneIcon(for: type)
    }

    private func canvasCallbacks(scaledWidth: CGFloat) -> TimelineCanvasCallbacks {
        timelineCanvasCallbacks(trackWidth: scaledWidth)
    }

    /// Disarming the slice tool. The hover state lives in the canvas (it owns
    /// the cursor position), and its `mouseMoved` clear is gated behind
    /// `snapshot.sliceArmed` — so once disarmed it can never clear itself and
    /// the playhead stays red until the next hover.
    private func clearSliceHover() {
        NSCursor.arrow.set()
        canvas.clearSliceHoverState()
    }

    // MARK: - Playback

    private func togglePlayback() {
        guard player != nil else { return }
        isPlaying.toggle()
    }

    // MARK: - Timeline zoom & playhead navigation

    private var scaledTrackWidth: CGFloat {
        max(visibleTrackWidth, visibleTrackWidth * timelineScale)
    }

    /// Change the timeline zoom while keeping the playhead at the same
    /// on-screen position, so zooming stays oriented around the work area.
    private func setTimelineScale(_ newScale: CGFloat) {
        let clamped = Self.resolvedTimelineScale(
            newScale,
            timeless: project.presentsTimelessTimeline,
            minScale: minTimelineScale,
            maxScale: maxTimelineScale
        )
        guard abs(clamped - timelineScale) > 0.0001 else { return }

        let oldWidth = scaledTrackWidth
        let outputCurrent = fullTimeMap.outputTime(forSource: currentTime)
        let fraction = outputDuration > 0 ? outputCurrent / outputDuration : 0
        let playheadScreenX = oldWidth * fraction - visibleScrollRect.minX

        timelineScale = clamped

        let newWidth = max(visibleTrackWidth, visibleTrackWidth * clamped)
        let anchorScreenX = min(max(playheadScreenX, 0), max(0, visibleScrollRect.width))
        let targetX = max(0, min(newWidth - visibleScrollRect.width, newWidth * fraction - anchorScreenX))
        // The document view is resized in `viewDidLayout`, which SwiftUI could
        // only reach after a layout pass — hence the async hop it needed here.
        // AppKit lets the order be explicit: resize, then scroll, synchronously,
        // so the zoom lands on the same frame as the gesture.
        layoutCanvasDocument()
        scrollTimeline(toX: targetX)
        // Same reason as viewDidLayout: the width the callbacks captured is
        // now stale, and nothing else refreshes the zoom buttons or the slider
        // (timelineScale is a plain var the observation loop cannot see).
        rebuildCanvas()
        refreshTransport()
    }

    /// Timeline zoom resolution, shared with the `--still-image-test` harness:
    /// a timeless still pins to the minimum scale so its video block always
    /// spans exactly the visible track width — "there is no time" to zoom into.
    static func resolvedTimelineScale(
        _ requested: CGFloat, timeless: Bool, minScale: CGFloat, maxScale: CGFloat
    ) -> CGFloat {
        timeless ? minScale : min(maxScale, max(minScale, requested))
    }

    /// Nudge the playhead by an output-time delta (frame stepping / jumps).
    private func stepPlayhead(byOutput delta: TimeInterval) {
        isPlaying = false
        let outputNow = fullTimeMap.outputTime(forSource: currentTime)
        let clamped = min(max(outputNow + delta, outputTrimStart), max(outputTrimStart, outputTrimEnd - 0.001))
        seekToSource(fullTimeMap.sourceTime(forOutput: clamped))
    }

    private func seekToSource(_ sourceTime: TimeInterval) {
        currentTime = sourceTime
        player?.seek(
            to: CMTime(seconds: sourceTime, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    /// Keep the playhead in view while playing — page-jump when it leaves the
    /// visible window, as video editors do.
    private func followPlayheadIfNeeded() {
        guard isPlaying, visibleScrollRect.width > 0, outputDuration > 0 else { return }
        let width = scaledTrackWidth
        guard width > visibleScrollRect.width + 1 else { return }

        let playheadX = width * (fullTimeMap.outputTime(forSource: currentTime) / outputDuration)
        let margin: CGFloat = 24
        if playheadX > visibleScrollRect.maxX - margin || playheadX < visibleScrollRect.minX {
            let targetX = max(0, min(width - visibleScrollRect.width, playheadX - margin))
            scrollTimeline(toX: targetX)
        }
    }

    private func loadThumbnails() async {
        guard let videoURL = project.videoURL else {
            thumbnails = []
            return
        }
        thumbnails = await TimelineThumbnailer.generate(
            from: videoURL,
            duration: project.duration,
            targetCount: 40
        )
    }

    private var hasCursorData: Bool {
        project.cursorDataURL != nil
    }

    private var hasRecordedCamera: Bool {
        project.cameraVideoURL != nil
    }

    // MARK: - Camera layout regions (FOCUS lane)

    /// An icon name the kit draws (CCIcon), else the fallback.
    private static func symbol(_ name: String, fallback: String) -> String {
        CCIcon.has(name) ? name : fallback
    }

    private func loadAudioSamples() async {
        guard let videoURL = project.videoURL else {
            audioSamples = []
            return
        }

        let sampleCount = 180
        let trimStart = project.effectiveTrimStart
        let trimDuration = max(0, project.effectiveTrimEnd - trimStart)
        let waveformTimeRange: CMTimeRange? = trimDuration > 0
            ? CMTimeRange(
                start: CMTime(seconds: trimStart, preferredTimescale: 600),
                duration: CMTime(seconds: trimDuration, preferredTimescale: 600)
            )
            : nil
        let trackCount = await WaveformGenerator.audioTrackCount(for: videoURL)
        guard trackCount > 0 else {
            audioSamples = []
            return
        }

        var merged = Array(repeating: Float(0), count: sampleCount)
        for trackIndex in 0..<trackCount {
            let samples = await WaveformGenerator.generate(
                from: videoURL,
                sampleCount: sampleCount,
                trackIndex: trackIndex,
                timeRange: waveformTimeRange
            )
            guard !samples.isEmpty else { continue }
            for index in 0..<min(merged.count, samples.count) {
                merged[index] = max(merged[index], samples[index])
            }
        }

        audioSamples = merged
    }

    // MARK: - Motion (still-image cinematic tour)

    /// Motion for image captures: the four-corner cinematic tour
    /// (StillMotionComposer). Regenerating replaces earlier generated
    /// regions; existing zoom blocks prompt a confirm first (CCAlert).
    private func stillMotion() {
        if !project.zoomRegions.isEmpty, let window = view.window {
            CCAlert(
                title: String(localized: "Replace Zoom Blocks?", comment: "Alert title before generating still-image Motion over existing zoom blocks"),
                message: String(localized: "Motion generates a new camera journey. Previously generated blocks will be replaced.", comment: "Alert message: Motion = generated camera movement for an image capture")
            )
            .addButton(String(localized: "Generate", comment: "Alert button: verb, generates the Motion zoom blocks"), role: .primary)
            .addButton(String(localized: "Cancel", comment: "Alert button: cancels"))
            .beginSheet(for: window) { [weak self] index in
                guard index == 0 else { return }
                self?.runStillMotion()
            }
        } else {
            runStillMotion()
        }
    }

    // MARK: - Floating annotation pill (EditorShell's bottom-of-preview toolbar)

    /// The pill's swatch color (TimelineEditing.toolbarAnnotationColor).
    var toolbarAnnotationColor: NSColor?

    func toolbarCurrentBackgroundColor() -> NSColor {
        guard let a = toolbarSelectedAnnotation() else { return .black }
        return NSColor(srgbRed: a.backgroundColor.red, green: a.backgroundColor.green,
                       blue: a.backgroundColor.blue, alpha: a.backgroundColor.opacity)
    }

    /// The pill's color well reads this: selected annotation's color, or the
    /// next-annotation default when nothing is selected.
    func toolbarCurrentColor() -> NSColor {
        if let id = selectedAnnotationID,
           let a = project.annotations.first(where: { $0.id == id }) {
            return NSColor(srgbRed: a.color.red, green: a.color.green,
                           blue: a.color.blue, alpha: a.color.opacity)
        }
        return toolbarAnnotationColor ?? .white
    }
}

// MARK: - TimelineEditing host

/// The edit operations live in the shared `TimelineEditing` extension
/// (TimelineEdits.swift) and the routing in `TimelineHosting`
/// (TimelineHostRouting.swift); this controller supplies the state and the
/// AppKit-only effects.
extension TimelineViewController: TimelineHosting {
    func timelineEditRefused() { NSSound.beep() }

    func timelineRequestFocus() { focusTimeline() }

    func timelineScrub(toSource time: TimeInterval, exact: Bool) {
        playback.scrub(to: time, for: project, exact: exact)
    }

    func timelinePause() { isPlaying = false }

    func timelineSeek(toSource time: TimeInterval) { seekToSource(time) }

    func timelineTogglePlayback() { togglePlayback() }

    func timelineSliceCommitted() {
        sliceMode = false
        clearSliceHover()
    }

    func timelineEditNeedsCameraMask() {
        AppState.current?.cameraSegmentation.ensureMask(for: project)
    }
}

// MARK: - Root view

/// Owns keyboard, pinch and focus for the whole panel. One first responder for
/// the timeline, so the canvas never has to compete for key events.
final class TimelineRootView: NSView {
    weak var controller: TimelineViewController?
    var toolbarHairline: CALayer?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: controller?.intrinsicPanelHeight ?? 356)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        toolbarHairline?.frame = CGRect(x: 0, y: 41, width: bounds.width, height: 1)
        CATransaction.commit()
    }

    override func keyDown(with event: NSEvent) {
        if controller?.handleKeyDown(event) == true { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // `.deviceIndependentFlagsMask` includes capsLock and function, so an
        // exact match against `.command` silently loses ⌘D / ⌘B whenever Caps
        // Lock happens to be on.
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard modifiers == .command else {
            return super.performKeyEquivalent(with: event)
        }
        if controller?.handleCommandKey(event.charactersIgnoringModifiers) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func magnify(with event: NSEvent) {
        controller?.handleMagnify(event)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
}

/// Forwards pinch up to `TimelineRootView`; the scroll view must not consume it
/// as magnification (that would scale pixels rather than re-lay-out the lanes).
final class TimelineScrollView: NSScrollView {
    override func magnify(with event: NSEvent) {
        nextResponder?.magnify(with: event)
    }
}
