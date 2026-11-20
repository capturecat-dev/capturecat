import AppKit

/// Grid card for a project that lives only in the cloud (made on the iPhone
/// or in the web app) — the project card's chassis, with:
///
/// • a cloud badge (top-right): not on this Mac yet, a click brings it here;
/// • a kind tag (top-left): "iPhone" for a device take, "Screenshot" for a
///   still — read from its project.json, so it arrives with the art;
/// • "size · date" meta, the duration in front once the document is known.
///
/// Art and tag land LIVE: the browser hands a newly loaded preview to the
/// visible card (`apply(preview:animated:)`), which fades the frame in over
/// the placeholder and pops the tag — never a snap.
@MainActor
final class CloudCardItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("CloudCardItem")

    var onOpen: (() -> Void)?
    var onOpenInWebEditor: (() -> Void)?
    private(set) var projectID: UUID?

    private let container = NSView()
    private let thumbView = NSView()
    private let artView = NSImageView()
    private let placeholderIcon = NSImageView()
    private let cloudBadge = NSImageView()
    private let tagBadge = CloudTagBadge()
    private let nameField = NSTextField(labelWithString: "")
    private let metaField = NSTextField(labelWithString: "")
    private var item: CloudLibraryItem?
    private var shownImage: NSImage?
    private var shownKind: CloudLibraryKind?
    private var shownDuration: Double?
    private var searchSnippet: String?
    private var trackingArea: NSTrackingArea?
    private var themeObservation: CCThemeObservation?

    // MARK: Probe seams (`--cloud-sync-test`)

    var probeArtView: NSImageView { artView }
    var probePlaceholder: NSImageView { placeholderIcon }
    var probeTag: NSView { tagBadge }
    var probeTagText: String? { tagBadge.isHidden ? nil : tagBadge.text }
    var probeMetaText: String { metaField.stringValue }
    var probeName: String { nameField.stringValue }
    var probeCloudBadge: NSImageView { cloudBadge }

    override func loadView() {
        view = CardBackdropView { [weak self] in self?.buildContextMenu() }
        view.wantsLayer = true
        buildLayout()
    }

    private func buildLayout() {
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.cornerRadius = CCTheme.radius(.lg)
        container.layer?.cornerCurve = .continuous
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.clear.cgColor
        view.addSubview(container)

        thumbView.translatesAutoresizingMaskIntoConstraints = false
        thumbView.wantsLayer = true
        thumbView.layer?.cornerRadius = CCTheme.radius(.md)
        thumbView.layer?.cornerCurve = .continuous
        thumbView.layer?.masksToBounds = true
        thumbView.layer?.borderWidth = 1
        container.addSubview(thumbView)

        artView.translatesAutoresizingMaskIntoConstraints = false
        artView.wantsLayer = true
        artView.imageScaling = .scaleProportionallyUpOrDown
        artView.alphaValue = 0
        thumbView.addSubview(artView)

        placeholderIcon.translatesAutoresizingMaskIntoConstraints = false
        placeholderIcon.wantsLayer = true
        placeholderIcon.image = CCIcon.image("icloud", pointSize: 28, weight: .regular)
        thumbView.addSubview(placeholderIcon)

        cloudBadge.translatesAutoresizingMaskIntoConstraints = false
        cloudBadge.image = CCIcon.image("icloud.and.arrow.down", pointSize: 9, weight: .semibold,
                                        accessibilityDescription: String(localized: "In the cloud", comment: "Accessibility label for the cloud badge on a cloud-only project card"))
        cloudBadge.contentTintColor = .white
        cloudBadge.wantsLayer = true
        cloudBadge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        cloudBadge.layer?.cornerRadius = 9
        cloudBadge.toolTip = String(localized: "In your CaptureCat cloud — opening it downloads it to this Mac.", comment: "Tooltip on the cloud badge of a cloud-only project card")
        container.addSubview(cloudBadge)

        tagBadge.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(tagBadge)

        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.font = .systemFont(ofSize: 12, weight: .medium)
        nameField.lineBreakMode = .byTruncatingTail
        container.addSubview(nameField)

        metaField.translatesAutoresizingMaskIntoConstraints = false
        metaField.font = .systemFont(ofSize: 10)
        metaField.lineBreakMode = .byTruncatingTail
        container.addSubview(metaField)

        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: view.topAnchor),
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            thumbView.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            thumbView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            thumbView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            artView.topAnchor.constraint(equalTo: thumbView.topAnchor),
            artView.leadingAnchor.constraint(equalTo: thumbView.leadingAnchor),
            artView.trailingAnchor.constraint(equalTo: thumbView.trailingAnchor),
            artView.bottomAnchor.constraint(equalTo: thumbView.bottomAnchor),

            placeholderIcon.centerXAnchor.constraint(equalTo: thumbView.centerXAnchor),
            placeholderIcon.centerYAnchor.constraint(equalTo: thumbView.centerYAnchor),

            cloudBadge.topAnchor.constraint(equalTo: thumbView.topAnchor, constant: 6),
            cloudBadge.trailingAnchor.constraint(equalTo: thumbView.trailingAnchor, constant: -6),
            cloudBadge.widthAnchor.constraint(equalToConstant: 18),
            cloudBadge.heightAnchor.constraint(equalToConstant: 18),

            tagBadge.topAnchor.constraint(equalTo: thumbView.topAnchor, constant: 6),
            tagBadge.leadingAnchor.constraint(equalTo: thumbView.leadingAnchor, constant: 6),

            nameField.topAnchor.constraint(equalTo: thumbView.bottomAnchor, constant: 8),
            nameField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            nameField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),

            metaField.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 3),
            metaField.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            metaField.trailingAnchor.constraint(equalTo: nameField.trailingAnchor),
        ])
        // Same thumbnail/label split as the project card.
        let thumbBottom = thumbView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -54)
        thumbBottom.priority = .defaultHigh
        thumbBottom.isActive = true

        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    private func applyTheme() {
        let ink: NSColor = CCTheme.isDark ? .white : .black
        thumbView.layer?.borderColor = ink.withAlphaComponent(0.10).cgColor
        thumbView.layer?.backgroundColor = ink.withAlphaComponent(0.06).cgColor
        placeholderIcon.contentTintColor = EditorThemeKit.textSecondary
        nameField.textColor = EditorThemeKit.textPrimary
        metaField.textColor = searchSnippet == nil ? EditorThemeKit.textSecondary : EditorThemeKit.textTertiary
    }

    /// Bind to an item (cells recycle — no motion here; arrivals animate in
    /// `apply(preview:animated:)`).
    func configure(with item: CloudLibraryItem, preview: CloudLibraryPreview?, searchSnippet: String? = nil) {
        if projectID != item.projectID {
            shownImage = nil
            shownKind = nil
            shownDuration = nil
            artView.image = nil
            artView.alphaValue = 0
            placeholderIcon.alphaValue = 1
            tagBadge.isHidden = true
        }
        projectID = item.projectID
        self.item = item
        self.searchSnippet = searchSnippet
        nameField.stringValue = item.name
        toolTip(for: item)
        apply(preview: preview, animated: false)
        applyTheme()
    }

    /// A preview arrived (or changed) for the bound project.
    func apply(preview: CloudLibraryPreview?, animated: Bool) {
        let motion = animated && view.window != nil

        let kind = preview?.kind
        if kind != shownKind {
            shownKind = kind
            if let tag = kind?.tag, let kind {
                let wasHidden = tagBadge.isHidden
                tagBadge.configure(text: tag, symbol: kind.tagSymbol)
                tagBadge.isHidden = false
                if motion && wasHidden {
                    CCMotion.fadeAlpha(tagBadge, to: 1, duration: 0.2, from: 0)
                    CCMotion.pop(tagBadge)
                } else {
                    tagBadge.alphaValue = 1
                }
            } else {
                tagBadge.isHidden = true
            }
        }

        let image = preview?.image
        if image !== shownImage {
            shownImage = image
            artView.image = image
            let showArt = image != nil
            if motion {
                // The frame fades in OVER the placeholder, which fades out
                // beneath it — a crossfade, not a pop.
                CCMotion.fadeAlpha(artView, to: showArt ? 1 : 0, duration: 0.32, from: showArt ? 0 : nil)
                CCMotion.fadeAlpha(placeholderIcon, to: showArt ? 0 : 1, duration: 0.2)
            } else {
                artView.alphaValue = showArt ? 1 : 0
                placeholderIcon.alphaValue = showArt ? 0 : 1
            }
        }

        let duration = (kind == .still) ? nil : preview?.duration
        if duration != shownDuration || metaField.stringValue.isEmpty || !motion {
            shownDuration = duration
            let text = metaText(duration: duration)
            if motion, metaField.stringValue != text {
                CCMotion.fadeContentSwap(metaField)
            }
            metaField.stringValue = text
        }
    }

    private func metaText(duration: Double?) -> String {
        if let searchSnippet { return String(localized: "match: \(searchSnippet)", comment: "Capture card line explaining why a search matched; the placeholder is text found in the video (lowercase label)") }
        guard let item else { return "" }
        var parts: [String] = []
        if let duration {
            let total = Int(duration.rounded())
            parts.append(String(format: "%d:%02d", total / 60, total % 60))
        }
        if item.totalBytes > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: item.totalBytes, countStyle: .file))
        }
        if let date = item.date {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            parts.append(formatter.localizedString(for: date, relativeTo: Date()))
        }
        return parts.joined(separator: " · ")
    }

    private func toolTip(for item: CloudLibraryItem) {
        view.toolTip = String(localized: "\(item.name) — in your CaptureCat cloud. Click to download it to this Mac.", comment: "Tooltip on a cloud-only project card; the placeholder is the project name")
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(CloudMenuTarget.item(String(localized: "Download to This Mac", comment: "Cloud project card context menu item: downloads the project to this Mac")) { [weak self] in self?.onOpen?() })
        menu.addItem(CloudMenuTarget.item(String(localized: "Open in Web Editor", comment: "Menu item / button: syncs the project and opens it in the CaptureCat web editor")) { [weak self] in self?.onOpenInWebEditor?() })
        return menu
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if let trackingArea { view.removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: view.bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self, userInfo: nil
        )
        view.addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        applyCardHover(container, hovered: true)
    }

    override func mouseExited(with event: NSEvent) {
        applyCardHover(container, hovered: false)
    }
}

/// "iPhone" / "Screenshot" pill over the card's art — the reminder badge's
/// language (dark scrim, white glyph + label), since it sits on pixels.
@MainActor
private final class CloudTagBadge: NSView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    var text: String { label.stringValue }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous

        icon.contentTintColor = .white
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)

        label.font = .systemFont(ofSize: 9, weight: .semibold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 18),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 3),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(text: String, symbol: String) {
        label.stringValue = text
        icon.image = CCIcon.image(symbol, pointSize: 8, weight: .semibold, accessibilityDescription: text)
    }
}
