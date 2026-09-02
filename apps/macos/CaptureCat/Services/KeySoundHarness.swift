import AVFoundation
import Foundation

/// `CaptureCat --keysound-test` — headless acceptance checks for keyboard sounds:
/// persistence round-trip, deterministic variation, category mapping, and
/// export-track rendering (density cap, event placement).
enum KeySoundHarness {
    /// Drives the tracker's REAL ingest path with a forged CGEvent whose
    /// hardware timestamp is `hostTime` — the point being that ingest happens
    /// now, seconds after the "keypress", so any tracker that stamps from the
    /// callback clock instead of the event fails the assertions below.
    private static func feedKeystroke(
        into tracker: KeystrokeTracker,
        hostTime: Double,
        virtualKey: CGKeyCode = 0
    ) {
        guard let event = CGEvent(
            keyboardEventSource: CGEventSource(stateID: .privateState),
            virtualKey: virtualKey,
            keyDown: true
        ) else { return }
        event.timestamp = RecordingClock.eventTimestamp(forHostTimeSeconds: hostTime)
        tracker.handle(type: .keyDown, event: event)
    }

    static func run() -> Never {
        var failures: [String] = []
        var checks = 0
        func expect(_ condition: Bool, _ label: String) {
            checks += 1
            if !condition { failures.append(label) }
        }

        // 1) Persistence round-trip
        let events: [KeystrokeEvent] = [
            .init(timestamp: 0.5, category: .key),
            .init(timestamp: 0.62, category: .space),
            .init(timestamp: 0.9, category: .return),
            .init(timestamp: 1.4, category: .modifier),
            .init(timestamp: 2.0, category: .delete),
        ]
        do {
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("keysound-test-\(UUID().uuidString).json")
            let data = try JSONEncoder().encode(KeystrokeRecording(version: 1, events: events))
            try data.write(to: url)
            let loaded = try KeystrokeTracker.loadRecording(from: url)
            expect(loaded.events == events, "round-trip equality")
            expect(loaded.version == 1, "round-trip version")
            // Privacy: the encoded JSON must contain ONLY timestamp/category.
            let json = String(data: data, encoding: .utf8) ?? ""
            expect(!json.contains("keyCode") && !json.contains("character"), "privacy: no key identity fields")
            try? FileManager.default.removeItem(at: url)
        } catch {
            failures.append("round-trip threw: \(error)")
        }

        // 2) Deterministic variation, bounds, category shaping
        let v1 = KeySoundPlayer.variation(timestamp: 1.234, category: .key)
        let v2 = KeySoundPlayer.variation(timestamp: 1.234, category: .key)
        expect(v1 == v2, "variation deterministic for same seed")
        let v3 = KeySoundPlayer.variation(timestamp: 1.235, category: .key)
        expect(v1 != v3, "variation differs across seeds")
        var pitches: [Double] = []
        for i in 0..<200 {
            let v = KeySoundPlayer.variation(timestamp: Double(i) * 0.0137, category: .key)
            pitches.append(v.pitch)
            expect(v.pitch >= 0.94 && v.pitch <= 1.06, "key pitch in ±6% (\(v.pitch))")
            expect(v.level >= 0.85 && v.level <= 1.15, "key level in ±15% (\(v.level))")
        }
        expect(Set(pitches.map { Int($0 * 1000) }).count > 20, "pitch actually varies")
        let space = KeySoundPlayer.variation(timestamp: 1.234, category: .space)
        expect(space.pitch < v1.pitch, "space deeper than key for same seed")
        let mod = KeySoundPlayer.variation(timestamp: 1.234, category: .modifier)
        expect(mod.level < v1.level, "modifier quieter than key for same seed")

        // 3) Category mapping
        expect(KeystrokeTracker.category(forKeyCode: 49) == .space, "keycode 49 = space")
        expect(KeystrokeTracker.category(forKeyCode: 36) == .return, "keycode 36 = return")
        expect(KeystrokeTracker.category(forKeyCode: 51) == .delete, "keycode 51 = delete")
        expect(KeystrokeTracker.category(forKeyCode: 0) == .key, "keycode 0 = key")

        // 4) Track rendering: placement + 1:1 density
        do {
            // 15 events 35ms apart — faster than any human types (28 keys/s).
            // Every one must produce its own onset: the old 50ms cap dropped
            // every other key of fast typing, which is audibly "missing keys".
            let dense = (0..<15).map { i in
                (outputTime: 1.0 + Double(i) * 0.035, seedTimestamp: Double(i), category: KeystrokeEvent.Category.key)
            }
            let url = try KeySoundPlayer.renderTrackWAV(events: dense, duration: 3.0, style: .thock)
            let file = try AVAudioFile(forReading: url)
            let expectedFrames = Int((3.0 + KeySoundPlayer.strokeDuration) * KeySoundPlayer.sampleRate)
            expect(abs(Int(file.length) - expectedFrames) < 64, "track length (\(file.length) vs \(expectedFrames))")

            let format = AVAudioFormat(standardFormatWithSampleRate: KeySoundPlayer.sampleRate, channels: 1)!
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buf)
            let data = UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength))

            func rms(around second: Double) -> Double {
                let start = max(0, Int(second * KeySoundPlayer.sampleRate))
                let end = min(data.count, start + Int(0.03 * KeySoundPlayer.sampleRate))
                guard end > start else { return 0 }
                var sum = 0.0
                for i in start..<end { sum += Double(data[i] * data[i]) }
                return (sum / Double(end - start)).squareRoot()
            }
            expect(rms(around: 1.0) > 0.01, "audio present at first event")
            expect(rms(around: 0.5) < 0.001, "silence before events")
            expect(rms(around: 2.5) < 0.001, "silence after events")

            // Count onsets. A thock's tail decays below the 0.05 threshold in
            // ~21ms (exp(-140t)·0.95 < 0.05), so 35ms-spaced strokes separate
            // cleanly: each stroke is one threshold crossing. 20ms refractory
            // rejects double-counts within a single attack.
            var onsets = 0
            var last = -1.0
            var i = 0
            while i < data.count {
                if abs(data[i]) > 0.05 {
                    let t = Double(i) / KeySoundPlayer.sampleRate
                    if t - last > 0.02 { onsets += 1; last = t }
                    i += Int(0.022 * KeySoundPlayer.sampleRate)
                } else {
                    i += 16
                }
            }
            expect(onsets == 15, "keystroke sounds are 1:1 — 15 events, 15 onsets (got \(onsets))")

            // Chords still merge: three same-millisecond keys render as ONE
            // clamped stroke, not a 3× louder clipped blast.
            let chord = (0..<3).map { i in
                (outputTime: 1.0, seedTimestamp: Double(i), category: KeystrokeEvent.Category.key)
            }
            let chordURL = try KeySoundPlayer.renderTrackWAV(events: chord, duration: 2.0, style: .thock)
            let chordFile = try AVAudioFile(forReading: chordURL)
            let chordBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chordFile.length))!
            try chordFile.read(into: chordBuf)
            let chordData = UnsafeBufferPointer(start: chordBuf.floatChannelData![0], count: Int(chordBuf.frameLength))
            var peak: Float = 0
            for s in chordData { peak = max(peak, abs(s)) }
            expect(peak <= 1.0, "chord stays clamped (peak \(peak))")
            try? FileManager.default.removeItem(at: chordURL)
            try? FileManager.default.removeItem(at: url)
        } catch {
            failures.append("track render threw: \(error)")
        }

        // 5) Clock basis: RecordingClock is the only time source, and it IS the
        // host clock the recorders anchor frame PTS to.
        do {
            let before = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
            let shared = RecordingClock.now()
            let after = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
            expect(
                shared >= before && shared <= after,
                "RecordingClock.now() reads CMClockGetHostTimeClock (Δ=\(shared - before)s)"
            )
        }

        // 6) CGEvent timestamp → host seconds, under BOTH documented readings.
        // The field is spec'd as "nanoseconds since startup" but carries
        // mach-absolute UNITS on Apple silicon (~42× apart). Misreading it is a
        // catastrophic, not subtle, skew — so both encodings must resolve.
        do {
            let now = RecordingClock.now()
            let moment = now - 1.25
            let machRaw = RecordingClock.eventTimestamp(forHostTimeSeconds: moment)
            let machResolved = RecordingClock.hostTimeSeconds(forEventTimestamp: machRaw, now: now)
            expect(abs(machResolved - moment) < 0.001,
                   "mach-units event stamp resolves (Δ=\((machResolved - moment) * 1000)ms)")

            let nanoRaw = CGEventTimestamp((moment * 1_000_000_000).rounded())
            let nanoResolved = RecordingClock.hostTimeSeconds(forEventTimestamp: nanoRaw, now: now)
            expect(abs(nanoResolved - moment) < 0.001,
                   "nanosecond event stamp resolves (Δ=\((nanoResolved - moment) * 1000)ms)")

            expect(RecordingClock.hostTimeSeconds(forEventTimestamp: 0, now: now) == now,
                   "unstamped event falls back to now")
            expect(RecordingClock.hostTimeSeconds(forEventTimestamp: 1, now: now) == now,
                   "implausible stamp falls back to now, never to a wild value")
        }

        // 7) CROSS-TRACKER SYNC — the regression test for the bug this harness
        // exists to prevent. One shared clock, one synthetic stream of
        // SIMULTANEOUS cursor samples and keystrokes; both trackers must stamp
        // them identically within 1ms.
        //
        // The keystrokes are forged with a hardware timestamp in the PAST and
        // ingested now, i.e. with a large simulated event-tap delivery latency.
        // The old tracker read the clock inside its tap callback, so it recorded
        // the delivery moment and every key landed late; this check fails hard
        // if that ever comes back.
        do {
            let origin = RecordingClock.now() - 3.0
            let clock = RecordingClock(originHostTimeSeconds: origin)
            let cursor = CursorTracker()
            let keys = KeystrokeTracker()
            cursor.prepareForTesting(clock: clock)
            keys.prepareForTesting(clock: clock)

            let offsets: [TimeInterval] = [0.0, 0.4, 0.9, 1.6, 2.5]
            for offset in offsets {
                let hostTime = origin + offset
                cursor.ingestSampleForTesting(hostTime: hostTime)
                feedKeystroke(into: keys, hostTime: hostTime)
            }

            expect(cursor.events.count == offsets.count,
                   "cursor recorded every synthetic sample (\(cursor.events.count))")
            expect(keys.events.count == offsets.count,
                   "keystroke tracker recorded every synthetic key (\(keys.events.count))")
            if cursor.events.count == offsets.count && keys.events.count == offsets.count {
                for (i, offset) in offsets.enumerated() {
                    let delta = abs(cursor.events[i].timestamp - keys.events[i].timestamp)
                    expect(delta <= 0.001,
                           "simultaneous event \(i) agrees within 1ms (Δ=\(delta * 1000)ms)")
                    expect(abs(keys.events[i].timestamp - offset) <= 0.001,
                           "keystroke \(i) anchored to the KEYPRESS not the delivery "
                           + "(got \(keys.events[i].timestamp)s, want \(offset)s)")
                }
            }

            // Same OBJECT, not two matching copies: re-anchoring the clock has
            // to move BOTH trackers' timelines together. This is the assertion
            // that a future refactor giving each tracker its own origin would
            // trip on.
            clock.restart(originHostTimeSeconds: origin + 1.0)
            cursor.ingestSampleForTesting(hostTime: origin + 2.0)
            feedKeystroke(into: keys, hostTime: origin + 2.0)
            if let c = cursor.events.last, let k = keys.events.last {
                expect(abs(c.timestamp - 1.0) <= 0.001,
                       "cursor follows the re-anchored shared origin (\(c.timestamp)s)")
                expect(abs(k.timestamp - 1.0) <= 0.001,
                       "keystrokes follow the re-anchored shared origin (\(k.timestamp)s)")
                expect(abs(c.timestamp - k.timestamp) <= 0.001,
                       "both trackers re-anchor together (Δ=\(abs(c.timestamp - k.timestamp) * 1000)ms)")
            } else {
                failures.append("re-anchor produced no events")
            }
        }

        // 8) PAUSE SCENARIO — paused wall time must fall out of both timelines
        // identically, and neither tracker may record while paused.
        do {
            let origin = RecordingClock.now() - 4.0
            let clock = RecordingClock(originHostTimeSeconds: origin)
            let cursor = CursorTracker()
            let keys = KeystrokeTracker()
            cursor.prepareForTesting(clock: clock)
            keys.prepareForTesting(clock: clock)

            // Before the pause.
            cursor.ingestSampleForTesting(hostTime: origin + 0.5)
            feedKeystroke(into: keys, hostTime: origin + 0.5)

            // Pause at a known instant, then let BOTH trackers call pause() the
            // way AppState does. They share one clock, so the extra calls are
            // no-ops instead of a second (divergent) pause window — that
            // idempotence is what removes the "identical call sites" hazard.
            clock.pause(at: origin + 1.0)
            cursor.pause()
            keys.pause()
            expect(clock.isPaused, "shared clock is paused")

            // Mid-pause keystroke: dropped, not stamped into the frozen gap.
            feedKeystroke(into: keys, hostTime: origin + 1.5)
            expect(keys.events.count == 1, "keystrokes during a pause are dropped (\(keys.events.count))")

            // Resume at a known instant so the expected math is exact.
            clock.resume(at: origin + 2.0)
            keys.resume()   // idempotent — must not double-count
            cursor.resume() // idempotent — must not double-count
            expect(!clock.isPaused, "shared clock resumed")
            expect(abs(clock.accumulatedPauseSeconds - 1.0) < 0.001,
                   "exactly one 1.0s pause accumulated (\(clock.accumulatedPauseSeconds)s)")

            // After the resume both trackers must subtract the SAME pause.
            for offset in [3.0, 3.5] as [TimeInterval] {
                cursor.ingestSampleForTesting(hostTime: origin + offset)
                feedKeystroke(into: keys, hostTime: origin + offset)
            }
            expect(cursor.events.count == 3 && keys.events.count == 3,
                   "post-resume events recorded (cursor \(cursor.events.count), keys \(keys.events.count))")
            if cursor.events.count == 3 && keys.events.count == 3 {
                // Raw offset minus the 1.0s the recorder wrote no frames for.
                let expected: [TimeInterval] = [0.5, 2.0, 2.5]
                for i in 0..<3 {
                    let delta = abs(cursor.events[i].timestamp - keys.events[i].timestamp)
                    expect(delta <= 0.001,
                           "paused-take event \(i) agrees within 1ms (Δ=\(delta * 1000)ms)")
                    expect(abs(keys.events[i].timestamp - expected[i]) <= 0.001,
                           "paused-take event \(i) at \(expected[i])s (got \(keys.events[i].timestamp)s)")
                }
            }
        }

        if failures.isEmpty {
            print("KEYSOUND PASS (\(checks) checks)")
            exit(0)
        } else {
            print("KEYSOUND FAIL (\(failures.count)/\(checks)):")
            for f in failures.prefix(20) { print("  ✘ \(f)") }
            exit(1)
        }
    }
}
