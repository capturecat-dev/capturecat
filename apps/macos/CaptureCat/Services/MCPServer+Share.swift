import AppKit
import Foundation

/// `share_project` / `share_status` — publish a project as a share link, but
/// only with the user's say-so (the owner's rule: an agent must ASK FIRST
/// before a video becomes viewable to others).
///
/// This headless process never uploads. It files a request (AgentShareIPC)
/// for the RUNNING GUI app, whose AgentShareBroker shows the CCKit consent
/// card and — only on Allow — runs the project card's own share pipeline
/// (ShareJobCenter.shareProject: export, upload, confirm, replace-in-place).
/// No GUI, an old GUI, a decline, signed out: a clear tool error, nothing
/// uploaded. Approval is per call; no argument can pre-grant it.
///
/// share_project replies asynchronously (a background thread waits for the
/// user's answer) so the stdio loop keeps serving other calls; after
/// `shareDecisionWait` without an answer it returns `awaiting_approval` and
/// the agent polls share_status like it would for the upload itself.
extension MCPServer {
    static let shareDecisionWait: TimeInterval = 45
    /// How long a filed request may sit unclaimed before it is withdrawn
    /// (a var only so the harness can shorten it).
    nonisolated(unsafe) static var shareClaimTimeout: TimeInterval = 10
    static let shareArgumentKeys: Set<String> = ["project_id", "privacy"]

    // MARK: - Who's asking (initialize clientInfo)

    private static let clientInfoLock = NSLock()
    nonisolated(unsafe) private static var clientInfoValue: (name: String?, version: String?) = (nil, nil)

    static func recordClientInfo(_ info: Any?) {
        let dict = info as? [String: Any]
        clientInfoLock.lock()
        clientInfoValue = (dict?["name"] as? String, dict?["version"] as? String)
        clientInfoLock.unlock()
    }

    static var clientInfo: (name: String?, version: String?) {
        clientInfoLock.lock()
        defer { clientInfoLock.unlock() }
        return clientInfoValue
    }

    // MARK: - Is a broker there to ask?

    /// Harness seam: the GUI pids the share tools see (nil = LaunchServices).
    nonisolated(unsafe) static var guiPIDsOverride: (() -> [Int32])?

    static func runningGUIPIDs() -> [Int32] {
        if let override = guiPIDsOverride { return override() }
        let bundleID = Bundle.main.bundleIdentifier ?? "so.capturecat.CaptureCat"
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != me }
            .map(\.processIdentifier)
    }

    enum ShareReachability: Equatable {
        case ready(brokerPID: Int32)
        case noGUI
        case brokerMissing
    }

    static func shareReachability() -> ShareReachability {
        let pids = runningGUIPIDs()
        guard !pids.isEmpty else { return .noGUI }
        guard let broker = AgentShareIPC.read(AgentShareIPC.Broker.self, from: AgentShareIPC.brokerURL),
              broker.protocolVersion == AgentShareIPC.protocolVersion,
              pids.contains(broker.pid) else { return .brokerMissing }
        return .ready(brokerPID: broker.pid)
    }

    static let noGUIRefusal = "CaptureCat isn't running. Sharing needs the CaptureCat app open so the user can "
        + "approve it there — ask the user to open CaptureCat, then try again. Nothing was uploaded."
    static let brokerMissingRefusal = "The running CaptureCat app can't approve agent shares (it is an older "
        + "version, or still starting up). Ask the user to update or relaunch CaptureCat, then try again. "
        + "Nothing was uploaded."

    // MARK: - share_project

    /// Entry point from callTool: validation errors answer at once; the wait
    /// for the user's decision runs on its own thread and replies when done.
    static func shareProjectAsync(_ arguments: [String: Any], requestID: Any, progress: ProgressReporter) {
        let filed: (request: AgentShareIPC.Request, projectName: String)
        do {
            filed = try fileShareRequest(arguments)
        } catch {
            replyToolError(id: requestID, message: error.localizedDescription)
            return
        }
        let thread = Thread {
            do {
                let result = try awaitShareDecision(filed.request, projectName: filed.projectName,
                                                    progress: progress)
                replyToolResult(id: requestID, name: "share_project", result: result)
            } catch {
                replyToolError(id: requestID, message: error.localizedDescription)
            }
        }
        thread.name = "capturecat-mcp-share"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Validates, checks a broker is there to ask, and files the request.
    static func fileShareRequest(_ arguments: [String: Any]) throws -> (request: AgentShareIPC.Request,
                                                                        projectName: String) {
        let unknown = Set(arguments.keys).subtracting(shareArgumentKeys)
        guard unknown.isEmpty else {
            throw ToolError("unknown argument(s): \(unknown.sorted().joined(separator: ", ")) — share_project takes "
                + "project_id and privacy only. Approval can only come from the user's click in CaptureCat.")
        }
        guard let ref = arguments["project_id"] as? String, !ref.isEmpty else {
            throw ToolError("missing project_id — a project UUID from list_projects")
        }
        guard let uuid = UUID(uuidString: ref) else {
            throw ToolError("project_id must be a project UUID from list_projects (only library projects can be "
                + "shared)")
        }
        let (_, project) = try loadProject(uuid.uuidString)
        let privacyRaw = arguments["privacy"] ?? ShareVisibility.unlisted.rawValue
        guard let privacy = privacyRaw as? String, let visibility = ShareVisibility(rawValue: privacy) else {
            throw ToolError("privacy must be one of: "
                + ShareVisibility.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", "))
        }

        switch shareReachability() {
        case .noGUI: throw ToolError(noGUIRefusal)
        case .brokerMissing: throw ToolError(brokerMissingRefusal)
        case .ready: break
        }

        let client = clientInfo
        let now = Date()
        let request = AgentShareIPC.Request(
            protocolVersion: AgentShareIPC.protocolVersion,
            jobId: UUID().uuidString,
            projectId: project.id.uuidString,
            privacy: visibility.rawValue,
            clientName: client.name.map { String($0.prefix(200)) },
            clientVersion: client.version.map { String($0.prefix(60)) },
            requestedAt: now,
            claimBy: now.addingTimeInterval(shareClaimTimeout),
            requesterPID: ProcessInfo.processInfo.processIdentifier
        )
        try AgentShareIPC.write(request, to: AgentShareIPC.requestURL(request.jobId))
        log("share_project \(request.jobId): asking the user (\(visibility.rawValue))")
        return (request, project.name)
    }

    /// Blocks THIS (background) thread until the user answers, the request
    /// goes unclaimed, or `shareDecisionWait` passes.
    static func awaitShareDecision(
        _ request: AgentShareIPC.Request, projectName: String, progress: ProgressReporter,
        wait: TimeInterval = shareDecisionWait
    ) throws -> [String: Any] {
        let start = Date()
        let deadline = start.addingTimeInterval(wait)
        let fm = FileManager.default
        while Date() < deadline {
            if let status = AgentShareIPC.read(AgentShareIPC.Status.self,
                                               from: AgentShareIPC.statusURL(request.jobId)),
               status.state != .awaitingApproval {
                switch status.state {
                case .declined:
                    throw ToolError(status.error ?? "The user declined — nothing was shared.")
                case .refused:
                    throw ToolError(status.error ?? "CaptureCat refused the request — nothing was shared.")
                case .failed, .interrupted:
                    throw ToolError("The user approved, but the share failed: "
                        + (status.error ?? "unknown error") + ". Nothing is viewable; tell the user.")
                case .exporting, .uploading, .completing, .done:
                    var payload = sharePayload(status)
                    payload["note"] = "The user approved. CaptureCat is exporting and uploading (its project card "
                        + "shows progress). Poll share_status {job_id} every few seconds; the link is live only "
                        + "once state is \"done\" — then report shareUrl to the user."
                    return payload
                case .awaitingApproval:
                    break
                }
            }
            // Unclaimed past its deadline: withdraw it so it can never pop up
            // later. If the GUI claimed it in the meantime the delete fails
            // and we keep waiting for its answer.
            let requestURL = AgentShareIPC.requestURL(request.jobId)
            if Date() > request.claimBy, fm.fileExists(atPath: requestURL.path),
               (try? fm.removeItem(at: requestURL)) != nil {
                throw ToolError("CaptureCat didn't pick up the request (is it busy or frozen?). Nothing was "
                    + "uploaded — ask the user to check the app, then try again.")
            }
            let elapsed = Date().timeIntervalSince(start)
            progress.report(min(elapsed, wait - 0.5).rounded(), total: wait,
                            message: "Waiting for the user to answer in CaptureCat")
            Thread.sleep(forTimeInterval: 0.25)
        }
        var payload = sharePayload(AgentShareIPC.read(AgentShareIPC.Status.self,
                                                      from: AgentShareIPC.statusURL(request.jobId)),
                                   fallback: request, projectName: projectName)
        payload["state"] = AgentShareIPC.State.awaitingApproval.rawValue
        payload["note"] = "CaptureCat is asking the user to approve this share; they haven't answered yet. Poll "
            + "share_status {job_id} — don't file another share_project for the same project meanwhile."
        return payload
    }

    // MARK: - share_status

    static func shareStatus(_ arguments: [String: Any]) throws -> [String: Any] {
        guard let jobID = arguments["job_id"] as? String, !jobID.isEmpty else {
            throw ToolError("missing job_id — the jobId share_project returned")
        }
        guard AgentShareIPC.isValidJobID(jobID) else {
            throw ToolError("job_id must be the jobId share_project returned")
        }
        let statusURL = AgentShareIPC.statusURL(jobID)
        guard var status = AgentShareIPC.read(AgentShareIPC.Status.self, from: statusURL) else {
            if let pending = AgentShareIPC.read(AgentShareIPC.Request.self, from: AgentShareIPC.requestURL(jobID)) {
                var payload = sharePayload(nil, fallback: pending, projectName: "")
                payload["note"] = "Filed; CaptureCat hasn't shown it to the user yet. Poll again in a few seconds."
                return payload
            }
            throw ToolError("unknown job_id \(jobID) — no share request with that id (job ids from a previous run "
                + "expire after a week)")
        }
        if !status.state.isTerminal, !runningGUIPIDs().contains(status.brokerPID) {
            status.state = .interrupted
            status.error = "CaptureCat quit before the share finished. Nothing more will happen for this job; "
                + "ask the user to reopen CaptureCat and share again."
        }
        var payload = sharePayload(status)
        payload["note"] = shareStateNote(status)
        return payload
    }

    static func shareStateNote(_ status: AgentShareIPC.Status) -> String {
        switch status.state {
        case .awaitingApproval:
            return "Waiting for the user to answer the request in CaptureCat. Poll again in a few seconds."
        case .declined:
            return "The user declined. Nothing was shared; don't retry unless the user asks."
        case .refused:
            return "CaptureCat couldn't ask the user (see error). Nothing was shared."
        case .exporting:
            return "Approved — CaptureCat is rendering the video (progress 0–1). Poll again."
        case .uploading:
            return "Approved — uploading (progress 0–1). Poll again."
        case .completing:
            return "Upload finished; the server is verifying it. Poll again."
        case .done:
            return "Live. shareUrl is the link — \(ShareVisibility(rawValue: status.privacy)?.summary ?? "")"
        case .failed:
            return "The share failed (see error). Nothing new is viewable; tell the user."
        case .interrupted:
            return "The share stopped before finishing (see error)."
        }
    }

    /// Status → the structured payload both share tools return.
    static func sharePayload(
        _ status: AgentShareIPC.Status?, fallback: AgentShareIPC.Request? = nil, projectName: String = ""
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "jobId": status?.jobId ?? fallback?.jobId ?? "",
            "state": (status?.state ?? .awaitingApproval).rawValue,
            "projectId": status?.projectId ?? fallback?.projectId ?? "",
            "projectName": status.map { $0.projectName.isEmpty ? projectName : $0.projectName } ?? projectName,
            "privacy": status?.privacy ?? fallback?.privacy ?? ShareVisibility.unlisted.rawValue,
        ]
        guard let status else { return payload }
        if let progress = status.progress { payload["progress"] = round3(max(0, min(1, progress))) }
        if let url = status.shareUrl { payload["shareUrl"] = url }
        if let videoId = status.videoId { payload["videoId"] = videoId }
        if let error = status.error { payload["error"] = error }
        if let warning = status.warning { payload["warning"] = warning }
        if let replaces = status.replacesExistingLink { payload["replacesExistingLink"] = replaces }
        payload["updatedAt"] = ISO8601DateFormatter().string(from: status.updatedAt)
        return payload
    }

    // MARK: - Schemas

    static var shareJobOutputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "jobId": ["type": "string", "description": "Pass to share_status."],
                "state": [
                    "type": "string",
                    "enum": ["awaiting_approval", "declined", "refused", "exporting", "uploading", "completing",
                             "done", "failed", "interrupted"],
                ],
                "projectId": ["type": "string"],
                "projectName": ["type": "string"],
                "privacy": ["type": "string", "enum": ShareVisibility.allCases.map(\.rawValue)],
                "progress": ["type": "number", "minimum": 0, "maximum": 1,
                             "description": "Within the current phase (exporting, then uploading)."],
                "shareUrl": ["type": "string", "description": "The link — present once state is done."],
                "videoId": ["type": "string", "description": "The cloud video id (remote MCP tools take it)."],
                "error": ["type": "string"],
                "warning": ["type": "string"],
                "replacesExistingLink": ["type": "boolean",
                                         "description": "The project was shared before: same link, new version."],
                "updatedAt": ["type": "string"],
                "note": ["type": "string", "description": "What to do next."],
            ],
            "required": ["jobId", "state", "projectId", "projectName", "privacy", "note"],
        ]
    }
}
