import AppKit

// CCKit structured dialog — shadcn's Dialog anatomy in AppKit:
//
//     CCDialog
//     ├─ header   (title + optional subtitle, pinned)
//     ├─ content  (any views; scrolls in place when taller than maxContentHeight)
//     └─ footer   (buttons trailing, pinned)
//
// CCAlert stays the one-liner for confirmations; CCDialog is for real forms
// (export sheet, settings). Presentation reuses the same scrim + spring-in as
// CCAlert via `present(over:)` / `dismiss()`.

@MainActor
final class CCDialog {
    let card = NSView()

    private let headerStack = NSStackView()
    private let contentStack = NSStackView()
    private let footerStack = NSStackView()
    private let scroll = NSScrollView()
    private var contentHeightLimit: NSLayoutConstraint?

    private var scrim: NSWindow?
    private var panel: NSWindow?
    private weak var parent: NSWindow?
    private var keyMonitor: Any?
    /// The width the caller asked for; the card presents at
    /// `min(preferredWidth, parent width − margin)` and re-clamps live while
    /// the parent resizes, so a dialog never overflows a small window.
    private let preferredWidth: CGFloat
    private var widthConstraint: NSLayoutConstraint!
    private var heightClamp: NSLayoutConstraint?
    private var resizeObserver: (any NSObjectProtocol)?
    /// Called when the user presses Escape (nil disables Escape dismissal).
    var onEscape: (() -> Void)?

    /// How the card arrives/leaves (`.scaleIn` Keynote settle by default;
    /// `.slideUp()` rises from below, etc. — see CCMotion.Entrance). Set
    /// before `present(over:)`.
    var entrance: CCMotion.Entrance = .scaleIn

    private let titleField: NSTextField
    private var themeObservation: CCThemeObservation?

    func setTitle(_ title: String) {
        titleField.stringValue = title
    }

    init(title: String, subtitle: String? = nil, width: CGFloat = 430) {
        preferredWidth = width
        card.wantsLayer = true
        card.layer?.cornerRadius = CCTheme.radius(.xl)
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 1
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowRadius = 28
        card.layer?.shadowOffset = CGSize(width: 0, height: -10)

        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = CCSpace.xxs
        titleField = NSTextField(labelWithString: title)
        titleField.font = CCTheme.font.title
        titleField.textColor = CCTheme.color.foreground
        headerStack.addArrangedSubview(titleField)
        if let subtitle {
            let sub = NSTextField(wrappingLabelWithString: subtitle)
            sub.font = CCTheme.font.label
            sub.textColor = CCTheme.color.mutedForeground
            headerStack.addArrangedSubview(sub)
        }

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = CCSpace.md

        footerStack.orientation = .horizontal
        footerStack.spacing = CCSpace.sm

        // Content lives in a scroll view that only engages past the cap.
        // The document view must be constrained to the scroll's contentView —
        // pinned to the scroll itself it never resolves a height and the
        // content simply doesn't render.
        let clipDoc = CCFlippedView()
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        clipDoc.addSubview(contentStack)
        scroll.documentView = clipDoc
        clipDoc.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            clipDoc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            clipDoc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            clipDoc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .automatic

        let footerHolder = NSView()
        footerStack.translatesAutoresizingMaskIntoConstraints = false
        footerHolder.addSubview(footerStack)

        for view in [headerStack, scroll, footerHolder] {
            view.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(view)
        }
        let pad = CCSpace.lg
        widthConstraint = card.widthAnchor.constraint(equalToConstant: width)
        // 999, not required: while presented the card is pinned edge-to-edge
        // to the panel, and the panel's frame is the animated truth — a
        // required width would fight mid-animation frames.
        widthConstraint.priority = .init(999)
        NSLayoutConstraint.activate([
            widthConstraint,

            headerStack.topAnchor.constraint(equalTo: card.topAnchor, constant: pad),
            headerStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: pad),
            headerStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -pad),

            scroll.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: CCSpace.md),
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: pad),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -pad),

            contentStack.topAnchor.constraint(equalTo: clipDoc.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: clipDoc.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: clipDoc.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: clipDoc.bottomAnchor),

            footerHolder.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: CCSpace.md),
            footerHolder.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: pad),
            footerHolder.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -pad),
            footerHolder.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -pad),
            footerHolder.heightAnchor.constraint(equalTo: footerStack.heightAnchor),
            footerStack.trailingAnchor.constraint(equalTo: footerHolder.trailingAnchor),
            footerStack.topAnchor.constraint(equalTo: footerHolder.topAnchor),
        ])

        // Scroll tracks its content height until the cap engages. 490, NOT
        // .defaultHigh: NSWindow's own keep-current-size constraints solve at
        // ~500, so a 750 fit lets any stray layout pass resize the WINDOW to
        // the content — animateContentChange's grow snapped to target before
        // the frame driver's first tick. Below 500 the window frame is the
        // authority and only CCMotion.resize moves it; fittingSize still
        // honors 490 when sizing the card at presentation.
        let fit = scroll.heightAnchor.constraint(equalTo: contentStack.heightAnchor)
        fit.priority = .init(490)
        fit.isActive = true

        themeObservation = CCThemeObservation { [weak self] in
            guard let self else { return }
            self.card.layer?.backgroundColor = CCTheme.color.elevated.cgColor
            self.card.layer?.borderColor = CCTheme.color.border.cgColor
            self.card.layer?.shadowOpacity = CCTheme.isDark ? 0.5 : 0.25
            // Skeuo: the dialog card is raised material (no gloss at this size).
            if let layer = self.card.layer {
                CCMaterial.dress(layer, as: .raisedMatte(tint: CCTheme.color.elevated),
                                 radius: CCTheme.radius(.xl))
            }
            self.titleField.textColor = CCTheme.color.foreground
        }
    }

    // MARK: - Harness seams

    var probeScroll: NSScrollView { scroll }

    // MARK: - Anatomy

    /// Add a view to the scrollable middle. Pass `fullWidth: false` for
    /// controls that size themselves.
    func addContent(_ view: NSView, fullWidth: Bool = true) {
        contentStack.addArrangedSubview(view)
        if fullWidth {
            view.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }
    }

    func addFooter(_ view: NSView) {
        footerStack.addArrangedSubview(view)
    }

    /// Mutate presented content (add/remove/show/hide rows) with the house
    /// growth motion: the TOP edge stays pinned and only the bottom extends
    /// (or contracts), landing on the kit bounce. Existing rows and text
    /// never animate — mutations apply instantly, and the moving bottom edge
    /// simply reveals (or covers) the changed content as it travels. When
    /// the dialog isn't presented the mutations just apply.
    ///
    ///     dialog.animateContentChange { extraRow.isHidden = false }
    func animateContentChange(_ mutations: @escaping () -> Void) {
        mutations()
        guard let panel, parent != nil else { return }
        // NO layoutSubtreeIfNeeded here: with the card pinned to the panel,
        // that walks up to the WINDOW's layout engine, which snaps the frame
        // to the new content size before the driver's first tick — the grow
        // became instant and only the overshoot animated. `fittingSize`
        // solves constraints without performing layout.
        // Dialog content stacks downward, so the bottom is the pushed edge.
        CCMotion.resize(panel, to: card.fittingSize, moving: .bottom)
    }

    /// Content taller than this scrolls in place (nil = grow with content).
    func setMaxContentHeight(_ height: CGFloat?) {
        contentHeightLimit?.isActive = false
        contentHeightLimit = nil
        if let height {
            let limit = scroll.heightAnchor.constraint(lessThanOrEqualToConstant: height)
            limit.isActive = true
            contentHeightLimit = limit
        }
    }

    // MARK: - Presentation (scrim + spring, same feel as CCAlert)

    func present(over window: NSWindow) {
        guard panel == nil else { return }
        parent = window

        let scrimWindow = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        scrimWindow.isOpaque = false
        scrimWindow.backgroundColor = .clear
        scrimWindow.hasShadow = false
        let scrimView = NSView(frame: NSRect(origin: .zero, size: window.frame.size))
        scrimView.wantsLayer = true
        scrimView.layer?.backgroundColor = CCTheme.color.overlay.cgColor
        scrimWindow.contentView = scrimView
        scrimWindow.setFrame(window.frame, display: false)
        scrimWindow.alphaValue = 0
        window.addChildWindow(scrimWindow, ordered: .above)
        scrim = scrimWindow

        let dialogPanel = CCDialogKeyWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        dialogPanel.isOpaque = false
        dialogPanel.backgroundColor = .clear
        dialogPanel.hasShadow = false
        dialogPanel.contentView = card
        // Pin the card to the panel's content area on ALL edges. Without
        // this the card keeps its content-driven size anchored at the
        // window's bottom-left, so an animated resize slides the ENTIRE
        // card with the moving bottom edge (the "bounces everywhere" bug —
        // caught by the growth probe's rowDrift watch). Pinned, the card
        // tracks the window every tick: top content holds still, the footer
        // rides the animated bottom edge, and the scroll middle stretches.
        if let host = card.superview {
            card.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                card.topAnchor.constraint(equalTo: host.topAnchor),
                card.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                card.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                card.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            ])
        }
        panel = dialogPanel
        clampAndCenter(over: window, animated: false)
        window.addChildWindow(dialogPanel, ordered: .above)
        dialogPanel.alphaValue = 0
        dialogPanel.orderFront(nil)
        dialogPanel.makeKey()

        // Track live parent resizes: keep the card clamped inside the window
        // and centered over it. Without this a dialog opened over a large
        // window pokes out of it once the user shrinks the window.
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let parent = self.parent else { return }
                self.clampAndCenter(over: parent, animated: true)
                self.scrim?.setFrame(parent.frame, display: true)
            }
        }

        if let layer = card.layer {
            CCMotion.enter(layer, entrance)
        }
        CCMotion.run(duration: 0.22, curve: CCMotion.glide) {
            scrimWindow.animator().alphaValue = 1
            dialogPanel.animator().alphaValue = 1
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, let onEscape = self.onEscape else { return event }
            onEscape()
            return nil
        }
    }

    /// Fit the card to the parent window (width AND height, with a usability
    /// floor), then center the panel over it. Called at presentation and on
    /// every parent resize.
    private func clampAndCenter(over window: NSWindow, animated: Bool) {
        widthConstraint.constant = max(280, min(preferredWidth, window.frame.width - CCSpace.lg * 2))
        heightClamp?.isActive = false
        let clamp = card.heightAnchor.constraint(
            lessThanOrEqualToConstant: max(220, window.frame.height - CCSpace.lg * 2)
        )
        clamp.isActive = true
        heightClamp = clamp

        card.layoutSubtreeIfNeeded()
        guard let panel else { return }
        let size = card.fittingSize
        let frame = NSRect(
            x: window.frame.midX - size.width / 2,
            y: window.frame.midY - size.height / 2 + 20,
            width: size.width, height: size.height
        )
        if animated {
            CCMotion.animateFrame(of: panel, to: frame, duration: 0.18, curve: CCMotion.glidePoints)
        } else {
            panel.setFrame(frame, display: false)
        }
    }

    func dismiss(completion: (() -> Void)? = nil) {
        guard let panel, let scrim else { completion?(); return }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        resizeObserver = nil
        if let layer = card.layer {
            CCMotion.exit(layer, entrance)
        }
        CCMotion.run(duration: 0.16, curve: CCMotion.glide, {
            scrim.animator().alphaValue = 0
            panel.animator().alphaValue = 0
        }, completion: { [weak self] in
            guard let self else { return }
            self.parent?.removeChildWindow(scrim)
            self.parent?.removeChildWindow(panel)
            scrim.orderOut(nil)
            panel.orderOut(nil)
            self.scrim = nil
            self.panel = nil
            self.parent?.makeKey()
            completion?()
        })
    }
}

private final class CCDialogKeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class CCFlippedView: NSView {
    override var isFlipped: Bool { true }
}
