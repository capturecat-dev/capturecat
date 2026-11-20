import Foundation

/// Background tab — background type, colours/image/wallpaper source, Look
/// adjustments, Frame (placement + pad, padding, shape, corners, shadows),
/// menu bar replacement. Values and rules moved verbatim from
/// BackgroundSettingsPaneAppKit (Studio 4d).
@MainActor
enum BackgroundPane {
    typealias Scope = InspectorScope
    private static func bgType(_ s: Scope) -> ProjectSettings.BackgroundType { s.settings.backgroundType }

    // MARK: Background

    static let type = InspectorChoice(
        id: "background.type", title: String(localized: "Background", comment: "Inspector ▸ Background: option picker label"), style: .chips,
        items: ProjectSettings.BackgroundType.allCases.map(\.displayName),
        read: { ProjectSettings.BackgroundType.allCases.firstIndex(of: $0.settings.backgroundType) ?? 0 },
        write: { $0.settings.backgroundType = ProjectSettings.BackgroundType.allCases[$1] })

    private static func usesRamp(_ s: Scope) -> Bool { bgType(s) == .gradient || bgType(s) == .mesh }

    static let gradientStart = InspectorColor(
        id: "background.gradientStart", title: String(localized: "Start Color", comment: "Inspector ▸ Background: color well label"),
        read: { $0.settings.gradientStartColor }, write: { $0.settings.gradientStartColor = $1 },
        visible: usesRamp)
    static let gradientEnd = InspectorColor(
        id: "background.gradientEnd", title: String(localized: "End Color", comment: "Inspector ▸ Background: color well label"),
        read: { $0.settings.gradientEndColor }, write: { $0.settings.gradientEndColor = $1 },
        visible: usesRamp)
    static let solid = InspectorColor(
        id: "background.solid", title: String(localized: "Color", comment: "Inspector ▸ Background: color well label"),
        read: { $0.settings.solidColor }, write: { $0.settings.solidColor = $1 },
        visible: { bgType($0) == .solid })
    /// nil = legacy corner-to-corner diagonal; shown as the nearest round
    /// number until the user takes over.
    static let angle = InspectorSlider(
        id: "background.angle", title: String(localized: "Angle", comment: "Inspector ▸ Background: slider label"), range: 0...360, step: 5,
        format: InspectorFormat.degreesRounded,
        read: { $0.settings.gradientAngle ?? 135 }, write: { $0.settings.gradientAngle = $1 },
        visible: { bgType($0) == .gradient })
    /// The host picks the file (NSOpenPanel / the iOS photo picker) and calls
    /// `adoptImage`.
    static let chooseImageVisible: (Scope) -> Bool = { bgType($0) == .image }
    static let wallpaperVisible: (Scope) -> Bool = { bgType($0) == .wallpaper }
    static let transparentCaption = InspectorCaption(
        id: "background.transparentCaption", String(localized: "No additional settings"),
        visible: { bgType($0) == .transparent })

    /// A picked image or wallpaper tile becomes the background.
    static func adoptImage(_ scope: Scope, path: String) {
        scope.settings.backgroundImagePath = path
    }

    // MARK: Look

    static let lookVisible: (Scope) -> Bool = { bgType($0) != .transparent }

    static let blur = InspectorSlider(
        id: "background.blur", title: String(localized: "Blur", comment: "Inspector ▸ Background: slider label"), range: 0...1, step: 0.02,
        read: { $0.settings.backgroundBlur }, write: { $0.settings.backgroundBlur = $1 })
    static let pixelate = InspectorSlider(
        id: "background.pixelate", title: String(localized: "Pixelate", comment: "Inspector ▸ Background: slider label"), range: 0...1, step: 0.02,
        read: { $0.settings.backgroundPixelate }, write: { $0.settings.backgroundPixelate = $1 })
    static let halftone = InspectorSlider(
        id: "background.halftone", title: String(localized: "Halftone", comment: "Inspector ▸ Background: slider label"), range: 0...1, step: 0.02,
        read: { $0.settings.backgroundHalftone }, write: { $0.settings.backgroundHalftone = $1 })
    static let grain = InspectorSlider(
        id: "background.grain", title: String(localized: "Grain", comment: "Inspector ▸ Background: slider label"), range: 0...1, step: 0.02,
        read: { $0.settings.backgroundNoise }, write: { $0.settings.backgroundNoise = $1 })
    static let brightness = InspectorSlider(
        id: "background.brightness", title: String(localized: "Brightness", comment: "Inspector ▸ Background: slider label"), range: -1...1, step: 0.02,
        format: { v in v >= 0 ? "+\(Int((v * 100).rounded()))" : "\(Int((v * 100).rounded()))" },
        read: { $0.settings.backgroundBrightness }, write: { $0.settings.backgroundBrightness = $1 })
    static let contrast = InspectorSlider(
        id: "background.contrast", title: String(localized: "Contrast", comment: "Inspector ▸ Background: slider label"), range: 0.5...1.5, step: 0.02,
        format: InspectorFormat.times2,
        read: { $0.settings.backgroundContrast }, write: { $0.settings.backgroundContrast = $1 })
    static let saturation = InspectorSlider(
        id: "background.saturation", title: String(localized: "Saturation", comment: "Inspector ▸ Background: slider label"), range: 0...2, step: 0.05,
        format: InspectorFormat.times2,
        read: { $0.settings.backgroundSaturation }, write: { $0.settings.backgroundSaturation = $1 })
    static let hue = InspectorSlider(
        id: "background.hue", title: String(localized: "Hue", comment: "Inspector ▸ Background: slider label"), range: 0...360, step: 5,
        format: InspectorFormat.degreesRounded,
        read: { $0.settings.backgroundHue }, write: { $0.settings.backgroundHue = $1 })
    /// Picking a tint with the amount at zero would look like nothing
    /// happened — give it a visible starting strength.
    static let tint = InspectorColor(
        id: "background.tint", title: String(localized: "Tint", comment: "Inspector ▸ Background: color well label"),
        read: { $0.settings.backgroundTintColor },
        write: { scope, color in
            scope.settings.backgroundTintColor = color
            if scope.settings.backgroundTintOpacity <= 0 {
                scope.settings.backgroundTintOpacity = 0.3
            }
        })
    static let tintAmount = InspectorSlider(
        id: "background.tintAmount", title: String(localized: "Tint Amount", comment: "Inspector ▸ Background: slider label"), range: 0...1, step: 0.02,
        read: { $0.settings.backgroundTintOpacity }, write: { $0.settings.backgroundTintOpacity = $1 })
    static let vignette = InspectorSlider(
        id: "background.vignette", title: String(localized: "Vignette", comment: "Inspector ▸ Background: slider label"), range: 0...1, step: 0.02,
        read: { $0.settings.backgroundVignette }, write: { $0.settings.backgroundVignette = $1 })
    static let resetLook = InspectorAction(
        id: "background.resetLook", title: String(localized: "Reset Look", comment: "Inspector ▸ Background: button title"),
        run: { scope in
            let s = scope.settings
            s.backgroundBlur = 0
            s.backgroundBrightness = 0
            s.backgroundSaturation = 1
            s.backgroundTintOpacity = 0
            s.backgroundVignette = 0
            s.backgroundPixelate = 0
            s.backgroundHalftone = 0
            s.backgroundNoise = 0
            s.backgroundContrast = 1
            s.backgroundHue = 0
        },
        visible: { !BackgroundLook.Spec($0.settings).isPlainLook })

    // MARK: Frame

    static let deviceFrame = InspectorToggle(
        id: "background.deviceFrame", title: String(localized: "iPhone / iPad Frame", comment: "Inspector ▸ Background: switch label"),
        read: { $0.settings.showDeviceFrame }, write: { $0.settings.showDeviceFrame = $1 },
        visible: { $0.env.isDeviceRecording })
    /// Picking an anchor is an explicit choice — drop any freeform drag
    /// position, or the selection would appear to do nothing.
    static func pickPlacement(_ scope: Scope, _ placement: ProjectSettings.VideoPlacement) {
        scope.settings.videoPlacement = placement
        scope.settings.videoCustomX = nil
        scope.settings.videoCustomY = nil
    }
    /// Placement honesty: while videoCustomX/Y override the enum, say
    /// "Custom", offer the reset, and show the card where it actually is.
    static func isCustomPlacement(_ scope: Scope) -> Bool { PlacementMath.isCustom(scope.settings) }
    static let placement = InspectorChoice(
        id: "background.placement", title: String(localized: "Placement", comment: "Inspector ▸ Background: option picker label"), style: .menu,
        items: ProjectSettings.VideoPlacement.allCases.map(\.displayName),
        read: { ProjectSettings.VideoPlacement.allCases.firstIndex(of: $0.settings.videoPlacement) ?? 0 },
        write: { pickPlacement($0, ProjectSettings.VideoPlacement.allCases[$1]) },
        overrideTitle: { isCustomPlacement($0) ? String(localized: "Custom", comment: "Inspector ▸ Background ▸ Frame: placement menu title when the video was dragged to a freeform position") : nil })
    /// The pad: a touch at (fx, fy) of its bounds snaps to one of nine anchors.
    static func placementPad(_ scope: Scope, fx: CGFloat, fy: CGFloat) {
        guard let match = InspectorPadMath.placement(atFraction: fx, fy) else { return }
        pickPlacement(scope, match)
    }
    static let placementReset = InspectorAction(
        id: "background.placementReset", title: String(localized: "Reset to Center", comment: "Inspector ▸ Background: button title"),
        run: { scope in
            scope.settings.videoCustomX = nil
            scope.settings.videoCustomY = nil
            scope.settings.videoPlacement = .center
        },
        visible: isCustomPlacement)
    static let padding = InspectorSlider(
        id: "background.padding", title: String(localized: "Padding", comment: "Inspector ▸ Background: slider label"), range: 0...300, step: 4,
        read: { $0.settings.backgroundPadding }, write: { $0.settings.backgroundPadding = $1 })
    static let shape = InspectorChoice(
        id: "background.shape", title: String(localized: "Shape", comment: "Inspector ▸ Background: option picker label"), style: .menu,
        items: ProjectSettings.FrameShape.allCases.map(\.displayName),
        read: { ProjectSettings.FrameShape.allCases.firstIndex(of: $0.settings.frameShape) ?? 0 },
        write: { $0.settings.frameShape = ProjectSettings.FrameShape.allCases[$1] })
    /// One slider writes both radii (as the SwiftUI pane did).
    static let corners = InspectorSlider(
        id: "background.corners", title: String(localized: "Rounded Corners", comment: "Inspector ▸ Background: slider label"), range: 0...20, step: 1,
        read: { $0.settings.windowCornerRadius },
        write: { scope, v in
            scope.settings.windowCornerRadius = v
            scope.settings.cornerRadius = v
        })
    static let shadow = InspectorSlider(
        id: "background.shadow", title: String(localized: "Shadow", comment: "Inspector ▸ Background: slider label"), range: 0...60, step: 2,
        read: { $0.settings.shadowRadius }, write: { $0.settings.shadowRadius = $1 })
    static let shadowOpacity = InspectorSlider(
        id: "background.shadowOpacity", title: String(localized: "Shadow Opacity", comment: "Inspector ▸ Background: slider label"), range: 0...1, step: 0.05,
        format: InspectorFormat.percentTruncating,
        read: { $0.settings.shadowOpacity }, write: { $0.settings.shadowOpacity = $1 })

    // MARK: Menu bar

    static let menuBarVisible: (Scope) -> Bool = { $0.env.supportsMenuBar }
    private static func showsCustomBar(_ s: Scope) -> Bool {
        s.settings.menuBarReplacement == .dark || s.settings.menuBarReplacement == .light
    }
    /// Chip labels shorten "Clean Dark/Light" to "Dark/Light".
    static let menuBar = InspectorChoice(
        id: "background.menuBar", title: String(localized: "Menu Bar", comment: "Inspector ▸ Background: option picker label"), style: .chips,
        items: ProjectSettings.MenuBarReplacement.allCases.map {
            switch $0 {
            case .off: return String(localized: "Original", comment: "Inspector ▸ Background ▸ Menu Bar: chip, keep the recorded menu bar")
            case .hidden: return String(localized: "Hidden", comment: "Inspector ▸ Background ▸ Menu Bar: chip, crop the menu bar off")
            case .dark: return String(localized: "Dark", comment: "Inspector ▸ Background ▸ Menu Bar: chip, cover with a clean dark bar")
            case .light: return String(localized: "Light", comment: "Inspector ▸ Background ▸ Menu Bar: chip, cover with a clean light bar")
            }
        },
        read: { ProjectSettings.MenuBarReplacement.allCases.firstIndex(of: $0.settings.menuBarReplacement) ?? 0 },
        write: { $0.settings.menuBarReplacement = ProjectSettings.MenuBarReplacement.allCases[$1] })
    static let menuBarTitle = InspectorText(
        id: "background.menuBarTitle", title: String(localized: "Title", comment: "Inspector ▸ Background: text field label"), placeholder: String(localized: "App name", comment: "Inspector ▸ Background: placeholder in a text field"), commit: .live,
        read: { $0.settings.menuBarTitle }, write: { $0.settings.menuBarTitle = $1 },
        visible: showsCustomBar)
    static let menuBarAlign = InspectorChoice(
        id: "background.menuBarAlign", title: String(localized: "Align", comment: "Inspector ▸ Background: option picker label"), style: .chips,
        items: ProjectSettings.MenuBarTitleAlignment.allCases.map(\.displayName),
        read: { ProjectSettings.MenuBarTitleAlignment.allCases.firstIndex(of: $0.settings.menuBarTitleAlignment) ?? 0 },
        write: { $0.settings.menuBarTitleAlignment = ProjectSettings.MenuBarTitleAlignment.allCases[$1] },
        visible: showsCustomBar)
    static let menuBarClock = InspectorText(
        id: "background.menuBarClock", title: String(localized: "Clock", comment: "Inspector ▸ Background: text field label"), placeholder: "9:41", commit: .live,
        read: { $0.settings.menuBarClock }, write: { $0.settings.menuBarClock = $1 },
        visible: showsCustomBar)
    static let menuBarIcons = InspectorToggle(
        id: "background.menuBarIcons", title: String(localized: "Wi-Fi & Battery Icons", comment: "Inspector ▸ Background: switch label"),
        read: { $0.settings.menuBarShowStatusIcons }, write: { $0.settings.menuBarShowStatusIcons = $1 },
        visible: showsCustomBar)
    static let menuBarHeight = InspectorSlider(
        id: "background.menuBarHeight", title: String(localized: "Height", comment: "Inspector ▸ Background: slider label"), range: 2...6, step: 0.1,
        format: { String(format: "%.1f%%", $0) },
        read: { $0.settings.menuBarHeight }, write: { $0.settings.menuBarHeight = $1 },
        visible: { $0.settings.menuBarReplacement != .off })
    static let menuBarCaption = InspectorCaption(
        id: "background.menuBarCaption",
        dynamic: { scope in
            scope.settings.menuBarReplacement == .hidden
                ? String(localized: "Crops the menu bar strip off the recording entirely — adjust Height until the bar is exactly gone.")
                : String(localized: "Covers the recorded macOS menu bar with a clean bar — your own title, a fixed clock, no personal clutter. Adjust Height until it exactly hides the real bar.")
        })

    // MARK: Layout

    static var sections: [InspectorSection] {
        [
            InspectorSection(id: "background.section.background", title: String(localized: "Background", comment: "Inspector ▸ Background: section header"), rows: [
                .choice(type), .color(gradientStart), .color(gradientEnd), .color(solid), .slider(angle),
                .custom(id: "background.chooseImage", visible: chooseImageVisible),
                .custom(id: "background.wallpaperGrid", visible: wallpaperVisible),
                .caption(transparentCaption),
            ]),
            InspectorSection(id: "background.section.look", title: String(localized: "Look", comment: "Inspector ▸ Background: section header"), rows: [
                .slider(blur), .slider(pixelate), .slider(halftone), .slider(grain), .slider(brightness),
                .slider(contrast), .slider(saturation), .slider(hue), .color(tint), .slider(tintAmount),
                .slider(vignette), .action(resetLook),
            ], visible: lookVisible),
            InspectorSection(id: "background.section.frame", title: String(localized: "Frame", comment: "Inspector ▸ Background: section header"), rows: [
                .toggle(deviceFrame), .choice(placement),
                .custom(id: "background.placementPad", visible: { _ in true }),
                .action(placementReset), .slider(padding), .choice(shape), .slider(corners), .slider(shadow),
                .slider(shadowOpacity), .custom(id: "background.framePad", visible: { _ in true }),
            ]),
            InspectorSection(id: "background.section.menuBar", title: String(localized: "Menu Bar", comment: "Inspector ▸ Background: section header"), rows: [
                .choice(menuBar), .text(menuBarTitle), .choice(menuBarAlign), .text(menuBarClock),
                .toggle(menuBarIcons), .slider(menuBarHeight), .caption(menuBarCaption),
            ], visible: menuBarVisible),
        ]
    }
}
