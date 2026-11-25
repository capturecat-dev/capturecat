import AVFoundation
import UIKit

/// Shared building blocks of the detail screens.

/// A player in a card whose height follows the video's aspect ratio — the
/// first time the real size is known, the BOTTOM edge grows (or tucks) to it
/// on the house bounce; the top never moves.
final class PlayerCard: UIView {
    let player = PlayerView()
    private var heightConstraint: NSLayoutConstraint!
    private var aspect: CGFloat = 9.0 / 16.0
    /// Tallest the player may get, as a fraction of the screen height.
    var maxHeightFraction: CGFloat = 0.6

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        clipsToBounds = true
        layer.cornerCurve = .continuous
        backgroundColor = .black
        player.translatesAutoresizingMaskIntoConstraints = false
        addSubview(player)
        heightConstraint = heightAnchor.constraint(equalToConstant: 200)
        heightConstraint.priority = .required - 1
        NSLayoutConstraint.activate([
            player.leadingAnchor.constraint(equalTo: leadingAnchor),
            player.trailingAnchor.constraint(equalTo: trailingAnchor),
            player.topAnchor.constraint(equalTo: topAnchor),
            player.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightConstraint,
        ])
        player.onPresentationSize = { [weak self] size in self?.setAspect(size.height / size.width, animated: true) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func targetHeight(width: CGFloat) -> CGFloat {
        let screen = window?.windowScene?.screen.bounds.height ?? 800
        return min(max(width * aspect, 160), screen * maxHeightFraction)
    }

    func setAspect(_ ratio: CGFloat, animated: Bool) {
        guard ratio.isFinite, ratio > 0, abs(ratio - aspect) > 0.001 else { return }
        aspect = ratio
        let target = targetHeight(width: bounds.width)
        if animated, window != nil, bounds.width > 0 {
            CCMotion.animate(heightConstraint, to: target, in: superview?.superview ?? superview, duration: 0.42, curve: .bounce)
        } else {
            heightConstraint.constant = target
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = CCTheme.radius(.lg)
        if !CCMotion.isAnimating(heightConstraint), bounds.width > 0 {
            let target = targetHeight(width: bounds.width)
            if abs(heightConstraint.constant - target) > 0.5 { heightConstraint.constant = target }
        }
    }

    // Probe seam.
    var probeHeightConstraint: NSLayoutConstraint { heightConstraint }
}

/// A card of label/value rows ("Duration 2:14").
final class InfoCard: CCCard {
    private let stack = UIStackView()
    private let rows = UIStackView()

    init(title: String? = nil) {
        super.init(radius: .lg)
        stack.axis = .vertical
        rows.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CCSpace.lg),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CCSpace.lg),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: CCSpace.xs),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -CCSpace.xs),
        ])
        if let title {
            let label = ccLabel(title, font: CCFont.labelSemibold, color: CCTheme.color.foreground)
            label.accessibilityTraits = .header
            let wrap = UIStackView(arrangedSubviews: [label])
            wrap.isLayoutMarginsRelativeArrangement = true
            wrap.directionalLayoutMargins = .init(top: CCSpace.md, leading: 0, bottom: CCSpace.xs, trailing: 0)
            stack.addArrangedSubview(wrap)
        }
        stack.addArrangedSubview(rows)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setRows(_ items: [(String, String)]) {
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, row) in items.enumerated() {
            if index > 0 { rows.addArrangedSubview(CCDivider()) }
            let label = ccLabel(row.0, font: CCFont.label, color: CCTheme.color.mutedForeground)
            let value = ccLabel(row.1, font: CCFont.labelMedium, color: CCTheme.color.foreground, lines: 2, alignment: .right)
            label.setContentHuggingPriority(.required, for: .horizontal)
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            let line = UIStackView(arrangedSubviews: [label, value])
            line.spacing = CCSpace.md
            line.alignment = .firstBaseline
            line.isLayoutMarginsRelativeArrangement = true
            line.directionalLayoutMargins = .init(top: 12, leading: 0, bottom: 12, trailing: 0)
            line.isAccessibilityElement = true
            line.accessibilityLabel = String(localized: "\(row.0): \(row.1)", comment: "VoiceOver: an info row; values are its label and its value, e.g. Length: 2:14")
            rows.addArrangedSubview(line)
        }
    }
}

/// Settings-style action rows: kit icon · title · chevron; press washes the
/// row in place; destructive rows in the destructive ink.
final class ActionListCard: CCCard {
    struct Action {
        var title: String
        var symbol: String
        var destructive: Bool = false
        var detail: String? = nil
        /// Instead of the kit symbol: a product's own mark.
        var image: UIImage? = nil
        var handler: (UIView) -> Void
    }

    private let stack = UIStackView()

    init() {
        super.init(radius: .lg)
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setActions(_ actions: [Action]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for action in actions {
            let row = ActionRowControl(action: action)
            stack.addArrangedSubview(row)
        }
    }
}

final class ActionRowControl: UIControl {
    private let wash = UIView()
    private let action: ActionListCard.Action

    init(action: ActionListCard.Action) {
        self.action = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wash.alpha = 0
        wash.backgroundColor = CCTheme.color.active
        wash.layer.cornerCurve = .continuous
        wash.isUserInteractionEnabled = false
        wash.translatesAutoresizingMaskIntoConstraints = false
        addSubview(wash)
        let ink = action.destructive ? CCTheme.color.destructive : CCTheme.color.foreground
        let icon = CCIconView(action.symbol, pointSize: 17, weight: .medium, tint: action.destructive ? CCTheme.color.destructive : CCTheme.color.mutedForeground)
        if let image = action.image {
            icon.image = image
            icon.tintColor = CCTheme.color.foreground
        }
        let title = ccLabel(action.title, font: CCFont.bodyMedium, color: ink, lines: 2)
        let chevron = CCIconView("chevron-right", pointSize: 13, weight: .semibold, tint: CCTheme.color.faintForeground)
        var views: [UIView] = [icon, title]
        if let detail = action.detail {
            let detailLabel = ccLabel(detail, font: CCFont.caption, color: CCTheme.color.mutedForeground)
            detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            views.append(detailLabel)
        }
        views.append(chevron)
        let row = UIStackView(arrangedSubviews: views)
        row.spacing = CCSpace.md
        row.alignment = .center
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addSubview(row)
        NSLayoutConstraint.activate([
            wash.leadingAnchor.constraint(equalTo: leadingAnchor), wash.trailingAnchor.constraint(equalTo: trailingAnchor),
            wash.topAnchor.constraint(equalTo: topAnchor), wash.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 50),
        ])
        isAccessibilityElement = true
        accessibilityLabel = action.title
        accessibilityTraits = .button
        addAction(UIAction { [weak self] _ in
            guard let self else { return }
            CCHaptics.selection()
            self.action.handler(self)
        }, for: .touchUpInside)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        wash.layer.cornerRadius = CCRadius.lg.concentric(inset: 6)
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            CCMotion.fadeAlpha(wash, to: isHighlighted ? 1 : 0, duration: isHighlighted ? 0.06 : 0.22)
        }
    }
}

/// A scrolling detail page: header bar on top, a centered content column
/// (max 720 pt) in a scroll view.
class DetailPageViewController: UIViewController {
    let header: CCHeaderBar
    let scrollView = UIScrollView()
    let column = UIStackView()
    var scrollBottom: NSLayoutConstraint!

    init(title: String) {
        header = CCHeaderBar(title: title, style: .inline)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = CCTheme.color.background
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .interactive
        view.addSubview(scrollView)
        view.addSubview(header)
        column.axis = .vertical
        column.spacing = CCSpace.lg
        column.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(column)
        scrollBottom = scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        scrollBottom.isActive = true
        // The safe area, not the screen: a folded iPhone Duo's trailing strip
        // (status + tab bar) is an inset on one side only.
        let width = column.widthAnchor.constraint(equalTo: view.safeAreaLayoutGuide.widthAnchor, constant: -CCSpace.gutter * 2)
        width.priority = .required - 1
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            column.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: CCSpace.sm),
            column.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -CCSpace.xl),
            column.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: 720),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: CCSpace.gutter),
            width,
        ])
        header.track(scrollView)
        header.onBack = { [weak self] in self?.navigationController?.popViewController(animated: true) }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        header.showsBack = (navigationController?.viewControllers.first).map { $0 !== self } ?? false
    }

    /// A small section heading above a card.
    func sectionLabel(_ text: String) -> UILabel {
        let label = ccLabel(text, font: CCFont.labelSemibold, color: CCTheme.color.mutedForeground)
        label.accessibilityTraits = .header
        return label
    }
}
