// make-hevc — synthetic screen-recording-like HEVC clips for spikes a/b/c/g.
//
//   make-hevc <out.mov> <width> <height> <fps> <seconds> <bitrate>
//
// Never user media: a generated "desktop" (menu bar, dock, text columns), a
// window that glides across it, a scrolling text column, a moving cursor and
// a frame-index barcode, so every frame differs like a real recording and a
// decoder cannot coast on static content.

import AVFoundation
import CoreGraphics
import CoreText
import Foundation

let a = CommandLine.arguments
guard a.count == 7, let W = Int(a[2]), let H = Int(a[3]), let fps = Int32(a[4]),
      let seconds = Double(a[5]), let bitrate = Int(a[6]) else {
    print("usage: make-hevc <out.mov> <width> <height> <fps> <seconds> <bitrate>")
    exit(64)
}
let url = URL(fileURLWithPath: a[1])
try? FileManager.default.removeItem(at: url)
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func context(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
}

func drawText(_ ctx: CGContext, _ s: String, x: CGFloat, y: CGFloat, size: CGFloat, color: CGColor) {
    let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
    let attr = NSAttributedString(string: s, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ])
    let line = CTLineCreateWithAttributedString(attr)
    ctx.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, ctx)
}

let words = "the quick brown fox jumps over a lazy dog while screen recordings show menus windows code and cursors moving across bright interfaces".split(separator: " ").map(String.init)
var seed: UInt64 = 0x9E3779B97F4A7C15
func rnd() -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(seed >> 33) }
func sentence(_ n: Int) -> String { (0..<n).map { _ in words[rnd() % words.count] }.joined(separator: " ") }

let u = CGFloat(W) / 1728 // UI scale relative to a 1728-pt-wide desktop

// Static desktop.
let desk = context(W, H)
desk.setFillColor(CGColor(red: 0.93, green: 0.94, blue: 0.96, alpha: 1)); desk.fill(CGRect(x: 0, y: 0, width: W, height: H))
desk.setFillColor(CGColor(red: 0.98, green: 0.98, blue: 0.99, alpha: 1))
desk.fill(CGRect(x: 0, y: CGFloat(H) - 37 * u, width: CGFloat(W), height: 37 * u))
for i in 0..<8 { drawText(desk, ["File", "Edit", "View", "Go", "Window", "Help", "Tools", "Share"][i], x: (60 + CGFloat(i) * 70) * u, y: CGFloat(H) - 26 * u, size: 15 * u, color: CGColor(gray: 0.1, alpha: 1)) }
desk.setFillColor(CGColor(gray: 1, alpha: 0.85))
desk.fill(CGRect(x: CGFloat(W) * 0.25, y: 10 * u, width: CGFloat(W) * 0.5, height: 70 * u))
for i in 0..<14 {
    desk.setFillColor(CGColor(red: CGFloat(rnd() % 255) / 255, green: CGFloat(rnd() % 255) / 255, blue: CGFloat(rnd() % 255) / 255, alpha: 1))
    desk.fillEllipse(in: CGRect(x: CGFloat(W) * 0.25 + (20 + CGFloat(i) * 58) * u, y: 18 * u, width: 52 * u, height: 52 * u))
}
for col in 0..<2 {
    for row in 0..<40 {
        drawText(desk, sentence(9), x: (40 + CGFloat(col) * 860) * u, y: CGFloat(H) - (90 + CGFloat(row) * 26) * u, size: 16 * u, color: CGColor(gray: 0.25, alpha: 1))
    }
}
let deskImage = desk.makeImage()!

// A window with its own text, and a long scrolling column.
let winW = Int(820 * u), winH = Int(560 * u)
let win = context(winW, winH)
win.setFillColor(CGColor(gray: 1, alpha: 1)); win.fill(CGRect(x: 0, y: 0, width: winW, height: winH))
win.setFillColor(CGColor(gray: 0.9, alpha: 1)); win.fill(CGRect(x: 0, y: CGFloat(winH) - 40 * u, width: CGFloat(winW), height: 40 * u))
for (i, c) in [CGColor(red: 1, green: 0.37, blue: 0.34, alpha: 1), CGColor(red: 1, green: 0.74, blue: 0.18, alpha: 1), CGColor(red: 0.16, green: 0.79, blue: 0.25, alpha: 1)].enumerated() {
    win.setFillColor(c); win.fillEllipse(in: CGRect(x: (14 + CGFloat(i) * 22) * u, y: CGFloat(winH) - 28 * u, width: 14 * u, height: 14 * u))
}
for row in 0..<18 { drawText(win, sentence(8), x: 24 * u, y: CGFloat(winH) - (70 + CGFloat(row) * 26) * u, size: 17 * u, color: CGColor(red: 0.1, green: 0.2, blue: 0.5, alpha: 1)) }
let winImage = win.makeImage()!
let colW = Int(600 * u), colH = Int(CGFloat(H) * 3)
let colCtx = context(colW, colH)
colCtx.setFillColor(CGColor(red: 0.12, green: 0.13, blue: 0.16, alpha: 1)); colCtx.fill(CGRect(x: 0, y: 0, width: colW, height: colH))
for row in 0..<Int(CGFloat(colH) / (24 * u)) {
    drawText(colCtx, "\(row)  " + sentence(6), x: 16 * u, y: CGFloat(row) * 24 * u + 6 * u, size: 15 * u, color: CGColor(red: 0.6, green: 0.9, blue: 0.6, alpha: 1))
}
let colImage = colCtx.makeImage()!

// Writer.
let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.hevc,
    AVVideoWidthKey: W, AVVideoHeightKey: H,
    AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: bitrate,
        AVVideoExpectedSourceFrameRateKey: fps,
        AVVideoMaxKeyFrameIntervalKey: Int(fps) * 2,
    ],
])
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H,
])
writer.add(input)
guard writer.startWriting() else { print("writer: \(String(describing: writer.error))"); exit(1) }
writer.startSession(atSourceTime: .zero)

let frames = Int(seconds * Double(fps))
for i in 0..<frames {
    while !input.isReadyForMoreMediaData { usleep(1000) }
    var pb: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
    guard let pb else { exit(1) }
    CVPixelBufferLockBaseAddress(pb, [])
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: W, height: H, bitsPerComponent: 8,
                        bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    let t = Double(i) / Double(fps)
    ctx.draw(deskImage, in: CGRect(x: 0, y: 0, width: W, height: H))
    // Scrolling column on the right.
    let colX = CGFloat(W) - CGFloat(colW) - 60 * u
    ctx.saveGState()
    ctx.clip(to: CGRect(x: colX, y: 120 * u, width: CGFloat(colW), height: CGFloat(H) - 200 * u))
    let scroll = CGFloat(t * 140) * u
    ctx.draw(colImage, in: CGRect(x: colX, y: -scroll, width: CGFloat(colW), height: CGFloat(colH)))
    ctx.restoreGState()
    // Gliding window with a shadow.
    let wx = (CGFloat(W) - CGFloat(winW) - CGFloat(colW) - 140 * u) * CGFloat(0.5 + 0.5 * sin(t * 0.7)) + 40 * u
    let wy = (CGFloat(H) - CGFloat(winH) - 160 * u) * CGFloat(0.5 + 0.5 * cos(t * 0.5)) + 100 * u
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * u), blur: 30 * u, color: CGColor(gray: 0, alpha: 0.35))
    ctx.draw(winImage, in: CGRect(x: wx, y: wy, width: CGFloat(winW), height: CGFloat(winH)))
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    // Cursor.
    let cx = CGFloat(W) * CGFloat(0.5 + 0.35 * sin(t * 1.3)), cy = CGFloat(H) * CGFloat(0.5 + 0.3 * sin(t * 0.9 + 1))
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.move(to: CGPoint(x: cx, y: cy)); ctx.addLine(to: CGPoint(x: cx, y: cy - 28 * u)); ctx.addLine(to: CGPoint(x: cx + 20 * u, y: cy - 20 * u)); ctx.fillPath()
    // Frame-index barcode (16 bits, bottom-left).
    for bit in 0..<16 {
        ctx.setFillColor(CGColor(gray: (i >> (15 - bit)) & 1 == 1 ? 1 : 0, alpha: 1))
        ctx.fill(CGRect(x: CGFloat(bit) * 12 * u, y: 0, width: 12 * u, height: 12 * u))
    }
    CVPixelBufferUnlockBaseAddress(pb, [])
    adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
guard writer.status == .completed else { print("failed: \(String(describing: writer.error))"); exit(1) }
let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
print("wrote \(url.lastPathComponent) \(W)x\(H)@\(fps) \(frames) frames \(bytes / 1_048_576) MB")
