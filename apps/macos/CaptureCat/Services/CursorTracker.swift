import Foundation
import AppKit
import ScreenCaptureKit
import CoreMedia

@Observable
final class CursorTracker {
    private(set) var events: [CursorEvent] = []
    private var timer: Task<Void, Never>?
    /// Timeline origin + pause bookkeeping, SHARED with KeystrokeTracker (same
    /// object, not a matching copy) so cursor and keyboard cannot drift apart.
    private var clock: RecordingClock?
    private var coordinateMapper: ((CGPoint) -> CGPoint)?
    /// Returns false when the mouse is outside the captured display/area —
    /// those samples (and their clicks) are skipped entirely.
    private var pointFilter: ((CGPoint) -> Bool)?
    private var targetWindowPID: pid_t = 0
    private var targetWindowID: CGWindowID = 0
    /// Live frame of the captured window (top-left space) — refreshed every
    /// tick so cursor mapping stays correct when the window moves.
    private var liveWindowFrame: CGRect = .zero
    private var coordinateSize: CGSize = .zero
    /// What the recorder actually captured. For a window this is the
    /// SHADOW-FREE content rect, which is smaller than `SCWindow.frame` — and
    /// mapping against `frame` instead is what put every recorded position up
    /// and to the left of the pixels it described.
    private var capturedContentRect: CGRect?
    /// True between monitored left-mouse down/up — OR-ed with the polled
    /// button state so a press can never fall between two sampler ticks.
    private var monitorPressed = false
    private var clickMonitors: [Any] = []

    var isTracking: Bool { timer != nil }

    func start(
        for source: CaptureSource? = nil,
        clock: RecordingClock,
        capturedContentRect: CGRect? = nil
    ) {
        events.removeAll()
        self.clock = clock
        self.capturedContentRect = capturedContentRect
        configureCoordinateMapping(for: source)
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16)) // ~60Hz
                guard let self else { break }
                if self.clock?.isPaused ?? true { continue }
                self.recordCurrentPosition()
            }
        }

        // Clicks are captured EVENT-DRIVEN, not just polled. The 60Hz loop
        // above hops through the main actor, and when recording keeps the main
        // thread busy its ticks stretch past a typical 50–100ms press — which
        // is how whole recordings ended up with a smooth cursor path (the
        // fluid resim hides sparse positions) but almost no click flags, and
        // therefore no ripples and no click sounds. A mouse-down cannot be
        // missed by a monitor; each edge also records a sample immediately so
        // even a press shorter than one polling period lands in the stream.
        monitorPressed = false
        let handle: (Bool) -> Void = { [weak self] down in
            guard let self else { return }
            self.monitorPressed = down
            if !(self.clock?.isPaused ?? true) { self.recordCurrentPosition() }
        }
        clickMonitors = [
            NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { _ in handle(true) },
            NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { _ in handle(false) },
            NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { e in handle(true); return e },
            NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { e in handle(false); return e },
        ].compactMap { $0 }
    }

    func start() {
        start(for: nil, clock: RecordingClock())
    }

    /// Pauses the SHARED clock (idempotent) — KeystrokeTracker.pause() does the
    /// identical thing to the identical object.
    func pause() {
        clock?.pause()
    }

    func resume() {
        clock?.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        for monitor in clickMonitors { NSEvent.removeMonitor(monitor) }
        clickMonitors.removeAll()
        monitorPressed = false
    }

    func save(to url: URL) throws {
        let recording = CursorRecording(
            version: 2,
            coordinateWidth: coordinateSize.width,
            coordinateHeight: coordinateSize.height,
            events: events
        )
        let data = try JSONEncoder().encode(recording)
        try data.write(to: url)
    }

    static func load(from url: URL) throws -> [CursorEvent] {
        try loadRecording(from: url).events
    }

    static func loadRecording(from url: URL) throws -> CursorRecording {
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(CursorRecording.self, from: data)
        } catch {
            if let events = try? JSONDecoder().decode([CursorEvent].self, from: data) {
                return CursorRecording(
                    version: 1,
                    coordinateWidth: 0,
                    coordinateHeight: 0,
                    events: events
                )
            }
            throw error
        }
    }

    private func recordCurrentPosition(atHostTime hostTime: Double = RecordingClock.now()) {
        guard let clock else { return }

        // For window recording: only record when the mouse is inside the target
        // window AND that window is the topmost window under the cursor — if the
        // user switches to another app in front, their clicks belong to that
        // app, not the (unchanged) captured window behind it.
        if targetWindowID != 0 {
            let mouseLocation = NSEvent.mouseLocation
            let mouseTopLeft = topLeftGlobalPoint(from: mouseLocation)

            // One front-to-back walk gives both the live target bounds and the
            // topmost normal window at the cursor.
            guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
                return
            }

            var targetRect: CGRect?
            var topmostHitID: CGWindowID?
            for entry in windowList {
                guard let number = entry[kCGWindowNumber as String] as? CGWindowID,
                      let boundsAny = entry[kCGWindowBounds as String] else { continue }
                var rect = CGRect.zero
                CGRectMakeWithDictionaryRepresentation(boundsAny as! NSDictionary as CFDictionary, &rect)

                if number == targetWindowID {
                    targetRect = rect
                }
                let layer = entry[kCGWindowLayer as String] as? Int ?? 0
                if topmostHitID == nil, layer == 0, rect.width > 1, rect.height > 1, rect.contains(mouseTopLeft) {
                    topmostHitID = number
                }
                if targetRect != nil && topmostHitID != nil { break }
            }

            guard let targetRect, targetRect.width > 0, targetRect.height > 0 else {
                return // Window gone — skip
            }

            // Use the current window-server bounds for the live origin. SCK's
            // screenRect arrives asynchronously and can trail a window drag by
            // one frame; the fixed coordinateSize still comes from SCK's first
            // cropped frame, and mapWindowPoint scales current bounds into it.
            liveWindowFrame = targetRect

            guard targetRect.contains(mouseTopLeft), topmostHitID == targetWindowID else {
                return // Mouse outside the window, or another window is in front
            }
        }

        let mouseLocation = NSEvent.mouseLocation
        // Only record while the cursor is on the captured screen/area —
        // movement and clicks on other displays don't belong in the recording.
        if let pointFilter, !pointFilter(mouseLocation) { return }
        let mappedPoint = coordinateMapper?(mouseLocation) ?? legacyMappedPoint(from: mouseLocation)
        // Monitored state first — the poll alone missed clicks whenever the
        // main actor ran late (see the monitor installation in start()).
        let isClicking = monitorPressed || NSEvent.pressedMouseButtons & 1 != 0
        // A polled sample: the moment we read the position IS the moment it
        // describes, so "now" is the correct observation time here. (The
        // keystroke tracker cannot do this — its events are delivered late, so
        // it stamps from the event's own hardware time instead.)
        let timestamp = clock.timelineTime(forHostTime: hostTime)

        let event = CursorEvent(
            timestamp: timestamp,
            x: max(0, min(mappedPoint.x, coordinateSize.width)),
            y: max(0, min(mappedPoint.y, coordinateSize.height)),
            isClick: isClicking
        )
        events.append(event)
    }

    private func configureCoordinateMapping(for source: CaptureSource?) {
        pointFilter = nil
        targetWindowPID = 0
        targetWindowID = 0
        liveWindowFrame = .zero
        guard let source else {
            coordinateMapper = { [weak self] mouseLocation in
                self?.legacyMappedPoint(from: mouseLocation) ?? .zero
            }
            coordinateSize = .zero
            return
        }

        switch source {
        case .display(let display):
            targetWindowPID = 0
            targetWindowID = 0
            guard let screen = screen(for: display.displayID) else {
                coordinateMapper = { [weak self] mouseLocation in
                    self?.legacyMappedPoint(from: mouseLocation) ?? .zero
                }
                coordinateSize = .zero
                return
            }
            let frame = screen.frame
            coordinateSize = frame.size
            pointFilter = { frame.contains($0) }
            coordinateMapper = { mouseLocation in
                CGPoint(
                    x: mouseLocation.x - frame.minX,
                    y: frame.maxY - mouseLocation.y
                )
            }

        case .window(let window):
            // Prefer the rect the capture really produced; fall back to the
            // window frame only when the recorder could not supply one.
            let scFrame = capturedContentRect ?? window.frame
            let targetPID = window.owningApplication?.processID ?? 0
            let windowID = window.windowID
            let desktopBounds = globalDesktopBounds()

            print("[CursorTracker] Window SCFrame: \(scFrame) (size: \(scFrame.size))")
            print("[CursorTracker] Window: '\(window.title ?? "")' pid=\(targetPID)")
            print("[CursorTracker] Desktop bounds for window mapping: \(desktopBounds)")

            coordinateSize = scFrame.size
            self.targetWindowPID = targetPID
            self.targetWindowID = windowID
            self.liveWindowFrame = scFrame

            // SCWindow.frame is in a top-left global coordinate space, unlike
            // NSEvent.mouseLocation. Convert the mouse into the same top-left
            // desktop space first, then normalize against the LIVE window frame
            // so coordinates stay correct after the window is moved.
            coordinateMapper = { [weak self] mouseLocation in
                let live = self?.liveWindowFrame ?? .zero
                let frame = live.isEmpty ? scFrame : live
                let outputSize = self?.coordinateSize ?? scFrame.size
                let mouseTopLeft = CGPoint(
                    x: mouseLocation.x,
                    y: desktopBounds.maxY - mouseLocation.y
                )
                return Self.mapWindowPoint(
                    mouseTopLeft,
                    from: frame,
                    to: outputSize
                )
            }

        case .iosDevice:
            // No Mac cursor on an iOS device screen — never record events.
            targetWindowPID = 0
            targetWindowID = 0
            coordinateSize = .zero
            coordinateMapper = nil
            pointFilter = { _ in false }

        case .area(let display, let rect):
            guard let screen = screen(for: display.displayID) else {
                coordinateMapper = { [weak self] mouseLocation in
                    self?.legacyMappedPoint(from: mouseLocation) ?? .zero
                }
                coordinateSize = .zero
                return
            }

            let screenFrame = screen.frame
            // The selection rect is already in display points (AreaDragView maps
            // view points → SCDisplay points, which are 1:1) — no Retina scaling.
            let areaRectInPoints = rect
            coordinateSize = areaRectInPoints.size
            pointFilter = { mouseLocation in
                let displayX = mouseLocation.x - screenFrame.minX
                let displayY = screenFrame.maxY - mouseLocation.y
                return areaRectInPoints.contains(CGPoint(x: displayX, y: displayY))
            }
            coordinateMapper = { mouseLocation in
                let displayX = mouseLocation.x - screenFrame.minX
                let displayY = screenFrame.maxY - mouseLocation.y
                return CGPoint(
                    x: displayX - areaRectInPoints.minX,
                    y: displayY - areaRectInPoints.minY
                )
            }
        }
    }

    private func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first(where: {
            guard let screenNumber = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                return false
            }
            return screenNumber == displayID
        })
    }

    private func legacyMappedPoint(from mouseLocation: CGPoint) -> CGPoint {
        let screenHeight = NSScreen.main?.frame.height ?? 0
        return CGPoint(
            x: mouseLocation.x,
            y: screenHeight - mouseLocation.y
        )
    }

    private func topLeftGlobalPoint(from mouseLocation: CGPoint) -> CGPoint {
        CGPoint(
            x: mouseLocation.x,
            y: globalDesktopBounds().maxY - mouseLocation.y
        )
    }

    /// The CG (top-left) global space that SCWindow frames and
    /// CGWindowListCopyWindowInfo bounds live in has y = 0 at the top of the
    /// PRIMARY display — not at the top of the tallest arrangement. Using the
    /// union of all screens shifts every cursor sample on multi-monitor setups
    /// where a display sits above the primary.
    private func globalDesktopBounds() -> CGRect {
        guard let primary = NSScreen.screens.first else { return .zero }
        return primary.frame
    }

    private static func mapWindowPoint(
        _ point: CGPoint,
        from liveFrame: CGRect,
        to coordinateSize: CGSize
    ) -> CGPoint {
        let sx = liveFrame.width > 0 ? coordinateSize.width / liveFrame.width : 1
        let sy = liveFrame.height > 0 ? coordinateSize.height / liveFrame.height : 1
        return CGPoint(
            x: (point.x - liveFrame.minX) * sx,
            y: (point.y - liveFrame.minY) * sy
        )
    }

    static func mapWindowPointForTesting(
        _ point: CGPoint,
        from liveFrame: CGRect,
        to coordinateSize: CGSize
    ) -> CGPoint {
        mapWindowPoint(point, from: liveFrame, to: coordinateSize)
    }

    // MARK: - Harness seam

    /// Installs `clock` WITHOUT starting the 60Hz sampler, so `--keysound-test`
    /// can feed a deterministic synthetic stream through the real stamping path.
    func prepareForTesting(clock: RecordingClock) {
        stop()
        events.removeAll()
        self.clock = clock
        configureCoordinateMapping(for: nil)
    }

    /// Records one sample as if it had been observed at `hostTime`.
    func ingestSampleForTesting(hostTime: Double) {
        recordCurrentPosition(atHostTime: hostTime)
    }
}
