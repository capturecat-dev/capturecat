import AppKit

final class FloatingPanelController: NSObject {
    private(set) var panel: NSPanel?

    /// Live panel content. Held here because this controller drives its
    /// `start()`/`teardown()` explicitly.
    private var recordingController: RecordingPanelViewController?

    func show(size: NSSize) {
        if let panel {
            panel.setContentSize(size)
            panel.contentView = makeContentView(size: size)
            panel.level = .screenSaver
            panel.sharingType = .none
            configureChrome(for: panel)
            position(panel: panel, for: size)
            panel.orderFrontRegardless()
            startRecordingControllerIfNeeded()
            return
        }

        let hostingView = makeContentView(size: size)
        hostingView.frame = NSRect(origin: .zero, size: size)

        // .titled is REQUIRED for Liquid Glass compositing — .borderless won't render glass
        let p = NSPanel(
            contentRect: hostingView.frame,
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Swift keeps strong references to this panel; the default
        // release-when-closed would over-release it and crash on reopen.
        p.isReleasedWhenClosed = false
        p.contentView = hostingView
        p.isFloatingPanel = true
        p.level = .screenSaver
        p.sharingType = .none
        p.isOpaque = false
        p.backgroundColor = .clear
        // Flat solid bar now — the window shadow does the lifting the glass
        // material used to.
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isMovableByWindowBackground = true

        // Hide titlebar chrome — we only need .titled for glass compositing.
        configureChrome(for: p)

        position(panel: p, for: size)

        p.orderFrontRegardless()
        panel = p
        startRecordingControllerIfNeeded()
    }

    func close() {
        teardownRecordingController()
        panel?.close()
        panel = nil
    }

    func updateContent() {
        guard let panel else { return }
        panel.contentView = makeContentView(size: panel.frame.size)
        startRecordingControllerIfNeeded()
    }

    // MARK: - Content

    /// The panel only ever hosts the recording toolbar, so it builds its own
    /// content. This used to take a SwiftUI view from `AppState` and ignore it
    /// whenever the native panel was enabled; the SwiftUI panel is gone, so the
    /// caller no longer passes anything.
    private func makeContentView(size: NSSize) -> NSView {
        teardownRecordingController()
        guard let appState = AppState.current else { return NSView(frame: NSRect(origin: .zero, size: size)) }
        let controller = RecordingPanelViewController(appState: appState)
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(origin: .zero, size: size)
        controller.view.autoresizingMask = [.width, .height]
        recordingController = controller
        return controller.view
    }

    /// Run once the content view is in a window, so the panel-resize call it
    /// makes finds a live panel.
    private func startRecordingControllerIfNeeded() {
        recordingController?.start()
    }

    private func teardownRecordingController() {
        recordingController?.teardown()
        recordingController = nil
    }

    /// `duration` lets a caller that is animating content in the same beat
    /// (the setup↔recording morph) put the window on the SAME clock; nil uses
    /// the standalone resize duration.
    func resize(to size: NSSize, animated: Bool = false, duration: TimeInterval? = nil,
                curve: CAMediaTimingFunction? = nil) {
        guard let panel else { return }
        panel.level = .screenSaver
        panel.sharingType = .none
        configureChrome(for: panel)

        guard animated, panel.isVisible else {
            panel.setContentSize(size)
            position(panel: panel, for: size)
            return
        }

        // Grow/shrink around the panel's CURRENT centre — the bar breathes in
        // place (including wherever the user dragged it) instead of jumping
        // back to the default screen anchor mid-animation.
        let current = panel.frame
        var target = NSRect(
            x: current.midX - size.width / 2,
            y: current.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        // The bar grew in the redesign — keep the animated target fully
        // on-screen even when the user parked it against an edge.
        if let visible = (panel.screen ?? NSScreen.main)?.visibleFrame {
            target.origin.x = min(max(target.minX, visible.minX + 8), visible.maxX - target.width - 8)
            target.origin.y = min(max(target.minY, visible.minY + 8), visible.maxY - target.height - 8)
        }

        // Window frame and Auto Layout animate in ONE group: never let the
        // window snap and the chips catch up, or vice versa.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = RecordingMotion.reduceMotion
                ? RecordingMotion.reducedDuration
                : (duration ?? RecordingMotion.resizeDuration)
            // Curve override rides with the duration override: the record-click
            // hero morph runs its own gentler curve, and the window must
            // decelerate identically or the bar lands before/after its chips.
            ctx.timingFunction = curve ?? RecordingMotion.settleCurve
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(target, display: true)
            panel.contentView?.layoutSubtreeIfNeeded()
        }
    }

    private func configureChrome(for panel: NSPanel) {
        panel.title = ""
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.toolbar = nil

        let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for buttonType in buttonTypes {
            guard let button = panel.standardWindowButton(buttonType) else { continue }
            button.isHidden = true
            button.alphaValue = 0
            button.isEnabled = false
            button.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        }
    }

    private func position(panel: NSPanel, for size: NSSize) {
        // Early in launch NSScreen.main can be nil — never bail, or the panel
        // stays at its creation origin (bottom-left). Always find a screen.
        guard let screen = NSScreen.main ?? panel.screen ?? NSScreen.screens.first else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - size.width / 2
        let y = screenFrame.minY + 80
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
