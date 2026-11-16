import CoreGraphics
import Foundation

// The timeline lanes' block math, platform-neutral (Studio 4c): how a dragged
// EFFECTS / FOCUS / ANNOTATE block resolves (snap, clamp, neighbour refusal),
// which spans and edges it snaps to, how the Slide / Curtain chips move, and
// how overlapping blocks stack into sub-rows. Moved verbatim out of the Mac
// `TimelineCanvasView` so the iOS timeline commits exactly the Mac's values;
// the Mac canvas now calls these. Frozen by `--timeline-edits-test` and the
// iOS `--timeline-edits` gate.

/// Which part of a lane block a press grabbed.
enum TimelineBlockDragMode { case move, resizeLeft, resizeRight }

/// The block a lane drag edits.
enum TimelineBlockDragTarget {
    case effect(EffectBlockItem)
    case focus(TimelineFocusItem)
    case annotate(TimelineAnnotateItem)
}

/// One block drag, captured at press time.
struct TimelineBlockDrag {
    var target: TimelineBlockDragTarget
    var mode: TimelineBlockDragMode
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

enum TimelineLaneMath {
    private typealias M = TimelineCanvasMetrics

    // MARK: - Block drags

    /// A fresh drag of an EFFECTS block (legacy grace on).
    static func effectDrag(
        _ item: EffectBlockItem, mode: TimelineBlockDragMode, at point: CGPoint, in snapshot: TimelineCanvasSnapshot
    ) -> TimelineBlockDrag {
        TimelineBlockDrag(
            target: .effect(item),
            mode: mode,
            initialStart: item.startTime,
            initialEnd: item.endTime,
            startPoint: point,
            snapCandidates: effectSnapCandidates(excluding: item, in: snapshot),
            otherSpans: effectLaneSpans(excluding: item, in: snapshot),
            usesLegacyGrace: true,
            minDuration: M.minDuration
        )
    }

    /// A fresh drag of a FOCUS block (neighbours block, no grace).
    static func focusDrag(
        _ item: TimelineFocusItem, mode: TimelineBlockDragMode, at point: CGPoint, in snapshot: TimelineCanvasSnapshot
    ) -> TimelineBlockDrag {
        TimelineBlockDrag(
            target: .focus(item),
            mode: mode,
            initialStart: item.startTime,
            initialEnd: item.endTime,
            startPoint: point,
            snapCandidates: focusSnapCandidates(excluding: item, in: snapshot),
            otherSpans: focusLaneSpans(excluding: item, in: snapshot),
            usesLegacyGrace: false,
            minDuration: M.minDuration
        )
    }

    /// A fresh drag of an ANNOTATE block (overlaps allowed — no blockers).
    static func annotateDrag(
        _ item: TimelineAnnotateItem, mode: TimelineBlockDragMode, at point: CGPoint, in snapshot: TimelineCanvasSnapshot
    ) -> TimelineBlockDrag {
        TimelineBlockDrag(
            target: .annotate(item),
            mode: mode,
            initialStart: item.startTime,
            initialEnd: item.endTime,
            startPoint: point,
            snapCandidates: annotateSnapCandidates(excluding: item, in: snapshot),
            // Overlaps are allowed on this lane — no blocking spans.
            otherSpans: [],
            usesLegacyGrace: false,
            minDuration: M.minDuration
        )
    }

    /// Which handle zone a down-point falls in, mirroring the SwiftUI blocks'
    /// clamped local-x test (`localX` = press x − the block's origin).
    static func dragMode(localX rawLocalX: CGFloat, blockWidth width: CGFloat) -> TimelineBlockDragMode {
        let localX = min(max(rawLocalX, 0), width)
        if localX < M.handleWidth { return .resizeLeft }
        if localX > width - M.handleWidth { return .resizeRight }
        return .move
    }

    /// Snap / clamp resolution (byte-for-byte port of the block views).
    static func resolvedTimes(
        for drag: TimelineBlockDrag, outputDuration: TimeInterval, trackWidth: CGFloat
    ) -> (start: TimeInterval, end: TimeInterval) {
        let delta = TimeInterval(drag.translationX / max(trackWidth, 1)) * outputDuration
        let totalDuration = outputDuration
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
                trackWidth: trackWidth
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

    /// The edge the resolved drag is locked onto — drives the snap guide.
    static func snapIndicator(
        for drag: TimelineBlockDrag, outputDuration: TimeInterval, trackWidth: CGFloat
    ) -> TimeInterval? {
        let resolved = resolvedTimes(for: drag, outputDuration: outputDuration, trackWidth: trackWidth)
        return TimelineSnap.snappedEdge(
            start: resolved.start,
            end: resolved.end,
            candidates: drag.snapCandidates,
            checkStart: drag.mode != .resizeRight,
            checkEnd: drag.mode != .resizeLeft
        )
    }

    // MARK: - Per-item candidates / spans (ports of the SwiftUI lane builders)

    static func effectSnapCandidates(excluding item: EffectBlockItem, in snapshot: TimelineCanvasSnapshot) -> [TimeInterval] {
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

    static func effectLaneSpans(
        excluding item: EffectBlockItem, in snapshot: TimelineCanvasSnapshot
    ) -> [(TimeInterval, TimeInterval)] {
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
    /// overlapping the chip at mouse-down (`initial`) are exempt (joined Slide).
    static func introBlockers(
        initial dragInitial: (start: TimeInterval, end: TimeInterval)?, in snapshot: TimelineCanvasSnapshot
    ) -> [(TimeInterval, TimeInterval)] {
        let initial = dragInitial ?? (snapshot.introChipStart, snapshot.introChipEnd ?? snapshot.introChipStart)
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
    static func curtainBlockers(
        initial dragInitial: (start: TimeInterval, end: TimeInterval)?, in snapshot: TimelineCanvasSnapshot
    ) -> [(TimeInterval, TimeInterval)] {
        let initial = dragInitial ?? (snapshot.curtainChipStart, snapshot.curtainChipEnd ?? snapshot.curtainChipStart)
        var blockers: [(TimeInterval, TimeInterval)] = snapshot.effectItems.compactMap { item in
            let overlapping = item.startTime < initial.end - 0.0001 && item.endTime > initial.start + 0.0001
            return overlapping ? nil : (item.startTime, item.endTime)
        }
        if let introEnd = snapshot.introChipEnd, introEnd > snapshot.introChipStart {
            blockers.append((snapshot.introChipStart, introEnd))
        }
        return blockers
    }

    static func focusSnapCandidates(excluding item: TimelineFocusItem, in snapshot: TimelineCanvasSnapshot) -> [TimeInterval] {
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

    static func focusLaneSpans(
        excluding item: TimelineFocusItem, in snapshot: TimelineCanvasSnapshot
    ) -> [(TimeInterval, TimeInterval)] {
        snapshot.focusItems.compactMap { other in
            guard other.id != item.id else { return nil }
            return (other.startTime, other.endTime)
        }
    }

    static func annotateSnapCandidates(excluding item: TimelineAnnotateItem, in snapshot: TimelineCanvasSnapshot) -> [TimeInterval] {
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

    // MARK: - Slide / Curtain chips

    /// Live END of a chip whose right edge is dragged to `proposedEnd`: same
    /// rule as resizeRight on effect blocks — stop flush against the nearest
    /// non-exempt neighbour instead of sliding under it.
    static func chipResizedEnd(
        proposedEnd: TimeInterval, chipStart start: TimeInterval, blockers: [(TimeInterval, TimeInterval)]
    ) -> TimeInterval {
        var end = proposedEnd
        if let block = blockers
            .filter({ $0.1 > start && $0.0 < end })
            .map({ $0.0 }).min() {
            end = min(end, block)
        }
        return end
    }

    /// Live START of a chip dragged by `dt` output seconds from
    /// `initialStart`: clamped into the timeline, refusing to land on a
    /// neighbour (slides flush to the nearer side).
    static func chipMovedStart(
        initialStart: TimeInterval, dt: TimeInterval, duration: TimeInterval,
        outputDuration: TimeInterval, blockers: [(TimeInterval, TimeInterval)]
    ) -> TimeInterval {
        var newStart = max(0, min(outputDuration - duration, initialStart + dt))
        // Refuse to land on a neighbour — slide flush to the nearer side.
        for other in blockers {
            if newStart < other.1 && newStart + duration > other.0 {
                let leftPos = other.0 - duration
                let rightPos = other.1
                newStart = abs((initialStart + dt) - leftPos) <= abs((initialStart + dt) - rightPos)
                    ? max(0, leftPos)
                    : min(outputDuration - duration, rightPos)
            }
        }
        return newStart
    }

    // MARK: - ANNOTATE sub-rows

    /// Draw order: earlier-starting first, so later-starting annotations draw
    /// on top (overlaps are allowed on this lane).
    static func orderedAnnotateItems(_ snapshot: TimelineCanvasSnapshot) -> [TimelineAnnotateItem] {
        snapshot.annotateItems.sorted { $0.startTime < $1.startTime }
    }

    /// Sub-row layout for concurrent annotations: greedy interval
    /// partitioning per overlap cluster, so overlapping blocks stack in
    /// slimmer rows instead of burying each other. Isolated annotations keep
    /// the full lane height.
    static func annotateRowLayout(_ snapshot: TimelineCanvasSnapshot) -> [UUID: (row: Int, rows: Int)] {
        var layout: [UUID: (row: Int, rows: Int)] = [:]
        var rowEnds: [TimeInterval] = []
        var assignments: [(UUID, Int)] = []
        var clusterMaxEnd = -TimeInterval.infinity

        func flushCluster() {
            for (id, row) in assignments { layout[id] = (row, rowEnds.count) }
            assignments.removeAll()
            rowEnds.removeAll()
        }

        for item in orderedAnnotateItems(snapshot) {
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

    // MARK: - EFFECTS sub-rows

    /// Greedy interval-graph coloring for the EFFECTS lane: sort by start,
    /// give each item the LOWEST sub-row whose previous occupant has ended.
    /// Overlapping effects STACK into sub-rows instead of drawing over each
    /// other (they still apply simultaneously). Capped at `maxEffectsRows`;
    /// beyond that, items share the last row. SHARED source of truth: the
    /// canvases color chips with it and the timelines size the lane with
    /// `effectsRowCount(snapshot:)` below.
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

    /// Key of an effect block in `effectsSpans` / the row assignment.
    static func effectsSpanKey(_ item: EffectBlockItem) -> String {
        "effect-\(item.zoomID?.uuidString ?? "-")/\(item.tiltID?.uuidString ?? "-")"
    }

    /// Live spans: the committed snapshot spans, with a mid-drag effect
    /// block's span replaced by its resolved drag times so chips glide to
    /// their sub-row while dragging. (Chip drags mutate the model live, so
    /// the snapshot is already current for them.)
    static func liveEffectsSpans(
        snapshot: TimelineCanvasSnapshot, drag: TimelineBlockDrag?, trackWidth: CGFloat
    ) -> [(key: String, start: TimeInterval, end: TimeInterval)] {
        var spans = effectsSpans(snapshot: snapshot)
        if let drag, case .effect(let item) = drag.target, drag.didDrag {
            let key = effectsSpanKey(item)
            let resolved = resolvedTimes(for: drag, outputDuration: snapshot.outputDuration, trackWidth: trackWidth)
            spans = spans.map { $0.key == key ? (key, resolved.start, resolved.end) : $0 }
        }
        return spans
    }
}
