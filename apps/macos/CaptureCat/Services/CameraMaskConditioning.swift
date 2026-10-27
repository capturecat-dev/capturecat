import Foundation

/// Producer alpha conditioning (docs/camera-cutout.md §6) — what a mask
/// PRODUCER does to each segmented frame before handing it to the `.ccmask`
/// encoder. The format and the decoder are untouched: this only decides which
/// alpha values get written, so the track compresses. Raw Vision / MODNet
/// mattes are noisy: low-level speckle in the background, a shimmering soft
/// edge and ±1–3 level flicker everywhere, which makes every frame a fresh
/// key and costs ~12 MB per minute. Conditioning removes exactly that noise.
///
/// The function is integer-exact so the web producer (TS twin in
/// apps/web/src/editor/core/mask/conditionAlpha.ts) writes identical bytes
/// for identical input. Per pixel, with `prev` = the previous frame's
/// CONDITIONED value (none for the first frame):
///
///   1. dead zone:   v < deadZone → 0;  v > 255 − deadZone → 255
///   2. hold:        if prev exists and |v − prev| ≤ hold → out = prev
///   3. quantise:    else out = q(v), q(v) = round-half-up(v·(L−1)/255)
///                   mapped back: (level·255 + (L−1)/2) / (L−1)  (integer ÷)
///
/// The hold compares the dead-zoned RAW value with the previous OUTPUT —
/// hysteresis: a pixel only changes level when the matte really moved, so
/// still regions repeat byte-for-byte and the encoder's XOR deltas win.
nonisolated enum CameraMaskConditioning {
    struct Rule: Equatable, Sendable, CustomStringConvertible {
        /// Values within this of 0 / 255 snap to 0 / 255. 0 = off.
        var deadZone: Int
        /// Output levels across 0…255 (2…256). 256 = off.
        var levels: Int
        /// Keep the previous output when the new value is within this. 0 = off.
        var hold: Int

        static let none = Rule(deadZone: 0, levels: 256, hold: 0)

        var description: String {
            var parts: [String] = []
            if deadZone > 0 { parts.append("dz\(deadZone)") }
            if levels < 256 { parts.append("q\(levels)") }
            if hold > 0 { parts.append("hold\(hold)") }
            return parts.isEmpty ? "raw" : parts.joined(separator: "+")
        }
    }

    /// THE producer rule both platforms write with (contract §6, "producer
    /// alpha conditioning"). Chosen on a real Vision matte with
    /// `--camera-mask-bench --variants`: at 192 rows it takes the track from
    /// 6.3 to 1.5 MB per minute (12.2 at the old 288 rows) with a mean alpha
    /// error of 0.35/255 (p99 12) against the raw matte and no visible edge
    /// change at bubble size. hold 32 < one level (36.4): pure hysteresis.
    static let producer = Rule(deadZone: 16, levels: 8, hold: 32)

    /// Quantised value of v for `levels` (exact integer arithmetic).
    @inline(__always)
    static func quantize(_ v: Int, levels: Int) -> Int {
        guard levels < 256, levels >= 2 else { return v }
        let steps = levels - 1
        let level = (v * steps + 127) / 255
        return (level * 255 + steps / 2) / steps
    }

    /// Conditions one frame in place. `previous` is the previous frame's
    /// conditioned output (same size), nil for the first frame.
    static func condition(_ alpha: inout [UInt8], previous: [UInt8]?, rule: Rule = producer) {
        let lo = rule.deadZone, hi = 255 - rule.deadZone
        let hold = rule.hold
        let usePrev = hold > 0 && previous?.count == alpha.count
        // Precomputed quantisation table (identity when off).
        var table = [UInt8](repeating: 0, count: 256)
        for v in 0..<256 { table[v] = UInt8(quantize(v, levels: rule.levels)) }
        alpha.withUnsafeMutableBufferPointer { a in
            table.withUnsafeBufferPointer { q in
                let count = a.count
                if usePrev, let previous {
                    previous.withUnsafeBufferPointer { p in
                        for i in 0..<count {
                            var v = Int(a[i])
                            if v < lo { v = 0 } else if v > hi { v = 255 }
                            let pv = Int(p[i])
                            a[i] = abs(v - pv) <= hold ? p[i] : q[v]
                        }
                    }
                } else {
                    for i in 0..<count {
                        var v = Int(a[i])
                        if v < lo { v = 0 } else if v > hi { v = 255 }
                        a[i] = q[v]
                    }
                }
            }
        }
    }
}
