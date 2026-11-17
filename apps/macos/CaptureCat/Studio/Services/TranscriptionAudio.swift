import Foundation

/// The speech engine's input — 16 kHz mono 16-bit — made by OUR code from
/// the decoder's float samples, identically on every platform.
///
/// Why not let AVAssetReader convert (it can): measured 2026-11-17 on the
/// same movie, the AAC decode agrees between the Mac and an iPhone 15 Pro Max
/// to far below one 16-bit step, but AVAssetReader's built-in 48 → 16 kHz
/// conversion does not — mean |Δ| 562 LSB, max 25,778 — and on the iPhone it
/// isn't even repeatable (two runs of one file: max 9,428). Word timings
/// followed (p90 boundary drift 0.06 s; with the Mac's exact WAV the phone's
/// timings were within 0.02 s). So the decode stays the system's and the
/// conversion is this file: plain scalar Double arithmetic in a fixed order
/// (no Accelerate, whose vector paths may differ per OS), so the same
/// samples give the same bytes on macOS and iOS.
///
/// Filter: Kaiser-windowed sinc (β 8, 16 zero crossings at the output rate,
/// cutoff 0.95 × the output Nyquist), polyphase over the exact rational
/// ratio, each phase normalized to unit DC gain. Channels are averaged.
enum TranscriptionAudio {
    static let outputRate = 16_000

    /// Float [-1, 1] → 16-bit, scaled by 32768 (Core Audio's convention),
    /// rounded to nearest (ties away from zero) and clamped.
    static func pcm16(_ v: Double) -> Int16 {
        Int16(clamping: Int((v * 32768).rounded(.toNearestOrAwayFromZero)))
    }

    /// Streams interleaved float frames at `inputRate` to mono `outputRate`.
    struct Resampler {
        let inputRate: Int
        let outputRate: Int
        let channels: Int
        /// Output step in input samples = m / l (reduced).
        private let l: Int
        private let m: Int
        private let halfTaps: Int
        /// weights[phase][j], j = 0 ... 2·halfTaps → input offset j − halfTaps.
        private let weights: [[Double]]
        /// Mono input not yet consumed; `buffer[0]` is input sample `base`.
        private var buffer: [Double] = []
        private var base = 0
        private var consumed = 0
        private var nextOutput = 0

        init(inputRate: Int, outputRate: Int = TranscriptionAudio.outputRate, channels: Int) {
            precondition(inputRate > 0 && outputRate > 0 && channels > 0)
            self.inputRate = inputRate
            self.outputRate = outputRate
            self.channels = channels
            var a = inputRate, b = outputRate
            while b != 0 { (a, b) = (b, a % b) }
            l = outputRate / a
            m = inputRate / a
            // Cutoff as a fraction of the INPUT Nyquist (downsampling only
            // lowers it; upsampling keeps the input band).
            let cutoff = 0.95 * min(1, Double(outputRate) / Double(inputRate))
            let zeroCrossings = 16.0
            let halfWidth = zeroCrossings / cutoff          // in input samples
            let taps = Int(halfWidth.rounded(.up)) + 1
            halfTaps = taps
            let phases = l
            let beta = 8.0
            let i0Beta = Self.besselI0(beta)
            weights = (0..<phases).map { phase in
                let frac = Double(phase) / Double(phases)
                var w = (0...(2 * taps)).map { j -> Double in
                    let t = frac - Double(j - taps)      // output time − input index
                    guard abs(t) < halfWidth else { return 0 }
                    let x = cutoff * t
                    let sinc = x == 0 ? 1 : sin(Double.pi * x) / (Double.pi * x)
                    let r = t / halfWidth
                    let window = Self.besselI0(beta * (1 - r * r).squareRoot()) / i0Beta
                    return cutoff * sinc * window
                }
                var sum = 0.0
                for v in w { sum += v }
                for k in w.indices { w[k] /= sum }
                return w
            }
        }

        /// Appends interleaved frames; returns the outputs now complete.
        mutating func push(_ interleaved: UnsafeBufferPointer<Float>) -> [Int16] {
            let frames = interleaved.count / channels
            buffer.reserveCapacity(buffer.count + frames)
            for f in 0..<frames {
                var s = 0.0
                for c in 0..<channels { s += Double(interleaved[f * channels + c]) }
                buffer.append(s / Double(channels))
            }
            consumed += frames
            return drain(final: false)
        }

        /// The outputs left once the input has ended (missing input = 0).
        mutating func finish() -> [Int16] { drain(final: true) }

        private mutating func drain(final: Bool) -> [Int16] {
            var out: [Int16] = []
            while true {
                // Output n sits at input time n·m/l: integer part i0, phase.
                let p = nextOutput * m
                if final {
                    guard p < consumed * l else { break }    // past the input's end
                } else {
                    guard p / l + halfTaps < consumed else { break }
                }
                let i0 = p / l, phase = p % l
                let w = weights[phase]
                var acc = 0.0
                for j in 0..<w.count {
                    let k = i0 + j - halfTaps - base
                    if k >= 0, k < buffer.count { acc += buffer[k] * w[j] }
                }
                out.append(TranscriptionAudio.pcm16(acc))
                nextOutput += 1
            }
            // Keep only what the next output can still reach.
            let keepFrom = (nextOutput * m) / l - halfTaps - base
            if keepFrom > 0 {
                let drop = min(keepFrom, buffer.count)
                buffer.removeFirst(drop)
                base += drop
            }
            return out
        }

        /// Modified Bessel function of the first kind, order 0 (series).
        static func besselI0(_ x: Double) -> Double {
            var sum = 1.0, term = 1.0
            let q = x * x / 4
            var k = 1.0
            while term > 1e-17 * sum {
                term *= q / (k * k)
                sum += term
                k += 1
            }
            return sum
        }
    }

    /// A 16 kHz mono 16-bit PCM WAV around `samples`.
    static func wav(_ samples: [Int16]) -> Data {
        // Every Apple platform is little-endian, as WAV is.
        let pcm = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        var wav = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        wav.append(contentsOf: Array("RIFF".utf8)); u32(36 + UInt32(pcm.count))
        wav.append(contentsOf: Array("WAVE".utf8))
        wav.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1); u16(1); u32(UInt32(outputRate)); u32(UInt32(outputRate * 2)); u16(2); u16(16)
        wav.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count))
        wav.append(pcm)
        return wav
    }
}
