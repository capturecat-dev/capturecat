import CoreGraphics
import Foundation

/// What the gesture core needs from the platform view that hosts it — the
/// Mac `PreviewInteractionView` (mouse, NSCursor, NSTextField) or the iOS
/// touch surface. Everything here is presentation; every decision about
/// what a press grabbed and what a drag writes stays in the core.
protocol PreviewGestureHost: AnyObject {
    /// The compositor's shown time (the frame the hit context describes).
    var gestureCurrentTime: TimeInterval { get }
    /// The undo stack the stack-seam drag registers on.
    var gestureUndoManager: UndoManager? { get }
    /// True while the in-place label editor is open.
    var gestureIsInlineEditing: Bool { get }
    func gestureEndInlineEdit(commit: Bool)
    func gestureBeginInlineEdit(of annotation: Annotation, in ctx: PreviewHitContext)
    /// The armed blur draw's rubber band, canvas space.
    func gestureUpdateBlurMarquee(from a: CGPoint, to b: CGPoint)
    /// A blur draw was armed (from disarmed) / disarmed — pointer + marquee.
    func gestureBlurDrawArmed()
    func gestureBlurDrawDisarmed()
    /// The card is being grabbed (true) / released (false). Balanced.
    func gestureSetCardGrab(_ grabbing: Bool)
    /// Re-place the stack resize notch for the pointer (nil = hide).
    func gestureUpdateStackNotch(pointer: CGPoint?)
}

/// The preview's on-canvas gesture state machine, platform-neutral
/// (docs/ios-studio-plan.md Phase 1d): one press → drag → release cascade
/// shared by the Mac mouse and the iOS touch front ends, so both grab the
/// same target and write the same model values. Moved verbatim from
/// PreviewInteractionView's mouseDown / mouseDragged / mouseUp; points are
/// canvas space (the host view's own, Y-down). Frozen by
/// `--preview-gesture-test`.
///
/// Writes go to the same Project / ProjectSettings properties the editor's
/// other surfaces write; selection and creation go out through callbacks.
final class PreviewGestureCore {
    weak var host: PreviewGestureHost?

    var context: PreviewHitContext?
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
    /// Fired after a canvas drag completes (see pointerUp).
    var onDragEnded: (() -> Void)?

    private(set) var mode: PreviewDragMode = .idle
    private var downPoint: CGPoint = .zero
    /// True while the card-grab affordance is up for a card drag
    /// (placement or blockOffset). Set/clear must stay balanced.
    private var cardGrabbing = false
    /// Pointer − card-centre at drag start, so the card moves with the
    /// pointer instead of jumping to centre itself under it.
    private var placementGrabOffset: CGPoint = .zero
    /// Non-nil while the next press should start a rubber-band blur draw
    /// instead of the normal hit-test cascade.
    private var armedBlurStyle: BlurStyle?

    /// True while a drag is mutating geometry — the compositor drops the
    /// annotation raster to 1x for the duration, which is what keeps direct
    /// manipulation at pointer-move rate.
    var isActivelyDragging: Bool {
        if case .idle = mode { return false }
        return true
    }

    var isStackResizing: Bool {
        if case .stackResize = mode { return true }
        return false
    }

    private var currentTime: TimeInterval { host?.gestureCurrentTime ?? 0 }

    // MARK: - Armed blur draw (popover → drag out a region)

    /// Arm one drag-to-draw pass; the next press-drag-release on the video
    /// creates a region via onCreateBlurRegion.
    func armBlurDraw(style: BlurStyle) {
        if armedBlurStyle == nil { host?.gestureBlurDrawArmed() }
        armedBlurStyle = style
    }

    /// Disarm without creating anything (Esc, or a click outside the video).
    func cancelBlurDraw() {
        guard armedBlurStyle != nil else { return }
        armedBlurStyle = nil
        host?.gestureBlurDrawDisarmed()
    }

    // MARK: - Press

    func pointerDown(at p: CGPoint, clickCount: Int) {
        guard let ctx = context else { return }
        downPoint = p

        // Click-away COMMITS the in-place edit. The click is
        // consumed — ending the edit is that click's whole job; the next
        // click selects or drags as usual. Clicks inside the field itself
        // never reach here (the field is a subview and takes them first).
        if host?.gestureIsInlineEditing == true {
            host?.gestureEndInlineEdit(commit: true)
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
        if clickCount == 2, !ctx.isPlaying {
            let time = currentTime
            let cpDouble = PreviewHitMath.contentPoint(p, ctx)
            for a in ctx.project.annotations.reversed()
            where time >= a.startTime && time <= a.endTime {
                guard a.type == .text || a.type == .callout else { continue }
                if PreviewHitMath.annotationHitRect(a, ctx).contains(cpDouble) {
                    onSelectAnnotation?(a.id)
                    onSelectBlur?(nil); onSelectHighlight?(nil); onSelectDepthFocus?(nil)
                    host?.gestureBeginInlineEdit(of: a, in: ctx)
                    return
                }
            }
        }

        // 0 — the on-canvas focal target is explicit editing chrome:
        // topmost when a zoom block is selected.
        if let focal = ctx.selectedZoomFocal {
            let cp = PreviewHitMath.contentPoint(p, ctx)
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
        // Vertical stack: the seam (or the notch on it) resizes the rows;
        // the stacked camera row itself is not a draggable bubble.
        if let stack = ctx.stack {
            if PreviewHitMath.stackSeamHit(p, stack) {
                mode = .stackResize(initial: ctx.project.settings.cameraStackRatio)
                return
            }
            if stack.cameraRow.contains(p) { return }
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

        let cp = PreviewHitMath.contentPoint(p, ctx)

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
            let time = currentTime
            if time >= annotation.startTime && time <= annotation.endTime {
                let n = PreviewHitMath.normalizedVideoPoint(cp, ctx)
                ctx.project.annotations[idx].drawingStrokes.append([CodablePoint(x: n.x, y: n.y)])
                mode = .draw(id: selectedID)
                requestRender?()
                return
            }
        }

        // 2 — annotations (paused editing, same as the SwiftUI overlay).
        if !ctx.isPlaying {
            let time = currentTime
            // 2a — endpoint/corner handles first (they sit on the body edge).
            for annotation in ctx.project.annotations.reversed()
            where time >= annotation.startTime && time <= annotation.endTime {
                if let handle = PreviewHitMath.annotationHandleHit(annotation, at: cp, ctx) {
                    onSelectAnnotation?(annotation.id)
                    onSelectBlur?(nil); onSelectHighlight?(nil); onSelectDepthFocus?(nil)
                    mode = handle
                    return
                }
            }
            for annotation in ctx.project.annotations.reversed()
            where time >= annotation.startTime && time <= annotation.endTime {
                if PreviewHitMath.annotationHitRect(annotation, ctx).contains(cp) {
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
        // one — the contextual toolbar drops back to the add tools
        // and the selection ring disappears. The click still proceeds to
        // whatever it actually hit (region handle, card drag, empty canvas).
        if !ctx.isPlaying, ctx.selectedAnnotationID != nil {
            onSelectAnnotation?(nil)
        }

        // 3 — highlight handles above blur handles (SwiftUI z-order).
        if let hit = PreviewHitMath.hitRegion(cp, ctx, time: currentTime) {
            selectRegion(hit.ref)
            mode = hit.mode
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
        if PreviewHitMath.cardHitRect(ctx).contains(cp) {
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

    /// Selecting a region clears the other region kinds it outranks — the
    /// exact callback sequence each region's handle always sent.
    private func selectRegion(_ ref: PreviewRegionRef) {
        switch ref {
        case .highlight(let id):
            onSelectHighlight?(id); onSelectBlur?(nil)
        case .depthFocus(let id):
            onSelectDepthFocus?(id)
            onSelectHighlight?(nil)
            onSelectBlur?(nil)
        case .blur(let id):
            onSelectBlur?(id)
            onSelectHighlight?(nil)
            onSelectDepthFocus?(nil)
        }
    }

    // MARK: - Drag

    func pointerDragged(to p: CGPoint) {
        guard let ctx = context else { return }
        let s = ctx.project.settings

        switch mode {
        case .idle:
            break

        case .blurDraw:
            host?.gestureUpdateBlurMarquee(from: downPoint, to: p)

        case .zoomFocal:
            let n = PreviewHitMath.normalizedVideoPoint(PreviewHitMath.contentPoint(p, ctx), ctx)
            onSetZoomFocal?(CGPoint(
                x: max(0, min(1, n.x)),
                y: max(0, min(1, n.y))))
            requestRender?()

        case .stackResize:
            guard let stack = ctx.stack else { break }
            s.cameraStackRatio = CameraLayoutMath.stackRatio(
                PreviewHitMath.stackRatio(at: p.y, area: stack.area, gap: stack.gap))
            requestRender?()
            host?.gestureUpdateStackNotch(pointer: p)

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
            let n = PreviewHitMath.normalizedVideoPoint(PreviewHitMath.contentPoint(p, ctx), ctx)
            var strokes = ctx.project.annotations[idx].drawingStrokes
            strokes[strokes.count - 1].append(CodablePoint(x: n.x, y: n.y))
            ctx.project.annotations[idx].drawingStrokes = strokes
            requestRender?()

        case .annotation(let id, let initial, let initialEnd):
            guard let idx = ctx.project.annotations.firstIndex(where: { $0.id == id }) else { break }
            let cp = PreviewHitMath.contentPoint(p, ctx)
            let cpDown = PreviewHitMath.contentPoint(downPoint, ctx)
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
            let cp = PreviewHitMath.contentPoint(p, ctx)
            let vr = ctx.videoRect
            let nx = Double(max(0, min(1, (cp.x - vr.minX) / max(1, vr.width))))
            let ny = Double(max(0, min(1, (cp.y - vr.minY) / max(1, vr.height))))
            if xIsStart { ctx.project.annotations[idx].x = nx }
            else { ctx.project.annotations[idx].arrowEndX = nx }
            if yIsStart { ctx.project.annotations[idx].y = ny }
            else { ctx.project.annotations[idx].arrowEndY = ny }
            requestRender?()

        case .regionMove(let ref, let initial):
            applyRegionRect(ref, PreviewHitMath.adjust(
                initial, ctx, p: p, downPoint: downPoint,
                left: false, right: false, top: false, bottom: false, move: true), ctx)

        case .regionResize(let ref, let initial, let l, let r, let t, let b):
            applyRegionRect(ref, PreviewHitMath.adjust(
                initial, ctx, p: p, downPoint: downPoint,
                left: l, right: r, top: t, bottom: b, move: false), ctx)

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
                beginCardGrab()
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
                beginCardGrab()
                guard ctx.canvas.width > 0, ctx.canvas.height > 0 else { break }
                // Freeform: the card CENTRE tracks (pointer − grab offset)
                // 1:1, including past the canvas edges. Magnetism happens
                // once, on release — snapping DURING the drag is what made
                // placement feel like it fought the user.
                let range = PlacementMath.customFractionRange
                // Zoom-corrected pointer, SAME space as the grab offset
                // (pointerDown computed it from contentPoint). Mixing raw `p`
                // with a content-space offset made the card jump on grab and
                // track at the wrong rate whenever a zoom effect was active.
                let cp = PreviewHitMath.contentPoint(p, ctx)
                let fx = (cp.x - placementGrabOffset.x) / ctx.canvas.width
                let fy = (cp.y - placementGrabOffset.y) / ctx.canvas.height
                ctx.project.settings.videoCustomX = Double(min(range.upperBound, max(range.lowerBound, fx)))
                ctx.project.settings.videoCustomY = Double(min(range.upperBound, max(range.lowerBound, fy)))
                requestRender?()
            }
        }
    }

    // MARK: - Release

    func pointerUp(at p: CGPoint) {
        guard let ctx = context else { mode = .idle; return }
        let s = ctx.project.settings
        switch mode {
        case .blurDraw(let style):
            // Normalize both endpoints through the SAME zoom/tilt inverse the
            // region editing handles use, so the drawn rect lands exactly
            // where the marquee showed it.
            let a = PreviewHitMath.normalizedVideoPoint(PreviewHitMath.contentPoint(downPoint, ctx), ctx)
            let b = PreviewHitMath.normalizedVideoPoint(PreviewHitMath.contentPoint(p, ctx), ctx)
            var rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                              width: abs(b.x - a.x), height: abs(b.y - a.y))
            let minNormSize = PreviewHitMath.minNormSize
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
        case .stackResize(let initial):
            // One undo step per drag, back to the ratio at the press.
            let settings = s
            let after = s.cameraStackRatio
            if after != initial {
                UndoStep.register(host?.gestureUndoManager, target: settings, name: String(localized: "Camera Height", comment: "Undo action name: dragging the camera stack height"),
                                  undo: { $0.cameraStackRatio = initial }, redo: { $0.cameraStackRatio = after })
            }
            _ = after
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
        endCardGrab()
        // One more render AFTER the drag flag clears: live drags raster the
        // annotations at 1x for responsiveness (see renderAnnotations), and
        // this pass re-rasters them crisp at full scale.
        requestRender?()
        // The shell hides the contextual toolbar during drags and nothing
        // observable changes on release — tell it explicitly to reappear.
        onDragEnded?()
    }

    // MARK: - Esc / deselect

    /// The ONE deselect path: clears every selectable object type. Used by
    /// Esc — total exclusivity.
    func deselectAll(_ ctx: PreviewHitContext) {
        var changed = false
        if ctx.selectedBlurID != nil { onSelectBlur?(nil); changed = true }
        if ctx.selectedHighlightID != nil { onSelectHighlight?(nil); changed = true }
        if ctx.selectedDepthFocusID != nil { onSelectDepthFocus?(nil); changed = true }
        if ctx.selectedAnnotationID != nil { onSelectAnnotation?(nil); changed = true }
        if changed { requestRender?() }
    }

    /// Esc — disarm a pending blur draw, else deselect everything (the
    /// click-away contract).
    func cancel() {
        if armedBlurStyle != nil {
            cancelBlurDraw()
            mode = .idle
            return
        }
        guard let ctx = context else { return }
        deselectAll(ctx)
    }

    // MARK: - Card grab affordance

    /// Grab affordance while a card drag (placement or blockOffset) is
    /// actively moving — subtle confirmation the gesture is grabbing the
    /// card, not a dead click. Idempotent; balanced by endCardGrab.
    private func beginCardGrab() {
        guard !cardGrabbing else { return }
        cardGrabbing = true
        host?.gestureSetCardGrab(true)
    }

    private func endCardGrab() {
        guard cardGrabbing else { return }
        cardGrabbing = false
        host?.gestureSetCardGrab(false)
    }

    // MARK: - Region writes

    private func applyRegionRect(_ ref: PreviewRegionRef, _ rect: CGRect, _ ctx: PreviewHitContext) {
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
