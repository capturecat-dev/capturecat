import AppKit
import AVFoundation
import CoreGraphics
import UserNotifications
import os

private let logger = Logger(subsystem: "so.capturecat.CaptureCat", category: "OnboardingAppKit")

/// Onboarding accent palette — the app's ACTUAL accent (the same
/// controlAccentColor the browser's selection ring and progress bars use;
/// the old bespoke periwinkle read as off-brand), plus soft wash/border
/// variants. Everything else comes straight from EditorThemeKit tokens.
private enum OnboardingPalette {
    static let accent = NSColor.controlAccentColor
    static let accentWash = NSColor.controlAccentColor.withAlphaComponent(0.14)
    static let accentBorder = NSColor.controlAccentColor.withAlphaComponent(0.30)
    static let successWash = NSColor.systemGreen.withAlphaComponent(0.14)
    static let successBorder = NSColor.systemGreen.withAlphaComponent(0.34)
}

/// One type scale for the whole wizard — display title, body, caption, and a
/// tracked overline. Everything in this file draws from here.
private enum OnboardingType {
    static let display = NSFont.systemFont(ofSize: 24, weight: .semibold)
    static let displayTracking: CGFloat = -0.4
    static let body = NSFont.systemFont(ofSize: 13, weight: .regular)
    static let rowTitle = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let caption = NSFont.systemFont(ofSize: 11, weight: .regular)
    static let overline = NSFont.systemFont(ofSize: 11, weight: .semibold)
    static let overlineKern: CGFloat = 1.8
}

/// Native onboarding wizard — four pages (welcome → permissions → sign-in →
/// finish), flat, choreographed, matching the editor's design language. Same
/// UserDefaults keys and AppState calls as the original: if Screen Recording
/// was granted on a previous install the whole wizard auto-completes, so
/// re-installs never see it.
@MainActor
final class OnboardingViewController: NSViewController {
    /// `--show-onboarding` launch argument: force the wizard open and skip the
    /// granted-permissions auto-complete, for previewing/testing.
    static var isForcedPreview: Bool {
        ProcessInfo.processInfo.arguments.contains("--show-onboarding")
    }

    private let appState: AppState

    private enum PermissionState {
        case unknown, denied, granted

        var label: String {
            switch self {
            case .unknown: return "Pending"
            case .denied: return "Blocked"
            case .granted: return "Allowed"
            }
        }

        var color: NSColor {
            switch self {
            case .unknown: return EditorThemeKit.textSecondary
            case .denied: return .systemOrange
            case .granted: return .systemGreen
            }
        }
    }

    /// The five-page flow: welcome → one combined permissions page → account →
    /// default screenshot tool → finish (which folds in the notes-intro
    /// highlights).
    private enum Step: Int, CaseIterable {
        case welcome, permissions, account, defaultTool, finish
    }

    private var step: Step = .welcome
    private var screenPermission: PermissionState = .unknown
    private var notificationPermission: PermissionState = .unknown
    private var microphonePermission: PermissionState = .unknown
    private var cameraPermission: PermissionState = .unknown
    private var isRequestingPermissions = false
    private var isSigningIn = false
    private var hasCelebratedFinish = false

    private var hasRequestedScreenRecording: Bool {
        get { UserDefaults.standard.bool(forKey: "hasRequestedScreenRecording") }
        set { UserDefaults.standard.set(newValue, forKey: "hasRequestedScreenRecording") }
    }
    private var hasVerifiedScreenRecordingAccess: Bool {
        get { UserDefaults.standard.bool(forKey: "hasVerifiedScreenRecordingAccess") }
        set { UserDefaults.standard.set(newValue, forKey: "hasVerifiedScreenRecordingAccess") }
    }

    /// Width fraction of the window the right hero panel occupies — an even
    /// 50/50 split with the content panel.
    static let heroPanelFraction: CGFloat = 0.5

    // MARK: Shared chrome

    private let ambient = AmbientGlowView()
    private let stepContainer = NSView()
    private var currentStepView: StepPageView?
    private let footerHairline = NSView()
    private let dots = PageDotsView(count: Step.allCases.count)
    private let backButton = OnboardingButton(title: "Back", symbol: "chevron.left", style: .plain)
    private let nextButton = OnboardingButton(title: "Continue", symbol: nil, style: .primary)
    private var activationObserver: NSObjectProtocol?
    private var themeObservation: CCThemeObservation?

    // MARK: Step-owned controls (kept alive across transitions)

    /// The combined permissions page: one grant-row per permission, each
    /// running the exact request path its old dedicated page ran.
    private let screenRow = GrantRowView(
        title: "Screen Recording", detail: "Required to record",
        symbol: "rectangle.inset.filled.badge.record")
    private let notifRow = GrantRowView(
        title: "Notifications", detail: "Optional — capture reminders",
        symbol: "bell.badge")
    private let micRow = GrantRowView(
        title: "Microphone", detail: "Optional — narrate your recordings",
        symbol: "mic.fill")
    private let cameraRow = GrantRowView(
        title: "Camera", detail: "Optional — add a webcam bubble",
        symbol: "camera.fill")
    private let relaunchButton = OnboardingButton(title: "Relaunch to Apply", symbol: "arrow.clockwise", style: .primary)
    private let deniedNote = NSTextField(wrappingLabelWithString: "")
    private var permissionsMascot: MarkHeroView?

    private let signInButton = OnboardingButton(title: "Sign In with Browser", symbol: "person.crop.circle", style: .primary)
    private let signInSpinner = CCSpinner()
    private let accountErrorLabel = NSTextField(wrappingLabelWithString: "")
    private let accountCard = AccountCardView()

    private let termsCheckbox = OnboardingCheckbox(title: "I agree to the Terms and Privacy Policy")
    private var finishMascot: MarkHeroView?

    /// Deep links used by the permission rows — exposed for the harness.
    nonisolated static let notificationSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
    nonisolated static let keyboardSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")

    init(appState: AppState) {
        self.appState = appState
        super.init(nibName: nil, bundle: nil)
    }

    /// Harness hook (--browser-shot): jump straight to a step by index, no
    /// animation. Not used by the app itself.
    func jumpToStep(_ index: Int) {
        guard let target = Step(rawValue: index) else { return }
        showStep(target, direction: .none)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 920, height: 560))
        root.wantsLayer = true
        view = root

        // Ambient indigo/cyan washes drifting behind every page — near
        // imperceptible; the eye should only catch deliberate moments.
        ambient.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(ambient)

        stepContainer.translatesAutoresizingMaskIntoConstraints = false
        stepContainer.wantsLayer = true
        stepContainer.layer?.masksToBounds = true
        root.addSubview(stepContainer)

        footerHairline.translatesAutoresizingMaskIntoConstraints = false
        footerHairline.wantsLayer = true
        root.addSubview(footerHairline)

        dots.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(dots)

        backButton.onClick = { [weak self] in self?.goBack() }
        nextButton.onClick = { [weak self] in self?.goForward() }
        nextButton.onDisabledClick = { [weak self] in self?.hintRequiredPermission() }
        root.addSubview(backButton)
        root.addSubview(nextButton)

        // Two-panel chrome: the hero card owns the window's full height on the
        // right (each page pins its own card there); the footer bar lives
        // inside the LEFT panel only, Shotbase-style.
        let footerHeight: CGFloat = 66
        NSLayoutConstraint.activate([
            ambient.topAnchor.constraint(equalTo: root.topAnchor),
            ambient.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            ambient.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            ambient.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            stepContainer.topAnchor.constraint(equalTo: root.topAnchor),
            stepContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stepContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stepContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            footerHairline.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footerHairline.widthAnchor.constraint(equalTo: root.widthAnchor, multiplier: 1 - Self.heroPanelFraction),
            footerHairline.heightAnchor.constraint(equalToConstant: 1),
            footerHairline.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -footerHeight),

            dots.centerXAnchor.constraint(equalTo: footerHairline.centerXAnchor),
            dots.centerYAnchor.constraint(equalTo: footerHairline.bottomAnchor, constant: footerHeight / 2),

            backButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            backButton.centerYAnchor.constraint(equalTo: dots.centerYAnchor),
            nextButton.trailingAnchor.constraint(equalTo: footerHairline.trailingAnchor, constant: -22),
            nextButton.centerYAnchor.constraint(equalTo: dots.centerYAnchor),
        ])

        // Live theming: the shared chrome re-paints in place; the visible page
        // (whose labels/tiles bake EditorThemeKit colors at build time) is
        // rebuilt. Persistent controls carry their own observations.
        themeObservation = CCThemeObservation { [weak self] in
            guard let self else { return }
            self.view.layer?.backgroundColor = EditorThemeKit.windowBackground.cgColor
            self.footerHairline.layer?.backgroundColor = EditorThemeKit.hairline.cgColor
            if self.currentStepView != nil {
                self.showStep(self.step, direction: .none)
            }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        termsCheckbox.isOn = appState.hasAcceptedTerms
        termsCheckbox.onChange = { [weak self] _ in self?.refreshControls() }

        screenRow.onGrant = { [weak self] in
            guard let self, !self.isRequestingPermissions else { return }
            if self.screenPermission == .denied {
                self.openSystemSettings(anchor: "Privacy_ScreenCapture")
            } else {
                Task { await self.requestScreenPermission() }
            }
        }
        notifRow.onGrant = { [weak self] in
            guard let self, !self.isRequestingPermissions else { return }
            if self.notificationPermission == .denied {
                if let url = Self.notificationSettingsURL { NSWorkspace.shared.open(url) }
            } else {
                self.requestNotificationPermission()
            }
        }
        micRow.onGrant = { [weak self] in
            guard let self, !self.isRequestingPermissions else { return }
            if self.microphonePermission == .denied {
                self.openSystemSettings(anchor: "Privacy_Microphone")
            } else {
                Task { await self.requestAVPermission(for: .audio) }
            }
        }
        cameraRow.onGrant = { [weak self] in
            guard let self, !self.isRequestingPermissions else { return }
            if self.cameraPermission == .denied {
                self.openSystemSettings(anchor: "Privacy_Camera")
            } else {
                Task { await self.requestAVPermission(for: .video) }
            }
        }
        relaunchButton.onClick = { [weak self] in self?.relaunchApp() }

        refreshPermissionStates()

        // Resume conservatively: mid-flow with the required permission still
        // missing → permissions page; required granted mid-flow but signed
        // out → sign-in; both done → finish. A fresh install (never requested)
        // always starts at welcome so the granted-on-previous-install
        // auto-complete below still fires.
        let resume: Step
        if hasRequestedScreenRecording {
            if screenPermission != .granted {
                resume = .permissions
            } else if !appState.isSignedIn {
                resume = .account
            } else {
                resume = .finish
            }
        } else {
            resume = .welcome
        }
        showStep(resume, direction: .none)

        // Auto-complete when Screen Recording is already granted (previous
        // install, TCC remembered) — the user never sees the wizard again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !Self.isForcedPreview else { return }
            self.refreshPermissionStates()
            if self.screenPermission == .granted, self.step == .welcome {
                self.termsCheckbox.isOn = true
                self.completeOnboardingFlow()
            }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Coming back from System Settings: re-probe everything so
                // the status pills flip (and pop) in place.
                self.refreshPermissionStates()
            }
        }
    }

    // MARK: - Navigation

    private enum Direction { case forward, backward, none }

    private func goForward() {
        switch step {
        case .welcome: showStep(.permissions, direction: .forward)
        case .permissions:
            guard screenPermission == .granted else {
                hintRequiredPermission()
                return
            }
            showStep(.account, direction: .forward)
        case .account: showStep(.defaultTool, direction: .forward)
        case .defaultTool: showStep(.finish, direction: .forward)
        case .finish: completeOnboardingFlow()
        }
    }

    private func goBack() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        showStep(previous, direction: .backward)
    }

    /// Continue clicked while Screen Recording is still missing: a gentle
    /// horizontal hint shake on the button, and a nudge glow on the row.
    private func hintRequiredPermission() {
        guard step == .permissions else { return }
        if !RecordingMotion.reduceMotion {
            let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
            shake.values = [0, -6, 5, -3, 2, 0]
            shake.duration = 0.4
            shake.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            nextButton.layer?.add(shake, forKey: "hint-shake")
        }
        screenRow.nudge()
    }

    private func showStep(_ newStep: Step, direction: Direction) {
        let outgoing = currentStepView
        step = newStep

        let incoming = buildStep(newStep)
        incoming.translatesAutoresizingMaskIntoConstraints = false
        stepContainer.addSubview(incoming)
        NSLayoutConstraint.activate([
            incoming.topAnchor.constraint(equalTo: stepContainer.topAnchor),
            incoming.leadingAnchor.constraint(equalTo: stepContainer.leadingAnchor),
            incoming.trailingAnchor.constraint(equalTo: stepContainer.trailingAnchor),
            incoming.bottomAnchor.constraint(equalTo: stepContainer.bottomAnchor),
        ])
        currentStepView = incoming
        stepContainer.layoutSubtreeIfNeeded()

        if direction == .none {
            // First appearance / direct jump: no travel — drop any previous
            // pane immediately and choreograph the content in.
            outgoing?.removeFromSuperview()
            staggerIn(incoming.staggerTargets)
        } else if RecordingMotion.reduceMotion {
            // Reduce-motion: plain crossfade, no travel.
            incoming.wantsLayer = true
            incoming.alphaValue = 0
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = RecordingMotion.reducedDuration
                context.allowsImplicitAnimation = true
                incoming.animator().alphaValue = 1
                outgoing?.animator().alphaValue = 0
            }, completionHandler: { outgoing?.removeFromSuperview() })
        } else {
            // Plain crossfade. The old slide+scale predates the two-panel
            // layout — dragging the full-height hero panel laterally read as
            // the whole window lurching. The pages share identical chrome, so
            // a fade holds the hero panel visually still while the left
            // column's stagger provides the motion.
            incoming.wantsLayer = true
            incoming.alphaValue = 0
            if let outgoing {
                outgoing.wantsLayer = true
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.3
                    context.timingFunction = RecordingMotion.settleCurve
                    context.allowsImplicitAnimation = true
                    outgoing.animator().alphaValue = 0
                }, completionHandler: { outgoing.removeFromSuperview() })
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.35
                context.timingFunction = RecordingMotion.settleCurve
                context.allowsImplicitAnimation = true
                incoming.animator().alphaValue = 1
            }
            staggerIn(incoming.staggerTargets, baseDelay: 0.08)
        }

        dots.select(index: newStep.rawValue)
        refreshAccountUI()
        refreshControls()

        if newStep == .finish, !hasCelebratedFinish {
            hasCelebratedFinish = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.finishMascot?.celebrate()
            }
        }
    }

    /// Choreographed sequential reveal — hero first, then title, body,
    /// content, each ~90ms apart, drifting UP into place from ~14pt below with
    /// a simultaneous fade on the settle curve. The hero settles on a longer
    /// clock than the text for a slight parallax feel. Layer-driven,
    /// independent of Auto Layout.
    private func staggerIn(_ views: [NSView], baseDelay: TimeInterval = 0.05) {
        if RecordingMotion.reduceMotion {
            for target in views { target.alphaValue = 1 }
            return
        }
        for (index, target) in views.enumerated() {
            target.wantsLayer = true
            target.alphaValue = 0
            target.layer?.setAffineTransform(CGAffineTransform(translationX: 0, y: -14))
            let delay = baseDelay + Double(index) * 0.09
            let duration = index == 0 ? 0.65 : 0.55
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak target] in
                guard let target else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = duration
                    context.timingFunction = RecordingMotion.settleCurve
                    context.allowsImplicitAnimation = true
                    target.animator().alphaValue = 1
                    target.layer?.setAffineTransform(.identity)
                }
            }
        }
    }

    // MARK: - Step views

    private func buildStep(_ step: Step) -> StepPageView {
        switch step {
        case .welcome: return buildWelcomeStep()
        case .permissions: return buildPermissionsStep()
        case .account: return buildAccountStep()
        case .defaultTool: return buildDefaultToolStep()
        case .finish: return buildFinishStep()
        }
    }

    /// Two-panel page, Shotbase-style: text and controls left-aligned in the
    /// left column; the hero on a full-height rounded card filling the right
    /// column. The card crossfades with the page, so each step brings its own
    /// visual.
    private func stepPage(overline: String, hero: NSView, imageName: String? = nil, title: String, subtitle: String, content: [NSView]) -> StepPageView {
        let page = StepPageView()

        // Right column: elevated rounded card. When the step has a named
        // illustration in the asset catalog it fills the card edge-to-edge;
        // otherwise the vector hero sits centred as before — so art can land
        // page by page without code changes.
        let heroPanel = NSView()
        heroPanel.translatesAutoresizingMaskIntoConstraints = false
        heroPanel.wantsLayer = true
        // Full-bleed: the card runs edge-to-edge against the window's own
        // rounded corners, so no radius or border of its own.
        heroPanel.layer?.masksToBounds = true
        heroPanel.layer?.backgroundColor = EditorThemeKit.panelElevated.cgColor
        if let imageName, let image = NSImage(named: imageName) {
            let fill = OnboardingCardImageView()
            fill.image = image
            fill.translatesAutoresizingMaskIntoConstraints = false
            heroPanel.addSubview(fill)
            NSLayoutConstraint.activate([
                fill.leadingAnchor.constraint(equalTo: heroPanel.leadingAnchor),
                fill.trailingAnchor.constraint(equalTo: heroPanel.trailingAnchor),
                fill.topAnchor.constraint(equalTo: heroPanel.topAnchor),
                fill.bottomAnchor.constraint(equalTo: heroPanel.bottomAnchor),
            ])
        } else {
            hero.translatesAutoresizingMaskIntoConstraints = false
            heroPanel.addSubview(hero)
            NSLayoutConstraint.activate([
                hero.centerXAnchor.constraint(equalTo: heroPanel.centerXAnchor),
                hero.centerYAnchor.constraint(equalTo: heroPanel.centerYAnchor),
            ])
        }
        page.addSubview(heroPanel)

        let overlineField = NSTextField(labelWithString: "")
        overlineField.attributedStringValue = NSAttributedString(
            string: overline.uppercased(),
            attributes: [
                .font: OnboardingType.overline,
                .foregroundColor: OnboardingPalette.accent,
                .kern: OnboardingType.overlineKern,
            ]
        )

        let titleField = NSTextField(wrappingLabelWithString: title)
        titleField.isSelectable = false
        titleField.attributedStringValue = NSAttributedString(
            string: title,
            attributes: [
                .font: OnboardingType.display,
                .foregroundColor: EditorThemeKit.textPrimary,
                .kern: OnboardingType.displayTracking,
            ]
        )

        let subtitleField = NSTextField(wrappingLabelWithString: subtitle)
        subtitleField.isSelectable = false
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        subtitleField.attributedStringValue = NSAttributedString(
            string: subtitle,
            attributes: [
                .font: OnboardingType.body,
                .foregroundColor: EditorThemeKit.textSecondary,
                .paragraphStyle: paragraph,
            ]
        )

        let stack = NSStackView(views: [overlineField, titleField, subtitleField] + content)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = CCSpace.md
        stack.setCustomSpacing(CCSpace.xs, after: overlineField)
        stack.setCustomSpacing(CCSpace.sm, after: titleField)
        stack.setCustomSpacing(CCSpace.lg, after: subtitleField)
        stack.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(stack)
        NSLayoutConstraint.activate([
            heroPanel.topAnchor.constraint(equalTo: page.topAnchor),
            heroPanel.bottomAnchor.constraint(equalTo: page.bottomAnchor),
            heroPanel.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            heroPanel.widthAnchor.constraint(equalTo: page.widthAnchor, multiplier: OnboardingViewController.heroPanelFraction),

            stack.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 44),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: heroPanel.leadingAnchor, constant: -32),
            // Centre in the visible left panel — the footer bar claims the
            // bottom 66pt of it.
            stack.centerYAnchor.constraint(equalTo: page.centerYAnchor, constant: -27),
            subtitleField.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])

        // The hero panel is NOT staggered: a full-height panel drifting 14pt
        // reads as layout jank, and holding it still is what makes the page
        // crossfade feel calm.
        page.staggerTargets = [overlineField, titleField, subtitleField] + content
        return page
    }

    private func buildWelcomeStep() -> StepPageView {
        let hero = MarkHeroView(markHeight: 112)
        return stepPage(
            overline: "Welcome",
            hero: hero,
            imageName: "OnboardingWelcome",
            title: "Welcome to CaptureCat",
            subtitle: "Beautiful screen recordings with automatic zooms, cursor effects, and device frames. A couple of quick permissions and you're rolling.",
            content: []
        )
    }

    private func buildPermissionsStep() -> StepPageView {
        let mascot = MarkHeroView(markHeight: 64)
        permissionsMascot = mascot

        let rows = NSStackView(views: [screenRow, notifRow, micRow, cameraRow])
        rows.orientation = .vertical
        rows.spacing = CCSpace.xs
        rows.translatesAutoresizingMaskIntoConstraints = false
        for row in [screenRow, notifRow, micRow, cameraRow] {
            row.widthAnchor.constraint(equalToConstant: 360).isActive = true
        }

        deniedNote.font = OnboardingType.caption
        deniedNote.textColor = .systemOrange
        deniedNote.alignment = .center
        deniedNote.isSelectable = true
        deniedNote.translatesAutoresizingMaskIntoConstraints = false
        deniedNote.widthAnchor.constraint(lessThanOrEqualToConstant: 360).isActive = true

        let page = stepPage(
            overline: "Permissions",
            hero: mascot,
            imageName: "OnboardingPermissions",
            title: "A Few Permissions",
            subtitle: "Screen Recording is required to record. The rest are optional — grant them now or any time later.",
            content: [rows, deniedNote, relaunchButton]
        )
        // Stagger each permission row individually, after the header.
        page.staggerTargets = Array(page.staggerTargets.prefix(3))
            + [screenRow, notifRow, micRow, cameraRow, deniedNote, relaunchButton]
        return page
    }

    private func buildAccountStep() -> StepPageView {
        let hero = SymbolHeroView(symbol: "person.crop.circle.badge.checkmark", tint: OnboardingPalette.accent, idle: .none)

        signInButton.onClick = { [weak self] in
            guard let self, !self.isSigningIn else { return }
            Task { await self.performSignIn() }
        }
        signInSpinner.isDisplayedWhenStopped = false
        signInSpinner.translatesAutoresizingMaskIntoConstraints = false

        accountErrorLabel.isSelectable = false
        accountErrorLabel.font = OnboardingType.caption
        accountErrorLabel.textColor = .systemOrange
        accountErrorLabel.alignment = .center
        accountErrorLabel.isHidden = true

        accountCard.translatesAutoresizingMaskIntoConstraints = false
        accountCard.widthAnchor.constraint(equalToConstant: 340).isActive = true

        let signInRow = NSStackView(views: [signInButton, signInSpinner])
        signInRow.orientation = .horizontal
        signInRow.spacing = CCSpace.xs

        return stepPage(
            overline: "Account",
            hero: hero,
            imageName: "OnboardingAccount",
            title: "Sign In",
            subtitle: "Sign in to sync your projects and unlock exporting. Prefer to look around first? You can skip and sign in later from the menu bar.",
            content: [accountCard, signInRow, accountErrorLabel]
        )
    }

    /// Shotbase-style yes/no choice: make CaptureCat the default screenshot
    /// tool (global ⇧⌘3/4/5 — see ScreenshotHotkeys for the macOS caveat).
    private func buildDefaultToolStep() -> StepPageView {
        let hero = SymbolHeroView(symbol: "camera.viewfinder", tint: OnboardingPalette.accent, idle: .none)

        let yesCard = OnboardingChoiceCard(
            title: "Yes, set CaptureCat as default",
            detail: "Use CaptureCat every time you press ⇧⌘3, ⇧⌘4 or ⇧⌘5.")
        let noCard = OnboardingChoiceCard(
            title: "No, keep my current screenshot tool",
            detail: nil)
        let select = { [weak self] (makeDefault: Bool) in
            guard let self else { return }
            self.appState.isDefaultScreenshotTool = makeDefault
            yesCard.setSelected(makeDefault)
            noCard.setSelected(!makeDefault)
            // macOS shows the Accessibility prompt only ONCE per app — every
            // later enable must walk the user to the pane itself, or the
            // toggle silently does nothing.
            if makeDefault, !ScreenshotHotkeys.hasPermission,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
        yesCard.onClick = { select(true) }
        noCard.onClick = { select(false) }
        yesCard.setSelected(appState.isDefaultScreenshotTool)
        noCard.setSelected(!appState.isDefaultScreenshotTool)

        let settingsLink = OnboardingButton(title: "Open Accessibility Settings", symbol: "accessibility", style: .plain)
        settingsLink.onClick = {
            guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
            NSWorkspace.shared.open(url)
        }

        for card in [yesCard, noCard] {
            card.translatesAutoresizingMaskIntoConstraints = false
            card.widthAnchor.constraint(equalToConstant: 360).isActive = true
        }

        return stepPage(
            overline: "Screenshots",
            hero: hero,
            imageName: "OnboardingDefaultTool",
            title: "Make CaptureCat your default screenshot tool?",
            subtitle: "CaptureCat catches ⇧⌘3, ⇧⌘4 and ⇧⌘5 before macOS does — it just needs Accessibility access, which macOS will ask for. You can change this any time in Settings.",
            content: [yesCard, noCard, settingsLink]
        )
    }

    private func buildFinishStep() -> StepPageView {
        let mascot = MarkHeroView(markHeight: 96)
        finishMascot = mascot

        // Feature highlights folded in from the old notes-intro page.
        func highlightRow(symbol: String, text: String) -> NSView {
            let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
            icon.symbolConfiguration = .init(pointSize: 13, weight: .medium)
            icon.contentTintColor = OnboardingPalette.accent
            icon.translatesAutoresizingMaskIntoConstraints = false
            let label = NSTextField(wrappingLabelWithString: text)
            label.isSelectable = false
            label.font = .systemFont(ofSize: 12)
            label.textColor = EditorThemeKit.textPrimary
            label.translatesAutoresizingMaskIntoConstraints = false
            let row = NSView()
            row.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(icon)
            row.addSubview(label)
            NSLayoutConstraint.activate([
                row.widthAnchor.constraint(equalToConstant: 360),
                icon.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                icon.topAnchor.constraint(equalTo: row.topAnchor, constant: 1),
                icon.widthAnchor.constraint(equalToConstant: 20),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: CCSpace.xs),
                label.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                label.topAnchor.constraint(equalTo: row.topAnchor),
                label.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            ])
            return row
        }

        let recordRow = highlightRow(
            symbol: "record.circle",
            text: "Record any time from the CaptureCat icon in your menu bar.")
        let notesRow = highlightRow(
            symbol: "cursorarrow.rays",
            text: "Capture text anywhere: highlight → right-click → Services → Capture Text in CaptureCat.")
        let clipboardRow = highlightRow(
            symbol: "doc.on.clipboard",
            text: "Or File → New Note from Clipboard (⌥⌘N) — notes live beside recordings, searchable and remindable.")

        let rows = NSStackView(views: [recordRow, notesRow, clipboardRow])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = CCSpace.sm

        termsCheckbox.translatesAutoresizingMaskIntoConstraints = false
        termsCheckbox.widthAnchor.constraint(equalToConstant: 360).isActive = true

        let page = stepPage(
            overline: "Ready",
            hero: mascot,
            imageName: "OnboardingFinish",
            title: "You're All Set",
            subtitle: "Here's what CaptureCat can do from day one.",
            content: [rows, termsCheckbox]
        )
        // Stagger highlight rows individually for the compact reveal moment.
        page.staggerTargets = Array(page.staggerTargets.prefix(3))
            + [recordRow, notesRow, clipboardRow, termsCheckbox]
        return page
    }

    // MARK: - Permission logic (same keys/probes as before)

    private func requestScreenPermission() async {
        isRequestingPermissions = true
        refreshControls()

        if screenPermission != .granted {
            hasRequestedScreenRecording = true
            ScreenRecorder.clearAutomaticProbeSuppression()

            let preflight = CGPreflightScreenCaptureAccess()
            logger.info("requestScreenPermission: preflight before request=\(preflight)")
            if !preflight {
                let requestResult = CGRequestScreenCaptureAccess()
                logger.info("requestScreenPermission: CGRequestScreenCaptureAccess returned \(requestResult)")
            }

            do {
                _ = try await appState.recorder.availableContent()
                hasVerifiedScreenRecordingAccess = true
                logger.info("requestScreenPermission: explicit screen-capture probe succeeded")
            } catch {
                let nsError = error as NSError
                logger.error("requestScreenPermission: explicit probe failed domain=\(nsError.domain, privacy: .public) code=\(nsError.code)")
                openSystemSettings(anchor: "Privacy_ScreenCapture")
            }
        }

        refreshPermissionStates()
        isRequestingPermissions = false
        refreshControls()

        if screenPermission == .granted {
            permissionsMascot?.happyBounce()
        }
    }

    private func requestAVPermission(for mediaType: AVMediaType) async {
        isRequestingPermissions = true
        refreshControls()
        let granted = await requestAVAccess(for: mediaType)
        refreshPermissionStates()
        isRequestingPermissions = false
        refreshControls()
        if granted { permissionsMascot?.happyBounce() }
    }

    private func performSignIn() async {
        isSigningIn = true
        accountErrorLabel.isHidden = true
        refreshControls()
        do {
            try await appState.signIn()
        } catch {
            let nsError = error as NSError
            logger.error("performSignIn: failed domain=\(nsError.domain, privacy: .public) code=\(nsError.code)")
            accountErrorLabel.stringValue = "Sign-in didn't complete. You can try again or skip for now."
            accountErrorLabel.isHidden = false
        }
        isSigningIn = false
        refreshAccountUI()
        refreshControls()
    }

    private func requestNotificationPermission() {
        isRequestingPermissions = true
        refreshControls()
        ReminderCenter.shared.requestAuthorization { [weak self] granted in
            guard let self else { return }
            self.notificationPermission = granted ? .granted : .denied
            self.isRequestingPermissions = false
            self.refreshControls()
            if granted { self.permissionsMascot?.happyBounce() }
        }
    }

    private func refreshNotificationState() {
        ReminderCenter.shared.authorizationStatus { [weak self] status in
            guard let self else { return }
            switch status {
            case .authorized, .provisional:
                self.notificationPermission = .granted
            case .denied:
                self.notificationPermission = .denied
            case .notDetermined:
                self.notificationPermission = .unknown
            @unknown default:
                self.notificationPermission = .unknown
            }
            self.refreshControls()
        }
    }

    private func refreshPermissionStates() {
        refreshNotificationState()
        let preflight = CGPreflightScreenCaptureAccess()
        if preflight || hasVerifiedScreenRecordingAccess {
            screenPermission = .granted
        } else if hasRequestedScreenRecording {
            screenPermission = .denied
        } else {
            screenPermission = .unknown
        }
        microphonePermission = Self.state(for: AVCaptureDevice.authorizationStatus(for: .audio))
        cameraPermission = Self.state(for: AVCaptureDevice.authorizationStatus(for: .video))
        refreshControls()
    }

    private func refreshAccountUI() {
        let signedIn = appState.isSignedIn
        accountCard.isHidden = !signedIn
        signInButton.isHidden = signedIn
        signInSpinner.isHidden = !isSigningIn
        if signedIn {
            accountCard.configure(email: appState.currentAccountEmail ?? "Signed in")
        }
    }

    private func refreshControls() {
        screenRow.apply(
            state: screenPermission.label, color: screenPermission.color,
            buttonTitle: screenPermission == .denied ? "Settings" : "Grant",
            showsButton: screenPermission != .granted,
            enabled: !isRequestingPermissions)
        notifRow.apply(
            state: notificationPermission == .unknown ? "Pending" : notificationPermission.label,
            color: notificationPermission.color,
            buttonTitle: notificationPermission == .denied ? "Settings" : "Grant",
            showsButton: notificationPermission != .granted,
            enabled: !isRequestingPermissions)
        micRow.apply(
            state: microphonePermission.label, color: microphonePermission.color,
            buttonTitle: microphonePermission == .denied ? "Settings" : "Grant",
            showsButton: microphonePermission != .granted,
            enabled: !isRequestingPermissions)
        cameraRow.apply(
            state: cameraPermission.label, color: cameraPermission.color,
            buttonTitle: cameraPermission == .denied ? "Settings" : "Grant",
            showsButton: cameraPermission != .granted,
            enabled: !isRequestingPermissions)

        // Screen-recording denied: the grant only applies on the next launch,
        // so surface the relaunch path beneath the rows.
        let screenDenied = screenPermission == .denied
        deniedNote.isHidden = !screenDenied
        relaunchButton.isHidden = !screenDenied
        if screenDenied {
            deniedNote.stringValue = "Enable CaptureCat in System Settings → Privacy & Security → Screen Recording, then relaunch — macOS applies the grant on the next launch. Missing from the list? Click + and add:\n\(Bundle.main.bundlePath)"
        }

        signInButton.isEnabled = !isSigningIn
        if isSigningIn { signInSpinner.startAnimation(nil) } else { signInSpinner.stopAnimation(nil) }

        backButton.isHidden = step == .welcome
        switch step {
        case .welcome:
            nextButton.setTitle("Get Started")
            nextButton.style = .primary
            nextButton.isEnabled = true
        case .permissions:
            nextButton.setTitle("Continue")
            nextButton.style = .primary
            nextButton.isEnabled = screenPermission == .granted
        case .account:
            let signedIn = appState.isSignedIn
            nextButton.setTitle(signedIn ? "Continue" : "Skip")
            nextButton.style = signedIn ? .primary : .secondary
            nextButton.isEnabled = true
        case .defaultTool:
            nextButton.setTitle("Continue")
            nextButton.style = .primary
            nextButton.isEnabled = true
        case .finish:
            nextButton.setTitle("Start Recording")
            nextButton.style = .primary
            nextButton.isEnabled = termsCheckbox.isOn
        }
    }

    private func requestAVAccess(for mediaType: AVMediaType) async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: mediaType) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private static func state(for status: AVAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized: return .granted
        case .notDetermined: return .unknown
        case .denied, .restricted: return .denied
        @unknown default: return .unknown
        }
    }

    /// macOS applies a Screen Recording grant only at process launch, so a grant
    /// made while we're running needs a quit-and-reopen. Spawn a fresh instance
    /// (preserving `--` launch flags) and terminate this one.
    private func relaunchApp() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        var arguments = ["-n", Bundle.main.bundlePath]
        let flags = ProcessInfo.processInfo.arguments.dropFirst().filter { $0.hasPrefix("--") }
        if !flags.isEmpty {
            arguments += ["--args"] + flags
        }
        task.arguments = arguments
        do {
            try task.run()
        } catch {
            logger.error("relaunchApp: failed to spawn new instance: \(error.localizedDescription, privacy: .public)")
            return
        }
        NSApplication.shared.terminate(nil)
    }

    private func openSystemSettings(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func completeOnboardingFlow() {
        appState.completeOnboarding(acceptedTerms: termsCheckbox.isOn)
        if let onboardingWindow = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue == "onboarding" }) {
            onboardingWindow.close()
        }
        appState.beginNewRecording()
    }
}

// MARK: - Step page

/// A single wizard page. Carries the ordered list of views to stagger in.
@MainActor
/// Radio-style choice card (Shotbase-esque): rounded row with a radio dot,
/// bold title and optional detail line; the selected card wears the accent
/// outline. Colors re-resolve on theme flips.
private final class OnboardingChoiceCard: NSControl {
    var onClick: (() -> Void)?

    private let radio = NSView()
    private let radioDot = NSView()
    private let titleField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(wrappingLabelWithString: "")
    private var isSelected = false
    private var themeObservation: CCThemeObservation?

    override var isFlipped: Bool { true }

    init(title: String, detail: String?) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1

        radio.translatesAutoresizingMaskIntoConstraints = false
        radio.wantsLayer = true
        radio.layer?.cornerRadius = 8
        radio.layer?.borderWidth = 1.5
        radioDot.translatesAutoresizingMaskIntoConstraints = false
        radioDot.wantsLayer = true
        radioDot.layer?.cornerRadius = 4
        radio.addSubview(radioDot)

        titleField.stringValue = title
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.translatesAutoresizingMaskIntoConstraints = false

        detailField.isSelectable = false
        detailField.stringValue = detail ?? ""
        detailField.font = .systemFont(ofSize: 11)
        detailField.isHidden = detail == nil
        detailField.translatesAutoresizingMaskIntoConstraints = false

        addSubview(radio)
        addSubview(titleField)
        addSubview(detailField)
        NSLayoutConstraint.activate([
            radio.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            radio.centerYAnchor.constraint(equalTo: centerYAnchor),
            radio.widthAnchor.constraint(equalToConstant: 16),
            radio.heightAnchor.constraint(equalToConstant: 16),
            radioDot.centerXAnchor.constraint(equalTo: radio.centerXAnchor),
            radioDot.centerYAnchor.constraint(equalTo: radio.centerYAnchor),
            radioDot.widthAnchor.constraint(equalToConstant: 8),
            radioDot.heightAnchor.constraint(equalToConstant: 8),

            titleField.leadingAnchor.constraint(equalTo: radio.trailingAnchor, constant: 12),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            titleField.topAnchor.constraint(equalTo: topAnchor, constant: 13),
            detailField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            detailField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            detailField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 2),
            bottomAnchor.constraint(equalTo: (detail == nil ? titleField : detailField).bottomAnchor, constant: 13),
        ])
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setSelected(_ selected: Bool) {
        isSelected = selected
        applyTheme()
    }

    private func applyTheme() {
        titleField.textColor = EditorThemeKit.textPrimary
        detailField.textColor = EditorThemeKit.textSecondary
        layer?.backgroundColor = EditorThemeKit.panelElevated.cgColor
        layer?.borderColor = isSelected
            ? OnboardingPalette.accent.cgColor
            : EditorThemeKit.hairline.cgColor
        layer?.borderWidth = isSelected ? 1.5 : 1
        radio.layer?.borderColor = isSelected
            ? OnboardingPalette.accent.cgColor
            : EditorThemeKit.textSecondary.withAlphaComponent(0.5).cgColor
        radioDot.layer?.backgroundColor = isSelected
            ? OnboardingPalette.accent.cgColor
            : NSColor.clear.cgColor
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

/// Aspect-fill image for the hero card. A PLAIN sublayer, not the view's
/// backing layer — AppKit owns view backing-layer contents and clears
/// foreign contents on the next display pass (see WallpaperCell); NSImage
/// contents on a raw CALayer are safe and auto-oriented.
private final class OnboardingCardImageView: NSView {
    var image: NSImage? { didSet { imageLayer.contents = image } }
    private let imageLayer = CALayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        layer?.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        CATransaction.commit()
    }
}

private final class StepPageView: NSView {
    var staggerTargets: [NSView] = []
    override var isFlipped: Bool { false }
}

// MARK: - Ambient background

/// Two soft radial washes (accent + cyan) drifting behind every page —
/// slow additive translation + opacity breathing on 13–17s loops. Near
/// imperceptible by design; fully static under Reduce Motion.
@MainActor
private final class AmbientGlowView: NSView {
    private let indigoWash = CAGradientLayer()
    private let cyanWash = CAGradientLayer()
    private var themeObservation: CCThemeObservation?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        for wash in [indigoWash, cyanWash] {
            wash.type = .radial
            wash.startPoint = CGPoint(x: 0.5, y: 0.5)
            wash.endPoint = CGPoint(x: 1, y: 1)
            layer?.addSublayer(wash)
        }
        themeObservation = CCThemeObservation { [weak self] in self?.applyColors() }
        applyColors()

        guard !RecordingMotion.reduceMotion else { return }
        addDrift(to: indigoWash, dx: 26, dy: 18, duration: 17, opacityRange: (0.7, 1.0))
        addDrift(to: cyanWash, dx: -22, dy: -16, duration: 13, opacityRange: (0.55, 0.9))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func applyColors() {
        let indigo = NSColor.systemIndigo.withAlphaComponent(CCTheme.isDark ? 0.16 : 0.10)
        let cyan = NSColor.systemCyan.withAlphaComponent(CCTheme.isDark ? 0.12 : 0.08)
        indigoWash.colors = [indigo.cgColor, indigo.withAlphaComponent(0).cgColor]
        cyanWash.colors = [cyan.cgColor, cyan.withAlphaComponent(0).cgColor]
    }

    private func addDrift(to wash: CALayer, dx: CGFloat, dy: CGFloat, duration: TimeInterval,
                          opacityRange: (Float, Float)) {
        let x = CABasicAnimation(keyPath: "transform.translation.x")
        x.fromValue = 0; x.toValue = dx
        let y = CABasicAnimation(keyPath: "transform.translation.y")
        y.fromValue = 0; y.toValue = dy
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = opacityRange.0; breathe.toValue = opacityRange.1
        for (key, anim) in [("drift-x", x), ("drift-y", y), ("breathe", breathe)] {
            anim.duration = duration
            anim.autoreverses = true
            anim.repeatCount = .infinity
            anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            wash.add(anim, forKey: key)
        }
    }

    override func layout() {
        super.layout()
        let size = max(bounds.width, bounds.height) * 0.9
        indigoWash.frame = CGRect(x: bounds.width * 0.12 - size / 2, y: bounds.height * 0.78 - size / 2,
                                  width: size, height: size)
        cyanWash.frame = CGRect(x: bounds.width * 0.88 - size / 2, y: bounds.height * 0.18 - size / 2,
                                width: size, height: size)
    }
}

// MARK: - Hero views

/// The vector CaptureCat mark — the traced artwork (not the app-icon bitmap),
/// floating and blinking over a soft ambient accent glow that slowly pulses.
/// Reacts: `happyBounce()` on a permission grant, `celebrate()` on finish.
/// All idle motion collapses under Reduce Motion.
@MainActor
private final class MarkHeroView: NSView {
    private let glow = CAGradientLayer()

    init(markHeight: CGFloat = 112) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        // Ambient glow — a soft radial accent falloff behind the mark,
        // breathing. Gradient, not CIFilter: layer filters need
        // layerUsesCoreImageFilters and this reads identically.
        let glowSize = markHeight * 1.5
        glow.type = .radial
        glow.colors = [
            OnboardingPalette.accent.withAlphaComponent(0.55).cgColor,
            OnboardingPalette.accent.withAlphaComponent(0.0).cgColor,
        ]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        glow.frame = CGRect(x: 0, y: 0, width: glowSize, height: glowSize)
        glow.opacity = 0.6
        layer?.addSublayer(glow)

        let mark = CaptureCatMarkView(height: markHeight)
        addSubview(mark)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: markHeight + 16),
            heightAnchor.constraint(equalToConstant: markHeight + 12),
            mark.centerXAnchor.constraint(equalTo: centerXAnchor),
            mark.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        if !RecordingMotion.reduceMotion {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.42
            pulse.toValue = 0.75
            pulse.duration = 2.75 // half the mark's 5.5 s float loop
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            glow.add(pulse, forKey: "pulse")
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// A single soft spring pulse — the "that worked" reaction on a grant.
    /// Restraint over bounce: one gentle overshoot, then settle.
    func happyBounce() {
        guard !RecordingMotion.reduceMotion, let layer else { return }
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: frame.midX, y: frame.midY)
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [1.0, 1.06, 0.99, 1.0]
        scale.keyTimes = [0, 0.35, 0.75, 1]
        scale.duration = 0.5
        scale.timingFunction = RecordingMotion.settleCurve
        layer.add(scale, forKey: "happy-bounce")
    }

    /// One-shot celebratory moment for the finish page: a soft pop on the
    /// mark plus a brief glow bloom (opacity + scale — no emitters).
    func celebrate() {
        guard !RecordingMotion.reduceMotion, let layer else { return }
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: frame.midX, y: frame.midY)
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [1.0, 1.08, 0.985, 1.0]
        scale.keyTimes = [0, 0.35, 0.7, 1]
        scale.duration = 0.6
        scale.timingFunction = RecordingMotion.settleCurve
        layer.add(scale, forKey: "celebrate")

        let bloomOpacity = CAKeyframeAnimation(keyPath: "opacity")
        bloomOpacity.values = [0.6, 1.0, 0.6]
        bloomOpacity.keyTimes = [0, 0.4, 1]
        let bloomScale = CAKeyframeAnimation(keyPath: "transform.scale")
        bloomScale.values = [1.0, 1.35, 1.0]
        bloomScale.keyTimes = [0, 0.4, 1]
        for (key, anim) in [("bloom-opacity", bloomOpacity), ("bloom-scale", bloomScale)] {
            anim.duration = 0.9
            anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            glow.add(anim, forKey: key)
        }
    }

    override func layout() {
        super.layout()
        glow.position = CGPoint(x: bounds.midX, y: bounds.midY)
    }
}

/// Large SF Symbol inside a flat elevated tile — the visual anchor of the
/// sign-in step, with an optional barely-there breathing scale.
@MainActor
private final class SymbolHeroView: NSView {
    enum Idle { case none, breathe }

    private let tile = NSView()

    init(symbol: String, tint: NSColor, idle: Idle) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        // Flat, quiet tile — elevated panel + hairline, tinted glyph. No
        // glow/wash: the tile should read like the app's chrome, not a badge.
        tile.translatesAutoresizingMaskIntoConstraints = false
        tile.wantsLayer = true
        tile.layer?.cornerRadius = 20
        tile.layer?.cornerCurve = .continuous
        tile.layer?.backgroundColor = EditorThemeKit.panelElevated.cgColor
        tile.layer?.borderWidth = 1
        tile.layer?.borderColor = EditorThemeKit.hairline.cgColor
        addSubview(tile)

        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 36, weight: .medium)
        icon.contentTintColor = tint
        icon.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(icon)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 96),
            heightAnchor.constraint(equalToConstant: 96),
            tile.widthAnchor.constraint(equalToConstant: 96),
            tile.heightAnchor.constraint(equalToConstant: 96),
            tile.centerXAnchor.constraint(equalTo: centerXAnchor),
            tile.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
        ])

        if idle == .breathe, !RecordingMotion.reduceMotion {
            tile.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 1.0
            scale.toValue = 1.015
            scale.duration = 2.6
            scale.autoreverses = true
            scale.repeatCount = .infinity
            scale.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            tile.layer?.add(scale, forKey: "breathe")
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        // Recenter about the middle for the breathing scale. The anchor must
        // be 0.5 for EVERY tile — with the default (0,0) anchor this position
        // assignment shoved non-animating tiles up-right by half their size.
        tile.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        tile.layer?.position = CGPoint(x: bounds.midX, y: bounds.midY)
    }
}

/// Shared "granted" celebration — a quick springy scale pop on a view's
/// layer, centred on the view. No-op under Reduce Motion.
@MainActor
private enum OnboardingPop {
    static func pop(_ view: NSView) {
        guard !RecordingMotion.reduceMotion, let layer = view.layer else { return }
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: view.frame.midX, y: view.frame.midY)
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [1.0, 1.14, 0.97, 1.0]
        scale.keyTimes = [0, 0.4, 0.75, 1]
        scale.duration = 0.38
        scale.timingFunction = RecordingMotion.settleCurve
        layer.add(scale, forKey: "granted-pop")
    }
}

// MARK: - Permission grant row

/// Flat panel row for the combined permissions page — icon well, title,
/// one-line why, a per-row Grant button, and a live status pill that pops
/// green on grant.
@MainActor
private final class GrantRowView: NSView {
    var onGrant: (() -> Void)?

    private let stateLabel = NSTextField(labelWithString: "")
    private let stateDot = NSView()
    private let statePill = NSView()
    private let iconWell = NSView()
    private let titleField: NSTextField
    private let detailField: NSTextField
    private let grantButton = OnboardingButton(title: "Grant", symbol: nil, style: .secondary)
    private var themeObservation: CCThemeObservation?

    init(title: String, detail: String, symbol: String) {
        titleField = NSTextField(labelWithString: title)
        detailField = NSTextField(labelWithString: detail)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = EditorThemeKit.panelRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1

        iconWell.translatesAutoresizingMaskIntoConstraints = false
        iconWell.wantsLayer = true
        iconWell.layer?.cornerRadius = 8
        iconWell.layer?.cornerCurve = .continuous
        addSubview(iconWell)

        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        icon.contentTintColor = OnboardingPalette.accent
        icon.translatesAutoresizingMaskIntoConstraints = false
        iconWell.addSubview(icon)

        titleField.font = OnboardingType.rowTitle
        titleField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleField)

        detailField.font = OnboardingType.caption
        detailField.lineBreakMode = .byTruncatingTail
        detailField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(detailField)

        grantButton.onClick = { [weak self] in self?.onGrant?() }
        addSubview(grantButton)

        statePill.translatesAutoresizingMaskIntoConstraints = false
        statePill.wantsLayer = true
        statePill.layer?.cornerRadius = 6
        statePill.layer?.borderWidth = 1
        addSubview(statePill)

        stateDot.translatesAutoresizingMaskIntoConstraints = false
        stateDot.wantsLayer = true
        stateDot.layer?.cornerRadius = 3
        statePill.addSubview(stateDot)

        stateLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        stateLabel.translatesAutoresizingMaskIntoConstraints = false
        statePill.addSubview(stateLabel)

        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 56),
            iconWell.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconWell.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconWell.widthAnchor.constraint(equalToConstant: 30),
            iconWell.heightAnchor.constraint(equalToConstant: 30),
            icon.centerXAnchor.constraint(equalTo: iconWell.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconWell.centerYAnchor),

            titleField.leadingAnchor.constraint(equalTo: iconWell.trailingAnchor, constant: 11),
            titleField.topAnchor.constraint(equalTo: centerYAnchor, constant: -15),
            detailField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            detailField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 2),
            detailField.trailingAnchor.constraint(lessThanOrEqualTo: grantButton.leadingAnchor, constant: -8),

            grantButton.trailingAnchor.constraint(equalTo: statePill.leadingAnchor, constant: -8),
            grantButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            statePill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            statePill.centerYAnchor.constraint(equalTo: centerYAnchor),
            statePill.heightAnchor.constraint(equalToConstant: 22),
            stateDot.leadingAnchor.constraint(equalTo: statePill.leadingAnchor, constant: 8),
            stateDot.centerYAnchor.constraint(equalTo: statePill.centerYAnchor),
            stateDot.widthAnchor.constraint(equalToConstant: 6),
            stateDot.heightAnchor.constraint(equalToConstant: 6),
            stateLabel.leadingAnchor.constraint(equalTo: stateDot.trailingAnchor, constant: 5),
            stateLabel.trailingAnchor.constraint(equalTo: statePill.trailingAnchor, constant: -8),
            stateLabel.centerYAnchor.constraint(equalTo: statePill.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func applyTheme() {
        layer?.backgroundColor = EditorThemeKit.panel.cgColor
        layer?.borderColor = EditorThemeKit.hairline.cgColor
        iconWell.layer?.backgroundColor = OnboardingPalette.accentWash.cgColor
        titleField.textColor = EditorThemeKit.textPrimary
        detailField.textColor = EditorThemeKit.textTertiary
        statePill.layer?.backgroundColor = EditorThemeKit.panelElevated.cgColor
        statePill.layer?.borderColor = EditorThemeKit.hairline.cgColor
    }

    func apply(state: String, color: NSColor, buttonTitle: String, showsButton: Bool, enabled: Bool) {
        let becameGranted = color == .systemGreen && stateLabel.textColor != .systemGreen
        stateLabel.stringValue = state
        stateLabel.textColor = color
        stateDot.layer?.backgroundColor = color.cgColor
        grantButton.setTitle(buttonTitle)
        grantButton.isHidden = !showsButton
        grantButton.isEnabled = enabled
        if becameGranted { OnboardingPop.pop(statePill) }
    }

    /// Continue-was-clicked-too-soon nudge: a brief accent border flash plus
    /// a tiny horizontal shake. Reduce Motion keeps just the flash.
    func nudge() {
        guard let layer else { return }
        let flash = CABasicAnimation(keyPath: "borderColor")
        flash.fromValue = OnboardingPalette.accentBorder.cgColor
        flash.toValue = EditorThemeKit.hairline.cgColor
        flash.duration = 0.8
        flash.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(flash, forKey: "nudge-flash")
        guard !RecordingMotion.reduceMotion else { return }
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shake.values = [0, -5, 4, -2, 0]
        shake.duration = 0.35
        shake.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(shake, forKey: "nudge-shake")
    }
}

// MARK: - Account card

/// Signed-in confirmation — avatar initial, email, and a green check.
@MainActor
private final class AccountCardView: NSView {
    private let avatar = NSView()
    private let avatarInitial = NSTextField(labelWithString: "")
    private let emailField = NSTextField(labelWithString: "")
    private let signedInLabel = NSTextField(labelWithString: "Signed in")
    private var themeObservation: CCThemeObservation?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = EditorThemeKit.panelRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1

        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.wantsLayer = true
        avatar.layer?.cornerRadius = 15
        addSubview(avatar)
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }

        avatarInitial.font = .systemFont(ofSize: 14, weight: .bold)
        avatarInitial.textColor = .white
        avatarInitial.alignment = .center
        avatarInitial.translatesAutoresizingMaskIntoConstraints = false
        avatar.addSubview(avatarInitial)

        signedInLabel.font = .systemFont(ofSize: 11, weight: .regular)
        signedInLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(signedInLabel)

        emailField.font = .systemFont(ofSize: 13, weight: .semibold)
        emailField.lineBreakMode = .byTruncatingMiddle
        emailField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emailField)

        let check = NSImageView(image: NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil) ?? NSImage())
        check.symbolConfiguration = .init(pointSize: 16, weight: .semibold)
        check.contentTintColor = .systemGreen
        check.translatesAutoresizingMaskIntoConstraints = false
        addSubview(check)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 56),
            avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            avatar.centerYAnchor.constraint(equalTo: centerYAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 30),
            avatar.heightAnchor.constraint(equalToConstant: 30),
            avatarInitial.centerXAnchor.constraint(equalTo: avatar.centerXAnchor),
            avatarInitial.centerYAnchor.constraint(equalTo: avatar.centerYAnchor),

            signedInLabel.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 11),
            signedInLabel.topAnchor.constraint(equalTo: centerYAnchor, constant: -12),
            emailField.leadingAnchor.constraint(equalTo: signedInLabel.leadingAnchor),
            emailField.topAnchor.constraint(equalTo: signedInLabel.bottomAnchor, constant: 1),
            emailField.trailingAnchor.constraint(lessThanOrEqualTo: check.leadingAnchor, constant: -8),

            check.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func applyTheme() {
        layer?.backgroundColor = OnboardingPalette.successWash.cgColor
        layer?.borderColor = OnboardingPalette.successBorder.cgColor
        avatar.layer?.backgroundColor = OnboardingPalette.accent.cgColor
        signedInLabel.textColor = EditorThemeKit.textTertiary
        emailField.textColor = EditorThemeKit.textPrimary
    }

    func configure(email: String) {
        emailField.stringValue = email
        let initial = email.first.map { String($0).uppercased() } ?? "?"
        avatarInitial.stringValue = initial
    }
}

// MARK: - Checkbox

/// Flat panel row with a hand-drawn checkbox — matches the app's controls
/// rather than the stock AppKit checkbox chrome.
@MainActor
private final class OnboardingCheckbox: NSControl {
    var isOn: Bool = false { didSet { refresh() } }
    var onChange: ((Bool) -> Void)?

    private let box = NSView()
    private let check = NSImageView()
    private let titleLabel: NSTextField
    private var themeObservation: CCThemeObservation?

    init(title: String) {
        titleLabel = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = EditorThemeKit.panelRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1

        box.translatesAutoresizingMaskIntoConstraints = false
        box.wantsLayer = true
        box.layer?.cornerRadius = 5
        box.layer?.cornerCurve = .continuous
        box.layer?.borderWidth = 1.5
        addSubview(box)

        check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .bold))
        check.contentTintColor = .white
        check.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(check)

        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 44),
            box.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            box.centerYAnchor.constraint(equalTo: centerYAnchor),
            box.widthAnchor.constraint(equalToConstant: 18),
            box.heightAnchor.constraint(equalToConstant: 18),
            check.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            check.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: box.trailingAnchor, constant: 11),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
        ])
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func applyTheme() {
        layer?.backgroundColor = EditorThemeKit.panel.cgColor
        layer?.borderColor = EditorThemeKit.hairline.cgColor
        titleLabel.textColor = EditorThemeKit.textPrimary
        refresh()
    }

    private func refresh() {
        check.isHidden = !isOn
        box.layer?.backgroundColor = (isOn ? OnboardingPalette.accent : NSColor.clear).cgColor
        box.layer?.borderColor = (isOn ? OnboardingPalette.accent : EditorThemeKit.textTertiary).cgColor
    }

    override func mouseDown(with event: NSEvent) {
        isOn.toggle()
        onChange?(isOn)
    }
}

// MARK: - Page dots

/// Wizard progress dots — the selected dot stretches into an accent capsule,
/// sliding between positions on the settle curve.
@MainActor
private final class PageDotsView: NSView {
    private var widthConstraints: [NSLayoutConstraint] = []
    private var dotViews: [NSView] = []
    private var selectedIndex = 0
    private var themeObservation: CCThemeObservation?

    private static var inactiveDot: NSColor {
        (CCTheme.isDark ? NSColor.white : .black).withAlphaComponent(0.20)
    }

    init(count: Int) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        for _ in 0..<count {
            let dot = NSView()
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3
            let width = dot.widthAnchor.constraint(equalToConstant: 6)
            NSLayoutConstraint.activate([width, dot.heightAnchor.constraint(equalToConstant: 6)])
            widthConstraints.append(width)
            dotViews.append(dot)
            stack.addArrangedSubview(dot)
        }
        themeObservation = CCThemeObservation { [weak self] in
            guard let self else { return }
            self.select(index: self.selectedIndex)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func select(index: Int) {
        selectedIndex = index
        NSAnimationContext.runAnimationGroup { context in
            context.duration = RecordingMotion.reduceMotion ? RecordingMotion.reducedDuration : 0.35
            context.timingFunction = RecordingMotion.settleCurve
            context.allowsImplicitAnimation = true
            for (i, dot) in dotViews.enumerated() {
                widthConstraints[i].constant = i == index ? 20 : 6
                dot.layer?.backgroundColor = (i == index
                    ? OnboardingPalette.accent
                    : Self.inactiveDot).cgColor
            }
            layoutSubtreeIfNeeded()
        }
    }
}

// MARK: - Button

/// Flat onboarding button — primary (accent fill), secondary (panel +
/// hairline), or plain (text only). Height 32, radius 8. Hover lifts the pill
/// 1pt with a subtle accent glow; press settles it back with a slight scale —
/// the web pill feel. Reduce Motion keeps only the color washes.
@MainActor
final class OnboardingButton: NSControl {
    enum Style { case primary, secondary, plain }

    var onClick: (() -> Void)?
    /// Fired when the button is clicked while disabled — used for the
    /// "Continue needs Screen Recording" hint shake.
    var onDisabledClick: (() -> Void)?
    var style: Style { didSet { refresh() } }

    private let label: NSTextField
    private let iconView: NSImageView?
    private var isHovered = false { didSet { refresh() } }
    private var isPressed = false { didSet { refresh() } }
    private var trackingArea: NSTrackingArea?
    private var themeObservation: CCThemeObservation?

    override var isEnabled: Bool { didSet { refresh() } }

    init(title: String, symbol: String?, style: Style) {
        self.style = style
        self.label = NSTextField(labelWithString: title)
        if let symbol {
            let view = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
            view.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
            self.iconView = view
        } else {
            self.iconView = nil
        }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1

        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        let leadingInset: CGFloat = iconView == nil ? 16 : 12
        if let iconView {
            iconView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(iconView)
            NSLayoutConstraint.activate([
                iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leadingInset),
                iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
                label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 7),
            ])
        } else {
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leadingInset).isActive = true
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 32),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])
        // refresh() reads EditorThemeKit live — re-run it on every theme flip.
        themeObservation = CCThemeObservation { [weak self] in self?.refresh() }

        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setTitle(_ title: String) { label.stringValue = title }

    private func refresh() {
        let fill: NSColor
        let border: NSColor
        let content: NSColor
        switch style {
        case .primary:
            let base = OnboardingPalette.accent
            // Hover blends toward the theme's ink; press always darkens.
            let ink: NSColor = CCTheme.isDark ? .white : .black
            fill = isPressed ? base.blended(withFraction: 0.15, of: .black) ?? base
                 : isHovered ? base.blended(withFraction: 0.12, of: ink) ?? base
                 : base
            border = .clear
            content = .white
        case .secondary:
            fill = isPressed ? EditorThemeKit.activeFill
                 : isHovered ? EditorThemeKit.hoverFill
                 : EditorThemeKit.panelElevated
            border = EditorThemeKit.hairline
            content = EditorThemeKit.textPrimary
        case .plain:
            fill = isHovered ? EditorThemeKit.hoverFill : .clear
            border = .clear
            content = EditorThemeKit.textSecondary
        }
        layer?.backgroundColor = fill.cgColor
        layer?.borderColor = border.cgColor
        label.textColor = content
        iconView?.contentTintColor = content
        alphaValue = isEnabled ? 1 : 0.4
        applyLiftAndGlow()
    }

    /// Hover lift (+1pt with a soft accent glow) and press scale — layer-only,
    /// independent of Auto Layout. Skipped under Reduce Motion.
    private func applyLiftAndGlow() {
        guard let layer, !RecordingMotion.reduceMotion else { return }
        let lift = isHovered && !isPressed && isEnabled
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = RecordingMotion.settleCurve
            context.allowsImplicitAnimation = true
            var transform = CGAffineTransform.identity
            if lift { transform = transform.translatedBy(x: 0, y: 1) }
            if isPressed {
                let w = bounds.width, h = bounds.height
                transform = transform
                    .translatedBy(x: w / 2, y: h / 2)
                    .scaledBy(x: 0.97, y: 0.97)
                    .translatedBy(x: -w / 2, y: -h / 2)
            }
            layer.setAffineTransform(transform)
            if style == .primary {
                layer.shadowColor = OnboardingPalette.accent.cgColor
                layer.shadowOpacity = lift ? 0.35 : 0
                layer.shadowRadius = 7
                layer.shadowOffset = .zero
            } else {
                layer.shadowOpacity = 0
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = isEnabled }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else {
            onDisabledClick?()
            return
        }
        isPressed = true
    }
    override func mouseUp(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}
