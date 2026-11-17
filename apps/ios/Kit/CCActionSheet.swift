import UIKit

// CCKit action sheet — the house replacement for UIMenu / context menus /
// action-style alerts (all of which render as system glass on iOS 26+).
//
// Compact width: a floating card of rows rises from the bottom edge (with a
// separate Cancel card), swipe down or tap the scrim to dismiss. Regular
// width: a floating menu card anchored to its source view, scaling in from
// the edge nearest the source. Rows: kit icon · title · check at the FAR
// right; destructive rows in the destructive ink. A pick blinks its row once,
// then the sheet leaves and the handler runs.
//
//     let sheet = CCActionSheet(title: "Onboarding walkthrough")
//     sheet.addAction("Rename", symbol: "pencil") { … }
//     sheet.addAction("Delete", symbol: "trash", destructive: true) { … }
//     sheet.present(from: self, source: button)
final class CCActionSheet {
    struct Item {
        var title: String
        var symbol: String?
        var destructive: Bool
        var checked: Bool
        var handler: () -> Void
    }

    let title: String?
    let message: String?
    private(set) var items: [Item] = []

    init(title: String? = nil, message: String? = nil) {
        self.title = title
        self.message = message
    }

    func addAction(_ title: String, symbol: String? = nil, destructive: Bool = false, checked: Bool = false, handler: @escaping () -> Void) {
        items.append(Item(title: title, symbol: symbol, destructive: destructive, checked: checked, handler: handler))
    }

    func present(from presenter: UIViewController, source: UIView? = nil) {
        let controller = CCActionSheetController(sheet: self, source: source)
        CCAlert.topmost(from: presenter).present(controller, animated: false)
    }
}

final class CCActionSheetController: UIViewController {
    private let sheet: CCActionSheet
    private weak var source: UIView?
    private let scrim = UIView()
    let menuCard = CCCard(floating: true, tint: CCTheme.color.popover, radius: .xl)
    private let cancelCard = CCCard(floating: true, tint: CCTheme.color.popover, radius: .xl)
    private let rows = UIStackView()
    private var isFinishing = false
    private var hasEntered = false
    private var anchored: Bool { traitCollection.horizontalSizeClass == .regular && source != nil }

    init(sheet: CCActionSheet, source: UIView?) {
        self.sheet = sheet
        self.source = source
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        scrim.backgroundColor = CCTheme.color.overlay
        scrim.alpha = 0
        scrim.frame = view.bounds
        scrim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(scrim)
        scrim.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(cancel)))

        rows.axis = .vertical
        rows.translatesAutoresizingMaskIntoConstraints = false
        if sheet.title != nil || sheet.message != nil {
            let header = UIStackView()
            header.axis = .vertical
            header.spacing = 2
            header.isLayoutMarginsRelativeArrangement = true
            header.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 14, leading: 18, bottom: 10, trailing: 18)
            if let title = sheet.title {
                let label = ccLabel(title, font: CCFont.labelSemibold, color: CCTheme.color.foreground, lines: 2)
                label.accessibilityTraits = .header
                header.addArrangedSubview(label)
            }
            if let message = sheet.message {
                header.addArrangedSubview(ccLabel(message, font: CCFont.caption, color: CCTheme.color.mutedForeground, lines: 0))
            }
            rows.addArrangedSubview(header)
            rows.addArrangedSubview(CCDivider())
        }
        for (index, item) in sheet.items.enumerated() {
            let row = CCActionRow(item: item)
            row.onTap = { [weak self] in self?.pick(index, row: row) }
            rows.addArrangedSubview(row)
        }
        menuCard.addSubview(rows)
        menuCard.accessibilityViewIsModal = true
        view.addSubview(menuCard)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: menuCard.leadingAnchor, constant: 6),
            rows.trailingAnchor.constraint(equalTo: menuCard.trailingAnchor, constant: -6),
            rows.topAnchor.constraint(equalTo: menuCard.topAnchor, constant: 6),
            rows.bottomAnchor.constraint(equalTo: menuCard.bottomAnchor, constant: -6),
        ])

        if anchored {
            layoutAnchored()
        } else {
            let cancelRow = CCActionRow(item: .init(title: "Cancel", symbol: nil, destructive: false, checked: false, handler: {}), isCancel: true)
            cancelRow.onTap = { [weak self] in self?.cancel() }
            cancelCard.addSubview(cancelRow)
            cancelRow.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(cancelCard)
            let maxWidth = menuCard.widthAnchor.constraint(lessThanOrEqualToConstant: 440)
            let fill = menuCard.widthAnchor.constraint(equalTo: view.safeAreaLayoutGuide.widthAnchor, constant: -CCSpace.lg * 2)
            fill.priority = .required - 1
            NSLayoutConstraint.activate([
                cancelRow.leadingAnchor.constraint(equalTo: cancelCard.leadingAnchor, constant: 6),
                cancelRow.trailingAnchor.constraint(equalTo: cancelCard.trailingAnchor, constant: -6),
                cancelRow.topAnchor.constraint(equalTo: cancelCard.topAnchor, constant: 6),
                cancelRow.bottomAnchor.constraint(equalTo: cancelCard.bottomAnchor, constant: -6),
                menuCard.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                maxWidth, fill,
                menuCard.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: CCSpace.lg),
                cancelCard.leadingAnchor.constraint(equalTo: menuCard.leadingAnchor),
                cancelCard.trailingAnchor.constraint(equalTo: menuCard.trailingAnchor),
                cancelCard.topAnchor.constraint(equalTo: menuCard.bottomAnchor, constant: CCSpace.sm),
                cancelCard.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -CCSpace.sm),
            ])
            let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
            view.addGestureRecognizer(pan)
        }
        menuCard.alpha = 0
        cancelCard.alpha = 0
    }

    private func layoutAnchored() {
        guard let source else { return }
        let frame = source.convert(source.bounds, to: nil)
        let width: CGFloat = 280
        let below = frame.maxY + 8
        let spaceBelow = view.bounds.height - below - view.safeAreaInsets.bottom
        let x = min(max(frame.midX - width / 2, CCSpace.lg), view.bounds.width - width - CCSpace.lg)
        menuCard.translatesAutoresizingMaskIntoConstraints = false
        var constraints = [
            menuCard.widthAnchor.constraint(equalToConstant: width),
            menuCard.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: x),
        ]
        if spaceBelow > CGFloat(sheet.items.count) * 50 + 40 {
            constraints.append(menuCard.topAnchor.constraint(equalTo: view.topAnchor, constant: below))
        } else {
            constraints.append(menuCard.bottomAnchor.constraint(equalTo: view.topAnchor, constant: frame.minY - 8))
        }
        NSLayoutConstraint.activate(constraints)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasEntered else { return }
        hasEntered = true
        CCMotion.fadeAlpha(scrim, to: anchored ? 0.5 : 1, duration: 0.2, from: 0)
        CCMotion.fadeAlpha(menuCard, to: 1, duration: 0.14, from: 0)
        if anchored {
            CCMotion.enter(menuCard.layer, .scaleIn)
        } else {
            CCMotion.fadeAlpha(cancelCard, to: 1, duration: 0.14, from: 0)
            let travel = view.bounds.height - menuCard.frame.minY
            if !CCMotion.reduceMotion {
                CCMotion.spring(menuCard.layer, keyPath: "transform.translation.y", from: travel, to: 0, .arrive)
                CCMotion.spring(cancelCard.layer, keyPath: "transform.translation.y", from: travel, to: 0, .arrive)
            }
        }
        // Rows stagger in (first eight).
        let rowViews = rows.arrangedSubviews.compactMap { $0 as? CCActionRow }.prefix(8)
        for (i, row) in rowViews.enumerated() {
            CCMotion.fadeAlpha(row, to: 1, duration: 0.18, delay: 0.018 * Double(i), from: 0)
        }
        UIAccessibility.post(notification: .screenChanged, argument: rows.arrangedSubviews.first)
    }

    @objc private func cancel() { leave(then: nil) }

    override func accessibilityPerformEscape() -> Bool { cancel(); return true }

    private func pick(_ index: Int, row: CCActionRow) {
        guard !isFinishing else { return }
        CCHaptics.selection()
        row.blink { [weak self] in
            self?.leave(then: self?.sheet.items[index].handler)
        }
    }

    @objc private func pan(_ gesture: UIPanGestureRecognizer) {
        let dy = max(0, gesture.translation(in: view).y)
        switch gesture.state {
        case .changed:
            menuCard.transform = CGAffineTransform(translationX: 0, y: dy)
            cancelCard.transform = menuCard.transform
            scrim.alpha = max(0, 1 - dy / 300)
        case .ended, .cancelled:
            if dy > 90 || gesture.velocity(in: view).y > 800 {
                leave(then: nil)
            } else {
                CCMotion.springViews(.snappy, crossFading: view) {
                    self.menuCard.transform = .identity
                    self.cancelCard.transform = .identity
                    self.scrim.alpha = 1
                }
            }
        default:
            break
        }
    }

    private func leave(then handler: (() -> Void)?) {
        guard !isFinishing else { return }
        isFinishing = true
        CCMotion.fadeAlpha(scrim, to: 0, duration: 0.18)
        if anchored {
            CCMotion.exit(menuCard.layer, .scaleIn)
            CCMotion.fadeAlpha(menuCard, to: 0, duration: 0.12)
        } else {
            let travel = view.bounds.height - menuCard.frame.minY
            CCMotion.run(duration: 0.22, curve: .glide) {
                self.menuCard.transform = CGAffineTransform(translationX: 0, y: travel)
                self.cancelCard.transform = self.menuCard.transform
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + CCMotion.paced(0.2)) { [weak self] in
            self?.dismiss(animated: false) { handler?() }
        }
    }
}

/// One sheet row: press washes it in place; a pick blinks it once.
final class CCActionRow: UIControl {
    // Keyboard (iPad, Studio 6a): Tab / arrows focus it; Space or Return
    // activates it — the same action a tap sends.
    override var canBecomeFocused: Bool { isEnabled && !isHidden && isUserInteractionEnabled }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if ccIsActivation(presses), isEnabled { sendActions(for: .touchUpInside); return }
        super.pressesEnded(presses, with: event)
    }

    var onTap: (() -> Void)?
    let isCancel: Bool
    private let item: CCActionSheet.Item
    private let wash = UIView()
    private let titleLabel: UILabel
    private let icon: CCIconView?
    private let check: CCIconView?

    init(item: CCActionSheet.Item, isCancel: Bool = false) {
        self.item = item
        self.isCancel = isCancel
        titleLabel = ccLabel(item.title, font: CCFont.bodyMedium, color: CCTheme.color.foreground, lines: 2)
        icon = item.symbol.map { CCIconView($0, pointSize: 17, weight: .medium, tint: CCTheme.color.mutedForeground) }
        check = item.checked ? CCIconView("check", pointSize: 15, weight: .semibold, tint: CCTheme.color.foreground) : nil
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wash.isUserInteractionEnabled = false
        wash.alpha = 0
        wash.layer.cornerCurve = .continuous
        wash.translatesAutoresizingMaskIntoConstraints = false
        addSubview(wash)
        let stack = UIStackView(arrangedSubviews: [icon, titleLabel, check].compactMap { $0 })
        stack.spacing = CCSpace.md
        stack.alignment = .center
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        if isCancel { stack.centerXAnchor.constraint(equalTo: centerXAnchor).isActive = true }
        let leading = stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14)
        leading.priority = isCancel ? .defaultLow : .required
        NSLayoutConstraint.activate([
            wash.leadingAnchor.constraint(equalTo: leadingAnchor), wash.trailingAnchor.constraint(equalTo: trailingAnchor),
            wash.topAnchor.constraint(equalTo: topAnchor), wash.bottomAnchor.constraint(equalTo: bottomAnchor),
            leading,
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 50),
        ])
        if let check {
            check.setContentHuggingPriority(.required, for: .horizontal)
            stack.setCustomSpacing(CCSpace.lg, after: titleLabel)
            // Check at the FAR right.
            check.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14).isActive = true
        }
        isAccessibilityElement = true
        accessibilityLabel = item.title
        accessibilityTraits = item.checked ? [.button, .selected] : .button
        addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .touchUpInside)
        ccOnThemeChange { [weak self] in self?.applyTheme() }
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        wash.layer.cornerRadius = CCRadius.xl.concentric(inset: 6)
    }

    private func applyTheme() {
        wash.backgroundColor = CCTheme.color.active
        let ink = item.destructive ? CCTheme.color.destructive : CCTheme.color.foreground
        titleLabel.textColor = ink
        titleLabel.font = isCancel ? CCFont.header : CCFont.bodyMedium
        titleLabel.textAlignment = isCancel ? .center : .natural
        icon?.tintColor = item.destructive ? CCTheme.color.destructive : CCTheme.color.mutedForeground
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            CCMotion.fadeAlpha(wash, to: isHighlighted ? 1 : 0, duration: isHighlighted ? 0.06 : 0.2)
        }
    }

    /// The pick blink: the wash flashes once, then `done`.
    func blink(_ done: @escaping () -> Void) {
        wash.alpha = 1
        CCMotion.fadeAlpha(wash, to: 0.25, duration: 0.06)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) {
            CCMotion.fadeAlpha(self.wash, to: 1, duration: 0.06)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.07, execute: done)
        }
    }
}
