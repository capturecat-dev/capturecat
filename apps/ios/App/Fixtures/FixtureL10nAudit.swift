#if DEBUG
import UIKit

/// `-uiFixtures -uiL10nAudit` (apps/ios/scripts/ios-l10n.sh) — the companion
/// app's screens in whatever language the process runs in
/// (`-AppleLanguages (de)`), in the app's own window chain over the
/// deterministic fixture world. Each screen goes through
/// `CCLocalizationAudit` (every visible / spoken text, truncation, clipping,
/// overlap, a snapshot) into Documents/l10n/. The script compares the texts
/// against the English run and the catalog; this side only records.
///
///     -uiL10nInject untranslated   a hard-coded English label on Account (must be caught)
///     -uiL10nInject truncate       header titles pinned to 36 pt (must be caught)
///     -uiFixtureEmpty -uiL10nOnly library,…   the empty states (Documents/l10n-empty, `empty-` screens)
@MainActor
enum FixtureL10nAudit {
    private struct Screen {
        let name: String
        let open: (ShellViewController) async -> Void
        let close: (ShellViewController) async -> Void
    }

    private static var problems = 0
    private static let out = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(FixtureWorld.has("-uiFixtureEmpty") ? "l10n-empty" : "l10n", isDirectory: true)
    /// `-uiFixtureEmpty`: the empty world (empty library, filters, inbox) —
    /// its screens are recorded as `empty-<name>`.
    private static let prefix = FixtureWorld.has("-uiFixtureEmpty") ? "empty-" : ""

    static func run(window: UIWindow, root: RootViewController) async {
        setbuf(stdout, nil)
        try? FileManager.default.removeItem(at: out)
        let inject = FixtureWorld.value("-uiL10nInject")
        if inject == "truncate" { CCHeaderBar.probeTruncateTitle = true }
        print("L10NAUDIT locale=\(Bundle.main.preferredLocalizations.first ?? "?") window=\(Int(window.bounds.width))×\(Int(window.bounds.height)) inject=\(inject ?? "none")")
        guard let shell = root.shell else { print("L10NAUDIT-DONE FAIL not signed in"); exit(1) }
        await settle(1.0)

        let project = FixtureDirector.projectID(1)
        func filter(_ i: Int) -> (ShellViewController) async -> Void {
            { shell in
                shell.select(.library, animated: false)
                shell.library.split.list.probeFilter.setSelectedIndex(i)
                shell.library.split.list.probeFilter.onChange?(i)
            }
        }
        var screens: [Screen] = [
            Screen(name: "library", open: filter(0), close: { _ in }),
            Screen(name: "library-recordings", open: filter(1), close: { _ in }),
            Screen(name: "library-screenshots", open: filter(2), close: { _ in }),
            Screen(name: "library-shares", open: filter(3), close: filter(0)),
            Screen(name: "library-actions", open: { shell in
                shell.select(.library, animated: false)
                await settle(0.5)
                shell.library.split.list.showActions(at: IndexPath(item: 0, section: 0))
            }, close: dismiss),
            Screen(name: "project", open: { shell in shell.library.showProject(project) },
                   close: { shell in shell.library.nav.popToRootViewController(animated: false) }),
            Screen(name: "project-end", open: { shell in
                shell.library.showProject(project)
                await settle(0.8)
                scrollToEnd(shell.view)
            }, close: { shell in shell.library.nav.popToRootViewController(animated: false) }),
            Screen(name: "share", open: { shell in shell.library.showShare("fxShareOnboard") },
                   close: { shell in shell.library.nav.popToRootViewController(animated: false) }),
            Screen(name: "share-end", open: { shell in
                shell.library.showShare("fxShareOnboard")
                await settle(0.8)
                scrollToEnd(shell.view)
            }, close: { shell in shell.library.nav.popToRootViewController(animated: false) }),
            Screen(name: "share-comments-off", open: { shell in shell.library.showShare("fxShareRoadmap") },
                   close: { shell in shell.library.nav.popToRootViewController(animated: false) }),
            Screen(name: "capture", open: { shell in shell.select(.capture, animated: false) }, close: { _ in }),
            Screen(name: "capture-end", open: { shell in
                shell.select(.capture, animated: false)
                await settle(0.5)
                scrollToEnd(shell.view)
            }, close: { _ in }),
            Screen(name: "account", open: { shell in
                shell.select(.account, animated: false)
                if inject == "untranslated" {
                    let label = ccLabel("Manage your subscription", font: CCFont.label, color: CCTheme.color.foreground)
                    label.tag = 0x4C31
                    label.frame = CGRect(x: 24, y: 140, width: 300, height: 24)
                    shell.account.view.addSubview(label)
                }
            }, close: { _ in }),
            Screen(name: "account-end", open: { shell in
                shell.select(.account, animated: false)
                await settle(0.4)
                scrollToEnd(shell.account.view)
            }, close: { shell in shell.account.view.viewWithTag(0x4C31)?.removeFromSuperview() }),
            Screen(name: "language", open: { shell in
                shell.select(.account, animated: false)
                shell.account.probeLanguageRow.sendActions(for: .touchUpInside)
            }, close: { shell in shell.account.navigationController?.popToRootViewController(animated: false) }),
        ]
        screens += connectAIScreens()
        screens += [
            Screen(name: "delete-account", open: { shell in
                shell.select(.account, animated: false)
                await settle(0.3)
                shell.account.probeDeleteButton.sendActions(for: .touchUpInside)
            }, close: dismiss),
            Screen(name: "toast", open: { shell in
                shell.select(.library, animated: false)
                _ = AppToaster.shared.show(title: String(localized: "Link copied", comment: "Toast after copying a share link"),
                                           message: "capturecat.so/share/fxShareOnboard", variant: .success, symbol: "link")
            }, close: { _ in await settle(4.0) }),
        ]
        if FixtureWorld.value("-uiL10nOnly") != nil {
            let only = Set((FixtureWorld.value("-uiL10nOnly") ?? "").split(separator: ",").map(String.init))
            screens = screens.filter { only.contains($0.name) }
        }
        for screen in screens {
            await screen.open(shell)
            await settle(1.1)
            await settleTransitions(window)
            record(screen.name, window: window)
            await screen.close(shell)
            await settle(0.4)
        }

        // Signed out: the sign-in (onboarding) screen.
        await FixtureWorld.shared.session.signOut()
        await settle(1.4)
        record("sign-in", window: window)
        print("L10NAUDIT-DONE \(problems == 0 ? "clean" : "\(problems) text problem(s)")")
        exit(0)
    }

    // MARK: Connect AI (no server: a fixture state through `probeLoader`)

    private static weak var connectAI: ConnectAIViewController?

    /// Account → Connect AI: each app's steps (chip), the connected list with
    /// its revoke sheet, and a plan without AI editing (the upgrade callout).
    private static func connectAIScreens() -> [Screen] {
        func state(editing: Bool) -> AgentAccessState {
            let now = Date()
            return AgentAccessState(
                agentAccess: true, agentEditing: editing, planName: editing ? "Pro" : "Free",
                connections: [
                    AgentConnection(kind: .app(clientId: "fxClaude"), name: "Claude", connectedAt: now.addingTimeInterval(-3 * 86_400),
                                    lastUsedAt: now.addingTimeInterval(-2 * 3_600), canEdit: true),
                    AgentConnection(kind: .token(id: "fxToken"), name: "Claude Code on my Mac", connectedAt: now.addingTimeInterval(-12 * 86_400),
                                    lastUsedAt: nil, canEdit: false),
                ])
        }
        func open(editing: Bool, _ then: @escaping (ConnectAIViewController) async -> Void) -> (ShellViewController) async -> Void {
            { shell in
                ConnectAIViewController.probeLoader = { state(editing: editing) }
                shell.select(.account, animated: false)
                let screen = ConnectAIViewController()
                connectAI = screen
                shell.account.navigationController?.pushViewController(screen, animated: false)
                await settle(0.8)
                await then(screen)
            }
        }
        let close: (ShellViewController) async -> Void = { shell in
            await dismiss(shell)
            shell.account.navigationController?.popToRootViewController(animated: false)
            ConnectAIViewController.probeLoader = nil
        }
        func guide(_ client: ConnectAIViewController.Client) -> (ConnectAIViewController) async -> Void {
            { screen in
                screen.show(client, animated: false)
                await settle(0.4)
                scroll(screen.probeGuideCard, in: screen)
            }
        }
        let clients: [(String, ConnectAIViewController.Client)] = [("claude", .claude), ("chatgpt", .chatGPT), ("gemini", .gemini), ("codex", .codex), ("other", .other)]
        var list = [Screen(name: "connect-ai", open: open(editing: true) { _ in }, close: close)]
        for (name, client) in clients {
            list.append(Screen(name: "connect-ai-\(name)", open: open(editing: true, guide(client)), close: close))
        }
        list += [
            Screen(name: "connect-ai-connected", open: open(editing: true) { screen in scrollToEnd(screen.view) }, close: close),
            Screen(name: "connect-ai-revoke", open: open(editing: true) { screen in
                scrollToEnd(screen.view)
                screen.probeRevokeButtons.first?.sendActions(for: .touchUpInside)
            }, close: close),
            Screen(name: "connect-ai-upgrade", open: open(editing: false) { _ in }, close: close),
        ]
        return list
    }

    private static func scroll(_ target: UIView, in screen: ConnectAIViewController) {
        let scroll = screen.scrollView
        scroll.layoutIfNeeded()
        let rect = target.convert(target.bounds, to: scroll)
        let maxOffset = max(-scroll.adjustedContentInset.top, scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height)
        scroll.setContentOffset(CGPoint(x: 0, y: min(max(-scroll.adjustedContentInset.top, rect.minY - 140), maxOffset)), animated: false)
    }

    private static func record(_ bare: String, window: UIWindow) {
        let name = prefix + bare
        let found = CCLocalizationAudit.capture(name, window: window, to: out)
        problems += found.count
        print("L10NAUDIT screen \(name) \(found.isEmpty ? "ok" : found.joined(separator: " | "))")
    }

    private static func scrollToEnd(_ root: UIView) {
        var best: UIScrollView?
        func walk(_ v: UIView) {
            if let s = v as? UIScrollView, !(s is UITextView), !s.isHidden, s.window != nil,
               s.contentSize.height > (best?.contentSize.height ?? 0) { best = s }
            v.subviews.forEach(walk)
        }
        walk(root)
        guard let scroll = best else { return }
        scroll.layoutIfNeeded()
        let maxY = max(-scroll.adjustedContentInset.top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: maxY), animated: false)
    }

    private static func dismiss(_ shell: ShellViewController) async {
        var top: UIViewController? = shell.view.window?.rootViewController
        while let next = top?.presentedViewController { top = next }
        guard let presented = top, presented !== shell.view.window?.rootViewController else { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in presented.dismiss(animated: false) { c.resume() } }
        await settle(0.3)
    }

    /// A push or a sheet still in flight would mix two screens' text.
    private static func settleTransitions(_ window: UIWindow) async {
        func busy(_ vc: UIViewController?) -> Bool {
            guard let vc else { return false }
            if vc.transitionCoordinator != nil { return true }
            return vc.children.contains(where: busy) || busy(vc.presentedViewController)
        }
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline, busy(window.rootViewController) { await settle(0.1) }
        await settle(0.3)
    }

    private static func settle(_ s: TimeInterval) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
}
#endif
