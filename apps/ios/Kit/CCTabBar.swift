import UIKit

/// A tab-bar / sidebar item.
struct CCNavItem {
    var title: String
    var symbol: String
}

/// CCKit floating tab bar — drawn by us instead of UITabBar (system glass on
/// iOS 26+). A FLOATING capsule above the home indicator; the selected item
/// sits on a raised chip that springs between items (`.snappy`). Compact
/// height (landscape phone) lays icon and title side by side.
final class CCTabBar: UIView {
    var onSelect: ((Int) -> Void)?
    /// Tapping the selected item again (pop to root / scroll to top).
    var onReselect: ((Int) -> Void)?
    private(set) var selectedIndex: Int

    private let items: [CCNavItem]
    private var buttons: [CCTabBarItemView] = []
    private let chip = CALayer()
    private let inset: CGFloat = 5

    init(items: [CCNavItem], selectedIndex: Int = 0) {
        self.items = items
        self.selectedIndex = selectedIndex
        super.init(frame: .zero)
        // The bar floats over scrolling content (the a11y audit takes the
        // content under it as covered).
        ccFloatsOverContent = true
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerCurve = .continuous
        chip.cornerCurve = .continuous
        layer.addSublayer(chip)
        for (index, item) in items.enumerated() {
            let view = CCTabBarItemView(item: item)
            view.addAction(UIAction { [weak self] _ in self?.tapped(index) }, for: .touchUpInside)
            addSubview(view)
            buttons.append(view)
        }
        accessibilityTraits = .tabBar
        isAccessibilityElement = false
        accessibilityElements = buttons
        ccOnThemeChange { [weak self] in self?.applyTheme() }
        registerForTraitChanges([UITraitVerticalSizeClass.self]) { (self: CCTabBar, _: UITraitCollection) in
            self.invalidateIntrinsicContentSize()
            self.setNeedsLayout()
        }
        applyTheme()
        refreshItems(animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var isCompactHeight: Bool { traitCollection.verticalSizeClass == .compact }

    var barHeight: CGFloat { isCompactHeight ? 50 : 62 }

    /// A vertical bar: items top to bottom, icons only (the title is the
    /// accessibility label) — where the system puts bars on a vertical
    /// edge (`FoldingDisplay.verticalBarEdge`, the iPhone Duo folded).
    var isVertical = false {
        didSet {
            guard isVertical != oldValue else { return }
            for button in buttons { button.iconOnly = isVertical }
            invalidateIntrinsicContentSize()
            setNeedsLayout()
            layoutIfNeeded()
            moveChip(animated: false)
        }
    }
    /// A vertical bar's item height.
    static let verticalItemHeight: CGFloat = 52
    /// A vertical bar's natural length.
    var verticalLength: CGFloat { CGFloat(items.count) * Self.verticalItemHeight + inset * 2 }

    override var intrinsicContentSize: CGSize {
        if isVertical { return CGSize(width: 48, height: verticalLength) }
        return CGSize(width: CGFloat(items.count) * (isCompactHeight ? 132 : 104) + inset * 2, height: barHeight)
    }

    func setSelectedIndex(_ index: Int, animated: Bool) {
        guard items.indices.contains(index), index != selectedIndex else { return }
        selectedIndex = index
        moveChip(animated: animated)
        refreshItems(animated: animated)
    }

    private func tapped(_ index: Int) {
        CCHaptics.selection()
        if index == selectedIndex {
            onReselect?(index)
            return
        }
        setSelectedIndex(index, animated: true)
        onSelect?(index)
    }

    private func itemRect(_ index: Int) -> CGRect {
        if isVertical {
            let height = (bounds.height - inset * 2) / CGFloat(max(items.count, 1))
            return CGRect(x: inset, y: inset + height * CGFloat(index), width: bounds.width - inset * 2, height: height)
        }
        let width = (bounds.width - inset * 2) / CGFloat(max(items.count, 1))
        return CGRect(x: inset + width * CGFloat(index), y: inset, width: width, height: bounds.height - inset * 2)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let thickness = isVertical ? bounds.width : bounds.height
        let outer = CCRadius.full.resolved(for: thickness)
        layer.cornerRadius = outer
        CCMaterial.refit(layer, radius: outer)
        for (index, button) in buttons.enumerated() {
            button.frame = itemRect(index)
            button.horizontal = isCompactHeight && !isVertical
        }
        let chipRadius = CCRadius.full.resolved(for: thickness - inset * 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if chip.animation(forKey: "ccmotion.position") == nil {
            chip.frame = itemRect(selectedIndex)
        }
        chip.cornerRadius = chipRadius
        CATransaction.commit()
        CCMaterial.refit(chip, radius: chipRadius)
    }

    private func moveChip(animated: Bool) {
        let target = itemRect(selectedIndex)
        if animated, window != nil {
            CCMotion.spring(chip, keyPath: "position", to: NSValue(cgPoint: CGPoint(x: target.midX, y: target.midY)), .snappy)
            CCMotion.spring(chip, keyPath: "bounds", to: NSValue(cgRect: CGRect(origin: .zero, size: target.size)), .snappy)
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            chip.frame = target
            CATransaction.commit()
        }
    }

    private func refreshItems(animated: Bool) {
        for (index, button) in buttons.enumerated() {
            button.setSelected(index == selectedIndex, animated: animated)
        }
    }

    private func applyTheme() {
        let colors = CCTheme.color
        CCMaterial.dress(layer, as: .raised(tint: colors.popover), radius: CCRadius.full.resolved(for: min(bounds.width, bounds.height)), traits: traitCollection)
        // A stronger float than the height formula — the bar hovers over content.
        layer.setValue(true, forKey: "ccmatShadow")
        CCMaterial.dress(chip, as: .raisedMatte(tint: colors.elevated), radius: chip.cornerRadius, traits: traitCollection)
        setNeedsLayout()
    }

    // Probe seams.
    var probeChipLayer: CALayer { chip }
    func probeItemRect(_ index: Int) -> CGRect { itemRect(index) }
}

final class CCTabBarItemView: UIControl {
    // Keyboard (iPad, Studio 6a): Tab / arrows focus it; Space or Return
    // activates it — the same action a tap sends.
    override var canBecomeFocused: Bool { isEnabled && !isHidden && isUserInteractionEnabled }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if ccIsActivation(presses), isEnabled { sendActions(for: .touchUpInside); return }
        super.pressesEnded(presses, with: event)
    }

    private let icon: CCIconView
    private let label: UILabel
    private var isOn = false
    var horizontal = false { didSet { if horizontal != oldValue { setNeedsLayout() } } }
    /// Icon only (a vertical bar); the title stays the accessibility label.
    var iconOnly = false { didSet { if iconOnly != oldValue { label.isHidden = iconOnly; setNeedsLayout() } } }

    init(item: CCNavItem) {
        icon = CCIconView(item.symbol, pointSize: 18, weight: .medium, tint: CCTheme.color.mutedForeground)
        icon.translatesAutoresizingMaskIntoConstraints = true
        label = UILabel()
        super.init(frame: .zero)
        label.text = item.title
        label.font = CCFont.scaled(11, .semibold, .caption2, max: 13)
        ccRelayoutOnTextSizeChange()
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .center
        label.textColor = CCTheme.color.mutedForeground
        for view in [icon, label] as [UIView] {
            view.isUserInteractionEnabled = false
            addSubview(view)
        }
        isAccessibilityElement = true
        accessibilityLabel = item.title
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = CCIcon.side(for: 18)
        let labelSize = label.sizeThatFits(CGSize(width: bounds.width - 8, height: 40))
        if iconOnly {
            icon.frame = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        } else if horizontal {
            let total = side + 6 + labelSize.width
            let x = (bounds.width - total) / 2
            icon.frame = CGRect(x: x, y: (bounds.height - side) / 2, width: side, height: side)
            label.frame = CGRect(x: x + side + 6, y: (bounds.height - labelSize.height) / 2, width: labelSize.width, height: labelSize.height)
        } else {
            let total = side + 2 + labelSize.height
            let y = (bounds.height - total) / 2
            icon.frame = CGRect(x: (bounds.width - side) / 2, y: y, width: side, height: side)
            label.frame = CGRect(x: 4, y: y + side + 2, width: bounds.width - 8, height: labelSize.height)
        }
    }

    func setSelected(_ selected: Bool, animated: Bool) {
        isOn = selected
        accessibilityTraits = selected ? [.button, .selected] : .button
        let color = selected ? CCTheme.color.foreground : CCTheme.color.mutedForeground
        let apply = {
            self.icon.tintColor = color
            self.label.textColor = color
        }
        if animated {
            UIView.transition(with: self, duration: CCMotion.paced(0.18), options: [.transitionCrossDissolve, .allowUserInteraction], animations: apply)
        } else {
            apply()
        }
        icon.weight = selected ? .semibold : .medium
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            // Press tints in place — the glyph dims, nothing moves.
            CCMotion.fadeAlpha(self, to: isHighlighted ? 0.55 : 1, duration: isHighlighted ? 0.05 : 0.2)
        }
    }
}

/// CCKit sidebar — the regular-width counterpart of the tab bar: rows of
/// icon + title with a raised selection chip that GLIDES between rows.
final class CCSidebar: UIView {
    var onSelect: ((Int) -> Void)?
    var onReselect: ((Int) -> Void)?
    private(set) var selectedIndex: Int
    private let items: [CCNavItem]
    private var rows: [CCSidebarRow] = []
    private let stack = UIStackView()
    private let chip = UIView()
    private var chipTop: NSLayoutConstraint?
    private var chipHeight: NSLayoutConstraint?
    private let header: UIView?
    let footer = UIStackView()
    private var stackLeading: NSLayoutConstraint!
    private var stackTrailing: NSLayoutConstraint!

    /// Icon rail (narrow iPads): icons over small titles, no header text.
    var isRail = false {
        didSet {
            guard isRail != oldValue else { return }
            rows.forEach { $0.isRail = isRail }
            header?.alpha = isRail ? 0 : 1
            footer.isHidden = isRail
            stackLeading.constant = isRail ? CCSpace.sm : CCSpace.md
            stackTrailing.constant = isRail ? -CCSpace.sm : -CCSpace.md
            setNeedsLayout()
            layoutIfNeeded()
            chip.frame = chipFrame()
        }
    }

    init(items: [CCNavItem], selectedIndex: Int = 0, header: UIView? = nil) {
        self.items = items
        self.selectedIndex = selectedIndex
        self.header = header
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = CCTheme.color.background
        chip.layer.cornerCurve = .continuous
        chip.isUserInteractionEnabled = false
        stack.axis = .vertical
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (index, item) in items.enumerated() {
            let row = CCSidebarRow(item: item)
            row.addAction(UIAction { [weak self] _ in self?.tapped(index) }, for: .touchUpInside)
            stack.addArrangedSubview(row)
            rows.append(row)
        }
        addSubview(chip)
        addSubview(stack)
        footer.axis = .vertical
        footer.spacing = CCSpace.sm
        footer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(footer)
        stackLeading = stack.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: CCSpace.md)
        stackTrailing = stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CCSpace.md)
        var constraints = [
            stackLeading!,
            stackTrailing!,
            footer.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: CCSpace.lg),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CCSpace.lg),
            footer.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -CCSpace.lg),
        ]
        if let header {
            header.translatesAutoresizingMaskIntoConstraints = false
            addSubview(header)
            constraints += [
                header.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: CCSpace.lg),
                header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CCSpace.lg),
                header.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: CCSpace.md),
                stack.topAnchor.constraint(equalTo: header.bottomAnchor, constant: CCSpace.xl),
            ]
        } else {
            constraints.append(stack.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: CCSpace.lg))
        }
        NSLayoutConstraint.activate(constraints)
        accessibilityElements = ([header].compactMap { $0 } as [Any]) + rows + [footer]
        ccOnThemeChange { [weak self] in self?.applyTheme() }
        applyTheme()
        refreshRows(animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setSelectedIndex(_ index: Int, animated: Bool) {
        guard items.indices.contains(index), index != selectedIndex else { return }
        selectedIndex = index
        refreshRows(animated: animated)
        moveChip(animated: animated)
    }

    private func tapped(_ index: Int) {
        CCHaptics.selection()
        if index == selectedIndex { onReselect?(index); return }
        setSelectedIndex(index, animated: true)
        onSelect?(index)
    }

    private func chipFrame() -> CGRect {
        guard rows.indices.contains(selectedIndex) else { return .zero }
        return rows[selectedIndex].convert(rows[selectedIndex].bounds, to: self)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Rows live in a stack that lays out AFTER this view — settle it first
        // or the chip lands on stale (zero) row frames.
        stack.layoutIfNeeded()
        if chip.layer.animationKeys()?.isEmpty ?? true {
            chip.frame = chipFrame()
        }
        chip.layer.cornerRadius = CCTheme.radius(.md)
        CCMaterial.refit(chip.layer, radius: CCTheme.radius(.md))
    }

    private func moveChip(animated: Bool) {
        layoutIfNeeded()
        let target = chipFrame()
        if animated, window != nil {
            CCMotion.glide(chip, to: target, .snappy)
        } else {
            chip.frame = target
        }
    }

    private func refreshRows(animated: Bool) {
        for (index, row) in rows.enumerated() { row.setSelected(index == selectedIndex, animated: animated) }
    }

    private func applyTheme() {
        CCMaterial.dress(chip.layer, as: .raised(tint: CCTheme.color.card), radius: CCTheme.radius(.md), traits: traitCollection)
    }

    var probeChip: UIView { chip }
}

final class CCSidebarRow: UIControl {
    // Keyboard (iPad, Studio 6a): Tab / arrows focus it; Space or Return
    // activates it — the same action a tap sends.
    override var canBecomeFocused: Bool { isEnabled && !isHidden && isUserInteractionEnabled }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if ccIsActivation(presses), isEnabled { sendActions(for: .touchUpInside); return }
        super.pressesEnded(presses, with: event)
    }

    private let icon: CCIconView
    private let label: UILabel
    private let wash = UIView()
    private let row = UIStackView()
    private var isOn = false

    var isRail = false {
        didSet {
            row.axis = isRail ? .vertical : .horizontal
            row.spacing = isRail ? 3 : CCSpace.md
            row.alignment = .center
            railCenter.isActive = isRail
            rowLeading.isActive = !isRail
            label.textAlignment = isRail ? .center : .natural
            applyFont()
        }
    }
    private var railCenter: NSLayoutConstraint!
    private var rowLeading: NSLayoutConstraint!

    init(item: CCNavItem) {
        icon = CCIconView(item.symbol, pointSize: 17, weight: .medium, tint: CCTheme.color.mutedForeground)
        label = ccLabel(item.title, font: CCFont.bodyMedium, color: CCTheme.color.mutedForeground)
        // The sidebar is a fixed column: big type shrinks to fit (≥ 55%).
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.55
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wash.alpha = 0
        wash.backgroundColor = CCTheme.color.hover
        wash.layer.cornerCurve = .continuous
        wash.isUserInteractionEnabled = false
        wash.translatesAutoresizingMaskIntoConstraints = false
        addSubview(wash)
        row.addArrangedSubview(icon)
        row.addArrangedSubview(label)
        row.spacing = CCSpace.md
        row.alignment = .center
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        rowLeading = row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CCSpace.md)
        railCenter = row.centerXAnchor.constraint(equalTo: centerXAnchor)
        NSLayoutConstraint.activate([
            wash.leadingAnchor.constraint(equalTo: leadingAnchor), wash.trailingAnchor.constraint(equalTo: trailingAnchor),
            wash.topAnchor.constraint(equalTo: topAnchor), wash.bottomAnchor.constraint(equalTo: bottomAnchor),
            rowLeading,
            row.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 2),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -CCSpace.xs),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 46),
        ])
        isAccessibilityElement = true
        accessibilityLabel = item.title
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        wash.layer.cornerRadius = CCTheme.radius(.md)
    }

    func setSelected(_ selected: Bool, animated: Bool) {
        accessibilityTraits = selected ? [.button, .selected] : .button
        let color = selected ? CCTheme.color.foreground : CCTheme.color.mutedForeground
        let apply = {
            self.icon.tintColor = color
            self.label.textColor = color
        }
        if animated {
            UIView.transition(with: self, duration: CCMotion.paced(0.18), options: [.transitionCrossDissolve, .allowUserInteraction], animations: apply)
        } else {
            apply()
        }
        isOn = selected
        applyFont()
    }

    private func applyFont() {
        if isRail {
            label.font = CCFont.scaled(11, .semibold, .caption2, max: 14)
        } else {
            label.font = isOn ? CCFont.scaled(16, .semibold, .body, max: 28) : CCFont.bodyMedium
        }
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            CCMotion.fadeAlpha(wash, to: isHighlighted ? 1 : 0, duration: isHighlighted ? 0.06 : 0.2)
        }
    }
}
