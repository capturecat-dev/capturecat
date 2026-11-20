import AppKit

/// Layer-backed, flipped AppKit port of the timeline's track area. Draws the
/// ruler, EFFECTS and FOCUS lanes, separators and hints itself; the VIDEO and
/// VOICE rows stay as hosted SwiftUI so their clip/speed/trim/recording logic
/// is reused untouched; a transparent overlay above the hosts draws the
/// playhead and snap guide.
final class TimelineCanvasView: NSView {
    /// Hands keyboard focus to the panel root on click. See the Keyboard note.
    var onFocusRequested: (() -> Void)?

    /// Drops every stored callback closure. The owning controller calls this
    /// when its view disappears: the closures capture the controller strongly,
    /// so holding them here keeps it (and its Project) alive forever.
    func releaseCallbacks() {
        callbacks = nil
        videoCallbacks = TimelineVideoCallbacks()
        voiceCallbacks = TimelineVoiceCallbacks()
        onFocusRequested = nil
    }

    /// Clears the slice-tool hover state. `mouseMoved` can only clear it while
    /// the tool is armed, so disarming has to reach in.
    func clearSliceHoverState() {
        guard sliceHoverX != nil || sliceSnappedToPlayhead else { return }
        sliceHoverX = nil
        sliceSnappedToPlayhead = false
        needsDisplay = true
    }

    private typealias M = TimelineCanvasMetrics

    private(set) var snapshot = TimelineCanvasSnapshot(
        outputDuration: 0,
        playheadOutputTime: 0,
        playheadIsRed: false,
        playheadHitTestEnabled: true,
        scrubLabel: "",
        effectItems: [],
        selectedZoomID: nil,
        selectedTiltID: nil,
        focusItems: [],
        annotateItems: [],
        trimStartOutput: 0,
        trimEndOutput: 0,
        sliceArmed: false
    ) {
        didSet {
            committedEffectsRows = Self.effectsRowCount(snapshot: snapshot)
            committedAnnotateRows = annotateRowLayout.values.map(\.rows).max() ?? 1
        }
    }
    var callbacks: TimelineCanvasCallbacks?

    // MARK: Lane accordion

    /// Hover-to-open accordion over EFFECTS / FOCUS / ANNOTATE — see
    /// `TimelineLaneAccordion.swift`. Geometry below reads `laneLayout`.
    let laneAccordion = TimelineLaneAccordion()
    /// Every lane-geometry change (each animation frame, row-count changes)
    /// goes out here so the controller's label column moves in lockstep.
    var onLaneLayoutChange: ((TimelineLaneLayout) -> Void)? {
        didSet {
            reportedLaneLayout = nil
            reportLaneLayout()
        }
    }
    private var reportedLaneLayout: TimelineLaneLayout?
    /// Committed sub-row counts, cached from the snapshot (geometry reads them
    /// many times per draw).
    private var committedEffectsRows = 1
    private var committedAnnotateRows = 1
    /// The overlay lane under the cursor — the ONLY open lane (nil = all
    /// strips). Frozen while a gesture owns the mouse so a drag never
    /// collapses the lane it is editing.
    private var hoverOverlayLane: TimelineOverlayLane? {
        didSet { if hoverOverlayLane != oldValue { retargetLaneAccordion() } }
    }

    var laneLayout: TimelineLaneLayout {
        TimelineLaneLayout(
            openness: laneAccordion.openness,
            effectsRows: committedEffectsRows,
            annotateRows: committedAnnotateRows
        )
    }

    /// Committed ANNOTATE sub-row count — the controller sizes the scroll
    /// document from it.
    var annotateRowCount: Int { committedAnnotateRows }

    private func retargetLaneAccordion() {
        laneAccordion.setTarget(hoverOverlayLane, animated: window != nil)
    }

    private func laneAccordionDidChange() {
        // Only the overlay band moves — VIDEO / VOICE above it never redraw.
        setNeedsDisplay(CGRect(
            x: 0, y: M.effectsLaneY - M.trackSpacing,
            width: bounds.width, height: max(0, bounds.height - M.effectsLaneY + M.trackSpacing)))
        overlay.needsDisplay = true
        reportLaneLayout()
    }

    private func reportLaneLayout() {
        let layout = laneLayout
        guard layout != reportedLaneLayout else { return }
        reportedLaneLayout = layout
        onLaneLayoutChange?(layout)
    }

    /// Harness seam: the lane the accordion is opening (or holds open);
    /// nil = every lane a strip.
    var openOverlayLane: TimelineOverlayLane? { laneAccordion.target }
    /// Harness seam: hover lane + whether a gesture owns the mouse.
    var probeHoverState: String {
        let idle: Bool
        if case .idle = mouseState { idle = true } else { idle = false }
        return "hover=\(hoverOverlayLane.map { "\($0)" } ?? "nil") idle=\(idle)"
    }

    // MARK: Slice tool

    /// Cursor-follow x of the pending cut, nil when the cursor is off-lane or
    /// over a position too close to a clip edge to split.
    private var sliceHoverX: CGFloat? {
        didSet {
            guard sliceHoverX != oldValue else { return }
            setNeedsDisplay(videoLaneRect)
        }
    }
    /// Cut snapped onto the playhead — turns the playhead red, like SwiftUI.
    private var sliceSnappedToPlayhead = false {
        didSet {
            guard sliceSnappedToPlayhead != oldValue else { return }
            overlay.sliceSnapActive = sliceSnappedToPlayhead
        }
    }

    // MARK: VIDEO row (native)

    /// Non-nil when the VIDEO lane is drawn natively instead of hosted.
    var videoModel: TimelineVideoRowModel?
    var videoAssets = TimelineVideoAssets()
    var videoCallbacks: TimelineVideoCallbacks?
    /// Live VIDEO-lane gesture — its own machine so the generic block lanes
    /// stay untouched.
    var videoDrag: VideoRowDrag?
    /// A mouse-down landed on empty lane; deselect fires on mouse-up (the
    /// SwiftUI row deselects from an `.onTapGesture`).
    var videoPendingDeselect = false
    /// Row-level hover, which brightens the slab fill and the edge grips.
    var videoIsHovering = false {
        didSet {
            guard videoIsHovering != oldValue, videoModel != nil else { return }
            setNeedsDisplay(videoLaneRect)
        }
    }
    private var videoAssetsKey = ""

    // MARK: VOICE row (native)

    /// Non-nil when the VOICE lane is drawn natively instead of hosted.
    var voiceModel: TimelineVoiceRowModel?
    var voiceAssets = TimelineVoiceAssets()
    var voiceCallbacks: TimelineVoiceCallbacks?
    /// Live VOICE-lane gesture — its own machine, like `videoDrag`.
    var voiceDrag: VoiceRowDrag?
    /// Per-clip hover, which brightens the slab fill and the resize grips.
    var voiceHoveredClipID: UUID? {
        didSet {
            guard voiceHoveredClipID != oldValue, voiceModel != nil else { return }
            setNeedsDisplay(voiceLaneRect)
        }
    }
    private var voiceAssetsKey = ""

    private let overlay = TimelinePlayheadOverlayView()

    // MARK: Mouse state machine

    // Drag state + resolution are shared with the iOS timeline
    // (Studio/Editor/TimelineLaneMath.swift).
    private typealias DragMode = TimelineBlockDragMode

    /// Intro chip drags (outside the block state machine — the chip is
    /// settings, not a region). Move distinguishes click from drag by the
    /// usual threshold; a plain click opens the Motion pane.
    private var draggingIntroEdge = false
    private var introMove: (downX: CGFloat, initialStart: TimeInterval, didDrag: Bool)?
    private var draggingCurtainEdge = false
    private var curtainMove: (downX: CGFloat, initialStart: TimeInterval, didDrag: Bool)?
    private var curtainDragInitialSpan: (start: TimeInterval, end: TimeInterval)?
    /// Chip span captured at mouse-down: effect blocks the chip was ALREADY
    /// overlapping then (a joined Slide co-spans its block) stay exempt from
    /// the no-overlap clamp, mirroring the lane's legacy-grace rule.
    private var introDragInitialSpan: (start: TimeInterval, end: TimeInterval)?
    /// The chips' spans at the press of a Slide / Curtain drag — handed back
    /// on release so the live writes become one undo step.
    private var chipDragBefore: TimelineChipSpans?

    private typealias DragTarget = TimelineBlockDragTarget
    private typealias BlockDrag = TimelineBlockDrag

    private enum MouseState {
        case idle
        /// Empty-lane / ruler scrub; seek fires on mouseUp.
        case scrubbing
        case draggingBlock(BlockDrag)
        /// The native VIDEO lane owns the sequence (state lives in `videoDrag`).
        case video
        /// The native VOICE lane owns the sequence (state lives in `voiceDrag`).
        case voice
        /// Slice tool armed and pressed — the cut commits on mouse-up, which
        /// is where the SwiftUI `DragGesture(minimumDistance: 0).onEnded` fired.
        case slicing
    }

    private var mouseState: MouseState = .idle
    /// Time an edge is locked onto, drives the yellow guide in the overlay.
    private var snapGuideTime: TimeInterval? {
        didSet { if snapGuideTime != oldValue { overlay.snapGuideTime = snapGuideTime } }
    }

    private enum HoveredLane { case effects, focus, annotate }
    private var hoveredLane: HoveredLane? {
        didSet { if hoveredLane != oldValue { needsDisplay = true } }
    }
    private var hoveredBlockKey: String? {
        didSet { if hoveredBlockKey != oldValue { needsDisplay = true } }
    }
    private var appliedCursor: NSCursor?

    // MARK: Init

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        overlay.canvas = self
        addSubview(overlay)
        laneAccordion.onChange = { [weak self] in self?.laneAccordionDidChange() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func apply(
        snapshot: TimelineCanvasSnapshot,
        callbacks: TimelineCanvasCallbacks,
        videoModel: TimelineVideoRowModel? = nil,
        videoAssets: TimelineVideoAssets = TimelineVideoAssets(),
        videoCallbacks: TimelineVideoCallbacks = TimelineVideoCallbacks(),
        voiceModel: TimelineVoiceRowModel? = nil,
        voiceAssets: TimelineVoiceAssets = TimelineVoiceAssets(),
        voiceCallbacks: TimelineVoiceCallbacks = TimelineVoiceCallbacks()
    ) {
        self.callbacks = callbacks
        self.videoCallbacks = videoCallbacks
        self.voiceCallbacks = voiceCallbacks

        if videoModel != self.videoModel {
            self.videoModel = videoModel
            needsDisplay = true
        }
        let assetsKey = videoAssets.renderKey
        self.videoAssets = videoAssets
        if assetsKey != videoAssetsKey {
            videoAssetsKey = assetsKey
            needsDisplay = true
        }

        if voiceModel != self.voiceModel {
            self.voiceModel = voiceModel
            needsDisplay = true
        }
        let voiceKey = voiceAssets.renderKey
        self.voiceAssets = voiceAssets
        if voiceKey != voiceAssetsKey {
            voiceAssetsKey = voiceKey
            needsDisplay = true
        }

        if snapshot != self.snapshot {
            self.snapshot = snapshot
            overlay.snapshot = snapshot
            needsDisplay = true
            // New sub-rows change the label column's heights.
            reportLaneLayout()
        }
    }

    /// Harness entry point (`--videotrack-math-test --canvas`): configures the
    /// canvas for synthetic VIDEO-lane mouse sequences with no window, no
    /// SwiftUI host and no project — the gesture machine and the drawing code
    /// are exercised exactly as they run in the app.
    func configureForVideoRowHarness(
        width: CGFloat,
        outputDuration: TimeInterval,
        model: TimelineVideoRowModel,
        callbacks: TimelineVideoCallbacks,
        assets: TimelineVideoAssets = TimelineVideoAssets()
    ) {
        frame = CGRect(x: 0, y: 0, width: width, height: tracksBottom + M.bottomInset)
        snapshot.outputDuration = outputDuration
        snapshot.trimEndOutput = outputDuration
        videoModel = model
        videoAssets = assets
        videoCallbacks = callbacks
        videoDrag = nil
        videoPendingDeselect = false
    }

    /// Harness entry point (`--voicetrack-test`): configures the canvas for
    /// synthetic VOICE-lane mouse sequences with no window, no SwiftUI host and
    /// no project — the gesture machine and the drawing code are exercised
    /// exactly as they run in the app.
    func configureForVoiceRowHarness(
        width: CGFloat,
        outputDuration: TimeInterval,
        model: TimelineVoiceRowModel,
        callbacks: TimelineVoiceCallbacks,
        assets: TimelineVoiceAssets = TimelineVoiceAssets()
    ) {
        frame = CGRect(x: 0, y: 0, width: width, height: tracksBottom + M.bottomInset)
        snapshot.outputDuration = outputDuration
        snapshot.trimEndOutput = outputDuration
        voiceModel = model
        voiceAssets = assets
        voiceCallbacks = callbacks
        voiceDrag = nil
        voiceHoveredClipID = nil
    }

    override func layout() {
        super.layout()
        overlay.frame = bounds
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    // MARK: - Geometry helpers

    private var trackWidth: CGFloat { bounds.width }

    private func x(forOutputTime t: TimeInterval) -> CGFloat {
        guard snapshot.outputDuration > 0 else { return 0 }
        return trackWidth * CGFloat(t / snapshot.outputDuration)
    }

    private func outputTime(atX x: CGFloat) -> TimeInterval {
        guard trackWidth > 0, snapshot.outputDuration > 0 else { return 0 }
        let fraction = max(0, min(1, x / trackWidth))
        return fraction * snapshot.outputDuration
    }

    /// The full (multi-row) band of an overlay lane at its CURRENT animated
    /// height — hit tests, hover, hints.
    private func overlayLaneRect(_ lane: TimelineOverlayLane) -> CGRect {
        laneLayout.laneRect(lane, width: trackWidth)
    }

    private func blockWidth(start: TimeInterval, end: TimeInterval) -> CGFloat {
        guard snapshot.outputDuration > 0 else { return M.minBlockWidth }
        return max(M.minBlockWidth, trackWidth * CGFloat((end - start) / snapshot.outputDuration))
    }

    /// Committed (model) rect for a span in one sub-row of an overlay lane,
    /// at the lane's current animated row height.
    private func blockRect(
        start: TimeInterval, end: TimeInterval, lane: TimelineOverlayLane, row: Int = 0
    ) -> CGRect {
        let layout = laneLayout
        return CGRect(
            x: x(forOutputTime: start),
            y: layout.rowY(lane, row: row) + M.blockInset,
            width: blockWidth(start: start, end: end),
            height: max(2, layout.rowHeight(lane) - M.blockInset * 2)
        )
    }

    private func effectKey(_ item: EffectBlockItem) -> String {
        "e:\(item.zoomID?.uuidString ?? "-"):\(item.tiltID?.uuidString ?? "-")"
    }

    private func focusKey(_ item: TimelineFocusItem) -> String {
        "f:\(item.id.uuidString)"
    }

    private func annotateKey(_ item: TimelineAnnotateItem) -> String {
        "a:\(item.id.uuidString)"
    }

    /// Draw order: earlier-starting first, so later-starting annotations draw
    /// on top (overlaps are allowed on this lane).
    private var orderedAnnotateItems: [TimelineAnnotateItem] {
        TimelineLaneMath.orderedAnnotateItems(snapshot)
    }

    /// Sub-row layout for concurrent annotations (TimelineLaneMath).
    private var annotateRowLayout: [UUID: (row: Int, rows: Int)] {
        TimelineLaneMath.annotateRowLayout(snapshot)
    }

    /// Committed rect for an annotation — full lane height when alone,
    /// its sub-row slice when overlapping others.
    private func annotateRect(for item: TimelineAnnotateItem) -> CGRect {
        guard let slot = annotateRowLayout[item.id], slot.rows > 1 else {
            return blockRect(start: item.startTime, end: item.endTime, lane: .annotate)
        }
        // Full-height sub-rows — the lane band grows instead of the bars
        // shrinking (see `TimelineLaneLayout.rows`), and the timeline scrolls.
        return blockRect(start: item.startTime, end: item.endTime, lane: .annotate, row: slot.row)
    }

    private func isSelected(_ item: EffectBlockItem) -> Bool {
        if let zoomID = item.zoomID, snapshot.selectedZoomID == zoomID { return true }
        if let tiltID = item.tiltID, snapshot.selectedTiltID == tiltID { return true }
        return false
    }

    // MARK: - Snap / clamp resolution (byte-for-byte port of the block views)

    private func resolvedTimes(for drag: BlockDrag) -> (start: TimeInterval, end: TimeInterval) {
        TimelineLaneMath.resolvedTimes(for: drag, outputDuration: snapshot.outputDuration, trackWidth: trackWidth)
    }

    private func snapIndicator(for drag: BlockDrag) -> TimeInterval? {
        TimelineLaneMath.snapIndicator(for: drag, outputDuration: snapshot.outputDuration, trackWidth: trackWidth)
    }

    // MARK: - Per-item candidates / spans (TimelineLaneMath)

    private func introBlockers() -> [(TimeInterval, TimeInterval)] {
        TimelineLaneMath.introBlockers(initial: introDragInitialSpan, in: snapshot)
    }

    private func curtainBlockers() -> [(TimeInterval, TimeInterval)] {
        TimelineLaneMath.curtainBlockers(initial: curtainDragInitialSpan, in: snapshot)
    }

    // MARK: - Hit testing

    // MARK: - EFFECTS sub-rows

    /// EFFECTS sub-row assignment — shared (TimelineLaneMath); these
    /// forwards keep the canvas's static entry points for its callers.
    static func effectsRowAssignment(
        spans: [(key: String, start: TimeInterval, end: TimeInterval)]
    ) -> (rows: [String: Int], rowCount: Int) {
        TimelineLaneMath.effectsRowAssignment(spans: spans)
    }

    static func effectsSpans(
        snapshot: TimelineCanvasSnapshot
    ) -> [(key: String, start: TimeInterval, end: TimeInterval)] {
        TimelineLaneMath.effectsSpans(snapshot: snapshot)
    }

    static func effectsRowCount(snapshot: TimelineCanvasSnapshot) -> Int {
        TimelineLaneMath.effectsRowCount(snapshot: snapshot)
    }

    private func liveEffectsSpans() -> [(key: String, start: TimeInterval, end: TimeInterval)] {
        var drag: BlockDrag?
        if case .draggingBlock(let d) = mouseState { drag = d }
        return TimelineLaneMath.liveEffectsSpans(snapshot: snapshot, drag: drag, trackWidth: trackWidth)
    }

    private func effectsSpanKey(_ item: EffectBlockItem) -> String {
        TimelineLaneMath.effectsSpanKey(item)
    }

    /// Live row assignment, keyed by `effectsSpanKey` / "intro-chip" /
    /// "curtain-chip". Computed per call — item counts are tiny.
    private func effectsRows() -> [String: Int] {
        Self.effectsRowAssignment(spans: liveEffectsSpans()).rows
    }

    // Lane geometry — committed row counts key off the SNAPSHOT so nothing
    // jumps mid-drag (live rows are capped into them); heights and Ys come
    // from the accordion's CURRENT layout, so every lane below an opening
    // lane rides along frame by frame. ANNOTATE grows the same way EFFECTS
    // does: every stacked row keeps its block height and the canvas gets
    // taller (the timeline scroll view absorbs it).

    /// The full multi-row EFFECTS lane band (hit tests, hover, empty hint).
    private var effectsLaneRect: CGRect { overlayLaneRect(.effects) }
    private var focusLaneRect: CGRect { overlayLaneRect(.focus) }
    /// The full multi-row ANNOTATE band (hit tests, hover, empty hint).
    private var annotateLaneRect: CGRect { overlayLaneRect(.annotate) }
    /// Bottom of the last lane right now (mid-animation included).
    var tracksBottom: CGFloat { laneLayout.tracksBottom }

    private func effectItem(at point: CGPoint) -> EffectBlockItem? {
        guard effectsLaneRect.contains(point) else { return nil }
        let rows = effectsRows()
        // Later items draw on top (tilt-only last), so hit test in reverse.
        for item in snapshot.effectItems.reversed() {
            if blockRect(start: item.startTime, end: item.endTime,
                         lane: .effects, row: rows[effectsSpanKey(item)] ?? 0)
                .insetBy(dx: 0, dy: -M.blockInset)
                .contains(point) {
                return item
            }
        }
        return nil
    }

    private func focusItem(at point: CGPoint) -> TimelineFocusItem? {
        guard focusLaneRect.contains(point) else { return nil }
        // Highlights draw after blurs, so they hit-test first.
        let ordered = snapshot.focusItems.filter(\.isHighlight) + snapshot.focusItems.filter { !$0.isHighlight }
        for item in ordered {
            if blockRect(start: item.startTime, end: item.endTime, lane: .focus)
                .insetBy(dx: 0, dy: -M.blockInset)
                .contains(point) {
                return item
            }
        }
        return nil
    }

    private func annotateItem(at point: CGPoint) -> TimelineAnnotateItem? {
        guard annotateLaneRect.contains(point) else { return nil }
        // Later-starting items draw on top, so hit test them first. Sub-row
        // rects mean overlapping annotations each own their slice.
        for item in orderedAnnotateItems.reversed() {
            if annotateRect(for: item)
                .insetBy(dx: 0, dy: -1)
                .contains(point) {
                return item
            }
        }
        return nil
    }

    /// Which handle zone a down-point falls in, mirroring the SwiftUI blocks'
    /// clamped local-x test.
    private func dragMode(for point: CGPoint, blockStart: TimeInterval, blockEnd: TimeInterval) -> DragMode {
        let originX = x(forOutputTime: blockStart)
        let width = blockWidth(start: blockStart, end: blockEnd)
        return TimelineLaneMath.dragMode(localX: point.x - originX, blockWidth: width)
    }

    // MARK: - Keyboard
    //
    // The canvas deliberately does NOT take first responder. It used to grab it
    // on every click, which starved SwiftUI's .onKeyPress chain and forced it to
    // reimplement the editing keys here. `TimelineRootView` is now the single
    // responder for the whole panel, so clicking the canvas hands focus up.

    override var acceptsFirstResponder: Bool { false }

    // MARK: - Mouse events

    override func mouseDown(with event: NSEvent) {
        onFocusRequested?()
        let point = convert(event.locationInWindow, from: nil)
        guard snapshot.outputDuration > 0 else { return }

        // Slice tool owns the VIDEO lane while armed — the SwiftUI overlay
        // covered the row the same way, so no clip drag can start.
        if snapshot.sliceArmed, videoModel != nil, videoLaneRect.contains(point) {
            mouseState = .slicing
            return
        }

        if let model = videoModel, videoMouseDown(at: point, model: model) {
            mouseState = .video
            return
        }

        // Native VOICE lane: a clip press starts its drag machine, empty lane
        // deselects then scrubs — exactly what `trackBackground` did.
        if let model = voiceModel, voiceLaneRect.contains(point) {
            mouseState = voiceMouseDown(at: point, model: model) ? .voice : .scrubbing
            setCursor(.arrow)
            return
        }

        // Intro chip: pinned at 0:00 (it is the clip's entrance) — its right
        // edge drags to set the length; anywhere else opens the Motion pane.
        if let chipRect = introChipRect, effectItem(at: point) == nil,
           chipRect.insetBy(dx: -4, dy: 0).contains(point) {
            if abs(point.x - chipRect.maxX) <= 6 {
                draggingIntroEdge = true
                introDragInitialSpan = (snapshot.introChipStart, snapshot.introChipEnd ?? snapshot.introChipStart)
                chipDragBefore = callbacks?.chipSpans()
                return
            }
            if chipRect.contains(point) {
                introMove = (point.x, snapshot.introChipStart, false)
                introDragInitialSpan = (snapshot.introChipStart, snapshot.introChipEnd ?? snapshot.introChipStart)
                chipDragBefore = callbacks?.chipSpans()
                return
            }
        }

        // Curtain chip: same gestures as the Slide chip — right edge drags the
        // length, body drags the start, a click opens the Effects pane.
        if let chipRect = curtainChipRect, effectItem(at: point) == nil,
           chipRect.insetBy(dx: -4, dy: 0).contains(point) {
            if abs(point.x - chipRect.maxX) <= 6 {
                draggingCurtainEdge = true
                curtainDragInitialSpan = (snapshot.curtainChipStart, snapshot.curtainChipEnd ?? snapshot.curtainChipStart)
                chipDragBefore = callbacks?.chipSpans()
                return
            }
            if chipRect.contains(point) {
                curtainMove = (point.x, snapshot.curtainChipStart, false)
                curtainDragInitialSpan = (snapshot.curtainChipStart, snapshot.curtainChipEnd ?? snapshot.curtainChipStart)
                chipDragBefore = callbacks?.chipSpans()
                return
            }
        }

        if let item = effectItem(at: point) {
            if !isSelected(item) {
                callbacks?.selectEffect(item.zoomID, item.tiltID)
            }
            mouseState = .draggingBlock(TimelineLaneMath.effectDrag(
                item, mode: dragMode(for: point, blockStart: item.startTime, blockEnd: item.endTime),
                at: point, in: snapshot))
            // The SwiftUI blocks pop their hover cursor when a drag begins.
            setCursor(.arrow)
            return
        }
        if let item = focusItem(at: point) {
            if !item.isSelected {
                callbacks?.selectFocus(item.id, item.isHighlight)
            }
            mouseState = .draggingBlock(TimelineLaneMath.focusDrag(
                item, mode: dragMode(for: point, blockStart: item.startTime, blockEnd: item.endTime),
                at: point, in: snapshot))
            setCursor(.arrow)
            return
        }

        if let item = annotateItem(at: point) {
            if !item.isSelected {
                callbacks?.selectAnnotation(item.id)
            }
            // Overlaps are allowed on this lane — no blocking spans.
            mouseState = .draggingBlock(TimelineLaneMath.annotateDrag(
                item, mode: dragMode(for: point, blockStart: item.startTime, blockEnd: item.endTime),
                at: point, in: snapshot))
            setCursor(.arrow)
            return
        }

        // Empty lane areas and the ruler scrub; the click clears that lane's
        // selection first, same as the SwiftUI lanes.
        if effectsLaneRect.contains(point) {
            callbacks?.selectEffect(nil, nil)
            mouseState = .scrubbing
        } else if focusLaneRect.contains(point) {
            callbacks?.selectFocus(nil, false)
            mouseState = .scrubbing
        } else if annotateLaneRect.contains(point) {
            callbacks?.selectAnnotation(nil)
            mouseState = .scrubbing
        } else if point.y < M.videoLaneY {
            mouseState = .scrubbing
        }
        // Timeless stills hide the idle playhead; a scrub interaction must
        // reveal the line immediately, even before the first drag delta.
        if case .scrubbing = mouseState { overlay.needsDisplay = true }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if draggingIntroEdge {
            // Same rule as resizeRight on effect blocks: stop flush against the
            // nearest non-exempt neighbour instead of sliding under it.
            let end = TimelineLaneMath.chipResizedEnd(
                proposedEnd: outputTime(atX: point.x), chipStart: snapshot.introChipStart,
                blockers: introBlockers())
            callbacks?.resizeIntro(end)
            return
        }
        if var move = introMove {
            let dx = point.x - move.downX
            if !move.didDrag, abs(dx) >= M.dragThreshold { move.didDrag = true }
            introMove = move
            if move.didDrag {
                let dt = TimeInterval(dx / max(1, trackWidth)) * snapshot.outputDuration
                let duration = (snapshot.introChipEnd ?? move.initialStart) - snapshot.introChipStart
                let newStart = TimelineLaneMath.chipMovedStart(
                    initialStart: move.initialStart, dt: dt, duration: duration,
                    outputDuration: snapshot.outputDuration, blockers: introBlockers())
                callbacks?.moveIntro(newStart)
            }
            return
        }
        if draggingCurtainEdge {
            let end = TimelineLaneMath.chipResizedEnd(
                proposedEnd: outputTime(atX: point.x), chipStart: snapshot.curtainChipStart,
                blockers: curtainBlockers())
            callbacks?.resizeCurtain(end)
            return
        }
        if var move = curtainMove {
            let dx = point.x - move.downX
            if !move.didDrag, abs(dx) >= M.dragThreshold { move.didDrag = true }
            curtainMove = move
            if move.didDrag {
                let dt = TimeInterval(dx / max(1, trackWidth)) * snapshot.outputDuration
                let duration = (snapshot.curtainChipEnd ?? move.initialStart) - snapshot.curtainChipStart
                let newStart = TimelineLaneMath.chipMovedStart(
                    initialStart: move.initialStart, dt: dt, duration: duration,
                    outputDuration: snapshot.outputDuration, blockers: curtainBlockers())
                callbacks?.moveCurtain(newStart)
            }
            return
        }
        switch mouseState {
        case .idle:
            break
        case .video:
            videoMouseDragged(to: point)
        case .voice:
            voiceMouseDragged(to: point)
        case .slicing:
            // Keep the indicator tracking the cursor while held, like the
            // SwiftUI overlay's continuous hover did.
            updateSliceHover(at: point)
        case .scrubbing:
            callbacks?.scrub(point.x)
        case .draggingBlock(var drag):
            drag.translationX = point.x - drag.startPoint.x
            let dy = point.y - drag.startPoint.y
            if !drag.didDrag,
               sqrt(drag.translationX * drag.translationX + dy * dy) >= M.dragThreshold {
                drag.didDrag = true
            }
            mouseState = .draggingBlock(drag)
            snapGuideTime = snapIndicator(for: drag)
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let before = chipDragBefore {
            chipDragBefore = nil
            callbacks?.commitChipDrag(before)
        }
        if draggingIntroEdge {
            draggingIntroEdge = false
            introDragInitialSpan = nil
            return
        }
        if let move = introMove {
            introMove = nil
            introDragInitialSpan = nil
            if !move.didDrag { callbacks?.openIntro() }
            return
        }
        if draggingCurtainEdge {
            draggingCurtainEdge = false
            curtainDragInitialSpan = nil
            return
        }
        if let move = curtainMove {
            curtainMove = nil
            curtainDragInitialSpan = nil
            if !move.didDrag { callbacks?.openCurtain() }
            return
        }
        switch mouseState {
        case .idle:
            break
        case .video:
            if let model = videoModel { videoMouseUp(at: point, model: model) }
        case .voice:
            if let model = voiceModel { voiceMouseUp(at: point, model: model) }
        case .slicing:
            placeSlice(at: point)
        case .scrubbing:
            callbacks?.seek(point.x)
            // Mirror of the mouseDown reveal: a timeless still's playhead
            // fades back out when the interaction ends.
            overlay.needsDisplay = true
        case .draggingBlock(var drag):
            drag.translationX = point.x - drag.startPoint.x
            if drag.didDrag {
                let resolved = resolvedTimes(for: drag)
                switch drag.target {
                case .effect(let item):
                    callbacks?.commitEffectTimes(item.zoomID, item.tiltID, resolved.start, resolved.end)
                case .focus(let item):
                    callbacks?.commitFocusTimes(item.id, item.isHighlight, resolved.start, resolved.end)
                case .annotate(let item):
                    callbacks?.commitAnnotationTimes(item.id, resolved.start, resolved.end)
                }
            } else {
                switch drag.target {
                case .effect(let item):
                    callbacks?.selectEffect(item.zoomID, item.tiltID)
                case .focus(let item):
                    callbacks?.selectFocus(item.id, item.isHighlight)
                case .annotate(let item):
                    callbacks?.selectAnnotation(item.id)
                }
            }
            snapGuideTime = nil
            needsDisplay = true
        }
        mouseState = .idle
        // The hover lane was frozen for the gesture — re-resolve it where the
        // mouse came up (outside the canvas = moving off → spring back).
        hoverOverlayLane = bounds.contains(point) ? laneLayout.hoverLane(atY: point.y) : nil
    }

    // MARK: Slice tool

    /// Resolved cut for a point, or nil when it isn't a legal split position.
    /// Port of `resolvedSliceTarget` + `isSliceableOutputTime`, via the shared
    /// `VideoSliceMath` so the SwiftUI path and this one cannot diverge.
    func sliceTarget(at point: CGPoint) -> VideoSliceMath.Target? {
        // Armed-ness is enforced here, not just at the call sites, so no path
        // can cut while the tool is off.
        guard snapshot.sliceArmed,
              let model = videoModel,
              trackWidth > 0,
              snapshot.outputDuration > 0 else { return nil }
        let target = VideoSliceMath.resolvedTarget(
            atX: point.x,
            trackWidth: trackWidth,
            outputDuration: snapshot.outputDuration,
            playheadOutputTime: snapshot.playheadOutputTime
        )
        guard VideoSliceMath.isSliceable(
            target.outputTime,
            trimStartOutput: snapshot.trimStartOutput,
            trimEndOutput: snapshot.trimEndOutput,
            clipSpans: model.clipSpans
        ) else { return nil }
        return target
    }

    /// Cursor-follow indicator update; clears when the position can't be cut.
    func updateSliceHover(at point: CGPoint) {
        guard let target = sliceTarget(at: point) else {
            clearSliceHover()
            return
        }
        sliceHoverX = target.x
        sliceSnappedToPlayhead = target.snappedToPlayhead
        setCursor(.crosshair)
    }

    func clearSliceHover() {
        sliceHoverX = nil
        sliceSnappedToPlayhead = false
    }

    /// Commit the cut. Routes into TimelineView's undo-registered
    /// `splitVideoClip`, which also disarms the tool.
    func placeSlice(at point: CGPoint) {
        guard let target = sliceTarget(at: point) else { return }
        videoCallbacks?.sliceAt(target.outputTime)
        clearSliceHover()
        startSnipAnimation(atX: target.x)
    }

    // MARK: Snip animation

    /// The cut's scissors close, ride down through the lane, and fade —
    /// driven by timed redraws of the lane rect (the canvas is CG-drawn, so
    /// a CALayer animation would live in a different coordinate story).
    private var snipAnimation: (x: CGFloat, start: CFTimeInterval)?
    private var snipTimer: Timer?

    private func startSnipAnimation(atX x: CGFloat) {
        snipAnimation = (x, CACurrentMediaTime())
        snipTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.setNeedsDisplay(self.videoLaneRect.insetBy(dx: -24, dy: -28))
            if let anim = self.snipAnimation,
               CACurrentMediaTime() - anim.start > ScissorsGlyph.snipDuration {
                self.snipAnimation = nil
                self.snipTimer?.invalidate()
                self.snipTimer = nil
            }
        }
        snipTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Harness: freeze the snip animation `t` seconds in, for deterministic
    /// shots of the real draw pipeline (`--videotrack-math-test --snip-shot`).
    func harnessFreezeSnip(atX x: CGFloat, time t: TimeInterval) {
        snipTimer?.invalidate()
        snipTimer = nil
        snipAnimation = (x, CACurrentMediaTime() - t)
    }

    private func drawSnipAnimation(in context: CGContext) {
        guard let anim = snipAnimation else { return }
        let state = ScissorsGlyph.snipState(at: CACurrentMediaTime() - anim.start)
        let lane = videoLaneRect
        let glyphHeight: CGFloat = 24
        // Blades lead the cut UPWARD: enter at the lane's bottom edge, ride
        // to the top (flipped view — minY is the top).
        let y = lane.maxY - glyphHeight + 2
              - state.travel * (lane.height - glyphHeight + 2)
        let image = ScissorsGlyph.image(height: glyphHeight, open: state.open)
        // The cut line trails BELOW the blades — the part already cut.
        context.setFillColor(NSColor.systemRed
            .withAlphaComponent(0.9 * state.alpha).cgColor)
        context.fill(CGRect(x: anim.x - 0.75, y: y + glyphHeight * 0.3,
                            width: 1.5,
                            height: max(0, lane.maxY - y - glyphHeight * 0.3)))
        image.draw(
            in: CGRect(x: anim.x - image.size.width / 2, y: y,
                       width: image.size.width, height: glyphHeight),
            from: .zero, operation: .sourceOver, fraction: state.alpha,
            respectFlipped: true, hints: nil)
    }

    private func drawSliceIndicator(in context: CGContext) {
        guard snapshot.sliceArmed, let x = sliceHoverX else { return }
        let lane = videoLaneRect
        context.setFillColor(NSColor.systemRed.withAlphaComponent(0.9).cgColor)
        context.fill(CGRect(x: x - 0.75, y: lane.minY, width: 1.5, height: lane.height))

        // Open scissors straddling the cut line, blades up, pinned to the
        // lane's top edge — closes with a snip when the cut lands.
        let glyph = ScissorsGlyph.image(height: 24, open: 1)
        glyph.draw(
            in: CGRect(x: x - glyph.size.width / 2, y: lane.minY + 2,
                       width: glyph.size.width, height: 24),
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
    }

    /// Harness entry point (`--videotrack-math-test --slice`): arms the slice
    /// tool on a headless canvas so synthetic clicks exercise the real path.
    func configureForSliceHarness(
        width: CGFloat,
        outputDuration: TimeInterval,
        playheadOutputTime: TimeInterval,
        trimStartOutput: TimeInterval,
        trimEndOutput: TimeInterval,
        model: TimelineVideoRowModel,
        callbacks: TimelineVideoCallbacks
    ) {
        configureForVideoRowHarness(
            width: width,
            outputDuration: outputDuration,
            model: model,
            callbacks: callbacks
        )
        snapshot.playheadOutputTime = playheadOutputTime
        snapshot.trimStartOutput = trimStartOutput
        snapshot.trimEndOutput = trimEndOutput
        snapshot.sliceArmed = true
    }

    /// Harness driver: full press → release at one x, as the app would.
    func harnessSliceClick(atX x: CGFloat) {
        let point = CGPoint(x: x, y: M.videoLaneY + M.trackHeight / 2)
        updateSliceHover(at: point)
        placeSlice(at: point)
    }

    /// A ruler / empty-lane scrub is in flight — the overlay shows the
    /// playhead line during the interaction even in timeless mode.
    /// `needsDisplay` defers the actual draw to the next pass, which runs
    /// after mouseUp resets the state to .idle — so the post-seek redraw
    /// already reads false and the line fades back out.
    fileprivate var isLaneScrubbing: Bool {
        if case .scrubbing = mouseState { return true }
        return false
    }

    // MARK: Playhead drag (forwarded from the overlay's grab strip)

    fileprivate func beginPlayheadDrag() {
        overlay.isScrubbingPlayhead = true
    }

    fileprivate func continuePlayheadDrag(atX x: CGFloat) {
        callbacks?.scrub(x)
    }

    fileprivate func endPlayheadDrag(atX x: CGFloat) {
        callbacks?.seek(x)
        overlay.isScrubbingPlayhead = false
    }

    // MARK: Hover / cursors

    override func mouseMoved(with event: NSEvent) {
        guard case .idle = mouseState else { return }
        let point = convert(event.locationInWindow, from: nil)

        // Lane accordion: the overlay lane under the cursor opens; anywhere
        // else (ruler, VIDEO, VOICE) it springs back. Bands are contiguous,
        // so crossing an inter-lane gap never flickers it shut.
        hoverOverlayLane = laneLayout.hoverLane(atY: point.y)

        // Slice tool owns the VIDEO lane while armed — before any block or
        // playhead hover, exactly as the SwiftUI overlay sat above the row.
        if snapshot.sliceArmed, videoModel != nil {
            if videoLaneRect.contains(point) {
                hoveredLane = nil
                hoveredBlockKey = nil
                videoIsHovering = false
                updateSliceHover(at: point)
                if sliceHoverX == nil { setCursor(.arrow) }
                return
            }
            clearSliceHover()
        }

        // Empty-lane "+" hints.
        if effectsLaneRect.contains(point) {
            hoveredLane = .effects
        } else if focusLaneRect.contains(point) {
            hoveredLane = .focus
        } else if annotateLaneRect.contains(point) {
            hoveredLane = .annotate
        } else {
            hoveredLane = nil
        }

        // Playhead strip wins the cursor everywhere it's grabbable.
        if snapshot.playheadHitTestEnabled,
           snapshot.outputDuration > 0,
           abs(point.x - x(forOutputTime: snapshot.playheadOutputTime)) <= M.playheadStripHalfWidth,
           point.y <= tracksBottom {
            hoveredBlockKey = nil
            setCursor(.resizeLeftRight)
            return
        }

        if let item = effectItem(at: point) {
            hoveredBlockKey = effectKey(item)
            setCursor(cursorForBlock(point: point, start: item.startTime, end: item.endTime))
            return
        }
        if let chipRect = introChipRect, chipRect.contains(point) {
            hoveredBlockKey = "intro-chip"
            setCursor(abs(point.x - chipRect.maxX) <= 6 ? .resizeLeftRight : .openHand)
            return
        }
        if let chipRect = curtainChipRect, chipRect.contains(point) {
            hoveredBlockKey = "curtain-chip"
            setCursor(abs(point.x - chipRect.maxX) <= 6 ? .resizeLeftRight : .openHand)
            return
        }
        if let item = focusItem(at: point) {
            hoveredBlockKey = focusKey(item)
            setCursor(cursorForBlock(point: point, start: item.startTime, end: item.endTime))
            return
        }
        if let item = annotateItem(at: point) {
            hoveredBlockKey = annotateKey(item)
            setCursor(cursorForBlock(point: point, start: item.startTime, end: item.endTime))
            return
        }
        hoveredBlockKey = nil

        // Native VIDEO lane: we own hover styling and the resize cursor.
        if let model = videoModel {
            let inLane = videoLaneRect.contains(point)
            videoIsHovering = inLane
            if inLane, let cursor = videoHoverCursor(at: point, model: model) {
                setCursor(cursor)
                return
            }
        }

        // Native VOICE lane: per-clip hover styling + the block's cursors.
        if let model = voiceModel {
            let inLane = voiceLaneRect.contains(point)
            voiceHoveredClipID = inLane ? voiceClipItem(at: point, model: model)?.id : nil
            if inLane, let cursor = voiceHoverCursor(at: point, model: model) {
                setCursor(cursor)
                return
            }
        }

        // Our own empty regions get the arrow; over a HOSTED VIDEO / VOICE lane
        // the SwiftUI row manages the cursor itself — don't fight it.
        let overHostedVideo = videoModel == nil
            && point.y >= M.videoLaneY && point.y < M.voiceLaneY - M.trackSpacing
        let overHostedVoice = voiceModel == nil
            && point.y >= M.voiceLaneY && point.y < M.effectsLaneY - M.trackSpacing
        if overHostedVideo || overHostedVoice {
            appliedCursor = nil
        } else {
            setCursor(.arrow)
        }
    }

    override func mouseExited(with event: NSEvent) {
        // A drag that leaves the canvas keeps its lane open; mouseUp
        // re-resolves the hover once the gesture ends.
        if case .idle = mouseState { hoverOverlayLane = nil }
        hoveredLane = nil
        hoveredBlockKey = nil
        videoIsHovering = false
        voiceHoveredClipID = nil
        clearSliceHover()
        if appliedCursor != nil, case .idle = mouseState {
            setCursor(.arrow)
            appliedCursor = nil
        }
    }

    private func cursorForBlock(point: CGPoint, start: TimeInterval, end: TimeInterval) -> NSCursor {
        switch dragMode(for: point, blockStart: start, blockEnd: end) {
        case .resizeLeft, .resizeRight: return .resizeLeftRight
        case .move: return .openHand
        }
    }

    private func setCursor(_ cursor: NSCursor) {
        guard appliedCursor !== cursor else { return }
        appliedCursor = cursor
        cursor.set()
    }

    // MARK: - Context menus

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard snapshot.outputDuration > 0 else { return }

        let menu: NSMenu?
        if let model = videoModel, videoLaneRect.contains(point) {
            menu = videoContextMenu(at: point, model: model)
        } else if let model = voiceModel, voiceLaneRect.contains(point) {
            // The SwiftUI voice lane only menus on a clip, never the background.
            menu = voiceContextMenu(at: point, model: model)
        } else if let chipRect = introChipRect, effectItem(at: point) == nil,
                  chipRect.contains(point) {
            let m = NSMenu()
            m.addItem(CanvasMenuItem(title: String(localized: "Delete", comment: "Timeline context menu: verb, deletes the clicked item")) { [weak self] in
                self?.callbacks?.deleteIntro()
            })
            menu = m
        } else if let chipRect = curtainChipRect, effectItem(at: point) == nil,
                  chipRect.contains(point) {
            let m = NSMenu()
            m.addItem(CanvasMenuItem(title: String(localized: "Delete", comment: "Timeline context menu: verb, deletes the clicked item")) { [weak self] in
                self?.callbacks?.deleteCurtain()
            })
            menu = m
        } else if let item = effectItem(at: point) {
            menu = effectBlockMenu(for: item)
        } else if let item = focusItem(at: point) {
            menu = focusBlockMenu(for: item)
        } else if let item = annotateItem(at: point) {
            let m = NSMenu()
            m.addItem(CanvasMenuItem(title: String(localized: "Delete", comment: "Timeline context menu: verb, deletes the clicked item")) { [weak self] in
                self?.callbacks?.deleteAnnotation(item.id)
            })
            menu = m
        } else if annotateLaneRect.contains(point) {
            let time = outputTime(atX: point.x)
            let entries: [(String, AnnotationType)] = [
                (String(localized: "Add Text Label", comment: "Timeline context menu on the annotations lane"), .text),
                (String(localized: "Add Arrow", comment: "Timeline context menu on the annotations lane"), .arrow),
                (String(localized: "Add Callout", comment: "Timeline context menu on the annotations lane; callout = line pointing to a labelled box"), .callout),
                (String(localized: "Add Drawing", comment: "Timeline context menu on the annotations lane; freehand drawing"), .drawing),
                (String(localized: "Add Rectangle", comment: "Timeline context menu on the annotations lane"), .rectangle),
                (String(localized: "Add Ellipse", comment: "Timeline context menu on the annotations lane"), .ellipse),
                (String(localized: "Add Tap Indicator", comment: "Timeline context menu on the annotations lane; touch ripple marker"), .tap),
            ]
            let m = NSMenu()
            for (title, type) in entries {
                m.addItem(CanvasMenuItem(title: title) { [weak self] in
                    self?.callbacks?.addAnnotationAt(type, time)
                })
            }
            menu = m
        } else if effectsLaneRect.contains(point) {
            let time = outputTime(atX: point.x)
            menu = makeMenu([
                (String(localized: "Add Zoom Region", comment: "Timeline context menu on the effects lane"), false, { [weak self] in self?.callbacks?.addZoomAt(time) }),
                (String(localized: "Add Tilt Region", comment: "Timeline context menu on the effects lane; 3D tilt"), false, { [weak self] in self?.callbacks?.addTiltAt(time) }),
            ])
        } else if focusLaneRect.contains(point) {
            let time = outputTime(atX: point.x)
            menu = makeMenu([
                (String(localized: "Add Highlight", comment: "Timeline context menu on the focus lane"), false, { [weak self] in self?.callbacks?.addHighlightAt(time) }),
                (String(localized: "Add Blur", comment: "Timeline context menu on the focus lane"), false, { [weak self] in self?.callbacks?.addBlurAt(time) }),
            ])
        } else {
            menu = nil
        }

        if let menu {
            CaptureCatMenuPresenter.showContextMenu(menu, with: event, for: self)
        } else {
            super.rightMouseDown(with: event)
        }
    }

    private func effectBlockMenu(for item: EffectBlockItem) -> NSMenu {
        let menu = NSMenu()

        if item.hasZoom {
            let zoomLevelTitle = String(localized: "Zoom Level", comment: "Timeline context menu on a zoom block: submenu of zoom amounts (1.5x, 2.0x…)")
            let levelsItem = NSMenuItem(title: zoomLevelTitle, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: zoomLevelTitle)
            for level in [1.5, 2.0, 2.5, 3.0, 4.0, 5.0] {
                let entry = CanvasMenuItem(title: UnitText.multiplier(level, digits: 1)) { [weak self] in
                    if let id = item.zoomID { self?.callbacks?.setZoomLevel(id, level) }
                }
                entry.state = abs((item.zoomLevel ?? 0) - level) < 0.01 ? .on : .off
                submenu.addItem(entry)
            }
            levelsItem.submenu = submenu
            menu.addItem(levelsItem)
            menu.addItem(.separator())
        }

        if item.hasTilt {
            menu.addItem(CanvasMenuItem(title: String(localized: "Remove Tilt", comment: "Timeline context menu on an effect block: removes its 3D tilt")) { [weak self] in
                if let id = item.tiltID { self?.callbacks?.removeTilt(id) }
            })
        } else {
            menu.addItem(CanvasMenuItem(title: String(localized: "Add Tilt to Block", comment: "Timeline context menu on a zoom block: adds a 3D tilt to it")) { [weak self] in
                if let id = item.zoomID { self?.callbacks?.addTiltToBlock(id) }
            })
        }

        if item.hasZoom {
            menu.addItem(CanvasMenuItem(title: String(localized: "Remove Zoom", comment: "Timeline context menu on an effect block: removes its zoom")) { [weak self] in
                if let id = item.zoomID { self?.callbacks?.removeZoom(id) }
            })
        } else {
            menu.addItem(CanvasMenuItem(title: String(localized: "Add Zoom to Block", comment: "Timeline context menu on a tilt block: adds a zoom to it")) { [weak self] in
                if let id = item.tiltID { self?.callbacks?.addZoomToBlock(id) }
            })
        }

        menu.addItem(.separator())
        menu.addItem(CanvasMenuItem(title: String(localized: "Delete", comment: "Timeline context menu: verb, deletes the clicked item")) { [weak self] in
            self?.callbacks?.deleteEffectBlock(item.zoomID, item.tiltID)
        })
        return menu
    }

    private func focusBlockMenu(for item: TimelineFocusItem) -> NSMenu {
        let menu = NSMenu()
        if !item.isHighlight {
            // Blur's SwiftUI menu shows a (currently inert) rename entry.
            let rename = NSMenuItem(title: String(localized: "Rename...", comment: "Timeline context menu on a blur region: rename (currently disabled)"), action: nil, keyEquivalent: "")
            rename.isEnabled = false
            menu.addItem(rename)
            menu.addItem(.separator())
        }
        let extras = callbacks?.focusMenuExtras(item.id) ?? []
        for entry in extras {
            guard let action = entry.action else { menu.addItem(.separator()); continue }
            let row = CanvasMenuItem(title: entry.title, handler: action)
            row.state = entry.checked ? .on : .off
            row.isEnabled = entry.isEnabled
            menu.addItem(row)
        }
        if !extras.isEmpty { menu.addItem(.separator()) }
        menu.addItem(CanvasMenuItem(title: String(localized: "Delete", comment: "Timeline context menu: verb, deletes the clicked item")) { [weak self] in
            self?.callbacks?.deleteFocus(item.id, item.isHighlight)
        })
        return menu
    }

    private func makeMenu(_ entries: [(String, Bool, () -> Void)]) -> NSMenu {
        let menu = NSMenu()
        for (title, checked, action) in entries {
            let item = CanvasMenuItem(title: title, handler: action)
            item.state = checked ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        drawRuler(in: context)
        drawSeparators(in: context)
        // Accordion frames dirty only the overlay band (120 Hz while it
        // moves) — skip the filmstrip and waveforms unless they're dirty.
        if let model = videoModel, needsToDraw(videoLaneRect.insetBy(dx: -24, dy: -28)) {
            if let anim = snipAnimation {
                // Strip separation: the two clip halves lean away from the
                // cut while the blades pass, then breathe shut onto the real
                // split geometry. Each half is the same lane draw, clipped to
                // its side of the cut and nudged outward.
                let gap = ScissorsGlyph.stripGap(
                    at: CACurrentMediaTime() - anim.start, maxGap: 5)
                let lane = videoLaneRect
                for side: CGFloat in [-1, 1] {
                    context.saveGState()
                    let half = side < 0
                        ? CGRect(x: 0, y: lane.minY - 4,
                                 width: anim.x, height: lane.height + 8)
                        : CGRect(x: anim.x, y: lane.minY - 4,
                                 width: bounds.width - anim.x, height: lane.height + 8)
                    context.clip(to: half)
                    context.translateBy(x: side * gap, y: 0)
                    drawVideoLane(in: context, model: model)
                    context.restoreGState()
                }
            } else {
                drawVideoLane(in: context, model: model)
            }
        }
        if let model = voiceModel, needsToDraw(voiceLaneRect.insetBy(dx: 0, dy: -4)) {
            drawVoiceLane(in: context, model: model)
        }
        drawEffectsLane(in: context)
        drawFocusLane(in: context)
        drawAnnotateLane(in: context)
        drawEmptyLaneHints()
        drawSliceIndicator(in: context)
        drawSnipAnimation(in: context)
    }

    private func drawSeparators(in context: CGContext) {
        context.setFillColor(EditorThemeKit.hairline.cgColor)
        // FOCUS/ANNOTATE separators ride the accordion (and EFFECTS sub-rows).
        let layout = laneLayout
        let ys = [
            M.voiceLaneY - M.trackSpacing,
            M.effectsLaneY - M.trackSpacing,
            layout.laneY(.focus) - M.trackSpacing,
            layout.laneY(.annotate) - M.trackSpacing,
        ]
        for y in ys {
            context.fill(CGRect(x: 0, y: y, width: trackWidth, height: 1))
        }
    }

    // Direct port of TimeRulerView's Canvas drawing.
    /// See the comment at its use in `drawRuler` — deliberately resolved once.
    private static let rulerLabelFont = NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold)

    private func drawRuler(in context: CGContext) {
        let duration = snapshot.outputDuration
        guard duration > 0, trackWidth > 0 else { return }

        let height = M.rulerHeight

        // Ruler chrome ink — draws over the panel background, so it follows
        // the theme (same alphas as the shipped dark values).
        let ink: NSColor = CCTheme.isDark ? .white : .black

        // Image treatment: no time to measure — keep only the baseline, at
        // half strength, so the gutter still reads as chrome, not a hole.
        if snapshot.timelessVideo {
            context.setStrokeColor(ink.withAlphaComponent(0.06).cgColor)
            context.setLineWidth(1)
            context.move(to: CGPoint(x: 0, y: height - 1))
            context.addLine(to: CGPoint(x: trackWidth, y: height - 1))
            context.strokePath()
            return
        }

        let pixelsPerSecond = trackWidth / CGFloat(duration)
        let majorInterval = TimelineSnap.majorInterval(for: pixelsPerSecond)
        let minorInterval = majorInterval / 5

        // Image treatment with timed effects: ticks slightly dimmed, labels
        // untouched — timecodes must stay legible for real scrubbing.
        let dim: CGFloat = snapshot.dimmedRuler ? 0.65 : 1.0
        let tickColor = ink.withAlphaComponent(0.22 * dim)
        let majorTickHeight = height * 0.46
        let minorTickHeight = height * 0.22
        let baseline = height - 1

        context.setStrokeColor(ink.withAlphaComponent(0.12 * dim).cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: 0, y: baseline))
        context.addLine(to: CGPoint(x: trackWidth, y: baseline))
        context.strokePath()

        context.setStrokeColor(tickColor.cgColor)

        var t: TimeInterval = 0
        while t <= duration {
            let tickX = CGFloat(t / duration) * trackWidth
            let isMajor = (t / majorInterval).remainder(dividingBy: 1).magnitude < 0.01
            if !isMajor {
                context.setLineWidth(0.5)
                context.move(to: CGPoint(x: tickX, y: baseline))
                context.addLine(to: CGPoint(x: tickX, y: baseline - minorTickHeight))
                context.strokePath()
            }
            t += minorInterval
        }

        // Resolved ONCE, not per draw. A shipped crash log shows CoreText's
        // ApplyFont throwing "attempt to insert nil object" typesetting the
        // first ruler label ("0:00") after the font system degraded mid-session
        // (the same draw had succeeded minutes earlier) — re-resolving the
        // composite monospaced system font every frame re-rolls that dice.
        // The instance cached at first draw was created while the font system
        // was healthy and stays valid.
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: Self.rulerLabelFont,
            .foregroundColor: EditorThemeKit.textSecondary,
        ]
        t = 0
        while t <= duration {
            let tickX = CGFloat(t / duration) * trackWidth
            context.setLineWidth(1)
            context.move(to: CGPoint(x: tickX, y: baseline))
            context.addLine(to: CGPoint(x: tickX, y: baseline - majorTickHeight))
            context.strokePath()

            let label = Self.formatRulerTime(t, showsFraction: majorInterval < 1)
            let text = NSAttributedString(string: label, attributes: labelAttributes)
            let size = text.size()
            let centerX = min(max(size.width / 2 + 2, tickX), trackWidth - size.width / 2 - 2)
            text.draw(at: CGPoint(x: centerX - size.width / 2, y: 6))

            t += majorInterval
        }
    }

    static func formatRulerTime(_ seconds: TimeInterval, showsFraction: Bool) -> String {
        let total = Int(seconds.rounded(.down))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if showsFraction {
            let fraction = seconds - seconds.rounded(.down)
            let tenths = Int((fraction * 10).rounded())
            if tenths > 0 && tenths < 10 {
                return String(format: "%d:%02d.%d", m, s, tenths)
            }
        }
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    // MARK: Lane drawing

    /// The dragged block's display geometry, if `key` is mid-drag.
    /// Move mode follows the cursor with a pixel clamp (no snap preview),
    /// resize modes show the resolved edge live — same as the SwiftUI blocks.
    private func dragDisplay(forKey key: String) -> (rect: CGRect, dimmed: Bool)? {
        guard case .draggingBlock(let drag) = mouseState else { return nil }
        let (dragKey, lane, row): (String, TimelineOverlayLane, Int)
        switch drag.target {
        case .effect(let item):
            (dragKey, lane, row) = (effectKey(item), .effects,
                                    effectsRows()[effectsSpanKey(item)] ?? 0)
        case .focus(let item): (dragKey, lane, row) = (focusKey(item), .focus, 0)
        case .annotate(let item): (dragKey, lane, row) = (annotateKey(item), .annotate, 0)
        }
        guard dragKey == key else { return nil }

        switch drag.mode {
        case .move:
            let committed = blockRect(start: drag.initialStart, end: drag.initialEnd, lane: lane, row: row)
            let maxX = max(0, trackWidth - committed.width)
            let clampedX = min(max(committed.minX + drag.translationX, 0), maxX)
            return (committed.offsetBy(dx: clampedX - committed.minX, dy: 0), drag.didDrag)
        case .resizeLeft, .resizeRight:
            let resolved = resolvedTimes(for: drag)
            return (blockRect(start: resolved.start, end: resolved.end, lane: lane, row: row), drag.didDrag)
        }
    }

    /// The Intro chip's rect, nil when the intro is off.
    private var introChipRect: CGRect? {
        guard let end = snapshot.introChipEnd, end > snapshot.introChipStart else { return nil }
        return blockRect(start: snapshot.introChipStart, end: end,
                         lane: .effects, row: effectsRows()["intro-chip"] ?? 0)
    }

    /// The Curtain chip's rect, nil when the curtain is off.
    private var curtainChipRect: CGRect? {
        guard let end = snapshot.curtainChipEnd, end > snapshot.curtainChipStart else { return nil }
        return blockRect(start: snapshot.curtainChipStart, end: end,
                         lane: .effects, row: effectsRows()["curtain-chip"] ?? 0)
    }

    /// Opacity of a block's content (icon, label, grips) at its current
    /// height: fully legible on an open lane, gone on a closed strip, and a
    /// smooth fade in between so nothing pops while the accordion moves.
    private static func contentAlpha(forBlockHeight height: CGFloat) -> CGFloat {
        min(1, max(0, (height - 16) / 16))
    }

    /// Draws a settings-backed chip (Slide / Curtain) in the effect-block
    /// style: surface, icon + label, grips.
    private func drawSettingsChip(
        in context: CGContext, rect: CGRect,
        icon: String, label: String, isSelected: Bool, hoverKey: String
    ) {
        context.saveGState()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        drawBlockSurface(
            in: context,
            rect: rect,
            top: EditorThemeKit.effectBlockTop,
            bottom: EditorThemeKit.effectBlockBottom,
            isSelected: isSelected,
            isHovering: hoveredBlockKey == hoverKey
        )
        drawBlockContent(in: context, rect: rect) {
            let content = NSMutableAttributedString()
            if let image = Self.tintedSymbol(
                icon, pointSize: 9, weight: .semibold,
                color: EditorThemeKit.blockContent) {
                let attachment = NSTextAttachment()
                attachment.image = image
                attachment.bounds = CGRect(
                    x: 0, y: -2, width: image.size.width, height: image.size.height)
                content.append(NSAttributedString(attachment: attachment))
            }
            if rect.width > 52 {
                content.append(NSAttributedString(
                    string: "  \(label)",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                        .foregroundColor: EditorThemeKit.blockContent,
                    ]))
            }
            let size = content.size()
            content.draw(at: CGPoint(
                x: rect.midX - size.width / 2,
                y: rect.midY - size.height / 2))
            drawGrips(in: context, rect: rect,
                      visible: isSelected || hoveredBlockKey == hoverKey)
        }
        context.endTransparencyLayer()
        context.restoreGState()
    }

    /// Draws a block's icon/label/grips at the accordion's content opacity —
    /// skipped entirely on a closed strip.
    private func drawBlockContent(in context: CGContext, rect: CGRect, _ body: () -> Void) {
        let alpha = Self.contentAlpha(forBlockHeight: rect.height)
        guard alpha > 0.01 else { return }
        context.saveGState()
        context.setAlpha(alpha)
        body()
        context.restoreGState()
    }

    private func drawEffectsLane(in context: CGContext) {
        // Intro Slide chip: pinned at 0:00, distinct hue (it is settings, not
        // a draggable region) — click opens the Motion pane.
        if let rect = introChipRect {
            context.saveGState()
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            drawBlockSurface(
                in: context,
                rect: rect,
                top: EditorThemeKit.effectBlockTop,
                bottom: EditorThemeKit.effectBlockBottom,
                isSelected: snapshot.introChipSelected,
                isHovering: hoveredBlockKey == "intro-chip"
            )
            // Same icon+value label style as every other effect block.
            drawBlockContent(in: context, rect: rect) {
                let content = NSMutableAttributedString()
                if let image = Self.tintedSymbol(
                    snapshot.introChipIcon, pointSize: 9, weight: .semibold,
                    color: EditorThemeKit.blockContent) {
                    let attachment = NSTextAttachment()
                    attachment.image = image
                    attachment.bounds = CGRect(
                        x: 0, y: -2, width: image.size.width, height: image.size.height)
                    content.append(NSAttributedString(attachment: attachment))
                }
                if rect.width > 52 {
                    content.append(NSAttributedString(
                        string: "  \(snapshot.introChipLabel)",
                        attributes: [
                            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                            .foregroundColor: EditorThemeKit.blockContent,
                        ]))
                }
                let size = content.size()
                content.draw(at: CGPoint(
                    x: rect.midX - size.width / 2,
                    y: rect.midY - size.height / 2))
                drawGrips(in: context, rect: rect,
                          visible: snapshot.introChipSelected || hoveredBlockKey == "intro-chip")
            }
            context.endTransparencyLayer()
            context.restoreGState()
        }
        // Curtain Unveil chip: like the Slide chip, it is settings, not a
        // region — drag to place, right edge for length, click for the pane.
        if let rect = curtainChipRect {
            drawSettingsChip(
                in: context, rect: rect,
                icon: "book.pages", label: String(localized: "Curtain", comment: "Timeline: label on the Curtain Unveil transition chip in the effects lane"),
                isSelected: snapshot.curtainChipSelected,
                hoverKey: "curtain-chip")
        }
        for item in snapshot.effectItems {
            let key = effectKey(item)
            let display = dragDisplay(forKey: key)
            let rect = display?.rect
                ?? blockRect(start: item.startTime, end: item.endTime,
                             lane: .effects, row: effectsRows()[effectsSpanKey(item)] ?? 0)
            context.saveGState()
            if display?.dimmed == true { context.setAlpha(0.8) }
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            drawBlockSurface(
                in: context,
                rect: rect,
                top: EditorThemeKit.effectBlockTop,
                bottom: EditorThemeKit.effectBlockBottom,
                isSelected: isSelected(item),
                isHovering: hoveredBlockKey == key
            )
            drawBlockContent(in: context, rect: rect) {
                drawEffectLabel(for: item, in: rect)
                drawGrips(in: context, rect: rect, visible: isSelected(item) || hoveredBlockKey == key)
            }
            context.endTransparencyLayer()
            context.restoreGState()
        }
    }

    private func drawFocusLane(in context: CGContext) {
        // Blurs first, highlights above — same z-order as the SwiftUI lane.
        let ordered = snapshot.focusItems.filter { !$0.isHighlight } + snapshot.focusItems.filter(\.isHighlight)
        for item in ordered {
            let key = focusKey(item)
            let display = dragDisplay(forKey: key)
            let rect = display?.rect
                ?? blockRect(start: item.startTime, end: item.endTime, lane: .focus)
            let top = item.isHighlight ? EditorThemeKit.highlightBlockTop : EditorThemeKit.blurBlockTop
            let bottom = item.isHighlight ? EditorThemeKit.highlightBlockBottom : EditorThemeKit.blurBlockBottom
            context.saveGState()
            if display?.dimmed == true { context.setAlpha(0.8) }
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            drawBlockSurface(
                in: context,
                rect: rect,
                top: top,
                bottom: bottom,
                isSelected: item.isSelected,
                isHovering: hoveredBlockKey == key
            )
            drawBlockContent(in: context, rect: rect) {
                drawCenteredLabel(item.label, in: rect.insetBy(dx: 8, dy: 0))
                drawGrips(in: context, rect: rect, visible: item.isSelected || hoveredBlockKey == key)
            }
            context.endTransparencyLayer()
            context.restoreGState()
        }
    }

    private func drawAnnotateLane(in context: CGContext) {
        for item in orderedAnnotateItems {
            let key = annotateKey(item)
            let display = dragDisplay(forKey: key)
            let rect = display?.rect ?? annotateRect(for: item)
            context.saveGState()
            if display?.dimmed == true { context.setAlpha(0.8) }
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            drawBlockSurface(
                in: context,
                rect: rect,
                top: EditorThemeKit.annotateBlockTop,
                bottom: EditorThemeKit.annotateBlockBottom,
                isSelected: item.isSelected,
                isHovering: hoveredBlockKey == key
            )
            drawBlockContent(in: context, rect: rect) {
                drawAnnotateLabel(for: item, in: rect)
                // Grips don't fit on slim sub-rows — edge-resize still works.
                if rect.height >= 16 {
                    drawGrips(in: context, rect: rect, visible: item.isSelected || hoveredBlockKey == key)
                }
            }
            context.endTransparencyLayer()
            context.restoreGState()
        }
    }

    private func drawAnnotateLabel(for item: TimelineAnnotateItem, in rect: CGRect) {
        // Slim sub-row bars (deep overlap stacks) draw as clean color bars —
        // an icon+label crammed into a ~12pt bar is what made a busy
        // ANNOTATE lane read as chaos. Established video editors draw
        // connected-clip and overlay bars the same way. Hover/selection still
        // identifies a bar, and it regains its label when the stack thins.
        guard rect.height >= 14 else { return }
        let contentColor = EditorThemeKit.blockContent
        var pieces: [NSAttributedString] = []
        if let image = Self.tintedSymbol(item.icon, pointSize: 9, weight: .semibold, color: contentColor) {
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = CGRect(x: 0, y: -2, width: image.size.width, height: image.size.height)
            pieces.append(NSAttributedString(attachment: attachment))
        }
        if rect.width > 58 {
            pieces.append(NSAttributedString(string: item.label, attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: contentColor,
            ]))
        }
        let combined = NSMutableAttributedString()
        for (index, piece) in pieces.enumerated() {
            if index > 0 { combined.append(NSAttributedString(string: "\u{2002}")) }
            combined.append(piece)
        }
        let size = combined.size()
        guard size.width > 0 else { return }
        combined.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }

    /// CG port of TimelineBlockSurface: gradient slab, glossy top edge, soft
    /// shadow, white selection border.
    private func drawBlockSurface(
        in context: CGContext,
        rect: CGRect,
        top: NSColor,
        bottom: NSColor,
        isSelected: Bool,
        isHovering: Bool
    ) {
        let brightness: CGFloat = isSelected ? 0.06 : (isHovering ? 0.03 : 0)
        // 2026 look (matches CCMaterial's floating surface): a soft,
        // nearly flat colour with only a whisper of top light — a clean
        // rounded bar, not a lit slab.
        let topColor = Self.brightened(top, by: brightness + 0.025)
        let bottomColor = Self.brightened(bottom, by: brightness - 0.015)
        // Closed accordion strips are ~12pt tall: the radius follows the bar
        // down to a capsule (CGPath traps if a corner exceeds half the rect).
        let radius = min(M.blockCornerRadius, rect.width / 2, rect.height / 2)
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )

        context.saveGState()

        // Soft contact shadow (offset is in unflipped base space: -1 renders below).
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -1),
            blur: 4,
            color: NSColor.black.withAlphaComponent(CCTheme.isDark ? 0.28 : 0.10).cgColor
        )
        context.addPath(path)
        context.setFillColor(bottomColor.cgColor)
        context.fillPath()
        context.restoreGState()

        // Vertical gradient, top → bottom.
        context.saveGState()
        context.addPath(path)
        context.clip()
        if let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [topColor.cgColor, bottomColor.cgColor] as CFArray,
            locations: [0, 1]
        ) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: rect.midX, y: rect.minY),
                end: CGPoint(x: rect.midX, y: rect.maxY),
                options: []
            )
        }
        // Hairline edge that follows the corners (CCMaterial.hairline's
        // twin) — no 1px top highlight line in the 2026 look.
        context.addPath(path)
        context.setStrokeColor(NSColor.black.withAlphaComponent(CCTheme.isDark ? 0.18 : 0.08).cgColor)
        context.setLineWidth(1)
        context.strokePath()
        context.restoreGState()

        if isSelected {
            let inner = rect.insetBy(dx: 1, dy: 1)
            let innerRadius = max(0, min(M.blockCornerRadius - 1, inner.width / 2, inner.height / 2))
            let borderPath = CGPath(
                roundedRect: inner,
                cornerWidth: innerRadius,
                cornerHeight: innerRadius,
                transform: nil
            )
            context.addPath(borderPath)
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
            context.setLineWidth(2)
            context.strokePath()
        }

        context.restoreGState()
    }

    private func drawGrips(in context: CGContext, rect: CGRect, visible: Bool) {
        guard visible else { return }
        context.setFillColor(EditorThemeKit.blockGrip.cgColor)
        let gripSize = CGSize(width: 2, height: 13)
        let y = rect.midY - gripSize.height / 2
        for edgeX in [rect.minX + 5, rect.maxX - 5 - 6] {
            for i in 0..<2 {
                let grip = CGRect(
                    x: edgeX + CGFloat(i) * 4,
                    y: y,
                    width: gripSize.width,
                    height: gripSize.height
                )
                context.addPath(CGPath(
                    roundedRect: grip,
                    cornerWidth: 1,
                    cornerHeight: 1,
                    transform: nil
                ))
            }
        }
        context.fillPath()
    }

    private func drawEffectLabel(for item: EffectBlockItem, in rect: CGRect) {
        var pieces: [NSAttributedString] = []
        let contentColor = EditorThemeKit.blockContent

        for (present, symbol) in [(item.hasZoom, "plus.magnifyingglass"), (item.hasTilt, "rotate.3d"),
                                  (item.hasSlide, "arrow.up.to.line")]
        where present {
            if let image = Self.tintedSymbol(symbol, pointSize: 9, weight: .semibold, color: contentColor) {
                let attachment = NSTextAttachment()
                attachment.image = image
                // Center the glyph roughly on the text baseline.
                attachment.bounds = CGRect(x: 0, y: -2, width: image.size.width, height: image.size.height)
                pieces.append(NSAttributedString(attachment: attachment))
            }
        }
        if rect.width > 58 {
            let valueText: String
            let zoomLabel = UnitText.multiplier(item.zoomLevel ?? 1, digits: 1)
            let tiltLabel = String(format: "%.0f°", item.dominantAngle)
            switch (item.hasZoom, item.hasTilt) {
            case (true, true): valueText = "\(zoomLabel) · \(tiltLabel)"
            case (true, false): valueText = zoomLabel
            case (false, true): valueText = tiltLabel
            case (false, false): valueText = ""
            }
            pieces.append(NSAttributedString(string: valueText, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: contentColor,
            ]))
        }

        let combined = NSMutableAttributedString()
        for (index, piece) in pieces.enumerated() {
            if index > 0 { combined.append(NSAttributedString(string: "\u{2002}")) }
            combined.append(piece)
        }
        let size = combined.size()
        guard size.width > 0 else { return }
        combined.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }

    private func drawCenteredLabel(_ label: String, in rect: CGRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let text = NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: EditorThemeKit.blockContent,
            .paragraphStyle: paragraph,
        ])
        let height = text.size().height
        text.draw(in: CGRect(
            x: rect.minX,
            y: rect.midY - height / 2,
            width: rect.width,
            height: height
        ))
    }

    private func drawEmptyLaneHints() {
        let hints: [(HoveredLane, TimelineOverlayLane, Bool)] = [
            (.effects, .effects, snapshot.effectItems.isEmpty),
            (.focus, .focus, snapshot.focusItems.isEmpty),
            (.annotate, .annotate, snapshot.annotateItems.isEmpty),
        ]
        let layout = laneLayout
        for (hovered, lane, isEmpty) in hints where hoveredLane == hovered && isEmpty {
            // The "+" grows in with its lane: invisible on a strip, full on
            // an open lane.
            let alpha = Self.contentAlpha(forBlockHeight: layout.rowHeight(lane) - M.blockInset * 2)
            guard alpha > 0.01 else { continue }
            if let image = Self.tintedSymbol(
                "plus",
                pointSize: 14,
                weight: .semibold,
                // Empty-lane hint sits on the panel background → theme ink.
                color: (CCTheme.isDark ? NSColor.white : NSColor.black).withAlphaComponent(0.25)
            ) {
                let rect = CGRect(x: 0, y: layout.laneY(lane), width: trackWidth,
                                  height: layout.rowHeight(lane))
                image.draw(
                    in: CGRect(
                        x: rect.midX - image.size.width / 2,
                        y: rect.midY - image.size.height / 2,
                        width: image.size.width,
                        height: image.size.height
                    ),
                    from: .zero, operation: .sourceOver, fraction: alpha,
                    respectFlipped: true, hints: nil
                )
            }
        }
    }

    // MARK: Drawing helpers

    private static var symbolCache: [String: NSImage] = [:]

    static func tintedSymbol(
        _ name: String,
        pointSize: CGFloat,
        weight: NSFont.Weight,
        color: NSColor
    ) -> NSImage? {
        let key = "\(name)-\(pointSize)-\(weight.rawValue)-\(color.description)"
        if let cached = symbolCache[key] { return cached }
        // Kit icon painted in `color` (CCIcon) — timeline chrome, never content.
        guard let tinted = CCIcon.image(name, pointSize: pointSize, weight: weight, color: color)
        else { return nil }
        symbolCache[key] = tinted
        return tinted
    }

    static func brightened(_ color: NSColor, by delta: CGFloat) -> NSColor {
        guard delta != 0, let rgb = color.usingColorSpace(.sRGB) else { return color }
        return NSColor(
            srgbRed: min(1, rgb.redComponent + delta),
            green: min(1, rgb.greenComponent + delta),
            blue: min(1, rgb.blueComponent + delta),
            alpha: rgb.alphaComponent
        )
    }
}

// MARK: - Playhead + snap-guide overlay

/// Sits above the hosted SwiftUI rows (layers draw beneath subviews, so the
/// playhead must be a view to cross the VIDEO/VOICE lanes). Transparent to
/// events except the 28pt grab strip around the playhead line.
private final class TimelinePlayheadOverlayView: NSView {
    private typealias M = TimelineCanvasMetrics

    weak var canvas: TimelineCanvasView?

    var snapshot: TimelineCanvasSnapshot? {
        didSet { needsDisplay = true }
    }
    var snapGuideTime: TimeInterval? {
        didSet { needsDisplay = true }
    }
    var isScrubbingPlayhead = false {
        didSet { needsDisplay = true }
    }
    /// Slice hover snapped onto the playhead. Lives here rather than in the
    /// snapshot because it changes on every mouse move — routing it through
    /// SwiftUI state would re-render the whole timeline per pixel.
    var sliceSnapActive = false {
        didSet { if sliceSnapActive != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var playheadX: CGFloat {
        guard let snapshot, snapshot.outputDuration > 0, bounds.width > 0 else { return 0 }
        return bounds.width * CGFloat(snapshot.playheadOutputTime / snapshot.outputDuration)
    }

    /// Tracks-bottom right now — EFFECTS sub-rows and the lane accordion
    /// included, read from the canvas's one `TimelineLaneLayout`.
    private var tracksBottom: CGFloat {
        canvas?.tracksBottom ?? M.tracksBottom
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let snapshot, snapshot.playheadHitTestEnabled, !snapshot.timelessVideo,
              snapshot.outputDuration > 0,
              let superview else { return nil }
        let local = convert(point, from: superview)
        guard abs(local.x - playheadX) <= M.playheadStripHalfWidth,
              local.y <= tracksBottom + 10 else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        canvas?.beginPlayheadDrag()
        let point = convert(event.locationInWindow, from: nil)
        canvas?.continuePlayheadDrag(atX: point.x)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        canvas?.continuePlayheadDrag(atX: point.x)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        canvas?.endPlayheadDrag(atX: point.x)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let snapshot, snapshot.outputDuration > 0,
              let context = NSGraphicsContext.current?.cgContext else { return }

        // Snap guide under the playhead, above the blocks — SwiftUI z-order.
        if let snapTime = snapGuideTime {
            let fraction = min(max(snapTime / snapshot.outputDuration, 0), 1)
            let snapX = bounds.width * CGFloat(fraction)
            let guideColor = EditorThemeKit.snapGuide
            context.setFillColor(guideColor.cgColor)
            context.fill(CGRect(x: snapX - 0.75, y: 0, width: 1.5, height: tracksBottom))
            context.move(to: CGPoint(x: snapX - 4.5, y: 0))
            context.addLine(to: CGPoint(x: snapX + 4.5, y: 0))
            context.addLine(to: CGPoint(x: snapX, y: 6))
            context.closePath()
            context.fillPath()
        }

        // Timeless still (Image treatment, no timed effects): the playhead
        // hides while IDLE only — a click/drag scrub reveals the line for the
        // duration of the interaction, then it fades back out. (The snap
        // guide above stays: block drags still deserve their alignment cue.)
        // With timed effects present, timelessVideo is false and the playhead
        // behaves exactly as in Video treatment.
        let interacting = isScrubbingPlayhead || (canvas?.isLaneScrubbing ?? false)
        if snapshot.timelessVideo && !interacting { return }

        let x = playheadX
        // `playheadIsRed` is now always false — the slice-snap state lives here,
        // in the view that knows where the cursor is.
        let color: NSColor = (snapshot.playheadIsRed || sliceSnapActive) ? .systemRed : .systemCyan

        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: x - 1, y: 0, width: 2, height: tracksBottom))

        // 16pt ringed diamond centred on the ruler's bottom edge.
        let cy = M.rulerHeight
        context.move(to: CGPoint(x: x, y: cy - 8))
        context.addLine(to: CGPoint(x: x + 8, y: cy))
        context.addLine(to: CGPoint(x: x, y: cy + 8))
        context.addLine(to: CGPoint(x: x - 8, y: cy))
        context.closePath()
        let diamond = context.path
        context.fillPath()
        if let diamond {
            context.addPath(diamond)
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
            context.setLineWidth(1)
            context.strokePath()
        }

        if isScrubbingPlayhead {
            drawScrubBubble(in: context, text: snapshot.scrubLabel, atX: x)
        }
    }

    private func drawScrubBubble(in context: CGContext, text: String, atX x: CGFloat) {
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: EditorThemeKit.textPrimary,
        ])
        let textSize = attributed.size()
        let capsule = CGRect(
            x: x + 8,
            y: -1,
            width: textSize.width + 14,
            height: textSize.height + 6
        )
        let path = CGPath(
            roundedRect: capsule,
            cornerWidth: capsule.height / 2,
            cornerHeight: capsule.height / 2,
            transform: nil
        )
        context.addPath(path)
        context.setFillColor(EditorThemeKit.panelElevated.cgColor)
        context.fillPath()
        context.addPath(path)
        context.setStrokeColor(EditorThemeKit.hairline.cgColor)
        context.setLineWidth(1)
        context.strokePath()
        attributed.draw(at: CGPoint(x: capsule.minX + 7, y: capsule.minY + 3))
    }
}

// MARK: - Closure-driven menu item

private final class CanvasMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func invoke() { handler() }
}
