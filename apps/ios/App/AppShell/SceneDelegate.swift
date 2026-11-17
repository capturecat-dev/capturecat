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
        handle(connectionOptions.urlContexts)
        #if DEBUG
        FixtureDirector.shared.start(in: window)
        AppPerfProbe.start(in: window)
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
        handle(URLContexts)
    }

    /// `capturecat://open-project?id=<UUID>` opens that project's detail.
    /// `capturecat://auth-done` belongs to the sign-in sheet — ignored here.
    private func handle(_ contexts: Set<UIOpenURLContext>) {
        for context in contexts {
            let url = context.url
            guard url.scheme?.lowercased() == CaptureCatAPI.callbackScheme else { continue }
            switch url.host?.lowercased() {
            case "open-project":
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                guard let id = items.first(where: { $0.name == "id" })?.value, UUID(uuidString: id) != nil else { continue }
                if let root {
                    root.openProject(id)
                } else {
                    DispatchQueue.main.async { [weak self] in self?.root?.openProject(id) }
                }
            default:
                continue
            }
        }
    }
}
