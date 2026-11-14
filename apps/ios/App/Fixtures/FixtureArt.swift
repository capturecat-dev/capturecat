#if DEBUG
import AVFoundation
import UIKit

/// Synthetic "screens" for fixture recordings, drawn locally: a desktop app
/// window for Mac/web takes, a phone UI for iPhone takes. Deterministic in
/// (hue, title, t) — `t` moves a cursor and a progress strip so scrubbing a
/// fixture video visibly changes frames. This is CONTENT (never themed).
enum FixtureArt {
    static func frame(device: Bool, still: Bool, hue: CGFloat, title: String, t: Double, duration: Double, exported: Bool = false) -> CGImage? {
        let size = device ? CGSize(width: 444, height: 960) : CGSize(width: 960, height: 600)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let progress = duration > 0 ? CGFloat(t / duration) : 0
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let ctx = context.cgContext
            if device {
                drawPhone(ctx, size: size, hue: hue, title: title, progress: progress, still: still)
            } else {
                drawDesktop(ctx, size: size, hue: hue, title: title, progress: progress, still: still, exported: exported)
            }
        }
        return image.cgImage
    }

    private static func color(_ hue: CGFloat, _ s: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> UIColor {
        UIColor(hue: hue.truncatingRemainder(dividingBy: 1), saturation: s, brightness: b, alpha: a)
    }

    private static func text(_ string: String, at point: CGPoint, size: CGFloat, weight: UIFont.Weight, color: UIColor, width: CGFloat = 600) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        (string as NSString).draw(in: CGRect(x: point.x, y: point.y, width: width, height: size * 1.4), withAttributes: [
            .font: UIFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: style,
        ])
    }

    private static func rounded(_ ctx: CGContext, _ rect: CGRect, _ radius: CGFloat, _ fill: UIColor) {
        ctx.setFillColor(fill.cgColor)
        ctx.addPath(UIBezierPath(roundedRect: rect, cornerRadius: radius).cgPath)
        ctx.fillPath()
    }

    private static func drawDesktop(_ ctx: CGContext, size: CGSize, hue: CGFloat, title: String, progress: CGFloat, still: Bool, exported: Bool) {
        // Wallpaper gradient.
        let colors = [color(hue, 0.55, 0.85).cgColor, color(hue + 0.12, 0.65, 0.55).cgColor] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        let inset: CGFloat = exported ? 70 : 40
        let window = CGRect(x: inset, y: inset, width: size.width - inset * 2, height: size.height - inset * 2)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 30, color: UIColor.black.withAlphaComponent(0.35).cgColor)
        rounded(ctx, window, 14, UIColor(white: 0.98, alpha: 1))
        ctx.restoreGState()
        // Title bar.
        rounded(ctx, CGRect(x: window.minX, y: window.minY, width: window.width, height: 34), 14, UIColor(white: 0.93, alpha: 1))
        ctx.fill(CGRect(x: window.minX, y: window.minY + 20, width: window.width, height: 14))
        for (i, dot) in [UIColor.systemRed, UIColor.systemYellow, UIColor.systemGreen].enumerated() {
            ctx.setFillColor(dot.cgColor)
            ctx.fillEllipse(in: CGRect(x: window.minX + 14 + CGFloat(i) * 18, y: window.minY + 11, width: 12, height: 12))
        }
        // Sidebar.
        let sidebar = CGRect(x: window.minX, y: window.minY + 34, width: 170, height: window.height - 34)
        ctx.setFillColor(UIColor(white: 0.95, alpha: 1).cgColor)
        ctx.fill(sidebar)
        for row in 0..<7 {
            let y = sidebar.minY + 22 + CGFloat(row) * 30
            rounded(ctx, CGRect(x: sidebar.minX + 16, y: y, width: 14, height: 14), 4, color(hue, 0.5, 0.75, row == 1 ? 1 : 0.45))
            rounded(ctx, CGRect(x: sidebar.minX + 38, y: y + 3, width: CGFloat(60 + (row * 23) % 50), height: 8), 4, UIColor(white: 0.7, alpha: 1))
        }
        // Content.
        let content = CGRect(x: sidebar.maxX + 26, y: window.minY + 58, width: window.maxX - sidebar.maxX - 52, height: window.height - 80)
        text(title, at: CGPoint(x: content.minX, y: content.minY - 6), size: 24, weight: .bold, color: UIColor(white: 0.12, alpha: 1), width: content.width)
        rounded(ctx, CGRect(x: content.minX, y: content.minY + 34, width: content.width * 0.6, height: 9), 4.5, UIColor(white: 0.78, alpha: 1))
        let hero = CGRect(x: content.minX, y: content.minY + 62, width: content.width, height: content.height * 0.38)
        let heroColors = [color(hue, 0.35, 0.98).cgColor, color(hue + 0.05, 0.5, 0.9).cgColor] as CFArray
        ctx.saveGState()
        ctx.addPath(UIBezierPath(roundedRect: hero, cornerRadius: 12).cgPath)
        ctx.clip()
        ctx.drawLinearGradient(CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: heroColors, locations: [0, 1])!,
                               start: hero.origin, end: CGPoint(x: hero.maxX, y: hero.maxY), options: [])
        ctx.restoreGState()
        let cardWidth = (content.width - 32) / 3
        for i in 0..<3 {
            let card = CGRect(x: content.minX + CGFloat(i) * (cardWidth + 16), y: hero.maxY + 20, width: cardWidth, height: content.maxY - hero.maxY - 26)
            rounded(ctx, card, 10, UIColor(white: 0.93, alpha: 1))
            rounded(ctx, CGRect(x: card.minX + 14, y: card.minY + 16, width: card.width * 0.55, height: 9), 4.5, UIColor(white: 0.62, alpha: 1))
            rounded(ctx, CGRect(x: card.minX + 14, y: card.minY + 34, width: card.width * 0.75, height: 7), 3.5, UIColor(white: 0.78, alpha: 1))
        }
        // Progress strip + cursor move with time.
        if !still {
            rounded(ctx, CGRect(x: hero.minX + 18, y: hero.maxY - 24, width: (hero.width - 36), height: 6), 3, UIColor.white.withAlphaComponent(0.45))
            rounded(ctx, CGRect(x: hero.minX + 18, y: hero.maxY - 24, width: (hero.width - 36) * progress, height: 6), 3, UIColor.white)
        }
        let cursor = CGPoint(x: content.minX + content.width * (0.2 + 0.6 * progress), y: hero.midY + sin(progress * .pi * 2) * 40)
        drawCursor(ctx, at: cursor)
    }

    private static func drawPhone(_ ctx: CGContext, size: CGSize, hue: CGFloat, title: String, progress: CGFloat, still: Bool) {
        ctx.setFillColor(UIColor(white: 0.97, alpha: 1).cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        // Status bar.
        text("9:41", at: CGPoint(x: 34, y: 18), size: 17, weight: .semibold, color: .black)
        rounded(ctx, CGRect(x: size.width - 66, y: 22, width: 34, height: 15), 4, UIColor.black)
        // Header band.
        let band = CGRect(x: 0, y: 60, width: size.width, height: 230)
        let colors = [color(hue, 0.55, 0.92).cgColor, color(hue + 0.1, 0.6, 0.7).cgColor] as CFArray
        ctx.drawLinearGradient(CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!,
                               start: band.origin, end: CGPoint(x: band.maxX, y: band.maxY), options: [])
        text(title, at: CGPoint(x: 26, y: band.minY + 24), size: 26, weight: .bold, color: .white, width: size.width - 52)
        rounded(ctx, CGRect(x: 26, y: band.minY + 70, width: 180, height: 10), 5, UIColor.white.withAlphaComponent(0.6))
        rounded(ctx, CGRect(x: 26, y: band.maxY - 70, width: size.width - 52, height: 46), 23, UIColor.white.withAlphaComponent(0.92))
        // List rows.
        for row in 0..<6 {
            let y = band.maxY + 26 + CGFloat(row) * 92
            rounded(ctx, CGRect(x: 20, y: y, width: size.width - 40, height: 78), 16, .white)
            rounded(ctx, CGRect(x: 34, y: y + 14, width: 50, height: 50), 12, color(hue + CGFloat(row) * 0.08, 0.45, 0.85))
            rounded(ctx, CGRect(x: 98, y: y + 20, width: CGFloat(140 + (row * 37) % 90), height: 11), 5.5, UIColor(white: 0.25, alpha: 1))
            rounded(ctx, CGRect(x: 98, y: y + 42, width: CGFloat(90 + (row * 53) % 70), height: 9), 4.5, UIColor(white: 0.7, alpha: 1))
        }
        // Tab bar.
        rounded(ctx, CGRect(x: 24, y: size.height - 96, width: size.width - 48, height: 64), 32, UIColor.white)
        for i in 0..<4 {
            rounded(ctx, CGRect(x: 24 + (size.width - 48) / 4 * (CGFloat(i) + 0.5) - 12, y: size.height - 76, width: 24, height: 24), 7,
                    i == 0 ? color(hue, 0.6, 0.8) : UIColor(white: 0.75, alpha: 1))
        }
        if !still {
            // A touch indicator moving down the list.
            let y = band.maxY + 64 + (size.height - band.maxY - 220) * progress
            ctx.setFillColor(UIColor(white: 0.2, alpha: 0.28).cgColor)
            ctx.fillEllipse(in: CGRect(x: size.width * 0.6 - 26, y: y - 26, width: 52, height: 52))
        }
        // Home indicator.
        rounded(ctx, CGRect(x: size.width / 2 - 70, y: size.height - 16, width: 140, height: 5), 2.5, UIColor.black)
    }

    private static func drawCursor(_ ctx: CGContext, at p: CGPoint) {
        let path = UIBezierPath()
        path.move(to: p)
        path.addLine(to: CGPoint(x: p.x, y: p.y + 24))
        path.addLine(to: CGPoint(x: p.x + 6, y: p.y + 18))
        path.addLine(to: CGPoint(x: p.x + 11, y: p.y + 28))
        path.addLine(to: CGPoint(x: p.x + 15, y: p.y + 26))
        path.addLine(to: CGPoint(x: p.x + 10, y: p.y + 16))
        path.addLine(to: CGPoint(x: p.x + 18, y: p.y + 16))
        path.close()
        ctx.setFillColor(UIColor.black.cgColor)
        ctx.setStrokeColor(UIColor.white.cgColor)
        ctx.setLineWidth(1.5)
        ctx.addPath(path.cgPath)
        ctx.drawPath(using: .fillStroke)
    }
}

/// Writes a fixture movie from drawn frames — a handful of frames spread over
/// `duration` (a still: two), so even a 6-minute fixture writes instantly.
enum FixtureMovie {
    static func ensure(url: URL, duration: Double, still: Bool, frame: @escaping (Double) -> CGImage?) async {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let tmp = url.deletingPathExtension().appendingPathExtension("tmp.mp4")
        try? FileManager.default.removeItem(at: tmp)
        let count = still ? 2 : min(40, max(6, Int(duration / 4)))
        var frames: [(CGImage, Double)] = []
        for i in 0..<count {
            let t = duration * Double(i) / Double(max(count - 1, 1))
            if let image = frame(t) { frames.append((image, t)) }
        }
        guard let first = frames.first?.0 else { return }
        let ok = await Task.detached(priority: .utility) { () -> Bool in
            write(frames: frames, size: CGSize(width: first.width, height: first.height), duration: duration, to: tmp)
        }.value
        if ok { try? FileManager.default.moveItem(at: tmp, to: url) }
    }

    nonisolated private static func write(frames: [(CGImage, Double)], size: CGSize, duration: Double, to url: URL) -> Bool {
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return false }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        guard writer.canAdd(input) else { return false }
        writer.add(input)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)
        for (image, t) in frames {
            while !input.isReadyForMoreMediaData { usleep(2000) }
            guard let pool = adaptor.pixelBufferPool else { return false }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { return false }
            CVPixelBufferLockBaseAddress(buffer, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height),
                                    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            context?.draw(image, in: CGRect(origin: .zero, size: size))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(seconds: min(t, max(0, duration - 0.04)), preferredTimescale: 600))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 600))
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        return writer.status == .completed
    }
}
#endif
