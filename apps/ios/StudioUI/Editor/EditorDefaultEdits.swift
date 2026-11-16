import UIKit

/// The editor's `TimelineEditing` host until the iOS timeline exists — just
/// enough for the canvas's own edits (long-press Delete, a drawn blur's
/// creation) to go through the SHARED timeline edits (`TimelineEdits.swift`)
/// with their exact values and undo registration, instead of copies.
///
/// TODO(4c): the iOS timeline controller conforms to `TimelineEditing` with
/// the full selection exclusivity and canvas refresh, and replaces this via
/// `EditorViewController.timelineEdits`.
@MainActor
final class EditorDefaultEdits: TimelineEditing {
    let project: Project
    let selection: EditorShellSelection
    private let undoProvider: () -> UndoManager?
    private let timeProvider: () -> TimeInterval

    init(project: Project, selection: EditorShellSelection,
         undoManager: @escaping () -> UndoManager?, currentTime: @escaping () -> TimeInterval) {
        self.project = project
        self.selection = selection
        undoProvider = undoManager
        timeProvider = currentTime
    }

    var undoManager: UndoManager? { undoProvider() }
    var currentTime: TimeInterval { timeProvider() }

    var selectedHighlightID: UUID? {
        get { selection.selectedHighlightID }
        set { selection.selectedHighlightID = newValue }
    }
    var selectedDepthFocusID: UUID? {
        get { selection.selectedDepthFocusID }
        set { selection.selectedDepthFocusID = newValue }
    }
    var selectedTiltID: UUID? {
        get { selection.selectedTiltID }
        set { selection.selectedTiltID = newValue }
    }
    var selectedZoomID: UUID? {
        get { selection.selectedZoomID }
        set { selection.selectedZoomID = newValue }
    }
    var selectedAnnotationID: UUID? {
        get { selection.selectedAnnotationID }
        set { selection.selectedAnnotationID = newValue }
    }
    var selectedBlurID: UUID? {
        get { selection.selectedBlurID }
        set { selection.selectedBlurID = newValue }
    }
    var selectedCameraLayoutID: UUID?
    var selectedVoiceOverID: UUID?
    var selectedSpeedID: UUID?
    var selectedClipID: UUID?
    var toolbarAnnotationColor: PlatformColor?

    func timelineEditRefused() { CCHaptics.warning() }
    func timelineEditNeedsCameraMask() {}
}
