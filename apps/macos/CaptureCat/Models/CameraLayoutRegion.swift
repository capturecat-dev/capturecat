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

/// An optional LOOK on a `.bubble` region (docs/camera-cutout.md §1). The
/// looks are deliberately NOT new layout modes: old builds throw on an
/// unknown mode raw value and the whole project vanished from their library,
/// whereas an unknown extra key is ignored — an old build draws the plain
/// bubble, a safe fallback.
///
/// Raw values are persistence identity — never rename one (house rule).
enum CameraBubbleLook: String, CaseIterable, Codable, Sendable {
    /// The webcam with its background removed, standing directly over the
    /// screen recording. No card, ring or stroke.
    case cutout = "cutout"
    /// The cut-out person on a rounded gradient card; the head breaks out
    /// above the card's top edge.
    case popOut = "popOut"

    var displayName: String {
        switch self {
        case .cutout: return "Cutout"
        case .popOut: return "Pop-out card"
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
    /// Cutout / pop-out card. Only takes effect while `mode == .bubble`; on
    /// any other mode it is ignored but KEPT (switching the block back to
    /// Bubble restores the look). nil = the plain bubble.
    var look: CameraBubbleLook?

    var duration: TimeInterval { endTime - startTime }

    /// The look this region actually draws: its `look` when it is a Bubble
    /// block, else none (CameraLayoutMath.lookWeights reads this).
    var effectiveLook: CameraBubbleLook? { mode == .bubble ? look : nil }

    init(
        id: UUID = UUID(),
        startTime: TimeInterval,
        endTime: TimeInterval,
        mode: CameraLayoutMode = .cameraOnly,
        look: CameraBubbleLook? = nil
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.mode = mode
        self.look = look
    }

    // Hand-rolled Codable (house rule): every field decodes with a default so
    // a project written by an older build always loads.
    private enum CodingKeys: String, CodingKey {
        case id, startTime, endTime, mode, look
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        startTime = try c.decodeIfPresent(TimeInterval.self, forKey: .startTime) ?? 0
        endTime = try c.decodeIfPresent(TimeInterval.self, forKey: .endTime) ?? 0
        // The raw value as a STRING (docs/camera-cutout.md §1): missing or
        // null → Camera Only, as always; a string that is not a known mode —
        // one from a newer build — → Bubble instead of throwing (a throw here
        // failed the whole Project decode and the project vanished from the
        // library). A non-string still throws, as it always did.
        if let raw = try c.decodeIfPresent(String.self, forKey: .mode) {
            mode = CameraLayoutMode(rawValue: raw) ?? .bubble
        } else {
            mode = .cameraOnly
        }
        // Lenient: missing, null, unknown or mistyped → nil (plain bubble).
        look = (try? c.decodeIfPresent(CameraBubbleLook.self, forKey: .look)) ?? nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(startTime, forKey: .startTime)
        try c.encode(endTime, forKey: .endTime)
        try c.encode(mode, forKey: .mode)
        // Only when set — untouched projects stay byte-identical.
        try c.encodeIfPresent(look, forKey: .look)
    }
}
