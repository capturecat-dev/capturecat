import Foundation

// iOS replay of the Mac's golden vectors (apps/ios/scripts/ios-vectors.sh).
// Built for the iOS Simulator from the shared Studio/ sources plus the Mac's
// own vector harness files, then run inside a booted simulator with
// `simctl spawn` — the same unit code, the iOS SDK underneath.
MainActor.assumeIsolated {
    WebVectorsHarness.run()
}
