import AppKit

/// Headless acceptance test for the shortcut overlay:
///
///   CaptureCat --keystroke-overlay-test
///
/// Asserts the four ways this feature could quietly break:
///  • privacy — plain typing (no ⌘/⌃/⌥) must NEVER produce a shortcut string;
///  • persistence — new events round-trip, and OLD keys.json (no `shortcut`
///    key) still decodes (enum raw values / formats are persistence identity);
///  • math — repeat collapsing and fade phases, including a MID-FADE sample
///    that is strictly between 0 and 1 (the "static frames only" failure mode);
///  • parity — the preview's cached pill raster and the exporter's full-canvas
///    burn produce the same pixels at the same math-computed rect. The two
///    sides share drawPill, and this proves the sharing actually holds
///    end-to-end (offsets, flips, raster scale).
enum KeystrokeOverlayHarness {
    static func run() -> Never {
        setbuf(stdout, nil)
        var failures: [String] = []
        func check(_ ok: Bool, _ label: String) {
            print("KEYOVERLAY \(ok ? "ok" : "FAIL") \(label)")
            if !ok { failures.append(label) }
        }

        // — privacy filter —
        check(KeystrokeTracker.shortcutDisplay(keyCode: 1, flags: []) == nil,
              "plain letter stores nothing")
        check(KeystrokeTracker.shortcutDisplay(keyCode: 1, flags: .maskShift) == nil,
              "shift-only typing stores nothing")
        check(KeystrokeTracker.shortcutDisplay(keyCode: 1, flags: [.maskCommand, .maskShift]) == "⇧⌘S",
              "⌘⇧S renders in canonical order")
        check(KeystrokeTracker.shortcutDisplay(keyCode: 6, flags: .maskCommand) == "⌘Z",
              "⌘Z renders")
        check(KeystrokeTracker.shortcutDisplay(keyCode: 999, flags: .maskCommand) == nil,
              "unknown keycode stores nothing")

        // — persistence —
        let events = [
            KeystrokeEvent(timestamp: 1.0, category: .key, shortcut: "⌘Z"),
            KeystrokeEvent(timestamp: 1.4, category: .key, shortcut: "⌘Z"),
            KeystrokeEvent(timestamp: 5.0, category: .key, shortcut: "⌘⇥"),
            KeystrokeEvent(timestamp: 6.0, category: .space),
        ]
        do {
            let data = try JSONEncoder().encode(KeystrokeRecording(version: 1, events: events))
            let decoded = try JSONDecoder().decode(KeystrokeRecording.self, from: data)
            check(decoded.events == events, "new format round-trips")
        } catch { check(false, "new format round-trips (threw)") }
        do {
            let legacy = Data(#"{"version":1,"events":[{"timestamp":2.5,"category":"key"}]}"#.utf8)
            let decoded = try JSONDecoder().decode(KeystrokeRecording.self, from: legacy)
            check(decoded.events == [KeystrokeEvent(timestamp: 2.5, category: .key)],
                  "legacy keys.json (no shortcut field) still loads")
        } catch { check(false, "legacy keys.json still loads (threw)") }

        // — app scoping (window recordings) —
        let mixed = [
            KeystrokeEvent(timestamp: 1.0, category: .key, shortcut: "⌘S", frontmostBundleID: "com.apple.dt.Xcode"),
            KeystrokeEvent(timestamp: 2.0, category: .key, shortcut: "⌘K", frontmostBundleID: "com.tinyspeck.slackmacgap"),
            KeystrokeEvent(timestamp: 3.0, category: .key, shortcut: "⌘Z"), // legacy: no app identity
        ]
        let scoped = KeystrokeOverlayMath.scopedEvents(
            mixed, recordedAppBundleID: "com.apple.dt.Xcode",
            scopeToRecordedApp: true, sourceKind: .window)
        check(scoped.map(\.shortcut) == ["⌘S", "⌘Z"],
              "window scope drops other-app shortcuts, keeps legacy nil-app events")
        check(KeystrokeOverlayMath.scopedEvents(
                  mixed, recordedAppBundleID: "com.apple.dt.Xcode",
                  scopeToRecordedApp: false, sourceKind: .window).count == 3,
              "toggle off keeps everything")
        check(KeystrokeOverlayMath.scopedEvents(
                  mixed, recordedAppBundleID: "com.apple.dt.Xcode",
                  scopeToRecordedApp: true, sourceKind: .display).count == 3,
              "display recordings never scope")
        check(KeystrokeOverlayMath.scopedEvents(
                  mixed, recordedAppBundleID: nil,
                  scopeToRecordedApp: true, sourceKind: .window).count == 3,
              "unknown recorded app never scopes")
        do {
            let legacy = Data(#"{"version":1,"events":[{"timestamp":1,"category":"key","shortcut":"⌘Z"}]}"#.utf8)
            let decoded = try JSONDecoder().decode(KeystrokeRecording.self, from: legacy)
            check(decoded.events.first?.frontmostBundleID == nil,
                  "shortcut-era keys.json (no app field) still loads")
        } catch { check(false, "shortcut-era keys.json still loads (threw)") }

        // — math: repeat collapsing + phases —
        let display = KeystrokeOverlayMath.displayEvents(from: events)
        check(display.map(\.text) == ["⌘Z", "⌘Z ×2", "⌘⇥"],
              "rapid repeat collapses to ×2, gap resets, non-shortcut skipped")
        let midFade = KeystrokeOverlayMath.activePill(
            displayEvents: display,
            currentTime: 1.4 + KeystrokeOverlayMath.fadeIn + KeystrokeOverlayMath.hold
                + KeystrokeOverlayMath.fadeOut / 2
        )
        check((midFade.map { $0.alpha > 0.05 && $0.alpha < 0.95 }) == true,
              "fade-out is mid-flight, not snapped (alpha=\(midFade?.alpha ?? -1))")
        check(KeystrokeOverlayMath.activePill(displayEvents: display, currentTime: 4.0) == nil,
              "pill is gone after its window")
        check(KeystrokeOverlayMath.activePill(displayEvents: display, currentTime: 0.5) == nil,
              "no pill before the first shortcut")

        // — animation styles: entry values must be MID-FLIGHT at entry 0.5,
        //   not snapped to either endpoint, and settled at entry 1 —
        let slideMid = KeystrokeOverlayMath.slideOffset(animation: .slideUp, entry: 0.5, scale: 1)
        check(slideMid > 0.5 && slideMid < 7.5, "slideUp offset is mid-flight (\(slideMid)pt)")
        check(KeystrokeOverlayMath.slideOffset(animation: .slideUp, entry: 1, scale: 1) == 0,
              "slideUp settles at 0 offset")
        check(KeystrokeOverlayMath.slideOffset(animation: .fade, entry: 0.5, scale: 1) == 0
                && KeystrokeOverlayMath.slideOffset(animation: .pop, entry: 0.5, scale: 1) == 0,
              "fade/pop never slide")
        let popStart = KeystrokeOverlayMath.popScale(animation: .pop, entry: 0)
        let popMid = KeystrokeOverlayMath.popScale(animation: .pop, entry: 0.5)
        check(abs(popStart - 0.85) < 0.001, "pop starts at 85% (\(popStart))")
        check(popMid != 1 && popMid != popStart, "pop scale is mid-flight (\(popMid))")
        check(KeystrokeOverlayMath.popScale(animation: .pop, entry: 1) == 1,
              "pop settles at exactly 1")
        check(KeystrokeOverlayMath.popScale(animation: .slideUp, entry: 0.5) == 1
                && KeystrokeOverlayMath.popScale(animation: .fade, entry: 0.5) == 1,
              "slideUp/fade never scale")

        // — parity: pillImage (preview path) vs full-canvas image (export path) —
        let canvas = CGSize(width: 640, height: 360)
        let time = 5.0 + KeystrokeOverlayMath.fadeIn + 0.2 // settled: alpha 1, entry 1
        let pill = KeystrokeOverlayMath.activePill(displayEvents: display, currentTime: time)
        check(pill?.alpha == 1 && pill?.entry == 1, "sample instant is settled")
        if let pill,
           let previewSide = KeystrokeOverlayRenderer.pillImage(
               text: pill.text, size: 1.0, scale: 1, rasterScale: 1),
           let exportSide = KeystrokeOverlayRenderer.image(
               canvasSize: canvas, displayEvents: display, currentTime: time,
               position: .bottomCenter, size: 1.0, scale: 1, rasterScale: 1) {
            let placed = KeystrokeOverlayMath.pillRect(
                position: .bottomCenter, canvasSize: canvas,
                pillSize: previewSide.size, entry: 1, scale: 1)
            let crop = CGRect(
                x: placed.minX, y: placed.minY,
                width: CGFloat(previewSide.image.width),
                height: CGFloat(previewSide.image.height)
            )
            // Export raster is y-flipped into CGImage space like the preview's.
            let cropped = exportSide.cropping(to: crop)
            let delta = meanDelta(previewSide.image, cropped)
            check(delta >= 0 && delta < 1.0, "preview/export pill pixels match (meanΔ=\(delta)/255)")
            // Structural guard: the pill actually contains ink, so a matching
            // pair of EMPTY images can't pass (the blind-mean failure mode).
            check(coverage(previewSide.image) > 0.2, "pill raster is non-empty")
        } else {
            check(false, "parity rasters produced")
        }

        print(failures.isEmpty ? "KEYOVERLAY PASS" : "KEYOVERLAY FAIL \(failures.count): \(failures.joined(separator: " | "))")
        exit(failures.isEmpty ? 0 : 1)
    }

    /// Mean absolute channel difference (0–255); -1 on shape mismatch.
    private static func meanDelta(_ a: CGImage, _ b: CGImage?) -> Double {
        guard let b, a.width == b.width, a.height == b.height,
              let pa = pixels(a), let pb = pixels(b), pa.count == pb.count else { return -1 }
        var total = 0.0
        for i in 0..<pa.count { total += Double(abs(Int(pa[i]) - Int(pb[i]))) }
        return total / Double(pa.count)
    }

    /// Fraction of pixels with any alpha — structural "there is ink here".
    private static func coverage(_ image: CGImage) -> Double {
        guard let px = pixels(image) else { return 0 }
        var hits = 0
        var i = 3
        while i < px.count { if px[i] > 8 { hits += 1 }; i += 4 }
        return Double(hits) / Double(px.count / 4)
    }

    private static func pixels(_ image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buf
    }
}
