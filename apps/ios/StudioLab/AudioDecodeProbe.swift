import AVFoundation
import Foundation

/// `--audio-decode-probe <movie> <outDir>` — splits transcription's audio
/// extraction (TranscriptionService.extractAudio: one AVAssetReader that
/// decodes AAC AND resamples to 16 kHz mono) into its two stages, so a
/// device run can say which one differs from the Mac:
///
///   decode.f32   the last audio track decoded at its own rate and channel
///                count (float32, interleaved) — the AAC decoder alone
///   s16k.i16     the shipping conversion (16 kHz mono int16)
///
/// The Mac runs this same file (`swift` with a two-line main) on the same
/// movie; apps/ios/scripts/ios-device-features.sh's notes say how.
enum AudioDecodeProbe {
    static func start(_ arguments: [String]) -> Bool {
        guard let i = arguments.firstIndex(of: "--audio-decode-probe"), arguments.indices.contains(i + 2) else { return false }
        let input = LabPath.url(arguments[i + 1], isDirectory: false)
        let out = LabPath.url(arguments[i + 2])
        Task {
            do {
                try await run(input: input, out: out)
                print("AUDIO-DECODE-PROBE DONE \(out.path)")
                exit(0)
            } catch {
                print("AUDIO-DECODE-PROBE FAIL \(error)")
                exit(1)
            }
        }
        return true
    }

    static func run(input: URL, out: URL) async throws {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let asset = AVURLAsset(url: input)
        guard let track = try await asset.loadTracks(withMediaType: .audio).last else {
            throw NSError(domain: "AudioDecodeProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "no audio track"])
        }
        let decode = try read(asset: asset, track: track, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        try decode.write(to: out.appendingPathComponent("decode.f32"))
        let s16k = try read(asset: asset, track: track, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        try s16k.write(to: out.appendingPathComponent("s16k.i16"))
        let desc = try await track.load(.formatDescriptions).first
        let asbd = desc.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        let info = "rate=\(asbd?.mSampleRate ?? 0) channels=\(asbd?.mChannelsPerFrame ?? 0) decodeBytes=\(decode.count) s16kBytes=\(s16k.count)"
        try info.write(to: out.appendingPathComponent("info.txt"), atomically: true, encoding: .utf8)
        print("AUDIO-DECODE-PROBE \(info)")
    }

    private static func read(asset: AVAsset, track: AVAssetTrack, settings: [String: Any]) throws -> Data {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        reader.startReading()
        var data = Data()
        while let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
            if let pointer, length > 0 { data.append(UnsafeBufferPointer(start: pointer, count: length)) }
        }
        return data
    }
}
