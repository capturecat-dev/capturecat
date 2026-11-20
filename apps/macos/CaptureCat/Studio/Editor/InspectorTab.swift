import Foundation

/// The inspector's eight panes. Pure UI state — never persisted, so the raw
/// values carry no compatibility obligation.
///
/// Previously nested inside the SwiftUI `EditorView`; extracted so the shell
/// and the inspector column can name it without that type existing.
enum InspectorTab: String, CaseIterable {
    case background = "Background"
    case cursor = "Cursor"
    case camera = "Camera"
    case audio = "Audio"
    case effects = "Effects"
    case motion = "Motion"
    case subtitles = "Subtitles"
    case brand = "Brand"
    case annotations = "Annotate"

    /// The tab's visible name (the raw value stays the harness identity).
    var displayName: String {
        switch self {
        case .background: return String(localized: "Background", comment: "Inspector tab name (rail button / tab bar)")
        case .cursor: return String(localized: "Cursor", comment: "Inspector tab name (rail button / tab bar)")
        case .camera: return String(localized: "Camera", comment: "Inspector tab name (rail button / tab bar)")
        case .audio: return String(localized: "Audio", comment: "Inspector tab name (rail button / tab bar)")
        case .effects: return String(localized: "Effects", comment: "Inspector tab name (rail button / tab bar)")
        case .motion: return String(localized: "Motion", comment: "Inspector tab name (rail button / tab bar)")
        case .subtitles: return String(localized: "Subtitles", comment: "Inspector tab name (rail button / tab bar)")
        case .brand: return String(localized: "Brand", comment: "Inspector tab name (rail button / tab bar)")
        case .annotations: return String(localized: "Annotate", comment: "Inspector tab name (rail button / tab bar)")
        }
    }

    /// SF Symbol name for the tab rail button.
    var icon: String {
        switch self {
        case .background: return "paintpalette"
        case .cursor: return "cursorarrow"
        case .camera: return "camera"
        case .audio: return "speaker.wave.2"
        case .effects: return "wand.and.stars"
        case .motion: return "figure.walk.motion"
        case .subtitles: return "captions.bubble"
        case .brand: return "checkmark.seal"
        case .annotations: return "pencil.tip"
        }
    }
}
