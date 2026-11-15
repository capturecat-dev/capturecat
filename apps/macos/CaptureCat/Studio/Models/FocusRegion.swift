import CoreGraphics
import Foundation

/// Depth Focus mode. Raw values are persistence identity — never rename one
/// (old projects must always still load).
enum FocusRegionStyle: String, CaseIterable, Codable, Sendable {
    /// The rect stays sharp; blur ramps outward from its rounded edge.
    case area = "Area"
    /// Planar tilt-shift: a sharp BAND through the rect's centre at `angle`,
    /// blur growing with perpendicular distance from the band.
    case tiltShift = "Tilt Shift"
}

/// Depth-of-field focus region — the highlight's sibling with BLUR instead of
/// dim: inside stays sharp, outside falls into a graduated blur whose profile
/// lives in `FocusMath` (shared by preview and exporter).
struct FocusRegion: Identifiable, Codable, Sendable {
    let id: UUID
    var startTime: TimeInterval
    var endTime: TimeInterval
    var label: String
    /// Normalized rect (0...1) relative to the visible video frame, stored in
    /// top-left view coordinates (same convention as Highlight/Blur regions).
    var rect: CGRect
    /// Max blur strength 0...1 ("Blur Strength").
    var intensity: Double
    /// Gradient band width 0...1 ("Focus Falloff": narrow = hard edge).
    var falloff: Double
    var style: FocusRegionStyle
    /// Tilt-shift band angle in degrees (−90…90), ignored for `.area`.
    var angle: Double
    /// Corner rounding of the sharp area, 0…1 of half the rect's short side
    /// (0 = sharp corners, 1 = capsule). Ignored for `.tiltShift`.
    var cornerRadius: Double

    var duration: TimeInterval { endTime - startTime }

    init(
        id: UUID = UUID(),
        startTime: TimeInterval,
        endTime: TimeInterval,
        label: String = "Focus",
        rect: CGRect = CGRect(x: 0.28, y: 0.3, width: 0.44, height: 0.34),
        intensity: Double = 0.7,
        falloff: Double = 0.45,
        style: FocusRegionStyle = .area,
        angle: Double = 0,
        cornerRadius: Double = FocusMath.defaultCornerRadius
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.label = label
        self.rect = rect
        self.intensity = intensity
        self.falloff = falloff
        self.style = style
        self.angle = angle
        self.cornerRadius = cornerRadius
    }

    enum CodingKeys: String, CodingKey {
        case id, startTime, endTime, label, intensity, falloff, style, angle, cornerRadius
        case rectX, rectY, rectW, rectH
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        startTime = try c.decode(TimeInterval.self, forKey: .startTime)
        endTime = try c.decode(TimeInterval.self, forKey: .endTime)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? "Focus"
        intensity = try c.decodeIfPresent(Double.self, forKey: .intensity) ?? 0.7
        falloff = try c.decodeIfPresent(Double.self, forKey: .falloff) ?? 0.45
        style = try c.decodeIfPresent(FocusRegionStyle.self, forKey: .style) ?? .area
        angle = try c.decodeIfPresent(Double.self, forKey: .angle) ?? 0
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius)
            ?? FocusMath.defaultCornerRadius
        let rx = try c.decodeIfPresent(CGFloat.self, forKey: .rectX) ?? 0.28
        let ry = try c.decodeIfPresent(CGFloat.self, forKey: .rectY) ?? 0.3
        let rw = try c.decodeIfPresent(CGFloat.self, forKey: .rectW) ?? 0.44
        let rh = try c.decodeIfPresent(CGFloat.self, forKey: .rectH) ?? 0.34
        rect = CGRect(x: rx, y: ry, width: rw, height: rh)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(startTime, forKey: .startTime)
        try c.encode(endTime, forKey: .endTime)
        try c.encode(label, forKey: .label)
        try c.encode(intensity, forKey: .intensity)
        try c.encode(falloff, forKey: .falloff)
        try c.encode(style, forKey: .style)
        try c.encode(angle, forKey: .angle)
        try c.encode(cornerRadius, forKey: .cornerRadius)
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
}
