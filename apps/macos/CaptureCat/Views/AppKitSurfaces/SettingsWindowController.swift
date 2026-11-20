import AppKit

// The Settings window — macOS System Settings layout in the house style:
// icon-tile sidebar on the left, one pane of CCCard groups on the right.
// Every control is CCKit (no stock AppKit chrome, CLAUDE.md §1); values
// read/write AppState and CCTheme directly, replacing the checkmark items
// that used to live in the status-item menu.

/// One sidebar entry. Order here is presentation order.
enum SettingsSection: CaseIterable {
    case general
    case recording
    case webCapture
    case appearance
    case account
    case storage

    var title: String {
        switch self {
        case .general: return String(localized: "General", comment: "Settings window: sidebar section name and pane title")
        case .recording: return String(localized: "Recording", comment: "Settings window: sidebar section name and pane title")
        case .webCapture: return String(localized: "Web Capture", comment: "Settings window: sidebar section name and pane title")
        case .appearance: return String(localized: "Appearance", comment: "Settings window: sidebar section name and pane title")
        case .account: return String(localized: "Account", comment: "Settings window: sidebar section name and pane title")
        case .storage: return String(localized: "Storage", comment: "Settings window: sidebar section name and pane title")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .recording: return "record.circle"
        case .webCapture: return "globe"
        case .appearance: return "paintbrush.fill"
        case .account: return "person.crop.circle.fill"
        case .storage: return "externaldrive.fill"
        }
    }

    /// System Settings-style icon tile tint.
    var tint: NSColor {
        switch self {
        case .general: return .systemGray
        case .recording: return .systemRed
        case .webCapture: return .systemBlue
        case .appearance: return .systemIndigo
        case .account: return .systemGreen
        case .storage: return .systemOrange
        }
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    convenience init(
        appState: AppState,
        onCheckForUpdates: @escaping () -> Void,
        onConnectAgents: @escaping () -> Void
    ) {
        let controller = SettingsViewController(
            appState: appState,
            onCheckForUpdates: onCheckForUpdates,
            onConnectAgents: onConnectAgents
        )
        let window = NSWindow(contentViewController: controller)
        // Transparent titlebar + full-size content: the sidebar runs to the
        // window's top edge under the traffic lights, like System Settings.
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = String(localized: "CaptureCat Settings", comment: "Settings window title")
        window.identifier = NSUserInterfaceItemIdentifier("settings")
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 715, height: 470))
        window.center()
        self.init(window: window)
    }

    func present() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class SettingsViewController: NSViewController {
    private let appState: AppState
    private let onCheckForUpdates: () -> Void
    private let onConnectAgents: () -> Void
    /// Settings › Storage talks through this seam: the live API in the app,
    /// a canned fake in `--settings-shot` (the gate never hits the network).
    private let storageClient: StorageBucketClient

    private static let sidebarWidth: CGFloat = 200

    private let sidebar = NSView()
    private let contentHost = NSView()
    private var rows: [SettingsSection: SettingsSidebarRow] = [:]
    private var currentPane: NSView?
    private(set) var selectedSection: SettingsSection = .general
    private var themeObservation: CCThemeObservation?
    private var authObservation: SurfaceObservation?

    init(
        appState: AppState,
        onCheckForUpdates: @escaping () -> Void = {},
        onConnectAgents: @escaping () -> Void = {},
        storageClient: StorageBucketClient = StorageBucketAPI()
    ) {
        self.appState = appState
        self.onCheckForUpdates = onCheckForUpdates
        self.onConnectAgents = onConnectAgents
        self.storageClient = storageClient
        super.init(nibName: nil, bundle: nil)
        // NSWindow(contentViewController:) sizes from this — without it the
        // window collapses to the constraint-fitting height.
        preferredContentSize = NSSize(width: 715, height: 470)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true

        sidebar.wantsLayer = true
        contentHost.wantsLayer = true
        let divider = CCDivider(vertical: true)

        // Sidebar column: window-drag backdrop, "Settings" header under the
        // traffic lights, then one row per section.
        let header = NSTextField(labelWithString: String(localized: "Settings", comment: "Settings window: header above the sidebar sections"))
        header.font = CCTheme.font.title
        let rowStack = NSStackView()
        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 2
        for section in SettingsSection.allCases {
            let row = SettingsSidebarRow(section: section) { [weak self] picked in
                self?.select(section: picked)
            }
            rows[section] = row
            rowStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true
        }

        for view in [header, rowStack] {
            view.translatesAutoresizingMaskIntoConstraints = false
            sidebar.addSubview(view)
        }
        for view in [sidebar, divider, contentHost] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: Self.sidebarWidth),

            header.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: CCSpace.lg),
            // Below the traffic lights the transparent titlebar leaves in place.
            header.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 44),

            rowStack.topAnchor.constraint(equalTo: header.bottomAnchor, constant: CCSpace.md),
            rowStack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: CCSpace.sm),
            rowStack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -CCSpace.sm),

            divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            divider.topAnchor.constraint(equalTo: root.topAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            contentHost.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentHost.topAnchor.constraint(equalTo: root.topAnchor),
            contentHost.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        view = root
        themeObservation = CCThemeObservation { [weak self] in
            guard let self else { return }
            self.sidebar.layer?.backgroundColor = CCTheme.color.background.cgColor
            self.contentHost.layer?.backgroundColor = CCTheme.color.card.cgColor
            header.textColor = CCTheme.color.foreground
        }
        // Sign-in completes asynchronously; rebuild the Account (and Storage,
        // which reloads for the new session) pane in place whenever auth
        // state moves while it is the visible pane.
        authObservation = SurfaceObservation { [weak self] in
            guard let self else { return }
            _ = self.appState.authStateRevision
            _ = self.appState.licence
            if self.selectedSection == .account || self.selectedSection == .storage || self.selectedSection == .recording {
                self.showPane(for: self.selectedSection, animated: false)
            }
        }
        select(section: .general, animated: false)
    }

    /// Sidebar drag = window drag, the System Settings contract.
    override func mouseDown(with event: NSEvent) {
        view.window?.performDrag(with: event)
    }

    func select(section: SettingsSection, animated: Bool = true) {
        selectedSection = section
        for (rowSection, row) in rows { row.isSelected = rowSection == section }
        showPane(for: section, animated: animated)
    }

    private func showPane(for section: SettingsSection, animated: Bool) {
        currentPane?.removeFromSuperview()
        let pane = buildPane(for: section)
        pane.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(pane)
        NSLayoutConstraint.activate([
            pane.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor, constant: CCSpace.xl),
            pane.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor, constant: -CCSpace.xl),
            pane.topAnchor.constraint(equalTo: contentHost.topAnchor, constant: 44),
        ])
        // Storage's form is taller than the window: that pane scrolls, so it
        // takes the full column height instead of hugging its content.
        if pane is StorageSettingsPane {
            pane.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor).isActive = true
        }
        currentPane = pane

        if animated, view.window != nil {
            // Incoming pane fades in and settles up 6pt — quiet, quick.
            pane.wantsLayer = true
            pane.alphaValue = 0
            contentHost.layoutSubtreeIfNeeded()
            if let layer = pane.layer {
                layer.transform = CATransform3DMakeTranslation(0, -6, 0)
                CCMotion.spring(layer, keyPath: "transform.translation.y", to: 0, .smooth)
            }
            CCMotion.run(duration: 0.18, curve: CCMotion.glide) {
                pane.animator().alphaValue = 1
            }
        }
    }

    // MARK: - Panes

    /// Account → Plan: the badge every account surface shows (PlanGate), and
    /// the way to Pro on Free.
    private func planRow() -> NSView {
        let licence = appState.licence
        let badge = CCBadge(licence.badgeTitle, variant: licence.allowsCommercialUse ? .primary : .subtle)
        guard !licence.allowsCommercialUse else {
            return SettingsRow(title: String(localized: "Plan", comment: "Settings ▸ Account: row title for the subscription plan (noun)"), subtitle: String(localized: "Commercial use, and recordings of any length.", comment: "Settings ▸ Account ▸ Plan: subtitle when on Pro"), control: badge)
        }
        let getPro = CCButton(title: String(localized: "Get Pro", comment: "Settings ▸ Account ▸ Plan: button that opens the pricing page"), style: .outline, size: .sm) {
            NSWorkspace.shared.open(PlanGate.pricingURL)
        }
        let controls = NSStackView(views: [badge, getPro])
        controls.orientation = .horizontal
        controls.spacing = 8
        controls.alignment = .centerY
        return SettingsRow(
            title: String(localized: "Plan", comment: "Settings ▸ Account: row title for the subscription plan (noun)"),
            subtitle: String(localized: "Free is for personal use, and each recording stops at 5 minutes.", comment: "Settings ▸ Account ▸ Plan: subtitle when on the Free plan"),
            control: controls
        )
    }

    private func buildPane(for section: SettingsSection) -> NSView {
        if section == .storage {
            return StorageSettingsPane(client: storageClient) { [weak self] in self?.signIn() }
        }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = CCSpace.md

        let title = NSTextField(labelWithString: section.title)
        title.font = CCTheme.font.title
        title.textColor = CCTheme.color.foreground
        stack.addArrangedSubview(title)
        stack.setCustomSpacing(CCSpace.lg, after: title)

        func addCard(_ rows: [NSView]) {
            let card = CCCard()
            for (index, row) in rows.enumerated() {
                if index > 0 { card.addContent(CCDivider()) }
                card.addContent(row)
            }
            stack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        switch section {
        case .general:
            let autoZoom = CCToggle(isOn: appState.autoZoomNewRecordings) { [weak self] on in
                self?.appState.autoZoomNewRecordings = on
            }
            let defaultTool = CCToggle(isOn: appState.isDefaultScreenshotTool) { [weak self] on in
                self?.appState.isDefaultScreenshotTool = on
            }
            addCard([
                SettingsRow(
                    title: String(localized: "Auto zoom new recordings", comment: "Settings ▸ General: toggle row title"),
                    subtitle: String(localized: "Recordings open with zooms already placed. No editing required.", comment: "Settings ▸ General ▸ Auto zoom: row subtitle"),
                    control: autoZoom
                ),
                SettingsRow(
                    title: String(localized: "Default screenshot tool", comment: "Settings ▸ General: toggle row title"),
                    subtitle: String(localized: "Capture with ⇧⌘3/4/5 instead of macOS — needs Accessibility access.", comment: "Settings ▸ General ▸ Default screenshot tool: row subtitle; ⇧⌘3/4/5 are keyboard shortcuts"),
                    control: defaultTool
                ),
                languageRow(),
            ])

        case .recording:
            let countdownValues = [0, 3, 5, 10]
            let countdown = CCSelect(placeholder: String(localized: "Countdown…", comment: "Settings ▸ Recording: countdown picker placeholder"))
            countdown.options = countdownValues.map {
                .init(title: $0 == 0 ? String(localized: "Off", comment: "Settings ▸ Recording ▸ Countdown: option for no countdown") : String(localized: "\($0) seconds", comment: "Settings ▸ Recording ▸ Countdown: option; the number is seconds"))
            }
            countdown.selectedIndex = countdownValues.firstIndex(of: appState.recordingCountdownSeconds) ?? 1
            countdown.onSelect = { [weak self] index in
                self?.appState.recordingCountdownSeconds = countdownValues[index]
            }

            // On Free every recording stops at 5 min (PlanGate): only the
            // lengths it can record are offered, and the cap shows as chosen.
            let licence = appState.licence
            let current = PlanGate.effectiveLimit(userLimit: appState.recordingDurationLimit, licence: licence) ?? 0
            var limitValues: [TimeInterval] = [0, 60, 120, 300, 600]
                .filter { !PlanGate.isProOnlyLimit($0, licence: licence) }
            if !limitValues.contains(current) {
                limitValues.append(current)
            }
            let limit = CCSelect(placeholder: String(localized: "Limit…", comment: "Settings ▸ Recording: maximum duration picker placeholder"))
            limit.options = limitValues.map { seconds in
                if seconds == 0 { return .init(title: String(localized: "No limit", comment: "Settings ▸ Recording ▸ Maximum duration: option for unlimited length")) }
                if seconds.truncatingRemainder(dividingBy: 60) == 0 {
                    return .init(title: String(localized: "\(Int(seconds) / 60) min", comment: "Settings ▸ Recording ▸ Maximum duration: option; the number is minutes, min = minutes abbreviation"))
                }
                return .init(title: String(localized: "\(Int(seconds)) s", comment: "Settings ▸ Recording ▸ Maximum duration: option; the number is seconds, s = seconds abbreviation"))
            }
            limit.selectedIndex = limitValues.firstIndex(of: current)
            limit.onSelect = { [weak self] index in
                self?.appState.setRecordingDurationLimit(limitValues[index])
            }

            addCard([
                SettingsRow(
                    title: String(localized: "Countdown", comment: "Settings ▸ Recording: row title (noun)"),
                    subtitle: String(localized: "Delay before a recording starts.", comment: "Settings ▸ Recording ▸ Countdown: row subtitle"),
                    control: countdown
                ),
                SettingsRow(
                    title: String(localized: "Maximum duration", comment: "Settings ▸ Recording: row title"),
                    subtitle: licence.allowsCommercialUse
                        ? String(localized: "Recordings stop automatically at this length.", comment: "Settings ▸ Recording ▸ Maximum duration: subtitle on Pro")
                        : String(localized: "Recordings stop automatically at this length. Free records up to 5 minutes; Pro removes the limit.", comment: "Settings ▸ Recording ▸ Maximum duration: subtitle on the Free plan; Free and Pro are plan names"),
                    control: limit
                ),
            ])

        case .webCapture:
            let device = CCSelect(placeholder: String(localized: "Device…", comment: "Settings ▸ Web Capture: device picker placeholder"))
            let presets = WebDevicePreset.allCases
            device.options = presets.map { .init(title: $0.title) }
            device.selectedIndex = presets.firstIndex(of: appState.webCaptureDevice)
            device.onSelect = { [weak self] index in
                self?.appState.webCaptureDevice = presets[index]
            }

            let delayValues = [0, 1, 2, 5]
            let delay = CCSelect(placeholder: String(localized: "Delay…", comment: "Settings ▸ Web Capture: capture delay picker placeholder"))
            delay.options = delayValues.map { .init(title: $0 == 0 ? String(localized: "None", comment: "Settings ▸ Web Capture ▸ Capture delay: option for no delay") : String(localized: "\($0) s", comment: "Settings ▸ Web Capture ▸ Capture delay: option; the number is seconds, s = seconds abbreviation")) }
            delay.selectedIndex = delayValues.firstIndex(of: appState.webCaptureOptions.delaySeconds) ?? 0
            delay.onSelect = { [weak self] index in
                self?.appState.webCaptureOptions.delaySeconds = delayValues[index]
            }

            func optionToggle(
                _ keyPath: WritableKeyPath<WebCaptureOptions, Bool>
            ) -> CCToggle {
                CCToggle(isOn: appState.webCaptureOptions[keyPath: keyPath]) { [weak self] on in
                    self?.appState.webCaptureOptions[keyPath: keyPath] = on
                }
            }

            addCard([
                SettingsRow(title: String(localized: "Device", comment: "Settings ▸ Web Capture: row title, the device viewport to emulate"), subtitle: String(localized: "Viewport used for page captures.", comment: "Settings ▸ Web Capture ▸ Device: row subtitle"), control: device),
                SettingsRow(title: String(localized: "Capture delay", comment: "Settings ▸ Web Capture: row title"), subtitle: String(localized: "Wait for lazy-loading content.", comment: "Settings ▸ Web Capture ▸ Capture delay: row subtitle"), control: delay),
            ])
            addCard([
                SettingsRow(title: String(localized: "Dark mode", comment: "Settings ▸ Web Capture: toggle row title"), subtitle: String(localized: "Use the site's dark theme when it has one.", comment: "Settings ▸ Web Capture ▸ Dark mode: row subtitle"),
                            control: optionToggle(\.darkMode)),
                SettingsRow(title: String(localized: "Hide cookie banners", comment: "Settings ▸ Web Capture: toggle row title"), control: optionToggle(\.hideCookieBanners)),
                SettingsRow(title: String(localized: "Hide chat widgets", comment: "Settings ▸ Web Capture: toggle row title"), control: optionToggle(\.hideChatWidgets)),
                SettingsRow(title: String(localized: "Reduce motion", comment: "Settings ▸ Web Capture: toggle row title"), subtitle: String(localized: "Pause page animations before the shot.", comment: "Settings ▸ Web Capture ▸ Reduce motion: row subtitle"),
                            control: optionToggle(\.reduceMotion)),
            ])

        case .appearance:
            let modes: [CCThemeMode] = [.system, .dark, .light]
            let segmented = CCSegmented(
                segments: [
                    String(localized: "System", comment: "Settings ▸ Appearance: segment, follow the macOS appearance"),
                    String(localized: "Dark", comment: "Settings ▸ Appearance: segment, dark theme"),
                    String(localized: "Light", comment: "Settings ▸ Appearance: segment, light theme"),
                ],
                selectedIndex: modes.firstIndex(of: CCTheme.mode) ?? 0
            ) { index in
                CCTheme.setMode(modes[index])
            }
            addCard([
                SettingsRow(
                    title: String(localized: "Appearance", comment: "Settings ▸ Appearance: row title"),
                    subtitle: String(localized: "System follows macOS light and dark switching live.", comment: "Settings ▸ Appearance: row subtitle; System is the segment name"),
                    control: segmented
                ),
            ])

        case .storage:
            break // built by StorageSettingsPane above

        case .account:
            if let email = appState.currentAccountEmail {
                let signOut = CCButton(title: String(localized: "Sign Out", comment: "Settings ▸ Account: button that signs out"), style: .outline, size: .sm) { [weak self] in
                    do { try self?.appState.signOut() } catch {
                        NSApplication.shared.presentError(error)
                    }
                }
                let autoSync = CCToggle(isOn: appState.autoSyncExports) { [weak self] on in
                    self?.appState.autoSyncExports = on
                }
                addCard([
                    SettingsRow(title: email, subtitle: String(localized: "Signed in", comment: "Settings ▸ Account: subtitle under the account email"), control: signOut),
                    planRow(),
                    SettingsRow(title: String(localized: "Sync exports to cloud", comment: "Settings ▸ Account: toggle row title"),
                                subtitle: String(localized: "Automatically upload every export to your library.", comment: "Settings ▸ Account ▸ Sync exports: row subtitle"),
                                control: autoSync),
                ])
            } else {
                let signIn = CCButton(title: String(localized: "Sign In…", comment: "Settings ▸ Account: button that starts sign-in"), style: .primary, size: .sm) { [weak self] in
                    self?.signIn()
                }
                addCard([
                    SettingsRow(title: String(localized: "Not signed in", comment: "Settings ▸ Account: row title when signed out"),
                                subtitle: String(localized: "Sign in to share captures and sync, or to use Pro.", comment: "Settings ▸ Account: row subtitle when signed out; Pro is the plan name"),
                                control: signIn),
                    planRow(),
                ])
            }

            let updates = CCButton(title: String(localized: "Check Now", comment: "Settings ▸ Account ▸ Software updates: button that checks for updates"), style: .secondary, size: .sm) { [weak self] in
                self?.onCheckForUpdates()
            }
            let agents = CCButton(title: String(localized: "Connect…", comment: "Settings ▸ Account ▸ AI agents: button that opens agent setup"), style: .secondary, size: .sm) { [weak self] in
                self?.onConnectAgents()
            }
            let betaToggle = CCToggle(isOn: UpdateChannel.receiveBeta) { on in
                UpdateChannel.receiveBeta = on
            }
            addCard([
                SettingsRow(title: String(localized: "Software updates", comment: "Settings ▸ Account: row title"),
                            subtitle: String(localized: "CaptureCat checks automatically.", comment: "Settings ▸ Account ▸ Software updates: row subtitle"), control: updates),
                SettingsRow(title: String(localized: "Beta updates", comment: "Settings ▸ Account: toggle row title"),
                            subtitle: String(localized: "Get pre-release builds as soon as they ship.", comment: "Settings ▸ Account ▸ Beta updates: row subtitle"),
                            control: betaToggle),
                SettingsRow(title: String(localized: "AI agents", comment: "Settings ▸ Account: row title"),
                            subtitle: String(localized: "Let agents record and edit via MCP.", comment: "Settings ▸ Account ▸ AI agents: row subtitle; MCP is a protocol name"), control: agents),
            ])
        }
        return stack
    }

    private func signIn() {
        Task { @MainActor in
            do { try await appState.signIn() } catch {
                if AuthService.isUserCancellation(error) { return }
                NSApplication.shared.presentError(error)
            }
        }
    }

    // MARK: - Harness seams

    var probeSidebarRows: [SettingsSidebarRow] {
        SettingsSection.allCases.compactMap { rows[$0] }
    }
    var probeCurrentPane: NSView? { currentPane }
}

// MARK: - Sidebar row

/// One System Settings-style sidebar entry: tinted icon tile + label on a
/// wash that answers hover and selection with the house fades.
@MainActor
final class SettingsSidebarRow: NSControl {
    let section: SettingsSection
    private let onPick: (SettingsSection) -> Void

    var isSelected = false {
        didSet { applyTheme(animated: true) }
    }

    private let iconTile = NSView()
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var isHovering = false
    private var trackingArea: NSTrackingArea?
    private var themeObservation: CCThemeObservation?

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 32)
    }

    init(section: SettingsSection, onPick: @escaping (SettingsSection) -> Void) {
        self.section = section
        self.onPick = onPick
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous

        iconTile.wantsLayer = true
        iconTile.layer?.cornerCurve = .continuous
        iconTile.layer?.cornerRadius = 5
        iconTile.layer?.backgroundColor = section.tint.cgColor
        iconView.image = CCIcon.image(section.symbol, pointSize: 11, weight: .medium,
                                      accessibilityDescription: section.title)
        iconView.contentTintColor = .white

        label.stringValue = section.title
        label.font = CCTheme.font.chip
        label.lineBreakMode = .byTruncatingTail

        for view in [iconTile, iconView, label] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(iconTile)
        addSubview(iconView)
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 32),
            iconTile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconTile.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconTile.widthAnchor.constraint(equalToConstant: 20),
            iconTile.heightAnchor.constraint(equalToConstant: 20),
            iconView.centerXAnchor.constraint(equalTo: iconTile.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconTile.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: iconTile.trailingAnchor, constant: CCSpace.sm),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        layer?.cornerRadius = CCTheme.radius(.md)
    }

    private func applyTheme(animated: Bool = false) {
        guard let layer else { return }
        let colors = CCTheme.color
        let fill: NSColor = isSelected ? colors.active : (isHovering ? colors.hover : .clear)
        if animated {
            CCMotion.fade(layer, keyPath: "backgroundColor", to: fill.cgColor)
        } else {
            layer.backgroundColor = fill.cgColor
        }
        label.textColor = colors.foreground
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        applyTheme(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        applyTheme(animated: true)
    }

    override func mouseDown(with event: NSEvent) {
        // Consume so the sidebar's window-drag doesn't swallow the click.
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPick(section)
    }
}

// MARK: - Settings row

/// System Settings row: title (+ optional caption) on the left, one control
/// on the right. Lives inside a CCCard.
// MARK: - Language

extension SettingsViewController {
    /// Settings ▸ General ▸ Language — "System" or one of the catalog's
    /// languages (AppLanguage), the same choice macOS offers per app in
    /// System Settings ▸ General ▸ Language & Region ▸ Applications.
    func languageRow() -> NSView {
        let select = CCSelect(placeholder: String(localized: "Language…", comment: "Settings ▸ General: language picker placeholder"))
        select.options = AppLanguage.languages.map { .init(title: AppLanguage.title(for: $0)) }
        select.selectedIndex = AppLanguage.languages.firstIndex { $0.code == AppLanguage.selectedCode } ?? 0
        select.onSelect = { [weak self] index in
            let language = AppLanguage.languages[index]
            guard language.code != AppLanguage.selectedCode else { return }
            AppLanguage.apply(language.code)
            self?.offerRelaunch(changed: language.code != AppLanguage.launchCode)
        }
        let systemSettings = CCButton(title: String(localized: "Language & Region…", comment: "Settings ▸ General ▸ Language: button that opens macOS System Settings ▸ Language & Region"),
                                      style: .ghost, size: .sm) {
            AppLanguage.openSystemLanguageSettings()
        }
        let controls = NSStackView(views: [systemSettings, select])
        controls.orientation = .horizontal
        controls.spacing = 8
        return SettingsRow(
            title: String(localized: "Language", comment: "Settings ▸ General: row title for the app language"),
            subtitle: String(localized: "System follows your Mac. macOS also lists CaptureCat in System Settings ▸ General ▸ Language & Region ▸ Applications.", comment: "Settings ▸ General ▸ Language: row subtitle; System is the first option; the path names macOS System Settings panes"),
            control: controls
        )
    }

    private func offerRelaunch(changed: Bool) {
        guard changed, let window = view.window else { return }
        let alert = CCAlert(
            title: String(localized: "Relaunch CaptureCat", comment: "Alert title after changing the app language"),
            message: String(localized: "The new language appears the next time CaptureCat opens.", comment: "Alert message after changing the app language")
        )
        alert.addButton(String(localized: "Relaunch Now", comment: "Language alert button: quits and reopens CaptureCat"), role: .primary)
        alert.addButton(String(localized: "Later", comment: "Language alert button: keep using the app in the current language"))
        alert.beginSheet(for: window) { choice in
            if choice == 0 { AppLanguage.relaunch() }
        }
    }
}

@MainActor
final class SettingsRow: NSView {
    private var themeObservation: CCThemeObservation?

    init(title: String, subtitle: String? = nil, control: NSView) {
        super.init(frame: .zero)
        let titleField = NSTextField(labelWithString: title)
        let subtitleField = NSTextField(wrappingLabelWithString: subtitle ?? "")
        subtitleField.isHidden = subtitle == nil

        let textStack = NSStackView(views: [titleField, subtitleField])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2

        for view in [textStack, control] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 34),
            textStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            textStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            control.trailingAnchor.constraint(equalTo: trailingAnchor),
            control.centerYAnchor.constraint(equalTo: centerYAnchor),
            control.leadingAnchor.constraint(greaterThanOrEqualTo: textStack.trailingAnchor, constant: CCSpace.md),
        ])
        themeObservation = CCThemeObservation { [weak self, weak titleField, weak subtitleField] in
            _ = self
            titleField?.font = CCTheme.font.chip
            titleField?.textColor = CCTheme.color.foreground
            subtitleField?.font = CCTheme.font.caption
            subtitleField?.textColor = CCTheme.color.mutedForeground
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
