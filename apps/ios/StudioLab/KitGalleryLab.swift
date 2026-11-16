import UIKit

/// `--kit-gallery <outDir>` (Studio 4a): every new house control — value
/// slider, choice chips, toggle (+ row), stepper, color well / picker, and
/// the dialog / confirmation sheet — in every state, in THIS real UIWindow
/// (the topology the app ships, CLAUDE.md §3), in both themes, written as PNGs.
///
/// Each page is built in dark, captured, re-themed LIVE to light (the
/// `ccOnThemeChange` path the app uses), captured again. Then the gate drives
/// the controls through their real touch / VoiceOver paths (probe seams that
/// call the same handlers) and asserts:
///   • structure — every dressed surface's material fits its bounds, every
///     control lies inside the window, 44 pt touch targets, VoiceOver labels,
///     values and traits, Dynamic Type growth, retheme reaches every surface;
///   • behaviour — discrete steps and detents with their haptics, tap-to-jump,
///     hold-to-repeat acceleration, chip selection, hex/HSB round trips;
///   • MOTION as SEQUENCES — filmstrips of the toggle, slider, stepper, chip
///     reflow and sheet entrance, with the animated value asserted MID-FLIGHT
///     (numerically from the presentation layer AND from the captured pixels),
///     growth overshoot with only the pushed edge moving — and the whole
///     mid-flight check is proven to FAIL once with `CCMotion.probeSnap`.
///
/// Output: <outDir>/{dark,light}/<page>.png, <outDir>/seq-*.png,
/// <outDir>/kit-gallery.txt. Lines start `KITGALLERY`; the last one is
/// `KITGALLERY SUMMARY PASS|FAIL`. Exit 0 on pass.
@MainActor
enum KitGalleryLab {
    /// The StudioLabApp hook: takes over when `--kit-gallery <dir>` is present.
    static func start(_ arguments: [String], lab: LabViewController) -> Bool {
        guard let i = arguments.firstIndex(of: "--kit-gallery"), arguments.indices.contains(i + 1) else { return false }
        lab.stage.isHidden = true
        let runner = KitGalleryRunner(lab: lab, out: URL(fileURLWithPath: arguments[i + 1], isDirectory: true))
        Task { @MainActor in await runner.run() }
        return true
    }
}

@MainActor
final class KitGalleryRunner {
    private let lab: LabViewController
    private let out: URL
    private var lines: [String] = []
    private var failures = 0
    private var window: UIWindow { lab.view.window! }
    private var device: String { lab.traitCollection.horizontalSizeClass == .regular ? "regular" : "compact" }

    init(lab: LabViewController, out: URL) {
        self.lab = lab
        self.out = out
    }

    // MARK: - Run

    func run() async {
        try? FileManager.default.createDirectory(at: out.appendingPathComponent("dark"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: out.appendingPathComponent("light"), withIntermediateDirectories: true)
        CCMotion.pace = .standard
        window.overrideUserInterfaceStyle = .dark
        await wait(0.6)
        log("KITGALLERY START device=\(device) window=\(Int(window.bounds.width))x\(Int(window.bounds.height)) scale=\(window.screen.scale) out=\(out.path)")

        await sliderPage()
        await chipsPage()
        await togglePage()
        await stepperPage()
        await colorPage()
        await dialogPages()

        log("KITGALLERY SUMMARY \(failures == 0 ? "PASS" : "FAIL") failures=\(failures) device=\(device)")
        try? lines.joined(separator: "\n").appending("\n").write(to: out.appendingPathComponent("kit-gallery.txt"), atomically: true, encoding: .utf8)
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Pages

    private func sliderPage() async {
        let padding = CCSlider(title: "Padding", value: 0.4)
        let blur = CCSlider(title: "Blur", value: 0.65)
        blur.symbol = CCIcon.has("sparkles") ? "sparkles" : nil
        let shadow = CCSlider(title: "Shadow", value: 3, range: 0...8, step: 1, format: { "\(Int($0))" })
        let speed = CCSlider(title: "Speed", value: 1, range: 0.5...4, format: { String(format: "%.2g×", $0) })
        speed.detents = [1]
        let held = CCSlider(title: "Opacity", value: 0.7)
        let disabled = CCSlider(title: "Tilt", value: 0.25)
        disabled.isEnabled = false
        let xl = CCSlider(title: "Volume", value: 0.5)
        let xlHost = UIView()
        xlHost.traitOverrides.preferredContentSizeCategory = .accessibilityLarge
        xlHost.addSubview(xl)
        pin(xl, in: xlHost)

        let content = column([
            section("Continuous · 0–100% readout", [padding, blur]),
            section("Discrete · the ticks are the stops", [shadow]),
            section("Detent at 1× (soft stop + haptic)", [speed]),
            section("Held (pill brightens, bar grows) · Disabled", [held, disabled]),
            section("Dynamic Type · accessibility large", [xlHost]),
        ])
        let page = mount(content, "slider")
        await wait(0.3)
        held.probeTrack(.began, x: held.probeX(for: 0.7))
        await wait(0.5)
        await captureThemes(page, "slider")

        // Ticks ARE the stops: 7 interior ticks, each under the bar's centre.
        let tickXs = shadow.probeTickFrames.map(\.midX)
        let stopXs = (1...7).map { shadow.probeX(for: Double($0)) }
        let tickError = zip(tickXs, stopXs).map { abs($0 - $1) }.max() ?? 99
        check("slider-ticks-are-stops", tickXs.count == 7 && tickError < 0.5,
              String(format: "ticks=%d (want 7) max |tick − stop|=%.2f pt", tickXs.count, tickError))
        check("slider-detent-mark", speed.probeDetentFrames.count == 1 && abs((speed.probeDetentFrames.first?.midX ?? 0) - speed.probeX(for: 1)) < 0.5,
              "the 1× detent shows one stronger tick under its stop")

        // Held: the bar is tall and the pill brightened.
        let heldBar = held.probeThumbLayer.bounds.height
        check("slider-held-grows", held.probeIsDragging && abs(heldBar - 28) < 0.5, String(format: "held bar height=%.1f (22 → 28)", heldBar))
        held.probeTrack(.cancelled, x: 0)

        // Dynamic Type: the XL title scales (to its cap) and still fits the pill.
        let xlTitle = xl.probeTitleFont, baseTitle = padding.probeTitleFont
        check("slider-dynamic-type", xlTitle.pointSize > baseTitle.pointSize + 2 && xl.bounds.height >= ceil(xlTitle.lineHeight) + 16,
              String(format: "accessibility-large title %.1f pt vs %.1f pt, pill %.0f pt fits it", xlTitle.pointSize, baseTitle.pointSize, xl.bounds.height))

        // Discrete drag: one selection haptic per stop, a detent at the end.
        shadow.setValue(0, animated: false)
        await wait(0.1)
        var commits = 0
        shadow.onCommit = { _ in commits += 1 }
        var visited: [Double] = []
        shadow.onChange = { visited.append($0) }
        CCHaptics.probeLog = []
        let x0 = shadow.probeX(for: 0)
        let stepWidth = shadow.probeX(for: 1) - x0
        shadow.probeTrack(.began, x: x0)
        for k in 1...8 { shadow.probeTrack(.moved, x: x0 + stepWidth * CGFloat(k)) }
        shadow.probeTrack(.ended, x: x0 + stepWidth * 8)
        let haptics = CCHaptics.probeLog ?? []
        check("slider-discrete-steps", visited == (1...8).map(Double.init) && shadow.value == 8,
              "visited \(visited.map { Int($0) }) → \(Int(shadow.value))")
        check("slider-discrete-haptics", haptics == Array(repeating: "selection", count: 7) + ["detent"],
              "haptics \(haptics) (7 steps + the end detent)")
        check("slider-commit-once", commits == 1, "onCommit fired \(commits)× for one drag")

        // Continuous through a detent: sticks at 1× for a stretch, one detent haptic.
        speed.setValue(0.5, animated: false)
        await wait(0.1)
        var speeds: [Double] = []
        speed.onChange = { speeds.append($0) }
        CCHaptics.probeLog = []
        let s0 = speed.probeX(for: 0.5), s1 = speed.probeX(for: 2)
        speed.probeTrack(.began, x: s0)
        var x = s0
        while x < s1 { x += 1; speed.probeTrack(.moved, x: x) }
        speed.probeTrack(.ended, x: x)
        let speedHaptics = CCHaptics.probeLog ?? []
        let stuck = speeds.filter { $0 == 1 }.count
        let stickMoves = Int(s1 - s0) - speeds.count   // moves that didn't change the value
        check("slider-detent-sticks", speedHaptics == ["detent"] && speeds.contains(1) && stickMoves >= 8 && speed.value > 1.9,
              "haptics \(speedHaptics), landed on 1× (\(stuck) change), held for \(stickMoves) pt of travel, ended \(String(format: "%.2f", speed.value))")

        // VoiceOver: adjustable, steps by the step; never steps OVER a detent.
        shadow.setValue(3, animated: false)
        shadow.accessibilityIncrement()
        speed.setValue(0.9, animated: false)
        speed.accessibilityIncrement()
        check("slider-voiceover-adjust", shadow.value == 4 && speed.value == 1,
              "shadow 3 → \(Int(shadow.value)) (step 1); speed 0.9 → \(speed.value) (lands on the 1× detent)")

        // Tap-to-jump springs: a FILMSTRIP, with the bar mid-flight in the
        // presentation layer AND in the captured pixels.
        padding.setValue(0.15, animated: false)
        await wait(0.2)
        let from = padding.probeX(for: 0.15), to = padding.probeX(for: 0.9)
        var mid: CGFloat = -1
        let frames = await filmstrip("seq-slider-tap", view: padding, count: 7, interval: 0.03) {
            padding.probeTrack(.began, x: to)
            padding.probeTrack(.ended, x: to)
        } sample: { t in
            if mid < 0, t > 0.03 { mid = (padding.probeThumbLayer.presentation() ?? padding.probeThumbLayer).position.x }
        }
        check("slider-tap-midflight", mid > from + 2 && mid < to - 2, String(format: "bar x from %.1f → %.1f, sampled %.1f", from, to, mid))
        let travel = padding.probeTravel
        let xs = frames.compactMap { whiteCentroidX($0.image, xRange: travel.origin...(travel.origin + travel.width)) }
        let pixelMid = xs.dropFirst().dropLast().contains { $0 > from + 2 && $0 < to - 2 }
        check("slider-tap-pixels-midflight", xs.count == frames.count && pixelMid,
              "captured bar x per frame " + xs.map { String(format: "%.0f", $0) }.joined(separator: " → "))

        await structuralChecks(page, "slider")
        unmount(page)
    }

    private func chipsPage() async {
        let pace = CCChipGroup(items: ["Snappy", "Smooth", "Slow glide", "Instant"], selected: [1])
        pace.accessibilityLabel = "Animation pace"
        let iconItems: [CCChipGroup.Item] = [("Arrow", "cursorarrow"), ("Camera", "camera"), ("Text", "textformat"), ("Sound", "speaker.wave.2")]
            .map { .init($0.0, symbol: CCIcon.has($0.1) ? $0.1 : nil) }
        let icons = CCChipGroup(items: iconItems, selected: [0])
        let lanes = CCChipGroup(items: ["Cursor", "Clicks", "Keys", "Camera"], mode: .multiple, selected: [0, 2])
        let quality = CCChipGroup(items: [.init("720p"), .init("1080p"), .init("4K", isEnabled: false)], selected: [1])
        let wrapped = CCChipGroup(items: ["16:9", "9:16", "1:1", "4:5", "4:3", "21:9", "Auto"], selected: [0])
        let narrow = UIView()
        narrow.addSubview(wrapped)
        wrapped.leadingAnchor.constraint(equalTo: narrow.leadingAnchor).isActive = true
        wrapped.topAnchor.constraint(equalTo: narrow.topAnchor).isActive = true
        wrapped.bottomAnchor.constraint(equalTo: narrow.bottomAnchor).isActive = true
        wrapped.widthAnchor.constraint(equalToConstant: 236).isActive = true
        // Compress-before-wrap: sized so the default padding overflows by a
        // little but the compressed padding fits on ONE line.
        let tight = CCChipGroup(items: ["Background", "Padding", "Shadow"], selected: [2])
        let tightContent = tight.probeChips.reduce(0) { $0 + $1.contentWidth } + CCChipGroup.hGap * 2
        let tightWidth = ceil(tightContent + 2 * 3 * 12)   // 12 pt per side: between min 10 and default 16
        let tightHost = UIView()
        tightHost.addSubview(tight)
        tight.leadingAnchor.constraint(equalTo: tightHost.leadingAnchor).isActive = true
        tight.topAnchor.constraint(equalTo: tightHost.topAnchor).isActive = true
        tight.bottomAnchor.constraint(equalTo: tightHost.bottomAnchor).isActive = true
        tight.widthAnchor.constraint(equalToConstant: tightWidth).isActive = true

        let content = column([
            section("Single choice", [pace]),
            section("With icons", [icons]),
            section("Multiple choice", [lanes]),
            section("Disabled option · pressed chip", [quality]),
            section("Wraps in a narrow column", [narrow]),
            section("Compresses padding before it wraps", [tightHost]),
        ])
        let page = mount(content, "chips")
        await wait(0.3)
        // Press shades take their ink at press time: re-press after each theme switch.
        await captureThemes(page, "chips") {
            quality.probeChips[0].isHighlighted = false
            quality.probeChips[0].isHighlighted = true
        }
        quality.probeChips[0].isHighlighted = false

        // Single choice: exactly one, haptic, traits follow.
        CCHaptics.probeLog = []
        var picked: Set<Int> = []
        pace.onChange = { picked = $0 }
        pace.probeTap(2)
        let selectedTraits = pace.probeChips.map { $0.accessibilityTraits.contains(.selected) }
        check("chips-single", pace.selection == [2] && picked == [2] && selectedTraits == [false, false, true, false] && (CCHaptics.probeLog ?? []) == ["selection"],
              "selection \(pace.selection.sorted()), .selected traits \(selectedTraits), haptics \(CCHaptics.probeLog ?? [])")
        pace.probeTap(2)
        check("chips-single-sticky", pace.selection == [2], "tapping the chosen chip keeps it (allowsEmpty = false)")
        lanes.probeTap(1)
        lanes.probeTap(0)
        check("chips-multiple", lanes.selection == [1, 2], "multiple: {0,2} +1 −0 → \(lanes.selection.sorted())")
        check("chips-compress-before-wrap", abs(tight.bounds.height - CCChip.height) < 0.5 && (tight.probeChips.first?.horizontalPadding ?? 16) < CCChip.defaultPadding,
              String(format: "one line (%.0f pt), padding %.0f pt (< %.0f)", tight.bounds.height, tight.probeChips.first?.horizontalPadding ?? -1, CCChip.defaultPadding))
        let lineCount = Set(wrapped.probeChips.map { Int($0.frame.minY) }).count
        let anyClipped = wrapped.probeChips.contains { $0.frame.maxX > wrapped.bounds.width + 0.5 }
        check("chips-wrap", lineCount >= 2 && !anyClipped, "\(lineCount) lines in 236 pt, none cut at the edge")

        // Growth: items added → the height bounces, only the BOTTOM edge moves.
        let topBefore = wrapped.convert(CGPoint.zero, to: window).y
        let h0 = wrapped.bounds.height
        var peak = h0, drift: CGFloat = 0, midSamples = 0
        var target: CGFloat = 0
        _ = await filmstrip("seq-chips-growth", view: narrow, count: 8, interval: 0.05) {
            wrapped.items += [.init("2.35:1"), .init("Custom"), .init("Square-ish")]
        } sample: { _ in
            let h = wrapped.bounds.height
            target = wrapped.probeHeightConstraint.constant
            peak = max(peak, h)
            drift = max(drift, abs(wrapped.convert(CGPoint.zero, to: self.window).y - topBefore))
        }
        for _ in 0..<40 {
            await wait(0.008)
            let h = wrapped.bounds.height
            if h > h0 + 1, abs(h - target) > 1 { midSamples += 1 }
            peak = max(peak, h)
        }
        await wait(0.4)
        let settled = wrapped.bounds.height
        check("chips-growth-overshoot", settled > h0 + 10 && peak > settled + 0.5,
              String(format: "height %.1f → peak %.1f → settled %.1f (bounce)", h0, peak, settled))
        check("chips-growth-top-pinned", drift < 0.5, String(format: "top edge drift %.2f pt (only the bottom moves)", drift))

        await structuralChecks(page, "chips")
        unmount(page)
    }

    private func togglePage() async {
        let off = CCToggle(isOn: false)
        let on = CCToggle(isOn: true)
        let pressedOff = CCToggle(isOn: false)
        let pressedOn = CCToggle(isOn: true)
        let disabledOff = CCToggle(isOn: false)
        let disabledOn = CCToggle(isOn: true)
        disabledOff.isEnabled = false
        disabledOn.isEnabled = false
        for (toggle, name) in [(off, "Off"), (on, "On"), (pressedOff, "Pressed off"), (pressedOn, "Pressed on"), (disabledOff, "Disabled off"), (disabledOn, "Disabled on")] {
            toggle.accessibilityLabel = name
        }
        let cells = [(off, "Off"), (on, "On"), (pressedOff, "Pressed"), (pressedOn, "Pressed"), (disabledOff, "Disabled"), (disabledOn, "Disabled")].map { toggle, caption -> UIView in
            let label = ccLabel(caption, font: CCFont.micro, color: CCTheme.color.mutedForeground, alignment: .center)
            let cell = UIStackView(arrangedSubviews: [toggle, label])
            cell.axis = .vertical
            cell.alignment = .center
            cell.spacing = 6
            return cell
        }
        let grid = UIStackView(arrangedSubviews: cells)
        grid.distribution = .equalSpacing
        grid.alignment = .top
        let cursor = CCToggleRow(title: "Show cursor", detail: "Draw the recorded pointer over the video.", isOn: true)
        let clicks = CCToggleRow(title: "Click sounds", isOn: false)
        let locked = CCToggleRow(title: "Motion blur", detail: "Needs a Pro plan.", isOn: false)
        locked.isEnabled = false
        let sequence = CCToggle(isOn: false)
        sequence.accessibilityLabel = "Sequence probe"
        let seqHost = UIView()
        seqHost.addSubview(sequence)
        NSLayoutConstraint.activate([
            sequence.leadingAnchor.constraint(equalTo: seqHost.leadingAnchor, constant: 8),
            sequence.topAnchor.constraint(equalTo: seqHost.topAnchor, constant: 8),
            sequence.bottomAnchor.constraint(equalTo: seqHost.bottomAnchor, constant: -8),
        ])

        let content = column([
            section("Toggle — off · on · pressed (stretch) · disabled", [grid]),
            section("Toggle rows (the whole row is the target)", [cursor, clicks, locked]),
            section("Motion probe", [seqHost]),
        ])
        let page = mount(content, "toggle")
        await wait(0.3)
        pressedOff.setStretched(true)
        pressedOn.setStretched(true)
        await wait(0.6)
        await captureThemes(page, "toggle")

        // Press stretch: only the PUSHED edge travels (sampled through the spring).
        let side = CCToggle.trackSize.height - 5
        pressedOff.setStretched(false)
        pressedOn.setStretched(false)
        await wait(0.6)
        var leftDrift: CGFloat = 0, rightDrift: CGFloat = 0, midWidth = false
        let restOff = pressedOff.probeThumbFrame(on: false, stretched: false)
        let restOn = pressedOn.probeThumbFrame(on: true, stretched: false)
        pressedOff.setStretched(true)
        pressedOn.setStretched(true)
        for _ in 0..<30 {
            await wait(0.01)
            let a = pressedOff.probeThumbLayer.presentation() ?? pressedOff.probeThumbLayer
            let b = pressedOn.probeThumbLayer.presentation() ?? pressedOn.probeThumbLayer
            leftDrift = max(leftDrift, abs((a.position.x - a.bounds.width / 2) - restOff.minX))
            rightDrift = max(rightDrift, abs((b.position.x + b.bounds.width / 2) - restOn.maxX))
            if a.bounds.width > side + 0.5, a.bounds.width < side + 6.5 { midWidth = true }
        }
        check("toggle-stretch-pushed-edge", leftDrift < 0.5 && rightDrift < 0.5 && midWidth,
              String(format: "resting edge drift off=%.2f on=%.2f pt; width seen mid-stretch=%@", leftDrift, rightDrift, midWidth ? "yes" : "NO"))
        pressedOff.setStretched(false)
        pressedOn.setStretched(false)

        // The thumb's spring across, as a filmstrip + presentation sample.
        let pass1 = await toggleSequence(sequence, name: "seq-toggle")
        check("toggle-thumb-midflight", pass1.numeric, pass1.detail)
        check("toggle-pixels-midflight", pass1.pixels, pass1.pixelDetail)

        // Injected defect: snapped springs must FAIL the very same assertions.
        CCMotion.probeSnap = true
        let snapped = await toggleSequence(sequence, name: "seq-toggle-injected-snap")
        CCMotion.probeSnap = false
        check("inject-snap-detected", !snapped.numeric && !snapped.pixels,
              "with probeSnap: numeric=\(snapped.numeric ? "PASSED (blind!)" : "failed") pixels=\(snapped.pixels ? "PASSED (blind!)" : "failed") — the gate can see a snap")

        // Row: the whole row toggles; VoiceOver value follows.
        var rowValue: Bool?
        clicks.onChange = { rowValue = $0 }
        clicks.sendActions(for: .touchUpInside)
        check("toggle-row", clicks.isOn && rowValue == true && clicks.accessibilityValue == "On" && clicks.toggle.isAccessibilityElement == false,
              "row tap → on, value \(clicks.accessibilityValue ?? "nil"), one VoiceOver element")
        locked.sendActions(for: .touchUpInside)
        check("toggle-disabled-inert", !locked.isOn && disabledOff.alpha < 0.5, "a disabled row ignores taps; disabled toggles dim")

        await structuralChecks(page, "toggle")
        unmount(page)
    }

    private struct SequenceResult {
        var numeric: Bool
        var pixels: Bool
        var detail: String
        var pixelDetail: String
    }

    private func toggleSequence(_ toggle: CCToggle, name: String) async -> SequenceResult {
        toggle.setOn(false, animated: false)
        await wait(0.5)
        let start = toggle.probeThumbFrame(on: false, stretched: false).midX
        let end = toggle.probeThumbFrame(on: true, stretched: false).midX
        var sampled: CGFloat = -1
        let frames = await filmstrip(name, view: toggle, count: 8, interval: 0.025) {
            toggle.userToggle()
        } sample: { t in
            if sampled < 0, t > 0.03 { sampled = (toggle.probeThumbLayer.presentation() ?? toggle.probeThumbLayer).position.x }
        }
        let numeric = sampled > start + 1 && sampled < end - 1
        let xs = frames.map { whiteCentroidX($0.image, xRange: 0...toggle.bounds.width) ?? -1 }
        let first = xs.first ?? -1, last = xs.last ?? -1
        let pixels = first > 0 && last > first + 8 && xs.dropFirst().dropLast().contains { $0 > first + 2 && $0 < last - 2 }
        await wait(0.6)
        return SequenceResult(
            numeric: numeric,
            pixels: pixels,
            detail: String(format: "thumb x %.1f → %.1f, presentation sample %.1f", start, end, sampled),
            pixelDetail: "captured thumb x per frame " + xs.map { String(format: "%.1f", $0) }.joined(separator: " → ")
        )
    }

    private func stepperPage() async {
        let fps = CCStepper(value: 30, min: 1, max: 120, step: 1)
        fps.format = { "\(Int($0)) fps" }
        let atMin = CCStepper(value: 0, min: 0, max: 10, step: 1)
        let atMax = CCStepper(value: 10, min: 0, max: 10, step: 1)
        let zoom = CCStepper(value: 1.5, min: 1, max: 3, step: 0.1)
        zoom.format = { String(format: "%.1f×", $0) }
        let disabled = CCStepper(value: 4, min: 0, max: 10, step: 1)
        disabled.isEnabled = false
        let pressed = CCStepper(value: 12, min: 0, max: 99, step: 1)
        let xl = CCStepper(value: 250, min: 0, max: 999, step: 1)
        let xlRow = CCControlRow(title: "Large text", control: xl)
        xlRow.traitOverrides.preferredContentSizeCategory = .accessibilityLarge
        let hold = CCStepper(value: 0, min: 0, max: 500, step: 1)

        let content = column([
            section("Stepper", [CCControlRow(title: "Frame rate", control: fps),
                                CCControlRow(title: "At minimum", detail: "− dims at the bound", control: atMin),
                                CCControlRow(title: "At maximum", control: atMax),
                                CCControlRow(title: "Zoom", detail: "step 0.1", control: zoom)]),
            section("Pressed key · disabled", [CCControlRow(title: "Pressed +", control: pressed),
                                               CCControlRow(title: "Disabled", control: disabled)]),
            section("Dynamic Type · accessibility large", [xlRow]),
            section("Hold probe", [CCControlRow(title: "Hold +", control: hold)]),
        ])
        let page = mount(content, "stepper")
        await wait(0.3)
        await captureThemes(page, "stepper") {
            CCMaterial.press(pressed.probeKeys.plus.layer, down: true, traits: pressed.traitCollection)
        }
        CCMaterial.press(pressed.probeKeys.plus.layer, down: false, traits: pressed.traitCollection)

        check("stepper-bounds-dim", !atMin.probeKeys.minus.isEnabled && atMin.probeKeys.plus.isEnabled
              && !atMax.probeKeys.plus.isEnabled && atMin.probeKeys.minus.alpha < 0.5,
              "at min − is disabled (alpha \(String(format: "%.2f", atMin.probeKeys.minus.alpha))); at max + is disabled")
        check("stepper-dynamic-type", xl.bounds.height > fps.bounds.height + 2,
              String(format: "accessibility-large stepper %.0f pt vs %.0f pt", xl.bounds.height, fps.bounds.height))

        // Tap: one step on release, the digits ROLL (sequence + mid-flight).
        CCHaptics.probeLog = []
        var rollY: CGFloat = -99
        var travelY: CGFloat = 0
        _ = await filmstrip("seq-stepper-roll", view: fps, count: 7, interval: 0.03) {
            fps.probeHold(plus: true, down: true)
            fps.probeHold(plus: true, down: false)
        } sample: { t in
            if rollY == -99, t > 0.03, let incoming = fps.probeLabel.lastIncoming.first {
                rollY = (incoming.presentation()?.value(forKeyPath: "transform.translation.y") as? CGFloat) ?? -98
                travelY = ceil(CCFont.monoValue(fps.traitCollection).lineHeight) * 0.9
            }
        }
        check("stepper-tap-step", fps.value == 31 && (CCHaptics.probeLog ?? []) == ["selection"],
              "30 → \(Int(fps.value)), haptics \(CCHaptics.probeLog ?? [])")
        check("stepper-roll-midflight", rollY > 0.5 && rollY < travelY - 0.5,
              String(format: "incoming digit translation.y=%.2f (rises from %.1f to 0)", rollY, travelY))

        // Hold: repeats after a beat and ACCELERATES.
        var stamps: [CFTimeInterval] = []
        let t0 = CACurrentMediaTime()
        hold.onChange = { _ in stamps.append(CACurrentMediaTime() - t0) }
        hold.probeHold(plus: true, down: true)
        await wait(1.5)
        hold.probeHold(plus: true, down: false)
        let gaps = zip(stamps.dropFirst(), stamps).map { $0 - $1 }
        let firstGap = gaps.first ?? 0, lastGap = gaps.last ?? 1
        check("stepper-hold-accelerates", stamps.count >= 8 && (stamps.first ?? 0) > 0.35 && lastGap < firstGap * 0.7 && hold.value == Double(stamps.count),
              String(format: "%d repeats in 1.5 s, first at %.2f s, gap %.3f → %.3f s, release added no extra step (%d)", stamps.count, stamps.first ?? -1, firstGap, lastGap, Int(hold.value)))

        // Reaching a bound: the firmer detent haptic, then the key dims.
        atMax.value = 9
        CCHaptics.probeLog = []
        atMax.probeHold(plus: true, down: true)
        atMax.probeHold(plus: true, down: false)
        check("stepper-bound-detent", atMax.value == 10 && (CCHaptics.probeLog ?? []) == ["detent"] && !atMax.probeKeys.plus.isEnabled,
              "9 → 10 fires \(CCHaptics.probeLog ?? []) and disables +")

        // VoiceOver: one adjustable element.
        zoom.accessibilityIncrement()
        check("stepper-voiceover", zoom.value == 1.6 && zoom.accessibilityValue == "1.6×" && zoom.accessibilityTraits.contains(.adjustable) && zoom.accessibilityLabel == "Zoom",
              "increment → \(zoom.accessibilityValue ?? "nil"), label \(zoom.accessibilityLabel ?? "nil")")

        await structuralChecks(page, "stepper")
        unmount(page)
    }

    private func colorPage() async {
        let periwinkle = CCColorPreset.house[8].color
        let background = CCColorWell(title: "Background", color: periwinkle)
        let shadow = CCColorWell(title: "Shadow", color: UIColor.black.withAlphaComponent(0.45))
        let ripple = CCColorWell(title: "Ripple", color: .white, supportsOpacity: false)
        ripple.isEnabled = false
        let picker = CCColorPickerView(color: UIColor(red: 0x3D / 255.0, green: 0x7E / 255.0, blue: 1, alpha: 0.8))
        let card = CCCard(floating: true, tint: CCTheme.color.popover, radius: .xl)
        card.addSubview(picker)
        NSLayoutConstraint.activate([
            picker.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            picker.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            picker.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            picker.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
        ])
        let content = column([
            section("Color wells", [CCControlRow(title: "Background", control: background),
                                    CCControlRow(title: "Shadow", detail: "translucent — the checker shows", control: shadow),
                                    CCControlRow(title: "Ripple", detail: "disabled", control: ripple)]),
            section("Picker — swatches, then custom (with opacity)", [card]),
        ], spacing: 18)
        let page = mount(content, "color")
        await wait(0.4)
        await captureThemes(page, "color")

        // HSB ↔ sRGB round trips (the hex always describes the swatch).
        var worst = 0
        for i in 0..<64 {
            let c = UIColor(red: Double((i * 37) % 256) / 255, green: Double((i * 91 + 17) % 256) / 255, blue: Double((i * 53 + 101) % 256) / 255, alpha: 1)
            let back = UIColor.ccSRGB(hue: c.ccHSBA.hue, saturation: c.ccHSBA.saturation, brightness: c.ccHSBA.brightness)
            let a = c.ccSRGBA, b = back.ccSRGBA
            worst = max(worst, Int((max(abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b)) * 255).rounded()))
        }
        check("color-hsb-roundtrip", worst == 0, "64 colors sRGB → HSB → sRGB, worst error \(worst)/255")
        check("color-hex-readout", picker.probeHexText == "3D7EFF" && picker.probeOpacityText == "80%",
              "adopted #3D7EFF @ 80% → hex field \(picker.probeHexText), opacity \(picker.probeOpacityText)")

        var emitted: [UIColor] = []
        picker.onChange = { emitted.append($0) }
        let ok = picker.commitHex("ff8800")
        let bad = picker.commitHex("zz")
        check("color-hex-entry", ok && !bad && picker.color.ccHex == "FF8800" && picker.probeHexText == "FF8800" && emitted.count == 1,
              "typed ff8800 → \(picker.color.ccHex); invalid text reverts (\(picker.probeHexText)); onChange \(emitted.count)×")

        // A swatch tap: adopts the preset, ring springs in on exactly one swatch.
        let blue = picker.probeSwatches.first { $0.preset.name == "Blue" }!
        blue.sendActions(for: .touchUpInside)
        await wait(0.03)
        let ring = blue.probeRingLayer.presentation()?.opacity ?? -1
        let selected = picker.probeSwatches.filter(\.isSelected).map(\.preset.name)
        check("color-swatch-pick", picker.color.ccSameRGB(blue.preset.color) && selected == ["Blue"] && blue.accessibilityTraits.contains(.selected),
              "picked Blue → \(picker.color.ccHex), selected \(selected)")
        check("color-swatch-ring-midflight", ring > 0.01 && ring < 0.99, String(format: "selection ring opacity %.2f mid fade-in", ring))

        // The field and bars: real commit paths.
        let field = picker.probeField
        field.probeTouch(CGPoint(x: field.bounds.width * 0.5, y: field.bounds.height * 0.25), phase: 0)
        field.probeTouch(CGPoint(x: field.bounds.width * 0.5, y: field.bounds.height * 0.25), phase: 2)
        check("color-field", abs(picker.saturation - 0.5) < 0.01 && abs(picker.brightness - 0.75) < 0.01,
              String(format: "touch at (½, ¼) → s=%.2f b=%.2f", picker.saturation, picker.brightness))
        let bar = picker.probeOpacityBar
        bar.probeCommit(x: bar.bounds.width / 2)
        check("color-opacity", abs(picker.opacity - 0.5) < 0.02 && picker.probeOpacityText == "50%",
              String(format: "opacity bar at ½ → %.2f (%@)", picker.opacity, picker.probeOpacityText))
        let hue = picker.probeHueBar
        hue.accessibilityIncrement()
        check("color-voiceover", hue.accessibilityTraits.contains(.adjustable) && (hue.accessibilityValue ?? "").hasSuffix("°")
              && field.accessibilityElements?.count == 2 && (background.accessibilityValue ?? "").contains("Periwinkle"),
              "hue \(hue.accessibilityValue ?? "nil"); field = saturation + brightness; well reads \"\(background.accessibilityValue ?? "nil")\"")

        await structuralChecks(page, "color")
        unmount(page)
    }

    private func dialogPages() async {
        // 1. Standard confirmation card.
        let standard = CCAlert(title: "Replace the background?", message: "Your current wallpaper choice will be swapped for the image you picked.")
        standard.addButton("Replace", role: .primary)
        standard.addButton("Cancel", role: .cancel)
        await presentAndCapture(standard, "dialog-card")

        // 2. Destructive card with an icon tile.
        let destructive = CCAlert(title: "Delete this clip?", message: "The footage between 0:12 and 0:18 is removed from the edit. You can undo this.")
        destructive.symbol = "trash"
        destructive.tone = .destructive
        destructive.addButton("Delete", role: .destructive)
        destructive.addButton("Cancel", role: .cancel)
        await presentAndCapture(destructive, "dialog-destructive-card")
        check("dialog-destructive-style", destructive.probeButtons.isEmpty || destructive.probeButtons.first?.style == .destructive,
              "the confirm button is the destructive style")

        // 3. Confirmation SHEET: docked + rising (compact), mid-flight entrance.
        let sheet = CCAlert(title: "Discard voice-over?", message: "The take you just recorded will be deleted.")
        sheet.symbol = "trash"
        sheet.tone = .destructive
        sheet.presentation = .sheet
        sheet.addButton("Discard take", role: .destructive)
        sheet.addButton("Keep recording", role: .secondary)
        sheet.addButton("Cancel", role: .cancel)
        sheet.present(from: lab)
        var card: UIView?
        for _ in 0..<300 {
            if let c = sheet.probeCard, c.layer.animation(forKey: "ccmotion.transform.translation.y") != nil
                || c.layer.animation(forKey: "ccmotion.transform.scale") != nil { card = c; break }
            await wait(0.004)
        }
        if let card {
            let docked = sheet.probeIsDocked
            var sample: CGFloat = -1
            let frames = await filmstrip("seq-dialog-sheet", view: window, count: 6, interval: 0.04, scale: 1) {} sample: { t in
                if sample < 0, t > 0.03 {
                    let key = docked ? "transform.translation.y" : "transform.scale"
                    sample = (card.layer.presentation()?.value(forKeyPath: key) as? CGFloat) ?? -1
                }
            }
            _ = frames
            if docked {
                check("dialog-sheet-entrance-midflight", sample > 1 && sample < window.bounds.height - card.frame.minY - 1,
                      String(format: "translation.y=%.1f (rises from %.0f to 0)", sample, window.bounds.height - card.frame.minY))
            } else {
                check("dialog-sheet-entrance-midflight", sample > 0.96 && sample < 0.9995,
                      String(format: "regular width → centred card, scale=%.4f (0.96 → 1)", sample))
            }
            await wait(0.6)
            let safeBottom = window.bounds.height - window.safeAreaInsets.bottom
            let buttonYs = sheet.probeButtons.map { $0.convert(CGPoint.zero, to: window).y }
            if docked {
                let titles = sheet.probeButtons.sorted { $0.convert(CGPoint.zero, to: window).y < $1.convert(CGPoint.zero, to: window).y }.map(\.title)
                check("dialog-sheet-docked", abs(card.convert(card.bounds, to: window).maxY - (safeBottom - CCSpace.sm)) < 1 && titles == ["Discard take", "Keep recording", "Cancel"],
                      "docked 8 pt over the safe bottom; buttons top→bottom \(titles)")
            } else {
                check("dialog-sheet-docked", abs(card.center.x - window.bounds.midX) < 1, "regular width keeps the centred card (buttons at y \(buttonYs.map { Int($0) }))")
            }
            try? LabCapture.png(LabCapture.view(window)!).write(to: out.appendingPathComponent("dark/dialog-destructive-sheet.png"))
            window.overrideUserInterfaceStyle = .light
            await wait(0.5)
            try? LabCapture.png(LabCapture.view(window)!).write(to: out.appendingPathComponent("light/dialog-destructive-sheet.png"))
            window.overrideUserInterfaceStyle = .dark
            await wait(0.4)

            // Error growth: a docked sheet grows its TOP edge; the bottom stays.
            let frame0 = card.convert(card.bounds, to: window)
            var peak = frame0.height, bottomDrift: CGFloat = 0
            sheet.probeShowError("Couldn't delete the take — the file is still being written.")
            for _ in 0..<70 {
                await wait(0.008)
                let f = card.convert(card.bounds, to: window)
                peak = max(peak, f.height)
                bottomDrift = max(bottomDrift, abs((docked ? f.maxY : f.minY) - (docked ? frame0.maxY : frame0.minY)))
            }
            await wait(0.3)
            let settled = card.bounds.height
            check("dialog-error-growth", settled > frame0.height + 8 && peak > settled + 0.5 && bottomDrift < 0.5,
                  String(format: "height %.1f → peak %.1f → %.1f; pinned %@ edge drift %.2f pt", frame0.height, peak, settled, docked ? "bottom" : "top", bottomDrift))
            try? LabCapture.png(LabCapture.view(window)!).write(to: out.appendingPathComponent("dark/dialog-sheet-error.png"))
            window.overrideUserInterfaceStyle = .light
            await wait(0.5)
            try? LabCapture.png(LabCapture.view(window)!).write(to: out.appendingPathComponent("light/dialog-sheet-error.png"))
            window.overrideUserInterfaceStyle = .dark
            await wait(0.3)
        } else {
            check("dialog-sheet-entrance-midflight", false, "the sheet never started its entrance")
        }
        sheet.dismiss()
        await wait(0.6)

        // 4. The color picker as presented (sheet on compact, anchored card on regular).
        let wellHost = UIView()
        let well = CCColorWell(title: "Ripple color", color: CCColorPreset.house[5].color, supportsOpacity: false)
        wellHost.addSubview(well)
        let page = mount(column([section("Color well → picker", [CCControlRow(title: "Ripple color", control: well)])]), "picker")
        _ = wellHost
        await wait(0.3)
        let controller = CCColorPicker.present(from: lab, source: well, title: "Ripple color", color: well.color, supportsOpacity: false)
        await wait(0.9)
        try? LabCapture.png(LabCapture.view(window)!).write(to: out.appendingPathComponent("dark/color-picker-presented.png"))
        window.overrideUserInterfaceStyle = .light
        await wait(0.5)
        try? LabCapture.png(LabCapture.view(window)!).write(to: out.appendingPathComponent("light/color-picker-presented.png"))
        window.overrideUserInterfaceStyle = .dark
        await wait(0.3)
        let pickerFrame = controller.card.convert(controller.card.bounds, to: window)
        check("color-picker-presented", window.bounds.contains(pickerFrame.insetBy(dx: 1, dy: 1)) && controller.picker.probeOpacityBar.isHidden,
              String(format: "picker card %.0f×%.0f at (%.0f, %.0f), inside the window; no opacity bar for an opaque property", pickerFrame.width, pickerFrame.height, pickerFrame.minX, pickerFrame.minY))
        controller.close()
        await wait(0.6)
        unmount(page)
    }

    private func presentAndCapture(_ alert: CCAlert, _ name: String) async {
        alert.present(from: lab)
        await wait(0.9)
        try? LabCapture.png(LabCapture.view(window)!).write(to: out.appendingPathComponent("dark/\(name).png"))
        window.overrideUserInterfaceStyle = .light
        await wait(0.5)
        try? LabCapture.png(LabCapture.view(window)!).write(to: out.appendingPathComponent("light/\(name).png"))
        window.overrideUserInterfaceStyle = .dark
        await wait(0.3)
        let frame = alert.probeCard.map { $0.convert($0.bounds, to: window) } ?? .zero
        check("\(name)-onscreen", frame.width > 200 && window.bounds.contains(frame), String(format: "card %.0f×%.0f inside the window", frame.width, frame.height))
        alert.dismiss()
        await wait(0.6)
    }

    // MARK: - Structural checks (every page)

    private func structuralChecks(_ page: UIView, _ name: String) async {
        var views: [UIView] = []
        func walk(_ v: UIView) {
            guard !v.isHidden, v.alpha > 0.01 else { return }
            views.append(v)
            v.subviews.forEach(walk)
        }
        walk(page)

        // Material refit: every dressed surface's base layer fills its bounds.
        var dressed = 0, misfit: [String] = []
        for v in views {
            guard let base = v.layer.sublayers?.first(where: { $0.name == "ccmat.base" }) else { continue }
            dressed += 1
            let b = v.layer.bounds
            if abs(base.frame.width - b.width) > 0.5 || abs(base.frame.height - b.height) > 0.5 || b.width < 1 || b.height < 1 {
                misfit.append("\(type(of: v)) base \(Int(base.frame.width))×\(Int(base.frame.height)) vs \(Int(b.width))×\(Int(b.height))")
            }
        }
        check("\(name)-material-fit", dressed > 0 && misfit.isEmpty, "\(dressed) dressed surfaces" + (misfit.isEmpty ? ", all fitted" : ": " + misfit.prefix(4).joined(separator: "; ")))

        // Controls: inside the window, 44 pt targets.
        let controls = views.compactMap { $0 as? UIControl }.filter { $0.isUserInteractionEnabled && !($0 is CCStepper) }
        var outside: [String] = [], small: [String] = []
        for c in controls {
            let f = c.convert(c.bounds, to: window)
            if f.width < 1 || f.height < 1 || !window.bounds.insetBy(dx: -0.5, dy: -0.5).contains(f) { outside.append("\(type(of: c))") }
            let center = CGPoint(x: c.bounds.midX, y: c.bounds.midY)
            let corners = [CGPoint(x: -21.5, y: -21.5), CGPoint(x: 21.5, y: -21.5), CGPoint(x: -21.5, y: 21.5), CGPoint(x: 21.5, y: 21.5)]
            if !corners.allSatisfy({ c.point(inside: CGPoint(x: center.x + $0.x, y: center.y + $0.y), with: nil) }) {
                small.append("\(type(of: c)) \(Int(c.bounds.width))×\(Int(c.bounds.height))")
            }
        }
        check("\(name)-onscreen", outside.isEmpty, "\(controls.count) controls inside the window" + (outside.isEmpty ? "" : "; outside: \(outside)"))
        check("\(name)-touch-targets", small.isEmpty, "\(controls.count) controls ≥ 44×44 pt" + (small.isEmpty ? "" : "; too small: \(Array(Set(small)).sorted())"))

        // VoiceOver: labels, values, traits per control kind.
        var problems: [String] = []
        for v in views {
            let label = v.accessibilityLabel ?? ""
            switch v {
            case let s as CCSlider:
                if label.isEmpty || !(s.accessibilityTraits.contains(.adjustable)) || (s.accessibilityValue ?? "").isEmpty { problems.append("slider \(label)") }
            case let c as CCChip:
                if label.isEmpty || !c.accessibilityTraits.contains(.button) || c.accessibilityTraits.contains(.selected) != c.isSelected { problems.append("chip \(label)") }
            case let t as CCToggle where t.isAccessibilityElement:
                if label.isEmpty || !t.accessibilityTraits.contains(.toggleButton) || !["On", "Off"].contains(t.accessibilityValue ?? "") { problems.append("toggle \(label)") }
            case let r as CCToggleRow:
                if label.isEmpty || !["On", "Off"].contains(r.accessibilityValue ?? "") { problems.append("toggle row \(label)") }
            case let s as CCStepper:
                if label.isEmpty || !s.accessibilityTraits.contains(.adjustable) || (s.accessibilityValue ?? "").isEmpty { problems.append("stepper \(label)") }
            case let w as CCColorWell:
                if label.isEmpty || !(w.accessibilityValue ?? "").contains("#") { problems.append("well \(label)") }
            case let s as CCColorSwatch:
                if label.isEmpty || !s.accessibilityTraits.contains(.button) { problems.append("swatch") }
            case let b as CCColorBar:
                if label.isEmpty || !b.accessibilityTraits.contains(.adjustable) || (b.accessibilityValue ?? "").isEmpty { problems.append("bar \(label)") }
            case let f as CCColorField:
                if f.accessibilityElements?.count != 2 { problems.append("field") }
            default:
                break
            }
        }
        check("\(name)-voiceover", problems.isEmpty, problems.isEmpty ? "labels, values and traits present on every control" : "missing: \(problems)")
    }

    // MARK: - Theme capture

    /// Capture in dark, re-theme LIVE to light, capture again; assert every
    /// dressed surface re-resolved its colors (no stale CGColors).
    private func captureThemes(_ page: UIView, _ name: String, prepare: () -> Void = {}) async {
        func baseColors() -> [ObjectIdentifier: [CGColor]] {
            var map: [ObjectIdentifier: [CGColor]] = [:]
            func walk(_ v: UIView) {
                guard !v.isHidden else { return }
                if let base = v.layer.sublayers?.first(where: { $0.name == "ccmat.base" }) as? CAGradientLayer,
                   let colors = base.colors as? [CGColor] { map[ObjectIdentifier(v)] = colors }
                v.subviews.forEach(walk)
            }
            walk(page)
            return map
        }
        window.overrideUserInterfaceStyle = .dark
        await wait(0.2)
        prepare()
        await wait(0.3)
        let darkImage = LabCapture.view(page)
        let dark = baseColors()
        if let darkImage { try? LabCapture.png(darkImage).write(to: out.appendingPathComponent("dark/\(name).png")) }
        window.overrideUserInterfaceStyle = .light
        await wait(0.2)
        prepare()
        await wait(0.35)
        let lightImage = LabCapture.view(page)
        let light = baseColors()
        if let lightImage { try? LabCapture.png(lightImage).write(to: out.appendingPathComponent("light/\(name).png")) }
        let stale = dark.filter { id, colors in light[id].map { $0.last == colors.last } ?? false }.count
        let diff = (darkImage != nil && lightImage != nil) ? meanDiff(darkImage!, lightImage!) : 0
        check("\(name)-retheme", !dark.isEmpty && stale == 0 && diff > 25,
              String(format: "%d surfaces re-resolved live (stale %d); dark vs light mean diff %.0f/255", dark.count, stale, diff))
        window.overrideUserInterfaceStyle = .dark
        await wait(0.35)
    }

    // MARK: - Sequences

    private struct Frame {
        var t: Double
        var image: CGImage
    }

    /// Capture `view` once at rest, run `start`, then `count` more frames
    /// `interval` apart (sampling the presentation tree between frames), and
    /// write them side by side as <name>.png. Frames come from the render
    /// server (what is ON SCREEN), so they show the animation as drawn.
    private func filmstrip(_ name: String, view: UIView, count: Int, interval: Double, scale: CGFloat? = nil,
                           start: () -> Void, sample: (Double) -> Void) async -> [Frame] {
        var frames: [Frame] = []
        if let rest = snap(view, scale: scale) { frames.append(Frame(t: -1, image: rest)) }
        let t0 = CACurrentMediaTime()
        start()
        for _ in 0..<count {
            await wait(interval)
            let t = CACurrentMediaTime() - t0
            sample(t)
            if let image = snap(view, scale: scale) { frames.append(Frame(t: t, image: image)) }
        }
        writeStrip(frames.map(\.image), to: out.appendingPathComponent("\(name).png"))
        log("KITGALLERY SEQ \(name) frames=\(frames.count) t=" + frames.map { $0.t < 0 ? "rest" : String(format: "%.0fms", $0.t * 1000) }.joined(separator: ","))
        return frames
    }

    /// One frame of the PRESENTATION tree — what Core Animation is showing
    /// right now, springs mid-flight. (`drawHierarchy` renders the model
    /// tree: every frame of a sequence would show the settled state — the
    /// "static frames only" lie, CLAUDE.md §3. Measured: the first gallery
    /// run's drawHierarchy strips had the toggle thumb at its END position
    /// 27 ms into a 1 s spring.)
    private func snap(_ view: UIView, scale: CGFloat?) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale ?? window.screen.scale
        format.opaque = false
        return UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { ctx in
            (view.layer.presentation() ?? view.layer).render(in: ctx.cgContext)
        }.cgImage
    }

    private func writeStrip(_ images: [CGImage], to url: URL) {
        guard !images.isEmpty else { return }
        let gap = 8
        let width = images.reduce(0) { $0 + $1.width } + gap * (images.count - 1)
        let height = images.map(\.height).max() ?? 1
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let strip = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { ctx in
            UIColor(white: 0.5, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            var x = 0
            for image in images {
                UIImage(cgImage: image).draw(in: CGRect(x: x, y: 0, width: image.width, height: image.height))
                x += image.width + gap
            }
        }
        try? strip.pngData()?.write(to: url)
    }

    /// Mean x (pt) of near-white pixels inside `xRange` (pt) — the white
    /// thumb / bar in a dark capture.
    private func whiteCentroidX(_ image: CGImage, xRange: ClosedRange<CGFloat>) -> CGFloat? {
        let scale = window.screen.scale
        let (data, w, h) = pixels(image)
        var sum = 0.0, count = 0.0
        let lo = max(0, Int(xRange.lowerBound * scale)), hi = min(w - 1, Int(xRange.upperBound * scale))
        guard lo < hi else { return nil }
        for y in 0..<h {
            for x in lo...hi {
                let i = (y * w + x) * 4
                if data[i] > 236, data[i + 1] > 236, data[i + 2] > 236, data[i + 3] > 200 {
                    sum += Double(x)
                    count += 1
                }
            }
        }
        return count > 20 ? CGFloat(sum / count) / scale : nil
    }

    private func meanDiff(_ a: CGImage, _ b: CGImage) -> Double {
        let (da, wa, ha) = pixels(a), (db, wb, hb) = pixels(b)
        guard wa == wb, ha == hb, !da.isEmpty else { return 0 }
        var total = 0
        for i in stride(from: 0, to: da.count, by: 4) {
            total += abs(Int(da[i]) - Int(db[i])) + abs(Int(da[i + 1]) - Int(db[i + 1])) + abs(Int(da[i + 2]) - Int(db[i + 2]))
        }
        return Double(total) / Double(da.count / 4 * 3)
    }

    private func pixels(_ image: CGImage) -> ([UInt8], Int, Int) {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        data.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return (data, w, h)
    }

    // MARK: - Layout helpers

    /// Mount a page under the safe area, a phone-width column (an inspector
    /// column on iPad), on the theme background.
    private func mount(_ content: UIView, _ name: String) -> UIView {
        let page = UIView()
        page.backgroundColor = CCTheme.color.background
        page.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(content)
        lab.view.addSubview(page)
        let guide = lab.view.safeAreaLayoutGuide
        let fill = content.widthAnchor.constraint(equalTo: page.widthAnchor, constant: -32)
        fill.priority = .required - 1
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: guide.topAnchor),
            page.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            content.topAnchor.constraint(equalTo: page.topAnchor, constant: 16),
            content.centerXAnchor.constraint(equalTo: page.centerXAnchor),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            fill,
            page.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: 20),
            page.bottomAnchor.constraint(lessThanOrEqualTo: guide.bottomAnchor),
        ])
        lab.view.layoutIfNeeded()
        let expected = min(page.bounds.width - 32, 420)
        check("\(name)-layout-column", abs(content.bounds.width - expected) < 0.5,
              String(format: "page column %.0f pt wide (want %.0f) — nothing inside out-voted it", content.bounds.width, expected))
        return page
    }

    private func unmount(_ page: UIView) {
        page.removeFromSuperview()
    }

    private func pin(_ view: UIView, in host: UIView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
    }

    private func section(_ title: String, _ views: [UIView], spacing: CGFloat = 10) -> UIView {
        let label = ccLabel(title, font: CCFont.captionMedium, color: CCTheme.color.mutedForeground)
        let stack = UIStackView(arrangedSubviews: [label] + views)
        stack.axis = .vertical
        stack.spacing = spacing
        stack.alignment = .fill
        return stack
    }

    private func column(_ sections: [UIView], spacing: CGFloat = 22) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: sections)
        stack.axis = .vertical
        stack.spacing = spacing
        stack.alignment = .fill
        return stack
    }

    // MARK: - Log

    private func log(_ line: String) {
        print(line)
        lines.append(line)
    }

    private func check(_ name: String, _ pass: Bool, _ detail: String) {
        if !pass { failures += 1 }
        log("KITGALLERY \(name) \(pass ? "PASS" : "FAIL") \(detail)")
    }

    private func wait(_ seconds: Double) async { await LabTime.settle(seconds) }
}
