import Foundation
import QuartzCore
import WhisperKit

/// (f) WhisperKit `base.en` on iOS — the model and decode options the Mac's
/// TranscriptionService uses (WhisperKit 0.15.0, wordTimestamps: true).
///
/// Times download, load (+prewarm: CoreML specialization happens on the
/// first load on each device and OS build), and two transcriptions of a
/// synthetic 60 s speech clip (`say` output, never user audio), and scores
/// a rough word error rate against the script it was generated from.
/// Run it twice: the first launch pays download + specialization; the second
/// shows the cached cost a user sees every later session.
enum SpikeF {
    @MainActor
    static func run(variant: String) async throws -> [String: Any] {
        let model = variant == "default" ? "base.en" : variant
        let h = Harness.shared
        let audio = try h.media("speech-60s.wav")
        let reference = (try? String(contentsOf: try h.media("speech-60s.txt"), encoding: .utf8)) ?? ""
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("whisper", isDirectory: true)
        var result: [String: Any] = ["model": model, "whisperKit": "0.15.0"]

        var t = CACurrentMediaTime()
        let folder = try await WhisperKit.download(variant: model, downloadBase: base)
        result["downloadOrCacheSeconds"] = CACurrentMediaTime() - t
        result["modelBytes"] = folderSize(folder)
        h.log("model at \(folder.lastPathComponent)")

        t = CACurrentMediaTime()
        let pipe = try await WhisperKit(WhisperKitConfig(
            model: model, downloadBase: base, modelFolder: folder.path,
            verbose: false, prewarm: true, load: true, download: false))
        result["loadAndPrewarmSeconds"] = CACurrentMediaTime() - t
        h.log("loaded")

        let options = DecodingOptions(task: .transcribe, language: "en", temperature: 0.0,
                                      skipSpecialTokens: true, wordTimestamps: true)
        var runs: [[String: Any]] = []
        for i in 0..<2 {
            t = CACurrentMediaTime()
            let results = try await pipe.transcribe(audioPath: audio.path, decodeOptions: options)
            let seconds = CACurrentMediaTime() - t
            let text = results.map(\.text).joined(separator: " ")
            let timings = results.first?.timings
            runs.append([
                "run": i + 1,
                "seconds": seconds,
                "audioSeconds": timings?.inputAudioSeconds ?? 60,
                "realtimeFactor": (timings?.inputAudioSeconds ?? 60) / seconds,
                "encodingSeconds": timings?.encoding ?? -1,
                "decodingLoopSeconds": timings?.decodingLoop ?? -1,
                "words": results.reduce(0) { $0 + $1.allWords.count },
                "wer": wer(reference: reference, hypothesis: text),
                "textPrefix": String(text.prefix(160)),
            ])
            h.log("run \(i + 1): \(String(format: "%.2f", seconds))s")
        }
        result["runs"] = runs
        return result
    }

    static func folderSize(_ url: URL) -> Int {
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        var total = 0
        while let f = e?.nextObject() as? URL { total += (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        return total
    }

    /// Word error rate (Levenshtein over lowercase alphanumeric words).
    static func wer(reference: String, hypothesis: String) -> Double {
        func words(_ s: String) -> [String] {
            s.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
        }
        let r = words(reference), h = words(hypothesis)
        guard !r.isEmpty else { return -1 }
        var prev = Array(0...h.count)
        for i in 1...r.count {
            var cur = [i] + Array(repeating: 0, count: h.count)
            for j in 1...max(1, h.count) where h.count > 0 {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return Double(prev[h.count]) / Double(r.count)
    }
}
