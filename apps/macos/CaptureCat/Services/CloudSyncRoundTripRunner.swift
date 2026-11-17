import Foundation

/// `CaptureCat --cloud-sync-roundtrip <dir> --step 1|3|5` — the Mac's steps
/// of the Mac ↔ iOS round trip (StudioHarness/CloudSyncRoundTrip.swift;
/// apps/ios/scripts/ios-cloud-sync.sh runs it). In-memory stub cloud
/// persisted in `<dir>`; no network, no user data.
enum CloudSyncRoundTripRunner {
    static func run() -> Never {
        setbuf(stdout, nil)
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--cloud-sync-roundtrip"), args.indices.contains(i + 1),
              let s = args.firstIndex(of: "--step"), args.indices.contains(s + 1), let step = Int(args[s + 1]) else {
            print("usage: --cloud-sync-roundtrip <dir> --step 1|3|5")
            exit(64)
        }
        let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        Task { @MainActor in
            let checks = CloudSyncHarness.Checks()
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try await CloudSyncRoundTrip.macStep(step, dir: dir, checks: checks)
            } catch {
                checks.expect(false, "step \(step) threw \(error)")
            }
            let ok = checks.failures.isEmpty
            print("ROUNDTRIP STEP \(step) \(ok ? "PASS" : "FAIL") (\(checks.passed) checks)")
            exit(ok ? 0 : 1)
        }
        dispatchMain()
    }
}
