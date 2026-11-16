import Foundation

/// A three-way merge being reviewed (docs/project-history.md §1): the three
/// raw documents, who wins a same-field clash, and the Mine / Theirs choices
/// made so far. Every conflict is already resolved in `merged` (its choice,
/// else the last writer); choosing re-merges — conflict ids are stable, so a
/// choice survives the re-merge.
///
/// Platform-neutral: the iOS studio's Merge Review runs on it, and its
/// `decisions` are what the Mac's MergeReviewDialog shows for the same
/// triple (`--history-transcript` prints them from the Mac dialog).
nonisolated struct ProjectMergeSession: Sendable {
    let base: JSONValue
    let mine: JSONValue
    let theirs: JSONValue
    let mineWins: Bool
    /// Who made `theirs` (the dialog's "Ana (Web)").
    var theirsAuthor: CloudVersionAuthor?
    /// The name when `theirsAuthor` has none ("The web editor" on the Mac).
    var theirsFallback: String
    private(set) var choices: [String: MergeSide]
    private(set) var result: MergeResult

    init(base: JSONValue, mine: JSONValue, theirs: JSONValue, mineWins: Bool,
         choices: [String: MergeSide] = [:], theirsAuthor: CloudVersionAuthor? = nil,
         theirsFallback: String = "The web editor") {
        self.base = base
        self.mine = mine
        self.theirs = theirs
        self.mineWins = mineWins
        self.choices = choices
        self.theirsAuthor = theirsAuthor
        self.theirsFallback = theirsFallback
        result = ProjectMerge.merge(base: base, mine: mine, theirs: theirs, mineWins: mineWins, choices: choices)
    }

    var merged: JSONValue { result.merged }
    var conflicts: [MergeConflict] { result.conflicts }
    var autoResolved: [MergeAutoResolved] { result.autoResolved }
    /// Conflicts no choice settles yet.
    var unresolved: [MergeConflict] { conflicts.filter { choices[$0.id] == nil } }
    var theirsName: String { MergeReviewWords.theirsName(author: theirsAuthor, fallback: theirsFallback) }

    /// Applies choices (conflict id → side) and re-merges.
    mutating func choose(_ picked: [String: MergeSide]) {
        for (id, side) in picked { choices[id] = side }
        result = ProjectMerge.merge(base: base, mine: mine, theirs: theirs, mineWins: mineWins, choices: choices)
    }

    /// The last-writer rule the caller decides (the merge has no clock):
    /// mine wins when its last edit is LATER than theirs at millisecond
    /// resolution; ties and unknown clocks go to theirs. The Mac sync's
    /// `CloudProjectSync.mineWins` is this.
    static func mineWins(mineEdited: Date?, theirsSaved: Date?, now: Date) -> Bool {
        guard let theirs = theirsSaved, let local = mineEdited else { return false }
        let mine = min(local, now)
        return milliseconds(mine) > milliseconds(theirs)
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    }

    // MARK: - What Merge Review shows

    /// One conflict row: title, caption and the side its control starts on.
    struct Decision: Equatable, Sendable {
        let id: String
        let kind: String
        let path: String
        let title: String
        let detail: String
        let resolution: MergeSide
        let defaultResolution: MergeSide
    }

    func decisions(device: String) -> [Decision] {
        let who = theirsName
        return conflicts.map { conflict in
            Decision(id: conflict.id, kind: conflict.kind, path: conflict.path,
                     title: MergeReviewWords.title(for: conflict),
                     detail: MergeReviewWords.detail(for: conflict, theirs: who, device: device),
                     resolution: conflict.resolution, defaultResolution: conflict.defaultResolution)
        }
    }

    /// Every conflict flipped from the side it shows — what a reviewer who
    /// overrides every default picks.
    var flippedChoices: [String: MergeSide] {
        Dictionary(uniqueKeysWithValues: conflicts.map { ($0.id, $0.resolution == .mine ? MergeSide.theirs : .mine) })
    }
}
