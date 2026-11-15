import Foundation

struct VideoSpeedRegion: Identifiable, Codable, Sendable {
    let id: UUID
    var startTime: TimeInterval
    var endTime: TimeInterval
    var speed: Double

    var duration: TimeInterval { endTime - startTime }

    init(
        id: UUID = UUID(),
        startTime: TimeInterval,
        endTime: TimeInterval,
        speed: Double = 2.0
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.speed = speed
    }
}
