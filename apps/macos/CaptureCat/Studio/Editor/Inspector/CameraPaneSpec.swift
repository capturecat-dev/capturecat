import Foundation

/// Camera tab — overlay (show, pad, background removal look, position,
/// shape, orientation, mirror, size, shrink, vertical stack), Cutout &
/// Pop-out styles, Adjust, Style, Name Tag. Moved verbatim from
/// CameraSettingsPaneAppKit (Studio 4d).
@MainActor
enum CameraPane {
    typealias Scope = InspectorScope

    /// The detail rows exist only for a recorded, shown camera.
    static func showDetails(_ s: Scope) -> Bool { s.env.hasRecordedCamera && s.settings.showCamera }

    // MARK: Camera overlay

    static let show = InspectorToggle(
        id: "camera.show", title: String(localized: "Show Camera", comment: "Inspector ▸ Camera: switch label"),
        read: { $0.settings.showCamera }, write: { $0.settings.showCamera = $1 },
        enabled: { $0.env.hasRecordedCamera })
    static let noCameraCaption = InspectorCaption(
        id: "camera.noCamera", String(localized: "No recorded camera video is available for this project."),
        visible: { !$0.env.hasRecordedCamera })

    /// Background removal for the WHOLE video: None / Cutout / Pop-out card.
    /// Not a timeline block — camera-layout blocks still override it.
    static let backgroundLooks: [CameraBubbleLook?] = [nil] + CameraBubbleLook.allCases
    /// The host starts finding the person right away (idempotent) — the Mac
    /// calls its segmentation's ensureMask; iOS hands it to the background
    /// removal feature.
    static let background = InspectorChoice(
        id: "camera.background", title: String(localized: "Background", comment: "Inspector ▸ Camera: option picker label"), style: .chips,
        items: backgroundLooks.map { $0?.displayName ?? String(localized: "None", comment: "Inspector ▸ Camera: option meaning no background removal look") },
        read: { backgroundLooks.firstIndex(of: $0.settings.cameraLook) ?? 0 },
        write: { $0.settings.cameraLook = backgroundLooks[$1] },
        visible: showDetails)
    /// Picking a corner from the menu clears free placement.
    static let position = InspectorChoice(
        id: "camera.position", title: String(localized: "Position", comment: "Inspector ▸ Camera: option picker label"), style: .menu,
        items: ProjectSettings.CameraPosition.allCases.map(\.displayName),
        read: { ProjectSettings.CameraPosition.allCases.firstIndex(of: $0.settings.cameraPosition) ?? 0 },
        write: { scope, index in
            scope.settings.cameraPosition = ProjectSettings.CameraPosition.allCases[index]
            scope.settings.cameraCustomX = nil
            scope.settings.cameraCustomY = nil
        },
        visible: showDetails)
    static let shape = InspectorChoice(
        id: "camera.shape", title: String(localized: "Shape", comment: "Inspector ▸ Camera: option picker label"), style: .menu,
        items: ProjectSettings.CameraShape.allCases.map(\.displayName),
        read: { ProjectSettings.CameraShape.allCases.firstIndex(of: $0.settings.cameraShape) ?? 0 },
        write: { $0.settings.cameraShape = ProjectSettings.CameraShape.allCases[$1] },
        visible: showDetails)
    /// Orientation only applies to the aspect-following shapes — circle and
    /// square are always 1:1.
    static func aspectShape(_ s: Scope) -> Bool {
        s.settings.cameraShape == .roundedRect || s.settings.cameraShape == .squircle
    }
    static let orientation = InspectorChoice(
        id: "camera.orientation", title: String(localized: "Orientation", comment: "Inspector ▸ Camera: option picker label"), style: .chips,
        items: ProjectSettings.CameraOrientation.allCases.map(\.displayName),
        read: { ProjectSettings.CameraOrientation.allCases.firstIndex(of: $0.settings.cameraOrientation) ?? 0 },
        write: { $0.settings.cameraOrientation = ProjectSettings.CameraOrientation.allCases[$1] },
        visible: { showDetails($0) && aspectShape($0) })
    static let mirror = InspectorToggle(
        id: "camera.mirror", title: String(localized: "Mirror Camera", comment: "Inspector ▸ Camera: switch label"),
        read: { $0.settings.cameraMirrored }, write: { $0.settings.cameraMirrored = $1 },
        visible: showDetails)
    /// Shown as % of canvas width — the stored value stays nominal-canvas
    /// points (persistence identity; 1456 pt nominal width = 100%). 8% floor:
    /// below that the bubble reads as a dot and the name tag has nowhere to
    /// live. 22% ceiling gives presenter-style prominence.
    static let size = InspectorSlider(
        id: "camera.size", title: String(localized: "Size", comment: "Inspector ▸ Camera: slider label"), range: 8...22, step: 0.5,
        format: { $0.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int($0))%" : String(format: "%.1f%%", $0) },
        read: { $0.settings.effectiveCameraSize / 1456 * 100 },
        write: { $0.settings.cameraSize = $1 / 100 * 1456 },
        visible: showDetails)
    /// §12.5 — off keeps the bubble at its size while the screen zooms.
    /// Default (on) is stored as nil so untouched projects stay byte-identical.
    static let shrink = InspectorToggle(
        id: "camera.shrink", title: String(localized: "Shrink During Zoom", comment: "Inspector ▸ Camera: switch label"),
        read: { $0.settings.cameraShrinkOnZoom ?? true },
        write: { $0.settings.cameraShrinkOnZoom = $1 ? nil : false },
        visible: showDetails)
    /// §12.12 — vertical videos: camera row on top, screen below.
    static let stack = InspectorToggle(
        id: "camera.stack", title: String(localized: "Stack on Top in Vertical Video", comment: "Inspector ▸ Camera: switch label"),
        read: { $0.settings.cameraPortraitStack ?? false },
        write: { $0.settings.cameraPortraitStack = $1 },
        visible: showDetails)
    static func stackShown(_ s: Scope) -> Bool { showDetails(s) && (s.settings.cameraPortraitStack ?? false) }
    static let stackHeight = InspectorSlider(
        id: "camera.stackHeight", title: String(localized: "Camera Height", comment: "Inspector ▸ Camera: slider label"), range: 25...70, step: 1,
        format: { "\(Int($0.rounded()))%" },
        read: { CameraLayoutMath.stackRatio($0.settings.cameraStackRatio) * 100 },
        write: { $0.settings.cameraStackRatio = $1 / 100 },
        visible: stackShown)
    /// §12.14 — the gap between the rows; None joins them into one card.
    static let stackGap = InspectorSlider(
        id: "camera.stackGap", title: String(localized: "Gap", comment: "Inspector ▸ Camera: slider label"), range: 0...8, step: 1,
        format: { $0 < 0.5 ? String(localized: "None", comment: "Inspector ▸ Camera: Gap slider readout when there is no gap") : "\(Int($0.rounded()))%" },
        read: { CameraLayoutMath.stackGap($0.settings.cameraStackGap) * 100 },
        write: { $0.settings.cameraStackGap = $1.rounded() / 100 },
        visible: stackShown)

    // MARK: Cutout & Pop-out (docs/camera-cutout.md §12)

    private static func regionLooks(_ s: Scope) -> [CameraBubbleLook] {
        s.project?.cameraLayoutRegions.compactMap(\.effectiveLook) ?? []
    }
    /// The section shows while the project uses a look anywhere.
    static func looksShown(_ s: Scope) -> Bool {
        showDetails(s) && (s.settings.cameraLook != nil || !regionLooks(s).isEmpty)
    }
    /// The card rows only while a pop-out card can draw.
    static func usesPopOut(_ s: Scope) -> Bool {
        looksShown(s) && (s.settings.cameraLook == .popOut || regionLooks(s).contains(.popOut))
    }
    private static func style(_ s: Scope) -> CameraCardStyle { CameraCardStyle(s.settings) }

    static let edgeSoftness = InspectorSlider(
        id: "camera.edgeSoftness", title: String(localized: "Edge Softness", comment: "Inspector ▸ Camera: slider label"), range: 0...1, step: 0.05,
        format: InspectorFormat.percent,
        read: { style($0).edgeSoftness }, write: { $0.settings.cameraEdgeSoftness = $1 }, visible: looksShown)
    static let edgeInset = InspectorSlider(
        id: "camera.edgeInset", title: String(localized: "Edge Inset", comment: "Inspector ▸ Camera: slider label"), range: 0...1, step: 0.05,
        format: InspectorFormat.percent,
        read: { style($0).edgeInset }, write: { $0.settings.cameraEdgeInset = $1 }, visible: looksShown)
    static let popOut = InspectorSlider(
        id: "camera.popOut", title: String(localized: "Pop-out", comment: "Inspector ▸ Camera: slider label"), range: 0...1, step: 0.05,
        format: InspectorFormat.percent,
        read: { style($0).popOutAmount ?? 0.5 }, write: { $0.settings.cameraPopOutAmount = $1 }, visible: usesPopOut)
    static let cardFill = InspectorChoice(
        id: "camera.cardFill", title: String(localized: "Card", comment: "Inspector ▸ Camera: option picker label"), style: .chips,
        items: CameraCardFill.allCases.map(\.displayName),
        read: { CameraCardFill.allCases.firstIndex(of: style($0).fill) ?? 0 },
        write: { $0.settings.cameraCardFill = CameraCardFill.allCases[$1] },
        visible: usesPopOut)
    private static func fill(_ s: Scope) -> CameraCardFill { style(s).fill }
    static let cardGradientStart = InspectorColor(
        id: "camera.cardGradientStart", title: String(localized: "Card Colors", comment: "Inspector ▸ Camera: color well label"),
        read: { CodableColor(style($0).gradientTop) }, write: { $0.settings.cameraCardGradientStart = $1 },
        visible: { usesPopOut($0) && fill($0) == .gradient })
    static let cardGradientEnd = InspectorColor(
        id: "camera.cardGradientEnd", title: String(localized: "Card Colors", comment: "Inspector ▸ Camera: color well label"),
        read: { CodableColor(style($0).gradientBottom) }, write: { $0.settings.cameraCardGradientEnd = $1 },
        visible: { usesPopOut($0) && fill($0) == .gradient })
    static let cardColor = InspectorColor(
        id: "camera.cardColor", title: String(localized: "Card Color", comment: "Inspector ▸ Camera: color well label"),
        read: { CodableColor(style($0).color) }, write: { $0.settings.cameraCardColor = $1 },
        visible: { usesPopOut($0) && fill($0) == .color })
    static let backgroundBlur = InspectorSlider(
        id: "camera.backgroundBlur", title: String(localized: "Background Blur", comment: "Inspector ▸ Camera: slider label"), range: 0...1, step: 0.05,
        format: InspectorFormat.percent,
        read: { min(1, max(0, $0.settings.cameraBackgroundBlur ?? 0)) },
        write: { $0.settings.cameraBackgroundBlur = $1 },
        visible: { usesPopOut($0) && fill($0) == .camera })
    static let cardImageVisible: (Scope) -> Bool = { usesPopOut($0) && fill($0) == .image }
    /// A picked card image (or wallpaper tile).
    static func adoptCardImage(_ scope: Scope, path: String) {
        scope.settings.cameraCardImagePath = path
    }
    static let cardBorders: [CameraCardBorder?] = [nil] + CameraCardBorder.allCases
    static let cardBorder = InspectorChoice(
        id: "camera.cardBorder", title: String(localized: "Border", comment: "Inspector ▸ Camera: option picker label"), style: .chips,
        items: cardBorders.map { $0?.displayName ?? String(localized: "None", comment: "Inspector ▸ Camera: pop-out card border option, no border") },
        read: { cardBorders.firstIndex(of: style($0).border) ?? 0 },
        write: { $0.settings.cameraCardBorder = cardBorders[$1] },
        visible: usesPopOut)
    static let cardBorderWidth = InspectorSlider(
        id: "camera.cardBorderWidth", title: String(localized: "Thickness", comment: "Inspector ▸ Camera: slider label"), range: 0...1, step: 0.05,
        format: InspectorFormat.percent,
        read: { style($0).borderThickness }, write: { $0.settings.cameraCardBorderWidth = $1 },
        visible: { usesPopOut($0) && style($0).border != nil })
    static let cardBorderColor = InspectorColor(
        id: "camera.cardBorderColor", title: String(localized: "Border Color", comment: "Inspector ▸ Camera: color well label"),
        read: { CodableColor(style($0).borderColor) }, write: { $0.settings.cameraCardBorderColor = $1 },
        visible: { usesPopOut($0) && style($0).border == .solid })

    // MARK: Adjust

    static let brightness = InspectorSlider(
        id: "camera.brightness", title: String(localized: "Brightness", comment: "Inspector ▸ Camera: slider label"), range: -1...1, step: 0.05,
        read: { $0.settings.cameraBrightness }, write: { $0.settings.cameraBrightness = $1 })
    static let contrast = InspectorSlider(
        id: "camera.contrast", title: String(localized: "Contrast", comment: "Inspector ▸ Camera: slider label"), range: 0.5...1.5, step: 0.05,
        read: { $0.settings.cameraContrast }, write: { $0.settings.cameraContrast = $1 })
    static let saturation = InspectorSlider(
        id: "camera.saturation", title: String(localized: "Saturation", comment: "Inspector ▸ Camera: slider label"), range: 0...2, step: 0.05,
        read: { $0.settings.cameraSaturation }, write: { $0.settings.cameraSaturation = $1 })
    static let hue = InspectorSlider(
        id: "camera.hue", title: String(localized: "Hue", comment: "Inspector ▸ Camera: slider label"), range: -180...180, step: 5,
        format: { "\(Int($0))°" },
        read: { $0.settings.cameraHue }, write: { $0.settings.cameraHue = $1 })
    static let filter = InspectorChoice(
        id: "camera.filter", title: String(localized: "Look", comment: "Inspector ▸ Camera: option picker label"), style: .chips,
        items: ProjectSettings.CameraFilterStyle.allCases.map(\.displayName),
        read: { ProjectSettings.CameraFilterStyle.allCases.firstIndex(of: $0.settings.cameraFilter) ?? 0 },
        write: { $0.settings.cameraFilter = ProjectSettings.CameraFilterStyle.allCases[$1] })
    static let ringLight = InspectorSlider(
        id: "camera.ringLight", title: String(localized: "Ring Light", comment: "Inspector ▸ Camera: slider label"), range: 0...1, step: 0.05,
        format: InspectorFormat.percentTruncating,
        read: { $0.settings.cameraRingLight }, write: { $0.settings.cameraRingLight = $1 })

    // MARK: Style

    /// Corner radius only applies to the rounded-rect shape.
    static let cornerRadius = InspectorSlider(
        id: "camera.cornerRadius", title: String(localized: "Corner Radius", comment: "Inspector ▸ Camera: slider label"), range: 0...60, step: 1,
        read: { $0.settings.cameraCornerRadius }, write: { $0.settings.cameraCornerRadius = $1 },
        visible: { showDetails($0) && $0.settings.cameraShape == .roundedRect })
    static let borderWidth = InspectorSlider(
        id: "camera.borderWidth", title: String(localized: "Border", comment: "Inspector ▸ Camera: slider label"), range: 0...8, step: 0.5,
        read: { $0.settings.cameraBorderWidth }, write: { $0.settings.cameraBorderWidth = $1 })
    static let borderColor = InspectorColor(
        id: "camera.borderColor", title: String(localized: "Border Color", comment: "Inspector ▸ Camera: color well label"),
        read: { CodableColor(CameraStyleMath.borderNSColor($0.settings)) },
        write: { $0.settings.cameraBorderColor = $1 })
    /// Back to the default white 30% (nil).
    static let borderColorReset = InspectorAction(
        id: "camera.borderColorReset", title: String(localized: "Reset", comment: "Inspector ▸ Camera: button title"),
        run: { $0.settings.cameraBorderColor = nil })
    static let opacity = InspectorSlider(
        id: "camera.opacity", title: String(localized: "Opacity", comment: "Inspector ▸ Camera: slider label"), range: 0.2...1, step: 0.05,
        format: InspectorFormat.percentTruncating,
        read: { $0.settings.cameraOpacity }, write: { $0.settings.cameraOpacity = $1 })
    /// House 2D tilt pad, capped at ±25°.
    static let tiltMaxAngle: Double = 25
    static func tilt(_ scope: Scope, pitch: Double, yaw: Double) {
        scope.settings.cameraTiltPitch = pitch
        scope.settings.cameraTiltYaw = yaw
    }

    // MARK: Name tag

    static let tagText = InspectorText(
        id: "camera.tagText", title: String(localized: "Name", comment: "Inspector ▸ Camera: text field label"), placeholder: String(localized: "Name", comment: "Inspector ▸ Camera: placeholder in a text field"), commit: .live,
        read: { $0.settings.cameraTagText }, write: { $0.settings.cameraTagText = $1 })
    static let tagSubtext = InspectorText(
        id: "camera.tagSubtext", title: String(localized: "Role", comment: "Inspector ▸ Camera: text field label"), placeholder: String(localized: "Role / company", comment: "Inspector ▸ Camera: placeholder in a text field"), commit: .live,
        read: { $0.settings.cameraTagSubtext }, write: { $0.settings.cameraTagSubtext = $1 })
    static let tagPosition = InspectorChoice(
        id: "camera.tagPosition", title: String(localized: "Tag Position", comment: "Inspector ▸ Camera: option picker label"), style: .menu,
        items: ProjectSettings.CameraTagPosition.allCases.map(\.displayName),
        read: { ProjectSettings.CameraTagPosition.allCases.firstIndex(of: $0.settings.cameraTagPosition) ?? 0 },
        write: { $0.settings.cameraTagPosition = ProjectSettings.CameraTagPosition.allCases[$1] })
    static let tagTextColor = InspectorColor(
        id: "camera.tagTextColor", title: String(localized: "Text Color", comment: "Inspector ▸ Camera: color well label"),
        read: { $0.settings.cameraTagTextColor }, write: { $0.settings.cameraTagTextColor = $1 })
    static let tagFill = InspectorColor(
        id: "camera.tagFill", title: String(localized: "Tag Fill", comment: "Inspector ▸ Camera: color well label"),
        read: { $0.settings.cameraTagBackgroundColor }, write: { $0.settings.cameraTagBackgroundColor = $1 })

    // MARK: Layout

    static var sections: [InspectorSection] {
        [
            InspectorSection(id: "camera.section.overlay", title: String(localized: "Camera Overlay", comment: "Inspector ▸ Camera: section header"), rows: [
                .toggle(show), .caption(noCameraCaption),
                .custom(id: "camera.pad", visible: { _ in true }),
                .choice(background),
                .feature(.removeBackground, visible: { showDetails($0) && $0.settings.cameraLook != nil }),
                .choice(position), .choice(shape), .choice(orientation), .toggle(mirror), .slider(size),
                .toggle(shrink), .toggle(stack), .slider(stackHeight), .slider(stackGap),
            ]),
            InspectorSection(id: "camera.section.looks", title: String(localized: "Cutout & Pop-out", comment: "Inspector ▸ Camera: section header"), rows: [
                .slider(edgeSoftness), .slider(edgeInset), .slider(popOut), .choice(cardFill),
                .colorPair(title: String(localized: "Card Colors", comment: "Inspector ▸ Camera: label for two color wells"), cardGradientStart, cardGradientEnd), .color(cardColor),
                .slider(backgroundBlur),
                .custom(id: "camera.cardImage", visible: cardImageVisible),
                .choice(cardBorder), .slider(cardBorderWidth), .color(cardBorderColor),
            ], visible: looksShown),
            InspectorSection(id: "camera.section.adjust", title: String(localized: "Adjust", comment: "Inspector ▸ Camera: section header"), rows: [
                .slider(brightness), .slider(contrast), .slider(saturation), .slider(hue), .choice(filter),
                .slider(ringLight),
            ], visible: showDetails),
            InspectorSection(id: "camera.section.style", title: String(localized: "Style", comment: "Inspector ▸ Camera: section header"), rows: [
                .slider(cornerRadius), .slider(borderWidth), .color(borderColor), .action(borderColorReset),
                .slider(opacity), .custom(id: "camera.tiltPad", visible: { _ in true }),
            ], visible: showDetails),
            InspectorSection(id: "camera.section.tag", title: String(localized: "Name Tag", comment: "Inspector ▸ Camera: section header"), rows: [
                .text(tagText), .text(tagSubtext), .choice(tagPosition), .color(tagTextColor), .color(tagFill),
            ], visible: showDetails),
        ]
    }
}
