#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// The default colours models fall back to. On the Mac these are the exact
/// `CodableColor(NSColor.…)` expressions the models used inline, evaluated at
/// the same moment (a computed property per use), so the dynamic system
/// colours still resolve against the appearance current at that moment.
///
/// On iOS they are UIKit's colours for now. White and black are exact; the
/// system hues are not the Mac's values and get Mac-captured sRGB literals
/// with the --ios-vectors gate (Phase 2), before iOS renders anything.
enum SystemColorDefaults {
    static var white: CodableColor { CodableColor(PlatformColor.white) }
    static var black: CodableColor { CodableColor(PlatformColor.black) }
    static var systemPurple: CodableColor { CodableColor(PlatformColor.systemPurple) }
    static var systemBlue: CodableColor { CodableColor(PlatformColor.systemBlue) }
    static var systemYellow: CodableColor { CodableColor(PlatformColor.systemYellow) }
}
