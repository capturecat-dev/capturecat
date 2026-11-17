import UIKit

/// CCKit icon rail — a switcher of icon + label keys (the Mac inspector's tab
/// rail at touch scale). Vertical: a column of keys (a sidebar). Horizontal:
/// a scrolling strip (a sheet header). The selected key sits on a raised
/// chip that GLIDES between keys on the house spring (`.smooth`) — one
/// travelling surface, never independent fills. An optional trailing key
/// (e.g. History) is a plain action, never selected.
///
/// Touch-first: every key is ≥ 48 × 52 pt. VoiceOver: each key is a button
/// labelled by its title, the selected one carries `.selected`.
final class CCIconRail: UIView {
    struct Item {
        var title: String
        var symbol: String
    }

    enum Axis { case vertical, horizontal }

    var onSelect: ((Int) -> Void)?
    var onTrailing: (() -> Void)?
    private(set) var selectedIndex: Int
    var axis: Axis { didSet { guard axis != oldValue else { return }; relayout() } }

    private let items: [Item]
    private let trailingItem: Item?
    private var keys: [CCIconRailKey] = []
    private var trailingKey: CCIconRailKey?
    private let scroll = UIScrollView()
    private let content = UIView()
    private let chip = CALayer()
    private var stack = UIStackView()

    static let keyWidth: CGFloat = 64
    static let keyHeight: CGFloat = 56

    init(items: [Item], selectedIndex: Int = 0, axis: Axis, trailing: Item? = nil) {
        self.items = items
        self.selectedIndex = selectedIndex
        self.axis = axis
        self.trailingItem = trailing
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.alwaysBounceHorizontal = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)
        chip.cornerCurve = .continuous
        content.layer.addSublayer(chip)
        for (index, item) in items.enumerated() {
            let key = CCIconRailKey(item: item)
            key.addAction(UIAction { [weak self] _ in self?.tapped(index) }, for: .touchUpInside)
            keys.append(key)
        }
        if let trailing {
            let key = CCIconRailKey(item: trailing)
            key.addAction(UIAction { [weak self] _ in self?.onTrailing?() }, for: .touchUpInside)
            trailingKey = key
        }
        isAccessibilityElement = false
        accessibilityElements = keys + [trailingKey].compactMap { $0 }
        ccOnThemeChange { [weak self] in self?.applyTheme() }
        applyTheme()
        relayout()
        refreshKeys()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var axisConstraints: [NSLayoutConstraint] = []

    private func relayout() {
        NSLayoutConstraint.deactivate(axisConstraints)
        stack.removeFromSuperview()
        stack = UIStackView(arrangedSubviews: keys + [trailingKey].compactMap { $0 })
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.spacing = 4
        stack.axis = axis == .vertical ? .vertical : .horizontal
        content.addSubview(stack)
        let pad: CGFloat = 6
        var c: [NSLayoutConstraint] = [
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: pad),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -pad),
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
        ]
        if axis == .vertical {
            c.append(content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor))
            scroll.alwaysBounceVertical = false
        } else {
            c.append(content.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor))
        }
        for key in keys + [trailingKey].compactMap({ $0 }) {
            key.compact = axis == .horizontal
        }
        axisConstraints = c
        NSLayoutConstraint.activate(c)
        setNeedsLayout()
    }

    override var intrinsicContentSize: CGSize {
        let count = CGFloat(keys.count + (trailingKey == nil ? 0 : 1))
        return axis == .vertical
            ? CGSize(width: Self.keyWidth + 12, height: count * (Self.keyHeight + 4) + 8)
            : CGSize(width: count * (Self.keyWidth + 4) + 8, height: Self.keyHeight + 12)
    }

    func setSelectedIndex(_ index: Int, animated: Bool) {
        guard keys.indices.contains(index), index != selectedIndex else { return }
        selectedIndex = index
        refreshKeys()
        placeChip(animated: animated)
        scrollToSelected(animated: animated)
    }

    private func tapped(_ index: Int) {
        guard index != selectedIndex else { return }
        CCHaptics.selection()
        setSelectedIndex(index, animated: true)
        onSelect?(index)
    }

    private func refreshKeys() {
        for (i, key) in keys.enumerated() { key.isSelected = i == selectedIndex }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        placeChip(animated: false)
    }

    /// The chip's frame for the selected key, in `content` coordinates.
    var chipTargetFrame: CGRect {
        guard keys.indices.contains(selectedIndex) else { return .zero }
        let key = keys[selectedIndex]
        return key.convert(key.bounds, to: content)
    }

    private func placeChip(animated: Bool) {
        let target = chipTargetFrame
        guard target.width > 1 else { return }
        let r = CCTheme.radius(.md)
        if animated, window != nil {
            CCMotion.spring(chip, keyPath: "position", to: NSValue(cgPoint: CGPoint(x: target.midX, y: target.midY)), .smooth)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            chip.bounds = CGRect(origin: .zero, size: target.size)
            CATransaction.commit()
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            chip.frame = target
            CATransaction.commit()
        }
        chip.cornerRadius = r
        CCMaterial.refit(chip, radius: r)
    }

    private func scrollToSelected(animated: Bool) {
        guard axis == .horizontal, keys.indices.contains(selectedIndex) else { return }
        let frame = keys[selectedIndex].convert(keys[selectedIndex].bounds, to: scroll)
        scroll.scrollRectToVisible(frame.insetBy(dx: -24, dy: 0), animated: animated)
    }

    private func applyTheme() {
        CCMaterial.dress(chip, as: .raised(tint: CCTheme.color.elevated), radius: CCTheme.radius(.md), traits: traitCollection)
    }

    // MARK: Probe

    var probeChipLayer: CALayer { chip }
    var probeKeys: [UIControl] { keys }
    var probeTrailingKey: UIControl? { trailingKey }
    func probeTap(_ index: Int) { tapped(index) }
}

/// One rail key: icon over a small label (side by side never — the label is
/// what makes nine icons legible). Tints in place on press.
final class CCIconRailKey: UIControl {
    // Keyboard (iPad, Studio 6a): Tab / arrows focus it; Space or Return
    // activates it — the same action a tap sends.
    override var canBecomeFocused: Bool { isEnabled && !isHidden && isUserInteractionEnabled }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if ccIsActivation(presses), isEnabled { sendActions(for: .touchUpInside); return }
        super.pressesEnded(presses, with: event)
    }

    private let iconView: CCIconView
    private let label: UILabel
    private let item: CCIconRail.Item
    var compact = false { didSet { setNeedsLayout() } }
    /// A key whose label may be long (a drill-down bar's sub-options): it
    /// grows past `keyWidth` to fit its title instead of truncating it —
    /// at the large text sizes too.
    var growsToFit = false {
        didSet {
            guard growsToFit != oldValue else { return }
            fixedWidth.isActive = !growsToFit
            minWidth.isActive = growsToFit
            invalidateIntrinsicContentSize()
        }
    }
    private var fixedWidth: NSLayoutConstraint!
    private var minWidth: NSLayoutConstraint!

    override var intrinsicContentSize: CGSize {
        guard growsToFit else { return super.intrinsicContentSize }
        let text = (label.text ?? "") as NSString
        let w = ceil(text.size(withAttributes: [.font: label.font as Any]).width) + 12
        return CGSize(width: max(CCIconRail.keyWidth, w), height: UIView.noIntrinsicMetric)
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if growsToFit { invalidateIntrinsicContentSize() }
    }

    init(item: CCIconRail.Item) {
        self.item = item
        iconView = CCIconView(item.symbol, pointSize: 19, weight: .medium, tint: CCTheme.color.mutedForeground)
        label = ccLabel(item.title, font: CCFont.scaled(11, .medium, .caption2, max: 15),
                        color: CCTheme.color.mutedForeground, alignment: .center)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.65
        ccRelayoutOnTextSizeChange()
        fixedWidth = widthAnchor.constraint(equalToConstant: CCIconRail.keyWidth)
        minWidth = widthAnchor.constraint(greaterThanOrEqualToConstant: CCIconRail.keyWidth)
        let column = UIStackView(arrangedSubviews: [iconView, label])
        column.axis = .vertical
        column.alignment = .center
        column.spacing = 3
        column.isUserInteractionEnabled = false
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            fixedWidth,
            heightAnchor.constraint(greaterThanOrEqualToConstant: CCIconRail.keyHeight),
            column.centerXAnchor.constraint(equalTo: centerXAnchor),
            column.centerYAnchor.constraint(equalTo: centerYAnchor),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 2),
            column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            column.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 4),
            column.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4),
        ])
        isAccessibilityElement = true
        accessibilityLabel = item.title
        accessibilityTraits = .button
        ccOnThemeChange { [weak self] in self?.restyle() }
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isSelected: Bool {
        didSet {
            guard isSelected != oldValue else { return }
            restyle()
            accessibilityTraits = isSelected ? [.button, .selected] : .button
        }
    }

    override var isHighlighted: Bool {
        didSet { CCMotion.quick { self.alpha = self.isHighlighted ? 0.6 : 1 } }
    }

    private func restyle() {
        let name = isSelected && CCIcon.has(item.symbol + ".fill") ? item.symbol + ".fill" : item.symbol
        iconView.image = CCIcon.image(name, pointSize: 19, weight: .medium)
        let color = isSelected ? CCTheme.color.foreground : CCTheme.color.mutedForeground
        iconView.tintColor = color
        label.textColor = color
    }
}
