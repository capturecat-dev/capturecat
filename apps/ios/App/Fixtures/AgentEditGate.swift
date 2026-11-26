#if DEBUG
import UIKit

/// `-agentEditGate` (with `-apiBaseURL http://127.0.0.1:<port>` pointing at
/// the LOCAL TEST API — apps/api/scripts/local-test-api: the real Worker, its
/// MCP server and op layer over in-memory D1/R2, never production): Connect
/// AI and background agent edits end to end in the REAL app — real shell,
/// real window, real Account → Connect AI, the shipping editor and sync.
/// Driven by scripts/ios-agent-edit.sh.
///
///  1. Seeds a cloud project + an OAuth-connected "Claude" (+ a personal
///     token) on the local API; signs in as its owner.
///  2. Connect AI: the Account row reachable (hit-tested) and pushed; the
///     list shows Claude and the token; the URL copies; the switcher's guide
///     swap is animated (sampled mid-flight); Revoke (house confirm) removes
///     the token on the server; screenshots of each guide.
///  3. Plan gate: signed in as a Free account the upgrade callout shows.
///  4. Agent edit over UNSENT local work: the editor holds an unsent edit;
///     "Claude" calls apply_edits over HTTP (/mcp, its OAuth token); the
///     server's "AI finished editing" push (captured) is handed to the app's
///     own router → no banner (the project is open), the editor pulls, both
///     edits are there; the "Edited by Claude" notice rises (mid-flight);
///     its Undo reverts only the agent's change and pushes a new revision.
///  5. Agent edit on a clean project, noticed on FOREGROUND: Undo restores
///     the previous version on the server (a new `restore` revision), the
///     editor equals what it held before, the agent's version is still in
///     History (nothing deleted), and the editor's undo stack names it.
///
/// Prints `AGENTEDIT <check> PASS|FAIL …` and `AGENTEDIT-GATE PASS|FAIL`,
/// writes Documents/agent-edit/{gate.txt,*.png}, exits.
/// `-agentEditInject skip-notice|undo-noop` must make it FAIL.
@available(iOS 26, *)
@MainActor
final class AgentEditGate {
    static func startIfRequested(in window: UIWindow) {
        guard ProcessInfo.processInfo.arguments.contains("-agentEditGate") else { return }
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-agentEditInject"), i + 1 < args.count { StudioAgentEdits.probeInject = args[i + 1] }
        let gate = AgentEditGate(window: window)
        running = gate
        Task { await gate.run() }
    }

    private static var running: AgentEditGate?
    private let window: UIWindow
    private var lines: [String] = []
    private var failures = 0
    private let out: URL
    private var base: String { CaptureCatAPI.baseURL }

    private init(window: UIWindow) {
        self.window = window
        out = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("agent-edit", isDirectory: true)
        try? FileManager.default.removeItem(at: out)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }

    private var root: RootViewController? { window.rootViewController as? RootViewController }

    private func record(_ name: String, _ pass: Bool, _ detail: String) {
        if !pass { failures += 1 }
        let line = "AGENTEDIT \(name) \(pass ? "PASS" : "FAIL") \(detail)"
        lines.append(line)
        print(line)
    }

    private func sleep(_ ms: UInt64) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }

    private func waitFor(_ timeoutMs: Int, _ condition: () -> Bool) async -> Bool {
        var waited = 0
        while waited < timeoutMs {
            if condition() { return true }
            await sleep(25)
            waited += 25
        }
        return condition()
    }

    // MARK: - Local API

    @discardableResult
    private func call(_ method: String, _ path: String, json: Any? = nil, bearer: String? = nil) async -> (Int, [String: Any]) {
        guard let url = URL(string: base + path) else { return (0, [:]) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let json {
            request.httpBody = try? JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return (0, [:]) }
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:])
    }

    /// An agent's tool call over the MCP endpoint, as Claude makes it.
    private func agentCall(_ token: String, _ tool: String, _ arguments: [String: Any]) async -> [String: Any]? {
        let (status, body) = await call("POST", "/mcp", json: [
            "jsonrpc": "2.0", "id": Int.random(in: 1...999_999), "method": "tools/call",
            "params": ["name": tool, "arguments": arguments],
        ], bearer: token)
        guard status == 200, let result = body["result"] as? [String: Any], result["isError"] as? Bool != true else {
            print("AGENTEDIT agent call \(tool) → \(status) \(body)")
            return nil
        }
        return result["structuredContent"] as? [String: Any]
    }

    private func versions(_ projectID: String) async -> [[String: Any]] {
        (await call("GET", "/__versions/\(projectID)")).1["versions"] as? [[String: Any]] ?? []
    }

    private func pushes() async -> [[String: Any]] {
        (await call("GET", "/__pushes")).1["pushes"] as? [[String: Any]] ?? []
    }

    // MARK: - Run

    private func run() async {
        let host = URL(string: base)?.host
        guard host == "127.0.0.1" || host == "localhost" else {
            record("setup", false, "API base \(base) is not the local test API — launch with -apiBaseURL http://127.0.0.1:<port>")
            return finish()
        }
        if let inject = StudioAgentEdits.probeInject { print("AGENTEDIT inject \(inject)") }
        await sleep(600)

        // 1. Seed + sign in.
        let projectID = UUID().uuidString
        let (seedStatus, seed) = await call("POST", "/__seed", json: ["projectId": projectID, "name": "Agent demo"])
        guard seedStatus == 200, let agentToken = seed["agentToken"] as? String else {
            record("setup", false, "seed failed: \(seedStatus) \(seed)")
            return finish()
        }
        signIn(uid: "owner", name: "Olive Owner")
        let signedIn = await waitFor(5000) { root?.shell != nil }
        record("setup-signed-in", signedIn, "seeded \(projectID) at revision \(seed["revision"] ?? "?"); shell up=\(signedIn)")
        guard let shell = root?.shell else { return finish() }

        // 2. Connect AI.
        await connectAI(shell: shell)

        // 3. Plan gate (a Free account).
        await planGate(shell: shell)
        signIn(uid: "owner", name: "Olive Owner")
        await sleep(400)

        // 4 + 5. The editor.
        await editorFlow(projectID: projectID, agentToken: agentToken)
        finish()
    }

    private func signIn(uid: String, name: String) {
        let user = AccountUser(id: uid, email: "\(uid)@local.test", name: name, image: nil)
        SessionStore.save(AuthSession(token: uid, expiresAt: Date().addingTimeInterval(86_400), user: user, apiBaseURL: base))
        StudioEditorEntry.adoptLiveEnvironment()
    }

    // MARK: 2. Connect AI

    private func connectAI(shell: ShellViewController) async {
        shell.select(.account, animated: false)
        await sleep(700)
        let account = shell.account
        let row = account.probeConnectAIRow
        let frame = row.convert(row.bounds, to: window)
        let hit = window.hitTest(CGPoint(x: frame.midX, y: frame.midY), with: nil)
        let reachable = row.window === window && window.bounds.contains(CGPoint(x: frame.midX, y: frame.midY)) && (hit?.isDescendant(of: row) ?? false)
        record("entry-reachable", reachable, String(format: "Connect AI row at (%.0f, %.0f, %.0f×%.0f); hit-test → %@", frame.minX, frame.minY, frame.width, frame.height,
                                                    hit.map { String(describing: type(of: $0)) } ?? "nil"))
        let rowBadge = await waitFor(8000) { self.labels(in: row).contains("Connected") }
        record("account-connected-badge", rowBadge, "Account → Connect AI row badged Connected: \(rowBadge)")
        snapshot("account.png")
        (hit as? UIControl ?? sequence(first: hit, next: { $0?.superview }).compactMap { $0 as? UIControl }.first)?.sendActions(for: .touchUpInside)
        let pushed = await waitFor(3000) { account.navigationController?.topViewController is ConnectAIViewController }
        guard pushed, let screen = account.navigationController?.topViewController as? ConnectAIViewController else {
            record("connect-ai-opens", false, "tapping the row didn't push Connect AI")
            return
        }
        let loaded = await waitFor(8000) { screen.probeState != nil }
        await sleep(600)
        let names = screen.probeState?.connections.map(\.name) ?? []
        record("connect-ai-opens", loaded && screen.view.window === window,
               "pushed; plan editing=\(screen.probeState?.agentEditing ?? false); connected: \(names.joined(separator: ", "))")
        record("connected-lists-agents", names.contains("Claude") && names.contains("Claude Code on my Mac") && screen.probeUpgradeCallout == nil,
               "Claude (signed in with CaptureCat) and the personal token listed; no upgrade callout on Pro")
        // "Connected": Claude signed in, ChatGPT didn't — only Claude's row is badged.
        let addRows = screen.probeAddCard.subviews.first?.subviews.compactMap { $0 as? ActionRowControl } ?? []
        let badged = addRows.map { row in labels(in: row).contains("Connected") }
        record("add-connected-badge", badged == [true, false],
               "Add to Claude / Add to ChatGPT badged: \(badged)")
        let words = labels(in: screen.view).joined(separator: " ")
        record("connect-ai-copy", words.contains(AgentConnect.mcpURL) && words.contains("Customize → Connectors") && words.contains("Add custom connector"),
               "URL shown; Claude steps name Customize → Connectors / Add custom connector")
        screen.scrollView.setContentOffset(.zero, animated: false)
        await sleep(300)
        snapshot("connect-ai.png")

        // Copy the URL.
        UIPasteboard.general.string = ""
        firstCodeWell(in: screen.view)?.copyButton.sendActions(for: .touchUpInside)
        await sleep(200)
        record("copy-url", UIPasteboard.general.string == AgentConnect.mcpURL, "pasteboard = \(UIPasteboard.general.string ?? "nil")")

        // Add to …: Claude's link is pre-filled and opens at once; ChatGPT
        // copies the URL, says what to tap, then opens the browser.
        var opened: [URL] = []
        screen.probeOpen = { opened.append($0) }
        screen.add(to: .claude)
        let claudeItems = opened.last.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        func item(_ n: String) -> String? { claudeItems?.queryItems?.first { $0.name == n }?.value }
        record("add-claude", opened.count == 1 && claudeItems?.host == "claude.ai" && claudeItems?.path == "/customize/connectors"
                   && item("modal") == "add-custom-connector" && item("connectorName") == "CaptureCat" && item("connectorUrl") == AgentConnect.mcpURL,
               opened.last?.absoluteString ?? "nothing opened")
        for (client, host) in [(ConnectAIViewController.Client.chatGPT, "chatgpt.com")] {
            opened = []
            UIPasteboard.general.string = ""
            screen.add(to: client)
            await sleep(700)
            let copied = UIPasteboard.general.string == AgentConnect.mcpURL, early = opened.count
            snapshot("connect-ai-add-\(host).png")
            screen.probeAddAlert?.probeButtons.first?.sendActions(for: .touchUpInside)
            await sleep(700)
            record("add-\(host)", copied && early == 0 && opened.count == 1 && opened.first?.host == host,
                   "copied=\(copied), opened before confirm=\(early), then \(opened.first?.absoluteString ?? "nothing")")
        }
        screen.probeOpen = nil
        screen.show(.claude, animated: false)
        await sleep(300)

        // The switcher: ChatGPT — the guide swap is animated.
        screen.show(.chatGPT, animated: true)
        await sleep(40)
        let midAlpha = screen.probeGuideCard.subviews.first?.layer.presentation()?.opacity ?? 1
        let midTy = (screen.probeGuideCard.subviews.first?.layer.presentation()?.value(forKeyPath: "transform.translation.y") as? CGFloat) ?? 0
        let animating = (midAlpha > 0.01 && midAlpha < 0.99) || (abs(midTy) > 0.3 && abs(midTy) < 9.7)
        record("guide-swap-midflight", animating, String(format: "40 ms in: steps alpha %.2f, rise %.1f pt", midAlpha, midTy))
        await sleep(600)
        let gpt = labels(in: screen.probeGuideCard).joined(separator: " ")
        record("chatgpt-guide", gpt.contains("Plugins") && gpt.contains("Add custom MCP server"), "ChatGPT steps: Plugins → Add custom MCP server")
        scrollTo(screen.probeGuideCard, in: screen)
        snapshot("connect-ai-chatgpt.png")
        screen.show(.gemini, animated: false)
        await sleep(400)
        let gemini = labels(in: screen.probeGuideCard).joined(separator: " ")
        scrollTo(screen.probeGuideCard, in: screen)
        await sleep(3800)   // earlier "Copied" toasts leave first
        snapshot("connect-ai-gemini.png")
        UIPasteboard.general.string = ""
        codeWells(in: screen.probeGuideCard).first?.copyButton.sendActions(for: .touchUpInside)
        await sleep(200)
        record("gemini-guide", gemini.contains("Custom apps") && gemini.contains("Add a custom app") && gemini.contains("personal Google Accounts")
                   && UIPasteboard.general.string == AgentConnect.geminiCommand,
               "Gemini app: Settings → Connected Apps → Custom apps (+ who can); Gemini CLI command copies: \(UIPasteboard.general.string ?? "nil")")
        screen.show(.codex, animated: false)
        await sleep(400)
        let wells = codeWells(in: screen.probeGuideCard)
        scrollTo(screen.probeGuideCard, in: screen)
        await sleep(3800)   // earlier "Copied" toasts leave first
        snapshot("connect-ai-codex.png")
        UIPasteboard.general.string = ""
        wells.first?.copyButton.sendActions(for: .touchUpInside)
        await sleep(200)
        let copiedCommands = UIPasteboard.general.string
        let codex = labels(in: screen.probeGuideCard).joined(separator: " ")
        record("codex-guide", copiedCommands == AgentConnect.codexCommand && wells.count == 2 && wells.last?.text == AgentConnect.codexConfig
                   && codex.contains("codex mcp add capturecat --url") && codex.contains("Codex cloud"),
               "Codex CLI commands copy in one tap (\(copiedCommands?.replacingOccurrences(of: "\n", with: " ⏎ ") ?? "nil")); config.toml snippet; cloud caveat")
        screen.show(.other, animated: false)
        await sleep(400)
        let other = labels(in: screen.probeGuideCard).joined(separator: " ")
        record("other-guide-json", other.contains("\"mcpServers\"") && other.contains(AgentConnect.mcpURL), "JSON block with the URL")
        scrollTo(screen.probeGuideCard, in: screen)
        snapshot("connect-ai-other.png")
        screen.show(.claude, animated: false)

        // Revoke the personal token.
        guard let index = screen.probeState?.connections.firstIndex(where: { $0.name == "Claude Code on my Mac" }),
              index < screen.probeRevokeButtons.count else {
            record("revoke", false, "no revoke key for the token")
            return
        }
        screen.probeRevokeButtons[index].sendActions(for: .touchUpInside)
        await sleep(700)
        let alert = screen.probeRevokeAlert
        alert?.probeButtons.first?.sendActions(for: .touchUpInside)
        let gone = await waitFor(6000) { !(screen.probeState?.connections.contains { $0.name == "Claude Code on my Mac" } ?? true) }
        let (_, tokens) = await call("GET", "/api/agent-tokens", bearer: "owner")
        let revokedOnServer = (tokens["tokens"] as? [[String: Any]] ?? []).allSatisfy { $0["revokedAt"] as? String != nil }
        record("revoke", alert != nil && gone && revokedOnServer, "confirm shown=\(alert != nil); gone from the list=\(gone); revoked on the server=\(revokedOnServer)")
        account.navigationController?.popToRootViewController(animated: false)
        await sleep(300)
    }

    // MARK: 3. Plan gate

    private func planGate(shell: ShellViewController) async {
        signIn(uid: "free", name: "Fran Free")
        await sleep(600)
        guard let nav = root?.shell?.account.navigationController else {
            record("plan-gate", false, "no account screen")
            return
        }
        let screen = ConnectAIViewController()
        nav.pushViewController(screen, animated: false)
        let loaded = await waitFor(8000) { screen.probeState != nil }
        await sleep(500)
        let words = labels(in: screen.probeUpgradeCallout).joined(separator: " ")
        record("plan-gate-upgrade", loaded && screen.probeState?.agentEditing == false && screen.probeUpgradeCallout != nil && words.contains("Pro"),
               "Free plan: agentEditing=\(screen.probeState?.agentEditing.description ?? "?"); callout: \(words.prefix(90))…")
        snapshot("connect-ai-free.png")
        nav.popToRootViewController(animated: false)
    }

    // MARK: 4–5. Background edits in the open editor

    private func editorFlow(projectID: String, agentToken: String) async {
        guard let id = UUID(uuidString: projectID), let root else { return }
        root.shell?.select(.library, animated: false)
        await sleep(300)
        StudioEditorEntry.open(projectID: projectID, from: root)
        let opened = await waitFor(30_000) { StudioCloudSync.existing(projectID: id)?.editor?.viewIfLoaded?.window != nil }
        guard opened, let sync = StudioCloudSync.existing(projectID: id), let editor = sync.editor else {
            record("editor-opens", false, "the editor didn't open the cloud project")
            return
        }
        await sleep(1500)
        await sync.settle()
        record("editor-opens", sync.status == .synced, "cloned + opened; sync \(sync.status)")
        sync.pollInterval = 0   // the gate drives every refresh itself

        // 4. Unsent local work + an agent edit, noticed through the push.
        sync.pushDelay = 120
        editor.project.settings.backgroundPadding = 61
        // The editor's autosave observation marks the change, then it saves.
        _ = await waitFor(3000) { editor.saveNow(); return sync.hasUnsentEdits }
        record("local-edit-unsent", sync.hasUnsentEdits, "backgroundPadding 61 saved here, not pushed (status \(sync.status))")

        let pushesBefore = await pushes().count
        let edit1 = await agentCall(agentToken, "apply_edits", ["project_id": projectID, "ops": [
            ["op": "add_annotation", "args": ["type": "text", "start": 0.5, "end": 3.0, "x": 0.5, "y": 0.2, "text": "From Claude"]],
        ]])
        record("agent-apply-edits", edit1?["revision"] as? Int != nil, "apply_edits over /mcp with Claude's OAuth token → revision \(edit1?["revision"] ?? "none")")

        var push: [String: Any]?
        for _ in 0..<40 {
            let all = await pushes()
            if all.count > pushesBefore { push = all.last; break }
            await sleep(250)
        }
        let payload = push?["payload"] as? [String: Any]
        let alert = (payload?["aps"] as? [String: Any])?["alert"] as? [String: Any]
        record("push-produced", (alert?["title"] as? String) == "AI finished editing" && (alert?["body"] as? String) == "Claude edited \u{201C}Agent demo\u{201D}.",
               "APNs payload: \(alert?["title"] ?? "none") — \(alert?["body"] ?? "")")
        var showBanner = true
        if let payload, let parsed = AgentEditNotifications.payload(from: payload) {
            showBanner = AgentEditNotifications.arrived(parsed)
        }
        record("push-routes-to-open-editor", payload != nil && !showBanner, "app in front with the project open → no banner, the editor refreshes")

        let notice1 = await sampleNotice(sync)
        let merged = await waitFor(15_000) {
            editor.project.annotations.contains { $0.text == "From Claude" } && editor.project.settings.backgroundPadding == 61
        }
        record("agent-edit-lands-keeps-local-work", merged,
               "editor has \"From Claude\" = \(editor.project.annotations.contains { $0.text == "From Claude" }), local padding = \(editor.project.settings.backgroundPadding)")
        record("notice-rises-midflight", notice1.midflight, notice1.detail)
        let toast1 = sync.agentEdits.probeNotice
        record("notice-copy", toast1 != nil && labels(in: toast1).contains("Edited by Claude") && toast1?.probeActionButton?.title == "Undo",
               "labels: \(labels(in: toast1).joined(separator: " | "))")
        await sleep(400)
        snapshot("editor-notice.png")

        await sync.settle()
        await sleep(500)
        let revBeforeUndo = (await call("GET", "/__versions/\(projectID)")).1["revision"] as? Int ?? 0
        toast1?.probeActionButton?.sendActions(for: .touchUpInside)
        let reverted = await waitFor(10_000) { !editor.project.annotations.contains { $0.text == "From Claude" } }
        let pushedUndo = await waitFor(15_000) { !sync.hasUnsentEdits && sync.status == .synced }
        let revAfterUndo = (await call("GET", "/__versions/\(projectID)")).1["revision"] as? Int ?? 0
        record("undo-reverts-agent-only", reverted && editor.project.settings.backgroundPadding == 61 && sync.agentEdits.probeLastUndoPath == .revert,
               "annotation gone=\(reverted); local padding kept=\(editor.project.settings.backgroundPadding == 61); path=\(sync.agentEdits.probeLastUndoPath?.rawValue ?? "none")")
        record("undo-is-new-revision", pushedUndo && revAfterUndo > revBeforeUndo, "server revision \(revBeforeUndo) → \(revAfterUndo) (pushed: \(pushedUndo))")

        // 5. Clean project, agent edit noticed on FOREGROUND, Undo = server restore.
        sync.pushDelay = 3
        await sync.settle()
        let before = editor.historyModelDocument()
        let annotationsBefore = editor.project.annotations.count
        let edit2 = await agentCall(agentToken, "apply_edits", ["project_id": projectID, "ops": [
            ["op": "add_effect", "args": ["type": "zoom", "start": 1.0, "end": 3.0, "zoomLevel": 1.6, "focalX": 0.4, "focalY": 0.4]],
            ["op": "add_annotation", "args": ["type": "text", "start": 1.0, "end": 2.5, "x": 0.5, "y": 0.8, "text": "Zoomed by Claude"]],
        ]])
        let agentVersionID = edit2?["versionId"] as? String
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        let landed2 = await waitFor(15_000) { editor.project.annotations.contains { $0.text == "Zoomed by Claude" } }
        let noticed2 = await waitFor(8000) { sync.agentEdits.last?.revision == edit2?["revision"] as? Int && sync.agentEdits.probeNotice != nil }
        record("foreground-pulls-agent-edit", edit2 != nil && landed2 && noticed2,
               "foreground → pulled revision \(edit2?["revision"] ?? "?"), notice: \(sync.agentEdits.probeNotice.map { labels(in: $0).joined(separator: " | ") } ?? "none")")
        await sleep(600)
        sync.agentEdits.probeNotice?.probeActionButton?.sendActions(for: .touchUpInside)
        let restored = await waitFor(15_000) { StudioAgentEdits.sameJSON(editor.historyModelDocument(), before) }
        await sync.settle()
        let vs = await versions(projectID)
        let last = vs.last
        let agentStill = vs.contains { ($0["id"] as? String) == agentVersionID }
        record("undo-server-restore", restored && sync.agentEdits.probeLastUndoPath == .serverRestore
                   && editor.project.annotations.count == annotationsBefore,
               "editor back to before=\(restored); path=\(sync.agentEdits.probeLastUndoPath?.rawValue ?? "none")")
        record("undo-never-deletes", (last?["kind"] as? String) == "restore" && agentStill && sync.status == .synced,
               "head version kind=\(last?["kind"] ?? "?") restored_from=\(last?["restored_from"] ?? "?"); the agent's version still in History=\(agentStill); \(vs.count) versions")
        record("undo-is-one-editor-step", editor.undoManager?.undoActionName == StudioAgentEdits.actionName,
               "editor undo names \"\(editor.undoManager?.undoActionName ?? "")\"")
        snapshot("editor-after-undo.png")
    }

    /// Waits for the agent notice and samples its rise (slide up from 28 pt + fade in).
    private func sampleNotice(_ sync: StudioCloudSync) async -> (midflight: Bool, detail: String) {
        var waited = 0
        while sync.agentEdits.probeNotice == nil && waited < 20_000 {
            try? await Task.sleep(nanoseconds: 8_000_000)
            waited += 8
        }
        guard let toast = sync.agentEdits.probeNotice else { return (false, "no notice within 20 s") }
        try? await Task.sleep(nanoseconds: 60_000_000)
        let layer = toast.layer.presentation()
        let ty = (layer?.value(forKeyPath: "transform.translation.y") as? CGFloat) ?? 0
        let alpha = layer?.opacity ?? 1
        let mid = (ty > 0.3 && ty < 27.7) || (alpha > 0.02 && alpha < 0.98)
        return (mid, String(format: "60 ms after it appeared: rise %.1f pt of 28, alpha %.2f", ty, alpha))
    }

    // MARK: - Helpers

    private func codeWells(in view: UIView) -> [CodeWell] {
        if let well = view as? CodeWell { return [well] }
        return view.subviews.flatMap { codeWells(in: $0) }
    }

    private func firstCodeWell(in view: UIView) -> CodeWell? {
        if let well = view as? CodeWell { return well }
        for sub in view.subviews { if let found = firstCodeWell(in: sub) { return found } }
        return nil
    }

    private func scrollTo(_ target: UIView, in screen: ConnectAIViewController) {
        let scroll = screen.scrollView
        let rect = target.convert(target.bounds, to: scroll)
        let maxOffset = max(-scroll.adjustedContentInset.top, scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height)
        scroll.setContentOffset(CGPoint(x: 0, y: min(max(-scroll.adjustedContentInset.top, rect.minY - 140), maxOffset)), animated: false)
        scroll.layoutIfNeeded()
    }

    private func labels(in view: UIView?) -> [String] {
        guard let view else { return [] }
        var out: [String] = []
        if let label = view as? UILabel, let text = label.text { out.append(text) }
        for sub in view.subviews { out += labels(in: sub) }
        return out
    }

    private func snapshot(_ name: String) {
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        try? image.pngData()?.write(to: out.appendingPathComponent(name))
    }

    private func finish() {
        let verdict = "AGENTEDIT-GATE \(failures == 0 && !lines.isEmpty ? "PASS" : "FAIL") (\(lines.count - failures)/\(lines.count) checks)"
        lines.append(verdict)
        print(verdict)
        try? lines.joined(separator: "\n").write(to: out.appendingPathComponent("gate.txt"), atomically: true, encoding: .utf8)
        fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { Darwin.exit(0) }
    }
}
#endif
