import AppKit
import AVFoundation
import CoreGraphics
import UserNotifications
import os

private let logger = Logger(subsystem: "so.capturecat.CaptureCat", category: "OnboardingAppKit")

/// One type scale for the wizard's content column.
private enum OnboardingType {
    static let display = NSFont.systemFont(ofSize: 27, weight: .semibold)
    static let displayTracking: CGFloat = -0.6
    static let body = NSFont.systemFont(ofSize: 13.5, weight: .regular)
    static let rowTitle = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let caption = NSFont.systemFont(ofSize: 11, weight: .regular)
    static let overline = NSFont.systemFont(ofSize: 11, weight: .semibold)
    static let overlineKern: CGFloat = 1.6
}

/// Native onboarding wizard — five steps (welcome → permissions → account →
/// default screenshot tool → finish) in two panels: a CCKit content column
/// on the left, and on the right a live STAGE (OnboardingStage.swift) — a
/// drifting mesh-gradient wallpaper with a choreographed product scene per
/// step (the auto-zoom demo, a permissions panel that mirrors your real
/// grants, cloud share, ⇧⌘4, a celebration). Same UserDefaults keys and
/// AppState calls as ever: if Screen Recording was granted on a previous
/// install the whole wizard auto-completes, so re-installs never see it.
///
/// Hosted in TWO topologies — its own 960×600 window and the (resizable)
/// editor window's content switcher — so every constraint is responsive.
@MainActor
final class OnboardingViewController: NSViewController {
    /// `--show-onboarding` launch argument: force the wizard open and skip the
    /// granted-permissions auto-complete, for previewing/testing.
    static var isForcedPreview: Bool {
        ProcessInfo.processInfo.arguments.contains("--show-onboarding")
    }

    /// Harnesses set this BEFORE constructing the controller: no auto-complete
    /// (it would write the real onboarding defaults and start a recording) and
    /// no activation re-probe (it would overwrite injected permission states).
    static var harnessMode = false

    /// Width fraction of the window the right-hand stage occupies.
    static let stageFraction: CGFloat = 0.5

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

        @MainActor var color: NSColor {
            switch self {
            case .unknown: return CCTheme.color.mutedForeground
            case .denied: return .systemOrange
            case .granted: return .systemGreen
            }
        }
    }

    private enum Step: Int, CaseIterable {
        case welcome, permissions, account, defaultTool, finish

        var scene: OnboardingStageView.SceneID {
            switch self {
            case .welcome: return .welcome
            case .permissions: return .permissions
            case .account: return .account
            case .defaultTool: return .shortcut
            case .finish: return .finish
            }
        }
    }

    private var step: Step = .welcome
    private var screenPermission: PermissionState = .unknown
    private var notificationPermission: PermissionState = .unknown
    private var microphonePermission: PermissionState = .unknown
    private var cameraPermission: PermissionState = .unknown
    private var isRequestingPermissions = false
    private var isSigningIn = false
    private var hasCelebratedFinish = false
    private var backShown: Bool?

    private var hasRequestedScreenRecording: Bool {
        get { UserDefaults.standard.bool(forKey: "hasRequestedScreenRecording") }
        set { UserDefaults.standard.set(newValue, forKey: "hasRequestedScreenRecording") }
    }
    private var hasVerifiedScreenRecordingAccess: Bool {
        get { UserDefaults.standard.bool(forKey: "hasVerifiedScreenRecordingAccess") }
        set { UserDefaults.standard.set(newValue, forKey: "hasVerifiedScreenRecordingAccess") }
    }

    // MARK: Shared chrome

    private let leftPanel = NSView()
    private let spill = OnboardingSpillView()
    private let pageContainer = NSView()
    private var currentPage: StepPageView?
    private let footerDivider = CCDivider()
    private let stepIndicator = CCStepIndicator(count: Step.allCases.count)
    private let backButton = CCButton(title: "Back", symbol: "chevron.left", style: .ghost)
    private let nextButton = CCButton(title: "Get Started", style: .primary, size: .lg)
    private let stage = OnboardingStageView()
    private var activationObserver: NSObjectProtocol?
    private var themeObservation: CCThemeObservation?

    // MARK: Step-owned controls (kept alive across transitions)

    private let screenRow = PermissionRow(
        title: "Screen Recording", detail: "Required to record",
        symbol: "rectangle.inset.filled.badge.record")
    private let notifRow = PermissionRow(
        title: "Notifications", detail: "Optional · capture reminders",
        symbol: "bell.badge")
    private let micRow = PermissionRow(
        title: "Microphone", detail: "Optional · narrate recordings",
        symbol: "mic.fill")
    private let cameraRow = PermissionRow(
        title: "Camera", detail: "Optional · webcam bubble",
        symbol: "camera.fill")
    private let relaunchButton = CCButton(title: "Relaunch to Apply", symbol: "arrow.clockwise", style: .primary)
    private let deniedNote = NSTextField(wrappingLabelWithString: "")

    private let signInButton = CCButton(title: "Sign In with Browser", symbol: "person.crop.circle",
                                        style: .primary, size: .lg)
    private let signInSpinner = CCSpinner()
    private let accountErrorLabel = NSTextField(wrappingLabelWithString: "")
    private let accountCard = AccountCardView()

    private let termsCheckbox = CCCheckbox(title: "I agree to the Terms and Privacy Policy")

    /// Deep links used by the permission rows — exposed for the harness.
    nonisolated static let notificationSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
    nonisolated static let keyboardSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")

    init(appState: AppState) {
        self.appState = appState
        super.init(nibName: nil, bundle: nil)
    }

    /// Harness hook: jump straight to a step by index, no animation.
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
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 600))
        root.wantsLayer = true
        view = root

        leftPanel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(leftPanel)
        stage.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stage)

        spill.translatesAutoresizingMaskIntoConstraints = false
        leftPanel.addSubview(spill)
        pageContainer.translatesAutoresizingMaskIntoConstraints = false
        leftPanel.addSubview(pageContainer)

        footerDivider.translatesAutoresizingMaskIntoConstraints = false
        leftPanel.addSubview(footerDivider)
        for view in [stepIndicator, backButton, nextButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            leftPanel.addSubview(view)
        }
        backButton.onClick = { [weak self] in self?.goBack() }
        nextButton.onClick = { [weak self] in self?.goForward() }
        nextButton.onDisabledClick = { [weak self] in self?.hintRequiredPermission() }
        stepIndicator.onSelect = { [weak self] index in
            guard let self, let target = Step(rawValue: index) else { return }
            self.showStep(target, direction: .backward)
        }

        let footerHeight: CGFloat = 68
        NSLayoutConstraint.activate([
            stage.topAnchor.constraint(equalTo: root.topAnchor),
            stage.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stage.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stage.widthAnchor.constraint(equalTo: root.widthAnchor, multiplier: Self.stageFraction),

            leftPanel.topAnchor.constraint(equalTo: root.topAnchor),
            leftPanel.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            leftPanel.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            leftPanel.trailingAnchor.constraint(equalTo: stage.leadingAnchor),

            spill.topAnchor.constraint(equalTo: leftPanel.topAnchor),
            spill.bottomAnchor.constraint(equalTo: leftPanel.bottomAnchor),
            spill.leadingAnchor.constraint(equalTo: leftPanel.leadingAnchor),
            spill.trailingAnchor.constraint(equalTo: leftPanel.trailingAnchor),

            pageContainer.topAnchor.constraint(equalTo: leftPanel.topAnchor),
            pageContainer.leadingAnchor.constraint(equalTo: leftPanel.leadingAnchor),
            pageContainer.trailingAnchor.constraint(equalTo: leftPanel.trailingAnchor),
            pageContainer.bottomAnchor.constraint(equalTo: footerDivider.topAnchor),

            footerDivider.leadingAnchor.constraint(equalTo: leftPanel.leadingAnchor, constant: 24),
            footerDivider.trailingAnchor.constraint(equalTo: leftPanel.trailingAnchor, constant: -24),
            footerDivider.bottomAnchor.constraint(equalTo: leftPanel.bottomAnchor, constant: -footerHeight),

            stepIndicator.centerXAnchor.constraint(equalTo: leftPanel.centerXAnchor),
            stepIndicator.centerYAnchor.constraint(equalTo: footerDivider.bottomAnchor, constant: footerHeight / 2),
            backButton.leadingAnchor.constraint(equalTo: leftPanel.leadingAnchor, constant: 20),
            backButton.centerYAnchor.constraint(equalTo: stepIndicator.centerYAnchor),
            nextButton.trailingAnchor.constraint(equalTo: leftPanel.trailingAnchor, constant: -24),
            nextButton.centerYAnchor.constraint(equalTo: stepIndicator.centerYAnchor),
            // Never let the footer collide at the narrowest host size.
            stepIndicator.leadingAnchor.constraint(greaterThanOrEqualTo: backButton.trailingAnchor, constant: 8),
            nextButton.leadingAnchor.constraint(greaterThanOrEqualTo: stepIndicator.trailingAnchor, constant: 8),
        ])

        // Live theming: shared chrome re-paints in place; the visible page is
        // rebuilt so its labels pick up the new tokens.
        themeObservation = CCThemeObservation { [weak self] in
            guard let self else { return }
            self.view.layer?.backgroundColor = CCTheme.color.background.cgColor
            if self.currentPage != nil { self.showStep(self.step, direction: .none) }
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
        signInButton.onClick = { [weak self] in
            guard let self, !self.isSigningIn else { return }
            Task { await self.performSignIn() }
        }

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

        guard !Self.harnessMode else { return }
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
                // Coming back from System Settings: re-probe everything so the
                // status pills (and the stage's mirror) flip in place.
                self?.refreshPermissionStates()
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
    /// horizontal hint shake on the button, and a nudge on the row.
    private func hintRequiredPermission() {
        guard step == .permissions else { return }
        if !RecordingMotion.reduceMotion, let layer = nextButton.layer {
            let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
            shake.values = [0, -6, 5, -3, 2, 0]
            shake.duration = 0.4
            shake.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(shake, forKey: "hint-shake")
        }
        screenRow.nudge()
    }

    private func showStep(_ newStep: Step, direction: Direction) {
        let outgoing = currentPage
        step = newStep

        let incoming = buildStep(newStep)
        incoming.translatesAutoresizingMaskIntoConstraints = false
        pageContainer.addSubview(incoming)
        NSLayoutConstraint.activate([
            incoming.topAnchor.constraint(equalTo: pageContainer.topAnchor),
            incoming.leadingAnchor.constraint(equalTo: pageContainer.leadingAnchor),
            incoming.trailingAnchor.constraint(equalTo: pageContainer.trailingAnchor),
            incoming.bottomAnchor.constraint(equalTo: pageContainer.bottomAnchor),
        ])
        currentPage = incoming
        pageContainer.layoutSubtreeIfNeeded()

        let animated = direction != .none && view.window != nil
        if let outgoing {
            if animated && !RecordingMotion.reduceMotion {
                // The old column slips away opposite the travel direction.
                let drift: CGFloat = direction == .forward ? -22 : 22
                outgoing.wantsLayer = true
                if let layer = outgoing.layer {
                    Stage.oneShot(layer, "transform.translation.x", from: 0, to: drift,
                                  duration: 0.24, curve: CCMotion.glide, additive: true)
                    Stage.oneShot(layer, "opacity", from: 1, to: 0, duration: 0.2, curve: CCMotion.glide)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { outgoing.removeFromSuperview() }
            } else {
                outgoing.removeFromSuperview()
            }
        }
        choreographIn(incoming.staggerTargets, direction: direction, baseDelay: animated ? 0.1 : 0.04)

        stage.show(newStep.scene, animated: animated)
        spill.setPalette(OnboardingWallpaper.palette(for: newStep.scene, dark: CCTheme.isDark),
                         animated: animated)
        stepIndicator.index = newStep.rawValue
        refreshAccountUI()
        refreshControls()

        if newStep == .finish, !hasCelebratedFinish {
            hasCelebratedFinish = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
                self?.stage.celebrate()
            }
        }
    }

    /// Sequential reveal: each element arrives ~55ms after the previous,
    /// gliding in along the travel direction (forward = from the right) with
    /// a fade, on the house settle curve. Explicit presentation-only
    /// animations — the model stays put, so an interrupted run can never
    /// strand a view invisible or offset.
    private func choreographIn(_ views: [NSView], direction: Direction, baseDelay: TimeInterval) {
        guard !RecordingMotion.reduceMotion else { return }
        for (index, target) in views.enumerated() {
            target.wantsLayer = true
            guard let layer = target.layer else { continue }
            let delay = baseDelay + Double(index) * 0.055
            switch direction {
            case .forward, .backward:
                let offset: CGFloat = direction == .forward ? 26 : -26
                Stage.oneShot(layer, "transform.translation.x", from: offset, to: 0,
                              duration: 0.62, delay: delay, additive: true)
            case .none:
                Stage.oneShot(layer, "transform.translation.y", from: -12, to: 0,
                              duration: 0.62, delay: delay, additive: true)
            }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = CCMotion.paced(0.38)
            fade.timingFunction = CCMotion.glide
            fade.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
            fade.fillMode = .backwards
            layer.add(fade, forKey: "onboarding.fadeIn")
        }
    }

    // MARK: - Step pages

    private func buildStep(_ step: Step) -> StepPageView {
        switch step {
        case .welcome: return buildWelcomeStep()
        case .permissions: return buildPermissionsStep()
        case .account: return buildAccountStep()
        case .defaultTool: return buildDefaultToolStep()
        case .finish: return buildFinishStep()
        }
    }

    /// The left column: overline, display title, body, then the step's own
    /// controls — a block centred in the panel above the footer, capped at a
    /// readable measure so a wide host (the editor window) never stretches it.
    private func stepPage(
        overline: String, title: String, subtitle: String,
        lead: NSView? = nil, content: [NSView]
    ) -> StepPageView {
        let page = StepPageView()
        let colors = CCTheme.color

        let overlineField = NSTextField(labelWithString: "")
        overlineField.attributedStringValue = NSAttributedString(
            string: overline.uppercased(),
            attributes: [.font: OnboardingType.overline, .foregroundColor: colors.primary,
                         .kern: OnboardingType.overlineKern])

        let titleField = NSTextField(wrappingLabelWithString: title)
        titleField.isSelectable = false
        titleField.attributedStringValue = NSAttributedString(
            string: title,
            attributes: [.font: OnboardingType.display, .foregroundColor: colors.foreground,
                         .kern: OnboardingType.displayTracking])

        let subtitleField = NSTextField(wrappingLabelWithString: subtitle)
        subtitleField.isSelectable = false
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3.5
        subtitleField.attributedStringValue = NSAttributedString(
            string: subtitle,
            attributes: [.font: OnboardingType.body, .foregroundColor: colors.mutedForeground,
                         .paragraphStyle: paragraph])

        var header: [NSView] = [overlineField, titleField, subtitleField]
        if let lead { header.insert(lead, at: 0) }
        let stack = NSStackView(views: header + content)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = CCSpace.md
        if let lead { stack.setCustomSpacing(CCSpace.lg, after: lead) }
        stack.setCustomSpacing(CCSpace.xs + 2, after: overlineField)
        stack.setCustomSpacing(CCSpace.sm + 2, after: titleField)
        stack.setCustomSpacing(CCSpace.lg + 4, after: subtitleField)
        stack.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(stack)

        let preferred = stack.widthAnchor.constraint(equalTo: page.widthAnchor, constant: -96)
        preferred.priority = .defaultHigh
        NSLayoutConstraint.activate([
            preferred,
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 404),
            stack.centerXAnchor.constraint(equalTo: page.centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: page.leadingAnchor, constant: 32),
            stack.centerYAnchor.constraint(equalTo: page.centerYAnchor, constant: 6),
            stack.topAnchor.constraint(greaterThanOrEqualTo: page.topAnchor, constant: 40),
            titleField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            subtitleField.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        for view in content where view.fullWidthInStack {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        page.staggerTargets = header + content
        page.probeStack = stack
        return page
    }

    private func buildWelcomeStep() -> StepPageView {
        let mark = CaptureCatMarkView(height: 50)
        let features = FeatureList(items: [
            ("plus.magnifyingglass", "Automatic zooms that follow every click"),
            ("cursorarrow.motionlines", "Silky cursor, device frames, backgrounds"),
            ("sparkles", "Captions, share links and AI-agent editing"),
        ])
        return stepPage(
            overline: "Welcome",
            title: "Screen recordings that edit themselves",
            subtitle: "CaptureCat turns a raw take into a polished video — no timeline wrangling. A couple of quick permissions and you're rolling.",
            lead: mark,
            content: [features]
        )
    }

    private func buildPermissionsStep() -> StepPageView {
        let card = CCCard()
        for (index, row) in [screenRow, notifRow, micRow, cameraRow].enumerated() {
            if index > 0 { card.addContent(CCDivider()) }
            card.addContent(row)
        }
        card.fullWidthInStack = true

        deniedNote.font = OnboardingType.caption
        deniedNote.textColor = .systemOrange
        deniedNote.isSelectable = true
        deniedNote.fullWidthInStack = true

        let page = stepPage(
            overline: "Permissions",
            title: "A few permissions",
            subtitle: "Screen Recording is required to record. The rest are optional — grant them now or any time later.",
            content: [card, deniedNote, relaunchButton]
        )
        page.staggerTargets = Array(page.staggerTargets.prefix(3)) + [card, deniedNote, relaunchButton]
        return page
    }

    private func buildAccountStep() -> StepPageView {
        signInSpinner.isDisplayedWhenStopped = false
        accountErrorLabel.isSelectable = false
        accountErrorLabel.font = OnboardingType.caption
        accountErrorLabel.textColor = .systemOrange
        accountErrorLabel.isHidden = true
        accountCard.fullWidthInStack = true

        let signInRow = NSStackView(views: [signInButton, signInSpinner])
        signInRow.orientation = .horizontal
        signInRow.spacing = CCSpace.sm

        let perks = FeatureList(items: [
            ("icloud.and.arrow.up", "Projects sync across your Macs"),
            ("link", "Instant share links with transcripts"),
            ("square.and.arrow.up", "Unlimited exports"),
        ])
        return stepPage(
            overline: "Account",
            title: "Sign in to share",
            subtitle: "Sign in to sync your projects and unlock exporting. Prefer to look around first? Skip — you can sign in later from the menu bar.",
            content: [accountCard, signInRow, perks, accountErrorLabel]
        )
    }

    /// Yes/no choice: make CaptureCat the default screenshot tool (global
    /// ⇧⌘3/4/5 — see ScreenshotHotkeys for the macOS caveat).
    private func buildDefaultToolStep() -> StepPageView {
        let yesCard = ChoiceCard(
            title: "Yes, use CaptureCat for screenshots",
            detail: "⇧⌘3, ⇧⌘4 and ⇧⌘5 open CaptureCat instead of macOS.",
            keys: ["⇧", "⌘", "4"])
        let noCard = ChoiceCard(
            title: "No, keep my current screenshot tool",
            detail: nil, keys: [])
        let select = { [weak self] (makeDefault: Bool) in
            guard let self else { return }
            self.appState.isDefaultScreenshotTool = makeDefault
            yesCard.setSelected(makeDefault, animated: true)
            noCard.setSelected(!makeDefault, animated: true)
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
        yesCard.setSelected(appState.isDefaultScreenshotTool, animated: false)
        noCard.setSelected(!appState.isDefaultScreenshotTool, animated: false)
        yesCard.fullWidthInStack = true
        noCard.fullWidthInStack = true

        let settingsLink = CCButton(title: "Open Accessibility Settings", symbol: "accessibility", style: .link)
        settingsLink.onClick = {
            guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
            NSWorkspace.shared.open(url)
        }

        return stepPage(
            overline: "Screenshots",
            title: "Make CaptureCat your screenshot tool?",
            subtitle: "CaptureCat catches ⇧⌘3, ⇧⌘4 and ⇧⌘5 before macOS does — it just needs Accessibility access. You can change this any time in Settings.",
            content: [yesCard, noCard, settingsLink]
        )
    }

    private func buildFinishStep() -> StepPageView {
        let highlights = FeatureList(items: [
            ("record.circle", "Record any time from the CaptureCat icon in your menu bar."),
            ("cursorarrow.rays", "Capture text anywhere: highlight → right-click → Services → Capture Text in CaptureCat."),
            ("doc.on.clipboard", "Or File → New Note from Clipboard (⌥⌘N) — notes live beside recordings."),
        ])
        let terms = CheckboxRow(checkbox: termsCheckbox)
        terms.fullWidthInStack = true

        let page = stepPage(
            overline: "Ready",
            title: "You're all set",
            subtitle: "Here's what CaptureCat can do from day one.",
            content: [highlights, terms]
        )
        page.staggerTargets = Array(page.staggerTargets.prefix(3)) + highlights.rows + [terms]
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
    }

    private func requestAVPermission(for mediaType: AVMediaType) async {
        isRequestingPermissions = true
        refreshControls()
        _ = await requestAVAccess(for: mediaType)
        refreshPermissionStates()
        isRequestingPermissions = false
        refreshControls()
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
        guard !Self.harnessMode || !harnessPermissionsInjected else { return }
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
        stage.update(accountEmail: signedIn ? (appState.currentAccountEmail ?? "you") : nil)
    }

    private func refreshControls() {
        for (row, permission) in [(screenRow, screenPermission), (notifRow, notificationPermission),
                                  (micRow, microphonePermission), (cameraRow, cameraPermission)] {
            row.apply(
                state: permission.label, color: permission.color,
                buttonTitle: permission == .denied ? "Settings" : "Grant",
                showsButton: permission != .granted,
                enabled: !isRequestingPermissions,
                granted: permission == .granted)
        }
        stage.update(permissions: .init(
            screen: screenPermission == .granted,
            notifications: notificationPermission == .granted,
            microphone: microphonePermission == .granted,
            camera: cameraPermission == .granted))

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

        // Back fades with the step. Driven by the INTENDED state, never read
        // back from isHidden: a fade-out interrupted by a quick step change
        // used to leave Back un-hidden at alpha 0 — invisible for good
        // (caught by --onboarding-shot in the editor-window host).
        let showBack = step != .welcome
        if backShown != showBack {
            backShown = showBack
            backButton.isHidden = false
            if view.window != nil {
                CCMotion.run(duration: 0.2, {
                    self.backButton.animator().alphaValue = showBack ? 1 : 0
                }, completion: { [weak self] in
                    guard let self, self.backShown == false else { return }
                    self.backButton.isHidden = true
                })
            } else {
                backButton.alphaValue = showBack ? 1 : 0
                backButton.isHidden = !showBack
            }
        }
        switch step {
        case .welcome:
            nextButton.title = "Get Started"
            nextButton.style = .primary
            nextButton.isEnabled = true
        case .permissions:
            nextButton.title = "Continue"
            nextButton.style = .primary
            nextButton.isEnabled = screenPermission == .granted
        case .account:
            let signedIn = appState.isSignedIn
            nextButton.title = signedIn ? "Continue" : "Skip for Now"
            nextButton.style = signedIn ? .primary : .secondary
            nextButton.isEnabled = true
        case .defaultTool:
            nextButton.title = "Continue"
            nextButton.style = .primary
            nextButton.isEnabled = true
        case .finish:
            nextButton.title = "Start Recording"
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
        guard !Self.harnessMode else { return }
        appState.completeOnboarding(acceptedTerms: termsCheckbox.isOn)
        if let onboardingWindow = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue == "onboarding" }) {
            onboardingWindow.close()
        }
        appState.beginNewRecording()
    }

    // MARK: - Harness seams

    private var harnessPermissionsInjected = false

    /// Inject permission states (harnessMode only) — drives the rows AND the
    /// stage mirror exactly as a real grant would.
    func probeSetPermissions(screen: Bool, notifications: Bool, microphone: Bool, camera: Bool) {
        guard Self.harnessMode else { return }
        harnessPermissionsInjected = true
        screenPermission = screen ? .granted : .unknown
        notificationPermission = notifications ? .granted : .unknown
        microphonePermission = microphone ? .granted : .unknown
        cameraPermission = camera ? .granted : .unknown
        refreshControls()
    }

    func probeAdvance() { goForward() }
    func probeBack() { goBack() }
    var probeStage: OnboardingStageView { stage }
    var probeLeftPanel: NSView { leftPanel }
    var probePage: NSView? { currentPage }
    var probePageStack: NSStackView? { currentPage?.probeStack }
    var probeNextButton: CCButton { nextButton }
    var probeBackButton: CCButton { backButton }
    var probeStepIndicator: CCStepIndicator { stepIndicator }
    var probeStepIndex: Int { step.rawValue }
    var probeScreenRow: NSView { screenRow }
}

// MARK: - Page

/// A single wizard page. Carries the ordered list of views to stagger in.
final class StepPageView: NSView {
    var staggerTargets: [NSView] = []
    var probeStack: NSStackView?
    override var isFlipped: Bool { false }
}

private extension NSView {
    private static var fullWidthKey = 0
    /// Marks a view that should span the content column's full width.
    var fullWidthInStack: Bool {
        get { (objc_getAssociatedObject(self, &Self.fullWidthKey) as? Bool) ?? false }
        set { objc_setAssociatedObject(self, &Self.fullWidthKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }
}

// MARK: - Left-panel palette spill

/// The stage's palette bleeding softly into the content panel from the seam
/// — ties the two halves together; morphs with the wallpaper per step.
/// Layer-hosting (we own the gradient layer outright).
@MainActor
private final class OnboardingSpillView: NSView {
    private let glow = CAGradientLayer()
    private let root = CALayer()

    init() {
        super.init(frame: .zero)
        layer = root
        wantsLayer = true
        glow.type = .radial
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        glow.locations = [0, 1]
        root.addSublayer(glow)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let d = max(newSize.height * 1.3, newSize.width * 1.2)
        glow.bounds = CGRect(x: 0, y: 0, width: d, height: d)
        glow.position = CGPoint(x: newSize.width, y: newSize.height * 0.45)
        CATransaction.commit()
    }

    func setPalette(_ palette: OnboardingWallpaper.Palette, animated: Bool) {
        let tint = palette.fields[0]
        let colors = [tint.withAlphaComponent(CCTheme.isDark ? 0.13 : 0.10).cgColor,
                      tint.withAlphaComponent(0).cgColor]
        if animated {
            CCMotion.fade(glow, keyPath: "colors", to: colors, duration: 0.9)
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            glow.colors = colors
            CATransaction.commit()
        }
    }
}

// MARK: - Key tile

/// A raised kit key holding an SF Symbol in the accent — the icon well used
/// by permission rows and feature lists.
@MainActor
private final class KeyTile: NSView {
    private let icon = NSImageView()
    private var themeObservation: CCThemeObservation?
    private let side: CGFloat

    init(symbol: String, side: CGFloat = 30) {
        self.side = side
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerCurve = .continuous
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: side * 0.43, weight: .semibold)
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: side),
            heightAnchor.constraint(equalToConstant: side),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 0.5),
        ])
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        if let layer { CCMaterial.refit(layer, radius: CCTheme.radius(.md)) }
    }

    private func applyTheme() {
        let colors = CCTheme.color
        icon.contentTintColor = colors.primary
        layer?.backgroundColor = colors.elevated.cgColor
        layer?.cornerRadius = CCTheme.radius(.md)
        if let layer {
            CCMaterial.suppressShadow(layer)
            CCMaterial.dress(layer, as: .raised(tint: colors.elevated), radius: CCTheme.radius(.md))
        }
    }

    /// The "that worked" acknowledgement — a single bouncy pop.
    func pop() {
        guard !RecordingMotion.reduceMotion, let layer else { return }
        CCMotion.recenterAnchor(layer)
        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [1.0, 1.16, 0.97, 1.0]
        pop.keyTimes = [0, 0.38, 0.72, 1]
        pop.duration = 0.42
        pop.timingFunction = CCMotion.settle
        layer.add(pop, forKey: "granted-pop")
    }
}

// MARK: - Feature list

/// Icon-key + text rows (welcome features, account perks, finish tips).
@MainActor
private final class FeatureList: NSView {
    private(set) var rows: [NSView] = []
    private var labels: [NSTextField] = []
    private var themeObservation: CCThemeObservation?

    init(items: [(symbol: String, text: String)]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = CCSpace.sm + 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        for item in items {
            let tile = KeyTile(symbol: item.symbol, side: 26)
            let label = NSTextField(wrappingLabelWithString: item.text)
            label.isSelectable = false
            label.font = .systemFont(ofSize: 12.5)
            label.translatesAutoresizingMaskIntoConstraints = false
            labels.append(label)
            let row = NSView()
            row.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(tile)
            row.addSubview(label)
            NSLayoutConstraint.activate([
                tile.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                tile.topAnchor.constraint(equalTo: row.topAnchor),
                label.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: CCSpace.sm + 2),
                label.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                label.centerYAnchor.constraint(equalTo: tile.centerYAnchor).withPriority(.defaultLow),
                label.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor),
                row.bottomAnchor.constraint(greaterThanOrEqualTo: tile.bottomAnchor),
                row.bottomAnchor.constraint(greaterThanOrEqualTo: label.bottomAnchor),
            ])
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            rows.append(row)
        }
        fullWidthInStack = true
        themeObservation = CCThemeObservation { [weak self] in
            self?.labels.forEach { $0.textColor = CCTheme.color.foreground }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

private extension NSLayoutConstraint {
    func withPriority(_ priority: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}

// MARK: - Permission row

/// One row of the permissions card: key-tile icon, title, one-line why, a
/// Grant key, and a recessed status pill that springs to "Allowed" (green)
/// the moment the grant lands.
@MainActor
private final class PermissionRow: NSView {
    var onGrant: (() -> Void)?

    private let tile: KeyTile
    private let titleField: NSTextField
    private let detailField: NSTextField
    private let grantButton = CCButton(title: "Grant", style: .secondary, size: .sm)
    private let statePill = NSView()
    private let stateDot = NSView()
    private let stateLabel = NSTextField(labelWithString: "")
    private var themeObservation: CCThemeObservation?
    private var wasGranted = false

    init(title: String, detail: String, symbol: String) {
        tile = KeyTile(symbol: symbol)
        titleField = NSTextField(labelWithString: title)
        detailField = NSTextField(labelWithString: detail)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        titleField.font = OnboardingType.rowTitle
        detailField.font = OnboardingType.caption
        detailField.lineBreakMode = .byTruncatingTail
        for view in [tile, titleField, detailField, grantButton, statePill] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        grantButton.onClick = { [weak self] in self?.onGrant?() }
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailField.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)

        statePill.wantsLayer = true
        stateDot.wantsLayer = true
        stateDot.layer?.cornerRadius = 3
        stateDot.translatesAutoresizingMaskIntoConstraints = false
        stateLabel.font = .systemFont(ofSize: 10.5, weight: .semibold)
        stateLabel.translatesAutoresizingMaskIntoConstraints = false
        statePill.addSubview(stateDot)
        statePill.addSubview(stateLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 44),
            tile.leadingAnchor.constraint(equalTo: leadingAnchor),
            tile.centerYAnchor.constraint(equalTo: centerYAnchor),

            titleField.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 11),
            titleField.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: grantButton.leadingAnchor, constant: -8),
            detailField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            detailField.topAnchor.constraint(equalTo: centerYAnchor, constant: 2),
            detailField.trailingAnchor.constraint(lessThanOrEqualTo: grantButton.leadingAnchor, constant: -8),

            grantButton.trailingAnchor.constraint(equalTo: statePill.leadingAnchor, constant: -8),
            grantButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            statePill.trailingAnchor.constraint(equalTo: trailingAnchor),
            statePill.centerYAnchor.constraint(equalTo: centerYAnchor),
            statePill.heightAnchor.constraint(equalToConstant: 22),
            stateDot.leadingAnchor.constraint(equalTo: statePill.leadingAnchor, constant: 9),
            stateDot.centerYAnchor.constraint(equalTo: statePill.centerYAnchor),
            stateDot.widthAnchor.constraint(equalToConstant: 6),
            stateDot.heightAnchor.constraint(equalToConstant: 6),
            stateLabel.leadingAnchor.constraint(equalTo: stateDot.trailingAnchor, constant: 5),
            stateLabel.trailingAnchor.constraint(equalTo: statePill.trailingAnchor, constant: -9),
            stateLabel.centerYAnchor.constraint(equalTo: statePill.centerYAnchor),
        ])
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        if let layer = statePill.layer {
            CCMaterial.refit(layer, radius: CCRadius.full.resolved(for: statePill.bounds.height))
        }
    }

    private func applyTheme() {
        let colors = CCTheme.color
        titleField.textColor = colors.foreground
        detailField.textColor = colors.mutedForeground
        if let layer = statePill.layer {
            layer.cornerRadius = 11
            CCMaterial.dress(layer, as: .recessed(tint: colors.background), radius: 11)
        }
    }

    func apply(state: String, color: NSColor, buttonTitle: String, showsButton: Bool,
               enabled: Bool, granted: Bool) {
        if stateLabel.stringValue != state {
            CCMotion.fadeContentSwap(stateLabel)
            stateLabel.stringValue = state
        }
        stateLabel.textColor = color
        stateDot.layer?.backgroundColor = color.cgColor
        grantButton.title = buttonTitle
        grantButton.isEnabled = enabled
        if grantButton.isHidden == showsButton {
            grantButton.isHidden = !showsButton
            if showsButton, let layer = grantButton.layer, window != nil {
                Stage.oneShot(layer, "opacity", from: 0, to: 1, duration: 0.2)
            }
        }
        if granted && !wasGranted && window != nil {
            tile.pop()
            if let layer = statePill.layer, !RecordingMotion.reduceMotion {
                CCMotion.recenterAnchor(layer)
                Stage.spring(layer, "transform.scale", from: 0.8, to: 1.0, .bouncy)
            }
        }
        wasGranted = granted
    }

    /// Continue-was-clicked-too-soon nudge: the row shakes, its icon pops.
    func nudge() {
        tile.pop()
        guard !RecordingMotion.reduceMotion, let layer else { return }
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shake.values = [0, -5, 4, -2, 0]
        shake.duration = 0.35
        shake.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(shake, forKey: "nudge-shake")
    }
}

// MARK: - Account card

/// Signed-in confirmation — avatar initial, email, and a green check, on a
/// raised matte card.
@MainActor
private final class AccountCardView: NSView {
    private let avatar = NSView()
    private let avatarInitial = NSTextField(labelWithString: "")
    private let emailField = NSTextField(labelWithString: "")
    private let signedInLabel = NSTextField(labelWithString: "Signed in")
    private let check = NSImageView()
    private var themeObservation: CCThemeObservation?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerCurve = .continuous

        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.wantsLayer = true
        avatar.layer?.cornerRadius = 16
        addSubview(avatar)

        avatarInitial.font = .systemFont(ofSize: 14, weight: .bold)
        avatarInitial.textColor = .white
        avatarInitial.alignment = .center
        avatarInitial.translatesAutoresizingMaskIntoConstraints = false
        avatar.addSubview(avatarInitial)

        signedInLabel.font = OnboardingType.caption
        emailField.font = .systemFont(ofSize: 13, weight: .semibold)
        emailField.lineBreakMode = .byTruncatingMiddle
        check.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        check.symbolConfiguration = .init(pointSize: 16, weight: .semibold)
        check.contentTintColor = .systemGreen
        for view in [signedInLabel, emailField, check] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        emailField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 58),
            avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            avatar.centerYAnchor.constraint(equalTo: centerYAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 32),
            avatar.heightAnchor.constraint(equalToConstant: 32),
            avatarInitial.centerXAnchor.constraint(equalTo: avatar.centerXAnchor),
            avatarInitial.centerYAnchor.constraint(equalTo: avatar.centerYAnchor),
            signedInLabel.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 11),
            signedInLabel.bottomAnchor.constraint(equalTo: centerYAnchor, constant: -1),
            emailField.leadingAnchor.constraint(equalTo: signedInLabel.leadingAnchor),
            emailField.topAnchor.constraint(equalTo: centerYAnchor, constant: 0),
            emailField.trailingAnchor.constraint(lessThanOrEqualTo: check.leadingAnchor, constant: -8),
            check.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        if let layer { CCMaterial.refit(layer, radius: CCTheme.radius(.lg)) }
    }

    private func applyTheme() {
        let colors = CCTheme.color
        layer?.backgroundColor = colors.card.cgColor
        layer?.cornerRadius = CCTheme.radius(.lg)
        if let layer { CCMaterial.dress(layer, as: .raisedMatte(tint: colors.card), radius: CCTheme.radius(.lg)) }
        avatar.layer?.backgroundColor = colors.primary.cgColor
        signedInLabel.textColor = colors.mutedForeground
        emailField.textColor = colors.foreground
    }

    func configure(email: String) {
        emailField.stringValue = email
        avatarInitial.stringValue = email.first.map { String($0).uppercased() } ?? "?"
    }
}

// MARK: - Choice card

/// Radio-style choice. Selected = a RAISED key with the accent radio filled;
/// unselected = a quiet recessed well — the material carries selection, no
/// outline ring (kit law). Optional keycaps preview the shortcut.
@MainActor
private final class ChoiceCard: NSControl {
    var onClick: (() -> Void)?

    private let radio = NSView()
    private let radioDot = NSView()
    private let titleField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(wrappingLabelWithString: "")
    private let keys: NSStackView?
    private var isSelected = false
    private var isHovering = false
    private var trackingArea: NSTrackingArea?
    private var themeObservation: CCThemeObservation?

    override var isFlipped: Bool { true }

    init(title: String, detail: String?, keys keyLabels: [String]) {
        keys = keyLabels.isEmpty ? nil : CCKbd.group(keyLabels, size: .sm)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerCurve = .continuous

        radio.translatesAutoresizingMaskIntoConstraints = false
        radio.wantsLayer = true
        radio.layer?.cornerRadius = 9
        radio.layer?.borderWidth = 1.5
        radioDot.translatesAutoresizingMaskIntoConstraints = false
        radioDot.wantsLayer = true
        radioDot.layer?.cornerRadius = 4
        radio.addSubview(radioDot)

        titleField.stringValue = title
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailField.isSelectable = false
        detailField.stringValue = detail ?? ""
        detailField.font = .systemFont(ofSize: 11.5)
        detailField.isHidden = detail == nil

        for view in [radio, titleField, detailField] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        var constraints: [NSLayoutConstraint] = [
            radio.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15),
            radio.topAnchor.constraint(equalTo: titleField.topAnchor, constant: -1),
            radio.widthAnchor.constraint(equalToConstant: 18),
            radio.heightAnchor.constraint(equalToConstant: 18),
            radioDot.centerXAnchor.constraint(equalTo: radio.centerXAnchor),
            radioDot.centerYAnchor.constraint(equalTo: radio.centerYAnchor),
            radioDot.widthAnchor.constraint(equalToConstant: 8),
            radioDot.heightAnchor.constraint(equalToConstant: 8),
            titleField.leadingAnchor.constraint(equalTo: radio.trailingAnchor, constant: 11),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -15),
            titleField.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            detailField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            detailField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -15),
            detailField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 3),
        ]
        var bottomAnchorView: NSView = detail == nil ? titleField : detailField
        if let keys {
            keys.translatesAutoresizingMaskIntoConstraints = false
            addSubview(keys)
            constraints += [
                keys.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
                keys.topAnchor.constraint(equalTo: bottomAnchorView.bottomAnchor, constant: 9),
            ]
            bottomAnchorView = keys
        }
        constraints.append(bottomAnchor.constraint(equalTo: bottomAnchorView.bottomAnchor, constant: 14))
        NSLayoutConstraint.activate(constraints)
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme(animated: false) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        if let layer { CCMaterial.refit(layer, radius: CCTheme.radius(.lg)) }
    }

    func setSelected(_ selected: Bool, animated: Bool) {
        let changed = selected != isSelected
        isSelected = selected
        applyTheme(animated: animated && changed)
        if animated, changed, selected, let dot = radioDot.layer, !RecordingMotion.reduceMotion {
            CCMotion.recenterAnchor(dot)
            Stage.spring(dot, "transform.scale", from: 0.2, to: 1.0, .bouncy)
            if let keys {
                for (i, key) in keys.arrangedSubviews.compactMap({ $0 as? CCKbd }).enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08 * Double(i)) { key.tap() }
                }
            }
        }
    }

    private func applyTheme(animated: Bool) {
        guard let layer else { return }
        let colors = CCTheme.color
        titleField.textColor = colors.foreground
        detailField.textColor = colors.mutedForeground
        layer.cornerRadius = CCTheme.radius(.lg)
        let fill: NSColor = isSelected ? colors.card : colors.background
        let washed = isHovering && !isSelected
            ? (fill.blended(withFraction: 0.04, of: CCTheme.isDark ? .white : .black) ?? fill) : fill
        if animated {
            CCMotion.fade(layer, keyPath: "backgroundColor", to: washed.cgColor, duration: 0.2)
        } else {
            layer.backgroundColor = washed.cgColor
        }
        CCMaterial.dress(layer, as: isSelected ? .raisedMatte(tint: washed) : .recessed(tint: washed),
                         radius: CCTheme.radius(.lg))
        radio.layer?.borderColor = (isSelected ? colors.primary : colors.mutedForeground.withAlphaComponent(0.6)).cgColor
        radio.layer?.backgroundColor = (isSelected ? colors.primary.withAlphaComponent(0.14) : .clear).cgColor
        radioDot.layer?.backgroundColor = colors.primary.cgColor
        radioDot.isHidden = !isSelected
        keys?.alphaValue = isSelected ? 1 : 0.55
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true; applyTheme(animated: true) }
    override func mouseExited(with event: NSEvent) { isHovering = false; applyTheme(animated: true) }
    override func mouseDown(with event: NSEvent) {
        if let layer { CCMaterial.press(layer, down: true) }
    }
    override func mouseUp(with event: NSEvent) {
        if let layer { CCMaterial.press(layer, down: false) }
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

// MARK: - Terms row

/// The terms checkbox on a recessed well — the one step gate on the finish
/// page, so it reads as a deliberate control, not a footnote.
@MainActor
private final class CheckboxRow: NSView {
    private var themeObservation: CCThemeObservation?

    init(checkbox: CCCheckbox) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerCurve = .continuous
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        checkbox.removeFromSuperview()
        addSubview(checkbox)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 44),
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            checkbox.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        themeObservation = CCThemeObservation { [weak self] in
            guard let self, let layer = self.layer else { return }
            layer.cornerRadius = CCTheme.radius(.lg)
            CCMaterial.dress(layer, as: .recessed(tint: CCTheme.color.background), radius: CCTheme.radius(.lg))
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        if let layer { CCMaterial.refit(layer, radius: CCTheme.radius(.lg)) }
    }
}
