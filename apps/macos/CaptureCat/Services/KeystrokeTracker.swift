import AppKit
import CoreGraphics
import CoreMedia

/// One captured keystroke. PRIVACY: by default only the moment and a coarse
/// category are stored — never keycodes or characters. The category exists
/// solely so keyboard SOUNDS can pick a deeper thock for space/return and a
/// quieter one for modifiers.
///
/// `shortcut` is the ONE opt-in exception: when the user enables the shortcut
/// overlay for a recording, keystrokes that include ⌘/⌃/⌥ store their display
/// string ("⌘⇧S") so the editor can show them subtitle-style. Plain typing —
/// anything without those modifiers — is still never identified, even opted
/// in, so passwords and prose can't leak into a video. The filter runs at
/// capture time; non-shortcut identity is discarded before it ever hits disk.
struct KeystrokeEvent: Codable, Sendable, Equatable {
    enum Category: String, Codable, Sendable {
        case key
        case space
        case `return`
        case delete
        case modifier
        /// Scroll-wheel tick (throttled) — recorded so zooms can steady the
        /// camera during scroll bursts. Never plays a key sound.
        case scroll
    }

    var timestamp: TimeInterval
    var category: Category
    /// Display string of a modifier shortcut ("⌘⇧S"), only when the user
    /// opted into the shortcut overlay for this recording. Synthesized
    /// Codable decodes it as nil from pre-existing recordings.
    var shortcut: String? = nil
    /// Bundle identifier of the application the shortcut was DELIVERED to,
    /// stamped only on events that carry a `shortcut` string (the same opt-in
    /// gate). Lets the editor scope the overlay to the recorded window's app
    /// and drop shortcuts typed into other apps mid-recording. Plain-category
    /// events stay identity-free; synthesized Codable decodes nil from
    /// pre-existing recordings.
    var frontmostBundleID: String? = nil
}

struct KeystrokeRecording: Codable, Sendable {
    var version: Int
    var events: [KeystrokeEvent]
}

/// Records keystroke timings during a capture session — the keyboard twin of
/// CursorTracker. Both consume the SAME `RecordingClock` instance, so timeline
/// origin and pause bookkeeping are shared storage rather than two copies that
/// have to be kept in step. Uses a listen-only CGEvent tap; if Input Monitoring
/// permission is missing the tracker simply records nothing — it must never
/// block or break a recording.
final class KeystrokeTracker {
    private(set) var events: [KeystrokeEvent] = []

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var clock: RecordingClock?
    private var previousFlags: CGEventFlags = []
    private var lastScrollTime: TimeInterval = -1
    /// Opt-in per recording (see KeystrokeEvent.shortcut's privacy note).
    private var capturesShortcuts = false

    var isTracking: Bool { tap != nil }

    /// True when the app can listen to keyboard events (Input Monitoring).
    static var hasPermission: Bool {
        CGPreflightListenEventAccess()
    }

    /// Prompts the system permission dialog (no-op if already decided).
    static func requestPermission() {
        CGRequestListenEventAccess()
    }

    /// `clock` must be the same instance the cursor tracker was started with —
    /// that shared instance is what makes keyboard/cursor drift impossible.
    func start(clock: RecordingClock, capturingShortcuts: Bool = false) {
        stop()
        events.removeAll()
        previousFlags = []
        bundleIDByPID.removeAll()
        self.clock = clock
        self.capturesShortcuts = capturingShortcuts

        guard Self.hasPermission else { return } // silently capture nothing

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.scrollWheel.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let tracker = Unmanaged<KeystrokeTracker>.fromOpaque(refcon).takeUnretainedValue()
                tracker.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: selfPtr
        ) else { return }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Pauses the SHARED clock (idempotent) — the cursor tracker's `pause()`
    /// does the identical thing to the identical object, so the two can never
    /// accumulate different pause totals no matter what order AppState calls
    /// them in.
    func pause() {
        clock?.pause()
    }

    func resume() {
        clock?.resume()
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
    }

    func save(to url: URL) throws {
        let recording = KeystrokeRecording(version: 1, events: events)
        let data = try JSONEncoder().encode(recording)
        try data.write(to: url)
    }

    static func loadRecording(from url: URL) throws -> KeystrokeRecording {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(KeystrokeRecording.self, from: data)
    }

    // MARK: - Event handling

    /// Internal (not private) so the keysound harness can drive the REAL
    /// ingest path with a forged CGEvent instead of a parallel reimplementation.
    func handle(type: CGEventType, event: CGEvent) {
        // The tap can be disabled by the system under load — re-enable. Checked
        // before the paused guard: a tap disabled during a pause must still come
        // back, or every keystroke after the resume is lost.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }

        guard let clock, !clock.isPaused else { return }

        let category: KeystrokeEvent.Category?
        var shortcut: String? = nil
        var frontmostBundleID: String? = nil
        switch type {
        case .scrollWheel:
            // Throttle to 10Hz — bursts matter, not individual ticks.
            let now = clock.timelineTimeNow()
            guard now - lastScrollTime >= 0.1 else { return }
            lastScrollTime = now
            category = .scroll
        case .keyDown:
            // Auto-repeat is not a new keystroke.
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return }
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            category = Self.category(forKeyCode: keyCode)
            if capturesShortcuts {
                shortcut = Self.shortcutDisplay(keyCode: keyCode, flags: event.flags)
            }
            // App identity rides ONLY on opt-in shortcut events (privacy note
            // on `frontmostBundleID`). The event's TARGET pid is thread-safe
            // and more accurate than NSWorkspace's frontmost snapshot.
            if shortcut != nil {
                frontmostBundleID = bundleID(forTargetOf: event)
            }
        case .flagsChanged:
            // Only the press edge (flags gained), not the release.
            let flags = event.flags
            let gained = flags.rawValue & ~previousFlags.rawValue
            previousFlags = flags
            let modifierBits: UInt64 = CGEventFlags.maskCommand.rawValue
                | CGEventFlags.maskShift.rawValue
                | CGEventFlags.maskAlternate.rawValue
                | CGEventFlags.maskControl.rawValue
                | CGEventFlags.maskSecondaryFn.rawValue
            category = (gained & modifierBits) != 0 ? .modifier : nil
        default:
            category = nil
        }
        guard let category else { return }

        // THE point of this tracker: stamp the key with the moment the HARDWARE
        // reported it (`event.timestamp`), not the moment this callback ran.
        // Event-tap callbacks arrive asynchronously on the main run loop, so
        // reading the clock here records main-thread delivery latency on top of
        // every keystroke — which is exactly what made typing sounds lag behind
        // the typing while cursor clicks (sampled, not delivered) stayed exact.
        let timestamp = clock.timelineTime(forEventTimestamp: event.timestamp)
        events.append(KeystrokeEvent(
            timestamp: timestamp, category: category,
            shortcut: shortcut, frontmostBundleID: frontmostBundleID
        ))
    }

    /// Bundle id of the process the event was delivered TO, cached per pid so
    /// the tap callback stays cheap. `eventTargetUnixProcessID` is readable
    /// from any thread, unlike NSWorkspace's frontmost snapshot.
    private var bundleIDByPID: [pid_t: String?] = [:]
    private func bundleID(forTargetOf event: CGEvent) -> String? {
        let pid = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
        guard pid > 0 else { return nil }
        if let cached = bundleIDByPID[pid] { return cached }
        let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        bundleIDByPID[pid] = id
        return id
    }

    // MARK: - Shortcut identity (opt-in)

    /// Display string for a keyDown that qualifies as a SHORTCUT — at least
    /// one of ⌘/⌃/⌥ held (⇧ alone is typing) — else nil, and the key's
    /// identity is discarded exactly like the default path.
    static func shortcutDisplay(keyCode: Int64, flags: CGEventFlags) -> String? {
        let hasCommand = flags.contains(.maskCommand)
        let hasControl = flags.contains(.maskControl)
        let hasOption = flags.contains(.maskAlternate)
        guard hasCommand || hasControl || hasOption else { return nil }
        guard let key = keyGlyph(forKeyCode: keyCode) else { return nil }
        var out = ""
        // Canonical macOS modifier order: ⌃ ⌥ ⇧ ⌘.
        if hasControl { out += "⌃" }
        if hasOption { out += "⌥" }
        if flags.contains(.maskShift) { out += "⇧" }
        if hasCommand { out += "⌘" }
        return out + key
    }

    /// ANSI-US keycode → display glyph. Letters/digits by physical key (the
    /// convention every shortcut visualizer uses); nil for keys that have no
    /// sensible badge (media keys, unknown codes).
    static func keyGlyph(forKeyCode keyCode: Int64) -> String? {
        switch keyCode {
        case 0: return "A"; case 1: return "S"; case 2: return "D"; case 3: return "F"
        case 4: return "H"; case 5: return "G"; case 6: return "Z"; case 7: return "X"
        case 8: return "C"; case 9: return "V"; case 11: return "B"; case 12: return "Q"
        case 13: return "W"; case 14: return "E"; case 15: return "R"; case 16: return "Y"
        case 17: return "T"; case 18: return "1"; case 19: return "2"; case 20: return "3"
        case 21: return "4"; case 22: return "6"; case 23: return "5"; case 24: return "="
        case 25: return "9"; case 26: return "7"; case 27: return "-"; case 28: return "8"
        case 29: return "0"; case 30: return "]"; case 31: return "O"; case 32: return "U"
        case 33: return "["; case 34: return "I"; case 35: return "P"; case 37: return "L"
        case 38: return "J"; case 39: return "'"; case 40: return "K"; case 41: return ";"
        case 42: return "\\"; case 43: return ","; case 44: return "/"; case 45: return "N"
        case 46: return "M"; case 47: return "."; case 50: return "`"
        case 36, 76: return "↩"; case 48: return "⇥"; case 49: return "␣"
        case 51: return "⌫"; case 117: return "⌦"; case 53: return "⎋"
        case 123: return "←"; case 124: return "→"; case 125: return "↓"; case 126: return "↑"
        case 115: return "↖"; case 119: return "↘"; case 116: return "⇞"; case 121: return "⇟"
        case 122: return "F1"; case 120: return "F2"; case 99: return "F3"; case 118: return "F4"
        case 96: return "F5"; case 97: return "F6"; case 98: return "F7"; case 100: return "F8"
        case 101: return "F9"; case 109: return "F10"; case 103: return "F11"; case 111: return "F12"
        default: return nil
        }
    }

    /// Coarse category from a keycode — the keycode itself is NOT stored.
    static func category(forKeyCode keyCode: Int64) -> KeystrokeEvent.Category {
        switch keyCode {
        case 49: return .space
        case 36, 76: return .return
        case 51, 117: return .delete
        default: return .key
        }
    }

    // MARK: - Harness seam

    /// Installs `clock` WITHOUT creating an event tap, so `--keysound-test` can
    /// feed a synthetic stream without ever touching the user's real keyboard
    /// (which `start()` would capture on a machine that has Input Monitoring).
    func prepareForTesting(clock: RecordingClock) {
        stop()
        events.removeAll()
        previousFlags = []
        bundleIDByPID.removeAll()
        self.clock = clock
    }
}
