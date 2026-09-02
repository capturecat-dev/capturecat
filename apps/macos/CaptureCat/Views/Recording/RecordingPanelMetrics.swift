import AppKit

/// The capture-source tabs offered by the recording panel.
///
/// Previously nested in the SwiftUI `RecordingControlsView`; rehomed here when
/// that view was deleted. Raw values are UI labels only — nothing persists them.
///
/// Panel geometry lives on `RecordingPanelMetrics` in `RecordingPanelKit`.
enum RecordingSourceTab: String, CaseIterable {
    case display = "Display"
    case window = "Window"
    case area = "Area"
    case device = "iPhone"
    /// Capture a web page by URL. Selecting this collapses the source chips and
    /// slides a URL field into their place — see `RecordingPanelViewController`.
    case url = "URL"

    /// SF Symbol name for the tab.
    var icon: String {
        switch self {
        case .display: return "display"
        case .window: return "macwindow"
        case .area: return "rectangle.dashed"
        case .device: return "iphone"
        case .url: return "link"
        }
    }
}
