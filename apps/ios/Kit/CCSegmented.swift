import UIKit

/// CCKit segmented control — shadcn's Tabs list: a recessed well holding
/// equal-width segments, with a FLOATING selection chip that springs between
/// them (`.snappy`). Tap or slide a finger across to choose.
///
///     let filter = CCSegmented(segments: ["All", "Recordings", "Screenshots", "Shares"]) { i in … }
final class CCSegmented: UIControl {
    enum Size {
        case sm
        case regular

        var height: CGFloat { self == .sm ? 32 : 38 }
        var inset: CGFloat { self == .sm ? 2 : 3 }
        var font: UIFont {
            self == .sm ? CCFont.scaled(13, .medium, .footnote, max: 17) : CCFont.scaled(15, .medium, .subheadline, max: 19)
        }
    }

    var onChange: ((Int) -> Void)?
    let size: Size
    var radius: CCRadius { didSet { setNeedsLayout() } }

    private(set) var selectedIndex: Int

    func setSelectedIndex(_ index: Int, animated: Bool = true) {
        guard labels.indices.contains(index), index != selectedIndex else { return }
        selectedIndex = index
        refreshSelection(animated: animated)
    }

    override var isEnabled: Bool {
        didSet { alpha = isEnabled ? 1 : CCTheme.disabledAlpha }
    }

    private var labels: [UILabel] = []
    private var titles: [String]
    private let selection = CALayer()
    /// Differentiate Without Color: a bar under the chosen segment's label.
    private let mark = CALayer()
    private var accessibilityItems: [CCAccessibilityAction] = []

    init(segments: [String], selectedIndex: Int = 0, size: Size = .regular, radius: CCRadius = .md, onChange: ((Int) -> Void)? = nil) {
        self.titles = segments
        self.selectedIndex = selectedIndex
        self.size = size
        self.radius = radius
        self.onChange = onChange
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerCurve = .continuous
        selection.cornerCurve = .continuous
        layer.addSublayer(selection)
        mark.cornerRadius = 1
        mark.opacity = 0
        selection.addSublayer(mark)
        for text in segments {
            let label = UILabel()
            label.text = text
            label.font = size.font
            label.adjustsFontForContentSizeCategory = true
            label.textAlignment = .center
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.7
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
            labels.append(label)
        }
        heightAnchor.constraint(greaterThanOrEqualToConstant: size.height).isActive = true
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
        isAccessibilityElement = false
        ccRelayoutOnTextSizeChange()
        ccOnThemeChange { [weak self] in self?.applyTheme() }
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setTitle(_ title: String, at index: Int) {
        guard labels.indices.contains(index), labels[index].text != title else { return }
        titles[index] = title
        if window != nil {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = CCMotion.paced(0.18)
            labels[index].layer.add(fade, forKey: "ccsegmented.title")
        }
        labels[index].text = title
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: CGSize {
        let widest = labels.map { ceil($0.intrinsicContentSize.width) }.max() ?? 40
        let height = max(size.height, ceil(size.font.lineHeight) + 16)
        return CGSize(width: (widest + 24) * CGFloat(max(labels.count, 1)) + size.inset * 2, height: height)
    }

    private func segmentRect(_ index: Int) -> CGRect {
        let count = CGFloat(max(labels.count, 1))
        let width = (bounds.width - size.inset * 2) / count
        return CGRect(x: size.inset + width * CGFloat(index), y: size.inset, width: width, height: bounds.height - size.inset * 2)
    }

    private var chipRadius: CGFloat {
        radius == .md ? CCTheme.radius(.sm) : max(radius.resolved(for: bounds.height) - size.inset, 2)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let outer = radius.resolved(for: bounds.height)
        layer.cornerRadius = outer
        CCMaterial.refit(layer, radius: outer)
        for (index, label) in labels.enumerated() {
            label.frame = segmentRect(index).insetBy(dx: 4, dy: 0)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if selection.animation(forKey: "ccmotion.position") == nil {
            selection.frame = segmentRect(selectedIndex)
        }
        selection.cornerRadius = chipRadius
        CATransaction.commit()
        CCMaterial.refit(selection, radius: chipRadius)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let chip = segmentRect(selectedIndex)
        mark.frame = CGRect(x: (chip.width - 16) / 2, y: chip.height - 5, width: 16, height: 2)
        CATransaction.commit()
        rebuildAccessibility()
    }

    /// A 44 pt touch target, however short the well.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let dy = max(0, (44 - bounds.height) / 2)
        return bounds.insetBy(dx: 0, dy: -dy).contains(point)
    }

    // Keyboard (iPad, Studio 6a): focusable; ← / → choose the neighbouring segment.
    override var canBecomeFocused: Bool { isEnabled && !isHidden }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if let step = ccArrowStep(presses), isEnabled {
            let next = min(max(selectedIndex + step, 0), labels.count - 1)
            if next != selectedIndex { commit(next) }
            return
        }
        super.pressesBegan(presses, with: event)
    }

    /// Probe seam: the Differentiate Without Color mark shows.
    var probeShowsCheck: Bool { mark.opacity > 0.5 }

    private func applyTheme() {
        let colors = CCTheme.color
        CCMaterial.dress(layer, as: .recessed(tint: colors.elevated), radius: radius.resolved(for: bounds.height), traits: traitCollection)
        layer.borderWidth = 1
        layer.borderColor = cc(colors.border)
        CCMaterial.dress(selection, as: .raised(tint: colors.card), radius: chipRadius, traits: traitCollection)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mark.backgroundColor = cc(colors.foreground)
        mark.opacity = CCAccessibility.differentiateWithoutColor ? 1 : 0
        CATransaction.commit()
        for (index, label) in labels.enumerated() {
            label.textColor = index == selectedIndex ? colors.foreground : colors.mutedForeground
        }
    }

    private func refreshSelection(animated: Bool) {
        let target = segmentRect(selectedIndex)
        if animated, window != nil {
            CCMotion.spring(selection, keyPath: "position", to: NSValue(cgPoint: CGPoint(x: target.midX, y: target.midY)), .snappy)
            CCMotion.spring(selection, keyPath: "bounds", to: NSValue(cgRect: CGRect(origin: .zero, size: target.size)), .snappy)
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            selection.frame = target
            CATransaction.commit()
        }
        let colors = CCTheme.color
        for (index, label) in labels.enumerated() {
            let color = index == selectedIndex ? colors.foreground : colors.mutedForeground
            if animated {
                UIView.transition(with: label, duration: CCMotion.paced(0.16), options: .transitionCrossDissolve) { label.textColor = color }
            } else {
                label.textColor = color
            }
        }
        rebuildAccessibility()
    }

    // MARK: - Touch

    private func index(at point: CGPoint) -> Int? {
        labels.indices.first { segmentRect($0).insetBy(dx: 0, dy: -12).contains(point) }
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        isEnabled
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        // Slide to choose: the chip follows the finger across segments.
        let point = touch.location(in: self)
        if let index = index(at: point), index != selectedIndex, bounds.insetBy(dx: -20, dy: -30).contains(point) {
            commit(index)
        }
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        guard let touch else { return }
        let point = touch.location(in: self)
        if let index = index(at: point), index != selectedIndex {
            commit(index)
        }
    }

    private func commit(_ index: Int) {
        selectedIndex = index
        refreshSelection(animated: true)
        CCHaptics.selection()
        onChange?(index)
        sendActions(for: .valueChanged)
    }

    // MARK: - Accessibility

    private func rebuildAccessibility() {
        accessibilityItems = labels.indices.map { index in
            let element = CCAccessibilityAction(accessibilityContainer: self)
            element.onActivate = { [weak self] in
                guard let self, index != self.selectedIndex else { return }
                self.commit(index)
            }
            element.accessibilityLabel = titles[index]
            element.accessibilityTraits = index == selectedIndex ? [.button, .selected] : .button
            element.accessibilityFrameInContainerSpace = segmentRect(index)
            element.accessibilityHint = "\(index + 1) of \(labels.count)"
            return element
        }
        accessibilityElements = accessibilityItems
    }


    // MARK: - Probe seams

    var probeSelectionLayer: CALayer { selection }
    func probeSegmentRect(_ index: Int) -> CGRect { segmentRect(index) }
}

/// An accessibility element that runs a closure when VoiceOver activates it.
final class CCAccessibilityAction: UIAccessibilityElement {
    var onActivate: (() -> Void)?

    override func accessibilityActivate() -> Bool {
        onActivate?()
        return onActivate != nil
    }
}
