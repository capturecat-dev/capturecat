import AVFoundation

/// Click sound styles — all synthesized (nothing to license). Raw values are
/// persistence identity.
enum ClickSoundStyle: String, CaseIterable, Codable, Sendable {
    case softTick = "Soft Tick"
    case clicky = "Clicky"
    case deep = "Deep"
    case pop = "Pop"
}

/// Synthesized mouse-click tick — generated in code, so there is nothing to
/// license. One shared sample set feeds BOTH the live preview (player node)
/// and the exporter (a cached WAV inserted into the audio composition), so
/// what you hear in the editor is exactly what the file contains.
final class ClickSoundPlayer {
    static let shared = ClickSoundPlayer()

    static let sampleRate: Double = 48_000
    static let tickDuration: TimeInterval = 0.07

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var buffers: [ClickSoundStyle: AVAudioPCMBuffer] = [:]
    private var isRunning = false

    private init() {}

    /// Each style is a fast-decay transient — different bodies, same length
    /// buffer (padded with silence) so composition timing is uniform.
    static func tickSamples(style: ClickSoundStyle) -> [Float] {
        let count = Int(sampleRate * tickDuration)
        var samples = [Float](repeating: 0, count: count)
        var seed: UInt32 = 0x9E3779B9
        for i in 0..<count {
            let t = Double(i) / sampleRate
            let body: Double
            let noiseAmp: Double
            switch style {
            case .softTick:
                body = exp(-t * 180)
                    * (0.6 * sin(2 * .pi * 2600 * t) + 0.25 * sin(2 * .pi * 1300 * t))
                noiseAmp = 0.12 * exp(-t * 420)
            case .clicky:
                body = exp(-t * 280)
                    * (0.7 * sin(2 * .pi * 3600 * t) + 0.2 * sin(2 * .pi * 1800 * t))
                noiseAmp = 0.22 * exp(-t * 650)
            case .deep:
                body = exp(-t * 110)
                    * (0.7 * sin(2 * .pi * 750 * t) + 0.25 * sin(2 * .pi * 380 * t))
                noiseAmp = 0.08 * exp(-t * 300)
            case .pop:
                // Downward pitch sweep 1200→300 Hz — a rounded "pop".
                let phase = 2 * .pi * (1200 * t - 6400 * t * t)
                body = exp(-t * 90) * 0.8 * sin(phase)
                noiseAmp = 0.05 * exp(-t * 250)
            }
            // Deterministic cheap noise (xorshift) for the contact "snap".
            seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
            let noise = (Double(seed % 2000) / 1000 - 1) * noiseAmp
            samples[i] = Float(max(-1, min(1, body + noise)))
        }
        return samples
    }

    /// WAV of the tick for the export composition — cached per style/launch.
    static func tickFileURL(style: ClickSoundStyle) throws -> URL {
        let slug = style.rawValue.lowercased().replacingOccurrences(of: " ", with: "-")
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("capturecat-click-\(slug).wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let samples = tickSamples(style: style)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        try file.write(from: buf)
        return url
    }

    private func startIfNeeded() {
        guard !isRunning else { return }
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1)!
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            node.play()
            isRunning = true
        } catch {
            // No audio device — stay silent rather than fail. The error is
            // kept for --clicksound-probe: a silently-cached start failure
            // once made every click sound vanish with zero trace.
            lastStartError = error
        }
    }

    /// Diagnostics for `--clicksound-probe`.
    var probeState: (running: Bool, error: String?) {
        (isRunning, lastStartError.map { "\($0)" })
    }
    private var lastStartError: Error?

    private func buffer(for style: ClickSoundStyle) -> AVAudioPCMBuffer? {
        if let cached = buffers[style] { return cached }
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1)!
        let samples = Self.tickSamples(style: style)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        buffers[style] = buf
        return buf
    }

    private var lastPreviewTime: CFTimeInterval = 0

    /// Throttled tick for UI feedback (slider drags fire onChange
    /// continuously — unthrottled that's a machine gun).
    func playPreview(volume: Double, style: ClickSoundStyle) {
        let now = CACurrentMediaTime()
        guard now - lastPreviewTime >= 0.15 else { return }
        lastPreviewTime = now
        play(volume: volume, style: style)
    }

    /// Play one tick at `volume` (0…1). Safe to call from the main actor per
    /// playback tick; overlapping schedules just layer.
    func play(volume: Double, style: ClickSoundStyle) {
        startIfNeeded()
        guard isRunning, let buffer = buffer(for: style) else { return }
        node.volume = Float(max(0, min(1, volume)))
        node.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
    }
}
