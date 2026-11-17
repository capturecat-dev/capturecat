import AVFoundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// `--export-sheet <outDir> [--inject wrong-resolution|snap-progress|cancel-leaves-file|no-background]`
/// (Studio 3d; `apps/ios/scripts/ios-export-sheet.sh`).
///
/// The SHIPPING export sheet, driven by touches in StudioLab's real window
/// chain: the editor (`EditorViewController`, presented full screen) → its
/// header's Export key → `StudioExportSheetController`. Every control is hit-
/// tested in the window at the point a finger would land, then fired the way
/// that touch fires it. Checks:
///
///   • the sheet: docked on compact width / centred on regular, entrance
///     caught MID-FLIGHT; iPhone opens at 1080p30, iPad at the project's settings;
///   • MP4 at 720p30, GIF and a PNG still: the sheet's file equals what
///     `VideoExporter` / `StillImageExporter` produce for the same settings —
///     every pre-encode frame byte-identical through the exporter's lossless tap
///     (`CAPTURECAT_EXPORT_FRAME_TAP`), the file's size / frames / duration
///     equal the reference file's and the settings' resolved size;
///   • progress caught MID-FLIGHT: the bar's drawn fill sampled while
///     exporting is none of the values it was told to show;
///   • Cancel mid-export: the sheet returns to its form and NO partial file
///     is left (the export's folder, the exports directory, temp movies);
///   • the background path is entered and ended for every export
///     (`StudioExportBackground`: continued processing, or the fallback with
///     the "keep the app open" note);
///   • errors: `ExportError.insufficientMemory` arrives as a house CCAlert with
///     its clear message; nothing is left behind;
///   • delivery from the finished sheet: Save to Photos, the Files export
///     picker and the share sheet are presented.
///
/// Each `--inject` defect must turn the gate red.
@available(iOS 26, *)
@MainActor
enum ExportSheetLab {
    enum Inject: String { case wrongResolution = "wrong-resolution", snapProgress = "snap-progress",
                               cancelLeavesFile = "cancel-leaves-file", noBackground = "no-background" }

    static func start(_ arguments: [String], lab: LabViewController) -> Bool {
        guard let i = arguments.firstIndex(of: "--export-sheet"), arguments.indices.contains(i + 1) else { return false }
        let out = URL(fileURLWithPath: arguments[i + 1], isDirectory: true)
        let inject = arguments.firstIndex(of: "--inject").flatMap {
            arguments.indices.contains($0 + 1) ? Inject(rawValue: arguments[$0 + 1]) : nil
        }
        lab.stage.isHidden = true
        Task { @MainActor in
            let pass = await ExportSheetRun(lab: lab, out: out, inject: inject).run()
            exit(pass ? 0 : 1)
        }
        return true
    }

    // MARK: - Touches

    /// Taps `control` where a finger would: the window must deliver a touch
    /// at that point to the control (nothing over it, enabled, visible), then
    /// the control fires as that touch's lift does.
    static func tap(_ control: UIControl, at local: CGPoint? = nil) -> String? {
        guard let window = control.window else { return "not in a window" }
        guard !control.isHidden, control.alpha > 0.01, control.isEnabled else { return "hidden or disabled" }
        let p = control.convert(local ?? CGPoint(x: control.bounds.midX, y: control.bounds.midY), to: window)
        guard let hit = window.hitTest(p, with: nil) else { return "no view at \(p)" }
        guard hit === control || hit.isDescendant(of: control) else { return "covered by \(type(of: hit))" }
        control.sendActions(for: .touchUpInside)
        return nil
    }

    static func tapSegment(_ control: CCSegmented, _ index: Int) -> String? {
        guard let window = control.window else { return "not in a window" }
        let r = control.probeSegmentRect(index)
        let p = control.convert(CGPoint(x: r.midX, y: r.midY), to: window)
        guard let hit = window.hitTest(p, with: nil), hit === control || hit.isDescendant(of: control) else {
            return "segment \(index) not reachable"
        }
        control.probeTap(index)
        return nil
    }

    // MARK: - Media

    static let videoSize = CGSize(width: 1280, height: 720)
    static let duration = 3.0
    static let fps: Int32 = 30

    static func writeMovie(to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let size = videoSize
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
        let total = Int(duration * Double(fps))
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
                let x = 40 + CGFloat(i) / CGFloat(total - 1) * (size.width - 200)
                ctx.fill(CGRect(x: x, y: 300, width: 120, height: 120))
                ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
                ctx.fill(CGRect(x: 100, y: 100 + CGFloat(i % 30) * 4, width: 300, height: 24))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(total), timescale: fps))
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    /// Byte-compares two frame-tap folders.
    static func compareTaps(_ a: URL, _ b: URL) -> (count: Int, other: Int, differing: [String]) {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: a.path)) ?? []).filter { $0.hasSuffix(".png") }.sorted()
        let other = ((try? fm.contentsOfDirectory(atPath: b.path)) ?? []).filter { $0.hasSuffix(".png") }.sorted()
        var differing: [String] = []
        for name in names {
            let x = try? Data(contentsOf: a.appendingPathComponent(name))
            let y = try? Data(contentsOf: b.appendingPathComponent(name))
            if x == nil || x != y { differing.append(name) }
        }
        if names != other { differing.append("names \(names.count) vs \(other.count)") }
        return (names.count, other.count, differing)
    }

    /// A movie's video size, duration and sample count.
    static func movieFacts(_ url: URL) async -> (size: CGSize, duration: Double, samples: Int)? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize),
              let duration = try? await asset.load(.duration),
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var samples = 0
        while let buffer = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(buffer) > 0 { samples += 1 }
        }
        return (size, duration.seconds, samples)
    }

    /// An image file's pixel size, frame count and GIF delays.
    static func imageFacts(_ url: URL) -> (size: CGSize, frames: Int, delays: Set<Double>, type: String)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        var delays = Set<Double>()
        for i in 0..<CGImageSourceGetCount(source) {
            let p = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
            if let gif = p?[kCGImagePropertyGIFDictionary] as? [CFString: Any],
               let d = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double ?? gif[kCGImagePropertyGIFDelayTime] as? Double {
                delays.insert((d * 1000).rounded() / 1000)
            }
        }
        return (CGSize(width: w, height: h), CGImageSourceGetCount(source), delays,
                CGImageSourceGetType(source).map { $0 as String } ?? "?")
    }
}

/// One gate run.
@available(iOS 26, *)
@MainActor
final class ExportSheetRun {
    let lab: LabViewController
    let out: URL
    let inject: ExportSheetLab.Inject?
    private var failures = 0
    private var checks = 0
    private var backgroundLog: [String] = []
    private var editor: EditorViewController?
    private var isPhone: Bool { lab.traitCollection.horizontalSizeClass == .compact }

    init(lab: LabViewController, out: URL, inject: ExportSheetLab.Inject?) {
        self.lab = lab
        self.out = out
        self.inject = inject
    }

    /// What the window shows now, for a look by eye (`<out>/shots/`).
    private func shot(_ name: String) {
        guard let window = editor?.view.window ?? lab.view.window, let image = LabCapture.view(window, scale: 1) else { return }
        let dir = out.appendingPathComponent("shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? LabCapture.png(image).write(to: dir.appendingPathComponent("\(isPhone ? "iphone" : "ipad")-\(name).png"))
    }

    private func check(_ name: String, _ pass: Bool, _ detail: String = "") {
        checks += 1
        if !pass { failures += 1 }
        print("EXPORT-SHEET \(pass ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    }

    private func touch(_ what: String, _ result: String?) {
        if let result { check("touch: \(what)", false, result) }
    }

    func run() async -> Bool {
        let fm = FileManager.default
        try? fm.removeItem(at: out)
        try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        print("EXPORT-SHEET ios out=\(out.path) device=\(isPhone ? "iPhone" : "iPad")" + (inject.map { " inject=\($0.rawValue)" } ?? ""))
        switch inject {
        case .wrongResolution?: StudioExportSheetController.probeWrongResolution = true
        case .snapProgress?: CCMotion.probeSnap = true
        case .cancelLeavesFile?: StudioExportJob.probeDefect = .cancelLeavesFile
        case .noBackground?: StudioExportBackground.probeSkip = true
        case nil: break
        }
        StudioExportBackground.probeLog = { [weak self] line in
            self?.backgroundLog.append(line)
            print("   background: \(line)")
        }
        try? fm.removeItem(at: StudioExportJob.exportsDirectory)
        let movie = out.appendingPathComponent("media/video.mov")
        do {
            try fm.createDirectory(at: movie.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await ExportSheetLab.writeMovie(to: movie)
        } catch {
            check("synthetic recording written", false, "\(error)")
            return finish()
        }

        // 1. A screen recording: MP4, GIF, Cancel, the error path.
        if await open(project: makeProject(name: "Sheet Gate", still: false), media: movie, folder: "video") {
            await entranceAndDefaults()
            await exportAndCompare(label: "mp4", format: 0, resolution: 0, fps: 0, fallback: false)
            await exportAndCompare(label: "gif", format: 2, resolution: 0, fps: 0, fallback: true)
            await cancelMidExport()
            await errorPath()
            await closeEditor()
        }
        // 2. A still capture in Image treatment: PNG.
        if await open(project: makeProject(name: "Still Gate", still: true), media: movie, folder: "still") {
            await stillPNG()
            await closeEditor()
        }
        return finish()
    }

    private func finish() -> Bool {
        let pass = failures == 0 && checks > 0
        print("EXPORT-SHEET-GATE \(pass ? "PASS" : "FAIL") \(checks - failures)/\(checks) checks")
        return pass
    }

    // MARK: - Fixture

    private func makeProject(name: String, still: Bool) -> Project {
        let project = Project(id: UUID(), name: name, duration: ExportSheetLab.duration, recordingSourceKind: .display)
        project.adoptNewProjectReferenceCanvas()
        project.isStillCapture = still
        project.stillTreatment = .image
        if !still {
            var zoom = ZoomRegion(startTime: 0.6, endTime: 2.2)
            zoom.zoomLevel = 1.6
            project.zoomRegions = [zoom]
        }
        return project
    }

    private func open(project: Project, media: URL, folder name: String) async -> Bool {
        let fm = FileManager.default
        let dir = out.appendingPathComponent("projects/\(name)", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let video = dir.appendingPathComponent("video.mov")
        try? fm.copyItem(at: media, to: video)
        project.videoURL = video
        do {
            try JSONEncoder().encode(project).write(to: dir.appendingPathComponent(StudioProjectFolder.documentName))
            let folder = try StudioProjectFolder.open(dir)
            let editor = EditorViewController(folder: folder)
            editor.onClose = {}
            self.editor = editor
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lab.present(editor, animated: false) { c.resume() }
            }
        } catch {
            check("[\(name)] project opens", false, "\(error)")
            return false
        }
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, !(editor?.playback.isReady ?? false) { await LabTime.settle(0.05) }
        await LabTime.settle(0.5)
        check("[\(name)] editor ready", editor?.playback.isReady == true && editor?.project.previewCanvasSize.width ?? 0 > 0,
              "canvas \(editor?.project.previewCanvasSize ?? .zero)")
        return editor?.playback.isReady == true
    }

    private func closeEditor() async {
        guard let editor else { return }
        while let presented = editor.presentedViewController {
            presented.dismiss(animated: false)
            await LabTime.settle(0.2)
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            editor.dismiss(animated: false) { c.resume() }
        }
        editor.playback.teardown()
        self.editor = nil
        await LabTime.settle(0.3)
    }

    /// Opens the sheet with the editor's header key.
    private func openSheet() async -> StudioExportSheetController? {
        guard let editor else { return nil }
        touch("header Export key", ExportSheetLab.tap(editor.exportButton))
        await LabTime.settle(0.05)
        guard let sheet = editor.presentedViewController as? StudioExportSheetController else {
            check("the Export key presents the export sheet", false, "\(String(describing: editor.presentedViewController))")
            return nil
        }
        await LabTime.settle(0.6)
        return sheet
    }

    private func closeSheet(_ sheet: StudioExportSheetController) async {
        let button = sheet.phase == .done ? sheet.doneButton : sheet.cancelButton
        touch("\(button.title)", ExportSheetLab.tap(button))
        await LabTime.settle(0.6)
        check("the sheet closes", editor?.presentedViewController == nil)
    }

    // MARK: - Entrance + defaults

    private func entranceAndDefaults() async {
        guard let editor else { return }
        touch("header Export key", ExportSheetLab.tap(editor.exportButton))
        guard let sheet = editor.presentedViewController as? StudioExportSheetController else {
            check("the Export key presents the export sheet", false)
            return
        }
        // The entrance, sampled as it runs.
        var samples: [CGFloat] = []
        for _ in 0..<24 {
            await LabTime.settle(1.0 / 60)
            let layer = sheet.card.layer.presentation() ?? sheet.card.layer
            samples.append(sheet.isDocked ? (layer.value(forKeyPath: "transform.translation.y") as? CGFloat ?? 0)
                                          : (layer.value(forKeyPath: "transform.scale") as? CGFloat ?? 1))
        }
        let rest: CGFloat = sheet.isDocked ? 0 : 1
        let mid = samples.filter { abs($0 - rest) > (sheet.isDocked ? 2 : 0.005) }
        check("entrance caught mid-flight (\(sheet.isDocked ? "rises from the bottom" : "scales in"))", mid.count >= 2,
              "\(mid.count) of \(samples.count) samples off rest; first \(samples.prefix(4).map { String(format: "%.3f", $0) })")
        await LabTime.settle(0.4)
        shot("form")
        // Structure: wrapped labels hug their text (a label measured at the
        // wrong width stretches and leaves its text centred in a gap).
        var stretched: [String] = []
        func walk(_ v: UIView) {
            if let label = v as? UILabel, label.numberOfLines == 0, !label.isHidden, label.window != nil,
               label.bounds.width > 0 {
                let fit = label.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude)).height
                if abs(label.bounds.height - fit) > 1.5 { stretched.append("\"\(label.text ?? "")\" \(label.bounds.height) vs \(fit)") }
            }
            v.subviews.forEach(walk)
        }
        walk(sheet.card)
        check("wrapped labels hug their text", stretched.isEmpty, stretched.joined(separator: "; "))
        // …and the rows hug their content: the toggle row (only a ≥ 44 pt
        // minimum) must not stretch into a gap.
        let row = sheet.fastExportRow
        let rowFit = row.systemLayoutSizeFitting(CGSize(width: row.bounds.width, height: 0),
                                                 withHorizontalFittingPriority: .required,
                                                 verticalFittingPriority: .fittingSizeLevel).height
        check("rows hug their content (no stretched gaps)", abs(row.bounds.height - rowFit) <= 1,
              "Fast export row \(row.bounds.height) pt vs \(rowFit) pt")
        check("docked on compact width, centred on regular", sheet.isDocked == isPhone,
              "docked=\(sheet.isDocked) compact=\(isPhone)")
        let window = sheet.view.window?.bounds ?? .zero
        let card = sheet.card.convert(sheet.card.bounds, to: nil)
        check("the card is on screen", window.contains(card.insetBy(dx: 1, dy: 1)), "\(card) in \(window)")
        // iPhone opens at 1080p30; iPad at the project's saved settings (1080p60).
        let expectFPS = isPhone ? 30 : editor.project.settings.exportSettings.fps
        check("opens at \(isPhone ? "the iPhone default 1080p30" : "the project's settings")",
              sheet.settings.resolution == .hd1080 && sheet.settings.fps == expectFPS
                && sheet.resolutionControl.selectedIndex == 1
                && sheet.frameRateControl.selectedIndex == ExportSheetSpec.frameRateIndex(expectFPS),
              "\(sheet.settings.resolution.rawValue) @ \(sheet.settings.fps)")
        check("caption is the shared spec's", sheet.caption.text == ExportSheetSpec.caption(settings: sheet.settings, project: editor.project),
              sheet.caption.text ?? "nil")
        check("no Type row for a screen recording", !ExportSheetSpec.offersImage(editor.project)
              && sheet.typeControl.superview?.isHidden == true)
        await closeSheet(sheet)
    }

    // MARK: - Export + compare

    private func sampleProgress(_ sheet: StudioExportSheetController, until done: () -> Bool) async -> (mid: Int, samples: Int, texts: Set<String>) {
        var mid = 0, n = 0
        var texts = Set<String>()
        let deadline = Date().addingTimeInterval(240)
        while !done(), Date() < deadline {
            await LabTime.settle(1.0 / 60)
            let row = sheet.progressRow
            let drawn = row.probeDrawnWidth
            let full = row.bar.bounds.width
            n += 1
            if let t = row.label.text { texts.insert(t) }
            if drawn > 0.5, drawn < full - 0.5,
               FeaturesLab.isMidFlight(drawn, shown: row.probeTargetWidths) { mid += 1 }
        }
        return (mid, n, texts)
    }

    private func exportAndCompare(label: String, format: Int, resolution: Int, fps: Int, fallback: Bool) async {
        guard let editor, let sheet = await openSheet() else { return }
        let fm = FileManager.default
        touch("Format", ExportSheetLab.tapSegment(sheet.formatControl, format))
        touch("Resolution", ExportSheetLab.tapSegment(sheet.resolutionControl, resolution))
        touch("Frame Rate", ExportSheetLab.tapSegment(sheet.frameRateControl, fps))
        await LabTime.settle(0.5)
        // What those touches ask for.
        var intended = editor.project.settings.exportSettings
        if isPhone { intended = ExportSheetSpec.phoneDefaults(intended) }
        intended.format = ExportSheetSpec.formats[format]
        intended.resolution = ExportSheetSpec.resolutions[resolution]
        intended.fps = ExportSheetSpec.frameRates[fps]
        check("[\(label)] caption follows the choices", sheet.caption.text == ExportSheetSpec.caption(settings: intended, project: editor.project),
              sheet.caption.text ?? "nil")

        let tapSheet = out.appendingPathComponent("tap-\(label)-sheet", isDirectory: true)
        try? fm.removeItem(at: tapSheet)
        setenv("CAPTURECAT_EXPORT_FRAME_TAP", tapSheet.path, 1)
        StudioExportBackground.probeForceFallback = fallback
        backgroundLog.removeAll()
        touch("Export", ExportSheetLab.tap(sheet.exportButton))
        let job = sheet.job
        Task { @MainActor [weak self] in
            await LabTime.settle(0.8)
            self?.shot("exporting-\(label)")
        }
        let progress = await sampleProgress(sheet) {
            if case .running? = job?.state { return false }
            return true
        }
        unsetenv("CAPTURECAT_EXPORT_FRAME_TAP")
        StudioExportBackground.probeForceFallback = false
        guard let job, case .finished(let file) = job.state else {
            check("[\(label)] export finishes", false, "\(String(describing: job?.state))")
            return
        }
        check("[\(label)] progress caught mid-flight", progress.mid >= 3,
              "\(progress.mid) of \(progress.samples) samples between shown values; labels \(progress.texts.count)")
        let path = job.background.path
        check("[\(label)] background path entered and ended",
              path != .none && backgroundLog.contains { $0.hasPrefix("background end") },
              "path=\(path.rawValue) gpu=\(job.background.usesGPU)" + (fallback ? " (fallback forced)" : ""))
        if !fallback {
            // The continued-processing request was made (the Simulator answers
            // `unavailable`; a device runs it — the plan's device list).
            check("[\(label)] continued processing requested first",
                  path == .continuedProcessing || backgroundLog.contains { $0.hasPrefix("continued-processing submit") },
                  backgroundLog.first { $0.hasPrefix("continued-processing") } ?? "path=\(path.rawValue)")
        }
        if fallback {
            check("[\(label)] fallback says to keep the app open", path == .backgroundTask
                  && sheet.backgroundNote.text?.contains("Keep CaptureCat open") == true, sheet.backgroundNote.text ?? "")
        }
        check("[\(label)] written inside the exports folder",
              file.path.hasPrefix(StudioExportJob.exportsDirectory.path) && fm.fileExists(atPath: file.path), file.lastPathComponent)

        // The reference: VideoExporter itself, the same settings, the same project.
        let tapRef = out.appendingPathComponent("tap-\(label)-ref", isDirectory: true)
        try? fm.removeItem(at: tapRef)
        let reference = out.appendingPathComponent("ref-\(label).\(file.pathExtension)")
        editor.project.settings.exportSettings = intended
        setenv("CAPTURECAT_EXPORT_FRAME_TAP", tapRef.path, 1)
        do {
            try await VideoExporter().export(project: editor.project, to: reference)
        } catch {
            check("[\(label)] reference export", false, "\(error)")
        }
        unsetenv("CAPTURECAT_EXPORT_FRAME_TAP")
        let taps = ExportSheetLab.compareTaps(tapSheet, tapRef)
        check("[\(label)] every pre-encode frame byte-identical to VideoExporter's", taps.count > 0 && taps.differing.isEmpty,
              "\(taps.count) sheet / \(taps.other) reference frames, \(taps.differing.count) differ \(taps.differing.prefix(3))")
        let size = intended.resolvedOutputSize(for: editor.project.settings.aspectRatio, sourceSize: ExportSheetLab.videoSize)
        if intended.format == .gif {
            let a = ExportSheetLab.imageFacts(file), b = ExportSheetLab.imageFacts(reference)
            let want = GIFExportPolicy.frameSize(for: size)
            let rate = GIFExportPolicy.frameRate(forRequested: intended.fps)
            let frames = GIFExportPolicy.frameCount(duration: ExportSheetLab.duration, frameRate: rate)
            check("[\(label)] GIF: size, frames and delays as the policy and the reference",
                  a?.size == want && a?.frames == frames && a?.delays == [Double(GIFExportPolicy.delayCentiseconds(frameRate: rate)) / 100]
                    && a?.size == b?.size && a?.frames == b?.frames && a?.type == UTType.gif.identifier,
                  "\(a.map { "\(Int($0.size.width))×\(Int($0.size.height)) \($0.frames) frames \($0.delays)" } ?? "unreadable") vs want \(Int(want.width))×\(Int(want.height)) \(frames)")
        } else {
            let a = await ExportSheetLab.movieFacts(file), b = await ExportSheetLab.movieFacts(reference)
            check("[\(label)] movie: size, duration and samples as the settings and the reference",
                  a != nil && a?.size == size && a?.size == b?.size && a?.samples == b?.samples
                    && abs((a?.duration ?? 0) - (b?.duration ?? -1)) < 1e-6,
                  "\(a.map { "\(Int($0.size.width))×\(Int($0.size.height)) \(String(format: "%.3f", $0.duration)) s \($0.samples) samples" } ?? "unreadable")"
                  + " vs reference \(b.map { "\(Int($0.size.width))×\(Int($0.size.height)) \($0.samples)" } ?? "–") · settings \(Int(size.width))×\(Int(size.height))")
        }
        try? fm.removeItem(at: reference)
        await LabTime.settle(0.8)
        shot("done-\(label)")
        check("[\(label)] the sheet shows the finished export", sheet.phase == .done
              && !sheet.photosButton.isHidden && !sheet.filesButton.isHidden && !sheet.shareButton.isHidden,
              "phase \(sheet.phase.rawValue) · \(sheet.summary.text ?? "")")
        if label == "mp4" { await deliver(sheet) }
        await closeSheet(sheet)
        check("[\(label)] the finished file is discarded with the sheet",
              !fm.fileExists(atPath: file.deletingLastPathComponent().path))
    }

    /// Delivery from the finished sheet: Photos, Files, Share.
    private func deliver(_ sheet: StudioExportSheetController) async {
        touch("Save to Photos", ExportSheetLab.tap(sheet.photosButton))
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, sheet.photosButton.title != "Saved to Photos", sheet.probeAlerts.isEmpty {
            await LabTime.settle(0.1)
        }
        check("Save to Photos saves", sheet.photosButton.title == "Saved to Photos",
              sheet.probeAlerts.last.map { "alert: \($0.message)" } ?? sheet.photosButton.title)
        for (button, name, expected) in [(sheet.filesButton, "Save to Files", UIDocumentPickerViewController.self as UIViewController.Type),
                                         (sheet.shareButton, "Share", UIActivityViewController.self)] {
            touch(name, ExportSheetLab.tap(button))
            var presented: UIViewController?
            let until = Date().addingTimeInterval(5)
            while Date() < until {
                presented = sheet.presentedViewController
                if let presented, type(of: presented) == expected || presented.isKind(of: expected), !presented.isBeingPresented { break }
                await LabTime.settle(0.1)
            }
            check("\(name) presents \(expected)", presented.map { $0.isKind(of: expected) } ?? false
                  && sheet.probePresented.last === presented,
                  presented.map { "\(type(of: $0))" } ?? "nothing presented")
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                if let presented { presented.dismiss(animated: false) { c.resume() } } else { c.resume() }
            }
            await LabTime.settle(0.5)
        }
    }

    // MARK: - Cancel

    private func cancelMidExport() async {
        guard let sheet = await openSheet() else { return }
        let fm = FileManager.default
        touch("Format MP4", ExportSheetLab.tapSegment(sheet.formatControl, 0))
        touch("Resolution 1080p", ExportSheetLab.tapSegment(sheet.resolutionControl, 1))
        touch("Frame Rate 60", ExportSheetLab.tapSegment(sheet.frameRateControl, 1))
        if sheet.fastExportRow.isOn { touch("Fast export off", ExportSheetLab.tap(sheet.fastExportRow)) }
        await LabTime.settle(0.4)
        let tempBefore = Set((try? fm.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? [])
        touch("Export", ExportSheetLab.tap(sheet.exportButton))
        guard let job = sheet.job else { check("cancel: export started", false); return }
        let folder = job.destination.deletingLastPathComponent()
        let started = Date()
        while Date().timeIntervalSince(started) < 60, job.state == .running, job.progress < 0.1 {
            await LabTime.settle(0.05)
        }
        let at = job.progress
        let partial = fm.fileExists(atPath: job.destination.path)
        check("cancel: caught mid-export with a partial file on disk", job.state == .running && at > 0 && at < 0.9 && partial,
              String(format: "progress %.2f, partial file %@", at, partial ? "yes" : "no"))
        touch("Cancel Export", ExportSheetLab.tap(sheet.cancelExportButton))
        let until = Date().addingTimeInterval(10)
        while Date() < until, sheet.phase != .form { await LabTime.settle(0.05) }
        await LabTime.settle(0.5)
        check("cancel: the sheet returns to its form", sheet.phase == .form && job.state == .cancelled,
              "phase \(sheet.phase.rawValue), job \(job.state)")
        let leftovers = ((try? fm.subpathsOfDirectory(atPath: StudioExportJob.exportsDirectory.path)) ?? [])
        let newTemp = Set((try? fm.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? []).subtracting(tempBefore)
            .filter { $0.hasPrefix("capturecat-") }
        check("cancel: no partial file left", !fm.fileExists(atPath: folder.path) && leftovers.isEmpty && newTemp.isEmpty,
              "folder \(fm.fileExists(atPath: folder.path) ? "still there" : "gone"), exports \(leftovers), temp \(newTemp)")
        check("cancel: the background path ended", backgroundLog.contains { $0.hasPrefix("background end") && $0.contains("success=false") })
        await closeSheet(sheet)
    }

    // MARK: - Errors

    private func errorPath() async {
        guard let sheet = await openSheet() else { return }
        StudioExportJob.probeForcedError = VideoExporter.ExportError.insufficientMemory(needed: 900 << 20, available: 400 << 20)
        touch("Export", ExportSheetLab.tap(sheet.exportButton))
        let folder = sheet.job?.destination.deletingLastPathComponent()
        let until = Date().addingTimeInterval(5)
        while Date() < until, sheet.probeAlerts.isEmpty { await LabTime.settle(0.05) }
        StudioExportJob.probeForcedError = nil
        await LabTime.settle(0.6)
        let alert = sheet.probeAlerts.last
        check("insufficient memory: a house alert with a clear message",
              alert?.title == "Not enough memory to export" && alert?.message.contains("Not enough free memory") == true
                && alert?.message.contains("lower resolution") == true
                && sheet.presentedViewController is CCAlertController,
              "\(alert?.title ?? "no alert"): \(alert?.message ?? "")")
        check("insufficient memory: back to the form, nothing written",
              sheet.phase == .form && !(folder.map { FileManager.default.fileExists(atPath: $0.path) } ?? true))
        alert?.dismiss()
        await LabTime.settle(0.5)
        await closeSheet(sheet)
    }

    // MARK: - PNG

    private func stillPNG() async {
        guard let editor, let sheet = await openSheet() else { return }
        let fm = FileManager.default
        check("[png] Type row offered, Image (PNG) chosen for a still with no timed effects",
              ExportSheetSpec.offersImage(editor.project) && sheet.outputKind == .image
                && sheet.typeControl.superview?.isHidden == false && sheet.typeControl.selectedIndex == 0
                && sheet.formatControl.superview?.isHidden == true)
        touch("Resolution 720p", ExportSheetLab.tapSegment(sheet.resolutionControl, 0))
        await LabTime.settle(0.4)
        var intended = editor.project.settings.exportSettings
        if isPhone { intended = ExportSheetSpec.phoneDefaults(intended) }
        intended.resolution = .hd720
        let tapSheet = out.appendingPathComponent("tap-png-sheet", isDirectory: true)
        setenv("CAPTURECAT_EXPORT_FRAME_TAP", tapSheet.path, 1)
        backgroundLog.removeAll()
        touch("Export", ExportSheetLab.tap(sheet.exportButton))
        let job = sheet.job
        let until = Date().addingTimeInterval(60)
        while Date() < until, job?.state == .running { await LabTime.settle(0.05) }
        unsetenv("CAPTURECAT_EXPORT_FRAME_TAP")
        guard let job, case .finished(let file) = job.state else {
            check("[png] export finishes", false, "\(String(describing: job?.state))")
            return
        }
        check("[png] background path entered and ended", job.background.path != .none
              && backgroundLog.contains { $0.hasPrefix("background end") }, "path=\(job.background.path.rawValue)")
        let tapRef = out.appendingPathComponent("tap-png-ref", isDirectory: true)
        let reference = out.appendingPathComponent("ref.png")
        editor.project.settings.exportSettings = intended
        setenv("CAPTURECAT_EXPORT_FRAME_TAP", tapRef.path, 1)
        do { try await StillImageExporter.exportPNG(project: editor.project, to: reference) } catch {
            check("[png] reference export", false, "\(error)")
        }
        unsetenv("CAPTURECAT_EXPORT_FRAME_TAP")
        let taps = ExportSheetLab.compareTaps(tapSheet, tapRef)
        check("[png] the still's rendered frames byte-identical to StillImageExporter's", taps.count > 0 && taps.differing.isEmpty,
              "\(taps.count) / \(taps.other) frames, \(taps.differing.count) differ")
        let a = ExportSheetLab.imageFacts(file), b = ExportSheetLab.imageFacts(reference)
        let size = intended.resolvedOutputSize(for: editor.project.settings.aspectRatio, sourceSize: ExportSheetLab.videoSize)
        check("[png] PNG at the settings' size, as the reference",
              a?.type == UTType.png.identifier && a?.size == size && a?.size == b?.size && a?.frames == 1,
              "\(a.map { "\($0.type) \(Int($0.size.width))×\(Int($0.size.height))" } ?? "unreadable") vs \(Int(size.width))×\(Int(size.height))")
        try? fm.removeItem(at: reference)
        await LabTime.settle(0.6)
        await closeSheet(sheet)
        // The Type row switches the sheet to video (format / rate rows return).
        guard let again = await openSheet() else { return }
        touch("Type Video", ExportSheetLab.tapSegment(again.typeControl, 1))
        await LabTime.settle(0.6)
        check("[png] Type → Video shows the video rows", again.outputKind == .video
              && again.formatControl.superview?.isHidden == false && again.frameRateControl.superview?.isHidden == false)
        await closeSheet(again)
    }
}
