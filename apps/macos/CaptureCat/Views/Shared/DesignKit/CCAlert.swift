import AppKit

// CCKit dialog — the house replacement for NSAlert.
//
// A dimmed scrim fades over the parent window and a flat elevated card
// springs in above it (Keynote-style settle, no Aqua sheet chrome). Buttons
// are CCButtons, so dialogs share the exact chrome of every other control.
//
// API mirrors NSAlert closely enough that call sites translate 1:1:
//
//     let alert = CCAlert(title: "Delete Note?", message: "This cannot be undone.")
//     alert.addButton("Delete", role: .destructive)
//     alert.addButton("Cancel")
//     alert.beginSheet(for: window) { index in ... }   // 0 = first added
//
// The first added button is the default (Return); Escape picks the last
// button when there is more than one, mirroring NSAlert's cancel slot.

@MainActor
final class CCAlert {
    enum ButtonRole {
        case primary
        case secondary
        case destructive
    }

    var title: String
    var message: String
    /// Optional custom content between the message and the buttons
    /// (e.g. an InspectorFlatTextField for prompts).
    var accessoryView: NSView?
    /// First responder once the card is up (defaults to the accessory view).
    var initialFirstResponder: NSView?
    /// How the card arrives/leaves (`.scaleIn` by default; `.slideUp()`
    /// rises from below — see CCMotion.Entrance). Set before presenting.
    var entrance: CCMotion.Entrance = .scaleIn

    private var buttons: [(title: String, role: ButtonRole)] = []
    private var session: CCAlertSession?

    init(title: String, message: String = "") {
        self.title = title
        self.message = message
    }

    @discardableResult
    func addButton(_ title: String, role: ButtonRole = .secondary) -> CCAlert {
        buttons.append((title, role))
        return self
    }

    /// Present over `window` without blocking; `completion` receives the index
    /// of the chosen button (in `addButton` order).
    func beginSheet(for window: NSWindow, completion: ((Int) -> Void)? = nil) {
        present(over: window, modal: false, completion: completion)
    }

    /// Blocking presentation for call sites that need a synchronous answer.
    /// Centers on the key window when one exists, else on screen.
    @discardableResult
    func runModal() -> Int {
        let parent = NSApp.keyWindow ?? NSApp.mainWindow
        var choice = 0
        present(over: parent, modal: true) { choice = $0 }
        return choice
    }

    private func present(over window: NSWindow?, modal: Bool, completion: ((Int) -> Void)?) {
        if buttons.isEmpty { buttons = [("OK", .primary)] }
        let session = CCAlertSession(alert: self, buttons: buttons, parent: window)
        self.session = session
        session.run(modal: modal) { [weak self] index in
            self?.session = nil
            completion?(index)
        }
    }
}

extension CCAlert {
    /// One-line text prompt ("New Folder", "Rename…"). Completion receives the
    /// trimmed text, or nil on cancel/empty.
    static func prompt(
        title: String,
        message: String = "",
        placeholder: String,
        initialValue: String = "",
        confirmTitle: String,
        in window: NSWindow,
        completion: @escaping (String?) -> Void
    ) {
        let alert = CCAlert(title: title, message: message)
        let field = CCField(placeholder: placeholder, value: initialValue)
        alert.accessoryView = field
        alert.addButton(confirmTitle, role: .primary)
        alert.addButton("Cancel")
        alert.beginSheet(for: window) { index in
            let trimmed = field.stringValue.trimmingCharacters(in: .whitespaces)
            completion(index == 0 && !trimmed.isEmpty ? trimmed : nil)
        }
    }
}

// MARK: - Session (windows, animation, keyboard)

@MainActor
private final class CCAlertSession {
    private let alert: CCAlert
    private let buttons: [(title: String, role: CCAlert.ButtonRole)]
    private weak var parent: NSWindow?

    private let scrim: NSWindow
    private let panel: CCKeyPanel
    private let card = NSView()
    private var keyMonitor: Any?
    private var finished: ((Int) -> Void)?
    private var isModal = false
    /// Keeps the card narrower than the parent window (with a usability
    /// floor) and re-clamps while the parent resizes.
    private var widthClamp: NSLayoutConstraint?
    private var resizeObserver: (any NSObjectProtocol)?

    init(alert: CCAlert, buttons: [(String, CCAlert.ButtonRole)], parent: NSWindow?) {
        self.alert = alert
        self.buttons = buttons.map { (title: $0.0, role: $0.1) }
        self.parent = parent

        scrim = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        scrim.isOpaque = false
        scrim.backgroundColor = .clear
        scrim.hasShadow = false
        scrim.ignoresMouseEvents = false

        panel = CCKeyPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
    }

    func run(modal: Bool, completion: @escaping (Int) -> Void) {
        finished = completion
        isModal = modal
        buildCard()

        let anchor = parent?.frame
            ?? NSScreen.main.map { screen -> NSRect in
                let size = NSSize(width: 640, height: 480)
                return NSRect(
                    x: screen.visibleFrame.midX - size.width / 2,
                    y: screen.visibleFrame.midY - size.height / 2,
                    width: size.width, height: size.height
                )
            } ?? NSRect(x: 0, y: 0, width: 640, height: 480)

        // Scrim covers the parent window exactly. Only for opaque chrome:
        // over a transparent borderless panel (the recording bar) the window
        // frame is invisible, and a rectangle dimming it renders as a gray
        // slab floating on the desktop.
        let parentHasVisibleFrame = parent.map {
            $0.isOpaque || !$0.styleMask.contains(.borderless)
        } ?? false
        if parentHasVisibleFrame {
            let scrimView = NSView(frame: NSRect(origin: .zero, size: anchor.size))
            scrimView.wantsLayer = true
            scrimView.layer?.backgroundColor = CCTheme.color.overlay.cgColor
            scrim.contentView = scrimView
            scrim.setFrame(anchor, display: false)
            scrim.alphaValue = 0
            scrim.level = parent?.level ?? .normal
            parent?.addChildWindow(scrim, ordered: .above)
        }

        // The recording bar floats above normal windows; a normal-level card
        // would open BEHIND it. Match the parent's level so the dialog always
        // sits on top of the window it belongs to.
        panel.level = parent?.level ?? .modalPanel

        // Responsive: never present a card wider than the window it dims.
        // The 340…440 design band still applies when there is room; a floor
        // of 280 keeps the card usable over very small windows.
        if parentHasVisibleFrame {
            let clamp = card.widthAnchor.constraint(
                lessThanOrEqualToConstant: max(280, anchor.width - CCSpace.lg * 2)
            )
            clamp.isActive = true
            widthClamp = clamp
            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: parent, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.parentDidResize() }
            }
        }

        card.layoutSubtreeIfNeeded()
        let size = card.fittingSize
        panel.setContentSize(size)
        var origin = NSPoint(
            x: anchor.midX - size.width / 2,
            y: anchor.midY - size.height / 2 + 20
        )
        if !parentHasVisibleFrame {
            // A slim floating bar: centering would bury the card under it.
            // Hang the card just below the bar (or above, when the bar sits
            // near the bottom edge), keeping it on screen.
            let gap: CGFloat = 12
            let screen = parent?.screen ?? NSScreen.main
            let bounds = screen?.visibleFrame ?? anchor
            origin.y = anchor.minY - gap - size.height
            if origin.y < bounds.minY { origin.y = anchor.maxY + gap }
            origin.x = max(bounds.minX + gap, min(origin.x, bounds.maxX - gap - size.width))
        }
        panel.setFrameOrigin(origin)
        (parent ?? scrim).addChildWindow(panel, ordered: .above)
        panel.alphaValue = 0
        panel.orderFront(nil)
        panel.makeKey()
        if let responder = alert.initialFirstResponder ?? alert.accessoryView {
            panel.makeFirstResponder(responder)
        }

        // Scrim fades while the card plays its entrance (Keynote settle by
        // default; the alert's `entrance` picks slide/fade variants).
        card.wantsLayer = true
        if let layer = card.layer {
            CCMotion.enter(layer, alert.entrance)
        }
        CCMotion.run(duration: 0.22, curve: CCMotion.glide) {
            self.scrim.animator().alphaValue = 1
            self.panel.animator().alphaValue = 1
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 53: // escape → cancel slot
                self.finish(self.buttons.count > 1 ? self.buttons.count - 1 : 0)
                return nil
            case 36, 76: // return → default button, unless typing multiline
                if self.panel.firstResponder is NSTextView,
                   self.alert.accessoryView is NSScrollView { return event }
                self.finish(0)
                return nil
            default:
                return event
            }
        }

        if modal { NSApp.runModal(for: panel) }
    }

    private func buildCard() {
        card.wantsLayer = true
        card.layer?.backgroundColor = CCTheme.color.elevated.cgColor
        // Skeuo: raised material card (no gloss at this size).
        if let layer = card.layer {
            CCMaterial.dress(layer, as: .raisedMatte(tint: CCTheme.color.elevated),
                             radius: CCTheme.radius(.xl))
        }
        card.layer?.cornerRadius = CCTheme.radius(.xl)
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 1
        card.layer?.borderColor = CCTheme.color.border.cgColor
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = 0.5
        card.layer?.shadowRadius = 28
        card.layer?.shadowOffset = CGSize(width: 0, height: -10)

        let titleField = NSTextField(wrappingLabelWithString: alert.title)
        titleField.font = CCTheme.font.title
        titleField.textColor = CCTheme.color.foreground
        titleField.isSelectable = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = CCSpace.sm
        stack.edgeInsets = NSEdgeInsets(
            top: CCSpace.lg, left: CCSpace.lg,
            bottom: CCSpace.lg, right: CCSpace.lg
        )
        stack.addArrangedSubview(titleField)

        if !alert.message.isEmpty {
            let messageField = NSTextField(wrappingLabelWithString: alert.message)
            messageField.font = CCTheme.font.label
            messageField.textColor = CCTheme.color.mutedForeground
            messageField.isSelectable = false
            messageField.preferredMaxLayoutWidth = 296
            stack.addArrangedSubview(messageField)
        }

        if let accessory = alert.accessoryView {
            stack.setCustomSpacing(CCSpace.md, after: stack.arrangedSubviews.last ?? accessory)
            stack.addArrangedSubview(accessory)
            accessory.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -CCSpace.lg * 2).isActive = true
        }

        // Buttons: default (index 0) sits trailing, like every macOS dialog.
        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = CCSpace.sm
        for (index, spec) in buttons.enumerated().reversed() {
            let style: CCButton.Style = switch spec.role {
            case .primary: .primary
            case .secondary: .secondary
            case .destructive: .destructive
            }
            let button = CCButton(title: spec.title, style: index == 0 && spec.role == .secondary ? .primary : style) { [weak self] in
                self?.finish(index)
            }
            buttonRow.addArrangedSubview(button)
        }
        let rowHolder = NSView()
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        rowHolder.addSubview(buttonRow)
        NSLayoutConstraint.activate([
            buttonRow.trailingAnchor.constraint(equalTo: rowHolder.trailingAnchor),
            buttonRow.topAnchor.constraint(equalTo: rowHolder.topAnchor),
            buttonRow.bottomAnchor.constraint(equalTo: rowHolder.bottomAnchor),
            rowHolder.heightAnchor.constraint(equalTo: buttonRow.heightAnchor),
        ])
        stack.setCustomSpacing(CCSpace.lg, after: stack.arrangedSubviews.last ?? rowHolder)
        stack.addArrangedSubview(rowHolder)
        rowHolder.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -CCSpace.lg * 2).isActive = true

        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        // The design band's floor yields (999) to the required parent-width
        // clamp, so a very small window compresses the card instead of
        // breaking constraints.
        let designFloor = card.widthAnchor.constraint(greaterThanOrEqualToConstant: 340)
        designFloor.priority = .init(999)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            designFloor,
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
        ])
        panel.contentView = card
    }

    /// Re-clamp and re-center the card over the parent's new frame.
    private func parentDidResize() {
        guard let parent, finished != nil else { return }
        widthClamp?.constant = max(280, parent.frame.width - CCSpace.lg * 2)
        card.layoutSubtreeIfNeeded()
        let size = card.fittingSize
        panel.setFrame(NSRect(
            x: parent.frame.midX - size.width / 2,
            y: parent.frame.midY - size.height / 2 + 20,
            width: size.width, height: size.height
        ), display: true)
        scrim.setFrame(parent.frame, display: true)
    }

    private func finish(_ index: Int) {
        guard let finished else { return }
        self.finished = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if isModal { NSApp.stopModal() }

        if let layer = card.layer {
            CCMotion.exit(layer, alert.entrance)
        }
        CCMotion.run(duration: 0.16, curve: CCMotion.glide, {
            self.scrim.animator().alphaValue = 0
            self.panel.animator().alphaValue = 0
        }, completion: {
            self.teardown()
            finished(index)
        })
    }

    private func teardown() {
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        resizeObserver = nil
        parent?.removeChildWindow(scrim)
        parent?.removeChildWindow(panel)
        scrim.parent?.removeChildWindow(scrim)
        panel.parent?.removeChildWindow(panel)
        scrim.orderOut(nil)
        panel.orderOut(nil)
        parent?.makeKey()
    }
}

/// Borderless windows refuse key status by default; the dialog needs it for
/// Return/Escape and text-field accessories.
private final class CCKeyPanel: NSWindow {
    override var canBecomeKey: Bool { true }
}
