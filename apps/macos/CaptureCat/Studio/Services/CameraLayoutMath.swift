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
/// seam the segment dip uses (card composited over transparency, background
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
        /// Card translation along X, in the caller's space.
        var cardTranslationX: CGFloat
        /// Card translation along Y, in the caller's space — non-zero only for
        /// the vertical stack (§12.12), which moves the card into its row.
        var cardTranslationY: CGFloat = 0
        /// Full-height split (§12.11): the card is clipped to this rounded
        /// rect (caller's space) at the card seam, riders included. nil = no
        /// clip — every arrangement but a full split and its morphs.
        var cardClip: CGRect? = nil
        var cardClipCornerRadius: CGFloat = 0
        /// The rounded-rect SHAPE each tile's corners come from, when it
        /// differs from the visible rect (§12.14): a joined stack extends each
        /// row's shape past the seam by its radius, so the mask (shape,
        /// cropped to the rect) has square corners there. nil = the rect.
        var cameraShapeRect: CGRect? = nil
        var cardClipShapeRect: CGRect? = nil
        /// How much the stack's rows are joined (§12.14), 0…1, eased through
        /// morphs — the camera tile's card shadow fades by `1 − seamJoin` so
        /// it never casts a band across the screen it touches.
        var seamJoin: Double = 0
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

    /// What a morph compares (§12.6): the mode, plus the camera side while
    /// it is Side by Side — so adjacent splits on opposite sides morph.
    struct Arrangement: Equatable {
        var mode: CameraLayoutMode
        var side: CameraSide
        var split: CameraSplitStyle = .tiles
        /// The vertical stack (§12.12) — the default arrangement while active.
        var stacked = false
    }

    static func arrangement(
        at t: TimeInterval, regions: [CameraLayoutRegion], stacking: Bool = false
    ) -> Arrangement {
        guard let r = region(at: t, regions: regions) else {
            return Arrangement(mode: .bubble, side: .trailing, stacked: stacking)
        }
        guard r.mode == .sideBySide else { return Arrangement(mode: r.mode, side: .trailing) }
        if stacking { return Arrangement(mode: r.mode, side: .trailing, stacked: true) }
        return Arrangement(mode: r.mode, side: r.effectiveSide, split: r.effectiveSplitStyle)
    }

    // MARK: - Vertical stack (§12.12)

    /// The two rows of the vertical stack, in the caller's space.
    struct StackRows: Equatable {
        var camera: CGRect
        var screen: CGRect
    }

    static let stackDefaultRatio: Double = 0.42
    static let stackRatioRange: ClosedRange<Double> = 0.25...0.7
    static let stackGapFraction: CGFloat = 0.02
    static let stackGapRange: ClosedRange<Double> = 0...0.08

    static func stackRatio(_ stored: Double?) -> Double {
        min(stackRatioRange.upperBound, max(stackRatioRange.lowerBound, stored ?? stackDefaultRatio))
    }

    /// The gap between the rows as a share of the stack height (§12.14):
    /// clamped to 0…0.08, absent = 0.02. 0 joins the rows into one card.
    static func stackGap(_ stored: Double?) -> Double {
        min(stackGapRange.upperBound, max(stackGapRange.lowerBound, stored ?? Double(stackGapFraction)))
    }

    /// Camera row on TOP, screen row below, inside `area` (the content rect).
    /// `yield` (§12.13, `stackYield`) shrinks the camera row's height while
    /// the screen zooms; the screen row takes what it gives up.
    static func stackRows(
        area: CGRect, ratio: Double, yAxisIsUp: Bool, yield: Double = 1, gap stored: Double? = nil
    ) -> StackRows {
        let gap = area.height * CGFloat(stackGap(stored))
        let h = (area.height - gap) * CGFloat(stackRatio(ratio)) * CGFloat(yield)
        let screenH = area.height - h - gap
        if yAxisIsUp {
            return StackRows(
                camera: CGRect(x: area.minX, y: area.maxY - h, width: area.width, height: h),
                screen: CGRect(x: area.minX, y: area.minY, width: area.width, height: screenH))
        }
        return StackRows(
            camera: CGRect(x: area.minX, y: area.minY, width: area.width, height: h),
            screen: CGRect(x: area.minX, y: area.minY + h + gap, width: area.width, height: screenH))
    }

    /// Whether the stack applies (§12.12): switched on, and the output canvas
    /// is portrait. The caller also needs a camera to show.
    static func stackActive(settings: ProjectSettings, canvas: CGSize) -> Bool {
        (settings.cameraPortraitStack ?? false) && canvas.height > canvas.width
    }

    // MARK: - Zoom inside the vertical stack (§12.13)

    /// The screen's view while stacked: the smoothed zoom and its focal point
    /// (0…1 of the video rect, Y-down) — the same values the card zoom uses.
    struct StackZoom: Equatable {
        var zoom: Double = 1
        var focalX: Double = 0.5
        var focalY: Double = 0.5
        static let none = StackZoom()
    }

    /// How much of its height the camera row keeps at `zoom` (pass
    /// `ReactiveCameraLayout.layoutZoom`, so Shrink During Zoom off keeps
    /// it): the bubble's own shrink, so the seam glides up on the same curve.
    static func stackYield(zoom: Double) -> Double {
        ReactiveCameraLayout.sizeFactor(forZoom: zoom)
    }

    /// The zoom the card stage AFTER the layout applies (§12.13). While the
    /// stack is on, every zoom-in happens inside the layout (`resolve`):
    /// inside the row when stacked, about the focal on the card in a Bubble /
    /// Camera Only / Screen Only block — so the camera tile never rides a
    /// zoom and a morph only blends two zoomed layouts. A scale-down (zoom < 1
    /// shrinks the whole composition) stays here. Feed the result to the
    /// cover zoom, the background parallax and both motion blur samples.
    static func outerZoom(_ zoom: Double, stacking: Bool) -> Double {
        stacking && zoom > 1 ? 1 : zoom
    }

    /// The two tiles of a side-by-side split: screen leading, camera
    /// trailing. Both tiles share the SAME height — the height the screen
    /// lands at after its aspect-preserving squeeze — and both are centred
    /// on the card's vertical midline, so the row reads as one deliberate
    /// composition.
    /// `side` leading mirrors the row (§12.6): camera first, screen last.
    /// `style` full (§12.11) runs both tiles the card's full height.
    static func columns(
        in videoRect: CGRect, side: CameraSide = .trailing, style: CameraSplitStyle = .tiles
    ) -> (screen: CGRect, camera: CGRect) {
        let gap = videoRect.width * sideBySideGapFraction
        let screenWidth = videoRect.width * sideBySideScreenFraction
        let cameraWidth = videoRect.width - screenWidth - gap
        let tileHeight = style == .full ? videoRect.height : videoRect.height * sideBySideScreenFraction
        let tileY = style == .full ? videoRect.minY : videoRect.midY - tileHeight / 2
        switch side {
        case .trailing:
            return (
                screen: CGRect(x: videoRect.minX, y: tileY,
                               width: screenWidth, height: tileHeight),
                camera: CGRect(x: videoRect.maxX - cameraWidth, y: tileY,
                               width: cameraWidth, height: tileHeight)
            )
        case .leading:
            return (
                screen: CGRect(x: videoRect.maxX - screenWidth, y: tileY,
                               width: screenWidth, height: tileHeight),
                camera: CGRect(x: videoRect.minX, y: tileY,
                               width: cameraWidth, height: tileHeight)
            )
        }
    }

    /// The settled state for one mode — the endpoints the morph interpolates.
    private static func target(
        _ arrangement: Arrangement,
        videoRect: CGRect,
        bubbleRect: CGRect,
        bubbleCornerRadius: CGFloat,
        cardCornerRadius: CGFloat,
        stack: StackRows? = nil,
        stackZoom: StackZoom = .none
    ) -> Resolved {
        if !arrangement.stacked, let stack, stackZoom.zoom > 1 {
            // §12.13, the other arrangements while the stack is on: the plain
            // zoom about the focal on the card, folded into the card transform
            // (outerZoom leaves it to the layout).
            var r = target(arrangement, videoRect: videoRect, bubbleRect: bubbleRect,
                           bubbleCornerRadius: bubbleCornerRadius, cardCornerRadius: cardCornerRadius)
            let z = CGFloat(stackZoom.zoom)
            let yUp = stack.camera.midY > stack.screen.midY
            let c = CGPoint(x: videoRect.midX, y: videoRect.midY)
            let fx = CGFloat(stackZoom.focalX), fy = CGFloat(stackZoom.focalY)
            let a = CGPoint(
                x: videoRect.minX + fx * videoRect.width,
                y: yUp ? videoRect.maxY - fy * videoRect.height : videoRect.minY + fy * videoRect.height)
            // p ↦ a + z·(T(p) − a), T = the arrangement's own card transform.
            r.cardTranslationX = a.x + z * (c.x + r.cardTranslationX - a.x) - c.x
            r.cardTranslationY = a.y + z * (c.y + r.cardTranslationY - a.y) - c.y
            r.cardScale *= z
            return r
        }
        if arrangement.stacked, let stack {
            // The card aspect-fills the screen row and is clipped to it; the
            // camera fills the row above.
            let row = stack.screen
            let fill = videoRect.width > 0 && videoRect.height > 0
                ? max(row.width / videoRect.width, row.height / videoRect.height) : 1
            // §12.13: the screen zooms INSIDE its row — the row is a window,
            // the camera row never zooms. The focal point P (on the filled
            // card) eases toward the same fraction of the row (Qd) as the zoom
            // grows, so a focal the fill cropped away pans into view; both
            // ends cover the row, so every blend does. The rows' order tells
            // the caller's Y convention (the camera row is always on top).
            let z = CGFloat(max(1, stackZoom.zoom))
            let fx = CGFloat(min(1, max(0, stackZoom.focalX)))
            let fy = CGFloat(min(1, max(0, stackZoom.focalY)))
            let yUp = stack.camera.midY > row.midY
            let c = CGPoint(x: videoRect.midX, y: videoRect.midY)
            let focal = CGPoint(
                x: videoRect.minX + fx * videoRect.width,
                y: yUp ? videoRect.maxY - fy * videoRect.height : videoRect.minY + fy * videoRect.height)
            let p = CGPoint(x: row.midX + fill * (focal.x - c.x), y: row.midY + fill * (focal.y - c.y))
            let qd = CGPoint(
                x: row.minX + fx * row.width,
                y: yUp ? row.maxY - fy * row.height : row.minY + fy * row.height)
            let e = CGFloat(ReactiveCameraLayout.envelope(forZoom: Double(z)))
            let q = CGPoint(x: p.x + (qd.x - p.x) * e, y: p.y + (qd.y - p.y) * e)
            // p ↦ q + z·(row centre + fill·(p − c) − P), as cardTransform's
            // centre + translation + scale·(p − c). At rest it is exactly
            // the plain fill (no rounding drift).
            let zoomed = z > 1
            // §12.14: rows that touch (Gap 0) join into one card — each row's
            // rounded shape runs past the seam by the radius, so its corners
            // there are square once cropped to the row.
            let seam = yUp ? stack.camera.minY - row.maxY : row.minY - stack.camera.maxY
            let joined = seam <= 1e-6 * max(1, stack.camera.height + row.height)
            let reach = joined ? max(0, cardCornerRadius) : 0
            return Resolved(
                cameraRect: stack.camera, cameraCornerRadius: cardCornerRadius,
                cameraOpacity: 1, chromeOpacity: 0,
                cardScale: fill * z,
                cardTranslationX: zoomed ? q.x + z * (row.midX - p.x) - c.x : row.midX - c.x,
                cardTranslationY: zoomed ? q.y + z * (row.midY - p.y) - c.y : row.midY - c.y,
                cardClip: row, cardClipCornerRadius: cardCornerRadius,
                cameraShapeRect: reach > 0
                    ? CGRect(x: stack.camera.minX, y: yUp ? stack.camera.minY - reach : stack.camera.minY,
                             width: stack.camera.width, height: stack.camera.height + reach) : nil,
                cardClipShapeRect: reach > 0
                    ? CGRect(x: row.minX, y: yUp ? row.minY : row.minY - reach,
                             width: row.width, height: row.height + reach) : nil,
                seamJoin: joined ? 1 : 0,
                isPlainBubble: false
            )
        }
        switch arrangement.mode {
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
        case .sideBySide where arrangement.split == .full:
            // Full-height split (§12.11): the card keeps its size and slides
            // so the screen's centre sits in its column, clipped to it; the
            // camera fills the other full-height column.
            let cols = columns(in: videoRect, side: arrangement.side, style: .full)
            return Resolved(
                cameraRect: cols.camera, cameraCornerRadius: cardCornerRadius,
                cameraOpacity: 1, chromeOpacity: 0,
                cardScale: 1,
                cardTranslationX: cols.screen.midX - videoRect.midX,
                cardClip: cols.screen, cardClipCornerRadius: cardCornerRadius,
                isPlainBubble: false
            )
        case .sideBySide:
            // The screen SHRINKS into the leading tile (aspect preserved —
            // the tile row is sized so width and height land together), the
            // camera fills the trailing tile at the same height.
            let cols = columns(in: videoRect, side: arrangement.side)
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
        hasCamera: Bool,
        stack: StackRows? = nil,
        stackZoom: StackZoom = .none
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
        let stacking = stack != nil
        guard !regions.isEmpty else {
            return target(
                Arrangement(mode: .bubble, side: .trailing, stacked: stacking), videoRect: videoRect,
                bubbleRect: bubbleRect, bubbleCornerRadius: bubbleCornerRadius,
                cardCornerRadius: cardCornerRadius, stack: stack,
                stackZoom: stackZoom
            )
        }

        let current = arrangement(at: t, regions: regions, stacking: stacking)
        let settled = target(
            current, videoRect: videoRect, bubbleRect: bubbleRect,
            bubbleCornerRadius: bubbleCornerRadius, cardCornerRadius: cardCornerRadius, stack: stack,
            stackZoom: stackZoom
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

        // Arrangement immediately BEFORE the boundary. The nudge must be
        // smaller than any gap the timeline can produce; region spans are
        // seconds.
        let previous = arrangement(at: boundary - 0.001, regions: regions, stacking: stacking)
        guard previous != current else { return settled }

        let from = target(
            previous, videoRect: videoRect, bubbleRect: bubbleRect,
            bubbleCornerRadius: bubbleCornerRadius, cardCornerRadius: cardCornerRadius, stack: stack,
            stackZoom: stackZoom
        )
        let p = ease((t - boundary) / transitionDuration)

        // The clip (§12.11) only exists when an end has one; the other end
        // stands in as its whole transformed card, so the clip opens from /
        // closes onto the card's own outline.
        var clip: CGRect?
        var clipRadius: CGFloat = 0
        var clipShape: CGRect?
        if from.cardClip != nil || settled.cardClip != nil {
            func outline(_ r: Resolved) -> (CGRect, CGFloat) {
                if let c = r.cardClip { return (c, r.cardClipCornerRadius) }
                return (videoRect.applying(cardTransform(r, videoRect: videoRect)), cardCornerRadius * r.cardScale)
            }
            let a = outline(from), b = outline(settled)
            clip = lerp(a.0, b.0, p)
            clipRadius = lerp(a.1, b.1, p)
            // A joined end's shape (§12.14) eases to the other end's outline.
            if from.cardClipShapeRect != nil || settled.cardClipShapeRect != nil {
                clipShape = lerp(from.cardClipShapeRect ?? a.0, settled.cardClipShapeRect ?? b.0, p)
            }
        }
        let fromCamera = from.cameraRect ?? bubbleRect, toCamera = settled.cameraRect ?? bubbleRect
        let cameraShape: CGRect? = from.cameraShapeRect != nil || settled.cameraShapeRect != nil
            ? lerp(from.cameraShapeRect ?? fromCamera, settled.cameraShapeRect ?? toCamera, p) : nil

        return Resolved(
            cameraRect: lerp(fromCamera, toCamera, p),
            cameraCornerRadius: lerp(from.cameraCornerRadius, settled.cameraCornerRadius, p),
            cameraOpacity: lerp(from.cameraOpacity, settled.cameraOpacity, p),
            chromeOpacity: lerp(from.chromeOpacity, settled.chromeOpacity, p),
            cardScale: lerp(from.cardScale, settled.cardScale, p),
            cardTranslationX: lerp(from.cardTranslationX, settled.cardTranslationX, p),
            cardTranslationY: lerp(from.cardTranslationY, settled.cardTranslationY, p),
            cardClip: clip, cardClipCornerRadius: clipRadius,
            cameraShapeRect: cameraShape, cardClipShapeRect: clipShape,
            seamJoin: lerp(from.seamJoin, settled.seamJoin, p),
            // Mid-morph is never the plain bubble, even when both ends are.
            isPlainBubble: false
        )
    }

    // MARK: - Looks (docs/camera-cutout.md §4)

    /// How much of each camera LOOK to draw. Each 0…1, summing to ≤ 1; the
    /// plain camera drawing gets the rest (`bubble`). Renderers composite,
    /// wherever `resolve` puts the camera, source-over in this order:
    /// existing camera stack faded by `bubble`, then the cutout stack faded by
    /// `cutout`, then the pop-out stack faded by `popOut`.
    struct LookWeights: Equatable {
        var cutout: Double
        var popOut: Double

        static let none = LookWeights(cutout: 0, popOut: 0)

        /// Weight of the existing (non-look) camera drawing.
        var bubble: Double { max(0, 1 - cutout - popOut) }
        /// True when any look draws at all.
        var isActive: Bool { cutout > 0 || popOut > 0 }

        static func settled(_ look: CameraBubbleLook?) -> LookWeights {
            switch look {
            case .cutout: return LookWeights(cutout: 1, popOut: 0)
            case .popOut: return LookWeights(cutout: 0, popOut: 1)
            case nil: return .none
            }
        }
    }

    /// The look drawn at `t` (docs/camera-cutout.md §1a): inside a region, its
    /// `look` while its mode is `.bubble` — `defaultLook` when it sets none —
    /// and nothing on any other mode (a look there is kept, ignored); outside
    /// every region, `defaultLook` (the Camera panel's whole-video
    /// Background, `ProjectSettings.cameraLook`). While the vertical stack
    /// (§12.12) is active its camera row wears `defaultLook` too — outside
    /// regions and on a Side by Side region, which stacks.
    static func look(
        at t: TimeInterval, regions: [CameraLayoutRegion], defaultLook: CameraBubbleLook?,
        stacking: Bool = false
    ) -> CameraBubbleLook? {
        guard let region = region(at: t, regions: regions) else { return defaultLook }
        switch region.mode {
        case .bubble: return region.look ?? defaultLook
        case .sideBySide where stacking: return defaultLook
        default: return nil
        }
    }

    /// Look weights at `t`, eased across region edges exactly like `resolve`
    /// eases the geometry: the most recent edge at or before `t` (edges at
    /// t ≤ 0.05 s never morph — no intro morph, so a whole-video
    /// `defaultLook` is settled from frame one), `transitionDuration`,
    /// smootherstep, from the look just before the edge to the look after it.
    /// Pure function of timeline position.
    static func lookWeights(
        at t: TimeInterval, regions: [CameraLayoutRegion], defaultLook: CameraBubbleLook?,
        stacking: Bool = false
    ) -> LookWeights {
        guard !regions.isEmpty else { return .settled(defaultLook) }
        let current = look(at: t, regions: regions, defaultLook: defaultLook, stacking: stacking)
        let settled = LookWeights.settled(current)
        let edges = regions.flatMap { [$0.startTime, $0.endTime] }.sorted()
        guard let boundary = edges.last(where: { $0 <= t }),
              boundary > 0.05,
              t - boundary < transitionDuration else {
            return settled
        }
        let previous = look(at: boundary - 0.001, regions: regions, defaultLook: defaultLook, stacking: stacking)
        guard previous != current else { return settled }
        let from = LookWeights.settled(previous)
        let p = ease((t - boundary) / transitionDuration)
        return LookWeights(
            cutout: lerp(from.cutout, settled.cutout, p),
            popOut: lerp(from.popOut, settled.popOut, p))
    }

    /// Card transform about its own centre. Shared so the two paths cannot
    /// derive it differently; safe in both Y-down and Y-up space because the
    /// scale is uniform and the translation is X-only.
    static func cardTransform(_ resolved: Resolved, videoRect: CGRect) -> CGAffineTransform {
        guard resolved.cardScale != 1 || resolved.cardTranslationX != 0 || resolved.cardTranslationY != 0
        else { return .identity }
        let c = CGPoint(x: videoRect.midX, y: videoRect.midY)
        return CGAffineTransform.identity
            .translatedBy(x: c.x + resolved.cardTranslationX, y: c.y + resolved.cardTranslationY)
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
