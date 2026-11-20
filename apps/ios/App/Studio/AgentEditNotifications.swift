import UIKit

/// The "AI finished editing …" notification (`cc.type == "agentEdited"`,
/// sent by the API once the user's AI agent goes quiet on one of their cloud
/// projects — apps/api/src/lib/agent-edit-push.ts).
///
/// - Arrives while the app is open: the library refreshes; if that project
///   is open in the editor no banner shows — the editor pulls now and its own
///   "Edited by …" notice (with Undo) says it. Otherwise the banner shows.
/// - Tapped: the project opens in the editor (already open → it refreshes);
///   without the studio (iOS < 26) its detail screen opens.
@MainActor
enum AgentEditNotifications {
    static let type = "agentEdited"

    struct Payload: Equatable {
        let projectID: String
        let revision: Int?
        let agentName: String?
    }

    static func payload(from userInfo: [AnyHashable: Any]) -> Payload? {
        guard let cc = userInfo["cc"] as? [String: Any], cc["type"] as? String == type,
              let id = cc["projectId"] as? String, UUID(uuidString: id) != nil else { return nil }
        return Payload(projectID: id.uppercased(), revision: (cc["revision"] as? NSNumber)?.intValue,
                       agentName: cc["agentName"] as? String)
    }

    /// Whether the project is open in an editor on screen.
    static func isOpenInEditor(_ projectID: String) -> Bool {
        guard #available(iOS 26, *), let id = UUID(uuidString: projectID),
              let editor = StudioCloudSync.existing(projectID: id)?.editor else { return false }
        return editor.viewIfLoaded?.window != nil
    }

    /// Arrived while the app is in front. Returns whether to show the banner.
    static func arrived(_ payload: Payload) -> Bool {
        NotificationCenter.default.post(name: .ccLibraryShouldRefresh, object: nil)
        guard isOpenInEditor(payload.projectID) else { return true }
        refreshOpenEditor(payload.projectID)
        return false
    }

    /// The user tapped it.
    static func opened(_ payload: Payload) {
        NotificationCenter.default.post(name: .ccLibraryShouldRefresh, object: nil)
        if isOpenInEditor(payload.projectID) {
            refreshOpenEditor(payload.projectID)
            return
        }
        guard let root = rootViewController() else { return }
        if #available(iOS 26, *), root.shell != nil {
            StudioEditorEntry.open(projectID: payload.projectID, from: root)
        } else {
            root.openProject(payload.projectID)
        }
    }

    private static func refreshOpenEditor(_ projectID: String) {
        guard #available(iOS 26, *), let id = UUID(uuidString: projectID) else { return }
        StudioCloudSync.existing(projectID: id)?.refreshNow()
    }

    private static func rootViewController() -> RootViewController? {
        for scene in UIApplication.shared.connectedScenes {
            guard let windows = (scene as? UIWindowScene)?.windows else { continue }
            for window in windows { if let root = window.rootViewController as? RootViewController { return root } }
        }
        return nil
    }
}
