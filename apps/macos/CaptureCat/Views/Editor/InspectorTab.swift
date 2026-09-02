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
