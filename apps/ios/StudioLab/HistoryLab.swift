import UIKit

/// `--history <outDir> --replay <dir> --transcript <mac-transcript.txt>
///  --merge-fixtures <dir> [--inject snap-panel|snap-compare|snap-preview|merge-pick]`
/// (Studio 4f) — the iOS History gate, against the Mac.
///
/// **Values.** The Mac's `--history-transcript` (real StubCloudServer +
/// CloudProjectSync + CloudHistoryClient, real HistoryRowView /
/// VersionCompareDialog / MergeReviewDialog) wrote a transcript and the
/// REPLAY: the saves its server turned into versions. Here those saves are
/// recorded into a real on-device `LocalProjectHistory` (reloaded from disk
/// before use), the fixture opens in the shipping `EditorViewController`
/// presented full screen in this window, and everything is read back from
/// the REAL iOS views and written with the SAME formatter
/// (StudioHarness/HistoryTranscript):
///   - rows: the History panel's day sections and row cells (author, time,
///     badges, summary) — before and after restore;
///   - compare: each version vs the project now and every consecutive pair,
///     opened from the rows' action sheets, read from the compare page;
///   - preview: the stage banner's words;
///   - restore: the named version restored through its action sheet and the
///     confirmation's Restore key — the rows after it, project.json and the
///     live model (media references reduced to file names);
///   - merge: every apps/web merge fixture through Merge Review — each
///     conflict's title, caption and starting side read from the rows, every
///     control flipped through its VoiceOver activation, Apply tapped.
/// The transcript must equal the Mac's line for line ("this iPad" ≡ "this Mac").
///
/// **Behaviour.** Restore is ONE undo step (undo puts the project back
/// exactly, redo restores it again); the preview is read-only and never
/// saved; "Changed outside this editor" merges a file edited under the
/// editor and keeps both inputs as versions.
///
/// **Motion** (CLAUDE.md §3), each a SEQUENCE of presentation-layer samples
/// with a mid-flight assertion: the panel / sheet entrance, the preview's
/// dissolve + banner drop, the compare page sliding over the list.
///
/// **Gate power.** In-process self-test: each defect injected must trip its
/// check (a snapped panel, compare and preview; a wrong merge pick).
/// `--inject <defect>` runs the whole gate with it on — it must FAIL.
@available(iOS 26, *)
@MainActor
enum HistoryLab {
    static func start(_ arguments: [String], lab: LabViewController) -> Bool {
        guard let i = arguments.firstIndex(of: "--history"), arguments.indices.contains(i + 1) else { return false }
        func value(_ name: String) -> String? {
            arguments.firstIndex(of: name).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        let out = URL(fileURLWithPath: arguments[i + 1], isDirectory: true)
        guard let replay = value("--replay"), let transcript = value("--transcript"), let fixtures = value("--merge-fixtures") else {
            print("HISTORY-GATE FAIL (usage: --history <out> --replay <dir> --transcript <file> --merge-fixtures <dir>)")
            exit(64)
        }
        lab.stage.isHidden = true
        let rig = HistoryRig(host: lab, out: out, replayDir: URL(fileURLWithPath: replay, isDirectory: true),
                             macTranscript: URL(fileURLWithPath: transcript),
                             mergeFixtures: URL(fileURLWithPath: fixtures, isDirectory: true), inject: value("--inject"))
        Task { @MainActor in
            let pass = await rig.run()
            print(pass ? "HISTORY-GATE PASS" : "HISTORY-GATE FAIL")
            exit(pass ? 0 : 1)
        }
        return true
    }
}

@available(iOS 26, *)
@MainActor
final class HistoryRig {
    let host: UIViewController
    let out: URL
    let replayDir: URL
    let macTranscript: URL
    let mergeFixtures: URL
    let inject: String?
    private var passed = 0
    private var failures: [String] = []
    private var lines: [String] = []
    private var motion: [String] = []
    private var editor: EditorViewController?
    private var store: LocalProjectHistory?
    private var replay: HistoryTranscript.Replay!
    private var clock: HistoryClock = .current
    private var folderDir: URL!

    init(host: UIViewController, out: URL, replayDir: URL, macTranscript: URL, mergeFixtures: URL, inject: String?) {
        self.host = host
        self.out = out
        self.replayDir = replayDir
        self.macTranscript = macTranscript
        self.mergeFixtures = mergeFixtures
        self.inject = inject
    }

    /// Self-test probes run the same checks with a defect injected; their
    /// outcome is reported by the self-test's own expectation, not counted.
    private var probing = false

    private func expect(_ condition: Bool, _ label: String) {
        if probing {
            print("    (self-test probe) \(condition ? "held" : "tripped"): \(label)")
            return
        }
        if condition {
            passed += 1
            print("  ✓ \(label)")
        } else {
            failures.append(label)
            print("  ✘ \(label)")
        }
    }

    private func wait(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > end { return false }
            await LabTime.settle(0.01)
        }
        return true
    }

    private static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

    // MARK: - Run

    func run() async -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        print("HISTORY iOS out=\(out.path)" + (inject.map { " inject=\($0)" } ?? ""))
        #if DEBUG
        HistoryPresentation.debugSnap = inject == "snap-panel"
        HistoryPanelController.debugSnapCompare = inject == "snap-compare"
        HistoryPreviewSession.debugSnap = inject == "snap-preview"
        StudioMergeReviewController.debugWrongPick = inject == "merge-pick"
        #endif
        guard let data = try? Data(contentsOf: replayDir.appendingPathComponent(HistoryTranscript.replayName)),
              let replay = try? JSONDecoder().decode(HistoryTranscript.Replay.self, from: data) else {
            expect(false, "the Mac's replay.json is readable (\(replayDir.path))")
            return report()
        }
        self.replay = replay
        clock = HistoryTranscript.clock(replay)
        lines = [HistoryTranscript.header, "clock tz=\(replay.timeZone)"]

        guard await prepareStore() else { return report() }
        await rowsBeforeEditor()
        guard await openEditor() else { return report() }
        await openPanel(label: "the History panel")
        await compares()
        await previewCheck()
        await restoreCheck()
        await mergeChecks()
        await externalChangeCheck()
        await selfTest()

        // ── The verdict against the Mac ──────────────────────────────────
        try? lines.joined(separator: "\n").appending("\n")
            .write(to: out.appendingPathComponent("ios-transcript.txt"), atomically: true, encoding: .utf8)
        try? motion.joined(separator: "\n").appending("\n")
            .write(to: out.appendingPathComponent("motion.txt"), atomically: true, encoding: .utf8)
        let mac = ((try? String(contentsOf: macTranscript, encoding: .utf8)) ?? "")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { !$0.isEmpty }
        let diffs = HistoryTranscript.failures(mac: mac, ios: lines)
        expect(!mac.isEmpty && diffs.isEmpty,
               "TRANSCRIPT: \(lines.count) lines \(diffs.isEmpty ? "identical to" : "differ from") the Mac's \(mac.count)"
               + " (rows \(lines.filter { $0.contains(" row ver-") }.count), compares \(lines.filter { $0.hasPrefix("compare ") && $0.contains(" summary=") }.count),"
               + " merges \(lines.filter { $0.hasPrefix("merge ") && $0.contains(" mineWins=") }.count))")
        for d in diffs { print("    \(d)") }
        return report()
    }

    private func report() -> Bool {
        if failures.isEmpty {
            print("HISTORY PASS (\(passed) checks)")
            return true
        }
        print("HISTORY FAIL (\(failures.count) of \(passed + failures.count)):")
        for f in failures { print("  ✘ \(f)") }
        return false
    }

    // MARK: - The replay → an on-device history

    private func prepareStore() async -> Bool {
        print("replay: the Mac's saves → LocalProjectHistory")
        let fm = FileManager.default
        let dir = out.appendingPathComponent("project", isDirectory: true)
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in replay.media {
            try? fm.copyItem(at: replayDir.appendingPathComponent(name), to: dir.appendingPathComponent(name))
        }
        try? Data(replay.currentDocument.utf8).write(to: dir.appendingPathComponent(StudioProjectFolder.documentName))
        folderDir = dir
        let device = ProjectHistoryIdentity(actorUID: replay.deviceActorUID,
                                            actorName: replay.displayNames[replay.deviceActorUID] ?? "Mac",
                                            clientKind: "mac", clientID: replay.deviceClientID)
        let recorder = LocalProjectHistory(projectDirectory: dir, identity: device, displayNames: replay.displayNames,
                                           window: .api, idPrefix: "ver-")
        for save in replay.saves {
            let who = ProjectHistoryIdentity(actorUID: save.actorUID, actorName: replay.displayNames[save.actorUID] ?? save.actorUID,
                                             clientKind: save.clientKind, clientID: save.clientID ?? "", source: save.source)
            let change = save.change.flatMap { try? JSONValue.parse($0) }.flatMap(ProjectDiff.changeSet(from:))
            guard let entry = recorder.record(Data(save.document.utf8), at: Self.date(save.at), change: change,
                                              checkpoint: HistoryTranscript.checkpoint(save.checkpoint),
                                              restoredFrom: save.restoredFrom, mergedFrom: save.mergedFrom, as: who) else {
                expect(false, "every replayed save opens a version")
                return false
            }
            if let label = save.label { try? await recorder.rename(versionID: entry.id, label: label) }
        }
        // Reload from disk: what the panel lists must survive persistence.
        let store = LocalProjectHistory(projectDirectory: dir, identity: device, displayNames: replay.displayNames,
                                        window: .api, idPrefix: "local-")
        expect(store.entries == recorder.entries && store.entries.count == replay.saves.count,
               "\(store.entries.count) versions recorded, persisted to .history/ and reloaded byte-identical")
        var times = replay.restoreAt
        store.clock = { times.isEmpty ? Date() : Self.date(times.removeFirst()) }
        StudioHistory.install(store)
        self.store = store
        return true
    }

    // MARK: - Rows

    /// Rows as the panel shows them: one line per day section and row cell.
    private func rowLines(_ tag: String, panel: HistoryPanelController) -> [String] {
        var out: [String] = []
        for (index, section) in panel.sections.enumerated() {
            let cells = section.ccDescendants(of: HistoryRowCell.self)
            out.append("\(tag) " + HistoryTranscript.sectionLine(panel.sectionTitles[index], rows: cells.count))
            for cell in cells {
                let v = cell.version
                let row = HistoryTranscript.Row(
                    versionID: v.id, seq: v.seq, kind: v.kind, label: v.label, isHead: cell.model.isHead,
                    day: panel.sectionTitles[index], time: cell.probeTime, author: cell.probeAuthor,
                    summary: cell.probeSummary,
                    badges: zip(cell.badges, cell.model.badges).map { ($0.0.text, $0.1.style.rawValue) },
                    documentSHA256: v.documentSHA256 ?? "", change: v.change.map { $0.json.canonical })
                out.append("\(tag) " + HistoryTranscript.line(row))
                if cell.probeAvatar.name != cell.probeAuthor {
                    expect(false, "row \(v.id): the avatar names \(cell.probeAvatar.name), the row \(cell.probeAuthor)")
                }
            }
        }
        return out
    }

    /// Before the editor opens (the Mac lists before its restore pushes the
    /// unsynced edit): the real panel, hosted in this window.
    private func rowsBeforeEditor() async {
        print("rows: the panel over the replayed history")
        guard let store else { return }
        let panel = HistoryPanelController(service: store, host: nil, device: StudioHistory.deviceNoun)
        panel.clock = clock
        host.addChild(panel)
        panel.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(panel.view)
        NSLayoutConstraint.activate([
            panel.view.centerXAnchor.constraint(equalTo: host.view.centerXAnchor),
            panel.view.widthAnchor.constraint(equalToConstant: 380),
            panel.view.topAnchor.constraint(equalTo: host.view.safeAreaLayoutGuide.topAnchor),
            panel.view.bottomAnchor.constraint(equalTo: host.view.safeAreaLayoutGuide.bottomAnchor),
        ])
        panel.didMove(toParent: host)
        host.view.layoutIfNeeded()
        await LabTime.settle(0.3)
        lines += rowLines("before", panel: panel)
        let frames = panel.rows.map { $0.convert($0.bounds, to: panel.view) }
        let overlap = zip(frames, frames.dropFirst()).contains { $1.minY < $0.maxY - 0.5 }
        expect(panel.rows.count == replay.saves.count && !overlap && frames.allSatisfy { $0.width > 250 && $0.height >= HistoryRowCell.minHeight - 0.5 },
               "\(panel.rows.count) rows in \(panel.sections.count) day cards, stacked without overlap, ≥ 44 pt targets")
        capture(host.view, "history-rows.png")
        panel.willMove(toParent: nil)
        panel.view.removeFromSuperview()
        panel.removeFromParent()
    }

    // MARK: - The editor

    private func openEditor() async -> Bool {
        print("editor: the replayed project in the shipping EditorViewController")
        do {
            let folder = try StudioProjectFolder.open(folderDir)
            let editor = EditorViewController(folder: folder)
            editor.onClose = {}
            self.editor = editor
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                host.present(editor, animated: false) { c.resume() }
            }
        } catch {
            expect(false, "the replayed project opens (\(error))")
            return false
        }
        guard let editor else { return false }
        _ = await wait(20) { editor.playback.isReady && editor.stage.core.displayedVideoFrame != nil }
        await LabTime.settle(0.3)
        expect(editor.stage.core.displayedVideoFrame != nil, "the editor shows the fixture's recording")
        // Attach recorded the unsynced edit the file holds (the Mac's restore pushes it first).
        expect(store?.entries.count == replay.saves.count + 1 && store?.head?.kind == "edit",
               "opening kept the file's unsynced edit as a new version (\(store?.entries.count ?? 0) versions)")
        return true
    }

    private var panel: HistoryPanelController? {
        guard let editor else { return nil }
        return HistoryPresentation.current(in: editor)?.panel
    }

    /// Opens History through the plain entry point; samples its entrance.
    @discardableResult
    private func openPanel(label: String) async -> Bool {
        guard let editor else { return false }
        if let open = panel { open.reloadNow(); return true }
        guard let shown = StudioHistory.present(from: editor, project: editor.project, undoManager: editor.undoManager) else {
            expect(false, "StudioHistory.present finds the editor")
            return false
        }
        shown.clock = clock
        shown.reloadNow()
        guard let presentation = shown.presentation else {
            expect(false, "\(label) is presented")
            return false
        }
        let samples = await sampleEntrance(presentation)
        let start = presentation.probeStartOffset
        let early = samples.first { $0.t >= 0.04 } ?? samples.first
        let later = samples.first { $0.t >= 0.12 } ?? samples.last
        let mid = early.map { abs($0.v) > abs(start) * 0.02 && abs($0.v) < abs(start) * 0.98 } ?? false
        let travelling = (early?.v).flatMap { e in (later?.v).map { abs($0) < abs(e) - 0.5 } } ?? false
        motion.append("\(label) \(presentation.style) start=\(f(start)) " + samples.map { "\(f($0.t)):\(f($0.v))" }.joined(separator: " "))
        expect(mid && travelling,
               "\(label) (\(presentation.style == .sidePanel ? "side panel" : "sheet")) enters mid-flight: "
               + "\(f(early?.v ?? 0)) of \(f(start)) at \(f(early?.t ?? 0)) s, \(f(later?.v ?? 0)) at \(f(later?.t ?? 0)) s")
        await LabTime.settle(0.6)
        if let view = presentation.probeMovingView, let window = view.window {
            let frame = view.convert(view.bounds, to: window)
            let wantSide = editor.view.bounds.width >= 700
            let ok = wantSide
                ? frame.maxX <= window.bounds.maxX + 0.5 && frame.width >= 340 && frame.minX > window.bounds.width * 0.4
                : frame.maxY <= window.bounds.maxY + 0.5 && frame.height > window.bounds.height * 0.6
            expect(ok && presentation.style == (wantSide ? .sidePanel : .sheet),
                   "\(label) lands as a \(wantSide ? "side panel on the trailing edge" : "bottom sheet") (\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))×\(Int(frame.height)))")
        }
        return mid && travelling
    }

    private struct Sample { let t: TimeInterval; let v: CGFloat }

    private func sampleEntrance(_ presentation: HistoryPresentation) async -> [Sample] {
        var samples: [Sample] = []
        let begin = Date()
        while Date().timeIntervalSince(begin) < 0.45 {
            if let layer = presentation.probeMovingView?.layer {
                let p = layer.presentation() ?? layer
                let v = (p.value(forKeyPath: presentation.probeKeyPath) as? CGFloat) ?? 0
                samples.append(Sample(t: Date().timeIntervalSince(begin), v: v))
            }
            await LabTime.settle(0.012)
        }
        return samples
    }

    // MARK: - Driving the house controls

    private func topmost() -> UIViewController { CCAlert.topmost(from: host) }

    /// Picks `title` in the action sheet on screen (a real row tap).
    private func pick(_ title: String, settle: Bool = true) async -> Bool {
        let found = await wait(2) { topmost() is CCActionSheetController }
        guard found, let sheet = topmost() as? CCActionSheetController else { return false }
        await LabTime.settle(0.3)
        guard let row = sheet.view.ccDescendants(of: CCActionRow.self).first(where: { $0.accessibilityLabel == title }) else {
            return false
        }
        row.sendActions(for: .touchUpInside)
        guard settle else { return true }
        _ = await wait(2) { !(topmost() is CCActionSheetController) }
        await LabTime.settle(0.1)
        return true
    }

    /// Taps `title` in the CCAlert on screen.
    private func confirm(_ title: String) async -> Bool {
        let found = await wait(2) { topmost() is CCAlertController }
        guard found, let alert = topmost() as? CCAlertController else { return false }
        await LabTime.settle(0.35)
        guard let button = alert.probeButtonViews.first(where: { $0.title == title }) else { return false }
        button.sendActions(for: .touchUpInside)
        _ = await wait(4) { !(topmost() is CCAlertController) }
        await LabTime.settle(0.2)
        return true
    }

    private func row(_ id: String) -> HistoryRowCell? { panel?.rows.first { $0.version.id == id } }

    // MARK: - Compare

    private func compares() async {
        print("compare: from the rows' action sheets")
        guard let page = panel?.page else { return }
        // The Mac compares every version but its head (ver-6) with now.
        let macHead = "ver-\(replay.saves.count)"
        var first = true
        for version in page.versions where version.id != macHead && version.id != store?.head?.id {
            await openCompare(version.id, action: "Compare with Current", tag: "current \(version.id)", sampleMotion: first)
            first = false
        }
        let ids = (1...replay.saves.count).map { "ver-\($0)" }
        for (a, b) in zip(ids, ids.dropFirst()) {
            await openCompare(b, action: "Compare with Previous", tag: "pair \(a) \(b)", sampleMotion: false)
        }
    }

    private func openCompare(_ id: String, action: String, tag: String, sampleMotion: Bool) async {
        guard let panel, let row = row(id) else {
            expect(false, "row \(id) is listed for \(action)")
            return
        }
        panel.probeScroll.scrollRectToVisible(row.convert(row.bounds, to: panel.probeScroll), animated: false)
        row.sendActions(for: .touchUpInside)
        guard await pick(action) else {
            expect(false, "\(id): the action sheet offers “\(action)”")
            return
        }
        let shown = await wait(2) { panel.comparePage != nil }
        guard shown, let compare = panel.comparePage else {
            expect(false, "\(id): \(action) opens the compare page")
            return
        }
        if sampleMotion { await checkCompareMotion(panel, compare: compare, label: "compare slides over the list") }
        await LabTime.settle(0.45)
        let groups = compare.sections.enumerated().map { index, section -> (title: String, lines: [String]) in
            let title = section.title.replacingOccurrences(of: " (\(section.lines.count))", with: "")
            return (title, section.lines.map { $0.hasPrefix("• ") ? String($0.dropFirst(2)) : $0 })
        }
        lines += HistoryTranscript.compareLines(tag, summary: compare.probeSummary, groups: groups)
        if sampleMotion {
            capture(panel.view.window ?? panel.view, "history-compare.png")
            let firstOpen = compare.sections.first?.isExpanded == true && compare.sections.dropFirst().allSatisfy { !$0.isExpanded }
            expect(firstOpen, "one disclosure card per group, the first open (the Mac's accordion)")
        }
        compare.backButton.sendActions(for: .touchUpInside)
        _ = await wait(1) { panel.comparePage == nil }
        await LabTime.settle(0.35)
    }

    /// The compare page's arrival, sampled as a sequence (cheap reads only).
    private func checkCompareMotion(_ panel: HistoryPanelController, compare: HistoryComparePage, label: String) async {
        var samples: [Sample] = []
        let begin = Date()
        let start = panel.compareStartOffset
        while Date().timeIntervalSince(begin) < 0.2 {
            let p = compare.layer.presentation() ?? compare.layer
            samples.append(Sample(t: Date().timeIntervalSince(begin), v: (p.value(forKeyPath: "transform.translation.x") as? CGFloat) ?? 0))
            await LabTime.settle(0.01)
        }
        let early = samples.first { $0.t >= 0.03 } ?? samples.first
        let later = samples.first { $0.t >= 0.11 } ?? samples.last
        let mid = early.map { $0.v > start * 0.02 && $0.v < start * 0.98 } ?? false
        let travelling = (early?.v).flatMap { e in (later?.v).map { $0 < e - 0.5 } } ?? false
        let listAlpha = (panel.probeListPage.layer.presentation() ?? panel.probeListPage.layer).opacity
        motion.append("\(label) start=\(f(start)) " + samples.map { "\(f($0.t)):\(f($0.v))" }.joined(separator: " "))
        compareMotionOK = mid && travelling
        expect(mid && travelling,
               "\(label) mid-flight: \(f(early?.v ?? 0)) of \(f(start)) pt at \(f(early?.t ?? 0)) s → \(f(later?.v ?? 0)) at \(f(later?.t ?? 0)) s (list α \(f(CGFloat(listAlpha))))")
    }

    private var compareMotionOK = false

    // MARK: - Preview

    private func previewCheck() async {
        print("preview: the named version on the live stage")
        guard let editor, let row = row(replay.restoreVersionID) else {
            expect(false, "the named version is listed")
            return
        }
        let liveBefore = HistoryTranscript.encodedModel(editor.project)
        row.sendActions(for: .touchUpInside)
        guard await pick("Preview", settle: false) else {
            expect(false, "the row's action sheet offers Preview")
            return
        }
        // Poll tightly: the sequence must start with the move, not after it.
        var began = false
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if HistoryPreviewSession.current(in: editor) != nil { began = true; break }
            await LabTime.settle(0.002)
        }
        guard began, let session = HistoryPreviewSession.current(in: editor) else {
            expect(false, "Preview puts the version on the stage")
            return
        }
        // ── The opening move, sampled before anything else ───────────────
        var dissolve: [Sample] = [], drop: [Sample] = []
        let begin = Date()
        while Date().timeIntervalSince(begin) < 0.3 {
            let t = Date().timeIntervalSince(begin)
            let d = session.probeDissolve.map { CGFloat(($0.layer.presentation() ?? $0.layer).opacity) } ?? 0
            let b = (session.banner.layer.presentation() ?? session.banner.layer).value(forKeyPath: "transform.translation.y") as? CGFloat ?? 0
            dissolve.append(Sample(t: t, v: d))
            drop.append(Sample(t: t, v: b))
            await LabTime.settle(0.012)
        }
        let early = dissolve.first { $0.t >= 0.05 } ?? dissolve.first
        let later = dissolve.first { $0.t >= 0.16 } ?? dissolve.last
        let earlyDrop = drop.first { $0.t >= 0.05 } ?? drop.first
        let dissolving = (early?.v ?? 0) > 0.02 && (early?.v ?? 1) < 0.98 && (later?.v ?? 1) < (early?.v ?? 0) - 0.01
        let dropping = (earlyDrop?.v ?? 0) < -0.5 && (earlyDrop?.v ?? -99) > HistoryPreviewSession.bannerTravel + 0.5
        motion.append("preview dissolve " + dissolve.map { "\(f($0.t)):\(f($0.v))" }.joined(separator: " "))
        motion.append("preview banner " + drop.map { "\(f($0.t)):\(f($0.v))" }.joined(separator: " "))
        previewMotionOK = dissolving && dropping
        expect(dissolving, "the frame on screen dissolves into the version mid-flight (α \(f(early?.v ?? 0)) → \(f(later?.v ?? 0)))")
        expect(dropping, "…while the banner drops in (\(f(earlyDrop?.v ?? 0)) of \(f(HistoryPreviewSession.bannerTravel)) pt)")
        await LabTime.settle(0.5)

        expect(editor.isPreviewingVersion && editor.frameInput().project === session.project && session.project.isPreview
               && !editor.canvas.isUserInteractionEnabled,
               "the stage renders the version (a separate isPreview model) and editing is off")
        lines.append("preview \(replay.restoreVersionID) title=\(HistoryTranscript.q(session.banner.titleLabel.text ?? ""))"
                     + " message=\(HistoryTranscript.q(session.banner.messageLabel.text ?? ""))")
        capture(editor.view, "history-preview.png")
        editor.saveNow()
        expect(HistoryTranscript.encodedModel(editor.project) == liveBefore
               && (try? Data(contentsOf: editor.folder.documentURL)).map { $0 == store?.head?.document } == true,
               "the preview never touches the project or its file")
        session.banner.backButton.sendActions(for: .touchUpInside)
        _ = await wait(1) { !editor.isPreviewingVersion }
        expect(!editor.isPreviewingVersion && editor.canvas.isUserInteractionEnabled, "Back to Current (real tap) returns the stage to the project, editable")
        await LabTime.settle(0.4)
    }

    private var previewMotionOK = false

    // MARK: - Restore

    private func restoreCheck() async {
        print("restore: the named version, from its action sheet")
        guard let editor, let store else { return }
        await openPanel(label: "History reopened")
        guard let row = row(replay.restoreVersionID) else {
            expect(false, "the named version is listed for restore")
            return
        }
        let before = replay.saves.count
        let opening = HistoryTranscript.encodedModel(editor.project)
        row.sendActions(for: .touchUpInside)
        let picked = await pick("Restore This Version…")
        let confirmed = picked ? await confirm("Restore") : false
        expect(picked && confirmed, "Restore This Version… → the confirmation's Restore key")
        let restored = await wait(3) { store.head?.kind == "restore" }
        expect(restored, "the restore is kept as the newest version (restoredFrom \(store.head?.restoredFrom ?? "nil"))")
        await LabTime.settle(0.3)
        lines.append("restore \(replay.restoreVersionID) versions \(before) → \(store.entries.count)")
        if let panel {
            panel.reloadNow()
            await LabTime.settle(0.2)
            lines += rowLines("after", panel: panel)
        }
        let document = (try? Data(contentsOf: editor.folder.documentURL)) ?? Data()
        let model = HistoryTranscript.encodedModel(editor.project)
        lines += HistoryTranscript.restoreLines(replay.restoreVersionID, document: document, model: model)

        // One undo step, both ways.
        let undo = editor.undoManager!
        expect(undo.canUndo && undo.undoActionName == "Restore Version", "restore registers an undo step (“\(undo.undoActionName)”)")
        editor.performUndo()
        await LabTime.settle(0.1)
        expect(HistoryTranscript.encodedModel(editor.project) == opening && !undo.canUndo,
               "one Undo puts the project back exactly — and it was the only step")
        editor.performRedo()
        await LabTime.settle(0.1)
        expect(HistoryTranscript.encodedModel(editor.project) == model, "Redo restores the version again")
        editor.saveNow()
        await LabTime.settle(0.1)
    }

    // MARK: - Merge Review

    private func mergeChecks() async {
        print("merge: every apps/web merge fixture through Merge Review")
        guard let editor else { return }
        let fixtures = HistoryTranscript.loadMergeFixtures(mergeFixtures)
        expect(!fixtures.isEmpty, "\(fixtures.count) merge fixtures loaded")
        var reviewed = 0
        for fx in fixtures {
            let session = ProjectMergeSession(base: fx.base, mine: fx.mine, theirs: fx.theirs, mineWins: fx.mineWins)
            var decisions: [HistoryTranscript.Decision] = []
            var flipped = HistoryTranscript.hash(session.merged)
            if !session.conflicts.isEmpty {
                guard let result = await review(session, in: editor, flip: true, sampleMotion: reviewed == 0) else {
                    expect(false, "\(fx.name): Merge Review applies")
                    continue
                }
                decisions = result.decisions
                flipped = HistoryTranscript.hash(result.applied.merged)
                reviewed += 1
            }
            lines += HistoryTranscript.mergeLines(
                fixture: fx.name, mineWins: fx.mineWins, decisions: decisions,
                autoResolved: session.autoResolved.map { MergeReviewWords.describe($0, device: StudioHistory.deviceNoun) },
                defaultHash: HistoryTranscript.hash(session.merged), flippedHash: flipped)
        }
        print("  · \(reviewed) fixtures reviewed through the controls")
    }

    private struct ReviewResult {
        let decisions: [HistoryTranscript.Decision]
        let applied: ProjectMergeSession
    }

    /// Presents Merge Review, reads it, flips every control (VoiceOver
    /// activation — the controls' own path), taps Apply.
    private func review(_ session: ProjectMergeSession, in editor: EditorViewController, flip: Bool,
                        sampleMotion: Bool) async -> ReviewResult? {
        var applied: ProjectMergeSession?
        let controller = StudioHistory.reviewMerge(from: editor, session: session, projectName: "Merge fixture",
                                                   onApply: { applied = $0 })
        let shown = await wait(2) { controller.view.window != nil }
        guard shown else { return nil }
        if sampleMotion, let sheet = controller.container {
            var samples: [Sample] = []
            let begin = Date()
            let keyPath = sheet.layout == .sheet ? "transform.translation.y" : "transform.translation.x"
            while Date().timeIntervalSince(begin) < 0.25 {
                let p = sheet.card.layer.presentation() ?? sheet.card.layer
                samples.append(Sample(t: Date().timeIntervalSince(begin), v: (p.value(forKeyPath: keyPath) as? CGFloat) ?? 0))
                await LabTime.settle(0.012)
            }
            let early = samples.first { $0.t >= 0.04 } ?? samples.first
            let start = sheet.startOffset
            motion.append("merge review start=\(f(start)) " + samples.map { "\(f($0.t)):\(f($0.v))" }.joined(separator: " "))
            expect(early.map { abs($0.v) > abs(start) * 0.02 && abs($0.v) < abs(start) * 0.98 } ?? false,
                   "Merge Review (\(sheet.layout == .sheet ? "sheet" : "side panel")) enters mid-flight (\(f(early?.v ?? 0)) of \(f(start)))")
        }
        await LabTime.settle(0.45)
        let decisions = controller.rows.map { row in
            HistoryTranscript.Decision(id: row.conflict.id, kind: row.conflict.kind, title: row.title.text ?? "",
                                       detail: row.detail.text ?? "", selectedIndex: row.control.selectedIndex)
        }
        if sampleMotion { capture(controller.view.window ?? controller.view, "merge-review.png") }
        if flip {
            for row in controller.rows {
                let target = row.control.selectedIndex == 0 ? 1 : 0
                (row.control.accessibilityElements?[target] as? UIAccessibilityElement).map { _ = $0.accessibilityActivate() }
            }
            await LabTime.settle(0.05)
        }
        controller.applyButton.sendActions(for: .touchUpInside)
        _ = await wait(2) { applied != nil }
        _ = await wait(2) { controller.view.window == nil }
        await LabTime.settle(0.1)
        return applied.map { ReviewResult(decisions: decisions, applied: $0) }
    }

    // MARK: - Changed outside this editor

    private func externalChangeCheck() async {
        print("changed outside this editor → Merge Review → merged")
        guard let editor, let store else { return }
        editor.saveNow()
        await LabTime.settle(1.2)
        editor.saveNow()
        guard let disk = try? Data(contentsOf: editor.folder.documentURL),
              var object = (try? JSONSerialization.jsonObject(with: disk)) as? [String: Any] else { return }
        // Another window renames the project and moves the trim end.
        object["name"] = "Renamed in another window"
        let trimEnd = (object["trimEnd"] as? Double) ?? 4
        object["trimEnd"] = trimEnd - 0.5
        let theirs = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        try? theirs.write(to: editor.folder.documentURL)
        let versionsBefore = store.entries.count
        if let panel { panel.reloadNow() } else { await openPanel(label: "History (external change)") }
        await LabTime.settle(0.2)
        guard let row = panel?.externalRow else {
            expect(false, "History shows “Changed outside this editor” for a file edited under the editor")
            return
        }
        expect(row.summaryLabel.text == "Renamed" || (row.summaryLabel.text ?? "").contains("Renamed"),
               "…summarising what changed (“\(row.summaryLabel.text ?? "")”)")
        row.reviewButton.sendActions(for: .touchUpInside)
        let merged = await wait(3) { editor.project.name == "Renamed in another window" }
        expect(merged && abs(editor.project.trimEnd - (trimEnd - 0.5)) < 1e-9,
               "Review merges the file's changes into the live project")
        let kinds = store.entries.dropFirst(versionsBefore).map(\.kind)
        expect(kinds == ["edit", "merge"] && store.entries.dropFirst(versionsBefore).first?.actorUID == "outside",
               "both inputs are kept: the file's version, then the merge (\(kinds.joined(separator: ", ")))")
        expect(editor.undoManager?.undoActionName == "Merge Changes", "the merge is one undo step (“\(editor.undoManager?.undoActionName ?? "")”)")
        await LabTime.settle(0.3)
        panel?.reloadNow()
        expect(panel?.externalRow == nil && panel?.rows.first?.badges.contains { $0.text == "Merge" } == true,
               "the row is gone and the newest version carries a Merge badge")
    }

    // MARK: - Gate power

    private func selfTest() async {
        #if DEBUG
        guard inject == nil, let editor else { return }
        print("self-test: injected defects are caught")
        // A wrong merge pick changes the merged document.
        if let fx = HistoryTranscript.loadMergeFixtures(mergeFixtures).first(where: {
            !ProjectMergeSession(base: $0.base, mine: $0.mine, theirs: $0.theirs, mineWins: $0.mineWins).conflicts.isEmpty
        }) {
            let session = ProjectMergeSession(base: fx.base, mine: fx.mine, theirs: fx.theirs, mineWins: fx.mineWins)
            let honest = await review(session, in: editor, flip: true, sampleMotion: false)
            StudioMergeReviewController.debugWrongPick = true
            let wrong = await review(session, in: editor, flip: true, sampleMotion: false)
            StudioMergeReviewController.debugWrongPick = false
            let a = honest.map { HistoryTranscript.hash($0.applied.merged) }, b = wrong.map { HistoryTranscript.hash($0.applied.merged) }
            expect(a != nil && b != nil && a != b, "a wrong merge pick changes the merged hash (\(a ?? "-") vs \(b ?? "-")) — the transcript catches it")
        }
        // A snapped compare fails the mid-flight assertion.
        if let panel, let row = panel.rows.dropFirst().first {
            HistoryPanelController.debugSnapCompare = true
            row.sendActions(for: .touchUpInside)
            if await pick("Compare with Current"), await wait(2, { panel.comparePage != nil }), let compare = panel.comparePage {
                probing = true
                await checkCompareMotion(panel, compare: compare, label: "snapped compare (injected)")
                probing = false
                expect(!compareMotionOK, "a snapped compare fails the mid-flight assertion")
                compare.backButton.sendActions(for: .touchUpInside)
                await LabTime.settle(0.4)
            } else {
                expect(false, "self-test: compare opens")
            }
            HistoryPanelController.debugSnapCompare = false
        }
        // A snapped preview fails the dissolve assertion.
        if let page = panel?.page, let version = page.versions.dropFirst().first, let store {
            HistoryPreviewSession.debugSnap = true
            if let document = try? await store.document(versionID: version.id),
               let session = try? HistoryPreviewSession.begin(version: version, document: document, in: editor, clock: clock) {
                await LabTime.settle(0.05)
                let d = session.probeDissolve.map { CGFloat(($0.layer.presentation() ?? $0.layer).opacity) } ?? 0
                let b = (session.banner.layer.presentation() ?? session.banner.layer).value(forKeyPath: "transform.translation.y") as? CGFloat ?? 0
                expect(!(d > 0.02 && d < 0.98) && abs(b) < 0.5, "a snapped preview fails the dissolve / drop assertions (α \(f(d)), banner \(f(b)))")
                session.end(animated: false)
            }
            HistoryPreviewSession.debugSnap = false
        }
        // A snapped panel fails the entrance assertion.
        if let presentation = HistoryPresentation.current(in: editor) {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in presentation.dismiss { c.resume() } }
            await LabTime.settle(0.3)
        }
        HistoryPresentation.debugSnap = true
        probing = true
        let ok = await openPanel(label: "snapped panel (injected)")
        probing = false
        HistoryPresentation.debugSnap = false
        expect(!ok, "a snapped panel fails the entrance assertion")
        #endif
    }

    // MARK: - Helpers

    private func f(_ v: CGFloat) -> String { String(format: "%.2f", Double(v)) }
    private func f(_ v: Double) -> String { String(format: "%.3f", v) }

    private func capture(_ view: UIView, _ name: String) {
        guard let image = LabCapture.view(view) else { return }
        let url = out.appendingPathComponent(name)
        if let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
            print("  · shot \(name)")
        }
    }
}

extension UIView {
    /// Every descendant of type `T`, depth first, in subview order.
    func ccDescendants<T: UIView>(of type: T.Type) -> [T] {
        var out: [T] = []
        for sub in subviews {
            if let match = sub as? T { out.append(match) }
            out += sub.ccDescendants(of: type)
        }
        return out
    }
}
