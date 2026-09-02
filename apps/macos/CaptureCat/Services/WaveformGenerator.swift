import AVFoundation

enum WaveformGenerator {
    static func generate(
        from url: URL,
        sampleCount: Int,
        trackIndex: Int = 0,
        timeRange: CMTimeRange? = nil
    ) async -> [Float] {
        await Task.detached(priority: .userInitiated) {
            await extractSamples(from: url, sampleCount: sampleCount, trackIndex: trackIndex, timeRange: timeRange)
        }.value
    }

    /// Returns the number of audio tracks in the file.
    static func audioTrackCount(for url: URL) async -> Int {
        let asset = AVURLAsset(url: url)
        let tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        return tracks.count
    }

    private static func extractSamples(
        from url: URL,
        sampleCount: Int,
        trackIndex: Int,
        timeRange: CMTimeRange?
    ) async -> [Float] {
        let asset = AVURLAsset(url: url)

        // System audio is track 0, mic is track 1
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        guard trackIndex < audioTracks.count else { return [] }
        let track = audioTracks[trackIndex]

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        guard let reader = try? AVAssetReader(asset: asset) else { return [] }
        if let timeRange {
            reader.timeRange = timeRange
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        reader.add(output)
        guard reader.startReading() else { return [] }

        var allSamples = [Int16]()
        allSamples.reserveCapacity(48000 * 30) // pre-allocate for ~30s of audio

        while let buffer = output.copyNextSampleBuffer(),
              let blockBuffer = CMSampleBufferGetDataBuffer(buffer) {
            let length = CMBlockBufferGetDataLength(blockBuffer)
            var data = Data(count: length)
            _ = data.withUnsafeMutableBytes { ptr in
                CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: ptr.baseAddress!)
            }
            let int16Samples = data.withUnsafeBytes {
                Array($0.bindMemory(to: Int16.self))
            }
            allSamples.append(contentsOf: int16Samples)
        }

        guard !allSamples.isEmpty, sampleCount > 0 else { return [] }

        let samplesPerBucket = max(1, allSamples.count / sampleCount)
        var buckets = [Float]()
        buckets.reserveCapacity(sampleCount)

        for i in 0..<sampleCount {
            let start = i * samplesPerBucket
            let end = min(start + samplesPerBucket, allSamples.count)
            guard start < allSamples.count else {
                buckets.append(0)
                continue
            }
            var maxVal: Int16 = 0
            for j in start..<end {
                let v = allSamples[j]
                let abs = v < 0 ? -v : v
                if abs > maxVal { maxVal = abs }
            }
            buckets.append(Float(maxVal) / Float(Int16.max))
        }

        // Normalize to peak so the loudest bar fills the full track height.
        // Mic recordings are rarely near Int16.max — without this they appear
        // as tiny flat lines even when the speaker is loud.
        let peak = buckets.max() ?? 0
        if peak > 0.01 {
            let scale = 1.0 / peak
            return buckets.map { min(1.0, $0 * scale) }
        }

        return buckets
    }
}
