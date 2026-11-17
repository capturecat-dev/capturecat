import Foundation

/// `--transcription-audio-test`: the shared 16 kHz conversion
/// (Studio/Services/TranscriptionAudio) on synthetic tones. Its cross-platform
/// half is the features gate's engine-input check (Mac WAV vs iOS WAV ≤ 1 LSB).
///
///   - pieces of any size give the same bytes (streaming is exact)
///   - output length = ⌈input · 16 kHz / rate⌉ at every common rate
///   - 1 kHz passes at full level; 7 kHz within 1 dB (the roll-off starts
///     just above it); 9 kHz at 48 kHz — which would fold onto 7 kHz — is
///     rejected by 60 dB or more
///   - channels average (opposite stereo phases cancel)
///   - the same input twice gives the same bytes
enum TranscriptionAudioHarness {
    static func run() -> Never {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String) {
            print("TRANSCRIPTION-AUDIO \(ok ? "PASS" : "FAIL") \(name) — \(detail)")
            if !ok { failures += 1 }
        }
        func convert(_ x: [Float], rate: Int, channels: Int = 1, piece: Int) -> [Int16] {
            var r = TranscriptionAudio.Resampler(inputRate: rate, channels: channels)
            var out: [Int16] = []
            var i = 0
            while i < x.count {
                let n = min(piece * channels, x.count - i)
                x[i..<(i + n)].withUnsafeBufferPointer { out += r.push($0) }
                i += n
            }
            return out + r.finish()
        }
        func tone(_ hz: Double, rate: Int, seconds: Double, amplitude: Double = 0.5) -> [Float] {
            (0..<Int(Double(rate) * seconds)).map { Float(amplitude * sin(2 * .pi * hz * Double($0) / Double(rate))) }
        }
        func rms(_ y: [Int16]) -> Double {
            let mid = y[(y.count / 4)..<(3 * y.count / 4)]
            var s = 0.0
            for v in mid { s += Double(v) * Double(v) }
            return (s / Double(mid.count)).squareRoot() / 32768
        }
        let full = 0.5 / 2.0.squareRoot()
        func db(_ v: Double) -> Double { 20 * log10(max(v, 1e-12) / full) }

        for rate in [48_000, 44_100, 32_000, 22_050, 16_000, 8_000] {
            let x = tone(1000, rate: rate, seconds: 2)
            let a = convert(x, rate: rate, piece: 1024), b = convert(x, rate: rate, piece: 333)
            let expected = (x.count * 16_000 + rate - 1) / rate
            check("\(rate) Hz streaming exact", a == b, "\(a.count) samples, pieces of 1024 vs 333")
            check("\(rate) Hz length", a.count == expected, "\(a.count) vs \(expected)")
            check("\(rate) Hz 1 kHz level", abs(db(rms(a))) < 0.05, String(format: "%.3f dB", db(rms(a))))
        }
        let inBand = convert(tone(7000, rate: 48_000, seconds: 2), rate: 48_000, piece: 4096)
        check("7 kHz within 1 dB", abs(db(rms(inBand))) < 1, String(format: "%.3f dB", db(rms(inBand))))
        let alias = convert(tone(9000, rate: 48_000, seconds: 2), rate: 48_000, piece: 4096)
        check("9 kHz rejected (≥ 60 dB)", db(rms(alias)) <= -60, String(format: "%.1f dB", db(rms(alias))))
        var stereo: [Float] = []
        for v in tone(1000, rate: 48_000, seconds: 1) { stereo.append(v); stereo.append(-v) }
        let cancelled = convert(stereo, rate: 48_000, channels: 2, piece: 500)
        check("stereo channels average", rms(cancelled) < 1e-4, String(format: "rms %.6f", rms(cancelled)))
        let speech = tone(220, rate: 44_100, seconds: 3).enumerated().map { $0.element * Float(1 + 0.5 * sin(Double($0.offset) / 900)) }
        check("repeatable", convert(speech, rate: 44_100, piece: 777) == convert(speech, rate: 44_100, piece: 777), "same input twice")

        print("TRANSCRIPTION-AUDIO \(failures == 0 ? "PASS" : "FAIL") (\(failures) failing)")
        exit(failures == 0 ? 0 : 1)
    }
}
