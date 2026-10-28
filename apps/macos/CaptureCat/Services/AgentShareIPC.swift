import Foundation

/// The file protocol behind the MCP `share_project` / `share_status` tools.
///
/// `CaptureCat --mcp` is a headless second instance of this bundle; it never
/// uploads anything itself. It files a REQUEST, and the running GUI's
/// `AgentShareBroker` asks the user (a CCKit consent card) and — only on an
/// explicit Allow — runs the share through the very ShareJobCenter the
/// card's Share button uses. The broker publishes STATUS files the MCP side
/// reads. Same sandbox container, so plain files (AutomationBridge does the
/// same for recording):
///
///     Automation/shares/broker.json            GUI: "a broker is live" + pid
///     Automation/shares/<job>.request.json     MCP → GUI (claimed by rename)
///     Automation/shares/<job>.status.json      GUI → MCP (every transition)
///
/// Nothing on disk can approve a share: the broker never reads a decision
/// from a file, only requests. Approval is the Allow click, per request.
nonisolated enum AgentShareIPC {
    /// Bumped if the request/status shapes change incompatibly.
    static let protocolVersion = 1

    /// Harness override (a temp folder) — never set in a normal launch.
    nonisolated(unsafe) static var rootOverride: URL?

    static var directory: URL {
        rootOverride ?? AutomationBridge.automationDirectory.appendingPathComponent("shares", isDirectory: true)
    }

    static var brokerURL: URL { directory.appendingPathComponent("broker.json") }

    static func requestURL(_ jobID: String) -> URL {
        directory.appendingPathComponent("\(jobID).request.json")
    }

    static func claimedURL(_ jobID: String) -> URL {
        directory.appendingPathComponent(".\(jobID).claimed.json")
    }

    static func statusURL(_ jobID: String) -> URL {
        directory.appendingPathComponent("\(jobID).status.json")
    }

    /// Job ids are UUIDs minted by the MCP side — anything else is refused
    /// before it is ever used in a path.
    static func isValidJobID(_ value: String) -> Bool {
        UUID(uuidString: value) != nil && value.count == 36
    }

    // MARK: - Shapes

    enum State: String, Codable, Sendable {
        /// Filed; the user hasn't answered the consent card yet.
        case awaitingApproval = "awaiting_approval"
        /// The user clicked Don't Allow.
        case declined
        /// Never asked: not signed in, onboarding, unknown project, already sharing.
        case refused
        case exporting
        case uploading
        case completing
        case done
        case failed
        /// The app quit (or stopped tracking the job) before it finished.
        case interrupted

        var isTerminal: Bool {
            switch self {
            case .declined, .refused, .done, .failed, .interrupted: return true
            case .awaitingApproval, .exporting, .uploading, .completing: return false
            }
        }
    }

    struct Request: Codable, Sendable {
        var protocolVersion: Int
        var jobId: String
        var projectId: String
        var privacy: String
        /// MCP clientInfo from `initialize` — self-reported, shown as such.
        var clientName: String?
        var clientVersion: String?
        var requestedAt: Date
        /// The MCP side stops waiting for a claim after this — a request the
        /// GUI finds later is stale and is dropped, never presented.
        var claimBy: Date
        var requesterPID: Int32
    }

    struct Status: Codable, Sendable {
        var jobId: String
        var state: State
        /// 0…1 within the current phase (exporting / uploading).
        var progress: Double?
        var projectId: String
        var projectName: String
        var privacy: String
        var shareUrl: String?
        var videoId: String?
        var error: String?
        var warning: String?
        /// The link existed before: this share replaces its video in place.
        var replacesExistingLink: Bool?
        var updatedAt: Date
        var brokerPID: Int32
    }

    struct Broker: Codable, Sendable {
        var protocolVersion: Int
        var pid: Int32
        var startedAt: Date
    }

    // MARK: - IO

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Atomic write (temp file + replace) so a reader never sees half a file.
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(value)
        let tmp = directory.appendingPathComponent(".tmp-\(getpid())-\(UUID().uuidString)")
        try data.write(to: tmp)
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: url)
        }
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }
}
