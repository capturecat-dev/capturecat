import CoreGraphics
import Foundation

/// The value math of the inspector's 2D pads, shared by the Mac pad controls
/// and the iOS pads (Studio 4d). Each pad maps a touch to a FRACTION in its
/// own geometry (insets, knob size — drawing, per platform) and hands it here;
/// everything that decides what is written — snapping, clamping, magnetism,
/// rounding — lives in this one copy.
enum InspectorPadMath {

    // MARK: - Placement (Background ▸ Frame)

    /// Card anchor fractions (x, y), Y-down — the pad's nine dots.
    static let placementFractions: [ProjectSettings.VideoPlacement: (x: CGFloat, y: CGFloat)] = [
        .topLeft: (0, 0), .top: (0.5, 0), .topRight: (1, 0),
        .left: (0, 0.5), .center: (0.5, 0.5), .right: (1, 0.5),
        .bottomLeft: (0, 1), .bottom: (0.5, 1), .bottomRight: (1, 1),
    ]

    /// The placement a touch at (fx, fy) of the pad's bounds picks: each axis
    /// snaps to thirds.
    static func placement(atFraction fx: CGFloat, _ fy: CGFloat) -> ProjectSettings.VideoPlacement? {
        func step(_ f: CGFloat) -> CGFloat { f < 1.0 / 3 ? 0 : (f > 2.0 / 3 ? 1 : 0.5) }
        let x = step(fx), y = step(fy)
        return placementFractions.first(where: { $0.value == (x, y) })?.key
    }

    // MARK: - Camera bubble (Camera ▸ pad)

    /// Drag: the bubble centre's fraction of the pad's usable travel.
    @MainActor
    static func cameraDrag(_ settings: ProjectSettings, fx: CGFloat, fy: CGFloat) {
        settings.cameraCustomX = Double(min(1, max(0, fx)))
        settings.cameraCustomY = Double(min(1, max(0, fy)))
    }

    /// The pad's mini bubble diameter for a camera size (nominal-canvas pt).
    static func cameraBubbleDiameter(cameraSize: Double) -> CGFloat {
        20 + CGFloat((cameraSize - 120) / 200) * 26
    }

    /// Where the pad draws the bubble centre (custom fraction, else the corner's).
    @MainActor
    static func cameraFraction(_ settings: ProjectSettings) -> CGPoint {
        if let x = settings.cameraCustomX, let y = settings.cameraCustomY {
            return CGPoint(x: x, y: y)
        }
        return ReactiveCameraLayout.fraction(for: settings.cameraPosition)
    }

    /// Release: near a corner (±0.08) collapses to the clean corner enum.
    @MainActor
    static func cameraRelease(_ settings: ProjectSettings) {
        guard let x = settings.cameraCustomX, let y = settings.cameraCustomY else { return }
        for corner in ProjectSettings.CameraPosition.allCases {
            let f = ReactiveCameraLayout.fraction(for: corner)
            if abs(f.x - x) < 0.08 && abs(f.y - y) < 0.08 {
                settings.cameraPosition = corner
                settings.cameraCustomX = nil
                settings.cameraCustomY = nil
                return
            }
        }
    }

    // MARK: - Subtitles (Subtitles ▸ Style pad)

    @MainActor
    static func subtitleDrag(_ settings: ProjectSettings, fx: CGFloat, fy: CGFloat) {
        settings.subtitleCustomX = Double(min(1, max(0, fx)))
        settings.subtitleCustomY = Double(min(1, max(0, fy)))
    }

    /// Release: centred (±0.08) on a stock anchor's height snaps to it.
    @MainActor
    static func subtitleRelease(_ settings: ProjectSettings) {
        guard let x = settings.subtitleCustomX, let y = settings.subtitleCustomY,
              abs(x - 0.5) < 0.08 else { return }
        let anchors: [(ProjectSettings.SubtitlePosition, Double)] = [(.top, 0), (.center, 0.5), (.bottom, 1)]
        for (anchor, fy) in anchors where abs(y - fy) < 0.08 {
            settings.subtitlePosition = anchor
            settings.subtitleCustomX = nil
            settings.subtitleCustomY = nil
            return
        }
    }

    /// Where the pad draws the pill (custom fraction, else the anchor's).
    @MainActor
    static func subtitleFraction(_ settings: ProjectSettings) -> CGPoint {
        if let x = settings.subtitleCustomX, let y = settings.subtitleCustomY {
            return CGPoint(x: min(1, max(0, x)), y: min(1, max(0, y)))
        }
        switch settings.subtitlePosition {
        case .top: return CGPoint(x: 0.5, y: 0)
        case .center: return CGPoint(x: 0.5, y: 0.5)
        case .bottom: return CGPoint(x: 0.5, y: 1)
        }
    }

    // MARK: - Watermark (Brand ▸ Position pad)

    @MainActor
    static func watermarkDrag(_ settings: ProjectSettings, fx: CGFloat, fy: CGFloat) {
        settings.watermarkX = Double(min(1, max(0, fx)))
        settings.watermarkY = Double(min(1, max(0, fy)))
    }

    /// Release: per-axis edge/corner magnetism (±0.06).
    @MainActor
    static func watermarkRelease(_ settings: ProjectSettings) {
        if abs(settings.watermarkX) < 0.06 { settings.watermarkX = 0 }
        if abs(settings.watermarkX - 1) < 0.06 { settings.watermarkX = 1 }
        if abs(settings.watermarkY) < 0.06 { settings.watermarkY = 0 }
        if abs(settings.watermarkY - 1) < 0.06 { settings.watermarkY = 1 }
    }

    /// The pad's mini logo width tracks Size (40…400 px → 12…56 pt).
    static func watermarkMarkWidth(size: Double) -> CGFloat {
        let t = (min(400, max(40, size)) - 40) / 360
        return 12 + CGFloat(t) * 44
    }

    // MARK: - Tilt (Effects ▸ Tilt, Camera ▸ Style)

    /// A drag at (fx, fy) of the pad's half-extents — x right, y UP, each
    /// −1…1 — as whole degrees of (pitch, yaw) within ±maxAngle.
    static func tiltAngles(fx: Double, fy: Double, maxAngle: Double) -> (pitch: Double, yaw: Double) {
        let yaw = (max(-1, min(1, fx)) * maxAngle).rounded()
        let pitch = (max(-1, min(1, fy)) * maxAngle).rounded()
        return (pitch, yaw)
    }

    /// Where the knob sits for (pitch, yaw), as a fraction of the pad (Y-down).
    static func tiltKnobFraction(pitch: Double, yaw: Double, maxAngle: Double) -> CGPoint {
        CGPoint(x: 0.5 + CGFloat(yaw / maxAngle) * 0.5, y: 0.5 - CGFloat(pitch / maxAngle) * 0.5)
    }

    // MARK: - Zoom focus / card offset (Effects ▸ Zoom)

    static func focal(fx: CGFloat, fy: CGFloat) -> CGPoint {
        CGPoint(x: min(1, max(0, fx)), y: min(1, max(0, fy)))
    }

    /// Offset pad 0…1 → card excursion over the full ±cardOffsetLimit range
    /// (shared with the canvas drag clamp; a tighter mapping would silently
    /// truncate a wide drag the moment the pad is touched). Dead centre
    /// (±0.02) means none (nil).
    static func cardOffset(padPoint point: CGPoint) -> (x: Double?, y: Double?) {
        let limit = ZoomFocalMath.cardOffsetLimit
        let dx = (Double(point.x) - 0.5) * 2 * limit
        let dy = (Double(point.y) - 0.5) * 2 * limit
        let none = abs(dx) < 0.02 && abs(dy) < 0.02
        return (none ? nil : dx, none ? nil : dy)
    }

    static func padPoint(cardOffsetX x: Double?, y: Double?) -> CGPoint {
        CGPoint(
            x: (x ?? 0) / (2 * ZoomFocalMath.cardOffsetLimit) + 0.5,
            y: (y ?? 0) / (2 * ZoomFocalMath.cardOffsetLimit) + 0.5
        )
    }
}
