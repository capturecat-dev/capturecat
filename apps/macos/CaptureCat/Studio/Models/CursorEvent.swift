import Foundation
import CoreGraphics

struct CursorEvent: Codable, Sendable {
    let timestamp: TimeInterval
    let x: CGFloat
    let y: CGFloat
    let isClick: Bool

    var point: CGPoint { CGPoint(x: x, y: y) }
}

struct CursorOverlayLayout: Sendable {
    static let shadowOffset = CGSize(width: 0, height: 1)
    static let shadowBlurRadius: CGFloat = 2
    static let shadowOpacity: CGFloat = 0.3

    let imageRect: CGRect
    /// Where the hotspot lands, in the same space as `imageRect`.
    ///
    /// Carried explicitly rather than recomputed by callers: the hotspot is the
    /// only point that has to be pixel-accurate, and deriving it from the rect
    /// requires knowing both `hotSpot` and `renderedScale`, which only this
    /// type has. A verification that measures the rect's CENTRE instead reports
    /// a constant `halfSize - hotSpot` error on a correct renderer.
    let hotspotPoint: CGPoint

    var center: CGPoint {
        CGPoint(x: imageRect.midX, y: imageRect.midY)
    }

    func imageSpaceRect(in canvasHeight: CGFloat) -> CGRect {
        CGRect(
            x: imageRect.minX,
            y: canvasHeight - imageRect.maxY,
            width: imageRect.width,
            height: imageRect.height
        )
    }

    static func resolveCoordinateSize(
        recordedSize: CGSize,
        fallbackSourceSize: CGSize
    ) -> CGSize {
        if recordedSize.width > 0, recordedSize.height > 0 {
            return recordedSize
        }
        return CGSize(
            width: max(1, fallbackSourceSize.width / 2),
            height: max(1, fallbackSourceSize.height / 2)
        )
    }

    static func viewRect(from imageRect: CGRect, canvasHeight: CGFloat) -> CGRect {
        CGRect(
            x: imageRect.minX,
            y: canvasHeight - imageRect.maxY,
            width: imageRect.width,
            height: imageRect.height
        )
    }

    static func make(
        cursorPosition: CGPoint,
        coordinateSize: CGSize,
        videoRect: CGRect,
        cursorSize: CGSize,
        hotSpot: CGPoint,
        cursorScale: Double
    ) -> CursorOverlayLayout? {
        let displayWidth = coordinateSize.width
        let displayHeight = coordinateSize.height
        guard displayWidth > 0,
              displayHeight > 0,
              videoRect.width > 0,
              videoRect.height > 0,
              cursorSize.width > 0,
              cursorSize.height > 0 else {
            return nil
        }

        let normalizedX = max(0, min(1, cursorPosition.x / displayWidth))
        let normalizedY = max(0, min(1, cursorPosition.y / displayHeight))
        let cursorPointToViewScale = min(
            videoRect.width / max(1, displayWidth),
            videoRect.height / max(1, displayHeight)
        )
        let renderedScale = CGFloat(cursorScale) * cursorPointToViewScale
        let cursorWidth = cursorSize.width * renderedScale
        let cursorHeight = cursorSize.height * renderedScale
        let hotspotX = videoRect.minX + videoRect.width * normalizedX
        let hotspotY = videoRect.minY + videoRect.height * normalizedY

        return CursorOverlayLayout(
            imageRect: CGRect(
                x: hotspotX - hotSpot.x * renderedScale,
                y: hotspotY - hotSpot.y * renderedScale,
                width: cursorWidth,
                height: cursorHeight
            ),
            hotspotPoint: CGPoint(x: hotspotX, y: hotspotY)
        )
    }
}
