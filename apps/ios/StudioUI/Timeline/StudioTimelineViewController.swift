import AVFoundation
import UIKit

/// The studio's touch timeline (docs/ios-studio-plan.md Phase 4c) — the
/// UIKit twin of the Mac's `TimelineViewController`: toolbar, track labels,
/// a horizontally scrolling `StudioTimelineCanvasView`, undo, and the asset
/// loaders (filmstrip, waveforms).
///
/// Every edit is the shared core's: this controller is a `TimelineHosting`
/// host, so the lanes' gestures route through the shared callback tables
/// (`timelineCanvasCallbacks` …) into the `TimelineEditing` operations, and
/// selection follows the shared exclusivity rules — an iOS edit writes the
/// Mac's values, registers the Mac's undo, names the Mac's action. Proven by
/// StudioLab `--timeline-edits` against the Mac's frozen transcript.
///
/// Standalone and embeddable: the editor shell (4b) hands in its project,
/// selection, playback and undo manager, and wires the outward hooks below.
@MainActor
final class StudioTimelineViewController: UIViewController {
    let project: Project
    let selection: EditorShellSelection
    let playback: StudioTimelinePlayback
    /// The editor's undo stack (the shell's, when embedded).
    let timelineUndoManager: UndoManager

    // MARK: Outward hooks (the shell wires these)

    /// A camera look was placed — start the person mask now.
    var onNeedsCameraMask: (() -> Void)?
    /// The mic key — nil hides it (voice-over lands in 4e).
    var onToggleVoiceOverRecording: (() -> Void)? { didSet { voiceButton?.isHidden = onToggleVoiceOverRecording == nil } }
    /// A fresh text/callout wants the in-place label editor.
    var onBeginInlineEdit: ((UUID) -> Void)?
    /// Arms the preview's drag-to-draw for a blur; nil = add at the playhead.
    var onArmBlurDraw: ((BlurStyle) -> Void)?
    /// The panel's height changed (EFFECTS sub-rows) — re-lay the stage.
    var onPreferredHeightChange: ((CGFloat) -> Void)?

    // MARK: Shims onto shared state (the Mac controller's, verbatim)

    var currentTime: TimeInterval {
        get { playback.currentTime }
        set { playback.currentTime = newValue }
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
    var selectedBlurID: UUID? {
        get { selection.selectedBlurID }
        set { selection.selectedBlurID = newValue; applySelectionExclusivity(.blur, newValue) }
    }
    var selectedCameraLayoutID: UUID? {
        didSet { applySelectionExclusivity(.cameraLayout, selectedCameraLayoutID); rebuildCanvas() }
    }
    var selectedVoiceOverID: UUID? {
        didSet { applySelectionExclusivity(.voiceOver, selectedVoiceOverID); rebuildCanvas(); refreshToolbar() }
    }
    var selectedSpeedID: UUID? {
        didSet { applySelectionExclusivity(.speed, selectedSpeedID); rebuildCanvas(); refreshToolbar() }
    }
    var selectedClipID: UUID? {
        didSet { applySelectionExclusivity(.clip, selectedClipID); rebuildCanvas(); refreshToolbar() }
    }
    /// The floating pill's swatch colour (TimelineEditing).
    var toolbarAnnotationColor: PlatformColor?

    override var undoManager: UndoManager? { timelineUndoManager }

    // MARK: Owned state

    private(set) var sliceMode = false { didSet { rebuildCanvas(); refreshToolbar() } }
    private var audioSamples: [Float] = [] { didSet { rebuildCanvas() } }
    private var thumbnails: [TimelineThumbnail] = [] { didSet { rebuildCanvas() } }
    private var voiceWaveforms: [UUID: [Float]] = [:] { didSet { rebuildCanvas() } }
    private(set) var timelineScale: CGFloat = 1
    private var pinchBaseScale: CGFloat?
    private var visibleTrackWidth: CGFloat = 0
    private var effectsLaneRowCount = 1
    private var applyingExclusivity = false

    let minTimelineScale: CGFloat = 1
    let maxTimelineScale: CGFloat = 30

    // MARK: Views

    let canvas = StudioTimelineCanvasView()
    let scrollView = UIScrollView()
    private let toolbarScroll = UIScrollView()
    private let toolbar = UIStackView()
    private let canvasArea = UIView()
    private let labelColumn = UIView()
    private var labelViews: [String: UIView] = [:]
    private var labelHeights: [TimelineOverlayLane: NSLayoutConstraint] = [:]
    private var labelTops: [String: NSLayoutConstraint] = [:]
    private var canvasAreaHeight: NSLayoutConstraint?
    let blockPan = StudioTimelinePanGesture()
    let tapGesture = UITapGestureRecognizer()
    let longPressGesture = UILongPressGestureRecognizer()
    let pinchGesture = UIPinchGestureRecognizer()

    private var playButton: CCButton?
    private var undoButton: CCButton?
    private var redoButton: CCButton?
    private var deleteButton: CCButton?
    private var sliceButton: CCButton?
    private var voiceButton: CCButton?
    private var zoomOutButton: CCButton?
    private var zoomInButton: CCButton?
    private var fitButton: CCButton?
    private let timecodeCurrent = UILabel()
    private let timecodeTotal = UILabel()

    private var observation: SurfaceObservation?
    private var undoTokens: [NSObjectProtocol] = []
    private var thumbnailTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?
    private var voiceTask: Task<Void, Never>?
    private var lastVideoURL: URL??
    private var lastTrimSignature: String?
    private var lastVoiceSignature: String?
    private var lastCurrentTime: TimeInterval?
    /// Harness seam: the last house menu presented.
    private(set) weak var presentedMenu: CCActionSheetController?

    // MARK: Lifecycle

    init(
        project: Project,
        selection: EditorShellSelection,
        playback: StudioTimelinePlayback,
        undoManager: UndoManager? = nil
    ) {
        self.project = project
        self.selection = selection
        self.playback = playback
        self.timelineUndoManager = undoManager ?? UndoManager()
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        for token in undoTokens { NotificationCenter.default.removeObserver(token) }
    }

    /// Total panel height: toolbar + gap + lanes (sized for the tallest
    /// accordion state, so opening a lane never re-lays out the stage) + 8.
    var intrinsicPanelHeight: CGFloat {
        StudioTimelineStyle.toolbarHeight + StudioTimelineStyle.canvasTopInset + timelineCanvasHeight + 8
    }

    private var timelineCanvasHeight: CGFloat {
        TimelineLaneLayout.maxTracksBottom(effectsRows: effectsLaneRowCount, annotateRows: 1) + TimelineCanvasMetrics.bottomInset
    }

    override func loadView() {
        let root = UIView()
        root.backgroundColor = CCTheme.color.card
        root.layer.cornerRadius = CCTheme.radius(.lg)
        root.layer.cornerCurve = .continuous
        root.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        root.layer.borderWidth = 0.5
        root.layer.borderColor = CCTheme.color.border.resolvedColor(with: root.traitCollection).cgColor
        root.clipsToBounds = true
        view = root
        buildToolbar()
        buildCanvasArea()
        let hairline = UIView()
        hairline.backgroundColor = CCTheme.color.border
        for v in [toolbarScroll, canvasArea, hairline] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        let height = canvasArea.heightAnchor.constraint(equalToConstant: timelineCanvasHeight)
        canvasAreaHeight = height
        NSLayoutConstraint.activate([
            toolbarScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbarScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbarScroll.topAnchor.constraint(equalTo: root.topAnchor),
            toolbarScroll.heightAnchor.constraint(equalToConstant: StudioTimelineStyle.toolbarHeight),
            hairline.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            hairline.topAnchor.constraint(equalTo: toolbarScroll.bottomAnchor, constant: -1),
            hairline.heightAnchor.constraint(equalToConstant: 1),
            canvasArea.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: StudioTimelineStyle.sideInset),
            canvasArea.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -StudioTimelineStyle.sideInset),
            canvasArea.topAnchor.constraint(equalTo: toolbarScroll.bottomAnchor, constant: StudioTimelineStyle.canvasTopInset),
            height,
        ])
        root.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: UIView, _: UITraitCollection) in
            view.layer.borderColor = CCTheme.color.border.resolvedColor(with: view.traitCollection).cgColor
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        startObserving()
        installUndoObservers()
        refreshToolbar()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The canvas area is the root's direct child, so its frame is final
        // here; the scroll view inside it lays out later in the pass.
        let width = max(0, canvasArea.frame.width - StudioTimelineStyle.labelWidth)
        guard width != visibleTrackWidth else { return }
        visibleTrackWidth = width
        layoutCanvasDocument()
        // The scrub/seek closures bake the track width in by value.
        rebuildCanvas()
    }

    /// Breaks the controller ⇄ canvas cycle (the callback tables capture self).
    func tearDown() {
        observation?.cancel()
        observation = nil
        thumbnailTask?.cancel(); audioTask?.cancel(); voiceTask?.cancel()
        canvas.releaseCallbacks()
        canvas.laneAccordion.invalidate()
        for token in undoTokens { NotificationCenter.default.removeObserver(token) }
        undoTokens.removeAll()
    }

    // MARK: - Layout

    private var scaledTrackWidth: CGFloat { max(visibleTrackWidth, visibleTrackWidth * timelineScale) }

    private func layoutCanvasDocument() {
        let width = scaledTrackWidth
        let height = max(timelineCanvasHeight,
                         TimelineLaneLayout.maxTracksBottom(effectsRows: effectsLaneRowCount, annotateRows: canvas.annotateRowCount)
                            + TimelineCanvasMetrics.bottomInset)
        if canvas.frame.size != CGSize(width: width, height: height) {
            canvas.frame = CGRect(x: 0, y: 0, width: width, height: height)
            scrollView.contentSize = canvas.frame.size
            canvas.setNeedsDisplay()
        }
    }

    private func buildCanvasArea() {
        labelColumn.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        canvasArea.addSubview(labelColumn)
        canvasArea.addSubview(scrollView)
        NSLayoutConstraint.activate([
            labelColumn.leadingAnchor.constraint(equalTo: canvasArea.leadingAnchor),
            labelColumn.topAnchor.constraint(equalTo: canvasArea.topAnchor),
            labelColumn.bottomAnchor.constraint(equalTo: canvasArea.bottomAnchor),
            labelColumn.widthAnchor.constraint(equalToConstant: StudioTimelineStyle.labelWidth),
            scrollView.leadingAnchor.constraint(equalTo: labelColumn.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: canvasArea.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: canvasArea.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: canvasArea.bottomAnchor),
        ])
        let M = TimelineCanvasMetrics.self
        let lanes: [(String, CGFloat, TimelineOverlayLane?)] = [
            ("VIDEO", M.videoLaneY, nil), ("VOICE", M.voiceLaneY, nil),
            ("EFFECTS", M.effectsLaneY, .effects), ("FOCUS", M.focusLaneY, .focus), ("ANNOTATE", M.annotateLaneY, .annotate),
        ]
        for (name, y, lane) in lanes {
            let row = UIView()
            row.translatesAutoresizingMaskIntoConstraints = false
            let label = UILabel()
            // Dynamic Type: 10 pt grows to 13 (what the 84 pt column and an
            // 18 pt closed strip hold), re-set on every size change.
            func setLaneTitle(_ label: UILabel) {
                label.attributedText = NSAttributedString(string: name, attributes: [
                    .font: UIFontMetrics(forTextStyle: .caption2).scaledFont(
                        for: .systemFont(ofSize: 10, weight: CCFont.legible(.semibold)), maximumPointSize: 13,
                        compatibleWith: label.traitCollection),
                    .foregroundColor: CCTheme.color.faintForeground, .kern: 0.6,
                ])
            }
            setLaneTitle(label)
            label.registerForTraitChanges([UITraitPreferredContentSizeCategory.self, CCAccessibilityTrait.self]) { (label: UILabel, _: UITraitCollection) in
                setLaneTitle(label)
            }
            label.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(label)
            labelColumn.addSubview(row)
            let top = row.topAnchor.constraint(equalTo: labelColumn.topAnchor, constant: y)
            let height = row.heightAnchor.constraint(equalToConstant: M.trackHeight)
            labelTops[name] = top
            if let lane {
                labelHeights[lane] = height
                row.isUserInteractionEnabled = true
                row.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(laneLabelTapped(_:))))
                row.tag = lane.rawValue + 1
            }
            labelViews[name] = row
            // VoiceOver: each lane label reads as its lane; an overlay lane's
            // label is the key that opens or closes it.
            row.isAccessibilityElement = true
            row.accessibilityLabel = name.capitalized + " lane"
            row.accessibilityTraits = lane == nil ? .header : .button
            if let lane {
                // Its height IS the lane's (an 18 pt strip while closed): the
                // a11y gate takes the toggle as a custom action instead.
                row.accessibilityIdentifier = CCAccessibility.dataGeometryPrefix + "lane"
                row.accessibilityHint = "Opens or closes the lane."
                row.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Open or close lane") { [weak self] _ in
                    self?.performLaneLabelTap(lane)
                    return true
                }]
            }
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: labelColumn.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: labelColumn.trailingAnchor),
                top, height,
                label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
                label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            ])
        }

        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.delaysContentTouches = false
        scrollView.addSubview(canvas)
        canvas.onLaneLayoutChange = { [weak self] layout in self?.applyLaneLabelLayout(layout) }
        canvas.laneAccordion.reducedMotionHost = canvasArea
        canvas.accessibilityController = self

        // Gestures: a drag that starts on a block / clip / chip / the ruler is
        // the timeline's (the scroll view waits for it to fail); anywhere else
        // the scroll view pans. Tap = click, long press = right-click.
        blockPan.maximumNumberOfTouches = 1
        blockPan.delegate = self
        blockPan.addTarget(self, action: #selector(handleBlockPan(_:)))
        canvas.addGestureRecognizer(blockPan)
        scrollView.panGestureRecognizer.require(toFail: blockPan)
        longPressGesture.minimumPressDuration = 0.45
        longPressGesture.addTarget(self, action: #selector(handleLongPress(_:)))
        canvas.addGestureRecognizer(longPressGesture)
        tapGesture.addTarget(self, action: #selector(handleTap(_:)))
        tapGesture.require(toFail: longPressGesture)
        canvas.addGestureRecognizer(tapGesture)
        pinchGesture.addTarget(self, action: #selector(handlePinch(_:)))
        scrollView.addGestureRecognizer(pinchGesture)
    }

    /// Lane accordion frame: each overlay label row takes its lane's current
    /// height and top, and a closed lane's label recedes a little with it.
    private func applyLaneLabelLayout(_ layout: TimelineLaneLayout) {
        let names: [TimelineOverlayLane: String] = [.effects: "EFFECTS", .focus: "FOCUS", .annotate: "ANNOTATE"]
        for lane in TimelineOverlayLane.allCases {
            guard let name = names[lane] else { continue }
            labelHeights[lane]?.constant = layout.laneHeight(lane)
            labelTops[name]?.constant = layout.laneY(lane)
            labelViews[name]?.alpha = 0.7 + 0.3 * min(1, max(0, layout.openness(lane)))
            labelViews[name]?.accessibilityValue = canvas.openOverlayLane == lane ? "Open" : "Closed"
        }
    }

    @objc private func laneLabelTapped(_ gesture: UITapGestureRecognizer) {
        guard let tag = gesture.view?.tag, let lane = TimelineOverlayLane(rawValue: tag - 1) else { return }
        performLaneLabelTap(lane)
    }

    /// A tap on an overlay lane's label toggles that lane open / shut.
    func performLaneLabelTap(_ lane: TimelineOverlayLane) {
        canvas.setOpenLane(canvas.openOverlayLane == lane ? nil : lane, animated: true)
    }

    private func applyEffectsLaneRowCount(_ rowCount: Int) {
        let clamped = max(1, min(TimelineCanvasMetrics.maxEffectsRows, rowCount))
        guard clamped != effectsLaneRowCount else { return }
        effectsLaneRowCount = clamped
        canvasAreaHeight?.constant = timelineCanvasHeight
        layoutCanvasDocument()
        preferredContentSize = CGSize(width: preferredContentSize.width, height: intrinsicPanelHeight)
        onPreferredHeightChange?(intrinsicPanelHeight)
    }

    // MARK: - Toolbar

    private func key(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> CCButton {
        let button = CCButton(symbol: symbol, style: .ghost, size: .sm, onTap: action)
        button.accessibilityLabelOverride = label
        return button
    }

    /// A key whose action needs the key itself (a menu anchored to it).
    private func menuKey(_ symbol: String, _ label: String, _ action: @escaping (CCButton) -> Void) -> CCButton {
        let button = CCButton(symbol: symbol, style: .ghost, size: .sm)
        button.accessibilityLabelOverride = label
        button.onTap = { [weak button] in if let button { action(button) } }
        return button
    }

    private func setEnabled(_ button: CCButton?, _ enabled: Bool) {
        guard let button, button.isEnabled != enabled else { return }
        button.isEnabled = enabled
    }

    private func setSymbol(_ button: CCButton?, _ symbol: String) {
        guard let button, button.symbol != symbol else { return }
        button.symbol = symbol
    }

    private func separator() -> UIView {
        let line = CCDivider(vertical: true)
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return line
    }

    private func buildToolbar() {
        toolbar.axis = .horizontal
        toolbar.alignment = .center
        // 34 pt keys, 10 pt apart and 5 pt in from the ends: each 44 pt
        // target is its own and inside the bar (Studio 6a).
        toolbar.spacing = 10
        toolbar.isLayoutMarginsRelativeArrangement = true
        toolbar.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 5, bottom: 0, trailing: 5)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbarScroll.showsHorizontalScrollIndicator = false
        toolbarScroll.addSubview(toolbar)
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: toolbarScroll.contentLayoutGuide.leadingAnchor, constant: 5),
            toolbar.trailingAnchor.constraint(equalTo: toolbarScroll.contentLayoutGuide.trailingAnchor, constant: -5),
            toolbar.topAnchor.constraint(equalTo: toolbarScroll.contentLayoutGuide.topAnchor),
            toolbar.bottomAnchor.constraint(equalTo: toolbarScroll.contentLayoutGuide.bottomAnchor),
            toolbar.heightAnchor.constraint(equalTo: toolbarScroll.frameLayoutGuide.heightAnchor),
            toolbar.widthAnchor.constraint(greaterThanOrEqualTo: toolbarScroll.frameLayoutGuide.widthAnchor, constant: -10),
        ])
        let toStart = key("backward.end.fill", "Go to Start") { [weak self] in
            guard let self else { return }
            seekToSource(project.effectiveTrimStart)
        }
        let play = key("play.fill", "Play") { [weak self] in self?.togglePlayback() }
        playButton = play
        let toEnd = key("forward.end.fill", "Go to End") { [weak self] in
            guard let self else { return }
            seekToSource(max(project.effectiveTrimStart, project.effectiveTrimEnd - 0.01))
        }
        for v in [toStart, play, toEnd] { toolbar.addArrangedSubview(v) }
        toolbar.addArrangedSubview(separator())

        // Dynamic Type, capped to what the 44 pt bar holds.
        func timecodeFont(_ size: CGFloat, _ weight: UIFont.Weight, max: CGFloat) -> UIFont {
            UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .monospacedDigitSystemFont(ofSize: size, weight: CCFont.legible(weight)), maximumPointSize: max)
        }
        timecodeCurrent.font = timecodeFont(14, .semibold, max: 19)
        timecodeCurrent.adjustsFontForContentSizeCategory = true
        timecodeCurrent.textColor = CCTheme.color.foreground
        let divider = UILabel()
        divider.text = "/"
        divider.font = timecodeFont(12, .regular, max: 17)
        divider.adjustsFontForContentSizeCategory = true
        divider.textColor = CCTheme.color.faintForeground
        timecodeTotal.font = timecodeFont(12, .medium, max: 17)
        timecodeTotal.adjustsFontForContentSizeCategory = true
        timecodeTotal.textColor = CCTheme.color.mutedForeground
        let timecode = UIStackView(arrangedSubviews: [timecodeCurrent, divider, timecodeTotal])
        timecode.spacing = 4
        timecode.isLayoutMarginsRelativeArrangement = true
        timecode.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8)
        // VoiceOver: one element, the playhead time in words.
        timecode.isAccessibilityElement = true
        timecode.accessibilityLabel = "Playhead time"
        timecode.accessibilityTraits = .updatesFrequently
        toolbar.addArrangedSubview(timecode)
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        toolbar.addArrangedSubview(spacer)

        undoButton = key("arrow.uturn.backward", "Undo") { [weak self] in self?.timelineUndoManager.undo() }
        redoButton = key("arrow.uturn.forward", "Redo") { [weak self] in self?.timelineUndoManager.redo() }
        for v in [undoButton!, redoButton!] { toolbar.addArrangedSubview(v) }
        toolbar.addArrangedSubview(separator())
        deleteButton = key("trash", "Delete Selected") { [weak self] in _ = self?.deleteSelectedRegion() }
        // ⌘D's touch twin (the Mac duplicates from the keyboard only).
        duplicateButton = key("clipboard", "Duplicate") { [weak self] in self?.duplicateSelectedRegion() }
        toolbar.addArrangedSubview(deleteButton!)
        toolbar.addArrangedSubview(duplicateButton!)
        toolbar.addArrangedSubview(separator())
        let effects = menuKey("sparkles", "Effects") { [weak self] in self?.showEffectsMenu(from: $0) }
        let focus = menuKey("scope", "Focus & Blur") { [weak self] in self?.showFocusMenu(from: $0) }
        sliceButton = key("scissors", "Slice") { [weak self] in self?.sliceMode.toggle() }
        let split = key("rectangle.split.2x1", "Split at Playhead") { [weak self] in self?.splitAtPlayhead() }
        let annotate = menuKey("pencil.tip", "Add Annotation") { [weak self] in self?.showAnnotationMenu(from: $0) }
        effectsButton = effects
        focusButton = focus
        annotateButton = annotate
        for v in [effects, focus, sliceButton!, split, annotate] { toolbar.addArrangedSubview(v) }
        toolbar.addArrangedSubview(separator())
        voiceButton = key("mic.fill", "Record Voice Over") { [weak self] in self?.onToggleVoiceOverRecording?() }
        voiceButton?.isHidden = onToggleVoiceOverRecording == nil
        toolbar.addArrangedSubview(voiceButton!)
        zoomOutButton = key("minus.magnifyingglass", "Zoom Out Timeline") { [weak self] in
            guard let self else { return }
            setTimelineScale(timelineScale / 1.5)
        }
        zoomInButton = key("plus.magnifyingglass", "Zoom In Timeline") { [weak self] in
            guard let self else { return }
            setTimelineScale(timelineScale * 1.5)
        }
        fitButton = key("arrow.down.right.and.arrow.up.left", "Fit Timeline") { [weak self] in self?.setTimelineScale(1) }
        for v in [zoomOutButton!, zoomInButton!, fitButton!] { toolbar.addArrangedSubview(v) }
    }

    private var duplicateButton: CCButton?
    private var effectsButton: CCButton?
    private var focusButton: CCButton?
    private var annotateButton: CCButton?

    private func refreshToolbar() {
        guard isViewLoaded else { return }
        setSymbol(playButton, playback.isPlaying ? "pause.fill" : "play.fill")
        setEnabled(playButton, playback.canPlay)
        setSymbol(voiceButton, playback.isRecordingVoiceOver ? "stop.fill" : "mic.fill")
        let hidesTime = project.hidesTimelinePlayhead
        timecodeCurrent.isHidden = hidesTime
        timecodeTotal.isHidden = hidesTime
        timecodeCurrent.text = visibleCurrentTime.formattedTimecode
        timecodeTotal.text = visibleDuration.formattedTimecode
        timecodeCurrent.superview?.accessibilityValue = "\(CCAccessibility.spokenTime(visibleCurrentTime)) of \(CCAccessibility.spokenTime(visibleDuration))"
        setEnabled(deleteButton, hasDeletableSelection)
        // What `duplicateSelectedRegion` can copy: EFFECTS blocks, blur,
        // highlight and speed regions.
        setEnabled(duplicateButton, selectedZoomID != nil || selectedTiltID != nil || selectedBlurID != nil
                   || selectedHighlightID != nil || selectedSpeedID != nil)
        let timeless = project.presentsTimelessTimeline
        setEnabled(zoomOutButton, !timeless && timelineScale > minTimelineScale)
        setEnabled(zoomInButton, !timeless && timelineScale < maxTimelineScale)
        setEnabled(fitButton, !timeless && timelineScale > minTimelineScale)
        // The armed slice tool reads as a pressed (filled) key.
        if let sliceButton, (sliceButton.style == .secondary) != sliceMode {
            sliceButton.style = sliceMode ? .secondary : .ghost
        }
        setEnabled(undoButton, timelineUndoManager.canUndo)
        setEnabled(redoButton, timelineUndoManager.canRedo)
    }

    // MARK: - Menus (house sheets, never system menus)

    private func present(_ sheet: CCActionSheet, from source: UIView?) {
        sheet.present(from: self, source: source)
        DispatchQueue.main.async { [weak self] in
            self?.presentedMenu = CCAlert.topmost(from: self ?? UIViewController()) as? CCActionSheetController
        }
    }

    private func addForInlineEditing(_ type: AnnotationType) {
        addAnnotation(type: type)
        if let id = selectedAnnotationID, type == .text || type == .callout { onBeginInlineEdit?(id) }
    }

    func showAnnotationMenu(from source: UIView?) {
        let sheet = CCActionSheet(title: "Add Annotation")
        sheet.addAction("Text Label", symbol: "text.bubble") { [weak self] in self?.addForInlineEditing(.text) }
        sheet.addAction("Arrow", symbol: "arrow.up.right") { [weak self] in self?.addAnnotation(type: .arrow) }
        sheet.addAction("Callout", symbol: "pencil.tip") { [weak self] in self?.addForInlineEditing(.callout) }
        sheet.addAction("Drawing", symbol: "pencil.and.scribble") { [weak self] in self?.addAnnotation(type: .drawing) }
        sheet.addAction("Rectangle", symbol: "rectangle") { [weak self] in self?.addAnnotation(type: .rectangle) }
        sheet.addAction("Ellipse", symbol: "oval") { [weak self] in self?.addAnnotation(type: .ellipse) }
        sheet.addAction("Tap Indicator", symbol: "hand.tap") { [weak self] in self?.addAnnotation(type: .tap) }
        present(sheet, from: source)
    }

    func showEffectsMenu(from source: UIView?) {
        let sheet = CCActionSheet(title: "Effects")
        if project.isImageCapture {
            sheet.addAction("Motion", symbol: "wand.and.stars") { [weak self] in self?.runStillMotion() }
        }
        if project.cursorDataURL != nil {
            sheet.addAction("Auto Zoom", symbol: "sparkle.magnifyingglass") { [weak self] in self?.autoZoom() }
        }
        sheet.addAction("Zoom In", symbol: "plus.magnifyingglass") { [weak self] in self?.addZoomRegion() }
        sheet.addAction("Showcase", symbol: "sparkles.rectangle.stack") { [weak self] in self?.addShowcaseBlock() }
        sheet.addAction("Scale Down", symbol: "arrow.down.right.and.arrow.up.left") { [weak self] in self?.addScaleDownBlock() }
        sheet.addAction("Tilt", symbol: "rotate.3d") { [weak self] in self?.addTiltRegion() }
        sheet.addAction("Slide", symbol: "arrow.up.to.line") { [weak self] in self?.enableIntroSlide() }
        sheet.addAction("Curtain Unveil", symbol: "book.pages") { [weak self] in self?.enableCurtainUnveil() }
        if project.cameraVideoURL != nil {
            sheet.addAction("Camera Full Screen", symbol: "person.crop.rectangle") { [weak self] in
                self?.addCameraLayoutRegion(mode: .cameraOnly)
            }
            sheet.addAction("Side by Side", symbol: "rectangle.split.2x1") { [weak self] in
                self?.addCameraLayoutRegion(mode: .sideBySide)
            }
            sheet.addAction("Side by Side, Camera Left", symbol: "rectangle.split.2x1") { [weak self] in
                self?.addCameraLayoutRegion(mode: .sideBySide, side: .leading)
            }
            sheet.addAction(CameraSplitStyle.full.displayName, symbol: "rectangle.split.2x1.fill") { [weak self] in
                self?.addCameraLayoutRegion(mode: .sideBySide, split: .full)
            }
            sheet.addAction(CameraBubbleLook.cutout.displayName, symbol: "person.fill") { [weak self] in
                self?.addCameraLayoutRegion(mode: .bubble, look: .cutout)
            }
            sheet.addAction(CameraBubbleLook.popOut.displayName, symbol: "person.crop.square") { [weak self] in
                self?.addCameraLayoutRegion(mode: .bubble, look: .popOut)
            }
            sheet.addAction("Hide Camera", symbol: "person.crop.rectangle.badge.xmark") { [weak self] in
                self?.addCameraLayoutRegion(mode: .screenOnly)
            }
        }
        present(sheet, from: source)
    }

    func showFocusMenu(from source: UIView?) {
        let sheet = CCActionSheet(title: "Focus & Blur")
        sheet.addAction("Add Blur", symbol: "eye.slash") { [weak self] in
            guard let self else { return }
            if let arm = onArmBlurDraw { arm(.blur) } else { addBlurRegion() }
        }
        sheet.addAction("Add Pixelate", symbol: "squareshape.split.3x3") { [weak self] in
            guard let self else { return }
            if let arm = onArmBlurDraw { arm(.pixelate) } else { addBlurRegion() }
        }
        sheet.addAction("Add Highlight", symbol: "highlighter") { [weak self] in self?.addHighlightRegion() }
        sheet.addAction("Add Depth Focus", symbol: "camera.aperture") { [weak self] in self?.addDepthFocusRegion() }
        present(sheet, from: source)
    }

    /// The long-press menu for a canvas point (anchored there on iPad).
    func showContextMenu(at point: CGPoint) {
        let hit = canvas.hit(at: point)
        let anchor = UIView(frame: CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2))
        anchor.isUserInteractionEnabled = false
        canvas.addSubview(anchor)
        let present: (CCActionSheet) -> Void = { [weak self, weak anchor] sheet in
            self?.present(sheet, from: anchor)
        }
        guard let sheet = StudioTimelineMenus.sheet(for: hit, canvas: canvas, present: present) else {
            anchor.removeFromSuperview()
            return
        }
        present(sheet)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { anchor.removeFromSuperview() }
    }

    // MARK: - Gestures

    // Each recognizer forwards to one `perform…` entry point; the
    // `--timeline-edits` gate drives the same entry points with the same
    // canvas points, so it exercises exactly what a finger does.

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        performTap(at: gesture.location(in: canvas))
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        performLongPress(at: gesture.location(in: canvas))
    }

    @objc private func handleBlockPan(_ gesture: StudioTimelinePanGesture) {
        let point = gesture.location(in: canvas)
        switch gesture.state {
        case .began: performDragBegan(at: gesture.initialLocation(in: canvas), current: point)
        case .changed: performDragMoved(to: point)
        case .ended: performDragEnded(at: point)
        case .cancelled, .failed: canvas.pressCancelled()
        default: break
        }
    }

    func performTap(at point: CGPoint) { canvas.tap(at: point) }

    func performLongPress(at point: CGPoint) {
        if canvas.isPressActive { canvas.pressCancelled() }
        canvas.noteTouch(at: point)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        showContextMenu(at: point)
    }

    /// Whether a one-finger drag pressed at `point` is the timeline's
    /// (`gestureRecognizerShouldBegin`) — false = the scroll view pans.
    func dragBelongsToTimeline(at point: CGPoint) -> Bool { canvas.ownsDrag(startingAt: point) }

    func performDragBegan(at start: CGPoint, current: CGPoint) {
        canvas.pressBegan(at: start)
        canvas.pressMoved(to: current)
    }

    func performDragMoved(to point: CGPoint) { canvas.pressMoved(to: point) }
    func performDragEnded(at point: CGPoint) { canvas.pressEnded(at: point) }

    /// Harness seam: a toolbar key by its accessibility label.
    func probeKey(_ label: String) -> CCButton? {
        toolbar.arrangedSubviews.compactMap { $0 as? CCButton }.first { $0.accessibilityLabelOverride == label }
    }

    /// Harness seam: the hardware-key command for `input` + `modifiers`.
    func probeKeyCommand(_ input: String, _ modifiers: UIKeyModifierFlags = []) -> UIKeyCommand? {
        keyCommands?.first { $0.input == input && $0.modifierFlags == modifiers }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard !project.presentsTimelessTimeline else { return }
        switch gesture.state {
        case .began:
            pinchBaseScale = timelineScale
        case .changed:
            setTimelineScale((pinchBaseScale ?? timelineScale) * gesture.scale)
        default:
            pinchBaseScale = nil
        }
    }

    // MARK: - Keyboard (iPad hardware keyboard)

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(title: "Duplicate", action: #selector(keyDuplicate), input: "d", modifierFlags: .command),
            UIKeyCommand(title: "Split at Playhead", action: #selector(keySplit), input: "b", modifierFlags: .command),
            UIKeyCommand(title: "Delete", action: #selector(keyDelete), input: "\u{8}"),
            UIKeyCommand(title: "Delete", action: #selector(keyDelete), input: UIKeyCommand.inputDelete),
            UIKeyCommand(title: "Undo", action: #selector(keyUndo), input: "z", modifierFlags: .command),
            UIKeyCommand(title: "Redo", action: #selector(keyRedo), input: "z", modifierFlags: [.command, .shift]),
            UIKeyCommand(title: "Play", action: #selector(keyPlay), input: " "),
            UIKeyCommand(title: "Back", action: #selector(keyLeft), input: UIKeyCommand.inputLeftArrow),
            UIKeyCommand(title: "Forward", action: #selector(keyRight), input: UIKeyCommand.inputRightArrow),
        ]
    }

    @objc private func keyDuplicate() { duplicateSelectedRegion() }
    @objc private func keySplit() { splitAtPlayhead() }
    @objc private func keyDelete() { _ = deleteSelectedRegion() }
    @objc private func keyUndo() { timelineUndoManager.undo() }
    @objc private func keyRedo() { timelineUndoManager.redo() }
    @objc private func keyPlay() { togglePlayback() }
    @objc private func keyLeft() { stepPlayhead(byOutput: -1.0 / 30.0) }
    @objc private func keyRight() { stepPlayhead(byOutput: 1.0 / 30.0) }

    // MARK: - Selection exclusivity

    /// The rules are the shared `clearSelections(exclusiveTo:)`; this is the
    /// Mac shim's guard (non-nil writes only, no re-entry).
    private func applySelectionExclusivity(_ lane: TimelineSelectionLane, _ value: UUID?) {
        guard value != nil, !applyingExclusivity else { return }
        applyingExclusivity = true
        defer { applyingExclusivity = false }
        timelineRequestFocus()
        clearSelections(exclusiveTo: lane)
    }

    // MARK: - Observation, undo, loaders

    private func startObserving() {
        observation?.cancel()
        observation = SurfaceObservation { [weak self] in
            guard let self else { return }
            _ = (playback.currentTime, playback.isPlaying, playback.isRecordingVoiceOver)
            _ = playback.liveVoiceOverSamples.count
            _ = (project.zoomRegions, project.tiltRegions, project.blurRegions)
            _ = (project.highlightRegions, project.focusRegions, project.cameraLayoutRegions)
            _ = (project.annotations, project.voiceOverClips, project.speedRegions)
            _ = (project.splitPoints, project.videoClipSegments)
            _ = (project.trimStart, project.trimEnd, project.duration)
            _ = (project.settings.introSlideStyle, project.settings.introSlideStart, project.settings.introSlideDuration)
            _ = (project.settings.curtainUnveilCorner, project.settings.curtainUnveilStart, project.settings.curtainUnveilDuration)
            _ = project.settings.muteRecordedAudio
            _ = (selection.selectedZoomID, selection.selectedTiltID, selection.selectedBlurID)
            _ = (selection.selectedHighlightID, selection.selectedAnnotationID, selection.selectedDepthFocusID)
            _ = (selection.introSelected, selection.curtainSelected)
            self.syncFromModel()
        }
    }

    private func syncFromModel() {
        if project.presentsTimelessTimeline, timelineScale != minTimelineScale { setTimelineScale(minTimelineScale) }
        refreshToolbar()
        rebuildCanvas()
        restartLoadersIfNeeded()
        if lastCurrentTime != playback.currentTime {
            lastCurrentTime = playback.currentTime
            followPlayheadIfNeeded()
        }
    }

    /// Re-derive every snapshot and push it into the canvas in one call.
    func rebuildCanvas() {
        guard isViewLoaded else { return }
        let snapshot = timelineCanvasSnapshot(sliceArmed: sliceMode)
        applyEffectsLaneRowCount(TimelineLaneMath.effectsRowCount(snapshot: snapshot))
        canvas.apply(
            snapshot: snapshot,
            callbacks: timelineCanvasCallbacks(trackWidth: scaledTrackWidth),
            videoModel: timelineVideoRowModel(hasAudio: !audioSamples.isEmpty, hasThumbnails: !thumbnails.isEmpty),
            videoAssets: TimelineVideoAssets(
                thumbnails: thumbnails, audioSamples: audioSamples, sourceSegments: project.sourceSegments,
                trimSourceStart: project.effectiveTrimStart, trimSourceEnd: project.effectiveTrimEnd),
            videoCallbacks: timelineVideoCallbacks(),
            voiceModel: timelineVoiceRowModel(
                isRecordingVoiceOver: playback.isRecordingVoiceOver,
                recordingStartTime: playback.voiceOverRecordingStartTime,
                liveSamples: playback.liveVoiceOverSamples),
            voiceAssets: TimelineVoiceAssets(waveforms: voiceWaveforms, signature: voiceWaveformSignature),
            voiceCallbacks: timelineVoiceCallbacks()
        )
        layoutCanvasDocument()
    }

    private func installUndoObservers() {
        guard undoTokens.isEmpty else { return }
        for name in [NSNotification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange,
                     .NSUndoManagerDidCloseUndoGroup] {
            let token = NotificationCenter.default.addObserver(forName: name, object: timelineUndoManager, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshToolbar() }
            }
            undoTokens.append(token)
        }
    }

    private var voiceWaveformSignature: String {
        project.voiceOverClips.map { "\($0.id.uuidString)|\(TimelineVoiceAssets.signature(for: $0))" }.joined(separator: ";")
    }

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

    private func loadThumbnails() async {
        guard let url = project.videoURL, FileManager.default.fileExists(atPath: url.path) else { thumbnails = []; return }
        thumbnails = await TimelineThumbnailer.generate(from: url, duration: project.duration, targetCount: 40)
    }

    /// The Mac's waveform: every audio track, 180 samples over the trim window, max-merged.
    private func loadAudioSamples() async {
        guard let url = project.videoURL, FileManager.default.fileExists(atPath: url.path) else { audioSamples = []; return }
        let sampleCount = 180
        let trimStart = project.effectiveTrimStart
        let trimDuration = max(0, project.effectiveTrimEnd - trimStart)
        let range: CMTimeRange? = trimDuration > 0
            ? CMTimeRange(start: CMTime(seconds: trimStart, preferredTimescale: 600),
                          duration: CMTime(seconds: trimDuration, preferredTimescale: 600))
            : nil
        let trackCount = await WaveformGenerator.audioTrackCount(for: url)
        guard trackCount > 0 else { audioSamples = []; return }
        var merged = Array(repeating: Float(0), count: sampleCount)
        for trackIndex in 0..<trackCount {
            let samples = await WaveformGenerator.generate(from: url, sampleCount: sampleCount, trackIndex: trackIndex, timeRange: range)
            for index in 0..<min(merged.count, samples.count) { merged[index] = max(merged[index], samples[index]) }
        }
        audioSamples = merged
    }

    private func loadVoiceWaveforms() async {
        var next: [UUID: [Float]] = [:]
        for clip in project.voiceOverClips {
            let url = clip.resolvedURL(in: project.projectDirectory)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let range = CMTimeRange(start: CMTime(seconds: clip.sourceStartTime, preferredTimescale: 600),
                                    duration: CMTime(seconds: max(0.1, clip.duration), preferredTimescale: 600))
            let samples = await WaveformGenerator.generate(from: url, sampleCount: 72, timeRange: range)
            if !samples.isEmpty { next[clip.id] = samples }
        }
        voiceWaveforms = next
    }

    // MARK: - Playback + zoom

    private func togglePlayback() {
        guard playback.canPlay else { return }
        playback.isPlaying.toggle()
    }

    private func seekToSource(_ sourceTime: TimeInterval) {
        playback.seek(to: sourceTime)
    }

    private func stepPlayhead(byOutput delta: TimeInterval) {
        playback.isPlaying = false
        let outputNow = fullTimeMap.outputTime(forSource: currentTime)
        let clamped = min(max(outputNow + delta, outputTrimStart), max(outputTrimStart, outputTrimEnd - 0.001))
        seekToSource(fullTimeMap.sourceTime(forOutput: clamped))
    }

    /// Change the timeline zoom keeping the playhead at the same on-screen
    /// position (the Mac's rule), resize, scroll — on the gesture's frame.
    func setTimelineScale(_ newScale: CGFloat) {
        let clamped = project.presentsTimelessTimeline ? minTimelineScale : min(maxTimelineScale, max(minTimelineScale, newScale))
        guard abs(clamped - timelineScale) > 0.0001 else { return }
        let oldWidth = scaledTrackWidth
        let fraction = outputDuration > 0 ? fullTimeMap.outputTime(forSource: currentTime) / outputDuration : 0
        let visible = scrollView.bounds
        let playheadScreenX = oldWidth * fraction - visible.minX
        timelineScale = clamped
        let newWidth = max(visibleTrackWidth, visibleTrackWidth * clamped)
        let anchorScreenX = min(max(playheadScreenX, 0), max(0, visible.width))
        let targetX = max(0, min(newWidth - visible.width, newWidth * fraction - anchorScreenX))
        layoutCanvasDocument()
        scrollView.contentOffset = CGPoint(x: targetX, y: scrollView.contentOffset.y)
        rebuildCanvas()
        refreshToolbar()
    }

    /// Keep the playhead in view while playing — page-jump when it leaves.
    private func followPlayheadIfNeeded() {
        let visible = scrollView.bounds
        guard playback.isPlaying, visible.width > 0, outputDuration > 0 else { return }
        let width = scaledTrackWidth
        guard width > visible.width + 1 else { return }
        let playheadX = width * (fullTimeMap.outputTime(forSource: currentTime) / outputDuration)
        if playheadX > visible.maxX - 24 || playheadX < visible.minX {
            scrollView.contentOffset.x = max(0, min(width - visible.width, playheadX - 24))
        }
    }
}

// MARK: - TimelineHosting

extension StudioTimelineViewController: TimelineHosting {
    func timelineEditRefused() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    func timelineEditNeedsCameraMask() { onNeedsCameraMask?() }

    func timelineRequestFocus() {
        guard isViewLoaded, view.window != nil, !isFirstResponder else { return }
        becomeFirstResponder()
    }

    func timelineScrub(toSource time: TimeInterval, exact: Bool) {
        playback.scrub(to: time, for: project, exact: exact)
    }

    func timelinePause() { playback.isPlaying = false }

    func timelineSeek(toSource time: TimeInterval) { seekToSource(time) }

    func timelineTogglePlayback() { togglePlayback() }

    func timelineSliceCommitted() { sliceMode = false }
}

// MARK: - Gesture plumbing

extension StudioTimelineViewController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === blockPan else { return true }
        return dragBelongsToTimeline(at: blockPan.initialLocation(in: canvas))
    }
}

/// A pan that remembers where the finger first touched, so a block drag is
/// measured from the press point (as the Mac measures from mouse-down) and
/// `gestureRecognizerShouldBegin` can hit-test the press, not the point the
/// finger had reached once the pan slop was crossed.
final class StudioTimelinePanGesture: UIPanGestureRecognizer {
    private var initialWindowPoint: CGPoint?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if initialWindowPoint == nil, let touch = touches.first {
            initialWindowPoint = touch.location(in: nil)
        }
        super.touchesBegan(touches, with: event)
    }

    override func reset() {
        super.reset()
        initialWindowPoint = nil
    }

    func initialLocation(in view: UIView) -> CGPoint {
        guard let point = initialWindowPoint else { return location(in: view) }
        return view.convert(point, from: nil)
    }
}
