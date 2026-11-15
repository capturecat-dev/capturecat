import CoreGraphics
import Foundation

/// A compact, frozen stand-in for a reference RENDER.
///
/// `RasterGoldenHarness` used to prove each CoreGraphics renderer against a
/// live SwiftUI rasterisation of the same content. With SwiftUI gone there is
/// no oracle to re-render, so the last verified output is frozen instead.
///
/// It is stored as a fingerprint rather than a PNG for three reasons:
/// the app is sandboxed and cannot read fixture files from the repo at runtime;
/// bundling ~4 MB of goldens would ship them inside the product; and a
/// fingerprint diff reviews as numbers in the diff rather than as an opaque
/// binary blob.
///
/// The fingerprint is a `gridX × gridY` downsample of straight (un-premultiplied)
/// RGBA, hex-encoded. That is deliberately a *perceptual* summary: it catches
/// colour shifts, geometry moves and missing elements, and is blind to
/// antialiasing noise. It is NOT sufficient on its own for small structural
/// defects — CLAUDE.md's duplicated Dynamic Island (1.846/255 mean, visibly
/// wrong) is exactly the case a downsample can miss — so callers pair it with
/// blob/centroid assertions where structure matters.
enum RasterFingerprint {
    // 24x14. At 12x7 two genuinely different states (a tap ripple present vs
    // absent) scored exactly 2/255 against a bar of 2 — i.e. the grid could not
    // tell them apart. Quadrupling the cell count keeps each cell well above
    // antialiasing noise while making a localised change move its own cell far
    // more than it moves a coarse average.
    static let gridX = 24
    static let gridY = 14

    /// Mean straight RGBA per cell, hex-encoded, row-major from the top.
    static func make(_ image: CGImage) -> String? {
        guard let px = pixels(image) else { return nil }
        defer { px.deallocate() }
        var out = ""
        out.reserveCapacity(gridX * gridY * 8)
        for gy in 0..<gridY {
            let y0 = gy * px.height / gridY
            let y1 = max(y0 + 1, (gy + 1) * px.height / gridY)
            for gx in 0..<gridX {
                let x0 = gx * px.width / gridX
                let x1 = max(x0 + 1, (gx + 1) * px.width / gridX)
                var sum = [Double](repeating: 0, count: 4)
                var n = 0.0
                for y in y0..<y1 {
                    let row = px.bytes + y * px.bytesPerRow
                    for x in x0..<x1 {
                        let p = row + x * 4
                        // Stored premultiplied BGRA; un-premultiply so a colour
                        // change under constant alpha cannot cancel out.
                        let a = Double(p[3]) / 255
                        if a > 0.0001 {
                            sum[0] += Double(p[2]) / a
                            sum[1] += Double(p[1]) / a
                            sum[2] += Double(p[0]) / a
                        }
                        sum[3] += Double(p[3])
                        n += 1
                    }
                }
                for c in 0..<4 {
                    let v = Int((sum[c] / max(1, n)).rounded())
                    out += String(format: "%02X", min(255, max(0, v)))
                }
            }
        }
        return out
    }

    /// Worst per-channel cell delta, in 0…255. `nil` if the two fingerprints
    /// are not the same shape.
    static func worstDelta(_ a: String, _ b: String) -> Double? {
        guard a.count == b.count, a.count == gridX * gridY * 8 else { return nil }
        let ab = Array(a), bb = Array(b)
        var worst = 0.0
        var i = 0
        while i < ab.count {
            let x = UInt8(String(ab[i...i + 1]), radix: 16) ?? 0
            let y = UInt8(String(bb[i...i + 1]), radix: 16) ?? 0
            worst = max(worst, abs(Double(x) - Double(y)))
            i += 2
        }
        return worst
    }

    private struct Pixels {
        let bytes: UnsafeMutablePointer<UInt8>
        let width: Int
        let height: Int
        let bytesPerRow: Int
        func deallocate() { bytes.deallocate() }
    }

    private static func pixels(_ image: CGImage) -> Pixels? {
        let w = image.width, h = image.height
        let bpr = w * 4
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bpr * h)
        buf.initialize(repeating: 0, count: bpr * h)
        guard let ctx = CGContext(
            data: buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            buf.deallocate()
            return nil
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return Pixels(bytes: buf, width: w, height: h, bytesPerRow: bpr)
    }
}
