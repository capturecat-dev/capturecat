import CoreGraphics

/// Pixel helpers shared by the headless raster gates.
///
/// Structural blob detection lived in `PreviewParityHarness` and was duplicated
/// in spirit by every other gate. It belongs in one place: CLAUDE.md §3 makes
/// blob/centroid assertions the required companion to any mean-based score, so
/// every harness needs the same implementation, not its own.
enum HarnessPixels {
    struct Blob {
        var area: Int
        var centroid: CGPoint
    }

    /// Connected components of PURE-BLACK pixels (r+g+b < 12), largest first.
    ///
    /// The Dynamic Island capsule fills with black, while even the darkest
    /// recorded UI sits at ≈#1c1c1e (sum 84) and the bezel body/glass are grey —
    /// so the island always resolves as its own blob. This catches a MISSING,
    /// MOVED or DUPLICATED pill, none of which shift a mean-abs-diff enough to
    /// fail (verified against injected defects: the mean stayed ≤1.9/255 while
    /// this gate failed).
    ///
    /// Known limit: a ghost pill drawn ON TOP of pure-black content merges into
    /// that blob and is not counted — but such a pill is black-on-black and
    /// invisible to the user too.
    static func darkBlobs(_ image: CGImage, minArea: Int = 100) -> [Blob] {
        guard let p = rgba(image) else { return [] }
        defer { p.deallocate() }
        let w = p.width, h = p.height
        var mask = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            let row = p.bytes + y * p.bytesPerRow
            for x in 0..<w {
                let px = row + x * 4
                // Alpha check first: a TRANSPARENT pixel is (0,0,0,0), which
                // reads as "pure black" on the colour test alone. Without this
                // the whole transparent surround of a bezel render merges into
                // one giant blob and the count asserts nothing.
                if px[3] > 128, Int(px[0]) + Int(px[1]) + Int(px[2]) < 12 {
                    mask[y * w + x] = true
                }
            }
        }
        var seen = [Bool](repeating: false, count: w * h)
        var blobs: [Blob] = []
        var stack: [Int] = []
        for start in 0..<(w * h) where mask[start] && !seen[start] {
            stack.removeAll(keepingCapacity: true)
            stack.append(start)
            seen[start] = true
            var area = 0
            var sx = 0.0, sy = 0.0
            while let i = stack.popLast() {
                area += 1
                let x = i % w, y = i / w
                sx += Double(x); sy += Double(y)
                if x > 0, mask[i - 1], !seen[i - 1] { seen[i - 1] = true; stack.append(i - 1) }
                if x < w - 1, mask[i + 1], !seen[i + 1] { seen[i + 1] = true; stack.append(i + 1) }
                if y > 0, mask[i - w], !seen[i - w] { seen[i - w] = true; stack.append(i - w) }
                if y < h - 1, mask[i + w], !seen[i + w] { seen[i + w] = true; stack.append(i + w) }
            }
            if area >= minArea {
                blobs.append(Blob(
                    area: area,
                    centroid: CGPoint(x: sx / Double(area), y: sy / Double(area))
                ))
            }
        }
        return blobs.sorted { $0.area > $1.area }
    }

    struct Pixels {
        let bytes: UnsafeMutablePointer<UInt8>
        let width: Int
        let height: Int
        let bytesPerRow: Int
        func deallocate() { bytes.deallocate() }
    }

    /// Premultiplied **RGBA** in sRGB — byte 0 is red. Row 0 is the image's TOP
    /// row. Both are worth stating: a premultipliedFirst/byteOrder32Little
    /// buffer is B,G,R,A instead, and reading it as RGBA silently swaps red and
    /// blue, which reads as a plausible-but-wrong colour rather than a crash.
    static func rgba(_ image: CGImage) -> Pixels? {
        let w = image.width, h = image.height
        let bpr = w * 4
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bpr * h)
        buf.initialize(repeating: 0, count: bpr * h)
        guard let ctx = CGContext(
            data: buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            buf.deallocate()
            return nil
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return Pixels(bytes: buf, width: w, height: h, bytesPerRow: bpr)
    }
}
