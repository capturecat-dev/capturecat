import UIKit
import UserNotifications

/// This phone's row in the account's device list (`PUT /api/devices/:id`):
/// it lets the Mac list the phone even when the app is closed, and carries
/// the APNs token the Mac's "use this iPhone" push goes to.
@MainActor
final class DeviceRegistry {
    static let shared = DeviceRegistry()

    private var apnsToken: String?

    /// Categories + permission + remote registration. Asked once, when the
    /// user first opens Capture (streaming to the Mac is why a push matters),
    /// never on cold launch.
    func requestPushPermission() async {
        let center = UNUserNotificationCenter.current()
        let start = UNNotificationAction(identifier: PushRouter.startActionID, title: String(localized: "Start streaming", comment: "Notification action button: start streaming this device to the Mac that asked"), options: [.foreground])
        let category = UNNotificationCategory(identifier: PushRouter.broadcastCategory, actions: [start], intentIdentifiers: [])
        center.setNotificationCategories([category])
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge, .timeSensitive])) ?? false
        if granted { UIApplication.shared.registerForRemoteNotifications() }
    }

    /// Launch path: never prompts. If notifications are already allowed,
    /// refresh the APNs token (it can change), so the Mac's push still lands.
    func registerIfAuthorized() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            UIApplication.shared.registerForRemoteNotifications()
        default:
            break
        }
    }

    func didRegister(deviceToken: Data) {
        apnsToken = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await register() }
    }

    /// Upsert this phone (cheap; called on launch, sign-in and token change).
    func register() async {
        guard SessionStore.load() != nil else { return }
        let registration = DeviceRegistration(
            deviceID: DeviceIdentity.deviceID,
            name: DeviceIdentity.name,
            model: DeviceIdentity.model,
            systemVersion: DeviceIdentity.systemVersion,
            appVersion: DeviceIdentity.appVersion,
            apnsToken: apnsToken,
            apnsEnvironment: apnsToken == nil ? nil : Self.apnsEnvironment
        )
        try? await APIClient.shared.registerDevice(registration)
    }

    func unregister() async {
        guard SessionStore.load() != nil else { return }
        await APIClient.shared.unregisterDevice(DeviceIdentity.deviceID)
    }

    /// Debug builds (and the Simulator) talk to the APNs sandbox.
    static var apnsEnvironment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }
}
