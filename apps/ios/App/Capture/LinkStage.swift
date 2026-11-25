import UIKit

/// The Capture hero's picture of the link between this device and the Mac.
///
/// Looking: this device sits in the middle and sends out radar rings under a
/// slow sweep. Found: the rings let go, the two devices part and the Mac
/// springs in, with light running between them. Connected: the beam draws
/// itself solid, a check lands on it, the Mac answers with one burst, and a
/// calm pulse keeps travelling. Reduce Motion: the same states, cross-faded.
/// Decorative — the status text beside it speaks for it.
final class LinkStage: UIView {
    enum State: Equatable {
        case idle
        /// Something to fix first (Local Network is off, no link).
        case blocked
        case searching
        case connecting
        case connected
    }

    private(set) var state: State = .idle

    static let height: CGFloat = 152
    private static let phoneSide: CGFloat = 60
    private static let macSide: CGFloat = 68

    private let phone = CCIconTile(symbol: ThisDevice.isPad ? "ipad" : "iphone", side: LinkStage.phoneSide, kind: .raised, iconSize: 26, radius: .lg)
    private let mac = CCIconTile(symbol: "laptop", side: LinkStage.macSide, kind: .raised, iconSize: 30, radius: .lg)
    private let badge = UIView()
    private let badgeIcon = CCIconView("checkmark", pointSize: 12, weight: .semibold, tint: .white)

    private let radar = CALayer()
    private let sweep = CAGradientLayer()
    private let sweepMask = CAGradientLayer()
    private var rings: [CAShapeLayer] = []
    private let glow = CAGradientLayer()
    private let track = CAShapeLayer()
    private let beam = CAShapeLayer()
    private let comet = CAGradientLayer()
    private let burst = CAShapeLayer()
    private var laidOutWidth: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true

        radar.opacity = 0
        sweep.type = .conic
        sweep.startPoint = CGPoint(x: 0.5, y: 0.5)
        sweep.endPoint = CGPoint(x: 0.5, y: 0)
        sweep.locations = [0, 0.72, 1]
        sweepMask.type = .radial
        sweepMask.startPoint = CGPoint(x: 0.5, y: 0.5)
        sweepMask.endPoint = CGPoint(x: 1, y: 1)
        sweepMask.colors = [UIColor.black.cgColor, UIColor.black.withAlphaComponent(0.55).cgColor, UIColor.clear.cgColor]
        sweepMask.locations = [0, 0.55, 1]
        sweep.mask = sweepMask
        radar.addSublayer(sweep)
        for _ in 0..<3 {
            let ring = CAShapeLayer()
            ring.fillColor = nil
            ring.lineWidth = 1.5
            ring.opacity = 0
            rings.append(ring)
            radar.addSublayer(ring)
        }
        glow.type = .radial
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        radar.addSublayer(glow)
        layer.addSublayer(radar)

        track.fillColor = nil
        track.lineWidth = 2
        track.lineCap = .round
        track.lineDashPattern = [0.5, 7]
        beam.fillColor = nil
        beam.lineWidth = 2.5
        beam.lineCap = .round
        beam.strokeEnd = 0
        comet.startPoint = CGPoint(x: 0, y: 0.5)
        comet.endPoint = CGPoint(x: 1, y: 0.5)
        comet.opacity = 0
        burst.fillColor = nil
        burst.lineWidth = 2
        burst.opacity = 0
        [track, beam, comet, burst].forEach(layer.addSublayer)

        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.layer.cornerRadius = 13
        badge.alpha = 0
        badgeIcon.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(badgeIcon)
        [mac, phone, badge].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            phone.centerXAnchor.constraint(equalTo: centerXAnchor),
            phone.centerYAnchor.constraint(equalTo: centerYAnchor),
            mac.centerXAnchor.constraint(equalTo: centerXAnchor),
            mac.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.centerXAnchor.constraint(equalTo: centerXAnchor),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 26),
            badge.heightAnchor.constraint(equalToConstant: 26),
            badgeIcon.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            badgeIcon.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
        ])
        applyColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (stage: LinkStage, _: UITraitCollection) in
            stage.applyColors()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Half the distance between the two devices once they part.
    private var reach: CGFloat { min(112, max(60, bounds.width / 2 - Self.macSide / 2 - 8)) }
    private var parted: Bool { state != .searching }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.width != laidOutWidth else { return }
        laidOutWidth = bounds.width
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let side = Self.height
        radar.frame = CGRect(x: center.x - side / 2, y: 0, width: side, height: side)
        sweep.frame = radar.bounds
        sweepMask.frame = sweep.bounds.insetBy(dx: side * 0.146, dy: side * 0.146)
        sweep.cornerRadius = side / 2
        glow.frame = radar.bounds.insetBy(dx: 22, dy: 22)
        for ring in rings {
            ring.frame = radar.bounds
            ring.path = UIBezierPath(ovalIn: radar.bounds.insetBy(dx: 1, dy: 1)).cgPath
        }
        let line = UIBezierPath()
        line.move(to: CGPoint(x: center.x - reach + Self.phoneSide / 2 + 8, y: center.y))
        line.addLine(to: CGPoint(x: center.x + reach - Self.macSide / 2 - 8, y: center.y))
        for shape in [track, beam] {
            shape.frame = bounds
            shape.path = line.cgPath
        }
        comet.bounds = CGRect(x: 0, y: 0, width: 26, height: 5)
        comet.cornerRadius = 2.5
        burst.bounds = CGRect(x: 0, y: 0, width: Self.macSide, height: Self.macSide)
        burst.position = CGPoint(x: center.x + reach, y: center.y)
        burst.path = UIBezierPath(roundedRect: burst.bounds, cornerRadius: CCTheme.radii.lg).cgPath
        CATransaction.commit()
        apply(from: nil)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Core Animation drops running loops with the window.
        if window != nil { restartLoops() }
    }

    func setState(_ new: State) {
        guard new != state else { return }
        let old = state
        state = new
        guard laidOutWidth > 0 else { return }
        apply(from: window == nil ? nil : old)
    }

    // MARK: - Drawing

    private func applyColors() {
        let c = CCTheme.color
        func cg(_ color: UIColor, _ alpha: CGFloat = 1) -> CGColor {
            let resolved = color.resolvedColor(with: traitCollection)
            return resolved.withAlphaComponent(resolved.cgColor.alpha * alpha).cgColor
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sweep.colors = [cg(c.primary, 0), cg(c.primary, 0), cg(c.primary, 0.42)]
        glow.colors = [cg(c.primary, 0.34), cg(c.primary, 0)]
        rings.forEach { $0.strokeColor = cg(c.primary, 0.75) }
        track.strokeColor = cg(c.faintForeground)
        beam.strokeColor = cg(c.success)
        burst.strokeColor = cg(c.success)
        let light = state == .connected ? c.success : c.primary
        comet.colors = [cg(light, 0), cg(light), cg(light, 0)]
        CATransaction.commit()
        badge.backgroundColor = state == .blocked ? c.warning : c.success
        badgeIcon.iconName = state == .blocked ? "warning-fill" : "checkmark"
    }

    /// Settle every part on `state`; `old` nil lands without motion.
    private func apply(from old: State?) {
        let animated = old != nil
        applyColors()

        let part = parted ? reach : 0
        move(phone.layer, "transform.translation.x", to: -part, .arrive, animated)
        let macShown = parted
        let dim: CGFloat = state == .idle || state == .blocked ? 0.45 : 1
        if macShown, old == .searching, animated {
            // The Mac appears where it will stand, out of nothing.
            setModel(mac.layer, "transform.translation.x", part)
            if CCMotion.reduceMotion {
                setModel(mac.layer, "transform.scale", 1)
            } else {
                CCMotion.spring(mac.layer, keyPath: "transform.scale", from: 0.3, to: 1, .bouncy, delay: 0.14)
            }
        } else if !macShown {
            move(mac.layer, "transform.scale", to: 0.6, .smooth, animated)
        } else {
            move(mac.layer, "transform.translation.x", to: part, .arrive, animated)
            move(mac.layer, "transform.scale", to: 1, .smooth, animated)
        }
        fade(mac, to: macShown ? dim : 0, animated, delay: old == .searching ? 0.14 : 0)
        fade(phone, to: dim, animated)

        fade(radar, to: state == .searching ? 1 : 0, animated, duration: 0.2)
        fade(track, to: parted ? (state == .connected ? 0 : 1) : 0, animated, delay: old == .searching ? 0.2 : 0)

        let connected = state == .connected
        if connected, animated, !CCMotion.reduceMotion {
            let draw = CABasicAnimation(keyPath: "strokeEnd")
            draw.fromValue = 0
            draw.toValue = 1
            draw.duration = CCMotion.paced(0.5)
            draw.timingFunction = CCMotion.settle
            let delay = old == .searching ? 0.22 : 0.0
            draw.beginTime = beam.convertTime(CACurrentMediaTime(), from: nil) + CCMotion.paced(delay)
            draw.fillMode = .backwards
            setModel(beam, "strokeEnd", 1)
            setModel(beam, "opacity", Float(1))
            beam.add(draw, forKey: "draw")
            fireBurst(delay: delay + 0.34)
        } else {
            // Leaving: the whole beam fades (the next draw starts from zero).
            if connected || !animated { setModel(beam, "strokeEnd", connected ? 1 : 0) }
            fade(beam, to: connected ? 1 : 0, animated)
        }

        let showBadge = connected || state == .blocked
        let delay = connected ? (old == .searching ? 0.6 : 0.38) : 0
        fade(badge, to: showBadge ? 1 : 0, animated, delay: showBadge ? delay : 0)
        if showBadge, animated, !CCMotion.reduceMotion {
            CCMotion.spring(badge.layer, keyPath: "transform.scale", from: 0.2, to: 1, .bouncy, delay: delay)
        }
        restartLoops()
    }

    private func setModel(_ layer: CALayer, _ keyPath: String, _ value: Any) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(value, forKeyPath: keyPath)
        CATransaction.commit()
    }

    private func move(_ layer: CALayer, _ keyPath: String, to value: CGFloat, _ spring: CCMotion.Spring, _ animated: Bool) {
        let current = (layer.value(forKeyPath: keyPath) as? CGFloat) ?? 0
        guard abs(current - value) > 0.001 else { return }
        if animated { CCMotion.spring(layer, keyPath: keyPath, to: value, spring) } else { setModel(layer, keyPath, value) }
    }

    private func fade(_ view: UIView, to alpha: CGFloat, _ animated: Bool, delay: TimeInterval = 0) {
        if animated { CCMotion.fadeAlpha(view, to: alpha, duration: 0.24, delay: delay) } else { view.alpha = alpha }
    }

    private func fade(_ layer: CALayer, to opacity: Float, _ animated: Bool, duration: TimeInterval = 0.24, delay: TimeInterval = 0) {
        if animated { CCMotion.fade(layer, keyPath: "opacity", to: opacity, duration: duration, delay: delay) } else { setModel(layer, "opacity", opacity) }
    }

    // MARK: - Loops

    private func restartLoops() {
        rings.forEach { $0.removeAnimation(forKey: "ping") }
        sweep.removeAnimation(forKey: "turn")
        glow.removeAnimation(forKey: "breathe")
        comet.removeAnimation(forKey: "travel")
        guard window != nil, laidOutWidth > 0 else { return }
        if CCMotion.reduceMotion {
            // Still rings, so "looking" reads without movement.
            for (index, ring) in rings.enumerated() {
                setModel(ring, "transform.scale", 0.55 + 0.2 * CGFloat(index))
                setModel(ring, "opacity", Float(0.5 - 0.13 * Double(index)))
            }
            return
        }
        switch state {
        case .searching: startRadar()
        case .connecting: startComet(period: 0.95, pause: 0, bothWays: true, delay: 0.5)
        case .connected: startComet(period: 1.1, pause: 1.7, bothWays: false, delay: 1.2)
        case .idle, .blocked: break
        }
    }

    private func startRadar() {
        let now = layer.convertTime(CACurrentMediaTime(), from: nil)
        let period = CCMotion.paced(2.7)
        for (index, ring) in rings.enumerated() {
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.38
            scale.toValue = 1
            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = [0, 0.9, 0]
            opacity.keyTimes = [0, 0.14, 1]
            let group = CAAnimationGroup()
            group.animations = [scale, opacity]
            group.duration = period
            group.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 0.6, 0.4, 1)
            group.repeatCount = .infinity
            group.isRemovedOnCompletion = false
            group.beginTime = now + period / 3 * Double(index)
            group.fillMode = .backwards
            ring.add(group, forKey: "ping")
        }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = CGFloat.pi * 2
        turn.duration = CCMotion.paced(3.2)
        turn.repeatCount = .infinity
        turn.isRemovedOnCompletion = false
        sweep.add(turn, forKey: "turn")
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 0.55
        breathe.toValue = 1
        breathe.duration = CCMotion.paced(1.35)
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.isRemovedOnCompletion = false
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glow.add(breathe, forKey: "breathe")
    }

    /// Light running along the beam.
    private func startComet(period: TimeInterval, pause: TimeInterval, bothWays: Bool, delay: TimeInterval = 0) {
        let left = bounds.midX - reach + Self.phoneSide / 2 + 14
        let right = bounds.midX + reach - Self.macSide / 2 - 14
        guard right > left else { return }
        setModel(comet, "position", NSValue(cgPoint: CGPoint(x: left, y: bounds.midY)))
        let travel = CABasicAnimation(keyPath: "position.x")
        travel.fromValue = left
        travel.toValue = right
        travel.duration = CCMotion.paced(period)
        travel.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        let shine = CAKeyframeAnimation(keyPath: "opacity")
        shine.values = [0, 1, 1, 0]
        shine.keyTimes = [0, 0.18, 0.82, 1]
        shine.duration = CCMotion.paced(period)
        let group = CAAnimationGroup()
        group.animations = [travel, shine]
        group.duration = CCMotion.paced(period + pause)
        group.autoreverses = bothWays
        group.repeatCount = .infinity
        group.isRemovedOnCompletion = false
        group.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + CCMotion.paced(delay)
        group.fillMode = .backwards
        comet.add(group, forKey: "travel")
    }

    private func fireBurst(delay: TimeInterval) {
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1
        scale.toValue = 1.55
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0.8
        opacity.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, opacity]
        group.duration = CCMotion.paced(0.7)
        group.timingFunction = CCMotion.settle
        group.beginTime = burst.convertTime(CACurrentMediaTime(), from: nil) + CCMotion.paced(delay)
        burst.add(group, forKey: "burst")
    }

    #if DEBUG
    // Probe seams (computed: nothing left in a Release binary).
    var probePhoneOffset: CGFloat { (phone.layer.presentation() ?? phone.layer).value(forKeyPath: "transform.translation.x") as? CGFloat ?? 0 }
    var probeReach: CGFloat { reach }
    var probeMacOpacity: Float { (mac.layer.presentation() ?? mac.layer).opacity }
    var probeMacScale: CGFloat { (mac.layer.presentation() ?? mac.layer).value(forKeyPath: "transform.scale") as? CGFloat ?? 0 }
    var probeBeam: CGFloat { (beam.presentation() ?? beam).strokeEnd }
    var probeRingScale: CGFloat { (rings[0].presentation() ?? rings[0]).value(forKeyPath: "transform.scale") as? CGFloat ?? 0 }
    var probeRadarRunning: Bool { rings.allSatisfy { $0.animation(forKey: "ping") != nil } && sweep.animation(forKey: "turn") != nil }
    var probeCometRunning: Bool { comet.animation(forKey: "travel") != nil }
    #endif
}
