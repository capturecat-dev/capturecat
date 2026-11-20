import Foundation

/// What Connect AI shows about the account's agents — the API's own routes
/// (session only; an agent's token is refused there by design):
///
///   GET  /api/agent-tokens            plan gates (`features`), plan name, personal tokens
///   GET  /api/oauth/apps              apps that signed in with CaptureCat (Claude, ChatGPT …)
///   POST /api/oauth/apps/revoke       { clientId } — every grant that app holds
///   DELETE /api/agent-tokens/:id      revoke one personal token
///
/// Nothing here mints a token: Claude and ChatGPT connect by signing in
/// (OAuth) at the MCP URL, so the phone never holds an agent credential.
nonisolated enum AgentConnect {
    /// The remote MCP server users add to their AI app. Always production —
    /// it is what the user types into another company's app.
    static let mcpURL = "https://mcp.capturecat.so/mcp"
    /// Where each app's connector settings live (their own docs, 2026-11).
    static let claudeConnectorsURL = URL(string: "https://claude.ai/customize/connectors")!
    static let chatGPTPluginsURL = URL(string: "https://chatgpt.com/plugins")!

    /// The standard `mcpServers` entry for any other MCP client.
    static var jsonConfig: String {
        """
        {
          "mcpServers": {
            "capturecat": {
              "type": "http",
              "url": "\(mcpURL)"
            }
          }
        }
        """
    }
}

nonisolated struct AgentConnection: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// An app that signed in with CaptureCat — revoked by client id.
        case app(clientId: String)
        /// A personal token made on the web — revoked by token id.
        case token(id: String)
    }
    let kind: Kind
    let name: String
    let connectedAt: Date?
    let lastUsedAt: Date?
    let canEdit: Bool
}

nonisolated struct AgentAccessState: Equatable, Sendable {
    var agentAccess: Bool
    var agentEditing: Bool
    var planName: String?
    var connections: [AgentConnection]
}

extension APIClient {
    func agentAccess() async throws -> AgentAccessState {
        async let tokensReply = send("GET", "/api/agent-tokens")
        async let appsReply = send("GET", "/api/oauth/apps")
        let (tokensData, _) = try await tokensReply
        let (appsData, _) = try await appsReply
        guard let tokens = try JSONSerialization.jsonObject(with: tokensData) as? [String: Any],
              let apps = try JSONSerialization.jsonObject(with: appsData) as? [String: Any] else { throw APIError.invalidResponse }
        let features = tokens["features"] as? [String: Any] ?? [:]
        let plan = tokens["plan"] as? [String: Any]
        var connections: [AgentConnection] = []
        for app in apps["apps"] as? [[String: Any]] ?? [] {
            guard let id = app["clientId"] as? String else { continue }
            let scopes = app["scopes"] as? [String] ?? []
            connections.append(AgentConnection(
                kind: .app(clientId: id), name: (app["name"] as? String) ?? id,
                connectedAt: AgentDate.parse(app["connectedAt"]), lastUsedAt: AgentDate.parse(app["lastUsedAt"]),
                canEdit: scopes.contains("projects:write")))
        }
        let now = Date()
        for token in tokens["tokens"] as? [[String: Any]] ?? [] {
            guard let id = token["id"] as? String, token["revokedAt"] as? String == nil else { continue }
            if let expires = AgentDate.parse(token["expiresAt"]), expires <= now { continue }
            let scopes = token["scopes"] as? [String] ?? []
            connections.append(AgentConnection(
                kind: .token(id: id), name: (token["name"] as? String) ?? "Token",
                connectedAt: AgentDate.parse(token["createdAt"]), lastUsedAt: AgentDate.parse(token["lastUsedAt"]),
                canEdit: scopes.contains("projects:write")))
        }
        connections.sort { ($0.lastUsedAt ?? $0.connectedAt ?? .distantPast) > ($1.lastUsedAt ?? $1.connectedAt ?? .distantPast) }
        return AgentAccessState(
            agentAccess: features["agentAccess"] as? Bool ?? false,
            agentEditing: features["agentEditing"] as? Bool ?? false,
            planName: plan?["displayName"] as? String ?? plan?["name"] as? String,
            connections: connections)
    }

    func revoke(_ connection: AgentConnection) async throws {
        switch connection.kind {
        case .app(let clientId):
            struct Body: Encodable { let clientId: String }
            try await send("POST", "/api/oauth/apps/revoke", json: Body(clientId: clientId))
        case .token(let id):
            guard let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { throw APIError.invalidResponse }
            try await send("DELETE", "/api/agent-tokens/\(escaped)")
        }
    }
}

nonisolated enum AgentDate {
    static func parse(_ raw: Any?) -> Date? {
        guard let text = raw as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
