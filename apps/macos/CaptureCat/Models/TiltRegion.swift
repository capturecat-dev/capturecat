import Foundation

/// A timeline span during which the screen card is skewed in 3D. The card
/// springs into the skew at the region start and back flat at the end, using
/// the same spring response as zoom transitions. Lives on its own track so it
/// can overlap zoom regions (skew composes with zoom).
struct TiltRegion: Identifiable, Codable, Sendable {
    let id: UUID
    var startTime: TimeInterval
    var endTime: TimeInterval
    /// Vertical tilt (pitch): positive tips the top edge back.
    var pitch: Double
    /// Horizontal tilt (yaw): positive tips the left edge back.
    var yaw: Double
    /// In-plane rotation: positive rotates clockwise.
    var roll: Double
    /// Per-block animation style (shared enum with zoom blocks); nil = the
    /// project default. Optional, so old projects decode untouched.
    var animationStyle: ZoomAnimationStyle?

    var duration: TimeInterval { endTime - startTime }

    init(
        id: UUID = UUID(),
        startTime: TimeInterval,
        endTime: TimeInterval,
        pitch: Double = 20,
        yaw: Double = 0,
        roll: Double = 0,
        animationStyle: ZoomAnimationStyle? = nil
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.pitch = pitch
        self.yaw = yaw
        self.roll = roll
        self.animationStyle = animationStyle
    }
}
