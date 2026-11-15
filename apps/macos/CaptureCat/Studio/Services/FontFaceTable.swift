import Foundation

/// The face the Mac draws for every `FontCatalog.curated` family at each of
/// the five subtitle/annotation weights, frozen (docs/ios-studio-phase0.md
/// §3.6, owner decision 5).
///
/// `FontCatalog` used to ask `NSFontManager` for the family member closest to
/// the weight on every call. That lookup has no iOS equivalent that lands on
/// the same faces (UIKit picks e.g. Futura-Bold for Medium where the Mac picks
/// Futura-Medium), so the Mac's answers are recorded here and both platforms
/// read them. Pure data: `PlatformFonts` turns a face into a font.
///
/// Generated, not written by hand: the entries are the output of FontCatalog's
/// live resolution (NSFontManager, as of commit 51b5314) run on the Mac over
/// curated × `ProjectSettings.SubtitleWeight.allCases` at 12/17/48/96 pt (the
/// face never depended on size). `--font-table-test` re-proves every entry
/// against the live resolution on the Mac it runs on. When `curated` changes,
/// regenerate the table the same way rather than editing it.
enum FontFaceTable {
    enum Face: Hashable, Sendable {
        /// The system UI face at the requested weight. The family resolved to
        /// it because it isn't installed (SF Pro, SF Pro Rounded, New York on
        /// the reference Mac).
        case system
        /// This PostScript face.
        case named(String)
        /// SF Mono: this PostScript face on the Mac; iOS has SF Mono only as
        /// the system font's `.monospaced` design, at the requested weight.
        case monospacedSystem(String)
    }

    /// The frozen face for a curated family at one of the five weights.
    static func face(family: String, weight: ProjectSettings.SubtitleWeight) -> Face? {
        faces[family]?[weight]
    }

    static let faces: [String: [ProjectSettings.SubtitleWeight: Face]] = [
        "SF Pro": [.regular: .system, .medium: .system, .semibold: .system, .bold: .system, .heavy: .system],
        "SF Pro Rounded": [.regular: .system, .medium: .system, .semibold: .system, .bold: .system, .heavy: .system],
        "New York": [.regular: .system, .medium: .system, .semibold: .system, .bold: .system, .heavy: .system],
        "Helvetica Neue": [.regular: .named("HelveticaNeue"), .medium: .named("HelveticaNeue-Medium"), .semibold: .named("HelveticaNeue-Bold"), .bold: .named("HelveticaNeue-Bold"), .heavy: .named("HelveticaNeue-CondensedBlack")],
        "Avenir Next": [.regular: .named("AvenirNext-Regular"), .medium: .named("AvenirNext-Medium"), .semibold: .named("AvenirNext-DemiBold"), .bold: .named("AvenirNext-Bold"), .heavy: .named("AvenirNext-Heavy")],
        "Futura": [.regular: .named("Futura-Medium"), .medium: .named("Futura-Medium"), .semibold: .named("Futura-Bold"), .bold: .named("Futura-Bold"), .heavy: .named("Futura-CondensedExtraBold")],
        "Gill Sans": [.regular: .named("GillSans"), .medium: .named("GillSans"), .semibold: .named("GillSans-SemiBold"), .bold: .named("GillSans-Bold"), .heavy: .named("GillSans-UltraBold")],
        "Georgia": [.regular: .named("Georgia"), .medium: .named("Georgia"), .semibold: .named("Georgia-Bold"), .bold: .named("Georgia-Bold"), .heavy: .named("Georgia-Bold")],
        "Times New Roman": [.regular: .named("TimesNewRomanPSMT"), .medium: .named("TimesNewRomanPSMT"), .semibold: .named("TimesNewRomanPS-BoldMT"), .bold: .named("TimesNewRomanPS-BoldMT"), .heavy: .named("TimesNewRomanPS-BoldMT")],
        "Palatino": [.regular: .named("Palatino-Roman"), .medium: .named("Palatino-Roman"), .semibold: .named("Palatino-Bold"), .bold: .named("Palatino-Bold"), .heavy: .named("Palatino-Bold")],
        "Menlo": [.regular: .named("Menlo-Regular"), .medium: .named("Menlo-Regular"), .semibold: .named("Menlo-Bold"), .bold: .named("Menlo-Bold"), .heavy: .named("Menlo-Bold")],
        "SF Mono": [.regular: .monospacedSystem("SFMono-Regular"), .medium: .monospacedSystem("SFMono-Medium"), .semibold: .monospacedSystem("SFMono-Semibold"), .bold: .monospacedSystem("SFMono-Bold"), .heavy: .monospacedSystem("SFMono-Heavy")],
        "Courier New": [.regular: .named("CourierNewPSMT"), .medium: .named("CourierNewPSMT"), .semibold: .named("CourierNewPS-BoldMT"), .bold: .named("CourierNewPS-BoldMT"), .heavy: .named("CourierNewPS-BoldMT")],
        "Impact": [.regular: .named("Impact"), .medium: .named("Impact"), .semibold: .named("Impact"), .bold: .named("Impact"), .heavy: .named("Impact")],
        "Copperplate": [.regular: .named("Copperplate"), .medium: .named("Copperplate"), .semibold: .named("Copperplate-Bold"), .bold: .named("Copperplate-Bold"), .heavy: .named("Copperplate-Bold")],
        "American Typewriter": [.regular: .named("AmericanTypewriter"), .medium: .named("AmericanTypewriter"), .semibold: .named("AmericanTypewriter-Semibold"), .bold: .named("AmericanTypewriter-Bold"), .heavy: .named("AmericanTypewriter-Bold")],
    ]
}
