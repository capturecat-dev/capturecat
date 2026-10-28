import Foundation

/// `CaptureCat --camera-mask-bench <camera.mov>` — runs the REAL segmentation
/// job (Vision person segmentation → `.ccmask`) on a COPY of a camera file and
/// reports what the mask track costs as the app writes it (§2 resolution,
/// producer alpha conditioning, keyframeInterval 30): frames, bytes per
/// frame, MB per minute, per-phase time, and a lossless re-encode at
/// keyframeInterval 15 for comparison. `--variants` runs the producer
/// experiments instead (CameraMaskBenchHarness+Variants.swift).
///
/// Read-only toward the input: the file is copied into the process's temp
/// directory first and every output lands there; nothing beside the source
/// (e.g. a user's project folder) is touched. Never reached in a normal launch.
enum CameraMaskBenchHarness {
    static func run() -> Never {
        setbuf(stdout, nil)
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--camera-mask-bench"), args.indices.contains(i + 1) else {
            print("CAMERA-MASK-BENCH usage: --camera-mask-bench <camera.mov>")
            exit(2)
        }
        let source = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath)
        let variants = args.contains("--variants")
        Task { @MainActor in
            let ok = variants ? await executeVariants(source: source) : await execute(source: source)
            exit(ok ? 0 : 1)
        }
        RunLoop.main.run()
        exit(1)
    }

    @MainActor
    private static func execute(source: URL) async -> Bool {
        let fm = FileManager.default
        let work = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("capturecat-mask-bench-\(UUID().uuidString.prefix(6))", isDirectory: true)
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            let copy = work.appendingPathComponent("camera.\(source.pathExtension.isEmpty ? "mov" : source.pathExtension)")
            try fm.copyItem(at: source, to: copy)
            defer { try? fm.removeItem(at: work) }
            let started = Date()
            let stats = CameraSegmentationStats()
            let data = try await Task.detached(priority: .userInitiated) {
                try await CameraSegmenter.segment(cameraURL: copy, gate: CameraSegmentationGate(),
                                                  stats: stats) { _ in }
            }.value
            let seconds = Date().timeIntervalSince(started)
            let track = try CameraMaskTrack(data: data)
            let h = track.header
            // Lossless re-encode at kfi 15 from the decoded frames.
            let decoder = CameraMaskTrack.Decoder(track: track)
            let encoder30 = CameraMaskTrack.Encoder(width: h.width, height: h.height, keyframeInterval: 15)
            var keys15 = 0
            for (f, entry) in track.index.enumerated() {
                if !entry.delta { keys15 += 1 }
                try encoder30.append(time: entry.time, alpha: try decoder.frame(f))
            }
            let data30 = encoder30.finish(sourceDuration: h.sourceDuration, sourceByteSize: h.sourceByteSize)
            let track30 = try CameraMaskTrack(data: data30)
            let check = CameraMaskTrack.Decoder(track: track30)
            let verify = CameraMaskTrack.Decoder(track: track)
            var lossless = true
            for f in stride(from: 0, to: h.frameCount, by: 7) where try check.frame(f) != verify.frame(f) { lossless = false }
            let minutes = max(1e-9, h.sourceDuration / 60)
            func fmt(_ bytes: Int) -> String {
                String(format: "%d B (%.0f B/frame, %.2f MB/min)", bytes, Double(bytes) / Double(max(1, h.frameCount)),
                       Double(bytes) / minutes / 1_000_000)
            }
            print("CAMERA-MASK-BENCH source \(source.lastPathComponent) \(Int(h.sourceByteSize)) B, \(String(format: "%.2f", h.sourceDuration)) s")
            print("CAMERA-MASK-BENCH mask \(h.width)x\(h.height) frames=\(h.frameCount) vision+encode \(String(format: "%.1f", seconds)) s (\(String(format: "%.1f", Double(h.frameCount) / max(0.001, seconds))) fps)")
            print("CAMERA-MASK-BENCH phases " + stats.snapshot.sorted { $0.key < $1.key }
                .map { String(format: "%@ %.1f ms/frame", $0.key, $0.value / Double(max(1, h.frameCount)) * 1000) }
                .joined(separator: ", "))
            print("CAMERA-MASK-BENCH written (kfi \(h.keyframeInterval)) \(fmt(data.count)) keys=\(keys15)")
            print("CAMERA-MASK-BENCH re-encoded kfi15 \(fmt(data30.count)) keys=\(track30.index.filter { !$0.delta }.count) lossless=\(lossless)")
            print("CAMERA-MASK-BENCH \(lossless ? "OK" : "FAILED")")
            return lossless
        } catch {
            print("CAMERA-MASK-BENCH FAILED \(error)")
            try? fm.removeItem(at: work)
            return false
        }
    }
}
