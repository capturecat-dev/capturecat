import AppKit

/// `CaptureCat --history-panel-shot [--inject-defect]` — acceptance gate for
/// the editor's History pane (docs/project-history.md Phase 3C).
///
/// Topology: the REAL `EditorShellViewController`, hosted through the SAME
/// `EditorWindowContentViewController.pinEditor` the editor window uses, in a
/// window dressed by the SAME `EditorWindowController.configureChrome` — the
/// History key is clicked through its real mouseDown/mouseUp path and the
/// pane appears inside the real inspector split item (CLAUDE.md §3).
///
/// Motion: the column ⇄ History swap is sampled MID-FLIGHT (pane offset
/// strictly between its start and 0, opacity strictly between 0 and 1), the
/// glide wash is sampled mid-hop between two rows — all BEFORE any CARenderer
/// capture (captures orphan presentation layers).
///
/// Structure: the row count and the day-section count must equal the stub
/// server's versions (rows don't overlap, each sits inside the pane). The
/// gate proves itself by injecting each defect in-process (a dropped row,
/// a snapped transition) and requiring the same assertions to FAIL;
/// `--inject-defect` runs the whole gate with both defects on (it must exit 1).
///
/// Data comes from `StubCloudServer` (versions across three days, a named
/// one, an agent edit, removed media pinned by old versions) — no network,
/// no user data; the fixture lives in a temp folder.
@MainActor
enum HistoryPanelHarness {
    static func run() -> Never {
        setbuf(stdout, nil)
        CCTheme.setMode(.dark, persist: false)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            CCTheme.setMode(.dark, persist: false)
            let ok = await execute()
            exit(ok ? 0 : 1)
        }
        app.run()
        exit(1)
    }

    private final class Checks {
        var passed = 0
        var failures: [String] = []
        func expect(_ condition: Bool, _ label: String) {
            if condition {
                passed += 1
                print("  ✓ \(label)")
            } else {
                failures.append(label)
                print("  ✘ \(label)")
            }
        }
    }

    /// Records what the pane asked the app to do.
    private final class Log {
        var syncNow = 0
        var previews: [String] = []
        var backToCurrent = 0
    }

    private static let windowSize = NSSize(width: 1400, height: 820)

    // MARK: - Fixture

    private struct Fixture {
        let root: URL
        let dir: URL
        let project: Project
        let server: StubCloudServer
        let sync: CloudProjectSync
        var json: URL { dir.appendingPathComponent("project.json") }
    }

    private static func write(_ project: Project, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        try encoder.encode(project).write(to: url, options: .atomic)
    }

    private static func load(_ url: URL) throws -> Project {
        try JSONDecoder().decode(Project.self, from: Data(contentsOf: url))
    }

    /// A project with six cloud versions across three days: Mac upload, Ana
    /// on the web, a Mac edit, an agent edit on the web (named), Ana again,
    /// a Mac push that replaced a media file (so old versions pin removed
    /// media) — then an unsynced Mac edit for the "not synced" pseudo-row.
    private static func makeFixture() async throws -> Fixture {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("capturecat-history-panel-\(UUID().uuidString)", isDirectory: true)
        let id = UUID()
        let dir = root.appendingPathComponent("Projects/\(id.uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let video = dir.appendingPathComponent("recording.mov")
        guard await PlaybackObserverHarness.writeVideo(to: video, seconds: 4, size: CGSize(width: 1280, height: 800), tint: 0.35) else {
            throw CloudSyncError.missingProjectFile
        }
        let cursor = dir.appendingPathComponent("cursor.json")
        try Data(#"{"events":[{"t":0.1,"x":0.5,"y":0.5}]}"#.utf8).write(to: cursor)
        let project = Project(id: id, name: "History Probe", videoURL: video, cursorDataURL: cursor, duration: 4)
        project.trimStart = 0
        project.trimEnd = 4
        project.settings.muteRecordedAudio = true
        project.zoomRegions = [ZoomRegion(startTime: 0.5, endTime: 1.5)]
        let json = dir.appendingPathComponent("project.json")
        try write(project, to: json)

        let server = StubCloudServer(ownerUID: "stub-owner")
        server.pinsVersionMedia = true
        let sync = CloudProjectSync(transport: server, apiBaseURL: "https://api.stub.test", clientID: "history-probe")
        let today = Calendar.current.startOfDay(for: Date())
        func at(_ dayOffset: Int, _ hour: Int, _ minute: Int) -> Date {
            today.addingTimeInterval(TimeInterval(dayOffset * 86_400 + hour * 3600 + minute * 60))
        }
        func edit(_ mutate: (Project) -> Void) throws {
            let p = try load(json)
            mutate(p)
            try write(p, to: json)
        }
        func web(_ when: Date, source: String = "human", _ mutate: @escaping (inout [String: Any], inout [String: Any]) -> Void) throws {
            server.clock = when
            server.webSave(try CloudSyncHarness.webEditedJSON(server.document!, mutate), source: source)
        }

        server.clock = at(-2, 10, 0)
        _ = try await sync.push(project: try load(json), projectDirectory: dir)                        // v1 upload (Mac)
        try web(at(-2, 15, 30)) { _, settings in settings["backgroundPadding"] = 32.0 }                // v2 Ana (Web)
        _ = try await sync.pull(projectID: id, projectDirectory: dir)
        try edit { $0.zoomRegions.append(ZoomRegion(startTime: 2, endTime: 3)) }
        // Media replaced: the first cursor file is now pinned only by the
        // two UNNAMED versions before it (freeable); the second one below
        // is also pinned by the named v4 (kept).
        try Data(#"{"events":[{"t":0.2,"x":0.4,"y":0.6}]}"#.utf8).write(to: cursor)
        server.clock = at(-1, 9, 12)
        _ = try await sync.push(project: try load(json), projectDirectory: dir)                        // v3 Mac edit
        try web(at(-1, 18, 40), source: "agent") { doc, _ in doc["name"] = "History Probe (agent)" }   // v4 Agent via Web
        server.name(server.versions.last!.id, "Sent to client")
        _ = try await sync.pull(projectID: id, projectDirectory: dir)
        try web(at(0, 0, 5)) { _, settings in settings["cornerRadius"] = 18.0 }                        // v5 Ana (Web)
        _ = try await sync.pull(projectID: id, projectDirectory: dir)
        try Data(#"{"events":[{"t":0.4,"x":0.2,"y":0.8}]}"#.utf8).write(to: cursor)                   // media replaced
        try edit { $0.settings.shadowOpacity = 0.3 }
        server.clock = at(0, 0, 20)
        _ = try await sync.push(project: try load(json), projectDirectory: dir)                        // v6 Mac push
        try edit { $0.name = "History Probe — edited on this Mac" }                                    // unsynced
        return Fixture(root: root, dir: dir, project: try load(json), server: server, sync: sync)
    }

    // MARK: - Hosting (the editor window's own chain)

    private final class Container: NSViewController {
        let shell: EditorShellViewController
        init(shell: EditorShellViewController) {
            self.shell = shell
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func loadView() {
            let root = NSView()
            root.wantsLayer = true
            view = root
            addChild(shell)
            EditorWindowContentViewController.pinEditor(shell, in: root)
        }
    }

    private static func host(_ shell: EditorShellViewController, x: CGFloat) -> NSWindow {
        let window = NSWindow(contentViewController: Container(shell: shell))
        EditorWindowController.configureChrome(window)
        window.title = shell.title ?? "History Probe"
        window.appearance = NSAppearance(named: .darkAqua)
        window.setContentSize(windowSize)
        window.setFrameOrigin(NSPoint(x: -20_000 + x, y: 200))
        window.orderFrontRegardless()
        window.contentView?.superview?.wantsLayer = true
        shell.installToolbar(on: window)
        return window
    }

    private static func environment(_ fixture: Fixture, log: Log) -> EditorHistoryEnvironment {
        let env = EditorHistoryEnvironment(
            client: CloudHistoryClient(transport: fixture.server, sync: fixture.sync),
            directory: { _ in fixture.dir },
            isSignedIn: { true })
        env.syncNow = { _, _ in log.syncNow += 1 }
        env.preview = { preview, version, _ in log.previews.append(version.id); _ = preview }
        return env
    }

    // MARK: - Probes

    private static func settle(_ seconds: Double) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func wait(_ timeout: Double, until condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > end { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    struct TransitionSample {
        let offset: CGFloat
        let alpha: Float
        let outgoingAlpha: Float
    }

    private static func sample(incoming: NSView, outgoing: NSView) -> TransitionSample {
        let inLayer = incoming.layer.map { $0.presentation() ?? $0 }
        let outLayer = outgoing.layer.map { $0.presentation() ?? $0 }
        return TransitionSample(
            offset: (inLayer?.value(forKeyPath: "transform.translation.x") as? CGFloat) ?? 0,
            alpha: inLayer?.opacity ?? 1,
            outgoingAlpha: outLayer?.opacity ?? 1)
    }

    /// The mid-flight law: offset strictly between the start and 0, the
    /// incoming side neither invisible nor fully faded in.
    private static func isMidFlight(_ s: TransitionSample, start: CGFloat) -> Bool {
        let lo = min(start, 0), hi = max(start, 0)
        return s.offset > lo + 0.5 && s.offset < hi - 0.5 && s.alpha > 0.02 && s.alpha < 0.98
    }

    /// The structural assertions — row count and day sections equal the
    /// server's versions, rows stacked without overlap inside the pane.
    /// Returns failures (empty = pass); the self-test requires them to fire.
    private static func structuralFailures(_ pane: HistoryPaneAppKit, server: StubCloudServer) -> [String] {
        var out: [String] = []
        let expectedRows = server.versions.count
        let calendar = Calendar.current
        let expectedDays = Set(server.versions.map { calendar.startOfDay(for: $0.updatedAt) }).count
        if pane.rows.count != expectedRows { out.append("rows \(pane.rows.count) ≠ versions \(expectedRows)") }
        if pane.sections.count != expectedDays { out.append("day sections \(pane.sections.count) ≠ days \(expectedDays)") }
        let host = pane.probeList
        let frames = pane.rows.map { $0.convert($0.bounds, to: host) }
        for (index, frame) in frames.enumerated() {
            if frame.width < 200 || abs(frame.height - HistoryRowView.height) > 0.5 {
                out.append("row \(index) is \(Int(frame.width))×\(Int(frame.height))")
            }
            if pane.rows[index].window == nil { out.append("row \(index) not in a window") }
        }
        // Unflipped host: later rows sit LOWER (smaller y).
        for (a, b) in zip(frames, frames.dropFirst()) where b.maxY > a.minY + 0.5 {
            out.append("rows overlap (\(Int(a.minY)) vs \(Int(b.maxY)))")
        }
        let ids = pane.rows.map(\.version.id)
        let newestFirst = server.versions.reversed().map(\.id)
        if ids != newestFirst, out.isEmpty { out.append("rows are not newest-first") }
        return out
    }

    // MARK: - Run

    private static func execute() async -> Bool {
        print("HISTORY PANEL SHOT")
        let checks = Checks()
        let expect = checks.expect
        let injected = CommandLine.arguments.contains("--inject-defect")
        if injected {
            print("  (defects injected: a dropped row per day + a snapped transition — this run MUST fail)")
            HistoryPaneAppKit.debugDropLastRowPerDay = true
            EditorInspectorViewController.debugSnapHistoryTransition = true
        }
        let fixture: Fixture
        do {
            fixture = try await makeFixture()
        } catch {
            print("  ✘ fixture: \(error)")
            return false
        }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let server = fixture.server
        let log = Log()
        let outDir = FileManager.default.temporaryDirectory.appendingPathComponent("capturecat-history-panel", isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        // ── The real editor shell in the editor window's chain ───────────
        print("topology: the editor shell + History key")
        let shell = EditorShellViewController(appState: nil, project: fixture.project, history: environment(fixture, log: log))
        let window = host(shell, x: 40)
        defer { window.close() }
        await settle(2.0)
        window.setContentSize(windowSize)
        await settle(0.4)

        guard let historyKey = shell.toolbarController.historyButton,
              let inspector = shell.inspectorController else {
            expect(false, "the top bar carries a History key")
            return report(checks)
        }
        let bar = shell.topBarView
        let exportKey = bar.subviews.compactMap { $0 as? CCButton }.first { $0.title == "Export…" }
        let keyFrame = historyKey.frame
        expect(keyFrame.width >= 20 && keyFrame.height >= 20 && bar.bounds.contains(keyFrame),
               "the History key renders inside the in-content top bar (\(Int(keyFrame.width))×\(Int(keyFrame.height)))")
        if let exportKey {
            expect(abs((exportKey.frame.minX - keyFrame.maxX) - CCSpace.sm) < 0.5 && abs(keyFrame.midY - exportKey.frame.midY) < 1,
                   "…\(Int(CCSpace.sm))pt left of its neighbour, on the same centre line")
        }
        expect(historyKey.style == .ghost && historyKey.size == .sm, "the key is a ghost, small CCButton")
        expect(CCTooltip.tooltip(for: historyKey)?.text == "History", "…with a CCTooltip “History”")
        if let content = window.contentView {
            let hit = content.hitTest(historyKey.convert(NSPoint(x: keyFrame.width / 2, y: keyFrame.height / 2), to: content))
            expect(hit.map { $0 === historyKey || $0.isDescendant(of: historyKey) } == true, "nothing covers the key (hit test)")
        }
        let column = inspector.probeColumn
        expect(!column.isHidden && inspector.historyPane == nil, "before: the inspector tabs show, no History pane yet")

        // ── Click → swap, sampled mid-flight (before ANY capture) ────────
        print("motion: column → History swap")
        server.versionsDelay = .milliseconds(900)
        CloudSyncHarness.click(historyKey)
        let started = await wait(1) { inspector.isHistoryVisible }
        expect(started && shell.selection.showHistory, "a real click on the key turns History on")
        guard let pane = inspector.historyPane else {
            expect(false, "the History pane is built inside the inspector")
            return report(checks)
        }
        try? await Task.sleep(for: .milliseconds(45))
        let early = sample(incoming: pane, outgoing: column)
        try? await Task.sleep(for: .milliseconds(55))
        let later = sample(incoming: pane, outgoing: column)
        expect(isMidFlight(early, start: EditorInspectorViewController.historySlide),
               "45 ms in, the pane is mid-flight (offset \(fmt(early.offset)) of \(Int(EditorInspectorViewController.historySlide)), α \(fmt(early.alpha)))")
        expect(later.offset < early.offset - 0.5 && later.alpha > early.alpha,
               "…and still travelling toward rest 55 ms later (offset \(fmt(later.offset)), α \(fmt(later.alpha)))")
        expect(early.outgoingAlpha < 0.98, "the tabs fade out under it (α \(fmt(early.outgoingAlpha)))")

        // ── Loading: CCSkeleton.lines while the versions request is out ──
        print("loading")
        expect(pane.state == .loading && pane.skeleton != nil, "while the list loads, the pane shows CCSkeleton lines")
        if let skeleton = pane.skeleton {
            let frame = skeleton.convert(skeleton.bounds, to: pane)
            let lines = skeleton.subviews.flatMap { $0.subviews }.compactMap { $0 as? CCSkeleton }
            expect(frame.width > 200 && pane.bounds.contains(frame) && lines.count >= 6,
                   "…\(lines.count) skeleton lines laid out inside the pane (\(Int(frame.width))pt wide)")
        }
        let loaded = await wait(4) { if case .loaded = pane.state { return true }; return false }
        expect(loaded, "the versions arrive and replace the skeleton")
        await settle(0.5)

        // ── Topology after the swap ──────────────────────────────────────
        print("topology: the pane in the inspector card")
        let panel = inspector.probePanel
        expect(pane.superview === panel && pane.frame.insetBy(dx: -0.5, dy: -0.5).contains(panel.bounds)
               && panel.bounds.width >= 300,
               "the pane fills the inspector card (\(Int(panel.bounds.width))×\(Int(panel.bounds.height)))")
        expect(column.isHidden && !pane.isHidden && (pane.layer?.opacity ?? 0) > 0.99, "the tabs are hidden once the swap lands")
        expect(pane.window === window && !pane.hasAmbiguousLayout, "pane in the editor window, unambiguous layout")

        // ── Structure: rows + day sections = the server's versions ───────
        print("structure")
        let failures = structuralFailures(pane, server: server)
        expect(failures.isEmpty, "rows (\(pane.rows.count)) and day sections (\(pane.sections.count)) equal the stub's versions "
               + "(\(server.versions.count) in \(Set(server.versions.map { Calendar.current.startOfDay(for: $0.updatedAt) }).count) days)"
               + (failures.isEmpty ? "" : " — \(failures.joined(separator: "; "))"))
        let head = pane.rows.first
        expect(head?.isHead == true && head?.badges.contains { $0.text == "Current" } == true, "the newest row is marked Current")
        expect(pane.rows.contains { row in row.badges.contains { $0.text == "Sent to client" } && row.badges.contains { $0.text == "Agent via Web" } },
               "the named agent edit shows its name and an “Agent via Web” badge")
        expect(pane.rows.contains { $0.version.actorName == "Ana" && $0.badges.contains { $0.text == "Web" } && $0.probeAvatar.name == "Ana" },
               "Ana's web edits carry her CCAvatar and a Web badge")
        expect(pane.rows.allSatisfy { !$0.probeSummary.isEmpty }, "every row has a change summary caption")
        expect(pane.rows.contains { $0.probeSummary.contains("Background changed") }, "summaries come from the change-set (“Background changed”)")

        // ── The "On this Mac — not synced" pseudo-row ────────────────────
        print("local pseudo-row")
        if let local = pane.localRow {
            let frame = local.convert(local.bounds, to: pane.probeList)
            let firstRow = pane.rows.first.map { $0.convert($0.bounds, to: pane.probeList) }
            expect(firstRow.map { frame.minY >= $0.maxY - 0.5 } == true, "“On this Mac — not synced” sits above every version")
            expect(local.probeSummary.contains("Renamed"), "…summarising base → local (“\(local.probeSummary)”)")
            CloudSyncHarness.click(local.probeSyncButton)
            expect(log.syncNow == 1, "its Sync now key (real click) asks the app to sync")
        } else {
            expect(false, "an unsynced Mac edit shows the “On this Mac — not synced” row")
        }

        // ── Footer: pinned media + Free up ───────────────────────────────
        print("footer")
        expect(pane.footerLabel?.stringValue.hasPrefix("History keeps") == true && pane.freeUpButton != nil,
               "“\(pane.footerLabel?.stringValue ?? "—")” with a Free up link")

        // ── Hover: one wash GLIDES between rows (mid-hop sample) ─────────
        print("motion: hover glide")
        if pane.rows.count >= 3 {
            let list = pane.probeList
            let a = pane.rows[1], b = pane.rows[2]
            a.setHovered(true)
            await settle(0.35)
            let aFrame = a.convert(a.bounds, to: list)
            let bFrame = b.convert(b.bounds, to: list)
            let landedA = pane.probeGlide.debugPresentationFrame
            a.setHovered(false)
            b.setHovered(true)
            try? await Task.sleep(for: .milliseconds(40))
            let mid = pane.probeGlide.debugPresentationFrame
            await settle(0.45)
            let landedB = pane.probeGlide.debugPresentationFrame
            expect(abs(landedA.midY - aFrame.midY) < 1.5, "the wash lands on the hovered row")
            expect(mid.midY < aFrame.midY - 0.5 && mid.midY > bFrame.midY + 0.5,
                   "40 ms into the hop it is between the rows (\(fmt(mid.midY)) ∈ (\(fmt(bFrame.midY)), \(fmt(aFrame.midY))))")
            expect(abs(landedB.midY - bFrame.midY) < 1.5, "…and lands on the next row")
            b.setHovered(false)
        }

        // ── Compare: real dialog over the window ─────────────────────────
        print("compare")
        if let oldest = server.versions.first {
            let current = (try? Data(contentsOf: fixture.json)) ?? Data()
            let dialog = VersionCompareDialog(
                version: pane.rows.last?.version ?? pane.rows[0].version,
                versionDocument: oldest.document, currentDocument: current, projectName: fixture.project.name)
            let titles = dialog.groups.map(\.title)
            let timeline = dialog.groups.first { $0.title == "Timeline" }?.lines ?? []
            expect(titles.contains("Background") && titles.contains("Other") && timeline.contains { $0.hasPrefix("Zoom added · 0:02–0:03") },
                   "groups by where you'd edit it (\(titles.joined(separator: ", "))), lines name spans (\(timeline.first ?? "—"))")
            dialog.present(over: window)
            await settle(0.6)
            let card = dialog.probeCard
            expect(card.window?.isVisible == true && dialog.probeAccordion.itemCount == dialog.groups.count
                   && dialog.probeAccordion.isExpanded(at: 0),
                   "the compare CCDialog shows one accordion item per group, the first open")
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in dialog.dismiss { c.resume() } }
        }

        // ── Preview banner on the stage ──────────────────────────────────
        print("preview")
        if let named = pane.rows.first(where: { $0.version.isNamed })?.version {
            let preview = try? await CloudHistoryClient(transport: server, sync: fixture.sync)
                .previewProject(projectID: fixture.project.id, versionID: named.id, projectDirectory: fixture.dir)
            expect(preview?.isPreview == true && preview.map(ProjectStore.persists) == false,
                   "Preview decodes the version as an isPreview project ProjectStore never saves")
            let callout = VersionPreviewController.callout(version: named, onRestore: {}, onBack: { log.backToCurrent += 1 })
            shell.showStageCallout(callout)
            await settle(0.5)
            if let stage = shell.probeStageCallout, let stageView = stage.superview {
                let frame = stage.frame
                expect(stage.window === window && stageView.bounds.contains(frame) && frame.width > 300,
                       "the CCCallout sits on the stage (\(Int(frame.width))pt)")
                expect(stage.actions.map(\.title) == ["Restore", "Back to Current"]
                       && VersionPreviewController.title(for: named).hasPrefix("Viewing "),
                       "“\(VersionPreviewController.title(for: named))” with [Restore] [Back to Current]")
                if let back = stage.actions.last { CloudSyncHarness.click(back) }
                expect(log.backToCurrent == 1, "Back to Current (real click) leaves the preview")
                stage.removeFromSuperview()
            } else {
                expect(false, "the preview callout mounts on the stage")
            }
        }

        // ── Gate self-test: each injected defect must trip its assertion ─
        if !injected {
            print("self-test: injected defects are caught")
            HistoryPaneAppKit.debugDropLastRowPerDay = true
            pane.reload()
            _ = await wait(3) { if case .loaded = pane.state { return pane.rows.count < server.versions.count }; return false }
            let caught = structuralFailures(pane, server: server)
            expect(!caught.isEmpty, "a dropped row per day fails the structural assertion (\(caught.first ?? "NOT CAUGHT"))")
            HistoryPaneAppKit.debugDropLastRowPerDay = false
            pane.reload()
            _ = await wait(3) { pane.rows.count == server.versions.count }
        }

        // ── Close: back to the tabs, also animated ───────────────────────
        print("motion: History → column")
        CloudSyncHarness.click(pane.probeCloseButton)
        _ = await wait(1) { !inspector.isHistoryVisible }
        try? await Task.sleep(for: .milliseconds(40))
        let back = sample(incoming: column, outgoing: pane)
        expect(!shell.selection.showHistory && isMidFlight(back, start: -EditorInspectorViewController.historySlide * 0.5),
               "the close key swaps back, mid-flight 40 ms in (offset \(fmt(back.offset)), α \(fmt(back.alpha)))")
        await settle(0.5)
        expect(!column.isHidden && pane.isHidden, "the tabs are back, the pane hidden")

        if !injected {
            EditorInspectorViewController.debugSnapHistoryTransition = true
            shell.selection.showHistory = true
            _ = await wait(1) { inspector.isHistoryVisible }
            try? await Task.sleep(for: .milliseconds(40))
            let snapped = sample(incoming: pane, outgoing: column)
            expect(!isMidFlight(snapped, start: EditorInspectorViewController.historySlide),
                   "a snapped swap fails the mid-flight assertion (offset \(fmt(snapped.offset)), α \(fmt(snapped.alpha)))")
            EditorInspectorViewController.debugSnapHistoryTransition = false
            shell.selection.showHistory = false
            await settle(0.4)
        }

        // ── Never uploaded: CCEmptyState ─────────────────────────────────
        print("empty state")
        let fresh = Project(name: "Never Uploaded", videoURL: fixture.project.videoURL, duration: 4)
        let freshDir = fixture.root.appendingPathComponent("Projects/\(fresh.id.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: freshDir, withIntermediateDirectories: true)
        try? write(fresh, to: freshDir.appendingPathComponent("project.json"))
        let emptyServer = StubCloudServer(ownerUID: "stub-owner")
        let emptyEnv = EditorHistoryEnvironment(
            client: CloudHistoryClient(transport: emptyServer,
                                       sync: CloudProjectSync(transport: emptyServer, apiBaseURL: "https://api.stub.test",
                                                              clientID: "history-probe")),
            directory: { _ in freshDir }, isSignedIn: { true })
        let emptyShell = EditorShellViewController(appState: nil, project: fresh, history: emptyEnv)
        let emptyWindow = host(emptyShell, x: 1600)
        defer { emptyWindow.close() }
        await settle(1.2)
        emptyShell.showHistory()
        let emptyShown = await wait(3) { emptyShell.inspectorController.historyPane?.state == .neverUploaded }
        await settle(0.5)
        if emptyShown, let emptyPane = emptyShell.inspectorController.historyPane, let empty = emptyPane.emptyState {
            let frame = empty.convert(empty.bounds, to: emptyPane)
            expect(emptyPane.bounds.contains(frame) && frame.width > 200 && frame.height > 120 && emptyPane.rows.isEmpty,
                   "a never-uploaded project shows CCEmptyState inside the pane (\(Int(frame.width))×\(Int(frame.height)))")
        } else {
            expect(false, "a never-uploaded project shows CCEmptyState")
        }

        // ── Captures LAST (CARenderer orphans presentation layers) ───────
        shell.selection.showHistory = true
        await settle(0.8)
        capture(window, to: outDir.appendingPathComponent("history-panel.png"))
        capture(emptyWindow, to: outDir.appendingPathComponent("history-empty.png"))
        // The top bar is not layer-hosted (CARenderer sees an empty
        // titlebar): draw it instead, like --editor-shell-shot.
        if let rep = bar.bitmapImageRepForCachingDisplay(in: bar.bounds) {
            bar.effectiveAppearance.performAsCurrentDrawingAppearance { bar.cacheDisplay(in: bar.bounds, to: rep) }
            try? rep.representation(using: .png, properties: [:])?
                .write(to: outDir.appendingPathComponent("history-topbar.png"))
            print("  · shot history-topbar.png")
        }
        if let named = server.versions.last(where: { $0.label != nil }),
           let version = try? await CloudHistoryClient(transport: server, sync: fixture.sync)
            .detail(projectID: fixture.project.id, versionID: named.id).version {
            shell.showStageCallout(VersionPreviewController.callout(version: version, onRestore: {}, onBack: {}))
            await settle(0.6)
            capture(window, to: outDir.appendingPathComponent("history-preview.png"))
        }
        print("  · shots in \(outDir.path)")
        return report(checks)
    }

    private static func report(_ checks: Checks) -> Bool {
        if checks.failures.isEmpty {
            print("HISTORY PANEL PASS (\(checks.passed) checks)")
            return true
        }
        print("HISTORY PANEL FAIL (\(checks.failures.count) of \(checks.passed + checks.failures.count)):")
        for failure in checks.failures { print("  ✘ \(failure)") }
        return false
    }

    private static func fmt(_ value: CGFloat) -> String { String(format: "%.1f", value) }
    private static func fmt(_ value: Float) -> String { String(format: "%.2f", value) }

    /// CARenderer capture of the window content, flipped upright (the
    /// renderer reads the texture Y-up — see the carenderer memory note).
    private static func capture(_ window: NSWindow, to url: URL) {
        guard let content = window.contentView else { return }
        content.wantsLayer = true
        guard let layer = content.layer,
              let raw = CARendererSnapshot.render(layer: layer, size: content.bounds.size, scale: 1),
              let ctx = CGContext(data: nil, width: raw.width, height: raw.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return }
        ctx.translateBy(x: 0, y: CGFloat(raw.height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(raw, in: CGRect(x: 0, y: 0, width: raw.width, height: raw.height))
        guard let image = ctx.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
        print("  · shot \(url.lastPathComponent) \(image.width)×\(image.height)")
    }
}
