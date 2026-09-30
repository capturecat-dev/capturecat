// Records apps/web/src/editor/core/vectors/golden/waveformPeaks.json — the
// golden for the web's port of the Mac timeline waveform
// (core/audio/waveformPeaks.ts) — from the REAL Swift: this driver is
// compiled TOGETHER WITH the app's own Services/WaveformGenerator.swift (no
// copy), writes synthetic WAV files into a scratch dir, and records what
// `WaveformGenerator.generate(from:sampleCount:trackIndex:timeRange:)`
// returns for them (AVAssetReader → 16-bit interleaved LPCM → buckets →
// peak normalisation). Synthetic data only.
//
//   xcrun swiftc -O apps/macos/CaptureCat/Services/WaveformGenerator.swift \
//     apps/web/scripts/waveform-golden/record.swift -o "$TMPDIR/wf-record"
//   "$TMPDIR/wf-record" "$TMPDIR/wf-scratch" > apps/web/src/editor/core/vectors/golden/waveformPeaks.json
//
// The TS suite (core/vectors/waveformPeaks.test.ts) regenerates the same PCM
// from each case's spec (xorshift32 — see `Signal` below) and must match
// every Float exactly.
import AVFoundation

struct XorShift32 {
    var state: UInt32
    mutating func next() -> UInt32 {
        state ^= state << 13
        state ^= state >> 17
        state ^= state << 5
        return state
    }
}

struct Spec {
    var name: String
    var rate: Int
    var channels: Int
    /// "s16" (16-bit integer WAV) or "f32" (IEEE float WAV).
    var format: String
    var seed: UInt32
    /// (frames, per-channel amplitude): s16 amplitudes are Int16 units, f32 are full-scale fractions.
    var segments: [(Int, [Double])]
    var sampleCount: Int
    /// (start, duration) seconds, converted with CMTime(seconds:preferredTimescale: 600) like the app.
    var timeRange: (Double, Double)?
}

/// Interleaved samples as the WAV stores them (s16 values or f32 values, as Double).
func signal(_ spec: Spec) -> [Double] {
    var rng = XorShift32(state: spec.seed)
    var out: [Double] = []
    for (frames, amps) in spec.segments {
        for _ in 0..<frames {
            for c in 0..<spec.channels {
                let u = Double(rng.next()) / 4294967296.0
                let v = (u * 2 - 1) * amps[c]
                if spec.format == "s16" {
                    out.append(Double(Int16(v))) // truncates toward zero
                } else {
                    out.append(Double(Float(v)))
                }
            }
        }
    }
    return out
}

func writeWav(_ url: URL, spec: Spec, interleaved: [Double]) throws {
    var d = Data()
    func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
    func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
    let isFloat = spec.format == "f32"
    let bps = isFloat ? 4 : 2
    let dataBytes = interleaved.count * bps
    d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + dataBytes)); d.append("WAVE".data(using: .ascii)!)
    d.append("fmt ".data(using: .ascii)!); u32(16); u16(isFloat ? 3 : 1); u16(UInt16(spec.channels))
    u32(UInt32(spec.rate)); u32(UInt32(spec.rate * spec.channels * bps)); u16(UInt16(spec.channels * bps)); u16(UInt16(bps * 8))
    d.append("data".data(using: .ascii)!); u32(UInt32(dataBytes))
    for v in interleaved {
        if isFloat {
            var f = Float(v).bitPattern.littleEndian
            d.append(Data(bytes: &f, count: 4))
        } else {
            var s = Int16(v).littleEndian
            d.append(Data(bytes: &s, count: 2))
        }
    }
    try d.write(to: url)
}

func json(_ d: Double) -> String { d.isFinite ? "\(d)" : "null" }

@main
struct Record {
    static func main() async throws {
        let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory())
            .appendingPathComponent("waveform-golden", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let s = 48_000
        var specs: [Spec] = [
            Spec(name: "mono-s16-48k-full", rate: s, channels: 1, format: "s16", seed: 0x1234_5678,
                 segments: [(20_000, [9000]), (30_000, [300]), (12_000, [0]), (40_000, [22000]), (42_000, [4000])],
                 sampleCount: 180, timeRange: nil),
            Spec(name: "mono-s16-48k-range72", rate: s, channels: 1, format: "s16", seed: 0x1234_5678,
                 segments: [(20_000, [9000]), (30_000, [300]), (12_000, [0]), (40_000, [22000]), (42_000, [4000])],
                 sampleCount: 72, timeRange: (0.5, 1.2)),
            Spec(name: "stereo-s16-48k-full", rate: s, channels: 2, format: "s16", seed: 0xC0FF_EE01,
                 segments: [(24_000, [12000, 2000]), (24_000, [500, 26000]), (24_001, [7000, 7000])],
                 sampleCount: 180, timeRange: nil),
            Spec(name: "stereo-s16-48k-range", rate: s, channels: 2, format: "s16", seed: 0xC0FF_EE01,
                 segments: [(24_000, [12000, 2000]), (24_000, [500, 26000]), (24_001, [7000, 7000])],
                 sampleCount: 180, timeRange: (0.1234, 0.9)),
            Spec(name: "stereo-s16-48k-odd7", rate: s, channels: 2, format: "s16", seed: 0x0BAD_F00D,
                 segments: [(1_001, [3000, 11000]), (777, [16000, 100])],
                 sampleCount: 7, timeRange: nil),
            Spec(name: "stereo-f32-44k-range72", rate: 44_100, channels: 2, format: "f32", seed: 0x5EED_0001,
                 segments: [(30_000, [0.8, 0.3]), (40_000, [0.05, 0.6]), (30_000, [0.9999, 0.9999])],
                 sampleCount: 72, timeRange: (0.37, 1.01)),
            Spec(name: "mono-f32-44k-full", rate: 44_100, channels: 1, format: "f32", seed: 0x5EED_0002,
                 segments: [(10_000, [0.25]), (10_000, [0.000_5]), (10_000, [0.7])],
                 sampleCount: 180, timeRange: nil),
            Spec(name: "mono-s16-quiet-unnormalised", rate: s, channels: 1, format: "s16", seed: 0x0000_0101,
                 segments: [(48_000, [200])],
                 sampleCount: 180, timeRange: nil),
            Spec(name: "mono-s16-threshold-above", rate: s, channels: 1, format: "s16", seed: 0x0000_0202,
                 segments: [(9_000, [329]), (9_000, [120])],
                 sampleCount: 72, timeRange: nil),
            Spec(name: "mono-s16-threshold-below", rate: s, channels: 1, format: "s16", seed: 0x0000_0303,
                 segments: [(9_000, [327]), (9_000, [120])],
                 sampleCount: 72, timeRange: nil),
            Spec(name: "mono-s16-fewer-samples-than-buckets", rate: s, channels: 1, format: "s16", seed: 0x0000_0404,
                 segments: [(100, [15000])],
                 sampleCount: 180, timeRange: nil),
            Spec(name: "mono-s16-silence", rate: s, channels: 1, format: "s16", seed: 0x0000_0505,
                 segments: [(4_800, [0])],
                 sampleCount: 72, timeRange: nil),
            Spec(name: "stereo-s16-range-past-end", rate: s, channels: 2, format: "s16", seed: 0x0000_0606,
                 segments: [(96_000, [5000, 18000])],
                 sampleCount: 180, timeRange: (1.5, 5.0)),
            Spec(name: "mono-s16-22k-range", rate: 22_050, channels: 1, format: "s16", seed: 0x0000_0707,
                 segments: [(11_025, [1000]), (11_025, [30000]), (11_025, [8000])],
                 sampleCount: 72, timeRange: (0.2513, 0.9871)),
            Spec(name: "tri-s16-48k", rate: s, channels: 3, format: "s16", seed: 0x0000_0808,
                 segments: [(12_000, [100, 200, 20000]), (12_000, [9000, 50, 50])],
                 sampleCount: 72, timeRange: nil),
            Spec(name: "mono-s16-44k-halfframe-range", rate: 44_100, channels: 1, format: "s16", seed: 0x0000_0909,
                 segments: [(44_100, [12000])],
                 sampleCount: 72, timeRange: (7.0 / 600, 13.0 / 600)),
        ]
        // A long-ish recording-shaped case: 10 s stereo, 180 buckets over a trim window.
        specs.append(Spec(name: "stereo-s16-48k-10s-trim", rate: s, channels: 2, format: "s16", seed: 0xFACE_B00C,
                          segments: (0..<20).map { i in (24_000, [Double((i * 1_637) % 30_000), Double((i * 2_909) % 25_000)]) },
                          sampleCount: 180, timeRange: (0.6433333333333333, 8.9)))

        var cases: [String] = []
        for (index, spec) in specs.enumerated() {
            let url = dir.appendingPathComponent("case-\(index).wav")
            try writeWav(url, spec: spec, interleaved: signal(spec))
            var range: CMTimeRange?
            if let (start, duration) = spec.timeRange {
                range = CMTimeRange(
                    start: CMTime(seconds: start, preferredTimescale: 600),
                    duration: CMTime(seconds: duration, preferredTimescale: 600)
                )
            }
            let peaks = await WaveformGenerator.generate(from: url, sampleCount: spec.sampleCount, timeRange: range)
            let segs = spec.segments.map { "[\($0.0),[\($0.1.map(json).joined(separator: ","))]]" }.joined(separator: ",")
            let tr = spec.timeRange.map { "[\(json($0.0)),\(json($0.1))]" } ?? "null"
            let input = "{\"name\":\"\(spec.name)\",\"rate\":\(spec.rate),\"channels\":\(spec.channels),\"format\":\"\(spec.format)\",\"seed\":\(spec.seed),\"segments\":[\(segs)],\"sampleCount\":\(spec.sampleCount),\"timeRange\":\(tr)}"
            let output = "[\(peaks.map { json(Double($0)) }.joined(separator: ","))]"
            cases.append("{\"input\":\(input),\"output\":\(output)}")
        }
        let notes = "Recorded from the REAL Swift: apps/macos/CaptureCat/Services/WaveformGenerator.swift compiled with apps/web/scripts/waveform-golden/record.swift; WaveformGenerator.generate(from:sampleCount:trackIndex: 0,timeRange:) over synthetic WAVs (s16 / f32 IEEE float, mono…3 ch). timeRange is (start, duration) seconds through CMTime(seconds:preferredTimescale: 600). Outputs are Swift Floats widened to Double."
        print("{\"unit\":\"waveformPeaks\",\"notes\":\"\(notes)\",\"count\":\(cases.count),\"cases\":[\n\(cases.joined(separator: ",\n"))\n]}")
    }
}
