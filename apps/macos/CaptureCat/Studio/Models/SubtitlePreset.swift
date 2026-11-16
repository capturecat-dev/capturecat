import Foundation

/// A named bundle of subtitle style settings (a one-click caption look). Applying one sets
/// the whole look at once; the preset cards render with the REAL style pipeline
/// (same font/weight/shadow rules as the canvas overlay).
///
/// Previously declared inside the SwiftUI subtitles pane and typed in
/// `SwiftUI.Color`; rehomed in `NSColor` when that view was deleted, and in
/// Studio 4d moved to the shared core (the iOS Subtitles pane applies the same
/// presets) with its colours as `PresetInk` — each resolves exactly as the
/// `CodableColor(NSColor.…)` it replaced, at the moment it is used. The `id`
/// values are card identity only — nothing persists them.
struct SubtitlePreset: Identifiable {
    let id: String
    let name: String
    let style: ProjectSettings.SubtitleStyle
    let weight: ProjectSettings.SubtitleWeight
    let uppercase: Bool
    let color: PresetInk
    let background: PresetInk?
    let karaoke: Bool
    let highlight: PresetInk?

    static let all: [SubtitlePreset] = [
        SubtitlePreset(id: "clean", name: "Clean", style: .outline, weight: .bold,
                       uppercase: false, color: .white, background: nil, karaoke: false, highlight: nil),
        SubtitlePreset(id: "boxed", name: "Boxed", style: .background, weight: .semibold,
                       uppercase: false, color: .white, background: .black, karaoke: false, highlight: nil),
        SubtitlePreset(id: "neon", name: "Neon", style: .glow, weight: .heavy,
                       uppercase: true, color: .srgb(0.55, 0.75, 1.0),
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
        settings.subtitleColor = color.codable
        if let background {
            settings.subtitleBackgroundColor = background.codable
        }
        settings.highlightWords = karaoke
        if let highlight {
            settings.subtitleHighlightColor = highlight.codable
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

/// A preset colour. `codable` is what a preset writes; `platformColor`
/// (Studio/Platform) is what a preset card draws with — the dynamic system
/// colour itself, so the card re-resolves with the theme as it always did.
enum PresetInk: Equatable {
    case white
    case black
    case systemYellow
    case srgb(Double, Double, Double)

    /// Resolved at the moment of use, like the `CodableColor(NSColor.…)` it
    /// replaced (the system yellow follows the appearance current then).
    var codable: CodableColor {
        switch self {
        case .white: return SystemColorDefaults.white
        case .black: return SystemColorDefaults.black
        case .systemYellow: return SystemColorDefaults.systemYellow
        case .srgb(let r, let g, let b): return CodableColor(PlatformColor.studioSRGB(r, g, b, 1))
        }
    }
}
