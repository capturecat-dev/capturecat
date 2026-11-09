import AppKit

// MARK: - Lane accordion
//
// The three overlay lanes (EFFECTS, FOCUS, ANNOTATE) rest as slim colour
// strips. Hovering one opens it to full block height — it grows downward,
// pushing the lanes below it (a sibling that was open tucks back as it goes) —
// and moving off springs it shut again. VIDEO and VOICE never move.
//
// `TimelineLaneLayout` is the ONE source of lane geometry: the canvas draws and
// hit-tests from it, the playhead overlay reads its bottom from it, and the
// controller sizes the label column and the panel from it. Nothing keeps a
// second copy of a lane Y.

enum TimelineOverlayLane: Int, CaseIterable {
    case effects, focus, annotate
}

struct TimelineLaneLayout: Equatable {
    private typealias M = TimelineCanvasMetrics

    /// Row height of a closed lane — a slim strip (blocks ≈ 12pt bars).
    static let compactRowHeight: CGFloat = 18
    /// Sub-row gap of a closed lane (stacked strips sit tighter).
    static let compactRowGap: CGFloat = 2
    /// Floor for the bounce undershoot of a closing lane.
    static let minRowHeight: CGFloat = 12

    /// Per-lane openness, indexed by `TimelineOverlayLane.rawValue`:
    /// 0 = compact strip, 1 = full lane. Values briefly leave [0, 1] on the
    /// growth bounce. At most one lane targets 1, so while the hover moves
    /// between lanes the openness sums to 1 and the band holds its height.
    var openness: [CGFloat] = [0, 0, 0]
    var effectsRows = 1
    var annotateRows = 1

    /// Steady state with `lane` open — nil = every lane a strip (rest).
    static func settled(
        open lane: TimelineOverlayLane?, effectsRows: Int, annotateRows: Int
    ) -> TimelineLaneLayout {
        TimelineLaneLayout(
            openness: TimelineOverlayLane.allCases.map { $0 == lane ? 1 : 0 },
            effectsRows: effectsRows,
            annotateRows: annotateRows
        )
    }

    /// Tallest settled `tracksBottom` over every possible open lane. The panel
    /// and the scroll document are sized from this, so a hover never re-lays
    /// out the editor stage — the lanes animate inside a fixed frame, and at
    /// rest the room an opening lane grows into sits below ANNOTATE.
    static func maxTracksBottom(effectsRows: Int, annotateRows: Int) -> CGFloat {
        TimelineOverlayLane.allCases.map {
            settled(open: $0, effectsRows: effectsRows, annotateRows: annotateRows).tracksBottom
        }.max() ?? M.tracksBottom
    }

    func openness(_ lane: TimelineOverlayLane) -> CGFloat {
        openness.indices.contains(lane.rawValue) ? openness[lane.rawValue] : 0
    }

    func rows(_ lane: TimelineOverlayLane) -> Int {
        switch lane {
        case .effects: return max(1, effectsRows)
        case .focus: return 1
        case .annotate: return max(1, annotateRows)
        }
    }

    func rowHeight(_ lane: TimelineOverlayLane) -> CGFloat {
        let w = openness(lane)
        return max(Self.minRowHeight,
                   Self.compactRowHeight + (M.trackHeight - Self.compactRowHeight) * w)
    }

    func rowGap(_ lane: TimelineOverlayLane) -> CGFloat {
        let w = min(1, max(0, openness(lane)))
        return Self.compactRowGap + (M.subRowGap - Self.compactRowGap) * w
    }

    func rowPitch(_ lane: TimelineOverlayLane) -> CGFloat {
        rowHeight(lane) + rowGap(lane)
    }

    func laneHeight(_ lane: TimelineOverlayLane) -> CGFloat {
        let n = CGFloat(rows(lane))
        return n * rowHeight(lane) + (n - 1) * rowGap(lane)
    }

    func laneY(_ lane: TimelineOverlayLane) -> CGFloat {
        var y = M.effectsLaneY
        for other in TimelineOverlayLane.allCases {
            if other == lane { return y }
            y += laneHeight(other) + M.trackSpacing
        }
        return y
    }

    /// Top of a sub-row (clamped into the lane's committed row count).
    func rowY(_ lane: TimelineOverlayLane, row: Int) -> CGFloat {
        laneY(lane) + CGFloat(max(0, min(row, rows(lane) - 1))) * rowPitch(lane)
    }

    func laneRect(_ lane: TimelineOverlayLane, width: CGFloat) -> CGRect {
        CGRect(x: 0, y: laneY(lane), width: width, height: laneHeight(lane))
    }

    var tracksBottom: CGFloat {
        laneY(.annotate) + laneHeight(.annotate)
    }

    /// Which overlay lane a canvas Y belongs to for HOVER. Bands are
    /// contiguous — each lane owns half of the gaps around it — so crossing a
    /// 4pt gap never drops the hover and flickers the accordion shut. Nil
    /// above the band (ruler, VIDEO, VOICE) and in the spare room below
    /// ANNOTATE. A lane only ever grows DOWN from its own top (or its top
    /// rises as a sibling above tucks away), so opening never slides the lane
    /// out from under the cursor.
    func hoverLane(atY y: CGFloat) -> TimelineOverlayLane? {
        guard y >= M.effectsLaneY - M.trackSpacing else { return nil }
        for lane in TimelineOverlayLane.allCases {
            if y < laneY(lane) + laneHeight(lane) + M.trackSpacing / 2 { return lane }
        }
        return nil
    }
}

// MARK: - Driver

/// Animates `TimelineLaneLayout.openness` toward the target lane on the house
/// growth bounce (`CCMotion.bouncePoints`, paced), at 120 Hz — the canvas is
/// CG-drawn, so there is no layer property to hand to Core Animation. Every
/// lane interpolates from where it visibly IS with the same eased progress, so
/// a retarget mid-flight never jumps (and a lane-to-lane hand-off keeps the
/// band's height: one lane gives exactly what the other takes).
@MainActor
final class TimelineLaneAccordion {
    /// Fires on every frame the openness changes (and once per snap).
    var onChange: (() -> Void)?

    /// The lane opening (or held open); nil = every lane a strip.
    private(set) var target: TimelineOverlayLane?
    private(set) var openness: [CGFloat] = [0, 0, 0]

    private var timer: Timer?
    private var from: [CGFloat] = [0, 0, 0]
    private var to: [CGFloat] = [0, 0, 0]
    private var began: CFTimeInterval = 0
    private var duration: TimeInterval = 0.4
    private var curve = CCMotion.bouncePoints

    /// Harness seam: forces the Reduce Motion path.
    var probeReduceMotion: Bool?
    /// Harness defect injection (`--inject accordion-snap`): every retarget
    /// snaps — the motion probe must FAIL with this set.
    var probeForceSnap = false

    var isAnimating: Bool { timer != nil }

    static func openness(for lane: TimelineOverlayLane?) -> [CGFloat] {
        TimelineOverlayLane.allCases.map { $0 == lane ? 1 : 0 }
    }

    func setTarget(_ lane: TimelineOverlayLane?, animated: Bool) {
        guard lane != target else { return }
        target = lane
        to = Self.openness(for: lane)
        let reduceMotion = probeReduceMotion
            ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard animated, !probeForceSnap else {
            stop()
            openness = to
            onChange?()
            return
        }
        from = openness
        began = CACurrentMediaTime()
        // Reduce Motion: a short symmetric glide, no overshoot.
        curve = reduceMotion ? CCMotion.glidePoints : CCMotion.bouncePoints
        // 0.28 s, snappier than the kit's 0.38 s growth default: a sweep
        // across lanes must keep up with the cursor (Mike, 2026-11-09).
        duration = CCMotion.paced(reduceMotion ? 0.16 : 0.28)
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    private func tick() {
        let t = CGFloat(min(1, (CACurrentMediaTime() - began) / max(duration, 0.001)))
        if t >= 1 {
            openness = to
            stop()
        } else {
            let y = CCMotion.bezierY(t, curve)
            openness = zip(from, to).map { $0 + ($1 - $0) * y }
        }
        onChange?()
    }

    /// (No deinit needed: the timer holds the driver weakly and invalidates
    /// itself on the first tick after the owner is gone.)
    private func stop() {
        timer?.invalidate()
        timer = nil
    }
}
