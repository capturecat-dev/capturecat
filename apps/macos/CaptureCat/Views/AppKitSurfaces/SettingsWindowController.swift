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

    var title: String {
        switch self {
        case .general: return "General"
        case .recording: return "Recording"
        case .webCapture: return "Web Capture"
        case .appearance: return "Appearance"
        case .account: return "Account"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .recording: return "record.circle"
        case .webCapture: return "globe"
        case .appearance: return "paintbrush.fill"
        case .account: return "person.crop.circle.fill"
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
        window.title = "CaptureCat Settings"
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
        onConnectAgents: @escaping () -> Void = {}
    ) {
        self.appState = appState
        self.onCheckForUpdates = onCheckForUpdates
        self.onConnectAgents = onConnectAgents
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
        let header = NSTextField(labelWithString: "Settings")
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
        // Sign-in completes asynchronously; rebuild the Account pane in place
        // whenever auth state moves while it is the visible pane.
        authObservation = SurfaceObservation { [weak self] in
            guard let self else { return }
            _ = self.appState.authStateRevision
            if self.selectedSection == .account {
                self.showPane(for: .account, animated: false)
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

    private func buildPane(for section: SettingsSection) -> NSView {
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
                    title: "Auto zoom new recordings",
                    subtitle: "Recordings open with zooms already placed. No editing required.",
                    control: autoZoom
                ),
                SettingsRow(
                    title: "Default screenshot tool",
                    subtitle: "Capture with ⇧⌘3/4/5 instead of macOS — needs Accessibility access.",
                    control: defaultTool
                ),
            ])

        case .recording:
            let countdownValues = [0, 3, 5, 10]
            let countdown = CCSelect(placeholder: "Countdown…")
            countdown.options = countdownValues.map {
                .init(title: $0 == 0 ? "Off" : "\($0) seconds")
            }
            countdown.selectedIndex = countdownValues.firstIndex(of: appState.recordingCountdownSeconds) ?? 1
            countdown.onSelect = { [weak self] index in
                self?.appState.recordingCountdownSeconds = countdownValues[index]
            }

            var limitValues: [TimeInterval] = [0, 60, 120, 300, 600]
            if !limitValues.contains(appState.recordingDurationLimit) {
                limitValues.append(appState.recordingDurationLimit)
            }
            let limit = CCSelect(placeholder: "Limit…")
            limit.options = limitValues.map { seconds in
                if seconds == 0 { return .init(title: "No limit") }
                if seconds.truncatingRemainder(dividingBy: 60) == 0 {
                    return .init(title: "\(Int(seconds) / 60) min")
                }
                return .init(title: "\(Int(seconds)) s")
            }
            limit.selectedIndex = limitValues.firstIndex(of: appState.recordingDurationLimit)
            limit.onSelect = { [weak self] index in
                self?.appState.recordingDurationLimit = limitValues[index]
            }

            addCard([
                SettingsRow(
                    title: "Countdown",
                    subtitle: "Delay before a recording starts.",
                    control: countdown
                ),
                SettingsRow(
                    title: "Maximum duration",
                    subtitle: "Recordings stop automatically at this length.",
                    control: limit
                ),
            ])

        case .webCapture:
            let device = CCSelect(placeholder: "Device…")
            let presets = WebDevicePreset.allCases
            device.options = presets.map { .init(title: $0.title) }
            device.selectedIndex = presets.firstIndex(of: appState.webCaptureDevice)
            device.onSelect = { [weak self] index in
                self?.appState.webCaptureDevice = presets[index]
            }

            let delayValues = [0, 1, 2, 5]
            let delay = CCSelect(placeholder: "Delay…")
            delay.options = delayValues.map { .init(title: $0 == 0 ? "None" : "\($0) s") }
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
                SettingsRow(title: "Device", subtitle: "Viewport used for page captures.", control: device),
                SettingsRow(title: "Capture delay", subtitle: "Wait for lazy-loading content.", control: delay),
            ])
            addCard([
                SettingsRow(title: "Dark mode", subtitle: "Use the site's dark theme when it has one.",
                            control: optionToggle(\.darkMode)),
                SettingsRow(title: "Hide cookie banners", control: optionToggle(\.hideCookieBanners)),
                SettingsRow(title: "Hide chat widgets", control: optionToggle(\.hideChatWidgets)),
                SettingsRow(title: "Reduce motion", subtitle: "Pause page animations before the shot.",
                            control: optionToggle(\.reduceMotion)),
            ])

        case .appearance:
            let modes: [CCThemeMode] = [.system, .dark, .light]
            let segmented = CCSegmented(
                segments: ["System", "Dark", "Light"],
                selectedIndex: modes.firstIndex(of: CCTheme.mode) ?? 0
            ) { index in
                CCTheme.setMode(modes[index])
            }
            addCard([
                SettingsRow(
                    title: "Appearance",
                    subtitle: "System follows macOS light and dark switching live.",
                    control: segmented
                ),
            ])

        case .account:
            if let email = appState.currentAccountEmail {
                let signOut = CCButton(title: "Sign Out", style: .outline, size: .sm) { [weak self] in
                    do { try self?.appState.signOut() } catch {
                        NSApplication.shared.presentError(error)
                    }
                }
                let autoSync = CCToggle(isOn: appState.autoSyncExports) { [weak self] on in
                    self?.appState.autoSyncExports = on
                }
                addCard([
                    SettingsRow(title: email, subtitle: "Signed in", control: signOut),
                    SettingsRow(title: "Sync exports to cloud",
                                subtitle: "Automatically upload every export to your library.",
                                control: autoSync),
                ])
            } else {
                let signIn = CCButton(title: "Sign In…", style: .primary, size: .sm) { [weak self] in
                    guard let self else { return }
                    Task { @MainActor in
                        do { try await self.appState.signIn() } catch {
                            if AuthService.isUserCancellation(error) { return }
                            NSApplication.shared.presentError(error)
                        }
                    }
                }
                addCard([
                    SettingsRow(title: "Not signed in",
                                subtitle: "Sign in to share captures and sync.",
                                control: signIn),
                ])
            }

            let updates = CCButton(title: "Check Now", style: .secondary, size: .sm) { [weak self] in
                self?.onCheckForUpdates()
            }
            let agents = CCButton(title: "Connect…", style: .secondary, size: .sm) { [weak self] in
                self?.onConnectAgents()
            }
            let betaToggle = CCToggle(isOn: UpdateChannel.receiveBeta) { on in
                UpdateChannel.receiveBeta = on
            }
            addCard([
                SettingsRow(title: "Software updates",
                            subtitle: "CaptureCat checks automatically.", control: updates),
                SettingsRow(title: "Beta updates",
                            subtitle: "Get pre-release builds as soon as they ship.",
                            control: betaToggle),
                SettingsRow(title: "AI agents",
                            subtitle: "Let agents record and edit via MCP.", control: agents),
            ])
        }
        return stack
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
        iconView.image = NSImage(systemSymbolName: section.symbol, accessibilityDescription: section.title)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
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
