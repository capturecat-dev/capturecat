import AppKit

/// `CaptureCat --share-consent-test` — the MCP share_project gate end to end,
/// with no network and no user data (a temp library + a temp IPC folder):
///
///  IPC  the REAL MCP-side code (fileShareRequest / awaitShareDecision /
///       shareStatus) against the REAL AgentShareBroker, polled on the main
///       run loop like AutomationBridge does, with the app seams faked:
///       no GUI → refusal; old GUI (no broker) → refusal; signed out →
///       refusal without a card; Don't Allow → declined, nothing started;
///       Allow → the share starts with the approved visibility and
///       share_status walks exporting → uploading → done (url, video id);
///       no answer yet → awaiting_approval, then the late answer lands;
///       an unclaimed request is withdrawn and never pops up later; stale
///       and pre-launch requests are dropped unseen; a dead broker reads as
///       interrupted; extra arguments ("approved") are refused; every
///       payload conforms to the advertised outputSchema.
///  CARD the real consent card (AgentShareConsent.present, standalone):
///       entrance + row stagger sampled MID-FLIGHT, Allow disarmed then
///       armed, topology (rows inside the card, centred on screen, kit
///       material on the well), texts; a posted Return does NOT approve —
///       and a control card with the default Return DOES close on the same
///       posted event, so that check can't pass vacuously; Escape declines;
///       clicking Allow approves. Saves an upright capture.
@MainActor
enum AgentShareHarness {
    private static var failures = 0

    private static func expect(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if ok {
            print("SHARE PASS  \(name)")
        } else {
            failures += 1
            print("SHARE FAIL  \(name)  \(detail())")
        }
    }

    static func run() -> Never {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            catalogChecks()
            await ipcChecks()
            await consentCardChecks()
            print(failures == 0 ? "SHARE-CONSENT PASS" : "SHARE-CONSENT FAIL (\(failures) failed)")
            exit(failures == 0 ? 0 : 1)
        }
        app.run()
        exit(0)
    }

    private static func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: - Catalog + protocol

    private static func catalogChecks() {
        let tools = MCPServer.toolDefinitions
        let byName = Dictionary(uniqueKeysWithValues: tools.compactMap { tool in
            (tool["name"] as? String).map { ($0, tool) }
        })
        for name in ["share_project", "share_status", "list_projects", "describe_project"] {
            expect((byName[name]?["outputSchema"] as? [String: Any])?["type"] as? String == "object",
                   "\(name) declares an object outputSchema")
        }
        let allHints = tools.allSatisfy { tool in
            let a = tool["annotations"] as? [String: Any] ?? [:]
            return ["readOnlyHint", "destructiveHint", "idempotentHint", "openWorldHint"]
                .allSatisfy { a[$0] is Bool }
        }
        expect(allHints, "every tool carries all four annotation hints")
        expect(tools.allSatisfy { ($0["annotations"] as? [String: Any])?["destructiveHint"] as? Bool == false },
               "destructiveHint is false everywhere (no tool deletes)")
        let share = byName["share_project"]?["annotations"] as? [String: Any] ?? [:]
        expect(share["readOnlyHint"] as? Bool == false && share["openWorldHint"] as? Bool == true
               && share["idempotentHint"] as? Bool == false, "share_project: write, open-world, not idempotent")
        let input = byName["share_project"]?["inputSchema"] as? [String: Any] ?? [:]
        expect(input["additionalProperties"] as? Bool == false
               && (input["required"] as? [String]) == ["project_id"],
               "share_project input is closed (no approval argument can exist)")
        expect(MCPServer.structuredOutputTools.isSuperset(of: ["share_project", "share_status", "list_projects",
                                                               "describe_project"]),
               "structuredContent is attached for every outputSchema tool")
        for version in ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"] {
            expect(MCPServer.negotiateProtocolVersion(version) == version, "initialize echoes \(version)")
        }
        expect(MCPServer.negotiateProtocolVersion("1999-01-01") == MCPServer.latestProtocolVersion
               && MCPServer.latestProtocolVersion == "2026-07-28", "unknown version → latest (2026-07-28)")
    }

    // MARK: - IPC (MCP side ⇄ broker)

    nonisolated(unsafe) private static var guiPIDs: [Int32] = []

    private final class FakeApp {
        var signedIn = true
        var sharing = false
        var onboarding = false
        var consents: [AgentShareBroker.ConsentRequest] = []
        /// nil = leave the card up (callback stored in `pendingAnswer`).
        var answer: Bool? = false
        var pendingAnswer: ((Bool) -> Void)?
        var starts: [(UUID, ShareVisibility)] = []
        var jobStates: [UUID: AgentShareBroker.JobSnapshot] = [:]
    }

    private struct Attempt {
        var payload: [String: Any]?
        var error: String?
    }

    /// share_project exactly as callTool runs it, minus the stdout reply.
    private static func attempt(_ arguments: [String: Any], wait: TimeInterval = 6) async -> Attempt {
        await withCheckedContinuation { (continuation: CheckedContinuation<Attempt, Never>) in
            let thread = Thread {
                var outcome = Attempt()
                do {
                    let filed = try MCPServer.fileShareRequest(arguments)
                    outcome.payload = try MCPServer.awaitShareDecision(
                        filed.request, projectName: filed.projectName,
                        progress: MCPServer.ProgressReporter(token: nil), wait: wait)
                } catch {
                    outcome.error = error.localizedDescription
                }
                continuation.resume(returning: outcome)
            }
            thread.start()
        }
    }

    private static func status(_ jobID: String) -> (payload: [String: Any]?, error: String?) {
        do { return (try MCPServer.shareStatus(["job_id": jobID]), nil) } catch {
            return (nil, error.localizedDescription)
        }
    }

    /// The advertised outputSchema must describe what the tool returns.
    private static func conforms(_ payload: [String: Any]) -> Bool {
        let schema = MCPServer.shareJobOutputSchema
        let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
        let required = schema["required"] as? [String] ?? []
        guard required.allSatisfy({ payload[$0] != nil }) else { return false }
        for (key, value) in payload {
            guard let spec = properties[key] else { return false }
            switch spec["type"] as? String {
            case "string":
                guard let text = value as? String else { return false }
                if let allowed = spec["enum"] as? [String], !allowed.contains(text) { return false }
            case "number": guard value is NSNumber, !(value is Bool) else { return false }
            case "boolean": guard value is Bool else { return false }
            default: return false
            }
        }
        return true
    }

    private static func requestFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: AgentShareIPC.directory.path)) ?? [])
            .filter { $0.hasSuffix(".request.json") }
    }

    private static func ipcChecks() async {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("capturecat-share-test-\(UUID().uuidString)", isDirectory: true)
        let projects = root.appendingPathComponent("Projects", isDirectory: true)
        AgentShareIPC.rootOverride = root.appendingPathComponent("shares", isDirectory: true)
        MCPServer.projectsRootOverride = projects
        MCPServer.guiPIDsOverride = { AgentShareHarness.guiPIDs }
        defer {
            try? fm.removeItem(at: root)
            AgentShareIPC.rootOverride = nil
            MCPServer.projectsRootOverride = nil
            MCPServer.guiPIDsOverride = nil
        }

        let project = Project(name: "Harness Demo", duration: 12)
        let projectDir = projects.appendingPathComponent(project.id.uuidString, isDirectory: true)
        do {
            try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)
            try JSONEncoder().encode(project).write(to: projectDir.appendingPathComponent("project.json"))
        } catch {
            expect(false, "fixture project", error.localizedDescription)
            return
        }
        let projectID = project.id.uuidString
        MCPServer.recordClientInfo(["name": "Harness\nAgent", "version": "9"])

        // 1. No GUI running → the clear refusal, nothing filed.
        guiPIDs = []
        var outcome = await attempt(["project_id": projectID])
        expect(outcome.error == MCPServer.noGUIRefusal, "no GUI → refusal", outcome.error ?? "<no error>")
        expect(requestFiles().isEmpty, "no GUI → nothing filed")

        // 2. A GUI without a broker (older build / still launching).
        let me = ProcessInfo.processInfo.processIdentifier
        guiPIDs = [me]
        outcome = await attempt(["project_id": projectID])
        expect(outcome.error == MCPServer.brokerMissingRefusal, "GUI without broker → refusal",
               outcome.error ?? "<no error>")

        // 3. Argument validation — nothing can smuggle in an approval.
        outcome = await attempt(["project_id": projectID, "approved": true])
        expect(outcome.error?.contains("Approval can only come from the user's click") == true,
               "an 'approved' argument is refused", outcome.error ?? "")
        outcome = await attempt(["project_id": projectID, "privacy": "everyone"])
        expect(outcome.error?.contains("privacy must be one of") == true, "unknown privacy refused",
               outcome.error ?? "")
        outcome = await attempt(["project_id": "../../etc"])
        expect(outcome.error?.contains("project UUID") == true, "non-UUID project refused", outcome.error ?? "")
        outcome = await attempt(["project_id": UUID().uuidString])
        expect(outcome.error?.contains("not found") == true, "unknown project refused", outcome.error ?? "")

        // The broker, polled on the main run loop like AutomationBridge.
        let fake = FakeApp()
        let brokerProject = AgentShareBroker.ProjectInfo(id: project.id, name: project.name)
        let broker = AgentShareBroker(environment: .init(
            needsOnboarding: { fake.onboarding },
            isSignedIn: { fake.signedIn },
            accountEmail: { "owner@example.com" },
            project: { $0 == project.id ? brokerProject : nil },
            existingShareURL: { _ in nil },
            isSharing: { _ in fake.sharing },
            askConsent: { request, reply in
                fake.consents.append(request)
                if let answer = fake.answer {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { reply(answer) }
                } else {
                    fake.pendingAnswer = reply
                }
            },
            startShare: { id, visibility in
                fake.starts.append((id, visibility))
                let local = UUID()
                fake.jobStates[local] = .init(state: .exporting(progress: 0.25), videoID: nil, warning: nil)
                return local
            },
            job: { fake.jobStates[$0] }
        ))
        broker.start()
        var polling = true
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated { if polling { broker.poll() } }
        }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }

        // 4. Signed out → refused before any card.
        fake.signedIn = false
        outcome = await attempt(["project_id": projectID])
        expect(outcome.error?.contains("Not signed in") == true && fake.consents.isEmpty,
               "signed out → refusal, no card shown", outcome.error ?? "<no error>")
        fake.signedIn = true

        // 5. Onboarding unfinished → refused.
        fake.onboarding = true
        outcome = await attempt(["project_id": projectID])
        expect(outcome.error?.contains("onboarding") == true && fake.consents.isEmpty,
               "onboarding → refusal, no card shown", outcome.error ?? "")
        fake.onboarding = false

        // 6. Don't Allow → declined; nothing started.
        fake.answer = false
        outcome = await attempt(["project_id": projectID])
        expect(outcome.error?.contains("declined") == true, "Don't Allow → declined", outcome.error ?? "<no error>")
        expect(fake.starts.isEmpty, "declined → no share started")
        let asked = fake.consents.last
        expect(asked?.projectName == "Harness Demo" && asked?.visibility == .unlisted
               && asked?.clientName == "Harness\nAgent" && asked?.accountEmail == "owner@example.com",
               "the card is told the project, default visibility, client and account",
               String(describing: asked))
        expect(AgentShareConsent.displayableClientName(asked?.clientName) == "HarnessAgent",
               "a self-reported client name is shown on one printable line")

        // 7. Allow → started with the approved visibility; status walks to done.
        fake.answer = true
        outcome = await attempt(["project_id": projectID, "privacy": "public"])
        let jobID = outcome.payload?["jobId"] as? String ?? ""
        expect(outcome.error == nil && outcome.payload?["state"] as? String == "exporting",
               "Allow → share started (exporting)", outcome.error ?? String(describing: outcome.payload))
        expect(fake.starts.count == 1 && fake.starts.first?.0 == project.id && fake.starts.first?.1 == .public,
               "the share runs with the approved visibility", String(describing: fake.starts))
        expect(outcome.payload.map(conforms) == true, "share_project payload conforms to its outputSchema",
               String(describing: outcome.payload))
        if let local = fake.jobStates.keys.first {
            fake.jobStates[local] = .init(state: .uploading(progress: 0.5), videoID: "abc1234567", warning: nil)
            await sleep(0.35)
            let mid = status(jobID).payload
            expect(mid?["state"] as? String == "uploading" && (mid?["progress"] as? NSNumber)?.doubleValue == 0.5,
                   "share_status: uploading 0.5", String(describing: mid))
            fake.jobStates[local] = .init(state: .done(shareURL: "https://capturecat.so/share/abc1234567"),
                                          videoID: "abc1234567", warning: nil)
            await sleep(0.35)
            let done = status(jobID).payload
            expect(done?["state"] as? String == "done"
                   && done?["shareUrl"] as? String == "https://capturecat.so/share/abc1234567"
                   && done?["videoId"] as? String == "abc1234567" && done?["privacy"] as? String == "public",
                   "share_status: done with url, video id and privacy", String(describing: done))
            expect(done.map(conforms) == true, "share_status payload conforms to its outputSchema")
            expect(broker.probeTrackedCount == 0, "a finished job stops being tracked")
        }

        // 8. A share already in flight → refused, no card.
        let cardsBefore = fake.consents.count
        fake.sharing = true
        outcome = await attempt(["project_id": projectID])
        expect(outcome.error?.contains("already in progress") == true && fake.consents.count == cardsBefore,
               "already sharing → refusal, no card", outcome.error ?? "")
        fake.sharing = false

        // 9. No answer within the wait → awaiting_approval; the late answer lands.
        fake.answer = nil
        outcome = await attempt(["project_id": projectID, "privacy": "private"], wait: 1.0)
        let pendingJob = outcome.payload?["jobId"] as? String ?? ""
        expect(outcome.payload?["state"] as? String == "awaiting_approval"
               && (outcome.payload?["note"] as? String)?.contains("share_status") == true,
               "unanswered → awaiting_approval with a poll hint", String(describing: outcome))
        expect(status(pendingJob).payload?["state"] as? String == "awaiting_approval",
               "share_status: awaiting_approval while the card is up")
        fake.pendingAnswer?(true)
        fake.pendingAnswer = nil
        await sleep(0.35)
        let late = status(pendingJob).payload
        expect(late?["state"] as? String == "exporting" && late?["privacy"] as? String == "private"
               && fake.starts.last?.1 == .private, "the late Allow starts a private share", String(describing: late))
        fake.answer = false

        // 10. Unclaimed (GUI stopped polling) → withdrawn, never pops later.
        polling = false
        MCPServer.shareClaimTimeout = 0.6
        let cardsBeforeClaim = fake.consents.count
        outcome = await attempt(["project_id": projectID], wait: 4)
        expect(outcome.error?.contains("didn't pick up") == true && requestFiles().isEmpty,
               "unclaimed request → refusal and withdrawn", outcome.error ?? "<no error>")
        polling = true
        await sleep(0.4)
        expect(fake.consents.count == cardsBeforeClaim, "a withdrawn request never shows a card")
        MCPServer.shareClaimTimeout = 10

        // 11. A stale request (its waiter gave up) is dropped unseen.
        let staleID = UUID().uuidString
        let stale = AgentShareIPC.Request(
            protocolVersion: AgentShareIPC.protocolVersion, jobId: staleID, projectId: projectID,
            privacy: "unlisted", clientName: nil, clientVersion: nil,
            requestedAt: Date().addingTimeInterval(-60), claimBy: Date().addingTimeInterval(-30),
            requesterPID: me)
        try? AgentShareIPC.write(stale, to: AgentShareIPC.requestURL(staleID))
        await sleep(0.4)
        expect(requestFiles().isEmpty && fake.consents.count == cardsBeforeClaim
               && !fm.fileExists(atPath: AgentShareIPC.statusURL(staleID).path),
               "stale request dropped: no card, no status")

        // 12. Requests left from before a launch are purged at start().
        polling = false
        let leftoverID = UUID().uuidString
        var leftover = stale
        leftover.jobId = leftoverID
        leftover.claimBy = Date().addingTimeInterval(60)
        try? AgentShareIPC.write(leftover, to: AgentShareIPC.requestURL(leftoverID))
        broker.start()
        expect(requestFiles().isEmpty, "broker start purges pre-launch requests")
        polling = true

        // 13. A job whose broker died reads as interrupted.
        let deadID = UUID().uuidString
        try? AgentShareIPC.write(AgentShareIPC.Status(
            jobId: deadID, state: .uploading, progress: 0.4, projectId: projectID, projectName: "Harness Demo",
            privacy: "unlisted", shareUrl: nil, videoId: nil, error: nil, warning: nil,
            replacesExistingLink: false, updatedAt: Date(), brokerPID: 999_999), to: AgentShareIPC.statusURL(deadID))
        expect(status(deadID).payload?["state"] as? String == "interrupted", "dead broker → interrupted")

        // 14. share_status input checks.
        expect(status("../../etc/passwd").error?.contains("job_id") == true, "share_status rejects non-UUID ids")
        expect(status(UUID().uuidString).error?.contains("unknown job_id") == true, "share_status: unknown job")
    }

    // MARK: - The consent card

    private static func button(in root: NSView, titled title: String) -> CCButton? {
        if let match = root as? CCButton, match.title == title { return match }
        for sub in root.subviews {
            if let found = button(in: sub, titled: title) { return found }
        }
        return nil
    }

    private static func details(in root: NSView) -> AgentShareConsentDetailsView? {
        if let match = root as? AgentShareConsentDetailsView { return match }
        for sub in root.subviews {
            if let found = details(in: sub) { return found }
        }
        return nil
    }

    private static func postKey(_ keyCode: UInt16, _ characters: String, to window: NSWindow?) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window?.windowNumber ?? 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode) else { return }
        NSApp.postEvent(event, atStart: false)
    }

    private static func consentCardChecks() async {
        let request = AgentShareBroker.ConsentRequest(
            jobID: UUID().uuidString, projectName: "Checkout flow demo", visibility: .unlisted,
            clientName: "Claude Code", accountEmail: "owner@example.com",
            existingShareURL: "https://capturecat.so/share/abc1234567")
        var answers: [Bool] = []
        let alert = AgentShareConsent.present(request) { answers.append($0) }

        await sleep(0.06)
        guard let card = alert.probeCard, let panel = card.window, let layer = card.layer else {
            expect(false, "consent card presented")
            return
        }
        let scale = (layer.presentation() ?? layer).value(forKeyPath: "transform.scale.x") as? CGFloat ?? -1
        expect(scale > 0.961 && scale < 0.999, "card entrance mid-flight @60ms", "scale=\(scale)")
        let detailsView = details(in: card)
        let rowLayers = detailsView?.probeRowViews.compactMap(\.layer) ?? []
        let rowsMoving = rowLayers.contains { row in
            let p = row.presentation() ?? row
            let ty = p.value(forKeyPath: "transform.translation.y") as? CGFloat ?? 0
            return abs(ty) > 0.2 || p.opacity < 0.98
        }
        expect(rowsMoving, "detail rows stagger in mid-flight @60ms")
        let allow = button(in: card, titled: AgentShareConsent.allowTitle)
        let decline = button(in: card, titled: AgentShareConsent.declineTitle)
        expect(allow?.isEnabled == false && decline?.isEnabled == true,
               "Allow starts disarmed; Don't Allow is live at once")

        await sleep(0.8)
        expect(allow?.isEnabled == true, "Allow arms after \(AgentShareConsent.armDelay)s")
        card.layoutSubtreeIfNeeded()
        let size = card.bounds.size
        expect(size.width >= 340 && size.width <= 440 && size.height >= 200, "card topology", "\(size)")
        let rows = detailsView?.probeRowViews ?? []
        let expectedRows = AgentShareConsent.rows(for: request)
        expect(rows.count == 5 && detailsView?.probeRows == expectedRows, "five detail rows (incl. link + account)",
               "\(rows.count)")
        let badRows = rows.filter { row in
            let frame = row.convert(row.bounds, to: card)
            return frame.height < 14 || frame.width < 200 || !card.bounds.contains(frame)
        }
        expect(badRows.isEmpty, "every detail row resolves inside the card", "\(badRows.count) bad")
        if let well = detailsView, let first = rows.first, let last = rows.last {
            let top = well.bounds.maxY - first.convert(first.bounds, to: well).maxY
            let bottom = last.convert(last.bounds, to: well).minY - well.bounds.minY
            expect(abs(top - bottom) < 2, "well padding is even (no phantom wrapped lines)",
                   "top=\(top) bottom=\(bottom)")
        }
        let titleFields = card.subviews.flatMap { $0.subviews }.compactMap { $0 as? NSTextField }
            .filter { $0.stringValue == AgentShareConsent.title }
        var titleDetail = "no title field"
        let titleFits = !titleFields.isEmpty && titleFields.allSatisfy { field in
            let frame = field.convert(field.bounds, to: card)
            // One unwrapped line of the title must fit the frame it was given.
            let natural = field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: 10_000, height: 100)).width ?? .infinity
            titleDetail = "frame=\(frame) natural=\(natural) card=\(card.bounds.width)"
            return card.bounds.insetBy(dx: 8, dy: 0).contains(frame) && natural <= frame.width + 1
        }
        expect(titleFits, "title fits on one line inside the card's insets", titleDetail)
        let texts = detailsView?.probeValueTexts ?? []
        expect(texts.first == "Checkout flow demo"
               && texts.contains { $0.contains("AI agent via MCP") && $0.contains("Claude Code") }
               && texts.contains(ShareVisibility.unlisted.summary)
               && texts.contains { $0.contains("abc1234567") },
               "rows name the project, the agent, the visibility and the link", texts.joined(separator: " | "))
        let wellDressed = detailsView?.layer?.sublayers?.contains { $0.name == "ccmat.base" } == true
        expect(wellDressed, "details well is dressed by CCMaterial")
        if let allow, let decline {
            let a = allow.convert(allow.bounds, to: card), d = decline.convert(decline.bounds, to: card)
            expect(a.minX > d.maxX, "Allow sits trailing (default slot), Don't Allow before it")
        }
        if let screen = panel.screen ?? NSScreen.main {
            expect(abs(panel.frame.midX - screen.visibleFrame.midX) < 2 && screen.visibleFrame.contains(panel.frame),
                   "standalone card is centred on screen", "\(panel.frame) in \(screen.visibleFrame)")
        }
        expect(panel.level.rawValue >= NSWindow.Level.modalPanel.rawValue,
               "standalone card floats above other apps' windows")
        expect(panel.sharingType == .none,
               "the card stays out of screen captures (recordings, screenshot-driven agents)")
        saveCapture(layer: layer, size: size)

        // Return never approves…
        postKey(36, "\r", to: panel)
        await sleep(0.25)
        expect(answers.isEmpty && alert.probeCard != nil, "Return does NOT answer the consent card")

        // Escape declines.
        postKey(53, "\u{1b}", to: panel)
        await sleep(0.4)
        expect(answers == [false] && alert.probeCard == nil, "Escape → Don't Allow, card dismissed",
               String(describing: answers))

        // Control: the same posted Return DOES close a default card, so the
        // check above can't pass because the event never arrived.
        let control = CCAlert(title: "Control", message: "Return picks the default here.")
        control.addButton("OK", role: .primary)
        control.addButton("Cancel")
        var controlChoice: Int?
        control.beginStandalone { controlChoice = $0 }
        await sleep(0.3)
        postKey(36, "\r", to: control.probeCard?.window)
        await sleep(0.4)
        expect(controlChoice == 0, "control: the posted Return reaches the key monitor",
               String(describing: controlChoice))

        // A click on (armed) Allow approves.
        var second: [Bool] = []
        let again = AgentShareConsent.present(
            .init(jobID: UUID().uuidString, projectName: "Private take", visibility: .private, clientName: nil,
                  accountEmail: nil, existingShareURL: nil)) { second.append($0) }
        await sleep(0.8)
        if let card = again.probeCard, let allow = button(in: card, titled: AgentShareConsent.allowTitle) {
            expect(details(in: card)?.probeRows.count == 3, "minimal card: project, agent, visibility")
            allow.onClick?()
        }
        await sleep(0.4)
        expect(second == [true] && again.probeCard == nil, "clicking Allow approves", String(describing: second))
    }

    private static func saveCapture(layer: CALayer, size: CGSize) {
        // CARendererSnapshot renders at 1× whatever the scale says.
        guard let raw = CARendererSnapshot.render(layer: layer, size: size, scale: 1) else {
            expect(false, "capture rendered")
            return
        }
        // CARenderer frames come back Y-mirrored — flip upright for review.
        let w = raw.width, h = raw.height
        var image = raw
        if let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(raw, in: CGRect(x: 0, y: 0, width: w, height: h))
            image = ctx.makeImage() ?? raw
        }
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("capturecat-share-consent.png")
        let rep = NSBitmapImageRep(cgImage: image)
        if (try? rep.representation(using: .png, properties: [:])?.write(to: out)) != nil {
            print("SHARE capture \(out.path)")
        }
    }
}
