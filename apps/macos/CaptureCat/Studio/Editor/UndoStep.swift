import Foundation

/// One user edit = ONE undo step that round-trips (Studio undo integrity).
///
/// Every shared edit (timeline lanes, inspector block adds/deletes, the
/// gesture core's Camera Height, Auto Zoom, Motion) registers through here so
/// that:
/// - undo restores the exact prior model — a removed item goes back at the
///   index it came from (array order is stacking order for annotations and
///   persistence order for everything), never appended;
/// - undoing registers the redo, and redoing registers the undo again, so
///   undo / redo / undo … alternate on the same values.
///
/// Inverses work by id where they touch one item (as the edits always did),
/// so an item edited meanwhile by something that registers no step is not
/// rolled back with it. Proven by `--undo-integrity-test`.
@MainActor
enum UndoStep {
    #if DEBUG
    /// INJECTED DEFECTS for `--undo-integrity-test --inject <name>`: each
    /// re-creates one of the original bugs so the gate proves it catches it.
    enum Defect: String, CaseIterable {
        /// A drag commit (FOCUS block, VOICE clip, Slide/Curtain chip)
        /// registers no step.
        case dragNoUndo = "drag-no-undo"
        /// A deletion's undo appends the item at the end of its list.
        case appendOnUndo = "append-on-undo"
        /// Undo registers no redo.
        case noRedo = "no-redo"
    }
    static var probeDefect: Defect?
    #endif

    /// Registers `undo` as the step `name`; running it registers `redo` as
    /// the inverse step (and that one registers `undo` again).
    static func register<Target: AnyObject>(
        _ manager: UndoManager?, target: Target, name: String,
        undo: @escaping (Target) -> Void, redo: @escaping (Target) -> Void
    ) {
        guard let manager else { return }
        manager.registerUndo(withTarget: target) { [weak manager] target in
            undo(target)
            #if DEBUG
            if probeDefect == .noRedo { return }
            #endif
            register(manager, target: target, name: name, undo: redo, redo: undo)
        }
        manager.setActionName(name)
    }

    /// `item` was just added to `list` (it is in it now): undo removes it,
    /// redo puts it back at the index it holds now.
    static func added<E: Identifiable>(
        _ manager: UndoManager?, _ project: Project,
        _ list: ReferenceWritableKeyPath<Project, [E]>, _ item: E, name: String
    ) {
        let index = project[keyPath: list].firstIndex { $0.id == item.id } ?? project[keyPath: list].count
        register(manager, target: project, name: name,
                 undo: { $0[keyPath: list].removeAll { $0.id == item.id } },
                 redo: { insert(item, at: index, into: list, of: $0) })
    }

    /// `item` was just removed from `list` at `index`: undo puts it back at
    /// that index, redo removes it again.
    static func removed<E: Identifiable>(
        _ manager: UndoManager?, _ project: Project,
        _ list: ReferenceWritableKeyPath<Project, [E]>, _ item: E, at index: Int, name: String
    ) {
        register(manager, target: project, name: name,
                 undo: { insert(item, at: index, into: list, of: $0) },
                 redo: { $0[keyPath: list].removeAll { $0.id == item.id } })
    }

    /// The item with `before.id` was just replaced by `after`: undo writes
    /// `before` back, redo writes `after`.
    static func replaced<E: Identifiable>(
        _ manager: UndoManager?, _ project: Project,
        _ list: ReferenceWritableKeyPath<Project, [E]>, before: E, after: E, name: String
    ) {
        register(manager, target: project, name: name,
                 undo: { write(before, in: list, of: $0) },
                 redo: { write(after, in: list, of: $0) })
    }

    /// Re-inserts `item` at `index` (clamped), unless it is already there.
    static func insert<E: Identifiable>(
        _ item: E, at index: Int, into list: ReferenceWritableKeyPath<Project, [E]>, of project: Project
    ) {
        guard !project[keyPath: list].contains(where: { $0.id == item.id }) else { return }
        #if DEBUG
        if probeDefect == .appendOnUndo { project[keyPath: list].append(item); return }
        #endif
        project[keyPath: list].insert(item, at: max(0, min(index, project[keyPath: list].count)))
    }

    /// Writes `item` over the element with its id (no-op if it is gone).
    static func write<E: Identifiable>(
        _ item: E, in list: ReferenceWritableKeyPath<Project, [E]>, of project: Project
    ) {
        guard let i = project[keyPath: list].firstIndex(where: { $0.id == item.id }) else { return }
        project[keyPath: list][i] = item
    }
}
