import Foundation

/// Edge inset (erosion) and softness (feather) for a decoded person-mask
/// frame — docs/camera-cutout.md §12.4. Pure integer arithmetic, so the web's
/// `core/mask/maskEdge.ts` produces the SAME bytes (the `cameraMaskEdge`
/// golden-vector unit locks it). Both renderers run every decoded mask frame
/// through `process` before it becomes alpha, for both looks.
nonisolated enum CameraMaskEdge {
    /// Radius at 1.0, in mask pixels at the producer's 192 rows.
    static let maxRadius: Double = 6
    static let referenceRows: Double = 192

    /// (inset, softness) radii in mask pixels for a mask `height` rows tall.
    static func radii(height: Int, softness: Double, inset: Double) -> (inset: Int, softness: Int) {
        let k = Double(height) / referenceRows
        func r(_ v: Double) -> Int { Int((min(1, max(0, v)) * maxRadius * k).rounded()) }
        return (r(inset), r(softness))
    }

    /// Erode by the inset radius, then box-blur twice each way by the
    /// softness radius. Returns `alpha` itself when both radii are 0.
    static func process(_ alpha: [UInt8], width: Int, height: Int, softness: Double, inset: Double) -> [UInt8] {
        guard width > 0, height > 0, alpha.count == width * height else { return alpha }
        let (i, s) = radii(height: height, softness: softness, inset: inset)
        guard i > 0 || s > 0 else { return alpha }
        var a = alpha
        if i > 0 {
            a = pass(a, width: width, height: height, horizontal: true) { minimum($0, radius: i) }
            a = pass(a, width: width, height: height, horizontal: false) { minimum($0, radius: i) }
        }
        if s > 0 {
            for _ in 0..<2 {
                a = pass(a, width: width, height: height, horizontal: true) { box($0, radius: s) }
                a = pass(a, width: width, height: height, horizontal: false) { box($0, radius: s) }
            }
        }
        return a
    }

    /// The last processed frame, keyed by (track, frame index, radii) — the
    /// preview re-presents the same frame often and the exporter runs the
    /// camera slower than the output, so one entry catches nearly every hit.
    final class Cache {
        private var key: (token: UUID, index: Int, inset: Int, softness: Int)?
        private var value: [UInt8] = []

        func processed(
            _ alpha: [UInt8], token: UUID, index: Int, width: Int, height: Int,
            softness: Double, inset: Double
        ) -> [UInt8] {
            let r = CameraMaskEdge.radii(height: height, softness: softness, inset: inset)
            guard r.inset > 0 || r.softness > 0 else { return alpha }
            if let k = key, k.token == token, k.index == index, k.inset == r.inset, k.softness == r.softness {
                return value
            }
            value = CameraMaskEdge.process(alpha, width: width, height: height, softness: softness, inset: inset)
            key = (token, index, r.inset, r.softness)
            return value
        }
    }

    /// Runs `line` over every row (horizontal) or column of the frame.
    private static func pass(
        _ a: [UInt8], width: Int, height: Int, horizontal: Bool, _ line: ([UInt8]) -> [UInt8]
    ) -> [UInt8] {
        var out = a
        if horizontal {
            for y in 0..<height {
                let row = Array(a[(y * width)..<((y + 1) * width)])
                out.replaceSubrange((y * width)..<((y + 1) * width), with: line(row))
            }
        } else {
            var column = [UInt8](repeating: 0, count: height)
            for x in 0..<width {
                for y in 0..<height { column[y] = a[y * width + x] }
                let result = line(column)
                for y in 0..<height { out[y * width + x] = result[y] }
            }
        }
        return out
    }

    /// out[x] = min(in[clamp(x + d)]) for d ∈ [−r, r] (clamp-to-edge).
    private static func minimum(_ line: [UInt8], radius r: Int) -> [UInt8] {
        let n = line.count
        var out = line
        for x in 0..<n {
            var m = UInt8.max
            for d in -r...r { m = min(m, line[min(max(x + d, 0), n - 1)]) }
            out[x] = m
        }
        return out
    }

    /// out[x] = (Σ in[clamp(x + d)] for d ∈ [−r, r] + r) ÷ (2r + 1).
    private static func box(_ line: [UInt8], radius r: Int) -> [UInt8] {
        let n = line.count
        let window = 2 * r + 1
        var out = line
        // Running sum over the clamped window.
        var sum = 0
        for d in -r...r { sum += Int(line[min(max(d, 0), n - 1)]) }
        for x in 0..<n {
            out[x] = UInt8((sum + r) / window)
            sum += Int(line[min(x + r + 1, n - 1)]) - Int(line[max(x - r, 0)])
        }
        return out
    }
}
