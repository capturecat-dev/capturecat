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
