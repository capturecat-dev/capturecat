import Foundation

/// Transcription: a recording with known speech (synthesized by the gate
/// script with `say`, never user audio) through `TranscriptionService` —
/// WhisperKit `base.en`, loaded from the SAME model folder on both sides.
///
/// EXACT (the subtitles a user gets): segment count, words per segment, and
/// the text (normalized words identical — WER 0 between the platforms).
///
/// TIMING, with bars that come from measured platform variance, never from
/// the result (owner: "you choose best practice", 2026-11-16, superseding
/// the earlier fixed-bar keep-failing decision):
/// - no global offset: the MEDIAN word-boundary |Δ| ≤ one Whisper timestamp
///   step (20 ms);
/// - per-boundary drift bounded by what the Mac does against ITSELF: every
///   run, the Mac transcribes a corpus of speech clips (the fixture plus
///   `--speech-corpus`) on its default compute units AND with every model on
///   the CPU, and pools the word-boundary |Δ| of each pair. iOS must stay
///   within that pooled MAX + one step and that pooled P90 + one step.
///   The Mac's corpus spread is printed with every run
///   (`FEATURES-REFERENCE transcription Mac self-variance …`) and written
///   to mac-transcription.json `selfSpread`, so the bar is traceable.
///
/// Measured 2026-11-16 (5 clips, 300 boundaries): the Mac against itself
/// moves word boundaries by max 0.020 s, p90 0.000 s (one earlier `say`
/// take showed 0.14 s, a one-off). The iOS 27 Simulator (CoreML on the CPU)
/// moves them by max 0.120 s, p90 0.040 s — also on the Mac's exact input,
/// and against the Mac's own CPU path — so both drift checks are RED there:
/// the Simulator's arithmetic differs from the Mac's by more than the Mac's
/// own compute-unit variance. Segments, words, text and the median match.
/// Do not widen these bars to go green; a device run (Neural Engine) is
/// the measurement still missing.
extension FeaturesHarness {
    /// The Mac's own compute-unit sensitivity, pooled over a corpus.
    struct TimingSpread {
        var max: Double
        var p90: Double
        var median: Double
        var boundaries: Int
        var clips: Int
        /// Corpus clips whose ANE and CPU runs differ in structure or text
        /// (pooled only where they match).
        var mismatches: Int

        var json: [String: Any] {
            ["max": max, "p90": p90, "median": median, "boundaries": boundaries, "clips": clips, "mismatches": mismatches]
        }

        init(max: Double, p90: Double, median: Double, boundaries: Int, clips: Int, mismatches: Int) {
            self.max = max; self.p90 = p90; self.median = median
            self.boundaries = boundaries; self.clips = clips; self.mismatches = mismatches
        }

        init?(json: Any?) {
            guard let d = json as? [String: Any], let max = d["max"] as? Double, let p90 = d["p90"] as? Double else { return nil }
            self.init(max: max, p90: p90, median: d["median"] as? Double ?? 0, boundaries: d["boundaries"] as? Int ?? 0,
                      clips: d["clips"] as? Int ?? 0, mismatches: d["mismatches"] as? Int ?? 0)
        }
    }

    /// Nearest-rank percentile (p in 0…1).
    static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return .infinity }
        let rank = Int((p * Double(sorted.count)).rounded(.up))
        return sorted[min(sorted.count, Swift.max(1, rank)) - 1]
    }

    /// Pools the word-boundary |Δ| of each (default compute, CPU-only) pair.
    static func selfSpread(_ pairs: [(a: [TranscriptSegment], b: [TranscriptSegment])]) -> TimingSpread {
        var pooled: [Double] = []
        var mismatches = 0
        for pair in pairs {
            guard pair.a.map(\.words.count) == pair.b.map(\.words.count),
                  pair.a.map({ normalizedWords($0.text) }) == pair.b.map({ normalizedWords($0.text) }) else {
                mismatches += 1
                continue
            }
            pooled.append(contentsOf: timingDeltas(mac: pair.a, ios: pair.b))
        }
        return TimingSpread(max: pooled.max() ?? 0, p90: percentile(pooled, 0.9), median: percentile(pooled, 0.5),
                            boundaries: pooled.count, clips: pairs.count, mismatches: mismatches)
    }

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
                                   spread: TimingSpread?, report: Report) {
        report.check("subtitles produced", !ios.isEmpty && !mac.isEmpty,
                     "\(mac.count) on the Mac, \(ios.count) on iOS")
        let structureMac = mac.map(\.words.count), structureIOS = ios.map(\.words.count)
        report.check("segment / word structure identical", structureMac == structureIOS,
                     "Mac \(structureMac) · iOS \(structureIOS)")
        var textDiffs = 0
        for (index, (a, b)) in zip(mac, ios).enumerated() where normalizedWords(a.text) != normalizedWords(b.text) {
            textDiffs += 1
            report.note("text differs in segment \(index): Mac “\(a.text)” · iOS “\(b.text)”")
        }
        let macText = mac.map(\.text).joined(separator: " "), iosText = ios.map(\.text).joined(separator: " ")
        let werBetween = wordErrorRate(reference: macText, hypothesis: iosText)
        report.check("text identical (WER 0 between the platforms)", mac.count == ios.count && textDiffs == 0 && werBetween == 0,
                     String(format: "%d segment(s) differ, WER %.3f", textDiffs, werBetween))
        report.note(String(format: "WER vs the script: Mac %.3f · iOS %.3f",
                           wordErrorRate(reference: script, hypothesis: macText), wordErrorRate(reference: script, hypothesis: iosText)))

        let deltas = timingDeltas(mac: mac, ios: ios)
        let step = SpeechFixture.timestampStep
        let median = percentile(deltas, 0.5), p90 = percentile(deltas, 0.9), worst = deltas.max() ?? .infinity
        report.check("no global timing offset (median word-boundary |Δ| ≤ \(step) s)", !deltas.isEmpty && median <= step + 1e-6,
                     String(format: "median %.3f s over %d boundaries", median, deltas.count))
        guard let spread, spread.boundaries > 0 else {
            report.check("the Mac's self-variance was measured", false, "no selfSpread in the Mac reference")
            return
        }
        let detail = String(format: "Mac self-variance (ANE vs CPU, %d clips, %d boundaries%@): max %.3f p90 %.3f median %.3f",
                            spread.clips, spread.boundaries,
                            spread.mismatches > 0 ? ", \(spread.mismatches) clip(s) differing in words" : "",
                            spread.max, spread.p90, spread.median)
        report.check("per-boundary drift: max ≤ the Mac's self-variance max + one step", worst <= spread.max + step + 1e-6,
                     String(format: "iOS max %.3f s (bar %.3f) · %d of %d boundaries beyond one step · %@",
                            worst, spread.max + step, deltas.filter { $0 > step + 1e-6 }.count, deltas.count, detail))
        report.check("per-boundary drift: p90 ≤ the Mac's self-variance p90 + one step", p90 <= spread.p90 + step + 1e-6,
                     String(format: "iOS p90 %.3f s (bar %.3f)", p90, spread.p90 + step))
    }
}
