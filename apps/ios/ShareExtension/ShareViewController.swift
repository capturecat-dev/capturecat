import UIKit
import UniformTypeIdentifiers

/// "Save to CaptureCat" — the share-sheet action. Take a screenshot, tap the
/// thumbnail, Share → CaptureCat: each image becomes a still-capture project
/// (8-second still movie, the Mac's own writer; iPhone bezel on Mac and web),
/// each video a recording project, uploaded right here while the card shows
/// progress. Not signed in, offline, or the user taps Done early: the takes
/// stay in the shared inbox and the app finishes them next time it opens.
final class ShareViewController: UIViewController {
    private let card = UIView()
    private let iconView = CCIconView("cloud-upload", pointSize: 24, weight: .medium)
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let progress = CCProgressBar()
    private let doneButton = CCButton(title: String(localized: "Close", comment: "Share extension button: close the sheet"), style: .ghost, size: .sm)
    private var work: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        buildCard()
        work = Task { await run() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // House presentation: the card rises into place and fades in.
        CCMotion.enter(card.layer, .slideUp())
        CCMotion.fadeAlpha(card, to: 1, duration: 0.2, from: 0)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        CCMaterial.refit(card.layer, radius: CCTheme.radii.xl)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        dressCard()
    }

    // MARK: Flow

    private func run() async {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        setStatus(title: String(localized: "Saving to CaptureCat", comment: "Share extension status title"), detail: providers.count == 1 ? String(localized: "Preparing…", comment: "Share extension status") : String(localized: "Preparing \(providers.count) items…", comment: "Share extension status; argument is the number of items"), fraction: 0)

        var takes: [PendingTake] = []
        var failures = 0
        for provider in providers {
            do {
                if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier),
                   let url = await Self.copyFile(provider, type: .movie) {
                    defer { try? FileManager.default.removeItem(at: url) }
                    takes.append(try await MediaImport.video(at: url))
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
                          let data = await Self.loadData(provider, type: .image) {
                    takes.append(try await MediaImport.screenshot(data: data))
                } else {
                    failures += 1
                }
            } catch {
                failures += 1
            }
        }
        guard !takes.isEmpty else {
            finish(title: String(localized: "Nothing to save", comment: "Share extension: nothing usable was shared"), detail: String(localized: "CaptureCat saves screenshots, images and videos."), success: false)
            return
        }
        guard SessionStore.load() != nil else {
            finish(title: String(localized: "Saved for later", comment: "Share extension: items are kept and upload later"),
                   detail: takes.count == 1
                       ? String(localized: "Open CaptureCat and sign in — it will upload then.")
                       : String(localized: "Open CaptureCat and sign in — they will upload then.", comment: "Several shared items"),
                   success: true)
            return
        }

        for (index, take) in takes.enumerated() {
            if Task.isCancelled { break }
            let position = index + 1
            let uploading = takes.count == 1
                ? Self.uploadingNoun(take)
                : String(localized: "Uploading \(position) of \(takes.count)…", comment: "Share extension status; arguments are the item number and the total")
            do {
                try await TakeInbox.publish(take) { [weak self] p in
                    Task { @MainActor in
                        let overall = (Double(index) + Self.weight(p)) / Double(takes.count)
                        self?.setStatus(title: String(localized: "Saving to CaptureCat", comment: "Share extension status title"), detail: uploading, fraction: overall)
                    }
                }
            } catch {
                failures += 1
            }
        }
        let saved = takes.count - failures
        if failures == 0 {
            finish(title: String(localized: "Saved", comment: "Share extension: everything was saved"), detail: takes.count == 1 ? String(localized: "It's in your CaptureCat library.") : String(localized: "\(takes.count) items are in your library."), success: true)
        } else if saved > 0 {
            finish(title: String(localized: "Partly saved", comment: "Share extension: some items failed to upload"), detail: String(localized: "\(failures) didn't upload — CaptureCat will retry when you open it.", comment: "Argument is the number of items that failed"), success: true)
        } else {
            finish(title: String(localized: "Saved for later", comment: "Share extension: items are kept and upload later"), detail: String(localized: "Couldn't upload right now — CaptureCat will retry when you open it."), success: true)
        }
    }

    private func finish(title: String, detail: String, success: Bool) {
        setStatus(title: title, detail: detail, fraction: success ? 1 : 0)
        iconView.iconName = success ? "check-circle-fill" : "alert-fill"
        iconView.tintColor = success ? CCTheme.color.success : CCTheme.color.warning
        CCMotion.pop(iconView)
        if success { CCHaptics.success() } else { CCHaptics.warning() }
        doneButton.title = String(localized: "Done", comment: "Share extension button: close the sheet")
        DispatchQueue.main.asyncAfter(deadline: .now() + (success ? 1.4 : 2.5)) { [weak self] in self?.close() }
    }

    private func close() {
        work?.cancel()
        UIView.animate(withDuration: CCMotion.paced(0.22), delay: 0, options: [.curveEaseIn], animations: {
            self.card.transform = CGAffineTransform(translationX: 0, y: 30)
            self.card.alpha = 0
            self.view.backgroundColor = .clear
        }, completion: { _ in
            self.extensionContext?.completeRequest(returningItems: nil)
        })
    }

    // MARK: UI

    private func buildCard() {
        view.backgroundColor = CCTheme.color.overlay
        card.alpha = 0
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)
        dressCard()

        iconView.contentMode = .center
        titleLabel.font = CCFont.header
        titleLabel.textColor = CCTheme.color.foreground
        titleLabel.adjustsFontForContentSizeCategory = true
        detailLabel.font = CCFont.label
        detailLabel.textColor = CCTheme.color.mutedForeground
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.numberOfLines = 2
        doneButton.onTap = { [weak self] in self?.close() }
        doneButton.accessibilityHint = String(localized: "Uploads that haven't finished continue next time you open CaptureCat.")

        let text = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        text.axis = .vertical
        text.spacing = CCSpace.xxs
        let header = UIStackView(arrangedSubviews: [iconView, text, doneButton])
        header.alignment = .center
        header.spacing = CCSpace.md
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        doneButton.setContentHuggingPriority(.required, for: .horizontal)
        let stack = UIStackView(arrangedSubviews: [header, progress])
        stack.axis = .vertical
        stack.spacing = CCSpace.md
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: CCSpace.gutter),
            card.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -CCSpace.gutter),
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.widthAnchor.constraint(equalTo: view.safeAreaLayoutGuide.widthAnchor, constant: -2 * CCSpace.gutter).withPriority(.defaultHigh),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
            card.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -CCSpace.gutter),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: CCSpace.lg + 2),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -(CCSpace.lg + 2)),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: CCSpace.lg + 2),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -(CCSpace.lg + 2)),
            iconView.widthAnchor.constraint(equalToConstant: 36),
        ])
    }

    private func dressCard() {
        CCMaterial.dress(card.layer, as: .raisedMatte(tint: CCTheme.color.card), radius: CCTheme.radii.xl, traits: traitCollection)
    }

    private func setStatus(title: String, detail: String, fraction: Double) {
        titleLabel.text = title
        detailLabel.text = detail
        progress.value = fraction
    }

    // MARK: Helpers

    private static func weight(_ p: PublishProgress) -> Double {
        switch p.phase {
        case .preparing: return 0.1 * p.fraction
        case .uploading: return 0.1 + 0.75 * p.fraction
        case .verifying: return 0.85 + 0.1 * p.fraction
        case .saving: return 0.95
        case .done: return 1
        }
    }

    private static func uploadingNoun(_ take: PendingTake) -> String {
        take.kind == .screenshot
            ? String(localized: "Uploading screenshot…", comment: "Share extension status")
            : String(localized: "Uploading video…", comment: "Share extension status")
    }

    private static func loadData(_ provider: NSItemProvider, type: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    private static func copyFile(_ provider: NSItemProvider, type: UTType) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else { continuation.resume(returning: nil); return }
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(url.pathExtension.isEmpty ? "mov" : url.pathExtension)
                continuation.resume(returning: (try? FileManager.default.copyItem(at: url, to: copy)) != nil ? copy : nil)
            }
        }
    }
}

private extension NSLayoutConstraint {
    func withPriority(_ priority: UILayoutPriority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
