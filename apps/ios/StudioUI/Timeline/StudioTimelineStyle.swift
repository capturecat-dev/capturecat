import UIKit

/// The touch timeline's inks and chrome metrics. Lane geometry is NOT here —
/// it is the shared `TimelineCanvasMetrics` / `TimelineLaneLayout`
/// (Studio/Editor/TimelineLaneModel.swift), the very numbers the Mac draws
/// and hit-tests with. The block palettes are the Mac's content colours
/// (EditorThemeAppKit: fixed, not themed); chrome follows `CCTheme`, whose
/// tokens are the Mac `EditorThemeKit`'s (panel = card, hairline = border, …).
enum StudioTimelineStyle {
    /// Track-label column — the Mac's 84 pt ("ANNOTATE" ≈ 66 pt + air).
    static let labelWidth: CGFloat = 84
    /// Toolbar row height (the Mac panel's 42 pt).
    static let toolbarHeight: CGFloat = 42
    /// Space between the toolbar and the canvas, and the panel's side inset.
    static let canvasTopInset: CGFloat = 10
    static let sideInset: CGFloat = 12

    // MARK: Block palettes (EditorThemeAppKit)

    static let effectBlockTop = UIColor(red: 1.00, green: 0.722, blue: 0.318, alpha: 1)       // #FFB851
    static let effectBlockBottom = UIColor(red: 0.910, green: 0.580, blue: 0.169, alpha: 1)   // #E8942B
    static let blurBlockTop = UIColor(red: 0.431, green: 0.525, blue: 0.784, alpha: 1)        // #6E86C8
    static let blurBlockBottom = UIColor(red: 0.298, green: 0.388, blue: 0.651, alpha: 1)     // #4C63A6
    static let highlightBlockTop = UIColor(red: 0.655, green: 0.545, blue: 0.980, alpha: 1)   // #A78BFA
    static let highlightBlockBottom = UIColor(red: 0.486, green: 0.357, blue: 0.878, alpha: 1) // #7C5BE0
    static let annotateBlockTop = UIColor(red: 0.204, green: 0.827, blue: 0.600, alpha: 1)    // #34D399
    static let annotateBlockBottom = UIColor(red: 0.055, green: 0.643, blue: 0.478, alpha: 1) // #0EA47A
    static let blockGrip = UIColor.white.withAlphaComponent(0.7)
    static let blockContent = UIColor.white.withAlphaComponent(0.9)
    static let snapGuide = UIColor(red: 1.0, green: 0.86, blue: 0.15, alpha: 1)
    static let videoYellow = UIColor.systemYellow
    static let videoOrange = UIColor.systemOrange
    static let voiceOrange = UIColor.systemOrange
    static let playhead = UIColor.systemCyan

    // MARK: Helpers

    /// Each channel nudged by `delta` (the Mac's `brightened`), in sRGB.
    static func brightened(_ color: UIColor, by delta: CGFloat) -> UIColor {
        guard delta != 0 else { return color }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return color }
        return UIColor(red: min(1, r + delta), green: min(1, g + delta), blue: min(1, b + delta), alpha: a)
    }

    private static var symbolCache: [String: UIImage] = [:]

    /// A kit icon painted in `color` (CCIcon) — timeline chrome, never content.
    static func symbol(_ name: String, pointSize: CGFloat, weight: UIFont.Weight, color: UIColor) -> UIImage? {
        let key = "\(name)-\(pointSize)-\(weight.rawValue)-\(color.description)"
        if let cached = symbolCache[key] { return cached }
        guard let image = CCIcon.image(name, pointSize: pointSize, weight: weight, color: color) else { return nil }
        symbolCache[key] = image
        return image
    }

    /// Opacity of a block's content (icon, label, grips) at its current
    /// height: legible on an open lane, gone on a closed strip, a smooth fade
    /// between so nothing pops while the accordion moves (the Mac's rule).
    static func contentAlpha(forBlockHeight height: CGFloat) -> CGFloat {
        min(1, max(0, (height - 16) / 16))
    }

    /// The chrome inks, resolved for the view's traits (dark studio).
    static func ink(_ traits: UITraitCollection) -> UIColor {
        traits.userInterfaceStyle == .dark ? .white : .black
    }
}
