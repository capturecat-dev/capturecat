import AppKit

// The app boots through an NSApplicationDelegate (CaptureCatAppDelegate); the
// SwiftUI App/Scene lifecycle shell was retired once the AppKit conversion
// landed. Historical note: the original Phase-1 failure was event routing —
// the bare NSHostingController window had no first responder, starving
// SwiftUI focus/.onKeyPress (space-to-play etc.). Fixed in
// EditorWindowController.

// P4 parity gate: `CaptureCat --preview-parity` renders the SwiftUI preview and
// the CA compositor from identical fixtures and reports per-pixel diffs.
// Never reached in a normal launch.
if CommandLine.arguments.contains("--preview-parity") {
    MainActor.assumeIsolated { PreviewParityHarness.run() }
}

// Inspector-column layout probe under the REAL hosting topology — repro tool
// for the in-app empty-pane bug. Never reached in a normal launch.
// URL capture pipeline: normalise -> load offscreen -> snapshot -> encode.
// Hits the network, so it is not part of the default gate sweep.
// Web-capture device-preset gate: proves Desktop/Tablet/Mobile presets render
// the layout viewport they claim against a media-query fixture page.
if WebCaptureHarness.isDeviceTestRequested {
    MainActor.assumeIsolated { WebCaptureHarness.runDeviceTest() }
}

if WebCaptureHarness.isRequested {
    MainActor.assumeIsolated { WebCaptureHarness.run() }
}

// Screen-recording permission diagnostic. Reports the bundle identity being
// checked alongside the result, so a TCC grant made under a DIFFERENT bundle id
// cannot be mistaken for this one.
if CaptureProbe.isRequested {
    MainActor.assumeIsolated { CaptureProbe.run() }
}

if CommandLine.arguments.contains("--inspector-probe") {
    MainActor.assumeIsolated { InspectorProbeHarness.run() }
}

// CCKit dialog probe: topology, entrance motion mid-flight, click-through.
// Never reached in a normal launch.
if CommandLine.arguments.contains("--capalert-shot") {
    MainActor.assumeIsolated { CCAlertHarness.run() }
}

// CCKit structured-dialog probe: content rows must resolve real frames.
// Never reached in a normal launch.
if CommandLine.arguments.contains("--capdialog-shot") {
    MainActor.assumeIsolated { CCAlertHarness.runDialog() }
}

// Draw On build-effect test: partial trim mid-flight, exit un-draw, other
// effects untrimmed. Never reached in a normal launch.
if CommandLine.arguments.contains("--drawon-test") {
    DrawOnHarness.run()
}

// Shortcut-overlay acceptance test: privacy filter, legacy keys.json compat,
// repeat/fade math mid-flight, preview-vs-export pill pixel parity.
if CommandLine.arguments.contains("--keystroke-overlay-test") {
    KeystrokeOverlayHarness.run()
}

// CCKit gallery probe: every component's topology, live dark/light theme
// swap, and toggle motion mid-flight. Never reached in a normal launch.
if CommandLine.arguments.contains("--capkit-shot") {
    MainActor.assumeIsolated { CCKitGalleryHarness.run() }
}

// Default-screenshot-tool diagnostics: permission state, tap creation, and
// the stored setting — each link in the ⇧⌘3/4/5 chain, printed and exiting.
if CommandLine.arguments.contains("--screenshot-hotkey-probe") {
    MainActor.assumeIsolated { ScreenshotHotkeys.probe() }
}

// Settings window probe: sidebar/pane topology, pane switching, a control
// write-through (restored), and the live dark/light recolor.
if CommandLine.arguments.contains("--settings-shot") {
    MainActor.assumeIsolated { SettingsShotHarness.run() }
}

// LIVE menu hover probe: real window, real menu overhanging it, REAL system
// cursor warped across every row (production hover polls the cursor, so this
// is the exact shipping path). Briefly moves the mouse; restores it after.
if CommandLine.arguments.contains("--menu-hover-live") {
    MainActor.assumeIsolated { CCMenuHoverProbe.runLive() }
}

// Menu hover probe: the gliding highlight must land on every hovered row.
// Never reached in a normal launch.
if CommandLine.arguments.contains("--menu-hover-probe") {
    MainActor.assumeIsolated { CCMenuHoverProbe.run() }
}

// Direct-manipulation probe: synthetic drag on an annotation must track the
// pointer 1:1 at several padding values. Never reached in a normal launch.
if CommandLine.arguments.contains("--annotation-drag-probe") {
    MainActor.assumeIsolated { AnnotationDragProbe.run() }
}

// VIDEO-track editing-math acceptance test: shared VideoTrackEditMath vs a
// verbatim oracle of the pre-extraction in-view code. Gate for the native
// canvas row port. Never reached in a normal launch.
if CommandLine.arguments.contains("--videotrack-math-test") {
    VideoTrackMathHarness.run()
}

// Keyboard-sound acceptance checks (persistence, determinism, track render).
// Never reached in a normal launch.
if CommandLine.arguments.contains("--keysound-test") {
    KeySoundHarness.run()
}

// Click PIPELINE probe: runs synthetic 60Hz cursor events (with a pressed
// interval) through the exact chain the editor applies — CursorSpringMath —
// and counts the discrete clicks that survive. The visual/audio harnesses
// feed events straight to the compositor/controller, so the spring chain is
// otherwise untested. Never reached in a normal launch.
if CommandLine.arguments.contains("--clickpipeline-probe") {
    var events: [CursorEvent] = []
    for i in 0..<180 {  // 3s at 60Hz, gentle diagonal motion
        let t = Double(i) / 60
        let pressed = (t >= 1.0 && t <= 1.08) || (t >= 2.0 && t <= 2.06)
        events.append(CursorEvent(
            timestamp: t, x: 100 + t * 40, y: 100 + t * 25, isClick: pressed))
    }
    let size = CGSize(width: 1280, height: 800)
    let raw = ClickRippleOverlay.discreteClickTimes(from: events, coordinateSize: size)
    let settings = ProjectSettings()  // cursorFluidEnabled defaults true
    let sprung = CursorSpringMath.apply(events: events, settings: settings)
    let after = ClickRippleOverlay.discreteClickTimes(from: sprung, coordinateSize: size)
    let sprungClickSamples = sprung.filter(\.isClick).count
    print("CLICKPIPE raw=\(raw.count) afterSpring=\(after.count) "
        + "springSamples=\(sprung.count) springClickSamples=\(sprungClickSamples)")
    exit(raw.count == after.count ? 0 : 1)
}

// Click DATA probe: runs every real project's recorded cursor events through
// the editor's exact chain (smooth? → spring → end behaviour) and reports how
// many discrete clicks exist raw vs. after the chain — the definitive answer
// to "ripples/sounds vanished in MY projects". Never reached in a normal launch.
if CommandLine.arguments.contains("--clickdata-probe") {
    let store = ProjectStore()
    store.loadAll()
    let fmt = ISO8601DateFormatter()
    for project in store.projects.sorted(by: { $0.createdAt > $1.createdAt }) {
        print("PROJECT \(fmt.string(from: project.createdAt)) \(String(format: "%.0fs", project.duration)) \(project.name)")
        guard let url = project.cursorDataURL,
              let rec = try? CursorTracker.loadRecording(from: url) else {
            print("CLICKDATA \(project.name): no cursor data")
            continue
        }
        let size = rec.coordinateSize
        let clickSamples = rec.events.filter(\.isClick).count
        let raw = ClickRippleOverlay.discreteClickTimes(from: rec.events, coordinateSize: size)
        let s = project.settings
        let smoothed = s.smoothCursor
            ? CursorSmoother(factor: s.smoothingFactor).smooth(events: rec.events)
            : rec.events
        var chained = CursorSpringMath.apply(events: smoothed, settings: s)
        chained = CursorEndBehaviorMath.apply(
            events: chained, trimEnd: project.effectiveTrimEnd,
            loopToStart: s.cursorLoopToStart, stopAtEnd: s.cursorStopAtEnd)
        let after = ClickRippleOverlay.discreteClickTimes(from: chained, coordinateSize: size)
        print("CLICKDATA \(project.name): clickSamples=\(clickSamples) rawDiscrete=\(raw.count) "
            + "afterChain=\(after.count) fluid=\(s.cursorFluidEnabled) smooth=\(s.smoothCursor) coord=\(size)")

        // Suspicious shape: presses recorded but every run judged a drag.
        // Dump each pressed run's duration + movement so the threshold can be
        // judged against real data instead of a guess.
        if raw.isEmpty, clickSamples > 0 {
            var start: CursorEvent?
            var lastPress: CursorEvent?
            var maxDist: CGFloat = 0
            var runs = 0
            for e in rec.events {
                if e.isClick {
                    if start == nil { start = e; maxDist = 0 }
                    if let s0 = start {
                        maxDist = max(maxDist, hypot(e.x - s0.x, e.y - s0.y))
                    }
                    lastPress = e
                } else if let s0 = start, let l = lastPress {
                    runs += 1
                    if runs <= 12 {
                        print(String(format: "  RUN t=%.2f dur=%.2fs moved=%.1fpx",
                                     s0.timestamp, l.timestamp - s0.timestamp, maxDist))
                    }
                    start = nil
                }
            }
            print("  RUNS total=\(runs)")
        }
    }
    exit(0)
}

// Click-sound audio probe: actually starts the AVAudioEngine and reports
// whether it is running (the play path swallows start failures by design, so
// a broken engine is otherwise invisible). Never reached in a normal launch.
if CommandLine.arguments.contains("--clicksound-probe") {
    ClickSoundPlayer.shared.play(volume: 0.7, style: .softTick)
    let state = ClickSoundPlayer.shared.probeState
    print("CLICKSOUND running=\(state.running) error=\(state.error ?? "none")")
    Thread.sleep(forTimeInterval: 0.4)   // let the tick actually sound
    exit(state.running ? 0 : 1)
}

// VOICE-track acceptance test: drives the native canvas row's mouse machine
// and asserts against a verbatim oracle of the pre-extraction SwiftUI block.
// `--shot <dir>` writes native/SwiftUI PNG pairs instead. Never reached in a
// normal launch.
if CommandLine.arguments.contains("--voicetrack-test") {
    MainActor.assumeIsolated { VoiceTrackHarness.run() }
}

// P6 recording-panel gate: renders the SwiftUI toolbar and its native AppKit
// twin side by side and captures matched PNGs per state. Never reached in a
// normal launch.
if CommandLine.arguments.contains("--recording-panel-shot") {
    MainActor.assumeIsolated { RecordingPanelHarness.run() }
}

// Recording hover gate: verifies the presentation layer is between source
// tabs and Mic → Audio during a real shared-wash transition.
if CommandLine.arguments.contains("--recording-hover-probe") {
    MainActor.assumeIsolated { RecordingPanelHarness.runHoverProbe() }
}

// Motion gate for the panel's phase/tab crossfade: drives the transitions
// frame-by-frame from the shared crossfade math and writes numbered PNGs so
// the choreography can be judged on real frames, not settled states
// (CLAUDE.md §3: static frames lie). Never reached in a normal launch.
if CommandLine.arguments.contains("--panel-motion-capture") {
    MainActor.assumeIsolated { RecordingPanelHarness.runMotionCapture() }
}

// LIVE-animation gate for the tab-switch crossfade: runs the real animated
// switch (real click events, animations NOT suppressed) and captures the CA
// PRESENTATION tree via CARenderer at ~30Hz — `cacheDisplay` renders model
// values and let two rounds of "double icons" ship. Never reached in a normal
// launch.
if CommandLine.arguments.contains("--panel-live-capture") {
    MainActor.assumeIsolated { RecordingPanelHarness.runLiveCapture() }
}

// URL-capture feedback gate: submits a deliberately slow localhost URL through
// the REAL Return-key path and asserts the row locks (spinner on, field/device/
// gear disabled) mid-flight and restores with an inline error afterwards.
// Never reached in a normal launch.
if CommandLine.arguments.contains("--url-spinner-probe") {
    MainActor.assumeIsolated { RecordingPanelHarness.runSpinnerProbe() }
}

// Chromium URL-capture gate: stubs the screenshot API with a local listener
// and asserts the wire shape (option → query params), that the returned PNG
// lands in the StillMovieWriter pipeline, and the inline signed-out / API
// error states. Never reached in a normal launch.
if CommandLine.arguments.contains("--remote-capture-probe") {
    MainActor.assumeIsolated { RecordingPanelHarness.runRemoteCaptureProbe() }
}

// P6 playback-extraction gate: drives a real EditorPlaybackController over a
// synthetic project and asserts every time-observer consumer still fires
// (click/key sounds, speed ramps, trim-end stop, camera sync). Never reached
// in a normal launch.
if CommandLine.arguments.contains("--playback-observer-test") {
    MainActor.assumeIsolated { PlaybackObserverHarness.run() }
}

// P6 shell-parity probe: SwiftUI EditorShellView vs the native
// EditorShellViewController at the same window size, matched PNGs + resolved
// frames. Never reached in a normal launch.
if CommandLine.arguments.contains("--editor-shell-shot") {
    MainActor.assumeIsolated { EditorShellProbeHarness.run() }
}

// De-SwiftUI-fication gate: renders each remaining SwiftUI rasterization
// source against its CoreGraphics replacement. Never reached in a normal
// launch.
if CommandLine.arguments.contains("--raster-golden") {
    MainActor.assumeIsolated { RasterGoldenHarness.run() }
}

// Browser UX probe: real ProjectBrowserViewController in an offscreen window,
// PNGs at wide + minimum sizes plus responsive-toolbar geometry assertions.
// Never reached in a normal launch.
if CommandLine.arguments.contains("--browser-shot") {
    MainActor.assumeIsolated { BrowserShotHarness.run() }
}

// Notes + reminders model gate: Codable round-trips of the Note record and
// the reminderDate field (including legacy project.json without the key),
// title derivation, and the reminder badge/date math. Never reached in a
// normal launch.
if CommandLine.arguments.contains("--notes-test") {
    MainActor.assumeIsolated {
    var failures = 0
    func expect(_ condition: Bool, _ label: String) {
        print("\(condition ? "PASS" : "FAIL") \(label)")
        if !condition { failures += 1 }
    }

    // Note round trip.
    let note = Note(text: "Remember the milk\nsecond line", sourceAppName: "Safari")
    note.reminderDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
    if let data = try? JSONEncoder().encode(note),
       let back = try? JSONDecoder().decode(Note.self, from: data) {
        expect(back.id == note.id, "note.id round-trips")
        expect(back.text == note.text, "note.text round-trips")
        expect(back.sourceAppName == "Safari", "note.sourceAppName round-trips")
        expect(back.reminderDate == note.reminderDate, "note.reminderDate round-trips")
        expect(back.title == "Remember the milk", "note.title derives from first line")
    } else {
        expect(false, "note encodes+decodes")
    }

    // Project reminderDate round trip.
    let project = Project(name: "Take 1", duration: 12)
    project.reminderDate = Date(timeIntervalSinceReferenceDate: 801_234_567)
    if let data = try? JSONEncoder().encode(project),
       let back = try? JSONDecoder().decode(Project.self, from: data) {
        expect(back.reminderDate == project.reminderDate, "project.reminderDate round-trips")
    } else {
        expect(false, "project encodes+decodes")
    }

    // Legacy project.json without reminderDate must still load (old projects
    // must always load), decoding to nil.
    if let data = try? JSONEncoder().encode(Project(name: "Old", duration: 3)),
       var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
        json.removeValue(forKey: "reminderDate")
        if let stripped = try? JSONSerialization.data(withJSONObject: json),
           let legacy = try? JSONDecoder().decode(Project.self, from: stripped) {
            expect(legacy.reminderDate == nil, "legacy project decodes with nil reminderDate")
        } else {
            expect(false, "legacy project decodes")
        }
    }

    // Badge + preset-date math.
    let now = Date()
    expect(ReminderCenter.badgeText(for: nil, now: now) == nil, "badgeText nil for no reminder")
    expect(ReminderCenter.badgeText(for: now.addingTimeInterval(-60), now: now) == nil,
           "badgeText nil for past reminder")
    expect(ReminderCenter.badgeText(for: now.addingTimeInterval(3 * 86400), now: now) == "in 3d",
           "badgeText 'in 3d'")
    expect(ReminderCenter.badgeText(for: now.addingTimeInterval(5 * 3600), now: now) == "in 5h",
           "badgeText 'in 5h'")
    let preset = ReminderCenter.reminderDate(daysFromNow: 3, now: now)
    let hour = Calendar.current.component(.hour, from: preset)
    expect(hour == 9 && preset > now, "preset lands at 9:00, in the future")

    // isStillCapture round-trips; legacy JSON without the key decodes false.
    let still = Project(name: "Shot", duration: StillMovieWriter.defaultDuration)
    still.isStillCapture = true
    if let data = try? JSONEncoder().encode(still),
       let back = try? JSONDecoder().decode(Project.self, from: data) {
        expect(back.isStillCapture, "project.isStillCapture round-trips")
    } else {
        expect(false, "still project encodes+decodes")
    }

    // Image classification: flag, legacy heuristic, and its exclusions.
    expect(still.isImageCapture, "flagged still classifies as image")
    let legacyStill = Project(name: "Old shot", duration: StillMovieWriter.defaultDuration)
    expect(legacyStill.isImageCapture, "legacy still (no cursor, default duration) classifies as image")
    let deviceTake = Project(
        name: "iPhone", duration: StillMovieWriter.defaultDuration, recordingSourceKind: .device)
    expect(!deviceTake.isImageCapture, "8s device take is NOT an image")
    let recording = Project(
        name: "Take", cursorDataURL: URL(fileURLWithPath: "/tmp/cursor.json"),
        duration: StillMovieWriter.defaultDuration)
    expect(!recording.isImageCapture, "8s recording with cursor data is NOT an image")
    let longTake = Project(name: "Long", duration: 42)
    expect(!longTake.isImageCapture, "42s cursorless take is NOT an image")

    // Type-filter predicate: (isNote, isImage) per filter.
    func included(_ filter: CaptureTypeFilter, note: Bool, image: Bool) -> Bool {
        filter.includes(isNote: note, isImage: image)
    }
    expect(included(.all, note: false, image: false)
        && included(.all, note: false, image: true)
        && included(.all, note: true, image: false), "filter .all includes everything")
    expect(included(.videos, note: false, image: false)
        && !included(.videos, note: false, image: true)
        && !included(.videos, note: true, image: false), "filter .videos → videos only")
    expect(!included(.images, note: false, image: false)
        && included(.images, note: false, image: true)
        && !included(.images, note: true, image: false), "filter .images → images only")
    expect(!included(.notes, note: false, image: false)
        && !included(.notes, note: false, image: true)
        && included(.notes, note: true, image: false), "filter .notes → notes only")
    expect(CaptureTypeFilter(rawValue: "videos") == .videos,
           "filter raw value is stable persistence identity")

    // Search-hit → playhead math (CaptureSearchSeek): best-frame pick and
    // the source→output mapping (trim clamp + speed region), the same
    // SpeedTimeMap conversion the share/deep-link paths use.
    let frames = [
        CaptureIndexFrame(time: 1, text: "alpha"),
        CaptureIndexFrame(time: 2, text: "alpha beta alpha"),
        CaptureIndexFrame(time: 3, text: "alpha alpha"),
        CaptureIndexFrame(time: 4, text: "gamma"),
    ]
    expect(CaptureSearchSeek.bestSourceTime(query: "alpha", frames: frames) == 2,
           "seek: most-hits frame wins, ties go earliest")
    expect(CaptureSearchSeek.bestSourceTime(query: "beta", frames: frames) == 2,
           "seek: single-hit frame found")
    expect(CaptureSearchSeek.bestSourceTime(query: "zzz", frames: frames) == nil,
           "seek: no match yields nil")

    // Trim-only project: trim 10…50, source 30 → output 20; matches inside
    // trimmed-away regions clamp to the nearest valid edge.
    let trimmed = Project(name: "Trimmed", duration: 60)
    trimmed.trimStart = 10
    trimmed.trimEnd = 50
    expect(abs(CaptureSearchSeek.outputTime(forSource: 30, project: trimmed) - 20) < 0.001,
           "seek: trim offsets source → output")
    expect(abs(CaptureSearchSeek.outputTime(forSource: 5, project: trimmed) - 0) < 0.001,
           "seek: pre-trim match clamps to 0")
    expect(abs(CaptureSearchSeek.outputTime(forSource: 58, project: trimmed) - 40) < 0.001,
           "seek: post-trim match clamps to the end")

    // Speed region: 2x over source 10…20 in a 0…30 take.
    // Output timeline: 0–10 @1x, 10–15 (the 2x span), 15–25.
    let sped = Project(name: "Sped", duration: 30)
    sped.speedRegions = [VideoSpeedRegion(startTime: 10, endTime: 20, speed: 2)]
    expect(abs(CaptureSearchSeek.outputTime(forSource: 15, project: sped) - 12.5) < 0.001,
           "seek: 2x region compresses source 15 → output 12.5")
    expect(abs(CaptureSearchSeek.outputTime(forSource: 25, project: sped) - 20) < 0.001,
           "seek: post-region source 25 → output 20")

    // Full pipeline through a trimmed project.
    expect(CaptureSearchSeek.seekOutputTime(query: "alpha", frames: frames, project: trimmed) == 0,
           "seek: pipeline (best frame at source 2, clamped into trim) → 0")
    expect(CaptureSearchSeek.timestampLabel(161) == "2:41", "seek: timestamp label 2:41")

    // Onboarding deep links for the new steps must parse.
    expect(OnboardingViewController.notificationSettingsURL != nil,
           "onboarding notification-settings deep link parses")
    expect(OnboardingViewController.keyboardSettingsURL != nil,
           "onboarding keyboard-settings deep link parses")

    // SF Symbol existence audit. `NSImage(systemSymbolName:)` returns nil
    // SILENTLY for an unknown name → blank icon in shipping UI, so every
    // symbol name used anywhere in the app is asserted here on this Mac.
    // Compatibility floor: deployment target is macOS 14.0 = SF Symbols 5.
    // Audited 2026-08 against Apple's SF Symbols release notes — the newest
    // symbols in use are `book.pages` and `pencil.and.scribble`, both
    // introduced in SF Symbols 5 (macOS 14), so no runtime fallbacks are
    // needed. Any NEW symbol added to the app must be appended here, and if
    // it is newer than SF Symbols 5 it must ship with an explicit `??`
    // fallback at the call site (see InspectorColumnAppKit for the pattern).
    let usedSymbols = [
        "arrow.clockwise", "arrow.counterclockwise", "arrow.down.circle.fill",
        "arrow.down.right.and.arrow.up.left", "arrow.down.to.line",
        "arrow.left.to.line", "arrow.right.circle.fill", "arrow.right.to.line",
        "arrow.triangle.2.circlepath", "arrow.up.right", "arrow.up.to.line",
        "arrow.uturn.backward", "arrow.uturn.forward", "backward.end.fill",
        "battery.100", "bell.badge", "bell.fill", "book.pages", "bubble.left",
        "camera.fill", "captions.bubble", "checkmark", "checkmark.circle.fill",
        "checkmark.seal", "checkmark.shield.fill", "chevron.down",
        "chevron.left", "chevron.right", "chevron.up.chevron.down",
        "circle.fill", "circle.lefthalf.filled", "cursorarrow.rays",
        "doc.on.clipboard", "exclamationmark.circle.fill",
        "exclamationmark.triangle.fill", "eye.slash", "eye.slash.fill",
        "figure.walk.motion", "film", "film.stack", "forward.end.fill",
        "gauge.with.needle", "gearshape", "hand.tap", "iphone", "keyboard",
        "mic.fill", "mic.slash", "minus.magnifyingglass", "note.text",
        "pause.fill", "pencil.and.scribble", "pencil.tip",
        "person.crop.circle", "person.crop.circle.badge.checkmark",
        "photo.badge.plus", "pin.fill", "play.fill", "plus",
        "plus.magnifyingglass", "record.circle", "rectangle.dashed",
        "rectangle.inset.filled.badge.record",
        "rectangle.portrait.and.arrow.forward", "rectangle.split.2x1",
        "rotate.3d", "seal.fill", "shield.checkerboard", "sidebar.left",
        "sidebar.right", "slider.horizontal.3", "sparkle.magnifyingglass",
        "sparkles.rectangle.stack", "speaker.slash", "speaker.slash.fill",
        "speaker.wave.2", "speaker.wave.2.fill", "square.fill.on.square",
        "square.grid.2x2", "square.grid.2x2.fill", "stop.fill", "text.bubble",
        "trash.fill", "wand.and.stars", "waveform.and.mic",
    ]
    for name in usedSymbols {
        expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil,
               "SF symbol exists: \(name)")
    }

    print(failures == 0 ? "NOTES-TEST OK" : "NOTES-TEST FAILED (\(failures))")
    exit(failures == 0 ? 0 : 1)
    }
}

// Capture-search gate: index record Codable round-trip (embedding-ready,
// legacy JSON without new keys must load), the token AND-matching truth
// table, ranking order (title hits before text hits, text hits by count),
// and an end-to-end OCR of a synthetic rendered image — Vision runs
// headless. Never reached in a normal launch.
if CommandLine.arguments.contains("--search-test") {
    MainActor.assumeIsolated {
    var failures = 0
    func expect(_ condition: Bool, _ label: String) {
        print("\(condition ? "PASS" : "FAIL") \(label)")
        if !condition { failures += 1 }
    }

    // 1. Index record Codable round-trip, embedding populated and nil.
    let frame = CaptureIndexFrame(time: 4.5, text: "Stripe invoice #1042")
    var record = CaptureIndexRecord(
        id: UUID(),
        sourceModifiedAt: Date(timeIntervalSinceReferenceDate: 750_000_000),
        frames: [frame],
        fullText: "Stripe invoice #1042",
        embedding: [0.25, -0.5, 1.0]
    )
    if let data = try? JSONEncoder().encode(record),
       let back = try? JSONDecoder().decode(CaptureIndexRecord.self, from: data) {
        expect(back.id == record.id, "record.id round-trips")
        expect(back.sourceModifiedAt == record.sourceModifiedAt, "record.sourceModifiedAt round-trips")
        expect(back.frames.count == 1 && back.frames[0].time == 4.5
            && back.frames[0].text == frame.text, "record.frames round-trip")
        expect(back.fullText == record.fullText, "record.fullText round-trips")
        expect(back.embedding == [0.25, -0.5, 1.0], "record.embedding round-trips")
    } else {
        expect(false, "record encodes+decodes")
    }
    record.embedding = nil
    if let data = try? JSONEncoder().encode(record),
       let back = try? JSONDecoder().decode(CaptureIndexRecord.self, from: data) {
        expect(back.embedding == nil, "nil embedding round-trips as nil")
    } else {
        expect(false, "record without embedding encodes+decodes")
    }
    // Legacy/foreign index JSON without the optional keys must still load.
    let legacyJSON = #"{"id":"11111111-2222-3333-4444-555555555555","fullText":"hello"}"#
    if let legacy = try? JSONDecoder().decode(
        CaptureIndexRecord.self, from: Data(legacyJSON.utf8)) {
        expect(legacy.fullText == "hello" && legacy.frames.isEmpty && legacy.embedding == nil,
               "legacy record without frames/embedding decodes")
    } else {
        expect(false, "legacy record decodes")
    }

    // 2. Token AND-matching truth table (case/diacritic-insensitive).
    typealias R = CaptureSearchRanking
    let body = "Your Stripe invoice #1042 is ready.\nWhatsApp — Joshua: see you at the café"
    expect(R.matches(query: "stripe invoice", in: body), "AND: both tokens present matches")
    expect(R.matches(query: "STRIPE", in: body), "case-insensitive match")
    expect(R.matches(query: "cafe", in: body), "diacritic-insensitive match (cafe ~ café)")
    expect(R.matches(query: "whatsapp joshua", in: body), "tokens match across lines")
    expect(!R.matches(query: "stripe refund", in: body), "AND: one missing token fails")
    expect(!R.matches(query: "", in: body), "empty query matches nothing")
    expect(!R.matches(query: "   ", in: body), "whitespace query matches nothing")
    expect(R.hitCount(query: "invoice", in: "invoice invoice invoice") == 3, "hitCount counts occurrences")
    if let snip = R.snippet(query: "joshua", in: body) {
        expect(snip.contains("joshua"), "snippet contains the hit")
        expect(!snip.contains("\n"), "snippet is one line")
    } else {
        expect(false, "snippet produced for a hit")
    }

    // 3. Ranking: title matches first (input order), then text matches by
    // descending hit count.
    let a = R.Candidate(id: UUID(), title: "Stripe demo", text: "nothing relevant")
    let b = R.Candidate(id: UUID(), title: "Recording 7", text: "stripe stripe stripe")
    let c = R.Candidate(id: UUID(), title: "Recording 8", text: "one stripe here")
    let d = R.Candidate(id: UUID(), title: "Unrelated", text: "no hits at all")
    let ranked = R.rank(query: "stripe", candidates: [c, b, d, a])
    expect(ranked.count == 3, "ranking drops non-matches")
    expect(ranked.first?.candidate.id == a.id, "title match ranks first")
    expect(ranked.count == 3 && ranked[1].candidate.id == b.id && ranked[2].candidate.id == c.id,
           "text matches ordered by hit count")
    expect(ranked.first.map { $0.titleMatched } == true
        && ranked.dropFirst().allSatisfy { !$0.titleMatched }, "titleMatched flags are correct")
    // bestFrameTime picks the frame with the most hits.
    let framed = R.Candidate(
        id: UUID(), title: "x",
        text: "stripe\nstripe stripe",
        frames: [CaptureIndexFrame(time: 2, text: "stripe"),
                 CaptureIndexFrame(time: 6, text: "stripe stripe")])
    expect(R.rank(query: "stripe", candidates: [framed]).first?.bestFrameTime == 6,
           "bestFrameTime is the frame with most hits")

    // 4. End-to-end OCR of a synthetic image: render text into a CGImage,
    // OCR it with the real Vision path, assert the words come back.
    let width = 800, height = 240
    if let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) {
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let nsContext = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext
        ("Stripe Invoice 1042" as NSString).draw(
            at: NSPoint(x: 60, y: 80),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 56, weight: .semibold),
                .foregroundColor: NSColor.black,
            ])
        NSGraphicsContext.restoreGraphicsState()
        if let image = ctx.makeImage() {
            let text = CaptureTextIndex.recognizeText(in: image)
            let folded = CaptureSearchRanking.normalize(text)
            expect(folded.contains("stripe"), "OCR recovers 'stripe' from synthetic image")
            expect(folded.contains("invoice"), "OCR recovers 'invoice' from synthetic image")
            expect(folded.contains("1042"), "OCR recovers '1042' from synthetic image")
            expect(CaptureSearchRanking.matches(query: "stripe invoice", in: text),
                   "OCR output AND-matches 'stripe invoice'")
        } else {
            expect(false, "synthetic image renders")
        }
    } else {
        expect(false, "CGContext for synthetic image")
    }

    print(failures == 0 ? "SEARCH-TEST OK" : "SEARCH-TEST FAILED (\(failures))")
    exit(failures == 0 ? 0 : 1)
    }
}

// Preview↔export geometry gate: output size/aspect, uniform canvas scale and
// camera-bubble parity across (source aspect × aspect setting × resolution ×
// window size) combos. Never reached in a normal launch.
if CommandLine.arguments.contains("--export-geometry-test") {
    ExportGeometryHarness.run()
}

// Image | Video treatment gate for still captures: stillTreatment Codable
// round-trip + legacy default, the timeless-timeline derivation and pinned
// scale, full-span VIDEO block geometry, and a real headless PNG export of a
// fixture still verified structurally. Never reached in a normal launch.
if CommandLine.arguments.contains("--still-image-test") {
    StillImageHarness.run()
}

// Auto Zoom acceptance gate: synthetic 60Hz cursor/keystroke fixtures encode
// the shipped failure modes (ping-pong, re-zoom instead of pan, lone-click
// zoom, edge letterbox crop, clobbered manual regions) and assert on the
// generated plan. Never reached in a normal launch.
// Camera release gate: after a zoom+tilt block ends, zoom/offset/tilt must
// spring back to the centred rest framing (pure-math settle bounds at 60/30 Hz
// + a structural card-position check on the real compositor). Never reached in
// a normal launch.
if CommandLine.arguments.contains("--camera-settle-test") {
    CameraSettleHarness.run()
}

if CommandLine.arguments.contains("--autozoom-test") {
    AutoZoomHarness.run()
}

// Camera layout acceptance gate: mode resolution, cameraOnly/sideBySide rect
// geometry (including the preview↔export scale-invariance contract),
// camera-less degradation, and region Codable. Never reached in a normal
// launch.
if CommandLine.arguments.contains("--cameralayout-test") {
    CameraLayoutHarness.run()
}

// Export throughput benchmark: synthetic fixture → full VideoExporter pass →
// wall time / encoded fps / ×realtime. For comparing two builds on the same
// machine, not for quoting absolute numbers. Never reached in a normal launch.
if CommandLine.arguments.contains("--export-bench") {
    ExportBenchHarness.run()
}

// Desktop auth acceptance test: PKCE generation, RFC 8252 redirect-URI
// validation, the loopback listener's full lifecycle (bind → 404 → one-shot
// callback → teardown, plus timeout/cancel/port-conflict) and the Keychain
// round trip — no browser, no identity provider, no Worker required. Never
// reached in a normal launch.
if AuthSelfTest.isRequested {
    AuthSelfTest.run()
}

MainActor.assumeIsolated {
    let delegate = CaptureCatAppDelegate()
    let app = NSApplication.shared
    app.delegate = delegate
    app.run()
}
