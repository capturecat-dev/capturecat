import Foundation

/// Selection drives the inspector: a newly selected region opens the Effects
/// tab, a newly selected annotation the Annotate tab. Moved out of the Mac
/// shell's chrome observation (EditorShellViewController) in Studio 4d so the
/// iOS inspector follows the selection by the same rule.
///
/// Feed it the selection on every change; it answers the tab to open (nil =
/// leave the tab alone). A cleared selection never moves the tab. When
/// several ids change at once the later checks win, in the Mac's order:
/// highlight, depth focus, blur, tilt, zoom, annotation.
@MainActor
struct InspectorTabFollower {
    private var lastHighlightID: UUID?
    private var lastDepthFocusID: UUID?
    private var lastBlurRegionID: UUID?
    private var lastTiltID: UUID?
    private var lastZoomID: UUID?
    private var lastAnnotationID: UUID?

    init() {}

    mutating func update(_ selection: EditorShellSelection) -> InspectorTab? {
        var tab: InspectorTab?
        func follow(_ id: UUID?, _ last: inout UUID?, _ target: InspectorTab) {
            guard id != last else { return }
            last = id
            if id != nil { tab = target }
        }
        follow(selection.selectedHighlightID, &lastHighlightID, .effects)
        follow(selection.selectedDepthFocusID, &lastDepthFocusID, .effects)
        follow(selection.selectedBlurID, &lastBlurRegionID, .effects)
        follow(selection.selectedTiltID, &lastTiltID, .effects)
        follow(selection.selectedZoomID, &lastZoomID, .effects)
        follow(selection.selectedAnnotationID, &lastAnnotationID, .annotations)
        return tab
    }
}
