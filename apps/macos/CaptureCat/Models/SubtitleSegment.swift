import Foundation

struct WordTiming: Identifiable, Codable, Sendable {
    let id: UUID
    var startTime: TimeInterval
    var endTime: TimeInterval
    var text: String

    init(id: UUID = UUID(), startTime: TimeInterval, endTime: TimeInterval, text: String) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
    }
}

struct SubtitleSegment: Identifiable, Codable, Sendable {
    let id: UUID
    var startTime: TimeInterval
    var endTime: TimeInterval
    var text: String
    var words: [WordTiming]

    var duration: TimeInterval { endTime - startTime }

    init(
        id: UUID = UUID(),
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String,
        words: [WordTiming] = []
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.words = words
    }

    enum CodingKeys: String, CodingKey {
        case id, startTime, endTime, text, words
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        startTime = try c.decode(TimeInterval.self, forKey: .startTime)
        endTime = try c.decode(TimeInterval.self, forKey: .endTime)
        text = try c.decode(String.self, forKey: .text)
        words = try c.decodeIfPresent([WordTiming].self, forKey: .words) ?? []
    }

    /// Group word-level segments into display-friendly subtitle chunks
    static func groupWords(_ words: [SubtitleSegment], maxDuration: TimeInterval = 3.0, maxWords: Int = 8) -> [SubtitleSegment] {
        guard !words.isEmpty else { return [] }

        var groups: [SubtitleSegment] = []
        var currentWords: [String] = []
        var currentTimings: [WordTiming] = []
        var groupStart = words[0].startTime
        var groupEnd = words[0].endTime

        for word in words {
            let wouldExceedDuration = (word.endTime - groupStart) > maxDuration
            let wouldExceedWords = currentWords.count >= maxWords
            let isAfterPunctuation = currentWords.last?.hasSuffix(".") == true
                || currentWords.last?.hasSuffix("?") == true
                || currentWords.last?.hasSuffix("!") == true

            if !currentWords.isEmpty && (wouldExceedDuration || wouldExceedWords || isAfterPunctuation) {
                groups.append(SubtitleSegment(
                    startTime: groupStart,
                    endTime: groupEnd,
                    text: currentWords.joined(separator: " "),
                    words: currentTimings
                ))
                currentWords = []
                currentTimings = []
                groupStart = word.startTime
            }

            let trimmed = word.text.trimmingCharacters(in: .whitespaces)
            currentWords.append(trimmed)
            currentTimings.append(WordTiming(
                startTime: word.startTime,
                endTime: word.endTime,
                text: trimmed
            ))
            groupEnd = word.endTime
        }

        if !currentWords.isEmpty {
            groups.append(SubtitleSegment(
                startTime: groupStart,
                endTime: groupEnd,
                text: currentWords.joined(separator: " "),
                words: currentTimings
            ))
        }

        return groups
    }
}
