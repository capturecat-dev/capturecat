#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO

/// The platform's preview, settled, captured at 2× its canvas with rows
/// top-down — the Mac's `PreviewCompositorView` in an NSWindow, or the iOS
/// `PreviewStageView` in StudioLab's real UIWindow.
@MainActor
protocol PreviewExportStage: AnyObject {
    /// Renders `input` once (the harness steps time itself).
    func render(_ input: PreviewCompositorCore.FrameInput)
    /// The current frame at 2× the canvas, rows top-down.
    func capture() async -> CGImage?
    /// The compositor behind the stage (its camera state is logged).
    var core: PreviewCompositorCore { get }
}

/// Preview ↔ export on ONE platform (Studio 3c): `--preview-export-parity`
/// (Mac, the control) and `--ios-preview-export-parity` (StudioLab).
///
/// Inputs are the Mac-dumped preview-parity fixture (`--preview-parity-
/// fixtures`: its project, poster and canvas). The poster becomes a still
/// movie; the PREVIEW is shown the frame the EXPORTER decodes from that movie
/// (read the exporter's way), so both sides start from identical pixels and
/// only compositor vs exporter remains. For each case the preview is stepped
/// at the export's own frame times up to `time` (springs integrate the same
/// way the exporter's camera path does), captured at 2× its canvas, and the
/// exporter's lossless frame tap at `time` — written at exactly that 2× size,
/// so canvasScale is 2 — is compared whole-frame and by the cursor's drawn
/// box (cursor on vs off, the Mac `--cursor-export-parity` measurement).
///
/// The Mac has never gated whole-frame preview vs export, so the whole-frame
/// bar is RELATIVE: the iOS run must be no worse than the Mac control on the
/// same case (`--reference <mac results.json>`); the cursor bar is absolute
/// (Δsize ≤ 4 px, Δposition ≤ 6 px on the 2× grid, as on the Mac).
enum PreviewExportParityHarness {
    static let scale: CGFloat = 2
    static let time: TimeInterval = 3.0
    static let duration: TimeInterval = 4.0
    static let fps = 30
    /// iOS may exceed the Mac's whole-frame numbers by at most this much.
    static let meanSlack = 0.5
    static let over8Slack = 0.005

    struct Box: Codable, CustomStringConvertible {
        var minX: Int, minY: Int, maxX: Int, maxY: Int
        var width: Int { maxX - minX + 1 }
        var height: Int { maxY - minY + 1 }
        var description: String { "x=\(minX)…\(maxX) y=\(minY)…\(maxY) \(width)×\(height)" }
    }

    struct CaseResult: Codable {
        var name: String
        var mean: Double = 255
        var over8: Double = 1
        var maxDelta: Int = 255
        var previewCursor: Box?
        var exportCursor: Box?
        var error: String?
    }

    struct Case {
        var name: String
        var measuresCursor = false
        var configure: (Project) -> Void
    }

    static let cases: [Case] = [
        Case(name: "base", measuresCursor: true) { _ in },
        Case(name: "rounded-shadow") { p in
            p.settings.cornerRadius = 28; p.settings.shadowRadius = 40
            p.settings.shadowOpacity = 0.7; p.settings.backgroundPadding = 72
        },
        Case(name: "zoom-held") { p in
            var z = ZoomRegion(startTime: 0, endTime: duration)
            z.zoomLevel = 1.6; z.focalPoint = CGPoint(x: 0.35, y: 0.4); z.followsCursor = false
            p.zoomRegions = [z]
        },
        Case(name: "tilt") { p in
            var t = TiltRegion(startTime: 0, endTime: duration)
            t.pitch = 10; t.yaw = -8
            p.tiltRegions = [t]
        },
        Case(name: "annotations") { p in
            var text = Annotation(type: .text, startTime: 0, endTime: duration)
            text.text = "Preview equals export"; text.x = 0.3; text.y = 0.25
            var box = Annotation(type: .rectangle, startTime: 0, endTime: duration)
            box.x = 0.55; box.y = 0.55; box.arrowEndX = 0.8; box.arrowEndY = 0.8
            p.annotations = [text, box]
        },
        Case(name: "cursor-inverted-1.0x", measuresCursor: true) { p in
            p.settings.cursorStyle = .inverted; p.settings.cursorScale = 1.0
        },
        Case(name: "cursor-hand-2.0x", measuresCursor: true) { p in
            p.settings.cursorStyle = .hand; p.settings.cursorScale = 2.0
        },
    ]

    /// Harness-only defect (`--inject`): the EXPORT alone gets +4 pt padding
    /// and a 1.3× cursor — the gate must fail (whole frame and cursor box).
    static var injectExportDefect = false

    @MainActor
    static func run(fixtureDir: URL, out: URL, stage: PreviewExportStage, reference: URL?,
                    log: (String) -> Void) async -> [CaseResult] {
        let fm = FileManager.default
        try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        guard let data = try? Data(contentsOf: fixtureDir.appendingPathComponent(ParityFixtureFile.fileName)),
              let file = try? JSONDecoder().decode(ParityFixtureFile.self, from: data),
              let posterSource = CGImageSourceCreateWithURL(
                  fixtureDir.appendingPathComponent(ParityFixtureFile.videoFrame) as CFURL, nil),
              let poster = CGImageSourceCreateImageAtIndex(posterSource, 0, nil) else {
            log("PREVIEW-EXPORT FAIL fixture unreadable at \(fixtureDir.path)")
            return []
        }
        let canvas = file.canvas
        let movie = out.appendingPathComponent("source.mov")
        do {
            try? fm.removeItem(at: movie)
            _ = try await StillMovieWriter.write(image: poster, to: movie, duration: duration)
        } catch {
            log("PREVIEW-EXPORT FAIL still movie: \(error)")
            return []
        }
        guard let decoded = await decodedFrame(movie, at: time) else {
            log("PREVIEW-EXPORT FAIL cannot decode the still movie")
            return []
        }
        let previewPoster = platformImage(decoded)
        // A stationary cursor (the same position at every time on both sides).
        let space = CursorOverlayLayout.resolveCoordinateSize(recordedSize: file.coordinateSize,
                                                              fallbackSourceSize: file.videoSize)
        let point = CGPoint(x: space.width * 0.62, y: space.height * 0.55)
        let events = stride(from: 0.0, through: duration + 0.05, by: 1.0 / 30).map {
            CursorEvent(timestamp: $0, x: point.x, y: point.y, isClick: false)
        }
        let cursorURL = out.appendingPathComponent("cursor.json")
        try? JSONEncoder().encode(CursorRecording(version: 2, coordinateWidth: file.coordinateSize.width,
                                                  coordinateHeight: file.coordinateSize.height, events: events))
            .write(to: cursorURL)
        let references = reference.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([CaseResult].self, from: $0) } ?? []

        var results: [CaseResult] = []
        for c in cases {
            var result = CaseResult(name: c.name)
            func makeProject(cursor: Bool) -> Project? {
                guard let p = try? JSONDecoder().decode(Project.self, from: file.project) else { return nil }
                p.videoURL = movie
                p.cursorDataURL = cursorURL
                p.cameraVideoURL = nil
                p.trimStart = 0; p.trimEnd = duration; p.duration = duration
                p.zoomRegions = []; p.tiltRegions = []; p.annotations = []; p.subtitles = []
                p.speedRegions = []; p.videoClipSegments = []; p.splitPoints = []
                let s = p.settings
                s.showCamera = false; s.showWatermark = false; s.showSubtitles = false
                s.showClickRipple = false; s.motionBlur = false; s.cursorFluidEnabled = false
                s.smoothCursor = false; s.autoHideCursor = false
                s.cursorTilt = 0; s.cursorStretch = 0; s.cursorDrag = 0
                s.cursorStyle = .system; s.cursorScale = 1.5
                s.introSlideStyle = .off; s.curtainUnveilCorner = .off
                s.showCursor = cursor
                s.exportSettings.resolution = .custom
                s.exportSettings.customWidth = Int(canvas.width * scale)
                s.exportSettings.customHeight = Int(canvas.height * scale)
                s.exportSettings.fps = fps
                s.exportSettings.collapseStaticSpans = false
                s.exportSettings.format = .mp4
                c.configure(p)
                return p
            }
            func previewAndExport(cursor: Bool, tag: String) async -> (CGImage, CGImage)? {
                guard let project = makeProject(cursor: cursor) else { return nil }
                // Step the preview at the export's frame times, then capture.
                let frames = Int(time * Double(fps))
                for i in 0...frames {
                    stage.render(input(project, time: Double(i) / Double(fps), events: events, file: file,
                                       poster: previewPoster))
                }
                await settle(0.3)
                stage.render(input(project, time: time, events: events, file: file, poster: previewPoster))
                await settle(0.3)
                guard let preview = await stage.capture() else { return nil }
                let m = stage.core.motion
                log(String(format: "MOTION %@ preview t=%.4f z=%.5f fx=%.4f fy=%.4f ox=%.4f oy=%.4f",
                           c.name, time, m.zoom, m.focalX, m.focalY, m.cardOffsetX, m.cardOffsetY))
                let camDump = out.appendingPathComponent("camera-\(c.name)-\(tag).txt")
                setenv("CAPTURECAT_DUMP_CAMERA", camDump.path, 1)
                defer { unsetenv("CAPTURECAT_DUMP_CAMERA") }
                // `render` set project.previewCanvasSize = canvas → canvasScale 2.
                if injectExportDefect {
                    project.settings.backgroundPadding += 4
                    project.settings.cursorScale *= 1.3
                }
                let tap = out.appendingPathComponent("tap-\(c.name)-\(tag)", isDirectory: true)
                try? fm.removeItem(at: tap)
                setenv("CAPTURECAT_EXPORT_FRAME_TAP", tap.path, 1)
                setenv("CAPTURECAT_EXPORT_FRAME_TAP_INDICES", "\(frames)", 1)
                defer { unsetenv("CAPTURECAT_EXPORT_FRAME_TAP"); unsetenv("CAPTURECAT_EXPORT_FRAME_TAP_INDICES") }
                let url = out.appendingPathComponent("export-\(c.name)-\(tag).mp4")
                do { try await VideoExporter().export(project: project, to: url) } catch {
                    result.error = "export failed: \(error)"
                    return nil
                }
                try? fm.removeItem(at: url)
                if let row = ((try? String(contentsOf: camDump, encoding: .utf8)) ?? "")
                    .split(separator: "\n").first(where: { $0.hasPrefix(String(format: "CAM t=%.4f ", time)) }) {
                    log("MOTION \(c.name) export  \(row)")
                }
                guard let src = CGImageSourceCreateWithURL(
                          tap.appendingPathComponent(String(format: "%04d.png", frames)) as CFURL, nil),
                      let exported = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
                write(preview, out.appendingPathComponent("\(c.name)-\(tag)-preview.png"))
                write(exported, out.appendingPathComponent("\(c.name)-\(tag)-export.png"))
                return (preview, exported)
            }

            guard let (preview, exported) = await previewAndExport(cursor: true, tag: "on") else {
                result.error = result.error ?? "preview or export missing"
                log("PREVIEW-EXPORT \(c.name) ERROR \(result.error ?? "")")
                results.append(result)
                continue
            }
            if let a = HarnessPixels.rgba(preview), let b = HarnessPixels.rgba(exported) {
                let score = ExportParityHarness.compare(a, b, index: 0)
                result.mean = score.mean; result.over8 = score.over8; result.maxDelta = score.maxDelta
                a.deallocate(); b.deallocate()
            }
            if c.measuresCursor, let (previewOff, exportedOff) = await previewAndExport(cursor: false, tag: "off") {
                result.previewCursor = changedBox(on: preview, off: previewOff)
                result.exportCursor = changedBox(on: exported, off: exportedOff)
            }
            let ref = references.first { $0.name == c.name }
            let verdict = judge(result, reference: ref)
            log(String(format: "PREVIEW-EXPORT %@ mean %.3f max %d over8 %.3f%%%@ cursor preview[%@] export[%@] %@",
                       c.name, result.mean, result.maxDelta, result.over8 * 100,
                       ref.map { String(format: " (Mac: mean %.3f over8 %.3f%%)", $0.mean, $0.over8 * 100) } ?? "",
                       result.previewCursor?.description ?? "–", result.exportCursor?.description ?? "–",
                       verdict.pass ? "PASS" : "FAIL \(verdict.reason)"))
            results.append(result)
        }
        if let json = try? JSONEncoder().encode(results) {
            try? json.write(to: out.appendingPathComponent("results.json"))
        }
        let passed = results.filter { result in
            judge(result, reference: references.first { $0.name == result.name }).pass
        }.count
        log("PREVIEW-EXPORT-PARITY \(passed == results.count && !results.isEmpty ? "PASS" : "FAIL") \(passed)/\(results.count) cases · results \(out.appendingPathComponent("results.json").path)")
        return results
    }

    /// Cursor: absolute (the Mac gate's tolerance). Whole frame: no worse than
    /// the Mac control on the same case; without a reference (the control
    /// itself) a sanity bar that catches a broken renderer.
    static func judge(_ r: CaseResult, reference: CaseResult?) -> (pass: Bool, reason: String) {
        if let error = r.error { return (false, error) }
        if let p = r.previewCursor, let e = r.exportCursor {
            let dw = abs(p.width - e.width), dh = abs(p.height - e.height)
            let dx = abs(p.minX - e.minX), dy = abs(p.minY - e.minY)
            if dw > 4 || dh > 4 || dx > 6 || dy > 6 { return (false, "cursor Δsize (\(dw),\(dh)) Δpos (\(dx),\(dy))") }
        } else if r.previewCursor != nil || r.exportCursor != nil {
            return (false, "cursor drawn on one side only")
        }
        if let reference {
            if r.mean > reference.mean + meanSlack || r.over8 > reference.over8 + over8Slack {
                return (false, "worse than the Mac")
            }
        } else if r.mean > 3 {
            return (false, "whole-frame mean above the sanity bar 3/255")
        }
        return (true, "")
    }

    private static func input(_ project: Project, time: TimeInterval, events: [CursorEvent],
                              file: ParityFixtureFile, poster: PlatformImage) -> PreviewCompositorCore.FrameInput {
        PreviewCompositorCore.FrameInput(
            project: project, currentTime: time, isPlaying: false, cursorEvents: events,
            cursorCoordinateSize: file.coordinateSize, videoSize: file.videoSize,
            player: nil, cameraPlayer: nil, cameraPosterImage: nil,
            cameraVideoAspect: file.cameraAspect, videoPosterImage: poster)
    }

    /// The frame at `time`, read the way VideoExporter reads its source.
    private static func decodedFrame(_ url: URL, at time: TimeInterval) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: VideoExporter.sourcePixelFormat,
        ])
        reader.add(output)
        reader.startReading()
        var last: CVPixelBuffer?
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetPresentationTimeStamp(sample).seconds > time + 0.001, last != nil { break }
            last = CMSampleBufferGetImageBuffer(sample)
        }
        reader.cancelReading()
        guard let buffer = last else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        return CIContext(options: VideoExporter.platformPinnedContextOptions)
            .createCGImage(image, from: image.extent, format: .RGBA8,
                           colorSpace: CVImageBufferGetColorSpace(buffer)?.takeUnretainedValue()
                               ?? CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    private static func platformImage(_ cg: CGImage) -> PlatformImage {
        #if canImport(AppKit)
        NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
        #else
        UIImage(cgImage: cg, scale: 1, orientation: .up)
        #endif
    }

    /// Bounding box of pixels that moved by more than `threshold` (max
    /// channel) between cursor on and off — the drawn sprite, not its shadow.
    static func changedBox(on: CGImage, off: CGImage, threshold: Int = 100) -> Box? {
        guard let a = HarnessPixels.rgba(on), let b = HarnessPixels.rgba(off),
              a.width == b.width, a.height == b.height else { return nil }
        defer { a.deallocate(); b.deallocate() }
        var box: Box?
        for y in 0..<a.height {
            let ra = a.bytes + y * a.bytesPerRow, rb = b.bytes + y * b.bytesPerRow
            for x in 0..<a.width {
                var worst = 0
                for c in 0..<3 { worst = max(worst, abs(Int(ra[x * 4 + c]) - Int(rb[x * 4 + c]))) }
                guard worst > threshold else { continue }
                if var bx = box {
                    bx.minX = min(bx.minX, x); bx.maxX = max(bx.maxX, x)
                    bx.minY = min(bx.minY, y); bx.maxY = max(bx.maxY, y)
                    box = bx
                } else {
                    box = Box(minX: x, minY: y, maxX: x, maxY: y)
                }
            }
        }
        return box
    }

    private static func write(_ image: CGImage, _ url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    @MainActor
    private static func settle(_ seconds: Double) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            try? await Task.sleep(for: .milliseconds(30))
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }
}
