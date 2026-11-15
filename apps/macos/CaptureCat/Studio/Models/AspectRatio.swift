import CoreGraphics
import Foundation

enum AspectRatio: String, CaseIterable, Codable, Sendable, Identifiable {
    case auto = "Auto"
    case widescreen = "16:9"
    case standard = "4:3"
    case square = "1:1"
    case vertical = "9:16"
    case ultrawide = "21:9"
    case tallVertical = "4:5"

    var id: String { rawValue }

    /// Where this framing is the native format — shown as the picker's
    /// subtitle so "9:16" reads as "TikTok · Shorts · Reels" without a
    /// separate platform preset list (raw values stay the persisted ids).
    var platformHint: String? {
        switch self {
        case .auto: return "Match the recording"
        case .widescreen: return "YouTube · X · LinkedIn"
        case .standard: return "Slides · legacy displays"
        case .square: return "Instagram · LinkedIn feed"
        case .vertical: return "TikTok · Shorts · Reels"
        case .ultrawide: return "Cinematic · ultrawide"
        case .tallVertical: return "Instagram feed portrait"
        }
    }

    var size: CGSize? {
        switch self {
        case .auto: return nil
        case .widescreen: return CGSize(width: 16, height: 9)
        case .standard: return CGSize(width: 4, height: 3)
        case .square: return CGSize(width: 1, height: 1)
        case .vertical: return CGSize(width: 9, height: 16)
        case .ultrawide: return CGSize(width: 21, height: 9)
        case .tallVertical: return CGSize(width: 4, height: 5)
        }
    }

    func resolution(fitting width: CGFloat) -> CGSize {
        guard let ratio = size else { return CGSize(width: width, height: width * 9 / 16) }
        let height = width * ratio.height / ratio.width
        return CGSize(width: width, height: height)
    }

    /// The width/height aspect the CANVAS must have for this setting — the
    /// single source of truth shared by the editor's letterboxed preview
    /// canvas and the exporter's output size, so preview and file always
    /// agree on framing. `.auto` follows the SOURCE video's aspect
    /// (falling back to 16:9 when it is unknown).
    func canvasAspect(sourceSize: CGSize) -> CGFloat {
        if let ratio = size { return ratio.width / ratio.height }
        guard sourceSize.width > 0, sourceSize.height > 0 else { return 16.0 / 9.0 }
        return sourceSize.width / sourceSize.height
    }

    /// Largest rect of `aspect` (w/h) that fits centered inside `bounds` —
    /// the letterbox the editor uses to shape the preview canvas. Shared
    /// with the geometry harness so the two sides cannot fork.
    static func letterboxRect(in bounds: CGRect, aspect: CGFloat) -> CGRect {
        guard bounds.width > 0, bounds.height > 0, aspect > 0 else { return bounds }
        var size = CGSize(width: bounds.width, height: bounds.width / aspect)
        if size.height > bounds.height {
            size = CGSize(width: bounds.height * aspect, height: bounds.height)
        }
        return CGRect(
            x: bounds.minX + (bounds.width - size.width) / 2,
            y: bounds.minY + (bounds.height - size.height) / 2,
            width: size.width, height: size.height
        )
    }
}
