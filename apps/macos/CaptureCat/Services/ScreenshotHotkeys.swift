import AppKit
import ApplicationServices

/// Global ⇧⌘3/4/5 interception — the "default screenshot tool" mechanism.
///
/// Carbon's `RegisterEventHotKey` can never win against macOS's reserved
/// screenshot shortcuts (that was the first attempt, and it silently lost).
/// This is an ACTIVE CGEvent tap at session/head-insert: matching key-downs
/// are consumed before the window server's symbolic-hotkey handling, so
/// CaptureCat fires and Apple's screenshot UI never does — the mechanism
/// BetterTouchTool-class remappers use. Consuming (unlike KeystrokeTracker's
/// `.listenOnly` tap, which rides Input Monitoring) requires Accessibility
/// trust; without it the tap is not created and macOS keeps its shortcuts.
///
/// ⇧⌘3 → instant full-screen still; ⇧⌘4/5 → open the capture panel.
@MainActor
enum ScreenshotHotkeys {
    static var onFullScreen: (() -> Void)?
    static var onPanel: (() -> Void)?

    private static var tap: CFMachPort?
    private static var runLoopSource: CFRunLoopSource?

    /// kVK_ANSI_3 / 4 / 5.
    nonisolated static let fullScreenKey: Int64 = 20
    nonisolated static let panelKeys: Set<Int64> = [21, 23]

    static var hasPermission: Bool { AXIsProcessTrusted() }

    /// Shows the system Accessibility prompt (no-op if already decided).
    static func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func setEnabled(_ enabled: Bool) {
        enabled ? start() : stop()
    }

    private static func start() {
        guard tap == nil, hasPermission else { return }
        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue
        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: screenshotTapCallbackPointer,
            userInfo: nil
        ) else { return }
        tap = created
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
    }

    static func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// `--screenshot-hotkey-probe`: prints every link in the chain and exits.
    static func probe() {
        let stored = UserDefaults.standard.bool(forKey: "defaultScreenshotTool")
        print("HOTKEY-PROBE settingOn=\(stored)")
        print("HOTKEY-PROBE axTrusted=\(AXIsProcessTrusted())")
        print("HOTKEY-PROBE inputMonitoring=\(CGPreflightListenEventAccess())")
        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue
        let active = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask,
            callback: screenshotTapCallbackPointer, userInfo: nil)
        print("HOTKEY-PROBE activeTapCreated=\(active != nil)")
        let listen = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .listenOnly, eventsOfInterest: mask,
            callback: screenshotTapCallbackPointer, userInfo: nil)
        print("HOTKEY-PROBE listenTapCreated=\(listen != nil)")
        // Also to a file: launched via LaunchServices (the REAL trust
        // context — from a terminal the probe inherits the terminal's
        // Accessibility trust and lies), stdout goes nowhere readable.
        let report = """
        settingOn=\(stored) axTrusted=\(AXIsProcessTrusted()) \
        inputMonitoring=\(CGPreflightListenEventAccess()) \
        activeTap=\(active != nil) listenTap=\(listen != nil)
        """
        try? report.write(
            to: FileManager.default.temporaryDirectory.appendingPathComponent("hotkey-probe.txt"),
            atomically: true, encoding: .utf8)
        exit(0)
    }

    private static func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
    }
}

/// The C-pointer conversion happens HERE, at nonisolated file scope — inside
/// the @MainActor enum the conversion site inherits actor isolation and the
/// compiler refuses it.
private let screenshotTapCallbackPointer: CGEventTapCallBack = screenshotTapCallback

/// Top-level (nonisolated) so it can be a C function pointer — a closure
/// formed inside the @MainActor enum inherits actor isolation and cannot.
private func screenshotTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    // The system disables a tap that stalls or on user-input safeguards —
    // re-enable, never drop the feature silently.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        Task { @MainActor in ScreenshotHotkeys.reenable() }
        return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown else { return Unmanaged.passUnretained(event) }
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags
    let cmdShift = flags.contains(.maskCommand) && flags.contains(.maskShift)
    let others = flags.contains(.maskControl) || flags.contains(.maskAlternate)
    guard cmdShift, !others,
          keyCode == ScreenshotHotkeys.fullScreenKey
            || ScreenshotHotkeys.panelKeys.contains(keyCode) else {
        return Unmanaged.passUnretained(event)
    }
    Task { @MainActor in
        keyCode == ScreenshotHotkeys.fullScreenKey
            ? ScreenshotHotkeys.onFullScreen?()
            : ScreenshotHotkeys.onPanel?()
    }
    return nil // consumed — macOS's own screenshot never fires
}
