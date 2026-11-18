import UIKit

// CCGlass — the kit's Liquid Glass (iOS 26), for FLOATING CHROME only: bars,
// keys and sheets that hover over content. Content itself (the stage, the
// timeline's lanes, the rows inside a panel) stays flat.
//
//  • `CCGlassView` — a `UIVisualEffectView` running `UIGlassEffect`, shaped
//    by the kit's radii (capsule, a CCRadius, top-only for a docked sheet,
//    leading-only for a side sheet) and tinted from the theme tokens (the
//    primary key's blue). Put the surface's content in `contentView`, or
//    wrap one control with `CCGlassView.wrapping(_:)`: a control INSIDE the
//    glass keeps its own (≥ 44 pt) hit target and drives the interactive
//    glass, since its touches reach the glass's own recognizers.
//  • `CCGlassGroup` — a `UIGlassContainerEffect` view: neighbouring glass
//    shapes in its `contentView` merge and morph into one another.
//
// Accessibility: Reduce Transparency swaps the glass for the kit's OPAQUE
// raised `CCMaterial` surface (same shape, the tint or the elevated token);
// Increase Contrast gives the glass a clear 1 pt border. Before iOS 26 the
// material fallback is all there is. Both re-apply live (`ccOnThemeChange`).
final class CCGlassView: UIVisualEffectView {
    enum Shape: Equatable {
        /// Half the height (keys, chips, floating bars).
        case capsule
        /// Every corner at this radius token.
        case rounded(CCRadius)
        /// Only the top corners (a sheet docked on what is below it).
        case top(CCRadius)
        /// Only the leading corners (a side sheet out from under a rail).
        case leading(CCRadius)
    }

    var shape: Shape { didSet { if shape != oldValue { setNeedsLayout(); applyLook() } } }
    /// The glass's tint (nil = clear regular glass). The fallback material
    /// uses it too, so a tinted key stays the same colour without glass.
    var tint: UIColor? { didSet { applyLook() } }
    /// The glass reacts to touches on the controls inside it.
    var isInteractive: Bool { didSet { applyLook() } }
    /// The opaque fallback's tint when `tint` is nil (default: elevated).
    var fallbackTint: UIColor? { didSet { applyLook() } }
    /// The fallback material casts the kit's float shadow.
    var castsShadow = true { didSet { applyLook() } }

    /// True while the surface renders real glass (probes).
    private(set) var isGlass = false

    #if DEBUG
    /// INJECTED DEFECT (`flat-chrome`): no glass anywhere — flat chrome.
    static var probeFlat = false
    /// INJECTED DEFECT (`glass-ignores-reduce-transparency`): glass stays on
    /// under Reduce Transparency.
    static var probeIgnoresReduceTransparency = false
    /// INJECTED DEFECT (`glass-no-contrast-border`): no border under
    /// Increase Contrast.
    static var probeNoContrastBorder = false
    #endif

    /// The platform has Liquid Glass at all.
    static var isAvailable: Bool {
        if #available(iOS 26, *) { return true }
        return false
    }

    /// Glass shows now (available, Reduce Transparency off).
    static var showsGlass: Bool {
        #if DEBUG
        if probeFlat { return false }
        if probeIgnoresReduceTransparency { return isAvailable }
        #endif
        return isAvailable && !CCAccessibility.reduceTransparency
    }

    init(shape: Shape = .capsule, tint: UIColor? = nil, interactive: Bool = false) {
        self.shape = shape
        self.tint = tint
        self.isInteractive = interactive
        super.init(effect: nil)
        layer.cornerCurve = .continuous
        accessibilityIdentifier = "cc.glass"
        ccOnThemeChange { [weak self] in self?.applyLook() }
        applyLook()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// A glass key: `view` (a control) pinned inside the glass's content.
    static func wrapping(_ view: UIView, shape: Shape = .capsule, tint: UIColor? = nil,
                         interactive: Bool = true, inset: UIEdgeInsets = .zero) -> CCGlassView {
        let glass = CCGlassView(shape: shape, tint: tint, interactive: interactive)
        glass.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: inset.left),
            view.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -inset.right),
            view.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: inset.top),
            view.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -inset.bottom),
        ])
        return glass
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { applyLook() }
    }

    // MARK: Look

    private var radius: CGFloat {
        switch shape {
        case .capsule: return bounds.height / 2
        case .rounded(let r), .top(let r), .leading(let r): return r.resolved(for: bounds.height)
        }
    }

    private var corners: CACornerMask {
        switch shape {
        case .capsule, .rounded: return [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        case .top: return [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        case .leading:
            let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
            return rtl ? [.layerMaxXMinYCorner, .layerMaxXMaxYCorner] : [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        }
    }

    /// Glass, or the opaque material (Reduce Transparency, pre-26, a probe).
    func applyLook() {
        let traits = traitCollection
        let glass = Self.showsGlass
        isGlass = false
        if glass, #available(iOS 26, *) {
            let effect = UIGlassEffect(style: .regular)
            effect.isInteractive = isInteractive
            effect.tintColor = tint?.resolvedColor(with: traits)
            self.effect = effect
            CCMaterial.strip(layer)
            layer.shadowOpacity = 0
            isGlass = true
        } else {
            effect = nil
            #if DEBUG
            if Self.probeFlat { CCMaterial.strip(layer); applyBorder(); return }
            #endif
            let base = tint ?? fallbackTint ?? CCTheme.color.elevated
            CCMaterial.dress(layer, as: castsShadow ? .raised(tint: base) : .raisedMatte(tint: base),
                             radius: radius, traits: traits)
        }
        applyBorder()
        setNeedsLayout()
    }

    /// Increase Contrast: a clear 1 pt edge on the glass (the material
    /// fallback draws its own 1 pt hairline).
    private func applyBorder() {
        var border = isGlass && CCAccessibility.highContrast(traitCollection)
        #if DEBUG
        if Self.probeNoContrastBorder { border = false }
        #endif
        layer.borderWidth = border ? 1 : 0
        layer.borderColor = border ? CCMaterial.hairline(dark: CCTheme.isDark(traitCollection), onWell: false,
                                                         highContrast: true).cgColor : nil
    }

    /// The edge drawn now (probes): the glass's border, or the fallback's hairline.
    var probeEdgeWidth: CGFloat {
        if isGlass { return layer.borderWidth }
        return layer.sublayers?.first(where: { $0.name == "ccmat.base" })?.borderWidth ?? 0
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let r = radius
        let mask = corners
        layer.cornerRadius = r
        layer.maskedCorners = mask
        if #available(iOS 26, *) {
            let fixed = UICornerRadius.fixed(r), zero = UICornerRadius.fixed(0)
            switch shape {
            case .capsule: cornerConfiguration = .capsule()
            case .rounded: cornerConfiguration = .corners(radius: fixed)
            case .top: cornerConfiguration = .uniformEdges(topRadius: fixed, bottomRadius: zero)
            case .leading:
                let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
                cornerConfiguration = rtl ? .uniformEdges(leftRadius: zero, rightRadius: fixed)
                                          : .uniformEdges(leftRadius: fixed, rightRadius: zero)
            }
        }
        if !isGlass {
            CCMaterial.refit(layer, radius: r)
            if let base = layer.sublayers?.first(where: { $0.name == "ccmat.base" }) {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                base.maskedCorners = mask
                CATransaction.commit()
            }
        }
    }

    // MARK: Touches

    /// The controls inside keep their own (expanded) targets, even where
    /// they reach past the glass's bounds; the glass itself never swallows
    /// a touch that lands on its bare surface outside them.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01 else { return nil }
        for sub in contentView.subviews.reversed() where !sub.isHidden && sub.isUserInteractionEnabled && sub.alpha > 0.01 {
            if let hit = sub.hitTest(convert(point, to: sub), with: event) { return hit }
        }
        return super.hitTest(point, with: event)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if super.point(inside: point, with: event) { return true }
        return contentView.subviews.contains { !$0.isHidden && $0.point(inside: convert(point, to: $0), with: event) }
    }
}

/// Neighbouring glass shapes as ONE effect: the glass views in `contentView`
/// merge when they come within `spacing` and morph as they move. Without
/// glass (Reduce Transparency, pre-26) it is a plain container. Touches on
/// its bare area pass through.
final class CCGlassGroup: UIVisualEffectView {
    var spacing: CGFloat { didSet { applyLook() } }

    init(spacing: CGFloat = CCSpace.sm) {
        self.spacing = spacing
        super.init(effect: nil)
        translatesAutoresizingMaskIntoConstraints = false
        accessibilityIdentifier = "cc.glassGroup"
        ccOnThemeChange { [weak self] in self?.applyLook() }
        applyLook()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private(set) var isGlass = false

    func applyLook() {
        if CCGlassView.showsGlass, #available(iOS 26, *) {
            let container = UIGlassContainerEffect()
            container.spacing = spacing
            effect = container
            isGlass = true
        } else {
            effect = nil
            isGlass = false
        }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01 else { return nil }
        for sub in contentView.subviews.reversed() where !sub.isHidden && sub.isUserInteractionEnabled && sub.alpha > 0.01 {
            if let hit = sub.hitTest(convert(point, to: sub), with: event) { return hit }
        }
        return nil
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        contentView.subviews.contains { !$0.isHidden && $0.point(inside: convert(point, to: $0), with: event) }
    }
}

extension UIView {
    /// The real `UIGlassEffect` views at and under this view (probes): what
    /// UIKit renders as glass, whatever the kit thinks.
    func ccGlassEffectViews() -> [UIVisualEffectView] {
        var out: [UIVisualEffectView] = []
        func walk(_ v: UIView) {
            if #available(iOS 26, *), let fx = v as? UIVisualEffectView, fx.effect is UIGlassEffect { out.append(fx) }
            v.subviews.forEach(walk)
        }
        walk(self)
        return out
    }

    /// This view or an ancestor renders as glass (`UIGlassEffect`).
    var ccIsOnGlass: Bool {
        var v: UIView? = self
        while let current = v {
            if #available(iOS 26, *), let fx = current as? UIVisualEffectView, fx.effect is UIGlassEffect { return true }
            v = current.superview
        }
        return false
    }
}
