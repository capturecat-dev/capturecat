import AppKit

/// Legacy façade over `CCTheme` — the CCKit token set is the single source
/// of truth; these aliases keep the historical names compiling. New code
/// should read `CCTheme.color/…/radius` directly.
@MainActor
enum EditorThemeKit {
    // MARK: - Surfaces

    static var windowBackground: NSColor { CCTheme.color.background }
    static var panel: NSColor { CCTheme.color.card }
    static var panelElevated: NSColor { CCTheme.color.elevated }

    // MARK: - Lines

    static var hairline: NSColor { CCTheme.color.border }

    // MARK: - Text

    static var textPrimary: NSColor { CCTheme.color.foreground }
    static var textSecondary: NSColor { CCTheme.color.mutedForeground }
    static var textTertiary: NSColor { CCTheme.color.faintForeground }

    // MARK: - Interaction

    static var hoverFill: NSColor { CCTheme.color.hover }
    static var activeFill: NSColor { CCTheme.color.active }

    /// Soft periwinkle outline on the active chip — one accent, app-wide.
    static var selectionOutline: NSColor { CCTheme.color.ring }

    // MARK: - Geometry

    static var panelRadius: CGFloat { CCTheme.radius(.lg) }
    static var controlRadius: CGFloat { CCTheme.radius(.md) }

    // MARK: - Fonts

    // One editor type scale (System Settings-like): 13pt semibold section
    // headers, 13pt regular row labels, 11pt muted captions. Sized here (not
    // in CCTheme) so the inspector scale doesn't ripple into alerts/buttons.
    static func label() -> NSFont { .systemFont(ofSize: 13) }
    static func header() -> NSFont { .systemFont(ofSize: 13, weight: .semibold) }
    static func caption() -> NSFont { .systemFont(ofSize: 11) }
    static func valuePill() -> NSFont { CCTheme.font.mono }
    static func button() -> NSFont { CCTheme.font.button }
    static func chip() -> NSFont { CCTheme.font.chip }
}

/// Solid block palettes, one per timeline lane family.
extension EditorThemeKit {
    /// EFFECTS lane — amber.
    static let effectBlockTop = NSColor(srgbRed: 1.00, green: 0.722, blue: 0.318, alpha: 1)     // #FFB851
    static let effectBlockBottom = NSColor(srgbRed: 0.910, green: 0.580, blue: 0.169, alpha: 1) // #E8942B

    /// FOCUS lane, blur half — slate blue.
    static let blurBlockTop = NSColor(srgbRed: 0.431, green: 0.525, blue: 0.784, alpha: 1)      // #6E86C8
    static let blurBlockBottom = NSColor(srgbRed: 0.298, green: 0.388, blue: 0.651, alpha: 1)   // #4C63A6

    /// FOCUS lane, highlight half — purple.
    static let highlightBlockTop = NSColor(srgbRed: 0.655, green: 0.545, blue: 0.980, alpha: 1)    // #A78BFA
    static let highlightBlockBottom = NSColor(srgbRed: 0.486, green: 0.357, blue: 0.878, alpha: 1) // #7C5BE0

    /// ANNOTATE lane — teal.
    static let annotateBlockTop = NSColor(srgbRed: 0.204, green: 0.827, blue: 0.600, alpha: 1)    // #34D399
    static let annotateBlockBottom = NSColor(srgbRed: 0.055, green: 0.643, blue: 0.478, alpha: 1) // #0EA47A

    /// Grip lines and text drawn on top of a solid block.
    static let blockGrip = NSColor.white.withAlphaComponent(0.7)
    static let blockContent = NSColor.white.withAlphaComponent(0.9)

    /// Snap guide — bright yellow so it reads instantly against the lanes.
    static let snapGuide = NSColor(srgbRed: 1.0, green: 0.86, blue: 0.15, alpha: 1)
}
