import UIKit

/// The editor's on-canvas edit surface on iOS — the TOUCH front end of the
/// shared gesture core (`PreviewGestureCore`, Studio/Compositor), the twin of
/// the Mac's mouse front end `PreviewInteractionView`. Every decision about
/// what a press grabbed, what a drag writes and what magnetism does on
/// release is the core's; this view turns touches into canvas points and
/// supplies what only UIKit has: the in-place text editor, the blur-draw
/// marquee, haptics, undo registration and the long-press menu.
///
/// Touch → pointer mapping (one primary touch, like one mouse button):
///   touch down  → `pointerDown(clickCount: touch.tapCount)` — a double tap
///                 is a double click (text/callout → edit in place);
///   touch moved → `pointerDragged` (Apple Pencil while drawing: every
///                 coalesced sample, so ink keeps the pencil's full rate);
///   touch up    → `pointerUp`;
///   cancelled   → the edit is reverted (a second finger starting a pinch,
///                 or the long press taking over).
/// Long press = right click: the press selects what it lands on (the core's
/// normal press), then `onContextMenu` shows that object's menu.
///
/// The four `touch…` entry points below are what the touch overrides call
/// and what `--editor-shell` drives — real touches and the gate go through
/// the same code.
final class EditorCanvasView: UIView {
    let gestures = PreviewGestureCore()

    /// The stage this surface overlays (same frame): coordinate mapping and
    /// the shown time.
    weak var stage: PreviewStageView?
    /// The editor's undo stack.
    var undoManagerProvider: (() -> UndoManager?)?
    /// Long press settled on `viewPoint` (the press has already selected).
    var onContextMenu: ((CGPoint) -> Void)?
    /// The in-place editor opened (id) or closed (nil).
    var onInlineEditChanged: ((UUID?) -> Void)?

    var context: PreviewHitContext? {
        get { gestures.context }
        set { gestures.context = newValue }
    }

    /// True while a canvas drag is mutating geometry (the core drops
    /// live-motion rasters to 1x for it; the shell hides contextual chrome).
    var isActivelyDragging: Bool { gestures.isActivelyDragging }

    private(set) var inlineEditor: EditorInlineTextEditor?
    var inlineEditingID: UUID? { inlineEditor?.annotationID }

    // Press state for undo / cancel.
    private var activeTouch: UITouch?
    private var pressSnapshot: CanvasEditSnapshot?
    private var pressMode: PreviewDragMode = .idle
    private var downCanvasPoint: CGPoint = .zero

    // VoiceOver (EditorCanvasView+Accessibility): stable elements, by target.
    var accessibilityItemCache: [EditorStageAccessibilityItem] = []
    var accessibilitySummaryElement: UIAccessibilityElement?
    /// Chrome over the stage (the zoom pill) that object frames keep clear of.
    var accessibilityExclusions: (() -> [CGRect])?

    private let blurMarquee = CAShapeLayer()
    private let stackNotch = CALayer()
    private lazy var longPress = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        // Multi-touch on, so the pinch / two-finger pan recognizers see the
        // second finger; the editing path follows the FIRST touch only.
        isMultipleTouchEnabled = true
        gestures.host = self

        blurMarquee.fillColor = UIColor(red: 0, green: 0.478, blue: 1, alpha: 0.12).cgColor
        blurMarquee.strokeColor = UIColor(red: 0, green: 0.478, blue: 1, alpha: 0.9).cgColor
        blurMarquee.lineWidth = 1.5
        blurMarquee.lineDashPattern = [5, 3]
        blurMarquee.isHidden = true
        layer.addSublayer(blurMarquee)

        stackNotch.backgroundColor = UIColor.white.cgColor
        stackNotch.borderColor = UIColor(white: 0, alpha: 0.12).cgColor
        stackNotch.borderWidth = 0.5
        stackNotch.shadowColor = UIColor.black.cgColor
        stackNotch.shadowOpacity = 0.35
        stackNotch.shadowRadius = 4
        stackNotch.shadowOffset = CGSize(width: 0, height: 1)
        stackNotch.opacity = 0
        layer.addSublayer(stackNotch)

        longPress.minimumPressDuration = 0.5
        longPress.cancelsTouchesInView = true
        addGestureRecognizer(longPress)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var project: Project? { gestures.context?.project }

    private func canvasPoint(_ viewPoint: CGPoint) -> CGPoint {
        guard let stage else { return viewPoint }
        let p = stage.canvasPoint(fromView: convert(viewPoint, to: stage))
        #if DEBUG
        return CGPoint(x: p.x + Self.probeTouchOffset, y: p.y)
        #else
        return p
        #endif
    }

    #if DEBUG
    /// Probe seam — INJECTED DEFECT: touches land this many canvas points to
    /// the right (`--editor-shell --inject touch` proves the gate sees it).
    static var probeTouchOffset: CGFloat = 0
    #endif

    private func viewPoint(_ canvasPoint: CGPoint) -> CGPoint {
        guard let stage else { return canvasPoint }
        return convert(stage.viewPoint(fromCanvas: canvasPoint), from: stage)
    }

    // MARK: - Entry points (touches and the gate)

    /// A finger or the pencil went down at `viewPoint` (this view's space).
    func touchDown(atView viewPoint: CGPoint, tapCount: Int) {
        guard let project else { return }
        let p = canvasPoint(viewPoint)
        // A press that ends the in-place edit is consumed by the core; the
        // editor registers the text change itself, so snapshot AFTER it.
        let endsInlineEdit = inlineEditor != nil
        if !endsInlineEdit { pressSnapshot = CanvasEditSnapshot(project) }
        gestures.pointerDown(at: p, clickCount: max(1, tapCount))
        if endsInlineEdit { pressSnapshot = CanvasEditSnapshot(project) }
        pressMode = gestures.mode
        downCanvasPoint = p
    }

    /// The touch moved (`viewPoints`: the coalesced samples, oldest first).
    func touchMoved(toView viewPoints: [CGPoint]) {
        for viewPoint in viewPoints { gestures.pointerDragged(to: canvasPoint(viewPoint)) }
    }

    /// The touch lifted at `viewPoint`: release, then one undo step for
    /// whatever the press → release changed.
    func touchUp(atView viewPoint: CGPoint) {
        let mode = gestures.mode
        gestures.pointerUp(at: canvasPoint(viewPoint))
        defer { pressSnapshot = nil; pressMode = .idle }
        guard let before = pressSnapshot, let project else { return }
        switch mode {
        case .stackResize, .blurDraw:
            // The core registers Camera Height itself; a drawn blur is
            // created (and registered) by the timeline's edit.
            return
        default:
            CanvasEditUndo.register(undoManagerProvider?() ?? undoManager, project: project,
                                    before: before, after: CanvasEditSnapshot(project),
                                    actionName: CanvasEditUndo.actionName(for: pressMode))
        }
    }

    /// The touch was taken away (pinch, long press): undo the press's edit.
    func touchCancelled() {
        guard pressSnapshot != nil || gestures.isActivelyDragging else { return }
        if case .blurDraw = gestures.mode {
            gestures.cancel()   // disarms without creating a region
        } else if gestures.isActivelyDragging {
            gestures.pointerDragged(to: downCanvasPoint)
            gestures.pointerUp(at: downCanvasPoint)
        }
        if let before = pressSnapshot, let project { before.apply(to: project) }
        pressSnapshot = nil
        pressMode = .idle
        gestures.requestRender?()
    }

    /// Esc on a hardware keyboard: close the in-place editor (discarding),
    /// else the core's cancel (disarm a blur draw, or deselect everything).
    func escape() {
        if inlineEditor != nil { endInlineEdit(commit: false); return }
        gestures.cancel()
    }

    /// Arm one drag-to-draw blur / pixelate pass (the timeline's popover).
    func armBlurDraw(style: BlurStyle) { gestures.armBlurDraw(style: style) }

    // MARK: - UIKit touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch == nil, let touch = touches.first else { return }
        activeTouch = touch
        touchDown(atView: touch.location(in: self), tapCount: touch.tapCount)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        // Ink takes every sample the hardware delivered (Pencil runs at up to
        // 240 Hz); other drags only need the latest position.
        if case .draw = gestures.mode, let coalesced = event?.coalescedTouches(for: touch), !coalesced.isEmpty {
            touchMoved(toView: coalesced.map { $0.location(in: self) })
        } else {
            touchMoved(toView: [touch.location(in: self)])
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        activeTouch = nil
        touchUp(atView: touch.location(in: self))
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        activeTouch = nil
        touchCancelled()
    }

    @objc private func longPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        // The press already selected its target; drop its (empty) drag.
        if activeTouch != nil {
            activeTouch = nil
            touchCancelled()
        }
        guard inlineEditor == nil, context?.isPlaying == false else { return }
        CCHaptics.light()
        onContextMenu?(recognizer.location(in: self))
    }

    /// The selected annotation's rect in this view (the contextual pill's
    /// anchor) — the core's view rect (zoom applied, tilt approximated).
    func selectedAnnotationRect() -> CGRect? {
        guard let ctx = context, let rect = PreviewHitMath.selectedAnnotationViewRect(ctx), let stage else { return nil }
        return convert(stage.viewRect(fromCanvas: rect), from: stage)
    }
}

// MARK: - PreviewGestureHost

extension EditorCanvasView: PreviewGestureHost {
    var gestureCurrentTime: TimeInterval { stage?.pendingInput?.currentTime ?? 0 }
    var gestureUndoManager: UndoManager? { undoManagerProvider?() ?? undoManager }
    var gestureIsInlineEditing: Bool { inlineEditor != nil }

    func gestureEndInlineEdit(commit: Bool) { endInlineEdit(commit: commit) }

    func gestureBeginInlineEdit(of annotation: Annotation, in ctx: PreviewHitContext) {
        beginInlineEdit(of: annotation, in: ctx)
    }

    func gestureUpdateBlurMarquee(from a: CGPoint, to b: CGPoint) {
        let va = viewPoint(a), vb = viewPoint(b)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        blurMarquee.isHidden = false
        blurMarquee.path = CGPath(rect: CGRect(x: min(va.x, vb.x), y: min(va.y, vb.y),
                                               width: abs(vb.x - va.x), height: abs(vb.y - va.y)), transform: nil)
        CATransaction.commit()
    }

    func gestureBlurDrawArmed() {}

    func gestureBlurDrawDisarmed() {
        blurMarquee.isHidden = true
        blurMarquee.path = nil
    }

    func gestureSetCardGrab(_ grabbing: Bool) {
        if grabbing { CCHaptics.selection() }
    }

    func gestureUpdateStackNotch(pointer: CGPoint?) {
        // No hover on touch: the notch shows while the seam is being dragged.
        guard pointer != nil, let stack = context?.stack else {
            stackNotch.opacity = 0
            return
        }
        let r = PreviewHitMath.stackNotchRect(stack)
        let o = viewPoint(r.origin)
        let m = stage?.magnification ?? 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stackNotch.frame = CGRect(x: o.x, y: o.y, width: r.width * m, height: r.height * m)
        stackNotch.cornerRadius = stackNotch.frame.height / 2
        stackNotch.opacity = 1
        CATransaction.commit()
    }
}

// MARK: - In-place label editing

extension EditorCanvasView {
    /// Fresh text/callout lands straight in the in-place editor (the Mac's
    /// `beginInlineEdit(annotationID:)`).
    func beginInlineEdit(annotationID: UUID) {
        guard let ctx = context,
              let a = ctx.project.annotations.first(where: { $0.id == annotationID }),
              a.type == .text || a.type == .callout else { return }
        beginInlineEdit(of: a, in: ctx)
    }

    func beginInlineEdit(of annotation: Annotation, in ctx: PreviewHitContext) {
        endInlineEdit(commit: true)
        guard let stage else { return }
        // The renderer's own label rect pushed through the zoom (PreviewHitMath),
        // then magnified to this view exactly as the stage magnifies the canvas.
        let geometry = PreviewHitMath.inlineEditGeometry(annotation, ctx)
        let frame = convert(stage.viewRect(fromCanvas: geometry.frame), from: stage)
        let m = stage.magnification
        let editor = EditorInlineTextEditor(
            annotation: annotation, frame: frame,
            pads: CGSize(width: geometry.pads.width * m, height: geometry.pads.height * m),
            scale: geometry.zoom * m)
        editor.onFinish = { [weak self] commit in self?.endInlineEdit(commit: commit) }
        editor.install(in: self)
        inlineEditor = editor
        onInlineEditChanged?(annotation.id)
        // Re-render so the compositor omits the drawn label NOW.
        gestures.requestRender?()
    }

    /// Commit (or discard) and close the editor. Safe to call repeatedly.
    func endInlineEdit(commit: Bool) {
        guard let editor = inlineEditor else { return }
        inlineEditor = nil
        let id = editor.annotationID
        let text = editor.text
        editor.remove()
        if commit, let project, let idx = project.annotations.firstIndex(where: { $0.id == id }),
           project.annotations[idx].text != text {
            let before = CanvasEditSnapshot(project)
            project.annotations[idx].text = text
            CanvasEditUndo.register(undoManagerProvider?() ?? undoManager, project: project,
                                    before: before, after: CanvasEditSnapshot(project), actionName: String(localized: "Edit Text", comment: "Undo/redo action name (Undo …)"))
        }
        onInlineEditChanged?(nil)
        gestures.requestRender?()
    }
}
