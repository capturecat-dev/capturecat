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
/// same snapping, same undo registration, same commit paths.
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
    private let project: Project
    private let playback: EditorPlaybackController
    private let selection: EditorShellSelection
    private let onToggleVoiceOverRecording: () -> Void

    // MARK: Shims onto shared state
    //
    // The ported logic reads and writes these as plain properties, exactly as
    // it did when they were `@Binding`s, so the bodies needed no edits.

    private var currentTime: TimeInterval {
        get { playback.currentTime }
        set { playback.currentTime = newValue }
    }
    private var isPlaying: Bool {
        get { playback.isPlaying }
        set { playback.isPlaying = newValue }
    }
    private var selectedHighlightID: UUID? {
        get { selection.selectedHighlightID }
        set { selection.selectedHighlightID = newValue; applySelectionExclusivity(.highlight, newValue) }
    }
    private var selectedDepthFocusID: UUID? {
        get { selection.selectedDepthFocusID }
        set { selection.selectedDepthFocusID = newValue; applySelectionExclusivity(.depthFocus, newValue) }
    }
    private var selectedTiltID: UUID? {
        get { selection.selectedTiltID }
        set { selection.selectedTiltID = newValue; applySelectionExclusivity(.tilt, newValue) }
    }
    private var selectedZoomID: UUID? {
        get { selection.selectedZoomID }
        set { selection.selectedZoomID = newValue; applySelectionExclusivity(.zoom, newValue) }
    }
    private var selectedAnnotationID: UUID? {
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

    private var selectedBlurID: UUID? {
        get { selection.selectedBlurID }
        set { selection.selectedBlurID = newValue; applySelectionExclusivity(.blur, newValue) }
    }
    /// Camera layout blocks ride the FOCUS lane; the ID picks the array,
    /// exactly like Depth Focus — including selection exclusivity, without
    /// which a layout block and an EFFECTS block showed drag handles at the
    /// same time.
    private var selectedCameraLayoutID: UUID? {
        didSet { applySelectionExclusivity(.cameraLayout, selectedCameraLayoutID); rebuildCanvas() }
    }
    private var selectedVoiceOverID: UUID? {
        didSet { applySelectionExclusivity(.voiceOver, selectedVoiceOverID); rebuildCanvas(); refreshTransport() }
    }
    private var selectedSpeedID: UUID? {
        didSet { applySelectionExclusivity(.speed, selectedSpeedID); rebuildCanvas(); refreshTransport() }
    }
    private var selectedClipID: UUID? {
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
    private var effectsLabelHeightConstraint: NSLayoutConstraint?

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
        let height = timelineCanvasHeight + canvas.annotateExtraHeight
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

        for (index, name) in ["VIDEO", "VOICE", "EFFECTS", "FOCUS", "ANNOTATE"].enumerated() {
            let label = makeTrackLabel(name, storeHeightAs: name == "EFFECTS")
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
    }

    /// `kerning: 0.6` has no NSTextField property — it has to go on the
    /// attributed string.
    private func makeTrackLabel(_ text: String, storeHeightAs storesHeight: Bool = false) -> NSView {
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
        if storesHeight { effectsLabelHeightConstraint = heightConstraint }
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: labelWidth),
            heightConstraint,
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    /// EFFECTS lane height changed (sub-rows added/removed): resize the label
    /// container, the canvas area, the document view, and the panel's
    /// intrinsic height so the stage re-lays out around the taller timeline.
    private func applyEffectsLaneRowCount(_ rowCount: Int) {
        let clamped = max(1, min(TimelineCanvasMetrics.maxEffectsRows, rowCount))
        guard clamped != effectsLaneRowCount else { return }
        effectsLaneRowCount = clamped
        let extra = CGFloat(clamped - 1) * TimelineCanvasMetrics.subRowPitch
        effectsLabelHeightConstraint?.constant = trackHeight + extra
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
        toStart.toolTip = "Go to Start"
        playButton = TimelineToolbarButton(icon: "play.fill", pointSize: 17) { [weak self] in
            self?.togglePlayback()
        }
        let toEnd = TimelineToolbarButton(icon: "forward.end.fill") { [weak self] in
            guard let self, let player else { return }
            let endTime = max(project.effectiveTrimStart, project.effectiveTrimEnd - 0.01)
            currentTime = endTime
            player.seek(to: CMTime(seconds: endTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        toEnd.toolTip = "Go to End"

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
        undoButton.toolTip = "Undo"
        redoButton = TimelineToolbarButton(icon: "arrow.uturn.forward") { [weak self] in
            self?.undoManager?.redo()
        }
        redoButton.toolTip = "Redo"
        toolbar.addArrangedSubview(undoButton)
        toolbar.addArrangedSubview(redoButton)
        toolbar.addArrangedSubview(makeSeparator())

        deleteButton = TimelineToolbarButton(icon: "trash", tint: .systemRed) { [weak self] in
            self?.deleteSelectedRegion()
        }
        deleteButton.toolTip = "Delete Selected"
        toolbar.addArrangedSubview(deleteButton)
        toolbar.addArrangedSubview(makeSeparator())

        zoomMenuButton = TimelineToolbarButton(icon: "sparkles") { [weak self] in
            self?.showZoomMenu()
        }
        zoomMenuButton.toolTip = "Zoom"
        toolbar.addArrangedSubview(zoomMenuButton)

        focusMenuButton = TimelineToolbarButton(icon: "scope") { [weak self] in
            self?.showFocusMenu()
        }
        focusMenuButton.toolTip = "Focus & Blur"
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
        split.toolTip = "Split at Playhead (⌘B)"
        toolbar.addArrangedSubview(split)

        annotationButton = TimelineToolbarButton(icon: "pencil.tip") { [weak self] in
            self?.showAnnotationMenu()
        }
        annotationButton.toolTip = "Add Annotation"
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
        zoomOutButton.toolTip = "Zoom Out Timeline"
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
        zoomInButton.toolTip = "Zoom In Timeline"
        toolbar.addArrangedSubview(zoomInButton)

        fitButton = TimelineToolbarButton(icon: "arrow.down.right.and.arrow.up.left", pointSize: 11) { [weak self] in
            self?.setTimelineScale(1)
        }
        fitButton.toolTip = "Fit Timeline"
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
        sliceButton.toolTip = sliceMode ? "Exit Slice Tool" : "Slice clip — click to split"
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
    /// text/callout so it lands ready to overtype (the Keynote add flow).
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
        let popover = TimelinePickerPopover.make(width: 220, rows: [
            .init(icon: "text.bubble", title: "Text Label", detail: "Add a text overlay") { [weak self] in self?.addForInlineEditing(.text) },
            .init(icon: "arrow.up.right", title: "Arrow", detail: "Draw a directional arrow") { [weak self] in self?.addAnnotation(type: .arrow) },
            .init(icon: "pencil.tip", title: "Callout", detail: "Line with labelled box") { [weak self] in self?.addForInlineEditing(.callout) },
            .init(icon: "pencil.and.scribble", title: "Drawing", detail: "Freehand brush strokes") { [weak self] in self?.addAnnotation(type: .drawing) },
            .init(icon: "rectangle", title: "Rectangle", detail: "Box with optional fill") { [weak self] in self?.addAnnotation(type: .rectangle) },
            .init(icon: "oval", title: "Ellipse", detail: "Circle / oval with optional fill") { [weak self] in self?.addAnnotation(type: .ellipse) },
            .init(icon: "hand.tap", title: "Tap Indicator", detail: "Looping touch ripple for iPhone takes") { [weak self] in self?.addAnnotation(type: .tap) },
        ])
        present(popover, from: annotationButton)
    }

    private func showZoomMenu() {
        // The one Effects menu: every effect starts here, drops at the
        // playhead pre-configured, and lands selected so the on-canvas focal
        // target and inspector are immediately live.
        let motionRows: [TimelinePickerPopover.Row] = project.isImageCapture ? [
            .init(icon: "wand.and.stars", title: "Motion",
                  detail: "Cinematic corner tour across the image") { [weak self] in self?.stillMotion() },
        ] : []
        let popover = TimelinePickerPopover.make(width: 260, rows: motionRows + [
            .init(icon: "sparkle.magnifyingglass", title: "Auto Zoom",
                  detail: "Generate zooms from cursor movement",
                  isEnabled: hasCursorData) { [weak self] in self?.autoZoom() },
            .init(icon: "plus.magnifyingglass", title: "Zoom In",
                  detail: "Push in at the playhead — drag the target to aim") { [weak self] in self?.addZoomRegion() },
            .init(icon: "sparkles.rectangle.stack", title: "Showcase",
                  detail: "Gentle zoom + 3D skew, returns to centre") { [weak self] in self?.addShowcaseBlock() },
            .init(icon: "arrow.down.right.and.arrow.up.left", title: "Scale Down",
                  detail: "Shrink the card for a beat, then back") { [weak self] in self?.addScaleDownBlock() },
            .init(icon: "rotate.3d", title: "Tilt",
                  detail: "Skew the screen in 3D for a span") { [weak self] in self?.addTiltRegion() },
            .init(icon: "arrow.up.to.line", title: "Slide",
                  detail: "Card slides from an edge — place it anywhere") { [weak self] in self?.enableIntroSlide() },
            .init(icon: NSImage(systemSymbolName: "book.pages", accessibilityDescription: nil) != nil
                      ? "book.pages" : "rectangle.portrait.and.arrow.forward",
                  title: "Curtain Unveil",
                  detail: "A curtain peels from a corner to reveal the screen") { [weak self] in self?.enableCurtainUnveil() },
            .init(icon: "person.crop.rectangle", title: "Camera: Full Screen",
                  detail: "Webcam fills the card for a span — talking head",
                  isEnabled: hasRecordedCamera) { [weak self] in self?.addCameraLayoutRegion(mode: .cameraOnly) },
            .init(icon: "rectangle.split.2x1", title: "Camera: Side by Side",
                  detail: "Screen shrinks left, webcam fills the right",
                  isEnabled: hasRecordedCamera) { [weak self] in self?.addCameraLayoutRegion(mode: .sideBySide) },
            .init(icon: "person.crop.rectangle.badge.xmark", title: "Camera: Hide",
                  detail: "No webcam for a span — screen only",
                  isEnabled: hasRecordedCamera) { [weak self] in self?.addCameraLayoutRegion(mode: .screenOnly) },
        ])
        present(popover, from: zoomMenuButton)
    }

    /// Showcase: the "reference look" as one click — modest push-in with a
    /// pitch-back skew, Slow Glide, eased back to a flat centred card.
    private func addShowcaseBlock() {
        let desiredStart = max(0, min(currentTime, project.duration))
        let desiredEnd = min(desiredStart + 3, project.duration)
        var (start, end) = findNonOverlappingSlot(
            desired: (desiredStart, desiredEnd),
            existing: effectLaneSpans,
            duration: project.duration
        )
        // No free slot → keep the desired span; overlapping effects stack
        // into EFFECTS sub-rows instead of being refused.
        if start >= end { (start, end) = (desiredStart, desiredEnd) }
        guard start < end else { return } // zero-length timeline

        let zoom = ZoomRegion(
            startTime: start, endTime: end, zoomLevel: 1.35,
            focalPoint: CGPoint(x: 0.5, y: 0.45), animationStyle: .slowGlide)
        let tilt = TiltRegion(
            startTime: start, endTime: end, pitch: 10, yaw: -6, roll: -2)
        project.zoomRegions.append(zoom)
        project.tiltRegions.append(tilt)
        selectedTiltID = tilt.id
        selectedZoomID = zoom.id

        undoManager?.registerUndo(withTarget: project) { project in
            project.zoomRegions.removeAll { $0.id == zoom.id }
            project.tiltRegions.removeAll { $0.id == tilt.id }
        }
        undoManager?.setActionName("Add Showcase")
    }

    /// Scale Down: the card shrinks toward centre for the span, then eases
    /// back — zoom below 1 is a scale effect on the same lane.
    private func addScaleDownBlock() {
        let desiredStart = max(0, min(currentTime, project.duration))
        let desiredEnd = min(desiredStart + 3, project.duration)
        var (start, end) = findNonOverlappingSlot(
            desired: (desiredStart, desiredEnd),
            existing: effectLaneSpans,
            duration: project.duration
        )
        // No free slot → keep the desired span; overlapping effects stack
        // into EFFECTS sub-rows instead of being refused.
        if start >= end { (start, end) = (desiredStart, desiredEnd) }
        guard start < end else { return } // zero-length timeline

        let region = ZoomRegion(
            startTime: start, endTime: end, zoomLevel: 0.85,
            animationStyle: .smooth)
        project.zoomRegions.append(region)
        selectedTiltID = nil
        selectedZoomID = region.id

        undoManager?.registerUndo(withTarget: project) { project in
            project.zoomRegions.removeAll { $0.id == region.id }
        }
        undoManager?.setActionName("Add Scale Down")
    }

    /// Intro Slide entry point: turns the entrance on (Bottom by default) and
    /// opens the Motion pane where direction and length live.
    private func enableIntroSlide() {
        if project.settings.introSlideStyle == .off {
            project.settings.introSlideStyle = .bottom
        }
        selection.selectedZoomID = nil
        selection.selectedTiltID = nil
        selection.curtainSelected = false
        selection.introSelected = true
        selection.inspectorTab = .effects
        selection.showInspector = true
    }

    /// Curtain Unveil entry point: turns the peel on (Top Left by default)
    /// and opens the Effects pane where corner and length live.
    private func enableCurtainUnveil() {
        if project.settings.curtainUnveilCorner == .off {
            project.settings.curtainUnveilCorner = .topLeft
        }
        selection.selectedZoomID = nil
        selection.selectedTiltID = nil
        selection.introSelected = false
        selection.curtainSelected = true
        selection.inspectorTab = .effects
        selection.showInspector = true
    }

    private func showFocusMenu() {
        let popover = TimelinePickerPopover.make(width: 240, rows: [
            .init(icon: "eye.slash", title: "Add Blur",
                  detail: "Drag over an area to blur it") { [weak self] in
                guard let self else { return }
                if let arm = self.onArmBlurDraw { arm(.blur) } else { self.addBlurRegion() }
            },
            .init(icon: "squareshape.split.3x3", title: "Add Pixelate",
                  detail: "Drag over an area to pixelate it") { [weak self] in
                guard let self else { return }
                if let arm = self.onArmBlurDraw { arm(.pixelate) } else { self.addBlurRegion() }
            },
            .init(icon: "highlighter", title: "Add Highlight",
                  detail: "Highlight a region of the video") { [weak self] in self?.addHighlightRegion() },
            .init(icon: "camera.aperture", title: "Add Depth Focus",
                  detail: "Keep a region sharp, blur the rest") { [weak self] in self?.addDepthFocusRegion() },
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

    private enum SelectionLane { case zoom, tilt, blur, voiceOver, highlight, depthFocus, cameraLayout, speed, clip, annotation }

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
        if lane != .annotation { selection.selectedAnnotationID = nil }
        switch lane {
        case .zoom, .tilt:
            selection.selectedHighlightID = nil
            selectedBlurID = nil; selectedVoiceOverID = nil; selectedSpeedID = nil; selectedClipID = nil
            selection.selectedDepthFocusID = nil; selectedCameraLayoutID = nil
        case .blur:
            selection.selectedZoomID = nil; selection.selectedTiltID = nil; selection.selectedHighlightID = nil
            selection.selectedDepthFocusID = nil; selectedCameraLayoutID = nil
            selectedVoiceOverID = nil; selectedClipID = nil
        case .voiceOver:
            selection.selectedZoomID = nil; selection.selectedTiltID = nil; selection.selectedHighlightID = nil
            selectedBlurID = nil; selectedClipID = nil
            selection.selectedDepthFocusID = nil; selectedCameraLayoutID = nil
        case .highlight:
            selection.selectedZoomID = nil; selection.selectedTiltID = nil
            selection.selectedDepthFocusID = nil; selectedCameraLayoutID = nil
            selectedBlurID = nil; selectedVoiceOverID = nil; selectedSpeedID = nil; selectedClipID = nil
        case .depthFocus:
            selection.selectedZoomID = nil; selection.selectedTiltID = nil
            selection.selectedHighlightID = nil; selectedCameraLayoutID = nil
            selectedBlurID = nil; selectedVoiceOverID = nil; selectedSpeedID = nil; selectedClipID = nil

        // Same rules as Depth Focus — they share the FOCUS lane.
        case .cameraLayout:
            selection.selectedZoomID = nil; selection.selectedTiltID = nil
            selection.selectedHighlightID = nil; selection.selectedDepthFocusID = nil
            selectedBlurID = nil; selectedVoiceOverID = nil; selectedSpeedID = nil; selectedClipID = nil
        case .speed:
            selection.selectedZoomID = nil; selection.selectedTiltID = nil; selection.selectedHighlightID = nil
            selectedBlurID = nil; selectedVoiceOverID = nil; selectedClipID = nil
            selection.selectedDepthFocusID = nil; selectedCameraLayoutID = nil
        case .clip:
            selection.selectedZoomID = nil; selection.selectedTiltID = nil; selection.selectedHighlightID = nil
            selectedBlurID = nil; selectedVoiceOverID = nil; selectedSpeedID = nil
            selection.selectedDepthFocusID = nil; selectedCameraLayoutID = nil
        case .annotation:
            selection.selectedZoomID = nil; selection.selectedTiltID = nil; selection.selectedHighlightID = nil
            selectedBlurID = nil; selectedVoiceOverID = nil; selectedSpeedID = nil; selectedClipID = nil
            selection.selectedDepthFocusID = nil; selectedCameraLayoutID = nil
        }
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
        playButton?.toolTip = isPlaying ? "Pause" : "Play"
        voiceButton?.icon = isRecordingVoiceOver ? "stop.fill" : "mic.fill"
        voiceButton?.tint = isRecordingVoiceOver ? .systemRed : nil
        voiceButton?.toolTip = isRecordingVoiceOver ? "Stop Recording" : "Record Voice Over"
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

    // MARK: - Ported edit logic

    private var fullTimeMap: SpeedTimeMap {
        SpeedTimeMap(
            sourceStart: project.effectiveTrimStart,
            sourceEnd: max(project.effectiveTrimStart, project.effectiveTrimEnd),
            regions: project.speedRegions
        )
    }

    /// The Slide's span matches some effect block — it renders as part of
    /// that block, not as its own chip.
    private var slideJoinsABlock: Bool {
        guard project.settings.introSlideStyle != .off else { return false }
        let map = fullTimeMap
        let s0 = project.settings.introSlideStart
        let s1 = s0 + project.settings.introSlideDuration
        let spans = project.zoomRegions.map { ($0.startTime, $0.endTime) }
            + project.tiltRegions.map { ($0.startTime, $0.endTime) }
        return spans.contains {
            abs(map.outputTime(forSource: $0.0) - s0) < 0.05
                && abs(map.outputTime(forSource: $0.1) - s1) < 0.08
        }
    }

    /// Output duration of the trimmed recording (scaled by speed regions).
    private var outputDuration: TimeInterval {
        max(0.0001, fullTimeMap.outputDuration)
    }

    /// Trim start in output time — always 0 in the trim-based map.
    private var outputTrimStart: TimeInterval { 0 }

    /// Trim end in output time — the end of the trim-based map.
    private var outputTrimEnd: TimeInterval {
        fullTimeMap.outputDuration
    }

    private var visibleDuration: TimeInterval {
        max(0, outputTrimEnd - outputTrimStart)
    }

    private var visibleCurrentTime: TimeInterval {
        max(0, fullTimeMap.outputTime(forSource: currentTime) - outputTrimStart)
    }

    /// EFFECTS sub-rows currently required (≥ 1) — overlapping effects stack
    /// instead of hiding each other. Updated from the snapshot on every
    /// canvas rebuild; the same shared row math the canvas draws with.
    private var effectsLaneRowCount = 1

    private var totalTracksHeight: CGFloat {
        5 * trackHeight + 4 * trackSpacing
            + CGFloat(effectsLaneRowCount - 1) * TimelineCanvasMetrics.subRowPitch
    }

    private var timelineTrackAreaHeight: CGFloat {
        rulerHeight + rulerBottomSpacing + totalTracksHeight
    }

    private var timelineCanvasHeight: CGFloat {
        timelineTrackAreaHeight + timelineBottomInset
    }

    /// Flat toolbar row above the tracks — extracted so the body stays
    /// cheap for the type-checker.

    private func canvasVideoModel() -> TimelineVideoRowModel {
        let map = fullTimeMap
        return TimelineVideoRowModel.make(
            project: project,
            timeMap: map,
            selectedClipID: selectedClipID,
            hasAudio: !audioSamples.isEmpty,
            hasThumbnails: !thumbnails.isEmpty,
            snapCandidates: videoTrackSnapCandidates(for: project).map { map.outputTime(forSource: $0) }
        )
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
        let commits = VideoTrackCommits(
            project: project,
            timeMap: fullTimeMap,
            undoManager: undoManager,
            outputDuration: outputDuration
        )
        return TimelineVideoCallbacks(
            selectClip: { [self] id in
                selectedClipID = id
                // Clicking the AppKit canvas must not strand SwiftUI focus.
                focusTimeline()
            },
            commitWholeDrag: { mode, delta, start, end in
                commits.commitWholeDrag(mode: mode, delta: delta, resolvedStart: start, resolvedEnd: end)
            },
            commitClipMove: { clip, resolvedStart in
                commits.commitClipMove(clip, resolvedOutputStart: resolvedStart)
            },
            commitClipEdge: { clip, side, resolved in
                commits.commitClipEdge(clip, side: side, resolvedOutput: resolved)
            },
            toggleMute: { [self] in project.settings.muteRecordedAudio.toggle() },
            addSpeedRange: { [self] start, end, speed in addSpeedRegion(start: start, end: end, speed: speed) },
            changeSpeed: { [self] id, speed in changeSpeedRegion(id: id, speed: speed) },
            deleteSpeed: { [self] id in deleteSpeedRegion(id: id) },
            deleteSplit: { [self] outputTime in removeSplit(nearOutputTime: outputTime) },
            sliceAt: { [self] outputTime in
                let sourceTime = fullTimeMap.sourceTime(forOutput: outputTime)
                if splitVideoClip(at: sourceTime) {
                    sliceMode = false
                    clearSliceHover()
                }
            }
        )
    }

    // MARK: - Native VOICE row inputs

    /// Presentation-ready VOICE row snapshot for the AppKit canvas. The
    /// derivation is shared with the screenshot harness (see
    /// `TimelineVoiceRowModel.make`).
    private func canvasVoiceModel() -> TimelineVoiceRowModel {
        TimelineVoiceRowModel.make(
            project: project,
            timeMap: fullTimeMap,
            outputDuration: outputDuration,
            playheadTime: currentTime,
            selectedVoiceOverID: selectedVoiceOverID,
            isRecordingVoiceOver: isRecordingVoiceOver,
            recordingStartTime: voiceOverRecordingStartTime,
            recordingCurrentTime: currentTime,
            liveSamples: liveVoiceOverSamples
        )
    }

    private func canvasVoiceAssets() -> TimelineVoiceAssets {
        TimelineVoiceAssets(waveforms: voiceWaveforms, signature: voiceWaveformSignature)
    }

    private func canvasVoiceCallbacks() -> TimelineVoiceCallbacks {
        let commits = VoiceTrackCommits(project: project, timeMap: fullTimeMap)
        return TimelineVoiceCallbacks(
            selectClip: { [self] id in
                selectedVoiceOverID = id
                // Clicking the AppKit canvas must not strand SwiftUI focus.
                focusTimeline()
            },
            commitClip: { id, outputValue in
                commits.commit(id: id, outputValue: outputValue)
            },
            deleteClip: { [self] id in deleteVoiceOverClip(id: id) }
        )
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

    /// Same pairing as EffectsTrackContent.items — each zoom claims the first
    /// unclaimed co-spanning tilt; unclaimed tilts append last for z-order.
    private func canvasEffectItems() -> [EffectBlockItem] {
        let map = fullTimeMap
        let epsilon = EffectBlockItem.linkEpsilon
        var claimedTilts: Set<UUID> = []
        var result: [EffectBlockItem] = []

        for zoom in project.zoomRegions {
            let match = project.tiltRegions.first { tilt in
                !claimedTilts.contains(tilt.id)
                    && abs(tilt.startTime - zoom.startTime) <= epsilon
                    && abs(tilt.endTime - zoom.endTime) <= epsilon
            }
            if let match { claimedTilts.insert(match.id) }
            result.append(
                EffectBlockItem(
                    zoomID: zoom.id,
                    tiltID: match?.id,
                    startTime: map.outputTime(forSource: zoom.startTime),
                    endTime: map.outputTime(forSource: zoom.endTime),
                    zoomLevel: zoom.zoomLevel,
                    pitch: match?.pitch ?? 0,
                    yaw: match?.yaw ?? 0,
                    roll: match?.roll ?? 0
                )
            )
        }
        for tilt in project.tiltRegions where !claimedTilts.contains(tilt.id) {
            result.append(
                EffectBlockItem(
                    zoomID: nil,
                    tiltID: tilt.id,
                    startTime: map.outputTime(forSource: tilt.startTime),
                    endTime: map.outputTime(forSource: tilt.endTime),
                    zoomLevel: nil,
                    pitch: tilt.pitch,
                    yaw: tilt.yaw,
                    roll: tilt.roll
                )
            )
        }
        // The Slide joins a block whose output span it matches — one linked
        // block on the lane instead of two stacked chips.
        if project.settings.introSlideStyle != .off {
            let s0 = project.settings.introSlideStart
            let s1 = s0 + project.settings.introSlideDuration
            if let i = result.firstIndex(where: {
                abs($0.startTime - s0) < 0.05 && abs($0.endTime - s1) < 0.08
            }) {
                result[i].hasSlide = true
            }
        }
        return result
    }

    private func canvasSnapshot() -> TimelineCanvasSnapshot {
        let map = fullTimeMap
        let focus: [TimelineFocusItem] =
            project.blurRegions.map { region in
                TimelineFocusItem(
                    id: region.id,
                    isHighlight: false,
                    startTime: map.outputTime(forSource: region.startTime),
                    endTime: map.outputTime(forSource: region.endTime),
                    label: region.label,
                    isSelected: selectedBlurID == region.id
                )
            }
            + project.focusRegions.map { region in
                TimelineFocusItem(
                    id: region.id,
                    isHighlight: false,
                    startTime: map.outputTime(forSource: region.startTime),
                    endTime: map.outputTime(forSource: region.endTime),
                    label: region.label,
                    isSelected: selectedDepthFocusID == region.id
                )
            }
            + project.cameraLayoutRegions.map { region in
                TimelineFocusItem(
                    id: region.id,
                    isHighlight: false,
                    startTime: map.outputTime(forSource: region.startTime),
                    endTime: map.outputTime(forSource: region.endTime),
                    label: "Camera: \(region.mode.displayName)",
                    isSelected: selectedCameraLayoutID == region.id
                )
            }
            + project.highlightRegions.map { region in
                TimelineFocusItem(
                    id: region.id,
                    isHighlight: true,
                    startTime: map.outputTime(forSource: region.startTime),
                    endTime: map.outputTime(forSource: region.endTime),
                    label: region.label,
                    isSelected: selectedHighlightID == region.id
                )
            }

        let annotate: [TimelineAnnotateItem] = project.annotations.map { annotation in
            TimelineAnnotateItem(
                id: annotation.id,
                startTime: map.outputTime(forSource: annotation.startTime),
                endTime: map.outputTime(forSource: annotation.endTime),
                label: Self.annotationLaneLabel(for: annotation),
                icon: Self.annotationLaneIcon(for: annotation.type),
                isSelected: selectedAnnotationID == annotation.id
            )
        }

        return TimelineCanvasSnapshot(
            outputDuration: outputDuration,
            playheadOutputTime: map.outputTime(forSource: currentTime),
            // Permanently false: the red slice-snap playhead is drawn by the
            // canvas from its OWN hover state (`sliceSnapActive`), which is the
            // only place that knows where the cursor is.
            playheadIsRed: false,
            playheadHitTestEnabled: !sliceMode,
            scrubLabel: scrubBubbleText(visibleCurrentTime),
            effectItems: canvasEffectItems(),
            introChipStart: project.settings.introSlideStart,
            introChipEnd: (project.settings.introSlideStyle == .off || slideJoinsABlock) ? nil
                : min(project.settings.introSlideStart
                      + project.settings.introSlideDuration, outputDuration),
            introChipSelected: selection.introSelected,
            introChipLabel: project.settings.introSlideStart <= 0.01 ? "Slide In" : "Slide",
            introChipIcon: {
                switch project.settings.introSlideStyle {
                case .top: "arrow.down.to.line"
                case .bottom: "arrow.up.to.line"
                case .left: "arrow.right.to.line"
                case .right: "arrow.left.to.line"
                case .off: "arrow.up.to.line"
                }
            }(),
            curtainChipStart: project.settings.curtainUnveilStart,
            curtainChipEnd: project.settings.curtainUnveilCorner == .off ? nil
                : min(project.settings.curtainUnveilStart
                      + project.settings.curtainUnveilDuration, outputDuration),
            curtainChipSelected: selection.curtainSelected,
            selectedZoomID: selectedZoomID,
            selectedTiltID: selectedTiltID,
            focusItems: focus,
            annotateItems: annotate,
            trimStartOutput: map.outputTime(forSource: project.effectiveTrimStart),
            trimEndOutput: map.outputTime(forSource: project.effectiveTrimEnd),
            sliceArmed: sliceMode,
            timelessVideo: project.hidesTimelinePlayhead,
            dimmedRuler: project.presentsTimelessTimeline && project.hasTimedEffects
        )
    }

    /// Block caption on the ANNOTATE lane — the text/label for text-bearing
    /// types, the type name otherwise.
    static func annotationLaneLabel(for annotation: Annotation) -> String {
        switch annotation.type {
        case .text, .callout:
            let trimmed = annotation.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Text" : trimmed
        case .arrow: return "Arrow"
        case .drawing: return "Drawing"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .tap: return "Tap"
        }
    }

    static func annotationLaneIcon(for type: AnnotationType) -> String {
        switch type {
        case .text: return "text.bubble"
        case .arrow: return "arrow.up.right"
        case .callout: return "pencil.tip"
        case .drawing: return "pencil.and.scribble"
        case .rectangle: return "rectangle"
        case .ellipse: return "oval"
        case .tap: return "hand.tap"
        }
    }

    /// Output-time callbacks from the canvas, converted to source time here
    /// and routed into the same undo-registered functions the SwiftUI lanes
    /// used. The FOCUS commit mirrors the old direct binding write.
    private func canvasCallbacks(scaledWidth: CGFloat) -> TimelineCanvasCallbacks {
        let map = fullTimeMap
        return TimelineCanvasCallbacks(
            scrub: { [self] x in
                focusTimeline()
                scrubTo(x: x, in: scaledWidth)
            },
            seek: { [self] x in seekTo(x: x, in: scaledWidth) },
            selectEffect: { [self] zoomID, tiltID in
                selection.introSelected = false
                selection.curtainSelected = false
                selectedZoomID = zoomID
                selectedTiltID = tiltID
                // Clicking the AppKit canvas must not strand SwiftUI focus —
                // ⌫/space/arrows live on the focused timeline view.
                focusTimeline()
            },
            openIntro: { [self] in
                selectedZoomID = nil
                selectedTiltID = nil
                selection.curtainSelected = false
                selection.introSelected = true
                selection.inspectorTab = .effects
                selection.showInspector = true
            },
            deleteIntro: { [self] in
                selection.introSelected = true
                _ = deleteSelectedRegion()
            },
            resizeIntro: { [self] end in
                project.settings.introSlideDuration = max(0.3, end - project.settings.introSlideStart)
            },
            moveIntro: { [self] start in
                let outputDuration = fullTimeMap.outputTime(forSource: project.duration)
                project.settings.introSlideStart = min(
                    max(0, start),
                    max(0, outputDuration - project.settings.introSlideDuration))
            },
            openCurtain: { [self] in
                selectedZoomID = nil
                selectedTiltID = nil
                selection.introSelected = false
                selection.curtainSelected = true
                selection.inspectorTab = .effects
                selection.showInspector = true
            },
            deleteCurtain: { [self] in
                selection.curtainSelected = true
                _ = deleteSelectedRegion()
            },
            resizeCurtain: { [self] end in
                project.settings.curtainUnveilDuration = max(0.3, end - project.settings.curtainUnveilStart)
            },
            moveCurtain: { [self] start in
                let outputDuration = fullTimeMap.outputTime(forSource: project.duration)
                project.settings.curtainUnveilStart = min(
                    max(0, start),
                    max(0, outputDuration - project.settings.curtainUnveilDuration))
            },
            commitEffectTimes: { [self] zoomID, tiltID, start, end in
                commitEffectBlockTimes(
                    zoomID: zoomID,
                    tiltID: tiltID,
                    start: map.sourceTime(forOutput: start),
                    end: map.sourceTime(forOutput: end)
                )
            },
            setZoomLevel: { [self] id, level in setZoomLevel(id: id, level: level) },
            addZoomToBlock: { [self] tiltID in addZoomToBlock(tiltID: tiltID) },
            addTiltToBlock: { [self] zoomID in addTiltToBlock(zoomID: zoomID) },
            removeZoom: { [self] id in deleteZoomRegion(id: id) },
            removeTilt: { [self] id in deleteTiltRegion(id: id) },
            deleteEffectBlock: { [self] zoomID, tiltID in deleteEffectBlock(zoomID: zoomID, tiltID: tiltID) },
            addZoomAt: { [self] time in addZoomRegion(at: map.sourceTime(forOutput: time)) },
            addTiltAt: { [self] time in addTiltRegion(at: map.sourceTime(forOutput: time)) },
            selectFocus: { [self] id, isHighlight in
                selection.introSelected = false
                selection.curtainSelected = false
                focusTimeline()
                if let id {
                    if isHighlight {
                        selectedHighlightID = id
                        selectedBlurID = nil
                        selectedDepthFocusID = nil
                    } else if project.focusRegions.contains(where: { $0.id == id }) {
                        // Depth Focus rides the FOCUS lane as a non-highlight
                        // item; the ID picks the array.
                        selectedDepthFocusID = id
                        selectedBlurID = nil
                        selectedHighlightID = nil
                        selectedCameraLayoutID = nil
                    } else if project.cameraLayoutRegions.contains(where: { $0.id == id }) {
                        selectedCameraLayoutID = id
                        selectedBlurID = nil
                        selectedHighlightID = nil
                        selectedDepthFocusID = nil
                    } else {
                        selectedBlurID = id
                        selectedHighlightID = nil
                        selectedDepthFocusID = nil
                        selectedCameraLayoutID = nil
                    }
                } else {
                    selectedBlurID = nil
                    selectedHighlightID = nil
                    selectedDepthFocusID = nil
                    selectedCameraLayoutID = nil
                }
            },
            commitFocusTimes: { [self] id, isHighlight, start, end in
                let sourceStart = map.sourceTime(forOutput: start)
                let sourceEnd = map.sourceTime(forOutput: end)
                if isHighlight {
                    guard let index = project.highlightRegions.firstIndex(where: { $0.id == id }) else { return }
                    project.highlightRegions[index].startTime = sourceStart
                    project.highlightRegions[index].endTime = sourceEnd
                } else if let index = project.focusRegions.firstIndex(where: { $0.id == id }) {
                    project.focusRegions[index].startTime = sourceStart
                    project.focusRegions[index].endTime = sourceEnd
                } else if let index = project.cameraLayoutRegions.firstIndex(where: { $0.id == id }) {
                    project.cameraLayoutRegions[index].startTime = sourceStart
                    project.cameraLayoutRegions[index].endTime = sourceEnd
                } else {
                    guard let index = project.blurRegions.firstIndex(where: { $0.id == id }) else { return }
                    project.blurRegions[index].startTime = sourceStart
                    project.blurRegions[index].endTime = sourceEnd
                }
            },
            deleteFocus: { [self] id, isHighlight in
                if isHighlight {
                    deleteHighlightRegion(id: id)
                } else if project.focusRegions.contains(where: { $0.id == id }) {
                    deleteDepthFocusRegion(id: id)
                } else if project.cameraLayoutRegions.contains(where: { $0.id == id }) {
                    deleteCameraLayoutRegion(id: id)
                } else {
                    deleteBlurRegion(id: id)
                }
            },
            addBlurAt: { [self] time in addBlurRegion(at: map.sourceTime(forOutput: time)) },
            addHighlightAt: { [self] time in addHighlightRegion(at: map.sourceTime(forOutput: time)) },
            selectAnnotation: { [self] id in
                selection.introSelected = false
                selection.curtainSelected = false
                selectedAnnotationID = id
                // Seek-if-not-visible (the Descript/CapCut overlay pattern):
                // when the playhead is outside the block's span, jump into it
                // so the selected annotation is actually ON SCREEN — which is
                // also what summons the contextual toolbar above it. Inside
                // the span, the playhead stays put (FCP rule).
                if let a = project.annotations.first(where: { $0.id == id }),
                   currentTime < a.startTime || currentTime > a.endTime {
                    isPlaying = false
                    seekToSource(min(a.startTime + 0.05, a.endTime))
                }
                focusTimeline()
            },
            commitAnnotationTimes: { [self] id, start, end in
                commitAnnotationTimes(
                    id: id,
                    start: map.sourceTime(forOutput: start),
                    end: map.sourceTime(forOutput: end)
                )
            },
            deleteAnnotation: { [self] id in deleteAnnotation(id: id) },
            addAnnotationAt: { [self] type, time in
                addAnnotation(type: type, atSource: map.sourceTime(forOutput: time))
            },
            deleteSelection: { [self] in _ = deleteSelectedRegion() },
            togglePlayback: { [self] in togglePlayback() }
        )
    }

    /// Move/resize commit for an ANNOTATE block, undo-registered like the
    /// other lanes.
    private func commitAnnotationTimes(id: UUID, start: TimeInterval, end: TimeInterval) {
        guard let index = project.annotations.firstIndex(where: { $0.id == id }) else { return }
        let previousStart = project.annotations[index].startTime
        let previousEnd = project.annotations[index].endTime
        guard abs(previousStart - start) > 0.0001 || abs(previousEnd - end) > 0.0001 else { return }
        project.annotations[index].startTime = start
        project.annotations[index].endTime = max(start + 0.25, end)

        undoManager?.registerUndo(withTarget: project) { p in
            guard let i = p.annotations.firstIndex(where: { $0.id == id }) else { return }
            p.annotations[i].startTime = previousStart
            p.annotations[i].endTime = previousEnd
        }
        undoManager?.setActionName("Edit Annotation Timing")
    }

    /// Undo-registered annotation delete — restores the full annotation.
    private func deleteAnnotation(id: UUID) {
        guard let index = project.annotations.firstIndex(where: { $0.id == id }) else { return }
        let removed = project.annotations[index]
        project.annotations.remove(at: index)
        if selectedAnnotationID == id { selectedAnnotationID = nil }

        undoManager?.registerUndo(withTarget: project) { p in
            p.annotations.append(removed)
        }
        undoManager?.setActionName("Delete Annotation")
    }

    /// Disarming the slice tool. The hover state lives in the canvas (it owns
    /// the cursor position), and its `mouseMoved` clear is gated behind
    /// `snapshot.sliceArmed` — so once disarmed it can never clear itself and
    /// the playhead stays red until the next hover.
    private func clearSliceHover() {
        NSCursor.arrow.set()
        canvas.clearSliceHoverState()
    }

    @discardableResult
    private func splitVideoClip(at sourceTime: TimeInterval) -> Bool {
        var clips = project.effectiveVideoClipSegments
        guard let index = clips.firstIndex(where: {
            sourceTime > $0.startTime + 0.1 && sourceTime < $0.endTime - 0.1
        }) else { return false }

        let previousClips = project.videoClipSegments
        let previousSplits = project.splitPoints
        let clip = clips[index]
        clips.remove(at: index)
        clips.insert(VideoClipSegment(startTime: sourceTime, endTime: clip.endTime), at: index)
        clips.insert(VideoClipSegment(startTime: clip.startTime, endTime: sourceTime), at: index)
        project.videoClipSegments = clips

        if !project.splitPoints.contains(where: { abs($0 - sourceTime) < 0.1 }) {
            project.splitPoints.append(sourceTime)
            project.splitPoints.sort()
        }

        undoManager?.registerUndo(withTarget: project) { p in
            p.videoClipSegments = previousClips
            p.splitPoints = previousSplits
        }
        undoManager?.setActionName("Split Clip")
        return true
    }

    /// Delegates to `VideoSliceMath` — same rule for both rows.
    private func isSliceableOutputTime(_ outputTime: TimeInterval) -> Bool {
        let map = fullTimeMap
        let spans = project.effectiveVideoClipSegments.map { clip in
            VideoTrackEditMath.ClipSpan(
                id: UUID(),
                outputStart: map.outputTime(forSource: clip.startTime),
                outputEnd: map.outputTime(forSource: clip.endTime)
            )
        }
        return VideoSliceMath.isSliceable(
            outputTime,
            trimStartOutput: outputTrimStart,
            trimEndOutput: outputTrimEnd,
            clipSpans: spans
        )
    }

    private func removeSplit(nearOutputTime outputTime: TimeInterval) {
        let sourceTime = fullTimeMap.sourceTime(forOutput: outputTime)
        let previousClips = project.videoClipSegments
        let previousSplits = project.splitPoints

        if !project.videoClipSegments.isEmpty {
            var clips = project.videoClipSegments.sorted { $0.startTime < $1.startTime }
            guard let idx = clips.firstIndex(where: { $0.startTime > project.effectiveTrimStart + 0.01 && abs($0.startTime - sourceTime) < 0.2 }),
                  idx > 0 else { return }

            clips[idx - 1].endTime = max(clips[idx - 1].endTime, clips[idx].endTime)
            clips.remove(at: idx)
            project.videoClipSegments = clips
            project.splitPoints = clips.dropFirst().map(\.startTime).sorted()
        } else {
            guard let idx = project.splitPoints.firstIndex(where: { abs($0 - sourceTime) < 0.2 }) else { return }
            project.splitPoints.remove(at: idx)
        }

        undoManager?.registerUndo(withTarget: project) { p in
            p.videoClipSegments = previousClips
            p.splitPoints = previousSplits
        }
        undoManager?.setActionName("Remove Split")
    }

    /// Lifts a clip out of the VIDEO lane, leaving a gap where it was.
    ///
    /// This is the removal the model already supports, not a new operation:
    /// `Project.effectiveVideoClipSegments` is just an array of source ranges,
    /// dragging a clip can already open a gap between two of them, and both
    /// renderers skip uncovered source time via `Project.hasVisibleVideo(at:)`
    /// (PreviewView + VideoExporter). The write mirrors `removeSplit` exactly:
    /// materialise the effective segments, drop one, re-derive `splitPoints`,
    /// register undo. Deliberately NOT a ripple delete — closing the gap would
    /// mean re-timing every clip, region, annotation and subtitle, and no
    /// existing operation does that.
    private func deleteVideoClip(id: UUID) {
        let clips = project.effectiveVideoClipSegments
        // Never leave the timeline with no video at all.
        guard clips.count > 1, clips.contains(where: { $0.id == id }) else { return }

        let previousClips = project.videoClipSegments
        let previousSplits = project.splitPoints

        let remaining = clips.filter { $0.id != id }
        project.videoClipSegments = remaining
        project.splitPoints = remaining.dropFirst().map(\.startTime).sorted()
        selectedClipID = nil

        undoManager?.registerUndo(withTarget: project) { p in
            p.videoClipSegments = previousClips
            p.splitPoints = previousSplits
        }
        undoManager?.setActionName("Delete Clip")
    }

    /// Compact scrub readout, e.g. "0:02.4".
    private func scrubBubbleText(_ time: TimeInterval) -> String {
        let total = max(0, time)
        let minutes = Int(total) / 60
        let seconds = total - Double(minutes * 60)
        return String(format: "%d:%04.1f", minutes, seconds)
    }

    private func deleteIntroSlide() {
        let settings = project.settings
        let prevStyle = settings.introSlideStyle
        guard prevStyle != .off else { return }
        let prevStart = settings.introSlideStart
        let prevDuration = settings.introSlideDuration
        settings.introSlideStyle = .off
        selection.introSelected = false
        undoManager?.registerUndo(withTarget: project) { project in
            project.settings.introSlideStyle = prevStyle
            project.settings.introSlideStart = prevStart
            project.settings.introSlideDuration = prevDuration
        }
        undoManager?.setActionName("Delete Slide")
    }

    private func deleteCurtainUnveil() {
        let settings = project.settings
        let prevCorner = settings.curtainUnveilCorner
        guard prevCorner != .off else { return }
        let prevStart = settings.curtainUnveilStart
        let prevDuration = settings.curtainUnveilDuration
        settings.curtainUnveilCorner = .off
        selection.curtainSelected = false
        undoManager?.registerUndo(withTarget: project) { project in
            project.settings.curtainUnveilCorner = prevCorner
            project.settings.curtainUnveilStart = prevStart
            project.settings.curtainUnveilDuration = prevDuration
        }
        undoManager?.setActionName("Delete Curtain Unveil")
    }

    /// Anything the trash button / Delete key can act on right now.
    private var hasDeletableSelection: Bool {
        selection.introSelected
            || selection.curtainSelected
            || selection.selectedDepthFocusID != nil
            || selectedZoomID != nil
            || selectedBlurID != nil
            || selectedVoiceOverID != nil
            || selectedHighlightID != nil
            || selectedSpeedID != nil
            || selectedTiltID != nil
            || canDeleteSelectedClip
    }

    /// A clip can only be lifted while another one remains.
    private var canDeleteSelectedClip: Bool {
        guard let id = selectedClipID else { return false }
        let clips = project.effectiveVideoClipSegments
        return clips.count > 1 && clips.contains { $0.id == id }
    }

    private func videoTrackSnapCandidates(for project: Project) -> [TimeInterval] {
        var out: [TimeInterval] = []
        out += project.zoomRegions.flatMap { [$0.startTime, $0.endTime] }
        out += project.blurRegions.flatMap { [$0.startTime, $0.endTime] }
        out += project.highlightRegions.flatMap { [$0.startTime, $0.endTime] }
        out += project.speedRegions.flatMap { [$0.startTime, $0.endTime] }
        out.append(currentTime) // playhead is a snap target, like CapCut
        return out
    }


    // MARK: - Toolbar helpers


    private func seekTo(x: CGFloat, in width: CGFloat) {
        guard project.duration > 0 else { return }
        let fraction = max(0, min(1, x / width))
        let outputSeekTime = fraction * outputDuration
        let sourceSeekTime = fullTimeMap.sourceTime(forOutput: outputSeekTime)
        playback.scrub(to: sourceSeekTime, for: project, exact: true)
    }

    private func scrubTo(x: CGFloat, in width: CGFloat) {
        guard project.duration > 0 else { return }
        let fraction = max(0, min(1, x / width))
        let outputSeekTime = fraction * outputDuration
        let sourceSeekTime = fullTimeMap.sourceTime(forOutput: outputSeekTime)
        playback.scrub(to: sourceSeekTime, for: project, exact: false)
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
    /// visible window, like CapCut/FCP.
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

    private func splitAtPlayhead() {
        let outputCurrent = fullTimeMap.outputTime(forSource: currentTime)
        guard isSliceableOutputTime(outputCurrent) else { return }
        _ = splitVideoClip(at: currentTime)
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

    private func addCameraLayoutRegion(mode: CameraLayoutMode) {
        // Playhead near the start = "this is my intro": snap to 0 so the
        // video OPENS on the arrangement (CameraLayoutMath renders a block
        // at t=0 settled from frame one, no ease-in from the bubble).
        var desiredStart = max(0, min(currentTime, project.duration))
        if desiredStart < 0.75 { desiredStart = 0 }
        let desiredEnd = min(desiredStart + 4, project.duration)
        // Shares the FOCUS lane with blur + highlight + depth focus.
        let (start, end) = findNonOverlappingSlot(
            desired: (desiredStart, desiredEnd),
            existing: project.blurRegions.map { ($0.startTime, $0.endTime) }
                + project.highlightRegions.map { ($0.startTime, $0.endTime) }
                + project.focusRegions.map { ($0.startTime, $0.endTime) }
                + project.cameraLayoutRegions.map { ($0.startTime, $0.endTime) },
            duration: project.duration
        )
        guard start < end else { NSSound.beep(); return } // lane full

        let region = CameraLayoutRegion(startTime: start, endTime: end, mode: mode)
        project.cameraLayoutRegions.append(region)
        selectedCameraLayoutID = region.id

        undoManager?.registerUndo(withTarget: project) { project in
            project.cameraLayoutRegions.removeAll { $0.id == region.id }
        }
        undoManager?.setActionName("Add Camera Layout")
    }

    private func deleteCameraLayoutRegion(id: UUID) {
        guard let index = project.cameraLayoutRegions.firstIndex(where: { $0.id == id }) else { return }
        let region = project.cameraLayoutRegions[index]
        project.cameraLayoutRegions.remove(at: index)
        if selectedCameraLayoutID == id { selectedCameraLayoutID = nil }
        undoManager?.registerUndo(withTarget: project) { project in
            project.cameraLayoutRegions.append(region)
        }
        undoManager?.setActionName("Delete Camera Layout")
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

    // MARK: - Zoom regions

    private func autoZoom() {
        // Shared with the MCP tool and the record-stop hook (AutoZoomApplier):
        // regenerating replaces only earlier AUTO regions; the user's
        // hand-placed blocks stay and the generator routes around them.
        let previousRegions = project.zoomRegions
        guard AutoZoomApplier.apply(to: project) > 0 else { return }
        selectedZoomID = nil

        undoManager?.registerUndo(withTarget: project) { project in
            project.zoomRegions = previousRegions
        }
        undoManager?.setActionName("Auto Zoom")
    }

    // MARK: - Motion (still-image cinematic tour)

    /// Motion for image captures: the four-corner cinematic tour
    /// (StillMotionComposer). Regenerating replaces earlier generated
    /// regions; existing zoom blocks prompt a confirm first (CCAlert).
    private func stillMotion() {
        if !project.zoomRegions.isEmpty, let window = view.window {
            CCAlert(
                title: "Replace Zoom Blocks?",
                message: "Motion generates a new camera journey. "
                    + "Previously generated blocks will be replaced."
            )
            .addButton("Generate", role: .primary)
            .addButton("Cancel")
            .beginSheet(for: window) { [weak self] index in
                guard index == 0 else { return }
                self?.runStillMotion()
            }
        } else {
            runStillMotion()
        }
    }

    private func runStillMotion() {
        let previousZooms = project.zoomRegions
        let previousTilts = project.tiltRegions
        guard StillMotionApplier.apply(to: project) > 0 else { return }
        selectedZoomID = nil
        selectedTiltID = nil
        undoManager?.registerUndo(withTarget: project) { project in
            project.zoomRegions = previousZooms
            project.tiltRegions = previousTilts
        }
        undoManager?.setActionName("Motion")
    }

    /// Adds a zoom region. `startTime` is a source time — defaults to the
    /// playhead, but right-clicking a track passes the clicked time instead.
    private func addZoomRegion(at startTime: TimeInterval? = nil) {
        let desiredStart = max(0, min(startTime ?? currentTime, project.duration))
        let desiredEnd = min(desiredStart + 3, project.duration)

        // Find a slot free of EVERY block on the lane — zoom, tilt and linked.
        var (start, end) = findNonOverlappingSlot(
            desired: (desiredStart, desiredEnd),
            existing: effectLaneSpans,
            duration: project.duration
        )
        // No free slot → keep the desired span; overlapping effects stack
        // into EFFECTS sub-rows instead of being refused.
        if start >= end { (start, end) = (desiredStart, desiredEnd) }
        guard start < end else { return } // zero-length timeline

        let region = ZoomRegion(startTime: start, endTime: end)
        project.zoomRegions.append(region)
        // A standalone zoom is its own EFFECTS block — drop any tilt selection.
        selectedTiltID = nil
        selectedZoomID = region.id

        undoManager?.registerUndo(withTarget: project) { project in
            project.zoomRegions.removeAll { $0.id == region.id }
        }
        undoManager?.setActionName("Add Zoom")
    }

    private func deleteZoomRegion(id: UUID) {
        guard let index = project.zoomRegions.firstIndex(where: { $0.id == id }) else { return }
        let region = project.zoomRegions[index]
        project.zoomRegions.remove(at: index)
        if selectedZoomID == id { selectedZoomID = nil }

        undoManager?.registerUndo(withTarget: project) { project in
            let insertIndex = min(index, project.zoomRegions.count)
            project.zoomRegions.insert(region, at: insertIndex)
        }
        undoManager?.setActionName("Delete Zoom")
    }

    // MARK: - Tilt regions

    private func addTiltRegion(at startTime: TimeInterval? = nil) {
        let desiredStart = max(0, min(startTime ?? currentTime, project.duration))
        let desiredEnd = min(desiredStart + 3, project.duration)

        // Blocks share one lane, so a new tilt must clear zoom-only and linked
        // blocks too. ("Add Tilt to Block" is the exempt case — it deliberately
        // co-spans its own block and never routes through here.)
        var (start, end) = findNonOverlappingSlot(
            desired: (desiredStart, desiredEnd),
            existing: effectLaneSpans,
            duration: project.duration
        )
        // No free slot → keep the desired span; overlapping effects stack
        // into EFFECTS sub-rows instead of being refused.
        if start >= end { (start, end) = (desiredStart, desiredEnd) }
        guard start < end else { return } // zero-length timeline

        // Seed with the Motion tab's skew angles so "make the tilt, then add
        // it to the timeline" carries the user's current look; fall back to a
        // visible default if the sliders are all flat.
        let s = project.settings
        let hasSkew = max(abs(s.screenTiltAngle), abs(s.screenTiltYaw), abs(s.screenTiltRoll)) > 0.01
        let region = TiltRegion(
            startTime: start,
            endTime: end,
            pitch: hasSkew ? s.screenTiltAngle : 20,
            yaw: hasSkew ? s.screenTiltYaw : 0,
            roll: hasSkew ? s.screenTiltRoll : 0
        )
        project.tiltRegions.append(region)
        // A standalone tilt is its own EFFECTS block — drop any zoom selection.
        selectedZoomID = nil
        selectedTiltID = region.id

        undoManager?.registerUndo(withTarget: project) { project in
            project.tiltRegions.removeAll { $0.id == region.id }
        }
        undoManager?.setActionName("Add Tilt")
    }

    private func deleteTiltRegion(id: UUID) {
        guard let index = project.tiltRegions.firstIndex(where: { $0.id == id }) else { return }
        let region = project.tiltRegions[index]
        project.tiltRegions.remove(at: index)
        if selectedTiltID == id { selectedTiltID = nil }

        undoManager?.registerUndo(withTarget: project) { project in
            let insertIndex = min(index, project.tiltRegions.count)
            project.tiltRegions.insert(region, at: insertIndex)
        }
        undoManager?.setActionName("Delete Tilt")
    }

    // MARK: - Effects lane (zoom + tilt presented as one block)

    /// Writes a dragged/resized block's span back into both halves. Linked
    /// blocks get *identical* times, which also snaps legacy pairs that were
    /// only co-spanning within the link epsilon to exact equality.
    private func commitEffectBlockTimes(
        zoomID: UUID?,
        tiltID: UUID?,
        start: TimeInterval,
        end: TimeInterval
    ) {
        let previousZooms = project.zoomRegions
        let previousTilts = project.tiltRegions
        var changed = false

        if let zoomID, let index = project.zoomRegions.firstIndex(where: { $0.id == zoomID }) {
            project.zoomRegions[index].startTime = start
            project.zoomRegions[index].endTime = end
            changed = true
        }
        if let tiltID, let index = project.tiltRegions.firstIndex(where: { $0.id == tiltID }) {
            project.tiltRegions[index].startTime = start
            project.tiltRegions[index].endTime = end
            changed = true
        }
        guard changed else { return }

        // A joined Slide rides the block it matched before the edit.
        if project.settings.introSlideStyle != .off {
            let map = fullTimeMap
            let s0 = project.settings.introSlideStart
            let prevSpans = (previousZooms.filter { $0.id == zoomID }.map { ($0.startTime, $0.endTime) }
                + previousTilts.filter { $0.id == tiltID }.map { ($0.startTime, $0.endTime) })
            if prevSpans.contains(where: {
                abs(map.outputTime(forSource: $0.0) - s0) < 0.05
            }) {
                project.settings.introSlideStart = map.outputTime(forSource: start)
                project.settings.introSlideDuration = max(
                    0.3, map.outputTime(forSource: end) - map.outputTime(forSource: start))
            }
        }

        undoManager?.registerUndo(withTarget: project) { project in
            project.zoomRegions = previousZooms
            project.tiltRegions = previousTilts
        }
        undoManager?.setActionName("Move Effect")
    }

    private func setZoomLevel(id: UUID, level: Double) {
        guard let index = project.zoomRegions.firstIndex(where: { $0.id == id }) else { return }
        let previous = project.zoomRegions[index].zoomLevel
        guard abs(previous - level) > 0.0001 else { return }
        project.zoomRegions[index].zoomLevel = level

        undoManager?.registerUndo(withTarget: project) { project in
            guard let i = project.zoomRegions.firstIndex(where: { $0.id == id }) else { return }
            project.zoomRegions[i].zoomLevel = previous
        }
        undoManager?.setActionName("Zoom Level")
    }

    /// Adds a tilt that exactly co-spans an existing zoom — the block then
    /// carries both effects.
    private func addTiltToBlock(zoomID: UUID) {
        guard let zoom = project.zoomRegions.first(where: { $0.id == zoomID }) else { return }

        let s = project.settings
        let hasSkew = max(abs(s.screenTiltAngle), abs(s.screenTiltYaw), abs(s.screenTiltRoll)) > 0.01
        let region = TiltRegion(
            startTime: zoom.startTime,
            endTime: zoom.endTime,
            pitch: hasSkew ? s.screenTiltAngle : 20,
            yaw: hasSkew ? s.screenTiltYaw : 0,
            roll: hasSkew ? s.screenTiltRoll : 0
        )
        project.tiltRegions.append(region)
        selectedZoomID = zoomID
        selectedTiltID = region.id

        undoManager?.registerUndo(withTarget: project) { project in
            project.tiltRegions.removeAll { $0.id == region.id }
        }
        undoManager?.setActionName("Add Tilt to Block")
    }

    /// Adds a zoom that exactly co-spans an existing tilt.
    private func addZoomToBlock(tiltID: UUID) {
        guard let tilt = project.tiltRegions.first(where: { $0.id == tiltID }) else { return }

        let region = ZoomRegion(
            startTime: tilt.startTime,
            endTime: tilt.endTime,
            zoomLevel: project.settings.autoZoomLevel
        )
        project.zoomRegions.append(region)
        selectedZoomID = region.id
        selectedTiltID = tiltID

        undoManager?.registerUndo(withTarget: project) { project in
            project.zoomRegions.removeAll { $0.id == region.id }
        }
        undoManager?.setActionName("Add Zoom to Block")
    }

    /// Deletes every half of a block as a single undoable action.
    private func deleteEffectBlock(zoomID: UUID?, tiltID: UUID?) {
        guard zoomID != nil || tiltID != nil else { return }
        let previousZooms = project.zoomRegions
        let previousTilts = project.tiltRegions

        if let zoomID {
            project.zoomRegions.removeAll { $0.id == zoomID }
            if selectedZoomID == zoomID { selectedZoomID = nil }
        }
        if let tiltID {
            project.tiltRegions.removeAll { $0.id == tiltID }
            if selectedTiltID == tiltID { selectedTiltID = nil }
        }

        undoManager?.registerUndo(withTarget: project) { project in
            project.zoomRegions = previousZooms
            project.tiltRegions = previousTilts
        }
        undoManager?.setActionName("Delete Effect")
    }

    /// Copies a linked zoom+tilt pair into the next free slot, keeping them
    /// co-spanning so the copy also presents as one block.
    private func duplicateEffectPair(zoomID: UUID, tiltID: UUID) -> Bool {
        guard let zoom = project.zoomRegions.first(where: { $0.id == zoomID }),
              let tilt = project.tiltRegions.first(where: { $0.id == tiltID }),
              let slot = duplicateSlot(
                  source: (zoom.startTime, zoom.endTime),
                  existing: effectLaneSpans
              )
        else { return false }

        let zoomCopy = ZoomRegion(
            startTime: slot.start,
            endTime: slot.end,
            zoomLevel: zoom.zoomLevel,
            focalPoint: zoom.focalPoint
        )
        let tiltCopy = TiltRegion(
            startTime: slot.start,
            endTime: slot.end,
            pitch: tilt.pitch,
            yaw: tilt.yaw,
            roll: tilt.roll
        )
        project.zoomRegions.append(zoomCopy)
        project.tiltRegions.append(tiltCopy)
        selectedZoomID = zoomCopy.id
        selectedTiltID = tiltCopy.id

        undoManager?.registerUndo(withTarget: project) { project in
            project.zoomRegions.removeAll { $0.id == zoomCopy.id }
            project.tiltRegions.removeAll { $0.id == tiltCopy.id }
        }
        undoManager?.setActionName("Duplicate Effect")
        return true
    }

    // MARK: - Blur regions

    private func addBlurRegion(at startTime: TimeInterval? = nil) {
        let desiredStart = max(0, min(startTime ?? currentTime, project.duration))
        let desiredEnd = min(desiredStart + 3, project.duration)

        // Check against both blur AND highlight — they share the FOCUS track
        let (start, end) = findNonOverlappingSlot(
            desired: (desiredStart, desiredEnd),
            existing: project.blurRegions.map { ($0.startTime, $0.endTime) }
                + project.highlightRegions.map { ($0.startTime, $0.endTime) }
                + project.focusRegions.map { ($0.startTime, $0.endTime) }
                + project.cameraLayoutRegions.map { ($0.startTime, $0.endTime) },
            duration: project.duration
        )
        guard start < end else { NSSound.beep(); return } // lane full

        let region = BlurRegion(startTime: start, endTime: end, label: "Blur")
        project.blurRegions.append(region)
        selectedBlurID = region.id

        undoManager?.registerUndo(withTarget: project) { project in
            project.blurRegions.removeAll { $0.id == region.id }
        }
        undoManager?.setActionName("Add Blur")
    }

    /// Drag-to-draw entry (popover arms the preview, the preview reports the
    /// drawn rect): same lane-slot rules as addBlurRegion, but the region is
    /// born with the user's rect and the popover's style.
    func createBlurRegion(rect: CGRect, style: BlurStyle) {
        let desiredStart = max(0, min(currentTime, project.duration))
        let desiredEnd = min(desiredStart + 3, project.duration)
        let (start, end) = findNonOverlappingSlot(
            desired: (desiredStart, desiredEnd),
            existing: project.blurRegions.map { ($0.startTime, $0.endTime) }
                + project.highlightRegions.map { ($0.startTime, $0.endTime) }
                + project.focusRegions.map { ($0.startTime, $0.endTime) }
                + project.cameraLayoutRegions.map { ($0.startTime, $0.endTime) },
            duration: project.duration
        )
        guard start < end else { NSSound.beep(); return } // lane full

        let label = style == .pixelate ? "Pixelate" : "Blur"
        let region = BlurRegion(startTime: start, endTime: end, label: label,
                                rect: rect, style: style)
        project.blurRegions.append(region)
        selectedBlurID = region.id

        undoManager?.registerUndo(withTarget: project) { project in
            project.blurRegions.removeAll { $0.id == region.id }
        }
        undoManager?.setActionName("Add \(label)")
    }

    /// Depth Focus: sharp region, graduated blur outside (FocusMath).
    private func addDepthFocusRegion(at startTime: TimeInterval? = nil) {
        let desiredStart = max(0, min(startTime ?? currentTime, project.duration))
        let desiredEnd = min(desiredStart + 3, project.duration)
        // Shares the FOCUS lane with blur + highlight.
        let (start, end) = findNonOverlappingSlot(
            desired: (desiredStart, desiredEnd),
            existing: project.blurRegions.map { ($0.startTime, $0.endTime) }
                + project.highlightRegions.map { ($0.startTime, $0.endTime) }
                + project.focusRegions.map { ($0.startTime, $0.endTime) }
                + project.cameraLayoutRegions.map { ($0.startTime, $0.endTime) },
            duration: project.duration
        )
        guard start < end else { NSSound.beep(); return } // lane full

        let region = FocusRegion(startTime: start, endTime: end)
        project.focusRegions.append(region)
        selectedDepthFocusID = region.id

        undoManager?.registerUndo(withTarget: project) { project in
            project.focusRegions.removeAll { $0.id == region.id }
        }
        undoManager?.setActionName("Add Depth Focus")
    }

    private func deleteDepthFocusRegion(id: UUID) {
        guard let index = project.focusRegions.firstIndex(where: { $0.id == id }) else { return }
        let region = project.focusRegions[index]
        project.focusRegions.remove(at: index)
        if selectedDepthFocusID == id { selectedDepthFocusID = nil }
        undoManager?.registerUndo(withTarget: project) { project in
            project.focusRegions.append(region)
        }
        undoManager?.setActionName("Delete Depth Focus")
    }

    private func deleteBlurRegion(id: UUID) {
        guard let index = project.blurRegions.firstIndex(where: { $0.id == id }) else { return }
        let region = project.blurRegions[index]
        project.blurRegions.remove(at: index)
        if selectedBlurID == id { selectedBlurID = nil }

        undoManager?.registerUndo(withTarget: project) { project in
            let insertIndex = min(index, project.blurRegions.count)
            project.blurRegions.insert(region, at: insertIndex)
        }
        undoManager?.setActionName("Delete Blur")
    }

    private func deleteVoiceOverClip(id: UUID) {
        guard let index = project.voiceOverClips.firstIndex(where: { $0.id == id }) else { return }
        let clip = project.voiceOverClips[index]
        let clipURL = clip.resolvedURL(in: project.projectDirectory)
        let clipData = try? Data(contentsOf: clipURL)
        project.voiceOverClips.remove(at: index)
        if selectedVoiceOverID == id { selectedVoiceOverID = nil }
        try? FileManager.default.removeItem(at: clipURL)

        undoManager?.registerUndo(withTarget: project) { project in
            let insertIndex = min(index, project.voiceOverClips.count)
            project.voiceOverClips.insert(clip, at: insertIndex)
            if let clipData {
                try? FileManager.default.createDirectory(at: project.projectDirectory, withIntermediateDirectories: true)
                try? clipData.write(to: clipURL, options: .atomic)
            }
        }
        undoManager?.setActionName("Delete Voice Over")
    }

    // MARK: - Highlight regions

    private func addHighlightRegion(at startTime: TimeInterval? = nil) {
        let desiredStart = max(0, min(startTime ?? currentTime, project.duration))
        let desiredEnd = min(desiredStart + 3, project.duration)

        // Check against both highlight AND blur — they share the FOCUS track
        let (start, end) = findNonOverlappingSlot(
            desired: (desiredStart, desiredEnd),
            existing: project.highlightRegions.map { ($0.startTime, $0.endTime) }
                + project.blurRegions.map { ($0.startTime, $0.endTime) }
                + project.focusRegions.map { ($0.startTime, $0.endTime) },
            duration: project.duration
        )
        guard start < end else { NSSound.beep(); return } // lane full

        let region = HighlightRegion(startTime: start, endTime: end, label: "Highlight")
        project.highlightRegions.append(region)
        selectedHighlightID = region.id

        undoManager?.registerUndo(withTarget: project) { project in
            project.highlightRegions.removeAll { $0.id == region.id }
        }
        undoManager?.setActionName("Add Highlight")
    }

    /// One creation path for every annotation type — placed AT the playhead
    /// (or an explicit source time from the lane's context menu) with a 3s
    /// default duration, selected immediately so it appears on the ANNOTATE
    /// lane and in the inspector at once.
    // MARK: - Floating annotation pill (EditorShell's bottom-of-preview toolbar)

    /// The pill's tool buttons land here — same path the popover rows used.
    /// Returns the new annotation's id so the shell can hand text/callout
    /// straight to the in-place editor.
    @discardableResult
    func addAnnotationFromToolbar(_ type: AnnotationType) -> UUID? {
        addAnnotation(type: type)
        return selectedAnnotationID
    }

    /// Color chosen on the pill's swatch. A selected annotation is recolored
    /// in place (undoable); with nothing selected the color becomes the
    /// default for annotations the pill creates next.
    private var toolbarAnnotationColor: NSColor?
    func applyToolbarColor(_ color: NSColor) {
        toolbarAnnotationColor = color
        guard let id = selectedAnnotationID,
              let idx = project.annotations.firstIndex(where: { $0.id == id }) else { return }
        let previous = project.annotations[idx].color
        project.annotations[idx].color = CodableColor(color)
        undoManager?.registerUndo(withTarget: project) { p in
            if let i = p.annotations.firstIndex(where: { $0.id == id }) {
                p.annotations[i].color = previous
            }
        }
        undoManager?.setActionName("Recolor Annotation")
    }

    /// Text-mode pill writes (font / weight / background) — the selected
    /// annotation only; no-ops with nothing selected.
    private func mutateSelectedAnnotation(_ change: (inout Annotation) -> Void) {
        guard let id = selectedAnnotationID,
              let idx = project.annotations.firstIndex(where: { $0.id == id }) else { return }
        var annotation = project.annotations[idx]
        change(&annotation)
        project.annotations[idx] = annotation
    }

    func applyToolbarFont(_ name: String?) {
        mutateSelectedAnnotation { $0.fontName = name }
    }

    func applyToolbarWeight(_ weight: ProjectSettings.SubtitleWeight) {
        mutateSelectedAnnotation { $0.fontWeight = weight }
    }

    func toggleToolbarBackground() {
        mutateSelectedAnnotation { $0.showBackground.toggle() }
    }

    func applyToolbarBackgroundColor(_ color: NSColor) {
        mutateSelectedAnnotation {
            $0.backgroundColor = CodableColor(color)
            // Picking a background color IS turning the background on.
            $0.showBackground = true
        }
    }

    /// Pill size slider: ripple size for taps, border/line width otherwise.
    func applyToolbarSize(_ value: Double) {
        mutateSelectedAnnotation {
            if $0.type == .tap { $0.fontSize = value } else { $0.lineWidth = value }
        }
    }

    /// The selected annotation, for the pill's per-type configuration.
    func toolbarSelectedAnnotation() -> Annotation? {
        guard let id = selectedAnnotationID else { return nil }
        return project.annotations.first(where: { $0.id == id })
    }

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

    /// Typography of the selected annotation, for the pill's text controls.
    func toolbarSelectedTypography() -> (fontName: String?, weight: ProjectSettings.SubtitleWeight)? {
        guard let id = selectedAnnotationID,
              let a = project.annotations.first(where: { $0.id == id }),
              a.type == .text || a.type == .callout else { return nil }
        return (a.fontName, a.fontWeight)
    }

    private func addAnnotation(type: AnnotationType, atSource requestedStart: TimeInterval? = nil) {
        let start = max(0, min(requestedStart ?? currentTime, max(0, project.duration - 0.5)))
        let defaultDuration: TimeInterval = type == .drawing ? 10 : 3
        let end = max(start + 0.5, min(project.duration, start + defaultDuration))
        var annotation = Annotation(type: type, startTime: start, endTime: end)

        switch type {
        case .text:
            annotation.text = "Label"
        case .arrow:
            annotation.x = 0.35; annotation.y = 0.45
            annotation.arrowEndX = 0.55; annotation.arrowEndY = 0.55
        case .rectangle, .ellipse:
            annotation.x = 0.35; annotation.y = 0.375
            annotation.arrowEndX = 0.65; annotation.arrowEndY = 0.625
            annotation.color = CodableColor(NSColor.white)
            annotation.backgroundColor = CodableColor(red: 1, green: 1, blue: 1, opacity: 0.25)
            annotation.showBackground = false
            annotation.lineWidth = 4
        case .tap:
            annotation.x = 0.5; annotation.y = 0.5
            annotation.fontSize = 60 // reused as ripple size for taps
        case .callout:
            annotation.x = 0.4; annotation.y = 0.3
            annotation.arrowEndX = 0.55; annotation.arrowEndY = 0.5
            annotation.text = "Look here"
        case .drawing:
            // Ink fades. The default pop would SCALE the strokes about the
            // drawing's (never-moved) placement point — which is also why a
            // freshly-drawn stroke used to appear far from the pen on the
            // mid-build frames.
            annotation.enterEffect = .fade
            annotation.exitEffect = .fade
        }

        // The pill's swatch color, when one was picked, wins over the
        // per-type defaults above — it is the user's explicit "draw in this".
        if let chosen = toolbarAnnotationColor {
            annotation.color = CodableColor(chosen)
        }

        project.annotations.append(annotation)
        selectedAnnotationID = annotation.id

        undoManager?.registerUndo(withTarget: project) { p in
            p.annotations.removeAll { $0.id == annotation.id }
        }
        undoManager?.setActionName("Add \(Self.annotationLaneLabel(for: annotation))")
    }

    // (The per-type add helpers went with the popover; the pill calls
    // addAnnotationFromToolbar directly.)

    private func deleteHighlightRegion(id: UUID) {
        guard let index = project.highlightRegions.firstIndex(where: { $0.id == id }) else { return }
        let region = project.highlightRegions[index]
        project.highlightRegions.remove(at: index)
        if selectedHighlightID == id { selectedHighlightID = nil }

        undoManager?.registerUndo(withTarget: project) { project in
            let insertIndex = min(index, project.highlightRegions.count)
            project.highlightRegions.insert(region, at: insertIndex)
        }
        undoManager?.setActionName("Delete Highlight")
    }

    // MARK: - Speed regions

    private func addSpeedRegion(at time: TimeInterval, speed: Double) {
        let desiredStart = max(0, min(time, project.duration))
        let desiredEnd = min(desiredStart + 3, project.duration)
        addSpeedRegion(start: desiredStart, end: desiredEnd, speed: speed)
    }

    /// Adds a speed region covering a full source-time range — used when the
    /// user picks a speed for a segment of the yellow clip. No hard-coded 3s.
    private func addSpeedRegion(start rawStart: TimeInterval, end rawEnd: TimeInterval, speed: Double) {
        let desiredStart = max(0, min(rawStart, project.duration))
        let desiredEnd = max(desiredStart + 0.1, min(rawEnd, project.duration))
        let (start, end) = findNonOverlappingSlot(
            desired: (desiredStart, desiredEnd),
            existing: project.speedRegions.map { ($0.startTime, $0.endTime) },
            duration: project.duration
        )
        guard start < end else { NSSound.beep(); return } // lane full

        let region = VideoSpeedRegion(startTime: start, endTime: end, speed: speed)
        project.speedRegions.append(region)
        selectedSpeedID = region.id

        undoManager?.registerUndo(withTarget: project) { project in
            project.speedRegions.removeAll { $0.id == region.id }
        }
        undoManager?.setActionName("Add Speed")
    }

    private func changeSpeedRegion(id: UUID, speed: Double) {
        guard let idx = project.speedRegions.firstIndex(where: { $0.id == id }) else { return }
        let previous = project.speedRegions[idx].speed
        project.speedRegions[idx].speed = speed
        undoManager?.registerUndo(withTarget: project) { p in
            if let i = p.speedRegions.firstIndex(where: { $0.id == id }) {
                p.speedRegions[i].speed = previous
            }
        }
        undoManager?.setActionName("Change Speed")
    }

    private func deleteSpeedRegion(id: UUID) {
        guard let index = project.speedRegions.firstIndex(where: { $0.id == id }) else { return }
        let region = project.speedRegions[index]
        project.speedRegions.remove(at: index)
        if selectedSpeedID == id { selectedSpeedID = nil }

        undoManager?.registerUndo(withTarget: project) { project in
            let insertIndex = min(index, project.speedRegions.count)
            project.speedRegions.insert(region, at: insertIndex)
        }
        undoManager?.setActionName("Delete Speed")
    }

    /// Find a non-overlapping time slot near the desired range.
    /// If the desired range overlaps, try placing it right after the overlapping region.
    /// Every span occupied on the EFFECTS lane, in SOURCE time.
    ///
    /// A linked block contributes its zoom and tilt spans, which are identical
    /// by construction, so the duplication is harmless for overlap tests; a
    /// zoom-only or tilt-only block contributes its own single span. Blocks on
    /// this lane may never overlap each other, exactly like the FOCUS lane.
    private var effectLaneSpans: [(Double, Double)] {
        project.zoomRegions.map { ($0.startTime, $0.endTime) }
            + project.tiltRegions.map { ($0.startTime, $0.endTime) }
    }

    /// Gap-based placement: an add NEVER silently fails while any usable gap
    /// exists on the lane. The old shift-right-only search returned nothing
    /// whenever the playhead sat inside or after the existing blocks — the
    /// menu clicked, the timeline didn't change, no feedback.
    ///
    /// Prefers the gap containing the desired start, else the nearest gap
    /// (before or after), and shrinks the block to fit down to `minDuration`.
    /// Returns (0, 0) only when no gap of `minDuration` exists at all.
    private func findNonOverlappingSlot(
        desired: (Double, Double),
        existing: [(Double, Double)],
        duration: Double,
        minDuration: Double = 0.8
    ) -> (Double, Double) {
        let want = max(minDuration, desired.1 - desired.0)

        // Merge spans → free gaps in [0, duration].
        let spans = existing.sorted { $0.0 < $1.0 }
        var gaps: [(Double, Double)] = []
        var cursor = 0.0
        for span in spans {
            if span.0 - cursor >= minDuration { gaps.append((cursor, span.0)) }
            cursor = max(cursor, span.1)
        }
        if duration - cursor >= minDuration { gaps.append((cursor, duration)) }
        guard !gaps.isEmpty else { return (0, 0) }

        // The gap holding the desired start wins; else the nearest gap.
        let gap = gaps.first { desired.0 >= $0.0 && desired.0 < $0.1 }
            ?? gaps.min {
                min(abs($0.0 - desired.0), abs($0.1 - desired.0))
                    < min(abs($1.0 - desired.0), abs($1.1 - desired.0))
            }!
        let length = min(want, gap.1 - gap.0)
        let start = min(max(desired.0, gap.0), gap.1 - length)
        return (start, start + length)
    }

    // MARK: - Duplicate (⌘D)

    /// Places a copy of `source` immediately after itself, sliding right past
    /// anything in `existing` that would overlap. Returns nil when there's no room.
    private func duplicateSlot(
        source: (start: TimeInterval, end: TimeInterval),
        existing: [(Double, Double)]
    ) -> (start: TimeInterval, end: TimeInterval)? {
        let length = max(0.1, source.end - source.start)
        let desiredStart = min(source.end, max(0, project.duration - length))
        let (start, end) = findNonOverlappingSlot(
            desired: (desiredStart, min(desiredStart + length, project.duration)),
            existing: existing,
            duration: project.duration
        )
        guard start < end else { return nil }
        return (start, end)
    }

    private func duplicateSelectedRegion() {
        // Duplicating a linked block yields a new linked pair.
        if let zoomID = selectedZoomID, let tiltID = selectedTiltID {
            _ = duplicateEffectPair(zoomID: zoomID, tiltID: tiltID)
            return
        }

        if let id = selectedZoomID, let source = project.zoomRegions.first(where: { $0.id == id }) {
            guard let slot = duplicateSlot(
                source: (source.startTime, source.endTime),
                existing: effectLaneSpans
            ) else { return }
            let copy = ZoomRegion(
                startTime: slot.start,
                endTime: slot.end,
                zoomLevel: source.zoomLevel,
                focalPoint: source.focalPoint
            )
            project.zoomRegions.append(copy)
            selectedZoomID = copy.id
            undoManager?.registerUndo(withTarget: project) { p in
                p.zoomRegions.removeAll { $0.id == copy.id }
            }
            undoManager?.setActionName("Duplicate Zoom")
            return
        }

        if let id = selectedTiltID, let source = project.tiltRegions.first(where: { $0.id == id }) {
            // One lane, so the copy must clear every other block on it.
            guard let slot = duplicateSlot(
                source: (source.startTime, source.endTime),
                existing: effectLaneSpans
            ) else { return }
            let copy = TiltRegion(
                startTime: slot.start,
                endTime: slot.end,
                pitch: source.pitch,
                yaw: source.yaw,
                roll: source.roll
            )
            project.tiltRegions.append(copy)
            selectedTiltID = copy.id
            undoManager?.registerUndo(withTarget: project) { p in
                p.tiltRegions.removeAll { $0.id == copy.id }
            }
            undoManager?.setActionName("Duplicate Tilt")
            return
        }

        if let id = selectedBlurID, let source = project.blurRegions.first(where: { $0.id == id }) {
            // Blur and highlight share the FOCUS track — avoid both.
            guard let slot = duplicateSlot(
                source: (source.startTime, source.endTime),
                existing: project.blurRegions.map { ($0.startTime, $0.endTime) }
                    + project.highlightRegions.map { ($0.startTime, $0.endTime) }
            ) else { return }
            let copy = BlurRegion(
                startTime: slot.start,
                endTime: slot.end,
                label: source.label,
                rect: source.rect,
                intensity: source.intensity
            )
            project.blurRegions.append(copy)
            selectedBlurID = copy.id
            undoManager?.registerUndo(withTarget: project) { p in
                p.blurRegions.removeAll { $0.id == copy.id }
            }
            undoManager?.setActionName("Duplicate Blur")
            return
        }

        if let id = selectedHighlightID, let source = project.highlightRegions.first(where: { $0.id == id }) {
            guard let slot = duplicateSlot(
                source: (source.startTime, source.endTime),
                existing: project.highlightRegions.map { ($0.startTime, $0.endTime) }
                    + project.blurRegions.map { ($0.startTime, $0.endTime) }
            ) else { return }
            let copy = HighlightRegion(
                startTime: slot.start,
                endTime: slot.end,
                label: source.label,
                rect: source.rect,
                opacity: source.opacity
            )
            project.highlightRegions.append(copy)
            selectedHighlightID = copy.id
            undoManager?.registerUndo(withTarget: project) { p in
                p.highlightRegions.removeAll { $0.id == copy.id }
            }
            undoManager?.setActionName("Duplicate Highlight")
            return
        }

        if let id = selectedSpeedID, let source = project.speedRegions.first(where: { $0.id == id }) {
            guard let slot = duplicateSlot(
                source: (source.startTime, source.endTime),
                existing: project.speedRegions.map { ($0.startTime, $0.endTime) }
            ) else { return }
            let copy = VideoSpeedRegion(startTime: slot.start, endTime: slot.end, speed: source.speed)
            project.speedRegions.append(copy)
            selectedSpeedID = copy.id
            undoManager?.registerUndo(withTarget: project) { p in
                p.speedRegions.removeAll { $0.id == copy.id }
            }
            undoManager?.setActionName("Duplicate Speed")
        }
    }

    @discardableResult
    private func deleteSelectedRegion() -> Bool {
        // The Slide chip lives in settings, not a region array — deleting it
        // turns the effect off (undo restores style, start and length).
        if selection.introSelected {
            deleteIntroSlide()
            return true
        }
        // The Curtain chip is settings too — deleting turns the effect off
        // (undo restores corner, start and length).
        if selection.curtainSelected {
            deleteCurtainUnveil()
            return true
        }
        // A linked EFFECTS block owns both halves — delete them together.
        if selectedZoomID != nil, selectedTiltID != nil {
            deleteEffectBlock(zoomID: selectedZoomID, tiltID: selectedTiltID)
            return true
        }
        if let id = selectedZoomID {
            deleteZoomRegion(id: id)
            return true
        }
        if let id = selectedBlurID {
            deleteBlurRegion(id: id)
            return true
        }
        if let id = selectedVoiceOverID {
            deleteVoiceOverClip(id: id)
            return true
        }
        if let id = selectedHighlightID {
            deleteHighlightRegion(id: id)
            return true
        }
        if let id = selectedDepthFocusID {
            deleteDepthFocusRegion(id: id)
            return true
        }
        if let id = selectedCameraLayoutID {
            deleteCameraLayoutRegion(id: id)
            return true
        }
        if let id = selectedSpeedID {
            deleteSpeedRegion(id: id)
            return true
        }
        if let id = selectedTiltID {
            deleteTiltRegion(id: id)
            return true
        }
        if let id = selectedClipID {
            deleteVideoClip(id: id)
            return true
        }
        if let id = selectedAnnotationID {
            deleteAnnotation(id: id)
            return true
        }
        return false
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
