import UIKit

// VoiceOver for the stage (Studio 6a). What can be edited on the stage at
// the playhead is an element: each visible annotation, the highlight / blur /
// depth-focus regions, the camera bubble, the subtitle pill and — while a
// zoom block is selected — its focal point. Frames come from the shared hit
// math (`PreviewHitMath`, what a touch is tested against), pushed through the
// stage's magnification. Every action runs the TOUCH path: activation is a
// tap on the object (`touchDown`/`touchUp`, the same entry points UIKit's
// touches call — the gesture core selects it), Move left/right/up/down is a
// drag through `touchDown/Moved/Up` (the core's own drag rules and
// magnetism; one undo step, registered on release exactly as for a finger),
// Larger / Smaller drags the bottom-right handle, Edit Text is the double tap.

enum EditorStageAccessibilityTarget: Equatable {
    case annotation(UUID)
    case highlight(UUID)
    case blur(UUID)
    case depthFocus(UUID)
    case camera
    case subtitle
    case zoomFocal
}

extension EditorCanvasView {
    enum AccessibilityAction {
        static let left = "Move left"
        static let right = "Move right"
        static let up = "Move up"
        static let down = "Move down"
        static let larger = "Make larger"
        static let smaller = "Make smaller"
        static let editText = "Edit text"
    }

    /// One nudge, as a fraction of the recording's frame.
    static let accessibilityNudge: CGFloat = 0.04
    /// One camera step, as a fraction of the stage.
    static let accessibilityCameraStep: CGFloat = 0.25

    override var accessibilityElements: [Any]? {
        get { accessibilityItems }
        set {}
    }

    var accessibilityItems: [NSObject] {
        guard let ctx = context, stage != nil else { return [] }
        let time = gestureCurrentTime
        var targets: [EditorStageAccessibilityTarget] = []
        if ctx.cameraRect != nil, ctx.stack == nil { targets.append(.camera) }
        if ctx.subtitleRect != nil { targets.append(.subtitle) }
        if !ctx.isPlaying {
            for r in ctx.project.highlightRegions where time >= r.startTime && time <= r.endTime { targets.append(.highlight(r.id)) }
            for r in ctx.project.focusRegions where time >= r.startTime && time <= r.endTime { targets.append(.depthFocus(r.id)) }
            for r in ctx.project.blurRegions where time >= r.startTime && time <= r.endTime { targets.append(.blur(r.id)) }
            for a in ctx.project.annotations where time >= a.startTime && time <= a.endTime { targets.append(.annotation(a.id)) }
        }
        if ctx.selectedZoomFocal != nil { targets.append(.zoomFocal) }
        let items = targets.map { target in
            accessibilityItemCache.first { $0.target == target } ?? EditorStageAccessibilityItem(canvas: self, target: target)
        }
        accessibilityItemCache = items
        guard !items.isEmpty else { return [accessibilitySummary] }
        return [accessibilitySummary] + items
    }

    /// The stage itself (what VoiceOver reads first): "Preview, 6.5 seconds".
    var accessibilitySummary: UIAccessibilityElement {
        let summary = accessibilitySummaryElement ?? UIAccessibilityElement(accessibilityContainer: self)
        accessibilitySummaryElement = summary
        summary.accessibilityLabel = "Preview"
        summary.accessibilityValue = "at " + CCAccessibility.spokenTime(gestureCurrentTime)
        summary.accessibilityTraits = .image
        summary.accessibilityIdentifier = CCAccessibility.dataGeometryPrefix + "stage.summary"
        // A thin strip along the stage's top edge, so it never covers an object.
        summary.accessibilityFrameInContainerSpace = CGRect(x: 0, y: 0, width: bounds.width, height: min(6, bounds.height))
        return summary
    }

    /// `target`'s rect in this view, nil when it is not on the stage.
    func accessibilityRect(for target: EditorStageAccessibilityTarget) -> CGRect? {
        guard let ctx = context, let stage else { return nil }
        let canvasRect: CGRect?
        switch target {
        case .annotation(let id):
            canvasRect = ctx.project.annotations.first { $0.id == id }
                .map { PreviewHitMath.viewRect(ofContentRect: PreviewHitMath.annotationHitRect($0, ctx), ctx) }
        case .highlight(let id):
            canvasRect = ctx.project.highlightRegions.first { $0.id == id }.map { regionCanvasRect($0.rect, ctx) }
        case .depthFocus(let id):
            canvasRect = ctx.project.focusRegions.first { $0.id == id }.map { regionCanvasRect($0.rect, ctx) }
        case .blur(let id):
            canvasRect = ctx.project.blurRegions.first { $0.id == id }.map { regionCanvasRect($0.rect, ctx) }
        case .camera:
            canvasRect = ctx.cameraRect
        case .subtitle:
            canvasRect = ctx.subtitleRect
        case .zoomFocal:
            canvasRect = ctx.selectedZoomFocal.map { focal in
                let c = CGPoint(x: ctx.videoRect.minX + focal.x * ctx.videoRect.width,
                                y: ctx.videoRect.minY + focal.y * ctx.videoRect.height)
                let r = 22 / max(1, ctx.zoom)
                return PreviewHitMath.viewRect(ofContentRect: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2), ctx)
            }
        }
        guard let canvasRect else { return nil }
        // (A mirrored camera's rect comes back with a negative width.)
        var rect = convert(stage.viewRect(fromCanvas: canvasRect.standardized), from: stage).standardized.intersection(bounds)
        // Keep clear of chrome over the stage: the largest part of the
        // object's rect outside it.
        for excluded in accessibilityExclusions?() ?? [] where rect.intersects(excluded) {
            // (CGRect.width reads a negative width as positive: clamp first.)
            let parts = [
                CGRect(x: rect.minX, y: rect.minY, width: max(0, excluded.minX - rect.minX), height: rect.height),
                CGRect(x: excluded.maxX, y: rect.minY, width: max(0, rect.maxX - excluded.maxX), height: rect.height),
                CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(0, excluded.minY - rect.minY)),
                CGRect(x: rect.minX, y: excluded.maxY, width: rect.width, height: max(0, rect.maxY - excluded.maxY)),
            ].filter { $0.width > 1 && $0.height > 1 }
            rect = parts.max { $0.width * $0.height < $1.width * $1.height } ?? .zero
        }
        return rect.isEmpty || rect.isNull ? nil : rect
    }

    private func regionCanvasRect(_ norm: CGRect, _ ctx: PreviewHitContext) -> CGRect {
        PreviewHitMath.viewRect(ofContentRect: PreviewHitMath.regionPixelRect(norm, ctx), ctx)
    }

    func accessibilityName(for target: EditorStageAccessibilityTarget) -> String {
        guard let ctx = context else { return "Object" }
        switch target {
        case .annotation(let id):
            guard let a = ctx.project.annotations.first(where: { $0.id == id }) else { return "Annotation" }
            let kind: String
            switch a.type {
            case .text: kind = "Text"
            case .callout: kind = "Callout"
            case .arrow: kind = "Arrow"
            case .rectangle: kind = "Rectangle"
            case .ellipse: kind = "Ellipse"
            case .tap: kind = "Tap"
            case .drawing: kind = "Drawing"
            default: kind = "Annotation"
            }
            let text = a.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return (a.type == .text || a.type == .callout) && !text.isEmpty ? "\(kind) annotation, \(text)" : "\(kind) annotation"
        case .highlight: return "Highlight region"
        case .depthFocus: return "Depth focus region"
        case .blur: return "Blur region"
        case .camera: return "Camera"
        case .subtitle: return "Subtitles"
        case .zoomFocal: return "Zoom focus point"
        }
    }

    /// Where the object sits, in words ("40% across, 30% down").
    func accessibilityPosition(for target: EditorStageAccessibilityTarget) -> String? {
        guard let rect = accessibilityRect(for: target), let ctx = context, let stage else { return nil }
        let video = convert(stage.viewRect(fromCanvas: PreviewHitMath.viewRect(ofContentRect: ctx.videoRect, ctx)), from: stage)
        guard video.width > 1, video.height > 1 else { return nil }
        let x = Int(((rect.midX - video.minX) / video.width * 100).rounded())
        let y = Int(((rect.midY - video.minY) / video.height * 100).rounded())
        return "\(x)% across, \(y)% down"
    }

    func accessibilityIsSelected(_ target: EditorStageAccessibilityTarget) -> Bool {
        guard let ctx = context else { return false }
        switch target {
        case .annotation(let id): return ctx.selectedAnnotationID == id
        case .highlight(let id): return ctx.selectedHighlightID == id
        case .depthFocus(let id): return ctx.selectedDepthFocusID == id
        case .blur(let id): return ctx.selectedBlurID == id
        default: return false
        }
    }

    /// The press point that grabs `target`'s body (its centre) or, for
    /// Larger/Smaller, its bottom-right handle.
    func accessibilityPressPoint(for target: EditorStageAccessibilityTarget, handle: Bool = false) -> CGPoint? {
        guard let rect = accessibilityRect(for: target) else { return nil }
        guard handle, case .annotation(let id) = target, let ctx = context, let stage,
              let a = ctx.project.annotations.first(where: { $0.id == id }) else {
            return CGPoint(x: rect.midX, y: rect.midY)
        }
        let vr = ctx.videoRect
        let corner = CGPoint(x: vr.minX + a.arrowEndX * vr.width, y: vr.minY + a.arrowEndY * vr.height)
        let canvasCorner = PreviewHitMath.viewRect(ofContentRect: CGRect(origin: corner, size: .zero), ctx).origin
        return convert(stage.viewPoint(fromCanvas: canvasCorner), from: stage)
    }

    /// One drag along the touch path (`touchDown` → `touchMoved` → `touchUp`).
    func accessibilityDrag(from point: CGPoint, by delta: CGVector) {
        touchDown(atView: point, tapCount: 1)
        touchMoved(toView: (1...4).map { CGPoint(x: point.x + delta.dx * CGFloat($0) / 4, y: point.y + delta.dy * CGFloat($0) / 4) })
        touchUp(atView: CGPoint(x: point.x + delta.dx, y: point.y + delta.dy))
    }

    /// One nudge in view points: `accessibilityNudge` of the recording's frame.
    var accessibilityNudgeVector: CGSize {
        guard let ctx = context, let stage else { return CGSize(width: 8, height: 8) }
        let video = stage.viewRect(fromCanvas: PreviewHitMath.viewRect(ofContentRect: ctx.videoRect, ctx))
        return CGSize(width: video.width * Self.accessibilityNudge, height: video.height * Self.accessibilityNudge)
    }
}

/// One editable object on the stage, as VoiceOver sees it.
final class EditorStageAccessibilityItem: UIAccessibilityElement {
    let target: EditorStageAccessibilityTarget
    private weak var canvas: EditorCanvasView?
    private typealias A = EditorCanvasView.AccessibilityAction

    init(canvas: EditorCanvasView, target: EditorStageAccessibilityTarget) {
        self.canvas = canvas
        self.target = target
        super.init(accessibilityContainer: canvas)
        accessibilityIdentifier = CCAccessibility.dataGeometryPrefix + "stage"
    }

    override var accessibilityFrameInContainerSpace: CGRect {
        get { canvas?.accessibilityRect(for: target) ?? .zero }
        set {}
    }

    override var accessibilityFrame: CGRect {
        get {
            guard let canvas, let rect = canvas.accessibilityRect(for: target) else { return .zero }
            return UIAccessibility.convertToScreenCoordinates(rect, in: canvas)
        }
        set {}
    }

    override var accessibilityLabel: String? {
        get { canvas?.accessibilityName(for: target) }
        set {}
    }

    override var accessibilityValue: String? {
        get { canvas?.accessibilityPosition(for: target) }
        set {}
    }

    override var accessibilityHint: String? {
        get { target == .zoomFocal ? "Actions aim the zoom." : "Selects it. Actions move it." }
        set {}
    }

    override var accessibilityTraits: UIAccessibilityTraits {
        get {
            if target == .zoomFocal { return [] }
            return canvas?.accessibilityIsSelected(target) == true ? [.button, .selected] : .button
        }
        set {}
    }

    /// Double tap = a tap on the object (the core selects what it lands on).
    override func accessibilityActivate() -> Bool {
        guard let canvas, target != .zoomFocal, let p = canvas.accessibilityPressPoint(for: target) else { return false }
        canvas.touchDown(atView: p, tapCount: 1)
        canvas.touchUp(atView: p)
        return true
    }

    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get {
            var names = [A.left, A.right, A.up, A.down]
            if case .annotation(let id) = target, let a = canvas?.context?.project.annotations.first(where: { $0.id == id }) {
                if a.type == .rectangle || a.type == .ellipse || a.type == .arrow { names += [A.larger, A.smaller] }
                if a.type == .text || a.type == .callout { names.append(A.editText) }
            }
            return names.map { name in UIAccessibilityCustomAction(name: name) { [weak self] _ in self?.perform(name) ?? false } }
        }
        set {}
    }

    @discardableResult
    func perform(_ name: String) -> Bool {
        guard let canvas else { return false }
        var n = canvas.accessibilityNudgeVector
        // The camera's drag is over the whole stage and lands on a corner when
        // near one (magnetism): one step is a quarter of the stage.
        if target == .camera {
            n = CGSize(width: canvas.bounds.width * EditorCanvasView.accessibilityCameraStep,
                       height: canvas.bounds.height * EditorCanvasView.accessibilityCameraStep)
        }
        switch name {
        case A.left, A.right, A.up, A.down, A.larger, A.smaller:
            let handle = name == A.larger || name == A.smaller
            // A region's body moves once it is selected (its chrome is live).
            if !canvas.accessibilityIsSelected(target), target != .camera, target != .subtitle, target != .zoomFocal,
               let p = canvas.accessibilityPressPoint(for: target) {
                canvas.touchDown(atView: p, tapCount: 1)
                canvas.touchUp(atView: p)
            }
            guard let p = canvas.accessibilityPressPoint(for: target, handle: handle) else { return false }
            let delta: CGVector
            switch name {
            case A.left: delta = CGVector(dx: -n.width, dy: 0)
            case A.right: delta = CGVector(dx: n.width, dy: 0)
            case A.up: delta = CGVector(dx: 0, dy: -n.height)
            case A.down: delta = CGVector(dx: 0, dy: n.height)
            case A.larger: delta = CGVector(dx: n.width, dy: n.height)
            default: delta = CGVector(dx: -n.width, dy: -n.height)
            }
            canvas.accessibilityDrag(from: p, by: delta)
            if let where_ = canvas.accessibilityPosition(for: target) { CCAccessibility.announce(where_) }
            return true
        case A.editText:
            guard let p = canvas.accessibilityPressPoint(for: target) else { return false }
            canvas.touchDown(atView: p, tapCount: 2)
            canvas.touchUp(atView: p)
            return true
        default:
            return false
        }
    }
}
