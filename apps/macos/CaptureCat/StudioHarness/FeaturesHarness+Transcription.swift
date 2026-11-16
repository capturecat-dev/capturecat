import Foundation

/// Transcription: a recording with known speech (synthesized by the gate
/// script with `say`, never user audio) through `TranscriptionService` —
/// WhisperKit `base.en`, loaded from the SAME model folder on both sides.
/// Compared: the audio the engine is given (the extracted 16 kHz WAV), the
/// subtitle STRUCTURE (segments, words per segment) exactly, word timing
/// within `timingTolerance`, and the text — which may differ only where the
/// engine's arithmetic does (CoreML on the Mac's Neural Engine vs the
/// Simulator's CPU), each difference logged with that reason.
extension FeaturesHarness {
    enum SpeechFixture {
        static let movie = "speech.mov"
        static let script = "speech.txt"
        static let modelFolderName = "openai_whisper-base.en"
        /// Whisper's timestamp grid is 20 ms; allow a few steps of drift
        /// between compute units.
        static let timingTolerance = 0.1
    }

    struct TranscriptWord: Codable, Equatable {
        var start: Double
        var end: Double
        var text: String
    }

    struct TranscriptSegment: Codable, Equatable {
        var start: Double
        var end: Double
        var text: String
        var words: [TranscriptWord]
    }

    static func transcript(_ segments: [SubtitleSegment]) -> [TranscriptSegment] {
        segments.map { segment in
            TranscriptSegment(start: segment.startTime, end: segment.endTime, text: segment.text,
                              words: segment.words.map { TranscriptWord(start: $0.startTime, end: $0.endTime, text: $0.text) })
        }
    }

    /// Lowercased words without punctuation — the text comparison.
    static func normalizedWords(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
    }

    /// Word error rate (Levenshtein over normalized words).
    static func wordErrorRate(reference: String, hypothesis: String) -> Double {
        let r = normalizedWords(reference), h = normalizedWords(hypothesis)
        guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
        guard !h.isEmpty else { return 1 }
        var previous = Array(0...h.count)
        for i in 1...r.count {
            var current = [i] + Array(repeating: 0, count: h.count)
            for j in 1...h.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1,
                                 previous[j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return Double(previous[h.count]) / Double(r.count)
    }

    /// Scores iOS against the Mac (and both against the script).
    static func compareTranscripts(mac: [TranscriptSegment], ios: [TranscriptSegment], script: String,
                                   engineNote: String, report: Report) {
        report.check("subtitles produced", !ios.isEmpty && !mac.isEmpty,
                     "\(mac.count) on the Mac, \(ios.count) on iOS")
        let structureMac = mac.map(\.words.count), structureIOS = ios.map(\.words.count)
        report.check("segment / word structure identical", structureMac == structureIOS,
                     "Mac \(structureMac) · iOS \(structureIOS)")
        var worst = 0.0, compared = 0
        for (a, b) in zip(mac, ios) {
            worst = max(worst, abs(a.start - b.start), abs(a.end - b.end))
            for (wa, wb) in zip(a.words, b.words) {
                worst = max(worst, abs(wa.start - wb.start), abs(wa.end - wb.end))
                compared += 1
            }
        }
        report.check("word timing within \(SpeechFixture.timingTolerance) s", compared > 0 && worst <= SpeechFixture.timingTolerance,
                     String(format: "max |Δ| %.3f s over %d words", worst, compared))
        let macText = mac.map(\.text).joined(separator: " "), iosText = ios.map(\.text).joined(separator: " ")
        var textDiffs = 0
        for (index, (a, b)) in zip(mac, ios).enumerated() where normalizedWords(a.text) != normalizedWords(b.text) {
            textDiffs += 1
            report.note("text differs in segment \(index): Mac “\(a.text)” · iOS “\(b.text)” — reason: \(engineNote)")
        }
        let werMac = wordErrorRate(reference: script, hypothesis: macText)
        let werIOS = wordErrorRate(reference: script, hypothesis: iosText)
        report.note(String(format: "WER vs script: Mac %.3f · iOS %.3f · %d segment text difference(s)", werMac, werIOS, textDiffs))
        // The engine must still hear the script: a broken pipeline (silence,
        // wrong track, garbled resample) shows up here, not as a timing miss.
        report.check("iOS transcript matches the script (WER ≤ Mac + 0.05)", werIOS <= werMac + 0.05,
                     String(format: "iOS %.3f, Mac %.3f", werIOS, werMac))
    }
}
