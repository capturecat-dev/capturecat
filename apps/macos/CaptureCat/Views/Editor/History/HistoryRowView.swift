import AppKit

/// One version in the History pane: `CCAvatar` for the author, the time,
/// `CCBadge`s for the client (Mac / Web / Agent via Mac…), a name, and the
/// kind (merge / restore / current), plus the change summary caption.
///
/// Rows own no fill: hover and the open-menu state ride the pane's ONE
/// `CCGlideHighlight` wash, which glides from row to row (they report intent
/// through `onHighlight`). A click (mouseUp inside, never bare mouseDown) or
/// a right-click opens the row's house menu.
@MainActor
final class HistoryRowView: NSView {
    /// Wire-format row data; the pseudo-row ("On this Mac — not synced") is
    /// a separate view in the pane.
    let version: CloudVersion
    let isHead: Bool

    var onHighlight: ((HistoryRowView, Bool) -> Void)?
    /// Click / right-click: the pane builds and shows the row menu.
    var onActivate: ((HistoryRowView, NSEvent?) -> Void)?

    private let avatar: CCAvatar
    private let timeField = NSTextField(labelWithString: "")
    private let authorField = NSTextField(labelWithString: "")
    private let summaryField = NSTextField(labelWithString: "")
    private let badgeRow = NSStackView()
    private(set) var badges: [CCBadge] = []
    private var trackingArea: NSTrackingArea?
    private var isHovering = false
    private var themeObservation: CCThemeObservation?

    static let height: CGFloat = 58

    override var isFlipped: Bool { true }

    init(version: CloudVersion, isHead: Bool, timeText: String) {
        self.version = version
        self.isHead = isHead
        avatar = CCAvatar(name: version.actorName ?? "Someone", size: .sm)
        super.init(frame: .zero)
        wantsLayer = true

        timeField.stringValue = timeText
        authorField.stringValue = version.actorName ?? "Someone"
        authorField.lineBreakMode = .byTruncatingTail
        summaryField.stringValue = version.summary
        summaryField.lineBreakMode = .byTruncatingTail
        summaryField.maximumNumberOfLines = 1
        summaryField.toolTip = version.change.map { ChangeSummary.format($0) } ?? version.summary
        for field in [authorField, summaryField] {
            field.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        }

        badgeRow.orientation = .horizontal
        badgeRow.spacing = CCSpace.xs
        badgeRow.setHuggingPriority(.required, for: .horizontal)
        var list: [CCBadge] = [CCBadge(version.clientLabel, variant: .subtle)]
        if let label = version.label, !label.isEmpty { list.insert(CCBadge(label, variant: .primary), at: 0) }
        if isHead { list.append(CCBadge("Current", variant: .outline)) }
        if version.kind == "merge" { list.append(CCBadge("Merge", variant: .outline)) }
        if version.kind == "restore" { list.append(CCBadge("Restored", variant: .outline)) }
        for badge in list { badgeRow.addArrangedSubview(badge) }
        badges = list

        for view in [avatar, timeField, authorField, badgeRow, summaryField] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let pad = CCSpace.sm
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            avatar.topAnchor.constraint(equalTo: topAnchor, constant: 10),

            timeField.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: CCSpace.sm),
            timeField.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            authorField.leadingAnchor.constraint(equalTo: timeField.trailingAnchor, constant: CCSpace.xs),
            authorField.firstBaselineAnchor.constraint(equalTo: timeField.firstBaselineAnchor),
            authorField.trailingAnchor.constraint(lessThanOrEqualTo: badgeRow.leadingAnchor, constant: -CCSpace.xs),

            badgeRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            badgeRow.centerYAnchor.constraint(equalTo: timeField.centerYAnchor),

            summaryField.leadingAnchor.constraint(equalTo: timeField.leadingAnchor),
            summaryField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -pad),
            summaryField.topAnchor.constraint(equalTo: timeField.bottomAnchor, constant: 4),
        ])
        timeField.setContentHuggingPriority(.required, for: .horizontal)
        timeField.setContentCompressionResistancePriority(.required, for: .horizontal)
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(timeText), \(version.actorName ?? "Someone"), \(version.clientLabel). \(version.summary)")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func applyTheme() {
        timeField.font = NSFont.systemFont(ofSize: CCTheme.font.label.pointSize, weight: .semibold)
        timeField.textColor = CCTheme.color.foreground
        authorField.font = CCTheme.font.label
        authorField.textColor = CCTheme.color.mutedForeground
        summaryField.font = CCTheme.font.caption
        summaryField.textColor = CCTheme.color.mutedForeground
    }

    // MARK: - Hover + click

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    /// Hover routing (also the harness seam).
    func setHovered(_ hovered: Bool) {
        guard hovered != isHovering else { return }
        isHovering = hovered
        onHighlight?(self, hovered)
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onActivate?(self, event)
    }

    override func rightMouseDown(with event: NSEvent) { onActivate?(self, event) }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    // MARK: - Probe seams

    var probeSummary: String { summaryField.stringValue }
    var probeAvatar: CCAvatar { avatar }
}

/// The "On this Mac — not synced" pseudo-row: base → local summary + Sync now.
@MainActor
final class HistoryLocalRowView: NSView {
    var onSyncNow: (() -> Void)?

    private let icon = NSImageView()
    private let titleField = NSTextField(labelWithString: "On this Mac — not synced")
    private let summaryField = NSTextField(labelWithString: "")
    private let syncButton = CCButton(title: "Sync now", symbol: "arrow.triangle.2.circlepath", style: .secondary, size: .sm)
    private var themeObservation: CCThemeObservation?

    override var isFlipped: Bool { true }

    init(summary: String) {
        super.init(frame: .zero)
        wantsLayer = true
        icon.image = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        summaryField.stringValue = summary
        summaryField.lineBreakMode = .byTruncatingTail
        summaryField.toolTip = summary
        summaryField.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        titleField.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        titleField.lineBreakMode = .byTruncatingTail
        syncButton.onClick = { [weak self] in self?.onSyncNow?() }
        for view in [icon, titleField, summaryField, syncButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let pad = CCSpace.sm
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 58),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad + 4),
            icon.centerYAnchor.constraint(equalTo: titleField.centerYAnchor),
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad + 24 + CCSpace.sm),
            titleField.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: syncButton.leadingAnchor, constant: -CCSpace.xs),
            summaryField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            summaryField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 4),
            summaryField.trailingAnchor.constraint(lessThanOrEqualTo: syncButton.leadingAnchor, constant: -CCSpace.xs),
            syncButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            syncButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        themeObservation = CCThemeObservation { [weak self] in
            guard let self else { return }
            self.icon.contentTintColor = CCTheme.color.primary
            self.titleField.font = NSFont.systemFont(ofSize: CCTheme.font.label.pointSize, weight: .semibold)
            self.titleField.textColor = CCTheme.color.foreground
            self.summaryField.font = CCTheme.font.caption
            self.summaryField.textColor = CCTheme.color.mutedForeground
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var probeSyncButton: CCButton { syncButton }
    var probeSummary: String { summaryField.stringValue }
}
