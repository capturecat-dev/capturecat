import UIKit

/// CCKit header bar — drawn in-content instead of a UINavigationBar (which
/// renders as system Liquid Glass on iOS 26+; CaptureCat never shows system
/// glass). Pin it to the top of a screen; it extends under the status bar.
///
/// `.large`: a big leading page title + trailing actions (tab roots).
/// `.inline`: a ghost back button, a centered title and trailing actions.
/// `track(scrollView)` fades in a bottom hairline once content scrolls under.
final class CCHeaderBar: UIView {
    enum Style {
        case large
        case inline
    }

    let style: Style
    var onBack: (() -> Void)?

    var title: String {
        get { titleLabel.text ?? "" }
        set {
            titleLabel.text = newValue
            titleLabel.accessibilityLabel = newValue
        }
    }

    var showsBack: Bool = false {
        didSet { backButton.isHidden = !showsBack }
    }

    private let titleLabel: UILabel
    private let backButton = CCButton(symbol: "chevron-left", style: .ghost, size: .regular, radius: .full)
    private let trailing = UIStackView()
    private let leading = UIStackView()
    private let hairline = CCDivider()
    private var offsetObservation: NSKeyValueObservation?
    static let barHeight: CGFloat = 56

    init(title: String, style: Style) {
        self.style = style
        titleLabel = ccLabel(title, font: style == .large ? CCFont.largeTitle : CCFont.header, color: CCTheme.color.foreground,
                             lines: 1, alignment: style == .large ? .natural : .center)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = CCTheme.color.background
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
        titleLabel.accessibilityTraits = .header
        titleLabel.adjustsFontSizeToFitWidth = style == .large
        titleLabel.minimumScaleFactor = 0.75

        backButton.accessibilityLabelOverride = "Back"
        backButton.isHidden = true
        backButton.onTap = { [weak self] in self?.onBack?() }
        leading.spacing = CCSpace.xs
        leading.alignment = .center
        leading.addArrangedSubview(backButton)
        trailing.spacing = CCSpace.xs
        trailing.alignment = .center
        hairline.alpha = 0

        let content = UIView()
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        for view in [leading, titleLabel, trailing, hairline] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        content.addSubview(leading)
        content.addSubview(titleLabel)
        content.addSubview(trailing)
        addSubview(hairline)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            content.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            content.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.barHeight),
            // The bar is exactly one row tall unless big Dynamic Type needs more.
            {
                let fixed = content.heightAnchor.constraint(equalToConstant: Self.barHeight)
                fixed.priority = .defaultHigh
                return fixed
            }(),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            leading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: style == .large ? CCSpace.gutter : CCSpace.sm),
            leading.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            trailing.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -CCSpace.sm - 4),
            trailing.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            titleLabel.topAnchor.constraint(greaterThanOrEqualTo: content.topAnchor, constant: 6),
            titleLabel.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -6),
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        switch style {
        case .large:
            NSLayoutConstraint.activate([
                titleLabel.leadingAnchor.constraint(equalTo: leading.trailingAnchor),
                titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -CCSpace.sm),
            ])
        case .inline:
            let centered = titleLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor)
            centered.priority = .defaultHigh
            titleCentering = centered
            NSLayoutConstraint.activate([
                centered,
                titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leading.trailingAnchor, constant: CCSpace.sm),
                titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -CCSpace.sm),
                titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 60),
            ])
        }
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        accessibilityElements = [backButton, titleLabel, trailing]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// `.inline`: moves the centred title sideways (points; + is right) —
    /// e.g. off a folding display's crease, over the pane it belongs to.
    var titleCenterOffset: CGFloat = 0 {
        didSet { if titleCentering?.constant != titleCenterOffset { titleCentering?.constant = titleCenterOffset } }
    }
    private var titleCentering: NSLayoutConstraint?
    /// Probe seam: the title label (its frame, in gates).
    var probeTitleView: UIView { titleLabel }

    func setTrailing(_ views: [UIView]) {
        trailing.arrangedSubviews.forEach { $0.removeFromSuperview() }
        views.forEach(trailing.addArrangedSubview)
    }

    /// A small view right after the back key (a status dot); nil removes it.
    /// The title keeps clear of it (it sits in the leading group).
    func setLeadingAccessory(_ view: UIView?) {
        leadingAccessory?.removeFromSuperview()
        leadingAccessory = view
        guard let view else { return }
        leading.addArrangedSubview(view)
        accessibilityElements = [backButton, view, titleLabel, trailing]
    }
    private(set) var leadingAccessory: UIView?

    /// Fade the bottom hairline in once `scrollView` content passes under.
    func track(_ scrollView: UIScrollView) {
        offsetObservation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let scrolled = scrollView.contentOffset.y + scrollView.adjustedContentInset.top > 2
                let target: CGFloat = scrolled ? 1 : 0
                if self.hairline.alpha != target {
                    CCMotion.fadeAlpha(self.hairline, to: target, duration: 0.16)
                }
            }
        }
    }
}
