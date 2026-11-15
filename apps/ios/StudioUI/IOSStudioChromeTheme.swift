import UIKit

/// The studio's on-canvas editing chrome inks on iOS (selection outline,
/// value pill) — the UIKit counterpart of the Mac's `MacStudioChromeTheme`.
/// The studio is dark, like the Mac editor's default theme, so these are the
/// Mac editor's dark tokens; the accent is the system accent.
struct IOSStudioChromeTheme: StudioChromeTheme {
    var controlAccent: CGColor? {
        UIColor.tintColor.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)).cgColor
    }
    var panelElevated: CGColor { CGColor(srgbRed: 0.17, green: 0.17, blue: 0.18, alpha: 1) }
    var hairline: CGColor { CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10) }
    var textSecondary: CGColor { CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.60) }
    var isDark: Bool { true }
}
