import AVFoundation
import ImageIO
import UIKit

/// `--background-export-probe <outDir> [--seconds N]` — a DEVICE check for
/// Studio 3d's background export (the Simulator refuses every
/// BGContinuedProcessingTask, so `--export-sheet` can only prove the request
/// and the fallback). Phase 0 §3.8 left open whether frames rendered in the
/// background WITHOUT `.gpu` (unsupported on an iPhone 15 Pro Max) are right.
///
/// 1. writes a synthetic 1080p movie (`--seconds`, default 40) and a project
///    with a zoom across most of it;
/// 2. exports it in the FOREGROUND straight through `VideoExporter`, tapping
///    every 15th frame losslessly (`CAPTURECAT_EXPORT_FRAME_TAP[_INDICES]`);
/// 3. exports it again through the shipping `StudioExportJob` (so
///    `StudioExportBackground` submits its continued-processing task), with
///    the same taps, printing `BG-EXPORT-STARTED`, then a progress line every
///    0.5 s with the app state — the host script backgrounds the app
///    (launches Settings) when it sees the start line;
/// 4. compares: every tapped frame byte-identical, the same movie facts, at
///    least one tapped frame rendered while the app was in the background, and
///    which background path ran.
///
/// Prints `BG-EXPORT-PROBE PASS|FAIL` and exits.
@available(iOS 26, *)
@MainActor
enum BackgroundExportProbe {
    static func start(_ arguments: [String], lab: LabViewController) -> Bool {
        guard let i = arguments.firstIndex(of: "--background-export-probe"), arguments.indices.contains(i + 1) else { return false }
        let out = LabPath.url(arguments[i + 1])
        let seconds = arguments.firstIndex(of: "--seconds").flatMap { arguments.indices.contains($0 + 1) ? Double(arguments[$0 + 1]) : nil } ?? 40
        lab.stage.isHidden = true
        UIApplication.shared.isIdleTimerDisabled = true
        Task { @MainActor in
            let pass = await run(out: out, seconds: seconds)
            print("BG-EXPORT-PROBE \(pass ? "PASS" : "FAIL")")
            exit(pass ? 0 : 1)
        }
        return true
    }

    static let size = CGSize(width: 1920, height: 1080)
    static let fps: Int32 = 30
    static let stride = 15

    /// Every result line also goes to `<out>/result.txt`: the device console
    /// stream can drop once the app leaves the screen.
    static var resultFile: URL?
    static func print(_ line: String) {
        Swift.print(line)
        guard let url = resultFile, let data = (line + "\n").data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() }
        else { try? data.write(to: url) }
    }

    static func run(out: URL, seconds: Double) async -> Bool {
        let fm = FileManager.default
        try? fm.removeItem(at: out)
        try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        resultFile = out.appendingPathComponent("result.txt")
        let movie = out.appendingPathComponent("source.mov")
        let total = Int(seconds * Double(fps))
        do { try await writeMovie(to: movie, frames: total) } catch {
            print("BG-EXPORT FAIL source movie: \(error)")
            return false
        }
        print("BG-EXPORT source \(Int(size.width))×\(Int(size.height)) \(total) frames")

        func project() -> Project {
            let p = Project(id: UUID(), name: "Background Probe", duration: seconds, recordingSourceKind: .display)
            p.adoptNewProjectReferenceCanvas()
            p.videoURL = movie
            var zoom = ZoomRegion(startTime: 1, endTime: max(2, seconds - 1))
            zoom.zoomLevel = 1.6
            p.zoomRegions = [zoom]
            var settings = p.settings.exportSettings
            settings.format = .mp4
            settings.resolution = .hd1080
            settings.fps = 30
            settings.collapseStaticSpans = false
            p.settings.exportSettings = settings
            return p
        }
        let indices = Swift.stride(from: 0, to: total, by: stride).map(String.init).joined(separator: ",")
        setenv("CAPTURECAT_EXPORT_FRAME_TAP_INDICES", indices, 1)
        defer {
            unsetenv("CAPTURECAT_EXPORT_FRAME_TAP")
            unsetenv("CAPTURECAT_EXPORT_FRAME_TAP_INDICES")
        }

        // 2. Foreground reference.
        let tapA = out.appendingPathComponent("tap-foreground", isDirectory: true)
        try? fm.createDirectory(at: tapA, withIntermediateDirectories: true)
        setenv("CAPTURECAT_EXPORT_FRAME_TAP", tapA.path, 1)
        let reference = out.appendingPathComponent("foreground.mp4")
        let t0 = Date()
        do { try await VideoExporter().export(project: project(), to: reference) } catch {
            print("BG-EXPORT FAIL foreground export: \(error)")
            return false
        }
        print(String(format: "BG-EXPORT foreground export %.1f s", Date().timeIntervalSince(t0)))

        // 3. The shipping job, backgrounded by the host mid-export.
        let tapB = out.appendingPathComponent("tap-background", isDirectory: true)
        try? fm.createDirectory(at: tapB, withIntermediateDirectories: true)
        setenv("CAPTURECAT_EXPORT_FRAME_TAP", tapB.path, 1)
        var paths: [String] = []
        StudioExportBackground.probeLog = { line in
            paths.append(line)
            print("BG-EXPORT path: \(line)")
        }
        defer { StudioExportBackground.probeLog = nil }
        let p = project()
        let job = StudioExportJob(project: p, kind: .video, settings: p.settings.exportSettings)
        let t1 = Date()
        job.start()
        print("BG-EXPORT-STARTED")
        var backgroundFrames = Set<Int>()
        var states: [String] = []
        var lastState = ""
        while case .running = job.state {
            try? await Task.sleep(for: .milliseconds(500))
            let state: String
            switch UIApplication.shared.applicationState {
            case .active: state = "active"
            case .inactive: state = "inactive"
            case .background: state = "background"
            @unknown default: state = "?"
            }
            let frame = Int(job.progress * Double(total))
            if state == "background" { backgroundFrames.insert(frame) }
            if state != lastState { states.append("\(state)@\(frame)"); lastState = state }
            print(String(format: "BG-EXPORT progress %.3f frame %d state %@", job.progress, frame, state))
        }
        let elapsed = Date().timeIntervalSince(t1)
        guard case .finished(let file) = job.state else {
            print("BG-EXPORT FAIL job ended \(job.state)")
            return false
        }
        print(String(format: "BG-EXPORT job export %.1f s; states %@", elapsed, states.joined(separator: " → ")))

        // 4. Compare.
        var pass = true
        func check(_ name: String, _ ok: Bool, _ detail: String) {
            print("BG-EXPORT \(ok ? "PASS" : "FAIL") \(name) — \(detail)")
            if !ok { pass = false }
        }
        let cpuFrames = job.exporter.cpuRenderedFrames
        print("BG-EXPORT NOTE \(cpuFrames) frame(s) rendered on the CPU (GPU refused)")
        let cmp = ExportSheetLab.compareTaps(tapA, tapB)
        check("same tapped frames", cmp.count > 0 && cmp.count == cmp.other, "\(cmp.count) vs \(cmp.other)")
        // Byte-identical where the GPU rendered; where the CPU did, Core
        // Image's software renderer is measured against the GPU's frame.
        var worstMean = 0.0, worstMax = 0, worstOver8 = 0.0
        for name in cmp.differing where name.hasSuffix(".png") {
            guard let d = diff(tapA.appendingPathComponent(name), tapB.appendingPathComponent(name)) else {
                check("frame \(name) readable", false, ""); continue
            }
            worstMean = max(worstMean, d.mean); worstMax = max(worstMax, d.max); worstOver8 = max(worstOver8, d.over8)
            print(String(format: "BG-EXPORT NOTE frame %@ differs: mean %.3f max %d >8 %.4f%%", name, d.mean, d.max, d.over8 * 100))
        }
        check("GPU-rendered frames byte-identical; CPU-rendered frames close (mean ≤ 0.5, >8/255 ≤ 0.1% px)",
              cmp.differing.isEmpty || (cpuFrames > 0 && worstMean <= 0.5 && worstOver8 <= 0.001),
              String(format: "%d differing of %d; worst mean %.3f max %d >8 %.4f%%", cmp.differing.count, cmp.count, worstMean, worstMax, worstOver8 * 100))
        let tapped = Set(Swift.stride(from: 0, to: total, by: stride))
        let lo = backgroundFrames.min() ?? -1, hi = backgroundFrames.max() ?? -1
        let tappedInBackground = tapped.filter { $0 >= lo && $0 <= hi && lo >= 0 }.count
        check("tapped frames rendered while backgrounded", tappedInBackground > 0,
              "\(tappedInBackground) tapped frame(s) in background span \(lo)…\(hi)")
        let a = await ExportSheetLab.movieFacts(reference), b = await ExportSheetLab.movieFacts(file)
        check("same movie facts", a != nil && a?.size == b?.size && a?.samples == b?.samples && abs((a?.duration ?? 0) - (b?.duration ?? -1)) < 0.001,
              "foreground \(a.map { "\($0.size) \($0.samples) \($0.duration)" } ?? "–") · background \(b.map { "\($0.size) \($0.samples) \($0.duration)" } ?? "–")")
        print("BG-EXPORT NOTE background path: \(paths.joined(separator: " | "))")
        job.discard()
        return pass
    }

    /// Mean / max per-pixel channel difference and the share of pixels off by more than 8.
    static func diff(_ a: URL, _ b: URL) -> (mean: Double, max: Int, over8: Double)? {
        func px(_ u: URL) -> (Int, Int, [UInt8])? {
            guard let src = CGImageSourceCreateWithURL(u as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
            let w = img.width, h = img.height
            var buf = [UInt8](repeating: 0, count: w * h * 4)
            guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return (w, h, buf)
        }
        guard let x = px(a), let y = px(b), x.0 == y.0, x.1 == y.1 else { return nil }
        var sum = 0, worst = 0, over = 0
        for i in Swift.stride(from: 0, to: x.2.count, by: 4) {
            var m = 0
            for c in 0..<3 { m = Swift.max(m, abs(Int(x.2[i + c]) - Int(y.2[i + c]))) }
            sum += m; worst = Swift.max(worst, m); if m > 8 { over += 1 }
        }
        let n = Double(x.0 * x.1)
        return (Double(sum) / n, worst, Double(over) / n)
    }

    static func writeMovie(to url: URL, frames total: Int) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        for i in 0..<total {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            guard let pool = adaptor.pixelBufferPool else { throw CocoaError(.fileWriteUnknown) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height),
                                   bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: cs,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                let colors = [CGColor(srgbRed: 0.12, green: 0.2, blue: 0.45, alpha: 1), CGColor(srgbRed: 0.85, green: 0.45, blue: 0.3, alpha: 1)]
                if let g = CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: [0, 1]) {
                    ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
                }
                ctx.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0.3, alpha: 1))
                let x = 40 + CGFloat(i) / CGFloat(max(1, total - 1)) * (size.width - 200)
                ctx.fill(CGRect(x: x, y: 420, width: 160, height: 160))
                ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
                ctx.fill(CGRect(x: 120, y: 120 + CGFloat(i % 30) * 6, width: 420, height: 32))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(total), timescale: fps))
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
}
