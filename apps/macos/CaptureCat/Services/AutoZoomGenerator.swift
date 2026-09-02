import Foundation
import CoreGraphics

/// Auto Zoom: turns recorded interaction data (60Hz cursor samples with
/// pressed state + keystroke times) into a calm, Screen-Studio-grade camera
/// plan of `ZoomRegion`s.
///
/// Pipeline (all pure functions — the `--autozoom-test` harness drives them
/// headless over synthetic fixtures):
///
///   1. INTERACTIONS — discrete clicks (via `ClickRippleOverlay.discreteClicks`,
///      so drag-selects are excluded exactly like ripples/sounds), typing
///      bursts (anchored at the click that focused the field), and dwells
///      (cursor hovering one spot after arriving — parked-idle is excluded).
///   2. CLUSTERS — interactions close in time AND space group into activity
///      clusters; clusters separated by less than the merge gap fuse.
///   3. QUALIFY — a lone transient click never zooms; a cluster needs 2+
///      interactions, a typing burst, or a dwell.
///   4. FRAME — focal at the cluster centroid, depth from spatial extent
///      (tight typing → deep, broad mousing → shallow), focal clamped so the
///      zoomed viewport never crops past the frame edge into letterbox.
///   5. RHYTHM — lead-in before the first interaction, calm release after the
///      last, a minimum zoom duration, a cooldown between separate zooms, and
///      hysteresis: a nearby next cluster becomes a contiguous PAN (the
///      camera springs to the new focal without dipping out) instead of a
///      zoom-out/zoom-in ping-pong.
///   6. RESPECT — regions are clipped out of spans occupied by the user's
///      manual zoom/effect blocks; only auto regions are ever replaced.
enum AutoZoomGenerator {

    // MARK: - Tuning (one table, shared by generator + harness assertions)

    enum Tuning {
        /// Zoom starts this long BEFORE the first interaction of a cluster.
        static let leadIn: TimeInterval = 0.35
        /// Calm release: hold after the last interaction before zooming out.
        static let release: TimeInterval = 0.9
        /// A zoom shorter than this reads as a glitch — extend, then merge.
        static let minDuration: TimeInterval = 1.8
        /// Separate zooms need this much air between them (else merge or pan).
        static let cooldown: TimeInterval = 1.0
        /// Interactions within this many seconds chain into one cluster.
        static let clusterTimeGap: TimeInterval = 2.0
        /// ...and within this fraction of the screen diagonal of the centroid.
        static let clusterRadius: Double = 0.22
        /// Focal distance (fraction of frame, max axis) below which two close
        /// clusters MERGE into one region.
        static let mergeFocalDistance: Double = 0.10
        /// ...and below which they become a contiguous PAN instead of a
        /// zoom-out/zoom-in (the ~25%-of-frame hysteresis).
        static let panFocalDistance: Double = 0.25
        /// Gap below which panning is preferred over a full out/in cycle.
        static let panMaxGap: TimeInterval = 2.5
        /// Dwell: cursor stays inside this fraction of the diagonal…
        static let dwellRadius: Double = 0.025
        /// …for at least this long to count as deliberate hovering…
        static let dwellMinDuration: TimeInterval = 0.8
        /// …but longer than this is a parked cursor (idle), not attention.
        static let dwellMaxDuration: TimeInterval = 4.0
        /// Typing burst: ≥ this many keys with < `typingMaxKeyGap` between.
        static let typingMinKeys = 3
        static let typingMaxKeyGap: TimeInterval = 1.5
        /// Depth bounds and spread thresholds (fraction of screen diagonal).
        static let minZoom: Double = 1.3
        static let maxZoom: Double = 2.75
        static let tightSpread: Double = 0.06
        static let broadSpread: Double = 0.18
        /// Focal keeps this margin inside the visible-viewport clamp.
        static let edgeMargin: Double = 0.02
        /// A region clipped against manual blocks below this length is dropped.
        static let minClippedDuration: TimeInterval = 1.2
    }

    // MARK: - Interactions

    enum InteractionKind { case click, typing, dwell }

    struct Interaction {
        var startTime: TimeInterval
        var endTime: TimeInterval
        /// Normalized 0…1 screen position.
        var point: CGPoint
        var kind: InteractionKind
    }

    /// Analyzes recorded activity and generates auto zoom regions.
    /// `existingRegions` are the user's MANUAL blocks (any effect spans that
    /// must stay untouched) — generated regions are clipped out of them.
    static func generateZoomRegions(
        from cursorEvents: [CursorEvent],
        videoDuration: TimeInterval,
        screenSize: CGSize,
        zoomLevel: Double = 2.0,
        keystrokes: [KeystrokeEvent] = [],
        existingRegions: [ZoomRegion] = []
    ) -> [ZoomRegion] {
        guard videoDuration > 0, screenSize.width > 0, screenSize.height > 0 else { return [] }

        let interactions = extractInteractions(
            cursorEvents: cursorEvents, keystrokes: keystrokes, screenSize: screenSize)
        guard !interactions.isEmpty else { return [] }

        let clusters = cluster(interactions)
        let qualified = clusters.filter(qualifies)
        guard !qualified.isEmpty else { return [] }

        var regions = qualified.map {
            frame(cluster: $0, baseZoom: zoomLevel, videoDuration: videoDuration)
        }
        regions = applyRhythm(regions, videoDuration: videoDuration)
        regions = clip(regions, around: existingRegions)
        return regions
    }

    /// Clicks + typing bursts + dwells, normalized and time-sorted.
    static func extractInteractions(
        cursorEvents: [CursorEvent],
        keystrokes: [KeystrokeEvent],
        screenSize: CGSize
    ) -> [Interaction] {
        var interactions: [Interaction] = []

        func normalize(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: max(0, min(1, x / screenSize.width)),
                y: max(0, min(1, y / screenSize.height)))
        }

        // Discrete clicks — same extraction as ripples/click sounds, so a
        // drag-select never counts as a click to zoom at.
        let clicks = ClickRippleOverlay.discreteClicks(
            from: cursorEvents, coordinateSize: screenSize)
        for click in clicks {
            interactions.append(Interaction(
                startTime: click.timestamp, endTime: click.timestamp,
                point: normalize(click.x, click.y), kind: .click))
        }

        // Typing bursts, anchored at the click that focused the field (we have
        // key TIMES, not caret positions); fallback: cursor position at the
        // burst start.
        for burst in typingBursts(in: keystrokes) {
            let anchor: CGPoint
            if let click = clicks.last(where: { $0.timestamp <= burst.start }) {
                anchor = normalize(click.x, click.y)
            } else if let sample = cursorEvents.last(where: { $0.timestamp <= burst.start })
                ?? cursorEvents.first {
                anchor = normalize(sample.x, sample.y)
            } else {
                continue
            }
            interactions.append(Interaction(
                startTime: burst.start, endTime: burst.end, point: anchor, kind: .typing))
        }

        // Dwells: the cursor arrives somewhere and hovers. A run that never
        // ends (parked cursor) or exceeds dwellMaxDuration is idle, not
        // attention, and produces nothing.
        interactions.append(contentsOf: dwells(in: cursorEvents, screenSize: screenSize))

        return interactions.sorted { $0.startTime < $1.startTime }
    }

    /// Bursts of ≥ typingMinKeys real keys with gaps < typingMaxKeyGap.
    static func typingBursts(in keystrokes: [KeystrokeEvent]) -> [(start: TimeInterval, end: TimeInterval)] {
        let keys = keystrokes
            .filter { $0.category != .scroll && $0.category != .modifier }
            .sorted { $0.timestamp < $1.timestamp }
        var bursts: [(TimeInterval, TimeInterval)] = []
        var start: TimeInterval?
        var last: TimeInterval = 0
        var count = 0
        for key in keys {
            if start == nil || key.timestamp - last > Tuning.typingMaxKeyGap {
                if let s = start, count >= Tuning.typingMinKeys { bursts.append((s, last)) }
                start = key.timestamp
                count = 0
            }
            last = key.timestamp
            count += 1
        }
        if let s = start, count >= Tuning.typingMinKeys { bursts.append((s, last)) }
        return bursts
    }

    /// Hover segments: cursor stays within dwellRadius·diagonal of the segment
    /// anchor for dwellMinDuration…dwellMaxDuration after having MOVED there.
    static func dwells(in events: [CursorEvent], screenSize: CGSize) -> [Interaction] {
        guard events.count > 1 else { return [] }
        let diagonal = Double(hypot(screenSize.width, screenSize.height))
        let radius = diagonal * Tuning.dwellRadius

        var result: [Interaction] = []
        var anchorIndex = 0
        var hasMovedSinceStart = false

        func close(_ endIndex: Int) {
            let anchor = events[anchorIndex]
            let end = events[endIndex]
            let duration = end.timestamp - anchor.timestamp
            // Only a dwell if the cursor travelled here first — the very first
            // segment of a recording (cursor untouched from t=0) is idle.
            if hasMovedSinceStart,
               duration >= Tuning.dwellMinDuration,
               duration <= Tuning.dwellMaxDuration {
                var sumX: CGFloat = 0, sumY: CGFloat = 0
                for i in anchorIndex...endIndex {
                    sumX += events[i].x
                    sumY += events[i].y
                }
                let n = CGFloat(endIndex - anchorIndex + 1)
                result.append(Interaction(
                    startTime: anchor.timestamp, endTime: end.timestamp,
                    point: CGPoint(
                        x: max(0, min(1, (sumX / n) / screenSize.width)),
                        y: max(0, min(1, (sumY / n) / screenSize.height))),
                    kind: .dwell))
            }
        }

        for i in 1..<events.count {
            let anchor = events[anchorIndex]
            let distance = Double(hypot(events[i].x - anchor.x, events[i].y - anchor.y))
            if distance > radius {
                close(i - 1)
                anchorIndex = i
                hasMovedSinceStart = true
            }
        }
        close(events.count - 1)
        return result
    }

    // MARK: - Clustering

    struct Cluster {
        var interactions: [Interaction]

        var startTime: TimeInterval { interactions.first?.startTime ?? 0 }
        var endTime: TimeInterval { interactions.map(\.endTime).max() ?? 0 }

        var centroid: CGPoint {
            guard !interactions.isEmpty else { return CGPoint(x: 0.5, y: 0.5) }
            let n = CGFloat(interactions.count)
            return CGPoint(
                x: interactions.map(\.point.x).reduce(0, +) / n,
                y: interactions.map(\.point.y).reduce(0, +) / n)
        }

        /// Max pairwise distance between interaction points (normalized).
        var spread: Double {
            var maxDistance = 0.0
            for a in interactions {
                for b in interactions {
                    maxDistance = max(
                        maxDistance,
                        Double(hypot(a.point.x - b.point.x, a.point.y - b.point.y)))
                }
            }
            return maxDistance
        }
    }

    /// Chain interactions into clusters (time gap AND distance-to-centroid),
    /// then fuse clusters whose gap is below the cooldown.
    static func cluster(_ interactions: [Interaction]) -> [Cluster] {
        guard let first = interactions.first else { return [] }
        var clusters: [Cluster] = [Cluster(interactions: [first])]

        for interaction in interactions.dropFirst() {
            var current = clusters[clusters.count - 1]
            let timeGap = interaction.startTime - current.endTime
            let centroid = current.centroid
            let distance = Double(hypot(
                interaction.point.x - centroid.x, interaction.point.y - centroid.y))
            if timeGap <= Tuning.clusterTimeGap && distance <= Tuning.clusterRadius {
                current.interactions.append(interaction)
                clusters[clusters.count - 1] = current
            } else {
                clusters.append(Cluster(interactions: [interaction]))
            }
        }

        // Fuse clusters closer in time than the cooldown — never two separate
        // zoom decisions within a second of each other.
        var fused: [Cluster] = []
        for cluster in clusters {
            if var last = fused.last, cluster.startTime - last.endTime < Tuning.cooldown {
                last.interactions.append(contentsOf: cluster.interactions)
                fused[fused.count - 1] = last
            } else {
                fused.append(cluster)
            }
        }
        return fused
    }

    /// A lone transient click never zooms: a cluster needs 2+ interactions,
    /// a typing burst, or a dwell.
    static func qualifies(_ cluster: Cluster) -> Bool {
        cluster.interactions.count >= 2
            || cluster.interactions.contains { $0.kind == .typing || $0.kind == .dwell }
    }

    // MARK: - Framing

    /// Depth from spatial extent: tight activity (typing into a field) gets a
    /// deep zoom, broad mousing a shallow one; clamped to sensible bounds.
    static func depth(spread: Double, hasTyping: Bool, baseZoom: Double) -> Double {
        let level: Double
        if spread < Tuning.tightSpread {
            level = baseZoom + (hasTyping ? 0.5 : 0.4)
        } else if spread > Tuning.broadSpread {
            level = baseZoom - 0.5
        } else {
            level = baseZoom
        }
        return max(Tuning.minZoom, min(Tuning.maxZoom, level))
    }

    /// Keeps the zoomed viewport fully inside the frame: at zoom z the visible
    /// half-extent is 0.5/z, so the focal must stay in
    /// [0.5/z + margin, 1 − 0.5/z − margin] on each axis.
    static func clampFocal(_ focal: CGPoint, zoomLevel: Double) -> CGPoint {
        let halfVisible = 0.5 / max(1.0, zoomLevel)
        let lower = halfVisible + Tuning.edgeMargin
        let upper = 1 - halfVisible - Tuning.edgeMargin
        guard lower < upper else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(
            x: max(lower, min(upper, focal.x)),
            y: max(lower, min(upper, focal.y)))
    }

    static func frame(
        cluster: Cluster, baseZoom: Double, videoDuration: TimeInterval
    ) -> ZoomRegion {
        let hasTyping = cluster.interactions.contains { $0.kind == .typing }
        let zoomLevel = depth(spread: cluster.spread, hasTyping: hasTyping, baseZoom: baseZoom)
        let focal = clampFocal(cluster.centroid, zoomLevel: zoomLevel)

        var start = max(0, cluster.startTime - Tuning.leadIn)
        var end = min(videoDuration, cluster.endTime + Tuning.release)
        if end - start < Tuning.minDuration {
            end = min(videoDuration, start + Tuning.minDuration)
            if end - start < Tuning.minDuration {
                start = max(0, end - Tuning.minDuration)
            }
        }
        return ZoomRegion(
            startTime: start, endTime: end, zoomLevel: zoomLevel,
            focalPoint: focal, isAuto: true)
    }

    // MARK: - Rhythm (anti ping-pong + pan hysteresis)

    /// Time-sorted regions → merged / panned / spaced-out plan:
    ///   • overlapping or focals within mergeFocalDistance → one region
    ///   • gap < panMaxGap and focals within panFocalDistance → contiguous PAN
    ///     (second region starts exactly at the first's end, same depth — the
    ///     camera springs across without a zoom-out dip)
    ///   • gap < cooldown but too far to pan → still contiguous (a whip pan
    ///     beats a 1-second out-and-back-in)
    ///   • otherwise: a real zoom-out and a fresh zoom-in later.
    static func applyRhythm(_ regions: [ZoomRegion], videoDuration: TimeInterval) -> [ZoomRegion] {
        guard !regions.isEmpty else { return [] }
        let sorted = regions.sorted { $0.startTime < $1.startTime }
        var result: [ZoomRegion] = [sorted[0]]

        for var region in sorted.dropFirst() {
            var last = result[result.count - 1]
            let gap = region.startTime - last.endTime
            let focalDistance = max(
                abs(Double(region.focalPoint.x - last.focalPoint.x)),
                abs(Double(region.focalPoint.y - last.focalPoint.y)))

            if gap < Tuning.cooldown || (gap < Tuning.panMaxGap && focalDistance <= Tuning.panFocalDistance) {
                if focalDistance <= Tuning.mergeFocalDistance {
                    // Same subject — one region, duration-weighted focal.
                    let total = last.duration + region.duration
                    last.focalPoint = CGPoint(
                        x: (last.focalPoint.x * last.duration + region.focalPoint.x * region.duration) / total,
                        y: (last.focalPoint.y * last.duration + region.focalPoint.y * region.duration) / total)
                    last.endTime = max(last.endTime, region.endTime)
                    last.zoomLevel = max(last.zoomLevel, region.zoomLevel)
                    result[result.count - 1] = last
                } else {
                    // Nearby subject — PAN: contiguous blocks, matched depth so
                    // the move is lateral, not a pump.
                    region.startTime = last.endTime
                    region.zoomLevel = last.zoomLevel
                    region.focalPoint = clampFocal(region.focalPoint, zoomLevel: region.zoomLevel)
                    if region.duration < Tuning.minDuration {
                        region.endTime = min(videoDuration, region.startTime + Tuning.minDuration)
                    }
                    if region.duration > 0.1 { result.append(region) }
                }
            } else {
                result.append(region)
            }
        }
        return result
    }

    // MARK: - Respecting manual regions

    /// Clips generated regions out of the spans held by the user's manual
    /// blocks (with cooldown air on both sides); fragments too short to be a
    /// real zoom are dropped.
    static func clip(_ regions: [ZoomRegion], around manual: [ZoomRegion]) -> [ZoomRegion] {
        guard !manual.isEmpty else { return regions }
        var result: [ZoomRegion] = []
        for region in regions {
            var spans: [(TimeInterval, TimeInterval)] = [(region.startTime, region.endTime)]
            for block in manual {
                let blockStart = block.startTime - Tuning.cooldown
                let blockEnd = block.endTime + Tuning.cooldown
                var next: [(TimeInterval, TimeInterval)] = []
                for (start, end) in spans {
                    if end <= blockStart || start >= blockEnd {
                        next.append((start, end))
                    } else {
                        if start < blockStart { next.append((start, blockStart)) }
                        if end > blockEnd { next.append((blockEnd, end)) }
                    }
                }
                spans = next
            }
            for (start, end) in spans where end - start >= Tuning.minClippedDuration {
                var piece = region
                if !(start == region.startTime && end == region.endTime) {
                    piece = ZoomRegion(
                        startTime: start, endTime: end, zoomLevel: region.zoomLevel,
                        focalPoint: region.focalPoint, isAuto: true)
                }
                result.append(piece)
            }
        }
        return result
    }
}
