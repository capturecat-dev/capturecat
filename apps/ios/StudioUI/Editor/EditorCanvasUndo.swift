import Foundation

/// Undo for on-canvas edits on iOS (Studio 4b).
///
/// The shared gesture core (`PreviewGestureCore`) writes the model directly
/// during a drag, exactly as on the Mac; it registers undo itself only for
/// the vertical-stack seam ("Camera Height"). On a touch screen a stray drag
/// is easy, so the iOS front end registers ONE undo step per completed canvas
/// edit: it snapshots everything a canvas gesture can write at the press and,
/// if the release changed it, registers a step that restores those press-time
/// values (redo re-applies the release values). The values themselves are
/// the core's — undo never computes an edit of its own.
///
/// (The Mac editor has no canvas-drag undo except Camera Height; adopting
/// this there is a Mac behaviour change for the owner to decide.)
struct CanvasEditSnapshot: Codable {
    var annotations: [Annotation]
    var blurRegions: [BlurRegion]
    var highlightRegions: [HighlightRegion]
    var focusRegions: [FocusRegion]
    var zoomRegions: [ZoomRegion]
    var videoPlacement: ProjectSettings.VideoPlacement
    var videoCustomX: Double?
    var videoCustomY: Double?
    var cameraPosition: ProjectSettings.CameraPosition
    var cameraCustomX: Double?
    var cameraCustomY: Double?
    var cameraStackRatio: Double?
    var watermarkX: Double
    var watermarkY: Double
    var subtitlePosition: ProjectSettings.SubtitlePosition
    var subtitleCustomX: Double?
    var subtitleCustomY: Double?

    @MainActor
    init(_ project: Project) {
        let s = project.settings
        annotations = project.annotations
        blurRegions = project.blurRegions
        highlightRegions = project.highlightRegions
        focusRegions = project.focusRegions
        zoomRegions = project.zoomRegions
        videoPlacement = s.videoPlacement
        videoCustomX = s.videoCustomX
        videoCustomY = s.videoCustomY
        cameraPosition = s.cameraPosition
        cameraCustomX = s.cameraCustomX
        cameraCustomY = s.cameraCustomY
        cameraStackRatio = s.cameraStackRatio
        watermarkX = s.watermarkX
        watermarkY = s.watermarkY
        subtitlePosition = s.subtitlePosition
        subtitleCustomX = s.subtitleCustomX
        subtitleCustomY = s.subtitleCustomY
    }

    @MainActor
    func apply(to project: Project) {
        let s = project.settings
        project.annotations = annotations
        project.blurRegions = blurRegions
        project.highlightRegions = highlightRegions
        project.focusRegions = focusRegions
        project.zoomRegions = zoomRegions
        s.videoPlacement = videoPlacement
        s.videoCustomX = videoCustomX
        s.videoCustomY = videoCustomY
        s.cameraPosition = cameraPosition
        s.cameraCustomX = cameraCustomX
        s.cameraCustomY = cameraCustomY
        s.cameraStackRatio = cameraStackRatio
        s.watermarkX = watermarkX
        s.watermarkY = watermarkY
        s.subtitlePosition = subtitlePosition
        s.subtitleCustomX = subtitleCustomX
        s.subtitleCustomY = subtitleCustomY
    }

    /// Byte-equal encodings ⇔ the canvas-editable state is unchanged.
    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(self)) ?? Data()
    }
}

@MainActor
enum CanvasEditUndo {
    /// Registers one step `before` → `after` on `undo` (no-op when equal).
    /// Undo and redo re-register each other, so the step round-trips.
    static func register(
        _ undo: UndoManager?, project: Project,
        before: CanvasEditSnapshot, after: CanvasEditSnapshot, actionName: String
    ) {
        guard let undo, before.encoded() != after.encoded() else { return }
        undo.registerUndo(withTarget: project) { project in
            before.apply(to: project)
            register(undo, project: project, before: after, after: before, actionName: actionName)
        }
        undo.setActionName(actionName)
    }

    /// The step's name for the drag mode the press grabbed.
    static func actionName(for mode: PreviewDragMode) -> String {
        switch mode {
        case .annotation: return String(localized: "Move Annotation", comment: "Undo/redo action name (Undo …)")
        case .annotationHandle: return String(localized: "Resize Annotation", comment: "Undo/redo action name (Undo …)")
        case .draw: return String(localized: "Draw", comment: "Undo/redo action name (Undo …)")
        case .regionMove: return String(localized: "Move Region", comment: "Undo/redo action name (Undo …)")
        case .regionResize: return String(localized: "Resize Region", comment: "Undo/redo action name (Undo …)")
        case .regionSlider: return String(localized: "Change Intensity", comment: "Undo/redo action name (Undo …)")
        case .placement: return String(localized: "Move Video", comment: "Undo/redo action name (Undo …)")
        case .blockOffset: return String(localized: "Move Zoom Card", comment: "Undo/redo action name (Undo …)")
        case .zoomFocal: return String(localized: "Move Zoom Focus", comment: "Undo/redo action name (Undo …)")
        case .camera: return String(localized: "Move Camera", comment: "Undo/redo action name (Undo …)")
        case .watermark: return String(localized: "Move Watermark", comment: "Undo/redo action name (Undo …)")
        case .subtitle: return String(localized: "Move Subtitles", comment: "Undo/redo action name (Undo …)")
        case .stackResize: return String(localized: "Camera Height", comment: "Undo/redo action name (Undo …)")
        case .blurDraw: return String(localized: "Add Blur", comment: "Undo/redo action name (Undo …)")
        case .idle: return String(localized: "Edit", comment: "Undo/redo action name (Undo …)")
        }
    }
}
