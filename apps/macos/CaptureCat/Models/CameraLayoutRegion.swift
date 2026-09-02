import Foundation

/// How the screen recording and the webcam share the frame during a span of
/// the timeline. Outside every region the project falls back to `.bubble`,
/// which is exactly the camera behaviour CaptureCat has always had.
///
/// Raw values are persistence identity — never rename one (house rule).
enum CameraLayoutMode: String, CaseIterable, Codable, Sendable {
    /// Today's floating bubble over a full-frame screen recording.
    case bubble
    /// Webcam fills the frame; the screen card is hidden. "Talking head".
    case cameraOnly
    /// Screen card and webcam split the frame, screen leading.
    case sideBySide
    /// Webcam hidden; screen recording alone.
    case screenOnly

    var displayName: String {
        switch self {
        case .bubble: return "Bubble"
        case .cameraOnly: return "Camera Only"
        case .sideBySide: return "Side by Side"
        case .screenOnly: return "Screen Only"
        }
    }
}

/// A span of the timeline that overrides the camera/screen arrangement.
/// Regions never overlap (the timeline allocates non-overlapping slots); the
/// first region containing a time wins.
struct CameraLayoutRegion: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    var startTime: TimeInterval
    var endTime: TimeInterval
    var mode: CameraLayoutMode

    var duration: TimeInterval { endTime - startTime }

    init(
        id: UUID = UUID(),
        startTime: TimeInterval,
        endTime: TimeInterval,
        mode: CameraLayoutMode = .cameraOnly
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.mode = mode
    }

    // Hand-rolled Codable (house rule): every field decodes with a default so
    // a project written by an older build always loads.
    private enum CodingKeys: String, CodingKey {
        case id, startTime, endTime, mode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        startTime = try c.decodeIfPresent(TimeInterval.self, forKey: .startTime) ?? 0
        endTime = try c.decodeIfPresent(TimeInterval.self, forKey: .endTime) ?? 0
        mode = try c.decodeIfPresent(CameraLayoutMode.self, forKey: .mode) ?? .cameraOnly
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(startTime, forKey: .startTime)
        try c.encode(endTime, forKey: .endTime)
        try c.encode(mode, forKey: .mode)
    }
}
