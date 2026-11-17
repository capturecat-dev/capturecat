import UIKit

/// The VIDEO lane's FILMSTRIP (part of `--timeline-edits`): a synthetic
/// screen recording whose marker band is a different colour every second
/// (`DemoMovieWriter`) loads into the shipping timeline; the frames must
/// load (the shared AVAssetImageGenerator thumbnailer), sit on an even
/// time grid across the recording, each image showing the second it claims
/// (within the thumbnailer's ±0.5 s keyframe tolerance) — and the lane must
/// DRAW the right frame at the right place: at mid-second t the pixel in the
/// tile under x(t) carries second t's colour.
/// `--inject filmstrip-offset` (frames drawn 2 s late) and `no-filmstrip`
/// must make it FAIL.
@MainActor
enum FilmstripCheck {
    static func run(parent: UIViewController, out: URL, inject: String?) async -> Bool {
        #if DEBUG
        StudioTimelineCanvasView.probeFilmstripOffset = inject == "filmstrip-offset" ? 2 : 0
        StudioTimelineViewController.probeNoFilmstrip = inject == "no-filmstrip"
        #endif
        let dir = out.appendingPathComponent("filmstrip", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let movie = dir.appendingPathComponent("screen.mov")
        let duration: TimeInterval = 8
        guard await DemoMovieWriter.write(to: movie, duration: duration) else {
            print("FILMSTRIP FAIL could not write the demo recording"); return false
        }
        let project = Project(id: UUID(), name: "Filmstrip", videoURL: movie, cameraVideoURL: nil,
                              duration: duration, recordingSourceKind: .window)
        let vc = StudioTimelineViewController(project: project, selection: EditorShellSelection(),
                                              playback: StudioTimelinePlayhead(), undoManager: UndoManager())
        parent.addChild(vc)
        let root = parent.view!
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(vc.view)
        NSLayoutConstraint.activate([
            vc.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            vc.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            vc.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            vc.view.heightAnchor.constraint(equalToConstant: vc.intrinsicPanelHeight + 60),
        ])
        vc.didMove(toParent: parent)
        defer {
            vc.tearDown()
            vc.willMove(toParent: nil)
            vc.view.removeFromSuperview()
            vc.removeFromParent()
        }
        // Frames load in the background.
        let t0 = CACurrentMediaTime()
        while vc.probeThumbnails.isEmpty && CACurrentMediaTime() - t0 < 8 { await LabTime.settle(0.1) }
        await LabTime.settle(0.3)
        var ok = true
        func check(_ name: String, _ pass: Bool, _ detail: String) {
            print("FILMSTRIP \(name) \(pass ? "PASS" : "FAIL") — \(detail)")
            if !pass { ok = false }
        }
        let thumbs = vc.probeThumbnails
        check("frames-loaded", thumbs.count >= 30, "\(thumbs.count) frames for \(Int(duration)) s")
        // An even grid over the recording (the thumbnailer's (i + ½) × stride).
        let stride = duration / 40
        let gridOK = !thumbs.isEmpty && thumbs.enumerated().allSatisfy { i, t in
            t.time > 0 && t.time < duration && (i == 0 || t.time > thumbs[i - 1].time)
        } && thumbs.allSatisfy { t in abs(((t.time / stride) - 0.5).rounded() - ((t.time / stride) - 0.5)) < 0.01 }
        check("frame-times", gridOK, "times \(thumbs.prefix(4).map { String(format: "%.2f", $0.time) }.joined(separator: ", ")) … on a \(String(format: "%.2f", stride)) s grid")
        // Each image shows its second (±0.5 s keyframe tolerance).
        var wrongImages: [String] = []
        for t in thumbs {
            guard let c = markerColour(t.image) else { wrongImages.append(String(format: "%.2f unreadable", t.time)); continue }
            let candidates = Set([t.time - 0.55, t.time, t.time + 0.55].map { Int(max(0, min(duration - 0.01, $0))) })
            if !candidates.contains(where: { close(c, DemoMovieWriter.colour(at: Double($0))) }) {
                wrongImages.append(String(format: "%.2f", t.time))
            }
        }
        check("frame-images", !thumbs.isEmpty && wrongImages.isEmpty,
              wrongImages.isEmpty ? "every frame shows the second it was taken at" : "wrong frame at \(wrongImages.prefix(6))")
        // The lane draws the right frame at the right x.
        vc.setTimelineScale(8)
        await LabTime.settle(0.4)
        var wrongTiles: [String] = []
        var sampled = 0
        for k in 0..<Int(duration) {
            let t = Double(k) + 0.5
            let x = vc.canvas.x(forOutputTime: t)
            guard let c = pixel(of: vc.canvas, at: CGPoint(x: x, y: TimelineCanvasMetrics.videoLaneY + TimelineCanvasMetrics.trackHeight - 4)) else {
                wrongTiles.append("\(t) unreadable"); continue
            }
            sampled += 1
            let candidates = Set([t - 0.65, t, t + 0.65].map { Int(max(0, min(duration - 0.01, $0))) })
            if !candidates.contains(where: { close(c, DemoMovieWriter.colour(at: Double($0))) }) {
                wrongTiles.append(String(format: "%.1f s", t))
            }
        }
        check("lane-tiles", sampled == Int(duration) && wrongTiles.isEmpty && !thumbs.isEmpty,
              wrongTiles.isEmpty ? "\(sampled) mid-second tiles show their second" : "wrong tile at \(wrongTiles)")
        print(ok ? "FILMSTRIP PASS" : "FILMSTRIP FAIL")
        return ok
    }

    private static func close(_ a: UIColor, _ b: UIColor) -> Bool {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        a.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        b.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return abs(r1 - r2) + abs(g1 - g2) + abs(b1 - b2) < 0.30
    }

    /// The marker band's colour in a frame (its centre, low in the image).
    private static func markerColour(_ image: CGImage) -> UIColor? {
        let p = CGPoint(x: CGFloat(image.width) / 2, y: CGFloat(image.height) * 0.92)
        return sample(image, at: p)
    }

    private static func pixel(of view: UIView, at point: CGPoint) -> UIColor? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 3, height: 3), format: format).image { ctx in
            ctx.cgContext.translateBy(x: -point.x + 1, y: -point.y + 1)
            view.layer.render(in: ctx.cgContext)
        }
        guard let cg = image.cgImage else { return nil }
        return sample(cg, at: CGPoint(x: 1, y: 1))
    }

    private static func sample(_ image: CGImage, at p: CGPoint) -> UIColor? {
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: -p.x, y: -(CGFloat(image.height) - p.y - 1), width: CGFloat(image.width), height: CGFloat(image.height)))
        return UIColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
    }
}
