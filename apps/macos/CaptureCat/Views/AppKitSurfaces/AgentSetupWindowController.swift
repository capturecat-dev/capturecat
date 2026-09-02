import AppKit

/// "Connect AI Agents" — one row per client, best mechanism each platform
/// offers (see AgentSetup). Flat house styling; no stock bezels.
final class AgentSetupViewController: NSViewController {

    private let stack = NSStackView()
    private let feedback = NSTextField(labelWithString: "")

    // Retheme chrome live; one observation covers the whole surface.
    private var themeObservation: CCThemeObservation?
    private let titleLabel = NSTextField(labelWithString: "Connect AI Agents")
    private var subtitleLabel: NSTextField?
    private var rowViews: [NSView] = []
    private var rowNameLabels: [NSTextField] = []
    private var rowDetailLabels: [NSTextField] = []

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        view = root

        let title = titleLabel
        title.font = .systemFont(ofSize: 17, weight: .semibold)

        let subtitle = NSTextField(wrappingLabelWithString:
            "Let Claude, Cursor, Codex or any MCP client drive CaptureCat — "
            + "record, edit, see rendered frames, and export. Pick your client:")
        subtitle.font = .systemFont(ofSize: 12)
        subtitleLabel = subtitle

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8

        stack.addArrangedSubview(title)
        stack.addArrangedSubview(subtitle)
        stack.setCustomSpacing(16, after: subtitle)

        addRow(
            name: "Cursor",
            detail: AgentSetup.cursorInstalled ? "Installed — one click" : "Opens Cursor's installer",
            buttonTitle: "Install",
            action: #selector(installCursor)
        )
        addRow(
            name: "Claude Desktop",
            detail: AgentSetup.claudeDesktopInstalled
                ? "Installed — opens the extension installer"
                : "Builds a one-click .mcpb bundle",
            buttonTitle: "Install",
            action: #selector(installClaudeDesktop)
        )
        addRow(
            name: "Claude Code",
            detail: "Runs `claude mcp add` in Terminal for you (one-time automation consent)",
            buttonTitle: "Install",
            action: #selector(installClaudeCode)
        )
        addRow(
            name: "Codex (app & CLI)",
            detail: "Runs `codex mcp add` in Terminal — the Codex desktop app reads the same config",
            buttonTitle: "Install",
            action: #selector(installCodex)
        )
        addRow(
            name: "VS Code (Copilot)",
            detail: AgentSetup.vsCodeInstalled
                ? "Installed — opens VS Code's install prompt"
                : "Opens VS Code's install prompt",
            buttonTitle: "Install",
            action: #selector(installVSCode)
        )
        addRow(
            name: "Windsurf & others",
            detail: "Copies the standard MCP JSON for any client's config",
            buttonTitle: "Copy JSON",
            action: #selector(copyJSON)
        )

        feedback.font = .systemFont(ofSize: 11, weight: .medium)
        stack.setCustomSpacing(14, after: stack.arrangedSubviews.last ?? subtitle)
        stack.addArrangedSubview(feedback)

        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            root.bottomAnchor.constraint(greaterThanOrEqualTo: stack.bottomAnchor, constant: 22),
            root.widthAnchor.constraint(equalToConstant: 480),
        ])
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    /// All chrome colors in one place so init and theme changes share a path.
    private func applyTheme() {
        view.layer?.backgroundColor = EditorThemeKit.windowBackground.cgColor
        titleLabel.textColor = EditorThemeKit.textPrimary
        subtitleLabel?.textColor = EditorThemeKit.textSecondary
        feedback.textColor = EditorThemeKit.textSecondary
        // Row card wash is ink-relative so it reads in both themes.
        let ink: NSColor = CCTheme.isDark ? .white : .black
        for row in rowViews {
            row.layer?.backgroundColor = ink.withAlphaComponent(0.05).cgColor
            row.layer?.borderColor = EditorThemeKit.hairline.cgColor
        }
        for label in rowNameLabels { label.textColor = EditorThemeKit.textPrimary }
        for label in rowDetailLabels { label.textColor = EditorThemeKit.textSecondary }
    }

    // MARK: - Rows

    private func addRow(name: String, detail: String, buttonTitle: String, action: Selector) {
        let row = NSView()
        row.wantsLayer = true
        row.layer?.cornerRadius = CCTheme.radius(.lg)
        row.layer?.cornerCurve = .continuous
        row.layer?.borderWidth = 1
        row.translatesAutoresizingMaskIntoConstraints = false
        rowViews.append(row)

        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        rowNameLabels.append(nameLabel)

        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.lineBreakMode = .byTruncatingTail
        rowDetailLabels.append(detailLabel)

        let text = NSStackView(views: [nameLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        let button = flatButton(title: buttonTitle, action: action)

        let h = NSStackView(views: [text, NSView(), button])
        h.orientation = .horizontal
        h.alignment = .centerY
        h.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 12)
        h.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(h)
        NSLayoutConstraint.activate([
            h.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            h.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            h.topAnchor.constraint(equalTo: row.topAnchor),
            h.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            row.widthAnchor.constraint(equalToConstant: 432),
        ])
        stack.addArrangedSubview(row)
    }

    /// Shared house button — no stock AppKit cell or bezel.
    private func flatButton(title: String, action: Selector) -> CaptureCatButton {
        let button = CaptureCatButton(title: title, style: .secondary, height: 28) { [weak self] in
            guard let self else { return }
            NSApp.sendAction(action, to: self, from: nil)
        }
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 110),
        ])
        return button
    }

    private func note(_ text: String) {
        feedback.stringValue = text
    }

    private func copyToPasteboard(_ text: String, note message: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        note(message)
    }

    // MARK: - Actions

    @objc private func installCursor() {
        guard let url = AgentSetup.cursorDeepLink else { return }
        if AgentSetup.cursorInstalled {
            NSWorkspace.shared.open(url)
            note("Opened Cursor — confirm the install prompt there.")
        } else {
            copyToPasteboard(AgentSetup.standardJSON,
                             note: "Cursor isn't installed — copied the JSON instead.")
        }
    }

    @objc private func installClaudeDesktop() {
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

    @objc private func installClaudeCode() {
        installViaTerminal(AgentSetup.claudeCodeCommand, client: "Claude Code")
    }

    @objc private func installCodex() {
        installViaTerminal(AgentSetup.codexCommand, client: "Codex")
    }

    private func installViaTerminal(_ command: String, client: String) {
        if let error = AgentSetup.runInTerminal(command) {
            // Automation refused (or Terminal unavailable) — degrade to copy.
            copyToPasteboard(command,
                             note: "Couldn't drive Terminal (\(error)) — copied the command instead.")
        } else {
            note("Running the \(client) setup in Terminal — it takes a second.")
        }
    }

    @objc private func installVSCode() {
        guard let url = AgentSetup.vsCodeDeepLink else { return }
        if AgentSetup.vsCodeInstalled {
            NSWorkspace.shared.open(url)
            note("Opened VS Code — confirm the install prompt there.")
        } else {
            copyToPasteboard(AgentSetup.standardJSON,
                             note: "VS Code isn't installed — copied the JSON instead.")
        }
    }

    @objc private func copyJSON() {
        copyToPasteboard(AgentSetup.standardJSON,
                         note: "Copied the standard MCP JSON — paste into your client's MCP config.")
    }
}
