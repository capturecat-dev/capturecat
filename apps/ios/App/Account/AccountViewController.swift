import UIKit

/// Account: who's signed in, the plan and storage meter, "Forget my
/// devices…" (rotates the account's Wi-Fi link key), Sign out and Delete
/// Account (AccountDeletion.swift) — every consequential action behind a
/// house confirm.
final class AccountViewController: UIViewController {
    private let header = CCHeaderBar(title: String(localized: "Account", comment: "Account screen title"), style: .large)
    private let scrollView = UIScrollView()
    private let column = UIStackView()
    private let avatar = CCAvatar(name: "", side: 56)
    private let nameLabel = ccLabel("", font: CCFont.title, color: CCTheme.color.foreground, lines: 2)
    private let emailLabel = ccLabel("", font: CCFont.label, color: CCTheme.color.mutedForeground)
    private let planBadge = CCBadge(String(localized: "Free", comment: "Plan badge placeholder: the free plan"), variant: .subtle)
    private let storageBar = CCProgressBar()
    private let storageLabel = ccLabel("", font: CCFont.label, color: CCTheme.color.foreground)
    private let storageDetail = ccLabel("", font: CCFont.caption, color: CCTheme.color.mutedForeground, lines: 2)
    private let planSpinner = CCSpinner(diameter: 16)
    private var planError: CCCallout?
    private var account: AccountInfo?
    private var observation: SurfaceObservation?
    private var loadingAvatarURL: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = CCTheme.color.background
        // Accessibility text sizes: the name and address wrap whole.
        nameLabel.ccWrapsAtAccessibilitySizes(otherwise: 2)
        emailLabel.ccWrapsAtAccessibilitySizes()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        view.addSubview(scrollView)
        view.addSubview(header)
        column.axis = .vertical
        column.spacing = CCSpace.lg
        column.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(column)
        let width = column.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -CCSpace.gutter * 2)
        width.priority = .required - 1
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            column.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: CCSpace.sm),
            column.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -CCSpace.xl),
            column.centerXAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerXAnchor),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: 620),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: CCSpace.gutter),
            width,
        ])
        header.track(scrollView)

        column.addArrangedSubview(makeProfileCard())
        column.addArrangedSubview(section(String(localized: "Plan", comment: "Account screen section header: subscription plan"), makePlanCard()))
        column.addArrangedSubview(connectAIRow)
        column.addArrangedSubview(section(String(localized: "Wi-Fi streaming", comment: "Account screen section header"), makeDevicesCard()))
        column.addArrangedSubview(section(String(localized: "Language", comment: "Account screen section header: the app language"), makeLanguageCard()))
        let signOut = CCButton(title: String(localized: "Sign out", comment: "Button"), symbol: "arrow-right-line", style: .secondary, size: .lg, radius: .lg)
        signOut.onTap = { [weak self] in self?.confirmSignOut() }
        column.addArrangedSubview(signOut)
        column.addArrangedSubview(section(String(localized: "Delete account", comment: "Account screen section header"), makeDeleteCard()))
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        column.addArrangedSubview(ccLabel(String(localized: "CaptureCat for iPhone and iPad \(version) (\(build))", comment: "App version footer; first argument is the version, second the build number"), font: CCFont.caption,
                                          color: CCTheme.color.faintForeground, lines: 1, alignment: .center))

        observation = SurfaceObservation { [weak self] in self?.renderStorage() }
        renderUser()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        languageRow.accessoryText = LanguageViewController.selectedDisplayName
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        loadAccount()
        LibraryStore.shared.refreshIfStale(30)
    }

    // MARK: - Cards

    private func section(_ title: String, _ card: UIView) -> UIView {
        let label = ccLabel(title, font: CCFont.labelSemibold, color: CCTheme.color.mutedForeground)
        label.accessibilityTraits = .header
        let stack = UIStackView(arrangedSubviews: [label, card])
        stack.axis = .vertical
        stack.spacing = CCSpace.sm
        return stack
    }

    private func padded(_ content: UIView, in card: CCCard) -> CCCard {
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: CCSpace.lg),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -CCSpace.lg),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: CCSpace.lg),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -CCSpace.lg),
        ])
        return card
    }

    private func makeProfileCard() -> UIView {
        let text = UIStackView(arrangedSubviews: [nameLabel, emailLabel])
        text.axis = .vertical
        text.spacing = 2
        let row = UIStackView(arrangedSubviews: [avatar, text])
        row.spacing = CCSpace.md + 2
        row.alignment = .center
        row.isAccessibilityElement = true
        return padded(row, in: CCCard())
    }

    private func makePlanCard() -> UIView {
        let planTitle = ccLabel(String(localized: "Current plan", comment: "Account screen label above the plan name"), font: CCFont.label, color: CCTheme.color.mutedForeground)
        let top = UIStackView(arrangedSubviews: [planTitle, UIView(), planSpinner, planBadge])
        top.spacing = CCSpace.sm
        top.alignment = .center
        planSpinner.color = CCTheme.color.mutedForeground
        let storageTitle = UIStackView(arrangedSubviews: [CCIconView("drive", pointSize: 15, weight: .medium, tint: CCTheme.color.mutedForeground), storageLabel])
        storageTitle.spacing = CCSpace.sm
        storageTitle.alignment = .center
        let stack = UIStackView(arrangedSubviews: [top, CCDivider(), storageTitle, storageBar, storageDetail])
        stack.axis = .vertical
        stack.spacing = CCSpace.md
        stack.setCustomSpacing(CCSpace.sm, after: storageTitle)
        stack.setCustomSpacing(CCSpace.sm, after: storageBar)
        storageBar.accessibilityLabel = String(localized: "Storage used", comment: "Accessibility label for the storage bar")
        self.planStack = stack
        return padded(stack, in: CCCard())
    }

    private var planStack: UIStackView?

    /// Account → Language: the current choice; tapping opens the picker.
    private let languageRow = LanguageRow(title: String(localized: "App language", comment: "Account: row that opens the language picker"),
                                          subtitle: nil, selected: false)
    /// Gate seam: the Language entry.
    var probeLanguageRow: UIControl { languageRow }

    private func makeLanguageCard() -> UIView {
        languageRow.accessoryText = LanguageViewController.selectedDisplayName
        languageRow.onTap = { [weak self] in
            self?.navigationController?.pushViewController(LanguageViewController(), animated: true)
        }
        let card = CCCard()
        card.addSubview(languageRow)
        NSLayoutConstraint.activate([
            languageRow.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: CCSpace.xs),
            languageRow.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -CCSpace.xs),
            languageRow.topAnchor.constraint(equalTo: card.topAnchor, constant: CCSpace.xs),
            languageRow.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -CCSpace.xs),
        ])
        return card
    }

    /// Settings → Connect AI (ConnectAIViewController): one row.
    private lazy var connectAIRow: ActionListCard = {
        let card = ActionListCard()
        card.setActions([.init(title: String(localized: "Connect AI", comment: "Account row that opens Connect AI"), symbol: "sparkles") { [weak self] _ in
            self?.navigationController?.pushViewController(ConnectAIViewController(), animated: true)
        }])
        return card
    }()
    /// Gate seam: the Connect AI entry.
    var probeConnectAIRow: UIView { connectAIRow }

    private func makeDevicesCard() -> UIView {
        let icon = CCIconView("wifi", pointSize: 17, weight: .medium, tint: CCTheme.color.mutedForeground)
        let title = ccLabel(String(localized: "Your \(ThisDevice.noun) and Macs stream to each other over Wi-Fi", comment: "Argument is iPhone or iPad"), font: CCFont.labelSemibold, color: CCTheme.color.foreground, lines: 0)
        let detail = ccLabel(String(localized: "Every device signed in to this account is linked automatically. Forgetting them unlinks every Mac, iPhone and iPad until they reconnect."),
                             font: CCFont.caption, color: CCTheme.color.mutedForeground, lines: 0)
        let text = UIStackView(arrangedSubviews: [title, detail])
        text.axis = .vertical
        text.spacing = CCSpace.xs
        let top = UIStackView(arrangedSubviews: [icon, text])
        top.spacing = CCSpace.md
        top.alignment = .top
        let forget = CCButton(title: String(localized: "Forget my devices…", comment: "Button: unlink all devices from Wi-Fi streaming"), style: .outline, size: .regular)
        forget.onTap = { [weak self] in self?.confirmForget() }
        let buttonRow = UIStackView(arrangedSubviews: [forget, UIView()])
        let stack = UIStackView(arrangedSubviews: [top, buttonRow])
        stack.axis = .vertical
        stack.spacing = CCSpace.md + 2
        return padded(stack, in: CCCard())
    }

    private let deleteButton = CCButton(title: String(localized: "Delete Account…", comment: "Button: opens the delete-account confirmation"), symbol: "trash", style: .destructive, size: .regular)
    /// Gate seam: the Delete Account entry.
    var probeDeleteButton: CCButton { deleteButton }

    private func makeDeleteCard() -> UIView {
        let detail = ccLabel(String(localized: "Permanently delete your CaptureCat account, your shared videos and cloud projects. An active subscription is cancelled immediately."),
                             font: CCFont.caption, color: CCTheme.color.mutedForeground, lines: 0)
        deleteButton.onTap = { [weak self] in self?.confirmDeleteAccount() }
        deleteButton.accessibilityHint = String(localized: "Asks you to confirm. Deletes your account and its data, and cancels your subscription.")
        let buttonRow = UIStackView(arrangedSubviews: [deleteButton, UIView()])
        let stack = UIStackView(arrangedSubviews: [detail, buttonRow])
        stack.axis = .vertical
        stack.spacing = CCSpace.md
        return padded(stack, in: CCCard())
    }

    // MARK: - Data

    private func renderUser() {
        let user = AppEnvironment.shared.session.user
        let name = user?.name?.isEmpty == false ? user!.name! : (user?.email ?? String(localized: "Signed in", comment: "Fallback account name when the user has no name or email"))
        nameLabel.text = name
        emailLabel.text = user?.email
        emailLabel.isHidden = user?.email == nil || user?.email == name
        avatar.name = name
        avatar.superview?.accessibilityLabel = [name, user?.email].compactMap { $0 }.joined(separator: ", ")
        if let image = user?.image, let url = URL(string: image), loadingAvatarURL != image {
            loadingAvatarURL = image
            Task { [weak self] in
                guard let (data, _) = try? await URLSession.shared.data(from: url), let picture = UIImage(data: data) else { return }
                self?.avatar.image = picture
            }
        }
    }

    private func loadAccount() {
        planSpinner.startAnimating()
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.planSpinner.stopAnimating() }
            do {
                let info = try await AppEnvironment.shared.api.me()
                self.account = info
                self.planError?.removeFromSuperview()
                self.planError = nil
                self.planBadge.text = info.planDisplayName
                self.planBadge.variant = info.tier == "free" ? .subtle : .primary
                self.renderStorage()
                self.renderUser()
            } catch {
                guard self.planError == nil, let stack = self.planStack else { return }
                let callout = CCCallout(message: String(localized: "Couldn't load your plan. \(error.localizedDescription)", comment: "Argument is the error message"), variant: .warning)
                stack.insertArrangedSubview(callout, at: 1)
                self.planError = callout
            }
        }
    }

    private func renderStorage() {
        let storage = LibraryStore.shared.storage
        let count = LibraryStore.shared.projects.count
        let limit = storage?.limitBytes ?? account?.storageLimitBytes
        if let used = storage?.usedBytes {
            if let limit, limit > 0 {
                storageLabel.text = String(localized: "\(Format.bytes(used)) of \(Format.bytes(limit)) used", comment: "Storage usage; arguments are sizes like '1.2 GB'")
                storageBar.value = Double(used) / Double(limit)
                storageBar.tint = Double(used) / Double(limit) > 0.9 ? CCTheme.color.warning : CCTheme.color.primary
            } else {
                storageLabel.text = String(localized: "\(Format.bytes(used)) used", comment: "Storage usage; argument is a size like '1.2 GB'")
                storageBar.value = 0
            }
        } else {
            storageLabel.text = String(localized: "Storage", comment: "Label while storage usage is unknown")
            storageBar.isIndeterminate = LibraryStore.shared.phase != .loaded
        }
        if storage != nil { storageBar.isIndeterminate = false }
        storageDetail.text = count == 1 ? String(localized: "1 project in your cloud library.") : String(localized: "\(count) projects in your cloud library.")
    }

    // MARK: - Actions

    private func confirmForget() {
        CCAlert.confirm(
            title: String(localized: "Forget my devices?"),
            message: String(localized: "This unlinks every Mac, iPhone and iPad on your account from Wi-Fi streaming. Each one reconnects by itself the next time CaptureCat opens on it while signed in."),
            confirmTitle: String(localized: "Forget devices", comment: "Confirm button: unlink all devices"),
            destructive: true,
            from: self,
            action: { try await AppEnvironment.shared.api.forgetDevices() },
            completion: { done in
                guard done else { return }
                CCHaptics.success()
                AppToaster.shared.show(title: String(localized: "Devices forgotten", comment: "Toast"), message: String(localized: "They'll relink when CaptureCat opens on them."), variant: .success, symbol: "wifi")
            }
        )
    }

    private func confirmDeleteAccount() {
        AccountDeletion.presentConfirmation(from: self)
    }

    private func confirmSignOut() {
        CCAlert.confirm(
            title: String(localized: "Sign out?"),
            message: String(localized: "Uploads still waiting on this \(ThisDevice.noun) stay here and finish after you sign back in.", comment: "Argument is iPhone or iPad"),
            confirmTitle: String(localized: "Sign out", comment: "Confirm button"),
            destructive: false,
            from: self,
            action: { await AppEnvironment.shared.session.signOut() }
        )
    }
}
