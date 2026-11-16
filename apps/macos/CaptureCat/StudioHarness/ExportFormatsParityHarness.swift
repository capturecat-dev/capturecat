#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import CoreGraphics
import Foundation
import ImageIO

/// GIF and PNG exports on this platform (Studio 3d), against the Mac's.
///
/// One render-parity fixture (`--web-parity-fixtures`) exported as an
/// animated GIF (VideoExporter's GIF path: GIFExportPolicy fps + size,
/// GIFFrameSink) and as a PNG still (StillImageExporter), with the sources
/// decoded to raw 4:2:0 (`--source-yuv`, the 3a seam) so both platforms start
/// from identical pixels. The Mac run (`--export-formats-parity`) writes the
/// reference; the iOS run (`--ios-export-formats`) must produce the same frame
/// count, size and per-frame delays, GIF frames within the bar, and the still's
/// RENDERED frame (the exporter's lossless tap of the micro clip the still is
/// cut from) within the bar. The PNG itself is decoded from that micro clip
/// after a lossy encode, so it carries each platform's video codec — reported
/// against its own tap (the codec loss), not gated across platforms.
enum ExportFormatsParityHarness {
    static let fixture = "01-baseline-gradient"
    static let meanBar = 1.0
    static let over8Bar = 0.01

    struct Summary: Codable, Equatable {
        var gifFrames: Int
        var gifWidth: Int
        var gifHeight: Int
        var gifDelays: [Double]
        var pngWidth: Int
        var pngHeight: Int
    }

    @MainActor
    static func run(fixtures: URL, out: URL, reference: URL?, log: (String) -> Void) async -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        let dir = fixtures.appendingPathComponent(fixture)
        func project() -> Project? {
            (try? Data(contentsOf: dir.appendingPathComponent("project.json")))
                .flatMap { try? JSONDecoder().decode(Project.self, from: $0) }
        }
        guard let gifProject = project(), let pngProject = project() else {
            log("EXPORT-FORMATS FAIL fixture \(fixture) unreadable in \(fixtures.path)")
            return false
        }
        setenv("CAPTURECAT_EXPORT_SOURCE_YUV", "1", 1)
        defer { unsetenv("CAPTURECAT_EXPORT_SOURCE_YUV") }
        let gif = out.appendingPathComponent("export.gif")
        let png = out.appendingPathComponent("still.png")
        try? fm.removeItem(at: gif); try? fm.removeItem(at: png)
        gifProject.settings.exportSettings.format = .gif
        let stillTap = out.appendingPathComponent("still-tap", isDirectory: true)
        try? fm.removeItem(at: stillTap)
        do {
            try await VideoExporter().export(project: gifProject, to: gif)
            setenv("CAPTURECAT_EXPORT_FRAME_TAP", stillTap.path, 1)
            defer { unsetenv("CAPTURECAT_EXPORT_FRAME_TAP") }
            try await StillImageExporter.exportPNG(project: pngProject, to: png)
        } catch {
            log("EXPORT-FORMATS FAIL export: \(error)")
            return false
        }
        // The micro clip's last rendered frame — the one the PNG is cut from.
        let lastTap = (try? fm.contentsOfDirectory(atPath: stillTap.path))?.filter { $0.hasSuffix(".png") }.sorted().last
        let tapURL = out.appendingPathComponent("still-tap.png")
        try? fm.removeItem(at: tapURL)
        if let lastTap { try? fm.copyItem(at: stillTap.appendingPathComponent(lastTap), to: tapURL) }
        let codecLoss = compare(frame(png, 0), frame(tapURL, 0))
        log(String(format: "EXPORT-FORMATS png vs its own rendered frame (codec loss, reported) mean %.3f max %d over8 %.3f%%",
                   codecLoss.mean, codecLoss.maxDelta, codecLoss.over8 * 100))
        guard let summary = summarize(gif: gif, png: png) else {
            log("EXPORT-FORMATS FAIL outputs unreadable")
            return false
        }
        try? JSONEncoder().encode(summary).write(to: out.appendingPathComponent("formats.json"))
        log("EXPORT-FORMATS gif \(summary.gifFrames) frames \(summary.gifWidth)×\(summary.gifHeight) "
            + "delays \(Set(summary.gifDelays).sorted()) · png \(summary.pngWidth)×\(summary.pngHeight)")
        guard let reference else {
            log("EXPORT-FORMATS WROTE reference \(out.path)")
            return true
        }
        guard let refData = try? Data(contentsOf: reference.appendingPathComponent("formats.json")),
              let ref = try? JSONDecoder().decode(Summary.self, from: refData) else {
            log("EXPORT-FORMATS FAIL no reference formats.json in \(reference.path)")
            return false
        }
        var pass = true
        let sameShape = summary == ref
        log("EXPORT-FORMATS structure \(sameShape ? "PASS" : "FAIL") (frames, size, delays\(sameShape ? " identical" : ": \(ref) vs \(summary)"))")
        pass = pass && sameShape
        for index in Set([0, summary.gifFrames / 2, max(0, summary.gifFrames - 1)]).sorted() {
            let score = compare(frame(gif, index), frame(reference.appendingPathComponent("export.gif"), index))
            log(String(format: "EXPORT-FORMATS gif frame %d mean %.3f max %d over8 %.3f%% %@", index,
                       score.mean, score.maxDelta, score.over8 * 100, score.ok ? "PASS" : "FAIL"))
            pass = pass && score.ok
        }
        let still = compare(frame(tapURL, 0), frame(reference.appendingPathComponent("still-tap.png"), 0))
        log(String(format: "EXPORT-FORMATS png rendered frame mean %.3f max %d over8 %.3f%% %@", still.mean,
                   still.maxDelta, still.over8 * 100, still.ok ? "PASS" : "FAIL"))
        pass = pass && still.ok
        let crossPNG = compare(frame(png, 0), frame(reference.appendingPathComponent("still.png"), 0))
        log(String(format: "EXPORT-FORMATS png file vs the Mac's (codecs differ, reported) mean %.3f max %d over8 %.3f%%",
                   crossPNG.mean, crossPNG.maxDelta, crossPNG.over8 * 100))
        log("EXPORT-FORMATS-PARITY \(pass ? "PASS" : "FAIL")")
        return pass
    }

    private static func summarize(gif: URL, png: URL) -> Summary? {
        guard let g = CGImageSourceCreateWithURL(gif as CFURL, nil),
              let p = CGImageSourceCreateWithURL(png as CFURL, nil),
              let first = CGImageSourceCreateImageAtIndex(g, 0, nil),
              let still = CGImageSourceCreateImageAtIndex(p, 0, nil) else { return nil }
        let count = CGImageSourceGetCount(g)
        let delays: [Double] = (0..<count).map { i in
            let props = CGImageSourceCopyPropertiesAtIndex(g, i, nil) as? [CFString: Any]
            let gifProps = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            return (gifProps?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gifProps?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0
        }
        return Summary(gifFrames: count, gifWidth: first.width, gifHeight: first.height, gifDelays: delays,
                       pngWidth: still.width, pngHeight: still.height)
    }

    private static func frame(_ url: URL, _ index: Int) -> CGImage? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, index, nil) }
    }

    private static func compare(_ a: CGImage?, _ b: CGImage?) -> (mean: Double, maxDelta: Int, over8: Double, ok: Bool) {
        guard let a, let b, let pa = HarnessPixels.rgba(a), let pb = HarnessPixels.rgba(b) else { return (255, 255, 1, false) }
        defer { pa.deallocate(); pb.deallocate() }
        let s = ExportParityHarness.compare(pa, pb, index: 0)
        return (s.mean, s.maxDelta, s.over8, s.mean <= meanBar && s.over8 <= over8Bar)
    }
}
