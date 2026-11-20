import UIKit

// VoiceOver for the touch timeline (Studio 6a). The canvas is CG-drawn, so
// every clip, block and chip is a `StudioTimelineAccessibilityItem` — an
// element whose frame follows its drawn block live (lanes open and close,
// the timeline scrolls) and whose actions run the SAME edit paths a finger
// does: activation is a tap at the block's centre (`performTap`), move /
// trim are drags through `performDragBegan/Moved/Ended` (the gesture
// recognizers' entry points — the shared snap, clamp and neighbour rules,
// ONE undo step), Delete / Duplicate / Split are the toolbar keys'
// `TimelineEditing` commands on the block after the tap selects it.
//
// Focusing a block opens its overlay lane, as a tap does. Each result is
// spoken (`CCAccessibility.announce`): the new span, or why nothing moved.

/// What one accessibility element on the timeline stands for.
enum StudioTimelineAccessibilityTarget: Equatable {
    case effect(zoom: UUID?, tilt: UUID?)
    case intro
    case curtain
    case focus(UUID)
    case annotate(UUID)
    case video(UUID)
    case voice(UUID)

    var lane: TimelineOverlayLane? {
        switch self {
        case .effect, .intro, .curtain: return .effects
        case .focus: return .focus
        case .annotate: return .annotate
        case .video, .voice: return nil
        }
    }
}

extension StudioTimelineCanvasView {
    /// How far one Move / Trim action shifts, in OUTPUT seconds.
    static let accessibilityStep: TimeInterval = 0.5

    /// Action names (the gate drives them by name).
    enum AccessibilityAction {
        static let moveLater = String(localized: "Move later", comment: "VoiceOver action on a timeline block: move it later in time")
        static let moveEarlier = String(localized: "Move earlier", comment: "VoiceOver action on a timeline block: move it earlier in time")
        static let startEarlier = String(localized: "Start earlier", comment: "VoiceOver action on a timeline block: extend its start earlier")
        static let startLater = String(localized: "Start later", comment: "VoiceOver action on a timeline block: trim its start later")
        static let endLater = String(localized: "End later", comment: "VoiceOver action on a timeline block: extend its end later")
        static let endEarlier = String(localized: "End earlier", comment: "VoiceOver action on a timeline block: trim its end earlier")
        static let duplicate = String(localized: "Duplicate", comment: "VoiceOver action on a timeline block: duplicate it")
        static let delete = String(localized: "Delete", comment: "VoiceOver action on a timeline block: delete it")
        static let split = String(localized: "Split at playhead", comment: "VoiceOver action on a video clip: split it at the playhead")
    }

    // MARK: - Elements

    override var accessibilityElements: [Any]? {
        get { accessibilityItems }
        set {}
    }

    /// The elements, rebuilt when the drawn content changes (frames are live).
    var accessibilityItems: [StudioTimelineAccessibilityItem] {
        if let cache = accessibilityCache, cache.version == accessibilityVersion { return cache.items }
        var targets: [StudioTimelineAccessibilityTarget] = []
        if let model = videoModel { targets += model.clips.map { .video($0.id) } }
        if let model = voiceModel { targets += model.clips.map { .voice($0.id) } }
        if introChipRect != nil { targets.append(.intro) }
        targets += snapshot.effectItems.sorted { $0.startTime < $1.startTime }.map { .effect(zoom: $0.zoomID, tilt: $0.tiltID) }
        if curtainChipRect != nil { targets.append(.curtain) }
        targets += snapshot.focusItems.sorted { $0.startTime < $1.startTime }.map { .focus($0.id) }
        targets += snapshot.annotateItems.sorted { $0.startTime < $1.startTime }.map { .annotate($0.id) }
        let old = accessibilityCache?.items ?? []
        let items = targets.map { target in
            old.first { $0.target == target } ?? StudioTimelineAccessibilityItem(canvas: self, target: target)
        }
        accessibilityCache = (accessibilityVersion, items)
        return items
    }

    /// The drawn rect of `target` now (canvas space), nil when it is gone.
    func accessibilityRect(for target: StudioTimelineAccessibilityTarget) -> CGRect? {
        switch target {
        case .effect(let zoom, let tilt):
            return snapshot.effectItems.first { $0.zoomID == zoom && $0.tiltID == tilt }.map(effectRect(for:))
        case .intro: return introChipRect
        case .curtain: return curtainChipRect
        case .focus(let id): return snapshot.focusItems.first { $0.id == id }.map(focusRect(for:))
        case .annotate(let id): return snapshot.annotateItems.first { $0.id == id }.map(annotateRect(for:))
        case .video(let id):
            guard let model = videoModel, let clip = model.clip(withID: id) else { return nil }
            return videoClipRect(clip.ref, model: model, block: videoBlockGeometry(model, preview: false))
        case .voice(let id):
            guard let item = voiceModel?.clips.first(where: { $0.id == id }) else { return nil }
            return voiceCommittedRect(item)
        }
    }

    /// The span (output seconds) of `target`.
    func accessibilitySpan(for target: StudioTimelineAccessibilityTarget) -> (start: TimeInterval, end: TimeInterval)? {
        switch target {
        case .effect(let zoom, let tilt):
            return snapshot.effectItems.first { $0.zoomID == zoom && $0.tiltID == tilt }.map { ($0.startTime, $0.endTime) }
        case .intro: return snapshot.introChipEnd.map { (snapshot.introChipStart, $0) }
        case .curtain: return snapshot.curtainChipEnd.map { (snapshot.curtainChipStart, $0) }
        case .focus(let id): return snapshot.focusItems.first { $0.id == id }.map { ($0.startTime, $0.endTime) }
        case .annotate(let id): return snapshot.annotateItems.first { $0.id == id }.map { ($0.startTime, $0.endTime) }
        case .video(let id): return videoModel?.clip(withID: id).map { ($0.outputStart, $0.outputEnd) }
        case .voice(let id):
            return voiceModel?.clips.first { $0.id == id }.map { ($0.clip.startTime, $0.clip.startTime + $0.clip.duration) }
        }
    }

    func accessibilityIsSelected(_ target: StudioTimelineAccessibilityTarget) -> Bool {
        switch target {
        case .effect(let zoom, let tilt):
            return (zoom != nil && snapshot.selectedZoomID == zoom) || (tilt != nil && snapshot.selectedTiltID == tilt)
        case .intro: return snapshot.introChipSelected
        case .curtain: return snapshot.curtainChipSelected
        case .focus(let id): return snapshot.focusItems.first { $0.id == id }?.isSelected ?? false
        case .annotate(let id): return snapshot.annotateItems.first { $0.id == id }?.isSelected ?? false
        case .video(let id): return videoModel?.clip(withID: id)?.isSelected ?? false
        case .voice(let id): return voiceModel?.clips.first { $0.id == id }?.isSelected ?? false
        }
    }

    /// What VoiceOver says for `target` ("Zoom 1.8×", "Text annotation").
    func accessibilityName(for target: StudioTimelineAccessibilityTarget) -> String {
        switch target {
        case .effect(let zoom, let tilt):
            guard let item = snapshot.effectItems.first(where: { $0.zoomID == zoom && $0.tiltID == tilt }) else { return String(localized: "Effect", comment: "VoiceOver name of a timeline effect block") }
            var parts: [String] = []
            if let level = item.zoomLevel, item.hasZoom {
                let levelText = String(format: "%.1f", level)
                parts.append(String(localized: "Zoom \(levelText)×", comment: "VoiceOver: a zoom effect and its magnification, e.g. Zoom 1.8×"))
            }
            if item.hasTilt {
                let degrees = String(format: "%.0f", item.dominantAngle)
                parts.append(String(localized: "Tilt \(degrees) degrees", comment: "VoiceOver: a 3D tilt effect and its angle"))
            }
            if item.hasSlide { parts.append(String(localized: "Slide", comment: "VoiceOver: an intro slide effect within an effect block")) }
            return parts.isEmpty ? String(localized: "Effect", comment: "VoiceOver name of a timeline effect block") : ListFormatter.localizedString(byJoining: parts)
        case .intro: return snapshot.introChipLabel.isEmpty ? String(localized: "Intro slide", comment: "VoiceOver name of the intro slide chip on the timeline") : snapshot.introChipLabel.replacingOccurrences(of: "·", with: ",")
        case .curtain: return String(localized: "Curtain unveil", comment: "VoiceOver name of the curtain-unveil chip on the timeline")
        case .focus(let id): return snapshot.focusItems.first { $0.id == id }?.label ?? String(localized: "Focus", comment: "VoiceOver name of a focus/blur/highlight block on the timeline")
        case .annotate(let id):
            let label = snapshot.annotateItems.first { $0.id == id }?.label ?? String(localized: "Annotation", comment: "VoiceOver name of an annotation block on the timeline")
            return String(localized: "\(label) annotation", comment: "VoiceOver: an annotation block, e.g. Text annotation")
        case .video(let id):
            guard let model = videoModel, let index = model.clips.firstIndex(where: { $0.id == id }) else { return String(localized: "Clip", comment: "VoiceOver name of a video clip on the timeline") }
            let speed = model.clips[index].pillSpeedLabel
            if model.clips.count == 1 {
                return speed.map { String(localized: "Video, speed \($0)", comment: "VoiceOver: the whole video track and its playback speed, e.g. Video, speed 2×") }
                    ?? String(localized: "Video", comment: "VoiceOver name of the single video clip on the timeline")
            }
            let number = index + 1, total = model.clips.count
            return speed.map { String(localized: "Clip \(number) of \(total), speed \($0)", comment: "VoiceOver: a video clip, its position and speed") }
                ?? String(localized: "Clip \(number) of \(total)", comment: "VoiceOver: a video clip and its position")
        case .voice: return String(localized: "Voice-over take", comment: "VoiceOver name of a recorded voice-over clip on the timeline")
        }
    }

    static func spokenSpan(_ start: TimeInterval, _ end: TimeInterval) -> String {
        let from = CCAccessibility.spokenTime(start), to = CCAccessibility.spokenTime(end)
        return String(localized: "\(from) to \(to)", comment: "VoiceOver: a time span on the timeline, e.g. 2 seconds to 5 seconds")
    }

    // MARK: - Actions (the touch paths)

    /// One drag through the timeline's gesture entry points: pressed at
    /// `point`, moved by `dx` in four steps, released.
    func accessibilityDrag(from point: CGPoint, by dx: CGFloat) {
        guard let host = accessibilityController else { return }
        host.performDragBegan(at: point, current: point)
        for i in 1...4 { host.performDragMoved(to: CGPoint(x: point.x + dx * CGFloat(i) / 4, y: point.y)) }
        host.performDragEnded(at: CGPoint(x: point.x + dx, y: point.y))
    }

    /// Points per `accessibilityStep` at the current zoom.
    var accessibilityStepWidth: CGFloat {
        guard snapshot.outputDuration > 0 else { return 0 }
        return max(M.dragThreshold + 1, trackWidth * CGFloat(Self.accessibilityStep / snapshot.outputDuration))
    }

    /// Where a press lands to move (`nil`) or trim one edge of `target`.
    func accessibilityPressPoint(for target: StudioTimelineAccessibilityTarget, edge: UIRectEdge?) -> CGPoint? {
        guard let rect = accessibilityRect(for: target) else { return nil }
        let y = rect.midY
        let handle: CGFloat
        switch target {
        case .voice: handle = Self.voiceHandleWidth
        case .video: handle = Self.videoHandleWidth
        case .intro, .curtain: handle = 6
        default: handle = M.handleWidth
        }
        switch edge {
        case .some(.left): return CGPoint(x: rect.minX + min(handle / 2, rect.width / 4), y: y)
        case .some(.right): return CGPoint(x: rect.maxX - min(handle / 2, rect.width / 4), y: y)
        default: return CGPoint(x: rect.midX, y: y)
        }
    }

    #if DEBUG
    /// INJECTED DEFECT (`--a11y --inject action-not-undoable`): the Move
    /// actions write the model's times directly — no drag path, no undo.
    static var probeActionBypassesUndo = false
    #endif
}

/// One clip, block or chip on the timeline, as VoiceOver sees it.
final class StudioTimelineAccessibilityItem: UIAccessibilityElement {
    let target: StudioTimelineAccessibilityTarget
    private weak var canvas: StudioTimelineCanvasView?
    private typealias A = StudioTimelineCanvasView.AccessibilityAction

    init(canvas: StudioTimelineCanvasView, target: StudioTimelineAccessibilityTarget) {
        self.canvas = canvas
        self.target = target
        super.init(accessibilityContainer: canvas)
        accessibilityIdentifier = CCAccessibility.dataGeometryPrefix + "timeline"
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
        get {
            guard let span = canvas?.accessibilitySpan(for: target) else { return nil }
            return StudioTimelineCanvasView.spokenSpan(span.start, span.end)
        }
        set {}
    }

    override var accessibilityHint: String? {
        get {
            switch target {
            case .intro, .curtain: return String(localized: "Opens its settings. Actions change its timing.", comment: "VoiceOver hint on the intro/curtain chip")
            default: return String(localized: "Selects it. Actions move, trim, split or delete it.", comment: "VoiceOver hint on a timeline block")
            }
        }
        set {}
    }

    override var accessibilityTraits: UIAccessibilityTraits {
        get { canvas?.accessibilityIsSelected(target) == true ? [.button, .selected] : .button }
        set {}
    }

    override func accessibilityElementDidBecomeFocused() {
        // As a tap does: the block's overlay lane opens.
        if let lane = target.lane, canvas?.openOverlayLane != lane { canvas?.setOpenLane(lane, animated: true) }
    }

    /// Double tap = a tap on the block (select; a chip opens its panel).
    override func accessibilityActivate() -> Bool {
        guard let canvas, let point = canvas.accessibilityPressPoint(for: target, edge: nil),
              let host = canvas.accessibilityController else { return false }
        host.performTap(at: point)
        return true
    }

    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get {
            var names: [String]
            switch target {
            case .effect, .focus, .annotate:
                names = [A.moveLater, A.moveEarlier, A.endLater, A.endEarlier, A.startEarlier, A.startLater, A.duplicate, A.delete]
            case .intro, .curtain:
                names = [A.moveLater, A.moveEarlier, A.endLater, A.endEarlier, A.delete]
            case .voice:
                names = [A.moveLater, A.moveEarlier, A.endLater, A.endEarlier, A.startEarlier, A.startLater, A.delete]
            case .video:
                names = [A.split]
            }
            return names.map { name in
                UIAccessibilityCustomAction(name: name) { [weak self] _ in self?.perform(name) ?? false }
            }
        }
        set {}
    }

    /// Runs one named action (the gate calls this through the custom
    /// action's handler).
    @discardableResult
    func perform(_ name: String) -> Bool {
        guard let canvas, let host = canvas.accessibilityController else { return false }
        let before = canvas.accessibilitySpan(for: target)
        let step = canvas.accessibilityStepWidth
        switch name {
        case A.moveLater, A.moveEarlier:
            let dx = name == A.moveLater ? step : -step
            #if DEBUG
            if StudioTimelineCanvasView.probeActionBypassesUndo, host.accessibilityBypassMove(target, by: dx > 0 ? StudioTimelineCanvasView.accessibilityStep : -StudioTimelineCanvasView.accessibilityStep) {
                break
            }
            #endif
            guard let p = canvas.accessibilityPressPoint(for: target, edge: nil) else { return false }
            canvas.accessibilityDrag(from: p, by: dx)
        case A.endLater, A.endEarlier:
            guard let p = canvas.accessibilityPressPoint(for: target, edge: .right) else { return false }
            canvas.accessibilityDrag(from: p, by: name == A.endLater ? step : -step)
        case A.startEarlier, A.startLater:
            guard let p = canvas.accessibilityPressPoint(for: target, edge: .left) else { return false }
            canvas.accessibilityDrag(from: p, by: name == A.startEarlier ? -step : step)
        case A.duplicate, A.delete, A.split:
            guard let p = canvas.accessibilityPressPoint(for: target, edge: nil) else { return false }
            if !canvas.accessibilityIsSelected(target) { host.performTap(at: p) }
            switch name {
            case A.duplicate: host.duplicateSelectedRegion()
            case A.delete: _ = host.deleteSelectedRegion()
            default: host.splitAtPlayhead()
            }
            CCAccessibility.announce(name == A.delete ? String(localized: "Deleted", comment: "VoiceOver announcement after deleting a timeline block") : name == A.duplicate ? String(localized: "Duplicated", comment: "VoiceOver announcement after duplicating a timeline block") : String(localized: "Split", comment: "VoiceOver announcement after splitting a clip"))
            return true
        default:
            return false
        }
        // Speak what happened.
        host.rebuildCanvas()
        if let after = canvas.accessibilitySpan(for: target) {
            if let before, abs(before.start - after.start) < 1e-6, abs(before.end - after.end) < 1e-6 {
                CCAccessibility.announce(String(localized: "No room: \(name)", comment: "VoiceOver: a timeline action could not move or resize the block; the argument is the action's name as shown in the actions rotor, e.g. Move Later"))
            } else {
                CCAccessibility.announce(StudioTimelineCanvasView.spokenSpan(after.start, after.end))
            }
        }
        return true
    }
}
