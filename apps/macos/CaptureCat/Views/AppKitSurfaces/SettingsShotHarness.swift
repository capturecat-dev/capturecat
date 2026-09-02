import AppKit

/// Headless acceptance probe for the Settings window.
///
///   CaptureCat --settings-shot
///
/// Asserts the lessons the visual gates have been burned by (CLAUDE.md §3):
///  • topology — sidebar rows and the selected pane resolve non-degenerate
///    frames inside the REAL window (same hosting chain the app uses);
///  • behavior — clicking through every section swaps the pane in place, and
///    a control write-through actually lands in AppState (flipped back so a
///    probe run never changes the user's stored settings);
///  • theming — a dark→light flip recolors the mounted sidebar in place.
/// Saves settled captures beside the report. DEBUG tooling.
@MainActor
enum SettingsShotHarness {
    static func run() -> Never {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        AppState.suppressAutoToolbar = true
        CCTheme.setMode(.dark, persist: false)
        let appState = AppState()

        let controller = SettingsViewController(appState: appState)
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .fullSizeContentView]
        window.setContentSize(NSSize(width: 715, height: 470))
        window.orderFrontRegardless()
        controller.view.layoutSubtreeIfNeeded()

        func snapshot(_ suffix: String) {
            guard let layer = controller.view.layer,
                  let img = CARendererSnapshot.render(
                    layer: layer, size: controller.view.bounds.size, scale: 2
                  ) else { return }
            let out = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("capturecat-settings-\(suffix).png")
            let rep = NSBitmapImageRep(cgImage: img)
            try? rep.representation(using: .png, properties: [:])?.write(to: out)
            print("SETTINGS capture \(out.path)")
        }

        // 1. Topology — the ROOT view first: a rogue required constraint
        // (the original vertical-divider bug) collapses the whole window to
        // 1pt while every child still "has a frame". Then rows and pane.
        let rootSize = controller.view.bounds.size
        let rootOK = rootSize.width > 600 && rootSize.height > 300
        print("SETTINGS root=\(rootSize) ok=\(rootOK)")
        let rows = controller.probeSidebarRows
        let degenerateRows = rows.filter { row in
            let frame = row.convert(row.bounds, to: controller.view)
            return frame.width < 50 || frame.height < 10
        }
        let paneOK = (controller.probeCurrentPane?.frame.height ?? 0) > 20
        print("SETTINGS topology rows=\(rows.count) degenerate=\(degenerateRows.count) paneOK=\(paneOK)")

        // 2. Pane switching — walk every section; the pane must be replaced
        // and re-laid-out each time.
        var switchOK = true
        for section in SettingsSection.allCases {
            let before = controller.probeCurrentPane
            controller.select(section: section, animated: false)
            controller.view.layoutSubtreeIfNeeded()
            let pane = controller.probeCurrentPane
            let swapped = pane !== before || section == controller.probeSidebarRows.first?.section
            let framed = (pane?.frame.height ?? 0) > 20
            if !(swapped && framed) {
                switchOK = false
                print("SETTINGS switch FAIL section=\(section.title) swapped=\(swapped) framed=\(framed)")
            }
        }
        print("SETTINGS switching ok=\(switchOK)")

        // 3. Write-through — flip Auto Zoom via the model the toggle writes,
        // then restore, so the probe never changes stored settings.
        controller.select(section: .general, animated: false)
        let original = appState.autoZoomNewRecordings
        appState.autoZoomNewRecordings = !original
        let flipped = appState.autoZoomNewRecordings == !original
        appState.autoZoomNewRecordings = original
        print("SETTINGS write-through ok=\(flipped)")

        // Captures happen after the runloop has pumped a display pass —
        // rendering the layer tree synchronously here yields a blank sheet.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            snapshot("dark")

            // 4. Live theming — mounted sidebar recolors on the flip.
            let darkFill = controller.probeSidebarRows.first?.superview?.superview?.layer?.backgroundColor
            CCTheme.setMode(.light, persist: false)
            controller.view.layoutSubtreeIfNeeded()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                snapshot("light")
                let lightFill = controller.probeSidebarRows.first?.superview?.superview?.layer?.backgroundColor
                let themed = darkFill != lightFill
                print("SETTINGS theme-swap changed=\(themed)")

                let pass = rootOK && degenerateRows.isEmpty && paneOK && switchOK && flipped && themed
                print(pass ? "SETTINGS PASS" : "SETTINGS FAIL")
                exit(pass ? 0 : 1)
            }
        }
        app.run()
        exit(0)
    }
}
