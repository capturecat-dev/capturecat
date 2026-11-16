import AVFoundation
import UIKit

/// `--features <outDir> --reference <macFeaturesDir> [--whisper-models <dir>]
///  [--only autozoom,voiceover,transcription,cutout] [--inject <defect>]`
///
/// The iOS half of the Studio 4e features gate (StudioHarness/FeaturesHarness;
/// `apps/ios/scripts/ios-features.sh`). Each feature runs through its
/// SHIPPING flow (StudioUI/Features) in this real window — the sheet
/// presented, its controls fired as touches (`.touchUpInside`) — and the
/// result is scored against the Mac's (`CaptureCat --features-reference`):
///
///   autozoom       blocks identical (default level and the slider's), undo
///                  restores, inert for a take without Mac capture data
///   voiceover      the synthetic take's entry and meter identical, the
///                  export mix within 1e-6; the sheet's level meter caught
///                  MID-FLIGHT while recording; undo / redo
///   transcription  structure identical, timing within 0.1 s, text diffs
///                  logged; the sheet's progress caught mid-flight
///   cutout         conditioning + encoder byte-identical, Vision's matte vs
///                  the Mac's, the job's progress caught mid-flight, and the
///                  cutout's preview / export frames within the parity bars
///
/// `--inject <defect>` (FeaturesHarness.Inject) must turn the gate red.
@MainActor
enum FeaturesLab {
    static func start(_ arguments: [String], lab: LabViewController) -> Bool {
        guard let i = arguments.firstIndex(of: "--features"), arguments.indices.contains(i + 1) else { return false }
        func value(_ name: String) -> String? {
            arguments.firstIndex(of: name).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        let out = URL(fileURLWithPath: arguments[i + 1], isDirectory: true)
        guard let reference = value("--reference").map({ URL(fileURLWithPath: $0, isDirectory: true) }) else {
            print("FEATURES-GATE FAIL usage: --features <out> --reference <macDir>")
            exit(2)
        }
        FeaturesHarness.inject = value("--inject").flatMap(FeaturesHarness.Inject.init(rawValue:))
        let only = value("--only").map { Set($0.split(separator: ",").map(String.init)) }
        let models = value("--whisper-models").map { URL(fileURLWithPath: $0, isDirectory: true) }
        lab.stage.isHidden = true
        Task { @MainActor in
            let pass = await run(lab: lab, out: out, reference: reference, models: models, only: only)
            exit(pass ? 0 : 1)
        }
        return true
    }

    static func run(lab: LabViewController, out: URL, reference: URL, models: URL?, only: Set<String>?) async -> Bool {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        print("FEATURES ios out=\(out.path) reference=\(reference.path)"
              + (FeaturesHarness.inject.map { " inject=\($0.rawValue)" } ?? ""))
        func wants(_ part: String) -> Bool { only?.contains(part) ?? true }
        var reports: [FeaturesHarness.Report] = []
        let log: (String) -> Void = { print($0) }
        if wants("autozoom") { reports.append(await autoZoom(lab, reference.appendingPathComponent("autozoom"), log: log)) }
        if wants("voiceover") {
            reports.append(await voiceOver(lab, reference.appendingPathComponent("voiceover"),
                                           out: out.appendingPathComponent("voiceover", isDirectory: true), log: log))
        }
        if wants("transcription") {
            reports.append(await transcription(lab, reference.appendingPathComponent("transcription"),
                                               models: models, log: log))
        }
        if wants("cutout") {
            reports.append(await cutout(lab, reference.appendingPathComponent("cutout"),
                                        out: out.appendingPathComponent("cutout", isDirectory: true), log: log))
        }
        let passed = reports.filter(\.pass).count
        for r in reports { print("FEATURE-SUMMARY \(r.feature) \(r.pass ? "PASS" : "FAIL") \(r.checks - r.failures)/\(r.checks)") }
        let pass = !reports.isEmpty && passed == reports.count
        print("FEATURES-GATE \(pass ? "PASS" : "FAIL") \(passed)/\(reports.count) features")
        return pass
    }

    // MARK: - Driving the sheets

    /// The house button with `title` inside the presented sheet.
    static func button(_ title: String, in alert: CCAlert?) -> CCButton? {
        alert?.probeButtons.first { $0.title == title }
    }

    /// MID-FLIGHT: the value drawn now is none of the values the control was
    /// ever told to show (nor where it started). A snapped animation — or a
    /// sample taken before a new value's frame committed — only ever draws
    /// one of those, so it can never count.
    static func isMidFlight(_ drawn: CGFloat, shown: [CGFloat], tolerance: CGFloat = 0.75) -> Bool {
        !shown.isEmpty && shown.allSatisfy { abs(drawn - $0) > tolerance }
    }

    static func tap(_ control: UIControl?) {
        control?.sendActions(for: .touchUpInside)
    }

    static func dismissSheets(_ lab: UIViewController) async {
        while let presented = lab.presentedViewController {
            presented.dismiss(animated: false)
            await LabTime.settle(0.2)
        }
    }

    // MARK: - Auto Zoom

    static func autoZoom(_ lab: LabViewController, _ ref: URL, log: @escaping (String) -> Void) async -> FeaturesHarness.Report {
        typealias F = FeaturesHarness.AutoZoomFixture
        let report = FeaturesHarness.Report("autozoom", log: log)
        guard let mac = FeaturesHarness.read(ref.appendingPathComponent("mac-autozoom.json")) as? [String: [String: Any]] else {
            report.check("Mac reference present", false, ref.path)
            return report
        }
        for (label, level) in [("default", nil), ("slider", F.sliderLevel)] as [(String, Double?)] {
            let project = F.project(in: ref)
            let undo = UndoManager()
            let controller = StudioAutoZoom.present(from: lab, project: project, undoManager: undo)
            await LabTime.settle(0.6)
            report.check("[\(label)] sheet offers Generate", controller.availability == .available
                         && button("Generate", in: controller.alert) != nil)
            if let level {
                // The slider's own callback, as a drag that lands on 2.6× would fire it.
                controller.levelSlider.setValue(level, animated: false)
                controller.levelSlider.onChange?(controller.levelSlider.value)
                report.check("[\(label)] slider sets the project's level", abs(project.settings.autoZoomLevel - level) < 1e-9,
                             String(format: "%.2f", project.settings.autoZoomLevel))
            }
            tap(button("Generate", in: controller.alert))
            await LabTime.settle(0.8)
            if FeaturesHarness.injected(.autoZoomShift) {
                for i in project.zoomRegions.indices where project.zoomRegions[i].isAuto == true {
                    project.zoomRegions[i].startTime += 1.0 / 30
                }
            }
            let lines = F.blockLines(project.zoomRegions)
            let macLines = mac[label]?["blocks"] as? [String] ?? []
            report.check("[\(label)] blocks identical to the Mac", lines == macLines && !lines.isEmpty,
                         "\(controller.lastCreated) auto block(s), \(lines.count) total vs Mac \(macLines.count)")
            if lines != macLines {
                for (a, b) in zip(macLines, lines) where a != b { report.note("Mac \(a)\n      iOS \(b)") }
            }
            report.check("[\(label)] sheet closed after Generate", lab.presentedViewController == nil)
            undo.undo()
            report.check("[\(label)] undo restores the blocks before Auto Zoom",
                         F.blockLines(project.zoomRegions) == F.blockLines(F.project(in: ref).zoomRegions))
            await dismissSheets(lab)
        }
        // Inert without Mac capture data: an iPhone take and a take whose cursor file is gone.
        for (label, mutate) in [("iPhone take", { (p: Project) in p.recordingSourceKind = .device }),
                                ("no cursor.json", { (p: Project) in p.cursorDataURL = nil })] {
            let project = F.project(in: ref)
            mutate(project)
            let before = F.blockLines(project.zoomRegions)
            let controller = StudioAutoZoom.present(from: lab, project: project, undoManager: UndoManager())
            await LabTime.settle(0.5)
            try? controller.generate()
            report.check("inert for \(label)", controller.availability == .needsMacCapture
                         && button("Generate", in: controller.alert) == nil && button("OK", in: controller.alert) != nil
                         && F.blockLines(project.zoomRegions) == before)
            await dismissSheets(lab)
        }
        return report
    }

    // MARK: - Voice-over

    static func voiceOver(_ lab: LabViewController, _ ref: URL, out: URL, log: @escaping (String) -> Void) async -> FeaturesHarness.Report {
        typealias F = FeaturesHarness.VoiceFixture
        let report = FeaturesHarness.Report("voiceover", log: log)
        let fm = FileManager.default
        try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        guard let mac = FeaturesHarness.read(ref.appendingPathComponent("mac-voiceover.json")) as? [String: Any],
              let macEntry = mac["entry"] as? String,
              let macMeter = mac["meter"] as? [Double],
              let macMix = FeaturesHarness.readFloats(ref.appendingPathComponent("mac-mix.f32")) else {
            report.check("Mac reference present", false, ref.path)
            return report
        }
        let recording = ref.appendingPathComponent(F.recording)
        defer { try? fm.removeItem(at: Project.directory(for: F.projectID)) }

        // 1. The scripted take through the shared engine.
        let project = F.project(recording: recording)
        do {
            let (clip, meter) = try await FeaturesHarness.scriptedTake(project: project)
            guard var clip else {
                report.check("the take made a clip", false)
                return report
            }
            if FeaturesHarness.injected(.voiceOffset), let i = project.voiceOverClips.firstIndex(where: { $0.id == clip.id }) {
                project.voiceOverClips[i].startTime += 0.05
                clip = project.voiceOverClips[i]
            }
            report.check("voice-track entry identical to the Mac", F.entry(clip) == macEntry, "iOS \(F.entry(clip))")
            report.check("file named and placed like the Mac's", clip.fileName.hasPrefix("voiceover-")
                         && clip.fileName.hasSuffix(".m4a")
                         && fm.fileExists(atPath: clip.resolvedURL(in: project.projectDirectory).path))
            let meterDelta = zip(meter, macMeter).map { abs(Double($0) - $1) }.max() ?? .infinity
            report.check("meter levels identical (≤ 1e-6)", meter.count == macMeter.count && meterDelta <= 1e-6,
                         String(format: "%d reads, max |Δ| %.2e, mid-take level %.3f", meter.count, meterDelta,
                                meter.dropFirst(meter.count / 2).first ?? 0))
            let voice = clip.resolvedURL(in: project.projectDirectory)
            try? fm.removeItem(at: out.appendingPathComponent("ios-voice.m4a"))
            try? fm.copyItem(at: voice, to: out.appendingPathComponent("ios-voice.m4a"))
            if let decoded = FeaturesHarness.decodeVoice(voice),
               let macDecoded = FeaturesHarness.readFloats(ref.appendingPathComponent("mac-voice.f32")) {
                let c = FeaturesHarness.compareSamples(decoded, macDecoded)
                report.note(String(format: "voice file decoded vs the Mac's: %d frames (Mac %d), max |Δ| %.2e",
                                   decoded.count, macDecoded.count, c.maxDelta))
            }
            if FeaturesHarness.injected(.mixGain), let i = project.voiceOverClips.firstIndex(where: { $0.id == clip.id }) {
                project.voiceOverClips[i].gain = 0.9
            }
            let mix = try await FeaturesHarness.readMix(project: project)
            FeaturesHarness.writeFloats(mix, to: out.appendingPathComponent("ios-mix.f32"))
            let c = FeaturesHarness.compareSamples(mix, macMix)
            report.check("export mix matches the Mac (≤ \(F.mixTolerance))", c.sameLength && c.maxDelta <= F.mixTolerance,
                         String(format: "%d samples (Mac %d), max |Δ| %.2e", mix.count, macMix.count, c.maxDelta))
            // Equal-input cross-check: the Mac's own take mixed by iOS.
            let cross = F.project(recording: recording)
            var macClip = clip
            macClip.fileName = "mac-voice.m4a"
            macClip.gain = 1
            macClip.startTime = F.takeStart
            try? fm.removeItem(at: cross.projectDirectory.appendingPathComponent("mac-voice.m4a"))
            try? fm.copyItem(at: ref.appendingPathComponent("mac-voice.m4a"),
                             to: cross.projectDirectory.appendingPathComponent("mac-voice.m4a"))
            cross.voiceOverClips = [macClip]
            let crossMix = try await FeaturesHarness.readMix(project: cross)
            let cc = FeaturesHarness.compareSamples(crossMix, macMix)
            report.note(String(format: "the Mac's take mixed on iOS vs the Mac's mix: max |Δ| %.2e", cc.maxDelta))
        } catch {
            report.check("scripted take", false, "\(error)")
        }

        // 2. The sheet: Record, the live meter (mid-flight), Stop, undo / redo.
        let uiProject = F.project(recording: recording)
        let playhead = StudioTimelinePlayhead()
        playhead.currentTime = F.takeStart
        let undo = UndoManager()
        let clock = FeaturesHarness.SyntheticVoiceCapture.Clock()
        _ = FeaturesHarness.installSyntheticVoice(on: StudioVoiceOver.session, clock: clock)
        defer {
            VoiceOverRecorder.makeCapture = VoiceOverMic.makeRecorder
            StudioVoiceOver.session.requestPermission = VoiceOverSession.ensureMicrophonePermission
            CCMotion.probeSnap = false
        }
        let controller = StudioVoiceOver.present(from: lab, project: uiProject, undoManager: undo, transport: playhead)
        await LabTime.settle(0.6)
        if FeaturesHarness.injected(.progressSnap) { CCMotion.probeSnap = true }
        tap(controller.recordButton)
        var samples: [(drawn: CGFloat, count: Int, time: String)] = []
        var midFlight = 0
        let end = Date().addingTimeInterval(1.4)
        while Date() < end {
            try? await Task.sleep(for: .milliseconds(12))
            let bar = controller.meter.probeNewestBar
            samples.append((bar?.drawn ?? 0, controller.meter.probeShownCount, controller.timeLabel.text ?? ""))
            // The newest bar springs from 2 pt to each new level; a snapped
            // one only ever draws 2 pt or one of its last few targets.
            let shown = controller.meter.probeHeightsShown
            if let drawn = bar?.drawn, shown.count > 1,
               isMidFlight(drawn, shown: [2] + Array(shown.suffix(3))) { midFlight += 1 }
        }
        CCMotion.probeSnap = false
        report.check("recording started from the sheet", StudioVoiceOver.session.isRecording && playhead.isPlaying
                     && controller.recordButton.title == "Stop")
        let counts = Set(samples.map(\.count)), times = Set(samples.map(\.time))
        report.check("level meter SEQUENCE advances", counts.count >= 8 && times.count >= 4,
                     "\(samples.count) samples, \(counts.count) bar counts, \(times.count) time readouts")
        report.check("newest level bar caught mid-flight", midFlight >= 1, "\(midFlight) mid-flight samples")
        tap(controller.recordButton)
        let stopDeadline = Date().addingTimeInterval(5)
        while controller.addedClips.isEmpty && Date() < stopDeadline { await LabTime.settle(0.1) }
        let uiClip = controller.addedClips.first
        report.check("Stop lands the take on the voice track like the Mac's",
                     uiClip.map { F.entry($0) == macEntry } ?? false && uiProject.voiceOverClips.count == 1
                     && !StudioVoiceOver.session.isRecording && !playhead.isPlaying,
                     uiClip.map { F.entry($0) } ?? "no clip")
        undo.undo()
        let undone = uiProject.voiceOverClips.isEmpty
        undo.redo()
        report.check("undo removes the take, redo restores it", undone && uiProject.voiceOverClips.first?.id == uiClip?.id
                     && undo.undoActionName == "Record Voice Over")
        await dismissSheets(lab)
        return report
    }

    // MARK: - Transcription

    static func transcription(_ lab: LabViewController, _ ref: URL, models: URL?, log: @escaping (String) -> Void) async -> FeaturesHarness.Report {
        typealias F = FeaturesHarness.SpeechFixture
        let report = FeaturesHarness.Report("transcription", log: log)
        guard let models,
              let data = try? Data(contentsOf: ref.appendingPathComponent("mac-transcript.json")),
              let macTranscript = try? JSONDecoder().decode([FeaturesHarness.TranscriptSegment].self, from: data),
              let mac = FeaturesHarness.read(ref.appendingPathComponent("mac-transcription.json")) as? [String: Any] else {
            report.check("Mac reference and model present", false, "\(ref.path), models \(models?.path ?? "–")")
            return report
        }
        StudioTranscription.probeModelFolder = models.appendingPathComponent(F.modelFolderName, isDirectory: true)
        let movie = ref.appendingPathComponent(F.movie)
        let script = (try? String(contentsOf: ref.appendingPathComponent(F.script), encoding: .utf8)) ?? ""
        let service = StudioTranscription.service

        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("features-\(UUID().uuidString).wav")
        do {
            try await service.extractAudio(from: movie, to: wav)
            let sha = FeaturesHarness.sha256(try Data(contentsOf: wav))
            let macSHA = mac["wavSHA256"] as? String ?? ""
            report.note("engine input (16 kHz WAV) \(sha == macSHA ? "byte-identical to" : "DIFFERS from") the Mac's (\(sha.prefix(12)) vs \(macSHA.prefix(12)))")
        } catch {
            report.check("audio extraction", false, "\(error)")
        }
        try? FileManager.default.removeItem(at: wav)

        let project = Project(name: "features-transcription", videoURL: movie, duration: 60)
        let undo = UndoManager()
        let controller = StudioTranscription.present(from: lab, project: project, undoManager: undo)
        await LabTime.settle(0.6)
        if FeaturesHarness.injected(.progressSnap) { CCMotion.probeSnap = true }
        defer { CCMotion.probeSnap = false }
        tap(button("Generate", in: controller.alert))
        var stages: [String] = []
        var midFlight = 0, fractions = Set<Int>()
        var barWidth: CGFloat = -1
        let started = Date()
        while controller.lastSegments == nil && Date().timeIntervalSince(started) < 600 {
            try? await Task.sleep(for: .milliseconds(15))
            let stage = service.progress
            if stages.last != stage { stages.append(stage) }
            if service.isTranscribing { fractions.insert(Int(service.fraction * 100)) }
            // Only while the bar's own width holds still (a sheet still
            // laying out moves the fill without any animation).
            let width = controller.status.bar.bounds.width
            defer { barWidth = width }
            if service.isTranscribing, !controller.status.bar.isIndeterminate, width > 0, width == barWidth,
               isMidFlight(controller.status.probeDrawnWidth, shown: controller.status.probeTargetWidths) { midFlight += 1 }
            if controller.alert.map({ !$0.probeButtons.isEmpty }) == false { break }
        }
        CCMotion.probeSnap = false
        let seconds = Date().timeIntervalSince(started)
        let expected = ["Loading model...", "Extracting audio...", "Transcribing..."]
        let order = expected.compactMap { stages.firstIndex(of: $0) }
        report.check("progress stages shown in order", order.count == expected.count && order == order.sorted(),
                     stages.joined(separator: " → "))
        report.check("progress bar caught mid-flight while transcribing", midFlight >= 1 && fractions.count >= 3,
                     "\(midFlight) mid-flight samples, \(fractions.count) distinct fractions")
        guard var segments = controller.lastSegments else {
            report.check("transcription finished", false, service.error ?? "no result in \(Int(seconds)) s")
            await dismissSheets(lab)
            return report
        }
        report.note(String(format: "iOS took %.1f s (Mac %.1f s)", seconds, mac["seconds"] as? Double ?? 0))
        report.check("subtitles installed in the project", project.subtitles.count == segments.count && !segments.isEmpty)
        if FeaturesHarness.injected(.transcriptTiming) {
            segments = segments.map { s in
                var s = s
                s.startTime += 0.12; s.endTime += 0.12
                s.words = s.words.map { w in var w = w; w.startTime += 0.12; w.endTime += 0.12; return w }
                return s
            }
        }
        FeaturesHarness.compareTranscripts(
            mac: macTranscript, ios: FeaturesHarness.transcript(segments), script: script,
            engineNote: "the same WhisperKit model and options, run by CoreML on different compute units (the Mac's Neural Engine / GPU vs the Simulator's CPU), so float16 vs float32 arithmetic can tip a token",
            report: report)
        undo.undo()
        report.check("undo restores the subtitles from before", project.subtitles.isEmpty
                     && undo.redoActionName == "Generate Subtitles")
        await dismissSheets(lab)
        return report
    }

    // MARK: - Background removal

    final class CutoutStage: PreviewExportStage {
        let view: PreviewStageView
        init(view: PreviewStageView) { self.view = view }
        func render(_ input: PreviewCompositorCore.FrameInput) { view.schedule(input) }
        func capture() async -> CGImage? { LabCapture.view(view, scale: FeaturesHarness.CutoutFixture.scale) }
        var core: PreviewCompositorCore { view.core }
    }

    static func cutout(_ lab: LabViewController, _ ref: URL, out: URL, log: @escaping (String) -> Void) async -> FeaturesHarness.Report {
        typealias F = FeaturesHarness.CutoutFixture
        let report = FeaturesHarness.Report("cutout", log: log)
        let fm = FileManager.default
        guard let mac = FeaturesHarness.read(ref.appendingPathComponent("mac-cutout.json")) as? [String: Any],
              let macMaskData = try? Data(contentsOf: ref.appendingPathComponent("mac-mask.ccmask")),
              let macMask = try? CameraMaskTrack(data: macMaskData),
              let rendersData = try? Data(contentsOf: ref.appendingPathComponent("mac-renders.json")),
              let macRenders = try? JSONDecoder().decode([FeaturesHarness.RenderResult].self, from: rendersData) else {
            report.check("Mac reference present", false, ref.path)
            return report
        }

        // 1. Producer arithmetic.
        let sha = (try? FeaturesHarness.conditionedSyntheticTrack()).map(FeaturesHarness.sha256) ?? "–"
        report.check("conditioning + encoder bytes identical to the Mac", sha == mac["conditioningSHA256"] as? String,
                     "\(sha.prefix(16))")

        // 2. The sheet runs the real job on a copy of the camera (the mask lands beside it).
        try? fm.removeItem(at: out)
        try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        let camera = out.appendingPathComponent(F.camera), screen = out.appendingPathComponent(F.screen)
        do {
            try fm.copyItem(at: ref.appendingPathComponent(F.camera), to: camera)
            try fm.copyItem(at: ref.appendingPathComponent(F.screen), to: screen)
        } catch {
            report.check("fixture copied", false, "\(error)")
            return report
        }
        let cameraDuration = mac["cameraDuration"] as? Double ?? 1.5
        // Vision's person segmentation has no runtime in the iOS Simulator
        // ("E5RT is not supported"; CPU-only: no inference context). There
        // the job runs the real pipeline with ONLY the Vision call replaced
        // by the Mac's matte (FeaturesHarness.replayMatte) — so the iOS
        // .ccmask must be the Mac's, byte for byte. On a device, real Vision.
        let (visionOK, visionReason) = await FeaturesHarness.visionSegmentationAvailable(camera: camera)
        let replaying = !visionOK
        if replaying {
            report.note("Vision person segmentation unavailable here (\(visionReason)) — the job runs with the Mac's matte replayed in place of Vision; Vision itself is compared on a device")
            StudioBackgroundRemoval.segmentation.matteSource = FeaturesHarness.replayMatte(macMask, delay: 0.03)
        }
        defer { StudioBackgroundRemoval.segmentation.matteSource = nil }
        let project = F.project(screen: screen, camera: camera, cameraDuration: cameraDuration, look: nil)
        let undo = UndoManager()
        let controller = StudioBackgroundRemoval.present(from: lab, project: project, undoManager: undo)
        await LabTime.settle(0.6)
        if FeaturesHarness.injected(.progressSnap) { CCMotion.probeSnap = true }
        let cutoutChip = controller.chips.allSubviews(of: CCChip.self).first { $0.accessibilityLabel == "Cutout" || $0.title == "Cutout" }
        tap(cutoutChip)
        var running = Set<Int>(), midFlight = 0
        var barWidth: CGFloat = -1
        let started = Date()
        var finalStatus = StudioBackgroundRemoval.segmentation.status(for: project)
        while Date().timeIntervalSince(started) < 120 {
            try? await Task.sleep(for: .milliseconds(10))
            finalStatus = StudioBackgroundRemoval.segmentation.status(for: project)
            if case .running(let p) = finalStatus, p > 0, p < 1 { running.insert(Int(p * 100)) }
            let row = controller.status
            let width = row.bar.bounds.width
            defer { barWidth = width }
            if case .running = finalStatus, !row.bar.isIndeterminate, width > 0, width == barWidth,
               isMidFlight(row.probeDrawnWidth, shown: row.probeTargetWidths) {
                midFlight += 1
                if midFlight <= 4 {
                    report.note(String(format: "mid-flight sample: drawn %.2f of %.1f; last targets %@", row.probeDrawnWidth,
                                       row.bar.bounds.width, row.probeTargetWidths.suffix(3).map { String(format: "%.2f", $0) }.joined(separator: ", ")))
                }
            }
            if finalStatus == .ready { break }
            if case .failed = finalStatus { break }
        }
        CCMotion.probeSnap = false
        let seconds = Date().timeIntervalSince(started)
        report.check("Cutout chip applies the look (one undo step)", project.settings.cameraLook == .cutout
                     && undo.undoActionName == "Background: Cutout")
        report.check("job ran to a fresh mask", finalStatus == .ready,
                     "\(finalStatus) after \(String(format: "%.1f", seconds)) s · sheet showed \(controller.statusLog.count) states")
        report.check("progress SEQUENCE: running percentages advance", running.count >= 3, "\(running.sorted().prefix(12)) …")
        report.check("progress bar caught mid-flight", midFlight >= 1, "\(midFlight) mid-flight samples")
        report.check("sheet shows the Mac's status line", controller.status.label.text == CameraSegmentation.Status.ready.displayText,
                     controller.status.label.text ?? "–")
        await dismissSheets(lab)

        // The iOS matte against the Mac's.
        let maskURL = CameraMaskTrack.url(besideCamera: camera)
        if var iosData = try? Data(contentsOf: maskURL), let iosMask = try? CameraMaskTrack(data: iosData) {
            try? iosData.write(to: out.appendingPathComponent("ios-mask.ccmask"))
            var compared = iosMask
            if FeaturesHarness.injected(.maskAlpha), let damaged = try? FeaturesHarness.damagedMask(iosMask),
               let track = try? CameraMaskTrack(data: damaged) {
                iosData = damaged
                compared = track
            }
            let c = FeaturesHarness.compareMasks(macMask, compared)
            report.check("mask header + frame times identical", c.headerEqual, c.headerDetail)
            if replaying {
                report.check("iOS pipeline re-encodes the Mac's matte byte for byte", iosData == macMaskData
                             && (mac["replayIdentical"] as? Bool) == true,
                             "\(iosData.count) B vs Mac \(macMaskData.count) B · Mac control \(mac["replayIdentical"] as? Bool ?? false)")
            } else {
                report.check("matte covers the same person (IoU mean ≥ \(F.minMeanIoU), min ≥ \(F.minFrameIoU), mean |Δ| ≤ \(F.maxMeanAlphaDelta)/255)",
                             c.meanIoU >= F.minMeanIoU && c.minIoU >= F.minFrameIoU && c.meanAlphaDelta <= F.maxMeanAlphaDelta,
                             String(format: "IoU mean %.4f min %.4f · mean |Δ| %.2f/255 · coverage Mac %.3f iOS %.3f",
                                    c.meanIoU, c.minIoU, c.meanAlphaDelta, c.coverage.a, c.coverage.b))
            }
        } else {
            report.check("iOS mask written beside the camera", false, maskURL.path)
        }

        // 3. Rendering with the Mac's mask (equal inputs).
        try? fm.removeItem(at: maskURL)
        try? macMaskData.write(to: maskURL)
        guard let posters = await FeaturesHarness.cutoutPosters(screen: screen, camera: camera) else {
            report.check("posters decoded", false)
            return report
        }
        let stageView = PreviewStageView(frame: CGRect(origin: CGPoint(x: 0, y: 80), size: F.canvas))
        stageView.virtualCanvasSize = F.canvas
        stageView.rasterScaleOverride = F.scale
        lab.view.addSubview(stageView)
        defer { stageView.removeFromSuperview() }
        await LabTime.settle(0.3)
        let stage = CutoutStage(view: stageView)
        let renders = out.appendingPathComponent("ios", isDirectory: true)
        try? fm.createDirectory(at: renders, withIntermediateDirectories: true)
        var results: [FeaturesHarness.RenderResult] = []
        var images: [String: (preview: CGImage, export: CGImage)] = [:]
        for (name, look) in F.looks {
            let p = F.project(screen: screen, camera: camera, cameraDuration: cameraDuration, look: look)
            let mask: CameraMaskTrack? = FeaturesHarness.injected(.maskIgnored) ? nil : macMask
            let (result, preview, export) = await FeaturesHarness.renderCutout(
                name: name, project: p, mask: mask, stage: stage, screenPoster: posters.screen,
                cameraPoster: posters.camera, cameraAspect: posters.aspect, out: renders)
            if let preview, let export { images[name] = (preview, export) }
            results.append(result)
        }
        FeaturesHarness.scoreCameraBoxes(&results, images: images)
        for r in results {
            guard let m = macRenders.first(where: { $0.name == r.name }) else {
                report.check("[\(r.name)] Mac render present", false); continue
            }
            if let error = r.error { report.check("[\(r.name)] rendered", false, error); continue }
            let whole = r.mean <= m.mean + PreviewExportParityHarness.meanSlack
                && r.over8 <= m.over8 + PreviewExportParityHarness.over8Slack
            report.check("[\(r.name)] preview ↔ export no worse than the Mac (3c bar)", whole,
                         String(format: "iOS mean %.3f over8 %.3f%% · Mac mean %.3f over8 %.3f%%",
                                r.mean, r.over8 * 100, m.mean, m.over8 * 100))
            if let rc = r.cameraMean, let mc = m.cameraMean {
                report.check("[\(r.name)] camera box preview ↔ export no worse than the Mac",
                             rc <= mc + PreviewExportParityHarness.meanSlack,
                             String(format: "iOS %.3f · Mac %.3f /255", rc, mc))
            }
            if let re = r.lookEffect, let me = m.lookEffect {
                report.check("[\(r.name)] the look is drawn (camera box vs bubble)", re >= 0.5 * me,
                             String(format: "iOS %.1f · Mac %.1f /255", re, me))
            }
            if let ours = images[r.name]?.export,
               let theirs = FeaturesHarness.loadPNG(ref.appendingPathComponent("mac/\(r.name)-export.png")),
               let a = HarnessPixels.rgba(ours), let b = HarnessPixels.rgba(theirs) {
                let s = ExportParityHarness.compare(a, b, index: F.frameIndex)
                a.deallocate(); b.deallocate()
                report.check("[\(r.name)] iOS export = Mac export (3a bar)", s.pass,
                             String(format: "mean %.3f/255, over8 %.4f%%, max %d", s.mean, s.over8 * 100, s.maxDelta))
            }
        }
        undo.undo()
        report.check("undo restores the background", project.settings.cameraLook == nil)
        return report
    }
}

extension UIView {
    /// Every descendant of `type`, depth first.
    func allSubviews<T: UIView>(of type: T.Type) -> [T] {
        subviews.flatMap { view -> [T] in
            if let match = view as? T { return [match] }
            return view.allSubviews(of: type)
        }
    }
}
