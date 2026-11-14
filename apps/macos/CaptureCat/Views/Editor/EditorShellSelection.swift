import CoreGraphics
import Foundation
import Observation

// Moved out of EditorShellViewController.swift (Studio 1e) so the shared
// timeline edits (TimelineEdits.swift) and the iOS studio can name it.

/// Selection + chrome state the shell owns — the values the toolbar, the stage,
/// the inspector column and the timeline all read.
@MainActor
@Observable
final class EditorShellSelection {
    var inspectorTab: InspectorTab = .background
    var showInspector = true
    /// The inspector column shows the History pane instead of the tabs
    /// (the top bar's clock key, or Web Editor ▸ History…).
    var showHistory = false
    var selectedHighlightID: UUID?
    var selectedTiltID: UUID?
    var selectedZoomID: UUID?
    var selectedAnnotationID: UUID?
    /// The Slide chip on the EFFECTS lane is selected (it is settings, not a
    /// region, so it has no UUID) — drives its focus ring.
    var selectedDepthFocusID: UUID?
    /// Selected blur region (FOCUS lane / canvas) — drives the Blur inspector
    /// section, like highlight/depth-focus.
    var selectedBlurID: UUID?
    var introSelected = false
    /// The Curtain Unveil chip on the EFFECTS lane is selected (settings, not
    /// a region, so it has no UUID) — drives its focus ring.
    var curtainSelected = false
    var previewZoom: CGFloat = 1.0
}
