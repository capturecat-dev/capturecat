import Foundation
import AVFoundation
import WhisperKit

@Observable
final class TranscriptionService {
    var isTranscribing = false
    var progress: String = ""
    var error: String?

    private var whisperKit: WhisperKit?

    func transcribe(videoURL: URL, language: String = "en") async throws -> [SubtitleSegment] {
        isTranscribing = true
        progress = "Loading model..."
        error = nil
        defer { isTranscribing = false }

        // Initialize WhisperKit (downloads base.en model on first use ~150MB)
        if whisperKit == nil {
            whisperKit = try await WhisperKit(
                WhisperKitConfig(model: "base.en")
            )
        }

        // Extract audio to 16kHz mono WAV via AVAssetReader
        progress = "Extracting audio..."
        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        try await extractAudio(from: videoURL, to: wavURL)

        // Transcribe with word-level timestamps
        progress = "Transcribing..."
        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            temperature: 0.0,
            skipSpecialTokens: true,
            wordTimestamps: true
        )
        let results = try await whisperKit!.transcribe(
            audioPath: wavURL.path,
            decodeOptions: options
        )

        try? FileManager.default.removeItem(at: wavURL)

        // Map word timings → SubtitleSegment, then group
        progress = "Processing subtitles..."
        var words: [SubtitleSegment] = []
        for result in results {
            for word in result.allWords {
                words.append(SubtitleSegment(
                    startTime: TimeInterval(word.start),
                    endTime: TimeInterval(word.end),
                    text: word.word.trimmingCharacters(in: CharacterSet.whitespaces)
                ))
            }
        }

        let grouped = SubtitleSegment.groupWords(words)
        progress = "Done — \(grouped.count) subtitles"
        return grouped
    }

    /// Extract audio to 16kHz mono WAV using AVAssetReader (sandbox-safe, no Process)
    private func extractAudio(from videoURL: URL, to wavURL: URL) async throws {
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
