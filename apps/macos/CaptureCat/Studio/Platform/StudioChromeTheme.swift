import CoreGraphics

/// The app-theme inks the studio's canvas chrome draws with
/// (`SelectionChromeKit`'s selection outline and floating value pill). The
/// host supplies it: on the Mac, `MacStudioChromeTheme` reads the editor's
/// EditorThemeKit / CCTheme tokens; iOS supplies its own kit's.
///
/// Implementations read the tokens when each property is read — the chrome
/// is rendered with whatever the theme is at that moment, so a theme flip
/// re-renders with the new inks.
protocol StudioChromeTheme {
    /// Selection outline: the system accent in sRGB, nil when unavailable
    /// (the outline then falls back to white 90%).
    var controlAccent: CGColor? { get }
    /// The value pill's fill (an elevated panel surface).
    var panelElevated: CGColor { get }
    /// The value pill's 1pt edge.
    var hairline: CGColor { get }
    /// The pill's icon tint (secondary text).
    var textSecondary: CGColor { get }
    /// The resolved theme is dark — the pill's slider inks branch on it.
    var isDark: Bool { get }
}
