import AppKit
import Observation

// Phase-3b of the AppKit conversion: the secondary surfaces (project browser,
// onboarding, export sheet) render as native AppKit view controllers. The
// SwiftUI implementations and the `useAppKitSurfaces` flag that selected
// between them have been retired.

/// Re-arming observation loop used by the native surfaces: `apply` runs once
/// immediately and again (on main) after any @Observable it read changes.
/// Returns a token; observation stops when `cancel()` is called or the token
/// deallocates.
@MainActor
final class SurfaceObservation {
    private var cancelled = false

    init(_ apply: @escaping @MainActor () -> Void) {
        observe(apply)
    }

    private func observe(_ apply: @escaping @MainActor () -> Void) {
        guard !cancelled else { return }
        withObservationTracking {
            apply()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observe(apply)
            }
        }
    }

    func cancel() { cancelled = true }

    deinit { cancelled = true }
}
