import UIKit
import UserNotifications

/// Routes the Mac's "use this iPhone" push (category CC_BROADCAST_REQUEST,
/// payload `cc: { type: "requestBroadcast", macId, macName }`) to the capture
/// hub, which offers the system Start Broadcast sheet; and the API's "AI
/// finished editing" push (`cc.type == "agentEdited"`) to
/// AgentEditNotifications.
@MainActor
final class PushRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PushRouter()
    static let broadcastCategory = "CC_BROADCAST_REQUEST"
    static let startActionID = "CC_START_BROADCAST"

    /// Set by the capture hub; called with the requesting Mac's name.
    var onBroadcastRequest: ((_ macID: String?, _ macName: String?) -> Void)?
    private var pending: (String?, String?)?

    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Deliver a request now, or hold it until the hub is on screen.
    func deliver(macID: String?, macName: String?) {
        if let onBroadcastRequest { onBroadcastRequest(macID, macName) } else { pending = (macID, macName) }
    }

    func takePending() -> (String?, String?)? {
        defer { pending = nil }
        return pending
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        if let cc = info["cc"] as? [String: Any], cc["type"] as? String == AgentEditNotifications.type {
            let userInfo = info
            await MainActor.run {
                if let payload = AgentEditNotifications.payload(from: userInfo) { AgentEditNotifications.opened(payload) }
            }
            return
        }
        guard let cc = info["cc"] as? [String: Any], cc["type"] as? String == "requestBroadcast" else { return }
        let macID = cc["macId"] as? String
        let macName = cc["macName"] as? String
        await MainActor.run { self.deliver(macID: macID, macName: macName) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // App already open: show the request in the app instead of a banner.
        let info = notification.request.content.userInfo
        if let cc = info["cc"] as? [String: Any], cc["type"] as? String == "requestBroadcast" {
            let macID = cc["macId"] as? String
            let macName = cc["macName"] as? String
            await MainActor.run { self.deliver(macID: macID, macName: macName) }
            return []
        }
        if let cc = info["cc"] as? [String: Any], cc["type"] as? String == AgentEditNotifications.type {
            let userInfo = info
            let showBanner = await MainActor.run { () -> Bool in
                guard let payload = AgentEditNotifications.payload(from: userInfo) else { return true }
                return AgentEditNotifications.arrived(payload)
            }
            return showBanner ? [.banner, .list, .sound] : []
        }
        return [.banner, .sound]
    }
}
