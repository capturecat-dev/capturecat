import UIKit
import UserNotifications

/// Account → Connect AI: edit with your own AI, the way the Mac's "Connect an
/// agent" window does — but through the CLOUD MCP server
/// (`https://mcp.capturecat.so/mcp`), since an iPhone can't run a local one.
/// No API key lives in the app: Claude and ChatGPT sign in to CaptureCat
/// (OAuth) at that URL, edit cloud projects server-side with the editor's own
/// op layer, and the phone syncs the result (StudioAgentEdits).
///
/// - Add to Claude / ChatGPT: Claude's link opens its app with the connector
///   filled in; ChatGPT has no such link, so the URL is copied and its
///   Plugins page opened.
/// - A switch over each app's steps (from their current help pages), the URL
///   to copy, and for other clients a copyable JSON block.
/// - Connected: apps that signed in with CaptureCat and personal tokens, each
///   revocable (house confirm).
/// - The `agentEditing` plan gate: without it, the upgrade path instead of
///   steps that would fail.
/// - "Tell me when AI finishes": the notification permission the
///   "AI finished editing" push needs.
final class ConnectAIViewController: DetailPageViewController {
    enum Client: Int, CaseIterable { case claude, chatGPT, gemini, codex, other }

    private let lead = ccLabel("", font: CCFont.body, color: CCTheme.color.mutedForeground, lines: 0)
    private let planSlot = UIStackView()
    /// One chip per app (five don't fit a segmented control on a phone; chips wrap).
    private let switcher = CCChipGroup(items: [
        String(localized: "Claude", comment: "Connect AI: the Claude choice"),
        String(localized: "ChatGPT", comment: "Connect AI: the ChatGPT choice"),
        String(localized: "Gemini", comment: "Connect AI: the Gemini choice"),
        String(localized: "Codex", comment: "Connect AI: the Codex choice"),
        String(localized: "Other apps", comment: "Connect AI: the choice for any other AI app"),
    ], mode: .single, selected: [0])
    private let guideCard = CCCard(radius: .lg)
    private let guideStack = UIStackView()
    private let connectedStack = UIStackView()
    private let connectedSpinner = CCSpinner(diameter: 16)
    private let notifyRow = UIStackView()
    private var state: AgentAccessState?
    private(set) var client: Client = .claude
    private var loadError: CCCallout?

    // MARK: Probe seams (the gate) — DEBUG only, never in the shipped binary
    #if DEBUG
    var probeState: AgentAccessState? { state }
    var probeGuideCard: UIView { guideCard }
    var probeAddCard: UIView { addCard }
    var probeSwitcher: CCChipGroup { switcher }
    private(set) var probeRevokeButtons: [CCButton] = []
    private(set) var probeUpgradeCallout: UIView?
    private(set) var probeRevokeAlert: CCAlert?
    private(set) weak var probeAddAlert: CCAlert?
    /// Links go here instead of leaving the app.
    var probeOpen: ((URL) -> Void)?
    #endif
    var onLoaded: (() -> Void)?
    #if DEBUG
    /// The l10n audit (no server): the state to show instead of the API's.
    static var probeLoader: (@MainActor () async throws -> AgentAccessState)?
    #endif

    init() {
        super.init(title: String(localized: "Connect AI", comment: "Title of the screen that connects Claude, ChatGPT or another AI app"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        lead.text = String(localized: "Let Claude, ChatGPT, Gemini, Codex or another AI app edit your cloud projects — zooms, trims, captions, speed-ups, the look — with CaptureCat's own editing tools. Use your own AI account; nothing to install on this \(ThisDevice.noun). Edits appear here, and you can undo them.", comment: "Connect AI: introduction; the argument is iPhone or iPad")
        column.addArrangedSubview(lead)
        state = AgentAccessCache.last
        renderAddCard()
        planSlot.axis = .vertical
        column.addArrangedSubview(planSlot)
        column.addArrangedSubview(makeAddSection())
        column.addArrangedSubview(makeURLSection())

        switcher.accessibilityLabel = String(localized: "AI app", comment: "Connect AI: VoiceOver label of the app switcher")
        switcher.onChange = { [weak self] selection in
            guard let index = selection.min() else { return }
            self?.show(Client(rawValue: index) ?? .claude, animated: true)
        }
        guideStack.axis = .vertical
        guideStack.spacing = CCSpace.md
        guideStack.translatesAutoresizingMaskIntoConstraints = false
        guideCard.addSubview(guideStack)
        NSLayoutConstraint.activate([
            guideStack.leadingAnchor.constraint(equalTo: guideCard.leadingAnchor, constant: CCSpace.lg),
            guideStack.trailingAnchor.constraint(equalTo: guideCard.trailingAnchor, constant: -CCSpace.lg),
            guideStack.topAnchor.constraint(equalTo: guideCard.topAnchor, constant: CCSpace.lg),
            guideStack.bottomAnchor.constraint(equalTo: guideCard.bottomAnchor, constant: -CCSpace.lg),
        ])
        let guide = UIStackView(arrangedSubviews: [sectionLabel(String(localized: "Set it up", comment: "Connect AI: section heading over the setup steps")), switcher, guideCard])
        guide.axis = .vertical
        guide.spacing = CCSpace.sm
        guide.setCustomSpacing(CCSpace.md, after: switcher)
        column.addArrangedSubview(guide)
        show(.claude, animated: false)

        column.addArrangedSubview(makeConnectedSection())
        column.addArrangedSubview(makeNotifySection())
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        reload()
        renderNotify()
    }

    // MARK: - Add to …

    private let addCard = ActionListCard()

    /// The two Add rows; each carries "Connected" once that app has signed in.
    private func renderAddCard() {
        let connected = String(localized: "connectAI.connected", defaultValue: "Connected", comment: "Badge on Add to Claude / Add to ChatGPT and the Account's Connect AI row once an AI app is connected")
        addCard.setActions([
            .init(title: String(localized: "Add to Claude", comment: "Connect AI: button that opens Claude with CaptureCat's connector filled in"), symbol: "plus", image: ProviderMark.claude.image(),
                  badge: state?.isConnected(.claude) == true ? connected : nil) { [weak self] _ in self?.add(to: .claude) },
            .init(title: String(localized: "Add to ChatGPT", comment: "Connect AI: button that copies the connector URL and opens ChatGPT's plugins"), symbol: "plus", image: ProviderMark.openAI.image(),
                  badge: state?.isConnected(.chatGPT) == true ? connected : nil) { [weak self] _ in self?.add(to: .chatGPT) },
        ])
    }

    private func makeAddSection() -> UIView {
        let section = UIStackView(arrangedSubviews: [sectionLabel(String(localized: "Add CaptureCat to your AI", comment: "Connect AI: section heading over the Add to Claude and Add to ChatGPT buttons")), addCard])
        section.axis = .vertical
        section.spacing = CCSpace.sm
        return section
    }

    /// Claude: one tap. ChatGPT: the URL is copied, and what to tap there is
    /// said before this app leaves the screen.
    func add(to client: Client) {
        if self.client != client { show(client, animated: true) }
        switch client {
        case .claude:
            open(AgentConnect.claudeAddURL)
        case .chatGPT:
            copyThenOpen(AgentConnect.chatGPTPluginsURL,
                         message: String(localized: "In ChatGPT's Plugins, choose +, then Add custom MCP server, and paste it. ChatGPT does this in the browser, and editing needs a Business, Enterprise or Edu plan.", comment: "Connect AI: alert after copying the connector URL, before opening ChatGPT"),
                         confirm: String(localized: "Open ChatGPT", comment: "Button that opens chatgpt.com in the browser"))
        case .gemini, .codex, .other:
            break
        }
    }

    private func copyThenOpen(_ url: URL, message: String, confirm: String) {
        UIPasteboard.general.string = AgentConnect.mcpURL
        let alert = CCAlert(title: String(localized: "Connector URL copied", comment: "Connect AI: alert title"), message: message)
        alert.presentation = .sheet
        alert.addButton(confirm, role: .primary)
        alert.addButton(String(localized: "Cancel", comment: "Cancel button"), role: .cancel)
        #if DEBUG
        probeAddAlert = alert
        #endif
        alert.present(from: self) { [weak self] index in
            if index == 0 { self?.open(url) }
        }
    }

    private func open(_ url: URL) {
        #if DEBUG
        if let probeOpen { return probeOpen(url) }
        #endif
        UIApplication.shared.open(url)
    }

    // MARK: - Connector URL

    private func makeURLSection() -> UIView {
        let detail = ccLabel(String(localized: "Claude, ChatGPT, Gemini and Codex sign in to CaptureCat with this address — no key or token to copy.", comment: "Connect AI: under the connector URL"),
                             font: CCFont.caption, color: CCTheme.color.mutedForeground, lines: 0)
        let card = CCCard(radius: .lg)
        let stack = UIStackView(arrangedSubviews: [CodeWell(text: AgentConnect.mcpURL, copyTitle: String(localized: "Copy URL", comment: "Button that copies the connector URL"), inline: true), detail])
        stack.axis = .vertical
        stack.spacing = CCSpace.sm
        pad(stack, in: card)
        let section = UIStackView(arrangedSubviews: [sectionLabel(String(localized: "Connector URL", comment: "Connect AI: section heading over the MCP URL")), card])
        section.axis = .vertical
        section.spacing = CCSpace.sm
        return section
    }

    // MARK: - Guides

    func show(_ client: Client, animated: Bool) {
        self.client = client
        if switcher.selectedIndex != client.rawValue { switcher.setSelection([client.rawValue]) }
        let content: [UIView]
        switch client {
        case .claude: content = claudeGuide()
        case .chatGPT: content = chatGPTGuide()
        case .gemini: content = geminiGuide()
        case .codex: content = codexGuide()
        case .other: content = otherGuide()
        }
        let swap = {
            self.guideStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            content.forEach { self.guideStack.addArrangedSubview($0) }
        }
        guard animated, view.window != nil else {
            swap()
            return
        }
        // The card grows/shrinks on the house bounce (its bottom edge is the
        // pushed one); the new steps rise in.
        swap()
        CCMotion.springViews(.smooth, crossFading: guideCard) { self.view.layoutIfNeeded() }
        CCMotion.fadeAlpha(guideStack, to: 1, duration: 0.22, from: 0)
        CCMotion.enter(guideStack.layer, .slideUp(distance: 10))
    }

    private func claudeGuide() -> [UIView] {
        [
            guideTitle(String(localized: "Add CaptureCat to Claude", comment: "Connect AI: Claude guide title")),
            steps([
                String(localized: "Tap Add to Claude. Claude opens with CaptureCat's name and address filled in.", comment: "Claude step 1"),
                String(localized: "Check the address and add the connector.", comment: "Claude step 2"),
                String(localized: "Sign in to CaptureCat and allow access.", comment: "Claude step 4"),
                String(localized: "In a chat, open + → Connectors and turn on CaptureCat. It then works in the Claude app on this \(ThisDevice.noun) too.", comment: "Claude step 5; the argument is iPhone or iPad"),
            ]),
            note(String(localized: "If the form doesn't open, add it on claude.ai or in the Claude desktop app: Customize → Connectors → + Add → Add custom connector. On a Team or Enterprise plan an owner adds it under Organization settings → Connectors.", comment: "Connect AI: Claude caveat")),
        ]
    }

    private func chatGPTGuide() -> [UIView] {
        [
            guideTitle(String(localized: "Add CaptureCat to ChatGPT", comment: "Connect AI: ChatGPT guide title")),
            steps([
                String(localized: "On chatgpt.com, open Plugins.", comment: "ChatGPT step 1"),
                String(localized: "Choose +, then Add custom MCP server.", comment: "ChatGPT step 2"),
                String(localized: "Name it CaptureCat, paste the connector URL under Connection and choose OAuth sign-in.", comment: "ChatGPT step 3"),
                String(localized: "Confirm, choose Create as a plugin, install it and sign in to CaptureCat.", comment: "ChatGPT step 4"),
                String(localized: "In a chat, type @CaptureCat (or + → Plugins) and ask for an edit.", comment: "ChatGPT step 5"),
            ]),
            note(String(localized: "ChatGPT adds custom MCP servers on the web only, and editing needs a workspace plan that allows them (Business, Enterprise or Edu).", comment: "Connect AI: ChatGPT caveat")),
            openButton(String(localized: "Open ChatGPT plugins", comment: "Button that opens chatgpt.com's plugins page"), AgentConnect.chatGPTPluginsURL),
        ]
    }

    private func geminiGuide() -> [UIView] {
        [
            guideTitle(String(localized: "Add CaptureCat to Gemini", comment: "Connect AI: Gemini guide title")),
            steps([
                String(localized: "On gemini.google.com, open Settings → Connected Apps → Custom apps.", comment: "Gemini step 1"),
                String(localized: "Choose Add a custom app, paste the connector URL and choose Next.", comment: "Gemini step 2"),
                String(localized: "Sign in to CaptureCat and allow access.", comment: "Gemini step 3"),
                String(localized: "Ask Gemini for an edit. It then works in the Gemini app on this \(ThisDevice.noun) too.", comment: "Gemini step 4; the argument is iPhone or iPad"),
            ]),
            note(String(localized: "Google offers custom apps in the Gemini app only to personal Google Accounts in the US, aged 18 or over, in English, and adds them on the web. Work and school accounts can't add them yet.", comment: "Connect AI: Gemini app caveat")),
            openButton(String(localized: "Open Gemini", comment: "Button that opens gemini.google.com"), AgentConnect.geminiURL),
            subTitle(String(localized: "Gemini CLI", comment: "Connect AI: Gemini CLI subheading")),
            note(String(localized: "Run this on your computer, then sign in when Gemini CLI asks (or type /mcp auth capturecat):", comment: "Connect AI: Gemini CLI explanation")),
            CodeWell(text: AgentConnect.geminiCommand, copyTitle: String(localized: "Copy command", comment: "Button that copies a terminal command"), inline: false),
            note(String(localized: "Gemini Code Assist and Gemini Enterprise take the same URL in their MCP settings — see Other apps.", comment: "Connect AI: other Gemini surfaces")),
        ]
    }

    private func codexGuide() -> [UIView] {
        [
            guideTitle(String(localized: "Add CaptureCat to Codex", comment: "Connect AI: Codex guide title")),
            note(String(localized: "Run these on your computer — the second signs Codex in to CaptureCat:", comment: "Connect AI: Codex CLI explanation")),
            CodeWell(text: AgentConnect.codexCommand, copyTitle: String(localized: "Copy commands", comment: "Button that copies terminal commands"), inline: false),
            note(String(localized: "Or add it to ~/.codex/config.toml, which the Codex CLI, IDE extension and desktop app share:", comment: "Connect AI: Codex config explanation")),
            CodeWell(text: AgentConnect.codexConfig, copyTitle: String(localized: "Copy config", comment: "Button that copies a config snippet"), inline: false),
            note(String(localized: "In the IDE extension or the desktop app you can also open Settings → MCP servers → Add server, choose Streamable HTTP and paste the connector URL. Codex cloud tasks can't use custom MCP servers yet.", comment: "Connect AI: Codex other surfaces")),
        ]
    }

    private func subTitle(_ text: String) -> UIView {
        let label = ccLabel(text, font: CCFont.labelSemibold, color: CCTheme.color.foreground, lines: 0)
        label.accessibilityTraits = .header
        return label
    }

    private func otherGuide() -> [UIView] {
        [
            guideTitle(String(localized: "Any app that speaks MCP", comment: "Connect AI: other-clients guide title")),
            note(String(localized: "Add a remote (HTTP) MCP server with the connector URL. Apps that support sign-in connect like Claude does; most accept this block in their MCP settings:", comment: "Connect AI: other-clients explanation")),
            CodeWell(text: AgentConnect.jsonConfig, copyTitle: String(localized: "Copy JSON", comment: "Button that copies the MCP JSON block"), inline: false),
            note(String(localized: "An app that can't sign in needs a personal token: make one on the web in Settings → Agent access.", comment: "Connect AI: token fallback")),
        ]
    }

    private func guideTitle(_ text: String) -> UIView {
        let label = ccLabel(text, font: CCFont.header, color: CCTheme.color.foreground, lines: 0)
        label.accessibilityTraits = .header
        return label
    }

    private func steps(_ items: [String]) -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = CCSpace.md
        for (index, text) in items.enumerated() {
            let number = StepNumber(index + 1)
            let label = ccLabel(text, font: CCFont.label, color: CCTheme.color.foreground, lines: 0)
            let row = UIStackView(arrangedSubviews: [number, label])
            row.spacing = CCSpace.md
            row.alignment = .firstBaseline
            row.isAccessibilityElement = true
            row.accessibilityLabel = String(localized: "Step \(index + 1): \(text)", comment: "VoiceOver: a numbered setup step")
            stack.addArrangedSubview(row)
        }
        return stack
    }

    private func note(_ text: String) -> UIView {
        ccLabel(text, font: CCFont.caption, color: CCTheme.color.mutedForeground, lines: 0)
    }

    private func openButton(_ title: String, _ url: URL) -> UIView {
        let button = CCButton(title: title, symbol: "arrow-up-right", style: .outline, size: .regular)
        button.accessibilityHint = String(localized: "Opens in your browser.", comment: "VoiceOver hint for buttons that open a web page")
        button.onTap = { UIApplication.shared.open(url) }
        return UIStackView(arrangedSubviews: [button, UIView()])
    }

    // MARK: - Connected

    private func makeConnectedSection() -> UIView {
        connectedStack.axis = .vertical
        connectedStack.spacing = 0
        let title = sectionLabel(String(localized: "Connected", comment: "Connect AI: section heading over the connected agents"))
        connectedSpinner.color = CCTheme.color.mutedForeground
        let heading = UIStackView(arrangedSubviews: [title, UIView(), connectedSpinner])
        heading.alignment = .center
        let card = CCCard(radius: .lg)
        pad(connectedStack, in: card, inset: CCSpace.md)
        let section = UIStackView(arrangedSubviews: [heading, card])
        section.axis = .vertical
        section.spacing = CCSpace.sm
        renderConnections()
        return section
    }

    func reload() {
        connectedSpinner.startAnimating()
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.connectedSpinner.stopAnimating() }
            do {
                #if DEBUG
                let state: AgentAccessState
                if let loader = Self.probeLoader { state = try await loader() } else { state = try await APIClient.shared.agentAccess() }
                #else
                let state = try await APIClient.shared.agentAccess()
                #endif
                self.loadError?.removeFromSuperview()
                self.loadError = nil
                self.state = state
                AgentAccessCache.last = state
                self.renderAddCard()
                self.renderPlan()
                self.renderConnections()
            } catch {
                if self.loadError == nil {
                    let callout = CCCallout(message: String(localized: "Couldn't load your AI connections. \(error.localizedDescription)", comment: "Connect AI: load error; the argument is the reason"), variant: .warning)
                    self.connectedStack.insertArrangedSubview(callout, at: 0)
                    self.loadError = callout
                }
            }
            self.onLoaded?()
        }
    }

    private func renderPlan() {
        planSlot.arrangedSubviews.forEach { $0.removeFromSuperview() }
        #if DEBUG
        probeUpgradeCallout = nil
        #endif
        guard let state, !state.agentEditing else { return }
        let plan = state.planName ?? String(localized: "current", comment: "Plan name fallback, as in 'your current plan'")
        let message = state.agentAccess
            ? String(localized: "Your \(plan) plan lets an AI read your projects but not edit them. Editing with AI comes with CaptureCat Pro — upgrade at app.capturecat.so/billing, then come back here.", comment: "Connect AI: plan has agent access but not editing; the argument is the plan name")
            : String(localized: "Editing with AI isn't included in your \(plan) plan. It comes with CaptureCat Pro — upgrade at app.capturecat.so/billing, then come back here.", comment: "Connect AI: plan has no agent access; the argument is the plan name")
        let callout = CCCallout(title: String(localized: "Upgrade to edit with AI", comment: "Connect AI: upgrade callout title"), message: message, variant: .warning)
        planSlot.addArrangedSubview(callout)
        #if DEBUG
        probeUpgradeCallout = callout
        #endif
        if view.window != nil { CCMotion.enter(callout.layer, .slideDown(distance: 8)) }
    }

    private func renderConnections() {
        connectedStack.arrangedSubviews.filter { $0 !== loadError }.forEach { $0.removeFromSuperview() }
        #if DEBUG
        probeRevokeButtons = []
        #endif
        guard let state else {
            connectedStack.addArrangedSubview(emptyRow(String(localized: "Checking…", comment: "Connect AI: connected list while loading")))
            return
        }
        guard !state.connections.isEmpty else {
            connectedStack.addArrangedSubview(emptyRow(String(localized: "No AI is connected yet. Once Claude or ChatGPT signs in to CaptureCat, it shows up here.", comment: "Connect AI: empty connected list")))
            return
        }
        var rows: [UIView] = []
        for (index, connection) in state.connections.enumerated() {
            if index > 0 { connectedStack.addArrangedSubview(CCDivider()) }
            let row = connectionRow(connection)
            connectedStack.addArrangedSubview(row)
            rows.append(row)
        }
        if view.window != nil { CCMotion.stagger(rows) }
    }

    private func emptyRow(_ text: String) -> UIView {
        let label = ccLabel(text, font: CCFont.label, color: CCTheme.color.mutedForeground, lines: 0)
        let wrap = UIStackView(arrangedSubviews: [label])
        wrap.isLayoutMarginsRelativeArrangement = true
        wrap.directionalLayoutMargins = NSDirectionalEdgeInsets(top: CCSpace.sm, leading: CCSpace.xs, bottom: CCSpace.sm, trailing: CCSpace.xs)
        return wrap
    }

    private func connectionRow(_ connection: AgentConnection) -> UIView {
        let icon = CCIconView(connection.kind.isApp ? "sparkles" : "terminal", pointSize: 17, weight: .medium, tint: CCTheme.color.mutedForeground)
        let name = ccLabel(connection.name, font: CCFont.bodyMedium, color: CCTheme.color.foreground, lines: 2)
        let detail = ccLabel(Self.detail(for: connection), font: CCFont.caption, color: CCTheme.color.mutedForeground, lines: 0)
        let text = UIStackView(arrangedSubviews: [name, detail])
        text.axis = .vertical
        text.spacing = 2
        let revoke = CCButton(title: String(localized: "Revoke", comment: "Button that disconnects an AI app"), style: .outline, size: .sm)
        revoke.accessibilityLabel = String(localized: "Revoke \(connection.name)", comment: "VoiceOver: revoke an AI connection; the argument is its name")
        revoke.onTap = { [weak self] in self?.confirmRevoke(connection) }
        revoke.setContentCompressionResistancePriority(.required, for: .horizontal)
        #if DEBUG
        probeRevokeButtons.append(revoke)
        #endif
        let row = UIStackView(arrangedSubviews: [icon, text, revoke])
        row.spacing = CCSpace.md
        row.alignment = .center
        row.ccStacksAtAccessibilitySizes()
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: CCSpace.sm, leading: CCSpace.xs, bottom: CCSpace.sm, trailing: 0)
        return row
    }

    static func detail(for connection: AgentConnection) -> String {
        var parts: [String] = []
        parts.append(connection.kind.isApp
            ? String(localized: "Signed in with CaptureCat", comment: "Connect AI: an app that connected by OAuth")
            : String(localized: "Personal token", comment: "Connect AI: a token made on the web"))
        if !connection.canEdit { parts.append(String(localized: "can't edit projects", comment: "Connect AI: a connection without the projects:write scope")) }
        if let used = connection.lastUsedAt {
            let relative = RelativeDateTimeFormatter()
            relative.unitsStyle = .short
            parts.append(String(localized: "used \(relative.localizedString(for: used, relativeTo: Date()))", comment: "Connect AI: last use, e.g. 'used 2 hr. ago'"))
        } else if let connected = connection.connectedAt {
            parts.append(String(localized: "connected \(connected.formatted(date: .abbreviated, time: .omitted))", comment: "Connect AI: when it connected"))
        }
        return parts.joined(separator: " · ")
    }

    private func confirmRevoke(_ connection: AgentConnection) {
        let alert = CCAlert(
            title: String(localized: "Revoke \(connection.name)?", comment: "Confirm title: disconnect an AI app; the argument is its name"),
            message: connection.kind.isApp
                ? String(localized: "\(connection.name) loses access to your CaptureCat account at once. To use it again, connect it again in that app.", comment: "Confirm message: revoke an OAuth app")
                : String(localized: "The token stops working at once. Anything using it loses access to your CaptureCat account.", comment: "Confirm message: revoke a personal token"))
        alert.symbol = "close"
        alert.tone = .destructive
        alert.presentation = .sheet
        alert.addButton(String(localized: "Revoke", comment: "Confirm button: revoke"), role: .destructive) {
            try await APIClient.shared.revoke(connection)
        }
        alert.addButton(String(localized: "Cancel", comment: "Cancel button"), role: .cancel)
        #if DEBUG
        probeRevokeAlert = alert
        #endif
        alert.present(from: self) { [weak self] index in
            guard index == 0 else { return }
            CCHaptics.success()
            AppToaster.shared.show(title: String(localized: "\(connection.name) revoked", comment: "Toast after revoking; the argument is its name"), variant: .success, symbol: "check")
            self?.reload()
        }
    }

    // MARK: - Notifications

    private func makeNotifySection() -> UIView {
        notifyRow.axis = .vertical
        notifyRow.spacing = CCSpace.md
        let card = CCCard(radius: .lg)
        pad(notifyRow, in: card)
        let section = UIStackView(arrangedSubviews: [sectionLabel(String(localized: "Notifications", comment: "Connect AI: section heading")), card])
        section.axis = .vertical
        section.spacing = CCSpace.sm
        return section
    }

    private func renderNotify() {
        Task { @MainActor [weak self] in
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            guard let self else { return }
            self.notifyRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
            let icon = CCIconView("bell", pointSize: 17, weight: .medium, tint: CCTheme.color.mutedForeground)
            let title = ccLabel(String(localized: "Tell me when AI finishes editing", comment: "Connect AI: notification row title"), font: CCFont.labelSemibold, color: CCTheme.color.foreground, lines: 0)
            let words: String
            var button: CCButton?
            switch status {
            case .authorized, .provisional, .ephemeral:
                words = String(localized: "On. You'll get a notification when your AI finishes editing a project.", comment: "Connect AI: notifications allowed")
            case .denied:
                words = String(localized: "Notifications for CaptureCat are off in Settings.", comment: "Connect AI: notifications denied")
                button = CCButton(title: String(localized: "Open Settings", comment: "Button that opens the app's iOS Settings"), style: .outline, size: .regular)
                button?.onTap = {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            default:
                words = String(localized: "Get a notification when your AI finishes editing a project.", comment: "Connect AI: notifications not asked yet")
                button = CCButton(title: String(localized: "Turn On", comment: "Button that asks for notification permission"), style: .primary, size: .regular)
                button?.onTap = { [weak self] in
                    Task { @MainActor in
                        await DeviceRegistry.shared.requestPushPermission()
                        await DeviceRegistry.shared.register()
                        self?.renderNotify()
                    }
                }
            }
            let detail = ccLabel(words, font: CCFont.caption, color: CCTheme.color.mutedForeground, lines: 0)
            let text = UIStackView(arrangedSubviews: [title, detail])
            text.axis = .vertical
            text.spacing = CCSpace.xs
            let top = UIStackView(arrangedSubviews: [icon, text])
            top.spacing = CCSpace.md
            top.alignment = .top
            self.notifyRow.addArrangedSubview(top)
            if let button { self.notifyRow.addArrangedSubview(UIStackView(arrangedSubviews: [button, UIView()])) }
        }
    }

    // MARK: - Layout

    private func pad(_ content: UIView, in card: CCCard, inset: CGFloat = CCSpace.lg) {
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -inset),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: inset),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -inset),
        ])
    }
}

private extension AgentConnection.Kind {
    var isApp: Bool { if case .app = self { return true } else { return false } }
}

/// A step's number in a small recessed disc.
private final class StepNumber: UIView {
    private let label: UILabel

    init(_ number: Int) {
        label = ccLabel("\(number)", font: CCFont.captionMedium, color: CCTheme.color.foreground, alignment: .center)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 24), heightAnchor.constraint(equalToConstant: 24),
            label.centerXAnchor.constraint(equalTo: centerXAnchor), label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        isAccessibilityElement = false
        ccOnThemeChange { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var forFirstBaselineLayout: UIView { label }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyTheme()
    }

    private func applyTheme() {
        CCMaterial.dress(layer, as: .recessed(tint: CCTheme.color.elevated), radius: bounds.height / 2, traits: traitCollection)
    }
}

/// Copyable text in a recessed well (the URL, the JSON block) with its Copy key.
final class CodeWell: UIView {
    let text: String
    private let well = RecessedWell()
    private let label: UILabel
    let copyButton: CCButton

    init(text: String, copyTitle: String, inline: Bool) {
        self.text = text
        label = ccLabel(text, font: inline ? CCFont.mono : CCFont.monoSmall, color: CCTheme.color.foreground, lines: 0)
        copyButton = CCButton(title: copyTitle, symbol: "doc.on.clipboard", style: inline ? .primary : .secondary, size: .sm)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byCharWrapping
        label.isAccessibilityElement = true
        label.accessibilityTraits = .staticText
        well.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        well.addSubview(label)
        let stack = UIStackView(arrangedSubviews: [well, UIStackView(arrangedSubviews: [copyButton, UIView()])])
        stack.axis = .vertical
        stack.spacing = CCSpace.sm
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.leadingAnchor.constraint(equalTo: well.leadingAnchor, constant: CCSpace.md),
            label.trailingAnchor.constraint(equalTo: well.trailingAnchor, constant: -CCSpace.md),
            label.topAnchor.constraint(equalTo: well.topAnchor, constant: CCSpace.sm + 2),
            label.bottomAnchor.constraint(equalTo: well.bottomAnchor, constant: -(CCSpace.sm + 2)),
        ])
        copyButton.accessibilityHint = String(localized: "Copies it to the clipboard.", comment: "VoiceOver hint for copy buttons")
        copyButton.onTap = { [weak self] in self?.copy() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func copy() {
        UIPasteboard.general.string = text
        CCHaptics.success()
        AppToaster.shared.show(title: String(localized: "Copied", comment: "Toast after copying text"), variant: .success, symbol: "check")
    }
}

/// The kit's recessed well, re-dressed whenever its size or theme changes.
private final class RecessedWell: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerCurve = .continuous
        ccOnThemeChange { [weak self] in self?.setNeedsLayout() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CCMaterial.dress(layer, as: .recessed(tint: CCTheme.color.elevated), radius: CCTheme.radius(.md), traits: traitCollection)
    }
}
