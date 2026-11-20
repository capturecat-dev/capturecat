import Foundation
import AVFoundation
import Observation
#if canImport(WhisperKit)
import CoreML
import WhisperKit
#endif

/// Speech → subtitles, shared by the Mac editor, the MCP `transcribe` tool
/// and the iOS studio (Studio 4e): WhisperKit `base.en` on device, word
/// timestamps, grouped by `SubtitleSegment.groupWords` — one engine and one
/// model on every platform, so a recording gets the same subtitle structure
/// wherever it is transcribed (Phase 0 measured WhisperKit on iOS: 20×
/// realtime, 232 MB).
///
/// Both apps link WhisperKit; `studio-canary.sh` typechecks Studio/ with no
/// packages, so the engine sits behind `canImport(WhisperKit)` there.
@Observable
final class TranscriptionService {
    var isTranscribing = false
    var progress: String = ""
    var error: String?
    /// 0…1 across the stages (model, audio, decoding, grouping) — the iOS
    /// sheet's bar. The stage strings above are unchanged.
    var fraction: Double = 0
    /// The first stage's line — compare `progress` against this, not a literal.
    static let loadingModelProgress = String(localized: "Loading model...", comment: "Generate Subtitles progress line")

    /// Where the model lives. Both nil (the Mac's choice since it shipped):
    /// WhisperKit's default download location. `modelFolder` loads a model
    /// already on disk without the network (Phase 0 §3.7); `downloadBase`
    /// moves the download.
    @ObservationIgnored let modelFolder: URL?
    @ObservationIgnored let downloadBase: URL?
    /// Gate seam: run every model on the CPU (the iOS Simulator's only
    /// path), to attribute a Mac ↔ Simulator difference to compute units.
    /// False in the apps — WhisperKit picks the Neural Engine / GPU.
    @ObservationIgnored let cpuOnly: Bool

    #if canImport(WhisperKit)
    private var whisperKit: WhisperKit?
    #endif

    init(modelFolder: URL? = nil, downloadBase: URL? = nil, cpuOnly: Bool = false) {
        self.modelFolder = modelFolder
        self.downloadBase = downloadBase
        self.cpuOnly = cpuOnly
    }

    static let model = "base.en"

    /// Where WhisperKit keeps the model under a download base (the
    /// tokenizer lands beside it, under `models/openai/`).
    static func modelFolder(in downloadBase: URL) -> URL {
        downloadBase.appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-\(model)", isDirectory: true)
    }

    /// Downloads the model into `downloadBase` (WhisperKit's own fetch — the
    /// apps do this inside `transcribe` on first use; gates call it once).
    static func fetchModel(into downloadBase: URL) async throws -> URL {
        #if canImport(WhisperKit)
        return try await WhisperKit.download(variant: model, downloadBase: downloadBase)
        #else
        throw TranscriptionError.transcriptionFailed("this build has no speech engine (WhisperKit is not linked)")
        #endif
    }

    func transcribe(videoURL: URL, language: String = "en") async throws -> [SubtitleSegment] {
        #if canImport(WhisperKit)
        isTranscribing = true
        progress = Self.loadingModelProgress
        fraction = 0
        error = nil
        defer { isTranscribing = false }

        // Initialize WhisperKit (downloads base.en model on first use ~150MB)
        if whisperKit == nil {
            if modelFolder == nil && downloadBase == nil {
                whisperKit = try await WhisperKit(
                    WhisperKitConfig(model: Self.model)
                )
            } else {
                let config = WhisperKitConfig(model: Self.model, downloadBase: downloadBase,
                                              modelFolder: modelFolder?.path, download: modelFolder == nil)
                if cpuOnly {
                    config.computeOptions = ModelComputeOptions(melCompute: .cpuOnly, audioEncoderCompute: .cpuOnly,
                                                                textDecoderCompute: .cpuOnly, prefillCompute: .cpuOnly)
                }
                whisperKit = try await WhisperKit(config)
            }
        }

        // Extract audio to 16kHz mono WAV via AVAssetReader
        progress = String(localized: "Extracting audio...", comment: "Generate Subtitles progress line")
        fraction = 0.1
        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        try await extractAudio(from: videoURL, to: wavURL)

        // Transcribe with word-level timestamps
        progress = String(localized: "Transcribing...", comment: "Generate Subtitles progress line")
        fraction = 0.15
        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            temperature: 0.0,
            skipSpecialTokens: true,
            wordTimestamps: true
        )
        // WhisperKit's own Progress, sampled for the bar (read-only: the
        // decode is unchanged).
        let pipe = whisperKit!
        let sampler = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let done = pipe.progress.fractionCompleted
                if done.isFinite, let self { self.fraction = 0.15 + 0.8 * min(1, max(0, done)) }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { sampler.cancel() }
        let results = try await pipe.transcribe(
            audioPath: wavURL.path,
            decodeOptions: options
        )
        sampler.cancel()

        try? FileManager.default.removeItem(at: wavURL)

        // Map word timings → SubtitleSegment, then group
        progress = String(localized: "Processing subtitles...", comment: "Generate Subtitles progress line")
        fraction = 0.95
        let grouped = Self.subtitles(fromWords: results.flatMap { result in
            result.allWords.map { (start: $0.start, end: $0.end, word: $0.word) }
        })
        progress = String(localized: "Done — \(grouped.count) subtitles", comment: "Generate Subtitles progress line")
        fraction = 1
        return grouped
        #else
        throw TranscriptionError.transcriptionFailed("this build has no speech engine (WhisperKit is not linked)")
        #endif
    }

    /// The engine's words (in order) → the project's subtitles: one segment
    /// per word, trimmed, then `SubtitleSegment.groupWords`.
    static func subtitles(fromWords words: [(start: Float, end: Float, word: String)]) -> [SubtitleSegment] {
        let segments = words.map { word in
            SubtitleSegment(
                startTime: TimeInterval(word.start),
                endTime: TimeInterval(word.end),
                text: word.word.trimmingCharacters(in: CharacterSet.whitespaces)
            )
        }
        return SubtitleSegment.groupWords(segments)
    }

    /// Extract audio to 16 kHz mono 16-bit WAV: AVAssetReader decodes the
    /// track to float at its own rate and channel count; the conversion to
    /// the engine's format is `TranscriptionAudio` (ours, identical on every
    /// platform — AVAssetReader's built-in resample is not; see that file).
    func extractAudio(from videoURL: URL, to wavURL: URL) async throws {
        let asset = AVURLAsset(url: videoURL)
        // Prefer mic track (last) over system audio (first) for speech transcription
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).last else {
            throw TranscriptionError.audioExtractionFailed(String(localized: "No audio track found", comment: "Transcription error detail"))
        }

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        reader.add(readerOutput)
        reader.startReading()

        var resampler: TranscriptionAudio.Resampler?
        var samples: [Int16] = []
        while let sampleBuffer = readerOutput.copyNextSampleBuffer(),
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
            if resampler == nil {
                guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
                      let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                      asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0 else {
                    throw TranscriptionError.audioExtractionFailed(String(localized: "Unreadable audio format", comment: "Transcription error detail"))
                }
                resampler = TranscriptionAudio.Resampler(inputRate: Int(asbd.mSampleRate.rounded()),
                                                         channels: Int(asbd.mChannelsPerFrame))
            }
            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                        totalLengthOut: &length, dataPointerOut: &dataPointer)
            if let dataPointer, length > 0 {
                let floats = dataPointer.withMemoryRebound(to: Float.self, capacity: length / 4) {
                    UnsafeBufferPointer(start: $0, count: length / 4)
                }
                samples.append(contentsOf: resampler!.push(floats))
            }
        }
        if reader.status == .failed {
            throw TranscriptionError.audioExtractionFailed(reader.error?.localizedDescription ?? String(localized: "Audio decode failed", comment: "Transcription error detail"))
        }
        if var r = resampler { samples.append(contentsOf: r.finish()) }
        try TranscriptionAudio.wav(samples).write(to: wavURL)
    }
}

enum TranscriptionError: LocalizedError {
    case audioExtractionFailed(String)
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .audioExtractionFailed(let msg): String(localized: "Audio extraction failed: \(msg)", comment: "Transcription error; %@ is a detail")
        case .transcriptionFailed(let msg): String(localized: "Transcription failed: \(msg)", comment: "Transcription error; %@ is a detail")
        }
    }
}
