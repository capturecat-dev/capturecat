import UIKit

// CCKit material engine — the dressing every surface shares (port of the
// Mac's CCMaterial, the 2026 look):
//  • raised — a FLOATING surface: the tint with a whisper of top light, a
//    0.5 pt hairline that follows the corners, and a soft cast shadow scaled
//    to the surface height (tight under a chip, airy under a card).
//  • raisedMatte — the same face without the cast shadow (cards inside a
//    container that already supplies depth, dialogs over a scrim).
//  • recessed — a flat WELL: the tint and a quieter hairline. No inner shadow.
// Never gloss, never bevels, never system Liquid Glass.
//
// `dress` from applyTheme (colors + frames), `refit` from layoutSubviews
// (frames only). The material lives in a `ccmat.base` sublayer at index 0,
// below every subview's layer. Press TINTS in place (`press`) — never moves.
enum CCMaterial {
    enum Style {
        case raised(tint: UIColor)
        case raisedMatte(tint: UIColor)
        case recessed(tint: UIColor)
    }

    /// Install/refresh the material (colors AND frames).
    static func dress(_ layer: CALayer, as style: Style, radius: CGFloat, traits: UITraitCollection) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let dark = CCTheme.isDark(traits)
        let base = baseLayer(in: layer)
        layer.setValue(dark, forKey: "ccmatDark")
        switch style {
        case .raised(let rawTint), .raisedMatte(let rawTint):
            let tint = solid(rawTint, traits: traits)
            base.colors = [
                tint.ccBlended(dark ? 0.035 : 0.02, of: .white, traits: traits).cgColor,
                tint.cgColor,
            ]
            base.borderColor = hairline(dark: dark, onWell: false).cgColor
            if case .raised = style, layer.value(forKey: "ccmatNoShadow") == nil {
                layer.setValue(true, forKey: "ccmatShadow")
            } else {
                layer.setValue(nil, forKey: "ccmatShadow")
                layer.shadowOpacity = 0
            }
        case .recessed(let rawTint):
            let tint = solid(rawTint, traits: traits)
            base.colors = [tint.cgColor, tint.cgColor]
            base.borderColor = hairline(dark: dark, onWell: true).cgColor
            layer.setValue(nil, forKey: "ccmatShadow")
            layer.shadowOpacity = 0
        }
        base.borderWidth = 0.5
        refit(layer, radius: radius)
    }

    /// Re-frame the material for the layer's current bounds.
    static func refit(_ layer: CALayer, radius: CGFloat) {
        guard let base = layer.sublayers?.first(where: { $0.name == "ccmat.base" }) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let b = layer.bounds
        base.frame = b
        base.cornerRadius = radius
        // The hairline reads as an outline on tiny surfaces — drop it.
        base.borderWidth = (b.height < 10 || b.width < 10) ? 0 : 0.5
        layer.sublayers?.first(where: { $0.name == "ccmat.pressShade" }).map {
            $0.frame = b
            $0.cornerRadius = radius
        }
        if layer.value(forKey: "ccmatShadow") as? Bool == true, b.width > 0, b.height > 0 {
            let dark = layer.value(forKey: "ccmatDark") as? Bool ?? false
            let shadow = floatShadow(height: b.height, dark: dark)
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOpacity = shadow.opacity
            layer.shadowRadius = shadow.radius
            layer.shadowOffset = CGSize(width: 0, height: shadow.y)
            layer.shadowPath = UIBezierPath(roundedRect: b, cornerRadius: radius).cgPath
        }
    }

    /// Apple press: the surface tints IN PLACE — an ink wash over the
    /// material, below the content. No movement, no scale, no restyle.
    static func press(_ layer: CALayer, down: Bool, traits: UITraitCollection) {
        let shade: CALayer
        if let existing = layer.sublayers?.first(where: { $0.name == "ccmat.pressShade" }) {
            shade = existing
        } else {
            shade = CALayer()
            shade.name = "ccmat.pressShade"
            shade.cornerCurve = .continuous
            shade.opacity = 0
            if let base = layer.sublayers?.first(where: { $0.name == "ccmat.base" }) {
                layer.insertSublayer(shade, above: base)
            } else {
                layer.insertSublayer(shade, at: 0)
            }
        }
        let dark = CCTheme.isDark(traits)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shade.backgroundColor = (dark ? UIColor.white : UIColor.black).cgColor
        shade.frame = layer.bounds
        shade.cornerRadius = layer.sublayers?.first(where: { $0.name == "ccmat.base" })?.cornerRadius ?? layer.cornerRadius
        CATransaction.commit()
        CCMotion.fade(shade, keyPath: "opacity", to: down ? (dark ? 0.10 : 0.07) : 0, duration: down ? 0.06 : 0.18)
    }

    /// Opt a dressed surface out of the cast shadow (packed rows, hosts with
    /// translucent fills).
    static func suppressShadow(_ layer: CALayer) {
        layer.setValue(nil, forKey: "ccmatShadow")
        layer.setValue(true, forKey: "ccmatNoShadow")
        layer.shadowOpacity = 0
    }

    /// Remove the material (ghost/link/clear surfaces).
    static func strip(_ layer: CALayer) {
        for sub in layer.sublayers ?? [] where sub.name == "ccmat.base" {
            sub.removeFromSuperlayer()
        }
        if layer.value(forKey: "ccmatShadow") as? Bool == true { layer.shadowOpacity = 0 }
        layer.setValue(nil, forKey: "ccmatShadow")
    }

    // MARK: - Internals

    /// The 2026 hairline: ink-relative so it reads on any tint, quieter on wells.
    static func hairline(dark: Bool, onWell: Bool) -> UIColor {
        if dark { return UIColor.white.withAlphaComponent(onWell ? 0.06 : 0.09) }
        return UIColor.black.withAlphaComponent(onWell ? 0.05 : 0.07)
    }

    /// Shadow for a floating surface of this height (chip → card → dialog).
    static func floatShadow(height: CGFloat, dark: Bool) -> (radius: CGFloat, opacity: Float, y: CGFloat) {
        let t = max(0, min(1, (height - 20) / 140))
        let radius = 2.5 + 11.5 * t
        let y = 1 + 4 * t
        let opacity: Float = dark ? Float(0.32 + 0.10 * t) : Float(0.07 + 0.03 * t)
        return (radius, opacity, y)
    }

    /// Translucent tints composite over the elevated surface first, so the
    /// material always derives from a REAL color (no alpha soup).
    private static func solid(_ tint: UIColor, traits: UITraitCollection) -> UIColor {
        let c = tint.ccComponents(traits)
        guard c.a < 0.99 else { return tint.resolvedColor(with: traits) }
        return CCTheme.color.elevated.ccBlended(c.a, of: UIColor(red: c.r, green: c.g, blue: c.b, alpha: 1), traits: traits)
    }

    private static func baseLayer(in host: CALayer) -> CAGradientLayer {
        if let existing = host.sublayers?.first(where: { $0.name == "ccmat.base" }) as? CAGradientLayer {
            return existing
        }
        let layer = CAGradientLayer()
        layer.name = "ccmat.base"
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        // iOS layers are Y-down: colors[0] (the top light) sits at the top.
        layer.startPoint = CGPoint(x: 0.5, y: 0)
        layer.endPoint = CGPoint(x: 0.5, y: 1)
        host.insertSublayer(layer, at: 0)
        return layer
    }
}
