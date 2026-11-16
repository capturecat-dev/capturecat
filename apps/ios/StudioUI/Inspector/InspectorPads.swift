import UIKit

/// The inspector's 2D pads on iOS. Each maps a touch to the fraction the
/// shared math takes (InspectorPadMath) in its OWN geometry and hands it to
/// the pane's write; snapping, clamping and magnetism live in the shared
/// math. A drag is one undo step (begin on press, commit on release).
@MainActor
class InspectorPadRowView: UIView, InspectorRowView {
    let rowID: String
    let pad: CCPadView
    weak var host: InspectorHost?
    private let visible: (InspectorScope) -> Bool
    private let undoName: String
    private let titleLabel: UILabel?
    let pill: UILabel?

    init(id: String, title: String?, undoName: String, padHeight: CGFloat, host: InspectorHost,
         visible: @escaping (InspectorScope) -> Bool) {
        rowID = id
        self.host = host
        self.visible = visible
        self.undoName = undoName
        pad = CCPadView(title: title ?? undoName)
        if let title {
            titleLabel = ccLabel(title, font: CCFont.labelMedium, color: CCTheme.color.foreground)
            pill = ccLabel("", font: CCFont.monoSmall, color: CCTheme.color.mutedForeground, alignment: .right)
        } else {
            titleLabel = nil
            pill = nil
        }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        pad.accessibilityIdentifier = id
        pad.heightAnchor.constraint(equalToConstant: padHeight).isActive = true
        var views: [UIView] = []
        if let titleLabel, let pill {
            titleLabel.adjustsFontForContentSizeCategory = true
            let header = UIStackView(arrangedSubviews: [titleLabel, pill])
            header.distribution = .fill
            titleLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            pill.setContentHuggingPriority(.defaultLow, for: .horizontal)
            pill.isAccessibilityElement = false
            titleLabel.isAccessibilityElement = false
            views.append(header)
        }
        views.append(pad)
        let column = UIStackView(arrangedSubviews: views)
        column.axis = .vertical
        column.spacing = CCSpace.sm
        addSubview(column)
        pinEdges(column, to: self)
        pad.onTouch = { [weak self] phase, point in self?.touch(phase, point) }
        pad.onNudge = { [weak self] dx, dy in self?.nudge(dx, dy) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func touch(_ phase: CCPadView.Phase, _ point: CGPoint) {
        guard let host else { return }
        if phase == .began { host.session.begin(rowID, name: undoName) }
        let fraction = self.fraction(at: point)
        drag(host.scope, fraction)
        if phase == .ended {
            release(host.scope)
            host.session.commit()
        }
        refresh(host.scope)
    }

    private func nudge(_ dx: CGFloat, _ dy: CGFloat) {
        guard let host else { return }
        let current = currentFraction(host.scope)
        host.session.begin(rowID, name: undoName)
        drag(host.scope, CGPoint(x: current.x + dx * nudgeScale.x, y: current.y + dy * nudgeScale.y))
        release(host.scope)
        host.session.commit()
        refresh(host.scope)
    }

    // MARK: Subclass hooks

    /// Touch point (pad coordinates) → the fraction the shared math takes.
    func fraction(at point: CGPoint) -> CGPoint { point }
    /// The inverse (probes, knob placement).
    func point(for fraction: CGPoint) -> CGPoint { fraction }
    func drag(_ scope: InspectorScope, _ fraction: CGPoint) {}
    func release(_ scope: InspectorScope) {}
    func currentFraction(_ scope: InspectorScope) -> CGPoint { CGPoint(x: 0.5, y: 0.5) }
    var nudgeScale: CGPoint { CGPoint(x: 1, y: 1) }
    func valueText(_ scope: InspectorScope) -> String { "" }

    func isRowVisible(_ scope: InspectorScope) -> Bool { visible(scope) }

    func refresh(_ scope: InspectorScope) {
        let text = valueText(scope)
        pill?.text = text
        pad.accessibilityValueProvider = { text }
    }

    /// Press and release at a shared-math fraction, through the touch path.
    func probePress(fx: CGFloat, fy: CGFloat) {
        layoutIfNeeded()
        pad.probePress(at: point(for: CGPoint(x: fx, y: fy)))
    }
}

// MARK: - Placement (Background ▸ Frame)

final class InspectorPlacementPad: InspectorPadRowView {
    private var dots: [CALayer] = []
    private let card = CALayer()

    init(host: InspectorHost) {
        super.init(id: "background.placementPad", title: nil, undoName: "Placement", padHeight: 112, host: host,
                   visible: { _ in true })
        pad.showsKnob = false
        for _ in 0..<9 {
            let dot = CALayer()
            dot.cornerRadius = 1.5
            pad.contentLayer.addSublayer(dot)
            dots.append(dot)
        }
        card.backgroundColor = UIColor.white.withAlphaComponent(0.85).cgColor
        card.cornerRadius = 3
        card.cornerCurve = .continuous
        card.shadowColor = UIColor.black.cgColor
        card.shadowOpacity = 0.35
        card.shadowRadius = 3
        card.shadowOffset = CGSize(width: 0, height: 1)
        pad.contentLayer.addSublayer(card)
        ccOnThemeChange { [weak self] in self?.applyDots() }
        applyDots()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func applyDots() {
        let ink: UIColor = CCTheme.isDark(traitCollection) ? .white : .black
        for dot in dots { dot.backgroundColor = ink.withAlphaComponent(0.22).cgColor }
    }

    override func fraction(at point: CGPoint) -> CGPoint {
        CGPoint(x: point.x / max(1, pad.bounds.width), y: point.y / max(1, pad.bounds.height))
    }

    override func point(for fraction: CGPoint) -> CGPoint {
        CGPoint(x: fraction.x * pad.bounds.width, y: fraction.y * pad.bounds.height)
    }

    override func drag(_ scope: InspectorScope, _ fraction: CGPoint) {
        BackgroundPane.placementPad(scope, fx: fraction.x, fy: fraction.y)
    }

    override func currentFraction(_ scope: InspectorScope) -> CGPoint {
        let f = InspectorPadMath.placementFractions[scope.settings.videoPlacement] ?? (0.5, 0.5)
        return CGPoint(x: f.x * 0.9 + 0.05, y: f.y * 0.9 + 0.05)
    }

    override var nudgeScale: CGPoint { CGPoint(x: 7, y: 7) }

    override func valueText(_ scope: InspectorScope) -> String {
        BackgroundPane.isCustomPlacement(scope) ? "Custom" : scope.settings.videoPlacement.rawValue
    }

    override func refresh(_ scope: InspectorScope) {
        super.refresh(scope)
        let s = scope.settings
        let size = pad.bounds.size
        guard size.width > 1 else { return }
        let inset = 8 + CGFloat(min(max(s.backgroundPadding, 0), 300) / 300) * min(size.width, size.height) * 0.28
        let content = CGRect(x: inset, y: inset, width: max(1, size.width - 2 * inset), height: max(1, size.height - 2 * inset))
        let cardW = content.width * 0.5, cardH = content.height * 0.58
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.18)
        for (i, dot) in dots.enumerated() {
            dot.frame = CGRect(x: content.minX + content.width * (CGFloat(i % 3) / 2) - 1.5,
                               y: content.minY + content.height * (CGFloat(i / 3) / 2) - 1.5, width: 3, height: 3)
        }
        if BackgroundPane.isCustomPlacement(scope) {
            let fx = min(1, max(0, s.videoCustomX ?? 0.5)), fy = min(1, max(0, s.videoCustomY ?? 0.5))
            card.frame = CGRect(x: content.minX + content.width * fx - cardW / 2,
                                y: content.minY + content.height * fy - cardH / 2, width: cardW, height: cardH)
        } else {
            let f = InspectorPadMath.placementFractions[s.videoPlacement] ?? (0.5, 0.5)
            card.frame = CGRect(x: content.minX + (content.width - cardW) * f.x,
                                y: content.minY + (content.height - cardH) * f.y, width: cardW, height: cardH)
        }
        CATransaction.commit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let host { refresh(host.scope) }
    }
}

// MARK: - Camera bubble (Camera ▸ pad)

final class InspectorCameraPad: InspectorPadRowView {
    private let inset: CGFloat = 8
    private let bubble = CALayer()

    init(host: InspectorHost) {
        super.init(id: "camera.pad", title: nil, undoName: "Move Camera", padHeight: 112, host: host,
                   visible: { _ in true })
        pad.showsKnob = false
        bubble.cornerCurve = .continuous
        bubble.borderWidth = 1.5
        bubble.borderColor = UIColor.white.withAlphaComponent(0.6).cgColor
        bubble.backgroundColor = UIColor(red: 0.42, green: 0.48, blue: 0.62, alpha: 1).cgColor
        pad.contentLayer.addSublayer(bubble)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func bubbleSize(_ scope: InspectorScope) -> CGFloat {
        InspectorPadMath.cameraBubbleDiameter(cameraSize: scope.settings.effectiveCameraSize)
    }

    private var lastBubble: CGFloat = 30

    override func fraction(at point: CGPoint) -> CGPoint {
        let b = lastBubble
        let usableW = max(1, pad.bounds.width - b - 2 * inset)
        let usableH = max(1, pad.bounds.height - b - 2 * inset)
        return CGPoint(x: (point.x - inset - b / 2) / usableW, y: (point.y - inset - b / 2) / usableH)
    }

    override func point(for fraction: CGPoint) -> CGPoint {
        let b = lastBubble
        let usableW = max(1, pad.bounds.width - b - 2 * inset)
        let usableH = max(1, pad.bounds.height - b - 2 * inset)
        return CGPoint(x: inset + b / 2 + fraction.x * usableW, y: inset + b / 2 + fraction.y * usableH)
    }

    override func drag(_ scope: InspectorScope, _ fraction: CGPoint) {
        InspectorPadMath.cameraDrag(scope.settings, fx: fraction.x, fy: fraction.y)
    }

    override func release(_ scope: InspectorScope) { InspectorPadMath.cameraRelease(scope.settings) }

    override func currentFraction(_ scope: InspectorScope) -> CGPoint { InspectorPadMath.cameraFraction(scope.settings) }

    override func valueText(_ scope: InspectorScope) -> String {
        let s = scope.settings
        if s.cameraCustomX != nil, s.cameraCustomY != nil {
            let f = InspectorPadMath.cameraFraction(s)
            return "\(Int((f.x * 100).rounded()))% / \(Int((f.y * 100).rounded()))%"
        }
        return s.cameraPosition.rawValue
    }

    override func refresh(_ scope: InspectorScope) {
        super.refresh(scope)
        lastBubble = bubbleSize(scope)
        guard pad.bounds.width > 1 else { return }
        let b = lastBubble
        let center = point(for: currentFraction(scope))
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.16)
        bubble.frame = CGRect(x: center.x - b / 2, y: center.y - b / 2, width: b, height: b)
        switch scope.settings.cameraShape {
        case .circle: bubble.cornerRadius = b / 2
        case .squircle: bubble.cornerRadius = b / 2 * 0.6
        case .roundedRect: bubble.cornerRadius = b / 2 * 0.35
        case .square: bubble.cornerRadius = 0
        }
        CATransaction.commit()
        pad.alpha = CameraPane.showDetails(scope) ? 1 : 0.45
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let host { refresh(host.scope) }
    }
}

// MARK: - Tilt (Effects ▸ Tilt, Camera ▸ Style)

final class InspectorTiltPad: InspectorPadRowView {
    private let maxAngle: Double
    private let angles: (InspectorScope) -> (pitch: Double, yaw: Double, roll: Double)
    private let write: (InspectorScope, Double, Double) -> Void
    private let card = CALayer()
    private let crossH = CALayer()
    private let crossV = CALayer()

    init(id: String, maxAngle: Double, host: InspectorHost, visible: @escaping (InspectorScope) -> Bool,
         angles: @escaping (InspectorScope) -> (pitch: Double, yaw: Double, roll: Double),
         write: @escaping (InspectorScope, Double, Double) -> Void) {
        self.maxAngle = maxAngle
        self.angles = angles
        self.write = write
        super.init(id: id, title: "Skew", undoName: "Tilt", padHeight: 132, host: host, visible: visible)
        pad.knobAreaInset = 10
        for line in [crossH, crossV] { pad.contentLayer.addSublayer(line) }
        card.cornerRadius = 4
        card.cornerCurve = .continuous
        card.backgroundColor = UIColor.white.withAlphaComponent(0.82).cgColor
        pad.contentLayer.addSublayer(card)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(resetTilt))
        doubleTap.numberOfTapsRequired = 2
        pad.addGestureRecognizer(doubleTap)
        ccOnThemeChange { [weak self] in self?.applyCross() }
        applyCross()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func applyCross() {
        let ink: UIColor = CCTheme.isDark(traitCollection) ? .white : .black
        for line in [crossH, crossV] { line.backgroundColor = ink.withAlphaComponent(0.12).cgColor }
    }

    /// Half-extents fractions, x right, y UP (InspectorPadMath.tiltAngles).
    override func fraction(at point: CGPoint) -> CGPoint {
        let size = pad.bounds.size
        return CGPoint(x: (point.x - size.width / 2) / max(1, size.width / 2 - 10),
                       y: (size.height / 2 - point.y) / max(1, size.height / 2 - 10))
    }

    override func point(for fraction: CGPoint) -> CGPoint {
        let size = pad.bounds.size
        return CGPoint(x: size.width / 2 + fraction.x * max(1, size.width / 2 - 10),
                       y: size.height / 2 - fraction.y * max(1, size.height / 2 - 10))
    }

    override func drag(_ scope: InspectorScope, _ fraction: CGPoint) {
        let a = InspectorPadMath.tiltAngles(fx: Double(fraction.x), fy: Double(fraction.y), maxAngle: maxAngle)
        write(scope, a.pitch, a.yaw)
    }

    override func currentFraction(_ scope: InspectorScope) -> CGPoint {
        let a = angles(scope)
        return CGPoint(x: a.yaw / maxAngle, y: a.pitch / maxAngle)
    }

    override var nudgeScale: CGPoint { CGPoint(x: 2, y: -2) }

    override func valueText(_ scope: InspectorScope) -> String {
        let a = angles(scope)
        return String(format: "%.0f° / %.0f°", a.pitch, a.yaw)
    }

    @objc private func resetTilt() {
        guard let host else { return }
        host.session.perform(rowID, name: "Reset Tilt") { write(host.scope, 0, 0) }
        refresh(host.scope)
    }

    override func refresh(_ scope: InspectorScope) {
        super.refresh(scope)
        let size = pad.bounds.size
        guard size.width > 1 else { return }
        let a = angles(scope)
        pad.setKnob(InspectorPadMath.tiltKnobFraction(pitch: a.pitch, yaw: a.yaw, maxAngle: maxAngle), animated: true)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        crossH.frame = CGRect(x: 10, y: size.height / 2 - 0.5, width: size.width - 20, height: 1)
        crossV.frame = CGRect(x: size.width / 2 - 0.5, y: 10, width: 1, height: size.height - 20)
        card.bounds = CGRect(x: 0, y: 0, width: size.width * 0.34, height: size.height * 0.4)
        card.position = CGPoint(x: size.width / 2, y: size.height / 2)
        var t = CATransform3DIdentity
        t.m34 = -1 / 300
        t = CATransform3DRotate(t, CGFloat(a.pitch * .pi / 180), 1, 0, 0)
        t = CATransform3DRotate(t, CGFloat(a.yaw * .pi / 180), 0, 1, 0)
        t = CATransform3DRotate(t, CGFloat(a.roll * .pi / 180), 0, 0, 1)
        card.transform = t
        CATransaction.commit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let host { refresh(host.scope) }
    }

    override func probePress(fx: CGFloat, fy: CGFloat) {
        layoutIfNeeded()
        // The pad commits on press (and drag); its release writes nothing.
        pad.probePress(at: point(for: CGPoint(x: fx, y: fy)))
    }
}

// MARK: - Focus / offset (Effects ▸ Zoom)

final class InspectorPointPad: InspectorPadRowView {
    private let read: (InspectorScope) -> CGPoint
    private let write: (InspectorScope, CGPoint) -> Void
    private let crossH = CALayer()
    private let crossV = CALayer()

    init(id: String, title: String, host: InspectorHost, visible: @escaping (InspectorScope) -> Bool,
         read: @escaping (InspectorScope) -> CGPoint, write: @escaping (InspectorScope, CGPoint) -> Void) {
        self.read = read
        self.write = write
        super.init(id: id, title: title, undoName: title, padHeight: 112, host: host, visible: visible)
        pad.knobAreaInset = 0
        for line in [crossH, crossV] { pad.contentLayer.addSublayer(line) }
        ccOnThemeChange { [weak self] in self?.applyCross() }
        applyCross()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func applyCross() {
        let ink: UIColor = CCTheme.isDark(traitCollection) ? .white : .black
        for line in [crossH, crossV] { line.backgroundColor = ink.withAlphaComponent(0.10).cgColor }
    }

    override func fraction(at point: CGPoint) -> CGPoint {
        CGPoint(x: point.x / max(1, pad.bounds.width), y: point.y / max(1, pad.bounds.height))
    }

    override func point(for fraction: CGPoint) -> CGPoint {
        CGPoint(x: fraction.x * pad.bounds.width, y: fraction.y * pad.bounds.height)
    }

    override func drag(_ scope: InspectorScope, _ fraction: CGPoint) { write(scope, fraction) }
    override func currentFraction(_ scope: InspectorScope) -> CGPoint { read(scope) }

    override func valueText(_ scope: InspectorScope) -> String {
        let p = read(scope)
        return "\(Int((p.x * 100).rounded()))% / \(Int((p.y * 100).rounded()))%"
    }

    override func refresh(_ scope: InspectorScope) {
        super.refresh(scope)
        let size = pad.bounds.size
        guard size.width > 1 else { return }
        let p = read(scope)
        pad.setKnob(CGPoint(x: min(1, max(0, p.x)), y: min(1, max(0, p.y))), animated: true)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        crossH.frame = CGRect(x: 0, y: size.height / 2 - 0.5, width: size.width, height: 1)
        crossV.frame = CGRect(x: size.width / 2 - 0.5, y: 0, width: 1, height: size.height)
        CATransaction.commit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let host { refresh(host.scope) }
    }

    override func probePress(fx: CGFloat, fy: CGFloat) {
        layoutIfNeeded()
        pad.probePress(at: point(for: CGPoint(x: fx, y: fy)))
    }
}

// MARK: - Subtitles position

final class InspectorSubtitlePad: InspectorPadRowView {
    private let inset: CGFloat = 8
    private let pillSize = CGSize(width: 34, height: 18)
    private let fauxCard = CALayer()
    private let pillLayer = CALayer()

    init(host: InspectorHost) {
        super.init(id: "subtitles.positionPad", title: nil, undoName: "Move Subtitles", padHeight: 112, host: host,
                   visible: { _ in true })
        pad.showsKnob = false
        fauxCard.cornerRadius = 4
        fauxCard.cornerCurve = .continuous
        pillLayer.cornerRadius = 4
        pillLayer.backgroundColor = UIColor.black.withAlphaComponent(0.7).cgColor
        pillLayer.borderColor = UIColor.white.withAlphaComponent(0.7).cgColor
        pillLayer.borderWidth = 1
        pad.contentLayer.addSublayer(fauxCard)
        pad.contentLayer.addSublayer(pillLayer)
        ccOnThemeChange { [weak self] in self?.applyInk() }
        applyInk()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func applyInk() {
        let ink: UIColor = CCTheme.isDark(traitCollection) ? .white : .black
        fauxCard.backgroundColor = ink.withAlphaComponent(0.10).cgColor
    }

    override func fraction(at point: CGPoint) -> CGPoint {
        let usableW = max(1, pad.bounds.width - 2 * inset - pillSize.width)
        let usableH = max(1, pad.bounds.height - 2 * inset - pillSize.height)
        return CGPoint(x: (point.x - inset - pillSize.width / 2) / usableW,
                       y: (point.y - inset - pillSize.height / 2) / usableH)
    }

    override func point(for fraction: CGPoint) -> CGPoint {
        let usableW = max(1, pad.bounds.width - 2 * inset - pillSize.width)
        let usableH = max(1, pad.bounds.height - 2 * inset - pillSize.height)
        return CGPoint(x: inset + pillSize.width / 2 + fraction.x * usableW,
                       y: inset + pillSize.height / 2 + fraction.y * usableH)
    }

    override func drag(_ scope: InspectorScope, _ fraction: CGPoint) {
        InspectorPadMath.subtitleDrag(scope.settings, fx: fraction.x, fy: fraction.y)
    }

    override func release(_ scope: InspectorScope) { InspectorPadMath.subtitleRelease(scope.settings) }
    override func currentFraction(_ scope: InspectorScope) -> CGPoint { InspectorPadMath.subtitleFraction(scope.settings) }

    override func valueText(_ scope: InspectorScope) -> String {
        let s = scope.settings
        guard s.subtitleCustomX != nil, s.subtitleCustomY != nil else { return s.subtitlePosition.rawValue }
        let f = InspectorPadMath.subtitleFraction(s)
        return "\(Int((f.x * 100).rounded()))% / \(Int((f.y * 100).rounded()))%"
    }

    override func refresh(_ scope: InspectorScope) {
        super.refresh(scope)
        let size = pad.bounds.size
        guard size.width > 1 else { return }
        let f = InspectorPadMath.subtitleFraction(scope.settings)
        let center = point(for: f)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.16)
        fauxCard.frame = CGRect(x: size.width * 0.29, y: size.height * 0.29 - 6, width: size.width * 0.42, height: size.height * 0.42)
        pillLayer.frame = CGRect(x: center.x - pillSize.width / 2, y: center.y - pillSize.height / 2,
                                 width: pillSize.width, height: pillSize.height)
        CATransaction.commit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let host { refresh(host.scope) }
    }
}

// MARK: - Watermark position (Brand)

final class InspectorWatermarkPad: InspectorPadRowView {
    private let inset: CGFloat = 8
    private let mark = CALayer()
    private var logo: UIImage?
    private var loadedName: String??

    init(host: InspectorHost) {
        super.init(id: "brand.pad", title: nil, undoName: "Move Watermark", padHeight: 112, host: host,
                   visible: { _ in true })
        pad.showsKnob = false
        mark.contentsGravity = .resizeAspect
        pad.contentLayer.addSublayer(mark)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func markSize(_ scope: InspectorScope) -> CGSize {
        let w = InspectorPadMath.watermarkMarkWidth(size: scope.settings.watermarkSize)
        let aspect: CGFloat = {
            guard let logo, logo.size.height > 0 else { return 1.5 }
            return logo.size.width / logo.size.height
        }()
        return CGSize(width: w, height: w / max(0.35, min(4, aspect)))
    }

    private var lastMark = CGSize(width: 24, height: 16)

    override func fraction(at point: CGPoint) -> CGPoint {
        let usableW = max(1, pad.bounds.width - 2 * inset - lastMark.width)
        let usableH = max(1, pad.bounds.height - 2 * inset - lastMark.height)
        return CGPoint(x: (point.x - inset - lastMark.width / 2) / usableW,
                       y: (point.y - inset - lastMark.height / 2) / usableH)
    }

    override func point(for fraction: CGPoint) -> CGPoint {
        let usableW = max(1, pad.bounds.width - 2 * inset - lastMark.width)
        let usableH = max(1, pad.bounds.height - 2 * inset - lastMark.height)
        return CGPoint(x: inset + lastMark.width / 2 + fraction.x * usableW,
                       y: inset + lastMark.height / 2 + fraction.y * usableH)
    }

    override func drag(_ scope: InspectorScope, _ fraction: CGPoint) {
        InspectorPadMath.watermarkDrag(scope.settings, fx: fraction.x, fy: fraction.y)
    }

    override func release(_ scope: InspectorScope) { InspectorPadMath.watermarkRelease(scope.settings) }

    override func currentFraction(_ scope: InspectorScope) -> CGPoint {
        CGPoint(x: scope.settings.watermarkX, y: scope.settings.watermarkY)
    }

    override func valueText(_ scope: InspectorScope) -> String {
        "\(Int((scope.settings.watermarkX * 100).rounded()))% / \(Int((scope.settings.watermarkY * 100).rounded()))%"
    }

    override func refresh(_ scope: InspectorScope) {
        super.refresh(scope)
        let name = scope.settings.watermarkFileName
        if loadedName != name {
            loadedName = name
            logo = scope.project?.watermarkImageURL.flatMap { UIImage(contentsOfFile: $0.path) }
        }
        lastMark = markSize(scope)
        guard pad.bounds.width > 1 else { return }
        let f = CGPoint(x: min(1, max(0, scope.settings.watermarkX)), y: min(1, max(0, scope.settings.watermarkY)))
        let c = point(for: f)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.16)
        mark.frame = CGRect(x: c.x - lastMark.width / 2, y: c.y - lastMark.height / 2,
                            width: lastMark.width, height: lastMark.height)
        mark.contents = (logo ?? CCIcon.image("seal.fill", pointSize: 14, weight: .regular, color: .white))?.cgImage
        mark.opacity = Float(max(0.35, scope.settings.watermarkOpacity))
        CATransaction.commit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let host { refresh(host.scope) }
    }
}
