import AppKit

/// macOS-screenshot-style window picker: dimmed overlays cover every screen,
/// the window under the cursor is highlighted live, a click selects it, and
/// Escape cancels. Returns the picked `CGWindowID` (or nil on cancel) —
/// callers map it back to their `SCWindow` list.
///
/// Hover is a 30Hz `NSEvent.mouseLocation` poll (the CCHoverPoller recipe):
/// mouse-moved delivery to borderless multi-screen overlay windows is exactly
/// the kind of routing that drops events, and the poll cannot.
@MainActor
enum WindowSelectionOverlay {
    private static var session: Session?

    static var isActive: Bool { session != nil }

    static func show(completion: @escaping (CGWindowID?) -> Void) {
        guard session == nil else { return }
        session = Session(completion: { id in
            session = nil
            completion(id)
        })
    }

    @MainActor
    private final class Session {
        private var windows: [KeyableOverlayWindow] = []
        private var views: [WindowHighlightView] = []
        private var poller: Timer?
        private var hoveredWindowID: CGWindowID?
        private let completion: (CGWindowID?) -> Void
        private var finished = false

        init(completion: @escaping (CGWindowID?) -> Void) {
            self.completion = completion

            for screen in NSScreen.screens {
                let window = KeyableOverlayWindow(
                    contentRect: screen.frame,
                    styleMask: .borderless,
                    backing: .buffered,
                    defer: false
                )
                window.isReleasedWhenClosed = false
                window.level = .screenSaver
                window.sharingType = .none
                window.isOpaque = false
                window.backgroundColor = NSColor.black.withAlphaComponent(0.25)
                window.ignoresMouseEvents = false
                window.hasShadow = false
                window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

                let view = WindowHighlightView()
                view.frame = NSRect(origin: .zero, size: screen.frame.size)
                view.onPick = { [weak self] in self?.commit() }
                view.onCancel = { [weak self] in self?.finish(with: nil) }
                window.contentView = view
                window.alphaValue = 0
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(view)
                windows.append(window)
                views.append(view)
            }
            // The dim eases in rather than popping — the system picker feel.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                for window in windows { window.animator().alphaValue = 1 }
            }

            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { _ in
                MainActor.assumeIsolated { [weak self] in self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            poller = timer
            tick()
        }

        private func commit() {
            finish(with: hoveredWindowID)
        }

        private func finish(with id: CGWindowID?) {
            guard !finished else { return }
            finished = true
            poller?.invalidate()
            poller = nil
            let closing = windows
            windows = []
            views = []
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.15
                for window in closing { window.animator().alphaValue = 0 }
            }, completionHandler: {
                for window in closing {
                    window.contentView = nil
                    window.close()
                }
            })
            completion(id)
        }

        private func tick() {
            let mouse = NSEvent.mouseLocation
            let hit = Self.window(under: mouse)
            hoveredWindowID = hit?.id
            for (index, view) in views.enumerated() {
                guard let screen = view.window?.screen ?? NSScreen.screens[safe: index] else { continue }
                if let hit {
                    // CG global (y-down from primary's top-left) → this
                    // overlay's local Cocoa coords (y-up).
                    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
                    let cocoaRect = NSRect(
                        x: hit.bounds.origin.x,
                        y: primaryHeight - hit.bounds.origin.y - hit.bounds.height,
                        width: hit.bounds.width,
                        height: hit.bounds.height
                    )
                    let local = NSRect(
                        x: cocoaRect.origin.x - screen.frame.origin.x,
                        y: cocoaRect.origin.y - screen.frame.origin.y,
                        width: cocoaRect.width,
                        height: cocoaRect.height
                    )
                    view.highlightRect = local.intersects(view.bounds) ? local : nil
                } else {
                    view.highlightRect = nil
                }
            }
        }

        /// Topmost normal window under the point — front-to-back CG window
        /// list, layer 0 only, own process excluded (the overlays themselves
        /// and the recording bar must be un-pickable).
        private static func window(under cocoaPoint: NSPoint) -> (id: CGWindowID, bounds: CGRect)? {
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            let cgPoint = CGPoint(x: cocoaPoint.x, y: primaryHeight - cocoaPoint.y)
            guard let list = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
            ) as? [[String: Any]] else { return nil }
            let ownPID = Int32(ProcessInfo.processInfo.processIdentifier)
            for info in list {
                guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                      let pid = info[kCGWindowOwnerPID as String] as? Int32, pid != ownPID,
                      let alpha = info[kCGWindowAlpha as String] as? Double, alpha > 0.01,
                      let id = info[kCGWindowNumber as String] as? CGWindowID,
                      let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat]
                else { continue }
                let bounds = CGRect(
                    x: boundsDict["X"] ?? 0, y: boundsDict["Y"] ?? 0,
                    width: boundsDict["Width"] ?? 0, height: boundsDict["Height"] ?? 0
                )
                if bounds.contains(cgPoint) { return (id, bounds) }
            }
            return nil
        }
    }

    private final class KeyableOverlayWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    /// One screen's overlay. The hovered window's wash GLIDES between window
    /// frames on the house spring — the CCGlideHighlight recipe (snap into
    /// place on first landing, spring position+bounds on every later hop,
    /// fade out when nothing is hovered), scaled up from toolbar rows to
    /// whole windows.
    private final class WindowHighlightView: NSView {
        var onPick: (() -> Void)?
        var onCancel: (() -> Void)?

        /// Whether the wash has a live target (mirrors CCGlideHighlight's
        /// `current` — opacity is not a reliable first-landing test).
        private var hasTarget = false

        var highlightRect: NSRect? {
            didSet {
                guard highlightRect != oldValue else { return }
                if let rect = highlightRect {
                    let target = rect.insetBy(dx: 2, dy: 2)
                    if !hasTarget {
                        CATransaction.begin()
                        CATransaction.setDisableActions(true)
                        highlight.frame = target
                        CATransaction.commit()
                    } else {
                        CCMotion.spring(highlight, keyPath: "position",
                                         to: NSValue(point: CGPoint(x: target.midX, y: target.midY)), .snappy)
                        CCMotion.spring(highlight, keyPath: "bounds",
                                         to: NSValue(rect: CGRect(origin: .zero, size: target.size)), .snappy)
                    }
                    hasTarget = true
                    CCMotion.fade(highlight, keyPath: "opacity", to: 1, duration: 0.1)
                } else {
                    hasTarget = false
                    CCMotion.fade(highlight, keyPath: "opacity", to: 0, duration: 0.16)
                }
            }
        }

        private let highlight = CALayer()

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            wantsLayer = true
            highlight.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
            highlight.borderColor = NSColor.controlAccentColor.cgColor
            highlight.borderWidth = 2
            highlight.cornerRadius = 12
            highlight.cornerCurve = .continuous
            highlight.opacity = 0
            layer?.addSublayer(highlight)
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .pointingHand)
        }

        override func mouseDown(with event: NSEvent) { onPick?() }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
