/// Inspector copy that names a pointer or a touch gesture — the one place
/// the two front ends' words differ (the values never do).
enum InspectorPlatformCopy {
    #if canImport(AppKit)
    static let annotateEmptyCaption = "Add a text label, arrow, shape, or tap indicator from the toolbar — it lands on the ANNOTATE lane at the playhead. Select one (on the preview or the timeline) to edit its properties here. Double-click a text label on the preview to edit it in place."
    static let annotateTextTip = "Tip: double-click the label on the preview to edit it in place."
    static let annotateDrawingTip = "Draw directly on the preview canvas."
    #else
    static let annotateEmptyCaption = "Add a text label, arrow, shape, or tap indicator from the timeline — it lands on the ANNOTATE lane at the playhead. Select one (on the preview or the timeline) to edit its properties here. Double-tap a text label on the preview to edit it in place."
    static let annotateTextTip = "Tip: double-tap the label on the preview to edit it in place."
    static let annotateDrawingTip = "Draw directly on the preview with your finger or Apple Pencil."
    #endif
}
