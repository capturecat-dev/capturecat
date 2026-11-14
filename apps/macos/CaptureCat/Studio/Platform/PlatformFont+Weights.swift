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
}
