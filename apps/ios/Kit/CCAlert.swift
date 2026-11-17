import UIKit

// CCKit dialog — the house replacement for UIAlertController (system alerts
// render as Liquid Glass on iOS 26+, which CaptureCat never shows).
//
// A scrim fades over the screen and a FLOATING card settles in above it
// (`CCMotion.Entrance`, `.scaleIn` by default). Buttons are CCButtons.
//
//     let alert = CCAlert(title: "Delete project?", message: "This can't be undone.")
//     alert.addButton("Delete", role: .destructive) { try await api.delete(id) }   // busy + inline error
//     alert.addButton("Cancel", role: .cancel)
//     alert.present(from: self) { index in … }      // 0 = first added
//
// A button with an async `action` shows a spinner while it runs; if it
// throws, the error appears inline (the card grows on the house bounce,
// bottom edge only) and the dialog stays. The first added button is the
// default (Return in prompts); the `.cancel` button (or the last one) is
// what a scrim tap picks.
//
// Confirmation SHEET (`presentation = .sheet`): on compact width the card
// docks to the bottom edge and rises from it, buttons stacked full width
// (actions first, Cancel last), swipe down to cancel; an inline error grows
// its TOP edge (the bottom is pinned). Regular width keeps the centred card.
// Icon, title and message scroll (indicators flash) when the card is
// squeezed — a long message with the keyboard up never clips; the accessory,
// inline error and buttons stay pinned. `setButtonEnabled` holds a button
// disabled (e.g. until a confirmation word is typed).
//
// `symbol` adds an icon tile over the title, tinted by `tone`:
//
//     CCAlert.confirm(title: "Delete clip?", message: "…", confirmTitle: "Delete",
//                     destructive: true, symbol: "trash", presentation: .sheet, from: self)
final class CCAlert {
    enum Role {
        case primary
        case secondary
        case destructive
        case cancel
    }

    struct Button {
        var title: String
        var role: Role
        var action: (() async throws -> Void)?
    }

    enum Tone {
        case standard
        /// The icon tile washes in the destructive ink.
        case destructive
    }

    enum Presentation {
        /// A centred floating card (the default).
        case card
        /// Compact width: docked to the bottom edge, rising from it. Regular
        /// width: the centred card.
        case sheet
    }

    var title: String
    var message: String
    var accessoryView: UIView?
    var entrance: CCMotion.Entrance = .scaleIn
    var presentation: Presentation = .card
    var tone: Tone = .standard
    /// Optional kit icon in a tile above the title.
    var symbol: String?
    /// The prompt's field (set by `prompt`).
    private(set) var textField: CCField?
    private(set) var buttons: [Button] = []
    fileprivate weak var controller: CCAlertController?

    init(title: String, message: String = "") {
        self.title = title
        self.message = message
    }

    @discardableResult
    func addButton(_ title: String, role: Role = .secondary, action: (() async throws -> Void)? = nil) -> CCAlert {
        buttons.append(Button(title: title, role: role, action: action))
        return self
    }

    func present(from presenter: UIViewController, completion: ((Int) -> Void)? = nil) {
        if buttons.isEmpty { buttons = [Button(title: "OK", role: .primary, action: nil)] }
        let controller = CCAlertController(alert: self, completion: completion)
        self.controller = controller
        let top = Self.topmost(from: presenter)
        top.present(controller, animated: false)
    }

    /// Close programmatically (picks the cancel slot).
    func dismiss() { controller?.finish(controller?.cancelIndex ?? 0) }

    /// Indices of buttons that start (and stay) disabled until enabled here —
    /// e.g. a destructive action gated on typing a confirmation word.
    private(set) var disabledButtons: Set<Int> = []

    /// Enable or disable one button (by added order). Works before and after
    /// `present`; a button re-enabled after a failed action stays as set here.
    func setButtonEnabled(_ index: Int, _ enabled: Bool) {
        if enabled { disabledButtons.remove(index) } else { disabledButtons.insert(index) }
        controller?.applyEnabledStates()
    }

    /// Probe seams: the presented card; show an inline error.
    var probeCard: UIView? { controller?.card }
    var probeIsDocked: Bool { controller?.isDocked ?? false }
    var probeButtons: [CCButton] { controller?.probeButtonViews ?? [] }
    func probeShowError(_ text: String) { controller?.showError(text) }
    /// The inline error on screen, or nil while none is shown.
    var probeErrorText: String? { controller?.probeErrorText }
    /// Still on screen (not finishing / dismissed).
    var probeIsPresented: Bool { controller.map { !$0.probeIsFinishing && $0.presentingViewController != nil } ?? false }

    static func topmost(from controller: UIViewController) -> UIViewController {
        var top = controller
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }

    // MARK: - Conveniences

    /// "Are you sure?" — `action` runs with the confirm button busy.
    static func confirm(
        title: String,
        message: String,
        confirmTitle: String,
        destructive: Bool = false,
        symbol: String? = nil,
        presentation: Presentation = .card,
        from presenter: UIViewController,
        action: (() async throws -> Void)? = nil,
        completion: ((Bool) -> Void)? = nil
    ) {
        let alert = CCAlert(title: title, message: message)
        alert.symbol = symbol
        alert.tone = destructive ? .destructive : .standard
        alert.presentation = presentation
        alert.addButton(confirmTitle, role: destructive ? .destructive : .primary, action: action)
        alert.addButton("Cancel", role: .cancel)
        alert.present(from: presenter) { completion?($0 == 0) }
    }

    /// One-line text prompt ("Rename"). `action` receives the trimmed text;
    /// throwing keeps the prompt open with the error inline.
    static func prompt(
        title: String,
        message: String = "",
        placeholder: String,
        initialValue: String = "",
        confirmTitle: String,
        from presenter: UIViewController,
        action: ((String) async throws -> Void)? = nil,
        completion: ((String?) -> Void)? = nil
    ) {
        let alert = CCAlert(title: title, message: message)
        let field = CCField(placeholder: placeholder, value: initialValue)
        field.returnKeyType = .done
        field.autocapitalizationType = .sentences
        // Names often hold product words autocorrect "fixes" — and a pending
        // correction is committed (rewriting the text) the moment the button
        // is tapped. The Mac's fields don't autocorrect either.
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.accessibilityLabel = placeholder
        alert.textField = field
        alert.accessoryView = field
        alert.addButton(confirmTitle, role: .primary) { [weak field] in
            // Commit any in-progress keyboard composition first, so what is
            // saved is exactly what is on screen.
            field?.unmarkText()
            let text = (field?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw CCAlertError.empty(placeholder) }
            try await action?(text)
        }
        alert.addButton("Cancel", role: .cancel)
        alert.present(from: presenter) { [weak field] index in
            let text = (field?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            completion?(index == 0 && !text.isEmpty ? text : nil)
        }
    }
}

enum CCAlertError: LocalizedError {
    case empty(String)

    var errorDescription: String? {
        switch self {
        case .empty(let what): return "\(what) can't be empty."
        }
    }
}

// MARK: - Controller

final class CCAlertController: UIViewController {
    private let alert: CCAlert
    private var completion: ((Int) -> Void)?
    private let scrim = UIView()
    let card = CCCard(floating: true, tint: CCTheme.color.popover, radius: .xl)
    private let stack = UIStackView()
    /// Icon, title and message. They scroll when the sheet is squeezed (a
    /// long message with the keyboard up) — the accessory, error and buttons
    /// stay put, and no text is ever clipped.
    private let textScroll = UIScrollView()
    private let textStack = UIStackView()
    private var flashedOverflow = false
    private let errorLabel = ccLabel("", font: CCFont.caption, color: CCTheme.color.destructive, lines: 0)
    private var buttonViews: [CCButton] = []
    private var isFinishing = false
    private var hasEntered = false
    /// Docked to the bottom edge (a `.sheet` on compact width).
    private(set) lazy var isDocked = alert.presentation == .sheet && traitCollection.horizontalSizeClass != .regular
    var probeButtonViews: [CCButton] { buttonViews }
    var probeErrorText: String? { errorLabel.isHidden ? nil : errorLabel.text }
    var probeIsFinishing: Bool { isFinishing }

    /// Every idle button enabled unless the alert holds it disabled.
    func applyEnabledStates() {
        for (index, button) in buttonViews.enumerated() where !button.isBusy {
            button.isEnabled = !alert.disabledButtons.contains(index)
        }
    }

    var cancelIndex: Int {
        alert.buttons.firstIndex(where: { $0.role == .cancel }) ?? (alert.buttons.count > 1 ? alert.buttons.count - 1 : 0)
    }

    init(alert: CCAlert, completion: ((Int) -> Void)?) {
        self.alert = alert
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalPresentationCapturesStatusBarAppearance = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        scrim.backgroundColor = CCTheme.color.overlay
        scrim.alpha = 0
        scrim.translatesAutoresizingMaskIntoConstraints = false
        scrim.isAccessibilityElement = false
        view.addSubview(scrim)
        scrim.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(scrimTapped)))

        card.alpha = 0
        card.accessibilityViewIsModal = true
        view.addSubview(card)

        let titleLabel = ccLabel(alert.title, font: CCFont.title, color: CCTheme.color.foreground, lines: 0)
        titleLabel.accessibilityTraits = .header
        stack.axis = .vertical
        stack.spacing = CCSpace.sm
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        textStack.axis = .vertical
        textStack.spacing = CCSpace.sm
        textStack.alignment = .fill
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textScroll.translatesAutoresizingMaskIntoConstraints = false
        textScroll.showsHorizontalScrollIndicator = false
        textScroll.alwaysBounceVertical = false
        textScroll.addSubview(textStack)
        // Natural height = the text's; below the labels' compression
        // resistance (750) and the button gap (999), so a squeezed card
        // shortens THIS (it scrolls) instead of clipping a label.
        let natural = textScroll.heightAnchor.constraint(equalTo: textStack.heightAnchor)
        natural.priority = UILayoutPriority(740)
        let floor = textScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 64)
        floor.priority = UILayoutPriority(760)
        NSLayoutConstraint.activate([
            textStack.topAnchor.constraint(equalTo: textScroll.contentLayoutGuide.topAnchor),
            textStack.bottomAnchor.constraint(equalTo: textScroll.contentLayoutGuide.bottomAnchor),
            textStack.leadingAnchor.constraint(equalTo: textScroll.contentLayoutGuide.leadingAnchor),
            textStack.trailingAnchor.constraint(equalTo: textScroll.contentLayoutGuide.trailingAnchor),
            textStack.widthAnchor.constraint(equalTo: textScroll.frameLayoutGuide.widthAnchor),
            natural, floor,
        ])
        stack.addArrangedSubview(textScroll)
        if let symbol = alert.symbol {
            let tone = alert.tone == .destructive ? CCTheme.color.destructive : CCTheme.color.primary
            let tile = CCIconTile(symbol: symbol, side: 44, kind: .recessed, tint: tone.withAlphaComponent(0.14),
                                  iconSize: 19, iconTint: tone, radius: .md)
            let holder = UIView()
            holder.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(tile)
            NSLayoutConstraint.activate([
                tile.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
                tile.topAnchor.constraint(equalTo: holder.topAnchor),
                tile.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            ])
            textStack.addArrangedSubview(holder)
            textStack.setCustomSpacing(CCSpace.md + 2, after: holder)
        }
        textStack.addArrangedSubview(titleLabel)
        if !alert.message.isEmpty {
            textStack.addArrangedSubview(ccLabel(alert.message, font: CCFont.label, color: CCTheme.color.mutedForeground, lines: 0))
        }
        if let accessory = alert.accessoryView {
            stack.setCustomSpacing(CCSpace.md + 2, after: stack.arrangedSubviews.last!)
            stack.addArrangedSubview(accessory)
        }
        errorLabel.isHidden = true
        errorLabel.alpha = 0
        stack.addArrangedSubview(errorLabel)
        card.addSubview(stack)
        let buttonRow = makeButtons()
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(buttonRow)

        // Content is top-pinned, buttons bottom-pinned; this gap defines the
        // natural height (999) so a growth animation can drive the height.
        let gap = buttonRow.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: CCSpace.xl)
        gap.priority = .required - 1
        if isDocked {
            // The sheet: full width (≤ 500), docked over the bottom safe area
            // (riding the keyboard); grows UPWARD.
            let fill = card.widthAnchor.constraint(equalTo: view.safeAreaLayoutGuide.widthAnchor, constant: -CCSpace.sm * 2)
            fill.priority = .required - 1
            let bottom = card.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -CCSpace.sm)
            bottom.priority = .defaultHigh
            NSLayoutConstraint.activate([
                card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                card.widthAnchor.constraint(lessThanOrEqualToConstant: 500),
                fill, bottom,
                card.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: CCSpace.lg),
                card.bottomAnchor.constraint(lessThanOrEqualTo: view.keyboardLayoutGuide.topAnchor, constant: -CCSpace.sm),
            ])
            let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
            view.addGestureRecognizer(pan)
        } else {
            // 999, not 750: button hugging (750) must never out-vote the card's
            // design width (it shrank the card and truncated the message).
            let width = card.widthAnchor.constraint(equalToConstant: 380)
            width.priority = .required - 1
            let centerY = card.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -12)
            centerY.priority = .defaultLow
            NSLayoutConstraint.activate([
                card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                width,
                card.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: CCSpace.xl),
                card.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -CCSpace.xl),
                centerY,
                card.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: CCSpace.lg),
                card.bottomAnchor.constraint(lessThanOrEqualTo: view.keyboardLayoutGuide.topAnchor, constant: -CCSpace.lg),
            ])
        }
        NSLayoutConstraint.activate([
            scrim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrim.topAnchor.constraint(equalTo: view.topAnchor),
            scrim.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: CCSpace.xl),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -CCSpace.xl),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: CCSpace.xl),
            buttonRow.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: CCSpace.xl),
            buttonRow.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -CCSpace.xl),
            buttonRow.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -CCSpace.xl),
            gap,
        ])
        alert.textField?.onReturn = { [weak self] _ in self?.tap(0) }
    }

    private func makeButtons() -> UIView {
        // Buttons in added order; index 0 is the default. Two buttons sit
        // side by side (cancel leading, default trailing); otherwise they stack.
        for (index, spec) in alert.buttons.enumerated() {
            let style: CCButton.Style
            switch spec.role {
            case .primary: style = .primary
            case .destructive: style = .destructive
            case .secondary, .cancel: style = index == 0 ? .primary : .secondary
            }
            let button = CCButton(title: spec.title, style: style, size: .lg, radius: .lg)
            button.onTap = { [weak self] in self?.tap(index) }
            button.isEnabled = !alert.disabledButtons.contains(index)
            buttonViews.append(button)
        }
        let row = UIStackView()
        row.spacing = CCSpace.sm
        row.distribution = .fillEqually
        // Side by side only when both titles fit untruncated.
        let cardWidth = min(380, max(view.bounds.width, 320) - CCSpace.xl * 2) - CCSpace.xl * 2
        let widest = buttonViews.map(\.intrinsicContentSize.width).max() ?? 0
        if isDocked {
            // The sheet: full-width stack, actions first, Cancel at the bottom
            // (nearest the thumb).
            row.axis = .vertical
            let cancel = alert.buttons.indices.filter { alert.buttons[$0].role == .cancel }
            let actions = alert.buttons.indices.filter { alert.buttons[$0].role != .cancel }
            (actions + cancel).forEach { row.addArrangedSubview(buttonViews[$0]) }
        } else if buttonViews.count == 2, widest * 2 + CCSpace.sm <= cardWidth {
            row.axis = .horizontal
            row.addArrangedSubview(buttonViews[1])
            row.addArrangedSubview(buttonViews[0])
        } else {
            row.axis = .vertical
            buttonViews.forEach(row.addArrangedSubview)
        }
        return row
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Squeezed (the keyboard came up): show that the text scrolls.
        let overflows = textScroll.contentSize.height > textScroll.bounds.height + 1
        if overflows, !flashedOverflow, hasEntered {
            flashedOverflow = true
            textScroll.flashScrollIndicators()
        } else if !overflows {
            flashedOverflow = false
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasEntered else { return }
        hasEntered = true
        CCMotion.fadeAlpha(scrim, to: 1, duration: 0.22, from: 0)
        CCMotion.fadeAlpha(card, to: 1, duration: 0.18, from: 0)
        if isDocked {
            if !CCMotion.reduceMotion {
                let travel = view.bounds.height - card.frame.minY
                CCMotion.spring(card.layer, keyPath: "transform.translation.y", from: travel, to: 0, .arrive)
            }
        } else {
            CCMotion.enter(card.layer, alert.entrance)
        }
        if let field = alert.textField {
            _ = field.becomeFirstResponder()
            field.selectAll(nil)
        } else {
            UIAccessibility.post(notification: .screenChanged, argument: card)
        }
    }

    @objc private func scrimTapped() {
        guard !buttonViews.contains(where: \.isBusy) else { return }
        finish(cancelIndex)
    }

    /// The sheet: swipe down to cancel (never while an action is busy).
    @objc private func pan(_ gesture: UIPanGestureRecognizer) {
        guard !isFinishing, !buttonViews.contains(where: \.isBusy) else { return }
        let dy = max(0, gesture.translation(in: view).y)
        switch gesture.state {
        case .changed:
            card.transform = CGAffineTransform(translationX: 0, y: dy)
            scrim.alpha = max(0, 1 - dy / 300)
        case .ended, .cancelled:
            if dy > 90 || gesture.velocity(in: view).y > 800 {
                finish(cancelIndex)
            } else {
                CCMotion.springViews(.snappy, crossFading: view) {
                    self.card.transform = .identity
                    self.scrim.alpha = 1
                }
            }
        default:
            break
        }
    }

    override func accessibilityPerformEscape() -> Bool {
        finish(cancelIndex)
        return true
    }

    private func tap(_ index: Int) {
        guard alert.buttons.indices.contains(index), !isFinishing, !alert.disabledButtons.contains(index) else { return }
        guard let action = alert.buttons[index].action else {
            finish(index)
            return
        }
        let button = buttonViews[index]
        button.isBusy = true
        buttonViews.filter { $0 !== button }.forEach { $0.isEnabled = false }
        Task { @MainActor [weak self] in
            do {
                try await action()
                self?.finish(index)
            } catch {
                guard let self else { return }
                button.isBusy = false
                self.applyEnabledStates()
                self.showError(error.localizedDescription)
            }
        }
    }

    private var topPin: NSLayoutConstraint?

    /// The error line grows in on the house bounce — only the card's BOTTOM
    /// edge moves (the top is pinned from here on); the buttons ride it. A
    /// docked sheet is the mirror image: its bottom is pinned, the TOP grows.
    func showError(_ text: String) {
        CCHaptics.warning()
        alert.textField?.isError = true
        let wasHidden = errorLabel.isHidden
        errorLabel.text = text
        UIAccessibility.post(notification: .announcement, argument: text)
        guard wasHidden else { CCMotion.pop(errorLabel, from: 0.96); return }
        view.layoutIfNeeded()
        if topPin == nil, !isDocked {
            let pin = card.topAnchor.constraint(equalTo: view.topAnchor, constant: card.frame.minY)
            // Below the labels' compression resistance: if the grown card
            // meets the keyboard, the card moves up instead of squashing text.
            pin.priority = UILayoutPriority(700)
            pin.isActive = true
            topPin = pin
        }
        let startHeight = card.bounds.height
        errorLabel.isHidden = false
        let natural = card.systemLayoutSizeFitting(
            CGSize(width: card.bounds.width, height: 0),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        ).height
        // Never taller than the room left (the keyboard may be up): the text
        // scrolls instead of the card fighting its edge constraints.
        let floorY = isDocked ? view.keyboardLayoutGuide.layoutFrame.minY - CCSpace.sm : view.keyboardLayoutGuide.layoutFrame.minY - CCSpace.lg
        let room = floorY - (isDocked ? view.safeAreaLayoutGuide.layoutFrame.minY + CCSpace.lg : card.frame.minY)
        let target = max(startHeight, min(natural, room))
        let height = card.heightAnchor.constraint(equalToConstant: startHeight)
        height.isActive = true
        view.layoutIfNeeded()
        CCMotion.animate(height, to: target, in: view, duration: 0.42, curve: .bounce) {
            height.isActive = false
        }
        CCMotion.fadeAlpha(errorLabel, to: 1, duration: 0.2, delay: 0.1, from: 0)
    }

    func finish(_ index: Int) {
        guard !isFinishing else { return }
        isFinishing = true
        view.endEditing(true)
        if isDocked {
            let travel = view.bounds.height - card.frame.minY
            CCMotion.run(duration: 0.22, curve: .glide) {
                self.card.transform = CGAffineTransform(translationX: 0, y: travel)
            }
        } else {
            CCMotion.exit(card.layer, alert.entrance)
            CCMotion.fadeAlpha(card, to: 0, duration: 0.16)
        }
        CCMotion.fadeAlpha(scrim, to: 0, duration: 0.18)
        DispatchQueue.main.asyncAfter(deadline: .now() + CCMotion.paced(0.18)) { [weak self] in
            guard let self else { return }
            let completion = self.completion
            self.completion = nil
            self.dismiss(animated: false) { completion?(index) }
        }
    }
}
