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

        switch mode {
        case .parallax(let strength):
            // A foreground card pulses zoom while background marks drift at a
            // fraction of that motion — the depth cue parallax adds.
            let cycle = 2.6
            let p = (elapsed.truncatingRemainder(dividingBy: cycle)) / cycle
            let zoom = 1 + 0.18 * sin(p * .pi)
            let drift = CGFloat(zoom - 1) * CGFloat(strength) * 60
            for (i, trail) in trailLayers.prefix(3).enumerated() {
                trail.isHidden = false
                trail.backgroundColor = NSColor.white.withAlphaComponent(0.3).cgColor
                trail.cornerRadius = 2
                let bx = bounds.width * (0.2 + CGFloat(i) * 0.3)
                trail.frame = CGRect(x: bx - drift * 0.6 - 2, y: bounds.height - 16, width: 4, height: 4)
            }
            cardLayer.isHidden = false
            let cardSize = CGSize(width: bounds.width * 0.4, height: bounds.height * 0.46)
            cardLayer.bounds = CGRect(origin: .zero, size: cardSize)
            cardLayer.position = center
            cardLayer.transform = CATransform3DMakeScale(CGFloat(zoom), CGFloat(zoom), 1)

        case .motionBlur(let on, let strength):
            // The story the real effect tells: sharp at rest, smeared only
            // while moving fast. The dot glides left↔right on an ease-in-out
            // (cosine) path — it PAUSES at each end, accelerates through the
            // middle — and the smear length follows the instantaneous
            // velocity, scaled by the user's Strength.
            let cycle = 2.6
            let p = (elapsed.truncatingRemainder(dividingBy: cycle)) / cycle   // 0…1
            let phase = p * 2 * .pi
            // Position: cosine sweep between 14% and 86% of the pad width.
            let travel = bounds.width * 0.72
            let x = bounds.width * 0.14 + travel * CGFloat(0.5 - 0.5 * cos(phase))
            // Normalized speed 0…1 (|sin| of the phase — zero at the ends,
            // max mid-flight), direction flips each half cycle.
            let speed = abs(sin(phase))
            let direction: CGFloat = sin(phase) >= 0 ? 1 : -1
            let shapeSize: CGFloat = 12
            // Smear extent: nothing at rest, up to ~34pt at full speed and
            // strength 1 — the slider visibly changes the trail length.
            let smear: CGFloat = on ? CGFloat(speed * max(0, min(1, strength))) * 34 : 0
            if on && smear > 1 {
                for (i, trail) in trailLayers.enumerated() {
                    let f = CGFloat(i + 1) / CGFloat(trailLayers.count)
                    trail.isHidden = false
                    trail.backgroundColor = NSColor.white
                        .withAlphaComponent(0.45 * Double(speed) * Double(1 - f) * min(1, strength + 0.3))
                        .cgColor
                    trail.cornerRadius = shapeSize / 2
                    trail.frame = CGRect(
                        x: x - direction * smear * f - shapeSize / 2,
                        y: center.y - shapeSize / 2,
                        width: shapeSize, height: shapeSize)
                }
            }
            cardLayer.isHidden = false
            // The dot itself stretches slightly along the motion at speed —
            // the same cue CIMotionBlur produces on the real card.
            let stretch = 1 + (on ? CGFloat(speed) * 0.5 * CGFloat(min(1, strength)) : 0)
            cardLayer.transform = CATransform3DMakeScale(stretch, 1, 1)
            cardLayer.bounds = CGRect(origin: .zero, size: CGSize(width: shapeSize, height: shapeSize))
            cardLayer.cornerRadius = shapeSize / 2
            cardLayer.position = CGPoint(x: x, y: center.y)

        case .frameStyle(let cornerRadius, let shadowRadius, let shadowOpacity):
            cardLayer.isHidden = false
            let cardSize = CGSize(width: bounds.width * 0.5, height: bounds.height * 0.6)
            cardLayer.bounds = CGRect(origin: .zero, size: cardSize)
            cardLayer.position = center
            cardLayer.transform = CATransform3DIdentity
            let scale = min(cardSize.width, cardSize.height) / 80
            cardLayer.cornerRadius = CGFloat(cornerRadius) * scale * 0.6
            cardLayer.shadowColor = NSColor.black.cgColor
            cardLayer.shadowOpacity = Float(shadowOpacity)
            cardLayer.shadowRadius = CGFloat(shadowRadius) * scale * 0.3
            cardLayer.shadowOffset = .zero

        case .highlightMask(let opacity):
            dimLayer.isHidden = false
            dimLayer.frame = bounds
            dimLayer.backgroundColor = NSColor.black.withAlphaComponent(opacity).cgColor
            cardLayer.isHidden = false
            let holeSize = CGSize(width: bounds.width * 0.32, height: bounds.height * 0.4)
            cardLayer.transform = CATransform3DIdentity
            cardLayer.bounds = CGRect(origin: .zero, size: holeSize)
            cardLayer.position = center
            cardLayer.cornerRadius = 4
            cardLayer.zPosition = 1
            dimLayer.zPosition = 0
        }
        CATransaction.commit()
    }
}
