import AppKit

/// The compositor's edit-gesture surface on the Mac — a transparent NSView
/// above the layer tree. Since Studio 1d the gesture LOGIC (what a press
/// grabbed, what a drag writes, magnetism on release) is the platform-neutral
/// `PreviewGestureCore` over `PreviewHitMath`; this view is the mouse front
/// end: it turns NSEvents into canvas points and supplies what only AppKit
/// has — cursors, the blur-draw marquee, the stack notch's hover, the undo
/// manager and the in-place NSTextField editor. Visual chrome
/// (outlines/handles/pills) is rendered by the compositor, so this view
/// draws nothing else.
///
/// Coordinate rules mirror SwiftUI hit-testing exactly: `scaleEffect` (the
/// card zoom) transforms hit geometry, `GeometryEffect` (the tilt) does NOT —
/// so content-space targets are hit through the zoom inverse only.
final class PreviewInteractionView: NSView {
    typealias HitContext = PreviewHitContext
    typealias StackSeam = PreviewStackSeam
    typealias RegionRef = PreviewRegionRef

    /// The shared press → drag → release state machine.
    let gestures = PreviewGestureCore()

    var context: HitContext? {
        get { gestures.context }
        set { gestures.context = newValue }
    }
    var onSelectHighlight: ((UUID?) -> Void)? {
        get { gestures.onSelectHighlight }
        set { gestures.onSelectHighlight = newValue }
    }
    var onSelectAnnotation: ((UUID?) -> Void)? {
        get { gestures.onSelectAnnotation }
        set { gestures.onSelectAnnotation = newValue }
    }
    var onSelectBlur: ((UUID?) -> Void)? {
        get { gestures.onSelectBlur }
        set { gestures.onSelectBlur = newValue }
    }
    var onSelectDepthFocus: ((UUID?) -> Void)? {
        get { gestures.onSelectDepthFocus }
        set { gestures.onSelectDepthFocus = newValue }
    }
    /// Drag of the on-canvas focal target — unit point in video space.
    var onSetZoomFocal: ((CGPoint) -> Void)? {
        get { gestures.onSetZoomFocal }
        set { gestures.onSetZoomFocal = newValue }
    }
    /// Fired when an armed blur draw completes — normalized video-space rect
    /// plus the style picked in the popover. The timeline owns creation.
    var onCreateBlurRegion: ((CGRect, BlurStyle) -> Void)? {
        get { gestures.onCreateBlurRegion }
        set { gestures.onCreateBlurRegion = newValue }
    }
    /// Ask the compositor to re-render after a model write.
    var requestRender: (() -> Void)? {
        get { gestures.requestRender }
        set { gestures.requestRender = newValue }
    }
    /// Fired after a canvas drag completes (see PreviewGestureCore.pointerUp).
    var onDragEnded: (() -> Void)? {
        get { gestures.onDragEnded }
        set { gestures.onDragEnded = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        gestures.host = self
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        gestures.host = self
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only claim events that land on an interactive target or the card;
        // empty canvas clicks fall through to whatever is behind.
        let local = convert(point, from: superview)
        guard bounds.contains(local), context != nil else { return nil }
        return self
    }

    /// True while the closed-hand cursor is pushed for a card drag.
    /// Push/pop must stay balanced, hence the explicit flag.
    private var cardGrabCursorPushed = false
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
    /// exactly like a text box in a presentation app.
    var inlineEditCenter: CGPoint?
    var inlineEditPads: CGSize?

    // MARK: - Armed blur draw (popover → drag out a region)

    /// The live rubber-band rect while a blur draw drag is in flight.
    private let blurMarquee = CAShapeLayer()

    /// Vertical stack resize notch (+StackNotch.swift): a white pill on the
    /// seam, shown while the pointer is over the stacked camera row.
    lazy var stackNotchLayer: CALayer = {
        let l = CALayer()
        l.backgroundColor = NSColor.white.cgColor
        l.borderColor = NSColor(white: 0, alpha: 0.12).cgColor
        l.borderWidth = 0.5
        l.shadowColor = NSColor.black.cgColor
        l.shadowOpacity = 0.35
        l.shadowRadius = 4
        l.shadowOffset = CGSize(width: 0, height: -1)
        l.opacity = 0
        wantsLayer = true
        layer?.addSublayer(l)
        return l
    }()
    var stackCursorPushed = false
    private var hoverTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateStackNotch(pointer: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if gestures.isStackResizing { return }
        updateStackNotch(pointer: nil)
    }

    /// Arm one drag-to-draw pass. The pointer becomes a crosshair; the next
    /// press-drag-release on the video creates a region via onCreateBlurRegion.
    func armBlurDraw(style: BlurStyle) {
        gestures.armBlurDraw(style: style)
    }

    /// Disarm without creating anything (Esc, or a click outside the video).
    func cancelBlurDraw() {
        gestures.cancelBlurDraw()
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

    // MARK: - Mouse (the front end: NSEvent → canvas point)

    override func mouseDown(with event: NSEvent) {
        gestures.pointerDown(at: convert(event.locationInWindow, from: nil), clickCount: event.clickCount)
    }

    override func mouseDragged(with event: NSEvent) {
        gestures.pointerDragged(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        gestures.pointerUp(at: convert(event.locationInWindow, from: nil))
    }

    /// Esc — deselect everything, matching the click-away contract.
    override func cancelOperation(_ sender: Any?) {
        gestures.cancel()
    }

    /// True while a mouse drag is mutating geometry — the compositor drops
    /// the annotation raster to 1x for the duration, which is what keeps
    /// direct manipulation at mouse-move rate.
    var isActivelyDragging: Bool { gestures.isActivelyDragging }

    /// The selected annotation's rect in THIS VIEW's coordinates — content
    /// rect pushed through the zoom transform (tilt deliberately ignored; the
    /// shell hangs the contextual toolbar off this and an approximate anchor
    /// under a tilted card is fine). Nil when nothing is selected.
    func selectedAnnotationViewRect() -> CGRect? {
        context.flatMap(PreviewHitMath.selectedAnnotationViewRect)
    }
}

// MARK: - PreviewGestureHost

extension PreviewInteractionView: PreviewGestureHost {
    var gestureCurrentTime: TimeInterval {
        // HitContext is rebuilt per frame; annotations/regions passed are the
        // project's — filter with the compositor's shown time.
        (superview as? PreviewCompositorView)?.pendingInput?.currentTime ?? 0
    }

    var gestureUndoManager: UndoManager? { undoManager }

    var gestureIsInlineEditing: Bool { inlineEditor != nil }

    func gestureEndInlineEdit(commit: Bool) { endInlineEdit(commit: commit) }

    func gestureBeginInlineEdit(of annotation: Annotation, in ctx: PreviewHitContext) {
        beginInlineEdit(of: annotation, in: ctx)
    }

    func gestureUpdateBlurMarquee(from a: CGPoint, to b: CGPoint) {
        updateBlurMarquee(from: a, to: b)
    }

    func gestureBlurDrawArmed() {
        NSCursor.crosshair.push()
    }

    func gestureBlurDrawDisarmed() {
        blurMarquee.removeFromSuperlayer()
        NSCursor.pop()
    }

    /// Closed-hand while a card drag (placement or blockOffset) is actively
    /// moving. The core keeps it balanced; the flag keeps NSCursor balanced.
    func gestureSetCardGrab(_ grabbing: Bool) {
        if grabbing {
            guard !cardGrabCursorPushed else { return }
            cardGrabCursorPushed = true
            NSCursor.closedHand.push()
        } else {
            guard cardGrabCursorPushed else { return }
            cardGrabCursorPushed = false
            NSCursor.pop()
        }
    }

    func gestureUpdateStackNotch(pointer: CGPoint?) {
        updateStackNotch(pointer: pointer)
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
        let geometry = PreviewHitMath.inlineEditGeometry(annotation, ctx)
        let zoomed = geometry.frame
        let z = geometry.zoom

        // Two views, not one: the BACKING carries the annotation's pill
        // (background + accent editing ring) at the exact drawn rect, and the
        // FIELD is transparent and glyph-sized inside it — so entering edit
        // mode does not shift the text by the field's own cell padding.
        // The compositor omits the drawn annotation meanwhile (Chrome.editingID).
        let pads = geometry.pads
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
    /// The pill grows symmetrically about its center as the
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
