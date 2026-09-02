import CoreGraphics
import CoreMedia
import Foundation

/// The ONE clock every recording-time tracker reads.
///
/// Everything the editor overlays on a take — cursor samples, click ripples,
/// keystroke sounds — has to land on the same timeline as the video, whose
/// frame PTS are `sampleHostTime − sharedOrigin` (see
/// `ScreenRecorder.sharedOriginHostTime`). That only holds if every tracker
/// agrees on (a) which clock "now" comes from, (b) where t = 0 is, and
/// (c) how much paused wall time to subtract.
///
/// Historically each tracker owned a private copy of that bookkeeping, so a
/// divergence in any one of the three silently skewed one input stream against
/// the others. `AppState` now creates a single instance per take and hands the
/// SAME object to `CursorTracker` and `KeystrokeTracker`: origin and pause
/// state are shared storage, not two things that happen to be kept equal.
///
/// There is deliberately no second way to ask for the time — `now()` and
/// `hostTimeSeconds(forEventTimestamp:)` are the only entry points, and both
/// resolve to `CMClockGetHostTimeClock()` seconds.
final class RecordingClock: @unchecked Sendable {
    /// Host-clock seconds — the identical basis the recorders anchor frame PTS
    /// to. Never `Date()` (wall clock, jumps on NTP/DST) and never
    /// `CACurrentMediaTime()` (same numbers today, but a different documented
    /// contract).
    static func now() -> Double {
        CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
    }

    /// Sanity window for a hardware event timestamp: a real event happened at
    /// most this long before it was delivered to us, and never in the future.
    /// Generous on purpose: the two candidate readings are ~42× apart, so any
    /// window discriminates them, and a wide one means even a pathological
    /// run-loop stall still resolves to the real keypress instead of falling
    /// back to delivery time.
    private static let maxPlausibleDeliveryLatency: Double = 30.0
    private static let maxPlausibleClockSkew: Double = 0.05

    private let lock = NSLock()
    private var origin: Double
    private var pauseStartHostTime: Double?
    private var accumulatedPause: Double = 0

    init(originHostTimeSeconds: Double? = nil) {
        origin = originHostTimeSeconds ?? RecordingClock.now()
    }

    // MARK: - Origin / pause bookkeeping

    var originHostTimeSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return origin
    }

    var isPaused: Bool {
        lock.lock(); defer { lock.unlock() }
        return pauseStartHostTime != nil
    }

    var accumulatedPauseSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return accumulatedPause
    }

    /// Re-anchors the clock for a new take. Pass the recorder's shared origin so
    /// tracker t = 0 is exactly the video's t = 0.
    func restart(originHostTimeSeconds: Double?) {
        lock.lock(); defer { lock.unlock() }
        origin = originHostTimeSeconds ?? RecordingClock.now()
        pauseStartHostTime = nil
        accumulatedPause = 0
    }

    /// Idempotent — every tracker may call it; the first call wins. That is what
    /// lets `AppState` keep symmetric per-tracker call sites without the two
    /// trackers ever accumulating different pause totals.
    func pause(at hostTime: Double? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard pauseStartHostTime == nil else { return }
        pauseStartHostTime = hostTime ?? RecordingClock.now()
    }

    /// Idempotent counterpart to `pause`.
    func resume(at hostTime: Double? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard let start = pauseStartHostTime else { return }
        accumulatedPause += max(0, (hostTime ?? RecordingClock.now()) - start)
        pauseStartHostTime = nil
    }

    // MARK: - Timeline mapping

    /// Timeline seconds for something that happened at `hostTime`.
    ///
    /// Paused wall time is removed, matching the recorder (which writes no
    /// frames while paused). While paused the timeline is frozen at the pause
    /// instant, so a straggling event delivered mid-pause can never jump ahead
    /// of the video.
    func timelineTime(forHostTime hostTime: Double) -> Double {
        lock.lock(); defer { lock.unlock() }
        let effective = pauseStartHostTime.map { min(hostTime, $0) } ?? hostTime
        return max(0, effective - origin - accumulatedPause)
    }

    /// Timeline seconds for "right now" — the polling-tracker entry point.
    func timelineTimeNow() -> Double {
        timelineTime(forHostTime: RecordingClock.now())
    }

    /// Timeline seconds for a `CGEvent`, taken from the event's OWN hardware
    /// timestamp rather than from whenever the run loop got around to handing
    /// it to us. Event-tap callbacks are delivered asynchronously on the main
    /// run loop; sampling the clock inside the callback records delivery
    /// latency, not the keypress.
    func timelineTime(forEventTimestamp raw: CGEventTimestamp) -> Double {
        timelineTime(forHostTime: RecordingClock.hostTimeSeconds(forEventTimestamp: raw))
    }

    // MARK: - CGEvent timestamp → host clock

    /// Converts a `CGEventTimestamp` to host-clock seconds.
    ///
    /// The field is documented as "nanoseconds since startup" but on Apple
    /// silicon it carries mach-absolute UNITS (1 tick ≈ 41.67ns at the 125/3
    /// timebase); on the old 1:1 timebase the two readings coincide. Rather
    /// than bake in an assumption that is wrong by ~42× on one of the two, we
    /// take whichever reading lands in a plausible window just behind `now`.
    /// A missing/implausible stamp (synthetic events post as 0) falls back to
    /// `now`, i.e. to the old delivery-time behaviour, never to a wild value.
    static func hostTimeSeconds(
        forEventTimestamp raw: CGEventTimestamp,
        now: Double = RecordingClock.now()
    ) -> Double {
        guard raw != 0 else { return now }
        func plausible(_ candidate: Double) -> Bool {
            candidate <= now + maxPlausibleClockSkew
                && candidate >= now - maxPlausibleDeliveryLatency
        }
        let machUnits = CMTimeGetSeconds(CMClockMakeHostTimeFromSystemUnits(raw))
        if plausible(machUnits) { return machUnits }
        let nanoseconds = Double(raw) / 1_000_000_000
        if plausible(nanoseconds) { return nanoseconds }
        return now
    }

    /// Inverse of the mach-units reading — harness-only, so a test can forge an
    /// event timestamp for a chosen host time.
    static func eventTimestamp(forHostTimeSeconds hostTime: Double) -> CGEventTimestamp {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let nanos = hostTime * 1_000_000_000
        let units = nanos * Double(info.denom) / Double(info.numer)
        return CGEventTimestamp(max(0, units.rounded()))
    }
}
