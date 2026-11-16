import AppKit

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
