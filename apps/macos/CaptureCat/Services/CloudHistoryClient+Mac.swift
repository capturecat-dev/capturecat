import Foundation

// The Mac's side of `CloudHistoryClient` (Studio/Sync, shared with the iOS
// studio): the live API client and the words for every error the History
// pane shows.

extension CloudHistoryClient {
    static func live() -> CloudHistoryClient {
        let transport = HTTPCloudProjectTransport()
        return CloudHistoryClient(transport: transport, sync: CloudProjectSync(transport: transport))
    }

    /// History refusals in the user's words; everything else as the sync says.
    static func message(for error: Error) -> String {
        historyMessage(for: error) ?? CloudSyncController.message(for: error)
    }
}
