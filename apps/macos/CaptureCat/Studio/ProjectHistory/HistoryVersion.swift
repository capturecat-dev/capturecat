import Foundation

// MARK: - Models (docs/project-history.md §6.1 — the implemented wire contract)
//
// Shared by the Mac (CloudHistoryClient parses the API into these) and the
// iOS studio (LocalProjectHistory builds them from its on-device log), so
// both History panes list the same rows from the same versions.

/// One retained checkpoint of a project — the API's version object `V`:
/// `{ id, seq, kind, label, namedBy: {uid,name}|null, namedAt,
///    actor: {uid,name}|null, client, source, firstRevision, revision,
///    documentBytes, documentSha256, change|null, restoredFrom,
///    mergedFromRevision, openedAt, updatedAt, isHead }`.
nonisolated struct CloudVersion: Equatable, Sendable, Identifiable {
    let id: String
    let seq: Int
    /// The head revision this version holds.
    let revision: Int
    /// The first revision it covered (a coalesced version spans several).
    let firstRevision: Int?
    /// `upload` | `edit` | `merge` | `restore`.
    let kind: String
    var label: String?
    /// Display name (else uid) of who named it.
    let namedBy: String?
    let namedAt: Date?
    let actorUID: String?
    /// The actor's display name (`actor.name`).
    let actorName: String?
    /// `mac` | `web` | `unknown` (`client`); `ios` for the iOS studio's
    /// on-device history (the API does not accept that client yet — Phase 5).
    let clientKind: String
    /// `human` | `agent` | `mixed`.
    let source: String
    /// The change-set from the previous version; nil = unknown (a client
    /// that sent no `X-CC-Change`) — shown as a generic "Edited".
    let change: ChangeSet?
    let documentBytes: Int64?
    let documentSHA256: String?
    let restoredFrom: String?
    let mergedFromRevision: Int?
    let openedAt: Date?
    let updatedAt: Date?
    /// The server marks the current version.
    let isHead: Bool

    var isNamed: Bool { !(label ?? "").isEmpty }
    var date: Date? { updatedAt ?? openedAt }

    /// The client badge: "Mac" / "Web" / "Agent via Mac" / "Agent via Web".
    var clientLabel: String {
        let client: String
        switch clientKind {
        case "mac": client = "Mac"
        case "web": client = String(localized: "Web", comment: "History row badge: which app saved the version")
        case "ios": client = "iOS"
        default: client = String(localized: "Other", comment: "History row badge: which app saved the version")
        }
        switch source {
        case "agent": return String(localized: "Agent via \(client)", comment: "History row badge: an AI agent saved it through an app (Mac, Web, iOS)")
        case "mixed": return String(localized: "\(client) + Agent", comment: "History row badge: a person and an AI agent both edited, through an app (Mac, Web, iOS)")
        default: return client
        }
    }

    /// "Zoom added · Background changed · 3 captions edited" (≤ 3 phrases).
    var summary: String {
        if let change { return ChangeSummary.format(change, maxParts: 3) }
        switch kind {
        case "upload": return String(localized: "Uploaded", comment: "History row caption: the first uploaded version")
        case "restore": return String(localized: "Restored an earlier version", comment: "History row caption")
        case "merge": return String(localized: "Merged edits", comment: "History row caption")
        default: return String(localized: "Edited", comment: "History row caption: a version whose changes are unknown")
        }
    }
}

nonisolated struct CloudRetention: Equatable, Sendable {
    /// `maxHistoryDays` — Pro 30, Business 365, Free 0 (head only).
    let historyDays: Int?
    /// `maxNamedVersions` — Pro 25, Business 500.
    let maxNamed: Int?
    let namedCount: Int?
}

nonisolated struct CloudVersionPage: Equatable, Sendable {
    var versions: [CloudVersion]
    /// `before=` cursor for the next page (nil = no more).
    var nextBefore: Int?
    var retention: CloudRetention?
    /// Media the committed set dropped that history still keeps (counts
    /// toward storage) — "History keeps X of removed media".
    var pinnedMediaBytes: Int64
    /// The part of it Free up would release (pinned only by unnamed,
    /// non-head versions).
    var freeableBytes: Int64
    var headVersionID: String?
    /// `access == "owner"` (only the owner deletes versions or frees media).
    var isOwner: Bool?
}

/// Who saved the revision a merge brought in (best effort, from the
/// versions list) — the toast's "from Ana (Web)".
nonisolated struct CloudVersionAuthor: Equatable, Sendable {
    let name: String?
    /// "Mac" / "Web" / "Agent via Mac" / "Agent via Web".
    let clientLabel: String?
}
