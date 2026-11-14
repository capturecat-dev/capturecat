#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

extension ProjectSettings.SubtitleWeight {
    /// `PlatformFont.Weight` raw values are the same on both platforms.
    var nsWeight: PlatformFont.Weight {
        switch self {
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        }
    }

    /// The case whose `nsWeight` is `weight`; nil for the weights the five
    /// cases don't cover (FontFaceTable is keyed by these cases).
    init?(nsWeight weight: PlatformFont.Weight) {
        guard let match = Self.allCases.first(where: { $0.nsWeight == weight }) else { return nil }
        self = match
    }
}
