import Foundation
import CoreGraphics

/// Reactive camera placement: the bubble shrinks as the screen zooms in
/// (so the zoomed content has more breathing room) and grows back to its
/// base size as the zoom releases. The chosen corner never changes.
///
/// Both the editor preview and the video exporter feed this helper the same
/// (already-smoothed) zoom value, so the camera animates in lockstep with the
/// zoom and the exported file matches the preview frame-for-frame.
enum ReactiveCameraLayout {
    /// 0 at zoom ≤ 1, ramps smoothly to 1 by zoom = 1.5, stays at 1 above.
    /// Smoothstep gives ease-in/ease-out without needing another spring.
    static func envelope(forZoom zoom: Double) -> Double {
        let t = max(0, min(1, (zoom - 1.0) / 0.5))
        return t * t * (3 - 2 * t)
    }

    /// Camera size at full envelope, expressed as a fraction of base size.
    /// 0.75 = noticeable shrink without the bubble disappearing.
    static let minSizeFactor: Double = 0.75

    /// The rect aspect a camera SHAPE permits: circle and square are always
    /// 1:1 — the video aspect-fills the bubble — while the rounded-rect AND
    /// the squircle (a landscape superellipse tile, like a TV/app-icon shape)
    /// follow the video's real aspect. Both renderers and the drag overlay
    /// MUST route their aspect through here; feeding the raw video aspect to
    /// a circle is what turns it into an ellipse.
    /// The squircle tile's aspect is CAPPED: a raw 16:9 webcam makes the
    /// superellipse squat, so the tile leans toward the reference TV shape
    /// (~1.2:1) and the video aspect-fills it. Portrait sources cap likewise.
    static let squircleMaxAspect: Double = 1.2
    /// Forced-portrait tile aspect (`cameraOrientation == .vertical`): 4:5,
    /// the tall reference tile. The webcam aspect-fills it.
    static let verticalAspect: Double = 0.8

    static func shapeAspect(
        shape: ProjectSettings.CameraShape,
        videoAspect: Double,
        orientation: ProjectSettings.CameraOrientation
    ) -> Double {
        switch shape {
        case .circle, .square:
            // Always 1:1 — orientation never applies (the inspector hides
            // the control for these shapes).
            return 1
        case .roundedRect, .squircle:
            switch orientation {
            case .vertical:
                // Forced portrait tile regardless of the source aspect.
                return verticalAspect
            case .wide:
                // Forced landscape tile at the reference cap.
                return squircleMaxAspect
            case .auto:
                break
            }
            if shape == .roundedRect { return videoAspect }
            return videoAspect >= 1
                ? min(videoAspect, squircleMaxAspect)
                : max(videoAspect, 1 / squircleMaxAspect)
        }
    }

    /// Bubble dimensions for a given base size and video aspect. `baseSize`
    /// always controls the LONGER side, so the user's size slider behaves the
    /// same for landscape webcams and portrait phone screens.
    static func bubbleSize(baseSize: Double, aspect: Double) -> CGSize {
        let size = max(1, baseSize)
        let safeAspect = max(0.01, aspect)
        return safeAspect >= 1
            ? CGSize(width: size, height: size / safeAspect)   // landscape / square
            : CGSize(width: size * safeAspect, height: size)   // portrait
    }

    /// Compute the camera rect inside `contentRect`. The corner is fixed by
    /// `basePosition`; only the size shrinks/grows with the zoom envelope.
    ///
    /// - Parameters:
    ///   - contentRect: the area to position the camera within. For both
    ///     preview and export this is the video card area (canvas minus
    ///     background padding) in that environment's coordinate space.
    ///   - basePosition: user-chosen camera corner.
    ///   - baseSize: camera size (longer side) at 1× zoom, in `contentRect` units.
    ///   - zoom: current smoothed zoom level (1.0 = no zoom).
    ///   - padding: distance the camera keeps from the content edges.
    ///   - aspect: camera video aspect (width / height); 1 = square bubble.
    ///   - yAxisIsUp: true for CIImage / CoreGraphics flipped contexts (the
    ///     exporter), false for SwiftUI / AppKit (the preview).
    /// Camera Size is tuned in points on a nominal 1456×728 canvas. This
    /// converts it to the CURRENT canvas so the bubble keeps its relative
    /// footprint when the window (and therefore the preview canvas) resizes.
    /// The exporter applies the same factor to project.previewCanvasSize
    /// before its own output scaling, so preview and file stay identical.
    static func canvasFitScale(for canvas: CGSize) -> CGFloat {
        guard canvas.width > 0, canvas.height > 0 else { return 1 }
        return min(canvas.width / 1456, canvas.height / 728)
    }

    /// Normalized (0…1, Y-down) placement for a corner — the corner enum is
    /// just the four extremes of the free-position space.
    static func fraction(for position: ProjectSettings.CameraPosition) -> CGPoint {
        switch position {
        case .topLeft: return CGPoint(x: 0, y: 0)
        case .topRight: return CGPoint(x: 1, y: 0)
        case .bottomLeft: return CGPoint(x: 0, y: 1)
        case .bottomRight: return CGPoint(x: 1, y: 1)
        }
    }

    static func cameraRect(
        in contentRect: CGRect,
        basePosition: ProjectSettings.CameraPosition,
        customPosition: CGPoint? = nil,
        baseSize: Double,
        zoom: Double,
        padding: Double,
        aspect: Double = 1,
        yAxisIsUp: Bool
    ) -> CGRect {
        let env = envelope(forZoom: zoom)
        let sizeFactor = 1.0 - (1.0 - minSizeFactor) * env
        let size = bubbleSize(baseSize: baseSize * sizeFactor, aspect: aspect)

        // Free placement interpolates the origin across the padded usable
        // area; the legacy corners are exactly f = 0/1. `customPosition` is
        // Y-down (SwiftUI) — mirrored for Y-up (CIImage) consumers so the
        // preview and export land on the identical spot.
        let f = customPosition.map {
            CGPoint(x: min(1, max(0, $0.x)), y: min(1, max(0, $0.y)))
        } ?? fraction(for: basePosition)
        let fy = yAxisIsUp ? 1 - f.y : f.y

        let usableW = contentRect.width - 2 * padding - size.width
        let usableH = contentRect.height - 2 * padding - size.height
        let originX = contentRect.minX + padding + max(0, usableW) * f.x
        let originY = contentRect.minY + padding + max(0, usableH) * fy

        return CGRect(x: originX, y: originY, width: size.width, height: size.height)
    }
}
