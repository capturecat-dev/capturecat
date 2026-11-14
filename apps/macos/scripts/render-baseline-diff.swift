// render-baseline-diff — exact comparisons render-baseline.sh can't do with cmp.
//
//   render-baseline-diff pixels <a.png> <b.png>
//       Exit 0 + "identical" when both decode to the same size, colour space
//       and RGBA8 pixels. PNG bytes can differ while pixels don't (encoder
//       metadata), so render artifacts are compared decoded.
//
//   render-baseline-diff f32 <a.f32> <b.f32> <tolerance>
//       Interleaved float32 audio. Exit 0 when both have the same sample
//       count and every |a−b| ≤ tolerance ("identical" if bit-equal,
//       otherwise "within …"). See render-baseline.sh for why audio is the
//       one category compared with a tolerance.
//
// Exit 1 and a one-line summary on a difference; exit 2 when a file can't be
// read. Compiled on demand by render-baseline.sh; not part of the app.

import CoreGraphics
import Foundation
import ImageIO

func fail(_ message: String, code: Int32 = 1) -> Never {
    print(message)
    exit(code)
}

// MARK: - pixels

struct Decoded {
    let width: Int
    let height: Int
    let colorSpace: String
    let pixels: [UInt8]
}

func decode(_ path: String) -> Decoded? {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let source = CGImageSourceCreateWithURL(url, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
        ?? CGColorSpace(name: CGColorSpace.sRGB)!
    let w = image.width, h = image.height
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
        guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.setBlendMode(.copy)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    guard drawn else { return nil }
    let name = (space.name as String?) ?? "unnamed-\(space.model.rawValue)"
    return Decoded(width: w, height: h, colorSpace: name, pixels: pixels)
}

func comparePixels(_ pathA: String, _ pathB: String) -> Never {
    guard let a = decode(pathA) else { fail("undecodable \(pathA)", code: 2) }
    guard let b = decode(pathB) else { fail("undecodable \(pathB)", code: 2) }
    if a.width != b.width || a.height != b.height {
        fail("size differs \(a.width)x\(a.height) vs \(b.width)x\(b.height)")
    }
    if a.colorSpace != b.colorSpace { fail("colour space differs \(a.colorSpace) vs \(b.colorSpace)") }
    var differing = 0, worst = 0, total = 0
    var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
    for y in 0..<a.height {
        for x in 0..<a.width {
            let i = (y * a.width + x) * 4
            var pixelWorst = 0
            for c in 0..<4 {
                let d = abs(Int(a.pixels[i + c]) - Int(b.pixels[i + c]))
                pixelWorst = max(pixelWorst, d)
                total += d
            }
            if pixelWorst > 0 {
                differing += 1
                worst = max(worst, pixelWorst)
                minX = min(minX, x); minY = min(minY, y)
                maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
    }
    if differing == 0 { print("identical"); exit(0) }
    let count = a.width * a.height
    fail(String(format: "%d px differ (%.3f%%), worst %d/255, mean %.4f/255, bbox x%d-%d y%d-%d (top-down)",
                differing, 100 * Double(differing) / Double(count), worst,
                Double(total) / Double(count * 4), minX, maxX, minY, maxY))
}

// MARK: - f32

func floats(_ path: String) -> [Float]? {
    guard let data = FileManager.default.contents(atPath: path), data.count % 4 == 0 else { return nil }
    return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}

func compareF32(_ pathA: String, _ pathB: String, tolerance: Float) -> Never {
    guard let a = floats(pathA) else { fail("unreadable \(pathA)", code: 2) }
    guard let b = floats(pathB) else { fail("unreadable \(pathB)", code: 2) }
    var differing = 0, worst: Float = 0, firstDiff = -1
    for i in 0..<min(a.count, b.count) where a[i] != b[i] {
        differing += 1
        worst = max(worst, abs(a[i] - b[i]))
        if firstDiff < 0 { firstDiff = i }
    }
    let lengths = a.count == b.count ? "" : "length \(a.count) vs \(b.count) samples, "
    if a.count == b.count && differing == 0 { print("identical"); exit(0) }
    let summary = String(format: "%@%d samples differ, worst |Δ| %.3g (first at sample %d)",
                         lengths, differing, worst, firstDiff)
    if a.count == b.count && worst <= tolerance {
        print("within \(tolerance): \(summary)")
        exit(0)
    }
    fail(summary)
}

// MARK: - main

let args = CommandLine.arguments
switch (args.count, args.count > 1 ? args[1] : "") {
case (4, "pixels"): comparePixels(args[2], args[3])
case (5, "f32"):
    guard let tol = Float(args[4]) else { fail("bad tolerance \(args[4])", code: 2) }
    compareF32(args[2], args[3], tolerance: tol)
default:
    FileHandle.standardError.write("usage: render-baseline-diff pixels <a> <b> | f32 <a> <b> <tolerance>\n".data(using: .utf8)!)
    exit(2)
}
