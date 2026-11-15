import AVFoundation
import QuartzCore

/// Keyboard sound styles — all synthesized (nothing to license). Raw values
/// are persistence identity.
enum KeySoundStyle: String, CaseIterable, Codable, Sendable {
    case thock = "Thock"
    case clacky = "Clacky"
    case soft = "Soft"
    /// Deep, muted "creamy" linear board — lubed switches on a gasket mount.
    case cream = "Cream"
    /// Clicky blue-switch style — sharp high click with a metallic ring.
    case blueClick = "Blue Click"
    /// Vintage typewriter — metallic strike with a heavy noise burst.
    case typewriter = "Typewriter"
    /// Rubber-dome laptop board — quiet, dull, short.
    case membrane = "Membrane"
}

/// Synthesized keystroke sounds. Every keystroke gets a DETERMINISTIC pitch/
/// level variation seeded from its timestamp, so typing sounds organic while
/// the preview and the exported file render the identical audio.
final class KeySoundPlayer {
    static let shared = KeySoundPlayer()

    static let sampleRate: Double = 48_000
    /// Per-keystroke sample length (60ms) — the render tail fits comfortably.
    static let strokeDuration: TimeInterval = 0.06
    /// Density floor shared by preview and export. Sounds are 1:1 with
    /// recorded keystrokes — this only merges events closer than one video
    /// frame (chords / same-millisecond rollover), where separate onsets are
    /// inaudible anyway. The old 50ms cap silently dropped every other key of
    /// fast typing (real rollover is ~30ms).
    static let minInterval: TimeInterval = 0.008

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var isRunning = false
    /// Live-playback buffer cache: style + category class + pitch bucket.
    private var buffers: [String: AVAudioPCMBuffer] = [:]
    private var lastPreviewTime: CFTimeInterval = 0

    private init() {}

    // MARK: - Deterministic variation

    /// (pitchFactor, levelFactor) for a keystroke — pure function of the
    /// timestamp and category so both renderers agree exactly.
    static func variation(
        timestamp: TimeInterval,
        category: KeystrokeEvent.Category
    ) -> (pitch: Double, level: Double) {
        // Hash the millisecond timestamp into two stable uniforms.
        var seed = UInt64(bitPattern: Int64((timestamp * 1000).rounded()))
        seed ^= 0x9E3779B97F4A7C15
        seed = seed &* 0xBF58476D1CE4E5B9
        seed ^= seed >> 27
        let u1 = Double(seed % 10_000) / 10_000
        seed = seed &* 0x94D049BB133111EB
        seed ^= seed >> 31
        let u2 = Double(seed % 10_000) / 10_000

        var pitch = 0.94 + u1 * 0.12   // ±6%
        var level = 0.85 + u2 * 0.30   // ±15%
        switch category {
        case .space, .return:
            pitch *= 0.85              // deeper
            level *= 1.15              // a touch louder
        case .modifier:
            level *= 0.6               // quieter
        case .key, .delete:
            break
        case .scroll:
            level = 0                  // scroll ticks are silent by definition
        }
        return (pitch, level)
    }

    // MARK: - Synthesis

    /// One keystroke's samples for a style at a pitch factor, unit level.
    static func strokeSamples(style: KeySoundStyle, pitch: Double) -> [Float] {
        let count = Int(sampleRate * strokeDuration)
        var samples = [Float](repeating: 0, count: count)
        var seed: UInt32 = 0x5F3759DF
        for i in 0..<count {
            let t = Double(i) / sampleRate
            let body: Double
            let noiseAmp: Double
            switch style {
            case .thock:
                body = exp(-t * 140)
                    * (0.7 * sin(2 * .pi * 620 * pitch * t) + 0.25 * sin(2 * .pi * 310 * pitch * t))
                noiseAmp = 0.10 * exp(-t * 380)
            case .clacky:
                body = exp(-t * 240)
                    * (0.55 * sin(2 * .pi * 2400 * pitch * t) + 0.3 * sin(2 * .pi * 1150 * pitch * t))
                noiseAmp = 0.25 * exp(-t * 620)
            case .soft:
                body = exp(-t * 200)
                    * (0.4 * sin(2 * .pi * 900 * pitch * t) + 0.2 * sin(2 * .pi * 450 * pitch * t))
                noiseAmp = 0.16 * exp(-t * 300)
            case .cream:
                body = exp(-t * 120)
                    * (0.65 * sin(2 * .pi * 480 * pitch * t) + 0.3 * sin(2 * .pi * 240 * pitch * t))
                noiseAmp = 0.07 * exp(-t * 340)
            case .blueClick:
                // Sharp click at the attack plus a short metallic ring.
                body = exp(-t * 320)
                    * (0.5 * sin(2 * .pi * 3200 * pitch * t) + 0.3 * sin(2 * .pi * 1600 * pitch * t))
                noiseAmp = 0.38 * exp(-t * 900)
            case .typewriter:
                body = exp(-t * 170)
                    * (0.35 * sin(2 * .pi * 1800 * pitch * t)
                        + 0.3 * sin(2 * .pi * 2700 * pitch * t)
                        + 0.25 * sin(2 * .pi * 900 * pitch * t))
                noiseAmp = 0.4 * exp(-t * 480)
            case .membrane:
                body = exp(-t * 260)
                    * (0.35 * sin(2 * .pi * 520 * pitch * t) + 0.2 * sin(2 * .pi * 260 * pitch * t))
                noiseAmp = 0.12 * exp(-t * 420)
            }
            seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
            let noise = (Double(seed % 2000) / 1000 - 1) * noiseAmp
            samples[i] = Float(max(-1, min(1, body + noise)))
        }
        return samples
    }

    // MARK: - Live playback (preview + UI test)

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
            // No audio device — stay silent rather than fail.
        }
    }

    /// Play one keystroke live. Pitch is bucketed (12 steps) for buffer reuse;
    /// exact level rides the node volume.
    func play(
        timestamp: TimeInterval,
        category: KeystrokeEvent.Category,
        volume: Double,
        style: KeySoundStyle
    ) {
        startIfNeeded()
        guard isRunning else { return }
        let v = Self.variation(timestamp: timestamp, category: category)
        let bucket = Int((v.pitch - 0.75) / 0.03)
        let bucketedPitch = 0.75 + Double(bucket) * 0.03
        let key = "\(style.rawValue)-\(bucket)"
        let buffer: AVAudioPCMBuffer
        if let cached = buffers[key] {
            buffer = cached
        } else {
            let samples = Self.strokeSamples(style: style, pitch: bucketedPitch)
            let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1)!
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
            buf.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { src in
                buf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
            }
            buffers[key] = buf
            buffer = buf
        }
        node.volume = Float(max(0, min(1, volume * v.level)))
        node.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
    }

    /// UI "Test": a short deterministic typing burst ("the quick" rhythm).
    func playTestBurst(volume: Double, style: KeySoundStyle) {
        let now = CACurrentMediaTime()
        guard now - lastPreviewTime >= 0.4 else { return }
        lastPreviewTime = now
        let pattern: [(TimeInterval, KeystrokeEvent.Category)] = [
            (0.00, .key), (0.09, .key), (0.17, .key),
            (0.32, .space),
            (0.41, .key), (0.50, .key), (0.58, .key), (0.66, .key), (0.74, .key),
        ]
        for (offset, category) in pattern {
            DispatchQueue.main.asyncAfter(deadline: .now() + offset) { [weak self] in
                guard let self else { return }
                // Seed with the offset so each burst key varies but the burst
                // itself always sounds the same.
                self.play(timestamp: 1000 + offset, category: category, volume: volume, style: style)
            }
        }
    }

    // MARK: - Export track rendering

    /// Renders the WHOLE keystroke track as one mono WAV (unit gain — the mix
    /// applies the user volume), using the exact per-event synthesis the
    /// preview plays. `events` carry OUTPUT-time already (retimed through the
    /// speed map) plus the SOURCE timestamp as the variation seed. Density is
    /// capped at one stroke per `minInterval`.
    static func renderTrackWAV(
        events: [(outputTime: TimeInterval, seedTimestamp: TimeInterval, category: KeystrokeEvent.Category)],
        duration: TimeInterval,
        style: KeySoundStyle
    ) throws -> URL {
        let frameCount = Int((duration + strokeDuration) * sampleRate)
        var track = [Float](repeating: 0, count: max(1, frameCount))

        var lastTime = -Double.infinity
        for event in events.sorted(by: { $0.outputTime < $1.outputTime }) {
            guard event.outputTime - lastTime >= minInterval else { continue }
            lastTime = event.outputTime
            let v = variation(timestamp: event.seedTimestamp, category: event.category)
            let samples = strokeSamples(style: style, pitch: v.pitch)
            let start = Int(event.outputTime * sampleRate)
            guard start >= 0 else { continue }
            let level = Float(v.level)
            for (i, s) in samples.enumerated() {
                let idx = start + i
                guard idx < track.count else { break }
                track[idx] = max(-1, min(1, track[idx] + s * level))
            }
        }

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("capturecat-keys-\(UUID().uuidString.prefix(8)).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(track.count)) else {
            throw NSError(domain: "KeySoundPlayer", code: 1)
        }
        buf.frameLength = AVAudioFrameCount(track.count)
        track.withUnsafeBufferPointer { src in
            buf.floatChannelData![0].update(from: src.baseAddress!, count: track.count)
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
}
