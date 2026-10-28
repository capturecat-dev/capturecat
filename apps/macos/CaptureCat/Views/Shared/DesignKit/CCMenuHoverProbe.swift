import AppKit

/// `--menu-hover-probe`
///
/// Opens a real CaptureCatMenuPresenter menu (with a checked item, like the cursor
/// style dropdown) and synthesizes hover transitions across rows, asserting
/// the gliding highlight actually lands on each hovered row — not just the
/// first / keyboard-selected one.
@MainActor
enum CCMenuHoverProbe {
    static func run() -> Never {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // The user's real pointer must not fight the synthetic sweep.
        CCMenu.probeIsolated = true

        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 400, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let anchor = NSView(frame: NSRect(x: 20, y: 20, width: 120, height: 24))
        window.contentView?.addSubview(anchor)
        window.orderFrontRegardless()

        // Mirror the Placement dropdown: 9 rows, one checked — the shipped
        // bug was hover dying after the first rows, so sweep EVERY row.
        let titles = ["Center", "Top Left", "Top", "Top Right", "Left",
                      "Right", "Bottom Left", "Bottom", "Bottom Right"]
        let menu = NSMenu()
        for (index, title) in titles.enumerated() {
            let item = NSMenuItem(title: title, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
            item.target = nil
            if index == 0 { item.state = .on }
            menu.addItem(item)
        }
        CaptureCatMenuPresenter.show(menu, from: anchor, edge: .below, selectedItem: menu.items[0])

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // Probe seams, never `sublayers.first`: the kit menu's rows and
            // its glide wash, through the presenter that opened them.
            guard let surface = CaptureCatMenuPresenter.probeRoot else {
                print("MENU-HOVER FAIL no menu panel — childWindows=\(String(describing: window.childWindows?.map { ($0.className, $0.isVisible, $0.frame) })) appWindows=\(NSApp.windows.count)")
                exit(1)
            }
            let list = surface.list
            let rows = list.rows
            guard rows.count == titles.count else {
                print("MENU-HOVER FAIL rows=\(rows.count)")
                exit(1)
            }
            let host: NSView = list
            let highlight = list.wash.layer

            var failures = 0
            // Sweep a synthetic pointer DOWN the menu through the list's
            // hover dispatcher (real window coordinates, real hit-testing) —
            // the wash must land on every row, not just the first ones.
            for index in rows.indices {
                let row = rows[index]
                move(over: row, in: list)
                host.layoutSubtreeIfNeeded()
                let expected = row.convert(row.bounds, to: host)
                // Model frame (animations land here immediately).
                let got = CGRect(
                    x: highlight.position.x - highlight.bounds.width / 2,
                    y: highlight.position.y - highlight.bounds.height / 2,
                    width: highlight.bounds.width, height: highlight.bounds.height
                )
                let ok = abs(got.midY - expected.midY) < 2 && highlight.opacity > 0.5
                print(String(format: "MENU-HOVER row=%d expectedY=%.0f gotY=%.0f opacity=%.2f %@",
                             index, expected.midY, got.midY, highlight.opacity, ok ? "OK" : "FAIL"))
                if !ok { failures += 1 }
            }
            // GLIDE assertion — the shipped bug: every row transition passed
            // through a cleared state and the wash SNAPPED in place instead
            // of gliding, while all the landing asserts above still passed.
            // Hop row 0 → row 8 and catch the wash's PRESENTATION mid-flight.
            move(over: rows[0], in: list)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let fromY = rows[0].convert(rows[0].bounds, to: host).midY
                let toY = rows[8].convert(rows[8].bounds, to: host).midY
                move(over: rows[8], in: list)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                    let presentedY = (highlight.presentation() ?? highlight).position.y
                    let low = min(fromY, toY) + 4, high = max(fromY, toY) - 4
                    let gliding = presentedY > low && presentedY < high
                    print(String(format: "MENU-HOVER glide from=%.0f to=%.0f presented@60ms=%.0f gliding=%@",
                                 fromY, toY, presentedY, gliding ? "true" : "FALSE"))
                    let pass = failures == 0 && gliding
                    print(pass ? "MENU-HOVER PASS" : "MENU-HOVER FAIL")
                    exit(pass ? 0 : 1)
                }
            }
        }
        app.run()
        exit(0)
    }

    /// Routes a pointer at the row's center through the list's hover
    /// DISPATCHER (the path the production hover poller drives) with real
    /// window coordinates — so hit-testing runs, not just state flipping.
    private static func move(over row: NSView, in list: CCMenuList) {
        let locationInWindow = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
        list.routeHover(windowPoint: locationInWindow)
    }

    /// `--menu-hover-live`: the REAL end-to-end check. Opens an on-screen
    /// window whose menu deliberately OVERHANGS the window's bottom edge (the
    /// geometry where every event-based hover mechanism died), then warps the
    /// actual system cursor across every row and asserts the wash follows.
    /// CGWarpMouseCursorPosition needs no permissions, and production hover
    /// POLLS NSEvent.mouseLocation — so this drives the exact shipping path,
    /// window server included. The cursor is restored afterwards.
    static func runLive() -> Never {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let originalMouse = NSEvent.mouseLocation

        // Short window near the top of the screen: a 9-row menu anchored at
        // its bottom must overhang the window frame.
        guard let screen = NSScreen.main else { print("MENU-LIVE FAIL no screen"); exit(1) }
        let windowRect = NSRect(
            x: screen.visibleFrame.midX - 220,
            y: screen.visibleFrame.maxY - 220,
            width: 440, height: 160
        )
        let window = NSWindow(contentRect: windowRect, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "CaptureCat hover probe"
        let anchor = NSView(frame: NSRect(x: 20, y: 12, width: 140, height: 24))
        window.contentView?.addSubview(anchor)
        window.orderFrontRegardless()

        let titles = ["Center", "Top Left", "Top", "Top Right", "Left",
                      "Right", "Bottom Left", "Bottom", "Bottom Right"]
        let menu = NSMenu()
        for (index, title) in titles.enumerated() {
            let item = NSMenuItem(title: title, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
            item.target = nil
            if index == 0 { item.state = .on }
            menu.addItem(item)
        }
        CaptureCatMenuPresenter.show(menu, from: anchor, edge: .below, selectedItem: menu.items[0])

        @MainActor func warp(to cocoaPoint: NSPoint) {
            let mainHeight = NSScreen.screens[0].frame.height
            CGWarpMouseCursorPosition(CGPoint(x: cocoaPoint.x, y: mainHeight - cocoaPoint.y))
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard let surface = CaptureCatMenuPresenter.probeRoot else {
                print("MENU-LIVE FAIL no menu panel")
                exit(1)
            }
            let panel = surface.panel
            let surfaceRect = surface.stage.surfaceScreenRect ?? panel.frame
            let overhang = surfaceRect.minY < window.frame.minY
            print("MENU-LIVE panel=\(surfaceRect) window=\(window.frame) overhangsWindow=\(overhang)")
            let rows = surface.list.rows
            let host: NSView = surface.list
            let highlight = surface.list.wash.layer
            guard rows.count == titles.count else {
                print("MENU-LIVE FAIL rows=\(rows.count)")
                exit(1)
            }

            var failures = 0
            var index = 0
            @MainActor func step() {
                guard index < rows.count else {
                    warp(to: originalMouse)
                    print(failures == 0 ? "MENU-LIVE PASS" : "MENU-LIVE FAIL \(failures)")
                    exit(failures == 0 ? 0 : 1)
                }
                let row = rows[index]
                let rowOnScreen = panel.convertToScreen(row.convert(row.bounds, to: nil))
                warp(to: NSPoint(x: rowOnScreen.midX, y: rowOnScreen.midY))
                // Three poller ticks later, the wash must sit on this row.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    MainActor.assumeIsolated { assessRow() }
                }
                @MainActor func assessRow() {
                    host.layoutSubtreeIfNeeded()
                    let expected = row.convert(row.bounds, to: host)
                    let gotY = highlight.position.y
                    let ok = abs(gotY - expected.midY) < 2 && highlight.opacity > 0.5
                    let inWindow = rowOnScreen.midY >= window.frame.minY
                    print(String(format: "MENU-LIVE row=%d insideParentWindow=%@ expectedY=%.0f gotY=%.0f opacity=%.2f %@",
                                 index, inWindow ? "y" : "N", expected.midY, gotY, highlight.opacity, ok ? "OK" : "FAIL"))
                    if !ok { failures += 1 }
                    index += 1
                    step()
                }
            }
            step()
        }
        app.run()
        exit(0)
    }
}
