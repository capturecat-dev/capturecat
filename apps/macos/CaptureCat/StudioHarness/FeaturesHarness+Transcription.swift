import Foundation

/// Transcription: a recording with known speech (synthesized by the gate
/// script with `say`, never user audio) through `TranscriptionService` —
/// WhisperKit `base.en`, loaded from the SAME model folder on both sides.
/// Compared: the audio the engine is given (the extracted 16 kHz WAV), the
/// subtitle STRUCTURE (segments, words per segment) exactly, the text — which
/// may differ only where the engine's arithmetic does, each difference logged
/// with that reason — and word timing:
///
/// - no systematic offset: the MEDIAN word-boundary |Δ| ≤ one timestamp
///   step (20 ms);
/// - outliers no larger than the engine's own arithmetic sensitivity,
///   measured on the Mac every run: the same audio with every model on the
///   CPU instead of the Neural Engine moves word boundaries by
///   `computeSpread` (0.14 s on 2026-11-16), so iOS (CoreML on the
///   Simulator's CPU) may differ by that, plus one step. Relative, like 3c's
///   "no worse than the Mac" bars.
extension FeaturesHarness {
    enum SpeechFixture {
        static let movie = "speech.mov"
        static let script = "speech.txt"
        /// The Mac's extracted 16 kHz engine input (the equal-input check).
        static let macInput = "mac-input.wav"
        /// The stages the service reports, in order (the quick ones may pass
        /// between two samples).
        static let stages = ["Loading model...", "Extracting audio...", "Transcribing...", "Processing subtitles..."]
        /// Whisper's timestamp grid: one step.
        static let timestampStep = 0.02
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

    /// The largest per-word timing differences, as text.
    static func worstWords(mac: [TranscriptSegment], ios: [TranscriptSegment], count: Int = 5) -> String {
        var rows: [(Double, String)] = []
        for (a, b) in zip(mac, ios) {
            for (wa, wb) in zip(a.words, b.words) {
                let d = max(abs(wa.start - wb.start), abs(wa.end - wb.end))
                rows.append((d, String(format: "“%@” Mac %.2f–%.2f iOS %.2f–%.2f", wa.text, wa.start, wa.end, wb.start, wb.end)))
            }
        }
        return rows.sorted { $0.0 > $1.0 }.prefix(count).map(\.1).joined(separator: " · ")
    }

    /// Every word-boundary |Δ| (start and end of each word; structure must match).
    static func timingDeltas(mac: [TranscriptSegment], ios: [TranscriptSegment]) -> [Double] {
        var deltas: [Double] = []
        for (a, b) in zip(mac, ios) {
            deltas.append(contentsOf: [abs(a.start - b.start), abs(a.end - b.end)])
            for (wa, wb) in zip(a.words, b.words) { deltas.append(contentsOf: [abs(wa.start - wb.start), abs(wa.end - wb.end)]) }
        }
        return deltas
    }

    /// max |Δ| over every segment and word boundary.
    static func maxTimingDelta(mac: [TranscriptSegment], ios: [TranscriptSegment]) -> Double {
        timingDeltas(mac: mac, ios: ios).max() ?? 0
    }

    static func medianTimingDelta(mac: [TranscriptSegment], ios: [TranscriptSegment]) -> Double {
        let d = timingDeltas(mac: mac, ios: ios).sorted()
        return d.isEmpty ? .infinity : d[d.count / 2]
    }

    /// Scores iOS against the Mac (and both against the script).
    static func compareTranscripts(mac: [TranscriptSegment], ios: [TranscriptSegment], script: String,
                                   computeSpread: Double, engineNote: String, report: Report) {
        report.check("subtitles produced", !ios.isEmpty && !mac.isEmpty,
                     "\(mac.count) on the Mac, \(ios.count) on iOS")
        let structureMac = mac.map(\.words.count), structureIOS = ios.map(\.words.count)
        report.check("segment / word structure identical", structureMac == structureIOS,
                     "Mac \(structureMac) · iOS \(structureIOS)")
        let deltas = timingDeltas(mac: mac, ios: ios)
        let worst = deltas.max() ?? .infinity, median = medianTimingDelta(mac: mac, ios: ios)
        let step = SpeechFixture.timestampStep
        report.check("no systematic timing offset (median word-boundary |Δ| ≤ \(step) s)", !deltas.isEmpty && median <= step + 1e-6,
                     String(format: "median %.3f s over %d boundaries", median, deltas.count))
        report.check("timing outliers within the Mac's own compute-unit spread + one step",
                     !deltas.isEmpty && computeSpread > 0 && worst <= computeSpread + step + 1e-6,
                     String(format: "max |Δ| %.3f s; %d of %d boundaries beyond one step · Mac Neural Engine vs CPU %.3f s",
                            worst, deltas.filter { $0 > step + 1e-6 }.count, deltas.count, computeSpread))
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
