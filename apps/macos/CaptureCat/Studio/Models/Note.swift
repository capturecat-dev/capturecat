import Foundation

/// Lightweight text capture ("note") — created from the macOS Services menu
/// (highlight text anywhere → right-click → Capture Text in CaptureCat) or
/// from the clipboard. Deliberately NOT a Project: Project is inherently
/// video-based (duration, trims, effect regions, media files), and forcing a
/// fake zero-length video project would leak note captures into every
/// video-only code path (export, thumbnailing, MCP effect tools). Notes get a
/// parallel record with the same folder-per-item persistence scheme:
/// `Application Support/CaptureCat/Notes/<uuid>/note.json`.
@Observable
final class Note: Identifiable, Codable {
    let id: UUID
    var text: String
    /// Localized name of the app the text was captured from, when known.
    var sourceAppName: String?
    var createdAt: Date
    var modifiedAt: Date
    /// When set, a local notification is scheduled for this date (see
    /// ReminderCenter). Same field name as Project.reminderDate.
    var reminderDate: Date?

    /// First non-empty line, clamped — notes have no explicit name field.
    var title: String {
        let line = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if line.isEmpty { return "Untitled Note" }
        return line.count > 60 ? String(line.prefix(60)) + "…" : line
    }

    static var notesRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CaptureCat/Notes", isDirectory: true)
    }

    var noteDirectory: URL {
        Self.notesRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    init(id: UUID = UUID(), text: String, sourceAppName: String? = nil) {
        self.id = id
        self.text = text
        self.sourceAppName = sourceAppName
        self.createdAt = Date()
        self.modifiedAt = Date()
        self.reminderDate = nil
    }

    enum CodingKeys: String, CodingKey {
        case id, text, sourceAppName, createdAt, modifiedAt, reminderDate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        sourceAppName = try c.decodeIfPresent(String.self, forKey: .sourceAppName)
        let created = try c.decode(Date.self, forKey: .createdAt)
        createdAt = created
        modifiedAt = try c.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? created
        reminderDate = try c.decodeIfPresent(Date.self, forKey: .reminderDate)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(text, forKey: .text)
        try c.encodeIfPresent(sourceAppName, forKey: .sourceAppName)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(modifiedAt, forKey: .modifiedAt)
        try c.encodeIfPresent(reminderDate, forKey: .reminderDate)
    }
}
