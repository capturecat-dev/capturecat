import Foundation

/// Export tuning gate (Studio 3b): `CaptureCat --export-tuning-test`.
///
/// `ExportTuning` decides the exporter's pipeline depth. This gate pins the
/// policy: the Mac always keeps 8; iOS runs 3 only with ample memory, 2
/// otherwise and when hot, and refuses up front when even 2 would not fit;
/// the footprint model reproduces Phase 0's 4K measurements; more memory
/// never yields a shallower pipe; a device that heats up mid-export drops to
/// 2 (iOS only). That depth never changes pixels is proven separately by the
/// export-parity control with `CAPTURECAT_EXPORT_PIPELINE_DEPTH`.
/// Pure — no media. Never reached in a normal launch.
enum ExportTuningHarness {
    static func run() -> Never {
        var checks = 0
        var failures = 0
        func check(_ name: String, _ pass: Bool, _ detail: String = "") {
            checks += 1
            if !pass { failures += 1 }
            print("\(pass ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        }
        let gb: UInt64 = 1 << 30
        let mb: UInt64 = 1 << 20
        let px4K = 3840 * 2160
        let px1080 = 1920 * 1080
        func inputs(_ available: UInt64?, _ thermal: ProcessInfo.ThermalState = .nominal,
                    _ pixels: Int = px4K, mac: Bool = false) -> ExportTuning.Inputs {
            ExportTuning.Inputs(availableMemory: available, thermal: thermal, outputPixels: pixels, isMac: mac)
        }

        // Mac: the long-standing depth, whatever the inputs.
        for thermal in [ProcessInfo.ThermalState.nominal, .fair, .serious, .critical] {
            for available in [nil, 100 * mb, 16 * gb] as [UInt64?] {
                let d = ExportTuning.decide(inputs(available, thermal, mac: true))
                check("mac: depth 8 (thermal \(thermal.rawValue), available \(available.map { "\($0 / mb) MB" } ?? "nil"))",
                      d == .depth(8), "\(d)")
            }
            check("mac: mid-export heat never changes the depth (thermal \(thermal.rawValue))",
                  ExportTuning.adjusted(depth: 8, thermal: thermal, isMac: true) == 8)
        }

        // The footprint model reproduces the measurements it was built from.
        for (depth, measured) in ExportTuning.measured4K.sorted(by: { $0.key < $1.key }) {
            let estimate = Double(ExportTuning.estimatedFootprint(depth: depth, outputPixels: px4K)) / Double(mb)
            check("model: 4K depth \(depth) = Phase 0's \(Int(measured)) MB", abs(estimate - measured) < 1,
                  String(format: "%.1f MB", estimate))
        }
        let e1080 = Double(ExportTuning.estimatedFootprint(depth: 2, outputPixels: px1080)) / Double(mb)
        check("model: 1080p depth 2 between the fixed part and the 4K figure", e1080 > 479 && e1080 < 757,
              String(format: "%.1f MB", e1080))

        // iOS policy.
        let table: [(String, ExportTuning.Inputs, ExportTuning.Decision)] = [
            ("4K, 3.4 GB available (Phase 0's phone)", inputs(3_400 * mb), .depth(3)),
            ("4K, 1.5 GB available", inputs(1_500 * mb), .depth(2)),
            ("4K, 3.4 GB but thermal serious", inputs(3_400 * mb, .serious), .depth(2)),
            ("4K, 3.4 GB but thermal critical", inputs(3_400 * mb, .critical), .depth(2)),
            ("4K, 3.4 GB, thermal fair", inputs(3_400 * mb, .fair), .depth(3)),
            ("unknown memory", inputs(nil), .depth(2)),
            ("4K, 2.3 GB available (depth 3 = under half)", inputs(2_300 * mb), .depth(3)),
            ("4K, 2.1 GB available (depth 3 = over half)", inputs(2_100 * mb), .depth(2)),
            ("1080p, 1.5 GB available", inputs(1_500 * mb, .nominal, px1080), .depth(3)),
            ("1080p, 1 GB available", inputs(1_000 * mb, .nominal, px1080), .depth(2)),
        ]
        for (name, i, expected) in table {
            let d = ExportTuning.decide(i)
            check("ios: \(name) → \(expected)", d == expected, "\(d)")
        }
        let tight = ExportTuning.decide(inputs(600 * mb))
        if case .insufficientMemory(let needed, let available) = tight {
            check("ios: 4K with 600 MB available is refused up front", needed > available,
                  "needs \(needed / mb) MB, \(available / mb) MB available")
        } else {
            check("ios: 4K with 600 MB available is refused up front", false, "\(tight)")
        }

        // More memory never chooses a shallower pipe (4K and 1080p sweeps).
        for pixels in [px4K, px1080] {
            var last = 0
            var monotonic = true
            for step in stride(from: 200, through: 8_000, by: 50) {
                let depth: Int
                switch ExportTuning.decide(inputs(UInt64(step) * mb, .nominal, pixels)) {
                case .depth(let d): depth = d
                case .insufficientMemory: depth = 0
                }
                if depth < last { monotonic = false }
                last = depth
            }
            check("ios: depth never falls as memory grows (\(pixels == px4K ? "4K" : "1080p"))", monotonic)
        }

        // Mid-export heat (iOS).
        check("ios: heating up mid-export drops 3 → 2",
              ExportTuning.adjusted(depth: 3, thermal: .serious, isMac: false) == 2)
        check("ios: a cool device keeps its depth",
              ExportTuning.adjusted(depth: 3, thermal: .fair, isMac: false) == 3)

        // Harness override wins everywhere.
        check("override wins on iOS and the Mac",
              ExportTuning.decide(inputs(600 * mb), override: 5) == .depth(5)
                && ExportTuning.decide(inputs(nil, mac: true), override: 2) == .depth(2))

        print("EXPORT-TUNING \(checks - failures)/\(checks) checks passed")
        exit(failures == 0 ? 0 : 1)
    }
}
