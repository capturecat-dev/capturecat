import Foundation
import CoreGraphics

/// Blur region look. Raw values are persistence identity — never rename one
/// (old projects must always still load).
enum BlurStyle: String, CaseIterable, Codable, Sendable {
    case blur = "Blur"
    case pixelate = "Pixelate"
}

struct BlurRegion: Identifiable, Codable, Sendable {
    static let previewCornerRadius: CGFloat = 0

    let id: UUID
    var startTime: TimeInterval
    var endTime: TimeInterval
    var label: String
    /// Normalized rect (0...1) relative to the visible video frame, stored in top-left view coordinates.
    var rect: CGRect
    /// Blur intensity (0...1), where 1 is maximum blur — the "Strength"
    /// slider drives this for BOTH styles.
    var intensity: Double
    /// Blurred (gaussian) or Pixelated (mosaic censor look).
    var style: BlurStyle
    /// Animated mosaic: the block grid jitters per BlurStyleMath's quantized
    /// timeline step. Meaningful only for `.pixelate`.
    var animated: Bool

    var duration: TimeInterval { endTime - startTime }

    init(
        id: UUID = UUID(),
        startTime: TimeInterval,
        endTime: TimeInterval,
        label: String = "Blur",
        rect: CGRect = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.15),
        intensity: Double = 0.6,
        style: BlurStyle = .blur,
        animated: Bool = false
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.label = label
        self.rect = rect
        self.intensity = intensity
        self.style = style
        self.animated = animated
    }

    enum CodingKeys: String, CodingKey {
        case id, startTime, endTime, label, intensity, style, animated
        case rectX, rectY, rectW, rectH
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        startTime = try c.decode(TimeInterval.self, forKey: .startTime)
        endTime = try c.decode(TimeInterval.self, forKey: .endTime)
        label = try c.decode(String.self, forKey: .label)
        intensity = try c.decodeIfPresent(Double.self, forKey: .intensity) ?? 0.6
        style = try c.decodeIfPresent(BlurStyle.self, forKey: .style) ?? .blur
        animated = try c.decodeIfPresent(Bool.self, forKey: .animated) ?? false
        let rx = try c.decodeIfPresent(CGFloat.self, forKey: .rectX) ?? 0.3
        let ry = try c.decodeIfPresent(CGFloat.self, forKey: .rectY) ?? 0.3
        let rw = try c.decodeIfPresent(CGFloat.self, forKey: .rectW) ?? 0.4
        let rh = try c.decodeIfPresent(CGFloat.self, forKey: .rectH) ?? 0.15
        rect = CGRect(x: rx, y: ry, width: rw, height: rh)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(startTime, forKey: .startTime)
        try c.encode(endTime, forKey: .endTime)
        try c.encode(label, forKey: .label)
        try c.encode(intensity, forKey: .intensity)
        try c.encode(style, forKey: .style)
        try c.encode(animated, forKey: .animated)
        try c.encode(rect.origin.x, forKey: .rectX)
        try c.encode(rect.origin.y, forKey: .rectY)
        try c.encode(rect.size.width, forKey: .rectW)
        try c.encode(rect.size.height, forKey: .rectH)
    }

    func rectInViewSpace(in containerRect: CGRect) -> CGRect {
        CGRect(
            x: containerRect.minX + rect.origin.x * containerRect.width,
            y: containerRect.minY + rect.origin.y * containerRect.height,
            width: rect.width * containerRect.width,
            height: rect.height * containerRect.height
        )
    }

    func rectInImageSpace(in containerRect: CGRect) -> CGRect {
        CGRect(
            x: containerRect.minX + rect.origin.x * containerRect.width,
            y: containerRect.maxY - (rect.origin.y + rect.height) * containerRect.height,
            width: rect.width * containerRect.width,
            height: rect.height * containerRect.height
        )
    }

    func blurRadius(in containerSize: CGSize) -> CGFloat {
        let blurWidth = rect.width * containerSize.width
        let blurHeight = rect.height * containerSize.height
        let maxBlur = max(blurWidth, blurHeight) * 0.18
        let clampedIntensity = CGFloat(max(0.1, min(1.0, intensity)))
        return min(36, max(6, maxBlur * clampedIntensity))
    }
}
