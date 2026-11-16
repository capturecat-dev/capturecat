import AVFoundation
import ImageIO
import UIKit

/// `--editor-shell <fixtureDir> --transcript <mac.txt> [--out <dir>] [--only a,b]`
/// (Studio 4b) — the iOS editor in the real window chain, against the Mac.
///
/// 1. **Gestures.** The Mac's `--preview-gesture-test` scenarios, ported
///    gesture for gesture (same fixture project — the Mac's own, dumped by
///    `--preview-parity-fixtures` — same objects, ids, canvases, times and
///    targets). Each scenario is written as a real project FOLDER
///    (project.json pointing at the Mac's absolute paths + media), opened
///    through `StudioProjectFolder` (media re-pointed) into a fresh
///    `EditorViewController` presented full screen, and driven through the
///    touch surface's own entry points (`EditorCanvasView.touchDown/Moved/
///    Up`, what UIKit's touches call). The transcript — every canvas
///    callback and model write, the Mac rig's format — must equal the Mac's
///    live transcript (the script passes `--preview-gesture-test --print`).
///    One documented normalization on BOTH sides: the `undo=` token is
///    dropped from `ui:` lines, because iOS registers one undo step per
///    canvas edit and the Mac registers only Camera Height. Undo is gated on
///    its own instead: unwinding every step must restore the scenario's
///    opening project byte for byte, and redo the final one.
/// 2. **Playback.** A real project played in the editor, captured as a
///    SEQUENCE (CLAUDE.md §3): the playhead and the delivered video frames
///    advance, the moving marker burned into the synthetic movie moves
///    right in every capture, and no motion-blur still is shown while
///    playing (the plan's playback exception) — even where the core's blur
///    is active; paused there, the twin's still appears.
@MainActor
enum EditorShellLab {
    struct Options {
        var fixture: URL
        var transcript: URL?
        var out: URL
        var only: Set<String>?
    }

    /// The StudioLab hook (one line in `LabViewController.start`).
    static func handles(_ arguments: [String], host: LabViewController) -> Bool {
        guard let i = arguments.firstIndex(of: "--editor-shell"), arguments.indices.contains(i + 1) else { return false }
        func value(_ name: String) -> String? {
            arguments.firstIndex(of: name).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        let fixture = URL(fileURLWithPath: arguments[i + 1], isDirectory: true)
        let options = Options(
            fixture: fixture,
            transcript: value("--transcript").map { URL(fileURLWithPath: $0) },
            out: value("--out").map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? fixture.deletingLastPathComponent().appendingPathComponent("editor-shell-ios", isDirectory: true),
            only: value("--only").map { Set($0.split(separator: ",").map(String.init)) })
        host.stage.isHidden = true
        guard #available(iOS 26, *) else {
            print("EDITOR-SHELL FAIL the studio needs iOS 26")
            exit(1)
        }
        // Injected defects (gate power): each must turn the gate red.
        switch value("--inject") {
        case "touch": EditorCanvasView.probeTouchOffset = 2
        case "playing-blur": EditorViewController.probeDefect = .blurWhilePlaying
        case "frozen-frames": EditorViewController.probeDefect = .frozenFrames
        case nil: break
        case let other?: print("EDITOR-SHELL FAIL unknown --inject \(other)"); exit(1)
        }
        if let inject = value("--inject") { print("EDITOR-SHELL inject=\(inject)") }
        Task { @MainActor in await run(options, host: host) }
        return true
    }

    @available(iOS 26, *)
    static func run(_ options: Options, host: UIViewController) async {
        setbuf(stdout, nil)
        print("EDITOR-SHELL fixture=\(options.fixture.path) out=\(options.out.path)")
        var failures: [String] = []
        do {
            let fm = FileManager.default
            try? fm.removeItem(at: options.out)
            try fm.createDirectory(at: options.out, withIntermediateDirectories: true)
            let file = try JSONDecoder().decode(
                ParityFixtureFile.self, from: Data(contentsOf: options.fixture.appendingPathComponent(ParityFixtureFile.fileName)))
            let media = try await EditorLabMedia.make(in: options.out.appendingPathComponent("media", isDirectory: true),
                                                      fixture: options.fixture)
            print("EDITOR-SHELL media video=\(media.video.lastPathComponent) camera=\(media.camera.lastPathComponent)")

            // 1 — gestures.
            var lines: [String] = []
            for scenario in EditorGestureScenarios.all where options.only?.contains(scenario.name) ?? true {
                let rig = EditorRig(scenario: scenario.name, canvas: scenario.canvas, fixtureProject: file.project,
                                    out: options.out, media: media)
                rig.stageZoom = scenario.stageZoom
                await scenario.run(rig, host)
                await rig.close()
                lines += rig.transcript
                failures += rig.failures
                print("SCENARIO \(scenario.name)\(scenario.stageZoom == 1 ? "" : " (stage ×\(Int(scenario.stageZoom)))") gestures=\(rig.gestureCount) undoSteps=\(rig.undoSteps) "
                      + "inexactTouches=\(rig.inexactTouches) "
                      + (rig.failures.isEmpty ? "OK" : "FAIL"))
            }
            try lines.joined(separator: "\n").write(to: options.out.appendingPathComponent("ios-transcript.txt"),
                                                    atomically: true, encoding: .utf8)
            failures += compare(ios: lines, macURL: options.transcript, out: options.out)

            // 2 — playback.
            if options.only?.contains("playback") ?? true {
                failures += await EditorPlaybackProbe.run(fixtureProject: file.project, media: media,
                                                          out: options.out, host: host)
            }
        } catch {
            failures.append("setup: \(error)")
        }
        if failures.isEmpty {
            print("EDITOR-SHELL PASS")
            exit(0)
        }
        for f in failures { print("FAIL " + f) }
        print("EDITOR-SHELL FAIL (\(failures.count) problem(s))")
        exit(1)
    }

    // MARK: - Transcript comparison

    /// Drops the `undo=` token from `ui:` lines and re-derives which `ui:`
    /// lines the diff log would then print (a `ui:` line equal to the last
    /// printed one in its scenario disappears) — applied to both sides.
    static func normalize(_ lines: [String]) -> [String] {
        var out: [String] = []
        var lastUI: String?
        for line in lines {
            if line.hasPrefix("== ") { lastUI = nil; out.append(line); continue }
            if line.hasPrefix("   ui: ") {
                let stripped = line.replacingOccurrences(of: #" undo=.*$"#, with: "", options: .regularExpression)
                if stripped == lastUI { continue }
                lastUI = stripped
                out.append(stripped)
                continue
            }
            out.append(line)
        }
        return out
    }

    /// Same text, and every number within one unit of the transcript's
    /// last printed digit (%.6f): the touch path maps view ↔ canvas through
    /// the stage's magnification, ~1e-13, which can flip a value sitting on
    /// a rounding boundary. Anything larger is a behaviour difference.
    static func equalWithinLastDigit(_ a: String, _ b: String) -> Bool {
        let pattern = try! NSRegularExpression(pattern: #"-?\d+(\.\d+)?"#)
        func split(_ s: String) -> (String, [Double]) {
            let ns = s as NSString
            var numbers: [Double] = []
            let skeleton = pattern.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length),
                                                            withTemplate: "#")
            for m in pattern.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                numbers.append(Double(ns.substring(with: m.range)) ?? .nan)
            }
            return (skeleton, numbers)
        }
        let (sa, na) = split(a), (sb, nb) = split(b)
        guard sa == sb, na.count == nb.count else { return false }
        return zip(na, nb).allSatisfy { abs($0 - $1) <= 1.0000001e-6 }
    }

    static func blocks(_ lines: [String]) -> [(name: String, lines: [String])] {
        var result: [(String, [String])] = []
        for line in lines {
            if line.hasPrefix("== ") {
                let name = String(line.dropFirst(3).split(separator: " ").first ?? "")
                result.append((name, [line]))
            } else if !result.isEmpty {
                result[result.count - 1].1.append(line)
            }
        }
        return result
    }

    static func compare(ios: [String], macURL: URL?, out: URL) -> [String] {
        guard let macURL, let text = try? String(contentsOf: macURL, encoding: .utf8) else {
            return ["transcript: no Mac transcript (--transcript)"]
        }
        var macLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while macLines.last?.isEmpty == true { macLines.removeLast() }
        let mac = blocks(normalize(macLines))
        let mine = blocks(normalize(ios))
        try? normalize(ios).joined(separator: "\n").write(
            to: out.appendingPathComponent("ios-transcript.normalized.txt"), atomically: true, encoding: .utf8)
        var failures: [String] = []
        for block in mine {
            guard let reference = mac.first(where: { $0.name == block.name })?.lines else {
                failures.append("transcript: Mac has no scenario \(block.name)")
                continue
            }
            let gestures = block.lines.filter { !$0.hasPrefix(" ") && !$0.hasPrefix("=") }.count
            var shown = 0, lastDigit: [String] = [], bad = 0
            for i in 0..<max(reference.count, block.lines.count) {
                let m = i < reference.count ? reference[i] : "<missing>"
                let o = i < block.lines.count ? block.lines[i] : "<missing>"
                guard m != o else { continue }
                if equalWithinLastDigit(m, o) {
                    lastDigit.append("    line \(i + 1): mac \(m.trimmingCharacters(in: .whitespaces))\n               ios \(o.trimmingCharacters(in: .whitespaces))")
                    continue
                }
                bad += 1
                if shown < 12 {
                    failures.append("transcript \(block.name) line \(i + 1):\n    mac: \(m)\n    ios: \(o)")
                    shown += 1
                }
            }
            if bad == 0 {
                print("TRANSCRIPT \(block.name) PASS (\(gestures) gestures, \(block.lines.count) lines — "
                      + (lastDigit.isEmpty ? "identical to the Mac)" : "\(lastDigit.count) differ only in the last printed digit)"))
                lastDigit.forEach { print($0) }
            } else {
                print("TRANSCRIPT \(block.name) FAIL (\(bad) lines)")
            }
        }
        return failures
    }
}

// MARK: - Media

/// The synthetic media the lab's projects point at: a 12 s, 30 fps,
/// 1280×800 movie of the Mac fixture's video frame with a lime marker
/// that moves right one step per frame (so a playback SEQUENCE can prove
/// frames advance), a 640×360 camera movie, and the watermark PNG the Mac
/// rig writes.
struct EditorLabMedia {
    let video: URL
    let camera: URL
    let watermark: URL
    static let duration: Double = 12
    static let fps: Int32 = 30
    static let videoSize = CGSize(width: 1280, height: 800)
    static let markerSide: CGFloat = 80

    /// Marker x (left edge) in frame `i`, video pixels.
    static func markerX(frame i: Int) -> CGFloat {
        let total = Int(duration) * Int(fps)
        return 40 + CGFloat(i) / CGFloat(total - 1) * (videoSize.width - 80 - markerSide)
    }

    static func make(in dir: URL, fixture: URL) async throws -> EditorLabMedia {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let frameURL = fixture.appendingPathComponent(ParityFixtureFile.videoFrame)
        guard let src = CGImageSourceCreateWithURL(frameURL as CFURL, nil),
              let poster = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw NSError(domain: "editor-shell", code: 1, userInfo: [NSLocalizedDescriptionKey: "fixture video.png"])
        }
        let video = dir.appendingPathComponent("video.mov")
        try await writeMovie(to: video, size: videoSize) { ctx, i in
            ctx.draw(poster, in: CGRect(origin: .zero, size: videoSize))
            ctx.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
            // CG is Y-up here: the marker sits 360 px from the top.
            ctx.fill(CGRect(x: markerX(frame: i), y: videoSize.height - 360 - markerSide,
                            width: markerSide, height: markerSide))
        }
        let camera = dir.appendingPathComponent("camera.mov")
        let cameraSize = CGSize(width: 640, height: 360)
        try await writeMovie(to: camera, size: cameraSize) { ctx, i in
            ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.45, blue: 0.75, alpha: 1))
            ctx.fill(CGRect(origin: .zero, size: cameraSize))
            ctx.setFillColor(CGColor(srgbRed: 0.95, green: 0.8, blue: 0.6, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: 250 + CGFloat(i % 30), y: 100, width: 140, height: 160))
        }
        let watermark = dir.appendingPathComponent("wm.png")
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        if let ctx = CGContext(data: nil, width: 160, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                               space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.9))
            ctx.fill(CGRect(x: 0, y: 0, width: 160, height: 48))
            if let image = ctx.makeImage(),
               let dest = CGImageDestinationCreateWithURL(watermark as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, image, nil)
                CGImageDestinationFinalize(dest)
            }
        }
        return EditorLabMedia(video: video, camera: camera, watermark: watermark)
    }

    private static func writeMovie(to url: URL, size: CGSize,
                                   draw: @escaping (CGContext, Int) -> Void) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
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
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "editor-shell", code: 2) }
        writer.startSession(atSourceTime: .zero)
        let total = Int(duration) * Int(fps)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        for i in 0..<total {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            guard let pool = adaptor.pixelBufferPool else { throw NSError(domain: "editor-shell", code: 3) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw NSError(domain: "editor-shell", code: 4) }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width),
                                   height: Int(size.height), bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: cs,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                       | CGBitmapInfo.byteOrder32Little.rawValue) {
                draw(ctx, i)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(total), timescale: fps))
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? NSError(domain: "editor-shell", code: 5) }
    }
}

// MARK: - Rig

/// The Mac's `GestureRig`, hosted by the real editor: same fixture helpers,
/// same targeting (`v`, `pillCenter` — geometry only, the gesture math is
/// what is under test), same transcript format.
@available(iOS 26, *)
@MainActor
final class EditorRig {
    struct Selection { var zoom: UUID? }

    let scenario: String
    let canvas: CGSize
    let template: Project
    let outDir: URL
    let media: EditorLabMedia
    var time: TimeInterval = 1.0
    var sel = Selection()
    var usesCamera = false
    var usesWatermark = false
    var stageZoom: CGFloat = 1
    private(set) var editor: EditorViewController!
    private var names: [UUID: String] = [:]
    private var events: [String] = []
    /// The transcript (the Mac rig's `out`).
    private(set) var transcript: [String] = []
    private var lastState: [(String, String)] = []
    private var step = 0
    private(set) var gestureCount = 0
    private(set) var undoSteps = 0
    var failures: [String] = []
    private var openingProject = Data()
    private var projectDir: URL?

    init(scenario: String, canvas: CGSize, fixtureProject: Data, out: URL, media: EditorLabMedia) {
        self.scenario = scenario
        self.canvas = canvas
        self.outDir = out
        self.media = media
        template = (try? JSONDecoder().decode(Project.self, from: fixtureProject)) ?? Project(
            id: UUID(), name: "missing", duration: 12, recordingSourceKind: .display)
        template.previewCanvasSize = canvas
    }

    /// The live project (the editor's, once open; the template before).
    var project: Project { editor?.project ?? template }

    // MARK: Fixture helpers (the Mac rig's)

    func id(_ name: String, _ n: Int) -> UUID {
        let u = UUID(uuidString: String(format: "00000000-0000-4000-A000-%012d", n))!
        names[u] = name
        return u
    }

    func annotation(
        _ name: String, _ type: AnnotationType,
        _ x: Double, _ y: Double, _ ex: Double, _ ey: Double,
        id n: Int, text: String? = nil, strokes: [[(Double, Double)]] = []
    ) -> Annotation {
        var a = Annotation(id: id(name, n), type: type, startTime: 0, endTime: 10)
        a.x = x; a.y = y; a.arrowEndX = ex; a.arrowEndY = ey
        if let text { a.text = text }
        if !strokes.isEmpty { a.drawingStrokes = strokes.map { $0.map { CodablePoint(x: $0.0, y: $0.1) } } }
        return a
    }

    func ann(_ name: String) -> Annotation { project.annotations.first { names[$0.id] == name }! }

    // MARK: Lifecycle

    /// Writes the scenario as a project folder, opens it in a fresh editor
    /// presented full screen, waits for the first decoded frame, records the
    /// opening state (the Mac rig's `start()`).
    func start(host: UIViewController) async {
        let fm = FileManager.default
        let dir = outDir.appendingPathComponent("projects/\(scenario)\(stageZoom == 1 ? "" : "-x\(Int(stageZoom))")", isDirectory: true)
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.copyItem(at: media.video, to: dir.appendingPathComponent("video.mov"))
        // Absolute Mac-shaped references the folder must re-point.
        template.videoURL = URL(fileURLWithPath: "/Users/mac-user/Library/Application Support/CaptureCat/Projects/\(template.id.uuidString)/video.mov")
        if usesCamera {
            try? fm.copyItem(at: media.camera, to: dir.appendingPathComponent("camera.mov"))
            template.cameraVideoURL = URL(fileURLWithPath: "/Users/mac-user/Library/Application Support/CaptureCat/Projects/\(template.id.uuidString)/camera.mov")
        }
        if usesWatermark {
            try? fm.copyItem(at: media.watermark, to: dir.appendingPathComponent("wm.png"))
            template.settings.showWatermark = true
            template.settings.watermarkFileName = "wm.png"
        }
        do {
            // A key this build does not know (a newer app's) must survive saves.
            var document = try JSONSerialization.jsonObject(with: JSONEncoder().encode(template)) as? [String: Any] ?? [:]
            document["futureKey"] = ["kept": true]
            try JSONSerialization.data(withJSONObject: document)
                .write(to: dir.appendingPathComponent(StudioProjectFolder.documentName))
            projectDir = dir
            let folder = try StudioProjectFolder.open(dir)
            guard folder.project.videoURL?.deletingLastPathComponent().standardizedFileURL.path
                    == dir.standardizedFileURL.path else {
                failures.append("\(scenario): media not re-pointed into the folder (\(folder.project.videoURL?.path ?? "nil"))")
                return
            }
            let editor = EditorViewController(folder: folder, initialTime: time)
            editor.canvasOverride = canvas
            editor.eventNames = names
            editor.canvasEventLog = { [weak self] in self?.events.append($0) }
            editor.selection.selectedZoomID = sel.zoom
            editor.onClose = {}
            self.editor = editor
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                host.present(editor, animated: false) { c.resume() }
            }
        } catch {
            failures.append("\(scenario): open failed: \(error)")
            return
        }
        // Ready: the player delivered a frame (and the camera, when shown).
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let videoReady = editor.playback.isReady && editor.stage.core.displayedVideoFrame != nil
            let cameraReady = !usesCamera || editor.playback.cameraPosterImage != nil
            if videoReady && cameraReady { break }
            await LabTime.settle(0.05)
        }
        if editor.stage.core.displayedVideoFrame == nil { failures.append("\(scenario): no video frame delivered") }
        await LabTime.settle(0.3)
        if editor.stage.virtualCanvasSize != canvas {
            failures.append("\(scenario): canvas \(editor.stage.virtualCanvasSize) != \(canvas)")
        }
        if abs(editor.playback.currentTime - time) > 1e-9 {
            failures.append("\(scenario): opened at \(editor.playback.currentTime), want \(time)")
        }
        if stageZoom != 1 {
            editor.stageCard.setZoom(stageZoom, pan: .zero)
            await LabTime.settle(0.1)
            if editor.stage.magnification <= editor.stage.fitMagnification * 1.5 {
                failures.append("\(scenario): the stage is not magnified (×\(editor.stage.magnification / editor.stage.fitMagnification))")
            }
        }
        render()
        render()
        openingProject = encoded(project)
        transcript.append("== \(scenario) \(Int(canvas.width))x\(Int(canvas.height))")
        lastState = []
        transcript.append(contentsOf: diffState())
    }

    /// Unwinds the whole undo stack (must restore the opening project byte
    /// for byte), redoes it, then closes the editor.
    func close() async {
        guard let editor else { return }
        let final = encoded(project)
        let undo = editor.undoManager!
        await LabTime.settle(0.05)
        var names: [String] = []
        while undo.canUndo {
            names.append(undo.undoActionName)
            editor.performUndo()
            undoSteps += 1
        }
        if encoded(project) != openingProject {
            failures.append("\(scenario): undoing all \(undoSteps) steps did not restore the opening project")
        }
        var redone = 0
        while undo.canRedo { editor.performRedo(); redone += 1 }
        if redone == undoSteps, encoded(project) != final {
            failures.append("\(scenario): redoing all \(redone) steps did not restore the final project")
        } else if redone != undoSteps {
            // The core's Camera Height step registers no redo (Mac behaviour).
            print("   note: \(scenario) redo covered \(redone) of \(undoSteps) steps (core steps register no redo)")
        }
        print("   undo steps (latest first): \(names.joined(separator: " · "))")
        // Saving: the edited model merged onto the document.
        editor.saveNow()
        if let dir = projectDir, undoSteps > 0 {
            let url = dir.appendingPathComponent(StudioProjectFolder.documentName)
            let object = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let saved = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Project.self, from: $0) }
            if (object?["futureKey"] as? [String: Any])?["kept"] as? Bool != true {
                failures.append("\(scenario): the save dropped a key this build does not know")
            }
            if (object?["videoURL"] as? String) != template.videoURL?.absoluteString {
                failures.append("\(scenario): the save stamped this device's media path (\(object?["videoURL"] ?? "nil"))")
            }
            if let saved {
                saved.videoURL = project.videoURL
                saved.cameraVideoURL = project.cameraVideoURL
                if CanvasEditSnapshot(saved).encoded() != CanvasEditSnapshot(project).encoded() {
                    failures.append("\(scenario): the saved project.json does not hold the edits")
                }
            } else {
                failures.append("\(scenario): the saved project.json does not decode")
            }
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            editor.dismiss(animated: false) { c.resume() }
        }
        editor.playback.teardown()
    }

    private func encoded(_ project: Project) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(project)) ?? Data()
    }

    func render() { editor?.renderStage() }

    // MARK: Geometry (targeting only)

    var ctx: PreviewHitContext { editor.canvas.context! }

    func v(_ ux: Double, _ uy: Double) -> CGPoint {
        let c = ctx
        let content = CGPoint(x: c.contentRect.minX + c.videoRect.minX + ux * c.videoRect.width,
                              y: c.contentRect.minY + c.videoRect.minY + uy * c.videoRect.height)
        return forward(content)
    }

    private func forward(_ q: CGPoint) -> CGPoint {
        let c = ctx
        return CGPoint(x: c.zoomAnchor.x + c.cardOffset.x * c.canvas.width + c.zoom * (q.x - c.zoomAnchor.x),
                       y: c.zoomAnchor.y + c.cardOffset.y * c.canvas.height + c.zoom * (q.y - c.zoomAnchor.y))
    }

    func pillCenter(_ norm: CGRect) -> CGPoint {
        let c = ctx, vr = c.videoRect
        let r = CGRect(x: vr.minX + norm.minX * vr.width, y: vr.minY + norm.minY * vr.height,
                       width: max(30, norm.width * vr.width), height: max(20, norm.height * vr.height))
        let pillWidth = min(max(90, r.width - 60), 150) + 54
        let h = RegionHandleChrome.pillHeight, gap = RegionHandleChrome.pillGap
        let y = r.maxY + gap + h <= vr.maxY ? r.maxY + gap : r.maxY - gap - h
        let lower = vr.minX + pillWidth / 2, upper = vr.maxX - pillWidth / 2
        let cx = upper >= lower ? min(max(r.midX, lower), upper) : vr.midX
        return forward(CGPoint(x: c.contentRect.minX + cx, y: c.contentRect.minY + y + h / 2))
    }

    /// A canvas point → the touch surface's own coordinates: where a finger
    /// must land for the surface's own mapping (`touchDown` → canvas) to give
    /// EXACTLY that canvas point — the forward mapping, then nudged by single
    /// ulps until the surface's inverse returns the target (the Mac rig sends
    /// canvas points directly; this keeps the transcripts free of 1e-13
    /// mapping noise). When no exact preimage exists the nearest is used and
    /// counted (`inexactTouches`).
    private func touchPoint(_ canvasPoint: CGPoint) -> CGPoint {
        let surface = editor.canvas, stage = editor.stage
        func back(_ v: CGPoint) -> CGPoint { stage.canvasPoint(fromView: surface.convert(v, to: stage)) }
        var v = surface.convert(stage.viewPoint(fromCanvas: canvasPoint), from: stage)
        func solve(_ start: CGFloat, _ target: CGFloat, _ f: (CGFloat) -> CGFloat) -> CGFloat {
            var x = start
            for _ in 0..<32 {
                let y = f(x)
                if y == target { return x }
                x = y < target ? x.nextUp : x.nextDown
            }
            return start
        }
        v.x = solve(v.x, canvasPoint.x) { back(CGPoint(x: $0, y: v.y)).x }
        v.y = solve(v.y, canvasPoint.y) { back(CGPoint(x: v.x, y: $0)).y }
        if back(v) != canvasPoint { inexactTouches += 1 }
        return v
    }

    private(set) var inexactTouches = 0

    // MARK: Gestures (through the touch surface's entry points)

    func drag(_ label: String, from start: CGPoint, by deltas: [(Double, Double)]) async {
        await drag(label, from: start, to: deltas.map { CGPoint(x: start.x + $0.0, y: start.y + $0.1) })
    }

    func drag(_ label: String, from start: CGPoint, to points: [CGPoint]) async {
        guard editor != nil else { return }
        let surface = editor.canvas
        surface.touchDown(atView: touchPoint(start), tapCount: 1)
        render()
        for p in points {
            surface.touchMoved(toView: [touchPoint(p)])
            render()
        }
        let dragging = surface.isActivelyDragging
        surface.touchUp(atView: touchPoint(points.last ?? start))
        render()
        record(label, extra: "from \(fmt(start)) drag=\(dragging)")
        await between()
    }

    func click(_ label: String, at p: CGPoint, clickCount: Int = 1) async {
        guard editor != nil else { return }
        editor.canvas.touchDown(atView: touchPoint(p), tapCount: clickCount)
        render()
        editor.canvas.touchUp(atView: touchPoint(p))
        render()
        record(label, extra: "at \(fmt(p))" + (clickCount > 1 ? " x\(clickCount)" : ""))
        await between()
    }

    func escape(_ label: String) async {
        guard editor != nil else { return }
        editor.canvas.escape()
        render()
        record(label)
        await between()
    }

    func note(_ text: String) { transcript.append("   note: \(text)") }

    /// Real playback on (the Mac rig flips `isPlaying` on a fixed frame; here
    /// the player really runs — nothing the transcript prints moves with it).
    func setPlaying(_ playing: Bool) async {
        editor.playback.setPlaying(playing, for: project)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if !playing || editor.playback.player?.timeControlStatus == .playing { break }
            await LabTime.settle(0.02)
        }
        render()
    }

    /// Lets the run loop turn: each gesture's undo step closes as its own
    /// group (as each real touch is its own event), queued renders flush.
    private func between() async { await LabTime.settle(0.03) }

    // MARK: Transcript (the Mac rig's format)

    private func record(_ label: String, extra: String = "") {
        step += 1
        gestureCount += 1
        transcript.append(String(format: "%@.%02d %@", scenario, step, label) + (extra.isEmpty ? "" : "  (\(extra))"))
        transcript.append("   events: " + (events.isEmpty ? "-" : events.joined(separator: ", ")))
        events.removeAll()
        transcript.append(contentsOf: diffState())
    }

    private func diffState() -> [String] {
        let now = state()
        let before = Dictionary(lastState, uniquingKeysWith: { a, _ in a })
        lastState = now
        return now.compactMap { key, value in before[key] == value ? nil : "   \(key): \(value)" }
    }

    private func state() -> [(String, String)] {
        var s: [(String, String)] = []
        let c = ctx
        s.append(("ctx", "content=\(fmt(c.contentRect)) video=\(fmt(c.videoRect)) zoom=\(f(c.zoom)) "
                  + "anchor=\(fmt(c.zoomAnchor)) off=\(fmt(c.cardOffset))"))
        s.append(("chrome", "cam=\(fmt(c.cameraRect)) sub=\(fmt(c.subtitleRect)) wm=\(fmt(c.watermarkRect)) "
                  + "stack=\(c.stack.map { "\(fmt($0.cameraRow)) seam=\(f($0.seamY))" } ?? "nil")"))
        for a in project.annotations {
            var line = "\(fmt(CGPoint(x: a.x, y: a.y)))→\(fmt(CGPoint(x: a.arrowEndX, y: a.arrowEndY)))"
            if a.type == .drawing {
                let last = a.drawingStrokes.last?.last.map { fmt(CGPoint(x: $0.x, y: $0.y)) } ?? "-"
                line += " strokes=\(a.drawingStrokes.count) points=\(a.drawingStrokes.map(\.count)) last=\(last)"
            }
            if a.type == .text || a.type == .callout { line += " text=\"\(a.text)\"" }
            s.append(("ann.\(name(a.id))", line))
        }
        for r in project.blurRegions { s.append(("blur.\(name(r.id))", "\(fmt(r.rect)) intensity=\(f(r.intensity))")) }
        for r in project.highlightRegions { s.append(("hl.\(name(r.id))", "\(fmt(r.rect)) opacity=\(f(r.opacity))")) }
        for r in project.focusRegions { s.append(("focus.\(name(r.id))", "\(fmt(r.rect)) intensity=\(f(r.intensity))")) }
        for z in project.zoomRegions {
            s.append(("zoom.\(name(z.id))", "focal=\(fmt(z.focalPoint)) off=\(opt(z.cardOffsetX)),\(opt(z.cardOffsetY))"))
        }
        let st = project.settings
        s.append(("settings", "cam=\(st.cameraPosition.rawValue) custom=\(pair(st.cameraCustomX, st.cameraCustomY)) "
                  + "wm=\(f(st.watermarkX)),\(f(st.watermarkY)) "
                  + "sub=\(st.subtitlePosition.rawValue) custom=\(pair(st.subtitleCustomX, st.subtitleCustomY)) "
                  + "card=\(st.videoPlacement.rawValue) custom=\(pair(st.videoCustomX, st.videoCustomY)) "
                  + "stack=\(opt(st.cameraStackRatio))"))
        let sel = editor.selection
        s.append(("selection", "ann=\(name(sel.selectedAnnotationID)) hl=\(name(sel.selectedHighlightID)) "
                  + "blur=\(name(sel.selectedBlurID)) depth=\(name(sel.selectedDepthFocusID)) zoom=\(name(sel.selectedZoomID))"))
        s.append(("ui", "editing=\(name(editor.canvas.inlineEditingID)) dragging=\(editor.canvas.isActivelyDragging) "
                  + "toolbarAnchor=\(fmt(PreviewHitMath.selectedAnnotationViewRect(c))) "
                  + "undo=\(editor.undoManager?.undoActionName ?? "-")"))
        return s
    }

    private func name(_ id: UUID?) -> String {
        guard let id else { return "nil" }
        return names[id] ?? "?"
    }

    private func f(_ v: Double) -> String { String(format: "%.6f", v) }
    private func f(_ v: CGFloat) -> String { String(format: "%.6f", Double(v)) }
    private func opt(_ v: Double?) -> String { v.map { f($0) } ?? "nil" }
    private func pair(_ x: Double?, _ y: Double?) -> String { x == nil && y == nil ? "nil" : "\(opt(x)),\(opt(y))" }
    func fmt(_ p: CGPoint) -> String { "(\(f(p.x)),\(f(p.y)))" }
    func fmt(_ r: CGRect?) -> String {
        guard let r else { return "nil" }
        return "[\(f(r.minX)),\(f(r.minY)) \(f(r.width))x\(f(r.height))]"
    }
}
