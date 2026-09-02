import AppKit

/// The compositor's edit-gesture surface — a transparent NSView above the
/// layer tree implementing the SAME gestures the SwiftUI preview provides,
/// with one mouse state machine (the TimelineCanvasView house pattern).
/// Writes go to the same Project/ProjectSettings properties the SwiftUI
/// gestures write; visual chrome (outlines/handles/pills) is rendered by the
/// compositor's rasterized FocusChromeView, so this view draws nothing.
///
/// Coordinate rules mirror SwiftUI hit-testing exactly: `scaleEffect` (the
/// card zoom) transforms hit geometry, `GeometryEffect` (the tilt) does NOT —
/// so content-space targets are hit through the zoom inverse only.
final class PreviewInteractionView: NSView {
    /// Everything a hit test needs, captured per rendered frame.
    struct HitContext {
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
    }

    var context: HitContext?
    var onSelectHighlight: ((UUID?) -> Void)?
    var onSelectAnnotation: ((UUID?) -> Void)?
    var onSelectBlur: ((UUID?) -> Void)?
    var onSelectDepthFocus: ((UUID?) -> Void)?
    /// Drag of the on-canvas focal target — unit point in video space.
    var onSetZoomFocal: ((CGPoint) -> Void)?
    /// Fired when an armed blur draw completes — normalized video-space rect
    /// plus the style picked in the popover. The timeline owns creation.
    var onCreateBlurRegion: ((CGRect, BlurStyle) -> Void)?
    /// Ask the compositor to re-render after a model write.
    var requestRender: (() -> Void)?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only claim events that land on an interactive target or the card;
        // empty canvas clicks fall through to whatever is behind.
        let local = convert(point, from: superview)
        guard bounds.contains(local), context != nil else { return nil }
        return self
    }

    // MARK: - State machine

    private enum DragMode {
        case idle
        case camera(initial: CGPoint)                    // fraction at mousedown
        case watermark(initial: CGPoint)
        case subtitle(initial: CGPoint)
        case annotation(id: UUID, initial: CGPoint, initialEnd: CGPoint) // normalized x/y + arrowEnd
        case draw(id: UUID)                              // freehand stroke capture
        /// Arrow endpoint or shape corner: the flags say which normalized
        /// fields this handle edits (start x/y vs arrowEnd x/y).
        case annotationHandle(id: UUID, xIsStart: Bool, yIsStart: Bool)
        case regionMove(RegionRef, initial: CGRect)
        case regionResize(RegionRef, initial: CGRect, left: Bool, right: Bool, top: Bool, bottom: Bool)
        case regionSlider(RegionRef, pillRect: CGRect)   // intensity / dim slider
        case placement(moved: Bool)
        /// Card drag while the playhead is inside a zoom block: composes the
        /// BLOCK's card excursion (springs home on release) instead of the
        /// permanent base placement. `initial` is the block's cardOffset at
        /// mousedown (canvas fractions, Y-down).
        case blockOffset(id: UUID, initial: CGPoint, moved: Bool)
        case zoomFocal                                   // on-canvas focal target
        case blurDraw(style: BlurStyle)                  // armed rubber-band draw
    }

    enum RegionRef {
        case blur(UUID)
        case highlight(UUID)
        case depthFocus(UUID)
    }

    private var mode: DragMode = .idle
    private var downPoint: CGPoint = .zero
    /// True while the closed-hand cursor is pushed for a card drag
    /// (placement or blockOffset) — the gesture reads as grabbing the card.
    /// Push/pop must stay balanced, hence the explicit flag.
    private var cardGrabCursorPushed = false
    /// Pointer − card-centre at drag start, so the card moves with the
    /// pointer instead of jumping to centre itself under it.
    private var placementGrabOffset: CGPoint = .zero
    /// Live in-place label editor (double-click on a text/callout).
    var inlineEditor: NSTextField?
    var inlineEditContainer: NSView?
    /// The pill drawn behind the field — carries the annotation's background
    /// and the accent editing ring, so the FIELD itself stays glyph-sized and
    /// the text sits exactly where the renderer draws it.
    var inlineEditBacking: NSView?
    var inlineEditingID: UUID?
    /// Center of the label being edited (content space) plus its pill padding —
    /// the field grows symmetrically about the center as the user types,
    /// exactly like a Keynote text box.
    var inlineEditCenter: CGPoint?
    var inlineEditPads: CGSize?

    private let minNormSize: CGFloat = 0.04

    // MARK: - Armed blur draw (popover → drag out a region)

    /// Non-nil while the next mouse-down should start a rubber-band blur
    /// draw instead of the normal hit-test cascade.
    private var armedBlurStyle: BlurStyle?
    /// The live rubber-band rect while a blur draw drag is in flight.
    private let blurMarquee = CAShapeLayer()

    /// Arm one drag-to-draw pass. The pointer becomes a crosshair; the next
    /// press-drag-release on the video creates a region via onCreateBlurRegion.
    func armBlurDraw(style: BlurStyle) {
        if armedBlurStyle == nil { NSCursor.crosshair.push() }
        armedBlurStyle = style
    }

    /// Disarm without creating anything (Esc, or a click outside the video).
    func cancelBlurDraw() {
        guard armedBlurStyle != nil else { return }
        armedBlurStyle = nil
        blurMarquee.removeFromSuperlayer()
        NSCursor.pop()
    }

    private func updateBlurMarquee(from a: CGPoint, to b: CGPoint) {
        if blurMarquee.superlayer == nil {
            wantsLayer = true
            blurMarquee.fillColor = NSColor(srgbRed: 0, green: 0.478, blue: 1, alpha: 0.12).cgColor
            blurMarquee.strokeColor = NSColor(srgbRed: 0, green: 0.478, blue: 1, alpha: 0.9).cgColor
            blurMarquee.lineWidth = 1.5
            blurMarquee.lineDashPattern = [5, 3]
            layer?.addSublayer(blurMarquee)
        }
        let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                          width: abs(b.x - a.x), height: abs(b.y - a.y))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        blurMarquee.path = CGPath(rect: rect, transform: nil)
        CATransaction.commit()
    }

    // MARK: - Coordinate transforms

    /// Canvas point → content space (through the zoom inverse; tilt is
    /// intentionally NOT applied — SwiftUI GeometryEffect hit-test parity).
    /// Inverse of the compositor's card camera transform
    /// `T(anchor + cardOffset·canvas) · S(zoom) · T(−anchor)` — the EXACT
    /// forward math of `PreviewCompositorView`'s zoomGroup (and the
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

    private func contentPoint(_ canvasPoint: CGPoint, _ ctx: HitContext) -> CGPoint {
        let unzoomed = Self.inverseCameraPoint(
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

    private func regionPixelRect(_ norm: CGRect, _ ctx: HitContext) -> CGRect {
        let vr = ctx.videoRect
        return CGRect(
            x: vr.minX + norm.minX * vr.width,
            y: vr.minY + norm.minY * vr.height,
            width: max(30, norm.width * vr.width),
            height: max(20, norm.height * vr.height)
        )
    }

    private func activeBlurRegions(_ ctx: HitContext) -> [BlurRegion] {
        ctx.project.blurRegions.filter { isActive($0.startTime, $0.endTime, ctx) }
    }

    private func activeHighlightRegions(_ ctx: HitContext) -> [HighlightRegion] {
        ctx.project.highlightRegions.filter { isActive($0.startTime, $0.endTime, ctx) }
    }

    private func isActive(_ start: TimeInterval, _ end: TimeInterval, _ ctx: HitContext) -> Bool {
        // The interaction layer is only rendered for the currently shown
        // time — the compositor rebuilds HitContext each frame.
        true
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        guard let ctx = context else { return }
        let p = convert(event.locationInWindow, from: nil)
        downPoint = p

        // Click-away COMMITS the in-place edit (Keynote). The click is
        // consumed — ending the edit is that click's whole job; the next
        // click selects or drags as usual. Clicks inside the field itself
        // never reach here (the field is a subview and takes them first).
        if inlineEditor != nil {
            endInlineEdit(commit: true)
            return
        }

        // Armed blur draw wins over everything: the whole point of the mode
        // is that the next drag draws the region, whatever is underneath.
        if let style = armedBlurStyle {
            mode = .blurDraw(style: style)
            return
        }

        // Double-click a text/callout annotation → edit the label in place,
        // matching the behaviour the SwiftUI preview had before the
        // CoreAnimation compositor replaced it.
        if event.clickCount == 2, !ctx.isPlaying {
            let time = currentTimeOf(ctx)
            let cpDouble = contentPoint(p, ctx)
            for a in ctx.project.annotations.reversed()
            where time >= a.startTime && time <= a.endTime {
                guard a.type == .text || a.type == .callout else { continue }
                if annotationHitRect(a, ctx).contains(cpDouble) {
                    onSelectAnnotation?(a.id)
                    onSelectBlur?(nil); onSelectHighlight?(nil); onSelectDepthFocus?(nil)
                    beginInlineEdit(of: a, in: ctx)
                    return
                }
            }
        }

        // 0 — the on-canvas focal target is explicit editing chrome:
        // topmost when a zoom block is selected.
        if let focal = ctx.selectedZoomFocal {
            let cp = contentPoint(p, ctx)
            let center = CGPoint(
                x: ctx.videoRect.minX + focal.x * ctx.videoRect.width,
                y: ctx.videoRect.minY + focal.y * ctx.videoRect.height)
            let grabRadius = 22 / max(1, ctx.zoom)
            if hypot(cp.x - center.x, cp.y - center.y) <= grabRadius {
                mode = .zoomFocal
                return
            }
        }

        // 1 — canvas-level chrome, topmost first (watermark > camera >
        // subtitle, matching compositor z-order).
        if let r = ctx.watermarkRect, r.insetBy(dx: -4, dy: -4).contains(p) {
            mode = .watermark(initial: CGPoint(x: ctx.project.settings.watermarkX, y: ctx.project.settings.watermarkY))
            return
        }
        if let r = ctx.cameraRect, r.contains(p) {
            let s = ctx.project.settings
            let f = (s.cameraCustomX != nil && s.cameraCustomY != nil)
                ? CGPoint(x: s.cameraCustomX!, y: s.cameraCustomY!)
                : ReactiveCameraLayout.fraction(for: s.cameraPosition)
            mode = .camera(initial: f)
            return
        }
        if let r = ctx.subtitleRect, r.insetBy(dx: -6, dy: -6).contains(p) {
            let s = ctx.project.settings
            let f: CGPoint
            if let x = s.subtitleCustomX, let y = s.subtitleCustomY {
                f = CGPoint(x: x, y: y)
            } else {
                switch s.subtitlePosition {
                case .top: f = CGPoint(x: 0.5, y: 0)
                case .center: f = CGPoint(x: 0.5, y: 0.5)
                case .bottom: f = CGPoint(x: 0.5, y: 1)
                }
            }
            mode = .subtitle(initial: f)
            return
        }

        let cp = contentPoint(p, ctx)

        // 2-pre — pen-down on the SELECTED drawing annotation: begin a stroke.
        // Strokes are the only annotation content authored by dragging on the
        // canvas itself, so while a drawing annotation is selected the pen
        // wins over annotation-move and card-placement drags.
        if !ctx.isPlaying,
           let selectedID = ctx.selectedAnnotationID,
           let idx = ctx.project.annotations.firstIndex(where: { $0.id == selectedID }),
           ctx.project.annotations[idx].type == .drawing,
           ctx.videoRect.insetBy(dx: -20, dy: -20).contains(cp) {
            let annotation = ctx.project.annotations[idx]
            let time = currentTimeOf(ctx)
            if time >= annotation.startTime && time <= annotation.endTime {
                let n = normalizedVideoPoint(cp, ctx)
                ctx.project.annotations[idx].drawingStrokes.append([CodablePoint(x: n.x, y: n.y)])
                mode = .draw(id: selectedID)
                requestRender?()
                return
            }
        }

        // 2 — annotations (paused editing, same as the SwiftUI overlay).
        if !ctx.isPlaying {
            let time = currentTimeOf(ctx)
            // 2a — endpoint/corner handles first (they sit on the body edge).
            for annotation in ctx.project.annotations.reversed()
            where time >= annotation.startTime && time <= annotation.endTime {
                if let handle = annotationHandleHit(annotation, at: cp, ctx) {
                    onSelectAnnotation?(annotation.id)
                    onSelectBlur?(nil); onSelectHighlight?(nil); onSelectDepthFocus?(nil)
                    mode = handle
                    return
                }
            }
            for annotation in ctx.project.annotations.reversed()
            where time >= annotation.startTime && time <= annotation.endTime {
                if annotationHitRect(annotation, ctx).contains(cp) {
                    onSelectAnnotation?(annotation.id)
                    onSelectBlur?(nil); onSelectHighlight?(nil); onSelectDepthFocus?(nil)
                    mode = .annotation(
                        id: annotation.id,
                        initial: CGPoint(x: annotation.x, y: annotation.y),
                        initialEnd: CGPoint(x: annotation.arrowEndX, y: annotation.arrowEndY)
                    )
                    return
                }
            }
        }

        // Clicking anything that is NOT an annotation deselects the current
        // one (Keynote) — the contextual toolbar drops back to the add tools
        // and the selection ring disappears. The click still proceeds to
        // whatever it actually hit (region handle, card drag, empty canvas).
        if !ctx.isPlaying, ctx.selectedAnnotationID != nil {
            onSelectAnnotation?(nil)
        }

        // 3 — highlight handles above blur handles (SwiftUI z-order).
        if let hit = hitRegion(cp, ctx) {
            mode = hit
            return
        }

        // Clicking anything that is NOT region chrome (card body, empty
        // canvas) deselects EVERY region type — chrome only renders while
        // selected, so all outlines disappear cleanly on click-away.
        // (The annotation deselect above already covered annotations.)
        if ctx.selectedBlurID != nil || ctx.selectedHighlightID != nil
            || ctx.selectedDepthFocusID != nil {
            if ctx.selectedBlurID != nil { onSelectBlur?(nil) }
            if ctx.selectedHighlightID != nil { onSelectHighlight?(nil) }
            if ctx.selectedDepthFocusID != nil { onSelectDepthFocus?(nil) }
            requestRender?()
        }

        // 4 — card body: placement drag (8pt threshold like SwiftUI).
        if cardHitRect(ctx).contains(cp) {
            // Inside a zoom block the drag composes THAT block's excursion
            // (cardOffsetX/Y — springs home when the block ends). Writing the
            // BASE placement here is the "camera never returns home" bug: the
            // block's look was baked into videoCustomX/Y, invisible while the
            // zoom filled the canvas, and the release sprang back to a
            // polluted off-centre base.
            if let zoomID = ctx.activeZoomID,
               let region = ctx.project.zoomRegions.first(where: { $0.id == zoomID }) {
                mode = .blockOffset(
                    id: zoomID,
                    initial: CGPoint(x: region.cardOffsetX ?? 0, y: region.cardOffsetY ?? 0),
                    moved: false
                )
                return
            }
            // Grab offset: the card must move WITH the pointer from wherever
            // it was grabbed — recentring it under the pointer on the first
            // drag event reads as a jump, not a drag.
            let cardCenter = CGPoint(
                x: ctx.contentRect.minX + ctx.videoRect.midX,
                y: ctx.contentRect.minY + ctx.videoRect.midY
            )
            placementGrabOffset = CGPoint(x: cp.x - cardCenter.x, y: cp.y - cardCenter.y)
            mode = .placement(moved: false)
            return
        }
        mode = .idle
    }

    override func mouseDragged(with event: NSEvent) {
        guard let ctx = context else { return }
        let p = convert(event.locationInWindow, from: nil)
        let s = ctx.project.settings

        switch mode {
        case .idle:
            break

        case .blurDraw:
            updateBlurMarquee(from: downPoint, to: p)

        case .zoomFocal:
            let n = normalizedVideoPoint(contentPoint(p, ctx), ctx)
            onSetZoomFocal?(CGPoint(
                x: max(0, min(1, n.x)),
                y: max(0, min(1, n.y))))
            requestRender?()

        case .camera(let initial):
            // Same normalized origin-interpolation space as the pads.
            guard let rect = ctx.cameraRect else { break }
            let usableW = ctx.canvas.width - 24 * ctx.cameraFitScale - rect.width
            let usableH = ctx.canvas.height - 24 * ctx.cameraFitScale - rect.height
            guard usableW > 0 || usableH > 0 else { break }
            let dx = (p.x - downPoint.x) / max(1, usableW)
            let dy = (p.y - downPoint.y) / max(1, usableH)
            s.cameraCustomX = Double(min(1, max(0, initial.x + dx)))
            s.cameraCustomY = Double(min(1, max(0, initial.y + dy)))
            requestRender?()

        case .watermark(let initial):
            guard let rect = ctx.watermarkRect else { break }
            let usableW = ctx.canvas.width - 40 - rect.width
            let usableH = ctx.canvas.height - 40 - rect.height
            guard usableW > 0 || usableH > 0 else { break }
            let dx = usableW > 0 ? (p.x - downPoint.x) / usableW : 0
            let dy = usableH > 0 ? (p.y - downPoint.y) / usableH : 0
            s.watermarkX = Double(min(1, max(0, initial.x + dx)))
            s.watermarkY = Double(min(1, max(0, initial.y + dy)))
            requestRender?()

        case .subtitle(let initial):
            guard let rect = ctx.subtitleRect else { break }
            let usableW = ctx.canvas.width - 40 - rect.width
            let usableH = ctx.canvas.height - 40 - rect.height
            guard usableW > 0 || usableH > 0 else { break }
            let dx = usableW > 0 ? (p.x - downPoint.x) / usableW : 0
            let dy = usableH > 0 ? (p.y - downPoint.y) / usableH : 0
            s.subtitleCustomX = Double(min(1, max(0, initial.x + dx)))
            s.subtitleCustomY = Double(min(1, max(0, initial.y + dy)))
            requestRender?()

        case .draw(let id):
            guard let idx = ctx.project.annotations.firstIndex(where: { $0.id == id }),
                  !ctx.project.annotations[idx].drawingStrokes.isEmpty else { break }
            let n = normalizedVideoPoint(contentPoint(p, ctx), ctx)
            var strokes = ctx.project.annotations[idx].drawingStrokes
            strokes[strokes.count - 1].append(CodablePoint(x: n.x, y: n.y))
            ctx.project.annotations[idx].drawingStrokes = strokes
            requestRender?()

        case .annotation(let id, let initial, let initialEnd):
            guard let idx = ctx.project.annotations.firstIndex(where: { $0.id == id }) else { break }
            let cp = contentPoint(p, ctx)
            let cpDown = contentPoint(downPoint, ctx)
            var dx = (cp.x - cpDown.x) / max(1, ctx.videoRect.width)
            var dy = (cp.y - cpDown.y) / max(1, ctx.videoRect.height)
            switch ctx.project.annotations[idx].type {
            case .rectangle, .ellipse, .arrow, .callout:
                // Two-point shapes MOVE as a unit — translating only x/y
                // drags one corner while the other stays pinned, which is a
                // resize wearing a move's clothes. Clamp the DELTA so the
                // whole shape stays on the video and its size never changes.
                let minX = min(initial.x, initialEnd.x)
                let maxX = max(initial.x, initialEnd.x)
                let minY = min(initial.y, initialEnd.y)
                let maxY = max(initial.y, initialEnd.y)
                dx = max(-minX, min(1 - maxX, dx))
                dy = max(-minY, min(1 - maxY, dy))
                ctx.project.annotations[idx].x = Double(initial.x + dx)
                ctx.project.annotations[idx].y = Double(initial.y + dy)
                ctx.project.annotations[idx].arrowEndX = Double(initialEnd.x + dx)
                ctx.project.annotations[idx].arrowEndY = Double(initialEnd.y + dy)
            default:
                ctx.project.annotations[idx].x = Double(max(0, min(1, initial.x + dx)))
                ctx.project.annotations[idx].y = Double(max(0, min(1, initial.y + dy)))
            }
            requestRender?()

        case .annotationHandle(let id, let xIsStart, let yIsStart):
            // The handle rides the cursor — same semantics as the SwiftUI
            // endpoint/corner drags (position, not translation).
            guard let idx = ctx.project.annotations.firstIndex(where: { $0.id == id }) else { break }
            let cp = contentPoint(p, ctx)
            let vr = ctx.videoRect
            let nx = Double(max(0, min(1, (cp.x - vr.minX) / max(1, vr.width))))
            let ny = Double(max(0, min(1, (cp.y - vr.minY) / max(1, vr.height))))
            if xIsStart { ctx.project.annotations[idx].x = nx }
            else { ctx.project.annotations[idx].arrowEndX = nx }
            if yIsStart { ctx.project.annotations[idx].y = ny }
            else { ctx.project.annotations[idx].arrowEndY = ny }
            requestRender?()

        case .regionMove(let ref, let initial):
            applyRegionRect(ref, adjust(initial, ctx, p: p, left: false, right: false, top: false, bottom: false, move: true), ctx)

        case .regionResize(let ref, let initial, let l, let r, let t, let b):
            applyRegionRect(ref, adjust(initial, ctx, p: p, left: l, right: r, top: t, bottom: b, move: false), ctx)

        case .regionSlider(let ref, let pillRect):
            // Slider track spans the pill's middle section; map X → value.
            let track = pillRect.insetBy(dx: 27, dy: 0)
            let f = Double(min(1, max(0, (p.x - track.minX) / max(1, track.width))))
            switch ref {
            case .blur(let id):
                if let i = ctx.project.blurRegions.firstIndex(where: { $0.id == id }) {
                    ctx.project.blurRegions[i].intensity = 0.1 + f * 0.9
                }
            case .highlight(let id):
                if let i = ctx.project.highlightRegions.firstIndex(where: { $0.id == id }) {
                    ctx.project.highlightRegions[i].opacity = 0.1 + f * 0.8
                }
            case .depthFocus(let id):
                if let i = ctx.project.focusRegions.firstIndex(where: { $0.id == id }) {
                    ctx.project.focusRegions[i].intensity = 0.1 + f * 0.9
                }
            }
            requestRender?()

        case .blockOffset(let id, let initial, let moved):
            let distance = hypot(p.x - downPoint.x, p.y - downPoint.y)
            if moved || distance >= 8 {
                mode = .blockOffset(id: id, initial: initial, moved: true)
                pushCardGrabCursor()
                guard ctx.canvas.width > 0, ctx.canvas.height > 0,
                      let idx = ctx.project.zoomRegions.firstIndex(where: { $0.id == id })
                else { break }
                // The excursion is applied OUTSIDE the zoom scale (a canvas-
                // space slide of the whole zoomed card), so raw canvas points
                // give 1:1 pointer tracking. Clamped only at the shared
                // safety bound (ZoomFocalMath.cardOffsetLimit — fully
                // off-canvas is allowed; "place anywhere").
                let dx = Double(initial.x + (p.x - downPoint.x) / ctx.canvas.width)
                let dy = Double(initial.y + (p.y - downPoint.y) / ctx.canvas.height)
                ctx.project.zoomRegions[idx].cardOffsetX = ZoomFocalMath.clampCardOffset(dx)
                ctx.project.zoomRegions[idx].cardOffsetY = ZoomFocalMath.clampCardOffset(dy)
                requestRender?()
            }

        case .placement(let moved):
            let distance = hypot(p.x - downPoint.x, p.y - downPoint.y)
            if moved || distance >= 8 {
                mode = .placement(moved: true)
                pushCardGrabCursor()
                guard ctx.canvas.width > 0, ctx.canvas.height > 0 else { break }
                // Freeform: the card CENTRE tracks (pointer − grab offset)
                // 1:1, including past the canvas edges. Magnetism happens
                // once, on mouse-up — snapping DURING the drag is what made
                // placement feel like it fought the user.
                let range = PlacementMath.customFractionRange
                // Zoom-corrected pointer, SAME space as the grab offset
                // (mouseDown computed it from contentPoint). Mixing raw `p`
                // with a content-space offset made the card jump on grab and
                // track at the wrong rate whenever a zoom effect was active.
                let cp = contentPoint(p, ctx)
                let fx = (cp.x - placementGrabOffset.x) / ctx.canvas.width
                let fy = (cp.y - placementGrabOffset.y) / ctx.canvas.height
                ctx.project.settings.videoCustomX = Double(min(range.upperBound, max(range.lowerBound, fx)))
                ctx.project.settings.videoCustomY = Double(min(range.upperBound, max(range.lowerBound, fy)))
                requestRender?()
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let ctx = context else { mode = .idle; return }
        let s = ctx.project.settings
        switch mode {
        case .blurDraw(let style):
            // Normalize both endpoints through the SAME zoom/tilt inverse the
            // region editing handles use, so the drawn rect lands exactly
            // where the marquee showed it.
            let a = normalizedVideoPoint(contentPoint(downPoint, ctx), ctx)
            let b = normalizedVideoPoint(contentPoint(convert(event.locationInWindow, from: nil), ctx), ctx)
            var rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                              width: abs(b.x - a.x), height: abs(b.y - a.y))
            if rect.width < minNormSize || rect.height < minNormSize {
                // A click (or a sliver) still works: grow to the minimum
                // around the pointer instead of silently doing nothing.
                let cx = rect.midX, cy = rect.midY
                let w = max(rect.width, minNormSize * 2), h = max(rect.height, minNormSize * 2)
                rect = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
            }
            rect = rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            cancelBlurDraw()
            if !rect.isNull, rect.width > 0.005, rect.height > 0.005 {
                onCreateBlurRegion?(rect, style)
            }
        case .camera:
            // Corner magnetism collapses back to the clean enum.
            if let x = s.cameraCustomX, let y = s.cameraCustomY {
                for corner in ProjectSettings.CameraPosition.allCases {
                    let f = ReactiveCameraLayout.fraction(for: corner)
                    if abs(f.x - x) < 0.06 && abs(f.y - y) < 0.06 {
                        s.cameraPosition = corner
                        s.cameraCustomX = nil
                        s.cameraCustomY = nil
                        break
                    }
                }
            }
            requestRender?()
        case .watermark:
            if abs(s.watermarkX) < 0.04 { s.watermarkX = 0 }
            if abs(s.watermarkX - 1) < 0.04 { s.watermarkX = 1 }
            if abs(s.watermarkY) < 0.04 { s.watermarkY = 0 }
            if abs(s.watermarkY - 1) < 0.04 { s.watermarkY = 1 }
            requestRender?()
        case .subtitle:
            if let x = s.subtitleCustomX, let y = s.subtitleCustomY, abs(x - 0.5) < 0.06 {
                let anchors: [(ProjectSettings.SubtitlePosition, Double)] = [(.top, 0), (.center, 0.5), (.bottom, 1)]
                for (anchor, fy) in anchors where abs(y - fy) < 0.06 {
                    s.subtitlePosition = anchor
                    s.subtitleCustomX = nil
                    s.subtitleCustomY = nil
                    break
                }
            }
            requestRender?()
        case .blockOffset(let id, _, let moved):
            // Rest magnetism: a near-zero excursion collapses to nil (no
            // offset at all) — same threshold the MCP set_style path uses.
            if moved, let idx = ctx.project.zoomRegions.firstIndex(where: { $0.id == id }) {
                if let x = ctx.project.zoomRegions[idx].cardOffsetX, abs(x) < 0.005 {
                    ctx.project.zoomRegions[idx].cardOffsetX = nil
                }
                if let y = ctx.project.zoomRegions[idx].cardOffsetY, abs(y) < 0.005 {
                    ctx.project.zoomRegions[idx].cardOffsetY = nil
                }
            }
            requestRender?()
        case .placement(let moved):
            // Grid magnetism on drop only: near one of the nine anchors the
            // freeform position collapses back to the clean enum (mirrors the
            // camera's corner magnetism); anywhere else it stays exactly where
            // the user put it.
            // Only the CENTER anchor magnetizes: a centred custom position and
            // the centre enum render identically, so the collapse is invisible.
            // Edge/corner anchors position differently (padding vs full-range)
            // and collapsing to them would make the card jump on release.
            if moved, let x = s.videoCustomX, let y = s.videoCustomY,
               abs(x - 0.5) < PlacementMath.magnetism,
               abs(y - 0.5) < PlacementMath.magnetism {
                s.videoPlacement = .center
                s.videoCustomX = nil
                s.videoCustomY = nil
            }
            requestRender?()
        default:
            break
        }
        mode = .idle
        popCardGrabCursor()
        // One more render AFTER the drag flag clears: live drags raster the
        // annotations at 1x for responsiveness (see renderAnnotations), and
        // this pass re-rasters them crisp at full scale.
        requestRender?()
        // The shell hides the contextual toolbar during drags and nothing
        // observable changes on mouse-up — tell it explicitly to reappear.
        onDragEnded?()
    }

    /// Fired after a canvas drag completes (see mouseUp).
    var onDragEnded: (() -> Void)?

    /// Closed-hand while a card drag (placement or blockOffset) is actively
    /// moving — subtle confirmation the gesture is grabbing the card, not a
    /// dead click. Idempotent; balanced by popCardGrabCursor on mouse-up.
    private func pushCardGrabCursor() {
        guard !cardGrabCursorPushed else { return }
        cardGrabCursorPushed = true
        NSCursor.closedHand.push()
    }

    private func popCardGrabCursor() {
        guard cardGrabCursorPushed else { return }
        cardGrabCursorPushed = false
        NSCursor.pop()
    }

    /// The ONE deselect path: clears every selectable object type. Used by
    /// empty-canvas / card-body clicks and by Esc — total exclusivity.
    private func deselectAll(_ ctx: HitContext) {
        var changed = false
        if ctx.selectedBlurID != nil { onSelectBlur?(nil); changed = true }
        if ctx.selectedHighlightID != nil { onSelectHighlight?(nil); changed = true }
        if ctx.selectedDepthFocusID != nil { onSelectDepthFocus?(nil); changed = true }
        if ctx.selectedAnnotationID != nil { onSelectAnnotation?(nil); changed = true }
        if changed { requestRender?() }
    }

    /// Esc — deselect everything, matching the click-away contract.
    override func cancelOperation(_ sender: Any?) {
        if armedBlurStyle != nil {
            cancelBlurDraw()
            mode = .idle
            return
        }
        guard let ctx = context else { return }
        deselectAll(ctx)
    }

    /// True while a mouse drag is mutating geometry — the compositor drops
    /// the annotation raster to 1x for the duration, which is what keeps
    /// direct manipulation at mouse-move rate.
    var isActivelyDragging: Bool {
        if case .idle = mode { return false }
        return true
    }

    // MARK: - Region hit testing (port of BlurRegionHandle/HighlightRegionHandle)

    private func currentTimeOf(_ ctx: HitContext) -> TimeInterval {
        // HitContext is rebuilt per frame; annotations/regions passed are the
        // project's — filter with the compositor's shown time.
        (superview as? PreviewCompositorView)?.pendingInput?.currentTime ?? 0
    }

    private func cardHitRect(_ ctx: HitContext) -> CGRect {
        ctx.videoRect
    }

    /// Arrow endpoints and shape corners — hit before the body, 12pt radius
    /// (matches the SwiftUI 14pt handle circles' effective target).
    private func annotationHandleHit(_ a: Annotation, at cp: CGPoint, _ ctx: HitContext) -> DragMode? {
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

    private func normalizedVideoPoint(_ cp: CGPoint, _ ctx: HitContext) -> CGPoint {
        let vr = ctx.videoRect
        return CGPoint(
            x: min(1, max(0, (cp.x - vr.minX) / max(1, vr.width))),
            y: min(1, max(0, (cp.y - vr.minY) / max(1, vr.height)))
        )
    }

    /// The selected annotation's rect in THIS VIEW's coordinates — content
    /// rect pushed through the zoom transform (tilt deliberately ignored; the
    /// shell hangs the contextual toolbar off this and an approximate anchor
    /// under a tilted card is fine). Nil when nothing is selected.
    func selectedAnnotationViewRect() -> CGRect? {
        guard let ctx = context, let id = ctx.selectedAnnotationID,
              let a = ctx.project.annotations.first(where: { $0.id == id }) else { return nil }
        let r = annotationHitRect(a, ctx)
            .offsetBy(dx: ctx.contentRect.minX, dy: ctx.contentRect.minY)
        let z = max(0.01, ctx.zoom)
        let ax = ctx.zoomAnchor.x, ay = ctx.zoomAnchor.y
        return CGRect(
            x: ax + (r.minX - ax) * z,
            y: ay + (r.minY - ay) * z,
            width: r.width * z,
            height: r.height * z
        )
    }

    private func annotationHitRect(_ a: Annotation, _ ctx: HitContext) -> CGRect {
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

    private func hitRegion(_ cp: CGPoint, _ ctx: HitContext) -> DragMode? {
        let time = currentTimeOf(ctx)
        // Highlights on top (drawn after blur overlays in SwiftUI).
        for region in ctx.project.highlightRegions.reversed()
        where time >= region.startTime && time <= region.endTime {
            if let mode = regionDragMode(
                cp, rect: region.rect, ref: .highlight(region.id),
                isSelected: ctx.selectedHighlightID == region.id, ctx: ctx,
                select: { self.onSelectHighlight?(region.id); self.onSelectBlur?(nil) }
            ) { return mode }
        }
        for region in ctx.project.focusRegions.reversed()
        where time >= region.startTime && time <= region.endTime {
            if let mode = regionDragMode(
                cp, rect: region.rect, ref: .depthFocus(region.id),
                isSelected: ctx.selectedDepthFocusID == region.id, ctx: ctx,
                select: {
                    self.onSelectDepthFocus?(region.id)
                    self.onSelectHighlight?(nil)
                    self.onSelectBlur?(nil)
                }
            ) { return mode }
        }
        for region in ctx.project.blurRegions.reversed()
        where time >= region.startTime && time <= region.endTime {
            if let mode = regionDragMode(
                cp, rect: region.rect, ref: .blur(region.id),
                isSelected: ctx.selectedBlurID == region.id, ctx: ctx,
                select: {
                    self.onSelectBlur?(region.id)
                    self.onSelectHighlight?(nil)
                    self.onSelectDepthFocus?(nil)
                }
            ) { return mode }
        }
        return nil
    }

    private func regionDragMode(
        _ cp: CGPoint, rect norm: CGRect, ref: RegionRef,
        isSelected: Bool, ctx: HitContext, select: () -> Void
    ) -> DragMode? {
        let r = regionPixelRect(norm, ctx)

        if isSelected {
            // Value pill (below the region, RegionPillPlacement) — slider drag.
            let pill = pillRect(for: r, ctx)
            if pill.contains(cp) {
                select()
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
                select()
                return .regionResize(ref, initial: norm, left: m.0, right: m.1, top: m.2, bottom: m.3)
            }
            let edges: [(CGRect, (Bool, Bool, Bool, Bool))] = [
                (CGRect(x: r.minX + 16, y: r.minY - 9, width: max(30, r.width - 32), height: 18), (false, false, true, false)),
                (CGRect(x: r.minX + 16, y: r.maxY - 9, width: max(30, r.width - 32), height: 18), (false, false, false, true)),
                (CGRect(x: r.minX - 9, y: r.minY + 14, width: 18, height: max(24, r.height - 28)), (true, false, false, false)),
                (CGRect(x: r.maxX - 9, y: r.minY + 14, width: 18, height: max(24, r.height - 28)), (false, true, false, false)),
            ]
            for (zone, m) in edges where zone.contains(cp) {
                select()
                return .regionResize(ref, initial: norm, left: m.0, right: m.1, top: m.2, bottom: m.3)
            }
        }

        if r.contains(cp) {
            select()
            return .regionMove(ref, initial: norm)
        }
        return nil
    }

    /// Pill rect for a selected region — RegionPillPlacement.offset port
    /// (below the region when it fits, tucked inside the bottom edge when
    /// not, clamped horizontally to the container).
    private func pillRect(for r: CGRect, _ ctx: HitContext) -> CGRect {
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

    private func adjust(
        _ initial: CGRect, _ ctx: HitContext, p: CGPoint,
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

    private func applyRegionRect(_ ref: RegionRef, _ rect: CGRect, _ ctx: HitContext) {
        switch ref {
        case .blur(let id):
            if let i = ctx.project.blurRegions.firstIndex(where: { $0.id == id }) {
                ctx.project.blurRegions[i].rect = rect
            }
        case .highlight(let id):
            if let i = ctx.project.highlightRegions.firstIndex(where: { $0.id == id }) {
                ctx.project.highlightRegions[i].rect = rect
            }
        case .depthFocus(let id):
            if let i = ctx.project.focusRegions.firstIndex(where: { $0.id == id }) {
                ctx.project.focusRegions[i].rect = rect
            }
        }
        requestRender?()
    }
}

// MARK: - In-place label editing

/// Double-clicking a text/callout annotation drops a real NSTextField over it,
/// styled to match what the compositor draws, so the label can be edited on the
/// canvas exactly as it could in the SwiftUI preview. Committing writes back to
/// the model and tears the field down.
extension PreviewInteractionView {
    /// Entry for the floating pill: adding a text/callout drops straight into
    /// the same in-place editor double-click reaches, with the placeholder
    /// selected and ready to overtype — no double-click hunting.
    /// `ctx.project` is the live model object, so the annotation appended a
    /// moment ago resolves even before the next rendered frame refreshes ctx.
    func beginInlineEdit(annotationID: UUID) {
        guard let ctx = context,
              let a = ctx.project.annotations.first(where: { $0.id == annotationID }),
              a.type == .text || a.type == .callout else { return }
        beginInlineEdit(of: a, in: ctx)
    }

    func beginInlineEdit(of annotation: Annotation, in ctx: HitContext) {
        endInlineEdit(commit: true)

        // Geometry comes from the RENDERER's own labelRect, pushed through the
        // zoom BY HAND (scale about the zoom anchor, font and pads scaled the
        // same way). The old approach mirrored the compositor's transforms on
        // layer-backed container views — but AppKit owns the backing layer of
        // a layer-backed view and resets its transform during layout, so with
        // an active zoom effect the editor landed at the UNZOOMED spot: the
        // "double-click and it moves" bug. Hand-computed geometry cannot be
        // clobbered. (Tilt is deliberately approximated as identity here.)
        let content = AnnotationRenderer.labelRect(
            annotation, videoRect: ctx.videoRect, scale: 1
        ) ?? annotationHitRect(annotation, ctx)
        let z = max(0.01, ctx.zoom)
        let inView = content.offsetBy(dx: ctx.contentRect.minX, dy: ctx.contentRect.minY)
        let zoomed = CGRect(
            x: ctx.zoomAnchor.x + (inView.minX - ctx.zoomAnchor.x) * z,
            y: ctx.zoomAnchor.y + (inView.minY - ctx.zoomAnchor.y) * z,
            width: inView.width * z,
            height: inView.height * z
        )

        // Two views, not one: the BACKING carries the annotation's pill
        // (background + accent editing ring) at the exact drawn rect, and the
        // FIELD is transparent and glyph-sized inside it — so entering edit
        // mode does not shift the text by the field's own cell padding.
        // The compositor omits the drawn annotation meanwhile (Chrome.editingID).
        let pads = CGSize(
            width: (annotation.type == .text ? 10 : 12) * z,
            height: (annotation.type == .text ? 6 : 8) * z
        )
        let bg = annotation.backgroundColor
        let showsBG = annotation.type == .callout || annotation.showBackground

        let backing = NSView(frame: zoomed)
        backing.wantsLayer = true
        backing.layer?.backgroundColor = showsBG
            ? NSColor(srgbRed: bg.red, green: bg.green, blue: bg.blue, alpha: bg.opacity).cgColor
            : NSColor.clear.cgColor
        backing.layer?.cornerRadius = max(0, annotation.cornerRadius) * z
        backing.layer?.cornerCurve = .continuous
        backing.layer?.borderWidth = 1.5
        backing.layer?.borderColor = NSColor(srgbRed: 0, green: 0.478, blue: 1, alpha: 1).cgColor

        // 4px wider than the measured glyphs on each side: NSTextField's cell
        // has its own ~2px inset, and a field exactly glyph-width WRAPS its
        // own text — the second line then renders outside the pill (the
        // "label sticking out of the box" bug the probe reproduces).
        let field = NSTextField(frame: zoomed
            .insetBy(dx: pads.width, dy: pads.height)
            .insetBy(dx: -4, dy: -1))
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.stringValue = annotation.text
        field.font = FontCatalog.font(
            named: annotation.fontName,
            size: max(10, annotation.fontSize) * z,
            weight: annotation.fontWeight.nsWeight
        )
        field.textColor = NSColor(
            srgbRed: annotation.color.red, green: annotation.color.green,
            blue: annotation.color.blue, alpha: 1
        )
        field.alignment = .center
        field.isBordered = false
        field.focusRingType = .none
        field.drawsBackground = false
        field.delegate = self
        field.target = self
        field.action = #selector(inlineEditCommitted(_:))

        addSubview(backing)
        addSubview(field)
        inlineEditContainer = nil
        inlineEditBacking = backing
        inlineEditor = field
        inlineEditingID = annotation.id
        inlineEditCenter = CGPoint(x: zoomed.midX, y: zoomed.midY)
        inlineEditPads = pads
        window?.makeFirstResponder(field)
        // Re-render so the compositor omits the drawn annotation NOW —
        // otherwise the field sits on a translucent twin until the next frame.
        requestRender?()
    }

    @objc func inlineEditCommitted(_ sender: NSTextField) {
        endInlineEdit(commit: true)
    }

    /// Commit (or discard) and remove the field. Safe to call repeatedly.
    func endInlineEdit(commit: Bool) {
        guard let field = inlineEditor, let id = inlineEditingID else { return }
        inlineEditor = nil
        inlineEditingID = nil
        inlineEditCenter = nil
        inlineEditPads = nil
        inlineEditBacking?.removeFromSuperview()
        inlineEditBacking = nil
        if commit, let ctx = context,
           let idx = ctx.project.annotations.firstIndex(where: { $0.id == id }) {
            ctx.project.annotations[idx].text = field.stringValue
        }
        if field.currentEditor() != nil { window?.makeFirstResponder(self) }
        field.removeFromSuperview()
        inlineEditContainer?.removeFromSuperview()
        inlineEditContainer = nil
        requestRender?()
    }
}

extension PreviewInteractionView: NSTextFieldDelegate {
    /// Keynote-style: the pill grows symmetrically about its center as the
    /// user types, instead of clipping or left-aligning into a fixed box.
    func controlTextDidChange(_ obj: Notification) {
        guard let field = inlineEditor, let center = inlineEditCenter,
              let pads = inlineEditPads, let font = field.font else { return }
        let measured = NSAttributedString(
            string: field.stringValue.isEmpty ? " " : field.stringValue,
            attributes: [.font: font]
        ).size()
        // Same +4/+1 cell allowance as at open — see beginInlineEdit.
        let w = max(16, measured.width) + 8
        let h = max(12, measured.height) + 2
        field.frame = CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
        inlineEditBacking?.frame = field.frame
            .insetBy(dx: 4, dy: 1)
            .insetBy(dx: -pads.width, dy: -pads.height)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            endInlineEdit(commit: false)
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            endInlineEdit(commit: true)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        endInlineEdit(commit: true)
    }
}


/// y-down container so children position the same way this view does.
final class FlippedContainer: NSView {
    override var isFlipped: Bool { true }
}
