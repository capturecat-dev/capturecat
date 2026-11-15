import Foundation
import CoreGraphics

struct CursorRecording: Codable, Sendable {
    let version: Int
    let coordinateWidth: CGFloat
    let coordinateHeight: CGFloat
    let events: [CursorEvent]

    var coordinateSize: CGSize {
        CGSize(width: coordinateWidth, height: coordinateHeight)
    }

    var hasValidCoordinateSpace: Bool {
        coordinateWidth > 0 && coordinateHeight > 0
    }
}

extension CursorRecording {
    /// Reads a cursor.json written by `CursorTracker.save(to:)`. Recordings
    /// from before the coordinate space was stored are a bare event array:
    /// they load as version 1 with no coordinate space.
    static func load(from url: URL) throws -> CursorRecording {
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(CursorRecording.self, from: data)
        } catch {
            if let events = try? JSONDecoder().decode([CursorEvent].self, from: data) {
                return CursorRecording(
                    version: 1,
                    coordinateWidth: 0,
                    coordinateHeight: 0,
                    events: events
                )
            }
            throw error
        }
    }
}
