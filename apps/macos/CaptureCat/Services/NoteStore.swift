import Foundation
import os

private let logger = Logger(subsystem: "so.capturecat.CaptureCat", category: "NoteStore")

/// Disk store for text captures — mirrors ProjectStore's scheme exactly
/// (folder per item, JSON file inside, in-memory list sorted newest first).
@Observable
final class NoteStore {
    private(set) var notes: [Note] = []

    private let fm = FileManager.default

    init() {
        try? fm.createDirectory(at: Note.notesRoot, withIntermediateDirectories: true)
        loadAll()
    }

    func loadAll() {
        guard let contents = try? fm.contentsOfDirectory(
            at: Note.notesRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else {
            notes = []
            return
        }
        let decoder = JSONDecoder()
        var loaded: [Note] = []
        for dir in contents {
            let jsonURL = dir.appendingPathComponent("note.json")
            guard let data = try? Data(contentsOf: jsonURL),
                  let note = try? decoder.decode(Note.self, from: data) else { continue }
            loaded.append(note)
        }
        notes = loaded.sorted { $0.createdAt > $1.createdAt }
    }

    func save(_ note: Note) {
        let dir = note.noteDirectory
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(note) else { return }
        try? data.write(to: dir.appendingPathComponent("note.json"), options: .atomic)

        if let idx = notes.firstIndex(where: { $0.id == note.id }) {
            notes[idx] = note
        } else {
            notes.insert(note, at: 0)
        }
    }

    func delete(_ note: Note) {
        let id = note.id
        Task { @MainActor in ReminderCenter.shared.cancelReminder(for: id) }
        try? fm.removeItem(at: note.noteDirectory)
        notes.removeAll { $0.id == note.id }
        logger.info("Deleted note \(note.id)")
    }
}
