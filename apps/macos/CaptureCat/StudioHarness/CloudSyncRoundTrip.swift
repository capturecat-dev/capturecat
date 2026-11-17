import CoreGraphics
import Foundation

/// The Mac ↔ iOS round trip of `apps/ios/scripts/ios-cloud-sync.sh` (Studio
/// Phase 5): ONE cloud (a `StubCloudServer` persisted in `<dir>/cloud`)
/// handed between the REAL Mac binary (`CaptureCat --cloud-sync-roundtrip
/// <dir> --step 1|3|5`, the Mac's own sync engine on a Mac project folder)
/// and the iOS studio (StudioLab `--ios-cloud-sync-roundtrip <dir> --step
/// 2|4`, the shipping editor and `StudioCloudSync`):
///
///   1 Mac   makes a project (a real movie, cursor data, a key from a newer
///           build) and pushes it                                  → rev 1
///   2 iOS   opens it (clone), edits padding + adds a text annotation in
///           the editor; the autosave pushes                        → rev 2
///   3 Mac   pulls (byte-exact, its Codable reads the iOS edits), then
///           renames, re-words the annotation, sets corner radius 30 → rev 3
///   4 iOS   had edited OFFLINE meanwhile (padding 72, corner radius 5,
///           the annotation deleted): opening pulls → three-way merge →
///           Merge Review (delete vs modify) → Mine → merged, pushed → rev 4
///   5 Mac   pulls: the Mac's rename survived, the iOS edits arrived, the
///           later corner radius (iOS) won — and the Mac binary re-merges
///           iOS's triple itself: identical result (merges as the Mac merges)
@MainActor
enum CloudSyncRoundTrip {
    static let apiBase = "https://api.stub.test"

    static func cloudDir(_ dir: URL) -> URL { dir.appendingPathComponent("cloud", isDirectory: true) }

    static func projectID(_ dir: URL) -> UUID? {
        (try? Data(contentsOf: dir.appendingPathComponent("roundtrip.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { $0["projectID"] as? String }
            .flatMap(UUID.init(uuidString:))
    }

    /// A small real H.264 movie (decodable by the editor's player).
    static func writeMovie(to url: URL, seconds: TimeInterval = 2) async throws {
        let width = 320, height = 180
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(CGColor(red: 0.12, green: 0.18, blue: 0.32, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for i in 0..<8 {
            ctx.setFillColor(CGColor(red: 0.9, green: 0.5 + Double(i) * 0.05, blue: 0.2, alpha: 1))
            ctx.fill(CGRect(x: i * 40, y: 0, width: 20, height: height))
        }
        guard let image = ctx.makeImage() else { return }
        _ = try await StillMovieWriter.write(image: image, to: url, duration: seconds)
    }

    static func decode(_ data: Data) -> Project? { try? JSONDecoder().decode(Project.self, from: data) }

    static func object(_ data: Data?) -> [String: Any]? {
        data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    // MARK: - The Mac's steps

    static func macStep(_ step: Int, dir: URL, checks: CloudSyncHarness.Checks) async throws {
        let expect = checks.expect
        let fm = FileManager.default
        switch step {
        case 1:
            print("round trip 1 (Mac): make a project and push it")
            let id = UUID()
            let projectDir = dir.appendingPathComponent("mac/Projects/\(id.uuidString)", isDirectory: true)
            try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)
            try await writeMovie(to: projectDir.appendingPathComponent("recording.mp4"))
            try Data(#"{"events":[{"t":0.4,"x":0.5,"y":0.5}]}"#.utf8).write(to: projectDir.appendingPathComponent("cursor.json"))
            let project = Project(id: id, name: "Round Trip", videoURL: projectDir.appendingPathComponent("recording.mp4"),
                                  cursorDataURL: projectDir.appendingPathComponent("cursor.json"), duration: 2)
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            var object = object(try encoder.encode(project)) ?? [:]
            object["futureKey"] = ["from": "a newer build"]
            try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
                .write(to: projectDir.appendingPathComponent("project.json"))
            let server = StubCloudServer(ownerUID: "stub-owner")
            let sync = CloudProjectSync(transport: server, apiBaseURL: apiBase, clientID: "mac-roundtrip")
            let outcome = try await sync.push(project: project, projectDirectory: projectDir)
            expect(outcome == .pushed(revision: 1), "the Mac pushes the project → revision 1 (got \(outcome))")
            expect(server.committedPaths == ["recording.mp4", "cursor.json"],
                   "the recording and cursor data are in the cloud (\(server.committedPaths.sorted()))")
            try server.save(to: cloudDir(dir))
            try JSONSerialization.data(withJSONObject: ["projectID": id.uuidString, "macDir": projectDir.path])
                .write(to: dir.appendingPathComponent("roundtrip.json"))
        case 3, 5:
            guard let id = projectID(dir) else { expect(false, "round trip state exists"); return }
            let projectDir = dir.appendingPathComponent("mac/Projects/\(id.uuidString)", isDirectory: true)
            let docURL = projectDir.appendingPathComponent("project.json")
            let server = try StubCloudServer.load(from: cloudDir(dir))
            let sync = CloudProjectSync(transport: server, apiBaseURL: apiBase, clientID: "mac-roundtrip")
            if step == 3 {
                print("round trip 3 (Mac): pull the iPad's edit, then edit on the Mac")
                let pulled = try await sync.pull(projectID: id, projectDirectory: projectDir)
                expect(pulled == .pulled(revision: 2), "the Mac pulls the iOS edit → revision 2 (got \(pulled))")
                let disk = try Data(contentsOf: docURL)
                let a = object(disk) ?? [:], b = object(server.document) ?? [:]
                let differing = Set(a.keys).union(b.keys).filter { (a[$0] as? NSObject) != (b[$0] as? NSObject) }.sorted()
                // A pull spells media as THIS Mac's copies (validatedDocument);
                // every other key is iOS's document exactly.
                let media: Set<String> = ["videoURL", "cursorDataURL", "keystrokeDataURL", "cameraVideoURL"]
                let repointed = (a["videoURL"] as? String).flatMap(URL.init(string:))?.path
                    == projectDir.appendingPathComponent("recording.mp4").path
                expect(Set(differing).isSubset(of: media) && repointed,
                       "the Mac holds iOS's document exactly, but for the media references re-pointed at its own copies (\(differing))")
                let project = decode(disk)
                expect(project?.settings.backgroundPadding == 64 && project?.annotations.first?.text == "From iOS",
                       "the Mac's Codable reads the iOS edits (padding 64, the “From iOS” annotation)")
                expect(object(disk)?["futureKey"] != nil, "a key neither app knows survived iOS's edit and push")
                expect(project?.videoURL?.path == projectDir.appendingPathComponent("recording.mp4").path,
                       "the recording still resolves to the Mac's own copy")
                // The Mac editor's save: through its Codable (ProjectStore).
                guard let edited = project else { return }
                edited.name = "Renamed on the Mac"
                if !edited.annotations.isEmpty { edited.annotations[0].text = "Edited on the Mac" }
                edited.settings.cornerRadius = 30
                let encoder = JSONEncoder()
                encoder.outputFormatting = .prettyPrinted
                try encoder.encode(edited).write(to: docURL, options: .atomic)
                let pushed = try await sync.push(project: edited, projectDirectory: projectDir)
                expect(pushed == .pushed(revision: 3), "the Mac's edit pushes → revision 3 (got \(pushed))")
                try server.save(to: cloudDir(dir))
            } else {
                print("round trip 5 (Mac): pull the merge iOS made")
                let pulled = try await sync.pull(projectID: id, projectDirectory: projectDir)
                expect(pulled == .pulled(revision: 4), "the Mac pulls iOS's merge → revision 4 (got \(pulled))")
                let disk = try Data(contentsOf: docURL)
                let project = decode(disk)
                expect(project?.name == "Renamed on the Mac", "the Mac's rename survived iOS's merge")
                expect(project?.settings.backgroundPadding == 72, "iOS's offline padding edit arrived (72)")
                expect(project?.settings.cornerRadius == 5,
                       "the corner radius both edited went to the later writer — iOS (5)")
                expect(project?.annotations.isEmpty == true,
                       "the annotation iOS deleted (Mine in Merge Review) is gone on the Mac too")
                // Merge parity: the Mac binary re-merges iOS's exact triple.
                guard let record = object(try? Data(contentsOf: dir.appendingPathComponent("merge-ios.json"))),
                      let base = (record["base"] as? String).flatMap({ try? JSONValue.parse($0) }),
                      let mine = (record["mine"] as? String).flatMap({ try? JSONValue.parse($0) }),
                      let theirs = (record["theirs"] as? String).flatMap({ try? JSONValue.parse($0) }),
                      let merged = record["merged"] as? String,
                      let mineWins = record["mineWins"] as? Bool else {
                    expect(false, "iOS recorded its merge (merge-ios.json)")
                    return
                }
                let choices = (record["choices"] as? [String: String] ?? [:])
                    .compactMapValues { $0 == "mine" ? MergeSide.mine : $0 == "theirs" ? MergeSide.theirs : nil }
                let mac = ProjectMerge.merge(base: base, mine: mine, theirs: theirs, mineWins: mineWins, choices: choices)
                expect(mac.merged.canonical == merged,
                       "the Mac merges iOS's triple to the same document, byte for byte (\(mac.conflicts.count) conflict(s), \(mac.autoResolved.count) auto-resolved)")
                // Media references are each device's own paths (re-pointed on
                // every pull, the clone rule) — everything else is the merge.
                func strip(_ data: Data?) -> NSDictionary? {
                    guard var object = object(data) else { return nil }
                    for key in ["videoURL", "cursorDataURL", "keystrokeDataURL", "cameraVideoURL"] { object[key] = nil }
                    return object as NSDictionary
                }
                let held = strip(disk), mergedDoc = strip(Data(merged.utf8))
                expect(held != nil && held == mergedDoc, "…and that is the document the Mac now holds (media paths aside)")
            }
        default:
            expect(false, "unknown Mac step \(step)")
        }
    }
}
