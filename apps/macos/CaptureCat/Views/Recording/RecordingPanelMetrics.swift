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

    /// Tab title shown to the person. The raw value stays the identity.
    var displayName: String {
        switch self {
        case .display: return String(localized: "Display", comment: "Recording panel source tab: record a whole screen/monitor")
        case .window: return String(localized: "Window", comment: "Recording panel source tab: record one app window")
        case .area: return String(localized: "Area", comment: "Recording panel source tab: record a dragged rectangle of the screen")
        case .device: return "iPhone"
        case .url: return String(localized: "URL", comment: "Recording panel source tab: capture a web page by its address")
        }
    }
}
