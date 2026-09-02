import AppKit

/// Builds the Motion and Annotate pane contexts from project + selection state.
///
/// This logic lived in the SwiftUI `InspectorView`, which existed only to turn
/// `@State` into `Binding`s for the native column. The column is now hosted
/// directly, so the region accessors, the undoable deletes, and the
/// effect-block composition live here as plain functions over `Ref`.
@MainActor
enum InspectorPaneContexts {

    static func motion(
        project: Project,
        selection: EditorShellSelection,
        undoManager: UndoManager?,
        currentTime: @escaping () -> TimeInterval = { 0 }
    ) -> MotionPaneContext {
        MotionPaneContext(
            highlightRegion: Ref(
                get: {
                    guard let id = selection.selectedHighlightID else { return nil }
                    return project.highlightRegions.first { $0.id == id }
                },
                set: { newValue in
                    guard let id = selection.selectedHighlightID,
                          let index = project.highlightRegions.firstIndex(where: { $0.id == id }),
                          let newValue else { return }
                    project.highlightRegions[index] = newValue
                }
            ),
            onDeleteHighlight: {
                guard let id = selection.selectedHighlightID else { return }
                project.highlightRegions.removeAll { $0.id == id }
                selection.selectedHighlightID = nil
            },
            tiltRegion: Ref(
                get: {
                    guard let id = selection.selectedTiltID else { return nil }
                    return project.tiltRegions.first { $0.id == id }
                },
                set: { newValue in
                    guard let id = selection.selectedTiltID,
                          let index = project.tiltRegions.firstIndex(where: { $0.id == id }),
                          let newValue else { return }
                    project.tiltRegions[index] = newValue
                }
            ),
            onDeleteTilt: {
                guard let id = selection.selectedTiltID else { return }
                let previous = project.tiltRegions
                project.tiltRegions.removeAll { $0.id == id }
                selection.selectedTiltID = nil
                undoManager?.registerUndo(withTarget: project) { $0.tiltRegions = previous }
                undoManager?.setActionName("Remove Tilt")
            },
            zoomRegion: Ref(
                get: {
                    guard let id = selection.selectedZoomID else { return nil }
                    return project.zoomRegions.first { $0.id == id }
                },
                set: { newValue in
                    guard let id = selection.selectedZoomID,
                          let index = project.zoomRegions.firstIndex(where: { $0.id == id }),
                          let newValue else { return }
                    project.zoomRegions[index] = newValue
                }
            ),
            onDeleteZoom: {
                guard let id = selection.selectedZoomID else { return }
                let previous = project.zoomRegions
                project.zoomRegions.removeAll { $0.id == id }
                selection.selectedZoomID = nil
                undoManager?.registerUndo(withTarget: project) { $0.zoomRegions = previous }
                undoManager?.setActionName("Remove Zoom")
            },
            onAddTiltToBlock: {
                addTiltToSelectedBlock(project: project, selection: selection, undoManager: undoManager)
            },
            onAddZoomToBlock: {
                addZoomToSelectedBlock(project: project, selection: selection, undoManager: undoManager)
            },
            onAddZoomBlockAtPlayhead: {
                guard let slot = freeEffectSlot(project: project, at: currentTime()) else {
                    NSSound.beep(); return
                }
                let region = ZoomRegion(startTime: slot.0, endTime: slot.1)
                project.zoomRegions.append(region)
                selection.selectedTiltID = nil
                selection.selectedZoomID = region.id
                undoManager?.registerUndo(withTarget: project) { project in
                    project.zoomRegions.removeAll { $0.id == region.id }
                }
                undoManager?.setActionName("Add Zoom")
            },
            onJoinSlideToSelectedBlock: {
                let span: (TimeInterval, TimeInterval)?
                if let id = selection.selectedZoomID,
                   let r = project.zoomRegions.first(where: { $0.id == id }) {
                    span = (r.startTime, r.endTime)
                } else if let id = selection.selectedTiltID,
                          let r = project.tiltRegions.first(where: { $0.id == id }) {
                    span = (r.startTime, r.endTime)
                } else {
                    span = nil
                }
                guard let span else { return false }
                let map = SpeedTimeMap(
                    sourceStart: project.effectiveTrimStart,
                    sourceEnd: max(project.effectiveTrimStart, project.effectiveTrimEnd),
                    regions: project.speedRegions)
                let s0 = map.outputTime(forSource: span.0)
                let s1 = map.outputTime(forSource: span.1)
                if project.settings.introSlideStyle == .off {
                    project.settings.introSlideStyle = .bottom
                }
                project.settings.introSlideStart = s0
                project.settings.introSlideDuration = max(0.3, s1 - s0)
                return true
            },
            focusRegion: Ref(
                get: {
                    guard let id = selection.selectedDepthFocusID else { return nil }
                    return project.focusRegions.first { $0.id == id }
                },
                set: { newValue in
                    guard let id = selection.selectedDepthFocusID,
                          let index = project.focusRegions.firstIndex(where: { $0.id == id }),
                          let newValue else { return }
                    project.focusRegions[index] = newValue
                }
            ),
            onDeleteFocusRegion: {
                guard let id = selection.selectedDepthFocusID else { return }
                let previous = project.focusRegions
                project.focusRegions.removeAll { $0.id == id }
                selection.selectedDepthFocusID = nil
                undoManager?.registerUndo(withTarget: project) { $0.focusRegions = previous }
                undoManager?.setActionName("Remove Depth Focus")
            },
            blurRegion: Ref(
                get: {
                    guard let id = selection.selectedBlurID else { return nil }
                    return project.blurRegions.first { $0.id == id }
                },
                set: { newValue in
                    guard let id = selection.selectedBlurID,
                          let index = project.blurRegions.firstIndex(where: { $0.id == id }),
                          let newValue else { return }
                    project.blurRegions[index] = newValue
                }
            ),
            onDeleteBlurRegion: {
                guard let id = selection.selectedBlurID else { return }
                let previous = project.blurRegions
                project.blurRegions.removeAll { $0.id == id }
                selection.selectedBlurID = nil
                undoManager?.registerUndo(withTarget: project) { $0.blurRegions = previous }
                undoManager?.setActionName("Remove Blur")
            },
            onAddTiltBlockAtPlayhead: {
                guard let slot = freeEffectSlot(project: project, at: currentTime()) else {
                    NSSound.beep(); return
                }
                let region = TiltRegion(startTime: slot.0, endTime: slot.1, pitch: 12)
                project.tiltRegions.append(region)
                selection.selectedZoomID = nil
                selection.selectedTiltID = region.id
                undoManager?.registerUndo(withTarget: project) { project in
                    project.tiltRegions.removeAll { $0.id == region.id }
                }
                undoManager?.setActionName("Add Tilt")
            }
        )
    }

    /// Gap-based slot on the EFFECTS lane (same policy as the timeline's
    /// placement): the gap containing `time` if any, else the nearest one,
    /// shrunk to fit. nil when the lane has no usable gap.
    private static func freeEffectSlot(
        project: Project, at time: TimeInterval,
        want: TimeInterval = 3, minDuration: TimeInterval = 0.8
    ) -> (TimeInterval, TimeInterval)? {
        let spans = (project.zoomRegions.map { ($0.startTime, $0.endTime) }
            + project.tiltRegions.map { ($0.startTime, $0.endTime) })
            .sorted { $0.0 < $1.0 }
        var gaps: [(Double, Double)] = []
        var cursor = 0.0
        for span in spans {
            if span.0 - cursor >= minDuration { gaps.append((cursor, span.0)) }
            cursor = max(cursor, span.1)
        }
        if project.duration - cursor >= minDuration { gaps.append((cursor, project.duration)) }
        guard !gaps.isEmpty else { return nil }
        let gap = gaps.first { time >= $0.0 && time < $0.1 }
            ?? gaps.min {
                min(abs($0.0 - time), abs($0.1 - time))
                    < min(abs($1.0 - time), abs($1.1 - time))
            }!
        let length = min(want, gap.1 - gap.0)
        let start = min(max(time, gap.0), gap.1 - length)
        return (start, start + length)
    }

    static func annotate(
        selection: EditorShellSelection,
        currentTime: TimeInterval,
        undoManager: UndoManager?
    ) -> AnnotatePaneContext {
        AnnotatePaneContext(
            selectedAnnotationID: Ref(
                get: { selection.selectedAnnotationID },
                set: { selection.selectedAnnotationID = $0 }
            ),
            currentTime: currentTime,
            undoManager: undoManager
        )
    }

    // MARK: - Effect block composition

    /// Adds a tilt that exactly co-spans the selected zoom, so the EFFECTS lane
    /// presents them as one block carrying both effects.
    private static func addTiltToSelectedBlock(
        project: Project,
        selection: EditorShellSelection,
        undoManager: UndoManager?
    ) {
        guard let zoomID = selection.selectedZoomID,
              let zoom = project.zoomRegions.first(where: { $0.id == zoomID }),
              selection.selectedTiltID == nil
        else { return }

        let s = project.settings
        let hasSkew = max(abs(s.screenTiltAngle), abs(s.screenTiltYaw), abs(s.screenTiltRoll)) > 0.01
        let region = TiltRegion(
            startTime: zoom.startTime,
            endTime: zoom.endTime,
            pitch: hasSkew ? s.screenTiltAngle : 20,
            yaw: hasSkew ? s.screenTiltYaw : 0,
            roll: hasSkew ? s.screenTiltRoll : 0
        )
        project.tiltRegions.append(region)
        selection.selectedTiltID = region.id

        undoManager?.registerUndo(withTarget: project) { project in
            project.tiltRegions.removeAll { $0.id == region.id }
        }
        undoManager?.setActionName("Add Tilt to Block")
    }

    /// Adds a zoom that exactly co-spans the selected tilt.
    private static func addZoomToSelectedBlock(
        project: Project,
        selection: EditorShellSelection,
        undoManager: UndoManager?
    ) {
        guard let tiltID = selection.selectedTiltID,
              let tilt = project.tiltRegions.first(where: { $0.id == tiltID }),
              selection.selectedZoomID == nil
        else { return }

        let region = ZoomRegion(
            startTime: tilt.startTime,
            endTime: tilt.endTime,
            zoomLevel: project.settings.autoZoomLevel
        )
        project.zoomRegions.append(region)
        selection.selectedZoomID = region.id

        undoManager?.registerUndo(withTarget: project) { project in
            project.zoomRegions.removeAll { $0.id == region.id }
        }
        undoManager?.setActionName("Add Zoom to Block")
    }
}
