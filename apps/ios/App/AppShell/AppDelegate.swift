import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        #if DEBUG
        CaptureCatAPI.adoptLaunchOverride()
        #endif
        PushRouter.shared.install()
        CaptureHubModel.shared.install()
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { CaptureHubModel.shared.appDidBecomeActive() }
        }
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { CaptureHubModel.shared.appDidEnterBackground() }
        }
        center.addObserver(forName: .ccSessionDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                if SessionStore.load() == nil { MacPresence.shared.stop() }
            }
        }
        if SessionStore.load() != nil {
            Task {
                await DeviceRegistry.shared.registerIfAuthorized()
                await DeviceRegistry.shared.register()
                try? await WirelessLinkStore.refresh()
            }
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        DeviceRegistry.shared.didRegister(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {}

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)  // l10n-ok: scene configuration identifier (Info.plist)
    }
}
