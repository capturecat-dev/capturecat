import Foundation

struct VoiceOverClip: Identifiable, Codable, Equatable {
    let id: UUID
    var fileName: String
    var startTime: TimeInterval
    var sourceStartTime: TimeInterval
    var duration: TimeInterval
    var sourceDuration: TimeInterval
    var gain: Double
    var label: String

    init(
        id: UUID = UUID(),
        fileName: String,
        startTime: TimeInterval,
        sourceStartTime: TimeInterval = 0,
        duration: TimeInterval,
        sourceDuration: TimeInterval? = nil,
        gain: Double = 1.0,
        label: String = "Voice Over"
    ) {
        self.id = id
        self.fileName = fileName
        self.startTime = startTime
        self.sourceStartTime = max(0, sourceStartTime)
        self.duration = duration
        self.sourceDuration = max(duration, sourceDuration ?? duration)
        self.gain = gain
        self.label = label
    }

    var endTime: TimeInterval {
        startTime + duration
    }

    var sourceEndTime: TimeInterval {
        sourceStartTime + duration
    }

    enum CodingKeys: String, CodingKey {
        case id
        case fileName
        case startTime
        case sourceStartTime
        case duration
        case sourceDuration
        case gain
        case label
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        fileName = try c.decode(String.self, forKey: .fileName)
        startTime = try c.decode(TimeInterval.self, forKey: .startTime)
        duration = try c.decode(TimeInterval.self, forKey: .duration)
        sourceStartTime = max(0, try c.decodeIfPresent(TimeInterval.self, forKey: .sourceStartTime) ?? 0)
        sourceDuration = max(duration, try c.decodeIfPresent(TimeInterval.self, forKey: .sourceDuration) ?? duration)
        gain = try c.decodeIfPresent(Double.self, forKey: .gain) ?? 1.0
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? "Voice Over"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(fileName, forKey: .fileName)
        try c.encode(startTime, forKey: .startTime)
        try c.encode(sourceStartTime, forKey: .sourceStartTime)
        try c.encode(duration, forKey: .duration)
        try c.encode(sourceDuration, forKey: .sourceDuration)
        try c.encode(gain, forKey: .gain)
        try c.encode(label, forKey: .label)
    }

    func resolvedURL(in projectDirectory: URL) -> URL {
        projectDirectory.appendingPathComponent(fileName)
    }

    mutating func clamp(to totalDuration: TimeInterval) {
        sourceStartTime = max(0, min(sourceStartTime, max(0, sourceDuration - 0.1)))
        sourceDuration = max(duration, sourceDuration)
        startTime = max(0, min(startTime, totalDuration))
        let maxVisibleDuration = max(0.1, sourceDuration - sourceStartTime)
        duration = max(0.1, min(duration, max(0.1, min(totalDuration - startTime, maxVisibleDuration))))
        gain = max(0, min(gain, 2))
    }
}
