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
        progress = "Loading model..."
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
        progress = "Extracting audio..."
        fraction = 0.1
        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        try await extractAudio(from: videoURL, to: wavURL)

        // Transcribe with word-level timestamps
        progress = "Transcribing..."
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
        progress = "Processing subtitles..."
        fraction = 0.95
        let grouped = Self.subtitles(fromWords: results.flatMap { result in
            result.allWords.map { (start: $0.start, end: $0.end, word: $0.word) }
        })
        progress = "Done — \(grouped.count) subtitles"
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

    /// Extract audio to 16kHz mono WAV using AVAssetReader (sandbox-safe, no Process)
    func extractAudio(from videoURL: URL, to wavURL: URL) async throws {
        let asset = AVURLAsset(url: videoURL)
        // Prefer mic track (last) over system audio (first) for speech transcription
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).last else {
            throw TranscriptionError.audioExtractionFailed("No audio track found")
        }

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        reader.add(readerOutput)
        reader.startReading()

        // Write WAV file
        var pcmData = Data()
        while let sampleBuffer = readerOutput.copyNextSampleBuffer(),
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                        totalLengthOut: &length, dataPointerOut: &dataPointer)
            if let dataPointer, length > 0 {
                pcmData.append(UnsafeBufferPointer(start: dataPointer, count: length))
            }
        }

        // Build WAV header + write
        var wav = Data()
        let headerSize: UInt32 = 44
        let dataSize = UInt32(pcmData.count)
        wav.append("RIFF".data(using: .ascii)!)
        wav.append(withUnsafeBytes(of: (headerSize - 8 + dataSize).littleEndian) { Data($0) })
        wav.append("WAVE".data(using: .ascii)!)
        wav.append("fmt ".data(using: .ascii)!)
        wav.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })  // chunk size
        wav.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })   // PCM
        wav.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })   // mono
        wav.append(withUnsafeBytes(of: UInt32(16000).littleEndian) { Data($0) }) // sample rate
        wav.append(withUnsafeBytes(of: UInt32(32000).littleEndian) { Data($0) }) // byte rate
        wav.append(withUnsafeBytes(of: UInt16(2).littleEndian) { Data($0) })   // block align
        wav.append(withUnsafeBytes(of: UInt16(16).littleEndian) { Data($0) })  // bits per sample
        wav.append("data".data(using: .ascii)!)
        wav.append(withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })
        wav.append(pcmData)
        try wav.write(to: wavURL)
    }
}

enum TranscriptionError: LocalizedError {
    case audioExtractionFailed(String)
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .audioExtractionFailed(let msg): "Audio extraction failed: \(msg)"
        case .transcriptionFailed(let msg): "Transcription failed: \(msg)"
        }
    }
}
