import UIKit

/// One choice chip (the Mac's InspectorChipsControl chip): a full-radius pill
/// sized to its label (+ optional kit icon). Unselected chips are flat WELLS;
/// the selected one FLOATS (raised material, brighter fill) — no ring. Press
/// tints in place. 36 pt tall, a 44 pt touch target.
///
///     let chip = CCChip(title: "Smooth")
///     chip.isSelected = true
///     chip.onTap = { … }
final class CCChip: UIControl {
    static let height: CGFloat = 36
    static let defaultPadding: CGFloat = 16
    static let minPadding: CGFloat = 10

    var onTap: (() -> Void)?

    var title: String {
        get { label.text ?? "" }
        set { label.text = newValue; accessibilityLabel = newValue; invalidateIntrinsicContentSize() }
    }

    /// Per-side padding; a CCChipGroup compresses it (down to `minPadding`)
    /// before it wraps, so labels stay whole.
    var horizontalPadding: CGFloat = CCChip.defaultPadding {
        didSet { if horizontalPadding != oldValue { invalidateIntrinsicContentSize(); setNeedsLayout() } }
    }

    override var isSelected: Bool {
        didSet {
            guard isSelected != oldValue else { return }
            applyTheme(animated: true)
            refreshAccessibility()
        }
    }

    override var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            CCMotion.fadeAlpha(self, to: isEnabled ? 1 : CCTheme.disabledAlpha, duration: 0.16)
            refreshAccessibility()
        }
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            CCMaterial.press(layer, down: isHighlighted, traits: traitCollection)
        }
    }

    private let label = UILabel()
    private let icon: CCIconView?

    init(title: String, symbol: String? = nil) {
        icon = symbol.map { CCIconView($0, pointSize: 14, weight: .medium) }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerCurve = .continuous
        label.text = title
        label.font = CCFont.scaled(15, .medium, .subheadline, max: 21)
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .center
        label.isUserInteractionEnabled = false
        addSubview(label)
        if let icon {
            icon.translatesAutoresizingMaskIntoConstraints = true
            icon.isUserInteractionEnabled = false
            addSubview(icon)
        }
        isAccessibilityElement = true
        accessibilityLabel = title
        addAction(UIAction { [weak self] _ in
            guard let self, self.isEnabled else { return }
            self.onTap?()
        }, for: .touchUpInside)
        ccOnThemeChange { [weak self] in self?.applyTheme(animated: false) }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: CCChip, _: UITraitCollection) in
            self.invalidateIntrinsicContentSize()
        }
        applyTheme(animated: false)
        refreshAccessibility()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The label's (+ icon's) own width — what the chip needs beyond padding.
    var contentWidth: CGFloat {
        let text = ceil((title as NSString).size(withAttributes: [.font: label.font as Any]).width)
        return text + (icon == nil ? 0 : CCIcon.side(for: 14) + CCSpace.xs + 2)
    }

    var chipHeight: CGFloat { max(Self.height, ceil(label.font.lineHeight) + 16) }

    override var intrinsicContentSize: CGSize {
        CGSize(width: contentWidth + horizontalPadding * 2, height: chipHeight)
    }

    /// 44 pt touch target.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let dx = max(0, (44 - bounds.width) / 2), dy = max(0, (44 - bounds.height) / 2)
        return bounds.insetBy(dx: -dx, dy: -dy).contains(point)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let r = CCRadius.full.resolved(for: bounds.height)
        layer.cornerRadius = r
        CCMaterial.refit(layer, radius: r)
        let labelHeight = ceil(label.font.lineHeight)
        var x = (bounds.width - contentWidth) / 2
        if let icon {
            let side = CCIcon.side(for: 14)
            icon.frame = CGRect(x: x, y: (bounds.height - side) / 2, width: side, height: side)
            x += side + CCSpace.xs + 2
        }
        label.frame = CGRect(x: x, y: (bounds.height - labelHeight) / 2, width: max(0, bounds.width - x - (bounds.width - contentWidth) / 2), height: labelHeight)
    }

    private func applyTheme(animated: Bool) {
        let colors = CCTheme.color
        label.textColor = colors.foreground
        icon?.tintColor = isSelected ? colors.foreground : colors.mutedForeground
        // 2026 look: unselected chips are flat wells; the selected one floats,
        // filled with the `active` wash (CCMaterial composites it over the
        // elevated surface) — exactly the Mac chip.
        let tint = isSelected ? colors.active : colors.elevated
        let r = CCRadius.full.resolved(for: max(bounds.height, Self.height))
        CCMaterial.dress(layer, as: isSelected ? .raised(tint: tint) : .recessed(tint: tint), radius: r, traits: traitCollection)
        layer.borderWidth = isSelected ? 0 : 1
        layer.borderColor = cc(colors.border)
        if animated, window != nil, let base = layer.sublayers?.first(where: { $0.name == "ccmat.base" }) {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = CCMotion.paced(0.18)
            base.add(fade, forKey: "ccchip.select")
            CCMotion.fade(layer, keyPath: "shadowOpacity", to: layer.shadowOpacity, duration: 0.18, from: isSelected ? Float(0) : nil)
        }
    }

    fileprivate var groupPosition: (index: Int, count: Int)? { didSet { refreshAccessibility() } }

    private func refreshAccessibility() {
        var traits: UIAccessibilityTraits = .button
        if isSelected { traits.insert(.selected) }
        if !isEnabled { traits.insert(.notEnabled) }
        accessibilityTraits = traits
        accessibilityHint = groupPosition.map { "\($0.index + 1) of \($0.count)" }
    }
}

/// A group of choice chips (the Mac's InspectorChipsControl) laid out as a
/// FLOW: when the row would overflow, every chip's padding compresses (down
/// to `CCChip.minPadding`) before the group wraps to another line — a chip
/// cut mid-label reads as broken. Single choice (exactly one, or none with
/// `allowsEmpty`) or multiple choice.
///
///     let pace = CCChipGroup(items: ["Snappy", "Smooth", "Slow glide"], selected: [1])
///     pace.onChange = { selected in … }        // Set<Int>
///     let lanes = CCChipGroup(items: [.init("Cursor", symbol: "cursor"), …], mode: .multiple)
///
/// When content changes the group's height (items added, a title grows),
/// the height lands on the house growth bounce with ONLY the bottom edge
/// moving, and chips glide to their new places.
final class CCChipGroup: UIView {
    enum Mode {
        case single
        case multiple
    }

    struct Item {
        var title: String
        var symbol: String?
        var isEnabled: Bool

        init(_ title: String, symbol: String? = nil, isEnabled: Bool = true) {
            self.title = title
            self.symbol = symbol
            self.isEnabled = isEnabled
        }
    }

    let mode: Mode
    /// Single mode: tapping the selected chip clears the selection.
    var allowsEmpty = false
    var onChange: ((Set<Int>) -> Void)?

    var items: [Item] { didSet { rebuild(animated: true) } }

    private(set) var selection: Set<Int>

    /// Single mode convenience.
    var selectedIndex: Int? { selection.min() }

    static let hGap: CGFloat = 8
    static let vGap: CGFloat = 8

    private var chips: [CCChip] = []
    private var heightConstraint: NSLayoutConstraint!
    private var animateNextReflow = false

    init(items: [Item], mode: Mode = .single, selected: Set<Int> = [0]) {
        self.items = items
        self.mode = mode
        selection = mode == .single ? Set(selected.prefix(1)) : selected
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightConstraint = heightAnchor.constraint(equalToConstant: CCChip.height)
        heightConstraint.isActive = true
        accessibilityContainerType = .semanticGroup
        rebuild(animated: false)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: CCChipGroup, _: UITraitCollection) in
            self.setNeedsLayout()
        }
    }

    convenience init(items: [String], mode: Mode = .single, selected: Set<Int> = [0]) {
        self.init(items: items.map { Item($0) }, mode: mode, selected: selected)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Push a model selection (no onChange echo).
    func setSelection(_ indices: Set<Int>) {
        selection = mode == .single ? Set(indices.prefix(1)) : indices
        restyle()
    }

    private func rebuild(animated: Bool) {
        let old = chips
        let oldFrames = Dictionary(old.map { ($0.title, $0.frame) }, uniquingKeysWith: { first, _ in first })
        old.forEach { $0.removeFromSuperview() }
        chips = items.enumerated().map { index, item in
            let chip = CCChip(title: item.title, symbol: item.symbol)
            chip.isEnabled = item.isEnabled
            chip.translatesAutoresizingMaskIntoConstraints = true
            chip.onTap = { [weak self] in self?.tap(index) }
            if let frame = oldFrames[item.title] { chip.frame = frame }
            return chip
        }
        chips.forEach(addSubview)
        selection = selection.filter { $0 < items.count }
        if mode == .single, selection.isEmpty, !allowsEmpty, !items.isEmpty { selection = [0] }
        restyle()
        animateNextReflow = animated && window != nil && !old.isEmpty
        setNeedsLayout()
        if animateNextReflow {
            let fresh = chips.filter { oldFrames[$0.title] == nil }
            fresh.forEach { $0.alpha = 0 }
            DispatchQueue.main.async {
                for chip in fresh {
                    CCMotion.fadeAlpha(chip, to: chip.isEnabled ? 1 : CCTheme.disabledAlpha, duration: 0.2, from: 0)
                    CCMotion.pop(chip, from: 0.9)
                }
            }
        }
    }

    private func tap(_ index: Int) {
        var next = selection
        switch mode {
        case .single:
            if selection.contains(index) {
                guard allowsEmpty else { return }
                next = []
            } else {
                next = [index]
            }
        case .multiple:
            if next.contains(index) { next.remove(index) } else { next.insert(index) }
        }
        selection = next
        restyle()
        CCHaptics.selection()
        onChange?(next)
    }

    private func restyle() {
        for (index, chip) in chips.enumerated() {
            chip.isSelected = selection.contains(index)
            chip.groupPosition = (index, chips.count)
        }
    }

    /// The flow layout for `width`: chip frames and the total height.
    private func flow(width: CGFloat) -> (frames: [CGRect], height: CGFloat) {
        guard !chips.isEmpty else { return ([], 0) }
        let contentTotal = chips.reduce(0) { $0 + $1.contentWidth }
        let gaps = Self.hGap * CGFloat(max(0, chips.count - 1))
        let perSide = floor((width - gaps - contentTotal) / CGFloat(chips.count * 2))
        let pad = min(CCChip.defaultPadding, max(CCChip.minPadding, perSide))
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for chip in chips {
            chip.horizontalPadding = pad
            let size = CGSize(width: min(ceil(chip.contentWidth + pad * 2), width), height: chip.chipHeight)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + Self.vGap
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + Self.hGap
            lineHeight = max(lineHeight, size.height)
        }
        return (frames, y + lineHeight)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0 else { return }
        let (frames, height) = flow(width: bounds.width)
        let animate = animateNextReflow
        animateNextReflow = false
        for (chip, frame) in zip(chips, frames) {
            if animate, chip.frame != .zero, chip.frame != frame, chip.alpha > 0 {
                CCMotion.glide(chip, to: frame)
            } else if chip.frame != frame {
                chip.frame = frame
            }
        }
        guard abs(heightConstraint.constant - height) > 0.5 else { return }
        if animate, window != nil {
            // Growth: the bottom edge travels on the bounce; the top stays.
            // (The driver re-lays-out the window's root view each tick.)
            CCMotion.animate(heightConstraint, to: height, in: ccLayoutRoot, duration: 0.42, curve: .bounce)
        } else if !CCMotion.isAnimating(heightConstraint) {
            heightConstraint.constant = height
        }
    }

    // MARK: - Probe seams

    var probeChips: [CCChip] { chips }
    var probeHeightConstraint: NSLayoutConstraint { heightConstraint }
    func probeTap(_ index: Int) { tap(index) }
}

extension UIView {
    /// The outermost view below the window (a root view controller's view):
    /// the right `in:` for `CCMotion.animate(constraint…)`, whose driver
    /// re-lays-out that view every tick. (A UIWindow is not a valid root —
    /// its own `window` is nil, so the driver would snap.)
    var ccLayoutRoot: UIView {
        var view: UIView = self
        while let parent = view.superview, !(parent is UIWindow) { view = parent }
        return view
    }
}
