import AppKit

/// `CaptureCat --history-transcript <outDir> [--merge-fixtures <dir>]` — the
/// Mac's project-history VALUES as a transcript, for the iOS studio's
/// `--history` gate (Studio 4f, apps/ios/scripts/ios-history.sh). Everything
/// comes from the real Mac code:
///
/// - **rows**: `--history-panel-shot`'s fixture (the real CloudProjectSync
///   pushing / pulling against StubCloudServer: six versions over three
///   days, a named agent edit, an unsynced Mac edit), listed through the
///   real CloudHistoryClient (the wire's JSON parsed by CloudHistoryParse)
///   and rendered by the real HistoryRowView — author, time, badges, summary;
/// - **compare**: the real VersionCompareDialog for every version against
///   the current project, plus every consecutive pair;
/// - **restore**: the real CloudHistoryClient.restore of the named version
///   (push the unsynced edit, POST restore, pull) — the rows after it, and
///   the restored project.json and decoded model;
/// - **merge**: every apps/web merge fixture through the real
///   MergeReviewDialog — each conflict's title, caption and starting side,
///   the auto-resolved lines, the default merge and the merge with every
///   control flipped.
///
/// Day and time words use a PINNED clock (today = this run's now, this
/// Mac's time zone, en_US), recorded in `replay.json` with the saves the
/// stub turned into versions and the fixture's media, so iOS replays the
/// same history and formats with the same clock. Writes
/// `<outDir>/mac-transcript.txt` and `<outDir>/replay/`. No network, no
/// user data, no ScreenCaptureKit.
@MainActor
enum HistoryTranscriptHarness {
    static func run() -> Never {
        setbuf(stdout, nil)
        CCTheme.setMode(.dark, persist: false)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--history-transcript"), args.indices.contains(i + 1) else {
            print("usage: --history-transcript <outDir> [--merge-fixtures <dir>]")
            exit(64)
        }
        let out = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath, isDirectory: true)
        let fixtures = args.firstIndex(of: "--merge-fixtures").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
        Task { @MainActor in
            let ok = await execute(out: out, mergeFixtures: fixtures)
            exit(ok ? 0 : 1)
        }
        app.run()
        exit(1)
    }

    private static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    private static func execute(out: URL, mergeFixtures: URL?) async -> Bool {
        let fm = FileManager.default
        try? fm.removeItem(at: out)
        let replayDir = out.appendingPathComponent("replay", isDirectory: true)
        try? fm.createDirectory(at: replayDir, withIntermediateDirectories: true)
        var lines = [HistoryTranscript.header]

        let fixture: HistoryPanelHarness.Fixture
        do {
            fixture = try await HistoryPanelHarness.makeFixture()
        } catch {
            print("HISTORY-TRANSCRIPT FAIL (fixture: \(error))")
            return false
        }
        defer { try? fm.removeItem(at: fixture.root) }
        let server = fixture.server
        let client = CloudHistoryClient(transport: server, sync: fixture.sync)
        let projectID = fixture.project.id
        let now = Date()
        let timeZone = TimeZone.current
        let clock = HistoryClock.pinned(now: now, timeZone: timeZone)
        lines.append("clock tz=\(timeZone.identifier)")

        // ── Rows: the real client + the real row view ────────────────────
        guard let page = try? await client.page(projectID: projectID) else {
            print("HISTORY-TRANSCRIPT FAIL (no versions)")
            return false
        }
        lines += rowLines("before", page: page, clock: clock)

        // ── The replay (saves → versions) + media, written before restore ─
        let current = (try? Data(contentsOf: fixture.json)) ?? Data()
        var saves: [HistoryTranscript.Save] = []
        for v in server.versions {
            let checkpoint: String
            switch v.kind {
            case "upload": checkpoint = "upload"
            case "merge": checkpoint = "merge"
            case "restore": checkpoint = "restore"
            default: checkpoint = "push"
            }
            saves.append(HistoryTranscript.Save(
                document: String(decoding: v.document, as: UTF8.self), actorUID: v.actorUID, clientKind: v.clientKind,
                clientID: v.clientID, source: v.source, checkpoint: checkpoint,
                // Mac pushes carry X-CC-Change; web saves leave it to the server.
                change: v.clientKind == "mac" ? v.change.map { $0.json.canonical } : nil,
                at: ms(v.openedAt), restoredFrom: v.restoredFrom, mergedFrom: v.mergedFrom, label: v.label))
        }
        var media: [String] = []
        for name in ["recording.mov", "cursor.json"] {
            let source = fixture.dir.appendingPathComponent(name)
            if (try? fm.copyItem(at: source, to: replayDir.appendingPathComponent(name))) != nil { media.append(name) }
        }

        // ── Compare: every version vs current, every consecutive pair ────
        let headID = HistoryWords.headID(of: page)
        for version in page.versions where version.id != headID {
            guard let detail = try? await client.detail(projectID: projectID, versionID: version.id) else { continue }
            let dialog = VersionCompareDialog(version: version, versionDocument: detail.document,
                                              currentDocument: current, projectName: fixture.project.name)
            lines += HistoryTranscript.compareLines("current \(version.id)", summary: VersionCompareGroups.summary(dialog.groups),
                                                    groups: dialog.groups.map { ($0.title, $0.lines) })
        }
        let oldestFirst = server.versions
        for (a, b) in zip(oldestFirst, oldestFirst.dropFirst()) {
            let from = (try? JSONValue.parse(data: a.document)) ?? .object(JSONObject())
            let to = (try? JSONValue.parse(data: b.document)) ?? .object(JSONObject())
            let groups = VersionCompareDialog.groups(from: from, to: to)
            lines += HistoryTranscript.compareLines("pair \(a.id) \(b.id)", summary: VersionCompareGroups.summary(groups),
                                                    groups: groups.map { ($0.title, $0.lines) })
        }

        // ── Restore the named version through the real client ────────────
        guard let named = page.versions.first(where: { $0.isNamed }) else {
            print("HISTORY-TRANSCRIPT FAIL (the fixture has no named version)")
            return false
        }
        lines.append("preview \(named.id) title=\(HistoryTranscript.q(HistoryWords.previewTitle(for: named, clock: clock)))"
                     + " message=\(HistoryTranscript.q(HistoryWords.previewMessage))")
        let before = server.versions.count
        let today = clock.calendar.startOfDay(for: now)
        server.clock = today.addingTimeInterval(40 * 60)
        do {
            let project = try HistoryPanelHarness.load(fixture.json)
            let outcome = try await client.restore(versionID: named.id, project: project, projectDirectory: fixture.dir)
            guard case .restored = outcome else {
                print("HISTORY-TRANSCRIPT FAIL (restore: \(outcome))")
                return false
            }
        } catch {
            print("HISTORY-TRANSCRIPT FAIL (restore: \(error))")
            return false
        }
        let restoreAt = server.versions.dropFirst(before).map { ms($0.openedAt) }
        lines.append("restore \(named.id) versions \(before) → \(server.versions.count)")
        if let after = try? await client.page(projectID: projectID) {
            lines += rowLines("after", page: after, clock: clock)
        }
        let restored = (try? Data(contentsOf: fixture.json)) ?? Data()
        let model = (try? HistoryPanelHarness.load(fixture.json)).map(HistoryTranscript.encodedModel) ?? Data()
        lines += HistoryTranscript.restoreLines(named.id, document: restored, model: model)

        let replay = HistoryTranscript.Replay(
            now: ms(now), timeZone: timeZone.identifier, projectName: fixture.project.name,
            displayNames: server.displayNames, deviceActorUID: server.ownerUID, deviceClientID: fixture.sync.clientID,
            saves: saves, currentDocument: String(decoding: current, as: UTF8.self),
            restoreVersionID: named.id, restoreAt: Array(restoreAt), media: media)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(replay).write(to: replayDir.appendingPathComponent(HistoryTranscript.replayName))

        // ── Merge Review over the apps/web merge fixtures ────────────────
        let merges = mergeFixturesDirectory(mergeFixtures).map(HistoryTranscript.loadMergeFixtures) ?? []
        if merges.isEmpty {
            print("HISTORY-TRANSCRIPT FAIL (no merge fixtures — pass --merge-fixtures apps/web/src/editor/core/merge/fixtures)")
            return false
        }
        var conflicted = 0
        for fx in merges {
            lines += mergeLines(fx, conflicted: &conflicted)
        }

        let text = lines.joined(separator: "\n") + "\n"
        try? text.write(to: out.appendingPathComponent("mac-transcript.txt"), atomically: true, encoding: .utf8)
        let rows = lines.filter { $0.contains(" row ver-") }.count
        print("HISTORY-TRANSCRIPT \(lines.count) lines: \(rows) rows, \(lines.filter { $0.hasPrefix("compare ") && $0.contains(" summary=") }.count) compares, "
              + "\(merges.count) merges (\(conflicted) with conflicts) → \(out.path)")
        return true
    }

    private static func mergeFixturesDirectory(_ explicit: URL?) -> URL? {
        if let explicit { return explicit }
        return MergeVectors.fixturesDirectory()
    }

    /// Rows exactly as the real pane builds them: day sections from the
    /// shared grouping, each row a real HistoryRowView.
    private static func rowLines(_ tag: String, page: CloudVersionPage, clock: HistoryClock) -> [String] {
        var lines: [String] = []
        let headID = HistoryWords.headID(of: page)
        for (day, versions) in HistoryWords.days(page.versions, clock: clock) {
            lines.append("\(tag) " + HistoryTranscript.sectionLine(HistoryWords.dayTitle(day, clock: clock), rows: versions.count))
            for version in versions {
                let time = HistoryWords.timeText(version.date, clock: clock)
                let view = HistoryRowView(version: version, isHead: version.id == headID, timeText: time)
                let model = HistoryRowModel(version: version, isHead: view.isHead, timeText: time)
                let badges = zip(view.badges, model.badges).map { ($0.0.text, $0.1.style.rawValue) }
                let row = HistoryTranscript.Row(
                    versionID: version.id, seq: version.seq, kind: version.kind, label: version.label, isHead: view.isHead,
                    day: HistoryWords.dayTitle(day, clock: clock), time: time, author: view.probeAvatar.name,
                    summary: view.probeSummary, badges: badges, documentSHA256: version.documentSHA256 ?? "",
                    change: version.change.map { $0.json.canonical })
                lines.append("\(tag) " + HistoryTranscript.line(row))
            }
        }
        return lines
    }

    /// One fixture through the real MergeReviewDialog (never presented —
    /// its controls are read and flipped in place).
    private static func mergeLines(_ fx: HistoryTranscript.MergeFixture, conflicted: inout Int) -> [String] {
        let result = ProjectMerge.merge(base: fx.base, mine: fx.mine, theirs: fx.theirs, mineWins: fx.mineWins)
        let review = CloudMergeReview(
            origin: .pull, projectID: UUID(), base: fx.base, mine: fx.mine, mineDocument: Data(fx.mine.canonical.utf8),
            theirs: fx.theirs, theirsDocument: Data(fx.theirs.canonical.utf8), theirsRevision: 2, theirsUpdatedAt: nil,
            mineWins: fx.mineWins, source: .human, choices: [:], conflicts: result.conflicts,
            autoResolved: result.autoResolved, author: nil)
        var decisions: [HistoryTranscript.Decision] = []
        var flippedHash = HistoryTranscript.hash(result.merged)
        if !result.conflicts.isEmpty {
            conflicted += 1
            let dialog = MergeReviewDialog(review: review, projectName: fx.name)
            let who = MergeReviewDialog.theirsName(review)
            for (index, conflict) in result.conflicts.enumerated() {
                decisions.append(HistoryTranscript.Decision(
                    id: conflict.id, kind: conflict.kind, title: dialog.probeTitles[index],
                    detail: MergeReviewDialog.detail(for: conflict, theirs: who),
                    selectedIndex: dialog.probeSegments[index].selectedIndex))
            }
            for control in dialog.probeSegments { control.selectedIndex = control.selectedIndex == 0 ? 1 : 0 }
            let flipped = ProjectMerge.merge(base: fx.base, mine: fx.mine, theirs: fx.theirs, mineWins: fx.mineWins,
                                             choices: dialog.choices)
            flippedHash = HistoryTranscript.hash(flipped.merged)
        }
        return HistoryTranscript.mergeLines(
            fixture: fx.name, mineWins: fx.mineWins, decisions: decisions,
            autoResolved: result.autoResolved.map(MergeReviewDialog.describe),
            defaultHash: HistoryTranscript.hash(result.merged), flippedHash: flippedHash)
    }
}
