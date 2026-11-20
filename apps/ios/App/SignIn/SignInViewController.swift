import UIKit

/// Signed out — drawn like the Mac's onboarding steps: an accent eyebrow, a
/// semibold title, a short paragraph, feature rows on recessed icon tiles,
/// and ONE primary action. Sign-in runs in the secure web sheet
/// (AuthService); a failure shows inline under the button (the error line
/// grows in on the bounce, bottom edge only) — never a system alert.
final class SignInViewController: UIViewController {
    private let mark = UIImageView()
    private let markHost = CCSurface(.raised, tint: .black, radius: .lg)
    private let eyebrow = UILabel()
    private let titleLabel = ccLabel(String(localized: "Sign in to your library", comment: "Sign-in screen title"), font: CCFont.scaled(28, .semibold, .title1, max: 38), color: CCTheme.color.foreground, lines: 0)
    private let body = ccLabel(String(localized: "Your recordings from your Mac and the web, on your \(ThisDevice.noun) — watch them, share them, and capture new ones that open straight in the editor.", comment: "Argument is iPhone or iPad"),
                               font: CCFont.body, color: CCTheme.color.mutedForeground, lines: 0)
    private let signInButton = CCButton(title: String(localized: "Sign in", comment: "Button"), style: .primary, size: .lg, radius: .lg)
    private let errorLabel = ccLabel("", font: CCFont.label, color: CCTheme.color.destructive, lines: 0)
    private let footnote = ccLabel(String(localized: "Opens a secure sign-in page. New to CaptureCat? Create a free account there."),
                                   font: CCFont.caption, color: CCTheme.color.mutedForeground, lines: 0)
    private let stack = UIStackView()
    private var errorHeight: NSLayoutConstraint!
    private var hasEntered = false
    private var topPin: NSLayoutConstraint?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = CCTheme.color.background

        mark.image = Self.appMark()
        mark.contentMode = .scaleAspectFill
        mark.clipsToBounds = true
        mark.layer.cornerCurve = .continuous
        mark.layer.cornerRadius = CCTheme.radius(.lg)
        mark.translatesAutoresizingMaskIntoConstraints = false
        mark.isAccessibilityElement = false
        markHost.addSubview(mark)

        eyebrow.attributedText = NSAttributedString(string: "CAPTURECAT", attributes: [
            .kern: 1.6, .font: CCFont.scaled(12, .semibold, .caption1, max: 16), .foregroundColor: CCTheme.color.primary,
        ])
        eyebrow.adjustsFontForContentSizeCategory = true
        titleLabel.accessibilityTraits = .header
        signInButton.onTap = { [weak self] in self?.signIn() }
        signInButton.accessibilityHint = String(localized: "Opens a secure sign-in page", comment: "Accessibility hint for the Sign in button")

        let features = UIStackView(arrangedSubviews: [
            feature("cloud-upload", String(localized: "Projects sync with your Mac and the web", comment: "Sign-in screen feature list")),
            feature("wifi", String(localized: "Stream this \(ThisDevice.noun) to your Mac — no cable", comment: "Sign-in screen feature list; argument is iPhone or iPad")),
            feature("link", String(localized: "Share links with time-pinned comments", comment: "Sign-in screen feature list")),
        ])
        features.axis = .vertical
        features.spacing = CCSpace.md

        errorLabel.alpha = 0
        let errorHost = UIView()
        errorHost.clipsToBounds = true
        errorHost.translatesAutoresizingMaskIntoConstraints = false
        errorHost.addSubview(errorLabel)
        errorHeight = errorHost.heightAnchor.constraint(equalToConstant: 0)
        errorHeight.isActive = true

        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = CCSpace.sm
        stack.translatesAutoresizingMaskIntoConstraints = false
        let markRow = UIStackView(arrangedSubviews: [markHost, UIView()])
        for item in [markRow, eyebrow, titleLabel, body, features, signInButton, errorHost, footnote] as [UIView] { stack.addArrangedSubview(item) }
        stack.setCustomSpacing(CCSpace.xl, after: markRow)
        stack.setCustomSpacing(CCSpace.xs, after: eyebrow)
        stack.setCustomSpacing(CCSpace.md, after: titleLabel)
        stack.setCustomSpacing(CCSpace.xl, after: body)
        stack.setCustomSpacing(CCSpace.xl + 4, after: features)
        stack.setCustomSpacing(0, after: signInButton)
        stack.setCustomSpacing(CCSpace.md, after: errorHost)
        // In a scroll view: at the accessibility text sizes the column is
        // taller than the screen and scrolls (centred while it fits).
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.showsVerticalScrollIndicator = false
        view.addSubview(scroll)
        scroll.addSubview(stack)
        let content = scroll.contentLayoutGuide
        let page = scroll.frameLayoutGuide
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            content.widthAnchor.constraint(equalTo: page.widthAnchor),
            content.heightAnchor.constraint(greaterThanOrEqualTo: page.heightAnchor),
        ])

        let center = stack.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        center.priority = .defaultHigh
        let fill = stack.widthAnchor.constraint(equalTo: page.widthAnchor, constant: -CCSpace.xl * 2)
        fill.priority = .required - 1
        NSLayoutConstraint.activate([
            markHost.widthAnchor.constraint(equalToConstant: 64),
            markHost.heightAnchor.constraint(equalToConstant: 64),
            mark.leadingAnchor.constraint(equalTo: markHost.leadingAnchor),
            mark.trailingAnchor.constraint(equalTo: markHost.trailingAnchor),
            mark.topAnchor.constraint(equalTo: markHost.topAnchor),
            mark.bottomAnchor.constraint(equalTo: markHost.bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            center, fill,
            stack.topAnchor.constraint(greaterThanOrEqualTo: content.topAnchor, constant: CCSpace.lg),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -CCSpace.lg),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            errorLabel.leadingAnchor.constraint(equalTo: errorHost.leadingAnchor),
            errorLabel.trailingAnchor.constraint(equalTo: errorHost.trailingAnchor),
            errorLabel.topAnchor.constraint(equalTo: errorHost.topAnchor, constant: CCSpace.md),
        ])
    }

    /// A Mac onboarding feature row: recessed icon tile + one line.
    private func feature(_ symbol: String, _ text: String) -> UIView {
        let tile = CCIconTile(symbol: symbol, side: 32, iconSize: 14, iconTint: CCTheme.color.primary, radius: .sm)
        let label = ccLabel(text, font: CCFont.labelMedium, color: CCTheme.color.foreground, lines: 0)
        let row = UIStackView(arrangedSubviews: [tile, label])
        row.spacing = CCSpace.md
        row.alignment = .center
        row.isAccessibilityElement = true
        row.accessibilityLabel = text
        return row
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasEntered else { return }
        hasEntered = true
        CCMotion.stagger(stack.arrangedSubviews.filter { $0.bounds.height > 0 }, distance: 12, interval: 0.05)
    }

    /// The app icon art from the asset catalog (the .icon's layer image).
    static func appMark() -> UIImage? {
        UIImage(named: "AppIcon_Assets/Image") ?? UIImage(named: "AppIcon") ?? UIImage(named: "AppIcon60x60")
    }

    private func signIn() {
        hideError()
        signInButton.isBusy = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await AppEnvironment.shared.session.signIn(from: self.view.window)
                // The root swaps to the library on .ccSessionDidChange.
            } catch {
                self.signInButton.isBusy = false
                if case AuthService.AuthError.cancelled = error { return }
                self.showError(error.localizedDescription)
            }
        }
    }

    private func showError(_ text: String) {
        CCHaptics.warning()
        errorLabel.text = text
        view.layoutIfNeeded()
        // Growth law: only the pushed (bottom) edge moves — pin the column's
        // top where it is before the error line opens.
        if topPin == nil {
            let pin = stack.topAnchor.constraint(equalTo: view.topAnchor, constant: stack.frame.minY)
            pin.priority = .required - 1
            pin.isActive = true
            topPin = pin
        }
        let width = errorLabel.bounds.width > 0 ? errorLabel.bounds.width : stack.bounds.width
        let target = errorLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height + CCSpace.md
        CCMotion.animate(errorHeight, to: target, in: view)
        CCMotion.fadeAlpha(errorLabel, to: 1, duration: 0.2, delay: 0.08, from: 0)
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    private func hideError() {
        guard errorHeight.constant > 0 else { return }
        CCMotion.fadeAlpha(errorLabel, to: 0, duration: 0.12)
        CCMotion.animate(errorHeight, to: 0, in: view, duration: 0.28, curve: .settle)
    }
}
