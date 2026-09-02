import Foundation
import CoreGraphics

struct HighlightRegion: Identifiable, Codable, Sendable {
    static let previewCornerRadius: CGFloat = 16
    static let cornerRadiusRatio: CGFloat = 0.12

    let id: UUID
    var startTime: TimeInterval
    var endTime: TimeInterval
    var label: String
    /// Normalized rect (0...1) relative to the visible video frame, stored in top-left view coordinates.
    var rect: CGRect
    /// Outside dim amount (0...1). Higher values make the surrounding video darker.
    var opacity: Double

    var duration: TimeInterval { endTime - startTime }

    init(
        id: UUID = UUID(),
        startTime: TimeInterval,
        endTime: TimeInterval,
        label: String = "Highlight",
        rect: CGRect = CGRect(x: 0.2, y: 0.18, width: 0.42, height: 0.2),
        opacity: Double = 0.55
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.label = label
        self.rect = rect
        self.opacity = opacity
    }

    enum CodingKeys: String, CodingKey {
        case id, startTime, endTime, label, opacity
        case rectX, rectY, rectW, rectH
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        startTime = try c.decode(TimeInterval.self, forKey: .startTime)
        endTime = try c.decode(TimeInterval.self, forKey: .endTime)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? "Highlight"
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 0.55
        let rx = try c.decodeIfPresent(CGFloat.self, forKey: .rectX) ?? 0.2
        let ry = try c.decodeIfPresent(CGFloat.self, forKey: .rectY) ?? 0.18
        let rw = try c.decodeIfPresent(CGFloat.self, forKey: .rectW) ?? 0.42
        let rh = try c.decodeIfPresent(CGFloat.self, forKey: .rectH) ?? 0.2
        rect = CGRect(x: rx, y: ry, width: rw, height: rh)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(startTime, forKey: .startTime)
        try c.encode(endTime, forKey: .endTime)
        try c.encode(label, forKey: .label)
        try c.encode(opacity, forKey: .opacity)
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

    static func cornerRadius(for rect: CGRect, in containerRect: CGRect) -> CGFloat {
        let pixelMinDimension = min(rect.width * containerRect.width, rect.height * containerRect.height)
        return min(
            pixelMinDimension / 2,
            max(6, min(pixelMinDimension * Self.cornerRadiusRatio, 24))
        )
    }

    func cornerRadius(in containerRect: CGRect) -> CGFloat {
        Self.cornerRadius(for: rect, in: containerRect)
    }

    var dimOpacity: CGFloat {
        CGFloat(max(0.05, min(0.95, opacity)))
    }
}
