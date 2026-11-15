import Foundation

/// One captured keystroke. PRIVACY: by default only the moment and a coarse
/// category are stored — never keycodes or characters. The category exists
/// solely so keyboard SOUNDS can pick a deeper thock for space/return and a
/// quieter one for modifiers.
///
/// `shortcut` is the ONE opt-in exception: when the user enables the shortcut
/// overlay for a recording, keystrokes that include ⌘/⌃/⌥ store their display
/// string ("⌘⇧S") so the editor can show them subtitle-style. Plain typing —
/// anything without those modifiers — is still never identified, even opted
/// in, so passwords and prose can't leak into a video. The filter runs at
/// capture time; non-shortcut identity is discarded before it ever hits disk.
struct KeystrokeEvent: Codable, Sendable, Equatable {
    enum Category: String, Codable, Sendable {
        case key
        case space
        case `return`
        case delete
        case modifier
        /// Scroll-wheel tick (throttled) — recorded so zooms can steady the
        /// camera during scroll bursts. Never plays a key sound.
        case scroll
    }

    var timestamp: TimeInterval
    var category: Category
    /// Display string of a modifier shortcut ("⌘⇧S"), only when the user
    /// opted into the shortcut overlay for this recording. Synthesized
    /// Codable decodes it as nil from pre-existing recordings.
    var shortcut: String? = nil
    /// Bundle identifier of the application the shortcut was DELIVERED to,
    /// stamped only on events that carry a `shortcut` string (the same opt-in
    /// gate). Lets the editor scope the overlay to the recorded window's app
    /// and drop shortcuts typed into other apps mid-recording. Plain-category
    /// events stay identity-free; synthesized Codable decodes nil from
    /// pre-existing recordings.
    var frontmostBundleID: String? = nil
}

struct KeystrokeRecording: Codable, Sendable {
    var version: Int
    var events: [KeystrokeEvent]
}

extension KeystrokeRecording {
    /// Reads a keys.json written by `KeystrokeTracker.save(to:)`.
    static func load(from url: URL) throws -> KeystrokeRecording {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(KeystrokeRecording.self, from: data)
    }
}
