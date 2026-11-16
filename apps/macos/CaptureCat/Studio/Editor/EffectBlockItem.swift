import Foundation

/// One block on the EFFECTS lane. It is a *presentation* over the existing
/// model: up to one ZoomRegion and up to one co-spanning TiltRegion. The two
/// arrays stay separate on disk (both renderers read them independently) — this
/// struct only describes what a single lane block should draw and edit.
struct EffectBlockItem: Identifiable, Equatable {
    /// Regions whose spans differ by less than this present as ONE block.
    static let linkEpsilon: TimeInterval = 0.02

    var zoomID: UUID?
    var tiltID: UUID?
    /// Output-time span (already mapped through the speed time map).
    var startTime: TimeInterval
    var endTime: TimeInterval
    var zoomLevel: Double?
    var pitch: Double
    var yaw: Double
    var roll: Double

    var id: UUID { zoomID ?? tiltID ?? UUID() }
    var hasZoom: Bool { zoomID != nil }
    var hasTilt: Bool { tiltID != nil }
    /// The project's Slide rides this block (its span matches) — rendered as
    /// one linked block with a slide icon.
    var hasSlide = false

    /// The dominant tilt angle, for the compact label.
    var dominantAngle: Double {
        [pitch, yaw, roll].max(by: { abs($0) < abs($1) }) ?? 0
    }
}
