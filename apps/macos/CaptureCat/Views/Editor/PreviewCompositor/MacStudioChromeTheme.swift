import AppKit

/// The Mac's `StudioChromeTheme`: the editor's EditorThemeKit / CCTheme
/// tokens. Every property is computed, so each read resolves the token at
/// that moment — exactly the inline reads SelectionChromeKit made before the
/// seam (CCTheme.apply invalidates every window, so a theme flip re-renders
/// the chrome with the new inks).
struct MacStudioChromeTheme: StudioChromeTheme {
    var controlAccent: CGColor? { NSColor.controlAccentColor.usingColorSpace(.sRGB)?.cgColor }
    var panelElevated: CGColor { EditorThemeKit.panelElevated.cgColor }
    var hairline: CGColor { EditorThemeKit.hairline.cgColor }
    var textSecondary: CGColor { EditorThemeKit.textSecondary.cgColor }
    var isDark: Bool { CCTheme.isDark }
}

extension SelectionChromeKit {
    /// The chrome in the editor's theme — the Mac gates that draw the kit
    /// directly (`--raster-golden`, `--preview-parity`) use this.
    static func image(
        size: CGSize,
        regions: [Region],
        containerRect: CGRect,
        scale: CGFloat
    ) -> CGImage? {
        image(size: size, regions: regions, containerRect: containerRect, scale: scale,
              theme: MacStudioChromeTheme())
    }
}
