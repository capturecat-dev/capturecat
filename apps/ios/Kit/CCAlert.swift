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

    var title: String
    var message: String
    var accessoryView: UIView?
    var entrance: CCMotion.Entrance = .scaleIn
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

    /// Probe seams: the presented card; show an inline error.
    var probeCard: UIView? { controller?.card }
    func probeShowError(_ text: String) { controller?.showError(text) }

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
        from presenter: UIViewController,
        action: (() async throws -> Void)? = nil,
        completion: ((Bool) -> Void)? = nil
    ) {
        let alert = CCAlert(title: title, message: message)
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
    private let errorLabel = ccLabel("", font: CCFont.caption, color: CCTheme.color.destructive, lines: 0)
    private var buttonViews: [CCButton] = []
    private var isFinishing = false
    private var hasEntered = false

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
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(titleLabel)
        if !alert.message.isEmpty {
            stack.addArrangedSubview(ccLabel(alert.message, font: CCFont.label, color: CCTheme.color.mutedForeground, lines: 0))
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

        // 999, not 750: button hugging (750) must never out-vote the card's
        // design width (it shrank the card and truncated the message).
        let width = card.widthAnchor.constraint(equalToConstant: 380)
        width.priority = .required - 1
        let centerY = card.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -12)
        centerY.priority = .defaultLow
        // Content is top-pinned, buttons bottom-pinned; this gap defines the
        // natural height (999) so a growth animation can drive the height.
        let gap = buttonRow.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: CCSpace.xl)
        gap.priority = .required - 1
        NSLayoutConstraint.activate([
            scrim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrim.topAnchor.constraint(equalTo: view.topAnchor),
            scrim.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            width,
            card.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: CCSpace.xl),
            card.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -CCSpace.xl),
            centerY,
            card.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: CCSpace.lg),
            card.bottomAnchor.constraint(lessThanOrEqualTo: view.keyboardLayoutGuide.topAnchor, constant: -CCSpace.lg),
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
            buttonViews.append(button)
        }
        let row = UIStackView()
        row.spacing = CCSpace.sm
        row.distribution = .fillEqually
        // Side by side only when both titles fit untruncated.
        let cardWidth = min(380, max(view.bounds.width, 320) - CCSpace.xl * 2) - CCSpace.xl * 2
        let widest = buttonViews.map(\.intrinsicContentSize.width).max() ?? 0
        if buttonViews.count == 2, widest * 2 + CCSpace.sm <= cardWidth {
            row.axis = .horizontal
            row.addArrangedSubview(buttonViews[1])
            row.addArrangedSubview(buttonViews[0])
        } else {
            row.axis = .vertical
            buttonViews.forEach(row.addArrangedSubview)
        }
        return row
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasEntered else { return }
        hasEntered = true
        CCMotion.fadeAlpha(scrim, to: 1, duration: 0.22, from: 0)
        CCMotion.fadeAlpha(card, to: 1, duration: 0.18, from: 0)
        CCMotion.enter(card.layer, alert.entrance)
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

    override func accessibilityPerformEscape() -> Bool {
        finish(cancelIndex)
        return true
    }

    private func tap(_ index: Int) {
        guard alert.buttons.indices.contains(index), !isFinishing else { return }
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
                self.buttonViews.forEach { $0.isEnabled = true }
                self.showError(error.localizedDescription)
            }
        }
    }

    private var topPin: NSLayoutConstraint?

    /// The error line grows in on the house bounce — only the card's BOTTOM
    /// edge moves (the top is pinned from here on); the buttons ride it.
    func showError(_ text: String) {
        CCHaptics.warning()
        alert.textField?.isError = true
        let wasHidden = errorLabel.isHidden
        errorLabel.text = text
        UIAccessibility.post(notification: .announcement, argument: text)
        guard wasHidden else { CCMotion.pop(errorLabel, from: 0.96); return }
        view.layoutIfNeeded()
        if topPin == nil {
            let pin = card.topAnchor.constraint(equalTo: view.topAnchor, constant: card.frame.minY)
            // Below the labels' compression resistance: if the grown card
            // meets the keyboard, the card moves up instead of squashing text.
            pin.priority = UILayoutPriority(700)
            pin.isActive = true
            topPin = pin
        }
        let startHeight = card.bounds.height
        errorLabel.isHidden = false
        let target = card.systemLayoutSizeFitting(
            CGSize(width: card.bounds.width, height: 0),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        ).height
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
        CCMotion.exit(card.layer, alert.entrance)
        CCMotion.fadeAlpha(card, to: 0, duration: 0.16)
        CCMotion.fadeAlpha(scrim, to: 0, duration: 0.18)
        DispatchQueue.main.asyncAfter(deadline: .now() + CCMotion.paced(0.18)) { [weak self] in
            guard let self else { return }
            let completion = self.completion
            self.completion = nil
            self.dismiss(animated: false) { completion?(index) }
        }
    }
}
