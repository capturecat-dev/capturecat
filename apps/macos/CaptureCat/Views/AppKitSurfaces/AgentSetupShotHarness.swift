import AppKit

/// Headless acceptance probe for the Connect AI Agents window.
///
///   CaptureCat --agent-setup-shot
///
/// Same lessons as the other visual gates (CLAUDE.md §3): topology inside
/// the REAL window (transparent titlebar, full-size content), every client
/// row resolving a non-degenerate frame, the card dressed by CCMaterial, and
/// a dark→light retheme recoloring in place. Saves a capture beside the
/// report. DEBUG tooling.
@MainActor
enum AgentSetupShotHarness {
    static func run() -> Never {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        CCTheme.setMode(.dark, persist: false)

        let controller = AgentSetupViewController()
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.orderFrontRegardless()
        controller.view.layoutSubtreeIfNeeded()

        func snapshot(_ suffix: String) {
            guard let layer = controller.view.layer,
                  let img = CARendererSnapshot.render(
                    layer: layer, size: controller.view.bounds.size, scale: 2
                  ) else { return }
            let out = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("capturecat-agents-\(suffix).png")
            let rep = NSBitmapImageRep(cgImage: img)
            try? rep.representation(using: .png, properties: [:])?.write(to: out)
            print("AGENTS capture \(out.path)")
        }

        // 1. Topology — the root must not collapse; every row must lay out
        // wide and tall inside the card, inside the window.
        let rootSize = controller.view.bounds.size
        let rootOK = rootSize.width >= 500 && rootSize.height > 300
        let rows = controller.probeRows
        let degenerate = rows.filter { row in
            let frame = row.convert(row.bounds, to: controller.view)
            return frame.width < 300 || frame.height < 30
        }
        let cardOK = (controller.probeCard?.frame.height ?? 0) > 200
        print("AGENTS topology root=\(rootSize) ok=\(rootOK) rows=\(rows.count) degenerate=\(degenerate.count) cardOK=\(cardOK)")

        // 2. Material — the card carries CCMaterial sublayers (dressed, not a
        // flat wash). Probe by the named material layers, never sublayers.first.
        let materialLayers = (controller.probeCard?.layer?.sublayers ?? [])
            .filter { ($0.name ?? "").hasPrefix("ccmat.") }
        let dressed = !materialLayers.isEmpty
        print("AGENTS material dressed=\(dressed) layers=\(materialLayers.count)")

        // Captures are deferred a beat: a CARenderer snapshot taken in the
        // same runloop turn as layout renders blank (CLAUDE.md §3).
        let darkBG = controller.view.layer?.backgroundColor
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            snapshot("dark")

            // 3. Retheme — flipping to light must recolor the mounted view.
            CCTheme.setMode(.light, persist: false)
            controller.view.layoutSubtreeIfNeeded()
            let lightBG = controller.view.layer?.backgroundColor
            let rethemed = darkBG != nil && lightBG != nil && darkBG != lightBG
            print("AGENTS retheme ok=\(rethemed)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                snapshot("light")
                CCTheme.setMode(.dark, persist: false)
                let pass = rootOK && rows.count == 7 && degenerate.isEmpty && cardOK && dressed && rethemed
                print(pass ? "AGENTS PASS" : "AGENTS FAIL")
                exit(pass ? 0 : 1)
            }
        }
        app.run()
        exit(1)
    }
}
