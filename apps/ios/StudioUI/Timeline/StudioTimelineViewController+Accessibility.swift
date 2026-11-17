import UIKit

#if DEBUG
extension StudioTimelineViewController {
    /// INJECTED DEFECT seam (`StudioTimelineCanvasView.probeActionBypassesUndo`):
    /// shifts a block's SOURCE times by `seconds` straight on the model — no
    /// drag path, no snapping, no undo. The a11y gate must catch it.
    func accessibilityBypassMove(_ target: StudioTimelineAccessibilityTarget, by seconds: TimeInterval) -> Bool {
        switch target {
        case .effect(let zoom, let tilt):
            if let zoom, let i = project.zoomRegions.firstIndex(where: { $0.id == zoom }) {
                project.zoomRegions[i].startTime += seconds
                project.zoomRegions[i].endTime += seconds
            }
            if let tilt, let i = project.tiltRegions.firstIndex(where: { $0.id == tilt }) {
                project.tiltRegions[i].startTime += seconds
                project.tiltRegions[i].endTime += seconds
            }
            return zoom != nil || tilt != nil
        case .annotate(let id):
            guard let i = project.annotations.firstIndex(where: { $0.id == id }) else { return false }
            project.annotations[i].startTime += seconds
            project.annotations[i].endTime += seconds
            return true
        case .focus(let id):
            if let i = project.highlightRegions.firstIndex(where: { $0.id == id }) {
                project.highlightRegions[i].startTime += seconds
                project.highlightRegions[i].endTime += seconds
                return true
            }
            if let i = project.blurRegions.firstIndex(where: { $0.id == id }) {
                project.blurRegions[i].startTime += seconds
                project.blurRegions[i].endTime += seconds
                return true
            }
            return false
        default:
            return false
        }
    }
}
#endif
