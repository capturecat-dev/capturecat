import AppKit
import AVFoundation

/// `CaptureCat --voicetrack-test` — acceptance test for the native VOICE row.
///
/// Drives the REAL `TimelineCanvasView` mouse machine with synthetic
/// sequences (mouseDown → 4 drag steps → mouseUp) and asserts that every value
/// crossing the commit boundary equals `VoiceTrackEditMath`'s direct result,
/// and that the drawn geometry equals a verbatim ORACLE copy of
/// `VoiceOverClipBlockView`'s pre-extraction computed properties. Exits 0 on
/// pass, 1 on any mismatch.
@MainActor
enum VoiceTrackHarness {
    private static let duration: TimeInterval = 13.6
    private static let width: CGFloat = 1200
    private static let snaps: [TimeInterval] = [0.0, 2.0, 3.03, 6.03, 9.5, 13.0]

    // MARK: - Oracle (verbatim pre-extraction VoiceOverClipBlockView geometry)

    private struct Oracle {
        var totalDuration: TimeInterval
        var trackWidth: CGFloat
        var snapCandidates: [TimeInterval]
        let minDuration: TimeInterval = 0.25

        func resolvedClip(
            from initial: VoiceOverClip,
            mode: VoiceTrackEditMath.Mode,
            delta: TimeInterval
        ) -> VoiceOverClip {
            let snapEdge: (TimeInterval, [TimeInterval]) -> TimeInterval? = { time, excludedEdges in
                let candidates = snapCandidates.filter { candidate in
                    !excludedEdges.contains(where: { abs($0 - candidate) < 0.0001 })
                }
                return TimelineSnap.nearestCandidate(
                    to: time,
                    candidates: candidates,
                    duration: totalDuration,
                    trackWidth: trackWidth
                )
            }

            var next = initial

            switch mode {
            case .none:
                break
            case .move:
                let duration = initial.duration
                let proposedStart = initial.startTime + delta
                let proposedEnd = proposedStart + duration
                let candidates = snapCandidates.filter { candidate in
                    abs(candidate - initial.startTime) >= 0.0001 && abs(candidate - initial.endTime) >= 0.0001
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
                next.startTime = max(0, min(totalDuration - duration, adjustedStart))
            case .resizeLeft:
                let snappedStart = snapEdge(initial.startTime + delta, [initial.startTime, initial.endTime])
                    ?? (initial.startTime + delta)
                let earliestStart = max(0, initial.startTime - initial.sourceStartTime)
                let latestStart = initial.endTime - minDuration
                let newStart = min(max(snappedStart, earliestStart), latestStart)
                let sourceDelta = newStart - initial.startTime
                next.startTime = newStart
                next.sourceStartTime = max(0, initial.sourceStartTime + sourceDelta)
                next.duration = max(minDuration, initial.endTime - newStart)
            case .resizeRight:
                let snappedEnd = snapEdge(initial.endTime + delta, [initial.startTime, initial.endTime])
                    ?? (initial.endTime + delta)
                let maxEnd = min(
                    totalDuration,
                    initial.startTime + max(minDuration, initial.sourceDuration - initial.sourceStartTime)
                )
                let newEnd = max(initial.startTime + minDuration, min(maxEnd, snappedEnd))
                next.duration = max(minDuration, newEnd - initial.startTime)
            }

            next.clamp(to: totalDuration)
            return next
        }

        /// Verbatim `blockWidth`.
        func blockWidth(previewClip: VoiceOverClip) -> CGFloat {
            guard totalDuration > 0 else { return trackWidth }
            return max(52, trackWidth * (previewClip.duration / totalDuration))
        }

        /// Verbatim `committedBlockOffsetX`.
        func committedBlockOffsetX(clip: VoiceOverClip) -> CGFloat {
            guard totalDuration > 0 else { return 0 }
            return trackWidth * (clip.startTime / totalDuration)
        }

        /// Verbatim `blockOffsetX + displayOffsetX`.
        func originX(
            clip: VoiceOverClip,
            previewClip: VoiceOverClip,
            mode: VoiceTrackEditMath.Mode,
            dragTranslation: CGFloat
        ) -> CGFloat {
            guard totalDuration > 0 else { return 0 }
            let committed = committedBlockOffsetX(clip: clip)
            let blockOffsetX: CGFloat
            switch mode {
            case .move: blockOffsetX = committed
            case .none, .resizeLeft, .resizeRight:
                blockOffsetX = trackWidth * (previewClip.startTime / totalDuration)
            }
            guard mode == .move else { return blockOffsetX }
            let width = blockWidth(previewClip: previewClip)
            let maxX = max(0, trackWidth - width)
            let proposedX = committed + dragTranslation
            return blockOffsetX + (min(max(proposedX, 0), maxX) - committed)
        }
    }

    // MARK: - Capture

    private final class Capture {
        var commits: [(id: UUID, clip: VoiceOverClip)] = []
        var selections: [UUID?] = []
        var deletes: [UUID] = []

        func reset() {
            commits = []
            selections = []
            deletes = []
        }
    }

    private static func callbacks(_ capture: Capture) -> TimelineVoiceCallbacks {
        TimelineVoiceCallbacks(
            selectClip: { capture.selections.append($0) },
            commitClip: { id, clip in capture.commits.append((id, clip)) },
            deleteClip: { capture.deletes.append($0) }
        )
    }

    // MARK: - Fixture builders

    private static func clip(
        _ start: TimeInterval,
        _ length: TimeInterval,
        sourceStart: TimeInterval = 0,
        sourceDuration: TimeInterval? = nil,
        label: String = "Voice Over",
        selected: Bool = false
    ) -> TimelineVoiceClipItem {
        TimelineVoiceClipItem(
            clip: VoiceOverClip(
                fileName: "voice.wav",
                startTime: start,
                sourceStartTime: sourceStart,
                duration: length,
                sourceDuration: sourceDuration ?? (length + sourceStart + 2),
                label: label
            ),
            isSelected: selected
        )
    }

    private static func makeCanvas(
        _ model: TimelineVoiceRowModel,
        _ capture: Capture,
        assets: TimelineVoiceAssets = TimelineVoiceAssets()
    ) -> TimelineCanvasView {
        let view = TimelineCanvasView()
        view.configureForVoiceRowHarness(
            width: width,
            outputDuration: duration,
            model: model,
            callbacks: callbacks(capture),
            assets: assets
        )
        return view
    }

    /// One synthetic press → 4 drag steps → release.
    private static func drive(
        _ view: TimelineCanvasView,
        _ model: TimelineVoiceRowModel,
        from origin: CGPoint,
        dx: CGFloat
    ) {
        view.voiceMouseDown(at: origin, model: model)
        for step in 1...4 {
            view.voiceMouseDragged(to: CGPoint(x: origin.x + dx * CGFloat(step) / 4, y: origin.y))
        }
        view.voiceMouseUp(at: CGPoint(x: origin.x + dx, y: origin.y), model: model)
    }

    private static func x(_ t: TimeInterval) -> CGFloat { width * CGFloat(t / duration) }

    private static var laneMidY: CGFloat {
        TimelineCanvasMetrics.voiceLaneY + TimelineCanvasMetrics.trackHeight / 2
    }

    private static var laneRect: CGRect {
        CGRect(
            x: 0,
            y: TimelineCanvasMetrics.voiceLaneY,
            width: width,
            height: TimelineCanvasMetrics.trackHeight
        )
    }

    private static func render(_ view: TimelineCanvasView) -> NSBitmapImageRep? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: laneRect) else { return nil }
        view.cacheDisplay(in: laneRect, to: rep)
        return rep
    }

    /// Count of non-transparent pixels — "did anything draw at all".
    private static func inkedPixels(_ rep: NSBitmapImageRep) -> Int {
        guard let data = rep.bitmapData else { return 0 }
        let bytesPerPixel = rep.bitsPerPixel / 8
        var count = 0
        for y in 0..<rep.pixelsHigh {
            let row = data + y * rep.bytesPerRow
            for px in 0..<rep.pixelsWide {
                let p = row + px * bytesPerPixel
                if p[3] > 8 { count += 1 }
            }
        }
        return count
    }

    private static func pixelDelta(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
        guard let da = a.bitmapData, let db = b.bitmapData,
              a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return -1 }
        let bpp = a.bitsPerPixel / 8
        var differing = 0
        for y in 0..<a.pixelsHigh {
            let ra = da + y * a.bytesPerRow
            let rb = db + y * b.bytesPerRow
            for px in 0..<a.pixelsWide {
                let pa = ra + px * bpp
                let pb = rb + px * bpp
                if pa[0] != pb[0] || pa[1] != pb[1] || pa[2] != pb[2] || pa[3] != pb[3] {
                    differing += 1
                }
            }
        }
        return differing
    }

    // MARK: - Runner

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
            guard let actual else { return fail("\(label): no value (expected \(expected))") }
            if abs(actual - expected) > 1e-9 {
                fail("\(label): canvas=\(actual) oracle=\(expected)")
            }
        }

        func expectPx(_ label: String, _ actual: CGFloat, _ expected: CGFloat) {
            checks += 1
            if abs(actual - expected) > 1e-9 {
                fail("\(label): canvas=\(actual) oracle=\(expected)")
            }
        }

        func expectTrue(_ label: String, _ condition: Bool) {
            checks += 1
            if !condition { fail(label) }
        }

        // Deterministic RNG (splitmix64) so failures reproduce.
        var state: UInt64 = 0x5EED_0000_C0FF_EE01
        func rand() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Double(z >> 11) / Double(1 << 53)
        }

        let oracle = Oracle(totalDuration: duration, trackWidth: width, snapCandidates: snaps)

        // ------------------------------------------------------------------
        // Fixture: three voice clips, one selected, one with a source offset
        // (so resizeLeft's `earliestStart` clamp has teeth).
        // ------------------------------------------------------------------
        let base = TimelineVoiceRowModel(
            clips: [
                clip(0.4, 2.6, label: "Intro"),
                clip(4.0, 3.2, sourceStart: 1.4, sourceDuration: 8.0, label: "Take 2", selected: true),
                clip(9.0, 2.0, label: "Outro"),
            ],
            live: nil,
            snapCandidates: snaps
        )
        let capture = Capture()

        // ------------------------------------------------------------------
        // 1. Hit-kind classification at every zone of every clip.
        // ------------------------------------------------------------------
        do {
            let view = makeCanvas(base, capture)
            for item in base.clips {
                let rect = view.voiceCommittedRect(item, model: base)
                expectPx("rect.x[\(item.clip.label)]", rect.minX, oracle.committedBlockOffsetX(clip: item.clip))
                expectPx("rect.w[\(item.clip.label)]", rect.width, oracle.blockWidth(previewClip: item.clip))

                let probes: [(CGFloat, VoiceTrackEditMath.Mode, String)] = [
                    (rect.minX + 1, .resizeLeft, "left-edge"),
                    (rect.minX + 7.9, .resizeLeft, "left-edge-inner"),
                    (rect.minX + 8.1, .move, "body-left"),
                    (rect.midX, .move, "body-mid"),
                    (rect.maxX - 8.1, .move, "body-right"),
                    (rect.maxX - 1, .resizeRight, "right-edge"),
                ]
                for (px, expected, name) in probes {
                    let mode = view.voiceDragMode(
                        at: CGPoint(x: px, y: laneMidY), item: item, model: base
                    )
                    expectTrue("hitkind[\(item.clip.label)/\(name)] got \(mode)", mode == expected)
                }
            }
        }

        // ------------------------------------------------------------------
        // 2. Seeded random drags, per gesture type, per clip.
        //    Every committed value must equal the ORACLE's resolve.
        // ------------------------------------------------------------------
        let gestures: [(VoiceTrackEditMath.Mode, String)] = [
            (.move, "move"), (.resizeLeft, "resizeLeft"), (.resizeRight, "resizeRight"),
        ]
        for (mode, name) in gestures {
            for item in base.clips {
                for trial in 0..<20 {
                    let view = makeCanvas(base, capture)
                    capture.reset()
                    let rect = view.voiceCommittedRect(item, model: base)
                    let originX: CGFloat
                    switch mode {
                    case .resizeLeft: originX = rect.minX + 3
                    case .resizeRight: originX = rect.maxX - 3
                    case .move, .none: originX = rect.midX
                    }
                    // ±420px, always past the 3pt activation threshold.
                    let dx = CGFloat((rand() - 0.5) * 840)
                    let signedDx = abs(dx) < 4 ? (dx < 0 ? -4 : 4) : dx

                    drive(view, base, from: CGPoint(x: originX, y: laneMidY), dx: signedDx)

                    let delta = TimeInterval(signedDx / width) * duration
                    let expected = oracle.resolvedClip(from: item.clip, mode: mode, delta: delta)
                    let label = "\(name)[\(item.clip.label)#\(trial)]"

                    guard let commit = capture.commits.last else {
                        fail("\(label): no commit"); checks += 1; continue
                    }
                    expectTrue("\(label): commit id", commit.id == item.id)
                    expect("\(label).start", commit.clip.startTime, expected.startTime)
                    expect("\(label).duration", commit.clip.duration, expected.duration)
                    expect("\(label).sourceStart", commit.clip.sourceStartTime, expected.sourceStartTime)
                    expect("\(label).sourceDuration", commit.clip.sourceDuration, expected.sourceDuration)
                    expectTrue("\(label): exactly one commit", capture.commits.count == 1)
                }
            }
        }

        // ------------------------------------------------------------------
        // 3. Live preview geometry mid-drag == the SwiftUI computed properties.
        // ------------------------------------------------------------------
        for (mode, name) in gestures {
            for item in base.clips {
                for trial in 0..<8 {
                    let view = makeCanvas(base, capture)
                    let rect = view.voiceCommittedRect(item, model: base)
                    let originX: CGFloat
                    switch mode {
                    case .resizeLeft: originX = rect.minX + 3
                    case .resizeRight: originX = rect.maxX - 3
                    case .move, .none: originX = rect.midX
                    }
                    let dx = CGFloat((rand() - 0.5) * 900)
                    view.voiceMouseDown(at: CGPoint(x: originX, y: laneMidY), model: base)
                    view.voiceMouseDragged(to: CGPoint(x: originX + dx, y: laneMidY))

                    let delta = TimeInterval(dx / width) * duration
                    let preview = oracle.resolvedClip(from: item.clip, mode: mode, delta: delta)
                    let label = "preview-\(name)[\(item.clip.label)#\(trial)]"
                    let drawn = view.voiceClipRect(item, model: base)
                    expectPx("\(label).w", drawn.width, oracle.blockWidth(previewClip: preview))
                    expectPx("\(label).x", drawn.minX, oracle.originX(
                        clip: item.clip, previewClip: preview, mode: mode, dragTranslation: dx
                    ))
                    // Move preview must never leave the track.
                    if mode == .move {
                        expectTrue("\(label): in-bounds",
                                   drawn.minX >= -1e-9 && drawn.maxX <= width + 1e-9)
                    }
                    view.voiceMouseUp(at: CGPoint(x: originX + dx, y: laneMidY), model: base)
                }
            }
        }

        // ------------------------------------------------------------------
        // 4. Sub-threshold tap selects and commits nothing.
        // ------------------------------------------------------------------
        for item in base.clips {
            for dx in [CGFloat(0), 1, -2.9] {
                let view = makeCanvas(base, capture)
                capture.reset()
                let rect = view.voiceCommittedRect(item, model: base)
                drive(view, base, from: CGPoint(x: rect.midX, y: laneMidY), dx: dx)
                expectTrue("tap[\(item.clip.label)/\(dx)]: no commit", capture.commits.isEmpty)
                expectTrue("tap[\(item.clip.label)/\(dx)]: selects",
                           capture.selections.last.map { $0 == item.id } ?? false)
            }
        }

        // ------------------------------------------------------------------
        // 5. Empty lane: deselect, no drag, caller scrubs.
        // ------------------------------------------------------------------
        do {
            let view = makeCanvas(base, capture)
            capture.reset()
            let started = view.voiceMouseDown(at: CGPoint(x: x(7.6), y: laneMidY), model: base)
            expectTrue("empty-lane: no drag", !started)
            expectTrue("empty-lane: deselect", capture.selections == [nil])
            expectTrue("empty-lane: no commit", capture.commits.isEmpty)
        }

        // ------------------------------------------------------------------
        // 6. Already-selected clip is not re-selected on press (the SwiftUI
        //    block guards with `if !isSelected`).
        // ------------------------------------------------------------------
        do {
            let view = makeCanvas(base, capture)
            capture.reset()
            let selected = base.clips[1]
            let rect = view.voiceCommittedRect(selected, model: base)
            view.voiceMouseDown(at: CGPoint(x: rect.midX, y: laneMidY), model: base)
            expectTrue("press-selected: no redundant select", capture.selections.isEmpty)

            capture.reset()
            let other = base.clips[0]
            let otherRect = view.voiceCommittedRect(other, model: base)
            view.voiceMouseDown(at: CGPoint(x: otherRect.midX, y: laneMidY), model: base)
            expectTrue("press-unselected: selects", capture.selections == [other.id])
        }

        // ------------------------------------------------------------------
        // 7. Overlapping clips: the later one in the array wins (draw order).
        // ------------------------------------------------------------------
        do {
            let overlapping = TimelineVoiceRowModel(
                clips: [clip(2.0, 4.0, label: "Under"), clip(3.0, 4.0, label: "Over")],
                live: nil,
                snapCandidates: snaps
            )
            let view = makeCanvas(overlapping, capture)
            let hit = view.voiceClipItem(at: CGPoint(x: x(4.0), y: laneMidY), model: overlapping)
            expectTrue("overlap z-order", hit?.id == overlapping.clips[1].id)
            let soloHit = view.voiceClipItem(at: CGPoint(x: x(2.2), y: laneMidY), model: overlapping)
            expectTrue("overlap non-overlapped region", soloHit?.id == overlapping.clips[0].id)
        }

        // ------------------------------------------------------------------
        // 8. Context menu shape + wiring.
        // ------------------------------------------------------------------
        do {
            let view = makeCanvas(base, capture)
            capture.reset()
            let item = base.clips[2]
            let rect = view.voiceCommittedRect(item, model: base)
            let menu = view.voiceContextMenu(at: CGPoint(x: rect.midX, y: laneMidY), model: base)
            expectTrue("menu: exists", menu != nil)
            expectTrue("menu: one item", menu?.items.count == 1)
            expectTrue("menu: title", menu?.items.first?.title == "Delete Voice Over")
            if let entry = menu?.items.first, let target = entry.target, let action = entry.action {
                _ = (target as AnyObject).perform(action)
            }
            expectTrue("menu: deletes the right clip", capture.deletes == [item.id])

            let empty = view.voiceContextMenu(at: CGPoint(x: x(7.6), y: laneMidY), model: base)
            expectTrue("menu: none on empty lane", empty == nil)
        }

        // ------------------------------------------------------------------
        // 9. Hover cursors.
        // ------------------------------------------------------------------
        do {
            let view = makeCanvas(base, capture)
            let item = base.clips[0]
            let rect = view.voiceCommittedRect(item, model: base)
            expectTrue("cursor: left edge",
                       view.voiceHoverCursor(at: CGPoint(x: rect.minX + 2, y: laneMidY), model: base) === NSCursor.resizeLeftRight)
            expectTrue("cursor: right edge",
                       view.voiceHoverCursor(at: CGPoint(x: rect.maxX - 2, y: laneMidY), model: base) === NSCursor.resizeLeftRight)
            expectTrue("cursor: body",
                       view.voiceHoverCursor(at: CGPoint(x: rect.midX, y: laneMidY), model: base) === NSCursor.openHand)
            expectTrue("cursor: background",
                       view.voiceHoverCursor(at: CGPoint(x: x(7.6), y: laneMidY), model: base) == nil)
        }

        // ------------------------------------------------------------------
        // 10. Live recording block geometry (port of its blockWidth/offset).
        // ------------------------------------------------------------------
        do {
            let cases: [(TimeInterval, TimeInterval)] = [(0, 0.05), (2.0, 5.0), (11.0, 13.5), (5.0, 5.0)]
            for (start, now) in cases {
                let live = TimelineVoiceLiveItem(startTime: start, currentTime: now, samples: [])
                let model = TimelineVoiceRowModel(clips: [], live: live, snapCandidates: snaps)
                let view = makeCanvas(model, capture)
                let rect = view.voiceLiveRect(live)
                let expectedWidth = max(52, width * CGFloat(max(0.1, now - start) / duration))
                expectPx("live.x[\(start)]", rect.minX, width * CGFloat(start / duration))
                expectPx("live.w[\(start)]", rect.width, expectedWidth)
                expectTrue("live: not hit-testable",
                           view.voiceClipItem(at: CGPoint(x: rect.midX, y: laneMidY), model: model) == nil)
            }
        }

        // ------------------------------------------------------------------
        // 11. Rendering: the lane actually draws, and the live waveform is
        //     driven by the sample array (different samples ⇒ different pixels).
        // ------------------------------------------------------------------
        do {
            let waveforms: [UUID: [Float]] = Dictionary(
                uniqueKeysWithValues: base.clips.map { item in
                    (item.id, (0..<72).map { Float(abs(sin(Double($0) * 0.37)) * 0.9 + 0.05) })
                }
            )
            let withWaves = makeCanvas(
                base, capture,
                assets: TimelineVoiceAssets(waveforms: waveforms, signature: "waves")
            )
            let noWaves = makeCanvas(base, capture)
            guard let repWaves = render(withWaves), let repPlain = render(noWaves) else {
                fail("render: cacheDisplay failed"); checks += 1
                print("VOICETRACK \(failures == 0 ? "PASS" : "FAIL") (\(checks) checks)")
                exit(1)
            }
            expectTrue("render: clips draw", inkedPixels(repWaves) > 5_000)
            expectTrue("render: waveform changes pixels", pixelDelta(repWaves, repPlain) > 500)

            // Live block: three different synthetic sample arrays.
            let flat = [Float](repeating: 0.1, count: 48)
            let loud = [Float](repeating: 0.95, count: 48)
            let ramp = (0..<48).map { Float($0) / 48 }
            var reps: [NSBitmapImageRep] = []
            for samples in [flat, loud, ramp, []] {
                let live = TimelineVoiceLiveItem(startTime: 1.0, currentTime: 6.0, samples: samples)
                let model = TimelineVoiceRowModel(clips: [], live: live, snapCandidates: snaps)
                let view = makeCanvas(model, capture)
                guard let rep = render(view) else { fail("live render failed"); checks += 1; continue }
                reps.append(rep)
                expectTrue("live render inked (\(samples.count) samples)", inkedPixels(rep) > 1_500)
            }
            if reps.count == 4 {
                expectTrue("live: flat vs loud differ", pixelDelta(reps[0], reps[1]) > 200)
                expectTrue("live: loud vs ramp differ", pixelDelta(reps[1], reps[2]) > 200)
                expectTrue("live: empty falls back to placeholder bars",
                           pixelDelta(reps[3], reps[0]) > 0 && inkedPixels(reps[3]) > 1_500)
            }

            // A growing recording widens the block monotonically.
            var previous: CGFloat = 0
            for now in stride(from: 1.2, through: 9.0, by: 0.9) {
                let live = TimelineVoiceLiveItem(startTime: 1.0, currentTime: now, samples: flat)
                let model = TimelineVoiceRowModel(clips: [], live: live, snapCandidates: snaps)
                let view = makeCanvas(model, capture)
                let w = view.voiceLiveRect(live).width
                expectTrue("live grows (\(now))", w >= previous - 1e-9)
                previous = w
            }
        }

        // ------------------------------------------------------------------
        // 12. Min-width floor: a very short clip still draws 52pt wide and
        //     stays grabbable at both edges.
        // ------------------------------------------------------------------
        do {
            let tiny = TimelineVoiceRowModel(
                clips: [clip(6.0, 0.3, label: "Blip")], live: nil, snapCandidates: snaps
            )
            let view = makeCanvas(tiny, capture)
            let item = tiny.clips[0]
            let rect = view.voiceCommittedRect(item, model: tiny)
            expectPx("tiny.width floor", rect.width, 52)
            expectTrue("tiny: left grab",
                       view.voiceDragMode(at: CGPoint(x: rect.minX + 2, y: laneMidY), item: item, model: tiny) == .resizeLeft)
            expectTrue("tiny: right grab",
                       view.voiceDragMode(at: CGPoint(x: rect.maxX - 2, y: laneMidY), item: item, model: tiny) == .resizeRight)
            expectTrue("tiny: body",
                       view.voiceDragMode(at: CGPoint(x: rect.midX, y: laneMidY), item: item, model: tiny) == .move)
        }

        print("VOICETRACK \(failures == 0 ? "PASS" : "FAIL") (\(checks) checks, \(failures) failures)")
        exit(failures == 0 ? 0 : 1)
    }

    /// A deterministic mono WAV in the project directory so BOTH rows load the
    /// same real waveform through `WaveformGenerator`.
    private static func writeVoiceFile(in directory: URL) -> Bool {
        let url = directory.appendingPathComponent("voice.wav")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)

        let sampleRate = 44_100.0
        let seconds = 9.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return false }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let frames = AVAudioFrameCount(sampleRate * seconds)
        guard let file = try? AVAudioFile(forWriting: url, settings: settings),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buffer.floatChannelData?[0] else { return false }
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            let t = Double(i) / sampleRate
            // Slow envelope × fast carrier: bars vary visibly along the clip.
            let envelope = 0.15 + 0.85 * abs(sin(t * 1.3)) * abs(sin(t * 0.31))
            channel[i] = Float(envelope * sin(t * 2 * .pi * 220))
        }
        return (try? file.write(from: buffer)) != nil
    }
}
