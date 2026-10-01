import Foundation
import os

private let mergeLogger = Logger(subsystem: "so.capturecat.CaptureCat", category: "CloudProjectMerge")

// MARK: - History headers (docs/project-history.md §6)

/// What one `PUT …/project` tells the server about itself. Old servers
/// ignore every header; a project-history server stores them on the version.
nonisolated struct CloudSaveContext: Equatable, Sendable {
    enum Checkpoint: String, Sendable { case merge, restore, push, upload, named }
    enum Source: String, Sendable { case human, agent, mixed }

    /// `X-CC-Client` — always `mac` from this app.
    var client = "mac"
    /// `X-CC-Client-Id` — the per-install id (`CloudClientIdentity`).
    var clientID: String
    /// `X-CC-Source` — `CloudAttribution` over the `.mcp-history` chain.
    var source: Source = .human
    /// `X-CC-Change` — base64url canonical change-set (§4.1); nil = omitted
    /// (no base to diff against, or over the 8 KiB budget).
    var change: String?
    /// `X-CC-Checkpoint` — forces a NEW version (push / upload / merge / restore).
    var checkpoint: Checkpoint?
    /// `X-CC-Merged-From` — the server revision (theirs) this save merged.
    var mergedFrom: Int?

    var headers: [String: String] {
        var out = ["X-CC-Client": client, "X-CC-Client-Id": clientID, "X-CC-Source": source.rawValue]
        if let change { out["X-CC-Change"] = change }
        if let checkpoint { out["X-CC-Checkpoint"] = checkpoint.rawValue }
        if let mergedFrom { out["X-CC-Merged-From"] = String(mergedFrom) }
        return out
    }
}

/// `X-CC-Client-Id`: a random UUID minted once per install and kept in
/// UserDefaults — never the machine or user name (it is a coalescing key the
/// server stores on every version, so it must identify nothing personal).
nonisolated enum CloudClientIdentity {
    static let defaultsKey = "cloudSyncClientID"

    static var installID: String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: defaultsKey), isValid(existing) { return existing }
        let fresh = UUID().uuidString.lowercased()
        defaults.set(fresh, forKey: defaultsKey)
        return fresh
    }

    /// The wire rule: ≤ 64 chars of `[A-Za-z0-9_-]`.
    static func isValid(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 64
            && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}

// MARK: - Attribution (Phase 4, Mac side)

/// Who made the edits a save carries: `agent` when the MCP server's undo
/// history (`.mcp-history`, written by `MCPServer.commitEdit`) covers the
/// change from the merge base to the current file EXACTLY — an unbroken run
/// of MCP writes whose `preSHA256 → postSHA256` hashes chain base → current;
/// `mixed` when MCP wrote inside that window but someone (the GUI) also did;
/// `human` when no MCP write touched it.
nonisolated enum CloudAttribution {
    struct Entry: Equatable, Sendable {
        let name: String
        /// SHA-256 of project.json BEFORE the write (`preSHA256`, or the
        /// snapshot file's hash for entries written before that field).
        let pre: String?
        /// SHA-256 of what the write produced (`postSHA256`).
        let post: String?
        let at: Date?
    }

    static let directoryName = ".mcp-history"

    /// Oldest first (entry names start with a millisecond timestamp).
    static func entries(in projectDirectory: URL) -> [Entry] {
        let dir = projectDirectory.appendingPathComponent(directoryName, isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.filter { $0.hasSuffix(".meta.json") }.sorted().map { metaName in
            let base = String(metaName.dropLast(".meta.json".count))
            let meta = (try? Data(contentsOf: dir.appendingPathComponent(metaName)))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            var pre = meta["preSHA256"] as? String
            if pre == nil, let snapshot = try? Data(contentsOf: dir.appendingPathComponent(base + ".json")) {
                pre = CloudProjectManifest.sha256(of: snapshot)
            }
            var at: Date?
            if base.count >= 13, let ms = Int64(base.prefix(13)) {
                at = Date(timeIntervalSince1970: Double(ms) / 1000)
            } else {
                at = CloudAPIDate.parse(meta["at"])
            }
            return Entry(name: base, pre: pre, post: meta["postSHA256"] as? String, at: at)
        }
    }

    /// `mark`: the newest entry name when the base was agreed (the sidecar's
    /// `mcpMark`) — entries after it are the MCP writes since the base.
    /// Without one (an older sidecar), entries at or after `since` count.
    static func source(entries: [Entry], baseSHA: String?, currentSHA: String,
                       since: Date?, mark: String? = nil) -> CloudSaveContext.Source {
        guard let baseSHA, baseSHA != currentSHA else { return .human }
        for start in entries.indices where entries[start].pre == baseSHA {
            var sha = baseSHA
            var index = start
            while index < entries.count, entries[index].pre == sha, let post = entries[index].post {
                sha = post
                if sha == currentSHA { return .agent }
                index += 1
            }
        }
        let touched = entries.contains { entry in
            if entry.pre == baseSHA || entry.post == currentSHA { return true }
            if let mark { return entry.name > mark }
            return since.flatMap { since in entry.at.map { $0 >= since } } ?? false
        }
        return touched ? .mixed : .human
    }

    static func source(projectDirectory: URL, baseSHA: String?, current: Data,
                       since: Date?, mark: String?) -> CloudSaveContext.Source {
        source(entries: entries(in: projectDirectory), baseSHA: baseSHA,
               currentSHA: CloudProjectManifest.sha256(of: current), since: since, mark: mark)
    }

    /// The newest entry's name — recorded in the sidecar at every agreed base.
    static func mark(in projectDirectory: URL) -> String {
        entries(in: projectDirectory).last?.name ?? ""
    }
}

// MARK: - API value helpers

nonisolated enum CloudAPIDate {
    /// The API's timestamps: ISO 8601 with or without fractional seconds,
    /// SQLite's `YYYY-MM-DD HH:MM:SS` (UTC), or epoch seconds/milliseconds.
    static func parse(_ value: Any?) -> Date? {
        if let number = value as? NSNumber, !(value is Bool) {
            let raw = number.doubleValue
            return Date(timeIntervalSince1970: raw > 1e11 ? raw / 1000 : raw)
        }
        guard let text = value as? String, !text.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        if let date = ISO8601DateFormatter().date(from: text) { return date }
        let sqlite = DateFormatter()
        sqlite.locale = Locale(identifier: "en_US_POSIX")
        sqlite.timeZone = TimeZone(identifier: "UTC")
        sqlite.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return sqlite.date(from: text)
    }

    static func string(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Whole milliseconds — the API's resolution, so a "tie" is a tie.
    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    }
}

nonisolated enum CloudJSON {
    static func string(_ value: Any?) -> String? {
        if let text = value as? String { return text.isEmpty ? nil : text }
        if let number = value as? NSNumber, !(value is Bool) { return number.stringValue }
        return nil
    }

    static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber, !(value is Bool) { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    static func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber, !(value is Bool) { return number.int64Value }
        if let text = value as? String { return Int64(text) }
        return nil
    }
}

// MARK: - Merge outcome types

/// Who saved the revision a merge brought in (best effort, from the
/// versions list) — the toast's "from Ana (Web)".
nonisolated struct CloudVersionAuthor: Equatable, Sendable {
    let name: String?
    /// "Mac" / "Web" / "Agent via Mac" / "Agent via Web".
    let clientLabel: String?
}

/// What a finished merge did — drives the "Merged 2 changes from Ana (Web)" toast.
nonisolated struct CloudMergeReport: Equatable, Sendable {
    /// The cloud revision whose edits were merged in.
    let theirsRevision: Int
    /// base → theirs: what this merge brought to the Mac.
    let theirsChanges: ChangeSet
    /// Same-field clashes the last writer settled (logged in History).
    let autoResolved: [MergeAutoResolved]
    /// Structural conflicts the user settled in Merge Review.
    let conflictsResolved: Int
    var author: CloudVersionAuthor?

    var theirsChangeCount: Int { ChangeSummary.countChanges(theirsChanges) }

    var toastTitle: String { Self.toastTitle(count: theirsChangeCount, author: author) }

    static func toastTitle(count: Int, author: CloudVersionAuthor?) -> String {
        let what = count == 1 ? "1 change" : count > 1 ? "\(count) changes" : "changes"
        guard let name = author?.name, !name.isEmpty else {
            return "Merged \(what) from the web editor"
        }
        if let label = author?.clientLabel, !label.isEmpty { return "Merged \(what) from \(name) (\(label))" }
        return "Merged \(what) from \(name)"
    }
}

/// A merge with structural conflicts, waiting for Merge Review. Nothing was
/// written or saved; `CloudProjectSync.resolve(_:choices:…)` applies it.
nonisolated struct CloudMergeReview: Equatable, Sendable {
    enum Origin: Equatable, Sendable { case push, pull }

    let origin: Origin
    let projectID: UUID
    let base: JSONValue
    let mine: JSONValue
    let mineDocument: Data
    let theirs: JSONValue
    let theirsDocument: Data
    let theirsRevision: Int
    let theirsUpdatedAt: Date?
    let mineWins: Bool
    /// Who made the Mac's side (base → mine), for `X-CC-Source`.
    let source: CloudSaveContext.Source
    /// The choices this merge was computed with (re-merges keep them).
    let choices: [String: MergeSide]
    let conflicts: [MergeConflict]
    let autoResolved: [MergeAutoResolved]
    var author: CloudVersionAuthor?

    /// Conflicts no choice settles yet.
    var unresolved: [MergeConflict] { conflicts.filter { choices[$0.id] == nil } }
}

nonisolated enum CloudMergeResolution: Equatable, Sendable {
    case merged(revision: Int, report: CloudMergeReport)
    /// New conflicts appeared (the cloud moved again during review).
    case needsReview(CloudMergeReview)
    /// No merge base any more — the two-way fallback.
    case conflict(remoteRevision: Int)
}

// MARK: - Engine

extension CloudProjectSync {
    /// mineWins = the project.json mtime (clamped to now) is LATER than the
    /// server's `updated_at`, at the API's millisecond resolution; ties (and
    /// an unknown server clock) go to theirs.
    static func mineWins(localModified: Date?, theirsUpdatedAt: Date?, now: Date) -> Bool {
        guard let theirs = theirsUpdatedAt, let local = localModified else { return false }
        let mine = min(local, now)
        return CloudAPIDate.milliseconds(mine) > CloudAPIDate.milliseconds(theirs)
    }

    /// `X-CC-Change` for `from` → `to` (nil without a parseable `from`).
    static func changeHeader(from: Data?, to: Data) -> String? {
        guard let from, let a = try? JSONValue.parse(data: from), let b = try? JSONValue.parse(data: to) else { return nil }
        return ProjectDiff.encodeHeader(ProjectDiff.diff(a, b))
    }

    func attributedSource(state: CloudSyncState?, mine: Data, projectDirectory: URL) -> CloudSaveContext.Source {
        CloudAttribution.source(projectDirectory: projectDirectory, baseSHA: state?.documentSHA256,
                                current: mine, since: state?.syncedAt, mark: state?.mcpMark)
    }

    func saveContext(
        checkpoint: CloudSaveContext.Checkpoint?,
        state: CloudSyncState?,
        from base: Data?,
        to document: Data,
        projectDirectory: URL
    ) -> CloudSaveContext {
        CloudSaveContext(
            clientID: clientID,
            source: attributedSource(state: state, mine: document, projectDirectory: projectDirectory),
            change: Self.changeHeader(from: base, to: document),
            checkpoint: checkpoint
        )
    }

    /// The three-way base: the sidecar's exact bytes; else (missing, or not
    /// the bytes the sidecar's hash names) the server's document of the
    /// agreed revision, re-spelled the way this Mac's pull would have
    /// written it. nil = no base anywhere → the two-way fallback.
    func mergeBase(state: CloudSyncState?, projectID: UUID, projectDirectory: URL,
                   files: [CloudRemoteFile]) async -> Data? {
        guard let state else { return nil }
        if let local = state.loadBase(from: projectDirectory) { return local }
        guard state.revision > 0 else { return nil }
        do {
            guard let fetched = try await transport.revisionDocument(projectID: projectID, revision: state.revision) else {
                mergeLogger.info("no merge base: revision \(state.revision) is not retained")
                return nil
            }
            return (try? Self.validatedDocument(fetched, projectID: projectID, projectDirectory: projectDirectory,
                                                files: files)) ?? fetched
        } catch {
            mergeLogger.error("merge base fetch failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Run the pure merge. nil when a side is not JSON (→ fallback).
    private func prepareMerge(
        origin: CloudMergeReview.Origin,
        base: Data, mine: Data, theirs: Data,
        theirsRevision: Int, theirsUpdatedAt: Date?,
        choices: [String: MergeSide],
        state: CloudSyncState?,
        projectID: UUID, projectDirectory: URL
    ) -> (review: CloudMergeReview, result: MergeResult)? {
        guard let b = try? JSONValue.parse(data: base),
              let m = try? JSONValue.parse(data: mine),
              let t = try? JSONValue.parse(data: theirs) else { return nil }
        let docURL = projectDirectory.appendingPathComponent("project.json")
        let wins = Self.mineWins(localModified: Self.modificationDate(docURL), theirsUpdatedAt: theirsUpdatedAt, now: now())
        let result = ProjectMerge.merge(base: b, mine: m, theirs: t, mineWins: wins, choices: choices)
        let review = CloudMergeReview(
            origin: origin, projectID: projectID,
            base: b, mine: m, mineDocument: mine, theirs: t, theirsDocument: theirs,
            theirsRevision: theirsRevision, theirsUpdatedAt: theirsUpdatedAt, mineWins: wins,
            source: attributedSource(state: state, mine: mine, projectDirectory: projectDirectory),
            choices: choices, conflicts: result.conflicts, autoResolved: result.autoResolved)
        return (review, result)
    }

    /// Bytes for a merged value: an input's own bytes when the merge IS that
    /// input (no reformatting churn), else the raw merged JSON — canonical,
    /// so web-only keys survive (never round-tripped through `Project`).
    static func documentBytes(_ merged: JSONValue, review: CloudMergeReview) -> Data {
        if merged == review.theirs { return review.theirsDocument }
        if merged == review.mine { return review.mineDocument }
        return Data(merged.canonical.utf8)
    }

    /// Push got 409: merge mine (the bytes it tried to save) with the head.
    func mergeAfterConflict(
        _ conflict: CloudConflict,
        mine: Data,
        state: CloudSyncState?,
        projectID: UUID,
        projectDirectory: URL,
        choices: [String: MergeSide] = [:],
        progress: @escaping (Progress) -> Void,
        attempt: Int = 0
    ) async throws -> PushOutcome {
        switch try await mergeConflict(conflict, mine: mine, state: state, projectID: projectID,
                                       projectDirectory: projectDirectory, choices: choices,
                                       progress: progress, attempt: attempt) {
        case .merged(let revision, let report): return .merged(revision: revision, report: report)
        case .needsReview(let review): return .needsReview(review)
        case .conflict(let revision): return .conflict(remoteRevision: revision)
        }
    }

    private func mergeConflict(
        _ conflict: CloudConflict,
        mine: Data,
        state: CloudSyncState?,
        projectID: UUID,
        projectDirectory: URL,
        choices: [String: MergeSide],
        progress: @escaping (Progress) -> Void,
        attempt: Int
    ) async throws -> CloudMergeResolution {
        var theirs = conflict.document
        var updatedAt = conflict.updatedAt
        if theirs == nil, let remote = try await transport.fetch(projectID: projectID) {
            theirs = remote.document
            updatedAt = remote.updatedAt ?? updatedAt
        }
        guard let theirs,
              let base = await mergeBase(state: state, projectID: projectID, projectDirectory: projectDirectory, files: [])
        else { return .conflict(remoteRevision: conflict.revision) }
        // Never merge in a document this Mac cannot open.
        try Self.checkedProject(theirs, projectID: projectID)
        guard let prepared = prepareMerge(
            origin: .push, base: base, mine: mine, theirs: theirs,
            theirsRevision: conflict.revision, theirsUpdatedAt: updatedAt, choices: choices,
            state: state, projectID: projectID, projectDirectory: projectDirectory)
        else { return .conflict(remoteRevision: conflict.revision) }
        if !prepared.review.unresolved.isEmpty {
            var review = prepared.review
            review.author = await mergeAuthor(revision: conflict.revision, projectID: projectID)
            return .needsReview(review)
        }
        return try await applyMerge(prepared.review, merged: prepared.result.merged, state: state,
                                    projectDirectory: projectDirectory, progress: progress, attempt: attempt)
    }

    /// Pull over unsynced Mac edits: merge them with the cloud's document.
    func mergePull(
        remote: CloudRemoteProject,
        theirs: Data,
        mine: Data,
        state: CloudSyncState?,
        projectID: UUID,
        projectDirectory: URL,
        choices: [String: MergeSide] = [:],
        progress: @escaping (Progress) -> Void
    ) async throws -> PullOutcome {
        guard let base = await mergeBase(state: state, projectID: projectID, projectDirectory: projectDirectory,
                                         files: remote.files)
        else { return .localChangesWouldBeLost(remoteRevision: remote.revision) }
        try Self.checkedProject(theirs, projectID: projectID)
        guard let prepared = prepareMerge(
            origin: .pull, base: base, mine: mine, theirs: theirs,
            theirsRevision: remote.revision, theirsUpdatedAt: remote.updatedAt, choices: choices,
            state: state, projectID: projectID, projectDirectory: projectDirectory)
        else { return .localChangesWouldBeLost(remoteRevision: remote.revision) }
        if !prepared.review.unresolved.isEmpty {
            var review = prepared.review
            review.author = await mergeAuthor(revision: remote.revision, projectID: projectID)
            return .needsReview(review)
        }
        switch try await applyMerge(prepared.review, merged: prepared.result.merged, state: state,
                                    projectDirectory: projectDirectory, progress: progress, attempt: 0,
                                    files: remote.files) {
        case .merged(let revision, let report): return .merged(revision: revision, report: report)
        case .needsReview(let review): return .needsReview(review)
        case .conflict(let revision): return .localChangesWouldBeLost(remoteRevision: revision)
        }
    }

    /// Apply Merge Review's Mine/Theirs choices. Re-merges against what is
    /// on disk and in the cloud NOW (the user may have edited, the cloud may
    /// have moved), keeping every choice — conflict ids are stable.
    func resolve(
        _ review: CloudMergeReview,
        choices: [String: MergeSide],
        projectDirectory: URL,
        progress: @escaping (Progress) -> Void = { _ in }
    ) async throws -> CloudMergeResolution {
        let docURL = projectDirectory.appendingPathComponent("project.json")
        guard let local = try? Data(contentsOf: docURL) else { throw CloudSyncError.missingProjectFile }
        let state = CloudSyncState.load(from: projectDirectory, projectID: review.projectID, apiBaseURL: apiBaseURL)
        var merged = review.choices
        for (id, side) in choices { merged[id] = side }
        switch review.origin {
        case .push:
            let conflict = CloudConflict(revision: review.theirsRevision, document: review.theirsDocument,
                                         updatedAt: review.theirsUpdatedAt)
            return try await mergeConflict(conflict, mine: local, state: state, projectID: review.projectID,
                                           projectDirectory: projectDirectory, choices: merged,
                                           progress: progress, attempt: 0)
        case .pull:
            guard let remote = try await transport.fetch(projectID: review.projectID), let theirs = remote.document else {
                return .conflict(remoteRevision: review.theirsRevision)
            }
            switch try await mergePull(remote: remote, theirs: theirs, mine: local, state: state,
                                       projectID: review.projectID, projectDirectory: projectDirectory,
                                       choices: merged, progress: progress) {
            case .merged(let revision, let report): return .merged(revision: revision, report: report)
            case .needsReview(let next): return .needsReview(next)
            case .localChangesWouldBeLost(let revision): return .conflict(remoteRevision: revision)
            case .pulled(let revision), .upToDate(let revision), .mediaRestored(let revision, _):
                return .conflict(remoteRevision: revision)
            case .noCloudCopy:
                return .conflict(remoteRevision: review.theirsRevision)
            }
        }
    }

    /// Write a clean merge: prove it decodes (re-pointing foreign media like
    /// a pull), bring the media it names here first, write it through
    /// ProjectFileIO (the GUI's external-edit reload path), then — for a
    /// push — save it with If-Match: theirs, checkpoint `merge`.
    private func applyMerge(
        _ review: CloudMergeReview,
        merged: JSONValue,
        state: CloudSyncState?,
        projectDirectory: URL,
        progress: @escaping (Progress) -> Void,
        attempt: Int,
        files known: [CloudRemoteFile]? = nil
    ) async throws -> CloudMergeResolution {
        let projectID = review.projectID
        let docURL = projectDirectory.appendingPathComponent("project.json")
        let bytes = Self.documentBytes(merged, review: review)
        let files: [CloudRemoteFile]
        if let known {
            files = known
        } else {
            files = try await transport.fetch(projectID: projectID)?.files ?? []
        }
        let final = try Self.validatedDocument(bytes, projectID: projectID, projectDirectory: projectDirectory, files: files)
        _ = try await syncMedia(files, referencedBy: final, projectID: projectID,
                                projectDirectory: projectDirectory, progress: progress)
        progress(Progress(phase: .writing, fraction: 0.5, message: "Applying merged edits…"))
        try ProjectFileIO.writeProjectData(final, to: docURL)

        var report = CloudMergeReport(
            theirsRevision: review.theirsRevision,
            theirsChanges: ProjectDiff.diff(review.base, review.theirs),
            autoResolved: review.autoResolved,
            conflictsResolved: review.conflicts.count)
        report.author = await mergeAuthor(revision: review.theirsRevision, projectID: projectID)

        switch review.origin {
        case .pull:
            // Agree with theirs; this Mac's side stays an unsynced edit the
            // next push sends WITH its media.
            let base = (try? Self.validatedDocument(review.theirsDocument, projectID: projectID,
                                                    projectDirectory: projectDirectory, files: files))
                ?? review.theirsDocument
            try saveState(revision: review.theirsRevision, base: base, in: projectDirectory, projectID: projectID)
            mergeLogger.info("merged cloud revision \(review.theirsRevision) into local edits (pull)")
            return .merged(revision: review.theirsRevision, report: report)
        case .push:
            if final == review.theirsDocument {
                // The merge IS the head: nothing new to save.
                try saveState(revision: review.theirsRevision, base: final, in: projectDirectory, projectID: projectID)
                return .merged(revision: review.theirsRevision, report: report)
            }
            progress(Progress(phase: .saving, fraction: 0.6, message: "Saving the merge…"))
            let context = CloudSaveContext(
                clientID: clientID, source: review.source,
                change: Self.changeHeader(from: review.theirsDocument, to: final),
                checkpoint: .merge, mergedFrom: review.theirsRevision)
            switch try await transport.save(projectID: projectID, document: final,
                                            baseRevision: review.theirsRevision, context: context) {
            case .saved(let revision, _, _):
                try saveState(revision: revision, base: final, in: projectDirectory, projectID: projectID)
                progress(Progress(phase: .saving, fraction: 1, message: "Merged"))
                mergeLogger.info("merged cloud revision \(review.theirsRevision) → saved \(revision)")
                return .merged(revision: revision, report: report)
            case .conflict(let again):
                // The cloud moved during the merge: merge again — mine is
                // now the merged file on disk, the base is unchanged.
                guard attempt < 3 else { throw CloudSyncError.tooManyRetries }
                return try await mergeConflict(again, mine: final, state: state, projectID: projectID,
                                               projectDirectory: projectDirectory, choices: review.choices,
                                               progress: progress, attempt: attempt + 1)
            }
        }
    }

    /// The author of `revision`, from the versions list (best effort).
    func mergeAuthor(revision: Int, projectID: UUID) async -> CloudVersionAuthor? {
        guard let history = transport as? CloudHistoryTransport,
              let page = try? await history.versions(projectID: projectID, before: nil, limit: 10) else { return nil }
        let version = page.versions.first { ($0.firstRevision ?? $0.revision) <= revision && revision <= $0.revision }
            ?? page.versions.first
        return version.map { CloudVersionAuthor(name: $0.actorName, clientLabel: $0.clientLabel) }
    }
}
