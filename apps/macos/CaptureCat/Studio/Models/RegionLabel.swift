import Foundation

/// Region labels are project content (saved, synced, editable), but a new
/// region is stamped with an English default ("Blur", "Focus", "Highlight").
/// Shown, a default reads in the reader's language; a label someone typed is
/// shown as typed. The stored value never changes.
nonisolated enum RegionLabel {
    static func display(_ stored: String) -> String {
        switch stored {
        case "Blur": return String(localized: "Blur", comment: "Timeline: default name of a blur region")
        case "Focus": return String(localized: "Focus", comment: "Timeline: default name of a depth-focus region")
        case "Highlight": return String(localized: "Highlight", comment: "Timeline: default name of a highlight region")
        case "Voice Over": return String(localized: "Voice Over", comment: "Timeline: default name of a voice-over clip")
        default: return stored
        }
    }
}
