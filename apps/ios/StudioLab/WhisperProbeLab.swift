import CoreML
import Foundation
import WhisperKit

/// `--whisper-probe <audio> --whisper-base <dir>` — the transcription
/// service's engine call (TranscriptionService: base.en, the same decoding
/// options) with WhisperKit's own result fields printed: text, segments,
/// no-speech probability, average log-prob, compression ratio, fallbacks.
/// Diagnoses an empty or diverging transcript in StudioLab (Studio 4e).
@MainActor
enum WhisperProbeLab {
    static func start(_ arguments: [String]) -> Bool {
        func value(_ name: String) -> String? {
            arguments.firstIndex(of: name).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        guard let audio = value("--whisper-probe"), let base = value("--whisper-base") else { return false }
        Task { @MainActor in
            let baseURL = URL(fileURLWithPath: base, isDirectory: true)
            do {
                let pipe = try await WhisperKit(WhisperKitConfig(
                    model: TranscriptionService.model, downloadBase: baseURL,
                    modelFolder: TranscriptionService.modelFolder(in: baseURL).path, download: false))
                print("WHISPER-PROBE compute audioEncoder=\(pipe.modelCompute.audioEncoderCompute.rawValue) textDecoder=\(pipe.modelCompute.textDecoderCompute.rawValue)")
                for words in [true, false] {
                    let options = DecodingOptions(task: .transcribe, language: "en", temperature: 0.0,
                                                  skipSpecialTokens: true, wordTimestamps: words)
                    let results = try await pipe.transcribe(audioPath: audio, decodeOptions: options)
                    for r in results {
                        print("WHISPER-PROBE wordTimestamps=\(words) text=\(r.text.prefix(120)) segments=\(r.segments.count) words=\(r.allWords.count)")
                        for s in r.segments.prefix(4) {
                            print(String(format: "WHISPER-PROBE   seg %.2f–%.2f noSpeech %.3f avgLogprob %.3f compression %.2f temp %.1f text=%@",
                                         s.start, s.end, s.noSpeechProb, s.avgLogprob, s.compressionRatio, s.temperature, String(s.text.prefix(60))))
                        }
                    }
                    if results.isEmpty { print("WHISPER-PROBE wordTimestamps=\(words) NO RESULTS") }
                }
            } catch {
                print("WHISPER-PROBE ERROR \(error)")
            }
            exit(0)
        }
        return true
    }
}
