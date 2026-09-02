import AppKit

/// Headless acceptance probe for the CCKit dialog.
///
///   CaptureCat --capalert-shot
///
/// Presents a CCAlert over a real parent window (the same beginSheet path the
/// app uses), then asserts three things the visual gates have been burned by
/// before:
///  • topology — the card resolved a non-degenerate size inside its panel;
///  • motion   — the entrance spring is genuinely mid-flight shortly after
///    presentation (scale strictly between 0.96 and 1.0), not snapped;
///  • outcome  — clicking the default button reports index 0 and tears the
///    scrim + panel down.
/// Saves a settled CARenderer capture beside the report. DEBUG tooling.
@MainActor
enum CCAlertHarness {
    static func run() -> Never {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let parent = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 720, height: 480),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        parent.contentView?.wantsLayer = true
        parent.contentView?.layer?.backgroundColor = CCTheme.color.background.cgColor
        parent.orderFrontRegardless()

        let alert = CCAlert(
            title: "Delete Capture?",
            message: "Are you sure you want to delete \"Probe\"? This cannot be undone."
        )
        alert.addButton("Delete", role: .destructive)
        alert.addButton("Cancel")

        var chosen: Int? = nil
        alert.beginSheet(for: parent) { index in chosen = index }

        // Mid-flight sample: the smooth spring (response 0.42) is nowhere near
        // settled 60ms in, so a snapped animation fails this deterministically.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            guard let panel = alertPanel(of: parent),
                  let card = panel.contentView, let layer = card.layer else {
                print("CAPALERT FAIL no alert panel/card in window tree")
                exit(1)
            }
            let scale = (layer.presentation() ?? layer).value(forKeyPath: "transform.scale.x") as? CGFloat ?? -1
            let midFlight = scale > 0.961 && scale < 0.999
            print("CAPALERT motion scale@60ms=\(scale) midFlight=\(midFlight)")

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                let size = card.bounds.size
                print("CAPALERT card size=\(size)")
                let sane = size.width >= 340 && size.height >= 80
                let out = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("capturecat-capalert.png")
                if let img = CARendererSnapshot.render(layer: layer, size: size, scale: 2) {
                    let rep = NSBitmapImageRep(cgImage: img)
                    try? rep.representation(using: .png, properties: [:])?.write(to: out)
                    print("CAPALERT capture \(out.path)")
                }

                // Responsive: shrink the parent below the card's design
                // floor; the card must re-clamp inside the window and stay
                // centered over it before we dismiss.
                parent.setContentSize(NSSize(width: 320, height: 420))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    card.layoutSubtreeIfNeeded()
                    let clamped = card.bounds.width <= 320 && card.bounds.width >= 280
                    let centered = abs(panel.frame.midX - parent.frame.midX) < 2
                    print("CAPALERT responsive card=\(card.bounds.size) parent=\(parent.frame.size) "
                        + "clamped=\(clamped) centered=\(centered)")

                    // Fire the default (index 0) button. The row is laid out
                    // cancel-first, default trailing, so match by title.
                    if let button = firstButton(in: card, titled: "Delete") {
                        button.onClick?()
                    } else {
                        print("CAPALERT FAIL no CCButton in card")
                        exit(1)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        let dismissed = alertPanel(of: parent) == nil
                        let pass = sane && midFlight && chosen == 0 && dismissed && clamped && centered
                        print("CAPALERT choice=\(String(describing: chosen)) dismissed=\(dismissed)")
                        print(pass ? "CAPALERT PASS" : "CAPALERT FAIL")
                        exit(pass ? 0 : 1)
                    }
                }
            }
        }
        app.run()
        exit(0)
    }

    /// `--capdialog-shot`: presents a CCDialog with real form content and
    /// asserts the scrollable middle actually resolves — the export sheet
    /// once rendered header+footer with an invisible body because the
    /// document view had no size, and a static "did it open" check passed.
    static func runDialog() -> Never {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let parent = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        parent.orderFrontRegardless()

        let dialog = CCDialog(title: "Export Video", width: 430)
        var rows: [NSView] = []
        for index in 0..<6 {
            let row = InspectorKitViews.row("Row \(index)", control: NSTextField(labelWithString: "value \(index)"))
            rows.append(row)
            dialog.addContent(row)
        }
        let slider = CCSlider(title: "Quality")
        slider.range = 0...1
        slider.doubleValue = 0.85
        dialog.addContent(slider)
        rows.append(slider)
        dialog.addFooter(CCButton(title: "Cancel"))
        dialog.addFooter(CCButton(title: "Export", style: .primary))
        dialog.present(over: parent)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let card = dialog.card
            card.layoutSubtreeIfNeeded()
            // Every content row must resolve a real on-card frame.
            let bad = rows.filter { row in
                let frame = row.convert(row.bounds, to: card)
                return frame.height < 10 || frame.width < 100 || !card.bounds.intersects(frame)
            }
            let tallEnough = card.bounds.height > 260
            print("CAPDIALOG card=\(card.bounds.size) badRows=\(bad.count)")
            if let layer = card.layer,
               let img = CARendererSnapshot.render(layer: layer, size: card.bounds.size, scale: 2) {
                let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("capturecat-capdialog.png")
                let rep = NSBitmapImageRep(cgImage: img)
                try? rep.representation(using: .png, properties: [:])?.write(to: out)
                print("CAPDIALOG capture \(out.path)")
            }
            print("CAPDIALOG body ok=\(bad.isEmpty && tallEnough)")

            // Responsive: shrink the parent well below the 430pt design
            // width; the card must re-clamp inside the window (width AND
            // height) and re-center over it.
            parent.setContentSize(NSSize(width: 360, height: 420))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                card.layoutSubtreeIfNeeded()
                let fits = card.bounds.width <= 360 && card.bounds.width >= 280
                    && card.bounds.height <= parent.frame.height
                let panelFrame = card.window?.frame ?? .zero
                let centered = abs(panelFrame.midX - parent.frame.midX) < 2
                print("CAPDIALOG responsive card=\(card.bounds.size) parent=\(parent.frame.size) "
                    + "fits=\(fits) centered=\(centered)")

                // Entrance styles: present a SECOND dialog with `.slideUp()`
                // and sample its translation mid-spring — the card must be
                // genuinely between off-stage (−24) and settled (0), proving
                // the entrance vocabulary actually animates (motion law:
                // never assert only settled frames).
                let riser = CCDialog(title: "Slide Up", width: 300)
                riser.entrance = .slideUp()
                let probeRow = NSTextField(labelWithString: "entrance probe")
                riser.addContent(probeRow)
                riser.setMaxContentHeight(440)   // mirror the export sheet
                riser.addFooter(CCButton(title: "OK", style: .primary))
                riser.present(over: parent)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                    let layer = riser.card.layer
                    let ty = (layer?.presentation() ?? layer)?
                        .value(forKeyPath: "transform.translation.y") as? CGFloat ?? 99
                    let entranceMidFlight = ty < -1 && ty > -23
                    print("CAPDIALOG entrance slideUp ty@60ms=\(ty) midFlight=\(entranceMidFlight)")

                    // Growth bounce: expand the riser's content; the panel
                    // must OVERSHOOT its target height (the house bounce) and
                    // then settle exactly on it. A flat ease never overshoots,
                    // so this fails if the growth curve is dropped anywhere.
                    let tall = NSView()
                    tall.translatesAutoresizingMaskIntoConstraints = false
                    tall.heightAnchor.constraint(equalToConstant: 120).isActive = true
                    let topBefore = (riser.card.window?.frame.maxY ?? -1).rounded()
                    riser.animateContentChange {
                        riser.addContent(tall)
                    }
                    // Watch the pinned edge EVERY tick, not at two samples —
                    // sub-pixel rounding jitter (±1px per frame) lives between
                    // point samples and shipped as "glitchy at top".
                    // Screen position of an EXISTING content row: the growth
                    // law says existing content must hold rock-still while the
                    // bottom opens — any drift here is the "bounce elsewhere".
                    func rowScreenY() -> CGFloat {
                        guard let window = probeRow.window else { return -1 }
                        return window.convertToScreen(
                            probeRow.convert(probeRow.bounds, to: nil)
                        ).minY
                    }
                    let rowBefore = rowScreenY()
                    let rowInCardBefore = probeRow.convert(NSPoint.zero, to: riser.card).y
                    var topDrift: CGFloat = 0
                    var rowDrift: CGFloat = 0
                    var rowSigned: CGFloat = 0
                    var rowInCardDrift: CGFloat = 0
                    let startHeight = riser.card.window?.frame.height ?? -1
                    var sawEarlyMidFlight = false
                    var dumped = false
                    let watchStart = CACurrentMediaTime()
                    let driftWatch = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
                        MainActor.assumeIsolated {
                            let topNow = riser.card.window?.frame.maxY ?? -1
                            topDrift = max(topDrift, abs(topNow - topBefore))
                            let delta = rowScreenY() - rowBefore
                            if abs(delta) > abs(rowSigned) { rowSigned = delta }
                            rowDrift = max(rowDrift, abs(delta))
                            let inCard = probeRow.convert(NSPoint.zero, to: riser.card).y
                            rowInCardDrift = max(rowInCardDrift, abs(inCard - rowInCardBefore))
                            _ = dumped
                            _ = watchStart
                            // The grow must ANIMATE from its old height — a
                            // window that layout-snapped to target before the
                            // driver's first tick never shows a height
                            // meaningfully between start and target.
                            let winH = riser.card.window?.frame.height ?? -1
                            if winH > startHeight + 5, winH < startHeight + 90 {
                                sawEarlyMidFlight = true
                            }
                        }
                    }
                    let targetHeight = riser.card.fittingSize.height
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                        let peak = riser.card.window?.frame.height ?? -1
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            driftWatch.invalidate()
                            let settled = riser.card.window?.frame.height ?? -1
                            // Top edge PINNED for the WHOLE animation — only
                            // the bottom travels (the growth-edge law).
                            let topPinned = topDrift < 0.5
                            let contentStill = rowDrift < 0.5
                            let bounced = peak > targetHeight + 2 && abs(settled - targetHeight) < 1.5
                                && topPinned && contentStill && sawEarlyMidFlight
                            print("CAPDIALOG growth target=\(targetHeight) peak@220ms=\(peak) settled=\(settled) "
                                + "topDrift=\(topDrift) rowDrift=\(rowDrift) rowSigned=\(rowSigned) "
                                + "rowInCardDrift=\(rowInCardDrift) topPinned=\(topPinned) "
                                + "contentStill=\(contentStill) bounced=\(bounced)")

                            // Toggle thumb — the travel is a REAL spring:
                            // sampled mid-flight between the endpoints (the
                            // old scale-to-1.0 "spring" was a no-op and the
                            // thumb rode a flat ease; this catches that).
                            let toggle = CaptureCatToggle()
                            riser.addContent(toggle, fullWidth: false)
                            riser.card.layoutSubtreeIfNeeded()
                            let thumbFrom = toggle.probeThumbLayer?.position.x ?? -1
                            toggle.isOn = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                                let thumb = toggle.probeThumbLayer
                                let target = thumb?.position.x ?? -1
                                let x = (thumb?.presentation() ?? thumb)?.position.x ?? -1
                                let thumbMidFlight = x > thumbFrom + 0.5 && x < target - 0.5
                                print("CAPDIALOG toggle thumb \(thumbFrom) -> \(target) @60ms=\(x) midFlight=\(thumbMidFlight)")
                                let pass = bad.isEmpty && tallEnough && fits && centered
                                    && entranceMidFlight && bounced && thumbMidFlight
                                print(pass ? "CAPDIALOG PASS" : "CAPDIALOG FAIL")
                                exit(pass ? 0 : 1)
                            }
                        }
                    }
                }
            }
        }
        app.run()
        exit(0)
    }

    private static func alertPanel(of parent: NSWindow) -> NSWindow? {
        // The dialog card panel is the borderless child that can become key
        // (the scrim never can).
        parent.childWindows?.first { $0.styleMask == [.borderless] && $0.canBecomeKey && $0.isVisible }
    }

    private static func firstButton(in root: NSView, titled title: String) -> CCButton? {
        if let match = root as? CCButton, match.title == title { return match }
        for sub in root.subviews {
            if let found = firstButton(in: sub, titled: title) { return found }
        }
        return nil
    }
}
