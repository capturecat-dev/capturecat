import UIKit

/// "Edit with Claude / ChatGPT" on a project: the user says what to change
/// HERE, then the AI app opens a new chat holding that request and THIS
/// project's id. The MCP tools take `projectId`, so the AI goes straight to
/// the right project instead of searching.
///
/// The request is written before leaving the app because ChatGPT's `?q=`
/// may send at once — the prompt must already be complete.
///
/// Shown only for apps that have signed in with CaptureCat (AgentAccessState);
/// with none connected — or a plan without AI editing — the one "Edit with
/// AI" item opens Connect AI, which explains the next step.
@MainActor enum AskAI {
    enum App: CaseIterable {
        case claude, chatGPT

        var provider: AgentProvider { self == .claude ? .claude : .chatGPT }
        var name: String { self == .claude ? "Claude" : "ChatGPT" }
        var mark: UIImage? { self == .claude ? ProviderMark.claude.image() : ProviderMark.openAI.image() }
        var title: String {
            switch self {
            case .claude: String(localized: "Edit with Claude", comment: "Project menu: opens Claude with a request to edit this project")
            case .chatGPT: String(localized: "Edit with ChatGPT", comment: "Project menu: opens ChatGPT with a request to edit this project")
            }
        }
    }

    /// One menu entry: a connected app, or Connect AI.
    enum Entry: Equatable {
        case app(App)
        case connect

        var title: String {
            switch self {
            case .app(let app): app.title
            case .connect: String(localized: "Edit with AI…", comment: "Project menu: no AI app connected yet; opens Connect AI")
            }
        }
        var image: UIImage? { if case .app(let app) = self { app.mark } else { nil } }
    }

    #if DEBUG
    /// Gate seam: links land here instead of leaving the app.
    static var probeOpen: ((URL) -> Void)?
    /// Gate seam: the request sheet that was shown last.
    static weak var probeSheet: CCAlert?
    static weak var probeField: CCField?
    #endif

    /// What the project menus offer, from the last loaded state.
    static var entries: [Entry] {
        guard let state = AgentAccessCache.last, state.agentEditing else { return [.connect] }
        let apps = App.allCases.filter { state.isConnected($0.provider) }
        return apps.isEmpty ? [.connect] : apps.map { .app($0) }
    }

    /// Refreshes the cached state (the menus read it synchronously); `changed`
    /// runs when the menu entries differ afterwards.
    static func refresh(changed: (() -> Void)? = nil) {
        Task { @MainActor in
            let before = entries
            guard let state = try? await APIClient.shared.agentAccess() else { return }
            AgentAccessCache.last = state
            if entries != before { changed?() }
        }
    }

    static func run(_ entry: Entry, projectID: String, name: String, from presenter: UIViewController) {
        switch entry {
        case .connect:
            openConnectAI(from: presenter)
        case .app(let app):
            askForRequest(app: app, projectID: projectID, name: name, from: presenter)
        }
    }

    // MARK: - The prompt

    /// Kept in English: it is an instruction to the AI (which answers in the
    /// user's language), and the tool parameter is literally `projectId`.
    static func prompt(request: String, projectID: String, name: String) -> String {
        "Use CaptureCat to edit my project “\(name)” (projectId: \(projectID)). \(request)"
    }

    static func url(for app: App, prompt: String) -> URL {
        var c = URLComponents(string: app == .claude ? "https://claude.ai/new" : "https://chatgpt.com/")!
        c.queryItems = [URLQueryItem(name: "q", value: prompt)]
        // URLComponents leaves "+" alone, which a server reads as a space.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url!
    }

    // MARK: - The request sheet

    private static func askForRequest(app: App, projectID: String, name: String, from presenter: UIViewController) {
        let placeholder = String(localized: "What should it change?", comment: "Edit with AI sheet: text field placeholder")
        let field = CCField(placeholder: placeholder, value: "")
        field.returnKeyType = .done
        field.autocapitalizationType = .sentences
        field.accessibilityLabel = placeholder

        let ideas = [
            String(localized: "Zoom in on each click", comment: "Edit with AI sheet: quick request"),
            String(localized: "Add captions", comment: "Edit with AI sheet: quick request"),
            String(localized: "Speed up the pauses", comment: "Edit with AI sheet: quick request"),
            String(localized: "Trim the start and end", comment: "Edit with AI sheet: quick request"),
        ]
        let chips = CCChipGroup(items: ideas, mode: .single, selected: [])
        chips.accessibilityLabel = String(localized: "Ideas", comment: "Edit with AI sheet: VoiceOver label of the quick requests")
        chips.onChange = { [weak field, weak chips] selection in
            guard let field, let index = selection.min() else { return }
            let idea = ideas[index]
            let current = (field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            field.text = current.isEmpty ? idea : "\(current). \(idea)"
            chips?.setSelection([])
        }
        let stack = UIStackView(arrangedSubviews: [field, chips])
        stack.axis = .vertical
        stack.spacing = CCSpace.md

        let alert = CCAlert(
            title: app.title,
            message: String(localized: "\(app.name) opens a new chat with your request and “\(name)”. Its edits appear here, and you can undo them.", comment: "Edit with AI sheet: message; first argument is Claude or ChatGPT, second the project name"))
        alert.presentation = .sheet
        alert.accessoryView = stack
        alert.addButton(String(localized: "Open \(app.name)", comment: "Edit with AI sheet: confirm; the argument is Claude or ChatGPT"), role: .primary) { [weak field] in
            field?.unmarkText()
            let request = (field?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !request.isEmpty else { throw CCAlertError.empty(placeholder) }
        }
        alert.addButton(String(localized: "Cancel", comment: "Cancel button"), role: .cancel)
        #if DEBUG
        probeSheet = alert
        probeField = field
        #endif
        alert.present(from: presenter) { [weak field] index in
            guard index == 0 else { return }
            let request = (field?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            open(url(for: app, prompt: prompt(request: request, projectID: projectID, name: name)))
        }
    }

    private static func openConnectAI(from presenter: UIViewController) {
        if let nav = presenter.navigationController {
            nav.pushViewController(ConnectAIViewController(), animated: true)
            return
        }
        // The editor (modal, no navigation stack): say where to go.
        let alert = CCAlert(
            title: String(localized: "Connect an AI first", comment: "Editor: Edit with AI when no AI app is connected"),
            message: String(localized: "Add CaptureCat to Claude or ChatGPT in Account → Connect AI. Then ask it to edit this project from here.", comment: "Editor: Edit with AI when no AI app is connected"))
        alert.symbol = "sparkles"
        alert.addButton(String(localized: "OK", comment: "Alert button"), role: .primary)
        alert.present(from: CCAlert.topmost(from: presenter))
    }

    private static func open(_ url: URL) {
        #if DEBUG
        if let probeOpen { return probeOpen(url) }
        #endif
        UIApplication.shared.open(url)
    }
}
