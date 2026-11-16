import Foundation

/// One undo step per inspector edit (Studio 4d).
///
/// The shared specs write the project directly, as the Mac panes do (the Mac
/// inspector registers undo only for its block adds/deletes). On iOS every
/// edit is ONE step on the editor's UndoManager: the session snapshots what
/// an edit can touch when it begins — the settings and every region list —
/// and when it commits (a tap at once; a slider or colour drag at its end;
/// a text field when editing ends) registers a step that restores exactly
/// the fields that edit changed. Field-level restore keeps changes made
/// meanwhile by anything else (canvas drags, features) intact; redo
/// re-applies the edit's values. The values themselves are always the
/// spec's — undo never computes an edit of its own.
///
/// Restoring settings swaps in a ProjectSettings decoded from the merged
/// JSON (its hand-rolled Codable round-trips; the gate asserts it). The
/// iOS studio never caches `project.settings`, so observers re-read it.
@MainActor
final class InspectorEditSession {
    struct Snapshot {
        var settings: [String: Any]
        var lists: [String: Data]

        init(_ project: Project) {
            settings = InspectorEditSession.json(project.settings)
            var lists: [String: Data] = [:]
            for (key, data) in InspectorEditSession.lists(project) { lists[key] = data }
            self.lists = lists
        }

        /// The settings keys and list names that differ from `other`.
        func changes(to other: Snapshot) -> (settings: Set<String>, lists: Set<String>) {
            var keys = Set<String>()
            for key in Set(settings.keys).union(other.settings.keys) {
                let a = settings[key].map(InspectorEditSession.canonical)
                let b = other.settings[key].map(InspectorEditSession.canonical)
                if a != b { keys.insert(key) }
            }
            let listKeys = Set(lists.keys).filter { lists[$0] != other.lists[$0] }
            return (keys, listKeys)
        }
    }

    private let project: () -> Project
    private let undoManager: () -> UndoManager?
    private var open: (id: String, name: String, before: Snapshot)?

    /// Steps registered (the gate reads it).
    private(set) var registeredSteps = 0

    init(project: @escaping () -> Project, undoManager: @escaping () -> UndoManager?) {
        self.project = project
        self.undoManager = undoManager
    }

    /// Opens an edit for control `id` unless one is already open for it.
    /// Another control's open edit commits first.
    func begin(_ id: String, name: String) {
        if let open, open.id == id { return }
        commit()
        open = (id, name, Snapshot(project()))
    }

    /// Closes the open edit, registering ONE step if it changed anything and
    /// none if it did not. (The inspector is the only undo registrar for its
    /// edits: the shared contexts get no undo manager on iOS, so a block add
    /// or an annotation delete is this one step too.)
    func commit() {
        guard let edit = open else { return }
        open = nil
        let after = Snapshot(project())
        let changes = edit.before.changes(to: after)
        guard !changes.settings.isEmpty || !changes.lists.isEmpty, let undo = undoManager() else { return }
        register(undo, restoring: edit.before, then: after, changes: changes, name: edit.name)
        registeredSteps += 1
    }

    /// A one-shot edit (tap, pick): begin, perform, commit.
    func perform(_ id: String, name: String, _ edit: () -> Void) {
        begin(id, name: name)
        edit()
        commit()
    }

    var isOpen: Bool { open != nil }

    /// Registers a step that restores `values` (and re-registers its inverse).
    private func register(_ undo: UndoManager, restoring values: Snapshot, then inverse: Snapshot,
                          changes: (settings: Set<String>, lists: Set<String>), name: String) {
        undo.registerUndo(withTarget: self) { session in
            session.restore(values, changes: changes)
            session.register(undo, restoring: inverse, then: values, changes: changes, name: name)
        }
        undo.setActionName(name)
    }

    private func restore(_ snapshot: Snapshot, changes: (settings: Set<String>, lists: Set<String>)) {
        let project = project()
        if !changes.settings.isEmpty {
            var live = Self.json(project.settings)
            for key in changes.settings { live[key] = snapshot.settings[key] }
            if let data = try? JSONSerialization.data(withJSONObject: live),
               let settings = try? JSONDecoder().decode(ProjectSettings.self, from: data) {
                // Fields the decoder deliberately ignores are set directly: the
                // restored value if this step changed them, else the live one
                // (a decode would silently turn them off).
                for (key, path) in Self.decoderForcedBools {
                    if changes.settings.contains(key), let value = snapshot.settings[key] as? Bool {
                        settings[keyPath: path] = value
                    } else {
                        settings[keyPath: path] = project.settings[keyPath: path]
                    }
                }
                project.settings = settings
            }
        }
        for key in changes.lists {
            guard let data = snapshot.lists[key] else { continue }
            Self.apply(list: key, data: data, to: project)
        }
    }

    /// ProjectSettings fields its decoder forces off on every load (a legacy
    /// correction in `init(from:)`), so a decode cannot restore them. The
    /// `--inspector` gate proves this list is exactly the set of fields that
    /// do not round-trip.
    static let decoderForcedBools: [String: ReferenceWritableKeyPath<ProjectSettings, Bool>] = [
        "smoothCursor": \.smoothCursor,
        "autoHideCursor": \.autoHideCursor,
    ]

    // MARK: Encoding

    static func json(_ settings: ProjectSettings) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(settings),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    /// A stable string for a JSON value (sorted keys), for comparing.
    static func canonical(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject([value]),
              let data = try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys]) else {
            return "\(value)"
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func lists(_ project: Project) -> [(String, Data)] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        func e<T: Encodable>(_ v: T) -> Data { (try? encoder.encode(v)) ?? Data() }
        return [
            ("zoom", e(project.zoomRegions)), ("tilt", e(project.tiltRegions)),
            ("highlight", e(project.highlightRegions)), ("depth", e(project.focusRegions)),
            ("blur", e(project.blurRegions)), ("annotations", e(project.annotations)),
            ("subtitles", e(project.subtitles)), ("cameraLayouts", e(project.cameraLayoutRegions)),
        ]
    }

    static func apply(list: String, data: Data, to project: Project) {
        let d = JSONDecoder()
        switch list {
        case "zoom": if let v = try? d.decode([ZoomRegion].self, from: data) { project.zoomRegions = v }
        case "tilt": if let v = try? d.decode([TiltRegion].self, from: data) { project.tiltRegions = v }
        case "highlight": if let v = try? d.decode([HighlightRegion].self, from: data) { project.highlightRegions = v }
        case "depth": if let v = try? d.decode([FocusRegion].self, from: data) { project.focusRegions = v }
        case "blur": if let v = try? d.decode([BlurRegion].self, from: data) { project.blurRegions = v }
        case "annotations": if let v = try? d.decode([Annotation].self, from: data) { project.annotations = v }
        case "subtitles": if let v = try? d.decode([SubtitleSegment].self, from: data) { project.subtitles = v }
        case "cameraLayouts": if let v = try? d.decode([CameraLayoutRegion].self, from: data) { project.cameraLayoutRegions = v }
        default: break
        }
    }
}
