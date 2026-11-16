import Foundation

/// The project-history transcript (Studio 4f), shared by the Mac
/// `--history-transcript <outDir>` (HistoryTranscriptHarness: the real
/// StubCloudServer + CloudProjectSync + CloudHistoryClient, the real
/// HistoryRowView / VersionCompareDialog / MergeReviewDialog) and the iOS
/// `--history <outDir>` gate (StudioLab HistoryLab: the real iOS History
/// views over LocalProjectHistory). Both write their lines through this one
/// formatter, so a difference is behaviour, not formatting.
///
/// The Mac also writes the REPLAY (`replay.json` + the fixture's media): the
/// saves its stub server turned into versions, so iOS can record the same
/// saves into its on-device history and must list the same rows.
enum HistoryTranscript {
    static let header = "== history transcript v1 (fixture: --history-panel-shot's six versions over three days + an unsynced edit; merges: apps/web merge fixtures)"

    // MARK: Lines

    struct Row: Equatable {
        var versionID: String
        var seq: Int
        var kind: String
        var label: String?
        var isHead: Bool
        var day: String
        var time: String
        var author: String
        var summary: String
        /// (text, style) in display order.
        var badges: [(String, String)]
        var documentSHA256: String
        var change: String?

        static func == (a: Row, b: Row) -> Bool { line(a) == line(b) }
    }

    static func line(_ r: Row) -> String {
        let badges = r.badges.map { "\($0.0)|\($0.1)" }.joined(separator: ",")
        // `seq` is not shown and not compared: the Mac's wire parser reads
        // `"seq": 1` as nil (JSON 1 passes its `is Bool` test), so its first
        // version lists seq 0 — reported, not mirrored.
        return "row \(r.versionID) kind=\(r.kind) label=\(q(r.label ?? "-")) head=\(r.isHead ? 1 : 0)"
            + " day=\(q(r.day)) time=\(q(r.time)) author=\(q(r.author)) summary=\(q(r.summary)) badges=[\(badges)]"
            + " sha=\(r.documentSHA256.prefix(16)) change=\(r.change.map { JSONHash.fnv1a64Hex($0) } ?? "nil")"
    }

    static func sectionLine(_ title: String, rows: Int) -> String { "section \(q(title)) rows=\(rows)" }

    static func compareLines(_ tag: String, summary: String, groups: [(title: String, lines: [String])]) -> [String] {
        ["compare \(tag) summary=\(q(summary)) groups=\(groups.count)"]
            + groups.map { "compare \(tag) group=\(q($0.title)) lines=[\($0.lines.map(q).joined(separator: ","))]" }
    }

    struct Decision {
        var id: String
        var kind: String
        var title: String
        var detail: String
        /// The side the control starts on (0 = Mine).
        var selectedIndex: Int
    }

    static func mergeLines(fixture: String, mineWins: Bool, decisions: [Decision], autoResolved: [String],
                           defaultHash: String, flippedHash: String) -> [String] {
        var out = ["merge \(fixture) mineWins=\(mineWins ? 1 : 0) conflicts=\(decisions.count) auto=\(autoResolved.count)"
                   + " default=\(defaultHash) flipped=\(flippedHash)"]
        for d in decisions {
            out.append("merge \(fixture) conflict \(d.id) kind=\(d.kind) start=\(d.selectedIndex == 0 ? "mine" : "theirs")"
                       + " title=\(q(d.title)) detail=\(q(d.detail))")
        }
        for a in autoResolved { out.append("merge \(fixture) auto \(q(a))") }
        return out
    }

    /// The merged document's identity: FNV-1a of its canonical JSON.
    static func hash(_ value: JSONValue) -> String { JSONHash.fnv1a64Hex(value.canonical) }

    static func q(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    /// iOS says "this iPad" / "this iPhone" where the Mac says "this Mac" —
    /// the one wording difference a line may carry.
    static func neutralDevice(_ line: String) -> String {
        line.replacingOccurrences(of: "this iPad", with: "this Mac").replacingOccurrences(of: "this iPhone", with: "this Mac")
    }

    /// Line-by-line verdict (device nouns neutralised on both sides).
    static func failures(mac: [String], ios: [String]) -> [String] {
        let a = mac.map(neutralDevice), b = ios.map(neutralDevice)
        var out: [String] = []
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : "<none>"
            let y = i < b.count ? b[i] : "<none>"
            if x != y {
                out.append("line \(i + 1):\n      mac \(x)\n      ios \(y)")
                if out.count >= 12 { out.append("… (more differences)"); break }
            }
        }
        return out
    }

    // MARK: Restored project

    static let mediaKeys = ["videoURL", "cursorDataURL", "keystrokeDataURL", "cameraVideoURL"]
    static let settingsPathKeys = ["backgroundImagePath", "cameraCardImagePath"]

    /// A project document with its media references reduced to file names
    /// (the Mac's fixture folder and the iOS container differ; everything
    /// else must be identical).
    static func mediaNeutral(_ value: JSONValue) -> JSONValue {
        guard var root = value.objectValue else { return value }
        for key in mediaKeys {
            if let raw = root[key]?.stringValue {
                root[key] = .string(URL(string: raw)?.lastPathComponent ?? (raw as NSString).lastPathComponent)
            }
        }
        if var settings = root["settings"]?.objectValue {
            for key in settingsPathKeys {
                if let raw = settings[key]?.stringValue, !raw.isEmpty {
                    settings[key] = .string((raw as NSString).lastPathComponent)
                }
            }
            root["settings"] = .object(settings)
        }
        return .object(root)
    }

    static func restoreLines(_ tag: String, document: Data, model: Data) -> [String] {
        func describe(_ data: Data) -> String {
            guard let value = try? JSONValue.parse(data: data) else { return "unparseable" }
            let neutral = mediaNeutral(value).canonical
            return "\(JSONHash.fnv1a64Hex(neutral)) bytes=\(neutral.utf8.count)"
        }
        return ["restore \(tag) document=\(describe(document))", "restore \(tag) model=\(describe(model))"]
    }

    /// The model as the Mac encodes it, sorted (the comparison form).
    static func encodedModel(_ project: Project) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(project)) ?? Data()
    }

    // MARK: Merge fixtures (apps/web/src/editor/core/merge/fixtures)

    struct MergeFixture {
        let name: String
        let mineWins: Bool
        let base: JSONValue
        let mine: JSONValue
        let theirs: JSONValue
    }

    static func loadMergeFixtures(_ dir: URL) -> [MergeFixture] {
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".json") }.sorted()
        return files.compactMap { file in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(file)),
                  let fixture = try? JSONValue.parse(data: data),
                  let name = fixture.get("name")?.stringValue,
                  case .bool(let mineWins)? = fixture.get("mineWins"),
                  let base = fixture.get("base"), let mine = fixture.get("mine"), let theirs = fixture.get("theirs")
            else { return nil }
            return MergeFixture(name: name, mineWins: mineWins, base: base, mine: mine, theirs: theirs)
        }
    }

    // MARK: Replay (Mac → iOS)

    static let replayName = "replay.json"

    /// One save the Mac's stub server turned into a version.
    struct Save: Codable, Equatable {
        var document: String
        var actorUID: String
        var clientKind: String
        var clientID: String?
        var source: String
        /// "push" | "upload" | "merge" | "restore"
        var checkpoint: String?
        /// The save's own change-set (`X-CC-Change`, canonical JSON) — Mac
        /// pushes send one; web saves don't (the server derives it).
        var change: String?
        /// Milliseconds since 1970.
        var at: Int64
        var restoredFrom: String?
        var mergedFrom: Int?
        /// The label it carries once the fixture is built (named later).
        var label: String?
    }

    struct Replay: Codable, Equatable {
        /// The transcript's "today" (ms) and time zone — both sides format with them.
        var now: Int64
        var timeZone: String
        var projectName: String
        var displayNames: [String: String]
        /// The Mac this history was recorded on (the replay saves as it).
        var deviceActorUID: String
        var deviceClientID: String
        var saves: [Save]
        /// project.json with the unsynced Mac edit (what the editor holds).
        var currentDocument: String
        /// The version restored in the transcript's restore section.
        var restoreVersionID: String
        /// The device's restore (and the push before it) happen at these times.
        var restoreAt: [Int64]
        /// Media files copied next to replay.json.
        var media: [String]
    }

    static func clock(_ replay: Replay) -> HistoryClock {
        .pinned(now: Date(timeIntervalSince1970: Double(replay.now) / 1000),
                timeZone: TimeZone(identifier: replay.timeZone) ?? .current)
    }

    static func checkpoint(_ raw: String?) -> ProjectVersionLog.Checkpoint? {
        raw.flatMap(ProjectVersionLog.Checkpoint.init(rawValue:))
    }
}
