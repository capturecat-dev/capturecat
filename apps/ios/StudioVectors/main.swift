import Foundation

// iOS replay of the Mac's golden vectors (apps/ios/scripts/ios-vectors.sh).
// Built for the iOS Simulator from the shared Studio/ sources plus the Mac's
// own vector harness files, then run inside a booted simulator with
// `simctl spawn` — the same unit code, the iOS SDK underneath.
// `--cursor-rasters <dir>` instead dumps every cursor raster for the
// script's byte comparison with the Mac's `--web-cursor-sprites`.
MainActor.assumeIsolated {
    if CommandLine.arguments.contains("--cursor-rasters") {
        CursorRasters.run(arguments: CommandLine.arguments)
    }
    WebVectorsHarness.run()
}
