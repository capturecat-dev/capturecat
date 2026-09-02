import Foundation
import ScreenCaptureKit
import AppKit

/// Resolves an automation capture request ("display 0", "the Chrome window",
/// "window titled Stripe") into a concrete `CaptureSource`. Shared by the
/// `capturecat://` deep-link handler and the MCP automation bridge so both
/// entry points pick targets identically — including launching the requested
/// browser when it isn't running yet.
@MainActor
enum CaptureSourceResolver {
    /// `type` is one of display | window | chrome | safari.
    /// Params: display (index), app (owning app name), title (window title).
    static func resolve(type: String, params: [String: String], launchIfMissing: Bool = false) async -> CaptureSource? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else {
            return nil
        }

        switch type {
        case "display":
            // Use specific display index or default to main
            let displayIndex = Int(params["display"] ?? "0") ?? 0
            guard displayIndex < content.displays.count else {
                return content.displays.first.map { .display($0) }
            }
            return .display(content.displays[displayIndex])

        case "window":
            // Match window by app name or title
            if let appName = params["app"] {
                let match = content.windows.first { window in
                    window.owningApplication?.applicationName.localizedCaseInsensitiveContains(appName) == true
                }
                if match == nil, launchIfMissing {
                    // App not running — try to launch it
                    await launchAppByName(appName)
                }
                if let match { return .window(match) }
            }
            if let title = params["title"] {
                let match = content.windows.first { window in
                    window.title?.localizedCaseInsensitiveContains(title) == true
                }
                if let match { return .window(match) }
            }
            // Fallback: first non-CaptureCat window
            let myPID = ProcessInfo.processInfo.processIdentifier
            return content.windows.first { $0.owningApplication?.processID != myPID }.map { .window($0) }

        case "chrome":
            return await findOrLaunchApp(
                bundleID: "com.google.Chrome",
                appPath: "/Applications/Google Chrome.app",
                label: "Chrome",
                from: content
            )

        case "safari":
            return await findOrLaunchApp(
                bundleID: "com.apple.Safari",
                appPath: "/System/Applications/Safari.app",
                label: "Safari",
                from: content
            )

        default:
            return content.displays.first.map { .display($0) }
        }
    }

    /// Find an app's window. If not running, launch it and wait up to 10s for a
    /// window to appear. Returns nil (error) if the window can't be found —
    /// never falls back to a different app.
    private static func findOrLaunchApp(
        bundleID: String,
        appPath: String,
        label: String,
        from content: SCShareableContent
    ) async -> CaptureSource? {
        // Check if already has a window
        if let window = findLargestWindow(bundleID: bundleID, from: content) {
            print("[CaptureSource] Found \(label) window: \(Int(window.frame.width))x\(Int(window.frame.height)) '\(window.title ?? "")'")
            return .window(window)
        }

        // Not running — launch it
        print("[CaptureSource] \(label) not found, launching...")
        await launchAppIfNeeded(bundleID: bundleID, path: appPath)

        // Wait for the app to create a visible window (up to 10 seconds)
        for attempt in 1...20 {
            try? await Task.sleep(for: .milliseconds(500))
            guard let freshContent = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { continue }
            if let window = findLargestWindow(bundleID: bundleID, from: freshContent) {
                print("[CaptureSource] Found \(label) window after \(Double(attempt) * 0.5)s: \(Int(window.frame.width))x\(Int(window.frame.height))")
                return .window(window)
            }
            if attempt % 4 == 0 {
                print("[CaptureSource] Waiting for \(label) window... (\(attempt / 2)s)")
            }
        }

        print("[CaptureSource] ERROR: \(label) window not found after 10s. Is it installed at \(appPath)?")
        return nil
    }

    private static func findLargestWindow(bundleID: String, from content: SCShareableContent) -> SCWindow? {
        content.windows
            .filter { $0.owningApplication?.bundleIdentifier == bundleID && $0.frame.width > 100 && $0.frame.height > 100 }
            .sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
            .first
    }

    private static func launchAppIfNeeded(bundleID: String, path: String) async {
        let appURL = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            print("[CaptureSource] App not installed: \(path)")
            return
        }

        // Always activate the app — even if running in background with no window
        print("[CaptureSource] Launching/activating \(bundleID)...")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        try? await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
    }

    private static func launchAppByName(_ name: String) async {
        // Try common app locations
        let candidates = [
            "/Applications/\(name).app",
            "/System/Applications/\(name).app",
            "/Applications/\(name).app/Contents/MacOS/\(name)"
        ]
        for path in candidates {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path) {
                print("[CaptureSource] Launching \(name) from \(path)...")
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
                return
            }
        }
        // No `open -a` fallback: that resolved ANY name LaunchServices knows,
        // which let a caller launch arbitrary apps. Only the fixed
        // /Applications paths above are honoured.
        print("[CaptureSource] \(name) not found in /Applications")
    }
}
