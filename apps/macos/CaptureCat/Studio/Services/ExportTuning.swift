import Foundation

/// How deep the exporter's frame pipeline runs (Studio 3b): how many frames
/// are rendered and encoded concurrently. Depth only changes speed and
/// memory, never pixels — frames are appended in PTS order whatever the depth
/// (`--export-parity` with `CAPTURECAT_EXPORT_PIPELINE_DEPTH` proves it).
///
/// The Mac keeps the depth it always had (8: it keeps Apple Silicon's media
/// engine fed at 4K, and memory is plentiful). iOS chooses by memory and heat
/// from Phase 0's 4K measurements on an iPhone 15 Pro Max (3840×2160 @ 30,
/// docs/ios-studio-phase0.md §2c): throughput is FLAT across depths
/// (44.5 / 44.6 / 44.8 / 44.9 fps at depth 2 / 3 / 5 / 8) while the peak
/// footprint is not (757 / 1,112 / 1,272 / 1,590 MB). So iOS runs depth 3
/// only when memory is ample, depth 2 otherwise and under thermal pressure,
/// and refuses up front — with a clear error — when even depth 2 would not
/// fit, instead of being terminated by the system mid-export.
///
/// Pure: every input is passed in, so the policy is unit-tested
/// (`--export-tuning-test`) and identical in every harness.
enum ExportTuning {
    struct Inputs: Equatable {
        /// `os_proc_available_memory()` at export start, bytes; nil = no
        /// per-process limit known (the Mac).
        var availableMemory: UInt64?
        var thermal: ProcessInfo.ThermalState
        /// Output pixels per frame (width × height).
        var outputPixels: Int
        var isMac: Bool
    }

    enum Decision: Equatable {
        case depth(Int)
        /// Even the shallowest pipeline's estimated footprint exceeds what the
        /// process may still allocate.
        case insufficientMemory(needed: UInt64, available: UInt64)
    }

    static let macDepth = 8
    static let mobileDepth = 2
    static let mobileAmpleDepth = 3
    /// Depth 3 runs only when its estimated footprint is at most this share of
    /// the available memory — it buys almost no throughput (Phase 0: +0.1
    /// fps at 4K), so it must never be what pushes a phone toward its limit.
    static let ampleShare = 0.5

    private static let mb: Double = 1_048_576
    private static let pixels4K = 3840.0 * 2160.0
    /// Phase 0 peak footprints at 4K by depth (MB).
    static let measured4K: [Int: Double] = [2: 757, 3: 1_112, 5: 1_272, 8: 1_590]
    /// The intercept of a straight-line fit through the 4K measurements: the
    /// part of the footprint that does not scale with output size. Smaller
    /// outputs keep it and scale the rest by their pixel count — which
    /// over- rather than under-estimates them.
    static let fixedFootprintMB = 479.0

    /// Estimated peak footprint of an export at `depth` (bytes).
    static func estimatedFootprint(depth: Int, outputPixels: Int) -> UInt64 {
        let at4K = measured4K[depth] ?? (measured4K[8] ?? 1_590)
        let scale = max(0, Double(outputPixels)) / pixels4K
        return UInt64((fixedFootprintMB + (at4K - fixedFootprintMB) * scale) * mb)
    }

    static func decide(_ inputs: Inputs, override: Int? = nil) -> Decision {
        if let override { return .depth(override) }
        if inputs.isMac { return .depth(macDepth) }
        guard let available = inputs.availableMemory else { return .depth(mobileDepth) }
        let needed = estimatedFootprint(depth: mobileDepth, outputPixels: inputs.outputPixels)
        guard needed <= available else { return .insufficientMemory(needed: needed, available: available) }
        if isHot(inputs.thermal) { return .depth(mobileDepth) }
        let ample = estimatedFootprint(depth: mobileAmpleDepth, outputPixels: inputs.outputPixels)
        return Double(ample) <= Double(available) * ampleShare ? .depth(mobileAmpleDepth) : .depth(mobileDepth)
    }

    /// Mid-export: a device that heats up drops to the shallow pipe (iOS
    /// only — the Mac's depth never changes).
    static func adjusted(depth: Int, thermal: ProcessInfo.ThermalState, isMac: Bool) -> Int {
        guard !isMac, isHot(thermal) else { return depth }
        return min(depth, mobileDepth)
    }

    static func isHot(_ thermal: ProcessInfo.ThermalState) -> Bool {
        thermal == .serious || thermal == .critical
    }

    /// Harness-only override (`CAPTURECAT_EXPORT_PIPELINE_DEPTH`, 1…16).
    static var environmentOverride: Int? {
        ProcessInfo.processInfo.environment["CAPTURECAT_EXPORT_PIPELINE_DEPTH"]
            .flatMap(Int.init).map { min(16, max(1, $0)) }
    }
}
