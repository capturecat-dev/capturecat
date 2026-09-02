import AppKit

/// Browser UX probe:
///
///     CaptureCat --browser-shot [<outDir>]
///
/// Builds the REAL ProjectBrowserViewController (real stores) inside a
/// window matching the editor shell's chrome, captures PNGs at a wide and a
/// narrow (minimum) size, and asserts the responsive-toolbar geometry:
/// chips never collide with search, search condenses to its loupe when
/// tight, controls share the 28/32pt height scale. Follows the
/// --recording-panel-shot / --editor-shell-shot pattern: standalone
/// offscreen window, never touches a running app. DEBUG tooling; never
/// reached in a normal launch.
@MainActor
enum BrowserShotHarness {
    private static var failures = 0

    static func run() -> Never {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            await execute()
            print(failures == 0 ? "BROWSER-SHOT OK" : "BROWSER-SHOT FAILED (\(failures))")
            exit(failures == 0 ? 0 : 1)
        }
        app.run()
        exit(0)
    }

    private static func expect(_ condition: Bool, _ label: String) {
        print("\(condition ? "PASS" : "FAIL") \(label)")
        if !condition { failures += 1 }
    }

    private static func execute() async {
        let outDir: URL = {
            let args = CommandLine.arguments
            if let i = args.firstIndex(of: "--browser-shot"), i + 1 < args.count,
               !args[i + 1].hasPrefix("-") {
                return URL(fileURLWithPath: args[i + 1])
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("capturecat-browser-shot")
        }()
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        AppState.suppressAutoToolbar = true
        let appState = AppState()
        let browser = ProjectBrowserViewController(appState: appState)

        // Same chrome as the real editor window (transparent title bar,
        // full-size content) so the safe-area top inset matches the app.
        let window = NSWindow(contentViewController: browser)
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 1280, height: 800))
        window.setFrameOrigin(NSPoint(x: -6000, y: -6000)) // far offscreen
        window.orderFrontRegardless()

        window.makeFirstResponder(nil)
        await settle()
        checkPopupGeometry(in: window)
        checkGeometry(in: browser.view, label: "WIDE")
        shoot(window, to: outDir.appendingPathComponent("browser-wide.png"))

        // Minimum window size — the full-width row scales, nothing overlaps.
        window.setContentSize(NSSize(width: 900, height: 600))
        window.makeFirstResponder(nil)
        await settle()
        checkGeometry(in: browser.view, label: "NARROW")
        shoot(window, to: outDir.appendingPathComponent("browser-narrow.png"))

        // ── Click-to-open regression probe ───────────────────────────────
        // hitTest at the first card's midpoint must resolve INTO the grid
        // (not an invisible overlay), and a synthetic click must open the
        // capture (appState.currentProject flips non-nil).
        let grid = browser.harnessCollectionView
        if grid.numberOfSections > 0, grid.numberOfItems(inSection: 0) > 0,
           let cardFrame = grid.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame {
            let midInGrid = NSPoint(x: cardFrame.midX, y: cardFrame.midY)
            let midInRoot = grid.convert(midInGrid, to: browser.view)
            let hit = browser.view.hitTest(browser.view.convert(midInRoot, to: browser.view.superview))
            var node: NSView? = hit
            var insideGrid = false
            while let current = node {
                if current === grid { insideGrid = true; break }
                node = current.superview
            }
            expect(insideGrid, "CLICK: hitTest at card midpoint lands in the grid "
                + "(hit \(hit.map { String(describing: type(of: $0)) } ?? "nil"))")

            // A real click = routing (covered by the hitTest above; NSCollection-
            // View drops selection clicks in non-key windows, and a headless
            // harness process can never become the active app) + the selection
            // delegate. Drive the delegate half exactly as a plain click does.
            appState.currentProject = nil
            // pendingSeekOutputTime must SURVIVE the open flow untouched —
            // only the editor timeline consumes it (viewDidAppear, after the
            // player is ready; the full editor load can't run headless, so
            // that consumption is covered by the deep-link path in app).
            appState.pendingSeekOutputTime = 12.5
            let path = IndexPath(item: 0, section: 0)
            grid.selectItems(at: [path], scrollPosition: [])
            print("CLICKDBG pre: selection=\(grid.selectionIndexPaths) currentEvent=\(String(describing: NSApp.currentEvent?.type))")
            (grid.delegate as? NSCollectionViewDelegate)?
                .collectionView?(grid, didSelectItemsAt: [path])
            print("CLICKDBG post: browser=\(appState.showProjectBrowser) project=\(String(describing: appState.currentProject?.name))")
            await settle()
            expect(appState.currentProject != nil, "CLICK: card selection opens the capture")
            expect(appState.pendingSeekOutputTime == 12.5,
                   "SEEK: pendingSeekOutputTime survives the open flow "
                   + "(\(String(describing: appState.pendingSeekOutputTime)))")
            appState.pendingSeekOutputTime = nil
            appState.currentProject = nil
            appState.showProjectBrowser = true
            await settle()
        } else {
            print("NOTE CLICK: no grid items on this machine — skipping click probe")
        }

        // ── Repeat-search probe ──────────────────────────────────────────
        // Two consecutive queries through the real pipeline: results must
        // update each time, and clearing must restore the full grid.
        let baseline = browser.harnessEntryCount
        browser.harnessSetQuery("zzz-no-such-capture-1")
        await settle()
        expect(browser.harnessEntryCount == 0,
               "SEARCH2: query A filters (\(browser.harnessEntryCount) of \(baseline))")
        browser.harnessSetQuery("")
        await settle()
        expect(browser.harnessEntryCount == baseline,
               "SEARCH2: clearing restores baseline (\(browser.harnessEntryCount) vs \(baseline))")
        browser.harnessSetQuery("zzz-no-such-capture-2")
        await settle()
        expect(browser.harnessEntryCount == 0,
               "SEARCH2: query B filters again (\(browser.harnessEntryCount))")
        browser.harnessSetQuery("")
        await settle()
        expect(browser.harnessEntryCount == baseline,
               "SEARCH2: second clear restores baseline (\(browser.harnessEntryCount))")

        // ── Seek-consumption probe (REAL player, headless) ───────────────
        // The half a unit test can't cover: setupPlayer(initialTime:) on an
        // actual AVPlayer must land on the target and SURVIVE the ready-wait
        // + first-frame warm-up re-anchor (the exact mechanism that used to
        // clobber the raced viewDidAppear scrub). Full shell/timeline load
        // still can't run headless; this exercises the consuming player path
        // the shell now feeds.
        let seekFixtureDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("capturecat-seek-probe", isDirectory: true)
        try? FileManager.default.createDirectory(at: seekFixtureDir, withIntermediateDirectories: true)
        let seekVideoURL = seekFixtureDir.appendingPathComponent("seek.mov")
        if await PlaybackObserverHarness.writeVideo(
            to: seekVideoURL, seconds: 4.0, size: CGSize(width: 640, height: 400), tint: 0.5
        ) {
            let seekProject = Project(videoURL: seekVideoURL, duration: 4.0)
            let playbackProbe = EditorPlaybackController(appState: nil)
            await playbackProbe.setupPlayer(for: seekProject, initialTime: 2.0)
            // Let readiness + the muted play/pause warm-up settle.
            for _ in 0..<12 {
                try? await Task.sleep(for: .milliseconds(150))
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                if abs(playbackProbe.currentTime - 2.0) < 0.05 { break }
            }
            expect(abs(playbackProbe.currentTime - 2.0) < 0.05,
                   "SEEK: setupPlayer(initialTime: 2.0) survives load + warm-up "
                   + "(currentTime=\(playbackProbe.currentTime))")
            playbackProbe.teardown(saving: nil)
            try? FileManager.default.removeItem(at: seekFixtureDir)
        } else {
            expect(false, "SEEK: could not synthesize probe video")
        }

        // Suggestions panel with fixture rows (recents + typed matches).
        browser.harnessShowSuggestions([
            .query("stripe invoice"),
            .capture(id: UUID(), kind: "video", title: "Untitled Recording",
                     snippet: "…invoice #1042 · stripe dashboard · paid…", time: 161),
            .capture(id: UUID(), kind: "image", title: "stripe.com",
                     snippet: "…financial infrastructure to grow your revenue…", time: nil),
            .capture(id: UUID(), kind: "note", title: "Remember the invoice", snippet: nil, time: nil),
            .recent("onboarding flow"),
        ])
        await settle()
        if let panel = findAll(SearchSuggestionsPanel.self, in: browser.view).first {
            expect(!panel.isHidden, "SUGGEST: panel visible with fixture rows")
            let frame = panel.superview!.convert(panel.frame, to: browser.view)
            expect(frame.height > 100, "SUGGEST: panel has rows (h=\(frame.height))")
        } else {
            expect(false, "SUGGEST: panel present")
        }
        shoot(window, to: outDir.appendingPathComponent("browser-suggestions.png"))

        // Reopen-after-dismiss: the panel must come back with fresh rows.
        browser.harnessDismissSuggestions()
        expect(browser.harnessSuggestionsPanelHidden, "SUGGEST: panel dismisses")
        browser.harnessShowSuggestions([.recent("second opening")])
        expect(!browser.harnessSuggestionsPanelHidden, "SUGGEST: panel reopens after dismiss")
        browser.harnessDismissSuggestions()

        // ── Onboarding panes ─────────────────────────────────────────────
        // Permissions (1), account (2), finish (3) —
        // forced via jumpToStep, captured at the wizard's fixed 560×600.
        let onboarding = OnboardingViewController(appState: appState)
        let onboardingWindow = NSWindow(contentViewController: onboarding)
        onboardingWindow.styleMask = [.titled, .closable, .fullSizeContentView]
        onboardingWindow.titlebarAppearsTransparent = true
        onboardingWindow.titleVisibility = .hidden
        onboardingWindow.isReleasedWhenClosed = false
        onboardingWindow.setContentSize(NSSize(width: 560, height: 600))
        onboardingWindow.setFrameOrigin(NSPoint(x: -6000, y: -6000))
        onboardingWindow.orderFrontRegardless()
        for (index, name) in [(1, "onboarding-permissions"), (2, "onboarding-account"), (3, "onboarding-default-tool"), (4, "onboarding-finish")] {
            onboarding.jumpToStep(index)
            await settle()
            // Vertical-rhythm report: frames of the page's stagger targets.
            if let page = onboarding.view.subviews
                .flatMap(\.subviews)
                .compactMap({ $0 as? NSView })
                .first(where: { String(describing: type(of: $0)).contains("StepPageView") }),
               let stack = page.subviews.first(where: { $0 is NSStackView }) as? NSStackView {
                for sub in stack.arrangedSubviews {
                    let f = sub.superview!.convert(sub.frame, to: onboarding.view)
                    print("RHYTHM \(name) \(String(describing: type(of: sub))) y=\(Int(f.minY)) h=\(Int(f.height))")
                }
            }
            shoot(onboardingWindow, to: outDir.appendingPathComponent("\(name).png"))
        }
        onboardingWindow.close()
    }

    private static func settle() async {
        for _ in 0..<8 {
            try? await Task.sleep(for: .milliseconds(120))
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    // MARK: - Geometry checks

    private static func checkPopupGeometry(in window: NSWindow) {
        guard let root = window.contentView else {
            expect(false, "POPUP: test window has a content view")
            return
        }

        // A deliberately nested hierarchy catches accidental mixing of
        // view-local, window, and screen coordinate spaces.
        let container = NSView(frame: NSRect(x: 123, y: 77, width: 400, height: 300))
        let anchor = NSView(frame: NSRect(x: 41, y: 29, width: 200, height: 100))
        root.addSubview(container)
        container.addSubview(anchor)
        defer { container.removeFromSuperview() }

        let localRect = NSRect(x: 12, y: 8, width: 90, height: 28)
        let expectedRect = window.convertToScreen(anchor.convert(localRect, to: nil))
        let resolvedRect = CaptureCatPopupGeometry.screenRect(of: localRect, in: anchor)
        expect(rectsMatch(resolvedRect, expectedRect),
               "POPUP: nested anchor resolves exactly in screen coordinates")

        let windowPoint = NSPoint(x: 501, y: 333)
        guard let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: windowPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ) else {
            expect(false, "POPUP: synthetic context-menu event created")
            return
        }

        let expectedPoint = window.convertToScreen(NSRect(origin: windowPoint, size: .zero)).origin
        let resolvedPoint = CaptureCatPopupGeometry.screenPoint(for: event, in: anchor)
        expect(pointsMatch(resolvedPoint, expectedPoint),
               "POPUP: context menu does not double-apply nested view offsets")
    }

    private static func rectsMatch(_ lhs: NSRect?, _ rhs: NSRect, tolerance: CGFloat = 0.01) -> Bool {
        guard let lhs else { return false }
        return pointsMatch(lhs.origin, rhs.origin, tolerance: tolerance)
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    private static func pointsMatch(
        _ lhs: NSPoint?,
        _ rhs: NSPoint,
        tolerance: CGFloat = 0.01
    ) -> Bool {
        guard let lhs else { return false }
        return abs(lhs.x - rhs.x) <= tolerance && abs(lhs.y - rhs.y) <= tolerance
    }

    private static func findAll<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        var found: [T] = []
        func walk(_ view: NSView) {
            if let match = view as? T { found.append(match) }
            for sub in view.subviews { walk(sub) }
        }
        walk(root)
        return found
    }

    private static func checkGeometry(in root: NSView, label: String) {
        root.layoutSubtreeIfNeeded()
        print("GEO \(label) rootWidth=\(root.bounds.width) windowWidth=\(root.window?.frame.width ?? -1)")

        // Type filter is a CCSegmented now: one control, four segments.
        guard let segmented = findAll(CCSegmented.self, in: root).first else {
            expect(false, "\(label): filter segmented present")
            return
        }
        let segFrame = segmented.superview!.convert(segmented.frame, to: root)
        expect(abs(segFrame.height - 30) < 0.5, "\(label): segmented height 30 (\(segFrame.height))")

        guard let search = findAll(CCSearchField.self, in: root).first else {
            expect(false, "\(label): search bar present")
            return
        }
        let searchFrame = search.superview!.convert(search.frame, to: root)
        expect(abs(searchFrame.height - 36) < 0.5, "\(label): search height 36 (\(searchFrame.height))")
        expect(search.layer?.cornerRadius == 18, "\(label): search pill radius 18")
        // Full-width row: 16pt inset from each side of the content area
        // (root minus the 208pt sidebar).
        let expectedWidth = root.bounds.width - 208 - 32
        expect(abs(searchFrame.width - expectedWidth) < 1,
               "\(label): search spans content width (\(searchFrame.width) vs \(expectedWidth))")

        // Row 1: segmented clear of the New Recording button (a CCButton now).
        if let newRec = findAll(CCButton.self, in: root).first {
            let newRecFrame = newRec.superview!.convert(newRec.frame, to: root)
            expect(segFrame.maxX + 8 <= newRecFrame.minX,
                   "\(label): segmented clear of New Recording (\(segFrame.maxX) vs \(newRecFrame.minX))")
        } else {
            expect(false, "\(label): New Recording CCButton present")
        }

        // Buttons on the 32pt scale.
        let pills = findAll(HoverPillButton.self, in: root)
        expect(!pills.isEmpty, "\(label): pill buttons present")
        for pill in pills where !pill.isHidden {
            expect(abs(pill.frame.height - 32) < 0.5, "\(label): button height 32 (\(pill.frame.height))")
        }

        // Grid fills its row: last card's right edge lands within one gutter
        // + inset of the scroll area's right edge (no huge ragged margin).
        if let grid = findAll(NSCollectionView.self, in: root).first,
           grid.numberOfSections > 0, grid.numberOfItems(inSection: 0) > 0 {
            let frames = (0..<grid.numberOfItems(inSection: 0)).compactMap {
                grid.layoutAttributesForItem(at: IndexPath(item: $0, section: 0))?.frame
            }
            if let maxX = frames.map(\.maxX).max() {
                let slack = grid.bounds.width - maxX
                expect(slack <= 40.5, "\(label): grid fills width (right slack \(slack))")
            }
            let widths = Set(frames.map { ($0.width * 2).rounded() / 2 })
            expect(widths.count == 1, "\(label): uniform card widths \(widths)")
        } else {
            print("NOTE \(label): no grid items on this machine — skipping fill checks")
        }
    }

    // MARK: - Capture

    private static func shoot(_ window: NSWindow, to url: URL) {
        guard let content = window.contentView,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            expect(false, "capture \(url.lastPathComponent)")
            return
        }
        content.cacheDisplay(in: content.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            expect(false, "encode \(url.lastPathComponent)")
            return
        }
        // The app is sandboxed: a destination outside the container is not
        // writable — fall back to the container's temp dir rather than
        // "succeeding" with no file (same contract as headless --export).
        do {
            try png.write(to: url)
            print("SHOT \(url.path)")
        } catch {
            let fallback = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(url.lastPathComponent)
            do {
                try png.write(to: fallback)
                print("SHOT \(fallback.path) (requested dir not writable from sandbox)")
            } catch {
                expect(false, "write \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }
}
