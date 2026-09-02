import Foundation
import CoreGraphics

/// `CaptureCat --videotrack-math-test` — numeric acceptance test for
/// VideoTrackEditMath. The ORACLE below is a verbatim copy of the original
/// in-view implementations (pre-extraction), so any drift between the shared
/// struct and the shipped SwiftUI behavior fails loudly with the exact
/// values. Exits 0 on pass, 1 on any mismatch.
enum VideoTrackMathHarness {
    // MARK: - Oracle (verbatim pre-refactor VideoTrackContent code)

    private struct Oracle {
        var duration: TimeInterval
        var trackWidth: CGFloat
        var snapCandidates: [TimeInterval]
        var regionStart: TimeInterval
        var regionEnd: TimeInterval
        let minDuration: TimeInterval = 0.5

        func resolvedTimes(
            mode: VideoTrackEditMath.DragMode,
            delta: TimeInterval,
            dragInitialStart: TimeInterval,
            dragInitialEnd: TimeInterval
        ) -> (start: TimeInterval, end: TimeInterval) {
            let snapEdge: (TimeInterval, [TimeInterval]) -> TimeInterval? = { time, excludedEdges in
                let candidates = snapCandidates.filter { candidate in
                    !excludedEdges.contains(where: { abs($0 - candidate) < 0.0001 })
                }
                return TimelineSnap.nearestCandidate(
                    to: time,
                    candidates: candidates,
                    duration: duration,
                    trackWidth: trackWidth
                )
            }

            switch mode {
            case .resizeLeft:
                let snappedStart = snapEdge(dragInitialStart + delta, [dragInitialStart, dragInitialEnd]) ?? (dragInitialStart + delta)
                let newStart = min(dragInitialEnd - minDuration, snappedStart)
                return (newStart, dragInitialEnd)
            case .resizeRight:
                let snappedEnd = snapEdge(dragInitialEnd + delta, [dragInitialStart, dragInitialEnd]) ?? (dragInitialEnd + delta)
                let newEnd = max(dragInitialStart + minDuration, snappedEnd)
                return (dragInitialStart, newEnd)
            case .move:
                let clipDuration = dragInitialEnd - dragInitialStart
                let maxStart = max(0, duration - clipDuration)
                let proposedStart = dragInitialStart + delta
                let proposedEnd = proposedStart + clipDuration
                let candidates = snapCandidates.filter { candidate in
                    abs(candidate - dragInitialStart) >= 0.0001 && abs(candidate - dragInitialEnd) >= 0.0001
                }
                let snappedStartCandidate = TimelineSnap.nearestCandidate(
                    to: proposedStart, candidates: candidates, duration: duration, trackWidth: trackWidth
                )
                let snappedEndCandidate = TimelineSnap.nearestCandidate(
                    to: proposedEnd, candidates: candidates, duration: duration, trackWidth: trackWidth
                )
                let adjustedStart: TimeInterval
                switch (snappedStartCandidate, snappedEndCandidate) {
                case let (start?, end?):
                    adjustedStart = abs(start - proposedStart) <= abs(end - proposedEnd) ? start : (end - clipDuration)
                case let (start?, nil):
                    adjustedStart = start
                case let (nil, end?):
                    adjustedStart = end - clipDuration
                case (nil, nil):
                    adjustedStart = proposedStart
                }
                let newStart = min(max(0, adjustedStart), maxStart)
                return (newStart, min(duration, newStart + clipDuration))
            case .none:
                return (regionStart, regionEnd)
            }
        }

        func resolvedClipEdgeOutput(
            _ clip: VideoTrackEditMath.ClipSpan,
            in clips: [VideoTrackEditMath.ClipSpan],
            side: VideoTrackEditMath.Side,
            proposedOutput: TimeInterval,
            snapsToCandidates: Bool
        ) -> TimeInterval {
            let bounds: (lower: TimeInterval, upper: TimeInterval)
            let index = clips.firstIndex(where: { $0.id == clip.id })
            switch side {
            case .left:
                let previousEnd = index.flatMap { $0 > 0 ? clips[$0 - 1].outputEnd : nil } ?? 0
                bounds = (max(0, previousEnd), clip.outputEnd - minDuration)
            case .right:
                let nextStart = index.flatMap { $0 < clips.count - 1 ? clips[$0 + 1].outputStart : nil } ?? duration
                bounds = (clip.outputStart + minDuration, min(duration, nextStart))
            }
            let resolved: TimeInterval
            if snapsToCandidates {
                let excluded = [clip.outputStart, clip.outputEnd]
                let candidates = snapCandidates.filter { candidate in
                    !excluded.contains(where: { abs($0 - candidate) < 0.0001 })
                }
                resolved = TimelineSnap.nearestCandidate(
                    to: proposedOutput, candidates: candidates, duration: duration, trackWidth: trackWidth
                ) ?? proposedOutput
            } else {
                resolved = proposedOutput
            }
            return min(max(resolved, bounds.lower), bounds.upper)
        }

        func resolvedClipMoveOutputStart(
            _ clip: VideoTrackEditMath.ClipSpan,
            in clips: [VideoTrackEditMath.ClipSpan],
            proposedOutputStart: TimeInterval,
            snapsToCandidates: Bool
        ) -> TimeInterval {
            let index = clips.firstIndex(where: { $0.id == clip.id })
            let previousEnd = index.flatMap { $0 > 0 ? clips[$0 - 1].outputEnd : nil } ?? 0
            let nextStart = index.flatMap { $0 < clips.count - 1 ? clips[$0 + 1].outputStart : nil } ?? duration
            let bounds = (lower: previousEnd, upper: nextStart - clip.outputDuration)
            guard bounds.upper >= bounds.lower else { return clip.outputStart }

            let proposedEnd = proposedOutputStart + clip.outputDuration
            let resolved: TimeInterval
            if snapsToCandidates {
                let excluded = [clip.outputStart, clip.outputEnd]
                let candidates = snapCandidates.filter { candidate in
                    !excluded.contains(where: { abs($0 - candidate) < 0.0001 })
                }
                let snappedStart = TimelineSnap.nearestCandidate(
                    to: proposedOutputStart, candidates: candidates, duration: duration, trackWidth: trackWidth
                )
                let snappedEnd = TimelineSnap.nearestCandidate(
                    to: proposedEnd, candidates: candidates, duration: duration, trackWidth: trackWidth
                )
                switch (snappedStart, snappedEnd) {
                case let (start?, end?):
                    resolved = abs(start - proposedOutputStart) <= abs(end - proposedEnd) ? start : end - clip.outputDuration
                case let (start?, nil):
                    resolved = start
                case let (nil, end?):
                    resolved = end - clip.outputDuration
                case (nil, nil):
                    resolved = proposedOutputStart
                }
            } else {
                resolved = proposedOutputStart
            }
            return min(max(resolved, bounds.lower), bounds.upper)
        }
    }

    // MARK: - Runner

    static func run() -> Never {
        // Sub-modes ride on this flag so main.swift needs no new dispatch.
        if CommandLine.arguments.contains("--canvas") {
            MainActor.assumeIsolated { VideoTrackCanvasHarness.run() }
        }

        var failures = 0
        var checks = 0

        func expect(_ label: String, _ a: TimeInterval, _ b: TimeInterval) {
            checks += 1
            if abs(a - b) > 1e-9 {
                failures += 1
                FileHandle.standardError.write(Data("FAIL \(label): math=\(a) oracle=\(b)\n".utf8))
            }
        }

        // Deterministic RNG (splitmix64) so failures reproduce.
        var state: UInt64 = 0x1234_5678_9ABC_DEF0
        func rand() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Double(z >> 11) / Double(1 << 53)
        }

        let duration = 13.6
        let trackWidth: CGFloat = 1200
        let snaps: [TimeInterval] = [0.668, 2.0, 3.03, 6.03, 9.5, 13.0]
        let math = VideoTrackEditMath(
            duration: duration, trackWidth: trackWidth, snapCandidates: snaps,
            regionStart: 0.668, regionEnd: 13.0
        )
        let oracle = Oracle(
            duration: duration, trackWidth: trackWidth, snapCandidates: snaps,
            regionStart: 0.668, regionEnd: 13.0
        )

        // 1. Whole-track drags: 20 random (mode, delta, span) triples per mode.
        let modes: [VideoTrackEditMath.DragMode] = [.move, .resizeLeft, .resizeRight, .none]
        for mode in modes {
            for i in 0..<20 {
                let start = rand() * 6
                let end = start + 1 + rand() * 6
                let delta = (rand() - 0.5) * 10
                let m = math.resolvedTimes(mode: mode, delta: delta, dragInitialStart: start, dragInitialEnd: end)
                let o = oracle.resolvedTimes(mode: mode, delta: delta, dragInitialStart: start, dragInitialEnd: end)
                expect("resolvedTimes(\(mode)#\(i)).start", m.start, o.start)
                expect("resolvedTimes(\(mode)#\(i)).end", m.end, o.end)
            }
        }

        // 2. Multi-clip move/resize: fixed three-clip layout, 20 random drags each.
        let ids = (0..<3).map { _ in UUID() }
        let clips: [VideoTrackEditMath.ClipSpan] = [
            .init(id: ids[0], outputStart: 0.7, outputEnd: 4.0),
            .init(id: ids[1], outputStart: 4.0, outputEnd: 8.2),
            .init(id: ids[2], outputStart: 9.0, outputEnd: 13.0),
        ]
        for clip in clips {
            for i in 0..<20 {
                let proposed = clip.outputStart + (rand() - 0.5) * 8
                for snapping in [true, false] {
                    let m = math.resolvedClipMoveOutputStart(clip, in: clips, proposedOutputStart: proposed, snapsToCandidates: snapping)
                    let o = oracle.resolvedClipMoveOutputStart(clip, in: clips, proposedOutputStart: proposed, snapsToCandidates: snapping)
                    expect("clipMove(\(clip.id.uuidString.prefix(4))#\(i) snap=\(snapping))", m, o)
                }
                for side in [VideoTrackEditMath.Side.left, .right] {
                    let edge = side == .left ? clip.outputStart : clip.outputEnd
                    let proposedEdge = edge + (rand() - 0.5) * 6
                    let m = math.resolvedClipEdgeOutput(clip, in: clips, side: side, proposedOutput: proposedEdge)
                    let o = oracle.resolvedClipEdgeOutput(clip, in: clips, side: side, proposedOutput: proposedEdge, snapsToCandidates: true)
                    expect("clipEdge(\(side)#\(i))", m, o)
                }
            }
        }

        // 3. Behavior pins (independent of the oracle): clamps + no-op safety.
        // Overshoot past the left edge stays unclamped (restores trimmed head).
        let overshoot = math.resolvedTimes(mode: .resizeLeft, delta: -100, dragInitialStart: 0.668, dragInitialEnd: 13.0)
        checks += 1
        if overshoot.start >= 0 {
            failures += 1
            FileHandle.standardError.write(Data("FAIL resizeLeft overshoot should go negative, got \(overshoot.start)\n".utf8))
        }
        // Move clamps inside [0, duration].
        let moved = math.resolvedTimes(mode: .move, delta: 100, dragInitialStart: 1, dragInitialEnd: 3)
        expect("move upper clamp end", moved.end, duration)
        // duration == 0: no-op, no crash, returns region.
        let degenerate = VideoTrackEditMath(duration: 0, trackWidth: 0, snapCandidates: [], regionStart: 0, regionEnd: 0)
        let dz = degenerate.resolvedTimes(mode: .none, delta: 5, dragInitialStart: 0, dragInitialEnd: 0)
        expect("degenerate none.start", dz.start, 0)
        // Min-duration floor on resize.
        let pinched = math.resolvedTimes(mode: .resizeRight, delta: -100, dragInitialStart: 2, dragInitialEnd: 10)
        expect("resizeRight min duration", pinched.end, 2.5)

        if failures == 0 {
            print("VIDEOTRACK-MATH PASS (\(checks) checks)")
            exit(0)
        } else {
            print("VIDEOTRACK-MATH FAIL (\(failures)/\(checks))")
            exit(1)
        }
    }
}

// MARK: - Canvas state-machine acceptance test

import AppKit

/// `CaptureCat --videotrack-math-test --canvas` — drives the AppKit VIDEO row's
/// mouse state machine with synthetic sequences and asserts that every value
/// crossing the commit boundary equals `VideoTrackEditMath`'s direct result.
/// The canvas is the real `TimelineCanvasView`, configured headlessly: same
/// hit testing, same drag machine, same drawing code as the app.
@MainActor
enum VideoTrackCanvasHarness {
    private static let duration: TimeInterval = 13.6
    private static let width: CGFloat = 1200
    private static let snaps: [TimeInterval] = [0.668, 2.0, 3.03, 6.03, 9.5, 13.0]

    /// Records what the row asked TimelineView to commit.
    private final class Capture {
        var whole: (mode: VideoTrackEditMath.DragMode, delta: TimeInterval, start: TimeInterval, end: TimeInterval)?
        var move: (id: UUID, start: TimeInterval)?
        var edge: (id: UUID, side: VideoTrackEditMath.Side, output: TimeInterval)?
        var selections: [UUID?] = []
        var muteToggles = 0
        var speedAdds: [(TimeInterval, TimeInterval, Double)] = []
        var speedChanges: [(UUID, Double)] = []
        var speedDeletes: [UUID] = []
        var splitDeletes: [TimeInterval] = []
        /// Output time of a slice-tool commit, nil when none fired.
        var slicedAt: TimeInterval?

        func reset() {
            whole = nil
            move = nil
            edge = nil
            selections = []
        }
    }

    private static func callbacks(_ capture: Capture) -> TimelineVideoCallbacks {
        TimelineVideoCallbacks(
            selectClip: { capture.selections.append($0) },
            commitWholeDrag: { mode, delta, start, end in
                capture.whole = (mode, delta, start, end)
            },
            commitClipMove: { clip, start in capture.move = (clip.id, start) },
            commitClipEdge: { clip, side, output in capture.edge = (clip.id, side, output) },
            toggleMute: { capture.muteToggles += 1 },
            addSpeedRange: { s, e, v in capture.speedAdds.append((s, e, v)) },
            changeSpeed: { id, v in capture.speedChanges.append((id, v)) },
            deleteSpeed: { capture.speedDeletes.append($0) },
            deleteSplit: { capture.splitDeletes.append($0) },
            sliceAt: { capture.slicedAt = $0 }
        )
    }

    private static func clip(
        _ id: UUID,
        _ outputStart: TimeInterval,
        _ outputEnd: TimeInterval,
        selected: Bool = false,
        speed: Double? = nil
    ) -> TimelineVideoClipItem {
        TimelineVideoClipItem(
            ref: VideoClipRef(
                id: id,
                sourceStart: outputStart,
                sourceEnd: outputEnd,
                outputStart: outputStart,
                outputEnd: outputEnd
            ),
            isSelected: selected,
            pillSpeedLabel: speed.map { TimelineVideoRowModel.formatSpeedLabel($0) },
            fillSpeed: nil,
            fillRegionID: nil
        )
    }

    private static func segment(
        _ clipID: UUID,
        _ start: TimeInterval,
        _ end: TimeInterval,
        speed: Double = 1.0,
        regionID: UUID? = nil,
        divider: Bool = false,
        split: Bool = false
    ) -> TimelineVideoSegmentItem {
        TimelineVideoSegmentItem(
            id: "\(clipID)-\(start)-\(end)",
            clipID: clipID,
            sourceStart: start,
            sourceEnd: end,
            outputStart: start,
            outputEnd: end,
            speed: speed,
            regionID: regionID,
            label: TimelineVideoRowModel.segmentLabel(outputSpan: end - start, speed: speed),
            showsLeadingDivider: divider,
            startsAtSplit: split
        )
    }

    private static func math(_ model: TimelineVideoRowModel) -> VideoTrackEditMath {
        VideoTrackEditMath(
            duration: duration,
            trackWidth: width,
            snapCandidates: model.snapCandidates,
            regionStart: model.regionStart,
            regionEnd: model.regionEnd,
            minDuration: TimelineCanvasMetrics.minDuration
        )
    }

    private static func makeCanvas(
        _ model: TimelineVideoRowModel,
        _ capture: Capture
    ) -> TimelineCanvasView {
        let view = TimelineCanvasView()
        view.configureForVideoRowHarness(
            width: width,
            outputDuration: duration,
            model: model,
            callbacks: callbacks(capture)
        )
        return view
    }

    /// One synthetic press → 4 drag steps → release.
    private static func drive(
        _ view: TimelineCanvasView,
        _ model: TimelineVideoRowModel,
        from origin: CGPoint,
        dx: CGFloat
    ) {
        view.videoMouseDown(at: origin, model: model)
        for step in 1...4 {
            view.videoMouseDragged(to: CGPoint(x: origin.x + dx * CGFloat(step) / 4, y: origin.y))
        }
        view.videoMouseUp(at: CGPoint(x: origin.x + dx, y: origin.y), model: model)
    }

    private static func x(_ t: TimeInterval) -> CGFloat { width * CGFloat(t / duration) }

    private static var laneMidY: CGFloat { TimelineCanvasMetrics.videoLaneY + TimelineCanvasMetrics.trackHeight / 2 }

    // MARK: Runner

    static func run() -> Never {
        _ = NSApplication.shared

        var failures = 0
        var checks = 0

        func fail(_ message: String) {
            failures += 1
            FileHandle.standardError.write(Data("FAIL \(message)\n".utf8))
        }

        func expect(_ label: String, _ actual: TimeInterval?, _ expected: TimeInterval) {
            checks += 1
            guard let actual else { return fail("\(label): no commit (expected \(expected))") }
            if abs(actual - expected) > 1e-9 {
                fail("\(label): canvas=\(actual) math=\(expected)")
            }
        }

        func expectTrue(_ label: String, _ condition: Bool) {
            checks += 1
            if !condition { fail(label) }
        }

        // Deterministic RNG (splitmix64), independent stream from the math test.
        var state: UInt64 = 0x0BAD_C0DE_1234_5678
        func rand() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Double(z >> 11) / Double(1 << 53)
        }
        /// Random pixel translation with a guaranteed past-threshold magnitude.
        func randomDX() -> CGFloat {
            let raw = (rand() - 0.5) * 700
            return CGFloat(raw >= 0 ? max(raw, 8) : min(raw, -8))
        }

        // MARK: Fixture A — single clip (whole-track trim / slip / resize)

        let soloID = UUID()
        let solo = TimelineVideoRowModel(
            regionStart: 0,
            regionEnd: duration,
            usesWholeTrackDrag: true,
            clips: [clip(soloID, 0, duration)],
            segments: [segment(soloID, 0, duration)],
            boundaries: [],
            isMuted: false,
            hasAudio: true,
            hasThumbnails: false,
            snapCandidates: snaps
        )
        let soloMath = math(solo)

        let wholeCases: [(VideoTrackEditMath.DragMode, CGFloat, String)] = [
            (.resizeLeft, 5, "resizeLeft"),
            (.resizeRight, width - 5, "resizeRight"),
            (.move, width / 2, "move"),
        ]
        for (mode, hitX, name) in wholeCases {
            let origin = CGPoint(x: hitX, y: laneMidY)
            // Hit classification must pick the right whole-track mode.
            let capture = Capture()
            let probe = makeCanvas(solo, capture)
            let kind = probe.videoDragKind(at: origin, model: solo)
            expectTrue("whole.\(name) hit classification", kind == .whole(mode))

            for i in 0..<20 {
                let dx = randomDX()
                capture.reset()
                let view = makeCanvas(solo, capture)
                drive(view, solo, from: origin, dx: dx)

                let delta = TimeInterval(dx) * duration / TimeInterval(width)
                let expected = soloMath.resolvedTimes(
                    mode: mode,
                    delta: delta,
                    dragInitialStart: solo.regionStart,
                    dragInitialEnd: solo.regionEnd
                )
                checks += 1
                guard let got = capture.whole else {
                    fail("whole.\(name)#\(i): no commit for dx=\(dx)")
                    continue
                }
                expectTrue("whole.\(name)#\(i) mode", got.mode == mode)
                expect("whole.\(name)#\(i).delta", got.delta, delta)
                expect("whole.\(name)#\(i).start", got.start, expected.start)
                expect("whole.\(name)#\(i).end", got.end, expected.end)
            }
        }

        // MARK: Fixture B — three clips (per-clip move / edge, joined boundary)

        let ids = (0..<3).map { _ in UUID() }
        let multi = TimelineVideoRowModel(
            regionStart: 0,
            regionEnd: duration,
            usesWholeTrackDrag: false,
            clips: [
                clip(ids[0], 0.7, 4.0),
                clip(ids[1], 4.0, 8.2, selected: true),
                clip(ids[2], 9.0, 13.0),
            ],
            segments: [
                segment(ids[0], 0.7, 4.0),
                segment(ids[1], 4.0, 6.0, speed: 2.0, regionID: ids[1], split: true),
                segment(ids[1], 6.0, 8.2, divider: true),
                segment(ids[2], 9.0, 13.0),
            ],
            boundaries: [
                TimelineVideoBoundaryItem(
                    id: "b0", leftClipID: ids[0], rightClipID: ids[1], outputTime: 4.0
                ),
            ],
            isMuted: false,
            hasAudio: true,
            hasThumbnails: false,
            snapCandidates: snaps
        )
        let multiMath = math(multi)
        let spans = multi.clipSpans

        // --- clip move (clip 0 body, clear of both its handles and the boundary)
        let moveClip = multi.clips[0]
        let moveOrigin = CGPoint(x: (x(0.7) + x(4.0)) / 2, y: laneMidY)
        do {
            let capture = Capture()
            let probe = makeCanvas(multi, capture)
            expectTrue(
                "clipMove hit classification",
                probe.videoDragKind(at: moveOrigin, model: multi) == .clipMove(moveClip.ref)
            )
        }
        for i in 0..<20 {
            let dx = randomDX()
            let capture = Capture()
            let view = makeCanvas(multi, capture)
            drive(view, multi, from: moveOrigin, dx: dx)

            let delta = TimeInterval(dx) * duration / TimeInterval(width)
            let expected = multiMath.resolvedClipMoveOutputStart(
                moveClip.ref.span, in: spans,
                proposedOutputStart: moveClip.outputStart + delta
            )
            checks += 1
            guard let got = capture.move else {
                fail("clipMove#\(i): no commit for dx=\(dx)")
                continue
            }
            expectTrue("clipMove#\(i) id", got.id == moveClip.id)
            expect("clipMove#\(i).start", got.start, expected)
        }

        // --- clip edge resize (both sides of the isolated third clip)
        for side in [VideoTrackEditMath.Side.left, .right] {
            let target = multi.clips[2]
            let edgeX = side == .left ? x(target.outputStart) + 4 : x(target.outputEnd) - 4
            let origin = CGPoint(x: edgeX, y: laneMidY)
            do {
                let capture = Capture()
                let probe = makeCanvas(multi, capture)
                expectTrue(
                    "clipEdge.\(side) hit classification",
                    probe.videoDragKind(at: origin, model: multi) == .clipEdge(target.ref, side)
                )
            }
            for i in 0..<20 {
                let dx = randomDX()
                let capture = Capture()
                let view = makeCanvas(multi, capture)
                drive(view, multi, from: origin, dx: dx)

                let delta = TimeInterval(dx) * duration / TimeInterval(width)
                let original = side == .left ? target.outputStart : target.outputEnd
                let expected = multiMath.resolvedClipEdgeOutput(
                    target.ref.span, in: spans, side: side,
                    proposedOutput: original + delta
                )
                checks += 1
                guard let got = capture.edge else {
                    fail("clipEdge.\(side)#\(i): no commit for dx=\(dx)")
                    continue
                }
                expectTrue("clipEdge.\(side)#\(i) id", got.id == target.id)
                expectTrue("clipEdge.\(side)#\(i) side", got.side == side)
                expect("clipEdge.\(side)#\(i).output", got.output, expected)
            }
        }

        // --- joined boundary: drag direction picks which clip's edge moves
        let boundaryOrigin = CGPoint(x: x(4.0), y: laneMidY)
        do {
            let capture = Capture()
            let probe = makeCanvas(multi, capture)
            expectTrue(
                "boundary hit classification",
                probe.videoDragKind(at: boundaryOrigin, model: multi) == .boundary(multi.boundaries[0])
            )
        }
        for i in 0..<20 {
            let dx = randomDX()
            let capture = Capture()
            let view = makeCanvas(multi, capture)
            drive(view, multi, from: boundaryOrigin, dx: dx)

            let delta = TimeInterval(dx) * duration / TimeInterval(width)
            let target = dx < 0 ? multi.clips[0] : multi.clips[1]
            let side: VideoTrackEditMath.Side = dx < 0 ? .right : .left
            let original = side == .left ? target.outputStart : target.outputEnd
            let expected = multiMath.resolvedClipEdgeOutput(
                target.ref.span, in: spans, side: side,
                proposedOutput: original + delta
            )
            checks += 1
            guard let got = capture.edge else {
                fail("boundary#\(i): no commit for dx=\(dx)")
                continue
            }
            expectTrue("boundary#\(i) id", got.id == target.id)
            expectTrue("boundary#\(i) side", got.side == side)
            expect("boundary#\(i).output", got.output, expected)
        }

        // MARK: Click / selection / mute / menus

        // Sub-threshold press on a clip body selects it, commits nothing.
        do {
            let capture = Capture()
            let view = makeCanvas(multi, capture)
            drive(view, multi, from: moveOrigin, dx: 0.5)
            expectTrue("tap selects clip", capture.selections == [moveClip.id])
            expectTrue("tap commits nothing", capture.move == nil && capture.edge == nil)
        }
        // Press on empty lane past the last clip clears the selection.
        do {
            let capture = Capture()
            let view = makeCanvas(multi, capture)
            drive(view, multi, from: CGPoint(x: x(13.3), y: laneMidY), dx: 0)
            expectTrue("empty-lane tap deselects", capture.selections == [nil])
        }
        // Whole-track fixture: sub-threshold press selects the clip under it.
        do {
            let capture = Capture()
            let view = makeCanvas(solo, capture)
            drive(view, solo, from: CGPoint(x: width / 2, y: laneMidY), dx: 0.5)
            expectTrue("whole tap selects", capture.selections == [soloID])
            expectTrue("whole tap commits nothing", capture.whole == nil)
        }
        // Mute button hit zone.
        do {
            let capture = Capture()
            let view = makeCanvas(solo, capture)
            guard let mute = view.videoMuteRect(solo) else {
                fail("mute rect missing with audio")
                return finish(checks: checks, failures: failures)
            }
            view.videoMouseDown(at: CGPoint(x: mute.midX, y: mute.midY), model: solo)
            view.videoMouseUp(at: CGPoint(x: mute.midX, y: mute.midY), model: solo)
            expectTrue("mute toggles once", capture.muteToggles == 1)
            expectTrue("mute starts no drag", capture.whole == nil)
        }
        // No mute affordance without audio.
        do {
            var silent = solo
            silent.hasAudio = false
            let capture = Capture()
            let view = makeCanvas(silent, capture)
            expectTrue("no mute rect without audio", view.videoMuteRect(silent) == nil)
        }

        // Context menus mirror the SwiftUI segment menus.
        do {
            let capture = Capture()
            let view = makeCanvas(multi, capture)
            let speedPoint = CGPoint(x: x(5.0), y: laneMidY)
            let plainPoint = CGPoint(x: x(7.0), y: laneMidY)
            let speedMenu = view.videoContextMenu(at: speedPoint, model: multi)
            let plainMenu = view.videoContextMenu(at: plainPoint, model: multi)
            expectTrue("speed menu exists", speedMenu != nil)
            expectTrue(
                "speed menu offers Change Speed",
                speedMenu?.items.contains { $0.title == "Change Speed" } == true
            )
            expectTrue(
                "speed menu offers Remove Speed",
                speedMenu?.items.contains { $0.title == "Remove Speed" } == true
            )
            expectTrue(
                "speed menu offers Remove Split at Start",
                speedMenu?.items.contains { $0.title == "Remove Split at Start" } == true
            )
            expectTrue(
                "Change Speed submenu has all presets",
                speedMenu?.items.first { $0.title == "Change Speed" }?.submenu?.items.count
                    == TimelineVideoRowModel.speedPresets.count
            )
            expectTrue("plain menu exists", plainMenu != nil)
            expectTrue(
                "plain menu offers Set Speed",
                plainMenu?.items.contains { $0.title == "Set Speed" } == true
            )
            expectTrue(
                "plain segment has no split entry",
                plainMenu?.items.contains { $0.title == "Remove Split at Start" } == false
            )
            expectTrue("no menu outside the lane", view.videoContextMenu(at: .zero, model: multi) == nil)
        }

        // Hover cursors: resize on handles/boundaries, arrow on bodies.
        do {
            let capture = Capture()
            let view = makeCanvas(multi, capture)
            expectTrue(
                "boundary hover cursor",
                view.videoHoverCursor(at: boundaryOrigin, model: multi) === NSCursor.resizeLeftRight
            )
            expectTrue(
                "clip edge hover cursor",
                view.videoHoverCursor(at: CGPoint(x: x(9.0) + 4, y: laneMidY), model: multi) === NSCursor.resizeLeftRight
            )
            expectTrue(
                "clip body hover cursor",
                view.videoHoverCursor(at: moveOrigin, model: multi) === NSCursor.arrow
            )
            let soloView = makeCanvas(solo, capture)
            expectTrue(
                "whole-track left handle cursor",
                soloView.videoHoverCursor(at: CGPoint(x: 5, y: laneMidY), model: solo) === NSCursor.resizeLeftRight
            )
            expectTrue(
                "whole-track body cursor",
                soloView.videoHoverCursor(at: CGPoint(x: width / 2, y: laneMidY), model: solo) === NSCursor.arrow
            )
        }

        // The native drawing path must render both fixtures without trapping.
        for (name, model) in [("solo", solo), ("multi", multi)] {
            let capture = Capture()
            let view = makeCanvas(model, capture)
            checks += 1
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                fail("draw.\(name): no bitmap rep")
                continue
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            expectTrue("draw.\(name) produced pixels", rep.pixelsWide > 0 && rep.pixelsHigh > 0)
        }

        // MARK: Filmstrip orientation + tile order
        //
        // The deleted `--shot` mode rendered the strip beside the SwiftUI row
        // so a human could spot a vertical flip or a reversed tile order. The
        // fixture tiles are deliberately asymmetric (red band top, blue band
        // bottom, a green stripe marching left→right), so both defects can be
        // asserted instead of eyeballed.
        do {
            let thumbs = syntheticThumbnails(count: 24, duration: duration)
            checks += 1
            if let first = thumbs.first?.image, let px = HarnessPixels.rgba(first) {
                defer { px.deallocate() }
            func bandMean(_ y0: Int, _ y1: Int) -> (r: Double, b: Double) {
                var r = 0.0, b = 0.0, n = 0.0
                for y in y0..<y1 {
                    let row = px.bytes + y * px.bytesPerRow
                    for x in 0..<px.width {
                        r += Double((row + x * 4)[0])
                        b += Double((row + x * 4)[2])
                        n += 1
                    }
                }
                return (r / max(1, n), b / max(1, n))
            }
                // CGImage row 0 is the TOP row: red must dominate there, blue below.
                let top = bandMean(0, 8)
                let bottom = bandMean(px.height - 8, px.height)
                expectTrue("filmstrip tile is not vertically flipped", top.r > top.b && bottom.b > bottom.r)
            } else {
                fail("filmstrip: no fixture tile")
            }
        }

        // MARK: Slice tool — canvas click vs the shared math

        // Two clips split at mid-duration, playhead parked off-centre so the
        // 12pt snap window is exercised independently of the clip boundary.
        let sliceA = UUID(), sliceB = UUID()
        let mid = duration / 2
        let playheadTime = duration * 0.7
        let sliceModel = TimelineVideoRowModel(
            regionStart: 0,
            regionEnd: duration,
            usesWholeTrackDrag: false,
            clips: [clip(sliceA, 0, mid), clip(sliceB, mid, duration)],
            segments: [segment(sliceA, 0, mid), segment(sliceB, mid, duration)],
            boundaries: [],
            isMuted: false,
            hasAudio: true,
            hasThumbnails: false,
            snapCandidates: snaps
        )

        func sliceCanvas(_ capture: Capture) -> TimelineCanvasView {
            let view = TimelineCanvasView()
            view.configureForSliceHarness(
                width: width,
                outputDuration: duration,
                playheadOutputTime: playheadTime,
                trimStartOutput: 0,
                trimEndOutput: duration,
                model: sliceModel,
                callbacks: callbacks(capture)
            )
            return view
        }

        // 20 seeded clicks: the canvas commit must equal VideoSliceMath's
        // resolution, and must be suppressed exactly when it is unsliceable.
        for i in 0..<20 {
            let hitX = CGFloat(rand()) * width
            let expected = VideoSliceMath.resolvedTarget(
                atX: hitX,
                trackWidth: width,
                outputDuration: duration,
                playheadOutputTime: playheadTime
            )
            let legal = VideoSliceMath.isSliceable(
                expected.outputTime,
                trimStartOutput: 0,
                trimEndOutput: duration,
                clipSpans: sliceModel.clipSpans
            )

            let capture = Capture()
            let view = sliceCanvas(capture)
            view.harnessSliceClick(atX: hitX)

            checks += 1
            if legal {
                guard let got = capture.slicedAt else {
                    fail("slice[\(i)] x=\(hitX): no commit (expected \(expected.outputTime))")
                    continue
                }
                if abs(got - expected.outputTime) > 1e-9 {
                    fail("slice[\(i)] x=\(hitX): canvas=\(got) math=\(expected.outputTime)")
                }
            } else if let got = capture.slicedAt {
                fail("slice[\(i)] x=\(hitX): committed \(got) at an unsliceable position")
            }
        }

        // Deterministic frames of the snip animation, rendered by the real
        // canvas draw path (NSImage orientation differs between contexts —
        // never trust a standalone render of it).
        if CommandLine.arguments.contains("--snip-shot") {
            let view = sliceCanvas(Capture())
            view.frame = NSRect(x: 0, y: 0, width: width, height: 320)
            for t in [0.05, 0.28, 0.5] {
                view.harnessFreezeSnip(atX: width / 2, time: t)
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    let url = URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("snip-\(Int(t * 100)).png")
                    try? rep.representation(using: .png, properties: [:])?.write(to: url)
                    print("SNIP-SHOT \(url.path)")
                }
            }
        }

        // Playhead snapping: a click just inside the snap window must land
        // exactly on the playhead, and one just outside must not.
        let playheadX = width * CGFloat(playheadTime / duration)
        for (offset, shouldSnap) in [(VideoSliceMath.playheadSnapDistance - 1, true),
                                     (VideoSliceMath.playheadSnapDistance + 6, false)] {
            let capture = Capture()
            let view = sliceCanvas(capture)
            view.harnessSliceClick(atX: playheadX + offset)
            checks += 1
            guard let got = capture.slicedAt else {
                fail("slice.snap(offset \(offset)): no commit")
                continue
            }
            let didSnap = abs(got - playheadTime) < 1e-9
            if didSnap != shouldSnap {
                fail("slice.snap(offset \(offset)): snapped=\(didSnap) expected=\(shouldSnap)")
            }
        }

        // Guard rails: clicks inside the min-duration dead zones never commit.
        for (hitX, name) in [(CGFloat(1), "left edge"),
                             (width - 1, "right edge"),
                             (width / 2, "clip boundary")] {
            let capture = Capture()
            let view = sliceCanvas(capture)
            view.harnessSliceClick(atX: hitX)
            checks += 1
            if let got = capture.slicedAt {
                fail("slice.deadzone(\(name)): committed \(got)")
            }
        }

        // Disarmed: no slice callback may fire when the tool is off.
        do {
            let capture = Capture()
            let view = TimelineCanvasView()
            view.configureForVideoRowHarness(
                width: width,
                outputDuration: duration,
                model: sliceModel,
                callbacks: callbacks(capture)
            )
            view.harnessSliceClick(atX: width * 0.31)
            checks += 1
            if let got = capture.slicedAt {
                fail("slice.disarmed: committed \(got) with the tool off")
            }
        }

        return finish(checks: checks, failures: failures)
    }

    private static func finish(checks: Int, failures: Int) -> Never {
        if failures == 0 {
            print("VIDEOTRACK-CANVAS PASS (\(checks) checks)")
            exit(0)
        }
        print("VIDEOTRACK-CANVAS FAIL (\(failures)/\(checks))")
        exit(1)
    }

    /// Synthetic filmstrip frames: a deliberately top/bottom-asymmetric tile
    /// (red band on top, blue band at the bottom, white notch on the left) so a
    /// wrong vertical flip or tile order in the native strip is unmissable.
    private static func syntheticThumbnails(count: Int, duration: TimeInterval) -> [TimelineThumbnail] {
        let w = 64, h = 36
        return (0..<count).compactMap { index in
            guard let ctx = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            // CGContext origin is bottom-left: fill the TOP band red.
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setFillColor(NSColor.systemRed.cgColor)
            ctx.fill(CGRect(x: 0, y: h - 10, width: w, height: 10))
            ctx.setFillColor(NSColor.systemBlue.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: 10))
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(x: 2, y: h / 2 - 4, width: 6, height: 8))
            // Frame index stripe marches left→right so tile order is visible.
            ctx.setFillColor(NSColor.systemGreen.cgColor)
            let stripeX = CGFloat(index % 6) * CGFloat(w) / 6
            ctx.fill(CGRect(x: stripeX, y: CGFloat(h) / 2 - 2, width: 4, height: 4))
            guard let image = ctx.makeImage() else { return nil }
            let stride = duration / Double(count)
            return TimelineThumbnail(time: (Double(index) + 0.5) * stride, image: image)
        }
    }
}
