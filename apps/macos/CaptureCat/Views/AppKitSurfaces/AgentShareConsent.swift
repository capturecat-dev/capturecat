import AppKit

/// The consent card an MCP `share_project` request raises (AgentShareBroker):
/// the house CCAlert — never NSAlert — presented standalone (centred on the
/// user's screen, over whatever app they're in) with a recessed details well
/// that says exactly what will happen: which project, who is asking, who
/// will be able to watch, and whether an existing link gets the new cut.
///
/// Approving takes a deliberate click: Return is swallowed (the card can pop
/// up while the user is typing to the agent) and Allow arms after a beat
/// (it can open under a moving pointer). Escape / Don't Allow declines.
@MainActor
enum AgentShareConsent {
    static let allowTitle = "Allow"
    static let declineTitle = "Don't Allow"
    static let armDelay: TimeInterval = 0.6

    /// Fixed length on purpose: project names can be long, and the name is
    /// the first row of the details well right below.
    static let title = "Allow an AI agent to share this project?"

    static let message = "An AI agent connected to CaptureCat through MCP asked to upload this project to your "
        + "CaptureCat account and create a share link. Allowing applies to this request only."

    /// Builds the card (used by `present` and by --share-consent-test).
    static func makeAlert(_ request: AgentShareBroker.ConsentRequest) -> (CCAlert, AgentShareConsentDetailsView) {
        let details = AgentShareConsentDetailsView(rows: rows(for: request))
        let alert = CCAlert(title: title, message: message)
        alert.accessoryView = details
        alert.addButton(allowTitle, role: .primary)    // index 0
        alert.addButton(declineTitle)                  // index 1 = Escape
        alert.returnKeyChoosesDefault = false
        alert.armDelay = armDelay
        return (alert, details)
    }

    /// Bring the app forward and ask. `completion(true)` only for Allow.
    @discardableResult
    static func present(
        _ request: AgentShareBroker.ConsentRequest, completion: @escaping (Bool) -> Void
    ) -> CCAlert {
        let (alert, _) = makeAlert(request)
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.requestUserAttention(.informationalRequest)
        alert.beginStandalone { index in completion(index == 0) }
        return alert
    }

    struct Row: Equatable {
        let symbol: String
        let key: String
        let value: String
    }

    static func rows(for request: AgentShareBroker.ConsentRequest) -> [Row] {
        var asker = "An AI agent via MCP"
        if let client = displayableClientName(request.clientName) {
            asker += " — it identifies as “\(client)”"
        }
        var rows = [
            Row(symbol: "film", key: "Project", value: request.projectName),
            Row(symbol: "sparkles", key: "Requested by", value: asker),
            Row(symbol: request.visibility == .private ? "eye.slash" : "globe",
                key: "Who can watch", value: request.visibility.summary),
        ]
        if let url = request.existingShareURL {
            rows.append(Row(symbol: "arrow.triangle.2.circlepath", key: "Existing link",
                            value: "Replaces the video at \(url) with this version."))
        }
        if let email = request.accountEmail, !email.isEmpty {
            rows.append(Row(symbol: "person.crop.circle", key: "Uploads to", value: email))
        }
        return rows
    }

    /// clientInfo.name is self-reported by the agent: one line, printable,
    /// bounded — it is shown as a claim, never as a verified identity.
    static func displayableClientName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let printable = raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let cleaned = String(String.UnicodeScalarView(printable))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return cleaned.count > 48 ? String(cleaned.prefix(47)) + "…" : cleaned
    }
}

/// The recessed details well inside the consent card: icon · key · value
/// rows. Dressed by CCMaterial (a flat well inside the raised card), colors
/// re-applied on every theme change, rows stagger in with the card.
@MainActor
final class AgentShareConsentDetailsView: NSView {
    /// A fixed well width (the card is then 380pt, inside CCAlert's 340…440
    /// band) so every value label wraps at a width known BEFORE the card
    /// measures itself — a guessed wrap width leaves phantom lines.
    static let width: CGFloat = 348

    private let stack = NSStackView()
    private var rowViews: [NSView] = []
    private var icons: [NSImageView] = []
    private var keyLabels: [NSTextField] = []
    private var valueLabels: [NSTextField] = []
    private let rows: [AgentShareConsent.Row]
    private var themeObservation: CCThemeObservation?
    private var didStagger = false

    init(rows: [AgentShareConsent.Row]) {
        self.rows = rows
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = CCSpace.sm
        stack.edgeInsets = NSEdgeInsets(top: CCSpace.md, left: CCSpace.md, bottom: CCSpace.md, right: CCSpace.md)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        for row in rows {
            let icon = NSImageView()
            icon.image = CCIcon.image(row.symbol, pointSize: 12, weight: .semibold)
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant: CCIcon.side(for: 12)).isActive = true
            icon.heightAnchor.constraint(equalToConstant: CCIcon.side(for: 12)).isActive = true

            let key = NSTextField(labelWithString: row.key)
            key.font = CCTheme.font.caption
            key.isSelectable = false

            let value = NSTextField(wrappingLabelWithString: row.value)
            value.font = CCTheme.font.label
            value.isSelectable = false
            value.preferredMaxLayoutWidth = Self.valueWidth
            value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let text = NSStackView(views: [key, value])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 1

            let line = NSStackView(views: [icon, text])
            line.orientation = .horizontal
            line.alignment = .top
            line.spacing = CCSpace.sm
            line.wantsLayer = true
            stack.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -CCSpace.md * 2).isActive = true

            rowViews.append(line)
            icons.append(icon)
            keyLabels.append(key)
            valueLabels.append(value)
        }

        let width = widthAnchor.constraint(equalToConstant: Self.width)
        width.priority = .init(990)
        width.isActive = true

        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Well width minus its insets, the icon column and the gap.
    private static var valueWidth: CGFloat {
        width - CCSpace.md * 2 - CCIcon.side(for: 12) - CCSpace.sm
    }

    private func applyTheme() {
        if let layer {
            CCMaterial.dress(layer, as: .recessed(tint: CCTheme.color.background), radius: CCTheme.radius(.lg))
        }
        for icon in icons { icon.contentTintColor = CCTheme.color.mutedForeground }
        for key in keyLabels {
            key.textColor = CCTheme.color.mutedForeground
            key.font = CCTheme.font.caption
        }
        for value in valueLabels {
            value.textColor = CCTheme.color.foreground
            value.font = CCTheme.font.label
            value.preferredMaxLayoutWidth = Self.valueWidth
        }
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = CCTheme.radius(.lg)
        if let layer { CCMaterial.refit(layer, radius: CCTheme.radius(.lg)) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Rows arrive with the card (fade + rise, staggered) — once.
        guard window != nil, !didStagger else { return }
        didStagger = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            CCMotion.stagger(self.rowViews, distance: 6, interval: 0.04)
        }
    }

    // MARK: - Probe seams (--share-consent-test)

    var probeRows: [AgentShareConsent.Row] { rows }
    var probeRowViews: [NSView] { rowViews }
    var probeValueTexts: [String] { valueLabels.map(\.stringValue) }
}
