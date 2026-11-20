import Foundation

/// Where the shortcut pill sits on the canvas.
enum KeystrokeOverlayPosition: String, CaseIterable, Codable, Sendable {
    case bottomCenter
    case bottomLeft
    case bottomRight
    case topCenter

    var label: String {
        switch self {
        case .bottomCenter: return String(localized: "Bottom Center", comment: "Inspector ▸ Cursor ▸ Shortcut Overlay: where the shortcut pill sits")
        case .bottomLeft: return String(localized: "Bottom Left", comment: "Inspector ▸ Cursor ▸ Shortcut Overlay: where the shortcut pill sits")
        case .bottomRight: return String(localized: "Bottom Right", comment: "Inspector ▸ Cursor ▸ Shortcut Overlay: where the shortcut pill sits")
        case .topCenter: return String(localized: "Top Center", comment: "Inspector ▸ Cursor ▸ Shortcut Overlay: where the shortcut pill sits")
        }
    }
}

/// How the pill enters. Raw values are persistence identity — never rename.
enum KeystrokeOverlayAnimation: String, CaseIterable, Codable, Sendable {
    case slideUp
    case fade
    case pop

    var label: String {
        switch self {
        case .slideUp: return String(localized: "Slide Up", comment: "Inspector ▸ Cursor ▸ Shortcut Overlay: how the shortcut pill enters")
        case .fade: return String(localized: "Fade", comment: "Inspector ▸ Cursor ▸ Shortcut Overlay: how the shortcut pill enters")
        case .pop: return String(localized: "Pop", comment: "Inspector ▸ Cursor ▸ Shortcut Overlay: how the shortcut pill enters")
        }
    }
}
