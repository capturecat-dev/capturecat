import Foundation
import CoreGraphics

// Golden-vector units for the TIME cluster: SpeedTimeMap, the clip/trim
// model, the exported-duration cap, TimelineSnap, VideoTrackEditMath and
// VoiceTrackEditMath. TS ports: apps/web/src/editor/core/time/.
extension WebVectors {
    static var timeUnits: [WebVectorUnit] {
        [
            WebVectorUnit(
                name: "speedTimeMap",
                notes: "Services/SpeedTimeMap.swift — init(sourceStart:sourceEnd:regions:), segments, outputDuration, sourceTime(forOutput:), outputTime(forSource:), speed(atSource:)",
                build: speedTimeMapCases),
            WebVectorUnit(
                name: "projectClips",
                notes: "Models/Project.swift — effectiveTrimStart/End, trimmedDuration, effectiveVideoClipSegments (incl. stableLegacyClipID), visibleVideoClip, hasVisibleVideo",
                build: projectClipCases),
            WebVectorUnit(
                name: "exportedDuration",
                notes: "VideoExporter.export 'Cap export at the last visible clip' — verbatim (identical to the uncommitted Project.exportedOutputDuration(timeMap:) extraction) over SpeedTimeMap(sourceStart: effectiveTrimStart, sourceEnd: exporter trimEnd)",
                build: exportedDurationCases),
            WebVectorUnit(
                name: "timelineSnap",
                notes: "Views/Editor/TimelineSnap.swift — majorInterval, minorInterval, snap, snapThreshold, nearestCandidate, magneticSnap, snappedEdge, clamp",
                build: timelineSnapCases),
            WebVectorUnit(
                name: "videoTrackEditMath",
                notes: "Views/Editor/VideoTrackEditMath.swift — resolvedTimes, moveBounds, resizeBounds, snapClipMoveStart, snapClipEdge, resolvedClipMoveOutputStart, resolvedClipEdgeOutput",
                build: videoTrackEditCases),
            WebVectorUnit(
                name: "voiceTrackEditMath",
                notes: "Views/Editor/VoiceTrackRowNative.swift VoiceTrackEditMath (delta, resolvedClip incl. VoiceOverClip.clamp) + VoiceTrackCommits.outputClip/commit mapping",
                build: voiceTrackEditCases),
        ]
    }

    // MARK: SpeedTimeMap

    private static func randomSpeedRegions(_ rng: inout WVRandom, span: ClosedRange<Double>) -> [VideoSpeedRegion] {
        let count = rng.int(0, 5)
        return (0..<count).map { _ in
            let a = rng.edgy(span.lowerBound - 2, span.upperBound + 2, edges: [span.lowerBound, span.upperBound, 0])
            let len = rng.edgy(0, (span.upperBound - span.lowerBound) * 0.6 + 0.5, edges: [0, 0.00005, 0.0002, 1])
            let speed = rng.edgy(0.05, 8, edges: [0.1, 0.5, 1, 2, 4, 0, -1, 16])
            return VideoSpeedRegion(id: rng.uuid(), startTime: a, endTime: a + len, speed: speed)
        }
    }

    private static func speedMapWV(_ map: SpeedTimeMap) -> WV {
        [
            "segments": .arr(map.segments.map {
                ["sourceStart": $0.sourceStart.wv, "sourceEnd": $0.sourceEnd.wv,
                 "outputStart": $0.outputStart.wv, "outputEnd": $0.outputEnd.wv, "speed": $0.speed.wv]
            }),
            "outputDuration": map.outputDuration.wv,
        ]
    }

    private static func speedTimeMapCases() -> [WV] {
        var rng = WVRandom(seed: "speedTimeMap")
        var cases: [WV] = []
        for i in 0..<1200 {
            let start = i % 7 == 0 ? 0 : rng.edgy(0, 20, edges: [0, 1, 5])
            let len = rng.edgy(0, 60, edges: [0, 0.01, 1, 30])
            let end = i % 23 == 0 ? start - 1 : start + len  // occasional inverted window
            let regions = randomSpeedRegions(&rng, span: start...max(start, end))
            let map = SpeedTimeMap(sourceStart: start, sourceEnd: end, regions: regions)
            let outQueries: [Double] = (0..<8).map { _ in
                rng.edgy(-1, map.outputDuration + 1, edges: [0, map.outputDuration, -0.0001])
            } + map.segments.flatMap { [$0.outputStart, $0.outputEnd] }.prefix(6)
            let srcQueries: [Double] = (0..<8).map { _ in
                rng.edgy(start - 1, end + 1, edges: [start, end])
            } + map.segments.flatMap { [$0.sourceStart, $0.sourceEnd] }.prefix(6)
            cases.append(vcase(
                [
                    "sourceStart": start.wv,
                    "sourceEnd": end.wv,
                    "regions": .arr(regions.map(WVModel.speedRegion)),
                    "outputQueries": outQueries.wv,
                    "sourceQueries": srcQueries.wv,
                ],
                speedMapWV(map).setting("sourceForOutput", outQueries.map { map.sourceTime(forOutput: $0) }.wv)
                    .setting("outputForSource", srcQueries.map { map.outputTime(forSource: $0) }.wv)
                    .setting("speedAtSource", srcQueries.map { map.speed(atSource: $0) }.wv)
            ))
        }
        return cases
    }

    // MARK: Project clips / trim

    private static func randomClipProject(_ rng: inout WVRandom, index i: Int) -> Project {
        let duration = i % 31 == 0 ? 0 : rng.edgy(0, 90, edges: [0.01, 8, 30, 60])
        let p = Project(id: rng.uuid(), name: "v", duration: duration)
        p.trimStart = rng.edgy(-2, duration, edges: [0, duration, -0.0])
        p.trimEnd = rng.edgy(-1, duration + 3, edges: [0, duration, duration + 1])
        let splitCount = rng.int(0, 6)
        p.splitPoints = (0..<splitCount).map { _ in
            rng.edgy(-1, duration + 1, edges: [0, duration, p.trimStart + 0.005, p.trimEnd - 0.005, 0.0078125, 1.5078125])
        }
        if rng.bool(0.5) {
            let clipCount = rng.int(1, 5)
            p.videoClipSegments = (0..<clipCount).map { _ in
                let s = rng.edgy(-1, duration + 1, edges: [0, duration, p.trimStart])
                let l = rng.edgy(-0.5, duration * 0.5 + 0.1, edges: [0, 0.005, 0.02])
                return VideoClipSegment(id: rng.uuid(), startTime: s, endTime: s + l)
            }
        }
        return p
    }

    private static func projectClipCases() -> [WV] {
        var rng = WVRandom(seed: "projectClips")
        var cases: [WV] = []
        for i in 0..<1500 {
            let p = randomClipProject(&rng, index: i)
            let clips = p.effectiveVideoClipSegments
            var queries: [WV] = []
            for _ in 0..<10 {
                let t = rng.edgy(-1, p.duration + 1, edges: clips.flatMap { [$0.startTime, $0.endTime] } + [0])
                let tol: Double? = rng.bool(0.3) ? rng.edgy(0, 0.2, edges: [0, 1.0 / 60]) : nil
                let found = tol.map { p.visibleVideoClip(containing: t, tolerance: $0) } ?? p.visibleVideoClip(containing: t)
                let has = tol.map { p.hasVisibleVideo(at: t, tolerance: $0) } ?? p.hasVisibleVideo(at: t)
                queries.append([
                    "t": t.wv,
                    "tolerance": tol.wv,
                    "clipID": found.map { WV.str($0.id.uuidString) } ?? .null,
                    "has": has.wv,
                ])
            }
            let project: WV = [
                "id": .str(p.id.uuidString),
                "duration": p.duration.wv,
                "trimStart": p.trimStart.wv,
                "trimEnd": p.trimEnd.wv,
                "splitPoints": p.splitPoints.wv,
                "videoClipSegments": .arr(p.videoClipSegments.map(WVModel.clip)),
            ]
            cases.append(vcase(
                ["project": project, "queries": .arr(queries)],
                [
                    "effectiveTrimStart": p.effectiveTrimStart.wv,
                    "effectiveTrimEnd": p.effectiveTrimEnd.wv,
                    "trimmedDuration": p.trimmedDuration.wv,
                    "effectiveVideoClipSegments": .arr(clips.map(WVModel.clip)),
                    "queries": .arr(queries),
                ]
            ))
        }
        return cases
    }

    // MARK: Exported duration

    private static func exportedDurationCases() -> [WV] {
        var rng = WVRandom(seed: "exportedDuration")
        var cases: [WV] = []
        for i in 0..<1200 {
            let p = randomClipProject(&rng, index: i)
            p.speedRegions = randomSpeedRegions(&rng, span: 0...max(0.01, p.duration))
            // The exporter's window: asset duration when effectiveTrimEnd is 0.
            let assetDuration = rng.bool(0.8) ? p.duration : rng.edgy(0, 90, edges: [p.duration + 0.5])
            let trimStart = p.effectiveTrimStart
            let trimEnd = p.effectiveTrimEnd > 0 ? p.effectiveTrimEnd : assetDuration
            let timeMap = SpeedTimeMap(sourceStart: trimStart, sourceEnd: trimEnd, regions: p.speedRegions)
            // Verbatim VideoExporter.export (HEAD) — the cap.
            let lastVisibleOutput = p.effectiveVideoClipSegments
                .map { timeMap.outputTime(forSource: $0.endTime) }
                .max() ?? timeMap.outputDuration
            let totalSeconds = max(0.0001, min(timeMap.outputDuration, lastVisibleOutput))
            // Output frame cadence (exportFrameTimes) is a separate unit; the
            // trimmed-output map (SpeedTimeMap(trimmedOutputOf:)) is recorded
            // too so the web's playhead map is locked as well.
            let trimmedMap = SpeedTimeMap(
                sourceStart: trimStart,
                sourceEnd: max(trimStart, p.effectiveTrimEnd),
                regions: p.speedRegions)
            cases.append(vcase(
                [
                    "project": [
                        "id": .str(p.id.uuidString),
                        "duration": p.duration.wv,
                        "trimStart": p.trimStart.wv,
                        "trimEnd": p.trimEnd.wv,
                        "splitPoints": p.splitPoints.wv,
                        "videoClipSegments": .arr(p.videoClipSegments.map(WVModel.clip)),
                        "speedRegions": .arr(p.speedRegions.map(WVModel.speedRegion)),
                    ],
                    "assetDuration": assetDuration.wv,
                ],
                [
                    "exportSourceStart": trimStart.wv,
                    "exportSourceEnd": trimEnd.wv,
                    "exportMapOutputDuration": timeMap.outputDuration.wv,
                    "totalSeconds": totalSeconds.wv,
                    "trimmedMapOutputDuration": trimmedMap.outputDuration.wv,
                ]
            ))
        }
        return cases
    }

    // MARK: TimelineSnap

    private static func timelineSnapCases() -> [WV] {
        var rng = WVRandom(seed: "timelineSnap")
        var cases: [WV] = []
        for _ in 0..<1500 {
            let duration = rng.edgy(0, 600, edges: [0, 0.5, 8, 60, 3600])
            let width = rng.edgy(0, 3000, edges: [0, 1, 320, 1200])
            let pps = rng.edgy(0, 800, edges: [0, 14.4, 72, 288, 1e-6])
            let time = rng.edgy(-5, duration + 5, edges: [0, duration])
            let candidates: [Double] = (0..<rng.int(0, 8)).map { _ in
                rng.edgy(-2, duration + 2, edges: [0, duration, time, time + 0.05, time - 0.05])
            }
            let start = rng.edgy(0, duration, edges: candidates)
            let end = start + rng.edgy(0, 10, edges: [0])
            let checkStart = rng.bool(), checkEnd = rng.bool()
            cases.append(vcase(
                [
                    "duration": duration.wv, "trackWidth": width.wv, "pixelsPerSecond": pps.wv,
                    "time": time.wv, "candidates": candidates.wv,
                    "start": start.wv, "end": end.wv, "checkStart": checkStart.wv, "checkEnd": checkEnd.wv,
                ],
                [
                    "majorInterval": TimelineSnap.majorInterval(for: CGFloat(pps)).wv,
                    "minorInterval": TimelineSnap.minorInterval(duration: duration, trackWidth: CGFloat(width)).wv,
                    "snap": TimelineSnap.snap(time, duration: duration, trackWidth: CGFloat(width)).wv,
                    "snapThreshold": TimelineSnap.snapThreshold(duration: duration, trackWidth: CGFloat(width)).wv,
                    "nearestCandidate": TimelineSnap.nearestCandidate(
                        to: time, candidates: candidates, duration: duration, trackWidth: CGFloat(width)).wv,
                    "magneticSnap": TimelineSnap.magneticSnap(
                        time: time, candidates: candidates, duration: duration, trackWidth: CGFloat(width)).wv,
                    "snappedEdge": TimelineSnap.snappedEdge(
                        start: start, end: end, candidates: candidates,
                        checkStart: checkStart, checkEnd: checkEnd).wv,
                    "clamp": TimelineSnap.clamp(time, duration: duration).wv,
                ]
            ))
        }
        return cases
    }

    // MARK: VideoTrackEditMath

    private static func videoTrackEditCases() -> [WV] {
        var rng = WVRandom(seed: "videoTrackEditMath")
        var cases: [WV] = []
        let modes: [(VideoTrackEditMath.DragMode, String)] = [
            (.none, "none"), (.move, "move"), (.resizeLeft, "resizeLeft"), (.resizeRight, "resizeRight"),
        ]
        for _ in 0..<1500 {
            let duration = rng.edgy(0, 120, edges: [0, 1, 10, 60])
            let width = rng.edgy(0, 2400, edges: [0, 400, 1200])
            let candidates: [Double] = (0..<rng.int(0, 8)).map { _ in rng.edgy(-1, duration + 1, edges: [0, duration]) }
            let regionStart = rng.edgy(0, duration, edges: [0])
            let regionEnd = regionStart + rng.edgy(0, duration, edges: [0])
            let math = VideoTrackEditMath(
                duration: duration, trackWidth: CGFloat(width), snapCandidates: candidates,
                regionStart: regionStart, regionEnd: regionEnd)
            let (mode, modeName) = rng.pick(modes)
            let delta = rng.edgy(-duration, duration, edges: [0, 0.001, -0.001])
            let dragStart = rng.edgy(0, duration, edges: candidates + [0])
            let dragEnd = dragStart + rng.edgy(0, duration, edges: [0, 0.4, 0.5])
            let resolved = math.resolvedTimes(mode: mode, delta: delta, dragInitialStart: dragStart, dragInitialEnd: dragEnd)

            // Multi-clip spans: sorted, non-overlapping-ish (random gaps).
            var spans: [VideoTrackEditMath.ClipSpan] = []
            var cursor = rng.edgy(0, 2, edges: [0])
            for _ in 0..<rng.int(1, 5) {
                let len = rng.edgy(0.1, max(0.2, duration / 3), edges: [0.5, 0.25])
                spans.append(.init(id: rng.uuid(), outputStart: cursor, outputEnd: cursor + len))
                cursor += len + rng.edgy(0, 2, edges: [0])
            }
            let clip = rng.pick(spans)
            let side: (VideoTrackEditMath.Side, String) = rng.bool() ? (.left, "left") : (.right, "right")
            let proposed = rng.edgy(-2, duration + 2, edges: candidates + [clip.outputStart, clip.outputEnd])
            let snaps = rng.bool(0.7)
            let excluded: [Double] = rng.bool() ? [clip.outputStart, clip.outputEnd] : []
            let moveBounds = math.moveBounds(for: clip, in: spans)
            let resizeBounds = math.resizeBounds(for: clip, side: side.0, in: spans)
            func spanWV(_ s: VideoTrackEditMath.ClipSpan) -> WV {
                ["id": .str(s.id.uuidString), "outputStart": s.outputStart.wv, "outputEnd": s.outputEnd.wv]
            }
            cases.append(vcase(
                [
                    "duration": duration.wv, "trackWidth": width.wv, "snapCandidates": candidates.wv,
                    "regionStart": regionStart.wv, "regionEnd": regionEnd.wv,
                    "mode": .str(modeName), "delta": delta.wv,
                    "dragInitialStart": dragStart.wv, "dragInitialEnd": dragEnd.wv,
                    "clips": .arr(spans.map(spanWV)), "clipIndex": .int(spans.firstIndex { $0.id == clip.id }!),
                    "side": .str(side.1), "proposed": proposed.wv, "snapsToCandidates": snaps.wv,
                    "excluded": excluded.wv,
                ],
                [
                    "resolvedTimes": ["start": resolved.start.wv, "end": resolved.end.wv],
                    "moveBounds": ["lower": moveBounds.lower.wv, "upper": moveBounds.upper.wv],
                    "resizeBounds": ["lower": resizeBounds.lower.wv, "upper": resizeBounds.upper.wv],
                    "snapClipMoveStart": math.snapClipMoveStart(
                        proposed, proposedOutputEnd: proposed + (clip.outputEnd - clip.outputStart),
                        clipDuration: clip.outputEnd - clip.outputStart, excluding: excluded).wv,
                    "snapClipEdge": math.snapClipEdge(proposed, excluding: excluded).wv,
                    "resolvedClipMoveOutputStart": math.resolvedClipMoveOutputStart(
                        clip, in: spans, proposedOutputStart: proposed, snapsToCandidates: snaps).wv,
                    "resolvedClipEdgeOutput": math.resolvedClipEdgeOutput(
                        clip, in: spans, side: side.0, proposedOutput: proposed, snapsToCandidates: snaps).wv,
                ]
            ))
        }
        return cases
    }

    // MARK: VoiceTrackEditMath

    private static func voiceTrackEditCases() -> [WV] {
        var rng = WVRandom(seed: "voiceTrackEditMath")
        var cases: [WV] = []
        let modes: [(VoiceTrackEditMath.Mode, String)] = [
            (.none, "none"), (.move, "move"), (.resizeLeft, "resizeLeft"), (.resizeRight, "resizeRight"),
        ]
        for _ in 0..<1500 {
            let total = rng.edgy(0, 120, edges: [0, 1, 10, 60])
            let width = rng.edgy(0, 2400, edges: [0, 400, 1200])
            let candidates: [Double] = (0..<rng.int(0, 8)).map { _ in rng.edgy(-1, total + 1, edges: [0, total]) }
            let math = VoiceTrackEditMath(totalDuration: total, trackWidth: CGFloat(width), snapCandidates: candidates)
            let dur = rng.edgy(0.01, max(0.02, total), edges: [0.1, 0.25])
            let clip = VoiceOverClip(
                id: rng.uuid(), fileName: "vo.m4a",
                startTime: rng.edgy(-1, total, edges: [0, total]),
                sourceStartTime: rng.edgy(-1, 5, edges: [0]),
                duration: dur,
                sourceDuration: rng.bool(0.8) ? rng.edgy(0, dur * 3, edges: [dur]) : nil,
                gain: rng.edgy(-0.5, 3, edges: [1]),
                label: "Voice Over")
            let (mode, modeName) = rng.pick(modes)
            let delta = rng.edgy(-total, total, edges: [0])
            let translation = rng.edgy(-500, 500, edges: [0])
            let resolved = math.resolvedClip(from: clip, mode: mode, delta: delta)

            // Commit mapping (VoiceTrackCommits) over a random speed map.
            let mapStart = rng.edgy(0, 5, edges: [0])
            let mapEnd = mapStart + rng.edgy(0, 60, edges: [0, total])
            let regions = randomSpeedRegions(&rng, span: mapStart...mapEnd)
            let timeMap = SpeedTimeMap(sourceStart: mapStart, sourceEnd: mapEnd, regions: regions)
            let project = Project(id: rng.uuid(), name: "v", duration: mapEnd)
            project.voiceOverClips = [clip]
            let commits = VoiceTrackCommits(project: project, timeMap: timeMap)
            let outputClip = commits.outputClip(for: clip)
            commits.commit(id: clip.id, outputValue: resolved)
            let committed = project.voiceOverClips[0]

            cases.append(vcase(
                [
                    "totalDuration": total.wv, "trackWidth": width.wv, "snapCandidates": candidates.wv,
                    "clip": WV.encoded(clip), "mode": .str(modeName), "delta": delta.wv,
                    "translationX": translation.wv,
                    "map": ["sourceStart": mapStart.wv, "sourceEnd": mapEnd.wv,
                            "regions": .arr(regions.map(WVModel.speedRegion))],
                ],
                [
                    "delta": math.delta(forTranslation: CGFloat(translation)).wv,
                    "resolvedClip": WV.encoded(resolved),
                    "outputClip": WV.encoded(outputClip),
                    "committed": WV.encoded(committed),
                ]
            ))
        }
        return cases
    }
}
