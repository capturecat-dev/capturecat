import AVFoundation
import BackgroundTasks
import QuartzCore
import UIKit

/// (g) Background GPU export with BGContinuedProcessingTask (iOS 26).
///
/// Variants:
///   probe         BGTaskScheduler.supportedResources (does this device allow
///                 background GPU at all?)
///   export        submit a continued-processing request with .gpu (strategy
///                 .fail), run spike c's 4K exporter inside it at depth 3, and
///                 sample throughput + applicationState twice a second. Put
///                 the app in the background a few seconds in (the run script
///                 launches Settings with devicectl) and see whether export
///                 keeps going on the GPU.
///   export-nogpu  same request WITHOUT .gpu — the control: what happens to
///                 Metal/CoreImage work once the app is backgrounded.
/// Arguments: --frames (default 900 = 30 s of 4K30 output).
@MainActor
enum SpikeG {
    static let prefix = "so.capturecat.spikes.export"

    /// Continued-processing registrations are exempt from the
    /// before-launch-finishes rule, so registration happens per submit; this
    /// hook exists so a future relaunch path has a place to go.
    nonisolated static func registerHandler() {}

    static func run(variant: String) async throws -> [String: Any] {
        guard #available(iOS 26.0, *) else { throw SpikeError("needs iOS 26") }
        let supported = BGTaskScheduler.supportedResources
        var result: [String: Any] = ["supportedResources": supported.contains(.gpu) ? ["gpu"] : []]
        if variant == "probe" { return result }
        let wantsGPU = variant == "export"
        if wantsGPU && !supported.contains(.gpu) {
            result["note"] = "device does not support background GPU; submitting without .gpu would be the control"
            return result
        }
        let frames = Harness.shared.int("--frames", default: 900)
        let identifier = "\(prefix).\(UUID().uuidString.prefix(8))"
        let source = try Harness.shared.media("screen-3456x2234-60.mov")
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("spike-g.mp4")
        try? FileManager.default.removeItem(at: output)
        let exporter = try ShapedExporter(source: source, output: output, size: CGSize(width: 3840, height: 2160), fps: 30)
        let recorder = Recorder()

        let outcome: [String: Any] = await withCheckedContinuation { cont in
            let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
                guard let task = task as? BGContinuedProcessingTask else { return }
                recorder.mark("handler started")
                task.progress.totalUnitCount = Int64(frames)
                let work = Task.detached {
                    do {
                        let r = try await exporter.export(frames: frames, depth: 3) { done in
                            task.progress.completedUnitCount = Int64(done)
                            recorder.frames = done
                        }
                        recorder.mark("export finished")
                        task.setTaskCompleted(success: true)
                        cont.resume(returning: ["export": r])
                    } catch {
                        recorder.mark("export failed: \(error)")
                        task.setTaskCompleted(success: false)
                        cont.resume(returning: ["exportError": "\(error)"])
                    }
                }
                task.expirationHandler = {
                    recorder.mark("EXPIRED by system")
                    work.cancel()
                }
            }
            recorder.mark("registered=\(registered)")
            let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: "Exporting 4K (spike)",
                                                           subtitle: "CCSpikes")
            request.strategy = .fail
            if wantsGPU { request.requiredResources = .gpu }
            do {
                try BGTaskScheduler.shared.submit(request)
                recorder.mark("submitted gpu=\(wantsGPU)")
            } catch {
                recorder.mark("submit failed: \(error)")
                cont.resume(returning: ["submitError": "\(error)"])
            }
        }
        recorder.stop()
        // Did the GPU really render the background frames, or did Metal fail
        // fast into black? Luma stats of decoded output frames, tagged with
        // the app state when each frame was exported.
        result["frameCheck"] = await frameCheck(output, timeline: recorder.samples)
        try? FileManager.default.removeItem(at: output)
        result.merge(outcome) { $1 }
        result["requestedGPU"] = wantsGPU
        result["timeline"] = recorder.samples
        result["events"] = recorder.events
        return result
    }
}

extension SpikeG {
    static func frameCheck(_ url: URL, timeline: [[String: Any]]) async -> [[String: Any]] {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        var rows: [[String: Any]] = []
        for index in [30, 90, 150, 300, 450, 600, 750, 880] {
            let state = timeline.first { ($0["frames"] as? Int ?? 0) >= index }?["state"] as? String ?? "?"
            guard let (cg, _) = try? await gen.image(at: CMTime(value: CMTimeValue(index), timescale: 30)) else {
                rows.append(["index": index, "state": state, "error": "no frame"]); continue
            }
            let w = 64, h = 36
            var px = [UInt8](repeating: 0, count: w * h * 4)
            px.withUnsafeMutableBytes { raw in
                let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            var lum: [Double] = []
            for i in 0..<(w * h) {
                lum.append(0.2126 * Double(px[i * 4]) + 0.7152 * Double(px[i * 4 + 1]) + 0.0722 * Double(px[i * 4 + 2]))
            }
            let mean = lum.reduce(0, +) / Double(lum.count)
            let sd = (lum.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(lum.count)).squareRoot()
            rows.append(["index": index, "state": state, "meanLuma": mean, "sdLuma": sd])
        }
        return rows
    }
}

/// Twice-a-second samples of progress and app state, plus timestamped events.
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private let start = CACurrentMediaTime()
    private var _frames = 0
    private(set) var samples: [[String: Any]] = []
    private(set) var events: [String] = []
    private var timer: Timer?

    var frames: Int {
        get { lock.withLock { _frames } }
        set { lock.withLock { _frames = newValue } }
    }

    init() {
        Task { @MainActor in
            let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sample() }
            }
            RunLoop.main.add(t, forMode: .common)
            self.timer = t
        }
    }

    @MainActor private func sample() {
        let state: String
        switch UIApplication.shared.applicationState {
        case .active: state = "active"
        case .inactive: state = "inactive"
        case .background: state = "background"
        @unknown default: state = "?"
        }
        let row: [String: Any] = ["t": CACurrentMediaTime() - start, "frames": frames, "state": state,
                                  "thermal": Metrics.thermal]
        lock.withLock { samples.append(row) }
    }

    func mark(_ e: String) {
        let line = String(format: "%.2f ", CACurrentMediaTime() - start) + e
        lock.withLock { events.append(line) }
        Harness.shared.log("G " + line)
    }

    func stop() { Task { @MainActor in self.timer?.invalidate() } }
}
