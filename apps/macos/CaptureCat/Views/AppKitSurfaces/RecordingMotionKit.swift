import AppKit
import QuartzCore

// Motion system for the floating recording panel's chrome.
//
// Pure toolbar animation — none of this touches timeline/effect math, so there
// are no preview/export parity concerns (CLAUDE.md §2 does not apply here).
// The goals, in order:
//
//   * selection reads as ONE pill that glides between segments, not as two
//     chips swapping tints
//   * hover is a backdrop that fades in once and then travels between items
//   * the panel window and its content always resize in the same animation
//     group — never window-then-content or content-then-window
//   * `accessibilityDisplayShouldReduceMotion` collapses everything to fast
//     crossfades with no slides

enum RecordingMotion {
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // ── One timing family. Every recording-bar animation draws from these ──
    //
    //   settleCurve   the family's shared ease: fast start, glassy long tail,
    //                 zero overshoot. Used by tab switches, phase morphs, and
    //                 the window resize so they all decelerate identically.
    //   resizeDuration   standalone window resizes (no row morph in flight).
    //   morphDuration    tab-switch row settle AND setup↔recording cross-morph
    //                    AND the window resize that accompanies a morph — one
    //                    clock, so the bar and its contents land together.
    //   fadeDuration     every micro state fade: hover backdrop, enable/disable
    //                    dimming, indicator dots, the live timer dot.
    //   reducedDuration  everything, when reduce-motion is on (plain fades).

    /// Fast start, a whisper of overshoot (~4%), glassy settle — the iOS
    /// sheet-resize feel. NSAnimationContext can't run a real CASpringAnimation
    /// on a window frame, but a bezier with y > 1 control points overshoots
    /// and settles exactly like a lightly underdamped spring, and it stays
    /// sampleable by the motion-capture harness through `sample()`. (User
    /// call 2026-08-17: the old monotone ease read as a snap, not a spring.)
    static let settleCurve = CAMediaTimingFunction(controlPoints: 0.32, 1.12, 0.24, 1)

    /// Window-frame + layout resize when no row morph accompanies it.
    static let resizeDuration: TimeInterval = 0.40
    /// Row settle / section cross-morph, and any window resize that shares its
    /// beat. Tight enough to feel precise, long enough to read.
    static let morphDuration: TimeInterval = 0.30
    // ── Phase / tab crossfade (the third-round design: radical restraint) ──
    //
    // The transition is exactly two things, like Apple's own record
    // transitions: the window resizes on one curve, and the row content does
    // a plain crossfade — outgoing over the FIRST half, incoming over the
    // SECOND half, with a brief mid-point where the bar is just the solid
    // surface. No hero, no slide, no scale, no stagger.

    /// Full crossfade clock (each fade half runs half of this).
    nonisolated static let phaseCrossfadeDuration: TimeInterval = 0.45
    /// Window-frame + layout curve for the crossfade clock. Same lightly
    /// underdamped spring shape as `settleCurve` but with a softer approach,
    /// so the bar breathes into its new width and settles with the same
    /// life the selection pill has — instead of the old dead-flat cubic.
    static let phaseResizeCurve = CAMediaTimingFunction(controlPoints: 0.36, 1.1, 0.22, 1.0)
    /// Per-half fade curve.
    static let crossfadeHalfCurve = CAMediaTimingFunction(name: .easeInEaseOut)

    /// Alphas of the outgoing/incoming rows at crossfade progress `t` (0…1 of
    /// the full clock). SHARED source of truth: the live animations and the
    /// `--panel-motion-capture` harness both read this — the frames the gate
    /// captures are the same math the app plays (CLAUDE.md §2 spirit).
    static func crossfadeAlphas(at t: Double) -> (outgoing: CGFloat, incoming: CGFloat) {
        let outgoing = 1 - sample(crossfadeHalfCurve, min(1, max(0, t * 2)))
        let incoming = sample(crossfadeHalfCurve, min(1, max(0, t * 2 - 1)))
        return (CGFloat(outgoing), CGFloat(incoming))
    }

    /// Eased progress of the window resize at crossfade progress `t`.
    static func resizeProgress(at t: Double) -> CGFloat {
        CGFloat(sample(phaseResizeCurve, min(1, max(0, t))))
    }

    /// y(x) for a CAMediaTimingFunction — bisection on the bezier's x.
    static func sample(_ function: CAMediaTimingFunction, _ x: Double) -> Double {
        guard x > 0 else { return 0 }
        guard x < 1 else { return 1 }
        var p1 = [Float](repeating: 0, count: 2)
        var p2 = [Float](repeating: 0, count: 2)
        function.getControlPoint(at: 1, values: &p1)
        function.getControlPoint(at: 2, values: &p2)
        func bezier(_ t: Double, _ a: Double, _ b: Double) -> Double {
            // Cubic bezier with endpoints 0 and 1.
            let u = 1 - t
            return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
        }
        var lo = 0.0, hi = 1.0
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if bezier(mid, Double(p1[0]), Double(p2[0])) < x { lo = mid } else { hi = mid }
        }
        let t = (lo + hi) / 2
        return bezier(t, Double(p1[1]), Double(p2[1]))
    }

    /// Micro state fades — hover backdrop, dots, enable/disable dimming.
    static let fadeDuration: TimeInterval = 0.15
    /// Back-compat alias for the hover backdrop's original name.
    static let hoverDuration: TimeInterval = fadeDuration
    /// Everything, when reduce-motion is on.
    static let reducedDuration: TimeInterval = 0.12
    // morphSlide is gone: phase morphs no longer translate their rows at all.
    // Sliding text read cheap (user call, 2026-08-08) — rows purely crossfade,
    // and motion is reserved for the hero flight, the window resize, the
    // selection pill, and the incoming row's unified 0.98→1.0 scale settle.

    /// Spring for the selection pill's position: response ≈ 0.35s, damping
    /// ratio 0.9 — precise, a whisper of life at the end, no visible bounce.
    static func positionSpring() -> CASpringAnimation {
        spring(dampingRatio: 0.9)
    }

    /// Spring for the pill's SIZE: same response but critically damped, so the
    /// pill never grows past its target width and snaps back.
    static func sizeSpring() -> CASpringAnimation {
        spring(dampingRatio: 1.0)
    }

    private static func spring(dampingRatio: CGFloat) -> CASpringAnimation {
        let spring = CASpringAnimation()
        spring.mass = 1
        spring.stiffness = pow(2 * .pi / 0.35, 2) // response 0.35s
        spring.damping = 2 * dampingRatio * sqrt(spring.stiffness)
        spring.duration = spring.settlingDuration
        return spring
    }
}

/// Transparent overlay that owns two persistent CALayers — a selection pill
/// and a hover backdrop — for a row of segment chips. The layers ANIMATE
/// between chip frames instead of being re-created per chip, which is what
/// makes selection read as one object gliding.
///
/// Pin it over the chips' superview; it never participates in hit testing.
/// Colors reuse the panel's existing selected-chip styling (white wash +
/// `EditorThemeKit.selectionOutline`) — motion only, no restyle.
@MainActor
final class SegmentPillOverlay: NSView {
    private let selectionLayer = CALayer()
    private let hoverLayer = CALayer()
    private var selectionFrame: CGRect?
    private var hoverVisible = false
    /// While a spring is in flight, `syncIfNeeded` must not stomp the model
    /// values with a layout pass.
    private var settleDeadline: CFTimeInterval = 0
    private var themeObservation: CCThemeObservation?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        hoverLayer.opacity = 0
        // Screen Studio-style: a subtle wash square behind the active tab —
        // no accent outline, no capsule.
        selectionLayer.borderWidth = 0
        selectionLayer.opacity = 0
        layer?.addSublayer(hoverLayer)
        layer?.addSublayer(selectionLayer)
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    private func applyTheme() {
        let ink: NSColor = CCTheme.isDark ? .white : .black
        hoverLayer.backgroundColor = ink.withAlphaComponent(0.06).cgColor
        selectionLayer.backgroundColor = ink.withAlphaComponent(0.12).cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Never intercept clicks meant for the chips underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: - Selection pill

    /// Move the pill to `frame` (in this overlay's coordinates). Animated
    /// moves spring position and size; the first placement just appears.
    func setSelection(frame: CGRect?, animated: Bool) {
        guard let frame, frame.width > 0, frame.height > 0 else {
            withDisabledActions {
                selectionLayer.opacity = 0
            }
            selectionFrame = nil
            return
        }
        guard frame != selectionFrame else { return }
        let previous = selectionFrame
        selectionFrame = frame

        // First placement, layout resync, or reduce-motion: no travel.
        guard animated, previous != nil else {
            withDisabledActions { place(selectionLayer, at: frame) }
            return
        }
        if RecordingMotion.reduceMotion {
            // Quick crossfade in place of the glide.
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.0
            fade.toValue = 1.0
            fade.duration = RecordingMotion.reducedDuration
            withDisabledActions { place(selectionLayer, at: frame) }
            selectionLayer.add(fade, forKey: "reduced-fade")
            return
        }

        let fromPosition = selectionLayer.presentation()?.position ?? selectionLayer.position
        let fromBounds = selectionLayer.presentation()?.bounds ?? selectionLayer.bounds
        withDisabledActions { place(selectionLayer, at: frame) }

        let move = RecordingMotion.positionSpring()
        move.keyPath = "position"
        move.fromValue = fromPosition
        move.toValue = selectionLayer.position
        selectionLayer.add(move, forKey: "pill-position")

        let resize = RecordingMotion.sizeSpring()
        resize.keyPath = "bounds"
        resize.fromValue = fromBounds
        resize.toValue = selectionLayer.bounds
        selectionLayer.add(resize, forKey: "pill-bounds")

        settleDeadline = CACurrentMediaTime() + max(move.duration, resize.duration)
    }

    /// Layout-time resync: snaps the pill only when no spring is mid-flight,
    /// so a re-layout during a glide doesn't teleport it.
    func syncIfNeeded(frame: CGRect?) {
        guard CACurrentMediaTime() >= settleDeadline else { return }
        setSelection(frame: frame, animated: false)
    }

    // MARK: - Hover backdrop

    /// Show the hover wash under `frame`, glide it there if it is already
    /// visible, or fade it out with `nil`. 0.15s fades; the layer persists.
    func setHover(frame: CGRect?) {
        guard let frame else {
            if CCHoverPoller.debug { NSLog("REC-SEGMENT hover clear") }
            // Keep the last destination as the next glide's origin. Resetting
            // this here meant every chip's mouse-exit made its successor look
            // like a first hover, so tab-to-tab movement could only fade and
            // reappear. The layer opacity still fades to zero while the
            // pointer is away; only its geometry ownership persists.
            fadeHover(to: 0)
            return
        }
        let travelling = hoverVisible && !RecordingMotion.reduceMotion
        if CCHoverPoller.debug {
            NSLog("REC-SEGMENT hover frame=%@ travelling=%d reduceMotion=%d",
                  NSStringFromRect(frame), travelling ? 1 : 0,
                  RecordingMotion.reduceMotion ? 1 : 0)
        }
        hoverVisible = true
        CATransaction.begin()
        if travelling {
            // Glide between items rather than re-appearing.
            CATransaction.setAnimationDuration(RecordingMotion.hoverDuration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        place(hoverLayer, at: frame)
        CATransaction.commit()
        fadeHover(to: 1)
    }

    /// Presentation geometry for the deterministic recording hover probe.
    /// Reading the presentation layer is essential: model geometry moves to
    /// the destination immediately, while this is the frame actually on glass.
    var debugHoverPresentationFrame: CGRect {
        (hoverLayer.presentation() ?? hoverLayer).frame
    }

    private func fadeHover(to opacity: Float) {
        guard hoverLayer.opacity != opacity else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(RecordingMotion.hoverDuration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        hoverLayer.opacity = opacity
        CATransaction.commit()
    }

    // MARK: - Helpers

    private func place(_ target: CALayer, at frame: CGRect) {
        target.frame = frame
        // Matches RecordingTabChip's rounded rect — the pill glides over the
        // near-square source tabs, not over capsules.
        target.cornerRadius = min(RecordingPanelMetrics.tabRadius, frame.height / 2)
        if target === selectionLayer { target.opacity = 1 }
    }

    private func withDisabledActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}
