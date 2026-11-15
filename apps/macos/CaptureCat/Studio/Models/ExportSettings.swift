import Foundation
import CoreGraphics

struct ExportSettings: Codable, Sendable {
    static let minimumQuality: Double = 0.5
    static let maximumQuality: Double = 1.0

    enum Format: String, CaseIterable, Codable, Sendable {
        case mp4 = "MP4"
        case mov = "MOV"
        case gif = "GIF"
    }

    enum Resolution: String, CaseIterable, Codable, Sendable {
        case hd720 = "720p"
        case hd1080 = "1080p"
        case uhd4k = "4K"
        case custom = "Custom"

        var width: Int {
            switch self {
            case .hd720: return 1280
            case .hd1080: return 1920
            case .uhd4k: return 3840
            case .custom: return 1920
            }
        }
    }

    var format: Format = .mp4
    var resolution: Resolution = .hd1080
    var fps: Int = 60
    var quality: Double = 0.85
    var customWidth: Int = 1920
    var customHeight: Int = 1080
    /// Fast export: spans where nothing on screen changes are written as one
    /// long-duration frame instead of 60 identical encodes per second. Pixels
    /// are identical; the file is just variable-frame-rate. Off = classic
    /// constant-frame-rate output for editors that dislike VFR.
    var collapseStaticSpans: Bool = true

    init() {}

    // Hand-rolled Codable (house rule): every field decodes with a default so
    // projects saved before a field existed always load.
    private enum CodingKeys: String, CodingKey {
        case format, resolution, fps, quality, customWidth, customHeight
        case collapseStaticSpans
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(Format.self, forKey: .format) ?? .mp4
        resolution = try c.decodeIfPresent(Resolution.self, forKey: .resolution) ?? .hd1080
        fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? 60
        quality = try c.decodeIfPresent(Double.self, forKey: .quality) ?? 0.85
        customWidth = try c.decodeIfPresent(Int.self, forKey: .customWidth) ?? 1920
        customHeight = try c.decodeIfPresent(Int.self, forKey: .customHeight) ?? 1080
        collapseStaticSpans = try c.decodeIfPresent(Bool.self, forKey: .collapseStaticSpans) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(format, forKey: .format)
        try c.encode(resolution, forKey: .resolution)
        try c.encode(fps, forKey: .fps)
        try c.encode(quality, forKey: .quality)
        try c.encode(customWidth, forKey: .customWidth)
        try c.encode(customHeight, forKey: .customHeight)
        try c.encode(collapseStaticSpans, forKey: .collapseStaticSpans)
    }

    var outputWidth: Int {
        resolution == .custom ? customWidth : resolution.width
    }

    var normalizedQuality: Double {
        let clamped = min(max(quality, Self.minimumQuality), Self.maximumQuality)
        return (clamped - Self.minimumQuality) / (Self.maximumQuality - Self.minimumQuality)
    }

    var qualityPresetName: String {
        switch normalizedQuality {
        case ..<0.2:
            return "Draft"
        case ..<0.45:
            return "Good"
        case ..<0.75:
            return "High"
        default:
            return "Master"
        }
    }

    /// The pixel size of the exported file. `sourceSize` is the recording's
    /// natural size — it decides the `.auto` aspect so the file keeps the
    /// exact shape the editor's letterboxed canvas shows (preview == export;
    /// `.auto` used to hardcode 16:9 here, cropping/reframing everything the
    /// editor laid out on a source-shaped canvas).
    func resolvedOutputSize(for aspectRatio: AspectRatio, sourceSize: CGSize) -> CGSize {
        let width = sanitizedDimension(resolution == .custom ? customWidth : resolution.width)

        if resolution == .custom {
            return CGSize(
                width: width,
                height: sanitizedDimension(customHeight)
            )
        }

        let aspect = aspectRatio.canvasAspect(sourceSize: sourceSize)
        return CGSize(
            width: width,
            height: sanitizedDimension(Int(round(width / max(0.01, aspect))))
        )
    }

    func estimatedVideoBitRate(for aspectRatio: AspectRatio, sourceSize: CGSize) -> Int {
        let outputSize = resolvedOutputSize(for: aspectRatio, sourceSize: sourceSize)
        let pixelsPerFrame = Double(outputSize.width * outputSize.height)
        let framesPerSecond = Double(max(1, fps))

        // Use a bits-per-pixel-per-frame curve so quality scales predictably
        // across 720p/1080p/4K and 30/60 fps instead of a flat resolution multiplier.
        let bitsPerPixelPerFrame = 0.08 + pow(normalizedQuality, 1.15) * 0.16
        let targetBitRate = pixelsPerFrame * framesPerSecond * bitsPerPixelPerFrame

        return max(3_000_000, Int(targetBitRate.rounded()))
    }

    func estimatedBitRateDescription(for aspectRatio: AspectRatio, sourceSize: CGSize) -> String {
        let outputSize = resolvedOutputSize(for: aspectRatio, sourceSize: sourceSize)
        let megabitsPerSecond = Double(estimatedVideoBitRate(for: aspectRatio, sourceSize: sourceSize)) / 1_000_000
        let width = Int(outputSize.width)
        let height = Int(outputSize.height)
        let rateText = String(format: "%.1f", megabitsPerSecond)
        return "\(qualityPresetName) • \(width)x\(height) @ \(fps) fps • ~\(rateText) Mbps"
    }

    private func sanitizedDimension(_ value: Int) -> CGFloat {
        let clamped = max(2, value)
        let even = clamped.isMultiple(of: 2) ? clamped : clamped + 1
        return CGFloat(even)
    }
}
