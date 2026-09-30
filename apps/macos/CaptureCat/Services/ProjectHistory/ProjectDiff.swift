import Foundation

/// Change-sets (docs/project-history.md §Change-set): what changed between
/// two project.json documents, small enough for the `X-CC-Change` header and
/// composable by the API without a project model.
///
/// Twin of apps/web/src/editor/core/merge/projectDiff.ts; the golden vectors
/// lock `diff`, `compose`, the canonical JSON form and the header encoding.
nonisolated struct ChangeCounts: Equatable, Sendable {
    var added: Int
    var removed: Int
    var changed: Int
}

/// One id collection's changes, in exactly one form: exact (ids), truncated
/// (`counts` only — id lists dropped to fit the header) or `replaced` (a
/// legacy id-less or malformed collection that changed).
nonisolated struct CollectionChange: Equatable, Sendable {
    var added: [String] = []
    var removed: [String] = []
    var changed: [String: [String]] = [:]
    var counts: ChangeCounts?
    var reordered = false
    var replaced = false

    var countsValue: ChangeCounts {
        if replaced { return ChangeCounts(added: 0, removed: 0, changed: 0) }
        if let counts { return counts }
        return ChangeCounts(added: added.count, removed: removed.count, changed: changed.count)
    }

    /// Canonical shape; nil when the entry carries no change.
    func normalized() -> CollectionChange? {
        if replaced { return CollectionChange(replaced: true) }
        if let counts {
            if counts.added == 0 && counts.removed == 0 && counts.changed == 0 && !reordered { return nil }
            return CollectionChange(counts: counts, reordered: reordered)
        }
        var out = CollectionChange()
        out.added = JSONKeys.sortedUnion(added)
        out.removed = JSONKeys.sortedUnion(removed)
        for (id, fields) in changed { out.changed[id] = JSONKeys.sortedUnion(fields) }
        out.reordered = reordered
        if out.added.isEmpty && out.removed.isEmpty && out.changed.isEmpty && !out.reordered { return nil }
        return out
    }

    var json: JSONValue {
        guard let n = normalized() else { return .object(JSONObject()) }
        var o = JSONObject()
        if n.replaced { o["replaced"] = .bool(true) }
        if let c = n.counts {
            o["counts"] = .object(JSONObject([
                ("added", .number(Double(c.added))),
                ("removed", .number(Double(c.removed))),
                ("changed", .number(Double(c.changed))),
            ]))
        }
        if !n.added.isEmpty { o["added"] = .array(n.added.map { .string($0) }) }
        if !n.removed.isEmpty { o["removed"] = .array(n.removed.map { .string($0) }) }
        if !n.changed.isEmpty {
            var changed = JSONObject()
            for id in JSONKeys.sorted(n.changed.keys) { changed[id] = .array(n.changed[id]!.map { .string($0) }) }
            o["changed"] = .object(changed)
        }
        if n.reordered { o["reordered"] = .bool(true) }
        return .object(o)
    }
}

nonisolated struct ChangeSet: Equatable, Sendable {
    static let version = 1
    static let headerMaxBytes = 8192

    /// Id collections by project.json key.
    var items: [String: CollectionChange] = [:]
    /// Changed settings keys grouped by inspector tab ("other" when unknown).
    var settings: [String: [String]] = [:]
    /// Other changed root keys, sorted ("*" = the documents are not objects).
    var fields: [String] = []

    var isEmpty: Bool { items.isEmpty && settings.isEmpty && fields.isEmpty }

    var json: JSONValue {
        var itemsJSON = JSONObject()
        for key in JSONKeys.sorted(items.keys) where items[key]!.normalized() != nil {
            itemsJSON[key] = items[key]!.json
        }
        var settingsJSON = JSONObject()
        for tab in JSONKeys.sorted(settings.keys) {
            let keys = JSONKeys.sortedUnion(settings[tab]!)
            if !keys.isEmpty { settingsJSON[tab] = .array(keys.map { .string($0) }) }
        }
        return .object(JSONObject([
            ("v", .number(Double(Self.version))),
            ("items", .object(itemsJSON)),
            ("settings", .object(settingsJSON)),
            ("fields", .array(JSONKeys.sortedUnion(fields).map { .string($0) })),
        ]))
    }
}

nonisolated enum ProjectDiff {
    private static func changedKeys(_ a: JSONObject, _ b: JSONObject) -> [String] {
        JSONKeys.sortedUnionKeys(.object(a), .object(b)).filter { a[$0] != b[$0] }
    }

    static func diff(_ a: JSONValue, _ b: JSONValue, policy: MergePolicy = .standard) -> ChangeSet {
        var cs = ChangeSet()
        guard let ao = a.objectValue, let bo = b.objectValue else {
            if a != b { cs.fields = ["*"] }
            return cs
        }
        var special = Set(policy.collections.map(\.key))
        special.insert(policy.settingsKey)

        for c in policy.collections {
            let va = ao[c.key], vb = bo[c.key]
            if va == vb { continue }
            guard let A = ProjectMerge.idEntries(va), let B = ProjectMerge.idEntries(vb) else {
                cs.items[c.key] = CollectionChange(replaced: true)
                continue
            }
            let aMap = Dictionary(uniqueKeysWithValues: A.map { ($0.id, $0.value) })
            let bMap = Dictionary(uniqueKeysWithValues: B.map { ($0.id, $0.value) })
            var entry = CollectionChange()
            for id in JSONKeys.sorted(aMap.keys.filter { bMap[$0] != nil }) {
                let keys = changedKeys(aMap[id]!, bMap[id]!)
                if !keys.isEmpty { entry.changed[id] = keys }
            }
            entry.added = B.filter { aMap[$0.id] == nil }.map(\.id)
            entry.removed = A.filter { bMap[$0.id] == nil }.map(\.id)
            entry.reordered = !JSONKeys.sameSequence(
                A.filter { bMap[$0.id] != nil }.map(\.id),
                B.filter { aMap[$0.id] != nil }.map(\.id)
            )
            if let n = entry.normalized() { cs.items[c.key] = n }
        }

        var fields: [String] = []
        let sa = ao[policy.settingsKey], sb = bo[policy.settingsKey]
        if sa != sb {
            if let so = sa?.objectValue, let tb = sb?.objectValue {
                for k in changedKeys(so, tb) {
                    cs.settings[policy.settingsTab(for: k), default: []].append(k)
                }
            } else {
                fields.append(policy.settingsKey)
            }
        }
        for k in JSONKeys.sortedUnionKeys(a, b) where !special.contains(k) {
            if ao[k] != bo[k] { fields.append(k) }
        }
        cs.fields = JSONKeys.sortedUnion(fields)
        return cs
    }

    // MARK: - compose

    private enum Status {
        case added
        case removed
        case changed([String])
    }

    private static func composeCollection(_ x: CollectionChange, _ y: CollectionChange) -> CollectionChange {
        if x.replaced || y.replaced { return CollectionChange(replaced: true) }
        let reordered = x.reordered || y.reordered
        if x.counts != nil || y.counts != nil {
            let a = x.countsValue, b = y.countsValue
            return CollectionChange(
                counts: ChangeCounts(added: a.added + b.added, removed: a.removed + b.removed, changed: a.changed + b.changed),
                reordered: reordered
            )
        }
        var status: [String: Status] = [:]
        for id in x.added { status[id] = .added }
        for id in x.removed { status[id] = .removed }
        for id in JSONKeys.sorted(x.changed.keys) { status[id] = .changed(x.changed[id]!) }
        for id in y.added {
            switch status[id] {
            case .removed: status[id] = .changed([])
            case nil: status[id] = .added
            default: break
            }
        }
        for id in y.removed {
            if case .added = status[id] {
                status[id] = nil
            } else {
                status[id] = .removed
            }
        }
        for id in JSONKeys.sorted(y.changed.keys) {
            let fields = y.changed[id]!
            switch status[id] {
            case .added: continue
            case .changed(let existing): status[id] = .changed(JSONKeys.sortedUnion(existing, fields))
            default: status[id] = .changed(fields)
            }
        }
        var out = CollectionChange(reordered: reordered)
        for (id, s) in status {
            switch s {
            case .added: out.added.append(id)
            case .removed: out.removed.append(id)
            case .changed(let fields): out.changed[id] = fields
            }
        }
        return out
    }

    /// `x` (a → b) then `y` (b → c): add+change=add, add+remove=nothing,
    /// change+remove=remove, remove+add=change.
    static func compose(_ x: ChangeSet, _ y: ChangeSet) -> ChangeSet {
        var out = ChangeSet()
        for key in JSONKeys.sortedUnion(Array(x.items.keys), Array(y.items.keys)) {
            let composed: CollectionChange
            switch (x.items[key], y.items[key]) {
            case let (cx?, cy?): composed = composeCollection(cx, cy)
            case let (cx?, nil): composed = cx
            case let (nil, cy?): composed = cy
            default: continue
            }
            if let n = composed.normalized() { out.items[key] = n }
        }
        for tab in JSONKeys.sortedUnion(Array(x.settings.keys), Array(y.settings.keys)) {
            let keys = JSONKeys.sortedUnion(x.settings[tab] ?? [], y.settings[tab] ?? [])
            if !keys.isEmpty { out.settings[tab] = keys }
        }
        out.fields = JSONKeys.sortedUnion(x.fields, y.fields)
        return out
    }

    // MARK: - JSON decode

    private static func stringList(_ v: JSONValue?) -> [String]? {
        guard let v else { return [] }
        guard let items = v.arrayValue else { return nil }
        var out: [String] = []
        for item in items {
            guard let s = item.stringValue else { return nil }
            out.append(s)
        }
        return out
    }

    private static func count(_ v: JSONValue?) -> Int? {
        guard let d = v?.numberValue, d >= 0, d.rounded() == d, d <= 9_007_199_254_740_991 else { return nil }
        return Int(d)
    }

    private static func collectionChange(_ v: JSONValue) -> CollectionChange? {
        guard let o = v.objectValue else { return nil }
        if o["replaced"] == .bool(true) { return CollectionChange(replaced: true) }
        let reordered = o["reordered"] == .bool(true)
        if let countsValue = o["counts"] {
            guard let c = countsValue.objectValue,
                  let added = count(c["added"]), let removed = count(c["removed"]), let changed = count(c["changed"])
            else { return nil }
            return CollectionChange(counts: ChangeCounts(added: added, removed: removed, changed: changed), reordered: reordered)
        }
        guard let added = stringList(o["added"]), let removed = stringList(o["removed"]) else { return nil }
        var changed: [String: [String]] = [:]
        if let changedValue = o["changed"] {
            guard let co = changedValue.objectValue else { return nil }
            for id in co.keys {
                guard let fields = stringList(co[id]) else { return nil }
                changed[id] = fields
            }
        }
        return CollectionChange(added: added, removed: removed, changed: changed, reordered: reordered)
    }

    /// Parses + validates a change-set JSON value; nil when malformed.
    static func changeSet(from v: JSONValue) -> ChangeSet? {
        guard let o = v.objectValue, o["v"] == .number(Double(ChangeSet.version)) else { return nil }
        var out = ChangeSet()
        let items = o["items"] ?? .object(JSONObject())
        let settings = o["settings"] ?? .object(JSONObject())
        guard let io = items.objectValue, let so = settings.objectValue else { return nil }
        for key in JSONKeys.sorted(io.keys) {
            guard let c = collectionChange(io[key]!) else { return nil }
            if let n = c.normalized() { out.items[key] = n }
        }
        for tab in JSONKeys.sorted(so.keys) {
            guard let keys = stringList(so[tab]) else { return nil }
            if !keys.isEmpty { out.settings[tab] = JSONKeys.sortedUnion(keys) }
        }
        guard let fields = stringList(o["fields"]) else { return nil }
        out.fields = JSONKeys.sortedUnion(fields)
        return out
    }

    // MARK: - X-CC-Change header

    static func base64url(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func fromBase64url(_ text: String) -> String? {
        guard text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        guard let data = Data(base64Encoded: s) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// base64url (no padding) of the canonical JSON. Over `maxBytes`, the
    /// exact collection with the most ids (ties → first key sorted) degrades
    /// to counts, repeatedly; then settings tabs collapse to ["*"]; else nil.
    static func encodeHeader(_ cs: ChangeSet, maxBytes: Int = ChangeSet.headerMaxBytes) -> String? {
        var current = cs
        while true {
            let encoded = base64url(current.json.canonical)
            if encoded.utf8.count <= maxBytes { return encoded }
            var best: String?
            var bestSize = -1
            for key in JSONKeys.sorted(current.items.keys) {
                let c = current.items[key]!
                if c.replaced || c.counts != nil { continue }
                let size = c.added.count + c.removed.count + c.changed.count
                if size > bestSize {
                    best = key
                    bestSize = size
                }
            }
            if let best {
                let c = current.items[best]!
                current.items[best] = CollectionChange(counts: c.countsValue, reordered: c.reordered)
                continue
            }
            if current.settings.values.contains(where: { $0 != ["*"] }) {
                for tab in Array(current.settings.keys) { current.settings[tab] = ["*"] }
                continue
            }
            return nil
        }
    }

    static func decodeHeader(_ text: String) -> ChangeSet? {
        guard let json = fromBase64url(text.trimmingCharacters(in: .whitespaces)),
              let value = try? JSONValue.parse(json) else { return nil }
        return changeSet(from: value)
    }
}
