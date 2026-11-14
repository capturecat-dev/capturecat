import Foundation

/// Where the shortcut pill sits on the canvas.
enum KeystrokeOverlayPosition: String, CaseIterable, Codable, Sendable {
    case bottomCenter
    case bottomLeft
    case bottomRight
    case topCenter

    var label: String {
        switch self {
        case .bottomCenter: return "Bottom Center"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        case .topCenter: return "Top Center"
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
        case .slideUp: return "Slide Up"
        case .fade: return "Fade"
        case .pop: return "Pop"
        }
    }
}
