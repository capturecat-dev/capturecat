import AppKit

/// Live preview pad for controls with no other visual feedback in the
/// inspector — the cursor's own size/style/fluid/ripple/auto-hide/loop/stop
/// properties already animate live in CursorPreviewBoxControl, so this pad
/// covers what's left: background parallax, motion blur, card frame style,
/// and the highlight mask dim. Same contract as EffectPreviewPadControl: a
/// self-driving CALayer loop inside a bordered pad, pure
/// AppKit/CoreAnimation/CoreGraphics — no SwiftUI, no UIKit. Display-only
/// chrome: it shows the FEEL of the current parameters, never real footage.
@MainActor
final class PropertyPreviewPadControl: NSView {
    enum Mode {
        case parallax(strength: Double)
        case motionBlur(on: Bool, strength: Double)
        case frameStyle(cornerRadius: Double, shadowRadius: Double, shadowOpacity: Double)
        case highlightMask(opacity: Double)
    }

    var mode: Mode = .parallax(strength: 0.4) {
        didSet { restartLoop() }
    }

    private let cardLayer = CALayer()
    private let dimLayer = CALayer()
    private let trailLayers = (0..<5).map { _ in CALayer() }
    private var timer: Timer?
    private var loopStart: CFTimeInterval = 0
    private var themeObservation: CCThemeObservation?

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 96) }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = EditorThemeKit.controlRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.masksToBounds = true

        dimLayer.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        dimLayer.isHidden = true
        layer?.addSublayer(dimLayer)

        for trail in trailLayers {
            trail.backgroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
            trail.cornerRadius = 4
            trail.isHidden = true
            layer?.addSublayer(trail)
        }

        cardLayer.backgroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
        cardLayer.cornerRadius = 3
        cardLayer.cornerCurve = .continuous
        layer?.addSublayer(cardLayer)

        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Pad chrome only — the mock card/trail/dim content mimics exported
    /// footage and keeps its fixed colors in both themes.
    private func applyTheme() {
        layer?.backgroundColor = EditorThemeKit.panelElevated.cgColor
        layer?.borderColor = EditorThemeKit.hairline.cgColor
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            timer?.invalidate()
            timer = nil
        } else {
            restartLoop()
        }
    }

    override func layout() {
        super.layout()
        tick()
    }

    private func restartLoop() {
        // Keep the phase when the loop is already running — a slider drag
        // updates `mode` every tick, and resetting `loopStart` each time
        // pinned the animation to its first frame for the whole drag.
        if timer == nil { loopStart = CACurrentMediaTime() }
        if timer == nil, window != nil {
            let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self,
                          self.window?.occlusionState.contains(.visible) == true,
                          !self.isHiddenOrHasHiddenAncestor else { return }
                    self.tick()
                }
            }
            timer = t
            RunLoop.main.add(t, forMode: .common)
        }
    }

    private func hideAll() {
        cardLayer.isHidden = true
        dimLayer.isHidden = true
        for trail in trailLayers { trail.isHidden = true }
    }

    private func tick() {
        guard bounds.width > 0 else { return }
        let elapsed = CACurrentMediaTime() - loopStart
        let center = CGPoint(x: bounds.midX, y: bounds.midY)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hideAll()

        // The maths: InspectorPreviewMath (shared with the iOS preview rows).
        switch mode {
        case .parallax(let strength):
            // A foreground card pulses zoom while background marks drift at a
            // fraction of that motion — the depth cue parallax adds.
            let f = InspectorPreviewMath.parallax(elapsed: elapsed, size: bounds.size, strength: strength)
            for (trail, mark) in zip(trailLayers.prefix(3), f.marks) {
                trail.isHidden = false
                trail.backgroundColor = NSColor.white.withAlphaComponent(0.3).cgColor
                trail.cornerRadius = 2
                trail.frame = mark
            }
            cardLayer.isHidden = false
            cardLayer.bounds = CGRect(origin: .zero, size: f.cardSize)
            cardLayer.position = f.center
            cardLayer.transform = CATransform3DMakeScale(f.zoom, f.zoom, 1)

        case .motionBlur(let on, let strength):
            // Sharp at rest, smeared only while moving fast.
            let f = InspectorPreviewMath.motionBlur(elapsed: elapsed, size: bounds.size, on: on, strength: strength)
            let shapeSize = InspectorPreviewMath.MotionBlurFrame.dotSize
            for (trail, dot) in zip(trailLayers, f.trail) {
                trail.isHidden = false
                trail.backgroundColor = NSColor.white.withAlphaComponent(dot.alpha).cgColor
                trail.cornerRadius = shapeSize / 2
                trail.frame = dot.frame
            }
            cardLayer.isHidden = false
            // The dot itself stretches slightly along the motion at speed —
            // the same cue CIMotionBlur produces on the real card.
            cardLayer.transform = CATransform3DMakeScale(f.stretch, 1, 1)
            cardLayer.bounds = CGRect(origin: .zero, size: CGSize(width: shapeSize, height: shapeSize))
            cardLayer.cornerRadius = shapeSize / 2
            cardLayer.position = f.center

        case .frameStyle(let cornerRadius, let shadowRadius, let shadowOpacity):
            let f = InspectorPreviewMath.frameStyle(size: bounds.size, cornerRadius: cornerRadius,
                                                    shadowRadius: shadowRadius, shadowOpacity: shadowOpacity)
            cardLayer.isHidden = false
            cardLayer.bounds = CGRect(origin: .zero, size: f.cardSize)
            cardLayer.position = center
            cardLayer.transform = CATransform3DIdentity
            cardLayer.cornerRadius = f.cornerRadius
            cardLayer.shadowColor = NSColor.black.cgColor
            cardLayer.shadowOpacity = f.shadowOpacity
            cardLayer.shadowRadius = f.shadowRadius
            cardLayer.shadowOffset = .zero

        case .highlightMask(let opacity):
            dimLayer.isHidden = false
            dimLayer.frame = bounds
            dimLayer.backgroundColor = NSColor.black.withAlphaComponent(opacity).cgColor
            cardLayer.isHidden = false
            let hole = InspectorPreviewMath.highlightHole(size: bounds.size)
            cardLayer.transform = CATransform3DIdentity
            cardLayer.bounds = CGRect(origin: .zero, size: hole.size)
            cardLayer.position = center
            cardLayer.cornerRadius = 4
            cardLayer.zPosition = 1
            dimLayer.zPosition = 0
        }
        CATransaction.commit()
    }

    #if DEBUG
    /// Harness seam: what the pad shows, in the shared vocabulary.
    var probeMode: InspectorPreviewMath.Mode {
        switch mode {
        case .parallax(let strength): return .parallax(strength: strength)
        case .motionBlur(let on, let strength): return .motionBlur(on: on, strength: strength)
        case .frameStyle(let c, let r, let o): return .frameStyle(cornerRadius: c, shadowRadius: r, shadowOpacity: o)
        case .highlightMask(let opacity): return .highlightMask(opacity: opacity)
        }
    }
    #endif
}
