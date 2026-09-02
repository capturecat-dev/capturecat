import Foundation
import CoreGraphics

/// Dynamic camera layouts: resolves the screen/camera arrangement at a time,
/// INTERPOLATED across mode boundaries so a switch reads as a smooth morph
/// rather than a cut.
///
/// Shared source of truth (house rule #2): the preview compositor and the
/// exporter both call `resolve` with their OWN card rect and bubble rect, and
/// consume the identical output. Everything here is derived from timeline
/// position only — never a wall clock — so scrubbing, playback and export
/// agree frame for frame (the lesson `DeviceSegmentDip` documents).
///
/// The card squeeze is expressed as a UNIFORM SCALE plus an X-ONLY
/// translation about the card's centre. That is deliberate: it rides the same
/// seam the keynote dip uses (card composited over transparency, background
/// underneath), it carries the cursor, annotations and window mask along for
/// free, and because Y never moves it is identical in the preview's Y-down
/// space and Core Image's Y-up space.
enum CameraLayoutMath {

    /// Morph length at every mode boundary.
    static let transitionDuration: TimeInterval = 0.45

    /// Side-by-side is a two-tile row of EQUAL HEIGHT, both vertically
    /// centred — not a full-height camera tower next to a shrunken floating
    /// card (the first composition; it looked broken). The screen keeps
    /// 60% of the width, so it stays clearly the subject.
    static let sideBySideScreenFraction: CGFloat = 0.60
    /// Gutter between the two tiles, as a fraction of the card width.
    static let sideBySideGapFraction: CGFloat = 0.03

    /// Smootherstep — zero first AND second derivative at both ends, so the
    /// morph has no visible start/stop tick. (Ken Perlin's 6t⁵−15t⁴+10t³.)
    static func ease(_ t: Double) -> Double {
        let x = min(1, max(0, t))
        return x * x * x * (x * (x * 6 - 15) + 10)
    }

    /// A fully-resolved, already-interpolated arrangement.
    struct Resolved: Equatable {
        /// Where the camera is drawn, in the caller's space. nil = the project
        /// has no camera at all.
        var cameraRect: CGRect?
        /// Corner radius for the camera, in the caller's space.
        var cameraCornerRadius: CGFloat
        /// Camera alpha (0 while hidden by a `screenOnly` span).
        var cameraOpacity: Double
        /// Bubble chrome — ring light, border, name tag, drop shadow. Fades to
        /// 0 as the camera leaves bubble geometry, because at card scale that
        /// chrome is wrong (the card carries its own shadow and corners).
        var chromeOpacity: Double
        /// Uniform scale applied to the CARD about its centre.
        var cardScale: CGFloat
        /// Card translation along X only, in the caller's space.
        var cardTranslationX: CGFloat
        /// True when the arrangement is exactly the untouched classic bubble —
        /// lets both paths take their existing fast path (baked assets, no
        /// card transform) and guarantees byte-identical output for projects
        /// with no layout regions.
        var isPlainBubble: Bool
    }

    /// The bubble silhouette expressed as a rounded-rect radius, so the morph
    /// can interpolate FROM the user's actual camera shape:
    ///   • circle — half the short side IS the circle (exact),
    ///   • square — hard corners (exact),
    ///   • rounded rect — the user's own radius (exact),
    ///   • squircle — a rounded rect cannot express a superellipse; a radius
    ///     of ~25% of the short side is the closest silhouette, so squircle
    ///     users get a hairline corner pop at the morph's first frame.
    /// `customRadius` arrives pre-scaled to the caller's space.
    static func bubbleApproxCornerRadius(
        shape: ProjectSettings.CameraShape,
        customRadius: CGFloat,
        size: CGSize
    ) -> CGFloat {
        let short = min(size.width, size.height)
        switch shape {
        case .circle: return short / 2
        case .square: return 0
        case .roundedRect: return min(max(0, customRadius), short / 2)
        case .squircle: return short * 0.25
        }
    }

    static func region(
        at t: TimeInterval, regions: [CameraLayoutRegion]
    ) -> CameraLayoutRegion? {
        regions.first { t >= $0.startTime && t <= $0.endTime }
    }

    static func mode(at t: TimeInterval, regions: [CameraLayoutRegion]) -> CameraLayoutMode {
        region(at: t, regions: regions)?.mode ?? .bubble
    }

    /// The two tiles of a side-by-side split: screen leading, camera
    /// trailing. Both tiles share the SAME height — the height the screen
    /// lands at after its aspect-preserving squeeze — and both are centred
    /// on the card's vertical midline, so the row reads as one deliberate
    /// composition.
    static func columns(in videoRect: CGRect) -> (screen: CGRect, camera: CGRect) {
        let gap = videoRect.width * sideBySideGapFraction
        let screenWidth = videoRect.width * sideBySideScreenFraction
        let cameraWidth = videoRect.width - screenWidth - gap
        let tileHeight = videoRect.height * sideBySideScreenFraction
        let tileY = videoRect.midY - tileHeight / 2
        return (
            screen: CGRect(x: videoRect.minX, y: tileY,
                           width: screenWidth, height: tileHeight),
            camera: CGRect(x: videoRect.maxX - cameraWidth, y: tileY,
                           width: cameraWidth, height: tileHeight)
        )
    }

    /// The settled state for one mode — the endpoints the morph interpolates.
    private static func target(
        mode: CameraLayoutMode,
        videoRect: CGRect,
        bubbleRect: CGRect,
        bubbleCornerRadius: CGFloat,
        cardCornerRadius: CGFloat
    ) -> Resolved {
        switch mode {
        case .bubble:
            return Resolved(
                cameraRect: bubbleRect, cameraCornerRadius: bubbleCornerRadius,
                cameraOpacity: 1, chromeOpacity: 1,
                cardScale: 1, cardTranslationX: 0, isPlainBubble: true
            )
        case .cameraOnly:
            // The camera IS the card: same rect, same corner treatment.
            return Resolved(
                cameraRect: videoRect, cameraCornerRadius: cardCornerRadius,
                cameraOpacity: 1, chromeOpacity: 0,
                cardScale: 1, cardTranslationX: 0, isPlainBubble: false
            )
        case .sideBySide:
            // The screen SHRINKS into the leading tile (aspect preserved —
            // the tile row is sized so width and height land together), the
            // camera fills the trailing tile at the same height.
            let cols = columns(in: videoRect)
            let scale = videoRect.width > 0 ? cols.screen.width / videoRect.width : 1
            return Resolved(
                cameraRect: cols.camera, cameraCornerRadius: cardCornerRadius,
                cameraOpacity: 1, chromeOpacity: 0,
                cardScale: scale,
                cardTranslationX: cols.screen.midX - videoRect.midX,
                isPlainBubble: false
            )
        case .screenOnly:
            // Fades out where the bubble sits, so it dissolves in place
            // instead of flying somewhere first.
            return Resolved(
                cameraRect: bubbleRect, cameraCornerRadius: bubbleCornerRadius,
                cameraOpacity: 0, chromeOpacity: 0,
                cardScale: 1, cardTranslationX: 0, isPlainBubble: false
            )
        }
    }

    private static func lerp(_ a: Double, _ b: Double, _ p: Double) -> Double {
        a + (b - a) * p
    }

    private static func lerp(_ a: CGFloat, _ b: CGFloat, _ p: Double) -> CGFloat {
        a + (b - a) * CGFloat(p)
    }

    private static func lerp(_ a: CGRect, _ b: CGRect, _ p: Double) -> CGRect {
        CGRect(
            x: lerp(a.minX, b.minX, p), y: lerp(a.minY, b.minY, p),
            width: lerp(a.width, b.width, p), height: lerp(a.height, b.height, p)
        )
    }

    /// `videoRect` is the card's rect and `bubbleRect` the classic bubble rect,
    /// both in the caller's own space. `hasCamera` false (no webcam recorded,
    /// or the camera switched off) degrades everything to plain screen so a
    /// layout region never renders an empty hole.
    static func resolve(
        at t: TimeInterval,
        regions: [CameraLayoutRegion],
        videoRect: CGRect,
        bubbleRect: CGRect,
        bubbleCornerRadius: CGFloat,
        cardCornerRadius: CGFloat,
        hasCamera: Bool
    ) -> Resolved {
        // No regions at all is the overwhelmingly common case — take the
        // untouched-bubble fast path before any work.
        guard hasCamera else {
            return Resolved(
                cameraRect: nil, cameraCornerRadius: 0,
                cameraOpacity: 0, chromeOpacity: 0,
                cardScale: 1, cardTranslationX: 0, isPlainBubble: false
            )
        }
        guard !regions.isEmpty else {
            return target(
                mode: .bubble, videoRect: videoRect, bubbleRect: bubbleRect,
                bubbleCornerRadius: bubbleCornerRadius, cardCornerRadius: cardCornerRadius
            )
        }

        let current = mode(at: t, regions: regions)
        let settled = target(
            mode: current, videoRect: videoRect, bubbleRect: bubbleRect,
            bubbleCornerRadius: bubbleCornerRadius, cardCornerRadius: cardCornerRadius
        )

        // The most recent boundary at or before `t` — the morph runs forward
        // from it, so the state is a pure function of timeline position.
        //
        // A boundary at (near) t=0 does NOT morph: a block that starts where
        // the video starts means "open on this arrangement" — the first frame
        // must be the settled state, not a bubble easing in. Same threshold
        // as `boundaries(_:duration:)`.
        let edges = regions.flatMap { [$0.startTime, $0.endTime] }.sorted()
        guard let boundary = edges.last(where: { $0 <= t }),
              boundary > 0.05,
              t - boundary < transitionDuration else {
            return settled
        }

        // Mode immediately BEFORE the boundary. The nudge must be smaller than
        // any gap the timeline can produce; region spans are seconds.
        let previous = mode(at: boundary - 0.001, regions: regions)
        guard previous != current else { return settled }

        let from = target(
            mode: previous, videoRect: videoRect, bubbleRect: bubbleRect,
            bubbleCornerRadius: bubbleCornerRadius, cardCornerRadius: cardCornerRadius
        )
        let p = ease((t - boundary) / transitionDuration)

        return Resolved(
            cameraRect: lerp(from.cameraRect ?? bubbleRect, settled.cameraRect ?? bubbleRect, p),
            cameraCornerRadius: lerp(from.cameraCornerRadius, settled.cameraCornerRadius, p),
            cameraOpacity: lerp(from.cameraOpacity, settled.cameraOpacity, p),
            chromeOpacity: lerp(from.chromeOpacity, settled.chromeOpacity, p),
            cardScale: lerp(from.cardScale, settled.cardScale, p),
            cardTranslationX: lerp(from.cardTranslationX, settled.cardTranslationX, p),
            // Mid-morph is never the plain bubble, even when both ends are.
            isPlainBubble: false
        )
    }

    /// Card transform about its own centre. Shared so the two paths cannot
    /// derive it differently; safe in both Y-down and Y-up space because the
    /// scale is uniform and the translation is X-only.
    static func cardTransform(_ resolved: Resolved, videoRect: CGRect) -> CGAffineTransform {
        guard resolved.cardScale != 1 || resolved.cardTranslationX != 0 else { return .identity }
        let c = CGPoint(x: videoRect.midX, y: videoRect.midY)
        return CGAffineTransform.identity
            .translatedBy(x: c.x + resolved.cardTranslationX, y: c.y)
            .scaledBy(x: resolved.cardScale, y: resolved.cardScale)
            .translatedBy(x: -c.x, y: -c.y)
    }

    /// Every region edge, plus the tail of each morph — both paths need these
    /// as "something is moving here" markers (export static-frame collapse,
    /// preview re-render triggers).
    static func boundaries(
        _ regions: [CameraLayoutRegion], duration: TimeInterval
    ) -> [TimeInterval] {
        regions
            .flatMap { [$0.startTime, $0.endTime] }
            .filter { $0 > 0.05 && $0 < duration - 0.05 }
            .sorted()
    }
}
