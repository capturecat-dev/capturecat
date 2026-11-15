import AppKit

/// `CaptureCat --export-parity <fixturesDir> [--out <dir>] [--only a,b] [--inject padding] [--source-yuv] [--reference <dir>]`
///
/// The Mac side of the Studio Phase 3 export-parity gate: the Mac's own
/// render-parity fixtures (`--web-parity-fixtures`) re-exported by THIS
/// binary through the shared `ExportParityHarness` — the control for the iOS
/// run (`apps/ios/scripts/ios-export-parity.sh`). A Mac re-export must be
/// byte-identical to the fixture's taps; with `--inject padding` it must
/// fail. Exit code 0 = every fixture passed. DEBUG tooling; never reached in
/// a normal launch.
@MainActor
enum ExportParityRunner {
    static func run() -> Never {
        setbuf(stdout, nil)
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--decode-probe"), args.indices.contains(i + 1) {
            let video = URL(fileURLWithPath: args[i + 1])
            let index = args.firstIndex(of: "--index").flatMap { args.indices.contains($0 + 1) ? Int(args[$0 + 1]) : nil } ?? 0
            let out = args.firstIndex(of: "--out").map { URL(fileURLWithPath: args[$0 + 1]) }
                ?? video.deletingLastPathComponent().appendingPathComponent("decode-probe-mac")
            Task { @MainActor in
                await ExportParityHarness.decodeProbe(video: video, index: index, out: out) { print($0) }
                exit(0)
            }
            RunLoop.main.run()
        }
        guard let options = ExportParityHarness.options(from: CommandLine.arguments, flag: "--export-parity") else {
            print("usage: CaptureCat --export-parity <fixturesDir> [--out <dir>] [--only a,b] [--inject padding] [--source-yuv] [--reference <dir>]")
            exit(2)
        }
        print("EXPORT-PARITY fixtures=\(options.fixtures.path) out=\(options.out.path)"
              + (options.inject.map { " inject=\($0.rawValue)" } ?? "")
              + (options.sourceYUV ? " source=yuv" : "")
              + (options.reference.map { " reference=\($0.path)" } ?? ""))
        Task { @MainActor in
            let results = await ExportParityHarness.run(options) { print($0) }
            exit(!results.isEmpty && results.allSatisfy(\.pass) ? 0 : 1)
        }
        RunLoop.main.run()
        fatalError("unreachable")
    }
}
