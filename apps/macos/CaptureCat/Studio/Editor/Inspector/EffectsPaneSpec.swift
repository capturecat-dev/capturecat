import CoreGraphics
import Foundation

/// Effects tab, part 1 — every project-wide effect in ONE list, each with an
/// enable switch: Slide, Curtain Unveil, Parallax, Motion Blur. Moved
/// verbatim from EffectsSettingsPaneAppKit (Studio 4d).
@MainActor
enum EffectsPane {
    typealias Scope = InspectorScope

    // MARK: Slide

    private static func slideOn(_ s: Scope) -> Bool { s.settings.introSlideStyle != .off }
    static let slideStyles = Array(IntroSlideStyle.allCases.dropFirst())
    /// On: joined to the selected block when there is one (span snapped),
    /// else a plain global slide from the bottom.
    static let slide = InspectorToggle(
        id: "effects.slide", title: "Slide",
        read: slideOn,
        write: { scope, on in
            if on {
                if scope.motion?.onJoinSlideToSelectedBlock() != true, scope.settings.introSlideStyle == .off {
                    scope.settings.introSlideStyle = .bottom
                }
            } else {
                scope.settings.introSlideStyle = .off
            }
        })
    static let slideStyle = InspectorChoice(
        id: "effects.slideStyle", title: "Slide", style: .chips,
        items: slideStyles.map(\.rawValue),
        read: { slideStyles.firstIndex(of: $0.settings.introSlideStyle) ?? 0 },
        write: { $0.settings.introSlideStyle = slideStyles[max(0, min(slideStyles.count - 1, $1))] },
        visible: slideOn)
    static let slideBounce = InspectorSlider(
        id: "effects.slideBounce", title: "Bounce", range: 0...1, step: 0.05,
        format: { $0 < 0.026 ? "None" : "\(Int(($0 * 100).rounded()))%" },
        read: { $0.settings.introSlideBounce }, write: { $0.settings.introSlideBounce = $1 }, visible: slideOn)
    /// Pace within the block: 1x spans the whole block, higher lands early and
    /// holds. Length stays timeline-only (a slider would bypass the lane's
    /// no-overlap clamp).
    static let slideSpeed = InspectorSlider(
        id: "effects.slideSpeed", title: "Speed", range: 1...4, step: 0.25,
        format: { $0 <= 1.01 ? "1x" : String(format: "%.2gx", $0) },
        read: { $0.settings.introSlideSpeed }, write: { $0.settings.introSlideSpeed = $1 }, visible: slideOn)
    static let slideDepth = InspectorToggle(
        id: "effects.slideDepth", title: "Pull Toward Viewer",
        read: { $0.settings.introSlideDepth }, write: { $0.settings.introSlideDepth = $1 }, visible: slideOn)
    static let slideCaption = InspectorCaption(
        id: "effects.slideCaption",
        "Slides in from an edge — drag the Slide block on the EFFECTS lane to place it.",
        full: "The screen slides from an edge with a punchy settle. Pull Toward Viewer adds a 3D depth pull — the card starts small and deep, then dollies to the front as it lands. Drag the yellow Slide block on the EFFECTS lane to place it anywhere — at 0:00 it plays as the intro.")

    // MARK: Curtain Unveil

    private static func curtainOn(_ s: Scope) -> Bool { s.settings.curtainUnveilCorner != .off }
    private static func hasLogo(_ s: Scope) -> Bool { s.settings.curtainLogoFileName != nil }
    private static func logoShown(_ s: Scope) -> Bool { curtainOn(s) && hasLogo(s) }
    static let curtainCorners = Array(CurtainUnveilCorner.allCases.dropFirst())
    static let curtain = InspectorToggle(
        id: "effects.curtain", title: "Curtain Unveil",
        read: curtainOn, write: { $0.settings.curtainUnveilCorner = $1 ? .topLeft : .off })
    static let curtainCorner = InspectorChoice(
        id: "effects.curtainCorner", title: "Curtain Unveil", style: .chips,
        items: curtainCorners.map(\.rawValue),
        read: { curtainCorners.firstIndex(of: $0.settings.curtainUnveilCorner) ?? 0 },
        write: { $0.settings.curtainUnveilCorner = curtainCorners[max(0, min(curtainCorners.count - 1, $1))] },
        visible: curtainOn)
    static let curtainLength = InspectorSlider(
        id: "effects.curtainLength", title: "Length", range: 0.4...3.0, step: 0.1,
        format: InspectorFormat.seconds1,
        read: { $0.settings.curtainUnveilDuration }, write: { $0.settings.curtainUnveilDuration = $1 },
        visible: curtainOn)
    /// No custom colour shows the math's shared charcoal top stop.
    static let curtainColor = InspectorColor(
        id: "effects.curtainColor", title: "Curtain",
        read: { scope in
            scope.settings.curtainColor ?? {
                let c = CurtainUnveilMath.coverColorTop
                return CodableColor(red: Double(c.r), green: Double(c.g), blue: Double(c.b), opacity: Double(c.a))
            }()
        },
        write: { $0.settings.curtainColor = $1 },
        visible: curtainOn)
    static let curtainColorReset = InspectorAction(
        id: "effects.curtainColorReset", title: "Reset Color",
        run: { $0.settings.curtainColor = nil },
        visible: { curtainOn($0) && $0.settings.curtainColor != nil })
    /// The host picks the file and calls `adoptCurtainLogo`.
    static let curtainLogoChooseTitle: (Scope) -> String = { hasLogo($0) ? "Replace Logo…" : "Choose Logo…" }
    static let curtainLogoChooseVisible: (Scope) -> Bool = curtainOn
    static let curtainLogoRemove = InspectorAction(
        id: "effects.curtainLogoRemove", title: "Remove Logo", destructive: true,
        run: { removeCurtainLogo($0) },
        visible: logoShown)
    static let curtainLogoOpacity = InspectorSlider(
        id: "effects.curtainLogoOpacity", title: "Logo Opacity", range: 0...1, step: 0.05,
        format: InspectorFormat.percent,
        read: { $0.settings.curtainLogoOpacity }, write: { $0.settings.curtainLogoOpacity = $1 },
        visible: logoShown)
    static let curtainLogoSize = InspectorSlider(
        id: "effects.curtainLogoSize", title: "Logo Size", range: 0.05...0.8, step: 0.05,
        format: InspectorFormat.percent,
        read: { $0.settings.curtainLogoScale }, write: { $0.settings.curtainLogoScale = $1 },
        visible: logoShown)
    static let curtainLogoTint = InspectorToggle(
        id: "effects.curtainLogoTint", title: "Tint Logo",
        read: { $0.settings.curtainLogoTint != nil },
        write: { $0.settings.curtainLogoTint = $1 ? SystemColorDefaults.white : nil },
        visible: logoShown)
    static let curtainLogoTintColor = InspectorColor(
        id: "effects.curtainLogoTintColor", title: "Tint",
        read: { $0.settings.curtainLogoTint ?? SystemColorDefaults.white },
        write: { $0.settings.curtainLogoTint = $1 },
        visible: { logoShown($0) && $0.settings.curtainLogoTint != nil })
    static let curtainCaption = InspectorCaption(
        id: "effects.curtainCaption",
        "A curtain peels away from the chosen corner to reveal the video.",
        full: "A curtain covers the screen and peels away from the chosen corner like a page turn, revealing the video underneath. Add a logo and it rides the curtain, peeling away with it. Drag the Curtain block on the EFFECTS lane to place it.")

    /// Copies a picked logo into the project folder under a fresh name
    /// (cache-busting) and removes the previous file — the Brand pane's
    /// watermark semantics. Throws when there is no folder or the copy fails.
    static func adoptCurtainLogo(_ scope: Scope, from source: URL) throws {
        guard let project = scope.project, let folder = project.videoURL?.deletingLastPathComponent() else {
            throw InspectorMediaError.noProjectFolder
        }
        let destName = "curtain-logo-\(UUID().uuidString.prefix(8)).\(source.pathExtension.lowercased())"
        let dest = folder.appendingPathComponent(destName)
        let previous = project.curtainLogoImageURL
        try FileManager.default.copyItem(at: source, to: dest)
        scope.settings.curtainLogoFileName = destName
        if let previous { try? FileManager.default.removeItem(at: previous) }
    }

    static func removeCurtainLogo(_ scope: Scope) {
        if let url = scope.project?.curtainLogoImageURL {
            try? FileManager.default.removeItem(at: url)
        }
        scope.settings.curtainLogoFileName = nil
    }

    // MARK: Parallax

    private static func parallaxOn(_ s: Scope) -> Bool { s.settings.parallaxStrength > 0.001 }
    static let parallax = InspectorToggle(
        id: "effects.parallax", title: "Parallax",
        read: parallaxOn, write: { $0.settings.parallaxStrength = $1 ? 0.4 : 0 })
    static let parallaxStrength = InspectorSlider(
        id: "effects.parallaxStrength", title: "Strength", range: 0.05...1, step: 0.05,
        format: InspectorFormat.percent,
        read: { $0.settings.parallaxStrength }, write: { $0.settings.parallaxStrength = $1 }, visible: parallaxOn)
    static let parallaxCaption = InspectorCaption(
        id: "effects.parallaxCaption", "The background drifts gently with zooms for a sense of depth.")

    // MARK: Motion blur

    private static func blurOn(_ s: Scope) -> Bool { s.settings.motionBlur }
    static let motionBlur = InspectorToggle(
        id: "effects.motionBlur", title: "Motion Blur",
        read: blurOn, write: { $0.settings.motionBlur = $1 })
    static let motionBlurStrength = InspectorSlider(
        id: "effects.motionBlurStrength", title: "Strength", range: 0...1, step: 0.05,
        format: InspectorFormat.percent,
        read: { $0.settings.motionBlurStrength }, write: { $0.settings.motionBlurStrength = $1 }, visible: blurOn)
    static let motionBlurCaption = InspectorCaption(
        id: "effects.motionBlurCaption", "Subtle blur during fast camera movement, for a more natural look.",
        full: "Adds subtle blur during fast camera movements for a more natural look.")

    static var sections: [InspectorSection] {
        [
            InspectorSection(id: "effects.section.slide", title: "Slide", rows: [
                .toggle(slide), .choice(slideStyle), .custom(id: "effects.slidePad", visible: slideOn),
                .slider(slideBounce), .slider(slideSpeed), .toggle(slideDepth), .caption(slideCaption),
            ]),
            InspectorSection(id: "effects.section.curtain", title: "Curtain Unveil", rows: [
                .toggle(curtain), .choice(curtainCorner), .slider(curtainLength), .color(curtainColor),
                .action(curtainColorReset),
                .custom(id: "effects.curtainLogo", visible: curtainLogoChooseVisible),
                .slider(curtainLogoOpacity), .slider(curtainLogoSize), .toggle(curtainLogoTint),
                .color(curtainLogoTintColor), .caption(curtainCaption),
            ]),
            InspectorSection(id: "effects.section.parallax", title: "Parallax", rows: [
                .toggle(parallax), .slider(parallaxStrength), .custom(id: "effects.parallaxPad", visible: parallaxOn),
                .caption(parallaxCaption),
            ]),
            InspectorSection(id: "effects.section.motionBlur", title: "Motion Blur", rows: [
                .toggle(motionBlur), .slider(motionBlurStrength),
                .custom(id: "effects.motionBlurPad", visible: blurOn), .caption(motionBlurCaption),
            ]),
        ]
    }
}

enum InspectorMediaError: LocalizedError {
    case noProjectFolder

    var errorDescription: String? {
        switch self {
        case .noProjectFolder: return "Project folder not available."
        }
    }
}

/// Effects tab, part 2 — the selected EFFECTS/FOCUS block's editors: Zoom,
/// Tilt, Highlight Mask, Depth Focus, Blur. Every target is reached through
/// the MotionPaneContext's accessors (the selection). Moved verbatim from
/// MotionSettingsPaneAppKit.
@MainActor
enum EffectBlocksPane {
    typealias Scope = InspectorScope

    private static func zoom(_ s: Scope) -> ZoomRegion? { s.motion?.zoomRegion.wrappedValue }
    private static func tiltRegion(_ s: Scope) -> TiltRegion? { s.motion?.tiltRegion.wrappedValue }
    private static func highlight(_ s: Scope) -> HighlightRegion? { s.motion?.highlightRegion.wrappedValue }
    private static func depth(_ s: Scope) -> FocusRegion? { s.motion?.focusRegion.wrappedValue }
    private static func blur(_ s: Scope) -> BlurRegion? { s.motion?.blurRegion.wrappedValue }
    static func hasZoom(_ s: Scope) -> Bool { zoom(s) != nil }
    static func hasTilt(_ s: Scope) -> Bool { tiltRegion(s) != nil }
    static func hasHighlight(_ s: Scope) -> Bool { highlight(s) != nil }
    static func hasDepth(_ s: Scope) -> Bool { depth(s) != nil }
    static func hasBlur(_ s: Scope) -> Bool { blur(s) != nil }

    private static func styleItems() -> [String] { ["Default"] + ZoomAnimationStyle.allCases.map(\.rawValue) }
    private static func styleIndex(_ style: ZoomAnimationStyle?) -> Int {
        style.flatMap { ZoomAnimationStyle.allCases.firstIndex(of: $0).map { $0 + 1 } } ?? 0
    }
    private static func style(at index: Int) -> ZoomAnimationStyle? {
        index == 0 ? nil : ZoomAnimationStyle.allCases[index - 1]
    }

    // MARK: Zoom

    /// On a selected tilt it stacks a zoom onto that block; with nothing
    /// selected it drops a zoom block at the playhead. Off removes it.
    static let zoomToggle = InspectorToggle(
        id: "blocks.zoom", title: "Zoom",
        read: hasZoom,
        write: { scope, on in
            guard let m = scope.motion else { return }
            if on {
                if m.tiltRegion.wrappedValue != nil { m.onAddZoomToBlock() } else { m.onAddZoomBlockAtPlayhead() }
            } else if m.zoomRegion.wrappedValue != nil {
                m.onDeleteZoom()
            }
        })
    /// Below 1.0 the "zoom" is a SCALE-DOWN toward the focal point.
    static let zoomLevel = InspectorSlider(
        id: "blocks.zoomLevel", title: "Zoom / Scale", range: 0.3...6.0, step: 0.1,
        format: InspectorFormat.multiplier1,
        read: { zoom($0)?.zoomLevel ?? 1 }, write: { $0.motion?.zoomRegion.wrappedValue?.zoomLevel = $1 },
        visible: hasZoom)
    /// Per-block animation style: Default follows the project speed.
    static let zoomSpeed = InspectorChoice(
        id: "blocks.zoomSpeed", title: "Speed", style: .menu, items: styleItems(),
        read: { styleIndex(zoom($0)?.animationStyle) },
        write: { $0.motion?.zoomRegion.wrappedValue?.animationStyle = style(at: $1) },
        visible: hasZoom)
    static let followCursor = InspectorToggle(
        id: "blocks.followCursor", title: "Follow Cursor",
        read: { zoom($0)?.followsCursor ?? true },
        write: { $0.motion?.zoomRegion.wrappedValue?.followsCursor = $1 ? nil : false },
        visible: hasZoom)
    /// Aim the zoom: where the push-in points, 0…1 in video space.
    static func focus(_ scope: Scope, fx: CGFloat, fy: CGFloat) {
        scope.motion?.zoomRegion.wrappedValue?.focalPoint = InspectorPadMath.focal(fx: fx, fy: fy)
    }
    static func focal(_ scope: Scope) -> CGPoint { zoom(scope)?.focalPoint ?? CGPoint(x: 0.5, y: 0.5) }
    /// Card excursion during the block — the pad's point (0…1).
    static func offset(_ scope: Scope, point: CGPoint) {
        let offset = InspectorPadMath.cardOffset(padPoint: point)
        scope.motion?.zoomRegion.wrappedValue?.cardOffsetX = offset.x
        scope.motion?.zoomRegion.wrappedValue?.cardOffsetY = offset.y
    }
    static func offsetPoint(_ scope: Scope) -> CGPoint {
        InspectorPadMath.padPoint(cardOffsetX: zoom(scope)?.cardOffsetX, y: zoom(scope)?.cardOffsetY)
    }
    static let zoomCaption = InspectorCaption(
        id: "blocks.zoomCaption", "How far this block pushes in — the EFFECTS block shows the level.",
        full: "How far this block pushes in. The block on the EFFECTS lane shows the level.",
        visible: hasZoom)

    // MARK: Tilt

    static let tiltToggle = InspectorToggle(
        id: "blocks.tilt", title: "Tilt",
        read: hasTilt,
        write: { scope, on in
            guard let m = scope.motion else { return }
            if on {
                if m.zoomRegion.wrappedValue != nil { m.onAddTiltToBlock() } else { m.onAddTiltBlockAtPlayhead() }
            } else if m.tiltRegion.wrappedValue != nil {
                m.onDeleteTilt()
            }
        })
    static let tiltMaxAngle: Double = 60
    static func tilt(_ scope: Scope, pitch: Double, yaw: Double) {
        scope.motion?.tiltRegion.wrappedValue?.pitch = pitch
        scope.motion?.tiltRegion.wrappedValue?.yaw = yaw
    }
    static func tiltAngles(_ scope: Scope) -> (pitch: Double, yaw: Double, roll: Double) {
        guard let t = tiltRegion(scope) else { return (0, 0, 0) }
        return (t.pitch, t.yaw, t.roll)
    }
    /// One-click skews (pitch, yaw, roll) — depth from PITCH, drama from yaw,
    /// life from a whisper of roll. Values chosen against the reference.
    static let tiltPresets: [(Double, Double, Double)] = [
        (0, 0, 0), (12, 0, -3), (8, -25, -2), (8, 25, 2), (28, 0, 0),
    ]
    static let tiltPreset = InspectorChoice(
        id: "blocks.tiltPreset", title: "Tilt", style: .chips,
        items: ["Flat", "Showcase", "Lean L", "Lean R", "Top Down"],
        read: { scope in
            guard let t = tiltRegion(scope) else { return nil }
            return tiltPresets.firstIndex { $0 == (t.pitch, t.yaw, t.roll) }
        },
        write: { scope, index in
            guard tiltPresets.indices.contains(index) else { return }
            let (pitch, yaw, roll) = tiltPresets[index]
            scope.motion?.tiltRegion.wrappedValue?.pitch = pitch
            scope.motion?.tiltRegion.wrappedValue?.yaw = yaw
            scope.motion?.tiltRegion.wrappedValue?.roll = roll
        },
        visible: hasTilt)
    static let rotation = InspectorSlider(
        id: "blocks.rotation", title: "Rotation", range: -30...30, step: 1,
        format: { String(format: "%.0f°", $0) },
        read: { tiltRegion($0)?.roll ?? 0 }, write: { $0.motion?.tiltRegion.wrappedValue?.roll = $1 },
        visible: hasTilt)
    static let tiltSpeed = InspectorChoice(
        id: "blocks.tiltSpeed", title: "Speed", style: .menu, items: styleItems(),
        read: { styleIndex(tiltRegion($0)?.animationStyle) },
        write: { $0.motion?.tiltRegion.wrappedValue?.animationStyle = style(at: $1) },
        visible: hasTilt)
    /// The "reference look": deep push-in with a gentle pitch-back and a
    /// whisper of rotation. Depth comes from PITCH — big roll values are what
    /// make zoom+tilt look broken.
    static let cinematic = InspectorAction(
        id: "blocks.cinematic", title: "Cinematic",
        run: { scope in
            guard let m = scope.motion else { return }
            if m.zoomRegion.wrappedValue == nil { m.onAddZoomToBlock() }
            if m.tiltRegion.wrappedValue == nil { m.onAddTiltToBlock() }
            m.zoomRegion.wrappedValue?.zoomLevel = 2.4
            m.tiltRegion.wrappedValue?.pitch = 12
            m.tiltRegion.wrappedValue?.yaw = 0
            m.tiltRegion.wrappedValue?.roll = -3
        },
        visible: hasTilt)
    static let tiltCaption = InspectorCaption(
        id: "blocks.tiltCaption", "Drag the pad to skew the screen — the preview updates live.",
        full: "Drag the pad to skew the screen — left/right tips a side back, up/down tips the top or bottom back. The preview updates live.",
        visible: hasTilt)

    // MARK: Highlight mask

    static let highlightOpacity = InspectorSlider(
        id: "blocks.highlightOpacity", title: "Opacity", range: 0.1...0.9, step: nil,
        format: InspectorFormat.percentTruncating,
        read: { highlight($0)?.opacity ?? 0.5 }, write: { $0.motion?.highlightRegion.wrappedValue?.opacity = $1 },
        visible: hasHighlight)
    static let highlightCaption = InspectorCaption(
        id: "blocks.highlightCaption", "Softly dims everything outside the selected region.",
        full: "Highlights softly dim everything outside the selected region so attention stays on the important area.",
        visible: hasHighlight)
    static let removeHighlight = InspectorAction(
        id: "blocks.removeHighlight", title: "Remove Highlight", destructive: true,
        run: { $0.motion?.onDeleteHighlight() }, visible: hasHighlight)

    // MARK: Depth focus

    private static func depthStyle(_ s: Scope) -> FocusRegionStyle? { depth(s)?.style }
    static let depthStyleChoice = InspectorChoice(
        id: "blocks.depthStyle", title: "Depth Focus", style: .chips,
        items: FocusRegionStyle.allCases.map(\.rawValue),
        read: { scope in depth(scope).map { FocusRegionStyle.allCases.firstIndex(of: $0.style) ?? 0 } },
        write: { scope, i in
            let styles = FocusRegionStyle.allCases
            scope.motion?.focusRegion.wrappedValue?.style = styles[max(0, min(styles.count - 1, i))]
        },
        visible: hasDepth)
    static let depthStrength = InspectorSlider(
        id: "blocks.depthStrength", title: "Blur Strength", range: 0.1...1, step: 0.05,
        format: InspectorFormat.percent,
        read: { depth($0)?.intensity ?? 0.5 }, write: { $0.motion?.focusRegion.wrappedValue?.intensity = $1 },
        visible: hasDepth)
    static let depthFalloff = InspectorSlider(
        id: "blocks.depthFalloff", title: "Focus Falloff", range: 0...1, step: 0.05,
        format: InspectorFormat.percent,
        read: { depth($0)?.falloff ?? 0.5 }, write: { $0.motion?.focusRegion.wrappedValue?.falloff = $1 },
        visible: hasDepth)
    /// Corner radius is Area-only; angle is tilt-shift-only.
    static let depthCorner = InspectorSlider(
        id: "blocks.depthCorner", title: "Corner Radius", range: 0...1, step: 0.05,
        format: InspectorFormat.percent,
        read: { depth($0)?.cornerRadius ?? 0 }, write: { $0.motion?.focusRegion.wrappedValue?.cornerRadius = $1 },
        visible: { depthStyle($0) == .area })
    static let depthAngle = InspectorSlider(
        id: "blocks.depthAngle", title: "Angle", range: -90...90, step: 1,
        format: InspectorFormat.degreesRounded,
        read: { depth($0)?.angle ?? 0 }, write: { $0.motion?.focusRegion.wrappedValue?.angle = $1 },
        visible: { depthStyle($0) == .tiltShift })
    static let depthCaption = InspectorCaption(
        id: "blocks.depthCaption", "Sharp inside the region, graduated blur outside — drag it on the preview.",
        full: "The focused area stays sharp while everything outside melts into a graduated blur. Area follows the rect; Tilt Shift blurs with distance from an angled band through its centre. Drag and resize the region on the preview.",
        visible: hasDepth)
    static let removeDepth = InspectorAction(
        id: "blocks.removeDepth", title: "Remove Depth Focus", destructive: true,
        run: { $0.motion?.onDeleteFocusRegion() }, visible: hasDepth)

    // MARK: Blur

    static let blurStyleChoice = InspectorChoice(
        id: "blocks.blurStyle", title: "Blur", style: .chips,
        items: BlurStyle.allCases.map(\.rawValue),
        read: { scope in blur(scope).map { BlurStyle.allCases.firstIndex(of: $0.style) ?? 0 } },
        write: { scope, i in
            let styles = BlurStyle.allCases
            scope.motion?.blurRegion.wrappedValue?.style = styles[max(0, min(styles.count - 1, i))]
        },
        visible: hasBlur)
    static let blurStrength = InspectorSlider(
        id: "blocks.blurStrength", title: "Strength", range: 0.1...1, step: 0.05,
        format: InspectorFormat.percent,
        read: { blur($0)?.intensity ?? 0.5 }, write: { $0.motion?.blurRegion.wrappedValue?.intensity = $1 },
        visible: hasBlur)
    /// Animation only means something for the mosaic.
    static let blurAnimated = InspectorToggle(
        id: "blocks.blurAnimated", title: "Animated",
        read: { blur($0)?.animated ?? false }, write: { $0.motion?.blurRegion.wrappedValue?.animated = $1 },
        visible: { blur($0)?.style == .pixelate })
    static let blurCaption = InspectorCaption(
        id: "blocks.blurCaption", "Blur softens the region; Pixelate covers it with a mosaic.",
        full: "Blur softens the region; Pixelate covers it with a mosaic. Animated jitters the mosaic grid over time — the classic censor look.",
        visible: hasBlur)
    static let removeBlur = InspectorAction(
        id: "blocks.removeBlur", title: "Remove Blur", destructive: true,
        run: { $0.motion?.onDeleteBlurRegion() }, visible: hasBlur)

    static var sections: [InspectorSection] {
        [
            InspectorSection(id: "blocks.section.zoom", title: "Zoom", rows: [
                .feature(.autoZoom, visible: { _ in true }),
                .toggle(zoomToggle), .slider(zoomLevel), .choice(zoomSpeed),
                .custom(id: "blocks.zoomPreviewPad", visible: hasZoom),
                .toggle(followCursor), .custom(id: "blocks.focusPad", visible: hasZoom),
                .custom(id: "blocks.offsetPad", visible: hasZoom), .caption(zoomCaption),
            ]),
            InspectorSection(id: "blocks.section.tilt", title: "Tilt", rows: [
                .toggle(tiltToggle), .custom(id: "blocks.tiltPad", visible: hasTilt), .choice(tiltPreset),
                .slider(rotation), .choice(tiltSpeed), .action(cinematic), .caption(tiltCaption),
            ]),
            InspectorSection(id: "blocks.section.highlight", title: "Highlight Mask", rows: [
                .slider(highlightOpacity), .custom(id: "blocks.highlightPad", visible: hasHighlight),
                .caption(highlightCaption), .action(removeHighlight),
            ], visible: hasHighlight),
            InspectorSection(id: "blocks.section.depth", title: "Depth Focus", rows: [
                .choice(depthStyleChoice), .slider(depthStrength), .slider(depthFalloff), .slider(depthCorner),
                .slider(depthAngle), .caption(depthCaption), .action(removeDepth),
            ], visible: hasDepth),
            InspectorSection(id: "blocks.section.blur", title: "Blur", rows: [
                .choice(blurStyleChoice), .slider(blurStrength), .toggle(blurAnimated), .caption(blurCaption),
                .action(removeBlur),
            ], visible: hasBlur),
        ]
    }
}
