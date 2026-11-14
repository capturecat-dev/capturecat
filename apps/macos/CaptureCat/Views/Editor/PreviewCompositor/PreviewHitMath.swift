import CoreGraphics
import Foundation

// The preview's on-canvas hit geometry, platform-neutral (docs/ios-studio-plan.md
// Phase 1d). Every function here is the verbatim body that used to live in
// PreviewInteractionView; the Mac mouse front end and the iOS touch front end
// both drive `PreviewGestureCore`, which asks these for every target, drag
// mapping and clamp — so a tap and a click land on exactly the same thing.
// Frozen by `--preview-gesture-test`.
//
// Coordinate rules: canvas = the host view's own space (Y-down); content =
// canvas through the zoom inverse with the content rect's origin removed;
// video unit = 0…1 of the video rect, Y-down.

/// Everything a hit test needs, captured per rendered frame.
struct PreviewHitContext {
    var project: Project
    var isPlaying: Bool
    var canvas: CGSize
    var contentRect: CGRect
    var videoRect: CGRect        // content space
    var zoom: CGFloat
    var zoomAnchor: CGPoint      // canvas space
    var cameraRect: CGRect?      // canvas space
    var subtitleRect: CGRect?    // canvas space (pill)
    var watermarkRect: CGRect?   // canvas space
    var selectedBlurID: UUID?
    var selectedHighlightID: UUID?
    var selectedDepthFocusID: UUID?
    var selectedAnnotationID: UUID?
    var cameraFitScale: CGFloat
    var cameraAspect: CGFloat
    /// The card's live tilt — needed so on-canvas editing chrome can sit
    /// in the same warped space the content is drawn in.
    var tiltPitch: Double = 0
    var tiltYaw: Double = 0
    var tiltRoll: Double = 0
    var tiltCenter: CGPoint = .zero      // content space
    var tiltDistance: CGFloat = 1
    /// Selected zoom block's focal point (unit, video space) — non-nil
    /// shows the draggable on-canvas focal target.
    var selectedZoomFocal: CGPoint? = nil
    /// The camera's live card-position excursion (canvas fractions,
    /// Y-down) — part of the zoom transform, so the inverse mapping
    /// needs it or every interaction misses while a block slides the card.
    var cardOffset: CGPoint = .zero
    /// Zoom region containing the playhead. While one is active, a card
    /// drag composes THAT block's excursion — it must never rewrite the
    /// permanent base placement (the "camera never returns home" bug: a
    /// mid-block drag stored the block's look as videoCustomX/Y, so the
    /// release sprang back to a polluted base instead of centre).
    var activeZoomID: UUID? = nil
    /// Vertical stack (§12.12) while settled: the camera row and the area
    /// the rows split (canvas space). nil = no resize notch.
    var stack: PreviewStackSeam? = nil
}

struct PreviewStackSeam {
    var cameraRow: CGRect
    var area: CGRect
    /// The rows' gap as a share of the stack height (§12.14 `stackGap`).
    var gap: Double = Double(CameraLayoutMath.stackGapFraction)
    /// The seam between the rows (canvas y): the camera row's bottom.
    var seamY: CGFloat { cameraRow.maxY }
}

enum PreviewRegionRef {
    case blur(UUID)
    case highlight(UUID)
    case depthFocus(UUID)
}

/// The gesture state machine's states — what a press grabbed, carried
/// through the drag to the release.
enum PreviewDragMode {
    case idle
    case camera(initial: CGPoint)                    // fraction at mousedown
    case watermark(initial: CGPoint)
    case subtitle(initial: CGPoint)
    case annotation(id: UUID, initial: CGPoint, initialEnd: CGPoint) // normalized x/y + arrowEnd
    case draw(id: UUID)                              // freehand stroke capture
    /// Arrow endpoint or shape corner: the flags say which normalized
    /// fields this handle edits (start x/y vs arrowEnd x/y).
    case annotationHandle(id: UUID, xIsStart: Bool, yIsStart: Bool)
    case regionMove(PreviewRegionRef, initial: CGRect)
    case regionResize(PreviewRegionRef, initial: CGRect, left: Bool, right: Bool, top: Bool, bottom: Bool)
    case regionSlider(PreviewRegionRef, pillRect: CGRect)   // intensity / dim slider
    case placement(moved: Bool)
    /// Card drag while the playhead is inside a zoom block: composes the
    /// BLOCK's card excursion (springs home on release) instead of the
    /// permanent base placement. `initial` is the block's cardOffset at
    /// mousedown (canvas fractions, Y-down).
    case blockOffset(id: UUID, initial: CGPoint, moved: Bool)
    case zoomFocal                                   // on-canvas focal target
    case blurDraw(style: BlurStyle)                  // armed rubber-band draw
    /// Vertical stack resize notch (§12.12): the stored ratio at mousedown.
    case stackResize(initial: Double?)
}

enum PreviewHitMath {
    /// Smallest region / drawn-blur side, as a fraction of the video.
    static let minNormSize: CGFloat = 0.04

    // MARK: - Coordinate transforms

    /// Canvas point → content space (through the zoom inverse; tilt is
    /// intentionally NOT applied — SwiftUI GeometryEffect hit-test parity).
    /// Inverse of the compositor's card camera transform
    /// `T(anchor + cardOffset·canvas) · S(zoom) · T(−anchor)` — the EXACT
    /// forward math of `PreviewCompositorCore`'s zoomGroup (and the
    /// exporter's camera translate/scale). Pure and static so the
    /// `--camera-settle-test` gate can round-trip it against the forward
    /// transform. The cardOffset term was missing for months: with a block
    /// excursion of (−0.18, +0.15) at zoom 1.6 every hit test and drag
    /// mapping missed by ~(81, 38) px.
    static func inverseCameraPoint(
        _ p: CGPoint,
        zoom: CGFloat,
        anchor: CGPoint,
        cardOffset: CGPoint,
        canvas: CGSize
    ) -> CGPoint {
        let z = max(0.01, zoom)
        return CGPoint(
            x: anchor.x + (p.x - cardOffset.x * canvas.width - anchor.x) / z,
            y: anchor.y + (p.y - cardOffset.y * canvas.height - anchor.y) / z
        )
    }

    static func contentPoint(_ canvasPoint: CGPoint, _ ctx: PreviewHitContext) -> CGPoint {
        let unzoomed = inverseCameraPoint(
            canvasPoint, zoom: ctx.zoom, anchor: ctx.zoomAnchor,
            cardOffset: ctx.cardOffset, canvas: ctx.canvas
        )
        let warped = CGPoint(x: unzoomed.x - ctx.contentRect.minX, y: unzoomed.y - ctx.contentRect.minY)
        // Undo the tilt: the user clicks shapes where they are DRAWN (warped),
        // but every hit rect lives in unwarped content space. Without this
        // inverse, a tilted card offsets every click — annotation bodies miss
        // (grabs land in corner-handle zones and "resize"), and pen strokes
        // land beside the pointer.
        guard max(abs(ctx.tiltPitch), abs(ctx.tiltYaw), abs(ctx.tiltRoll)) > 0.01 else {
            return warped
        }
        let homography = TiltMath.projectionTransform(
            pitchDegrees: ctx.tiltPitch,
            yawDegrees: ctx.tiltYaw,
            rollDegrees: ctx.tiltRoll,
            center: ctx.tiltCenter,
            distance: ctx.tiltDistance
        )
        guard let inverse = homography.inverted() else { return warped }
        return inverse.applied(to: warped)
    }

    static func regionPixelRect(_ norm: CGRect, _ ctx: PreviewHitContext) -> CGRect {
        let vr = ctx.videoRect
        return CGRect(
            x: vr.minX + norm.minX * vr.width,
            y: vr.minY + norm.minY * vr.height,
            width: max(30, norm.width * vr.width),
            height: max(20, norm.height * vr.height)
        )
    }

    static func normalizedVideoPoint(_ cp: CGPoint, _ ctx: PreviewHitContext) -> CGPoint {
        let vr = ctx.videoRect
        return CGPoint(
            x: min(1, max(0, (cp.x - vr.minX) / max(1, vr.width))),
            y: min(1, max(0, (cp.y - vr.minY) / max(1, vr.height)))
        )
    }

    /// A content-space rect in the host view's coordinates — pushed through
    /// the zoom about its anchor (tilt deliberately ignored).
    static func viewRect(ofContentRect content: CGRect, _ ctx: PreviewHitContext) -> CGRect {
        let r = content.offsetBy(dx: ctx.contentRect.minX, dy: ctx.contentRect.minY)
        let z = max(0.01, ctx.zoom)
        let ax = ctx.zoomAnchor.x, ay = ctx.zoomAnchor.y
        return CGRect(
            x: ax + (r.minX - ax) * z,
            y: ay + (r.minY - ay) * z,
            width: r.width * z,
            height: r.height * z
        )
    }

    // MARK: - Chrome

    /// The card body: the whole video rect.
    static func cardHitRect(_ ctx: PreviewHitContext) -> CGRect {
        ctx.videoRect
    }

    /// The selected annotation's rect in the host view's coordinates —
    /// content rect pushed through the zoom transform (tilt deliberately
    /// ignored; the shell hangs the contextual toolbar off this and an
    /// approximate anchor under a tilted card is fine). Nil when nothing
    /// is selected.
    static func selectedAnnotationViewRect(_ ctx: PreviewHitContext) -> CGRect? {
        guard let id = ctx.selectedAnnotationID,
              let a = ctx.project.annotations.first(where: { $0.id == id }) else { return nil }
        return viewRect(ofContentRect: annotationHitRect(a, ctx), ctx)
    }

    /// Where the in-place label editor sits (host view coordinates) and its
    /// pill padding. Geometry comes from the RENDERER's own labelRect,
    /// pushed through the zoom BY HAND (scale about the zoom anchor, font
    /// and pads scaled the same way) — tilt is approximated as identity.
    static func inlineEditGeometry(
        _ annotation: Annotation, _ ctx: PreviewHitContext
    ) -> (frame: CGRect, pads: CGSize, zoom: CGFloat) {
        let content = AnnotationRenderer.labelRect(
            annotation, videoRect: ctx.videoRect, scale: 1
        ) ?? annotationHitRect(annotation, ctx)
        let z = max(0.01, ctx.zoom)
        let zoomed = viewRect(ofContentRect: content, ctx)
        let pads = CGSize(
            width: (annotation.type == .text ? 10 : 12) * z,
            height: (annotation.type == .text ? 6 : 8) * z
        )
        return (zoomed, pads, z)
    }

    // MARK: - Annotations

    /// Arrow endpoints and shape corners — hit before the body, 12pt radius
    /// (matches the SwiftUI 14pt handle circles' effective target).
    static func annotationHandleHit(_ a: Annotation, at cp: CGPoint, _ ctx: PreviewHitContext) -> PreviewDragMode? {
        let vr = ctx.videoRect
        func pt(_ nx: Double, _ ny: Double) -> CGPoint {
            CGPoint(x: vr.minX + nx * vr.width, y: vr.minY + ny * vr.height)
        }
        // Handle radius shrinks with the shape: at the fixed 12pt, the four
        // corner targets of a small shape on a scaled-down card overlap and
        // swallow the whole body — every click "resizes" and none move.
        let shapeW = abs(a.arrowEndX - a.x) * vr.width
        let shapeH = abs(a.arrowEndY - a.y) * vr.height
        let radius = min(12, max(5, min(shapeW, shapeH) / 4))
        func near(_ point: CGPoint) -> Bool { hypot(cp.x - point.x, cp.y - point.y) <= radius }

        switch a.type {
        case .arrow:
            if near(pt(a.arrowEndX, a.arrowEndY)) {
                return .annotationHandle(id: a.id, xIsStart: false, yIsStart: false) // head
            }
            if near(pt(a.x, a.y)) {
                return .annotationHandle(id: a.id, xIsStart: true, yIsStart: true) // tail
            }
        case .rectangle, .ellipse:
            if near(pt(a.x, a.y)) {
                return .annotationHandle(id: a.id, xIsStart: true, yIsStart: true) // TL
            }
            if near(pt(a.arrowEndX, a.y)) {
                return .annotationHandle(id: a.id, xIsStart: false, yIsStart: true) // TR
            }
            if near(pt(a.x, a.arrowEndY)) {
                return .annotationHandle(id: a.id, xIsStart: true, yIsStart: false) // BL
            }
            if near(pt(a.arrowEndX, a.arrowEndY)) {
                return .annotationHandle(id: a.id, xIsStart: false, yIsStart: false) // BR
            }
        default:
            break
        }
        return nil
    }

    static func annotationHitRect(_ a: Annotation, _ ctx: PreviewHitContext) -> CGRect {
        let vr = ctx.videoRect
        let p = CGPoint(x: vr.minX + a.x * vr.width, y: vr.minY + a.y * vr.height)
        switch a.type {
        case .rectangle, .ellipse:
            let q = CGPoint(x: vr.minX + a.arrowEndX * vr.width, y: vr.minY + a.arrowEndY * vr.height)
            return CGRect(x: min(p.x, q.x), y: min(p.y, q.y),
                          width: abs(q.x - p.x), height: abs(q.y - p.y))
                .insetBy(dx: -10, dy: -10)
        case .arrow, .callout:
            let q = CGPoint(x: vr.minX + a.arrowEndX * vr.width, y: vr.minY + a.arrowEndY * vr.height)
            return CGRect(x: min(p.x, q.x), y: min(p.y, q.y),
                          width: abs(q.x - p.x), height: abs(q.y - p.y))
                .insetBy(dx: -16, dy: -16)
        case .tap:
            let r = max(24, a.fontSize)
            return CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
        case .drawing:
            // The INK's bounding box — the placement point (x, y) never moves
            // for drawings, so the default center-box sat nowhere near the
            // strokes and the annotation was unselectable by clicking it.
            var minX = Double.infinity, minY = Double.infinity
            var maxX = -Double.infinity, maxY = -Double.infinity
            for stroke in a.drawingStrokes {
                for pt in stroke {
                    minX = min(minX, pt.x); maxX = max(maxX, pt.x)
                    minY = min(minY, pt.y); maxY = max(maxY, pt.y)
                }
            }
            guard minX.isFinite else {
                // No strokes yet (fresh drawing) — fall back to the whole
                // video so pen-down anywhere starts the first stroke.
                return vr
            }
            return CGRect(
                x: vr.minX + minX * vr.width,
                y: vr.minY + minY * vr.height,
                width: (maxX - minX) * vr.width,
                height: (maxY - minY) * vr.height
            ).insetBy(dx: -12, dy: -12)
        case .text:
            // The renderer's own pill rect, padded for grabbability — the old
            // char-count estimate missed by half a pill on wide glyphs.
            if let pill = AnnotationRenderer.labelRect(a, videoRect: vr, scale: 1) {
                return pill.insetBy(dx: -8, dy: -8)
            }
            fallthrough
        default:
            let w = max(60, a.fontSize * CGFloat(max(3, a.text.count)) * 0.6)
            let h = max(28, a.fontSize * 1.8)
            return CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h)
        }
    }

    // MARK: - Regions (port of BlurRegionHandle/HighlightRegionHandle)

    /// What a press on region chrome grabbed, and which region it selects.
    struct RegionHit {
        var mode: PreviewDragMode
        var ref: PreviewRegionRef
    }

    /// Highlights on top (drawn after blur overlays), then depth focus,
    /// then blur — the first region whose chrome contains `cp` wins.
    static func hitRegion(_ cp: CGPoint, _ ctx: PreviewHitContext, time: TimeInterval) -> RegionHit? {
        for region in ctx.project.highlightRegions.reversed()
        where time >= region.startTime && time <= region.endTime {
            if let mode = regionDragMode(
                cp, rect: region.rect, ref: .highlight(region.id),
                isSelected: ctx.selectedHighlightID == region.id, ctx: ctx
            ) { return RegionHit(mode: mode, ref: .highlight(region.id)) }
        }
        for region in ctx.project.focusRegions.reversed()
        where time >= region.startTime && time <= region.endTime {
            if let mode = regionDragMode(
                cp, rect: region.rect, ref: .depthFocus(region.id),
                isSelected: ctx.selectedDepthFocusID == region.id, ctx: ctx
            ) { return RegionHit(mode: mode, ref: .depthFocus(region.id)) }
        }
        for region in ctx.project.blurRegions.reversed()
        where time >= region.startTime && time <= region.endTime {
            if let mode = regionDragMode(
                cp, rect: region.rect, ref: .blur(region.id),
                isSelected: ctx.selectedBlurID == region.id, ctx: ctx
            ) { return RegionHit(mode: mode, ref: .blur(region.id)) }
        }
        return nil
    }

    static func regionDragMode(
        _ cp: CGPoint, rect norm: CGRect, ref: PreviewRegionRef,
        isSelected: Bool, ctx: PreviewHitContext
    ) -> PreviewDragMode? {
        let r = regionPixelRect(norm, ctx)

        if isSelected {
            // Value pill (below the region, RegionPillPlacement) — slider drag.
            let pill = pillRect(for: r, ctx)
            if pill.contains(cp) {
                return .regionSlider(ref, pillRect: pill)
            }
            // 24pt corner zones, 18pt edge strips — the SwiftUI hit metrics.
            let corners: [(CGRect, (Bool, Bool, Bool, Bool))] = [
                (CGRect(x: r.minX - 12, y: r.minY - 12, width: 24, height: 24), (true, false, true, false)),
                (CGRect(x: r.maxX - 12, y: r.minY - 12, width: 24, height: 24), (false, true, true, false)),
                (CGRect(x: r.minX - 12, y: r.maxY - 12, width: 24, height: 24), (true, false, false, true)),
                (CGRect(x: r.maxX - 12, y: r.maxY - 12, width: 24, height: 24), (false, true, false, true)),
            ]
            for (zone, m) in corners where zone.contains(cp) {
                return .regionResize(ref, initial: norm, left: m.0, right: m.1, top: m.2, bottom: m.3)
            }
            let edges: [(CGRect, (Bool, Bool, Bool, Bool))] = [
                (CGRect(x: r.minX + 16, y: r.minY - 9, width: max(30, r.width - 32), height: 18), (false, false, true, false)),
                (CGRect(x: r.minX + 16, y: r.maxY - 9, width: max(30, r.width - 32), height: 18), (false, false, false, true)),
                (CGRect(x: r.minX - 9, y: r.minY + 14, width: 18, height: max(24, r.height - 28)), (true, false, false, false)),
                (CGRect(x: r.maxX - 9, y: r.minY + 14, width: 18, height: max(24, r.height - 28)), (false, true, false, false)),
            ]
            for (zone, m) in edges where zone.contains(cp) {
                return .regionResize(ref, initial: norm, left: m.0, right: m.1, top: m.2, bottom: m.3)
            }
        }

        if r.contains(cp) {
            return .regionMove(ref, initial: norm)
        }
        return nil
    }

    /// Pill rect for a selected region — RegionPillPlacement.offset port
    /// (below the region when it fits, tucked inside the bottom edge when
    /// not, clamped horizontally to the container).
    static func pillRect(for r: CGRect, _ ctx: PreviewHitContext) -> CGRect {
        let sliderWidth = min(max(90, r.width - 60), 150)
        let pillWidth = sliderWidth + 54
        let pillHeight = RegionHandleChrome.pillHeight
        let gap = RegionHandleChrome.pillGap
        let container = ctx.videoRect
        let fitsBelow = r.maxY + gap + pillHeight <= container.maxY
        let y = fitsBelow ? r.maxY + gap : r.maxY - gap - pillHeight
        let lower = container.minX + pillWidth / 2
        let upper = container.maxX - pillWidth / 2
        let centreX = upper >= lower ? min(max(r.midX, lower), upper) : container.midX
        return CGRect(x: centreX - pillWidth / 2, y: y, width: pillWidth, height: pillHeight)
    }

    /// A region's normalized rect after a move / edge drag from `downPoint`
    /// to `p` (both canvas space), clamped to the video and the minimum size.
    static func adjust(
        _ initial: CGRect, _ ctx: PreviewHitContext, p: CGPoint, downPoint: CGPoint,
        left: Bool, right: Bool, top: Bool, bottom: Bool, move: Bool
    ) -> CGRect {
        let cp = contentPoint(p, ctx)
        let cpDown = contentPoint(downPoint, ctx)
        let dx = (cp.x - cpDown.x) / max(1, ctx.videoRect.width)
        let dy = (cp.y - cpDown.y) / max(1, ctx.videoRect.height)

        func clamped(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
            hi >= lo ? min(max(v, lo), hi) : lo
        }

        if move {
            return CGRect(
                x: clamped(initial.origin.x + dx, 0, max(0, 1 - initial.width)),
                y: clamped(initial.origin.y + dy, 0, max(0, 1 - initial.height)),
                width: initial.width, height: initial.height
            )
        }
        var minX = initial.minX, maxX = initial.maxX
        var minY = initial.minY, maxY = initial.maxY
        if left { minX = clamped(initial.minX + dx, 0, max(0, initial.maxX - minNormSize)) }
        if right { maxX = clamped(initial.maxX + dx, min(1, initial.minX + minNormSize), 1) }
        if top { minY = clamped(initial.minY + dy, 0, max(0, initial.maxY - minNormSize)) }
        if bottom { maxY = clamped(initial.maxY + dy, min(1, initial.minY + minNormSize), 1) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: - Vertical stack seam (docs/camera-cutout.md §12.12)

    /// Grab band around the seam, in points.
    static let stackSeamSlop: CGFloat = 8

    static func stackSeamHit(_ p: CGPoint, _ stack: PreviewStackSeam) -> Bool {
        p.x >= stack.area.minX && p.x <= stack.area.maxX && abs(p.y - stack.seamY) <= stackSeamSlop
            || stackNotchRect(stack).insetBy(dx: -6, dy: -6).contains(p)
    }

    /// The ratio whose camera row ends at canvas y (stackRows' inverse).
    static func stackRatio(at y: CGFloat, area: CGRect, gap share: Double) -> Double {
        let gap = area.height * CGFloat(share)
        let usable = max(1, area.height - gap)
        return Double((y - area.minY) / usable)
    }

    static func stackNotchRect(_ stack: PreviewStackSeam) -> CGRect {
        let w: CGFloat = 44, h: CGFloat = 8
        return CGRect(x: stack.cameraRow.midX - w / 2, y: stack.seamY - h / 2, width: w, height: h)
    }
}
