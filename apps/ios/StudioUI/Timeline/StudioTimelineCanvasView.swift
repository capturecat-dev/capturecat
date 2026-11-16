import UIKit

/// What a long press landed on — the touch twin of the Mac canvas's
/// right-click resolution (same order: VIDEO, VOICE, chips, blocks, empty
/// lanes). `StudioTimelineMenus` turns it into a house menu.
enum StudioTimelineHit {
    case videoSegment(TimelineVideoSegmentItem)
    case voiceClip(TimelineVoiceClipItem)
    case introChip
    case curtainChip
    case effect(EffectBlockItem)
    case focus(TimelineFocusItem)
    case annotate(TimelineAnnotateItem)
    /// Empty lane area — OUTPUT time under the press.
    case emptyEffects(TimeInterval)
    case emptyFocus(TimeInterval)
    case emptyAnnotate(TimeInterval)
    case none
}

/// The touch timeline's track area: ruler, VIDEO and VOICE rows, the three
/// overlay lanes, the playhead — CG-drawn at the Mac's metrics from the
/// shared lane model (`TimelineCanvasSnapshot`, `TimelineLaneLayout`), edited
/// through the shared callback tables (`TimelineHosting`). Every press goes
/// through one state machine, a port of the Mac canvas's mouse machine:
/// `pressBegan` / `pressMoved` / `pressEnded` — the gesture recognizers call
/// them, and so does the `--timeline-edits` gate. Block drags resolve with
/// the shared `TimelineLaneMath`, so a touch drag commits the Mac's values.
///
/// Touch differences from the Mac, deliberately: a TAP opens an overlay lane
/// (the Mac opens on hover); a drag that starts on empty lane space scrolls
/// (the scroll view owns it) while the ruler scrubs; the selection outline is
/// a layer that GLIDES between blocks.
@MainActor
final class StudioTimelineCanvasView: UIView {
    typealias M = TimelineCanvasMetrics

    // MARK: Inputs

    private(set) var snapshot = TimelineCanvasSnapshot(
        outputDuration: 0, playheadOutputTime: 0, playheadIsRed: false, playheadHitTestEnabled: true,
        scrubLabel: "", effectItems: [], selectedZoomID: nil, selectedTiltID: nil,
        focusItems: [], annotateItems: [], trimStartOutput: 0, trimEndOutput: 0, sliceArmed: false
    ) {
        didSet {
            committedEffectsRows = TimelineLaneMath.effectsRowCount(snapshot: snapshot)
            committedAnnotateRows = TimelineLaneMath.annotateRowLayout(snapshot).values.map(\.rows).max() ?? 1
        }
    }
    private(set) var callbacks: TimelineCanvasCallbacks?
    private(set) var videoModel: TimelineVideoRowModel?
    private(set) var videoAssets = TimelineVideoAssets()
    private(set) var videoCallbacks: TimelineVideoCallbacks?
    private(set) var voiceModel: TimelineVoiceRowModel?
    private(set) var voiceAssets = TimelineVoiceAssets()
    private(set) var voiceCallbacks: TimelineVoiceCallbacks?

    /// Lane-geometry changes (every accordion frame, row-count changes) — the
    /// controller moves the label column in lockstep.
    var onLaneLayoutChange: ((TimelineLaneLayout) -> Void)?

    // MARK: Lane accordion

    let laneAccordion = StudioTimelineLaneAccordion()
    private var committedEffectsRows = 1
    private var committedAnnotateRows = 1
    private var reportedLaneLayout: TimelineLaneLayout?

    var laneLayout: TimelineLaneLayout {
        TimelineLaneLayout(
            openness: laneAccordion.openness,
            effectsRows: committedEffectsRows,
            annotateRows: committedAnnotateRows
        )
    }

    /// Committed ANNOTATE sub-row count — the controller sizes the document.
    var annotateRowCount: Int { committedAnnotateRows }
    /// Bottom of the last lane right now (mid-animation included).
    var tracksBottom: CGFloat { laneLayout.tracksBottom }
    /// The lane a tap opened (nil = every lane a strip).
    var openOverlayLane: TimelineOverlayLane? { laneAccordion.target }

    // MARK: Press state machine

    private enum PressState {
        case idle
        /// Ruler / empty-lane scrub; seek fires on release.
        case scrubbing
        case draggingBlock(TimelineBlockDrag)
        case video
        case voice
        /// Slice tool armed and pressed on VIDEO — the cut lands on release.
        case slicing
        case introEdge
        case introMove(downX: CGFloat, initialStart: TimeInterval, didDrag: Bool)
        case curtainEdge
        case curtainMove(downX: CGFloat, initialStart: TimeInterval, didDrag: Bool)
    }

    private var pressState: PressState = .idle
    private var introDragInitialSpan: (start: TimeInterval, end: TimeInterval)?
    private var curtainDragInitialSpan: (start: TimeInterval, end: TimeInterval)?
    var videoDrag: VideoRowDrag?
    var videoPendingDeselect = false
    var voiceDrag: VoiceRowDrag?

    /// Time an edge is locked onto — the yellow guide.
    private var snapGuideTime: TimeInterval? {
        didSet { if snapGuideTime != oldValue { overlay.snapGuideTime = snapGuideTime } }
    }

    // MARK: Layers

    private let overlay = StudioTimelinePlayheadOverlay()
    /// The selection outline — a layer, so it can glide between blocks.
    let selectionRing = CAShapeLayer()
    private var ringKey: String?
    /// The outline's drawn rect (mid-glide included).
    private var ringRect: CGRect?

    #if DEBUG
    /// Harness defect injection: the selection outline jumps instead of gliding.
    var probeSnapSelection = false
    #endif

    // MARK: Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        selectionRing.fillColor = nil
        selectionRing.strokeColor = UIColor.white.withAlphaComponent(0.85).cgColor
        selectionRing.lineWidth = 2
        selectionRing.opacity = 0
        layer.addSublayer(selectionRing)
        overlay.canvas = self
        overlay.isUserInteractionEnabled = false
        addSubview(overlay)
        laneAccordion.onChange = { [weak self] in self?.laneAccordionDidChange() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        overlay.frame = bounds
        refreshSelectionRing(animated: false)
    }

    func apply(
        snapshot: TimelineCanvasSnapshot,
        callbacks: TimelineCanvasCallbacks,
        videoModel: TimelineVideoRowModel?,
        videoAssets: TimelineVideoAssets,
        videoCallbacks: TimelineVideoCallbacks,
        voiceModel: TimelineVoiceRowModel?,
        voiceAssets: TimelineVoiceAssets,
        voiceCallbacks: TimelineVoiceCallbacks
    ) {
        self.callbacks = callbacks
        self.videoCallbacks = videoCallbacks
        self.voiceCallbacks = voiceCallbacks
        var dirty = false
        if videoModel != self.videoModel { self.videoModel = videoModel; dirty = true }
        if videoAssets.renderKey != self.videoAssets.renderKey { dirty = true }
        self.videoAssets = videoAssets
        if voiceModel != self.voiceModel { self.voiceModel = voiceModel; dirty = true }
        if voiceAssets.renderKey != self.voiceAssets.renderKey { dirty = true }
        self.voiceAssets = voiceAssets
        if snapshot != self.snapshot {
            self.snapshot = snapshot
            overlay.snapshot = snapshot
            dirty = true
            reportLaneLayout()
        }
        if dirty {
            setNeedsDisplay()
            refreshSelectionRing(animated: true)
        }
    }

    /// Drops the stored callback tables — they capture the controller.
    func releaseCallbacks() {
        callbacks = nil
        videoCallbacks = TimelineVideoCallbacks()
        voiceCallbacks = TimelineVoiceCallbacks()
    }

    private func laneAccordionDidChange() {
        setNeedsDisplay()
        overlay.setNeedsDisplay()
        refreshSelectionRing(animated: false)
        reportLaneLayout()
    }

    private func reportLaneLayout() {
        let layout = laneLayout
        guard layout != reportedLaneLayout else { return }
        reportedLaneLayout = layout
        onLaneLayoutChange?(layout)
    }

    /// Opens the overlay lane a press lands in; a press above the band
    /// (ruler, VIDEO, VOICE) springs every lane shut.
    private func openLane(forPressAt point: CGPoint) {
        guard bounds.contains(point) else { return }
        let lane = laneLayout.hoverLane(atY: point.y)
        if lane != nil || point.y < M.effectsLaneY - M.trackSpacing {
            laneAccordion.setTarget(lane, animated: window != nil)
        }
    }

    /// A touch that does not start a press (a long press) still opens the
    /// lane it lands in.
    func noteTouch(at point: CGPoint) { openLane(forPressAt: point) }

    /// Programmatic open/close (the controller's tap on a lane label).
    func setOpenLane(_ lane: TimelineOverlayLane?, animated: Bool) {
        laneAccordion.setTarget(lane, animated: animated && window != nil)
    }

    // MARK: - Geometry

    var trackWidth: CGFloat { bounds.width }

    func x(forOutputTime t: TimeInterval) -> CGFloat {
        guard snapshot.outputDuration > 0 else { return 0 }
        return trackWidth * CGFloat(t / snapshot.outputDuration)
    }

    func outputTime(atX x: CGFloat) -> TimeInterval {
        guard trackWidth > 0, snapshot.outputDuration > 0 else { return 0 }
        let fraction = max(0, min(1, x / trackWidth))
        return fraction * snapshot.outputDuration
    }

    private func overlayLaneRect(_ lane: TimelineOverlayLane) -> CGRect {
        laneLayout.laneRect(lane, width: trackWidth)
    }

    private func blockWidth(start: TimeInterval, end: TimeInterval) -> CGFloat {
        guard snapshot.outputDuration > 0 else { return M.minBlockWidth }
        return max(M.minBlockWidth, trackWidth * CGFloat((end - start) / snapshot.outputDuration))
    }

    /// Committed rect for a span in one sub-row of an overlay lane, at the
    /// lane's current animated row height.
    func blockRect(start: TimeInterval, end: TimeInterval, lane: TimelineOverlayLane, row: Int = 0) -> CGRect {
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

    private func focusKey(_ item: TimelineFocusItem) -> String { "f:\(item.id.uuidString)" }
    private func annotateKey(_ item: TimelineAnnotateItem) -> String { "a:\(item.id.uuidString)" }

    private var orderedAnnotateItems: [TimelineAnnotateItem] { TimelineLaneMath.orderedAnnotateItems(snapshot) }

    func annotateRect(for item: TimelineAnnotateItem) -> CGRect {
        guard let slot = TimelineLaneMath.annotateRowLayout(snapshot)[item.id], slot.rows > 1 else {
            return blockRect(start: item.startTime, end: item.endTime, lane: .annotate)
        }
        return blockRect(start: item.startTime, end: item.endTime, lane: .annotate, row: slot.row)
    }

    private func isSelected(_ item: EffectBlockItem) -> Bool {
        if let zoomID = item.zoomID, snapshot.selectedZoomID == zoomID { return true }
        if let tiltID = item.tiltID, snapshot.selectedTiltID == tiltID { return true }
        return false
    }

    private var activeDrag: TimelineBlockDrag? {
        if case .draggingBlock(let drag) = pressState { return drag }
        return nil
    }

    private func effectsRows() -> [String: Int] {
        TimelineLaneMath.effectsRowAssignment(
            spans: TimelineLaneMath.liveEffectsSpans(snapshot: snapshot, drag: activeDrag, trackWidth: trackWidth)
        ).rows
    }

    func effectRect(for item: EffectBlockItem) -> CGRect {
        blockRect(start: item.startTime, end: item.endTime, lane: .effects,
                  row: effectsRows()[TimelineLaneMath.effectsSpanKey(item)] ?? 0)
    }

    func focusRect(for item: TimelineFocusItem) -> CGRect {
        blockRect(start: item.startTime, end: item.endTime, lane: .focus)
    }

    var introChipRect: CGRect? {
        guard let end = snapshot.introChipEnd, end > snapshot.introChipStart else { return nil }
        return blockRect(start: snapshot.introChipStart, end: end, lane: .effects, row: effectsRows()["intro-chip"] ?? 0)
    }

    var curtainChipRect: CGRect? {
        guard let end = snapshot.curtainChipEnd, end > snapshot.curtainChipStart else { return nil }
        return blockRect(start: snapshot.curtainChipStart, end: end, lane: .effects, row: effectsRows()["curtain-chip"] ?? 0)
    }

    private func resolvedTimes(for drag: TimelineBlockDrag) -> (start: TimeInterval, end: TimeInterval) {
        TimelineLaneMath.resolvedTimes(for: drag, outputDuration: snapshot.outputDuration, trackWidth: trackWidth)
    }

    // MARK: - Hit testing

    func effectItem(at point: CGPoint) -> EffectBlockItem? {
        guard overlayLaneRect(.effects).contains(point) else { return nil }
        let rows = effectsRows()
        for item in snapshot.effectItems.reversed() {
            if blockRect(start: item.startTime, end: item.endTime, lane: .effects,
                         row: rows[TimelineLaneMath.effectsSpanKey(item)] ?? 0)
                .insetBy(dx: 0, dy: -M.blockInset).contains(point) {
                return item
            }
        }
        return nil
    }

    func focusItem(at point: CGPoint) -> TimelineFocusItem? {
        guard overlayLaneRect(.focus).contains(point) else { return nil }
        let ordered = snapshot.focusItems.filter(\.isHighlight) + snapshot.focusItems.filter { !$0.isHighlight }
        for item in ordered where focusRect(for: item).insetBy(dx: 0, dy: -M.blockInset).contains(point) {
            return item
        }
        return nil
    }

    func annotateItem(at point: CGPoint) -> TimelineAnnotateItem? {
        guard overlayLaneRect(.annotate).contains(point) else { return nil }
        for item in orderedAnnotateItems.reversed() where annotateRect(for: item).insetBy(dx: 0, dy: -1).contains(point) {
            return item
        }
        return nil
    }

    private func dragMode(for point: CGPoint, blockStart: TimeInterval, blockEnd: TimeInterval) -> TimelineBlockDragMode {
        TimelineLaneMath.dragMode(localX: point.x - x(forOutputTime: blockStart),
                                  blockWidth: blockWidth(start: blockStart, end: blockEnd))
    }

    /// Whether a one-finger drag starting at `point` belongs to the timeline
    /// (block move/resize, clip edits, chips, the ruler scrub) rather than
    /// the scroll view. Empty lane space scrolls.
    func ownsDrag(startingAt point: CGPoint) -> Bool {
        guard snapshot.outputDuration > 0 else { return false }
        if point.y < M.videoLaneY { return true }                       // ruler scrub
        if let model = videoModel, videoLaneRect.contains(point) {
            if snapshot.sliceArmed { return true }
            return videoDragKind(at: point, model: model) != nil
        }
        if let model = voiceModel, voiceLaneRect.contains(point) {
            return voiceClipItem(at: point, model: model) != nil
        }
        if let chip = introChipRect, effectItem(at: point) == nil, chip.insetBy(dx: -4, dy: 0).contains(point) { return true }
        if let chip = curtainChipRect, effectItem(at: point) == nil, chip.insetBy(dx: -4, dy: 0).contains(point) { return true }
        return effectItem(at: point) != nil || focusItem(at: point) != nil || annotateItem(at: point) != nil
    }

    /// The long-press target — the Mac's right-click resolution order.
    func hit(at point: CGPoint) -> StudioTimelineHit {
        guard snapshot.outputDuration > 0 else { return .none }
        if let model = videoModel, videoLaneRect.contains(point) {
            return videoSegment(at: point, model: model).map { .videoSegment($0) } ?? .none
        }
        if let model = voiceModel, voiceLaneRect.contains(point) {
            return voiceClipItem(at: point, model: model).map { .voiceClip($0) } ?? .none
        }
        if let chip = introChipRect, effectItem(at: point) == nil, chip.contains(point) { return .introChip }
        if let chip = curtainChipRect, effectItem(at: point) == nil, chip.contains(point) { return .curtainChip }
        if let item = effectItem(at: point) { return .effect(item) }
        if let item = focusItem(at: point) { return .focus(item) }
        if let item = annotateItem(at: point) { return .annotate(item) }
        let time = outputTime(atX: point.x)
        if overlayLaneRect(.annotate).contains(point) { return .emptyAnnotate(time) }
        if overlayLaneRect(.effects).contains(point) { return .emptyEffects(time) }
        if overlayLaneRect(.focus).contains(point) { return .emptyFocus(time) }
        return .none
    }

    // MARK: - Press machine (port of the Mac canvas's mouse machine)

    /// A tap: press and release on the same point (select, seek, open a chip,
    /// slice, toggle mute — exactly the Mac's click).
    func tap(at point: CGPoint) {
        pressBegan(at: point)
        pressEnded(at: point)
    }

    func pressBegan(at point: CGPoint) {
        guard snapshot.outputDuration > 0 else { return }
        openLane(forPressAt: point)

        if snapshot.sliceArmed, videoModel != nil, videoLaneRect.contains(point) {
            pressState = .slicing
            return
        }
        if let model = videoModel, videoPressBegan(at: point, model: model) {
            pressState = .video
            return
        }
        if let model = voiceModel, voiceLaneRect.contains(point) {
            pressState = voicePressBegan(at: point, model: model) ? .voice : .scrubbing
            return
        }
        if let chip = introChipRect, effectItem(at: point) == nil, chip.insetBy(dx: -4, dy: 0).contains(point) {
            if abs(point.x - chip.maxX) <= 6 {
                pressState = .introEdge
                introDragInitialSpan = (snapshot.introChipStart, snapshot.introChipEnd ?? snapshot.introChipStart)
                return
            }
            if chip.contains(point) {
                pressState = .introMove(downX: point.x, initialStart: snapshot.introChipStart, didDrag: false)
                introDragInitialSpan = (snapshot.introChipStart, snapshot.introChipEnd ?? snapshot.introChipStart)
                return
            }
        }
        if let chip = curtainChipRect, effectItem(at: point) == nil, chip.insetBy(dx: -4, dy: 0).contains(point) {
            if abs(point.x - chip.maxX) <= 6 {
                pressState = .curtainEdge
                curtainDragInitialSpan = (snapshot.curtainChipStart, snapshot.curtainChipEnd ?? snapshot.curtainChipStart)
                return
            }
            if chip.contains(point) {
                pressState = .curtainMove(downX: point.x, initialStart: snapshot.curtainChipStart, didDrag: false)
                curtainDragInitialSpan = (snapshot.curtainChipStart, snapshot.curtainChipEnd ?? snapshot.curtainChipStart)
                return
            }
        }
        if let item = effectItem(at: point) {
            if !isSelected(item) { callbacks?.selectEffect(item.zoomID, item.tiltID) }
            pressState = .draggingBlock(TimelineLaneMath.effectDrag(
                item, mode: dragMode(for: point, blockStart: item.startTime, blockEnd: item.endTime),
                at: point, in: snapshot))
            return
        }
        if let item = focusItem(at: point) {
            if !item.isSelected { callbacks?.selectFocus(item.id, item.isHighlight) }
            pressState = .draggingBlock(TimelineLaneMath.focusDrag(
                item, mode: dragMode(for: point, blockStart: item.startTime, blockEnd: item.endTime),
                at: point, in: snapshot))
            return
        }
        if let item = annotateItem(at: point) {
            if !item.isSelected { callbacks?.selectAnnotation(item.id) }
            pressState = .draggingBlock(TimelineLaneMath.annotateDrag(
                item, mode: dragMode(for: point, blockStart: item.startTime, blockEnd: item.endTime),
                at: point, in: snapshot))
            return
        }
        // Empty lane areas and the ruler: clear that lane's selection, scrub.
        if overlayLaneRect(.effects).contains(point) {
            callbacks?.selectEffect(nil, nil)
            pressState = .scrubbing
        } else if overlayLaneRect(.focus).contains(point) {
            callbacks?.selectFocus(nil, false)
            pressState = .scrubbing
        } else if overlayLaneRect(.annotate).contains(point) {
            callbacks?.selectAnnotation(nil)
            pressState = .scrubbing
        } else if point.y < M.videoLaneY {
            pressState = .scrubbing
        }
        if case .scrubbing = pressState { overlay.isScrubbing = true }
    }

    func pressMoved(to point: CGPoint) {
        switch pressState {
        case .idle:
            break
        case .introEdge:
            callbacks?.resizeIntro(TimelineLaneMath.chipResizedEnd(
                proposedEnd: outputTime(atX: point.x), chipStart: snapshot.introChipStart,
                blockers: TimelineLaneMath.introBlockers(initial: introDragInitialSpan, in: snapshot)))
        case .introMove(let downX, let initialStart, var didDrag):
            let dx = point.x - downX
            if !didDrag, abs(dx) >= M.dragThreshold { didDrag = true }
            pressState = .introMove(downX: downX, initialStart: initialStart, didDrag: didDrag)
            if didDrag {
                let dt = TimeInterval(dx / max(1, trackWidth)) * snapshot.outputDuration
                let duration = (snapshot.introChipEnd ?? initialStart) - snapshot.introChipStart
                callbacks?.moveIntro(TimelineLaneMath.chipMovedStart(
                    initialStart: initialStart, dt: dt, duration: duration, outputDuration: snapshot.outputDuration,
                    blockers: TimelineLaneMath.introBlockers(initial: introDragInitialSpan, in: snapshot)))
            }
        case .curtainEdge:
            callbacks?.resizeCurtain(TimelineLaneMath.chipResizedEnd(
                proposedEnd: outputTime(atX: point.x), chipStart: snapshot.curtainChipStart,
                blockers: TimelineLaneMath.curtainBlockers(initial: curtainDragInitialSpan, in: snapshot)))
        case .curtainMove(let downX, let initialStart, var didDrag):
            let dx = point.x - downX
            if !didDrag, abs(dx) >= M.dragThreshold { didDrag = true }
            pressState = .curtainMove(downX: downX, initialStart: initialStart, didDrag: didDrag)
            if didDrag {
                let dt = TimeInterval(dx / max(1, trackWidth)) * snapshot.outputDuration
                let duration = (snapshot.curtainChipEnd ?? initialStart) - snapshot.curtainChipStart
                callbacks?.moveCurtain(TimelineLaneMath.chipMovedStart(
                    initialStart: initialStart, dt: dt, duration: duration, outputDuration: snapshot.outputDuration,
                    blockers: TimelineLaneMath.curtainBlockers(initial: curtainDragInitialSpan, in: snapshot)))
            }
        case .video:
            videoPressMoved(to: point)
        case .voice:
            voicePressMoved(to: point)
        case .slicing:
            sliceHoverX = sliceTarget(at: point)?.x
            setNeedsDisplay()
        case .scrubbing:
            callbacks?.scrub(point.x)
        case .draggingBlock(var drag):
            drag.translationX = point.x - drag.startPoint.x
            let dy = point.y - drag.startPoint.y
            if !drag.didDrag, sqrt(drag.translationX * drag.translationX + dy * dy) >= M.dragThreshold {
                drag.didDrag = true
            }
            pressState = .draggingBlock(drag)
            snapGuideTime = TimelineLaneMath.snapIndicator(
                for: drag, outputDuration: snapshot.outputDuration, trackWidth: trackWidth)
            setNeedsDisplay()
            refreshSelectionRing(animated: false)
        }
    }

    func pressEnded(at point: CGPoint) {
        defer {
            pressState = .idle
            introDragInitialSpan = nil
            curtainDragInitialSpan = nil
        }
        switch pressState {
        case .idle, .introEdge, .curtainEdge:
            break
        case .introMove(_, _, let didDrag):
            if !didDrag { callbacks?.openIntro() }
        case .curtainMove(_, _, let didDrag):
            if !didDrag { callbacks?.openCurtain() }
        case .video:
            if let model = videoModel { videoPressEnded(at: point, model: model) }
        case .voice:
            if let model = voiceModel { voicePressEnded(at: point, model: model) }
        case .slicing:
            placeSlice(at: point)
        case .scrubbing:
            callbacks?.seek(point.x)
            overlay.isScrubbing = false
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
                case .effect(let item): callbacks?.selectEffect(item.zoomID, item.tiltID)
                case .focus(let item): callbacks?.selectFocus(item.id, item.isHighlight)
                case .annotate(let item): callbacks?.selectAnnotation(item.id)
                }
            }
            snapGuideTime = nil
            setNeedsDisplay()
        }
    }

    /// A gesture the system took away (a scroll won, the app went inactive):
    /// drop the press without committing.
    func pressCancelled() {
        if case .scrubbing = pressState { overlay.isScrubbing = false }
        pressState = .idle
        videoDrag = nil
        videoPendingDeselect = false
        voiceDrag = nil
        snapGuideTime = nil
        sliceHoverX = nil
        setNeedsDisplay()
        refreshSelectionRing(animated: false)
    }

    var isPressActive: Bool {
        if case .idle = pressState { return false }
        return true
    }

    // MARK: - Playhead scrub (the ruler handle)

    func beginPlayheadScrub(atX x: CGFloat) {
        overlay.isScrubbing = true
        callbacks?.scrub(x)
    }

    func continuePlayheadScrub(atX x: CGFloat) { callbacks?.scrub(x) }

    func endPlayheadScrub(atX x: CGFloat) {
        callbacks?.seek(x)
        overlay.isScrubbing = false
    }

    // MARK: - Slice tool

    var sliceHoverX: CGFloat?

    func sliceTarget(at point: CGPoint) -> VideoSliceMath.Target? {
        guard snapshot.sliceArmed, let model = videoModel, trackWidth > 0, snapshot.outputDuration > 0 else { return nil }
        let target = VideoSliceMath.resolvedTarget(
            atX: point.x, trackWidth: trackWidth, outputDuration: snapshot.outputDuration,
            playheadOutputTime: snapshot.playheadOutputTime)
        guard VideoSliceMath.isSliceable(
            target.outputTime, trimStartOutput: snapshot.trimStartOutput,
            trimEndOutput: snapshot.trimEndOutput, clipSpans: model.clipSpans) else { return nil }
        return target
    }

    private func placeSlice(at point: CGPoint) {
        sliceHoverX = nil
        guard let target = sliceTarget(at: point) else { setNeedsDisplay(); return }
        videoCallbacks?.sliceAt(target.outputTime)
        setNeedsDisplay()
    }

    // MARK: - Selection ring (glides between blocks)

    /// Key + rect + radius of whatever is selected right now, at the current
    /// geometry (mid-drag and mid-accordion included).
    func selectedBlockFrame() -> (key: String, rect: CGRect, radius: CGFloat)? {
        if let item = snapshot.effectItems.first(where: isSelected) {
            let rect = dragDisplayRect(forKey: effectKey(item)) ?? effectRect(for: item)
            return (effectKey(item), rect, M.blockCornerRadius)
        }
        if snapshot.introChipSelected, let rect = introChipRect { return ("intro-chip", rect, M.blockCornerRadius) }
        if snapshot.curtainChipSelected, let rect = curtainChipRect { return ("curtain-chip", rect, M.blockCornerRadius) }
        if let item = snapshot.focusItems.first(where: \.isSelected) {
            return (focusKey(item), dragDisplayRect(forKey: focusKey(item)) ?? focusRect(for: item), M.blockCornerRadius)
        }
        if let item = snapshot.annotateItems.first(where: \.isSelected) {
            return (annotateKey(item), dragDisplayRect(forKey: annotateKey(item)) ?? annotateRect(for: item), M.blockCornerRadius)
        }
        if let model = videoModel, let clip = model.clips.first(where: \.isSelected) {
            let block = videoBlockGeometry(model)
            return ("v:\(clip.id.uuidString)", videoClipRect(videoDisplayClip(clip.ref, model: model), model: model, block: block), 8)
        }
        if let model = voiceModel, let clip = model.clips.first(where: \.isSelected) {
            return ("o:\(clip.id.uuidString)", voiceClipRect(clip, model: model), StudioTimelineCanvasView.voiceCornerRadius)
        }
        return nil
    }

    /// Re-aims the outline. A NEW selection glides there on the house spring
    /// (`CCMotion.Spring.smooth`: critically damped, 0.42 s response) from
    /// wherever the outline visibly is; the glide RETARGETS every frame, so a
    /// block that moves while it glides (the lane a tap opens grows under it)
    /// is tracked, not jumped. The same selection moving with its block
    /// (drag, accordion, zoom) simply follows.
    func refreshSelectionRing(animated: Bool) {
        guard let frame = selectedBlockFrame() else {
            if ringKey != nil {
                ringKey = nil
                ringRect = nil
                stopGlide()
                CCMotion.fade(selectionRing, keyPath: "opacity", to: Float(0), duration: 0.12)
            }
            return
        }
        let isNew = frame.key != ringKey
        let wasHidden = ringKey == nil
        ringKey = frame.key
        ringRadius = frame.radius
        var glide = animated && isNew && !wasHidden && window != nil && !CCMotion.reduceMotion
        #if DEBUG
        if probeSnapSelection { glide = false }
        #endif
        if glide, let shown = ringRect {
            glideFrom = shown
            glideBegan = CACurrentMediaTime()
            startGlide()
        } else if isNew {
            stopGlide()
        }
        applyRing(target: frame.rect)
        if wasHidden {
            CCMotion.fade(selectionRing, keyPath: "opacity", to: Float(1), duration: 0.12)
        }
    }

    private var ringRadius: CGFloat = M.blockCornerRadius
    private var glideFrom: CGRect?
    private var glideBegan: CFTimeInterval = 0
    private var glideLink: CADisplayLink?
    /// Settled after this long (x(t) > 0.998 for the smooth spring).
    private var glideDuration: TimeInterval { CCMotion.paced(0.6) }

    /// The smooth spring's progress at `t` seconds: critically damped,
    /// ω = 2π / response (CCMotion.Spring.smooth).
    private func glideProgress(_ t: TimeInterval) -> CGFloat {
        let omega = 2 * Double.pi / (Double(CCMotion.Spring.smooth.response) / Double(CCMotion.pace.rawValue))
        return CGFloat(1 - (1 + omega * t) * exp(-omega * t))
    }

    /// Where the outline is drawn this frame: the target, or the glide's
    /// interpolation toward it.
    private func applyRing(target: CGRect) {
        var shown = target
        if let from = glideFrom {
            let t = CACurrentMediaTime() - glideBegan
            if t >= glideDuration {
                stopGlide()
            } else {
                let p = glideProgress(t)
                shown = CGRect(x: from.minX + (target.minX - from.minX) * p,
                               y: from.minY + (target.minY - from.minY) * p,
                               width: from.width + (target.width - from.width) * p,
                               height: from.height + (target.height - from.height) * p)
            }
        }
        ringRect = shown
        let inner = shown.insetBy(dx: 1, dy: 1)
        let radius = max(0, min(ringRadius - 1, inner.width / 2, inner.height / 2))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selectionRing.path = UIBezierPath(roundedRect: inner, cornerRadius: radius).cgPath
        CATransaction.commit()
    }

    private func startGlide() {
        guard glideLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(glideStep))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        glideLink = link
    }

    private func stopGlide() {
        glideFrom = nil
        glideLink?.invalidate()
        glideLink = nil
    }

    @objc private func glideStep() {
        guard let frame = selectedBlockFrame() else { stopGlide(); return }
        applyRing(target: frame.rect)
    }

    /// Harness seam: the outline's drawn rect right now, and whether it is
    /// mid-glide.
    var probeRing: (rect: CGRect?, gliding: Bool) { (ringRect, glideFrom != nil) }

    /// The dragged block's display rect, if `key` is mid-drag — move follows
    /// the finger with a pixel clamp, resize shows the resolved edge live
    /// (the Mac's rule).
    private func dragDisplayRect(forKey key: String) -> CGRect? {
        guard let drag = activeDrag else { return nil }
        let (dragKey, lane, row): (String, TimelineOverlayLane, Int)
        switch drag.target {
        case .effect(let item):
            (dragKey, lane, row) = (effectKey(item), .effects, effectsRows()[TimelineLaneMath.effectsSpanKey(item)] ?? 0)
        case .focus(let item): (dragKey, lane, row) = (focusKey(item), .focus, 0)
        case .annotate(let item): (dragKey, lane, row) = (annotateKey(item), .annotate, 0)
        }
        guard dragKey == key else { return nil }
        switch drag.mode {
        case .move:
            let committed = blockRect(start: drag.initialStart, end: drag.initialEnd, lane: lane, row: row)
            let maxX = max(0, trackWidth - committed.width)
            let clampedX = min(max(committed.minX + drag.translationX, 0), maxX)
            return committed.offsetBy(dx: clampedX - committed.minX, dy: 0)
        case .resizeLeft, .resizeRight:
            let resolved = resolvedTimes(for: drag)
            return blockRect(start: resolved.start, end: resolved.end, lane: lane, row: row)
        }
    }

    private func isDimmed(_ key: String) -> Bool {
        guard let drag = activeDrag, drag.didDrag else { return false }
        switch drag.target {
        case .effect(let item): return effectKey(item) == key
        case .focus(let item): return focusKey(item) == key
        case .annotate(let item): return annotateKey(item) == key
        }
    }

    // MARK: - Drawing

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        drawRuler(in: context)
        drawSeparators(in: context)
        if let model = videoModel { drawVideoLane(in: context, model: model) }
        if let model = voiceModel { drawVoiceLane(in: context, model: model) }
        drawEffectsLane(in: context)
        drawFocusLane(in: context)
        drawAnnotateLane(in: context)
        drawEmptyLaneHints(in: context)
        drawSliceIndicator(in: context)
    }

    private func drawSeparators(in context: CGContext) {
        context.setFillColor(CCTheme.color.border.resolvedColor(with: traitCollection).cgColor)
        let layout = laneLayout
        for y in [M.voiceLaneY - M.trackSpacing, M.effectsLaneY - M.trackSpacing,
                  layout.laneY(.focus) - M.trackSpacing, layout.laneY(.annotate) - M.trackSpacing] {
            context.fill(CGRect(x: 0, y: y, width: trackWidth, height: 1))
        }
    }

    private static let rulerLabelFont = UIFont.monospacedSystemFont(ofSize: 9, weight: .semibold)

    private func drawRuler(in context: CGContext) {
        let duration = snapshot.outputDuration
        guard duration > 0, trackWidth > 0 else { return }
        let height = M.rulerHeight
        let ink = StudioTimelineStyle.ink(traitCollection)
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
        let dim: CGFloat = snapshot.dimmedRuler ? 0.65 : 1.0
        let baseline = height - 1
        context.setStrokeColor(ink.withAlphaComponent(0.12 * dim).cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: 0, y: baseline))
        context.addLine(to: CGPoint(x: trackWidth, y: baseline))
        context.strokePath()

        context.setStrokeColor(ink.withAlphaComponent(0.22 * dim).cgColor)
        var t: TimeInterval = 0
        while t <= duration {
            let tickX = CGFloat(t / duration) * trackWidth
            let isMajor = (t / majorInterval).remainder(dividingBy: 1).magnitude < 0.01
            if !isMajor {
                context.setLineWidth(0.5)
                context.move(to: CGPoint(x: tickX, y: baseline))
                context.addLine(to: CGPoint(x: tickX, y: baseline - height * 0.22))
                context.strokePath()
            }
            t += minorInterval
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.rulerLabelFont,
            .foregroundColor: CCTheme.color.mutedForeground.resolvedColor(with: traitCollection),
        ]
        t = 0
        while t <= duration {
            let tickX = CGFloat(t / duration) * trackWidth
            context.setLineWidth(1)
            context.move(to: CGPoint(x: tickX, y: baseline))
            context.addLine(to: CGPoint(x: tickX, y: baseline - height * 0.46))
            context.strokePath()
            let text = NSAttributedString(string: Self.formatRulerTime(t, showsFraction: majorInterval < 1), attributes: attributes)
            let size = text.size()
            let centerX = min(max(size.width / 2 + 2, tickX), trackWidth - size.width / 2 - 2)
            text.draw(at: CGPoint(x: centerX - size.width / 2, y: 6))
            t += majorInterval
        }
    }

    /// The Mac ruler's label format.
    static func formatRulerTime(_ seconds: TimeInterval, showsFraction: Bool) -> String {
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if showsFraction {
            let tenths = Int(((seconds - seconds.rounded(.down)) * 10).rounded())
            if tenths > 0 && tenths < 10 { return String(format: "%d:%02d.%d", m, s, tenths) }
        }
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    private func drawBlockContent(in context: CGContext, rect: CGRect, _ body: () -> Void) {
        let alpha = StudioTimelineStyle.contentAlpha(forBlockHeight: rect.height)
        guard alpha > 0.01 else { return }
        context.saveGState()
        context.setAlpha(alpha)
        body()
        context.restoreGState()
    }

    private func drawEffectsLane(in context: CGContext) {
        if let rect = introChipRect {
            drawChip(in: context, rect: rect, icon: snapshot.introChipIcon, label: snapshot.introChipLabel,
                     isSelected: snapshot.introChipSelected)
        }
        if let rect = curtainChipRect {
            drawChip(in: context, rect: rect, icon: "book.pages", label: "Curtain", isSelected: snapshot.curtainChipSelected)
        }
        for item in snapshot.effectItems {
            let key = effectKey(item)
            let rect = dragDisplayRect(forKey: key) ?? effectRect(for: item)
            context.saveGState()
            if isDimmed(key) { context.setAlpha(0.8) }
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            drawBlockSurface(in: context, rect: rect, top: StudioTimelineStyle.effectBlockTop,
                             bottom: StudioTimelineStyle.effectBlockBottom, isSelected: isSelected(item))
            drawBlockContent(in: context, rect: rect) {
                drawEffectLabel(for: item, in: rect)
                drawGrips(in: context, rect: rect, visible: isSelected(item))
            }
            context.endTransparencyLayer()
            context.restoreGState()
        }
    }

    private func drawChip(in context: CGContext, rect: CGRect, icon: String, label: String, isSelected: Bool) {
        context.saveGState()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        drawBlockSurface(in: context, rect: rect, top: StudioTimelineStyle.effectBlockTop,
                         bottom: StudioTimelineStyle.effectBlockBottom, isSelected: isSelected)
        drawBlockContent(in: context, rect: rect) {
            drawIconLabel(icon: icon, text: rect.width > 52 ? label : nil, in: rect, separator: "  ",
                          font: .systemFont(ofSize: 10, weight: .semibold))
            drawGrips(in: context, rect: rect, visible: isSelected)
        }
        context.endTransparencyLayer()
        context.restoreGState()
    }

    private func drawFocusLane(in context: CGContext) {
        let ordered = snapshot.focusItems.filter { !$0.isHighlight } + snapshot.focusItems.filter(\.isHighlight)
        for item in ordered {
            let key = focusKey(item)
            let rect = dragDisplayRect(forKey: key) ?? focusRect(for: item)
            context.saveGState()
            if isDimmed(key) { context.setAlpha(0.8) }
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            drawBlockSurface(
                in: context, rect: rect,
                top: item.isHighlight ? StudioTimelineStyle.highlightBlockTop : StudioTimelineStyle.blurBlockTop,
                bottom: item.isHighlight ? StudioTimelineStyle.highlightBlockBottom : StudioTimelineStyle.blurBlockBottom,
                isSelected: item.isSelected)
            drawBlockContent(in: context, rect: rect) {
                drawCenteredLabel(item.label, in: rect.insetBy(dx: 8, dy: 0))
                drawGrips(in: context, rect: rect, visible: item.isSelected)
            }
            context.endTransparencyLayer()
            context.restoreGState()
        }
    }

    private func drawAnnotateLane(in context: CGContext) {
        for item in orderedAnnotateItems {
            let key = annotateKey(item)
            let rect = dragDisplayRect(forKey: key) ?? annotateRect(for: item)
            context.saveGState()
            if isDimmed(key) { context.setAlpha(0.8) }
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            drawBlockSurface(in: context, rect: rect, top: StudioTimelineStyle.annotateBlockTop,
                             bottom: StudioTimelineStyle.annotateBlockBottom, isSelected: item.isSelected)
            drawBlockContent(in: context, rect: rect) {
                if rect.height >= 14 {
                    drawIconLabel(icon: item.icon, text: rect.width > 58 ? item.label : nil, in: rect,
                                  separator: "\u{2002}", font: .systemFont(ofSize: 10, weight: .semibold))
                }
                if rect.height >= 16 { drawGrips(in: context, rect: rect, visible: item.isSelected) }
            }
            context.endTransparencyLayer()
            context.restoreGState()
        }
    }

    private func drawIconLabel(icon: String?, text: String?, in rect: CGRect, separator: String, font: UIFont) {
        let content = NSMutableAttributedString()
        if let icon, let image = StudioTimelineStyle.symbol(icon, pointSize: 9, weight: .semibold,
                                                            color: StudioTimelineStyle.blockContent) {
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = CGRect(x: 0, y: -2, width: image.size.width, height: image.size.height)
            content.append(NSAttributedString(attachment: attachment))
        }
        if let text {
            if content.length > 0 { content.append(NSAttributedString(string: separator)) }
            content.append(NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: StudioTimelineStyle.blockContent,
            ]))
        }
        let size = content.size()
        guard size.width > 0 else { return }
        content.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }

    private func drawEffectLabel(for item: EffectBlockItem, in rect: CGRect) {
        let content = NSMutableAttributedString()
        for (present, symbol) in [(item.hasZoom, "plus.magnifyingglass"), (item.hasTilt, "rotate.3d"),
                                  (item.hasSlide, "arrow.up.to.line")] where present {
            if let image = StudioTimelineStyle.symbol(symbol, pointSize: 9, weight: .semibold,
                                                      color: StudioTimelineStyle.blockContent) {
                if content.length > 0 { content.append(NSAttributedString(string: "\u{2002}")) }
                let attachment = NSTextAttachment()
                attachment.image = image
                attachment.bounds = CGRect(x: 0, y: -2, width: image.size.width, height: image.size.height)
                content.append(NSAttributedString(attachment: attachment))
            }
        }
        if rect.width > 58 {
            let zoomLabel = String(format: "%.1fx", item.zoomLevel ?? 1)
            let tiltLabel = String(format: "%.0f°", item.dominantAngle)
            let value: String
            switch (item.hasZoom, item.hasTilt) {
            case (true, true): value = "\(zoomLabel) · \(tiltLabel)"
            case (true, false): value = zoomLabel
            case (false, true): value = tiltLabel
            case (false, false): value = ""
            }
            if content.length > 0 { content.append(NSAttributedString(string: "\u{2002}")) }
            content.append(NSAttributedString(string: value, attributes: [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: StudioTimelineStyle.blockContent,
            ]))
        }
        let size = content.size()
        guard size.width > 0 else { return }
        content.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }

    private func drawCenteredLabel(_ label: String, in rect: CGRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let text = NSAttributedString(string: label, attributes: [
            .font: UIFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: StudioTimelineStyle.blockContent,
            .paragraphStyle: paragraph,
        ])
        let height = text.size().height
        text.draw(in: CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height))
    }

    /// CG port of the Mac's block surface: soft near-flat gradient, a hairline
    /// that follows the corners, a soft contact shadow. (The selection outline
    /// is the gliding `selectionRing` layer on iOS, not drawn here.)
    private func drawBlockSurface(in context: CGContext, rect: CGRect, top: UIColor, bottom: UIColor, isSelected: Bool) {
        let brightness: CGFloat = isSelected ? 0.06 : 0
        let topColor = StudioTimelineStyle.brightened(top, by: brightness + 0.025)
        let bottomColor = StudioTimelineStyle.brightened(bottom, by: brightness - 0.015)
        let radius = min(M.blockCornerRadius, rect.width / 2, rect.height / 2)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let dark = traitCollection.userInterfaceStyle == .dark
        context.saveGState()
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 1), blur: 4,
                          color: UIColor.black.withAlphaComponent(dark ? 0.28 : 0.10).cgColor)
        context.addPath(path)
        context.setFillColor(bottomColor.cgColor)
        context.fillPath()
        context.restoreGState()
        context.saveGState()
        context.addPath(path)
        context.clip()
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                     colors: [topColor.cgColor, bottomColor.cgColor] as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.minY),
                                       end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
        }
        context.addPath(path)
        context.setStrokeColor(UIColor.black.withAlphaComponent(dark ? 0.18 : 0.08).cgColor)
        context.setLineWidth(1)
        context.strokePath()
        context.restoreGState()
        context.restoreGState()
    }

    private func drawGrips(in context: CGContext, rect: CGRect, visible: Bool) {
        guard visible else { return }
        context.setFillColor(StudioTimelineStyle.blockGrip.cgColor)
        let y = rect.midY - 6.5
        for edgeX in [rect.minX + 5, rect.maxX - 5 - 6] {
            for i in 0..<2 {
                let grip = CGRect(x: edgeX + CGFloat(i) * 4, y: y, width: 2, height: 13)
                context.addPath(CGPath(roundedRect: grip, cornerWidth: 1, cornerHeight: 1, transform: nil))
            }
        }
        context.fillPath()
    }

    /// The "+" hint on an OPEN empty lane (the Mac shows it on hover).
    private func drawEmptyLaneHints(in context: CGContext) {
        let layout = laneLayout
        let lanes: [(TimelineOverlayLane, Bool)] = [
            (.effects, snapshot.effectItems.isEmpty && snapshot.introChipEnd == nil && snapshot.curtainChipEnd == nil),
            (.focus, snapshot.focusItems.isEmpty),
            (.annotate, snapshot.annotateItems.isEmpty),
        ]
        for (lane, isEmpty) in lanes where isEmpty && laneAccordion.target == lane {
            let alpha = StudioTimelineStyle.contentAlpha(forBlockHeight: layout.rowHeight(lane) - M.blockInset * 2)
            guard alpha > 0.01,
                  let image = StudioTimelineStyle.symbol("plus", pointSize: 14, weight: .semibold,
                                                         color: StudioTimelineStyle.ink(traitCollection).withAlphaComponent(0.25))
            else { continue }
            let band = CGRect(x: 0, y: layout.laneY(lane), width: trackWidth, height: layout.rowHeight(lane))
            image.draw(in: CGRect(x: band.midX - image.size.width / 2, y: band.midY - image.size.height / 2,
                                  width: image.size.width, height: image.size.height),
                       blendMode: .normal, alpha: alpha)
        }
    }

    private func drawSliceIndicator(in context: CGContext) {
        guard snapshot.sliceArmed, let x = sliceHoverX else { return }
        context.setFillColor(UIColor.systemRed.cgColor)
        context.fill(CGRect(x: x - 1, y: M.videoLaneY - 4, width: 2, height: M.trackHeight + 8))
    }
}

// MARK: - Playhead + snap guide

/// Draws the playhead (cyan line + ringed diamond on the ruler's edge), the
/// scrub readout and the yellow snap guide above every lane — the Mac
/// overlay's drawing. Touch passes through it.
@MainActor
final class StudioTimelinePlayheadOverlay: UIView {
    private typealias M = TimelineCanvasMetrics
    weak var canvas: StudioTimelineCanvasView?
    var snapshot: TimelineCanvasSnapshot? { didSet { setNeedsDisplay() } }
    var snapGuideTime: TimeInterval? { didSet { setNeedsDisplay() } }
    var isScrubbing = false { didSet { if isScrubbing != oldValue { setNeedsDisplay() } } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var playheadX: CGFloat {
        guard let snapshot, snapshot.outputDuration > 0, bounds.width > 0 else { return 0 }
        return bounds.width * CGFloat(snapshot.playheadOutputTime / snapshot.outputDuration)
    }

    override func draw(_ rect: CGRect) {
        guard let snapshot, snapshot.outputDuration > 0, let context = UIGraphicsGetCurrentContext() else { return }
        let tracksBottom = canvas?.tracksBottom ?? M.tracksBottom
        if let snapTime = snapGuideTime {
            let snapX = bounds.width * CGFloat(min(max(snapTime / snapshot.outputDuration, 0), 1))
            context.setFillColor(StudioTimelineStyle.snapGuide.cgColor)
            context.fill(CGRect(x: snapX - 0.75, y: 0, width: 1.5, height: tracksBottom))
            context.move(to: CGPoint(x: snapX - 4.5, y: 0))
            context.addLine(to: CGPoint(x: snapX + 4.5, y: 0))
            context.addLine(to: CGPoint(x: snapX, y: 6))
            context.closePath()
            context.fillPath()
        }
        if snapshot.timelessVideo && !isScrubbing { return }
        let x = playheadX
        context.setFillColor((snapshot.playheadIsRed ? UIColor.systemRed : StudioTimelineStyle.playhead).cgColor)
        context.fill(CGRect(x: x - 1, y: 0, width: 2, height: tracksBottom))
        let cy = M.rulerHeight
        let diamond = CGMutablePath()
        diamond.move(to: CGPoint(x: x, y: cy - 8))
        diamond.addLine(to: CGPoint(x: x + 8, y: cy))
        diamond.addLine(to: CGPoint(x: x, y: cy + 8))
        diamond.addLine(to: CGPoint(x: x - 8, y: cy))
        diamond.closeSubpath()
        context.addPath(diamond)
        context.fillPath()
        context.addPath(diamond)
        context.setStrokeColor(UIColor.white.withAlphaComponent(0.9).cgColor)
        context.setLineWidth(1)
        context.strokePath()
        if isScrubbing { drawScrubBubble(in: context, text: snapshot.scrubLabel, atX: x) }
    }

    private func drawScrubBubble(in context: CGContext, text: String, atX x: CGFloat) {
        let attributed = NSAttributedString(string: text, attributes: [
            .font: UIFont.monospacedSystemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: CCTheme.color.foreground.resolvedColor(with: traitCollection),
        ])
        let size = attributed.size()
        var capsule = CGRect(x: x + 8, y: -1, width: size.width + 14, height: size.height + 6)
        if capsule.maxX > bounds.width { capsule.origin.x = x - 8 - capsule.width }
        let path = CGPath(roundedRect: capsule, cornerWidth: capsule.height / 2, cornerHeight: capsule.height / 2, transform: nil)
        context.addPath(path)
        context.setFillColor(CCTheme.color.elevated.resolvedColor(with: traitCollection).cgColor)
        context.fillPath()
        context.addPath(path)
        context.setStrokeColor(CCTheme.color.border.resolvedColor(with: traitCollection).cgColor)
        context.setLineWidth(1)
        context.strokePath()
        attributed.draw(at: CGPoint(x: capsule.minX + 7, y: capsule.minY + 3))
    }
}
