import AppKit
import AVFoundation
import CoreMedia

// Free-floating live camera preview (Screen Studio style).
//
// A borderless always-on-top panel showing the selected camera through an
// `AVCaptureVideoPreviewLayer` on the SAME `AVCaptureSession` the recorder
// uses (`AppState.cameraManager.captureSession`), masked to the true squircle
// (`CameraStyleMath.superellipsePath` — the identical path the editor preview
// and exporter share). Draggable anywhere on any screen — no corner snapping —
// with the position persisted in UserDefaults and restored on the next show.
//
// Capture exclusion: the panel sets `sharingType = .none` AND the recorder's
// display filters exclude every window of this process
// (`ScreenRecorder.refreshExcludedWindows`, called by AppState right after a
// recording starts), so the bubble never appears in recordings.

enum CameraFloatMetrics {
    static let diameterKey = "capturecat.cameraFloatDiameter"
    static let originKey = "capturecat.cameraFloatOrigin"

    /// Default bubble size — ~200pt like Screen Studio's.
    static var savedDiameter: CGFloat {
        let stored = UserDefaults.standard.double(forKey: diameterKey)
        return stored > 0 ? CGFloat(stored) : 200
    }

    static func setDiameter(_ value: CGFloat) {
        UserDefaults.standard.set(Double(value), forKey: diameterKey)
        NotificationCenter.default.post(name: .cameraBubbleSizeChanged, object: nil)
    }

    /// Content rect: square for webcams; device-aspect rect for muxed
    /// phone/iPad screens (a square crop of a portrait screen is useless).
    static func contentSize(for device: AVCaptureDevice?, isScreenDevice: Bool) -> NSSize {
        let diameter = savedDiameter
        guard isScreenDevice, let device else {
            return NSSize(width: diameter, height: diameter)
        }
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let aspect: CGFloat = dims.width > 0 && dims.height > 0
            ? CGFloat(dims.width) / CGFloat(dims.height) : 9.0 / 19.5
        let longSide = diameter * 1.6
        return aspect < 1
            ? NSSize(width: max(90, longSide * aspect), height: longSide)
            : NSSize(width: longSide, height: max(90, longSide / aspect))
    }

    /// Slack around the content for the drop shadow to paint into.
    static let shadowPadding: CGFloat = 24

    static func panelSize(for contentSize: NSSize) -> NSSize {
        NSSize(width: contentSize.width + shadowPadding * 2,
               height: contentSize.height + shadowPadding * 2)
    }

    // MARK: - Position persistence

    static func saveOrigin(_ origin: NSPoint) {
        UserDefaults.standard.set("\(origin.x),\(origin.y)", forKey: originKey)
    }

    static func savedOrigin() -> NSPoint? {
        guard let raw = UserDefaults.standard.string(forKey: originKey) else { return nil }
        let parts = raw.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return NSPoint(x: parts[0], y: parts[1])
    }

    /// Restored origin, kept mostly on SOME screen — a monitor that was
    /// unplugged since last time must not strand the bubble off-screen.
    static func restoredOrigin(panelSize: NSSize) -> NSPoint {
        if let saved = savedOrigin() {
            let frame = NSRect(origin: saved, size: panelSize)
            for screen in NSScreen.screens where screen.visibleFrame.intersects(frame.insetBy(dx: 40, dy: 40)) {
                return saved
            }
        }
        // Default: bottom-right of the main screen, clear of the recording bar.
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: visible.maxX - panelSize.width - 12, y: visible.minY + 12)
    }
}

// MARK: - Squircle view

/// Superellipse-masked live preview with a soft shadow and a quiet hairline —
/// the whole surface is a drag handle (the panel moves by window background).
@MainActor
final class CameraFloatSquircleView: NSView {
    private let shadowLayer = CALayer()
    private let clip = NSView()
    private let strokeLayer = CAShapeLayer()
    private let maskLayer = CAShapeLayer()
    private let preview: CameraPreviewNSView?
    private let placeholder = NSImageView()
    private var themeObservation: CCThemeObservation?

    init(session: AVCaptureSession?, contentSize: NSSize, isScreenDevice: Bool) {
        preview = session.map { session in
            let view = CameraPreviewNSView()
            // Same mirroring rule as everywhere else in the app: webcams
            // mirror like a mirror, phone screens are shown as-is.
            view.mirrored = !isScreenDevice
            view.attach(session: session)
            return view
        }
        super.init(frame: NSRect(origin: .zero, size: CameraFloatMetrics.panelSize(for: contentSize)))
        wantsLayer = true

        // Subtle lift; the squircle outline IS the shadow path so the shadow
        // hugs the shape, not a bounding box.
        shadowLayer.backgroundColor = NSColor.clear.cgColor
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = 0.35
        shadowLayer.shadowRadius = 12
        shadowLayer.shadowOffset = CGSize(width: 0, height: -5)
        layer?.addSublayer(shadowLayer)

        clip.wantsLayer = true
        clip.layer?.backgroundColor = NSColor.black.cgColor
        clip.layer?.mask = maskLayer
        clip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clip)

        let pad = CameraFloatMetrics.shadowPadding
        NSLayoutConstraint.activate([
            clip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            clip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            clip.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            clip.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),
        ])

        if let preview {
            preview.translatesAutoresizingMaskIntoConstraints = false
            clip.addSubview(preview)
            NSLayoutConstraint.activate([
                preview.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
                preview.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
                preview.topAnchor.constraint(equalTo: clip.topAnchor),
                preview.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
            ])
        } else {
            placeholder.image = NSImage(
                systemSymbolName: isScreenDevice ? "iphone" : "camera.fill",
                accessibilityDescription: nil
            )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 24, weight: .regular))
            placeholder.translatesAutoresizingMaskIntoConstraints = false
            clip.addSubview(placeholder)
            NSLayoutConstraint.activate([
                placeholder.centerXAnchor.constraint(equalTo: clip.centerXAnchor),
                placeholder.centerYAnchor.constraint(equalTo: clip.centerYAnchor),
            ])
        }

        // Quiet hairline riding the squircle edge, above the video.
        strokeLayer.fillColor = NSColor.clear.cgColor
        strokeLayer.lineWidth = 1.5
        clip.layer?.addSublayer(strokeLayer)

        toolTip = "Drag to move — right-click for size."
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Chrome only — the feed (and its black backdrop + shadow) never rethemes.
    private func applyTheme() {
        let ink: NSColor = CCTheme.isDark ? .white : .black
        strokeLayer.strokeColor = ink.withAlphaComponent(0.35).cgColor
        placeholder.contentTintColor = ink.withAlphaComponent(0.3)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = CameraStyleMath.superellipsePath(in: clip.bounds)
        maskLayer.frame = clip.bounds
        maskLayer.path = path
        strokeLayer.frame = clip.bounds
        strokeLayer.path = path
        shadowLayer.frame = bounds
        // Shadow path is in this view's coordinates — offset by the clip inset.
        shadowLayer.shadowPath = CameraStyleMath.superellipsePath(in: clip.frame)
        CATransaction.commit()
    }

    /// The whole bubble is a drag surface; there are no controls inside it.
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func rightMouseDown(with event: NSEvent) {
        CaptureCatMenuPresenter.showContextMenu(sizeMenu(), with: event, for: self)
    }

    private func sizeMenu() -> NSMenu {
        let menu = NSMenu()
        for (title, value) in [("Small", CGFloat(150)), ("Medium", CGFloat(200)), ("Large", CGFloat(270))] {
            let item = NSMenuItem(title: title, action: #selector(pickSize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = abs(CameraFloatMetrics.savedDiameter - value) < 1 ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func pickSize(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? CGFloat else { return }
        CameraFloatMetrics.setDiameter(value)
    }
}

// MARK: - Panel controller

/// Owns the floating preview panel: shows it over everything, restores the
/// remembered position, persists every move, and never appears in captures.
/// Follows FloatingPanelController's panel conventions (non-activating,
/// strong-referenced, `isReleasedWhenClosed = false`).
@MainActor
final class CameraFloatPreviewController {
    private(set) var panel: NSPanel?
    private var moveObserver: NSObjectProtocol?

    var isVisible: Bool { panel != nil }

    func show(session: AVCaptureSession?, device: AVCaptureDevice?, isScreenDevice: Bool) {
        guard panel == nil else { return }

        let contentSize = CameraFloatMetrics.contentSize(for: device, isScreenDevice: isScreenDevice)
        let panelSize = CameraFloatMetrics.panelSize(for: contentSize)
        let view = CameraFloatSquircleView(
            session: session, contentSize: contentSize, isScreenDevice: isScreenDevice
        )
        view.autoresizingMask = [.width, .height]

        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        p.isReleasedWhenClosed = false
        p.contentView = view
        p.isFloatingPanel = true
        p.level = .floating
        p.identifier = CameraBubbleGeometry.panelIdentifier
        p.sharingType = .none // never in screenshots/recordings
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false // squircle-hugging shadow drawn by the view
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isMovableByWindowBackground = true

        p.setFrameOrigin(CameraFloatMetrics.restoredOrigin(panelSize: panelSize))
        p.orderFrontRegardless()
        panel = p

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: p, queue: .main
        ) { [weak p] _ in
            MainActor.assumeIsolated {
                guard let p else { return }
                CameraFloatMetrics.saveOrigin(p.frame.origin)
            }
        }
    }

    func hide() {
        if let moveObserver {
            NotificationCenter.default.removeObserver(moveObserver)
            self.moveObserver = nil
        }
        guard let panel else { return }
        panel.orderOut(nil)
        // Detach the preview layer BEFORE any camera-session teardown (same
        // rationale as AppState.dismissLiveCameraPreviewPanel).
        panel.contentView = nil
        panel.close()
        self.panel = nil
    }
}
