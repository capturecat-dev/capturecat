import AppKit

// CCKit — the house design kit.
//
// A shadcn-style token system for AppKit: every control in the app reads its
// colors, radii, spacing and fonts from `CCTheme.current`, so restyling the
// whole app (or any other Swift package that adopts the kit) is a matter of
// swapping one `CCThemeSpec`. Nothing in this folder may depend on app code —
// the kit must lift cleanly into a standalone package.

// MARK: - Scales

/// Radius scale, addressed by name exactly like shadcn's `rounded-sm/md/lg`.
enum CCRadius {
    case none
    case sm
    case md
    case lg
    case xl
    /// Fully round — resolves to half the control's height at layout time;
    /// `resolved(for:)` needs the height for this case.
    case full

    @MainActor
    func resolved(for height: CGFloat = 0) -> CGFloat {
        let r = CCTheme.current.radii
        switch self {
        case .none: return 0
        case .sm: return r.sm
        case .md: return r.md
        case .lg: return r.lg
        case .xl: return r.xl
        case .full: return height / 2
        }
    }
}

/// Spacing scale (`p-1 … p-6` energy). Use these instead of magic paddings.
@MainActor
enum CCSpace {
    static var xxs: CGFloat { CCTheme.current.spacing.xxs }
    static var xs: CGFloat { CCTheme.current.spacing.xs }
    static var sm: CGFloat { CCTheme.current.spacing.sm }
    static var md: CGFloat { CCTheme.current.spacing.md }
    static var lg: CGFloat { CCTheme.current.spacing.lg }
    static var xl: CGFloat { CCTheme.current.spacing.xl }
}

// MARK: - Spec

/// One theme = one value of this struct. Every field is semantic (shadcn
/// naming) rather than component-specific, so components stay theme-agnostic.
struct CCThemeSpec {
    struct Colors {
        // Surfaces
        var background: NSColor
        var card: NSColor
        var popover: NSColor
        var elevated: NSColor
        // Content
        var foreground: NSColor
        var mutedForeground: NSColor
        var faintForeground: NSColor
        // Interactive
        var primary: NSColor
        var primaryForeground: NSColor
        var destructive: NSColor
        // Lines & states
        var border: NSColor
        var ring: NSColor
        var hover: NSColor
        var active: NSColor
        /// Scrim behind dialogs.
        var overlay: NSColor
    }

    struct Radii {
        var sm: CGFloat
        var md: CGFloat
        var lg: CGFloat
        var xl: CGFloat
    }

    struct Spacing {
        var xxs: CGFloat
        var xs: CGFloat
        var sm: CGFloat
        var md: CGFloat
        var lg: CGFloat
        var xl: CGFloat
    }

    struct Fonts {
        var label: NSFont
        var header: NSFont
        var title: NSFont
        var caption: NSFont
        var mono: NSFont
        var button: NSFont
        var chip: NSFont
    }

    /// The shadcn `--ring`: an outline drawn on interactive controls. Width 0
    /// disables that state's ring. Color comes from `colors.ring` unless
    /// overridden here.
    struct Ring {
        var hoverWidth: CGFloat
        var pressWidth: CGFloat
        var focusWidth: CGFloat
        var color: NSColor?
    }

    var colors: Colors
    var radii: Radii
    var spacing: Spacing
    var fonts: Fonts
    var ring: Ring
    /// Disabled controls dim to this alpha.
    var disabledAlpha: CGFloat

    @MainActor var ringColor: NSColor { ring.color ?? colors.ring }
}

// MARK: - Theme access

/// How the kit picks between the dark and light specs.
enum CCThemeMode: String, Codable, Sendable {
    case dark
    case light
    /// Follows the system appearance live (AppleInterfaceThemeChanged).
    case system
}

enum CCTheme {
    /// Swap this to restyle every CCKit control app-wide.
    @MainActor static var current: CCThemeSpec = .capDark

    /// Posted after `apply` mutates the theme.
    static let didChangeNotification = Notification.Name("CCThemeDidChange")

    /// The shadcn "CSS variables" affordance: override any token in place —
    ///
    ///     CCTheme.apply {
    ///         $0.radii.md = 8                    // like --radius: 0.5rem
    ///         $0.colors.primary = .systemPink    // like --primary: …
    ///     }
    ///
    /// Controls resolve radius/spacing tokens at layout time and colors at
    /// their next state refresh, so overrides propagate live to everything on
    /// screen that re-lays-out; chrome that painted its colors at init picks
    /// the change up when it is next created. Set brand-wide overrides at
    /// launch (the `:root` pattern) for guaranteed full coverage.
    @MainActor static func apply(_ mutate: (inout CCThemeSpec) -> Void) {
        mutate(&current)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
        for window in NSApp.windows {
            window.contentView?.needsLayout = true
            window.contentView?.needsDisplay = true
        }
    }

    // Sugar so call sites read like utility classes:
    // `CCTheme.color.primary`, `CCTheme.radius(.lg)`, `CCTheme.font.label`.
    @MainActor static var color: CCThemeSpec.Colors { current.colors }
    @MainActor static var font: CCThemeSpec.Fonts { current.fonts }
    @MainActor static func radius(_ r: CCRadius, height: CGFloat = 0) -> CGFloat {
        r.resolved(for: height)
    }

    // MARK: - Mode (dark / light / system)

    @MainActor private(set) static var mode: CCThemeMode = .dark
    @MainActor private static var systemObserver: NSObjectProtocol?

    /// True when the resolved spec is the dark one — components that need a
    /// literal (e.g. a white thumb) branch on this rather than re-deriving it.
    @MainActor static var isDark: Bool {
        switch mode {
        case .dark: return true
        case .light: return false
        case .system: return systemPrefersDark
        }
    }

    @MainActor private static var systemPrefersDark: Bool {
        // NSApplication.shared, never bare NSApp: setMode can run before the
        // app object exists (harness entry points), where NSApp is still nil.
        NSApplication.shared.effectiveAppearance
            .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// UserDefaults key for the persisted mode (see `bootFromDefaults`).
    static let modeDefaultsKey = "capThemeMode"

    /// Call once at launch: restores the persisted mode (default `.system`).
    @MainActor static func bootFromDefaults() {
        let stored = UserDefaults.standard.string(forKey: modeDefaultsKey)
        setMode(stored.flatMap(CCThemeMode.init(rawValue:)) ?? .system)
    }

    /// A harness seed (persist: false) PINS the mode: launch-time restores
    /// (bootFromDefaults and friends, persist: true) can no longer override
    /// it. Without the pin, probe output silently depended on launch ordering
    /// and the machine's system appearance — shots came out light on a
    /// light-mode Mac regardless of what the harness seeded.
    @MainActor private static var pinnedByHarness = false

    /// Set the kit-wide appearance and persist it. `.system` re-resolves live
    /// when macOS switches appearance. Harnesses pass `persist: false` so a
    /// probe run never rewrites the user's stored choice (and see the pin
    /// above).
    @MainActor static func setMode(_ newMode: CCThemeMode, persist: Bool = true) {
        if persist {
            guard !pinnedByHarness else { return }
        } else {
            pinnedByHarness = true
        }
        mode = newMode
        if persist {
            UserDefaults.standard.set(newMode.rawValue, forKey: modeDefaultsKey)
        }
        if newMode == .system, systemObserver == nil {
            systemObserver = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
                object: nil, queue: .main
            ) { _ in
                // The distributed note can beat NSApp.effectiveAppearance's
                // update; hop the run loop so bestMatch sees the new value.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { resolveMode() }
                }
            }
        }
        resolveMode()
    }

    @MainActor private static func resolveMode() {
        // Keep AppKit's own chrome (labels, fields, menus, scrollers) on the
        // same side as the kit: explicit modes pin NSApp.appearance, .system
        // clears the override so macOS drives it.
        switch mode {
        case .dark: NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        case .light: NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case .system: NSApplication.shared.appearance = nil
        }
        let target: CCThemeSpec = isDark ? .capDark : .capLight
        apply { $0 = target }
    }
}

// MARK: - Change observation

/// Token that keeps a theme-change subscription alive; components store one
/// and get their `applyTheme()` re-run on every `CCTheme.apply`. Fires once
/// immediately so init and restyle share a single code path.
@MainActor
final class CCThemeObservation {
    private var token: NSObjectProtocol?

    init(_ apply: @escaping @MainActor () -> Void) {
        apply()
        token = NotificationCenter.default.addObserver(
            forName: CCTheme.didChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { apply() }
        }
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }
}

extension CCThemeSpec {
    /// The CaptureCat flat dark palette — byte-identical to the shipped
    /// EditorTheme values so adopting the kit changed nothing visually.
    static let capDark = CCThemeSpec(
        colors: .init(
            background: NSColor(srgbRed: 0x13 / 255, green: 0x13 / 255, blue: 0x15 / 255, alpha: 1),
            card: NSColor(srgbRed: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255, alpha: 1),
            popover: NSColor(srgbRed: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255, alpha: 1),
            elevated: NSColor(srgbRed: 0x23 / 255, green: 0x23 / 255, blue: 0x27 / 255, alpha: 1),
            foreground: NSColor.white.withAlphaComponent(0.92),
            mutedForeground: NSColor.white.withAlphaComponent(0.55),
            faintForeground: NSColor.white.withAlphaComponent(0.35),
            primary: .controlAccentColor,
            primaryForeground: .white,
            destructive: .systemRed,
            border: NSColor.white.withAlphaComponent(0.07),
            // Ink ring, not accent-blue — Mike's call 2026-09-01: selection/
            // focus rings are WHITE on dark (blueish rings vetoed).
            ring: NSColor.white.withAlphaComponent(0.85),
            hover: NSColor.white.withAlphaComponent(0.06),
            active: NSColor.white.withAlphaComponent(0.10),
            overlay: NSColor.black.withAlphaComponent(0.42)
        ),
        radii: .init(sm: 4, md: 6, lg: 10, xl: 16),
        spacing: .init(xxs: 2, xs: 4, sm: 8, md: 12, lg: 16, xl: 24),
        fonts: .init(
            label: .systemFont(ofSize: 12),
            header: .systemFont(ofSize: 14, weight: .semibold),
            title: .systemFont(ofSize: 15, weight: .semibold),
            caption: .systemFont(ofSize: 10.5),
            mono: .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium),
            button: .systemFont(ofSize: 12, weight: .medium),
            chip: .systemFont(ofSize: 13)
        ),
        // No hover or PRESS rings — washes + key travel carry those states
        // (Mike removed highlight rings 2026-09-01). The ring survives only
        // as the keyboard-focus indicator on text inputs.
        ring: .init(hoverWidth: 0, pressWidth: 0, focusWidth: 1, color: nil),
        disabledAlpha: 0.38
    )

    /// Light counterpart — same geometry/typography, inverted surfaces. Every
    /// token is the shadcn "zinc light" energy tuned to sit beside the dark
    /// palette without changing contrast relationships.
    static let capLight = CCThemeSpec(
        colors: .init(
            background: NSColor(srgbRed: 0xF7 / 255, green: 0xF7 / 255, blue: 0xF8 / 255, alpha: 1),
            card: NSColor.white,
            popover: NSColor.white,
            elevated: NSColor(srgbRed: 0xEF / 255, green: 0xEF / 255, blue: 0xF1 / 255, alpha: 1),
            foreground: NSColor.black.withAlphaComponent(0.88),
            mutedForeground: NSColor.black.withAlphaComponent(0.55),
            faintForeground: NSColor.black.withAlphaComponent(0.34),
            primary: .controlAccentColor,
            primaryForeground: .white,
            destructive: .systemRed,
            border: NSColor.black.withAlphaComponent(0.09),
            // The light theme's "white" ring is ink-black — a literal white
            // ring vanishes on light surfaces; the intent is a neutral
            // hard-contrast ring, never accent-blue.
            ring: NSColor.black.withAlphaComponent(0.55),
            hover: NSColor.black.withAlphaComponent(0.05),
            active: NSColor.black.withAlphaComponent(0.09),
            overlay: NSColor.black.withAlphaComponent(0.28)
        ),
        radii: capDark.radii,
        spacing: capDark.spacing,
        fonts: capDark.fonts,
        ring: capDark.ring,
        disabledAlpha: 0.38
    )
}
