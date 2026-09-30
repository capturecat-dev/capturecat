import Foundation

/// `ProjectMerge.merge(base:mine:theirs:mineWins:choices:)` — the three-way
/// project merge (docs/project-history.md §Merge). Pure and clock-free:
/// `mineWins` (last local edit vs the server's updated_at, ties → theirs) is
/// decided by the caller.
///
/// Twin of apps/web/src/editor/core/merge/{jsonMerge,projectMerge}.ts, line
/// for line; the `projectMerge` golden vectors (`--web-vectors`) require the
/// TypeScript to reproduce every merged document, conflict list and
/// auto-resolution log exactly (canonical JSON).
nonisolated enum MergeSide: String, Sendable {
    case mine
    case theirs

    var opposite: MergeSide { self == .mine ? .theirs : .mine }
}

/// A same-field (or same-group, or order) clash settled by the last writer.
nonisolated struct MergeAutoResolved: Equatable, Sendable {
    var path: String
    /// "field" | "group" | "order"
    var kind: String
    var winner: MergeSide

    var json: JSONValue {
        .object(JSONObject([("path", .string(path)), ("kind", .string(kind)), ("winner", .string(winner.rawValue))]))
    }
}

/// A structural clash the user reviews. The merged document already applies
/// `resolution`; re-merging with `choices[id]` flips it.
nonisolated struct MergeConflict: Equatable, Sendable {
    /// `"\(kind):\(path)"` — stable across re-merges with different choices.
    var id: String
    /// "deleteVsModify" | "clipStructure" | "subtitlesRegenerated" | "laneOverlap"
    var kind: String
    var path: String
    var resolution: MergeSide
    var defaultResolution: MergeSide
    var deletedBy: MergeSide?
    /// "mine" | "theirs" | "both"
    var regeneratedBy: String?
    var lane: String?
    var elements: [String]?

    var json: JSONValue {
        var o = JSONObject([
            ("id", .string(id)),
            ("kind", .string(kind)),
            ("path", .string(path)),
            ("resolution", .string(resolution.rawValue)),
            ("defaultResolution", .string(defaultResolution.rawValue)),
        ])
        if let deletedBy { o["deletedBy"] = .string(deletedBy.rawValue) }
        if let regeneratedBy { o["regeneratedBy"] = .string(regeneratedBy) }
        if let lane { o["lane"] = .string(lane) }
        if let elements { o["elements"] = .array(elements.map { .string($0) }) }
        return .object(o)
    }
}

nonisolated struct MergeResult: Sendable {
    var merged: JSONValue
    var conflicts: [MergeConflict]
    var autoResolved: [MergeAutoResolved]
}

nonisolated final class MergeContext {
    let mineWins: Bool
    let choices: [String: MergeSide]
    var conflicts: [MergeConflict] = []
    var autoResolved: [MergeAutoResolved] = []

    init(mineWins: Bool, choices: [String: MergeSide]) {
        self.mineWins = mineWins
        self.choices = choices
    }

    var lastWriter: MergeSide { mineWins ? .mine : .theirs }

    /// The caller's choice for a conflict id, else the last writer.
    func decide(_ id: String) -> MergeSide { choices[id] ?? lastWriter }
}

nonisolated enum ProjectMerge {
    static func merge(
        base: JSONValue,
        mine: JSONValue,
        theirs: JSONValue,
        mineWins: Bool,
        choices: [String: MergeSide] = [:],
        policy: MergePolicy = .standard
    ) -> MergeResult {
        let ctx = MergeContext(mineWins: mineWins, choices: choices)
        let merged: JSONValue?
        if mine == theirs {
            merged = mine
        } else if mine == base {
            merged = theirs
        } else if theirs == base {
            merged = mine
        } else if let m = mine.objectValue, let t = theirs.objectValue {
            let root = mergeObject(base.objectValue, m, t, path: "", spec: rootSpec(policy), ctx: ctx)
            merged = .object(resolveLaneOverlaps(root, mine: m, theirs: t, policy: policy, ctx: ctx))
        } else {
            merged = threeWay(base, mine, theirs, path: "", ctx: ctx)
        }
        return MergeResult(merged: merged ?? .null, conflicts: ctx.conflicts, autoResolved: ctx.autoResolved)
    }

    // MARK: - Paths

    static func joinPath(_ base: String, _ key: String) -> String {
        base.isEmpty ? key : "\(base).\(key)"
    }

    static func elementPath(_ collectionPath: String, _ id: String) -> String {
        "\(collectionPath)[\(id)]"
    }

    static func groupPath(_ base: String, _ keys: [String]) -> String {
        joinPath(base, "{\(keys.joined(separator: ","))}")
    }

    // MARK: - Generic three-way

    /// One side changed → that side; both identically → it; both differently
    /// → the last writer, logged. nil = absent key.
    static func threeWay(_ b: JSONValue?, _ m: JSONValue?, _ t: JSONValue?, path: String, ctx: MergeContext) -> JSONValue? {
        if m == t { return m }
        if m == b { return t }
        if t == b { return m }
        let w = ctx.lastWriter
        ctx.autoResolved.append(MergeAutoResolved(path: path, kind: "field", winner: w))
        return w == .mine ? m : t
    }

    struct GroupSpec {
        let name: String
        let keys: [String]
        let prompt: Bool
    }

    typealias ChildMerger = (JSONValue?, JSONValue?, JSONValue?, String, MergeContext) -> JSONValue?

    struct ObjectSpec {
        let groups: [GroupSpec]
        let child: (String) -> ChildMerger?
    }

    private static func groupEqual(_ a: JSONObject?, _ b: JSONObject?, _ keys: [String]) -> Bool {
        keys.allSatisfy { a?[$0] == b?[$0] }
    }

    private static func mergeGroup(
        _ b: JSONObject?, _ m: JSONObject, _ t: JSONObject, path: String, group g: GroupSpec, ctx: MergeContext
    ) -> MergeSide {
        let changedMine = !groupEqual(b, m, g.keys)
        let changedTheirs = !groupEqual(b, t, g.keys)
        if !changedTheirs { return .mine }
        if !changedMine { return .theirs }
        if groupEqual(m, t, g.keys) { return .mine }
        let gp = groupPath(path, g.keys)
        let def = ctx.lastWriter
        if g.prompt {
            let id = "\(g.name):\(gp)"
            let resolution = ctx.decide(id)
            ctx.conflicts.append(MergeConflict(id: id, kind: g.name, path: gp, resolution: resolution, defaultResolution: def))
            return resolution
        }
        ctx.autoResolved.append(MergeAutoResolved(path: gp, kind: "group", winner: def))
        return def
    }

    /// Per-key merge of an object the policy opens (root, settings, an
    /// element): groups first (policy order), then the other keys sorted.
    /// Output key order: mine's, then keys only theirs has.
    static func mergeObject(
        _ b: JSONObject?, _ m: JSONObject, _ t: JSONObject, path: String, spec: ObjectSpec, ctx: MergeContext
    ) -> JSONObject {
        var taken: [String: JSONValue] = [:]
        var handled = Set<String>()
        for g in spec.groups {
            for k in g.keys { handled.insert(k) }
            let src = mergeGroup(b, m, t, path: path, group: g, ctx: ctx) == .theirs ? t : m
            for k in g.keys { taken[k] = src[k] }
        }
        let bv: JSONValue? = b.map { .object($0) }
        for k in JSONKeys.sortedUnionKeys(bv, .object(m), .object(t)) where !handled.contains(k) {
            let kp = joinPath(path, k)
            if let child = spec.child(k) {
                taken[k] = child(b?[k], m[k], t[k], kp, ctx)
            } else {
                taken[k] = threeWay(b?[k], m[k], t[k], path: kp, ctx: ctx)
            }
        }
        var out = JSONObject()
        for k in m.keys { if let v = taken[k] { out[k] = v } }
        for k in t.keys where !m.has(k) { if let v = taken[k] { out[k] = v } }
        return out
    }

    // MARK: - Specs

    private static func rootSpec(_ policy: MergePolicy) -> ObjectSpec {
        let settings = ObjectSpec(
            groups: policy.settingsGroups.map { GroupSpec(name: $0.name, keys: $0.keys, prompt: $0.prompt) },
            child: { _ in nil }
        )
        return ObjectSpec(
            groups: policy.rootGroups.map { GroupSpec(name: $0.name, keys: $0.keys, prompt: $0.prompt) },
            child: { key in
                if key == policy.settingsKey {
                    return { b, m, t, path, ctx in mergeOpenObject(b, m, t, path: path, spec: settings, ctx: ctx) }
                }
                guard let c = policy.collection(key) else { return nil }
                return { b, m, t, path, ctx in mergeCollection(c, policy, b, m, t, path: path, ctx: ctx) }
            }
        )
    }

    private static func elementSpec(_ c: MergePolicy.IdCollection, _ policy: MergePolicy) -> ObjectSpec {
        ObjectSpec(
            groups: c.groups.map { GroupSpec(name: $0.joined(separator: ","), keys: $0, prompt: false) },
            child: { key in
                guard let nested = c.nested.first(where: { $0.key == key }) else { return nil }
                return { b, m, t, path, ctx in mergeCollection(nested, policy, b, m, t, path: path, ctx: ctx) }
            }
        )
    }

    /// An object the policy opens: per key when both sides hold objects, else one value.
    private static func mergeOpenObject(
        _ b: JSONValue?, _ m: JSONValue?, _ t: JSONValue?, path: String, spec: ObjectSpec, ctx: MergeContext
    ) -> JSONValue? {
        if m == t { return m }
        if m == b { return t }
        if t == b { return m }
        if let mo = m?.objectValue, let to = t?.objectValue {
            return .object(mergeObject(b?.objectValue, mo, to, path: path, spec: spec, ctx: ctx))
        }
        return threeWay(b, m, t, path: path, ctx: ctx)
    }

    // MARK: - Id collections

    struct IdEntry {
        let id: String
        let value: JSONObject
    }

    /// Elements of an id collection, or nil when it cannot merge by id (not
    /// an array, a non-object element, a missing / empty / non-string id —
    /// legacy — or a duplicate id). Absent = [].
    static func idEntries(_ v: JSONValue?) -> [IdEntry]? {
        guard let v else { return [] }
        guard let items = v.arrayValue else { return nil }
        var seen = Set<String>()
        var out: [IdEntry] = []
        for item in items {
            guard let o = item.objectValue, let id = o["id"]?.stringValue, !id.isEmpty,
                  seen.insert(id).inserted else { return nil }
            out.append(IdEntry(id: id, value: o))
        }
        return out
    }

    private static func mergeCollection(
        _ c: MergePolicy.IdCollection, _ policy: MergePolicy,
        _ b: JSONValue?, _ m: JSONValue?, _ t: JSONValue?, path: String, ctx: MergeContext
    ) -> JSONValue? {
        if m == t { return m }
        if m == b { return t }
        if t == b { return m }
        guard let B = idEntries(b), let M = idEntries(m), let T = idEntries(t) else {
            // Legacy (an element without an id) or malformed → one value.
            return threeWay(b, m, t, path: path, ctx: ctx)
        }
        if c.regenerationCheck {
            let regenMine = regenerated(B, M, policy)
            let regenTheirs = regenerated(B, T, policy)
            if regenMine || regenTheirs {
                let id = "subtitlesRegenerated:\(path)"
                let resolution = ctx.decide(id)
                ctx.conflicts.append(MergeConflict(
                    id: id, kind: "subtitlesRegenerated", path: path,
                    resolution: resolution, defaultResolution: ctx.lastWriter,
                    regeneratedBy: regenMine && regenTheirs ? "both" : regenMine ? "mine" : "theirs"
                ))
                return resolution == .mine ? m : t
            }
        }
        return .array(mergeById(c, policy, B, M, T, path: path, ctx: ctx))
    }

    /// Fewer than `regenerationSurvival` of the base ids survive on that side.
    private static func regenerated(_ base: [IdEntry], _ side: [IdEntry], _ policy: MergePolicy) -> Bool {
        guard !base.isEmpty else { return false }
        let ids = Set(side.map(\.id))
        let survivors = base.filter { ids.contains($0.id) }.count
        return Double(survivors) < Double(base.count) * policy.regenerationSurvival
    }

    private static func mergeById(
        _ c: MergePolicy.IdCollection, _ policy: MergePolicy,
        _ B: [IdEntry], _ M: [IdEntry], _ T: [IdEntry], path: String, ctx: MergeContext
    ) -> [JSONValue] {
        let bMap = Dictionary(uniqueKeysWithValues: B.map { ($0.id, $0.value) })
        let mMap = Dictionary(uniqueKeysWithValues: M.map { ($0.id, $0.value) })
        let tMap = Dictionary(uniqueKeysWithValues: T.map { ($0.id, $0.value) })
        let spec = elementSpec(c, policy)
        var out: [JSONValue] = []
        for id in mergedOrder(B, M, T, path: path, ctx: ctx) {
            let bv = bMap[id], mv = mMap[id], tv = tMap[id]
            let ep = elementPath(path, id)
            if let mv, let tv {
                out.append(.object(mergeElement(bv, mv, tv, path: ep, spec: spec, ctx: ctx)))
            } else if let mv {
                if bv == nil {
                    out.append(.object(mv)) // added by mine
                } else if mv != bv!, deleteVsModify(ep, deletedBy: .theirs, ctx: ctx) == .mine {
                    out.append(.object(mv))
                }
            } else if let tv {
                if bv == nil {
                    out.append(.object(tv)) // added by theirs
                } else if tv != bv!, deleteVsModify(ep, deletedBy: .mine, ctx: ctx) == .theirs {
                    out.append(.object(tv))
                }
            }
        }
        return out
    }

    private static func deleteVsModify(_ path: String, deletedBy: MergeSide, ctx: MergeContext) -> MergeSide {
        let id = "deleteVsModify:\(path)"
        let resolution = ctx.decide(id)
        ctx.conflicts.append(MergeConflict(
            id: id, kind: "deleteVsModify", path: path,
            resolution: resolution, defaultResolution: ctx.lastWriter, deletedBy: deletedBy
        ))
        return resolution
    }

    private static func mergeElement(
        _ b: JSONObject?, _ m: JSONObject, _ t: JSONObject, path: String, spec: ObjectSpec, ctx: MergeContext
    ) -> JSONObject {
        if m == t { return m }
        if let b, m == b { return t }
        if let b, t == b { return m }
        return mergeObject(b, m, t, path: path, spec: spec, ctx: ctx)
    }

    /// Mine's order with theirs-only ids appended (annotation order is
    /// z-order, never re-sorted); theirs' order when ONLY theirs reordered the
    /// shared ids; the last writer's when both reordered differently.
    private static func mergedOrder(_ B: [IdEntry], _ M: [IdEntry], _ T: [IdEntry], path: String, ctx: MergeContext) -> [String] {
        let inB = Set(B.map(\.id)), inM = Set(M.map(\.id)), inT = Set(T.map(\.id))
        let projB = B.filter { inM.contains($0.id) && inT.contains($0.id) }.map(\.id)
        let projM = M.filter { inB.contains($0.id) && inT.contains($0.id) }.map(\.id)
        let projT = T.filter { inB.contains($0.id) && inM.contains($0.id) }.map(\.id)
        let mineReordered = !JSONKeys.sameSequence(projM, projB)
        let theirsReordered = !JSONKeys.sameSequence(projT, projB)
        var backbone = MergeSide.mine
        if theirsReordered && !mineReordered {
            backbone = .theirs
        } else if theirsReordered && mineReordered && !JSONKeys.sameSequence(projM, projT) {
            backbone = ctx.lastWriter
            ctx.autoResolved.append(MergeAutoResolved(path: path, kind: "order", winner: backbone))
        }
        let first = backbone == .mine ? M : T
        let second = backbone == .mine ? T : M
        var order = first.map(\.id)
        var seen = Set(order)
        for e in second where seen.insert(e.id).inserted { order.append(e.id) }
        return order
    }

    // MARK: - Exclusive lanes

    private struct LaneItem {
        let collection: String
        let id: String
        let start: Double
        let end: Double
        /// `collection[id]`
        let key: String
    }

    private struct LanePair {
        let key: String
        let a: LaneItem
        let b: LaneItem
    }

    private static func laneItems(_ doc: JSONObject, _ collections: [String]) -> [LaneItem] {
        var items: [LaneItem] = []
        for collection in collections {
            guard let entries = idEntries(doc[collection]) else { continue }
            for e in entries {
                guard let start = e.value["startTime"]?.numberValue,
                      let end = e.value["endTime"]?.numberValue else { continue }
                items.append(LaneItem(collection: collection, id: e.id, start: start, end: end,
                                      key: elementPath(collection, e.id)))
            }
        }
        return items
    }

    private static func pairKey(_ a: String, _ b: String) -> String {
        JSONKeys.less(a, b) ? "\(a)|\(b)" : "\(b)|\(a)"
    }

    /// Linked zoom+tilt blocks (TimelineViewController.canvasEffectItems pairing).
    private static func linkedPairs(_ doc: JSONObject, _ lane: MergePolicy.Lane) -> Set<String> {
        var links = Set<String>()
        guard let link = lane.link else { return links }
        let primaries = laneItems(doc, [link.primary])
        let secondaries = laneItems(doc, [link.secondary])
        var claimed = Set<String>()
        for p in primaries {
            if let match = secondaries.first(where: {
                !claimed.contains($0.id)
                    && abs($0.start - p.start) <= link.epsilon
                    && abs($0.end - p.end) <= link.epsilon
            }) {
                claimed.insert(match.id)
                links.insert(pairKey(p.key, match.key))
            }
        }
        return links
    }

    private static func overlapPairs(_ doc: JSONObject, _ lane: MergePolicy.Lane, _ policy: MergePolicy) -> [LanePair] {
        let eps = policy.overlapEpsilon
        let items = laneItems(doc, lane.collections)
        let links = linkedPairs(doc, lane)
        var pairs: [LanePair] = []
        for i in 0..<items.count {
            for j in (i + 1)..<max(i + 1, items.count) {
                let x = items[i], y = items[j]
                guard x.start < y.end - eps && y.start < x.end - eps else { continue }
                let key = pairKey(x.key, y.key)
                if links.contains(key) { continue }
                pairs.append(JSONKeys.less(x.key, y.key) ? LanePair(key: key, a: x, b: y) : LanePair(key: key, a: y, b: x))
            }
        }
        return pairs.sorted { JSONKeys.less($0.key, $1.key) }
    }

    /// An exclusive-lane overlap NEITHER input had is a conflict; its
    /// resolution puts both elements back to the chosen side's version
    /// (removing one that side lacks). Detected once; applied in order.
    private static func resolveLaneOverlaps(
        _ merged: JSONObject, mine: JSONObject, theirs: JSONObject, policy: MergePolicy, ctx: MergeContext
    ) -> JSONObject {
        var resolutions: [(items: [LaneItem], side: MergeSide)] = []
        for lane in policy.lanes {
            let pairs = overlapPairs(merged, lane, policy)
            if pairs.isEmpty { continue }
            let before = Set(overlapPairs(mine, lane, policy).map(\.key) + overlapPairs(theirs, lane, policy).map(\.key))
            for p in pairs where !before.contains(p.key) {
                let id = "laneOverlap:\(p.key)"
                let resolution = ctx.decide(id)
                ctx.conflicts.append(MergeConflict(
                    id: id, kind: "laneOverlap", path: p.key,
                    resolution: resolution, defaultResolution: ctx.lastWriter,
                    lane: lane.name, elements: [p.a.key, p.b.key]
                ))
                resolutions.append((items: [p.a, p.b], side: resolution))
            }
        }
        guard !resolutions.isEmpty else { return merged }

        var out = merged
        for r in resolutions {
            let source = r.side == .mine ? mine : theirs
            for item in r.items {
                guard var current = out[item.collection]?.arrayValue else { continue }
                guard let index = current.firstIndex(where: { $0.get("id")?.stringValue == item.id }) else { continue }
                let replacement = idEntries(source[item.collection])?.first { $0.id == item.id }?.value
                if let replacement {
                    current[index] = .object(replacement)
                } else {
                    current.remove(at: index)
                }
                out[item.collection] = .array(current)
            }
        }
        return out
    }
}
