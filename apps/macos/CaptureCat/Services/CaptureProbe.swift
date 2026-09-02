import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// `CaptureCat --capture-probe` — reports why the recording panel has no sources.
///
/// # Why this exists
///
/// When the source pickers are empty the panel can only say "permission is
/// required", because that is all `SCShareableContent` tells it. That message
/// is the same whether the app was never granted access, had it revoked, or —
/// the case that actually happened — was granted access under a DIFFERENT
/// bundle identifier.
///
/// macOS keys Screen Recording (TCC) on bundle id plus code signature. Renaming
/// `com.michaelgarland.Cappd` to `so.capturecat.CaptureCat` therefore produced a
/// binary with no permission at all, while the old identifier kept its grant and
/// went on showing up in System Settings. The UI symptom is that the display and
/// window menus are empty, which reads as "the dock bar is broken" rather than
/// as a permissions problem.
///
/// This prints the identity being checked alongside the result, so the two can
/// never be conflated again.
enum CaptureProbe {
    static let flag = "--capture-probe"

    static var isRequested: Bool { CommandLine.arguments.contains(flag) }

    static func run() -> Never {
        let bundleID = Bundle.main.bundleIdentifier ?? "<none>"
        let path = Bundle.main.bundlePath

        emit("IDENTITY bundle=\(bundleID)")
        emit("IDENTITY path=\(path)")

        // Does NOT prompt. `CGRequestScreenCaptureAccess` would, and a probe
        // that changes the state it is measuring is worse than useless.
        let preflight = CGPreflightScreenCaptureAccess()
        emit("PREFLIGHT screen-capture=\(preflight)")

        let sem = DispatchSemaphore(value: 0)
        var displays = 0
        var windows = 0
        var failure: String?

        Task.detached {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: true)
                displays = content.displays.count
                windows = content.windows.count
                for d in content.displays {
                    emit("DISPLAY id=\(d.displayID) \(d.width)x\(d.height)")
                }
            } catch {
                let ns = error as NSError
                failure = "\(ns.domain) code=\(ns.code) \(ns.localizedDescription)"
            }
            sem.signal()
        }

        if sem.wait(timeout: .now() + 20) == .timedOut {
            emit("RESULT timed out asking ScreenCaptureKit")
            exit(2)
        }

        if let failure {
            emit("SHAREABLE-CONTENT failed: \(failure)")
        } else {
            emit("SHAREABLE-CONTENT displays=\(displays) windows=\(windows)")
        }

        emit("")
        if displays > 0 {
            emit("RESULT OK — \(displays) display(s) available; the pickers should populate.")
            exit(0)
        }
        if !preflight {
            emit("RESULT NO PERMISSION for \(bundleID).")
            emit("  System Settings > Privacy & Security > Screen & System Audio Recording,")
            emit("  then enable CaptureCat and relaunch it.")
            emit("  If an older entry for a DIFFERENT identifier is listed and enabled,")
            emit("  that grant does not apply here — TCC is keyed per bundle id.")
            exit(1)
        }
        emit("RESULT Permission looks granted but no displays came back.")
        emit("  macOS is denying this app session; quit CaptureCat fully and reopen.")
        exit(1)
    }

    private static func emit(_ s: String) {
        FileHandle.standardOutput.write(Data((s + "\n").utf8))
    }
}
