import AppKit

/// A named bundle of subtitle style settings, CapCut-style. Applying one sets
/// the whole look at once; the preset cards render with the REAL style pipeline
/// (same font/weight/shadow rules as the canvas overlay).
///
/// Previously declared inside the SwiftUI subtitles pane and typed in
/// `SwiftUI.Color`; rehomed here in `NSColor` when that view was deleted. The
/// `id` values are card identity only — nothing persists them.
struct SubtitlePreset: Identifiable {
    let id: String
    let name: String
    let style: ProjectSettings.SubtitleStyle
    let weight: ProjectSettings.SubtitleWeight
    let uppercase: Bool
    let color: NSColor
    let background: NSColor?
    let karaoke: Bool
    let highlight: NSColor?

    static let all: [SubtitlePreset] = [
        SubtitlePreset(id: "clean", name: "Clean", style: .outline, weight: .bold,
                       uppercase: false, color: .white, background: nil, karaoke: false, highlight: nil),
        SubtitlePreset(id: "boxed", name: "Boxed", style: .background, weight: .semibold,
                       uppercase: false, color: .white, background: .black, karaoke: false, highlight: nil),
        SubtitlePreset(id: "neon", name: "Neon", style: .glow, weight: .heavy,
                       uppercase: true, color: NSColor(srgbRed: 0.55, green: 0.75, blue: 1.0, alpha: 1),
                       background: nil, karaoke: false, highlight: nil),
        SubtitlePreset(id: "karaoke", name: "Karaoke", style: .outline, weight: .bold,
                       uppercase: false, color: .white, background: nil, karaoke: true, highlight: .systemYellow),
        SubtitlePreset(id: "shout", name: "Shout", style: .outline, weight: .heavy,
                       uppercase: true, color: .systemYellow, background: nil, karaoke: false, highlight: nil),
        SubtitlePreset(id: "minimal", name: "Minimal", style: .plain, weight: .regular,
                       uppercase: false, color: .white, background: nil, karaoke: false, highlight: nil),
    ]

    func apply(to settings: ProjectSettings) {
        settings.subtitleStyle = style
        settings.subtitleWeight = weight
        settings.subtitleUppercase = uppercase
        settings.subtitleColor = CodableColor(color)
        if let background {
            settings.subtitleBackgroundColor = CodableColor(background)
        }
        settings.highlightWords = karaoke
        if let highlight {
            settings.subtitleHighlightColor = CodableColor(highlight)
        }
    }

    /// Active when the settings match the preset's signature knobs (colors
    /// excluded — tweaking a color keeps the preset selected).
    func matches(_ settings: ProjectSettings) -> Bool {
        settings.subtitleStyle == style
            && settings.subtitleWeight == weight
            && settings.subtitleUppercase == uppercase
            && settings.highlightWords == karaoke
    }
}
