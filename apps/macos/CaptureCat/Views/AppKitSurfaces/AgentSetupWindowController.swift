import AppKit

/// "Connect AI Agents" — one row per client, the best mechanism each platform
/// offers (see AgentSetup). Built from CCKit like every other surface: a
/// title block, one raised CCCard of rows, dressed keys for the actions and a
/// status pill per client. Retheme is live.
@MainActor
final class AgentSetupViewController: NSViewController {

    struct Client {
        let name: String
        let symbol: String
        let detail: String
        let installed: Bool?
        let buttonTitle: String
        let action: () -> Void
    }

    private let stack = NSStackView()
    private let titleLabel = NSTextField(labelWithString: "Connect AI Agents")
    private let subtitleLabel = NSTextField(wrappingLabelWithString:
        "Let Claude, Cursor, Codex or any MCP client drive CaptureCat — record, "
        + "edit, see rendered frames, and export. Pick your client:")
    private let feedback = NSTextField(wrappingLabelWithString: "")
    private let feedbackPill = NSView()
    private var themeObservation: CCThemeObservation?
    private var rowIcons: [NSView] = []
    private var rowTitles: [NSTextField] = []
    private var rowDetails: [NSTextField] = []

    /// Probe seams for the --agent-setup-shot harness.
    private(set) var probeRows: [NSView] = []
    var probeCard: NSView? { card }
    private var card: CCCard?

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        view = root

        titleLabel.font = CCTheme.font.title
        subtitleLabel.font = CCTheme.font.label
        subtitleLabel.preferredMaxLayoutWidth = 440

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = CCSpace.sm
        stack.addArrangedSubview(titleLabel)
        stack.setCustomSpacing(4, after: titleLabel)
        stack.addArrangedSubview(subtitleLabel)
        stack.setCustomSpacing(CCSpace.lg, after: subtitleLabel)

        let card = CCCard()
        self.card = card
        for (index, client) in clients().enumerated() {
            if index > 0 { card.addContent(CCDivider()) }
            let row = makeRow(client)
            probeRows.append(row)
            card.addContent(row)
        }
        stack.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setCustomSpacing(CCSpace.md, after: card)

        // Feedback rides in a recessed pill so it reads as a status, not a
        // stray caption; hidden until there is something to say.
        feedback.font = CCTheme.font.caption
        feedback.preferredMaxLayoutWidth = 420
        feedbackPill.wantsLayer = true
        feedbackPill.isHidden = true
        feedback.translatesAutoresizingMaskIntoConstraints = false
        feedbackPill.addSubview(feedback)
        NSLayoutConstraint.activate([
            feedback.leadingAnchor.constraint(equalTo: feedbackPill.leadingAnchor, constant: 12),
            feedback.trailingAnchor.constraint(equalTo: feedbackPill.trailingAnchor, constant: -12),
            feedback.topAnchor.constraint(equalTo: feedbackPill.topAnchor, constant: 7),
            feedback.bottomAnchor.constraint(equalTo: feedbackPill.bottomAnchor, constant: -7),
        ])
        stack.addArrangedSubview(feedbackPill)
        feedbackPill.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: CCSpace.lg),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -CCSpace.lg),
            // Room for the traffic lights: the titlebar is transparent.
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 44),
            root.bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: CCSpace.lg),
            root.widthAnchor.constraint(equalToConstant: 520),
        ])
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if let layer = feedbackPill.layer {
            CCMaterial.refit(layer, radius: CCTheme.radius(.md))
        }
        for icon in rowIcons {
            if let layer = icon.layer { CCMaterial.refit(layer, radius: CCTheme.radius(.md)) }
        }
    }

    /// All chrome colors in one place so init and theme changes share a path.
    private func applyTheme() {
        let colors = CCTheme.color
        view.layer?.backgroundColor = colors.background.cgColor
        titleLabel.textColor = colors.foreground
        subtitleLabel.textColor = colors.mutedForeground
        feedback.textColor = colors.foreground
        if let layer = feedbackPill.layer {
            CCMaterial.dress(layer, as: .recessed(tint: colors.background), radius: CCTheme.radius(.md))
        }
        for icon in rowIcons {
            if let layer = icon.layer {
                CCMaterial.dress(layer, as: .raised(tint: colors.elevated), radius: CCTheme.radius(.md))
            }
            (icon.subviews.first as? NSImageView)?.contentTintColor = colors.foreground
        }
        for label in rowTitles { label.textColor = colors.foreground }
        for label in rowDetails { label.textColor = colors.mutedForeground }
    }

    // MARK: - Rows

    private func makeRow(_ client: Client) -> NSView {
        let row = NSView()

        // Icon key: a small raised tile with the client's SF Symbol.
        let icon = NSView()
        icon.wantsLayer = true
        icon.translatesAutoresizingMaskIntoConstraints = false
        let image = NSImageView()
        image.image = NSImage(systemSymbolName: client.symbol, accessibilityDescription: client.name)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        image.translatesAutoresizingMaskIntoConstraints = false
        icon.addSubview(image)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 30),
            icon.heightAnchor.constraint(equalToConstant: 30),
            image.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
            image.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
        ])
        rowIcons.append(icon)

        let title = NSTextField(labelWithString: client.name)
        title.font = CCTheme.font.chip
        rowTitles.append(title)

        let detail = NSTextField(wrappingLabelWithString: client.detail)
        detail.font = CCTheme.font.caption
        detail.preferredMaxLayoutWidth = 250
        rowDetails.append(detail)

        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        var trailing: [NSView] = []
        if let installed = client.installed {
            let badge = CCBadge(installed ? "Installed" : "Not found",
                                variant: installed ? .primary : .outline)
            trailing.append(badge)
        }
        let button = CCButton(title: client.buttonTitle, style: .secondary, size: .sm, onClick: client.action)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 92).isActive = true
        trailing.append(button)
        let trailingStack = NSStackView(views: trailing)
        trailingStack.orientation = .horizontal
        trailingStack.alignment = .centerY
        trailingStack.spacing = CCSpace.sm

        let h = NSStackView(views: [icon, text, NSView(), trailingStack])
        h.orientation = .horizontal
        h.alignment = .centerY
        h.spacing = CCSpace.sm
        h.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(h)
        NSLayoutConstraint.activate([
            h.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            h.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            h.topAnchor.constraint(equalTo: row.topAnchor, constant: 4),
            h.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -4),
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        return row
    }

    private func clients() -> [Client] {
        [
            Client(
                name: "Claude Code",
                symbol: "terminal",
                detail: "Registers for every project on this Mac (user scope) via Terminal.",
                installed: nil,
                buttonTitle: "Install"
            ) { [weak self] in self?.installViaTerminal(AgentSetup.claudeCodeCommand, client: "Claude Code") },
            Client(
                name: "Claude Desktop",
                symbol: "sparkles",
                detail: AgentSetup.claudeDesktopInstalled
                    ? "Opens a one-click extension bundle in Claude Desktop."
                    : "Builds the extension bundle for when Claude Desktop is installed.",
                installed: AgentSetup.claudeDesktopInstalled,
                buttonTitle: "Install"
            ) { [weak self] in self?.installClaudeDesktop() },
            Client(
                name: "Cursor",
                symbol: "cursorarrow.rays",
                detail: AgentSetup.cursorInstalled
                    ? "One click — Cursor confirms the server."
                    : "Copies the config until Cursor is installed.",
                installed: AgentSetup.cursorInstalled,
                buttonTitle: "Install"
            ) { [weak self] in self?.installCursor() },
            Client(
                name: "Codex",
                symbol: "chevron.left.forwardslash.chevron.right",
                detail: "Registers globally via Terminal — the Codex app reads the same config.",
                installed: nil,
                buttonTitle: "Install"
            ) { [weak self] in self?.installViaTerminal(AgentSetup.codexCommand, client: "Codex") },
            Client(
                name: "Gemini CLI",
                symbol: "diamond",
                detail: "Registers for every project (user scope) via Terminal.",
                installed: nil,
                buttonTitle: "Install"
            ) { [weak self] in self?.installViaTerminal(AgentSetup.geminiCommand, client: "Gemini CLI") },
            Client(
                name: "VS Code",
                symbol: "chevron.left.forwardslash.chevron.right",
                detail: AgentSetup.vsCodeInstalled
                    ? "Opens VS Code's install prompt for the server."
                    : "Copies the config until VS Code is installed.",
                installed: AgentSetup.vsCodeInstalled,
                buttonTitle: "Install"
            ) { [weak self] in self?.installVSCode() },
            Client(
                name: "Windsurf & others",
                symbol: "doc.on.clipboard",
                detail: "Copies the standard mcpServers JSON for any client's config.",
                installed: AgentSetup.windsurfInstalled ? true : nil,
                buttonTitle: "Copy JSON"
            ) { [weak self] in self?.copyJSON() },
        ]
    }

    // MARK: - Feedback

    private func note(_ text: String) {
        feedback.stringValue = text
        let wasHidden = feedbackPill.isHidden
        feedbackPill.isHidden = false
        if wasHidden {
            // Growth lands on the house bounce: the pill pushes the bottom edge.
            CCMotion.expand(feedbackPill)
        } else {
            CCMotion.fadeContentSwap(feedback)
        }
    }

    private func copyToPasteboard(_ text: String, note message: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        note(message)
    }

    // MARK: - Actions

    private func installCursor() {
        guard let url = AgentSetup.cursorDeepLink else { return }
        if AgentSetup.cursorInstalled {
            NSWorkspace.shared.open(url)
            note("Opened Cursor — confirm the install prompt there.")
        } else {
            copyToPasteboard(AgentSetup.standardJSON,
                             note: "Cursor isn't installed — copied the JSON instead.")
        }
    }

    private func installClaudeDesktop() {
        do {
            let bundle = try AgentSetup.buildMCPB()
            if AgentSetup.claudeDesktopInstalled {
                NSWorkspace.shared.open(bundle)
                note("Opened the extension bundle — confirm the install in Claude Desktop.")
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([bundle])
                note("Claude Desktop isn't installed — the .mcpb is in the revealed folder for later.")
            }
        } catch {
            copyToPasteboard(AgentSetup.standardJSON,
                             note: "Bundle failed (\(error.localizedDescription)) — copied the JSON instead.")
        }
    }

    private func installViaTerminal(_ command: String, client: String) {
        if let error = AgentSetup.runInTerminal(command) {
            // Automation refused (or Terminal unavailable) — degrade to copy.
            copyToPasteboard(command,
                             note: "Couldn't drive Terminal (\(error)) — copied the command instead.")
        } else {
            note("Running the \(client) setup in Terminal — it takes a second. Restart \(client) afterwards.")
        }
    }

    private func installVSCode() {
        guard let url = AgentSetup.vsCodeDeepLink else { return }
        if AgentSetup.vsCodeInstalled {
            NSWorkspace.shared.open(url)
            note("Opened VS Code — confirm the install prompt there.")
        } else {
            copyToPasteboard(AgentSetup.standardJSON,
                             note: "VS Code isn't installed — copied the JSON instead.")
        }
    }

    private func copyJSON() {
        copyToPasteboard(AgentSetup.standardJSON,
                         note: "Copied the standard MCP JSON — paste into your client's MCP config.")
    }
}
