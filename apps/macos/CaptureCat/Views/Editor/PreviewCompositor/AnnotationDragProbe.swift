import AppKit

/// `--annotation-drag-probe`
///
/// Reproduces the reported "shape doesn't follow the cursor after changing
/// padding" interactively but headless: builds the REAL compositor +
/// interaction stack in a window, synthesizes a mouse drag on a rectangle
/// annotation, and asserts the rendered shape tracked the pointer 1:1 —
/// at several padding values. A mapping bug (wrong rect, wrong divisor,
/// stale context after a padding change) fails this with the measured ratio.
@MainActor
enum AnnotationDragProbe {
    static func run() -> Never {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        var failures = 0
        for padding in [0.0, 48.0, 176.0, 268.0] {
            failures += probe(padding: padding) ? 0 : 1
        }
        print(failures == 0 ? "ANNOTATION-DRAG PASS" : "ANNOTATION-DRAG FAIL (\(failures) paddings)")
        exit(failures == 0 ? 0 : 1)
    }

    private static func probe(padding: Double) -> Bool {
        let canvasSize = NSSize(width: 960, height: 540)
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: 100, y: 100), size: canvasSize),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        let compositor = PreviewCompositorView(frame: NSRect(origin: .zero, size: canvasSize))
        compositor.rasterScaleOverride = 1
        window.contentView = compositor
        window.orderFrontRegardless()

        let project = PreviewParityHarness.makeFixtureProject()
        project.settings.backgroundPadding = padding
        var annotation = Annotation(type: .rectangle, startTime: 0, endTime: 12)
        annotation.x = 0.35; annotation.y = 0.35
        annotation.arrowEndX = 0.55; annotation.arrowEndY = 0.55
        project.annotations = [annotation]
        project.previewCanvasSize = canvasSize

        let input = PreviewCompositorView.FrameInput(
            project: project,
            currentTime: 1.0,
            isPlaying: false,
            cursorEvents: [],
            cursorCoordinateSize: CGSize(width: 1280, height: 800),
            videoSize: CGSize(width: 1280, height: 800),
            player: nil,
            cameraPlayer: nil,
            cameraPosterImage: nil,
            cameraVideoAspect: 16.0 / 9,
            videoPosterImage: PreviewParityHarness.syntheticVideoFrame(
                size: CGSize(width: 1280, height: 800)),
            selectedAnnotationID: annotation.id
        )
        compositor.render(input)
        compositor.layoutSubtreeIfNeeded()
        compositor.render(input)

        guard let interaction = findInteraction(in: compositor) else {
            print("ANNOTATION-DRAG padding=\(padding) FAIL no interaction view")
            return false
        }

        // Video rect the compositor just laid out — the shape's coordinate frame.
        let videoRect = compositor.lastVideoRect
        let startCanvas = CGPoint(
            x: videoRect.minX + videoRect.width * 0.45,
            y: videoRect.minY + videoRect.height * 0.45
        )
        // Stay inside the annotation's clamp slack (shape spans 0.35–0.55, so
        // 0.45 of the video width is available rightward) — the clamp stopping
        // a shape at the video edge is correct behavior, not a tracking bug.
        let dragPixels: CGFloat = min(120, videoRect.width * 0.45 * 0.9)

        send(.leftMouseDown, at: startCanvas, in: interaction, window: window, clickCount: 1)
        // Two moves — the first can be swallowed by drag thresholds.
        send(.leftMouseDragged, at: CGPoint(x: startCanvas.x + dragPixels / 2, y: startCanvas.y),
             in: interaction, window: window)
        send(.leftMouseDragged, at: CGPoint(x: startCanvas.x + dragPixels, y: startCanvas.y),
             in: interaction, window: window)
        send(.leftMouseUp, at: CGPoint(x: startCanvas.x + dragPixels, y: startCanvas.y),
             in: interaction, window: window)

        let moved = project.annotations[0]
        let deltaFraction = CGFloat(moved.x) - 0.35
        let deltaPixels = deltaFraction * videoRect.width
        let ratio = deltaPixels / dragPixels
        let pass = abs(ratio - 1.0) < 0.02
        print(String(
            format: "ANNOTATION-DRAG padding=%.0f videoRect=%.0f×%.0f moved=%.1fpx of %.0fpx ratio=%.3f %@",
            padding, videoRect.width, videoRect.height, deltaPixels, dragPixels, ratio,
            pass ? "OK" : "FAIL"
        ))
        window.orderOut(nil)
        return pass
    }

    private static func send(
        _ type: NSEvent.EventType,
        at canvasPoint: CGPoint,
        in view: NSView,
        window: NSWindow,
        clickCount: Int = 1
    ) {
        let windowPoint = view.convert(canvasPoint, to: nil)
        guard let event = NSEvent.mouseEvent(
            with: type, location: windowPoint,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: clickCount, pressure: 1
        ) else { return }
        switch type {
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        case .leftMouseUp: view.mouseUp(with: event)
        default: break
        }
    }

    private static func findInteraction(in root: NSView) -> PreviewInteractionView? {
        if let match = root as? PreviewInteractionView { return match }
        for sub in root.subviews {
            if let found = findInteraction(in: sub) { return found }
        }
        return nil
    }
}
