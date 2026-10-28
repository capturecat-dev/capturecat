import AppKit
import Foundation
import os

private let brokerLogger = Logger(subsystem: "so.capturecat.CaptureCat", category: "AgentShareBroker")

/// GUI half of the MCP `share_project` tool (the other half is
/// MCPServer+Share). The owner's rule: an agent must ASK FIRST before a
/// video becomes viewable to others, and agents can never delete anything.
///
/// For every request the `--mcp` process files (AgentShareIPC), the broker:
///  1. claims it (atomic rename — it fires once, and a stale request from a
///     previous run or one the MCP side gave up on is dropped unseen);
///  2. refuses up front what can't be asked: onboarding unfinished, unknown
///     project, signed out, a share of that project already running;
///  3. shows the CCKit consent card (AgentShareConsent) — project, who is
///     asking, who will be able to watch — one at a time;
///  4. ONLY on Allow, starts the share through `ShareJobCenter.shareProject`,
///     exactly what a project card's Share button runs (the card shows the
///     progress too), with the approved visibility enforced by the upload;
///  5. mirrors the job into a status file until it is done or failed.
///
/// There is no "always allow": every call is its own card, and nothing an
/// agent writes to disk can stand in for the Allow click.
@MainActor
final class AgentShareBroker {
    struct ProjectInfo {
        let id: UUID
        let name: String
    }

    /// Everything the consent card shows.
    struct ConsentRequest {
        let jobID: String
        let projectName: String
        let visibility: ShareVisibility
        /// The MCP client's self-reported name (initialize clientInfo).
        let clientName: String?
        let accountEmail: String?
        /// The project's current link — this share replaces its video.
        let existingShareURL: String?
    }

    struct JobSnapshot {
        let state: ShareService.ShareState
        let videoID: String?
        let warning: String?
    }

    /// The app seams, injectable so `--share-consent-test` can drive the
    /// real broker against a temp folder with no network and no user data.
    struct Environment {
        var needsOnboarding: () -> Bool
        var isSignedIn: () -> Bool
        var accountEmail: () -> String?
        var project: (UUID) -> ProjectInfo?
        var existingShareURL: (UUID) -> String?
        var isSharing: (UUID) -> Bool
        /// Present the consent card; the callback fires exactly once.
        var askConsent: (ConsentRequest, @escaping (Bool) -> Void) -> Void
        /// Start the share — called only after Allow. nil = not started.
        var startShare: (UUID, ShareVisibility) -> UUID?
        var job: (UUID) -> JobSnapshot?
        var now: () -> Date = Date.init
        var pid: Int32 = ProcessInfo.processInfo.processIdentifier
    }

    private struct Pending {
        let request: AgentShareIPC.Request
        let projectID: UUID
        let visibility: ShareVisibility
        var status: AgentShareIPC.Status
    }

    private let env: Environment
    private var queue: [Pending] = []
    private var isPresenting = false
    private var tracked: [String: (localID: UUID, status: AgentShareIPC.Status)] = [:]

    init(environment: Environment) {
        self.env = environment
    }

    /// The live app wiring.
    static func live(appState: AppState) -> AgentShareBroker {
        func project(_ id: UUID) -> Project? {
            appState.projectStore.projects.first { $0.id == id }
        }
        return AgentShareBroker(environment: Environment(
            needsOnboarding: { appState.needsOnboarding },
            // The very check the upload makes (ShareUploadAPI.sessionToken).
            isSignedIn: { AuthKeychain.currentToken() != nil },
            accountEmail: { appState.currentAccountEmail },
            project: { id in project(id).map { ProjectInfo(id: $0.id, name: $0.name) } },
            existingShareURL: { appState.library.sharedURLs[$0] },
            isSharing: { appState.shareJobCenter.job(for: $0)?.isActive == true },
            askConsent: { request, answer in AgentShareConsent.present(request, completion: answer) },
            startShare: { id, visibility in
                guard let project = project(id) else { return nil }
                // Same arguments as ProjectBrowserViewController's card.onShare.
                return appState.shareJobCenter.shareProject(
                    projectID: project.id,
                    projectName: project.name,
                    durationSeconds: project.duration,
                    annotationMarkers: ExportSheetController.annotationMarkers(for: project),
                    transcript: ShareIntelligence.transcriptPayload(for: project),
                    visibility: visibility
                )
            },
            job: { id in
                appState.shareJobCenter.job(id: id).map {
                    JobSnapshot(state: $0.state, videoID: $0.videoID, warning: $0.warning)
                }
            }
        ))
    }

    // MARK: - Lifecycle

    /// Drops every request left from before this launch (they must never
    /// pop a card later) and announces the broker.
    func start() {
        let fm = FileManager.default
        let dir = AgentShareIPC.directory
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        let weekAgo = env.now().addingTimeInterval(-7 * 24 * 3600)
        for name in names {
            let url = dir.appendingPathComponent(name)
            if name.hasSuffix(".request.json") || name.hasSuffix(".claimed.json") || name.hasPrefix(".tmp-") {
                try? fm.removeItem(at: url)
            } else if name.hasSuffix(".status.json"),
                      let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                      modified < weekAgo {
                try? fm.removeItem(at: url)
            }
        }
        do {
            try AgentShareIPC.write(
                AgentShareIPC.Broker(protocolVersion: AgentShareIPC.protocolVersion, pid: env.pid,
                                     startedAt: env.now()),
                to: AgentShareIPC.brokerURL
            )
        } catch {
            brokerLogger.error("could not announce the share broker: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Called from AutomationBridge's poll timer (0.4 s).
    func poll() {
        claimRequests()
        syncTrackedJobs()
    }

    // MARK: - Requests

    private func claimRequests() {
        let fm = FileManager.default
        let dir = AgentShareIPC.directory
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names.sorted() where name.hasSuffix(".request.json") {
            let jobID = String(name.dropLast(".request.json".count))
            let source = dir.appendingPathComponent(name)
            guard AgentShareIPC.isValidJobID(jobID) else {
                try? fm.removeItem(at: source)
                continue
            }
            let claimed = AgentShareIPC.claimedURL(jobID)
            try? fm.removeItem(at: claimed)
            // Claim by rename: exactly one claimant, and a crash mid-way
            // leaves nothing that could fire on the next launch.
            guard (try? fm.moveItem(at: source, to: claimed)) != nil else { continue }
            let request = AgentShareIPC.read(AgentShareIPC.Request.self, from: claimed)
            try? fm.removeItem(at: claimed)
            guard let request else { continue }
            handle(request, jobID: jobID)
        }
    }

    private func handle(_ request: AgentShareIPC.Request, jobID: String) {
        guard request.jobId == jobID, request.protocolVersion == AgentShareIPC.protocolVersion else { return }
        // The MCP side already reported "no answer" and withdrew — never
        // surface a card for a request nobody is waiting on.
        guard request.claimBy > env.now() else {
            brokerLogger.info("dropping stale share request \(jobID, privacy: .public)")
            return
        }
        var status = AgentShareIPC.Status(
            jobId: jobID, state: .awaitingApproval, progress: nil,
            projectId: request.projectId, projectName: "", privacy: request.privacy,
            shareUrl: nil, videoId: nil, error: nil, warning: nil, replacesExistingLink: nil,
            updatedAt: env.now(), brokerPID: env.pid
        )
        func refuse(_ message: String) {
            status.state = .refused
            status.error = message
            publish(status)
        }
        guard let visibility = ShareVisibility(rawValue: request.privacy) else {
            return refuse("privacy must be one of: "
                + ShareVisibility.allCases.map(\.rawValue).joined(separator: ", "))
        }
        guard let projectID = UUID(uuidString: request.projectId) else {
            return refuse("project_id must be a project UUID from list_projects")
        }
        guard !env.needsOnboarding() else {
            return refuse("CaptureCat hasn't finished setting up. Ask the user to complete onboarding in the "
                + "app, then try again.")
        }
        guard let project = env.project(projectID) else {
            return refuse("No project with id \(request.projectId) in the CaptureCat library.")
        }
        status.projectName = project.name
        guard env.isSignedIn() else {
            return refuse("Not signed in to CaptureCat. Sharing uploads to the user's CaptureCat account: ask "
                + "the user to sign in in the CaptureCat app (the account row in the project browser, or "
                + "Settings), then try again.")
        }
        guard !env.isSharing(projectID) else {
            return refuse("A share of “\(project.name)” is already in progress in CaptureCat. Wait for it to "
                + "finish, then try again.")
        }
        status.replacesExistingLink = env.existingShareURL(projectID) != nil
        publish(status)
        queue.append(Pending(request: request, projectID: projectID, visibility: visibility, status: status))
        presentNextIfIdle()
    }

    private func presentNextIfIdle() {
        guard !isPresenting, !queue.isEmpty else { return }
        let pending = queue.removeFirst()
        isPresenting = true
        let consent = ConsentRequest(
            jobID: pending.request.jobId,
            projectName: pending.status.projectName,
            visibility: pending.visibility,
            clientName: pending.request.clientName,
            accountEmail: env.accountEmail(),
            existingShareURL: env.existingShareURL(pending.projectID)
        )
        var answered = false
        env.askConsent(consent) { [weak self] allowed in
            guard let self, !answered else { return }
            answered = true
            self.decide(pending, allowed: allowed)
            self.isPresenting = false
            self.presentNextIfIdle()
        }
    }

    private func decide(_ pending: Pending, allowed: Bool) {
        var status = pending.status
        guard allowed else {
            status.state = .declined
            status.error = "The user declined: “\(status.projectName)” was not shared. Don't retry unless the "
                + "user asks you to."
            publish(status)
            return
        }
        // The world may have moved while the card was up.
        guard env.isSignedIn() else {
            status.state = .refused
            status.error = "Signed out of CaptureCat while the request was open — nothing was shared."
            publish(status)
            return
        }
        guard !env.isSharing(pending.projectID),
              let localID = env.startShare(pending.projectID, pending.visibility) else {
            status.state = .refused
            status.error = "A share of “\(status.projectName)” is already in progress — nothing new was started."
            publish(status)
            return
        }
        status.state = .exporting
        status.progress = 0
        tracked[status.jobId] = (localID, status)
        publish(status)
        brokerLogger.info("agent share \(status.jobId, privacy: .public) approved (\(pending.visibility.rawValue, privacy: .public))")
    }

    // MARK: - Job mirror

    private func syncTrackedJobs() {
        for (jobID, entry) in tracked {
            var status = entry.status
            if let job = env.job(entry.localID) {
                switch job.state {
                case .exporting(let progress):
                    status.state = .exporting
                    status.progress = progress
                case .uploading(let progress):
                    status.state = .uploading
                    status.progress = progress
                case .completing:
                    status.state = .completing
                    status.progress = 1
                case .done(let url):
                    status.state = .done
                    status.progress = 1
                    status.shareUrl = url
                case .failed(let message):
                    status.state = .failed
                    status.error = message
                case .idle:
                    status.state = .interrupted
                    status.error = "The share job was reset before it finished."
                }
                status.videoId = job.videoID ?? status.videoId
                status.warning = job.warning
            } else {
                status.state = .interrupted
                status.error = "CaptureCat stopped tracking this share before it finished."
            }
            let previous = entry.status
            let progressMoved = abs((status.progress ?? 0) - (previous.progress ?? 0)) >= 0.01
            if status.state != previous.state || progressMoved || status.videoId != previous.videoId
                || status.shareUrl != previous.shareUrl || status.warning != previous.warning {
                publish(status)
            }
            if status.state.isTerminal {
                tracked.removeValue(forKey: jobID)
            } else {
                tracked[jobID] = (entry.localID, status)
            }
        }
    }

    private func publish(_ status: AgentShareIPC.Status) {
        var status = status
        status.updatedAt = env.now()
        status.brokerPID = env.pid
        do {
            try AgentShareIPC.write(status, to: AgentShareIPC.statusURL(status.jobId))
        } catch {
            brokerLogger.error("share status write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Probe seams (--share-consent-test)

    var probeQueueCount: Int { queue.count }
    var probeTrackedCount: Int { tracked.count }
}
