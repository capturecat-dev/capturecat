import AppKit
import ScreenCaptureKit

/// Full-screen drag-to-select overlay for the Area capture source.
///
/// This was an `NSViewRepresentable` wrapping `AreaDragView`, but every caller
/// went through `showOverlay` — the wrapper was never embedded in anything.
enum AreaSelectionOverlay {
    static func showOverlay(for display: SCDisplay, completion: @escaping (CGRect?) -> Void) {
        guard let screen = NSScreen.screens.first(where: {
            guard let id = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
            return id == display.displayID
        }) else {
            completion(nil)
            return
        }

        // Borderless windows refuse key status by default — without key status
        // the view never gets keyDown and Escape can't cancel the overlay.
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
        window.backgroundColor = NSColor.black.withAlphaComponent(0.2)
        window.ignoresMouseEvents = false
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let dragView = AreaDragView()
        dragView.frame = NSRect(origin: .zero, size: screen.frame.size)
        dragView.displayBounds = CGRect(x: 0, y: 0, width: display.width, height: display.height)
        // Weak captures + clearing hostWindow break the window ↔ contentView
        // retain cycle so the full-screen overlay is actually released.
        dragView.onSelection = { [weak window, weak dragView] rect in
            window?.close()
            dragView?.hostWindow = nil
            completion(rect)
        }
        dragView.onCancel = { [weak window, weak dragView] in
            window?.close()
            dragView?.hostWindow = nil
            completion(nil)
        }

        window.contentView = dragView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(dragView)

        // Keep a reference so the window isn't deallocated while on screen
        dragView.hostWindow = window
    }
}

private final class KeyableOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private class AreaDragView: NSView {
    var onSelection: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    var displayBounds: CGRect = .zero
    var hostWindow: NSWindow?

    private var dragStart: NSPoint?
    private var dragCurrent: NSPoint?
    private var selectionLayer: CAShapeLayer?

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true

        let layer = CAShapeLayer()
        layer.fillColor = NSColor.systemBlue.withAlphaComponent(0.15).cgColor
        layer.strokeColor = NSColor.white.cgColor
        layer.lineWidth = 2
        layer.lineDashPattern = [6, 4]
        self.layer?.addSublayer(layer)
        selectionLayer = layer
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        dragCurrent = dragStart
    }

    override func mouseDragged(with event: NSEvent) {
        dragCurrent = convert(event.locationInWindow, from: nil)
        updateSelectionRect()
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = dragStart, let end = dragCurrent else { return }
        let rect = rectFromPoints(start, end)

        // Require minimum size (10x10 points)
        guard rect.width > 10 && rect.height > 10 else {
            dragStart = nil
            dragCurrent = nil
            selectionLayer?.path = nil
            return
        }

        // Convert from view coordinates to display pixel coordinates
        let scaleX = displayBounds.width / bounds.width
        let scaleY = displayBounds.height / bounds.height
        let pixelRect = CGRect(
            x: rect.origin.x * scaleX,
            y: (bounds.height - rect.origin.y - rect.height) * scaleY, // flip Y
            width: rect.width * scaleX,
            height: rect.height * scaleY
        )

        onSelection?(pixelRect)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    private func rectFromPoints(_ a: NSPoint, _ b: NSPoint) -> NSRect {
        NSRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        )
    }

    private func updateSelectionRect() {
        guard let start = dragStart, let current = dragCurrent else { return }
        let rect = rectFromPoints(start, current)
        selectionLayer?.path = CGPath(rect: rect, transform: nil)
    }
}
