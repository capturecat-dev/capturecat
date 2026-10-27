import AppKit

/// `--menu-shot [<outDir>] [--before]`
///
/// Opens the app's REAL custom menus through their shipping presentation
/// paths, inside the real editor topology (EditorShellViewController + top
/// bar in an editor-configured window), in dark AND light, and captures
/// them. `--before` only captures (it ran against the pre-redesign menus to
/// record the baseline); the default mode is the gate.
///
/// Standalone off-screen window — never touches the running app. DEBUG
/// tooling; never reached in a normal launch.
@MainActor
enum MenuShotHarness {
    static var failures = 0

    static func run() -> Never {
        setbuf(stdout, nil)
        CCTheme.setMode(.dark, persist: false)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            await execute()
            print(failures == 0 ? "MENUSHOT PASS" : "MENUSHOT FAIL \(failures)")
            exit(failures == 0 ? 0 : 1)
        }
        app.run()
        exit(0)
    }

    // MARK: - Fixture

    struct Fixture {
        let window: NSWindow
        let shell: EditorShellViewController
        let project: Project
        let videoURL: URL
        let outDir: URL
    }

    static func outDirectory() -> URL {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--menu-shot"), i + 1 < args.count, !args[i + 1].hasPrefix("-") {
            return URL(fileURLWithPath: args[i + 1])
        }
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("capturecat-menu-shot")
    }

    private static func makeFixture() async -> Fixture? {
        // Re-seed after launch (applicationDidFinishLaunching restores the
        // persisted mode otherwise).
        CCTheme.setMode(.dark, persist: false)
        let outDir = outDirectory()
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let fixtureDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("capturecat-menu-shot-fixture")
        try? FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)
        let videoURL = fixtureDir.appendingPathComponent("screen.mov")
        guard await PlaybackObserverHarness.writeVideo(
            to: videoURL, seconds: 4.0, size: CGSize(width: 1280, height: 800), tint: 0.35
        ) else {
            print("MENUSHOT FAIL could not synthesize fixture video")
            return nil
        }
        let project = Project(name: "Menu Probe", videoURL: videoURL, duration: 4.0)
        project.trimStart = 0
        project.trimEnd = 4.0
        project.settings.muteRecordedAudio = true
        project.zoomRegions = [ZoomRegion(startTime: 0.5, endTime: 1.5)]

        let shell = EditorShellViewController(appState: nil, project: project)
        let container = ProbeContent(shell: shell)
        let window = NSWindow(contentViewController: container)
        window.styleMask.insert(.fullSizeContentView)
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 1400, height: 800))
        // Off the visible desktop: the probe must never cover the real app.
        // (Menus clamp themselves onto the nearest screen, as in production.)
        window.setFrameOrigin(NSPoint(x: -20_000, y: 200))
        window.orderFrontRegardless()
        window.contentView?.superview?.wantsLayer = true
        for _ in 0..<8 {
            try? await Task.sleep(for: .milliseconds(250))
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return Fixture(window: window, shell: shell, project: project, videoURL: videoURL, outDir: outDir)
    }

    /// Mirrors EditorWindowContentViewController: 52 pt top bar + shell.
    private final class ProbeContent: NSViewController {
        let shell: EditorShellViewController
        init(shell: EditorShellViewController) {
            self.shell = shell
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func loadView() {
            let root = NSView()
            root.wantsLayer = true
            view = root
            addChild(shell)
            shell.view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(shell.view)
            let bar = shell.topBarView
            bar.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(bar)
            NSLayoutConstraint.activate([
                bar.topAnchor.constraint(equalTo: root.topAnchor),
                bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                bar.heightAnchor.constraint(equalToConstant: 52),
                shell.view.topAnchor.constraint(equalTo: bar.bottomAnchor),
                shell.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                shell.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                shell.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ])
        }
    }

    // MARK: - Run

    private static func execute() async {
        guard let fixture = await makeFixture() else { failures += 1; return }
        if CommandLine.arguments.contains("--before") {
            await beforeShots(fixture)
            return
        }
        // The user's real pointer/clicks never reach the probe's menus; the
        // gate drives hover through the lists' real dispatchers.
        CCMenu.probeIsolated = true
        if let i = CommandLine.arguments.firstIndex(of: "--inject"), i + 1 < CommandLine.arguments.count {
            CCMenu.probeInjectedDefects = Set(CommandLine.arguments[i + 1].split(separator: ",").map(String.init))
            print("MENUSHOT injecting defects: \(CCMenu.probeInjectedDefects.sorted())")
        }
        for dark in [true, false] {
            CCTheme.setMode(dark ? .dark : .light, persist: false)
            fixture.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            try? await Task.sleep(for: .milliseconds(300))
            let theme = dark ? "dark" : "light"
            await effectsScenario(fixture, camera: false, theme: theme)
            await effectsScenario(fixture, camera: true, theme: theme)
            await contextScenario(fixture, theme: theme)
            await selectScenario(fixture, theme: theme)
            await annotateScenario(fixture, theme: theme)
        }
        await wrapScenario(fixture)
        await reduceMotionScenario(fixture)
    }

    // MARK: - Checks

    static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if !ok { failures += 1 }
        print("MENUSHOT \(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    }

    static func sleep(_ ms: Int) async {
        try? await Task.sleep(for: .milliseconds(ms))
    }

    static func fmt(_ value: CGFloat) -> String { String(format: "%.3f", value) }

    /// OPEN mid-flight at ~60 ms (opacity strictly inside (0,1); scale
    /// strictly inside (0.96,1) or past 1 on the overshoot) with the row
    /// stagger visible (row 0 ahead of row 5), then SETTLED at 1.
    static func probeOpen(_ label: String, stage: CCMenuStage, list: CCMenuList, opened: CFTimeInterval,
                          expectsScale: Bool = true) async {
        // Sample ~60 ms into the animation itself: CA starts it at the
        // open's COMMIT (the build + first window commit takes 20–45 ms
        // after the call), so anchor on the animation's real beginTime.
        await sleep(1)
        var start = CACurrentMediaTime()
        if let layer = stage.probeSurfaceLayer,
           let animation = layer.animation(forKey: "capmotion.transform") ?? layer.animation(forKey: "capmotion.alpha"),
           animation.beginTime > 0 {
            start = layer.convertTime(animation.beginTime, to: nil)
        }
        await sleep(max(0, Int((start + 0.060 - CACurrentMediaTime()) * 1000)))
        let t = (CACurrentMediaTime() - start) * 1000
        let sinceCall = (CACurrentMediaTime() - opened) * 1000
        let opacity = CGFloat(stage.probePresentedOpacity)
        let scale = stage.probePresentedScale
        let fading = opacity > 0.001 && opacity < 0.999
        let scaling = expectsScale
            ? (scale > CCMenu.openScale + 0.0005 && abs(scale - 1) > 0.0005)
            : abs(scale - 1) < 0.0005
        check("\(label) open-midflight", fading && scaling,
              "t=\(Int(t))ms into the animation (\(Int(sinceCall))ms after the call) opacity=\(fmt(opacity)) scale=\(fmt(scale))")
        let rows = list.visibleRows
        if rows.count > 5 {
            let first = CGFloat((rows[0].layer?.presentation() ?? rows[0].layer)?.opacity ?? 0)
            let fifth = CGFloat((rows[5].layer?.presentation() ?? rows[5].layer)?.opacity ?? 0)
            check("\(label) row-stagger", first > fifth + 0.05,
                  "t=\(Int(t))ms row0=\(fmt(first)) row5=\(fmt(fifth))")
        }
        await sleep(650)
        let settledOpacity = CGFloat(stage.probePresentedOpacity)
        let settledScale = stage.probePresentedScale
        let shift = stage.probePresentedTranslation
        let rowsSettled = list.visibleRows.allSatisfy { row in
            let shown = CGFloat((row.layer?.presentation() ?? row.layer)?.opacity ?? 0)
            let resting = row.isEnabled ? 1 : CCTheme.current.disabledAlpha
            return abs(shown - resting) < 0.01
        }
        check("\(label) open-settles", abs(settledOpacity - 1) < 0.001 && abs(settledScale - 1) < 0.001
              && abs(shift.x) < 0.01 && abs(shift.y) < 0.01 && rowsSettled,
              "opacity=\(fmt(settledOpacity)) scale=\(fmt(settledScale)) shift=(\(fmt(shift.x)),\(fmt(shift.y))) rowsAtRest=\(rowsSettled)")
    }

    /// No label is truncated: every text field's REQUIRED size fits its
    /// frame (cell measurement, single line), descriptions need ≤ 2 lines at
    /// their real width, shortcut caps sit clear of the title, and nothing
    /// pokes past the row.
    static func probeLabels(_ label: String, list: CCMenuList) {
        var fields = 0
        var bad: [String] = []
        var maxLines = 0
        func fits(_ field: NSTextField, in container: NSView, _ name: String) {
            guard !field.isHidden, !field.stringValue.isEmpty else { return }
            fields += 1
            let need = CCMenu.singleLineSize(field)
            if need.width > field.frame.width + 0.5 || need.height > field.frame.height + 0.5
                || field.frame.maxX > container.bounds.width + 0.5 || field.frame.minX < 0 {
                bad.append("\(name)(need \(Int(need.width))x\(Int(need.height)) has \(Int(field.frame.width))x\(Int(field.frame.height)))")
            }
        }
        for row in list.visibleRows {
            fits(row.titleField, in: row, "title:\(row.model.title)")
            fits(row.subtitleField, in: row, "subtitle:\(row.model.title)")
            let detail = row.detailField
            if !detail.isHidden, !detail.stringValue.isEmpty {
                fields += 1
                let need = CCMenu.wrappedRequirement(detail.stringValue, font: detail.font ?? CCMenu.detailFont,
                                                     width: detail.frame.width)
                maxLines = max(maxLines, need.lines)
                if need.lines > CCMenu.maxDetailLines || need.height > detail.frame.height + 0.5
                    || detail.frame.maxX > row.bounds.width + 0.5 {
                    bad.append("detail:\(row.model.title)(\(need.lines) lines, need h\(Int(need.height)) has \(Int(detail.frame.height)))")
                }
            }
            if let cap = row.probeShortcutCap {
                fields += 1
                let capLabel = cap.probeLabel
                let need = CCMenu.singleLineSize(capLabel)
                if cap.frame.minX < row.titleField.frame.maxX + 8 || cap.frame.maxX > row.bounds.width + 0.5
                    || need.width > cap.frame.width + 0.5 {
                    bad.append("shortcut:\(row.model.title)")
                }
            }
            if row.model.accessory != .none {
                // Check marks and chevrons sit at the FAR right.
                let accessory = row.probeAccessory.frame
                if accessory.maxX < row.bounds.width - CCMenuRow.richTrailPad - 0.5 || accessory.isEmpty {
                    bad.append("accessory:\(row.model.title)")
                }
            }
            if row.frame.maxX > list.bounds.width - CCMenu.padding + 0.5 { bad.append("row-overflow:\(row.model.title)") }
        }
        for header in list.headers {
            fits(header.titleField, in: header, "header:\(header.titleField.stringValue)")
            fits(header.captionField, in: header, "caption:\(header.captionField.stringValue)")
        }
        check("\(label) no-truncation", bad.isEmpty && fields > 0,
              "fields=\(fields) width=\(Int(list.bounds.width)) maxDetailLines=\(maxLines)\(bad.isEmpty ? "" : " BAD=\(bad.joined(separator: ", "))")")
    }

    /// HOVER: the wash glides (never snaps) between two rows — sampled on its
    /// PRESENTATION mid-hop — then lands; rich rows' tiles spring to the
    /// accent.
    static func probeHover(_ label: String, list: CCMenuList) async {
        let enabled = list.visibleRows.filter(\.isEnabled)
        guard enabled.count >= 3 else {
            check("\(label) hover-glide", false, "only \(enabled.count) enabled rows")
            return
        }
        let a = enabled[0], b = enabled[min(4, enabled.count - 1)]
        route(list, over: a)
        await sleep(350)
        let fromY = a.frame.midY, toY = b.frame.midY
        route(list, over: b)
        await sleep(45)
        let mid = list.wash.debugPresentationFrame.midY
        let tileMid = b.probeTileHotPresented
        let low = min(fromY, toY) + 3, high = max(fromY, toY) - 3
        check("\(label) hover-glide", mid > low && mid < high,
              "from=\(Int(fromY)) to=\(Int(toY)) presented@45ms=\(fmt(mid))")
        if b.probeIsRich {
            check("\(label) tile-crossfade-midflight", tileMid > 0.01 && tileMid < 0.99, "tileAccent@45ms=\(fmt(CGFloat(tileMid)))")
        }
        await sleep(400)
        let landed = list.wash.debugPresentationFrame.midY
        let washOpacity = (list.wash.layer.presentation() ?? list.wash.layer).opacity
        check("\(label) hover-lands", abs(landed - toY) < 1 && washOpacity > 0.99 && list.highlightedRow === b
              && (!b.probeIsRich || b.probeTileHotAlpha > 0.99),
              "landed=\(fmt(landed)) target=\(fmt(toY)) wash=\(fmt(CGFloat(washOpacity)))")
    }

    static func route(_ list: CCMenuList, over row: NSView) {
        list.routeHover(windowPoint: row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil))
    }

    /// CLOSE: a ~100 ms fade + scale toward 0.98, caught mid-flight, and the
    /// panel gone afterwards.
    static func probeClose(_ label: String, stage: CCMenuStage, panel: NSWindow, close: () -> Void) async {
        close()
        await sleep(45)
        let opacity = CGFloat(stage.probePresentedOpacity)
        let scale = stage.probePresentedScale
        let midFlight = opacity > 0.001 && opacity < 0.999
        let shrinking = CCMenu.reduceMotion || (scale < 0.9995 && scale > CCMenu.closeScale - 0.0005)
        check("\(label) close-fades", midFlight && shrinking, "opacity@45ms=\(fmt(opacity)) scale=\(fmt(scale))")
        await sleep(250)
        check("\(label) close-orders-out", !panel.isVisible, "panelVisible=\(panel.isVisible)")
    }

    static func probeSurface(_ label: String, stage: CCMenuStage, panel: NSWindow, parent: NSWindow) {
        let tint = (stage.surface.layer?.value(forKey: "ccmatTint") as? NSColor)?.usingColorSpace(.sRGB)
        let token = CCTheme.color.popover.usingColorSpace(.sRGB)
        let tintOK = tint.map { t in token.map { abs(t.redComponent - $0.redComponent) < 0.01 && abs(t.blueComponent - $0.blueComponent) < 0.01 } ?? false } ?? false
        let shadow = stage.surface.probeShadow
        let shadowOK = abs(shadow.opacity - (CCTheme.isDark ? 0.45 : 0.16)) < 0.001
        let radiusOK = abs((stage.surface.layer?.cornerRadius ?? 0) - CCTheme.radius(.lg)) < 0.01
        let topologyOK = panel.parent === parent
        // The shadow must fit INSIDE the panel (a window clips layer shadows).
        let surface = stage.surface.frame
        let room = min(surface.minX, surface.minY - 10, stage.bounds.width - surface.maxX, stage.bounds.height - surface.maxY + 10)
        let roomOK = room >= 3.3 * shadow.radius - 0.5
        check("\(label) surface", tintOK && shadowOK && radiusOK && topologyOK && roomOK,
              "popoverTint=\(tintOK) shadowOpacity=\(shadow.opacity) radius=\(stage.surface.layer?.cornerRadius ?? 0) childOfEditor=\(topologyOK) shadowRoom=\(Int(room))pt")
    }

    // MARK: - Scenarios

    static func effectsScenario(_ f: Fixture, camera: Bool, theme: String) async {
        let label = "effects-\(camera ? "camera" : "nocam")-\(theme)"
        guard let timeline = f.shell.probeTimeline else {
            check(label, false, "no timeline")
            return
        }
        f.project.cameraVideoURL = camera ? f.videoURL : nil
        await sleep(150)
        let opened = CACurrentMediaTime()
        guard let popover = timeline.probeOpenEffectsMenu(), let stage = popover.probeStage,
              let list = popover.probeList else {
            check(label, false, "picker did not open")
            return
        }
        print("MENUSHOT info \(label) open-call=\(Int((CACurrentMediaTime() - opened) * 1000))ms")
        await probeOpen(label, stage: stage, list: list, opened: opened)
        probeSurface(label, stage: stage, panel: popover.probePanel, parent: f.window)
        probeLabels(label, list: list)

        // Sections + the disabled-group caption.
        let headers = list.headers.map { $0.titleField.stringValue }
        let cameraHeader = list.headers.first { $0.titleField.stringValue == "Camera" }
        let cameraTitles: Set<String> = ["Full Screen", "Side by Side", "Cutout", "Pop-out card", "Hide Camera"]
        let cameraRows = list.rows.filter { cameraTitles.contains($0.model.title) }
        check("\(label) sections", headers == ["Zoom & motion", "Transitions", "Camera"] && cameraRows.count == 5,
              "headers=\(headers) cameraRows=\(cameraRows.count)")
        if camera {
            check("\(label) camera-enabled", cameraRows.allSatisfy(\.isEnabled) && cameraHeader?.hasCaption == false,
                  "enabled=\(cameraRows.filter(\.isEnabled).count)/5 caption=\(cameraHeader?.hasCaption ?? false)")
        } else {
            let caption = cameraHeader?.hasCaption == true ? cameraHeader!.captionField.stringValue : "(none)"
            let dimmed = cameraRows.allSatisfy { !$0.isEnabled && abs($0.alphaValue - CCTheme.current.disabledAlpha) < 0.01 }
            check("\(label) disabled-caption", caption == "Needs a camera recording" && dimmed,
                  "caption=\"\(caption)\" dimmedDisabled=\(dimmed)")
            // Disabled rows take no hover.
            if let dead = cameraRows.first {
                list.clearHover()
                route(list, over: dead)
                check("\(label) disabled-no-hover", list.highlightedRow == nil, "highlight=\(list.highlightedRow?.model.title ?? "none")")
                list.clearHover()
            }
        }
        await probeHover(label, list: list)
        // Keyboard: the picker never becomes key, so ↑/↓ arrive through its
        // monitor; ↓ from the hovered row moves on, skipping disabled rows.
        list.clearHover()
        postKey(126)
        await sleep(80)
        let lastEnabled = list.visibleRows.last(where: \.isEnabled)
        check("\(label) keyboard", list.highlightedRow === lastEnabled && lastEnabled != nil,
              "↑ highlights \(list.highlightedRow?.model.title ?? "none") (last enabled: \(lastEnabled?.model.title ?? "none"))")
        await probeClose(label, stage: stage, panel: popover.probePanel) { popover.close() }

        // Settled capture (motion probes all ran first — CARenderer re-hosts
        // the tree), with a row hovered so the accent tile shows.
        if let again = timeline.probeOpenEffectsMenu(), let list = again.probeList {
            await sleep(700)
            if let row = list.visibleRows.filter(\.isEnabled).dropFirst().first { route(list, over: row) }
            await sleep(450)
            captureChildPanels(of: f.window, name: label, outDir: f.outDir)
            again.close()
            await sleep(300)
        }
        f.project.cameraVideoURL = nil
    }

    static func contextScenario(_ f: Fixture, theme: String) async {
        let label = "context-\(theme)"
        guard let canvas = findView(TimelineCanvasView.self, in: f.window.contentView!) else {
            check(label, false, "no timeline canvas")
            return
        }
        let opened = CACurrentMediaTime()
        showContextMenu(on: canvas)
        guard let root = CaptureCatMenuPresenter.probeRoot else {
            check(label, false, "context menu did not open")
            return
        }
        print("MENUSHOT info \(label) open-call=\(Int((CACurrentMediaTime() - opened) * 1000))ms")
        await probeOpen(label, stage: root.stage, list: root.list, opened: opened)
        probeSurface(label, stage: root.stage, panel: root.panel, parent: f.window)
        probeLabels(label, list: root.list)
        let caps = root.list.rows.filter { $0.probeShortcutCap != nil }.count
        let expected = probeContextMenu().items.filter { !$0.keyEquivalent.isEmpty }.count
        check("\(label) shortcuts", caps == expected && caps > 0, "caps=\(caps) expected=\(expected)")
        await probeHover(label, list: root.list)

        // SUBMENU: hover dwell (140 ms) flies it out with a slide + fade.
        guard let parentRow = root.list.rows.first(where: { $0.model.accessory == .submenu }) else {
            check(label, false, "no submenu row")
            return
        }
        route(root.list, over: parentRow)
        var flyout: CaptureCatMenuPresenter.ProbeSurface?
        let dwellStart = CACurrentMediaTime()
        for _ in 0..<40 {
            await sleep(5)
            if let open = CaptureCatMenuPresenter.probeFlyout { flyout = open; break }
        }
        let dwell = (CACurrentMediaTime() - dwellStart) * 1000
        guard let flyout else {
            check("\(label) submenu-flyout", false, "no flyout after \(Int(dwell))ms")
            return
        }
        await sleep(35)
        let fOpacity = CGFloat(flyout.stage.probePresentedOpacity)
        let fShift = flyout.stage.probePresentedTranslation
        let fScale = flyout.stage.probePresentedScale
        check("\(label) submenu-flyout", dwell > 100 && fOpacity > 0.001 && fOpacity < 0.999 && abs(fShift.x) > 0.05
              && abs(fScale - 1) < 0.0005,
              "dwell=\(Int(dwell))ms opacity@35ms=\(fmt(fOpacity)) slideX=\(fmt(fShift.x)) scale=\(fmt(fScale))")
        await sleep(500)
        if let rootRect = root.stage.surfaceScreenRect, let flyRect = flyout.stage.surfaceScreenRect,
           let firstRow = flyout.list.visibleRows.first {
            let rowY = root.panel.convertToScreen(parentRow.convert(parentRow.bounds, to: nil)).midY
            let flyRowY = flyout.panel.convertToScreen(firstRow.convert(firstRow.bounds, to: nil)).midY
            let beside = flyRect.minX >= rootRect.maxX - 0.5 || flyRect.maxX <= rootRect.minX + 0.5
            check("\(label) submenu-placement", beside && abs(rowY - flyRowY) < 2 && root.list.highlightedRow === parentRow,
                  "beside=\(beside) parentRowY=\(Int(rowY)) firstRowY=\(Int(flyRowY)) parentKeepsHighlight=\(root.list.highlightedRow === parentRow)")
            probeLabels("\(label)-submenu", list: flyout.list)
        }

        // SELECT pulse: the picked row's wash blinks before the menu closes.
        if let pick = root.list.rows.first(where: { $0.isEnabled && $0.model.accessory == .none }) {
            root.list.activate(pick)
            await sleep(50)
            let washMid = CGFloat((root.list.wash.layer.presentation() ?? root.list.wash.layer).opacity)
            let stillOpen = root.panel.isVisible && !root.stage.isClosing
            check("\(label) select-pulse", washMid < 0.9 && stillOpen && root.list.highlightedRow === pick,
                  "wash@50ms=\(fmt(washMid)) menuStillOpen=\(stillOpen)")
            await sleep(400)
            check("\(label) select-closes", !root.panel.isVisible && CaptureCatMenuPresenter.probeRoot == nil,
                  "panelVisible=\(root.panel.isVisible)")
        }

        // KEYBOARD through the real path (keys enqueued → the menu's local
        // monitor): ↓↓ walks enabled rows, type-select jumps, → flies the
        // submenu out, ← steps back, ⎋ closes.
        showContextMenu(on: canvas)
        await sleep(600)
        if let menu = CaptureCatMenuPresenter.probeRoot {
            let enabled = menu.list.visibleRows.filter(\.isEnabled)
            postKey(125)
            postKey(125)
            await sleep(80)
            let walked = menu.list.highlightedRow === enabled[1]
            postKey(0, characters: "z")
            await sleep(80)
            let typed = menu.list.highlightedRow?.model.title == "Zoom Level"
            postKey(124)
            await sleep(120)
            let flew = CaptureCatMenuPresenter.probeFlyout != nil
            postKey(123)
            await sleep(200)
            let stepped = CaptureCatMenuPresenter.probeFlyout == nil && menu.list.highlightedRow?.model.title == "Zoom Level"
            postKey(53)
            await sleep(300)
            let closed = !menu.panel.isVisible
            check("\(label) keyboard", walked && typed && flew && stepped && closed,
                  "↓↓=\(walked) type-select=\(typed) →flyout=\(flew) ←back=\(stepped) ⎋closed=\(closed)")
        }

        // Close fade on a fresh open.
        showContextMenu(on: canvas)
        await sleep(700)
        if let again = CaptureCatMenuPresenter.probeRoot {
            await probeClose(label, stage: again.stage, panel: again.panel) { CaptureCatMenuPresenter.dismiss() }
        }

        // Capture: menu + flown-out submenu, settled.
        showContextMenu(on: canvas)
        await sleep(600)
        if let again = CaptureCatMenuPresenter.probeRoot,
           let row = again.list.rows.first(where: { $0.model.accessory == .submenu }) {
            route(again.list, over: row)
            await sleep(800)
            captureChildPanels(of: f.window, name: label, outDir: f.outDir)
        }
        CaptureCatMenuPresenter.dismiss()
        await sleep(300)
    }

    static func selectScenario(_ f: Fixture, theme: String) async {
        let label = "select-\(theme)"
        guard let select = findView(CCSelect.self, in: f.window.contentView!) else {
            check(label, false, "no CCSelect in the editor shell")
            return
        }
        let opened = CACurrentMediaTime()
        select.open()
        guard let popup = select.probePopup else {
            check(label, false, "popup did not open")
            return
        }
        print("MENUSHOT info \(label) open-call=\(Int((CACurrentMediaTime() - opened) * 1000))ms")
        await probeOpen(label, stage: popup.probeStage, list: popup.probeList, opened: opened)
        probeSurface(label, stage: popup.probeStage, panel: popup.probePanel, parent: f.window)
        probeLabels(label, list: popup.probeList)
        let checked = popup.probeList.rows.filter { $0.model.accessory == .check }.count
        check("\(label) check-far-right", checked == 1, "checkedRows=\(checked)")
        await probeHover(label, list: popup.probeList)
        await probeClose(label, stage: popup.probeStage, panel: popup.probePanel) { select.dismissPopup() }

        select.open()
        await sleep(700)
        if let popup = select.probePopup, let row = popup.probeList.visibleRows.dropFirst(2).first {
            route(popup.probeList, over: row)
            await sleep(450)
            captureChildPanels(of: f.window, name: label, outDir: f.outDir)
        }
        select.dismissPopup()
        await sleep(300)
    }

    /// The other rich picker (unheaded): fits, settles, captured.
    static func annotateScenario(_ f: Fixture, theme: String) async {
        let label = "annotate-\(theme)"
        guard let timeline = f.shell.probeTimeline, let popover = timeline.probeOpenAnnotationMenu(),
              let list = popover.probeList else {
            check(label, false, "picker did not open")
            return
        }
        await sleep(700)
        probeLabels(label, list: list)
        if let row = list.visibleRows.first { route(list, over: row) }
        await sleep(450)
        captureChildPanels(of: f.window, name: label, outDir: f.outDir)
        popover.close()
        await sleep(300)
    }

    /// Long descriptions WRAP (≤ 2 lines) at the 380 pt max instead of
    /// truncating or widening the menu — the picker path with a fixture row
    /// no shipping picker needs yet.
    static func wrapScenario(_ f: Fixture) async {
        guard let anchor = findView(TimelineCanvasView.self, in: f.window.contentView!) else { return }
        let long = "Pushes in on whatever the cursor is doing and eases back out when the pointer rests"
        let popover = TimelinePickerPopover.make(rows: [
            .init(icon: "sparkle.magnifyingglass", title: "Auto Zoom", detail: long) {},
            .init(icon: "plus.magnifyingglass", title: "Zoom In", detail: "Push in at the playhead") {},
        ])
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        await sleep(700)
        guard let list = popover.probeList else {
            check("wrap", false, "picker did not open")
            return
        }
        let row = list.visibleRows[0]
        let lines = row.detailLines(forRowWidth: row.bounds.width)
        check("wrap two-lines-at-max", abs(list.bounds.width - CCMenu.maxWidth) < 0.5 && lines == 2
              && row.bounds.height > CCMenu.richRowMinHeight,
              "width=\(Int(list.bounds.width)) lines=\(lines) rowHeight=\(Int(row.bounds.height))")
        probeLabels("wrap", list: list)
        captureChildPanels(of: f.window, name: "wrap-light", outDir: f.outDir)
        popover.close()
        await sleep(300)
    }

    /// Reduce Motion: the open is a FADE only — no scale, no slide, no row
    /// stagger.
    static func reduceMotionScenario(_ f: Fixture) async {
        guard let select = findView(CCSelect.self, in: f.window.contentView!) else { return }
        CCMenu.probeReduceMotion = true
        defer { CCMenu.probeReduceMotion = nil }
        select.open()
        guard let popup = select.probePopup else {
            check("reduce-motion", false, "popup did not open")
            return
        }
        await sleep(60)
        let opacity = CGFloat(popup.probeStage.probePresentedOpacity)
        let scale = popup.probeStage.probePresentedScale
        let shift = popup.probeStage.probePresentedTranslation
        let rowShift = popup.probeList.visibleRows.map { ($0.layer?.presentation() ?? $0.layer)?.transform.m42 ?? 0 }
        check("reduce-motion fade-only", opacity > 0.001 && opacity < 0.999 && abs(scale - 1) < 0.0001
              && shift == .zero && rowShift.allSatisfy { abs($0) < 0.001 },
              "opacity@60ms=\(fmt(opacity)) scale=\(fmt(scale)) rowsStill=\(rowShift.allSatisfy { abs($0) < 0.001 })")
        select.dismissPopup()
        await sleep(300)
    }

    /// Baseline captures of whatever menus the build ships — no assertions.
    private static func beforeShots(_ f: Fixture) async {
        for dark in [true, false] {
            CCTheme.setMode(dark ? .dark : .light, persist: false)
            f.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            try? await Task.sleep(for: .milliseconds(300))
            let suffix = dark ? "dark" : "light"
            guard let timeline = f.shell.probeTimeline else {
                print("MENUSHOT FAIL no timeline")
                failures += 1
                return
            }

            f.project.cameraVideoURL = nil
            let effects = timeline.probeOpenEffectsMenu()
            try? await Task.sleep(for: .milliseconds(700))
            captureChildPanels(of: f.window, name: "effects-nocam-\(suffix)", outDir: f.outDir)
            effects?.close()
            try? await Task.sleep(for: .milliseconds(300))

            f.project.cameraVideoURL = f.videoURL
            let effectsCam = timeline.probeOpenEffectsMenu()
            try? await Task.sleep(for: .milliseconds(700))
            captureChildPanels(of: f.window, name: "effects-camera-\(suffix)", outDir: f.outDir)
            effectsCam?.close()
            f.project.cameraVideoURL = nil
            try? await Task.sleep(for: .milliseconds(300))

            let annotate = timeline.probeOpenAnnotationMenu()
            try? await Task.sleep(for: .milliseconds(700))
            captureChildPanels(of: f.window, name: "annotate-\(suffix)", outDir: f.outDir)
            annotate?.close()
            try? await Task.sleep(for: .milliseconds(300))

            // Context menu with shortcuts + a submenu, through the real
            // presenter, flown out with the real keyboard path (→).
            if let canvas = findView(TimelineCanvasView.self, in: f.window.contentView!) {
                showContextMenu(on: canvas)
                try? await Task.sleep(for: .milliseconds(500))
                postKey(125) // ↓ to "Zoom Level"
                postKey(125)
                postKey(125)
                postKey(125)
                postKey(124) // → fly the submenu out
                try? await Task.sleep(for: .milliseconds(700))
                captureChildPanels(of: f.window, name: "context-\(suffix)", outDir: f.outDir)
                CaptureCatMenuPresenter.dismiss()
                try? await Task.sleep(for: .milliseconds(300))
            }

            if let select = findView(CCSelect.self, in: f.window.contentView!) {
                select.open()
                try? await Task.sleep(for: .milliseconds(700))
                captureChildPanels(of: f.window, name: "select-\(suffix)", outDir: f.outDir)
                select.dismissPopup()
                try? await Task.sleep(for: .milliseconds(300))
            } else {
                print("MENUSHOT no CCSelect in the shell")
            }
        }
    }

    // MARK: - Menus

    /// The representative context menu: shortcuts, a checked submenu, a
    /// destructive-looking tail — built here, presented by the REAL
    /// presenter from a synthetic right-click on the timeline canvas.
    static func probeContextMenu() -> NSMenu {
        let menu = NSMenu()
        // A selector nothing implements: picking is inert, and (unlike
        // standard actions) macOS attaches no automatic item image.
        func item(_ title: String, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command,
                  icon: String? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: Selector(("menuShotProbeNoop:")), keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.target = nil
            item.image = icon.flatMap { CCIcon.image($0, pointSize: 12, weight: .semibold) }
            return item
        }
        menu.addItem(item("Split at Playhead", "b", icon: "scissors"))
        menu.addItem(item("Duplicate", "d", icon: "plus.square.on.square"))
        menu.addItem(item("Copy Effect Settings", "c", [.command, .option], icon: "doc.on.doc"))
        let levels = NSMenuItem(title: "Zoom Level", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Zoom Level")
        for (index, level) in ["1.5×", "2.0×", "2.5×", "3.0×", "4.0×"].enumerated() {
            let entry = item(level, "")
            entry.state = index == 1 ? .on : .off
            submenu.addItem(entry)
        }
        levels.submenu = submenu
        menu.addItem(levels)
        menu.addItem(.separator())
        let rename = NSMenuItem(title: "Rename…", action: nil, keyEquivalent: "")
        rename.isEnabled = false
        menu.addItem(rename)
        menu.addItem(item("Delete", "\u{8}", [], icon: "trash"))
        return menu
    }

    static func showContextMenu(on view: NSView) {
        guard let window = view.window else { return }
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        guard let event = NSEvent.mouseEvent(
            with: .rightMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        ) else { return }
        CaptureCatMenuPresenter.showContextMenu(probeContextMenu(), with: event, for: view)
    }

    /// Posts a key through the app's event queue, so local monitors (the
    /// menus' real keyboard path) see it exactly like a typed key.
    static func postKey(_ keyCode: UInt16, characters: String = "") {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode
        ) else { return }
        // Enqueued (not sendEvent): local monitors run as events are
        // DEQUEUED, which is where the menus' keyboard handling lives.
        NSApp.postEvent(event, atStart: false)
    }

    // MARK: - Capture

    static func findView<T: NSView>(_ type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        for sub in root.subviews {
            if let found = findView(type, in: sub) { return found }
        }
        return nil
    }

    /// Composites every visible child panel of `window` onto one backdrop at
    /// their real relative screen positions (a menu + its flyout land in
    /// one image), retina-scaled and upright.
    static func captureChildPanels(of window: NSWindow, name: String, outDir: URL) {
        let panels = (window.childWindows ?? []).filter { $0.isVisible }
        guard !panels.isEmpty else {
            print("MENUSHOT capture \(name) — no visible panel")
            return
        }
        let pad: CGFloat = 24
        let union = panels.map(\.frame).reduce(NSRect.null) { $0.union($1) }
        let canvas = NSSize(width: union.width + pad * 2, height: union.height + pad * 2)
        let scale: CGFloat = 2
        guard let ctx = CGContext(
            data: nil, width: Int(canvas.width * scale), height: Int(canvas.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setFillColor(CCTheme.color.background.cgColor)
        ctx.fill(CGRect(origin: .zero, size: canvas))
        for panel in panels {
            guard let content = panel.contentView, let layer = content.layer else { continue }
            let size = content.bounds.size
            let prior = layer.transform
            layer.transform = CATransform3DConcat(CATransform3DMakeScale(2, -2, 1),
                                                  CATransform3DMakeTranslation(0, size.height * 2, 0))
            let image = CARendererSnapshot.render(layer: layer, size: size, scale: 2)
            layer.transform = prior
            guard let image else { continue }
            // CG is Y-up like screen space: place by screen offsets.
            let rect = CGRect(
                x: panel.frame.minX - union.minX + pad,
                y: panel.frame.minY - union.minY + pad,
                width: size.width, height: size.height
            )
            ctx.draw(image, in: rect)
        }
        guard let out = ctx.makeImage() else { return }
        let url = outDir.appendingPathComponent("\(name).png")
        try? NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])?.write(to: url)
        print("MENUSHOT capture \(url.path) \(out.width)x\(out.height)")
    }
}
