import CoreGraphics
import Foundation

/// Subtitles tab — show, generate/manage (the transcription itself is the
/// host's), presets, text, style + position pad, the editable caption list.
/// Moved from SubtitleSettingsPaneAppKit (Studio 4d).
@MainActor
enum SubtitlePane {
    typealias Scope = InspectorScope

    private static func show(_ s: Scope) -> Bool { s.settings.showSubtitles }
    static func hasSubtitles(_ s: Scope) -> Bool { !(s.project?.subtitles.isEmpty ?? true) }

    static let showToggle = InspectorToggle(
        id: "subtitles.show", title: String(localized: "Show Subtitles", comment: "Inspector ▸ Subtitles: switch label"),
        read: { $0.settings.showSubtitles }, write: { $0.settings.showSubtitles = $1 })
    /// Generate: shown while subtitles are on, none exist and nothing runs.
    static func generateVisible(_ s: Scope, busy: Bool) -> Bool { show(s) && !hasSubtitles(s) && !busy }
    static let manageVisible: (Scope) -> Bool = { show($0) && hasSubtitles($0) }
    static func countText(_ s: Scope) -> String {
        let count = s.project?.subtitles.count ?? 0
        return count == 1
            ? String(localized: "1 subtitle", comment: "Inspector ▸ Subtitles: how many subtitle lines exist")
            : String(localized: "\(count) subtitles", comment: "Inspector ▸ Subtitles: how many subtitle lines exist")
    }
    /// Regenerate clears the captions, then the host transcribes again.
    static func clearForRegenerate(_ scope: Scope) { scope.project?.subtitles.removeAll() }
    static let delete = InspectorAction(
        id: "subtitles.delete", title: String(localized: "Delete", comment: "Inspector ▸ Subtitles: button title"), destructive: true,
        run: { $0.project?.subtitles.removeAll() }, visible: manageVisible)

    static let detailsVisible: (Scope) -> Bool = show

    /// A preset card applies the whole look.
    static func applyPreset(_ scope: Scope, _ preset: SubtitlePreset) { preset.apply(to: scope.settings) }

    static let size = InspectorSlider(
        id: "subtitles.size", title: String(localized: "Size", comment: "Inspector ▸ Subtitles: slider label"), range: 16...64, step: 2,
        read: { $0.settings.subtitleFontSize }, write: { $0.settings.subtitleFontSize = $1 })
    static let font = InspectorChoice(
        id: "subtitles.font", title: String(localized: "Font", comment: "Inspector ▸ Subtitles: option picker label"), style: .menu, items: FontCatalog.displayMenuNames,
        read: { FontCatalog.menuIndex(for: $0.settings.subtitleFontName) },
        write: { $0.settings.subtitleFontName = FontCatalog.storedName(forMenuIndex: $1) })
    static let weight = InspectorChoice(
        id: "subtitles.weight", title: String(localized: "Weight", comment: "Inspector ▸ Subtitles: option picker label"), style: .chips,
        items: ProjectSettings.SubtitleWeight.allCases.map(\.displayName),
        read: { ProjectSettings.SubtitleWeight.allCases.firstIndex(of: $0.settings.subtitleWeight) ?? 0 },
        write: { $0.settings.subtitleWeight = ProjectSettings.SubtitleWeight.allCases[$1] })
    static let uppercase = InspectorToggle(
        id: "subtitles.uppercase", title: String(localized: "Uppercase", comment: "Inspector ▸ Subtitles: switch label"),
        read: { $0.settings.subtitleUppercase }, write: { $0.settings.subtitleUppercase = $1 })
    static let color = InspectorColor(
        id: "subtitles.color", title: String(localized: "Color", comment: "Inspector ▸ Subtitles: color well label"),
        read: { $0.settings.subtitleColor }, write: { $0.settings.subtitleColor = $1 })
    /// Picking a stock anchor clears free placement (pad/preview drag).
    static let position = InspectorChoice(
        id: "subtitles.position", title: String(localized: "Position", comment: "Inspector ▸ Subtitles: option picker label"), style: .chips,
        items: ProjectSettings.SubtitlePosition.allCases.map(\.displayName),
        read: { ProjectSettings.SubtitlePosition.allCases.firstIndex(of: $0.settings.subtitlePosition) ?? 0 },
        write: { scope, i in
            scope.settings.subtitlePosition = ProjectSettings.SubtitlePosition.allCases[i]
            scope.settings.subtitleCustomX = nil
            scope.settings.subtitleCustomY = nil
        })
    static let style = InspectorChoice(
        id: "subtitles.style", title: String(localized: "Style", comment: "Inspector ▸ Subtitles: option picker label"), style: .chips,
        items: ProjectSettings.SubtitleStyle.allCases.map(\.displayName),
        read: { ProjectSettings.SubtitleStyle.allCases.firstIndex(of: $0.settings.subtitleStyle) ?? 0 },
        write: { $0.settings.subtitleStyle = ProjectSettings.SubtitleStyle.allCases[$1] })
    static let background = InspectorColor(
        id: "subtitles.background", title: String(localized: "Background", comment: "Inspector ▸ Subtitles: color well label"),
        read: { $0.settings.subtitleBackgroundColor }, write: { $0.settings.subtitleBackgroundColor = $1 },
        visible: { show($0) && $0.settings.subtitleStyle == .background })
    static let karaoke = InspectorToggle(
        id: "subtitles.karaoke", title: String(localized: "Karaoke Highlight", comment: "Inspector ▸ Subtitles: switch label"),
        read: { $0.settings.highlightWords }, write: { $0.settings.highlightWords = $1 })
    static let highlight = InspectorColor(
        id: "subtitles.highlight", title: String(localized: "Highlight", comment: "Inspector ▸ Subtitles: color well label"),
        read: { $0.settings.subtitleHighlightColor }, write: { $0.settings.subtitleHighlightColor = $1 },
        visible: { show($0) && $0.settings.highlightWords })
    /// A caption's text, edited in the list (live).
    static func setCaption(_ scope: Scope, id: UUID, text: String) {
        guard let project = scope.project, let index = project.subtitles.firstIndex(where: { $0.id == id }) else { return }
        project.subtitles[index].text = text
    }

    static var sections: [InspectorSection] {
        [
            InspectorSection(id: "subtitles.section.subtitles", title: String(localized: "Subtitles", comment: "Inspector ▸ Subtitles: section header"), rows: [
                .toggle(showToggle),
                .custom(id: "subtitles.generate", visible: show),
                .custom(id: "subtitles.manage", visible: manageVisible),
            ]),
            InspectorSection(id: "subtitles.section.presets", title: String(localized: "Presets", comment: "Inspector ▸ Subtitles: section header"), rows: [
                .custom(id: "subtitles.presets", visible: { _ in true }),
            ], visible: detailsVisible),
            InspectorSection(id: "subtitles.section.text", title: String(localized: "Text", comment: "Inspector ▸ Subtitles: section header"), rows: [
                .slider(size), .choice(font), .choice(weight), .toggle(uppercase), .color(color),
            ], visible: detailsVisible),
            InspectorSection(id: "subtitles.section.style", title: String(localized: "Style", comment: "Inspector ▸ Subtitles: section header"), rows: [
                .choice(position), .custom(id: "subtitles.positionPad", visible: { _ in true }), .choice(style),
                .color(background), .toggle(karaoke), .color(highlight),
            ], visible: detailsVisible),
            InspectorSection(id: "subtitles.section.edit", title: String(localized: "Edit Subtitles", comment: "Inspector ▸ Subtitles: section header"), rows: [
                .custom(id: "subtitles.captions", visible: { _ in true }),
            ], visible: manageVisible),
        ]
    }
}

/// Brand tab — watermark toggle, logo (copied into the project folder), the
/// free-drag position pad, Size / Opacity. Moved from BrandSettingsPaneAppKit.
@MainActor
enum BrandPane {
    typealias Scope = InspectorScope

    static let show = InspectorToggle(
        id: "brand.show", title: String(localized: "Show Watermark", comment: "Inspector ▸ Brand: switch label"),
        read: { $0.settings.showWatermark }, write: { $0.settings.showWatermark = $1 })
    static func hasLogo(_ s: Scope) -> Bool { s.settings.watermarkFileName != nil }
    static func chooseTitle(_ s: Scope) -> String {
        hasLogo(s)
            ? String(localized: "Replace Logo…", comment: "Inspector ▸ Brand: watermark logo button")
            : String(localized: "Choose Logo…", comment: "Inspector ▸ Brand: watermark logo button")
    }
    static let remove = InspectorAction(
        id: "brand.remove", title: String(localized: "Remove", comment: "Inspector ▸ Brand: button title"), destructive: true,
        run: { removeLogo($0) }, visible: hasLogo)
    static let detailsVisible: (Scope) -> Bool = { $0.settings.showWatermark && hasLogo($0) }
    static let size = InspectorSlider(
        id: "brand.size", title: String(localized: "Size", comment: "Inspector ▸ Brand: slider label"), range: 40...400, step: 10,
        read: { $0.settings.watermarkSize }, write: { $0.settings.watermarkSize = $1 })
    static let opacity = InspectorSlider(
        id: "brand.opacity", title: String(localized: "Opacity", comment: "Inspector ▸ Brand: slider label"), range: 0.1...1.0, step: 0.05,
        format: InspectorFormat.percent,
        read: { $0.settings.watermarkOpacity }, write: { $0.settings.watermarkOpacity = $1 })

    /// Copies a picked logo into the project folder under a fresh name
    /// (cache-busting), turns the watermark on, removes the previous file.
    static func adoptLogo(_ scope: Scope, from source: URL) throws {
        guard let project = scope.project, let folder = project.videoURL?.deletingLastPathComponent() else {
            throw InspectorMediaError.noProjectFolder
        }
        let destName = "watermark-\(UUID().uuidString.prefix(8)).\(source.pathExtension.lowercased())"
        let dest = folder.appendingPathComponent(destName)
        let previous = project.watermarkImageURL
        try FileManager.default.copyItem(at: source, to: dest)
        scope.settings.watermarkFileName = destName
        scope.settings.showWatermark = true
        if let previous { try? FileManager.default.removeItem(at: previous) }
    }

    static func removeLogo(_ scope: Scope) {
        if let url = scope.project?.watermarkImageURL {
            try? FileManager.default.removeItem(at: url)
        }
        scope.settings.watermarkFileName = nil
        scope.settings.showWatermark = false
    }

    static var sections: [InspectorSection] {
        [
            InspectorSection(id: "brand.section.brand", title: String(localized: "Brand", comment: "Inspector ▸ Brand: section header"), rows: [
                .toggle(show), .custom(id: "brand.logo", visible: { _ in true }),
            ]),
            InspectorSection(id: "brand.section.position", title: String(localized: "Position", comment: "Inspector ▸ Brand: section header"), rows: [
                .custom(id: "brand.pad", visible: { _ in true }), .slider(size), .slider(opacity),
            ], visible: detailsVisible),
        ]
    }
}
