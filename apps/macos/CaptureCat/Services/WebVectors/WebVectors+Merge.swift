import Foundation

/// Project-history golden vectors (docs/project-history.md): the merge, diff,
/// compose, header and summary twins in Services/ProjectHistory against
/// apps/web/src/editor/core/merge.
///
/// - `mergePolicy`: the policy table's canonical JSON + FNV hash, canonical
///   number / string / JSON-text parity, compose, summary and header cases.
/// - `projectMerge`: every synthetic triple in
///   apps/web/src/editor/core/merge/fixtures/ — merged documents (default,
///   every conflict flipped, last writer reversed), conflicts, auto-resolved
///   logs, diffs, composed change-sets, summaries, headers. Every merged
///   output (and every input) must decode with the REAL `Project` Codable,
///   and the identity properties must hold, or the unit FAILS.
///
/// The app is sandboxed and cannot read the repo, so the fixtures are staged
/// into the container tmp first: `apps/web/scripts/merge-vectors.sh` does
/// that, runs this unit, and copies the output into the committed
/// apps/web/src/editor/core/merge/golden/. The fixtures dir is
/// `--merge-fixtures <dir>` or `NSTemporaryDirectory()/capturecat-merge-fixtures`.
extension WebVectors {
    static var mergeUnits: [WebVectorUnit] {
        [
            WebVectorUnit(
                name: "mergePolicy",
                notes: "Services/ProjectHistory: MergePolicy.standard (canonical JSON + FNV-1a hash), JSONValue canonical numbers/strings/texts, ProjectDiff.compose / encodeHeader / decodeHeader, ChangeSummary.format / countChanges on hand-built change-sets.",
                build: { MergeVectors.policyCases() }
            ),
            WebVectorUnit(
                name: "mergeRandom",
                notes: "Services/ProjectHistory: ProjectMerge.merge (+ every conflict flipped) and ProjectDiff.diff / ChangeSummary over WVRandom-generated project-shaped triples (random settings subsets, id collections incl. absent / legacy id-less, nested words, reorders, regenerations, unknown keys). Inputs are recorded; identity properties are asserted.",
                build: { MergeVectors.randomCases() }
            ),
            WebVectorUnit(
                name: "projectMerge",
                notes: "Services/ProjectHistory: ProjectMerge.merge (default, flipped choices, reversed last writer), ProjectDiff.diff / compose / encodeHeader, ChangeSummary over every staged fixture of apps/web/src/editor/core/merge/fixtures. Every merged output decodes with the real Project Codable.",
                build: { MergeVectors.fixtureCases() },
                skipReason: { MergeVectors.fixturesDirectory() == nil ? MergeVectors.stagingHelp : nil }
            ),
        ]
    }
}

enum MergeVectors {
    static let stagingHelp =
        "merge fixtures are not staged — run apps/web/scripts/merge-vectors.sh (copies apps/web/src/editor/core/merge/fixtures into the container tmp and regenerates the golden)"

    static func fixturesDirectory() -> URL? {
        let args = CommandLine.arguments
        var url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("capturecat-merge-fixtures", isDirectory: true)
        if let i = args.firstIndex(of: "--merge-fixtures"), args.indices.contains(i + 1) {
            url = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath, isDirectory: true)
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return files.contains { $0.hasSuffix(".json") } ? url : nil
    }

    // MARK: - projectMerge

    private static func str(_ v: JSONValue) -> WV { .str(v.canonical) }

    /// Structured (not string-escaped) JSON — for recorded inputs whose
    /// numbers are exact binary fractions, so no precision question arises.
    private static func plain(_ v: JSONValue) -> WV {
        switch v {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .number(let d): return .num(d)
        case .string(let s): return .str(s)
        case .array(let a): return .arr(a.map(plain))
        case .object(let o): return .obj(o.keys.map { ($0, plain(o[$0]!)) })
        }
    }

    private static func list(_ items: [JSONValue]) -> JSONValue { .array(items) }

    /// A variant whose merged document equals the default merge stores
    /// "=default" instead of repeating it (keeps the golden small).
    private static func resultWV(_ r: MergeResult, sameAs defaultMerged: JSONValue? = nil) -> WV {
        [
            "merged": defaultMerged == r.merged ? .str("=default") : str(r.merged),
            "conflicts": str(list(r.conflicts.map(\.json))),
            "autoResolved": str(list(r.autoResolved.map(\.json))),
        ]
    }

    private static func decodes(_ v: JSONValue) -> Bool {
        (try? JSONDecoder().decode(Project.self, from: Data(v.canonical.utf8))) != nil
    }

    static func fixtureHash(base: JSONValue, mine: JSONValue, theirs: JSONValue, mineWins: Bool) -> String {
        JSONHash.fnv1a64Hex(JSONValue.object(JSONObject([
            ("mineWins", .bool(mineWins)), ("base", base), ("mine", mine), ("theirs", theirs),
        ])).canonical)
    }

    static func fixtureCases() -> [WV] {
        guard let dir = fixturesDirectory() else {
            print("WEB-VECTORS FAIL projectMerge: \(stagingHelp)")
            return []
        }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".json") }
            .sorted(by: JSONKeys.less)
        var cases: [WV] = []
        var failures: [String] = []
        for file in names {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(file)),
                  let fixture = try? JSONValue.parse(data: data),
                  let name = fixture.get("name")?.stringValue,
                  case .bool(let mineWins)? = fixture.get("mineWins"),
                  let base = fixture.get("base"), let mine = fixture.get("mine"), let theirs = fixture.get("theirs")
            else {
                failures.append("\(file): unreadable fixture")
                continue
            }

            let result = ProjectMerge.merge(base: base, mine: mine, theirs: theirs, mineWins: mineWins)
            var choices: [String: MergeSide] = [:]
            var choicesJSON = JSONObject()
            for c in result.conflicts {
                choices[c.id] = c.resolution.opposite
                choicesJSON[c.id] = .string(c.resolution.opposite.rawValue)
            }
            let flipped = ProjectMerge.merge(base: base, mine: mine, theirs: theirs, mineWins: mineWins, choices: choices)
            let reversed = ProjectMerge.merge(base: base, mine: mine, theirs: theirs, mineWins: !mineWins)

            let diffMine = ProjectDiff.diff(base, mine)
            let diffTheirs = ProjectDiff.diff(base, theirs)
            let diffMerged = ProjectDiff.diff(base, result.merged)
            let composed = ProjectDiff.compose(diffMine, ProjectDiff.diff(mine, result.merged))
            let header = ProjectDiff.encodeHeader(diffMerged)
            let headerSmall = ProjectDiff.encodeHeader(diffMerged, maxBytes: 96)

            // Gates: the Mac must open every input and every merged output.
            let decodeChecks: [(String, JSONValue)] = [
                ("base", base), ("mine", mine), ("theirs", theirs),
                ("merged", result.merged), ("flipped", flipped.merged), ("reversed", reversed.merged),
            ]
            var decodesWV: [(String, WV)] = []
            for (label, value) in decodeChecks {
                let ok = decodes(value)
                decodesWV.append((label, .bool(ok)))
                if !ok { failures.append("\(name): \(label) does not decode as Project") }
            }
            // Identity properties.
            for wins in [true, false] {
                let checks: [(String, MergeResult, JSONValue)] = [
                    ("merge(b,x,b)=x", ProjectMerge.merge(base: base, mine: mine, theirs: base, mineWins: wins), mine),
                    ("merge(b,b,y)=y", ProjectMerge.merge(base: base, mine: base, theirs: theirs, mineWins: wins), theirs),
                    ("merge(b,x,x)=x", ProjectMerge.merge(base: base, mine: mine, theirs: mine, mineWins: wins), mine),
                ]
                for (label, r, expected) in checks
                where r.merged != expected || !r.conflicts.isEmpty || !r.autoResolved.isEmpty {
                    failures.append("\(name): \(label) fails (mineWins=\(wins))")
                }
            }
            if let header, ProjectDiff.decodeHeader(header) != diffMerged {
                failures.append("\(name): header does not round-trip")
            }

            cases.append(WebVectors.vcase(
                [
                    "fixture": .str(name),
                    "fixtureHash": .str(fixtureHash(base: base, mine: mine, theirs: theirs, mineWins: mineWins)),
                    "mineWins": .bool(mineWins),
                ],
                [
                    "default": resultWV(result),
                    "flippedChoices": str(.object(choicesJSON)),
                    "flipped": resultWV(flipped, sameAs: result.merged),
                    "reversed": resultWV(reversed, sameAs: result.merged),
                    "diffMine": str(diffMine.json),
                    "diffTheirs": str(diffTheirs.json),
                    "diffMerged": str(diffMerged.json),
                    "composed": str(composed.json),
                    "summaryMine": .str(ChangeSummary.format(diffMine)),
                    "summaryTheirs": .str(ChangeSummary.format(diffTheirs)),
                    "summaryMerged": .str(ChangeSummary.format(diffMerged)),
                    "summaryMergedShort": .str(ChangeSummary.format(diffMerged, maxParts: 1)),
                    "summaryComposed": .str(ChangeSummary.format(composed)),
                    "countMerged": .int(ChangeSummary.countChanges(diffMerged)),
                    "header": header.map { WV.str($0) } ?? .null,
                    "headerSmall": headerSmall.map { WV.str($0) } ?? .null,
                    "decodes": .obj(decodesWV),
                ]
            ))
        }
        if !failures.isEmpty {
            for f in failures { print("WEB-VECTORS FAIL projectMerge: \(f)") }
            return []
        }
        return cases
    }

    // MARK: - mergeRandom

    private static let randomCollections = [
        "zoomRegions", "tiltRegions", "blurRegions", "highlightRegions", "focusRegions",
        "cameraLayoutRegions", "annotations", "voiceOverClips", "speedRegions", "subtitles",
    ]
    private static let randomSettings = [
        "backgroundType", "backgroundPadding", "videoPlacement", "videoCustomX", "videoCustomY", "cursorScale",
        "cameraPosition", "cameraCustomX", "introSlideStyle", "introSlideStart", "subtitleFontSize",
        "gradientStartColor", "exportSettings", "aspectRatio", "futureSettingA",
    ]

    private static func randomScalar(_ rng: inout WVRandom) -> JSONValue {
        switch rng.int(0, 5) {
        case 0: return .number(Double(rng.int(-50, 50)) / 4)
        case 1: return .bool(rng.bool())
        case 2: return .string(rng.pick(["Gradient", "Solid Color", "Left", "Top", "é🎬", ""]))
        case 3: return .null
        case 4:
            return .object(JSONObject([
                ("red", .number(Double(rng.int(0, 8)) / 8)), ("green", .number(0.5)),
                ("blue", .number(1)), ("opacity", .number(1)),
            ]))
        default: return .array([.number(Double(rng.int(0, 3))), .number(Double(rng.int(0, 3)))])
        }
    }

    /// Short random ids keep the recorded inputs small (the merge only needs
    /// non-empty strings; a rare collision just exercises the legacy path).
    private static func shortID(_ rng: inout WVRandom) -> String {
        "r" + String(rng.next() % 2_176_782_336, radix: 36)
    }

    private static func randomElement(_ rng: inout WVRandom, _ collection: String) -> JSONValue {
        let start = Double(rng.int(0, 40)) / 2
        var e = JSONObject([
            ("id", .string(shortID(&rng))),
            ("startTime", .number(start)),
            ("endTime", .number(start + Double(rng.int(1, 8)) / 2)),
        ])
        if rng.bool() { e["label"] = .string(rng.pick(["a", "b", "c"])) }
        if rng.bool(0.3) { e["futureElementKey"] = randomScalar(&rng) }
        if collection == "subtitles" {
            e["text"] = .string("caption")
            e["words"] = .array((0..<rng.int(0, 2)).map { _ in randomElement(&rng, "words") })
        }
        if collection == "voiceOverClips" { e["duration"] = .number(Double(rng.int(1, 6))) }
        return .object(e)
    }

    private static func randomDoc(_ rng: inout WVRandom) -> JSONObject {
        var settings = JSONObject()
        for k in randomSettings where rng.bool(0.5) { settings[k] = randomScalar(&rng) }
        var doc = JSONObject([
            ("id", .string("F0000000-0000-4000-8000-000000000000")), ("name", .string("doc")),
            ("settings", .object(settings)), ("duration", .number(30)),
        ])
        for c in randomCollections {
            if rng.bool(0.25) { continue }
            doc[c] = .array((0..<rng.int(0, 3)).map { _ in randomElement(&rng, c) })
        }
        if rng.bool(0.2) {
            doc["cameraLayoutRegions"] = .array([.object(JSONObject([
                ("startTime", .number(0)), ("endTime", .number(2)), ("mode", .string("cameraOnly")),
            ]))])
        }
        if rng.bool(0.4) { doc["futureRoot"] = .object(JSONObject([("nested", randomScalar(&rng))])) }
        doc["trimEnd"] = .number(rng.pick([0, 20, 25]))
        doc["videoClipSegments"] = .array([.object(JSONObject([
            ("id", .string(shortID(&rng))), ("startTime", .number(0)), ("endTime", .number(30)),
        ]))])
        return doc
    }

    /// Edits biased toward a per-case "hot" collection and settings subset,
    /// so mine and theirs clash (auto-resolutions, conflicts, lane overlaps).
    private static func randomMutation(
        _ doc: JSONObject, hot: String, hotSettings: [String], _ rng: inout WVRandom
    ) -> JSONObject {
        var out = doc
        for _ in 0..<rng.int(2, 7) {
            let kind = rng.pick([0, 0, 0, 0, 4, 4, 4, 4, 4, 2, 2, 3, 5, 6, 7, 8, 9, 10, 11])
            var settings = out["settings"]?.objectValue ?? JSONObject()
            let coll = rng.bool(0.7) ? hot : rng.pick(randomCollections)
            let settingKey = rng.bool(0.6) ? rng.pick(hotSettings) : rng.pick(randomSettings)
            var arr = out[coll]?.arrayValue
            switch kind {
            case 0: settings[settingKey] = randomScalar(&rng)
            case 1: settings[settingKey] = nil
            case 2: arr = (arr ?? []) + [randomElement(&rng, coll)]
            case 3: if let a = arr, !a.isEmpty { arr!.remove(at: rng.int(0, a.count - 1)) }
            case 4:
                if let a = arr, !a.isEmpty {
                    let i = rng.bool(0.8) ? 0 : rng.int(0, a.count - 1)
                    if var e = a[i].objectValue {
                        let field = rng.pick(["startTime", "endTime", "label", "futureElementKey"])
                        e[field] = field.hasSuffix("Time") ? .number(Double(rng.int(0, 40)) / 2) : randomScalar(&rng)
                        arr![i] = .object(e)
                    }
                }
            case 5: if let a = arr, a.count > 1 { arr = Array(a.dropFirst()) + [a[0]] }
            case 6: out["futureRoot\(rng.int(0, 2))"] = randomScalar(&rng)
            case 7: out["name"] = .string("renamed \(rng.int(0, 9))")
            case 8: out["trimEnd"] = .number(Double(rng.int(10, 30)))
            case 9:
                if coll == "subtitles", let a = arr, !a.isEmpty, var s = a[0].objectValue {
                    var words = s["words"]?.arrayValue ?? []
                    if !words.isEmpty, var w = words[0].objectValue {
                        w["text"] = .string("w\(rng.int(0, 9))")
                        words[0] = .object(w)
                    } else {
                        words = [randomElement(&rng, "words")]
                    }
                    s["words"] = .array(words)
                    arr![0] = .object(s)
                }
            case 10: if coll == "subtitles", arr != nil { arr = [randomElement(&rng, "subtitles")] }
            default:
                let key = rng.pick(["futureRoot", "duration", coll])
                out[key] = nil
                if key == coll { arr = nil }
            }
            out["settings"] = .object(settings)
            if let arr { out[coll] = .array(arr) }
        }
        return out
    }

    static func randomCases() -> [WV] {
        var rng = WVRandom(seed: "mergeRandom")
        var cases: [WV] = []
        var failures: [String] = []
        for i in 0..<32 {
            let base = randomDoc(&rng)
            let hot = rng.pick(randomCollections)
            let hotSettings = [rng.pick(randomSettings)]
            let mine = randomMutation(base, hot: hot, hotSettings: hotSettings, &rng)
            let theirs = randomMutation(base, hot: hot, hotSettings: hotSettings, &rng)
            let mineWins = rng.bool()
            let (b, m, t) = (JSONValue.object(base), JSONValue.object(mine), JSONValue.object(theirs))
            let result = ProjectMerge.merge(base: b, mine: m, theirs: t, mineWins: mineWins)
            var choices: [String: MergeSide] = [:]
            for c in result.conflicts { choices[c.id] = c.resolution.opposite }
            let flipped = ProjectMerge.merge(base: b, mine: m, theirs: t, mineWins: mineWins, choices: choices)
            for (label, r, expected) in [
                ("merge(b,x,b)=x", ProjectMerge.merge(base: b, mine: m, theirs: b, mineWins: mineWins), m),
                ("merge(b,b,y)=y", ProjectMerge.merge(base: b, mine: b, theirs: t, mineWins: mineWins), t),
                ("merge(b,x,x)=x", ProjectMerge.merge(base: b, mine: m, theirs: m, mineWins: mineWins), m),
            ] where r.merged != expected || !r.conflicts.isEmpty || !r.autoResolved.isEmpty {
                failures.append("random #\(i): \(label)")
            }
            let diffMerged = ProjectDiff.diff(b, result.merged)
            cases.append(WebVectors.vcase(
                ["base": plain(b), "mine": plain(m), "theirs": plain(t), "mineWins": .bool(mineWins)],
                [
                    "default": resultWV(result),
                    "flipped": resultWV(flipped, sameAs: result.merged),
                    "diffMerged": str(diffMerged.json),
                    "summaryMerged": .str(ChangeSummary.format(diffMerged)),
                ]
            ))
        }
        if !failures.isEmpty {
            for f in failures { print("WEB-VECTORS FAIL mergeRandom: \(f)") }
            return []
        }
        return cases
    }

    // MARK: - mergePolicy

    static func policyCases() -> [WV] {
        var cases: [WV] = []
        let policy = MergePolicy.standard
        cases.append(WebVectors.vcase(
            ["case": "policy"],
            ["policyJSON": .str(policy.json.canonical), "policyHash": .str(policy.hash)]
        ))

        for d in numberInputs() {
            cases.append(WebVectors.vcase(["case": "number", "value": .num(d)], ["canonical": .str(JSONValue.canonicalNumber(d))]))
        }
        for s in stringInputs {
            cases.append(WebVectors.vcase(["case": "string", "value": .str(s)], ["canonical": .str(JSONValue.canonicalString(s))]))
        }
        for text in jsonTexts {
            guard let v = try? JSONValue.parse(text) else {
                print("WEB-VECTORS FAIL mergePolicy: vector text does not parse: \(text)")
                return []
            }
            cases.append(WebVectors.vcase(
                ["case": "json", "text": .str(text)],
                ["canonical": .str(v.canonical), "hash": .str(JSONHash.fnv1a64Hex(v.canonical))]
            ))
        }

        for (x, y) in composePairs() {
            let composed = ProjectDiff.compose(x, y)
            cases.append(WebVectors.vcase(
                ["case": "compose", "x": str(x.json), "y": str(y.json)],
                [
                    "composed": str(composed.json),
                    "summary": .str(ChangeSummary.format(composed)),
                    "count": .int(ChangeSummary.countChanges(composed)),
                ]
            ))
        }

        for cs in summarySets() {
            for maxParts in [0, 2, 3] {
                cases.append(WebVectors.vcase(
                    ["case": "summary", "changeSet": str(cs.json), "maxParts": .int(maxParts)],
                    ["summary": .str(ChangeSummary.format(cs, maxParts: maxParts)), "count": .int(ChangeSummary.countChanges(cs))]
                ))
            }
        }

        var headers: [String] = []
        for (cs, maxBytes) in headerSets() {
            let header = ProjectDiff.encodeHeader(cs, maxBytes: maxBytes)
            if let header { headers.append(header) }
            cases.append(WebVectors.vcase(
                ["case": "header", "changeSet": str(cs.json), "maxBytes": .int(maxBytes)],
                [
                    "header": header.map { WV.str($0) } ?? .null,
                    "decoded": header.flatMap { ProjectDiff.decodeHeader($0) }.map { str($0.json) } ?? .null,
                ]
            ))
        }
        let malformed = [
            "", "!!!", "e30", ProjectDiff.base64url("{\"v\":2}"), ProjectDiff.base64url("{\"v\":1}") + "=",
            ProjectDiff.base64url("{\"v\":1,\"items\":{\"zoomRegions\":{\"added\":[1]}}}"),
            ProjectDiff.base64url("{\"v\":1,\"items\":{},\"settings\":{},\"fields\":[],\"future\":true}"),
            ProjectDiff.base64url("{\"v\":1,\"items\":{\"x\":{\"counts\":{\"added\":1.5,\"removed\":0,\"changed\":0}}}}"),
            ProjectDiff.base64url("{\"v\":1,\"fields\":[\"b\",\"a\",\"a\"],\"items\":{\"zoomRegions\":{\"added\":[\"B\",\"A\"],\"changed\":{\"C\":[]}}}}"),
        ]
        for text in Array(headers.prefix(3)) + malformed {
            cases.append(WebVectors.vcase(
                ["case": "decodeHeader", "header": .str(text)],
                ["decoded": ProjectDiff.decodeHeader(text).map { str($0.json) } ?? .null]
            ))
        }
        return cases
    }

    private static func numberInputs() -> [Double] {
        var values: [Double] = [
            0, -0.0, 1, -1, 0.1, 0.2, 0.1 + 0.2, 1.0 / 3.0, 2.0 / 3.0, 100, 12.5, 4.35, 0.3, 1234.5678,
            1e21, 1e20, 9.999999999999999e20, Double("123456789012345680000")!, 1e16, 1e15, Double("12345678901234567890")!,
            Double("9007199254740993")!, 1e-6, 1e-7, 1.5e-7, 0.000001234, -1.5e-10, 5e-324, 2.2250738585072014e-308,
            1.7976931348623157e308, 0.02, 0.0001, 780000000, 1920, 0.85, 0.55, 29.999999999999996,
        ]
        var rng = WVRandom(seed: "mergePolicy.numbers")
        for _ in 0..<120 {
            let mantissa = rng.double(-1, 1)
            let exponent = rng.int(-30, 30)
            values.append(mantissa * pow(10, Double(exponent)))
        }
        for _ in 0..<40 { values.append(Double(rng.int(-1_000_000, 1_000_000)) / Double(rng.pick([1, 2, 3, 7, 10, 100, 1000]))) }
        return values
    }

    private static let stringInputs: [String] = [
        "", "plain", "quote\"back\\slash/", "\n\r\t\u{08}\u{0C}", "\u{01}\u{1F}\u{7F}", "é ü 中文",
        "🎬 take 2", "\u{2028}\u{2029}", "</script>", "tab\tin\u{00}middle",
    ]

    private static let jsonTexts: [String] = [
        "{\"b\":1,\"a\":[1,2,{\"d\":null,\"c\":true}],\"é\":\"x\",\"Z\":0.5,\"a1\":{\"z\":{}},\"10\":1,\"9\":2}",
        "[]", "\"x\"", "1e-7", "null", "-0", "1E+2",
        "{\"a\":{\"b\":{\"c\":[1.0,2.50,-3e2,0.000001,123456789012345678901234567890]}}}",
        "{\"s\":\"\\u00e9\\ud83c\\udfac\\n\\\"\\\\\\/\",\"t\":\"\\u0001\"}",
        "{ \"spaced\" : [ true , false , null ] , \"dup\" : 1 , \"dup\" : 2 }",
    ]

    // MARK: Hand-built change-sets

    private static func ids(_ prefix: String, _ n: Int) -> [String] {
        (1...n).map { String(format: "\(prefix)000000-0000-4000-8000-%012ld", $0) }
    }

    private static func composePairs() -> [(ChangeSet, ChangeSet)] {
        let z = ids("21", 6)
        var x1 = ChangeSet()
        x1.items["zoomRegions"] = CollectionChange(added: [z[0], z[1]], removed: [z[2]], changed: [z[3]: ["zoomLevel"], z[4]: ["startTime"]])
        x1.settings["background"] = ["backgroundPadding"]
        x1.fields = ["name"]
        var y1 = ChangeSet()
        // add+change=add, add+remove=nothing, remove+add=change, change+change=union, change+remove=remove
        y1.items["zoomRegions"] = CollectionChange(
            added: [z[2]], removed: [z[1], z[4]], changed: [z[0]: ["focalPoint"], z[3]: ["animationStyle"], z[5]: ["zoomLevel"]]
        )
        y1.settings["background"] = ["cornerRadius"]
        y1.settings["cursor"] = ["cursorScale"]
        y1.fields = ["trimEnd"]

        var x2 = ChangeSet()
        x2.items["subtitles"] = CollectionChange(counts: ChangeCounts(added: 40, removed: 38, changed: 0))
        x2.items["cameraLayoutRegions"] = CollectionChange(replaced: true)
        x2.items["annotations"] = CollectionChange(reordered: true)
        var y2 = ChangeSet()
        y2.items["subtitles"] = CollectionChange(changed: [ids("2A", 1)[0]: ["text"]])
        y2.items["cameraLayoutRegions"] = CollectionChange(added: ids("26", 1))
        y2.items["annotations"] = CollectionChange(changed: [ids("27", 1)[0]: ["text"]])

        var x3 = ChangeSet()
        x3.items["blurRegions"] = CollectionChange(added: ids("23", 2))
        var y3 = ChangeSet()
        y3.items["blurRegions"] = CollectionChange(removed: ids("23", 2))
        y3.items["futureRegions"] = CollectionChange(added: ["F1"])
        y3.settings["other"] = ["futureSetting"]

        return [(x1, y1), (y1, x1), (x2, y2), (x3, y3), (ChangeSet(), x1), (x1, ChangeSet())]
    }

    private static func summarySets() -> [ChangeSet] {
        var all = ChangeSet()
        all.fields = ["splitPoints", "trimStart", "videoURL", "name", "stillTreatment", "reminderDate", "id", "futureKey"]
        all.items["zoomRegions"] = CollectionChange(added: ids("21", 1), removed: ids("21", 3), changed: [ids("21", 4)[3]: ["zoomLevel"]])
        all.items["tiltRegions"] = CollectionChange(counts: ChangeCounts(added: 0, removed: 2, changed: 1), reordered: true)
        all.items["speedRegions"] = CollectionChange(added: ids("29", 2))
        all.items["blurRegions"] = CollectionChange(changed: [ids("23", 1)[0]: ["rectX"]])
        all.items["highlightRegions"] = CollectionChange(removed: ids("24", 1))
        all.items["focusRegions"] = CollectionChange(added: ids("25", 3))
        all.items["cameraLayoutRegions"] = CollectionChange(replaced: true)
        all.items["annotations"] = CollectionChange(reordered: true)
        all.items["voiceOverClips"] = CollectionChange(added: ids("28", 1))
        all.items["subtitles"] = CollectionChange(changed: Dictionary(uniqueKeysWithValues: ids("2A", 3).map { ($0, ["text"]) }))
        for tab in ["background", "cursor", "camera", "audio", "effects", "motion", "subtitles", "brand", "canvas", "export", "other", "future"] {
            all.settings[tab] = ["k"]
        }

        var captions = ChangeSet()
        captions.items["zoomRegions"] = CollectionChange(added: ids("21", 1))
        captions.settings["background"] = ["backgroundType"]
        captions.items["subtitles"] = CollectionChange(changed: Dictionary(uniqueKeysWithValues: ids("2A", 3).map { ($0, ["text"]) }))

        var unknownItem = ChangeSet()
        unknownItem.items["futureRegions"] = CollectionChange(added: ["F1", "F2"])

        var recording = ChangeSet()
        recording.fields = ["cameraTimeOffset", "trimEnd", "videoClipSegments"]

        var settingsOnly = ChangeSet()
        settingsOnly.settings["future"] = ["x"]
        settingsOnly.settings["other"] = ["y"]

        return [ChangeSet(), all, captions, unknownItem, recording, settingsOnly]
    }

    private static func headerSets() -> [(ChangeSet, Int)] {
        var rng = WVRandom(seed: "mergePolicy.headers")
        var big = ChangeSet()
        big.items["subtitles"] = CollectionChange(
            added: (0..<48).map { _ in rng.uuid().uuidString },
            removed: (0..<40).map { _ in rng.uuid().uuidString }
        )
        big.items["zoomRegions"] = CollectionChange(
            added: (0..<6).map { _ in rng.uuid().uuidString },
            changed: Dictionary(uniqueKeysWithValues: (0..<8).map { _ in (rng.uuid().uuidString, ["zoomLevel", "startTime"]) }),
            reordered: true
        )
        big.items["annotations"] = CollectionChange(changed: [rng.uuid().uuidString: ["text"]])
        big.settings["background"] = ["backgroundPadding", "cornerRadius", "shadowRadius"]
        big.settings["cursor"] = ["cursorScale"]
        big.fields = ["name"]

        var small = ChangeSet()
        small.items["zoomRegions"] = CollectionChange(added: ids("21", 2))
        small.settings["background"] = ["backgroundPadding"]

        return [
            (big, ChangeSet.headerMaxBytes), (big, 2048), (big, 500), (big, 200), (big, 40),
            (small, ChangeSet.headerMaxBytes), (small, 120), (ChangeSet(), 10), (ChangeSet(), 60),
        ]
    }
}
