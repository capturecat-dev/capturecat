import AppKit

// MARK: - Snapshot (one-way data in)

/// One block on the FOCUS lane, already mapped into output time.
struct TimelineFocusItem: Equatable {
    var id: UUID
    var isHighlight: Bool
    var startTime: TimeInterval
    var endTime: TimeInterval
    var label: String
    var isSelected: Bool
}

/// One block on the ANNOTATE lane, already mapped into output time.
struct TimelineAnnotateItem: Equatable {
    var id: UUID
    var startTime: TimeInterval
    var endTime: TimeInterval
    /// Short type label ("Text", "Tap"…) — the block caption.
    var label: String
    /// SF Symbol name for the type glyph.
    var icon: String
    var isSelected: Bool
}

/// Immutable value the AppKit canvas renders from. All times are OUTPUT time
/// (post speed-map); the SwiftUI side converts to source time at every
/// callback boundary, so the canvas never touches the model or the time map.
struct TimelineCanvasSnapshot: Equatable {
    var outputDuration: TimeInterval
    var playheadOutputTime: TimeInterval
    /// Slice hover snapped onto the playhead — line turns red, same as SwiftUI.
    var playheadIsRed: Bool
    /// The playhead grab strip is disabled while the slice tool owns the lane.
    var playheadHitTestEnabled: Bool
    /// Pre-formatted scrub readout (e.g. "0:02.4"), computed by TimelineView.
    var scrubLabel: String
    var effectItems: [EffectBlockItem]
    /// Intro Slide chip pinned to the head of the EFFECTS lane — end time in
    /// output seconds (nil = intro off) and its label ("Intro · Bottom").
    var introChipStart: TimeInterval = 0
    var introChipEnd: TimeInterval? = nil
    var introChipSelected: Bool = false
    var introChipLabel: String = ""
    var introChipIcon: String = "arrow.up.to.line"
    /// Curtain Unveil chip on the EFFECTS lane — end time in output seconds
    /// (nil = curtain off). Label/icon are fixed ("Curtain" / book.pages).
    var curtainChipStart: TimeInterval = 0
    var curtainChipEnd: TimeInterval? = nil
    var curtainChipSelected: Bool = false
    var selectedZoomID: UUID?
    var selectedTiltID: UUID?
    var focusItems: [TimelineFocusItem]
    var annotateItems: [TimelineAnnotateItem]
    var trimStartOutput: TimeInterval
    var trimEndOutput: TimeInterval
    /// Slice tool armed — the VIDEO lane swaps its drag gestures for the
    /// crosshair cut indicator, exactly like the SwiftUI overlay did.
    var sliceArmed: Bool = false
    /// Still capture in Image treatment with NO timed effects — "there is no
    /// time". The video block reads as one full-width slab (scale is pinned to
    /// 1 by the controller), the ruler drops to a bare baseline and the
    /// playhead hides while idle — but scrubbing still works, and the line
    /// shows during the interaction. The underlying time mapping is UNCHANGED:
    /// effect blocks keep their exact positions and drag math. The moment a
    /// timed effect exists this goes false (playhead/scrub behave exactly as
    /// video; see `dimmedRuler`).
    var timelessVideo: Bool = false
    /// Still capture in Image treatment WITH timed effects: full video-style
    /// playhead and scrubbing, ruler ticks slightly dimmed (labels stay
    /// legible) as the one remaining hint of the Image treatment.
    var dimmedRuler: Bool = false
}

// MARK: - Callbacks (mutations out)

/// Every mutation routes through these closures into the SAME TimelineView
/// functions the SwiftUI lanes used, so undo registration and lane rules are
/// reused verbatim. Times passed here are OUTPUT time; the wrappers convert.
struct TimelineCanvasCallbacks {
    var scrub: (CGFloat) -> Void
    var seek: (CGFloat) -> Void
    var selectEffect: (UUID?, UUID?) -> Void
    /// Click on the Intro chip — opens the Motion pane where the entrance
    /// direction and length live.
    var openIntro: () -> Void = {}
    var deleteIntro: () -> Void = {}
    /// Live drag of the Intro chip's right edge — new END in output seconds.
    var resizeIntro: (TimeInterval) -> Void = { _ in }
    /// Live drag of the whole chip — new START in output seconds.
    var moveIntro: (TimeInterval) -> Void = { _ in }
    /// Click on the Curtain chip — opens the Effects pane.
    var openCurtain: () -> Void = {}
    var deleteCurtain: () -> Void = {}
    /// Live drag of the Curtain chip's right edge — new END in output seconds.
    var resizeCurtain: (TimeInterval) -> Void = { _ in }
    /// Live drag of the whole Curtain chip — new START in output seconds.
    var moveCurtain: (TimeInterval) -> Void = { _ in }
    var commitEffectTimes: (UUID?, UUID?, TimeInterval, TimeInterval) -> Void
    var setZoomLevel: (UUID, Double) -> Void
    var addZoomToBlock: (UUID) -> Void
    var addTiltToBlock: (UUID) -> Void
    var removeZoom: (UUID) -> Void
    var removeTilt: (UUID) -> Void
    var deleteEffectBlock: (UUID?, UUID?) -> Void
    var addZoomAt: (TimeInterval) -> Void
    var addTiltAt: (TimeInterval) -> Void
    var selectFocus: (UUID?, Bool) -> Void
    var commitFocusTimes: (UUID, Bool, TimeInterval, TimeInterval) -> Void
    var deleteFocus: (UUID, Bool) -> Void
    var addBlurAt: (TimeInterval) -> Void
    var addHighlightAt: (TimeInterval) -> Void
    var selectAnnotation: (UUID?) -> Void
    var commitAnnotationTimes: (UUID, TimeInterval, TimeInterval) -> Void
    var deleteAnnotation: (UUID) -> Void
    var addAnnotationAt: (AnnotationType, TimeInterval) -> Void
    /// Keyboard, handled natively by the canvas (it becomes first responder
    /// on click, which starves SwiftUI's .onKeyPress chain).
    var deleteSelection: () -> Void = {}
    var togglePlayback: () -> Void = {}
}

// MARK: - Shared metrics

/// Mirrors TimelineView's layout constants exactly — one source of numbers for
/// both drawing and hit testing. Flipped coordinates: y grows downward.
enum TimelineCanvasMetrics {
    static let rulerHeight: CGFloat = 22
    static let rulerBottomSpacing: CGFloat = 6
    static let trackHeight: CGFloat = 48
    static let trackSpacing: CGFloat = 4
    static let bottomInset: CGFloat = 12

    static let videoLaneY: CGFloat = rulerHeight + rulerBottomSpacing               // 28
    static let voiceLaneY: CGFloat = videoLaneY + trackHeight + trackSpacing        // 80
    static let effectsLaneY: CGFloat = voiceLaneY + trackHeight + trackSpacing      // 132
    static let focusLaneY: CGFloat = effectsLaneY + trackHeight + trackSpacing      // 184
    static let annotateLaneY: CGFloat = focusLaneY + trackHeight + trackSpacing     // 236
    static let tracksBottom: CGFloat = annotateLaneY + trackHeight                  // 284

    /// Separators sit at the top of each inter-lane gap, like the SwiftUI
    /// `.overlay(alignment: .top)` on the padded rows.
    static let separatorYs: [CGFloat] = [
        voiceLaneY - trackSpacing,
        effectsLaneY - trackSpacing,
        focusLaneY - trackSpacing,
        annotateLaneY - trackSpacing,
    ]

    /// EFFECTS sub-rows: overlapping items stack instead of hiding each
    /// other. Each extra row adds one pitch to the lane; capped so a
    /// pathological pile-up cannot swallow the timeline.
    static let subRowGap: CGFloat = 4
    static let subRowPitch: CGFloat = trackHeight + subRowGap
    static let maxEffectsRows = 3

    static let blockInset: CGFloat = 3      // TimelineBlockSurface.inset
    static let blockCornerRadius: CGFloat = 9
    static let handleWidth: CGFloat = 8
    static let minBlockWidth: CGFloat = 20
    static let minDuration: TimeInterval = 0.5
    static let dragThreshold: CGFloat = 3
    static let playheadStripHalfWidth: CGFloat = 14
}

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
    )
    var callbacks: TimelineCanvasCallbacks?

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

    private enum DragMode { case move, resizeLeft, resizeRight }

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

    private enum DragTarget {
        case effect(EffectBlockItem)
        case focus(TimelineFocusItem)
        case annotate(TimelineAnnotateItem)
    }

    private struct BlockDrag {
        var target: DragTarget
        var mode: DragMode
        var initialStart: TimeInterval
        var initialEnd: TimeInterval
        var startPoint: CGPoint
        var didDrag = false
        var translationX: CGFloat = 0
        /// Captured once at mouseDown so the whole gesture resolves against a
        /// stable set — same as the SwiftUI blocks re-deriving from drag-start.
        var snapCandidates: [TimeInterval]
        var otherSpans: [(TimeInterval, TimeInterval)]
        /// Legacy-overlap grace applies on the EFFECTS lane only.
        var usesLegacyGrace: Bool
        var minDuration: TimeInterval
    }

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

    private func laneRect(atY laneY: CGFloat) -> CGRect {
        CGRect(x: 0, y: laneY, width: trackWidth, height: M.trackHeight)
    }

    private func blockWidth(start: TimeInterval, end: TimeInterval) -> CGFloat {
        guard snapshot.outputDuration > 0 else { return M.minBlockWidth }
        return max(M.minBlockWidth, trackWidth * CGFloat((end - start) / snapshot.outputDuration))
    }

    /// Committed (model) rect for a span on a lane.
    private func blockRect(start: TimeInterval, end: TimeInterval, laneY: CGFloat) -> CGRect {
        CGRect(
            x: x(forOutputTime: start),
            y: laneY + M.blockInset,
            width: blockWidth(start: start, end: end),
            height: M.trackHeight - M.blockInset * 2
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
        snapshot.annotateItems.sorted { $0.startTime < $1.startTime }
    }

    /// Sub-row layout for concurrent annotations: greedy interval
    /// partitioning per overlap cluster, so overlapping blocks stack in
    /// slimmer rows instead of burying each other. Isolated annotations keep
    /// the full lane height.
    private var annotateRowLayout: [UUID: (row: Int, rows: Int)] {
        var layout: [UUID: (row: Int, rows: Int)] = [:]
        var rowEnds: [TimeInterval] = []
        var assignments: [(UUID, Int)] = []
        var clusterMaxEnd = -TimeInterval.infinity

        func flushCluster() {
            for (id, row) in assignments { layout[id] = (row, rowEnds.count) }
            assignments.removeAll()
            rowEnds.removeAll()
        }

        for item in orderedAnnotateItems {
            if !rowEnds.isEmpty && item.startTime >= clusterMaxEnd - 0.0001 {
                flushCluster()
            }
            if let free = rowEnds.firstIndex(where: { $0 <= item.startTime + 0.0001 }) {
                rowEnds[free] = item.endTime
                assignments.append((item.id, free))
            } else {
                rowEnds.append(item.endTime)
                assignments.append((item.id, rowEnds.count - 1))
            }
            clusterMaxEnd = max(clusterMaxEnd, item.endTime)
        }
        flushCluster()
        return layout
    }

    /// Committed rect for an annotation — full lane height when alone,
    /// its sub-row slice when overlapping others.
    private func annotateRect(for item: TimelineAnnotateItem) -> CGRect {
        let full = blockRect(start: item.startTime, end: item.endTime, laneY: annotateLaneY)
        guard let slot = annotateRowLayout[item.id], slot.rows > 1 else { return full }
        // Full-height sub-rows — the lane band grows instead of the bars
        // shrinking (annotateExtraHeight), and the timeline scrolls.
        return blockRect(
            start: item.startTime, end: item.endTime,
            laneY: annotateLaneY + CGFloat(slot.row) * M.subRowPitch
        )
    }

    private func isSelected(_ item: EffectBlockItem) -> Bool {
        if let zoomID = item.zoomID, snapshot.selectedZoomID == zoomID { return true }
        if let tiltID = item.tiltID, snapshot.selectedTiltID == tiltID { return true }
        return false
    }

    // MARK: - Snap / clamp resolution (byte-for-byte port of the block views)

    private func resolvedTimes(for drag: BlockDrag) -> (start: TimeInterval, end: TimeInterval) {
        let delta = TimeInterval(drag.translationX / max(trackWidth, 1)) * snapshot.outputDuration
        let totalDuration = snapshot.outputDuration
        let minDuration = drag.minDuration

        // Anything the block was ALREADY overlapping at drag start is exempt
        // (EFFECTS lane only) — legacy-overlap projects can be pulled apart.
        let blockers: [(TimeInterval, TimeInterval)]
        if drag.usesLegacyGrace {
            blockers = drag.otherSpans.filter { other in
                !(other.0 < drag.initialEnd - 0.0001 && other.1 > drag.initialStart + 0.0001)
            }
        } else {
            blockers = drag.otherSpans
        }

        let snapEdge: (TimeInterval, [TimeInterval]) -> TimeInterval? = { time, excludedEdges in
            let candidates = drag.snapCandidates.filter { candidate in
                !excludedEdges.contains(where: { abs($0 - candidate) < 0.0001 })
            }
            return TimelineSnap.nearestCandidate(
                to: time,
                candidates: candidates,
                duration: totalDuration,
                trackWidth: self.trackWidth
            )
        }

        switch drag.mode {
        case .move:
            let duration = drag.initialEnd - drag.initialStart
            let proposedStart = drag.initialStart + delta
            let proposedEnd = proposedStart + duration
            let candidates = drag.snapCandidates.filter { candidate in
                abs(candidate - drag.initialStart) >= 0.0001 && abs(candidate - drag.initialEnd) >= 0.0001
            }
            let snappedStartCandidate = TimelineSnap.nearestCandidate(
                to: proposedStart, candidates: candidates,
                duration: totalDuration, trackWidth: trackWidth
            )
            let snappedEndCandidate = TimelineSnap.nearestCandidate(
                to: proposedEnd, candidates: candidates,
                duration: totalDuration, trackWidth: trackWidth
            )
            let adjustedStart: TimeInterval
            switch (snappedStartCandidate, snappedEndCandidate) {
            case let (start?, end?):
                adjustedStart = abs(start - proposedStart) <= abs(end - proposedEnd) ? start : (end - duration)
            case let (start?, nil):
                adjustedStart = start
            case let (nil, end?):
                adjustedStart = end - duration
            case (nil, nil):
                adjustedStart = proposedStart
            }
            var newStart = max(0, min(totalDuration - duration, adjustedStart))
            // Snap has already run; now refuse to land on top of a neighbour,
            // sliding flush against whichever side the drag was heading for.
            for other in blockers {
                if newStart < other.1 && (newStart + duration) > other.0 {
                    let leftPos = other.0 - duration
                    let rightPos = other.1
                    newStart = abs(adjustedStart - leftPos) <= abs(adjustedStart - rightPos)
                        ? max(0, leftPos)
                        : min(totalDuration - duration, rightPos)
                }
            }
            return (newStart, newStart + duration)
        case .resizeLeft:
            let snappedStart = snapEdge(drag.initialStart + delta, [drag.initialStart, drag.initialEnd])
                ?? (drag.initialStart + delta)
            var newStart = max(0, min(drag.initialEnd - minDuration, snappedStart))
            if let block = blockers
                .filter({ $0.0 < drag.initialEnd && $0.1 > newStart })
                .map({ $0.1 }).max() {
                // EFFECTS keeps the min-duration clamp after the neighbour
                // clamp; FOCUS lets the neighbour win outright — same as the
                // SwiftUI blocks.
                newStart = drag.usesLegacyGrace
                    ? min(max(newStart, block), drag.initialEnd - minDuration)
                    : max(newStart, block)
            }
            return (newStart, drag.initialEnd)
        case .resizeRight:
            let snappedEnd = snapEdge(drag.initialEnd + delta, [drag.initialStart, drag.initialEnd])
                ?? (drag.initialEnd + delta)
            var newEnd = max(drag.initialStart + minDuration, min(totalDuration, snappedEnd))
            if let block = blockers
                .filter({ $0.1 > drag.initialStart && $0.0 < newEnd })
                .map({ $0.0 }).min() {
                newEnd = max(drag.initialStart + minDuration, min(newEnd, block))
            }
            return (drag.initialStart, newEnd)
        }
    }

    private func snapIndicator(for drag: BlockDrag) -> TimeInterval? {
        let resolved = resolvedTimes(for: drag)
        return TimelineSnap.snappedEdge(
            start: resolved.start,
            end: resolved.end,
            candidates: drag.snapCandidates,
            checkStart: drag.mode != .resizeRight,
            checkEnd: drag.mode != .resizeLeft
        )
    }

    // MARK: - Per-item candidates / spans (ports of the SwiftUI lane builders)

    private func effectSnapCandidates(excluding item: EffectBlockItem) -> [TimeInterval] {
        var candidates: [TimeInterval] = [
            snapshot.trimStartOutput,
            snapshot.trimEndOutput,
            snapshot.playheadOutputTime,
        ]
        for focus in snapshot.focusItems {
            candidates.append(focus.startTime)
            candidates.append(focus.endTime)
        }
        for other in snapshot.effectItems
        where other.zoomID != item.zoomID || other.tiltID != item.tiltID {
            candidates.append(other.startTime)
            candidates.append(other.endTime)
        }
        return candidates
    }

    private func effectLaneSpans(excluding item: EffectBlockItem) -> [(TimeInterval, TimeInterval)] {
        var spans: [(TimeInterval, TimeInterval)] = snapshot.effectItems.compactMap { other in
            guard other.zoomID != item.zoomID || other.tiltID != item.tiltID else { return nil }
            return (other.startTime, other.endTime)
        }
        // The Slide chip shares this lane — blocks may not be dragged under it
        // either. (Effect drags use legacy grace, so a joined Slide that
        // already co-spans this block stays exempt.)
        if let introEnd = snapshot.introChipEnd, introEnd > snapshot.introChipStart {
            spans.append((snapshot.introChipStart, introEnd))
        }
        if let curtainEnd = snapshot.curtainChipEnd, curtainEnd > snapshot.curtainChipStart {
            spans.append((snapshot.curtainChipStart, curtainEnd))
        }
        return spans
    }

    /// Effect spans the Slide chip must not be dragged onto. Spans already
    /// overlapping the chip at mouse-down are exempt (joined Slide).
    private func introBlockers() -> [(TimeInterval, TimeInterval)] {
        let initial = introDragInitialSpan ?? (snapshot.introChipStart, snapshot.introChipEnd ?? snapshot.introChipStart)
        var blockers: [(TimeInterval, TimeInterval)] = snapshot.effectItems.compactMap { item in
            let overlapping = item.startTime < initial.end - 0.0001 && item.endTime > initial.start + 0.0001
            return overlapping ? nil : (item.startTime, item.endTime)
        }
        if let curtainEnd = snapshot.curtainChipEnd, curtainEnd > snapshot.curtainChipStart {
            blockers.append((snapshot.curtainChipStart, curtainEnd))
        }
        return blockers
    }

    /// Spans the Curtain chip must not be dragged onto — every effect block
    /// (span-overlap exempt at mouse-down, like the Slide chip) plus the
    /// Slide chip itself.
    private func curtainBlockers() -> [(TimeInterval, TimeInterval)] {
        let initial = curtainDragInitialSpan ?? (snapshot.curtainChipStart, snapshot.curtainChipEnd ?? snapshot.curtainChipStart)
        var blockers: [(TimeInterval, TimeInterval)] = snapshot.effectItems.compactMap { item in
            let overlapping = item.startTime < initial.end - 0.0001 && item.endTime > initial.start + 0.0001
            return overlapping ? nil : (item.startTime, item.endTime)
        }
        if let introEnd = snapshot.introChipEnd, introEnd > snapshot.introChipStart {
            blockers.append((snapshot.introChipStart, introEnd))
        }
        return blockers
    }

    private func focusSnapCandidates(excluding item: TimelineFocusItem) -> [TimeInterval] {
        var candidates: [TimeInterval] = [
            snapshot.trimStartOutput,
            snapshot.trimEndOutput,
            snapshot.playheadOutputTime,
        ]
        // The SwiftUI FOCUS lane snaps to zoom-region edges only, not to
        // tilt-only blocks.
        for effect in snapshot.effectItems where effect.hasZoom {
            candidates.append(effect.startTime)
            candidates.append(effect.endTime)
        }
        for other in snapshot.focusItems where other.id != item.id {
            candidates.append(other.startTime)
            candidates.append(other.endTime)
        }
        return candidates
    }

    private func focusLaneSpans(excluding item: TimelineFocusItem) -> [(TimeInterval, TimeInterval)] {
        snapshot.focusItems.compactMap { other in
            guard other.id != item.id else { return nil }
            return (other.startTime, other.endTime)
        }
    }

    private func annotateSnapCandidates(excluding item: TimelineAnnotateItem) -> [TimeInterval] {
        var candidates: [TimeInterval] = [
            snapshot.trimStartOutput,
            snapshot.trimEndOutput,
            snapshot.playheadOutputTime,
        ]
        for effect in snapshot.effectItems {
            candidates.append(effect.startTime)
            candidates.append(effect.endTime)
        }
        for focus in snapshot.focusItems {
            candidates.append(focus.startTime)
            candidates.append(focus.endTime)
        }
        for other in snapshot.annotateItems where other.id != item.id {
            candidates.append(other.startTime)
            candidates.append(other.endTime)
        }
        return candidates
    }

    // MARK: - Hit testing

    // MARK: - EFFECTS sub-rows

    /// Greedy interval-graph coloring for the EFFECTS lane: sort by start,
    /// give each item the LOWEST sub-row whose previous occupant has ended.
    /// Overlapping effects STACK into sub-rows instead of drawing over each
    /// other (they still apply simultaneously). Capped at `maxEffectsRows`;
    /// beyond that, items share the last row. SHARED source of truth: the
    /// canvas colors chips with it and TimelineViewController sizes the lane
    /// with `effectsRowCount(snapshot:)` below.
    static func effectsRowAssignment(
        spans: [(key: String, start: TimeInterval, end: TimeInterval)]
    ) -> (rows: [String: Int], rowCount: Int) {
        var rows: [String: Int] = [:]
        var rowEnds: [TimeInterval] = []
        for span in spans.sorted(by: { $0.start < $1.start }) {
            if let free = rowEnds.indices.first(where: { span.start >= rowEnds[$0] - 0.0001 }) {
                rows[span.key] = free
                rowEnds[free] = max(rowEnds[free], span.end)
            } else if rowEnds.count < TimelineCanvasMetrics.maxEffectsRows {
                rows[span.key] = rowEnds.count
                rowEnds.append(span.end)
            } else {
                rows[span.key] = TimelineCanvasMetrics.maxEffectsRows - 1
                rowEnds[TimelineCanvasMetrics.maxEffectsRows - 1] =
                    max(rowEnds[TimelineCanvasMetrics.maxEffectsRows - 1], span.end)
            }
        }
        return (rows, max(1, rowEnds.count))
    }

    /// The committed EFFECTS-lane spans a snapshot describes — effect blocks
    /// plus the Slide and Curtain chips.
    static func effectsSpans(
        snapshot: TimelineCanvasSnapshot
    ) -> [(key: String, start: TimeInterval, end: TimeInterval)] {
        var spans: [(key: String, start: TimeInterval, end: TimeInterval)] =
            snapshot.effectItems.map {
                ("effect-\($0.zoomID?.uuidString ?? "-")/\($0.tiltID?.uuidString ?? "-")",
                 $0.startTime, $0.endTime)
            }
        if let end = snapshot.introChipEnd, end > snapshot.introChipStart {
            spans.append(("intro-chip", snapshot.introChipStart, end))
        }
        if let end = snapshot.curtainChipEnd, end > snapshot.curtainChipStart {
            spans.append(("curtain-chip", snapshot.curtainChipStart, end))
        }
        return spans
    }

    /// Committed sub-row count for a snapshot (≥ 1) — the number the lane
    /// HEIGHT is sized from, on both the canvas and the controller.
    static func effectsRowCount(snapshot: TimelineCanvasSnapshot) -> Int {
        effectsRowAssignment(spans: effectsSpans(snapshot: snapshot)).rowCount
    }

    /// Live spans: the committed snapshot spans, with a mid-drag effect
    /// block's span replaced by its resolved drag times so chips glide to
    /// their sub-row while dragging. (Chip drags mutate the model live, so
    /// the snapshot is already current for them.)
    private func liveEffectsSpans() -> [(key: String, start: TimeInterval, end: TimeInterval)] {
        var spans = Self.effectsSpans(snapshot: snapshot)
        if case .draggingBlock(let drag) = mouseState,
           case .effect(let item) = drag.target, drag.didDrag {
            let key = effectsSpanKey(item)
            let resolved = resolvedTimes(for: drag)
            spans = spans.map { $0.key == key ? (key, resolved.start, resolved.end) : $0 }
        }
        return spans
    }

    private func effectsSpanKey(_ item: EffectBlockItem) -> String {
        "effect-\(item.zoomID?.uuidString ?? "-")/\(item.tiltID?.uuidString ?? "-")"
    }

    /// Live row assignment, keyed by `effectsSpanKey` / "intro-chip" /
    /// "curtain-chip". Computed per call — item counts are tiny.
    private func effectsRows() -> [String: Int] {
        Self.effectsRowAssignment(spans: liveEffectsSpans()).rows
    }

    /// Committed row count — geometry (lane height, lane Ys below) keys off
    /// the SNAPSHOT so nothing jumps mid-drag; live rows are capped into it.
    private var effectsRowCountCommitted: Int {
        Self.effectsRowCount(snapshot: snapshot)
    }

    private var effectsExtraHeight: CGFloat {
        CGFloat(effectsRowCountCommitted - 1) * M.subRowPitch
    }

    private func effectsRowY(_ row: Int) -> CGFloat {
        M.effectsLaneY + CGFloat(max(0, min(row, effectsRowCountCommitted - 1))) * M.subRowPitch
    }

    /// The full multi-row EFFECTS lane band (hit tests, hover, empty hint).
    private var effectsLaneRect: CGRect {
        CGRect(x: 0, y: M.effectsLaneY, width: trackWidth,
               height: M.trackHeight + effectsExtraHeight)
    }

    // Lanes BELOW the effects lane shift down as sub-rows appear.
    private var focusLaneY: CGFloat { M.focusLaneY + effectsExtraHeight }
    private var annotateLaneY: CGFloat { M.annotateLaneY + effectsExtraHeight }
    private var tracksBottom: CGFloat { M.tracksBottom + effectsExtraHeight + annotateExtraHeight }

    // ANNOTATE grows the same way EFFECTS does: every stacked row keeps the
    // full block height and the canvas gets taller (the timeline scroll view
    // absorbs it) — no more squashed micro-bars in deep stacks.
    private var annotateRowCountCommitted: Int {
        annotateRowLayout.values.map(\.rows).max() ?? 1
    }

    /// Read by TimelineViewController: the document view must be sized taller
    /// than the (fixed) panel by exactly this so the extra rows SCROLL.
    var annotateExtraHeight: CGFloat {
        CGFloat(annotateRowCountCommitted - 1) * M.subRowPitch
    }

    /// The full multi-row ANNOTATE band (hit tests, hover, empty hint).
    private var annotateLaneRect: CGRect {
        CGRect(x: 0, y: annotateLaneY, width: trackWidth,
               height: M.trackHeight + annotateExtraHeight)
    }

    private func effectItem(at point: CGPoint) -> EffectBlockItem? {
        guard effectsLaneRect.contains(point) else { return nil }
        let rows = effectsRows()
        // Later items draw on top (tilt-only last), so hit test in reverse.
        for item in snapshot.effectItems.reversed() {
            let laneY = effectsRowY(rows[effectsSpanKey(item)] ?? 0)
            if blockRect(start: item.startTime, end: item.endTime, laneY: laneY)
                .insetBy(dx: 0, dy: -M.blockInset)
                .contains(point) {
                return item
            }
        }
        return nil
    }

    private func focusItem(at point: CGPoint) -> TimelineFocusItem? {
        guard laneRect(atY: focusLaneY).contains(point) else { return nil }
        // Highlights draw after blurs, so they hit-test first.
        let ordered = snapshot.focusItems.filter(\.isHighlight) + snapshot.focusItems.filter { !$0.isHighlight }
        for item in ordered {
            if blockRect(start: item.startTime, end: item.endTime, laneY: focusLaneY)
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
        let localX = min(max(point.x - originX, 0), width)
        if localX < M.handleWidth { return .resizeLeft }
        if localX > width - M.handleWidth { return .resizeRight }
        return .move
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
                return
            }
            if chipRect.contains(point) {
                introMove = (point.x, snapshot.introChipStart, false)
                introDragInitialSpan = (snapshot.introChipStart, snapshot.introChipEnd ?? snapshot.introChipStart)
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
                return
            }
            if chipRect.contains(point) {
                curtainMove = (point.x, snapshot.curtainChipStart, false)
                curtainDragInitialSpan = (snapshot.curtainChipStart, snapshot.curtainChipEnd ?? snapshot.curtainChipStart)
                return
            }
        }

        if let item = effectItem(at: point) {
            if !isSelected(item) {
                callbacks?.selectEffect(item.zoomID, item.tiltID)
            }
            mouseState = .draggingBlock(BlockDrag(
                target: .effect(item),
                mode: dragMode(for: point, blockStart: item.startTime, blockEnd: item.endTime),
                initialStart: item.startTime,
                initialEnd: item.endTime,
                startPoint: point,
                snapCandidates: effectSnapCandidates(excluding: item),
                otherSpans: effectLaneSpans(excluding: item),
                usesLegacyGrace: true,
                minDuration: M.minDuration
            ))
            // The SwiftUI blocks pop their hover cursor when a drag begins.
            setCursor(.arrow)
            return
        }
        if let item = focusItem(at: point) {
            if !item.isSelected {
                callbacks?.selectFocus(item.id, item.isHighlight)
            }
            mouseState = .draggingBlock(BlockDrag(
                target: .focus(item),
                mode: dragMode(for: point, blockStart: item.startTime, blockEnd: item.endTime),
                initialStart: item.startTime,
                initialEnd: item.endTime,
                startPoint: point,
                snapCandidates: focusSnapCandidates(excluding: item),
                otherSpans: focusLaneSpans(excluding: item),
                usesLegacyGrace: false,
                minDuration: M.minDuration
            ))
            setCursor(.arrow)
            return
        }

        if let item = annotateItem(at: point) {
            if !item.isSelected {
                callbacks?.selectAnnotation(item.id)
            }
            mouseState = .draggingBlock(BlockDrag(
                target: .annotate(item),
                mode: dragMode(for: point, blockStart: item.startTime, blockEnd: item.endTime),
                initialStart: item.startTime,
                initialEnd: item.endTime,
                startPoint: point,
                snapCandidates: annotateSnapCandidates(excluding: item),
                // Overlaps are allowed on this lane — no blocking spans.
                otherSpans: [],
                usesLegacyGrace: false,
                minDuration: M.minDuration
            ))
            setCursor(.arrow)
            return
        }

        // Empty lane areas and the ruler scrub; the click clears that lane's
        // selection first, same as the SwiftUI lanes.
        if effectsLaneRect.contains(point) {
            callbacks?.selectEffect(nil, nil)
            mouseState = .scrubbing
        } else if laneRect(atY: focusLaneY).contains(point) {
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
            var end = outputTime(atX: point.x)
            // Same rule as resizeRight on effect blocks: stop flush against the
            // nearest non-exempt neighbour instead of sliding under it.
            let start = snapshot.introChipStart
            if let block = introBlockers()
                .filter({ $0.1 > start && $0.0 < end })
                .map({ $0.0 }).min() {
                end = min(end, block)
            }
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
                var newStart = max(0, min(snapshot.outputDuration - duration, move.initialStart + dt))
                // Refuse to land on a neighbour — slide flush to the nearer side.
                for other in introBlockers() {
                    if newStart < other.1 && newStart + duration > other.0 {
                        let leftPos = other.0 - duration
                        let rightPos = other.1
                        newStart = abs((move.initialStart + dt) - leftPos) <= abs((move.initialStart + dt) - rightPos)
                            ? max(0, leftPos)
                            : min(snapshot.outputDuration - duration, rightPos)
                    }
                }
                callbacks?.moveIntro(newStart)
            }
            return
        }
        if draggingCurtainEdge {
            var end = outputTime(atX: point.x)
            let start = snapshot.curtainChipStart
            if let block = curtainBlockers()
                .filter({ $0.1 > start && $0.0 < end })
                .map({ $0.0 }).min() {
                end = min(end, block)
            }
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
                var newStart = max(0, min(snapshot.outputDuration - duration, move.initialStart + dt))
                // Refuse to land on a neighbour — slide flush to the nearer side.
                for other in curtainBlockers() {
                    if newStart < other.1 && newStart + duration > other.0 {
                        let leftPos = other.0 - duration
                        let rightPos = other.1
                        newStart = abs((move.initialStart + dt) - leftPos) <= abs((move.initialStart + dt) - rightPos)
                            ? max(0, leftPos)
                            : min(snapshot.outputDuration - duration, rightPos)
                    }
                }
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
            from: .zero, operation: .sourceOver, fraction: state.alpha)
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
            fraction: 1
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
        } else if laneRect(atY: focusLaneY).contains(point) {
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
            m.addItem(CanvasMenuItem(title: "Delete") { [weak self] in
                self?.callbacks?.deleteIntro()
            })
            menu = m
        } else if let chipRect = curtainChipRect, effectItem(at: point) == nil,
                  chipRect.contains(point) {
            let m = NSMenu()
            m.addItem(CanvasMenuItem(title: "Delete") { [weak self] in
                self?.callbacks?.deleteCurtain()
            })
            menu = m
        } else if let item = effectItem(at: point) {
            menu = effectBlockMenu(for: item)
        } else if let item = focusItem(at: point) {
            menu = focusBlockMenu(for: item)
        } else if let item = annotateItem(at: point) {
            let m = NSMenu()
            m.addItem(CanvasMenuItem(title: "Delete") { [weak self] in
                self?.callbacks?.deleteAnnotation(item.id)
            })
            menu = m
        } else if annotateLaneRect.contains(point) {
            let time = outputTime(atX: point.x)
            let entries: [(String, AnnotationType)] = [
                ("Add Text Label", .text),
                ("Add Arrow", .arrow),
                ("Add Callout", .callout),
                ("Add Drawing", .drawing),
                ("Add Rectangle", .rectangle),
                ("Add Ellipse", .ellipse),
                ("Add Tap Indicator", .tap),
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
                ("Add Zoom Region", false, { [weak self] in self?.callbacks?.addZoomAt(time) }),
                ("Add Tilt Region", false, { [weak self] in self?.callbacks?.addTiltAt(time) }),
            ])
        } else if laneRect(atY: focusLaneY).contains(point) {
            let time = outputTime(atX: point.x)
            menu = makeMenu([
                ("Add Highlight", false, { [weak self] in self?.callbacks?.addHighlightAt(time) }),
                ("Add Blur", false, { [weak self] in self?.callbacks?.addBlurAt(time) }),
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
            let levelsItem = NSMenuItem(title: "Zoom Level", action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: "Zoom Level")
            for level in [1.5, 2.0, 2.5, 3.0, 4.0, 5.0] {
                let entry = CanvasMenuItem(title: String(format: "%.1fx", level)) { [weak self] in
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
            menu.addItem(CanvasMenuItem(title: "Remove Tilt") { [weak self] in
                if let id = item.tiltID { self?.callbacks?.removeTilt(id) }
            })
        } else {
            menu.addItem(CanvasMenuItem(title: "Add Tilt to Block") { [weak self] in
                if let id = item.zoomID { self?.callbacks?.addTiltToBlock(id) }
            })
        }

        if item.hasZoom {
            menu.addItem(CanvasMenuItem(title: "Remove Zoom") { [weak self] in
                if let id = item.zoomID { self?.callbacks?.removeZoom(id) }
            })
        } else {
            menu.addItem(CanvasMenuItem(title: "Add Zoom to Block") { [weak self] in
                if let id = item.tiltID { self?.callbacks?.addZoomToBlock(id) }
            })
        }

        menu.addItem(.separator())
        menu.addItem(CanvasMenuItem(title: "Delete") { [weak self] in
            self?.callbacks?.deleteEffectBlock(item.zoomID, item.tiltID)
        })
        return menu
    }

    private func focusBlockMenu(for item: TimelineFocusItem) -> NSMenu {
        let menu = NSMenu()
        if !item.isHighlight {
            // Blur's SwiftUI menu shows a (currently inert) rename entry.
            let rename = NSMenuItem(title: "Rename...", action: nil, keyEquivalent: "")
            rename.isEnabled = false
            menu.addItem(rename)
            menu.addItem(.separator())
        }
        menu.addItem(CanvasMenuItem(title: "Delete") { [weak self] in
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
        if let model = videoModel {
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
        if let model = voiceModel { drawVoiceLane(in: context, model: model) }
        drawEffectsLane(in: context)
        drawFocusLane(in: context)
        drawAnnotateLane(in: context)
        drawEmptyLaneHints()
        drawSliceIndicator(in: context)
        drawSnipAnimation(in: context)
    }

    private func drawSeparators(in context: CGContext) {
        context.setFillColor(EditorThemeKit.hairline.cgColor)
        // FOCUS/ANNOTATE separators ride below the (dynamic) EFFECTS lane.
        let ys = [
            M.voiceLaneY - M.trackSpacing,
            M.effectsLaneY - M.trackSpacing,
            focusLaneY - M.trackSpacing,
            annotateLaneY - M.trackSpacing,
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
    private func dragDisplay(forKey key: String) -> (rect: CGRect, laneY: CGFloat, dimmed: Bool)? {
        guard case .draggingBlock(let drag) = mouseState else { return nil }
        let (dragKey, laneY): (String, CGFloat)
        switch drag.target {
        case .effect(let item):
            (dragKey, laneY) = (effectKey(item),
                                effectsRowY(effectsRows()[effectsSpanKey(item)] ?? 0))
        case .focus(let item): (dragKey, laneY) = (focusKey(item), focusLaneY)
        case .annotate(let item): (dragKey, laneY) = (annotateKey(item), annotateLaneY)
        }
        guard dragKey == key else { return nil }

        switch drag.mode {
        case .move:
            let committed = blockRect(start: drag.initialStart, end: drag.initialEnd, laneY: laneY)
            let maxX = max(0, trackWidth - committed.width)
            let clampedX = min(max(committed.minX + drag.translationX, 0), maxX)
            return (committed.offsetBy(dx: clampedX - committed.minX, dy: 0), laneY, drag.didDrag)
        case .resizeLeft, .resizeRight:
            let resolved = resolvedTimes(for: drag)
            return (blockRect(start: resolved.start, end: resolved.end, laneY: laneY), laneY, drag.didDrag)
        }
    }

    /// The Intro chip's rect, nil when the intro is off.
    private var introChipRect: CGRect? {
        guard let end = snapshot.introChipEnd, end > snapshot.introChipStart else { return nil }
        return blockRect(start: snapshot.introChipStart, end: end,
                         laneY: effectsRowY(effectsRows()["intro-chip"] ?? 0))
    }

    /// The Curtain chip's rect, nil when the curtain is off.
    private var curtainChipRect: CGRect? {
        guard let end = snapshot.curtainChipEnd, end > snapshot.curtainChipStart else { return nil }
        return blockRect(start: snapshot.curtainChipStart, end: end,
                         laneY: effectsRowY(effectsRows()["curtain-chip"] ?? 0))
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
        context.endTransparencyLayer()
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
            context.endTransparencyLayer()
            context.restoreGState()
        }
        // Curtain Unveil chip: like the Slide chip, it is settings, not a
        // region — drag to place, right edge for length, click for the pane.
        if let rect = curtainChipRect {
            drawSettingsChip(
                in: context, rect: rect,
                icon: "book.pages", label: "Curtain",
                isSelected: snapshot.curtainChipSelected,
                hoverKey: "curtain-chip")
        }
        for item in snapshot.effectItems {
            let key = effectKey(item)
            let display = dragDisplay(forKey: key)
            let rect = display?.rect
                ?? blockRect(start: item.startTime, end: item.endTime,
                             laneY: effectsRowY(effectsRows()[effectsSpanKey(item)] ?? 0))
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
            drawEffectLabel(for: item, in: rect)
            drawGrips(in: context, rect: rect, visible: isSelected(item) || hoveredBlockKey == key)
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
                ?? blockRect(start: item.startTime, end: item.endTime, laneY: focusLaneY)
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
            drawCenteredLabel(item.label, in: rect.insetBy(dx: 8, dy: 0))
            drawGrips(in: context, rect: rect, visible: item.isSelected || hoveredBlockKey == key)
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
            drawAnnotateLabel(for: item, in: rect)
            // Grips don't fit on slim sub-rows — edge-resize still works.
            if rect.height >= 16 {
                drawGrips(in: context, rect: rect, visible: item.isSelected || hoveredBlockKey == key)
            }
            context.endTransparencyLayer()
            context.restoreGState()
        }
    }

    private func drawAnnotateLabel(for item: TimelineAnnotateItem, in rect: CGRect) {
        // Slim sub-row bars (deep overlap stacks) draw as clean color bars —
        // an icon+label crammed into a ~12pt bar is what made a busy
        // ANNOTATE lane read as chaos. FCP's connected-clip bars and
        // CapCut's overlay strips make the same call. Hover/selection still
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
        // Skeuo depth even when a lane's top/bottom tokens are near-equal:
        // widen the pair around their midpoint (matches CCMaterial's raised
        // lift/sink) so every block reads as a lit slab, not a flat sticker.
        let topColor = Self.brightened(top, by: brightness + 0.07)
        let bottomColor = Self.brightened(bottom, by: brightness - 0.07)
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: min(M.blockCornerRadius, rect.width / 2),
            cornerHeight: M.blockCornerRadius,
            transform: nil
        )

        context.saveGState()

        // Drop shadow (offset is in unflipped base space: -1 renders below).
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -1),
            blur: 3,
            color: NSColor.black.withAlphaComponent(0.35).cgColor
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
        // 1px top-edge highlight only — NO glass sheen (Mike's veto).
        context.setFillColor(NSColor.white.withAlphaComponent(0.25).cgColor)
        context.fill(CGRect(
            x: rect.minX + M.blockCornerRadius * 0.75,
            y: rect.minY + 1,
            width: max(0, rect.width - M.blockCornerRadius * 1.5),
            height: 1
        ))
        context.restoreGState()

        if isSelected {
            let borderPath = CGPath(
                roundedRect: rect.insetBy(dx: 1, dy: 1),
                cornerWidth: min(M.blockCornerRadius - 1, rect.width / 2),
                cornerHeight: M.blockCornerRadius - 1,
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
            let zoomLabel = String(format: "%.1fx", item.zoomLevel ?? 1)
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
        let hints: [(HoveredLane, CGFloat, Bool)] = [
            (.effects, M.effectsLaneY, snapshot.effectItems.isEmpty),
            (.focus, focusLaneY, snapshot.focusItems.isEmpty),
            (.annotate, annotateLaneY, snapshot.annotateItems.isEmpty),
        ]
        for (lane, laneY, isEmpty) in hints where hoveredLane == lane && isEmpty {
            if let image = Self.tintedSymbol(
                "plus",
                pointSize: 14,
                weight: .semibold,
                // Empty-lane hint sits on the panel background → theme ink.
                color: (CCTheme.isDark ? NSColor.white : NSColor.black).withAlphaComponent(0.25)
            ) {
                let rect = laneRect(atY: laneY)
                image.draw(in: CGRect(
                    x: rect.midX - image.size.width / 2,
                    y: rect.midY - image.size.height / 2,
                    width: image.size.width,
                    height: image.size.height
                ))
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
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .init(rawValue: weight.rawValue))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        let tinted = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
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

    /// Tracks-bottom including the EFFECTS lane's dynamic sub-rows — same
    /// shared row math the canvas and controller size with.
    private var tracksBottom: CGFloat {
        guard let snapshot else { return M.tracksBottom }
        return M.tracksBottom
            + CGFloat(TimelineCanvasView.effectsRowCount(snapshot: snapshot) - 1) * M.subRowPitch
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
