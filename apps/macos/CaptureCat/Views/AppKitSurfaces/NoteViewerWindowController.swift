import AppKit

/// Minimal note viewer/editor — flat house chrome, an NSTextView for the
/// captured text (autosaved on edit, ProjectStore-style debounce), a meta
/// line (source app + date), a Remind Me pill, and Delete. One window per
/// note; presenting again fronts the existing one.
@MainActor
final class NoteViewerWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [UUID: NoteViewerWindowController] = [:]

    static func present(note: Note, appState: AppState) {
        if let existing = open[note.id] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = NoteViewerWindowController(note: note, appState: appState)
        open[note.id] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private let note: Note
    private let appState: AppState
    private let textView = NSTextView()
    private let metaLabel = NSTextField(labelWithString: "")
    private let remindButton = HoverPillButton(title: "Remind Me", symbol: "bell")
    private let deleteButton = HoverPillButton(title: "Delete", symbol: "trash")
    private var saveTask: Task<Void, Never>?

    // Retheme chrome live; fires once at init and on every theme change.
    private var themeObservation: CCThemeObservation?
    private let icon = NSImageView()
    private let hairline = NSView()

    private init(note: Note, appState: AppState) {
        self.note = note
        self.appState = appState

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = note.title
        window.minSize = NSSize(width: 320, height: 240)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        buildContent(in: window)
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func buildContent(in window: NSWindow) {
        let root = NSView()
        root.wantsLayer = true
        window.contentView = root

        // Header: note icon + meta line + actions.
        icon.image = NSImage(
            systemSymbolName: "note.text", accessibilityDescription: "Note"
        ) ?? NSImage()
        icon.symbolConfiguration = .init(pointSize: 14, weight: .medium)
        icon.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(icon)

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        var meta = formatter.string(from: note.createdAt)
        if let app = note.sourceAppName { meta = "\(app) · \(meta)" }
        metaLabel.font = .systemFont(ofSize: 11)
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.stringValue = meta
        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(metaLabel)

        remindButton.translatesAutoresizingMaskIntoConstraints = false
        remindButton.onClick = { [weak self] in self?.showReminderMenu() }
        root.addSubview(remindButton)

        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.onClick = { [weak self] in self?.promptDelete() }
        root.addSubview(deleteButton)

        hairline.translatesAutoresizingMaskIntoConstraints = false
        hairline.wantsLayer = true
        root.addSubview(hairline)

        // Text editor.
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        textView.string = note.text
        textView.font = .systemFont(ofSize: 13)
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        scroll.documentView = textView
        root.addSubview(scroll)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: remindButton.centerYAnchor),

            metaLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            metaLabel.centerYAnchor.constraint(equalTo: remindButton.centerYAnchor),
            metaLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: remindButton.leadingAnchor, constant: -10),

            deleteButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            deleteButton.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 8),
            remindButton.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -8),
            remindButton.centerYAnchor.constraint(equalTo: deleteButton.centerYAnchor),

            hairline.topAnchor.constraint(equalTo: deleteButton.bottomAnchor, constant: 8),
            hairline.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1),

            scroll.topAnchor.constraint(equalTo: hairline.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        refreshReminderButton()
    }

    /// All chrome colors in one place so init and theme changes share a path.
    private func applyTheme() {
        window?.backgroundColor = EditorThemeKit.windowBackground
        window?.contentView?.layer?.backgroundColor = EditorThemeKit.windowBackground.cgColor
        icon.contentTintColor = EditorThemeKit.effectBlockTop
        metaLabel.textColor = EditorThemeKit.textSecondary
        hairline.layer?.backgroundColor = EditorThemeKit.hairline.cgColor
        textView.textColor = EditorThemeKit.textPrimary
        textView.insertionPointColor = EditorThemeKit.textPrimary
    }

    private func refreshReminderButton() {
        remindButton.toolTip = ReminderCenter.badgeText(for: note.reminderDate)
            .map { "Reminder \($0)" } ?? "Set a reminder for this note"
    }

    private func showReminderMenu() {
        let menu = NSMenu()
        let items = ReminderCenter.reminderMenuItems(
            currentDate: note.reminderDate,
            makeItem: { title, handler in
                ProjectBrowserViewController.closureItem(title, handler: handler)
            },
            set: { [weak self] date in self?.setReminder(date) },
            pickCustom: { [weak self] in
                guard let self else { return }
                ReminderCenter.promptCustomDate(
                    in: self.window, current: self.note.reminderDate
                ) { picked in
                    if let picked { self.setReminder(picked) }
                }
            },
            clear: { [weak self] in
                guard let self else { return }
                self.note.reminderDate = nil
                self.appState.noteStore.save(self.note)
                ReminderCenter.shared.cancelReminder(for: self.note.id)
                self.refreshReminderButton()
            }
        )
        // Present the submenu contents directly under the button.
        if let submenu = items.first?.submenu {
            CaptureCatMenuPresenter.show(submenu, from: remindButton, edge: .below)
        }
        _ = menu
    }

    private func setReminder(_ date: Date) {
        note.reminderDate = date
        appState.noteStore.save(note)
        ReminderCenter.shared.scheduleReminder(
            id: note.id, title: note.title, kind: .note, date: date
        ) { [weak self] granted in
            guard let self else { return }
            if !granted { Self.showNotificationsDeniedAlert(in: self.window) }
            self.refreshReminderButton()
        }
    }

    /// Shared "notifications are off" explainer.
    static func showNotificationsDeniedAlert(in window: NSWindow?) {
        let alert = CCAlert(
            title: "Notifications Are Off",
            message: "The reminder date was saved, but macOS notifications are "
                + "disabled for CaptureCat. Enable them in System Settings → Notifications "
                + "to be reminded."
        )
        alert.addButton("OK", role: .primary)
        if let window {
            alert.beginSheet(for: window)
        } else {
            alert.runModal()
        }
    }

    private func promptDelete() {
        guard let window else { return }
        let alert = CCAlert(
            title: "Delete Note?",
            message: "Are you sure you want to delete \"\(note.title)\"? This cannot be undone."
        )
        alert.addButton("Delete", role: .destructive)
        alert.addButton("Cancel")
        alert.beginSheet(for: window) { [weak self] index in
            guard index == 0, let self else { return }
            self.saveTask?.cancel()
            self.appState.noteStore.delete(self.note)
            self.close()
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Flush any pending edit immediately.
        saveTask?.cancel()
        if note.text != textView.string {
            note.text = textView.string
            note.modifiedAt = Date()
            appState.noteStore.save(note)
        }
        Self.open[note.id] = nil
    }
}

extension NoteViewerWindowController: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            self.note.text = self.textView.string
            self.note.modifiedAt = Date()
            self.appState.noteStore.save(self.note)
            self.window?.title = self.note.title
        }
    }
}
