import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var root: RootViewController? { window?.rootViewController as? RootViewController }

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = CCWindow(windowScene: windowScene)
        window.backgroundColor = CCTheme.color.background
        // Accent for the few system surfaces we allow (keyboard caret,
        // share sheet, photo picker).
        window.tintColor = CCTheme.color.primary
        window.rootViewController = RootViewController()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-kitGallery") {
            window.rootViewController = KitGalleryViewController()
        }
        #endif
        window.makeKeyAndVisible()
        // Assistive settings (Reduce Motion, contrast, …) re-theme live.
        CCAccessibility.install(on: window)
        self.window = window
        handle(connectionOptions.urlContexts, cold: true)
        // A universal link that launched the app (share pages on capturecat.so).
        var activities = Array(connectionOptions.userActivities)
        #if DEBUG
        // Universal links can't reach a Simulator build until the AASA is
        // live on capturecat.so, so the share-viewer gate injects the SAME
        // NSUserActivity a cold launch by a tapped link delivers
        // (`-shareViewerColdLink https://capturecat.so/share/<id>`).
        if let activity = ShareViewerGate.coldLaunchActivity() { activities.append(activity) }
        #endif
        for activity in activities { continueActivity(activity, cold: true) }
        #if DEBUG
        FixtureDirector.shared.start(in: window)
        AppPerfProbe.start(in: window)
        AccountDeleteGate.startIfRequested(in: window)
        ShareViewerGate.startIfRequested(in: window)
        #endif
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        let environment = AppEnvironment.shared
        environment.inbox.processPending()
        // Studio projects edited offline push now (Phase 5).
        if #available(iOS 26, *), environment.session.user != nil { StudioEditorEntry.resumePending() }
        NotificationCenter.default.post(name: .ccAppDidBecomeActive, object: nil)
        if environment.session.user != nil { LibraryStore.shared.refresh() }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        handle(URLContexts, cold: false)
    }

    /// A universal link tapped while the app runs (or Handoff from the web).
    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        continueActivity(userActivity, cold: false)
    }

    /// `NSUserActivityTypeBrowsingWeb` with a share page URL → the viewer;
    /// any other web URL the system hands us → the browser.
    func continueActivity(_ activity: NSUserActivity, cold: Bool) {
        guard activity.activityType == NSUserActivityTypeBrowsingWeb, let url = activity.webpageURL else { return }
        guard let link = ShareLink.parse(url) else {
            ShareLinkRouter.openInBrowser(url)
            return
        }
        route(link, source: .universalLink, cold: cold)
    }

    private func route(_ link: ShareLink, source: ShareLinkRouter.Source, cold: Bool) {
        if cold {
            // The root is up but has not laid out its first screen yet.
            DispatchQueue.main.async { [weak self] in
                ShareLinkRouter.open(link, in: self?.window, source: source, cold: true)
            }
        } else {
            ShareLinkRouter.open(link, in: window, source: source, cold: false)
        }
    }

    /// `capturecat://open-project?id=<UUID>` opens that project's detail.
    /// `capturecat://share/<id>[?t=]` opens the share viewer.
    /// `capturecat://auth-done` belongs to the sign-in sheet — ignored here.
    func handle(_ contexts: Set<UIOpenURLContext>, cold: Bool) {
        for context in contexts { handle(url: context.url, cold: cold) }
    }

    func handle(url: URL, cold: Bool) {
        guard url.scheme?.lowercased() == CaptureCatAPI.callbackScheme else { return }
        switch url.host?.lowercased() {
        case "open-project":
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard let id = items.first(where: { $0.name == "id" })?.value, UUID(uuidString: id) != nil else { return }
            if let root {
                root.openProject(id)
            } else {
                DispatchQueue.main.async { [weak self] in self?.root?.openProject(id) }
            }
        case "share":
            guard let link = ShareLink.parse(url) else { return }
            route(link, source: .customScheme, cold: cold)
        default:
            return
        }
    }
}
