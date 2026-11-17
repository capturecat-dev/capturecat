import UIKit

/// Animates the shared `TimelineLaneLayout.openness` toward the target lane —
/// the touch twin of the Mac's `TimelineLaneAccordion`. The overlay lanes
/// (EFFECTS, FOCUS, ANNOTATE) rest as slim strips; on touch a TAP opens one
/// (the Mac opens on hover). It grows on the house growth bounce
/// (`CCMotion.Curve.bounce`, paced, 0.28 s — the Mac's numbers) frame by frame
/// on a display link, because the lanes are CG-drawn: there is no layer
/// property to hand to Core Animation. Every lane interpolates from where it
/// visibly IS with the same eased progress, so a retarget mid-flight never
/// jumps and a lane-to-lane hand-off keeps the band's height.
@MainActor
final class StudioTimelineLaneAccordion: NSObject {
    /// Fires on every frame the openness changes (and once per snap).
    var onChange: (() -> Void)?

    /// The lane opening (or held open); nil = every lane a strip.
    private(set) var target: TimelineOverlayLane?
    private(set) var openness: [CGFloat] = [0, 0, 0]

    private var link: CADisplayLink?
    private var from: [CGFloat] = [0, 0, 0]
    private var to: [CGFloat] = [0, 0, 0]
    private var began: CFTimeInterval = 0
    private var duration: TimeInterval = 0.28
    private var curve = CCMotion.Curve.bounce.points

    /// What cross-fades when Reduce Motion lands a lane change (the
    /// timeline's canvas area: lane labels + canvas). Shipping code, not a
    /// harness seam — it must exist in Release.
    weak var reducedMotionHost: UIView?

    #if DEBUG
    /// Harness seam: forces the Reduce Motion path.
    var probeReduceMotion: Bool?
    /// Harness defect injection (`--inject accordion-snap`): every retarget
    /// snaps — the motion check must FAIL with this set.
    var probeForceSnap = false
    /// Harness seam: a fixed clock (`nil` = CACurrentMediaTime), so a probe
    /// can sample the sequence at exact times.
    var probeClock: (() -> CFTimeInterval)?
    private var now: CFTimeInterval { probeClock?() ?? CACurrentMediaTime() }
    private var reducesMotion: Bool { probeReduceMotion ?? CCMotion.reduceMotion }
    private var forcesSnap: Bool { probeForceSnap }
    #else
    // Release: no harness seams (ios-release-check.sh).
    private var now: CFTimeInterval { CACurrentMediaTime() }
    private var reducesMotion: Bool { CCMotion.reduceMotion }
    private var forcesSnap: Bool { false }
    #endif

    var isAnimating: Bool { link != nil }

    static func openness(for lane: TimelineOverlayLane?) -> [CGFloat] {
        TimelineOverlayLane.allCases.map { $0 == lane ? 1 : 0 }
    }


    func setTarget(_ lane: TimelineOverlayLane?, animated: Bool) {
        guard lane != target else { return }
        target = lane
        to = Self.openness(for: lane)
        let reduceMotion = reducesMotion
        guard animated, !forcesSnap else {
            stop()
            openness = to
            onChange?()
            return
        }
        // Reduce Motion: the lanes land at once under a cross-fade of the
        // timeline (labels + canvas) — still animated, nothing grows.
        if reduceMotion, let host = reducedMotionHost, host.window != nil {
            stop()
            CCMotion.crossFade(host) {
                openness = to
                onChange?()
            }
            return
        }
        from = openness
        began = now
        // Reduce Motion without a host: a short symmetric glide, no overshoot.
        curve = reduceMotion ? CCMotion.Curve.glide.points : CCMotion.Curve.bounce.points
        duration = CCMotion.paced(reduceMotion ? 0.16 : 0.28)
        if link == nil {
            let link = CADisplayLink(target: self, selector: #selector(step))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        tick()
    }

    @objc private func step() { tick() }

    /// Advances to the current clock (the display link calls it; a probe may too).
    func tick() {
        let t = CGFloat(min(1, (now - began) / max(duration, 0.001)))
        if t >= 1 {
            openness = to
            stop()
        } else {
            let y = CCMotion.bezierY(t, curve)
            openness = zip(from, to).map { $0 + ($1 - $0) * y }
        }
        onChange?()
    }

    private func stop() {
        link?.invalidate()
        link = nil
    }

    func invalidate() { stop() }
}
