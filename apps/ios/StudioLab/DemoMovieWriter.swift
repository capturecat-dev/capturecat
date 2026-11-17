import AVFoundation
import UIKit

/// A short synthetic SCREEN RECORDING for the labs: a light app window with
/// a sidebar and a form, a cursor travelling across it, and a coloured
/// marker block whose colour encodes the SECOND it was drawn in
/// (`palette[Int(t)]`) — so a filmstrip frame can be checked for the time it
/// claims to show (the filmstrip gate) and screenshots look like a real
/// capture instead of a flat colour.
enum DemoMovieWriter {
    static let palette: [UIColor] = [
        UIColor(red: 0.93, green: 0.20, blue: 0.20, alpha: 1), UIColor(red: 0.98, green: 0.60, blue: 0.10, alpha: 1),
        UIColor(red: 0.95, green: 0.85, blue: 0.10, alpha: 1), UIColor(red: 0.20, green: 0.75, blue: 0.30, alpha: 1),
        UIColor(red: 0.10, green: 0.75, blue: 0.85, alpha: 1), UIColor(red: 0.20, green: 0.35, blue: 0.95, alpha: 1),
        UIColor(red: 0.60, green: 0.25, blue: 0.90, alpha: 1), UIColor(red: 0.95, green: 0.30, blue: 0.70, alpha: 1),
    ]

    static func colour(at t: TimeInterval) -> UIColor { palette[max(0, Int(t)) % palette.count] }

    /// The marker block's rect in a frame of `size` (it fills the frame's
    /// lower band so every filmstrip tile shows it).
    static func markerRect(in size: CGSize) -> CGRect {
        CGRect(x: 0, y: size.height * 0.80, width: size.width, height: size.height * 0.20)
    }

    static func frame(at t: TimeInterval, size: CGSize) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let c = ctx.cgContext
            UIColor(white: 0.96, alpha: 1).setFill()
            c.fill(CGRect(origin: .zero, size: size))
            // The app window: sidebar + content.
            let win = CGRect(x: size.width * 0.06, y: size.height * 0.07, width: size.width * 0.88, height: size.height * 0.68)
            UIColor.white.setFill()
            UIBezierPath(roundedRect: win, cornerRadius: 10).fill()
            UIColor(white: 0.97, alpha: 1).setFill()
            c.fill(CGRect(x: win.minX, y: win.minY, width: win.width * 0.22, height: win.height))
            UIColor(white: 0.80, alpha: 1).setFill()
            for i in 0..<6 {
                c.fill(CGRect(x: win.minX + 14, y: win.minY + 22 + CGFloat(i) * 24, width: win.width * 0.13, height: 7))
            }
            UIColor(white: 0.15, alpha: 1).setFill()
            c.fill(CGRect(x: win.minX + win.width * 0.28, y: win.minY + 24, width: win.width * 0.30, height: 14))
            UIColor(white: 0.85, alpha: 1).setFill()
            for i in 0..<4 {
                c.fill(CGRect(x: win.minX + win.width * 0.28, y: win.minY + 60 + CGFloat(i) * 34, width: win.width * 0.5, height: 20))
            }
            UIColor(red: 0.45, green: 0.40, blue: 0.95, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(x: win.minX + win.width * 0.62, y: win.maxY - 46, width: 96, height: 26), cornerRadius: 7).fill()
            // The marker band: the colour of this second.
            colour(at: t).setFill()
            c.fill(markerRect(in: size))
            // The cursor, travelling.
            let x = win.minX + win.width * CGFloat(0.2 + 0.6 * (t.truncatingRemainder(dividingBy: 4) / 4))
            let y = win.minY + win.height * 0.55
            let arrow = UIBezierPath()
            arrow.move(to: CGPoint(x: x, y: y))
            arrow.addLine(to: CGPoint(x: x, y: y + 20))
            arrow.addLine(to: CGPoint(x: x + 5, y: y + 15))
            arrow.addLine(to: CGPoint(x: x + 13, y: y + 15))
            arrow.close()
            UIColor.black.setFill()
            arrow.fill()
        }.cgImage
    }

    /// Writes `duration` seconds at `fps` (H.264 .mov).
    static func write(to url: URL, duration: TimeInterval = 8, size: CGSize = CGSize(width: 960, height: 600), fps: Int32 = 10) async -> Bool {
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return false }
        let w = Int(size.width), h = Int(size.height)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ])
        guard writer.canAdd(input) else { return false }
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let frames = Int(duration * Double(fps))
        for i in 0...frames {
            let t = Double(i) / Double(fps)
            guard let image = frame(at: min(t, duration - 0.001), size: size), let pool = adaptor.pixelBufferPool else { return false }
            var out: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let buffer = out else { return false }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h, bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            while !input.isReadyForMoreMediaData { try? await Task.sleep(nanoseconds: 2_000_000) }
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps)) else { return false }
        }
        input.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed
    }
}
