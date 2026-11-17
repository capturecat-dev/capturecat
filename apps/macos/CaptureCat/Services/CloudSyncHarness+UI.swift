import AppKit
import Foundation

/// `--cloud-sync-test`'s Mac-only UI part: the real editor top bar and
/// progress dialog in real windows (the engine sections are shared with
/// iOS in StudioHarness/CloudSyncHarness.swift).
extension CloudSyncHarness {
    // MARK: - UI probe

    final class ProbeLog {
        var anchors: [NSView] = []
        var cancelled = false
    }

    /// Synthesized click through the view's REAL mouseDown/mouseUp path.
    static func click(_ view: NSView) {
        guard let window = view.window else { return }
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        if let down = event(.leftMouseDown), let up = event(.leftMouseUp) {
            view.mouseDown(with: down)
            view.mouseUp(with: up)
        }
    }

    /// The REAL `EditorToolbarController` bar, hosted the way the editor
    /// window hosts it (in-content, pinned top/leading/trailing at 52 pt under
    /// a transparent full-size titlebar — see EditorWindowContentController),
    /// measured at three widths; then the REAL progress dialog presented over
    /// that window. Windows are parked off-screen.
    static func probeUI(_ checks: Checks, project: Project) async {
        let expect = checks.expect
        print("ui: editor top bar")
        let log = ProbeLog()
        let toolbar = EditorToolbarController(
            project: project,
            onShowBrowser: {},
            onExport: {},
            onToggleInspector: {},
            onWebEditor: { log.anchors.append($0) }
        )
        let root = NSView()
        root.wantsLayer = true
        let content = NSViewController()
        content.view = root
        let bar = toolbar.barView
        bar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 52),
        ])
        let window = NSWindow(contentViewController: content)
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.setContentSize(NSSize(width: 1400, height: 420))
        window.setFrameOrigin(NSPoint(x: -20_000, y: 200))
        window.orderFrontRegardless()
        toolbar.install(on: window)
        defer { window.close() }

        let buttons = bar.subviews.compactMap { $0 as? CCButton }
        guard let web = buttons.first(where: { $0.title == "Web Editor" }),
              let export = buttons.first(where: { $0.title == "Export…" }) else {
            expect(false, "top bar carries a Web Editor button beside Export")
            return
        }
        expect(true, "top bar carries a Web Editor button beside Export")
        let cluster = bar.subviews.first { $0 is NSStackView }

        for width in [1400.0, 1100.0, 900.0] {
            window.setContentSize(NSSize(width: width, height: 420))
            root.layoutSubtreeIfNeeded()
            let tag = "@\(Int(width))"
            let w = web.frame
            let e = export.frame
            expect(w.width > 40 && w.height > 10, "\(tag): Web Editor button rendered (\(Int(w.width))×\(Int(w.height)))")
            expect(abs((e.minX - w.maxX) - CCSpace.sm) < 0.5, "\(tag): sits \(Int(CCSpace.sm))pt left of Export")
            expect(bar.bounds.contains(w), "\(tag): inside the bar")
            expect(abs(w.midY - e.midY) < 1, "\(tag): on Export's centre line")
            if let cluster {
                expect(cluster.frame.maxX <= w.minX + 0.5, "\(tag): never overlaps the aspect cluster")
            }
            expect(!web.hasAmbiguousLayout && !export.hasAmbiguousLayout, "\(tag): unambiguous layout")
            if let superview = root.superview {
                let hit = root.hitTest(bar.convert(NSPoint(x: w.midX, y: w.midY), to: superview))
                expect(hit.map { $0 === web || $0.isDescendant(of: web) } == true, "\(tag): nothing covers it (hit test)")
            }
        }
        writeDrawnShot(of: bar, name: "cloud-topbar-900.png")
        click(web)
        expect(log.anchors.count == 1 && log.anchors.first === web,
               "a click hands the button itself to the Web Editor menu as its anchor")

        print("ui: progress dialog")
        let dialog = CloudSyncProgressDialog(title: "Opening in Web Editor", subtitle: project.name)
        dialog.onCancel = { log.cancelled = true }
        window.setContentSize(NSSize(width: 1100, height: 600))
        dialog.present(over: window)
        try? await Task.sleep(for: .milliseconds(500))
        let card = dialog.probeCard
        card.layoutSubtreeIfNeeded()
        let barFrame = dialog.probeBar.convert(dialog.probeBar.bounds, to: card)
        expect(card.window?.isVisible == true, "progress card is on screen over the editor window")
        expect(barFrame.width > 200 && card.bounds.contains(barFrame),
               "progress bar laid out inside the card (\(Int(barFrame.width))pt wide)")
        let weights: [CloudProjectSync.Progress.Phase: ClosedRange<Double>] = [.hashing: 0...0.12, .uploading: 0.12...0.86]
        dialog.update(CloudProjectSync.Progress(phase: .uploading, fraction: 0.5, message: "Uploading 3 files…"), weights: weights)
        expect(abs(dialog.probeBar.doubleValue - 0.49) < 1e-9, "upload at 50% → overall 49% (\(dialog.probeBar.doubleValue))")
        expect(dialog.probeStatus == "Uploading 3 files…", "status line follows the phase")
        dialog.update(CloudProjectSync.Progress(phase: .hashing, fraction: 1, message: "Preparing files…"), weights: weights)
        expect(dialog.probeBar.doubleValue >= 0.49, "the bar never runs backwards when a phase re-enters")
        // Pull Web Edits drives the same card through its download phase.
        dialog.update(CloudProjectSync.Progress(phase: .downloading, fraction: 0.5, message: "Downloading 3 files…"),
                      weights: CloudSyncController.pullWeights)
        expect(abs(dialog.probeBar.doubleValue - 0.56) < 1e-9 && dialog.probeStatus == "Downloading 3 files…",
               "pull: downloading at 50% → overall 56%, status follows (\(dialog.probeBar.doubleValue))")
        try? await Task.sleep(for: .milliseconds(400)) // let the fill glide land before the shot
        writeShot(of: card, name: "cloud-progress.png")
        click(dialog.probeCancelButton)
        expect(log.cancelled && dialog.probeStatus == "Cancelling…" && !dialog.probeCancelButton.isEnabled,
               "Cancel (real click) stops the sync and says so")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            dialog.dismiss { continuation.resume() }
        }
        expect(card.window?.isVisible != true, "dismiss takes the card down")
    }

    /// `--shot`: PNGs of what the UI checks measured, for eyeballing. Written
    /// to the (sandboxed) temp dir — ~/Library/Containers/so.capturecat.CaptureCat/
    /// Data/tmp/capturecat-cloud-sync/ — like the other probe shots.
    static func writeShot(of view: NSView, name: String) {
        guard CommandLine.arguments.contains("--shot"),
              let layer = view.layer,
              let raw = CARendererSnapshot.render(layer: layer, size: view.bounds.size, scale: 2) else { return }
        // CARenderer hands back a bottom-up buffer; flip so the PNG reads upright.
        guard let ctx = CGContext(
            data: nil, width: raw.width, height: raw.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return }
        ctx.translateBy(x: 0, y: CGFloat(raw.height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(raw, in: CGRect(x: 0, y: 0, width: raw.width, height: raw.height))
        guard let image = ctx.makeImage() else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("capturecat-cloud-sync", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
        print("  · shot \(url.path)")
    }

    /// Draw-based capture (`cacheDisplay`) for chrome CARenderer sees as an
    /// empty tree off-screen — the same split `--editor-shell-shot` uses.
    static func writeDrawnShot(of view: NSView, name: String) {
        guard CommandLine.arguments.contains("--shot"),
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: rep)
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("capturecat-cloud-sync", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("  · shot \(url.path)")
    }
}
