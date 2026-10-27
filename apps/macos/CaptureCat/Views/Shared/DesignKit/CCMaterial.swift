import AppKit

// CCKit material engine — the dressing every component shares.
//
// THE 2026 LOOK (Mike, 2026-10-27: "a more 2026 style like macOS apps" —
// soft light surfaces, our own take), replacing the 2026-09-01
// skeuomorphic keys: soft, airy, floating. Still our own drawing — never
// system Liquid Glass (Mike, 2026-08-17).
//  • raised / raisedMatte — a FLOATING surface: the tint with a whisper of
//    top light, a hairline edge that follows the corners, and a wide soft
//    shadow scaled to the surface (tight under chips, airy under cards).
//    No extruded side, no inner light, no bevel lines, no gloss.
//  • recessed — a flat WELL: the tint, a hairline edge, no inner shadow.
//
// Everything is DERIVED from the live theme tokens — no image assets. The
// sublayers keep their `ccmat.*` names (base, under, bevelTop/Bottom,
// innerTop) so probes and the self-heal below work unchanged; the 2026 look
// simply hides the ones it does not use.
//
// Components call `dress` from applyTheme() (colors + frames) and `refit`
// from layout() (frames only). Both are idempotent and self-healing: AppKit
// occasionally rebuilds view backing layers' sublayer arrays (the
// CCGlideHighlight lesson), and the next dress/refit simply reinstalls.
@MainActor
enum CCMaterial {
    enum Style {
        /// Floating, touchable surface (hairline + soft cast shadow scaled to
        /// its height) — buttons, chips, thumbs, popovers.
        case raised(tint: NSColor)
        /// The same floating face WITHOUT the cast shadow — large surfaces
        /// (cards, dialogs) whose host window or container supplies depth.
        case raisedMatte(tint: NSColor)
        /// A flat well the content sits inside (tint + quieter hairline, no
        /// inner shadow) — fields, tracks, segmented wells.
        case recessed(tint: NSColor)
    }

    // MARK: - Public

    /// Install/refresh the material (colors AND frames). Call from applyTheme.
    static func dress(_ layer: CALayer, as style: Style, radius: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // Translucent tints (selection washes like activeFill) make the
        // gradient/bevel math derive from alpha-soup — washed-out "weird"
        // surfaces. Composite them over the elevated surface first so the
        // material always works from a REAL color.
        let style = solidified(style)

        // Remember the recipe on the layer itself: AppKit rebuilds view
        // backing layers' sublayer arrays on window attach, silently dropping
        // the whole material ("I have to hover to see it"). refit() uses
        // this record to re-dress from scratch when it finds the base gone.
        switch style {
        case .raised(let tint): layer.setValue(1, forKey: "ccmatStyle"); layer.setValue(tint, forKey: "ccmatTint")
        case .raisedMatte(let tint): layer.setValue(2, forKey: "ccmatStyle"); layer.setValue(tint, forKey: "ccmatTint")
        case .recessed(let tint): layer.setValue(3, forKey: "ccmatStyle"); layer.setValue(tint, forKey: "ccmatTint")
        }

        let dark = CCTheme.isDark
        let under = line(in: layer, name: "ccmat.under", index: 0)
        let base = gradient(in: layer, name: "ccmat.base", index: 1)
        let bevelTop = line(in: layer, name: "ccmat.bevelTop", index: 2)
        let bevelBottom = line(in: layer, name: "ccmat.bevelBottom", index: 3)
        let innerTop = gradient(in: layer, name: "ccmat.innerTop", index: 4)
        // NO gloss layer: the glass sheen shipped and Mike vetoed it on
        // sight ("a big no no") — depth comes from the hairline and the
        // floating shadow only. If a layer was dressed before the veto, clear it.
        layer.sublayers?.first(where: { $0.name == "ccmat.gloss" })?.removeFromSuperlayer()
        // Dress resets visibility; refit's size guards then re-hide as needed
        // (without this, a guard that fired once would latch forever).
        bevelTop.isHidden = false
        bevelBottom.isHidden = false

        switch style {
        case .raised(let tint), .raisedMatte(let tint):
            // A floating surface: the tint itself with a whisper of top
            // light (2026 surfaces read flat; the gradient only keeps big
            // panels from looking printed), and a hairline edge.
            base.colors = [
                blend(tint, .white, dark ? 0.035 : 0.02).cgColor,
                tint.cgColor,
            ]
            base.locations = [0, 1]
            base.borderWidth = 0.5
            base.borderColor = hairline(dark: dark, onWell: false).cgColor
            under.isHidden = true
            bevelTop.isHidden = true
            bevelBottom.isHidden = true
            innerTop.isHidden = true
            if case .raised = style, !layer.masksToBounds,
               layer.value(forKey: "ccmatNoShadow") == nil {
                // The floating shadow is APPLIED in refit, not here: AppKit
                // owns view backing layers and reconfigures them on window
                // attach, wiping an init-time shadow — which shipped as
                // "shadows only appear after hovering" (hover re-dressed).
                // refit runs on every layout, so it heals the clobber.
                layer.setValue(true, forKey: "ccmatShadow")
            } else {
                layer.setValue(nil, forKey: "ccmatShadow")
            }
        case .recessed(let tint):
            // A flat well: the tint and a hairline edge. Depth comes from the
            // floating surfaces around it, not from shading inside it.
            under.isHidden = true
            layer.setValue(nil, forKey: "ccmatShadow")
            layer.shadowOpacity = 0
            base.colors = [tint.cgColor, tint.cgColor]
            base.locations = [0, 1]
            base.borderWidth = 0.5
            base.borderColor = hairline(dark: dark, onWell: true).cgColor
            innerTop.isHidden = true
            bevelTop.isHidden = true
            bevelBottom.isHidden = true
        }
        refit(layer, radius: radius)
    }

    /// Re-frame the material for the layer's current bounds. Call from layout.
    /// Self-healing: if AppKit's backing-layer rebuild dropped the material
    /// sublayers, re-dress from the recorded recipe instead of bailing.
    static func refit(_ layer: CALayer, radius: CGFloat) {
        guard let base = layer.sublayers?.first(where: { $0.name == "ccmat.base" }) else {
            if let tag = layer.value(forKey: "ccmatStyle") as? Int,
               let tint = layer.value(forKey: "ccmatTint") as? NSColor {
                let style: Style = tag == 1 ? .raised(tint: tint)
                    : tag == 2 ? .raisedMatte(tint: tint) : .recessed(tint: tint)
                dress(layer, as: style, radius: radius)
            }
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let b = layer.bounds
        // Host layers in this kit are a mix of flipped view backers and raw
        // CALayers; resolve "top" from geometryFlipped so bevels land on the
        // visually-correct edge either way.
        let flipped = layer.isGeometryFlipped
        let topY = flipped ? b.minY : b.maxY - 1
        let bottomY = flipped ? b.maxY - 1 : b.minY
        // Quality guards (tuned on the real panes): straight 1px bevel lines
        // read as floating dashes on pill-shaped or narrow surfaces, gloss
        // and inner shadows turn to noise on very short ones — suppress
        // rather than render badly.
        let pillish = radius > b.height * 0.35 || b.width < 40
        let tooShortForSheen = b.height < 10
        // Re-assert the floating shadow every refit — AppKit reconfigures view
        // backing layers on window attach and silently drops an init-time
        // shadow (seen as "shadows only appear after hovering").
        if layer.value(forKey: "ccmatShadow") as? Bool == true {
            // Soft and wide, scaled to the surface: a chip gets a tight
            // contact shadow, a card an airy one. Never a hard key shadow.
            let shadow = floatShadow(height: b.height, dark: CCTheme.isDark)
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = shadow.opacity
            layer.shadowRadius = shadow.radius
            layer.shadowOffset = CGSize(width: 0, height: flipped ? shadow.y : -shadow.y)
        }
        // Gradient axis re-resolved every refit from LIVE flippedness —
        // colors[0] (the top shade/lift) must sit at the visual top.
        let gradStart = CGPoint(x: 0.5, y: flipped ? 0 : 1)
        let gradEnd = CGPoint(x: 0.5, y: flipped ? 1 : 0)
        for sub in layer.sublayers ?? [] {
            if let grad = sub as? CAGradientLayer, sub.name?.hasPrefix("ccmat.") == true {
                grad.startPoint = gradStart
                grad.endPoint = gradEnd
            }
            switch sub.name {
            case "ccmat.base":
                sub.frame = b
                sub.cornerRadius = radius
                // The hairline is a border, so it follows the corners;
                // on a tiny surface it would read as an outline — drop it.
                if b.height < 10 || b.width < 10 { sub.borderWidth = 0 }
            case "ccmat.under":
                // The 2026-09 key's "side" (hidden in the 2026 look; kept so
                // probes and the self-heal keep their layer indices).
                let extrude = min(2, b.height * 0.12)
                sub.frame = b.offsetBy(dx: 0, dy: flipped ? extrude : -extrude)
                sub.cornerRadius = radius
            case "ccmat.innerTop":
                let h = min(6, b.height * 0.4)
                sub.frame = CGRect(x: 0, y: flipped ? 0 : b.height - h, width: b.width, height: h)
                sub.cornerRadius = min(radius, h / 2)
                if tooShortForSheen { sub.isHidden = true }
            case "ccmat.bevelTop":
                sub.frame = CGRect(x: radius * 0.6, y: topY, width: b.width - radius * 1.2, height: 1)
                sub.isHidden = sub.isHidden || pillish
            case "ccmat.bevelBottom":
                sub.frame = CGRect(x: radius * 0.6, y: bottomY, width: b.width - radius * 1.2, height: 1)
                sub.isHidden = sub.isHidden || pillish
            default:
                break
            }
        }
        _ = base
    }

    /// Apple-style press: the surface tints IN PLACE — no movement, no
    /// geometry change (a traveling button read as un-Apple; Mike,
    /// 2026-09-01 — and before that, a recessed re-dress snapped a dark
    /// band into the face). An ink wash fades in over the material, below
    /// the content, and fades out on release. Components that already
    /// darken their own fill on press (CCButton, InspectorButton) should
    /// NOT also call this — double-darkening reads heavy.
    static func press(_ layer: CALayer, down: Bool) {
        let shade: CALayer
        if let existing = layer.sublayers?.first(where: { $0.name == "ccmat.pressShade" }) {
            shade = existing
        } else {
            shade = CALayer()
            shade.name = "ccmat.pressShade"
            shade.cornerCurve = .continuous
            shade.opacity = 0
            // Above the material, below the content's subview layers.
            if let base = layer.sublayers?.first(where: { $0.name == "ccmat.innerTop" })
                ?? layer.sublayers?.first(where: { $0.name == "ccmat.base" }) {
                layer.insertSublayer(shade, above: base)
            } else {
                layer.insertSublayer(shade, at: 0)
            }
        }
        // Ink-relative, matching the kit's hover washes: dark theme presses
        // lighten, light theme presses darken.
        let ink: NSColor = CCTheme.isDark ? .white : .black
        shade.backgroundColor = ink.cgColor
        shade.cornerRadius = layer.cornerRadius
        shade.frame = layer.bounds
        CCMotion.fade(shade, keyPath: "opacity",
                      to: down ? (CCTheme.isDark ? 0.10 : 0.08) : 0, duration: 0.08)
    }

    /// Opt a dressed surface out of the cast shadow — dense bars where
    /// shadows smear across packed neighbors, or hosts whose fills are
    /// translucent (a shadow shows through the fill as a muddy halo).
    static func suppressShadow(_ layer: CALayer) {
        layer.setValue(nil, forKey: "ccmatShadow")
        // Part of the recorded recipe — survives the refit self-heal, which
        // would otherwise re-arm the shadow when it re-dresses.
        layer.setValue(true, forKey: "ccmatNoShadow")
        layer.shadowOpacity = 0
    }

    /// Remove the material (ghost/link buttons, plain chromes).
    static func strip(_ layer: CALayer) {
        for sub in layer.sublayers ?? [] where sub.name?.hasPrefix("ccmat.") == true {
            sub.removeFromSuperlayer()
        }
        if layer.value(forKey: "ccmatShadow") as? Bool == true {
            layer.shadowOpacity = 0
        }
        layer.setValue(nil, forKey: "ccmatShadow")
        layer.setValue(nil, forKey: "ccmatNoShadow")
        layer.setValue(nil, forKey: "ccmatStyle")
        layer.setValue(nil, forKey: "ccmatTint")
    }

    // MARK: - Internals

    /// The 2026 hairline: ink-relative so it reads on any tint, quieter on
    /// wells than on floating surfaces.
    static func hairline(dark: Bool, onWell: Bool) -> NSColor {
        if dark { return NSColor.white.withAlphaComponent(onWell ? 0.06 : 0.09) }
        return NSColor.black.withAlphaComponent(onWell ? 0.05 : 0.07)
    }

    /// Shadow for a floating surface of this height: radius, opacity and
    /// downward offset grow with size (chip → card → dialog).
    static func floatShadow(height: CGFloat, dark: Bool) -> (radius: CGFloat, opacity: Float, y: CGFloat) {
        let t = max(0, min(1, (height - 20) / 140))       // 20 pt chip … 160 pt card
        let radius = 2.5 + 11.5 * t                         // 2.5 … 14
        let y = 1 + 4 * t                                   // 1 … 5
        let opacity: Float = dark ? Float(0.32 + 0.10 * t) : Float(0.07 + 0.03 * t)
        return (radius, opacity, y)
    }

    private static func blend(_ base: NSColor, _ with: NSColor, _ fraction: CGFloat) -> NSColor {
        base.blended(withFraction: fraction, of: with) ?? base
    }

    /// Composite a translucent tint over the elevated surface so gradients
    /// and bevels always derive from an opaque color.
    private static func solidified(_ style: Style) -> Style {
        func solid(_ tint: NSColor) -> NSColor {
            guard tint.alphaComponent < 0.99 else { return tint }
            return CCTheme.color.elevated
                .blended(withFraction: tint.alphaComponent, of: tint.withAlphaComponent(1)) ?? tint
        }
        switch style {
        case .raised(let tint): return .raised(tint: solid(tint))
        case .raisedMatte(let tint): return .raisedMatte(tint: solid(tint))
        case .recessed(let tint): return .recessed(tint: solid(tint))
        }
    }

    private static func gradient(in host: CALayer, name: String, index: UInt32) -> CAGradientLayer {
        if let existing = host.sublayers?.first(where: { $0.name == name }) as? CAGradientLayer {
            return existing
        }
        let layer = CAGradientLayer()
        layer.name = name
        // Orientation is set in refit(), NOT here: at creation time a flipped
        // view's backing layer often isn't geometry-flipped YET (AppKit marks
        // it lazily), so a baked direction ships the recessed top-lip shade
        // at the visual BOTTOM ("the black bottom inside").
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        host.insertSublayer(layer, at: min(index, UInt32(host.sublayers?.count ?? 0)))
        return layer
    }

    private static func line(in host: CALayer, name: String, index: UInt32) -> CALayer {
        if let existing = host.sublayers?.first(where: { $0.name == name }) {
            return existing
        }
        let layer = CALayer()
        layer.name = name
        layer.cornerRadius = 0.5
        host.insertSublayer(layer, at: min(index, UInt32(host.sublayers?.count ?? 0)))
        return layer
    }
}
