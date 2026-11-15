import Foundation

/// Deterministic camera-mask fixtures, shared by `--cameralayout-test`, the
/// web golden vectors (`maskCodec`) and their iOS replay (ios-vectors.sh) —
/// Foundation only, so the iOS Simulator build can compile it alone.
enum CameraMaskFixtures {
    /// A soft ellipse "head and shoulders" that drifts, then holds still —
    /// both key and delta payloads occur. Deterministic.
    static func syntheticMaskFrames(width: Int, height: Int, count: Int, fps: Double = 30) -> [(time: Double, alpha: [UInt8])] {
        (0..<count).map { i in
            let still = i >= count * 2 / 3
            let u = still ? Double(count * 2 / 3) / Double(count) : Double(i) / Double(count)
            let cx = Double(width) * (0.35 + 0.3 * u)
            let cy = Double(height) * 0.62
            let rx = Double(width) * 0.24, ry = Double(height) * 0.5
            var alpha = [UInt8](repeating: 0, count: width * height)
            for y in 0..<height {
                for x in 0..<width {
                    let dx = (Double(x) + 0.5 - cx) / rx, dy = (Double(y) + 0.5 - cy) / ry
                    let d = (dx * dx + dy * dy).squareRoot()
                    // 1 inside, 0 outside, a soft ramp across the edge.
                    let v = min(1, max(0, (1.12 - d) / 0.24))
                    alpha[y * width + x] = UInt8((v * 255).rounded())
                }
            }
            return (Double(i) / fps + 0.0123, alpha)
        }
    }
}
