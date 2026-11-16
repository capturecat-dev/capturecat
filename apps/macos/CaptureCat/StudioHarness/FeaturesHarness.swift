import CoreGraphics
import CryptoKit
import Foundation

/// Studio 4e gate — the editor's four features on iOS against the Mac, for
/// the same fixture:
///
///   Auto Zoom          blocks identical
///   Voice-over         a synthetic mic buffer → the same voice-track entry,
///                      the same level meter, the same export mix
///   Transcription      the same subtitle structure and timing for known
///                      speech (text may differ only where the engine does)
///   Background removal the shared mask producer (conditioning + encoder
///                      byte-identical; Vision's matte compared), and the
///                      cutout's preview and export frames within the
///                      studio's parity bars
///
/// `CaptureCat --features-reference <dir>` (the Mac,
/// Services/FeaturesReferenceRunner.swift) writes every fixture and the Mac's
/// own results into <dir>; StudioLab `--features <out> --reference <dir>`
/// (StudioLab/FeaturesLab.swift) runs the same features on iOS through the
/// SHIPPING flows (StudioUI/Features) and scores them with the comparators
/// here. Both sides call the functions in these files, so what is left to
/// differ is the platform. `apps/ios/scripts/ios-features.sh` runs both.
enum FeaturesHarness {
    /// Harness-only defects (`--inject <name>`): each must turn its check red.
    enum Inject: String, CaseIterable {
        /// Every iOS Auto Zoom block starts one frame late.
        case autoZoomShift = "autozoom-shift"
        /// The iOS take starts 50 ms after the playhead.
        case voiceOffset = "voice-offset"
        /// The iOS voice clip's gain drops to 0.9 before the mix.
        case mixGain = "mix-gain"
        /// The iOS transcript's words all move 0.12 s later.
        case transcriptTiming = "transcript-timing"
        /// The iOS preview is rendered without the person mask.
        case maskIgnored = "mask-ignored"
        /// The iOS matte loses its edges (alpha thresholded at 200).
        case maskAlpha = "mask-alpha"
        /// The iOS progress bar jumps straight to its value (no motion).
        case progressSnap = "progress-snap"
    }

    static var inject: Inject?

    static func injected(_ defect: Inject) -> Bool { inject == defect }

    // MARK: - Canonical values

    /// Sorted-key JSON of `value` with every `id` removed, so two runs that
    /// minted different UUIDs compare on content.
    static func canonical<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) else { return "<unencodable>" }
        return canonicalJSON(stripIDs(object))
    }

    nonisolated static func canonicalJSON(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.sortedKeys, .fragmentsAllowed]) else { return "<invalid>" }
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated static func stripIDs(_ object: Any) -> Any {
        if let dict = object as? [String: Any] {
            var out: [String: Any] = [:]
            for (key, value) in dict where key != "id" { out[key] = stripIDs(value) }
            return out
        }
        if let array = object as? [Any] { return array.map(stripIDs) }
        return object
    }

    // MARK: - Files

    static func write(_ object: Any, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
    }

    static func read(_ url: URL) -> Any? {
        (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func writeFloats(_ samples: [Float], to url: URL) {
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        try? data.write(to: url)
    }

    static func readFloats(_ url: URL) -> [Float]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    // MARK: - Report

    /// Collects one feature's checks; every line is printed as it lands.
    final class Report {
        let feature: String
        private(set) var failures = 0
        private(set) var checks = 0
        private let log: (String) -> Void

        init(_ feature: String, log: @escaping (String) -> Void) {
            self.feature = feature
            self.log = log
        }

        func check(_ name: String, _ pass: Bool, _ detail: String = "") {
            checks += 1
            if !pass { failures += 1 }
            log("FEATURE \(feature) \(pass ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        }

        func note(_ text: String) { log("FEATURE \(feature) NOTE \(text)") }

        var pass: Bool { failures == 0 && checks > 0 }
    }
}
