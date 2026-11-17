import UIKit

/// CCKit accessibility — the ONE place the kit reads the user's assistive
/// settings, posts VoiceOver announcements, and lets a harness pin a setting
/// (StudioLab `--a11y`, the app's `-uiA11yAudit`), so every component, gate
/// and screen agree on what "Reduce Motion is on" means.
///
/// Settings → what the kit does:
///  • Reduce Motion — `CCMotion` replaces travel (slides, bounces, glides,
///    scale pops, growth) with short CROSS-FADES: still animated (house rule:
///    never snap), no movement.
///  • Reduce Transparency — scrims and translucent fills go (nearly) opaque.
///  • Increase Contrast — hairlines, borders and secondary ink get stronger
///    (`CCTheme` colours resolve on `accessibilityContrast`).
///  • Differentiate Without Color — selected / on / status states also carry
///    a SHAPE (check glyphs on chips and segments, I/O on switches, a glyph in
///    the sync dot), never colour alone.
///  • Bold Text — the type ramp steps one weight up (`CCFont`).
///
/// Every component re-themes on `ccOnThemeChange`, which also fires when any
/// of these change: hosts call `CCAccessibility.install(on:)` for each window,
/// and the settings travel to every view as the `CCAccessibilityTrait`.
enum CCAccessibility {
    // MARK: - Settings (system, or pinned by a harness)

    /// Harness pins (nil = follow the system). Setting one re-themes every
    /// installed window.
    static var forcedReduceMotion: Bool? { didSet { settingsChanged() } }
    static var forcedReduceTransparency: Bool? { didSet { settingsChanged() } }
    static var forcedIncreaseContrast: Bool? { didSet { settingsChanged() } }
    static var forcedDifferentiateWithoutColor: Bool? { didSet { settingsChanged() } }
    static var forcedBoldText: Bool? { didSet { settingsChanged() } }

    static var reduceMotion: Bool { forcedReduceMotion ?? UIAccessibility.isReduceMotionEnabled }
    static var reduceTransparency: Bool { forcedReduceTransparency ?? UIAccessibility.isReduceTransparencyEnabled }
    static var increaseContrast: Bool { forcedIncreaseContrast ?? UIAccessibility.isDarkerSystemColorsEnabled }
    static var differentiateWithoutColor: Bool {
        forcedDifferentiateWithoutColor ?? UIAccessibility.shouldDifferentiateWithoutColor
    }
    static var boldText: Bool { forcedBoldText ?? UIAccessibility.isBoldTextEnabled }

    /// True when a resolved trait collection asks for more contrast (the
    /// system trait, or the pinned setting).
    static func highContrast(_ traits: UITraitCollection) -> Bool {
        forcedIncreaseContrast ?? (traits.accessibilityContrast == .high)
    }

    static let didChange = Notification.Name("CCAccessibility.didChange")

    /// Bumped on every change; carried to views as `CCAccessibilityTrait`.
    private(set) static var generation = 0
    private static var windows = NSHashTable<UIWindow>.weakObjects()
    private static var observing = false

    /// Re-theme `window`'s views whenever an assistive setting changes
    /// (call once per window; extension-safe).
    static func install(on window: UIWindow) {
        windows.add(window)
        window.traitOverrides[CCAccessibilityTrait.self] = generation
        guard !observing else { return }
        observing = true
        let names: [Notification.Name] = [
            UIAccessibility.reduceMotionStatusDidChangeNotification,
            UIAccessibility.reduceTransparencyStatusDidChangeNotification,
            UIAccessibility.darkerSystemColorsStatusDidChangeNotification,
            UIAccessibility.differentiateWithoutColorDidChangeNotification,
            UIAccessibility.boldTextStatusDidChangeNotification,
            UIAccessibility.voiceOverStatusDidChangeNotification,
        ]
        for name in names {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { settingsChanged() }
            }
        }
    }

    private static func settingsChanged() {
        generation += 1
        for window in windows.allObjects {
            window.traitOverrides[CCAccessibilityTrait.self] = generation
        }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    // MARK: - VoiceOver

    /// VoiceOver is reading the screen (or a harness says it is).
    static var forcedVoiceOver: Bool? { didSet { settingsChanged() } }
    static var isVoiceOverRunning: Bool { forcedVoiceOver ?? UIAccessibility.isVoiceOverRunning }

    /// Speak the result of an asynchronous job (export finished, merge
    /// landed, transcription done…). Every announcement in the app goes
    /// through here so the a11y gate can hear it.
    static func announce(_ text: String) {
        guard !text.isEmpty else { return }
        #if DEBUG
        probeAnnouncements.append(text)
        #endif
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    #if DEBUG
    /// Harness log of every `announce` (newest last).
    static var probeAnnouncements: [String] = []
    #endif

    // MARK: - Element helpers

    /// Identifier prefix for elements whose size IS their data (timeline
    /// blocks, stage objects): they cannot all be 44 pt, so they must offer
    /// custom actions that do the same edits instead (the a11y gate's rule).
    static let dataGeometryPrefix = "a11y.data."

    /// A spoken duration / time — "1 minute 4.5 seconds", never "1:04.5".
    static func spokenTime(_ seconds: TimeInterval, fraction: Bool = true) -> String {
        let s = max(0, seconds)
        let minutes = Int(s / 60)
        let rest = s - Double(minutes * 60)
        let secText: String
        if fraction {
            let tenths = (rest * 10).rounded() / 10
            secText = tenths == tenths.rounded() ? "\(Int(tenths))" : String(format: "%.1f", tenths)
        } else {
            secText = "\(Int(rest.rounded(.down)))"
        }
        let secWord = secText == "1" ? "second" : "seconds"
        guard minutes > 0 else { return "\(secText) \(secWord)" }
        let minWord = minutes == 1 ? "minute" : "minutes"
        return secText == "0" ? "\(minutes) \(minWord)" : "\(minutes) \(minWord) \(secText) \(secWord)"
    }
}

/// The assistive settings' generation, as a trait every view inherits — so
/// `ccOnThemeChange` (and dynamic colours) re-resolve when one changes.
nonisolated struct CCAccessibilityTrait: UITraitDefinition {
    static let defaultValue = 0
    static let identifier = "so.capturecat.kit.accessibility"
    static let name = "CCAccessibility"
    static let affectsColorAppearance = true
}

// MARK: - Keyboard (iPad hardware keyboard, Full Keyboard Access)

extension UIResponder {
    /// Space, Return or a focus-engine select: "activate the focused control".
    func ccIsActivation(_ presses: Set<UIPress>) -> Bool {
        presses.contains { press in
            if press.type == .select { return true }
            guard let key = press.key, key.modifierFlags.isDisjoint(with: [.command, .control, .alternate]) else { return false }
            return key.keyCode == .keyboardSpacebar || key.keyCode == .keyboardReturnOrEnter
        }
    }

    /// An arrow on a focused adjustable control: +1 (→ ↑) or −1 (← ↓).
    func ccArrowStep(_ presses: Set<UIPress>) -> Int? {
        for press in presses {
            switch press.key?.keyCode {
            case .keyboardRightArrow?, .keyboardUpArrow?: return 1
            case .keyboardLeftArrow?, .keyboardDownArrow?: return -1
            default: continue
            }
        }
        return nil
    }
}

// MARK: - Dynamic Type

extension UIView {
    /// Re-measures and re-lays-out this view when the text size (or an
    /// assistive setting) changes — for kit controls that place their
    /// labels by hand: the label's font follows Dynamic Type by itself, its
    /// FRAME only on the next layout pass.
    func ccRelayoutOnTextSizeChange() {
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self, CCAccessibilityTrait.self]) { (view: UIView, _: UITraitCollection) in
            view.invalidateIntrinsicContentSize()
            view.setNeedsLayout()
            view.superview?.setNeedsLayout()
        }
    }
}

// MARK: - Pointer (iPad trackpad / mouse)

extension UIView {
    /// The kit's pointer effect: a hover highlight shaped like the control
    /// (iPad trackpad / mouse). Idempotent.
    func ccInstallPointerHover(radius: @escaping () -> CGFloat) {
        guard !interactions.contains(where: { $0 is UIPointerInteraction }) else { return }
        let delegate = CCPointerHoverDelegate(radius: radius)
        objc_setAssociatedObject(self, &CCPointerHoverDelegate.key, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        addInteraction(UIPointerInteraction(delegate: delegate))
    }

    /// The kit's keyboard focus (Tab / arrow navigation on iPad, Full
    /// Keyboard Access): a halo that follows the control's corners.
    func ccInstallFocusHalo(radius: CGFloat) {
        focusEffect = UIFocusHaloEffect(roundedRect: bounds, cornerRadius: radius, curve: .continuous)
    }
}

final class CCPointerHoverDelegate: NSObject, UIPointerInteractionDelegate {
    nonisolated(unsafe) static var key: UInt8 = 0
    private let radius: () -> CGFloat
    init(radius: @escaping () -> CGFloat) { self.radius = radius }

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        guard let view = interaction.view, view.window != nil else { return nil }
        let target = UITargetedPreview(view: view)
        let shape = UIPointerShape.roundedRect(view.bounds, radius: radius())
        return UIPointerStyle(effect: .highlight(target), shape: shape)
    }
}
