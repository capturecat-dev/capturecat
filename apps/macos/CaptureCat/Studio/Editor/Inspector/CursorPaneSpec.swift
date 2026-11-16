import Foundation

/// Cursor tab — cursor, fluid motion, behaviour, click effect, keyboard
/// sounds, shortcut overlay. Moved verbatim from CursorSettingsPaneAppKit.
@MainActor
enum CursorPane {
    typealias Scope = InspectorScope

    // MARK: Cursor

    static let show = InspectorToggle(
        id: "cursor.show", title: "Show Cursor",
        read: { $0.settings.showCursor }, write: { $0.settings.showCursor = $1 })
    static let style = InspectorChoice(
        id: "cursor.style", title: "Style", style: .menu,
        items: ProjectSettings.CursorStyle.allCases.map(\.rawValue),
        read: { ProjectSettings.CursorStyle.allCases.firstIndex(of: $0.settings.cursorStyle) ?? 0 },
        write: { $0.settings.cursorStyle = ProjectSettings.CursorStyle.allCases[$1] })
    static let size = InspectorSlider(
        id: "cursor.size", title: "Size", range: 0.5...3.0, step: 0.25,
        format: InspectorFormat.multiplier2,
        read: { $0.settings.cursorScale }, write: { $0.settings.cursorScale = $1 })

    // MARK: Motion (fluid movement — CursorSpringMath)

    private static func fluid(_ s: Scope) -> Bool { s.settings.cursorFluidEnabled }
    static let fluidToggle = InspectorToggle(
        id: "cursor.fluid", title: "Fluid Movement",
        read: { $0.settings.cursorFluidEnabled }, write: { $0.settings.cursorFluidEnabled = $1 })
    static let tension = InspectorSlider(
        id: "cursor.tension", title: "Tension", range: 20...600, step: 10,
        read: { $0.settings.cursorTension }, write: { $0.settings.cursorTension = $1 }, visible: fluid)
    static let tensionCaption = InspectorCaption(
        id: "cursor.tensionCaption", "How quickly the cursor accelerates toward where you moved.", visible: fluid)
    static let friction = InspectorSlider(
        id: "cursor.friction", title: "Friction", range: 2...80, step: 1,
        read: { $0.settings.cursorFriction }, write: { $0.settings.cursorFriction = $1 }, visible: fluid)
    static let frictionCaption = InspectorCaption(
        id: "cursor.frictionCaption", "Resistance while moving fast — higher settles sooner.", visible: fluid)
    static let mass = InspectorSlider(
        id: "cursor.mass", title: "Mass", range: 0.2...6, step: 0.1,
        format: InspectorFormat.multiplier1,
        read: { $0.settings.cursorMass }, write: { $0.settings.cursorMass = $1 }, visible: fluid)
    static let massCaption = InspectorCaption(
        id: "cursor.massCaption",
        "Heavier keeps momentum — more overshoot and wiggle. Clicks always stay exactly where you clicked.",
        visible: fluid)
    static let smooth = InspectorToggle(
        id: "cursor.smooth", title: "Smooth Cursor Motion",
        read: { $0.settings.smoothCursor }, write: { $0.settings.smoothCursor = $1 })
    static let smoothing = InspectorSlider(
        id: "cursor.smoothing", title: "Smoothing", range: 0.05...0.5, step: 0.05,
        read: { $0.settings.smoothingFactor }, write: { $0.settings.smoothingFactor = $1 },
        visible: { $0.settings.smoothCursor })

    // MARK: Behavior

    static let autoHide = InspectorToggle(
        id: "cursor.autoHide", title: "Auto-Hide Cursor",
        read: { $0.settings.autoHideCursor }, write: { $0.settings.autoHideCursor = $1 })
    static let hideAfter = InspectorSlider(
        id: "cursor.hideAfter", title: "Hide After", range: 1...10, step: 0.5,
        format: InspectorFormat.seconds1,
        read: { $0.settings.autoHideDelay }, write: { $0.settings.autoHideDelay = $1 },
        visible: { $0.settings.autoHideCursor })
    /// Loop and Stop at End are exclusive.
    static let loop = InspectorToggle(
        id: "cursor.loop", title: "Loop to Start",
        read: { $0.settings.cursorLoopToStart },
        write: { scope, on in
            scope.settings.cursorLoopToStart = on
            if on { scope.settings.cursorStopAtEnd = false }
        })
    static let stopAtEnd = InspectorToggle(
        id: "cursor.stopEnd", title: "Stop at End",
        read: { $0.settings.cursorStopAtEnd },
        write: { scope, on in
            scope.settings.cursorStopAtEnd = on
            if on { scope.settings.cursorLoopToStart = false }
        })
    static let endCaption = InspectorCaption(
        id: "cursor.endCaption",
        "Loop glides the cursor back to its first position near the end — seamless for looping social clips. Stop freezes it for the final half second.")

    // MARK: Click effect

    private static func ripple(_ s: Scope) -> Bool { s.settings.showClickRipple }
    private static func clickSound(_ s: Scope) -> Bool { s.settings.clickSoundEnabled }
    static let rippleToggle = InspectorToggle(
        id: "cursor.ripple", title: "Show Click Ripple",
        read: { $0.settings.showClickRipple }, write: { $0.settings.showClickRipple = $1 })
    static let rippleSize = InspectorSlider(
        id: "cursor.rippleSize", title: "Size", range: 20...100, step: 5,
        read: { $0.settings.clickRippleSize }, write: { $0.settings.clickRippleSize = $1 }, visible: ripple)
    static let rippleColor = InspectorColor(
        id: "cursor.rippleColor", title: "Color", supportsOpacity: false,
        read: { $0.settings.clickRippleColor }, write: { $0.settings.clickRippleColor = $1 }, visible: ripple)
    static let clickSoundToggle = InspectorToggle(
        id: "cursor.clickSound", title: "Click Sound",
        read: { $0.settings.clickSoundEnabled },
        write: { scope, on in
            scope.settings.clickSoundEnabled = on
            if on {
                InspectorSounds.clickPreview(volume: scope.settings.clickSoundVolume, style: scope.settings.clickSoundStyle)
            }
        })
    static let clickStyle = InspectorChoice(
        id: "cursor.clickStyle", title: "Sound", style: .menu,
        items: ClickSoundStyle.allCases.map(\.rawValue),
        read: { ClickSoundStyle.allCases.firstIndex(of: $0.settings.clickSoundStyle) ?? 0 },
        write: { scope, index in
            let style = ClickSoundStyle.allCases[index]
            scope.settings.clickSoundStyle = style
            InspectorSounds.click(volume: scope.settings.clickSoundVolume, style: style)
        },
        visible: clickSound)
    static let clickTest = InspectorAction(
        id: "cursor.clickTest", title: "Test",
        run: { InspectorSounds.click(volume: $0.settings.clickSoundVolume, style: $0.settings.clickSoundStyle) },
        visible: clickSound)
    static let clickVolume = InspectorSlider(
        id: "cursor.clickVolume", title: "Volume", range: 0.1...1.0, step: 0.05,
        format: InspectorFormat.percent,
        read: { $0.settings.clickSoundVolume },
        write: { scope, v in
            scope.settings.clickSoundVolume = v
            InspectorSounds.clickPreview(volume: v, style: scope.settings.clickSoundStyle)
        },
        visible: clickSound)
    static let clickCaption = InspectorCaption(
        id: "cursor.clickCaption", "A synthesized tick plays at every recorded click.",
        full: "A synthesized tick plays at every recorded click — in the preview and in the exported file.",
        visible: clickSound)

    // MARK: Keyboard sounds

    private static func keySound(_ s: Scope) -> Bool { s.settings.keySoundEnabled }
    static let keySoundToggle = InspectorToggle(
        id: "cursor.keySound", title: "Keyboard Sounds",
        read: { $0.settings.keySoundEnabled },
        write: { scope, on in
            scope.settings.keySoundEnabled = on
            if on { InspectorSounds.keyBurst(volume: scope.settings.keySoundVolume, style: scope.settings.keySoundStyle) }
        })
    static let keyStyle = InspectorChoice(
        id: "cursor.keyStyle", title: "Sound", style: .menu,
        items: KeySoundStyle.allCases.map(\.rawValue),
        read: { KeySoundStyle.allCases.firstIndex(of: $0.settings.keySoundStyle) ?? 0 },
        write: { scope, index in
            let style = KeySoundStyle.allCases[index]
            scope.settings.keySoundStyle = style
            InspectorSounds.keyBurst(volume: scope.settings.keySoundVolume, style: style)
        },
        visible: keySound)
    static let keyTest = InspectorAction(
        id: "cursor.keyTest", title: "Test",
        run: { InspectorSounds.keyBurst(volume: $0.settings.keySoundVolume, style: $0.settings.keySoundStyle) },
        visible: keySound)
    static let keyVolume = InspectorSlider(
        id: "cursor.keyVolume", title: "Volume", range: 0.1...1.0, step: 0.05,
        format: InspectorFormat.percent,
        read: { $0.settings.keySoundVolume }, write: { $0.settings.keySoundVolume = $1 }, visible: keySound)
    static let keyNoDataCaption = InspectorCaption(
        id: "cursor.keyNoDataCaption",
        "This recording has no keystroke data — typing sounds apply to recordings made from now on (with Input Monitoring granted). Record a new take to hear them.",
        visible: { keySound($0) && !$0.env.hasKeystrokeData })
    static let keyCaption = InspectorCaption(
        id: "cursor.keyCaption", "Keystroke timings (never what you typed) play as typing sounds.",
        full: "Keystroke timings (never what you typed) are captured in new recordings and play as typing sounds.",
        visible: { keySound($0) && $0.env.hasKeystrokePermission && $0.env.hasKeystrokeData })
    static let keyPermissionCaption = InspectorCaption(
        id: "cursor.keyPermissionCaption",
        "Grant Input Monitoring in System Settings → Privacy & Security so future recordings can capture keystroke timing. Nothing you type is ever stored — only when keys were pressed.",
        visible: { keySound($0) && !$0.env.hasKeystrokePermission })
    /// Mac-only effect (KeystrokeTracker.requestPermission) — the host runs it.
    static let keyPermissionVisible: (Scope) -> Bool = { keySound($0) && !$0.env.hasKeystrokePermission }

    // MARK: Shortcut overlay

    private static func overlayActive(_ s: Scope) -> Bool { s.settings.showKeystrokes && s.env.hasShortcutData }
    private static func scopeShown(_ s: Scope) -> Bool { overlayActive(s) && s.env.isWindowRecording }
    static let keystrokeOverlay = InspectorToggle(
        id: "cursor.keystrokeOverlay", title: "Show Shortcut Overlay",
        read: { $0.settings.showKeystrokes }, write: { $0.settings.showKeystrokes = $1 })
    static let keystrokePosition = InspectorChoice(
        id: "cursor.keystrokePosition", title: "Position", style: .menu,
        items: KeystrokeOverlayPosition.allCases.map(\.label),
        read: { KeystrokeOverlayPosition.allCases.firstIndex(of: $0.settings.keystrokeOverlayPosition) ?? 0 },
        write: { $0.settings.keystrokeOverlayPosition = KeystrokeOverlayPosition.allCases[$1] },
        visible: overlayActive)
    static let keystrokeAnimation = InspectorChoice(
        id: "cursor.keystrokeAnimation", title: "Animation", style: .menu,
        items: KeystrokeOverlayAnimation.allCases.map(\.label),
        read: { KeystrokeOverlayAnimation.allCases.firstIndex(of: $0.settings.keystrokeOverlayAnimation) ?? 0 },
        write: { $0.settings.keystrokeOverlayAnimation = KeystrokeOverlayAnimation.allCases[$1] },
        visible: overlayActive)
    static let keystrokeSize = InspectorSlider(
        id: "cursor.keystrokeSize", title: "Size", range: 0.6...1.8, step: 0.1,
        format: InspectorFormat.percent,
        read: { $0.settings.keystrokeOverlaySize }, write: { $0.settings.keystrokeOverlaySize = $1 },
        visible: overlayActive)
    static let keystrokeScope = InspectorToggle(
        id: "cursor.keystrokeScope", title: "Only Recorded App",
        read: { $0.settings.keystrokeOverlayScopeToRecordedApp },
        write: { $0.settings.keystrokeOverlayScopeToRecordedApp = $1 },
        visible: scopeShown)
    static let keystrokeScopeCaption = InspectorCaption(
        id: "cursor.keystrokeScopeCaption", "Hide shortcuts pressed in other apps during the recording.",
        full: "Hide shortcuts pressed in other apps while this window was being recorded.",
        visible: scopeShown)
    static let keystrokeNoDataCaption = InspectorCaption(
        id: "cursor.keystrokeNoDataCaption",
        "This recording has no shortcut data. Enable \"Capture Shortcuts\" in the recording panel before recording — only combos with ⌘, ⌃ or ⌥ are stored, never plain typing.",
        visible: { $0.settings.showKeystrokes && !$0.env.hasShortcutData })
    static let keystrokeCaption = InspectorCaption(
        id: "cursor.keystrokeCaption", "Recorded shortcuts (⌘⇧S…) appear as a pill in preview and export.",
        full: "Recorded shortcuts (⌘⇧S…) appear as a pill, in the preview and in the exported file.",
        visible: overlayActive)

    // MARK: Layout

    static var sections: [InspectorSection] {
        [
            InspectorSection(id: "cursor.section.cursor", title: "Cursor", rows: [
                .custom(id: "cursor.preview", visible: { _ in true }),
                .toggle(show), .choice(style), .slider(size),
            ]),
            InspectorSection(id: "cursor.section.motion", title: "Motion", rows: [
                .toggle(fluidToggle), .slider(tension), .caption(tensionCaption), .slider(friction),
                .caption(frictionCaption), .slider(mass), .caption(massCaption), .toggle(smooth), .slider(smoothing),
            ]),
            InspectorSection(id: "cursor.section.behavior", title: "Behavior", rows: [
                .toggle(autoHide), .slider(hideAfter), .toggle(loop), .toggle(stopAtEnd), .caption(endCaption),
            ]),
            InspectorSection(id: "cursor.section.click", title: "Click Effect", rows: [
                .toggle(rippleToggle), .slider(rippleSize), .color(rippleColor), .toggle(clickSoundToggle),
                .choice(clickStyle), .action(clickTest), .slider(clickVolume), .caption(clickCaption),
            ]),
            InspectorSection(id: "cursor.section.keys", title: "Keyboard Sounds", rows: [
                .toggle(keySoundToggle), .choice(keyStyle), .action(keyTest), .slider(keyVolume),
                .caption(keyNoDataCaption), .caption(keyCaption), .caption(keyPermissionCaption),
                .custom(id: "cursor.keyPermission", visible: keyPermissionVisible),
            ]),
            InspectorSection(id: "cursor.section.overlay", title: "Shortcut Overlay", rows: [
                .toggle(keystrokeOverlay), .choice(keystrokePosition), .choice(keystrokeAnimation),
                .slider(keystrokeSize), .toggle(keystrokeScope), .caption(keystrokeScopeCaption),
                .caption(keystrokeNoDataCaption), .caption(keystrokeCaption),
            ]),
        ]
    }
}
