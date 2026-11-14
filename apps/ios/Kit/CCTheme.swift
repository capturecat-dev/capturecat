import UIKit

// CCKit for iOS — the UIKit port of the Mac's house design kit
// (apps/macos/CaptureCat/Views/Shared/DesignKit). Same names, same tokens,
// same 2026 look: soft, airy, FLOATING surfaces over flat WELLS, our own icon
// kit, Apple-feel motion. 100% UIKit (never SwiftUI) and app-extension-safe:
// the share extension compiles this folder with APPLICATION_EXTENSION_API_ONLY,
// so nothing in Kit/ may touch UIApplication.shared or other app-only API.
//
// Colors are DYNAMIC UIColors (light + dark palettes, following the system).
// UIKit properties (textColor, backgroundColor, tintColor) resolve them on
// their own; CALayer colors don't — every component re-applies its layer
// colors in `applyTheme()`, run at init, on window attach and on every
// user-interface-style change (`ccOnThemeChange`).

// MARK: - Scales

/// Radius scale — law. Never hardcode a corner radius: `.sm` row
/// highlights, `.md` buttons/fields/nested thumbs, `.lg` cards/menus/sheets,
/// `.xl` dialog cards/floating bars, `.full` pills.
enum CCRadius: Equatable {
    case none
    case sm
    case md
    case lg
    case xl
    /// Fully round — half the control's height.
    case full

    func resolved(for height: CGFloat = 0) -> CGFloat {
        switch self {
        case .none: return 0
        case .sm: return CCTheme.radii.sm
        case .md: return CCTheme.radii.md
        case .lg: return CCTheme.radii.lg
        case .xl: return CCTheme.radii.xl
        case .full: return height / 2
        }
    }

    /// The radius one step inside this one when content sits `inset` pt in
    /// (concentric corners).
    func concentric(inset: CGFloat, height: CGFloat = 0) -> CGFloat {
        max(resolved(for: height) - inset, CCTheme.radii.sm / 2)
    }
}

/// Spacing scale. Use these instead of magic paddings.
enum CCSpace {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    /// Side gutter for screen content.
    static let gutter: CGFloat = 16
}

// MARK: - Tokens

/// Semantic colors (shadcn naming), each a dynamic light/dark UIColor.
struct CCThemeColors {
    // Surfaces
    let background: UIColor
    let card: UIColor
    let popover: UIColor
    let elevated: UIColor
    // Content
    let foreground: UIColor
    let mutedForeground: UIColor
    let faintForeground: UIColor
    // Interactive
    let primary: UIColor
    let primaryForeground: UIColor
    let destructive: UIColor
    let success: UIColor
    let warning: UIColor
    // Lines & states
    let border: UIColor
    /// Ink ring — the ONLY ring in the kit: keyboard focus on text inputs.
    let ring: UIColor
    let hover: UIColor
    let active: UIColor
    /// Scrim behind dialogs and sheets.
    let overlay: UIColor
}

enum CCTheme {
    static let radii = (sm: CGFloat(6), md: CGFloat(9), lg: CGFloat(14), xl: CGFloat(20))
    /// Disabled controls dim to this alpha.
    static let disabledAlpha: CGFloat = 0.38

    static func radius(_ r: CCRadius, height: CGFloat = 0) -> CGFloat { r.resolved(for: height) }

    static func isDark(_ traits: UITraitCollection) -> Bool { traits.userInterfaceStyle == .dark }

    /// The 2026 palettes (Mac CCThemeSpec.capDark / capLight, 2026-10-27).
    static let color = CCThemeColors(
        background: dyn(light: hex(0xF4F4F6), dark: hex(0x121215)),
        card: dyn(light: .white, dark: hex(0x1C1C20)),
        popover: dyn(light: .white, dark: hex(0x212126)),
        elevated: dyn(light: hex(0xECECEF), dark: hex(0x2A2A30)),
        foreground: dyn(light: hex(0x1D1D1F), dark: UIColor.white.withAlphaComponent(0.94)),
        mutedForeground: dyn(light: UIColor.black.withAlphaComponent(0.54), dark: UIColor.white.withAlphaComponent(0.58)),
        faintForeground: dyn(light: UIColor.black.withAlphaComponent(0.32), dark: UIColor.white.withAlphaComponent(0.36)),
        primary: .systemBlue,
        primaryForeground: .white,
        destructive: .systemRed,
        success: .systemGreen,
        warning: .systemOrange,
        border: dyn(light: UIColor.black.withAlphaComponent(0.08), dark: UIColor.white.withAlphaComponent(0.08)),
        ring: dyn(light: UIColor.black.withAlphaComponent(0.55), dark: UIColor.white.withAlphaComponent(0.85)),
        hover: dyn(light: UIColor.black.withAlphaComponent(0.045), dark: UIColor.white.withAlphaComponent(0.06)),
        active: dyn(light: UIColor.black.withAlphaComponent(0.08), dark: UIColor.white.withAlphaComponent(0.10)),
        overlay: dyn(light: UIColor.black.withAlphaComponent(0.25), dark: UIColor.black.withAlphaComponent(0.42))
    )

    static func dyn(light: UIColor, dark: UIColor) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? dark : light }
    }

    static func hex(_ value: UInt32, alpha: CGFloat = 1) -> UIColor {
        UIColor(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: alpha
        )
    }
}

// MARK: - Type

/// The kit's type ramp — the Mac's roles at iOS reading sizes, all Dynamic
/// Type-scaled (capped so chrome never explodes). Labels showing these set
/// `adjustsFontForContentSizeCategory = true` and follow the user's size.
enum CCFont {
    static func scaled(_ size: CGFloat, _ weight: UIFont.Weight, _ style: UIFont.TextStyle, max: CGFloat) -> UIFont {
        UIFontMetrics(forTextStyle: style).scaledFont(for: .systemFont(ofSize: size, weight: weight), maximumPointSize: max)
    }

    // The Mac kit's weight hierarchy (label 12 · chip 13 · header 14 semibold ·
    // title 15 semibold) at touch scale (~1.25×). No iOS large-bold titles.
    /// Page titles in header bars.
    static var largeTitle: UIFont { scaled(24, .semibold, .title1, max: 34) }
    /// Detail titles, dialog titles.
    static var title: UIFont { scaled(19, .semibold, .title2, max: 30) }
    /// Field / select / chip text (the Mac's `chip`, 13 → 16).
    static var chip: UIFont { scaled(16, .regular, .body, max: 26) }
    static var header: UIFont { scaled(17, .semibold, .headline, max: 26) }
    static var body: UIFont { scaled(16, .regular, .body, max: 28) }
    static var bodyMedium: UIFont { scaled(16, .medium, .body, max: 28) }
    static var label: UIFont { scaled(15, .regular, .subheadline, max: 24) }
    static var labelMedium: UIFont { scaled(15, .medium, .subheadline, max: 24) }
    static var labelSemibold: UIFont { scaled(15, .semibold, .subheadline, max: 24) }
    static var caption: UIFont { scaled(13, .regular, .footnote, max: 20) }
    static var captionMedium: UIFont { scaled(13, .medium, .footnote, max: 20) }
    static var micro: UIFont { scaled(11, .semibold, .caption2, max: 16) }
    static var mono: UIFont {
        UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .monospacedDigitSystemFont(ofSize: 13, weight: .medium), maximumPointSize: 19)
    }
    static var monoSmall: UIFont {
        UIFontMetrics(forTextStyle: .caption2).scaledFont(for: .monospacedDigitSystemFont(ofSize: 11, weight: .semibold), maximumPointSize: 15)
    }
}

// MARK: - Color helpers

extension UIColor {
    /// RGBA in sRGB after resolving for `traits`.
    func ccComponents(_ traits: UITraitCollection) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        let resolved = resolvedColor(with: traits)
        if !resolved.getRed(&r, green: &g, blue: &b, alpha: &a) {
            var white: CGFloat = 0
            resolved.getWhite(&white, alpha: &a)
            r = white; g = white; b = white
        }
        return (r, g, b, a)
    }

    /// AppKit's `blended(withFraction:of:)` for UIKit, resolved for `traits`.
    func ccBlended(_ fraction: CGFloat, of other: UIColor, traits: UITraitCollection) -> UIColor {
        let a = ccComponents(traits), b = other.ccComponents(traits)
        let f = max(0, min(1, fraction))
        return UIColor(
            red: a.r + (b.r - a.r) * f,
            green: a.g + (b.g - a.g) * f,
            blue: a.b + (b.b - a.b) * f,
            alpha: a.a + (b.a - a.a) * f
        )
    }
}

extension UIView {
    /// Resolve a (dynamic) color for this view's traits, as a CGColor —
    /// layer colors never update on their own.
    func cc(_ color: UIColor) -> CGColor {
        color.resolvedColor(with: traitCollection).cgColor
    }

    /// Re-run `apply` whenever light/dark (or contrast) changes. Components
    /// call their `applyTheme()` from here, at init and on window attach.
    @discardableResult
    func ccOnThemeChange(_ apply: @escaping () -> Void) -> UITraitChangeRegistration {
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (_: UIView, _: UITraitCollection) in
            apply()
        }
    }

    /// Hairline width for this view's screen (1 px).
    var ccHairline: CGFloat { 1 / max(traitCollection.displayScale, 1) }
}

/// Builds a themed label in one line.
func ccLabel(_ text: String = "", font: UIFont, color: UIColor, lines: Int = 1, alignment: NSTextAlignment = .natural) -> UILabel {
    let label = UILabel()
    label.text = text
    label.font = font
    label.textColor = color
    label.numberOfLines = lines
    label.textAlignment = alignment
    label.adjustsFontForContentSizeCategory = true
    label.lineBreakMode = .byTruncatingTail
    label.translatesAutoresizingMaskIntoConstraints = false
    return label
}
