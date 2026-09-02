import AppKit
import AVFoundation
import CoreMedia

/// Camera-bubble preferences and geometry — the ONE source of truth shared by
/// the SwiftUI recording panel and its native twin. Both read the same
/// UserDefaults keys and the same size/corner math, so the bubble lands in the
/// identical spot no matter which panel implementation is live.
enum CameraBubbleGeometry {
    static let diameterKey = "capturecat.cameraBubbleDiameter"
    static let cornerKey = "capturecat.cameraBubbleCorner"
    static let padding: CGFloat = 16

    /// AppState finds and tears down the live preview panel by this identifier
    /// — both panel implementations must stamp it.
    static let panelIdentifier = NSUserInterfaceItemIdentifier("so.capturecat.CaptureCat.liveCameraPreview")

    static var savedDiameter: CGFloat {
        let stored = UserDefaults.standard.double(forKey: diameterKey)
        return stored > 0 ? CGFloat(stored) : 180
    }

    static var savedCorner: String {
        UserDefaults.standard.string(forKey: cornerKey) ?? "bottomRight"
    }

    static func setDiameter(_ value: CGFloat) {
        UserDefaults.standard.set(Double(value), forKey: diameterKey)
        NotificationCenter.default.post(name: .cameraBubbleSizeChanged, object: nil)
    }

    static func setCorner(_ corner: String) {
        UserDefaults.standard.set(corner, forKey: cornerKey)
    }

    /// Rounded rect matching the device's real aspect — landscape for webcams,
    /// portrait/landscape for iPhone/iPad screens.
    static func contentSize(for device: AVCaptureDevice?, isScreenDevice: Bool) -> NSSize {
        let diameter = savedDiameter
        let aspect: CGFloat = {
            guard let device else { return 4.0 / 3.0 }
            let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            guard dims.width > 0, dims.height > 0 else { return 4.0 / 3.0 }
            return CGFloat(dims.width) / CGFloat(dims.height)
        }()
        let longSide = diameter * (isScreenDevice ? 1.9 : 1.5)
        return aspect < 1
            ? NSSize(width: max(80, longSide * aspect), height: longSide)   // portrait
            : NSSize(width: longSide, height: max(80, longSide / aspect))   // landscape
    }

    static func panelSize(for contentSize: NSSize) -> NSSize {
        NSSize(width: contentSize.width + padding * 2, height: contentSize.height + padding * 2)
    }

    static func origin(corner: String, panelSize: NSSize, on screen: NSScreen) -> NSPoint {
        let visible = screen.visibleFrame
        let margin: CGFloat = 12
        switch corner {
        case "topLeft":
            return NSPoint(x: visible.minX + margin, y: visible.maxY - panelSize.height - margin)
        case "topRight":
            return NSPoint(x: visible.maxX - panelSize.width - margin, y: visible.maxY - panelSize.height - margin)
        case "bottomLeft":
            return NSPoint(x: visible.minX + margin, y: visible.minY + margin)
        default:
            return NSPoint(x: visible.maxX - panelSize.width - margin, y: visible.minY + margin)
        }
    }

    static func cornerRadius(for contentSize: NSSize) -> CGFloat {
        min(contentSize.width, contentSize.height) * 0.16
    }
}

// MARK: - Camera bubble

/// Native twin of `CameraPreviewBubble`: black rounded rect wrapping the live
/// `AVCaptureVideoPreviewLayer`, hairline white stroke, drop shadow, and the
/// Small/Medium/Large right-click menu.
@MainActor
final class CameraBubbleNSView: NSView {
    private let shadowHost = NSView()
    private let clip = NSView()
    private var preview: CameraPreviewNSView?
    private let placeholder = NSImageView()
    private let contentSize: NSSize
    private var themeObservation: CCThemeObservation?

    init(session: AVCaptureSession?, contentSize: NSSize, isScreenDevice: Bool) {
        self.contentSize = contentSize
        let padding = CameraBubbleGeometry.padding
        super.init(frame: NSRect(
            origin: .zero,
            size: CameraBubbleGeometry.panelSize(for: contentSize)
        ))
        wantsLayer = true
        let radius = CameraBubbleGeometry.cornerRadius(for: contentSize)

        shadowHost.wantsLayer = true
        shadowHost.layer?.cornerRadius = radius
        shadowHost.layer?.cornerCurve = .continuous
        // `.shadow(color: .black.opacity(0.4), radius: 10, y: 4)` — shadow
        // stays black in both themes; only chrome colors live in applyTheme().
        shadowHost.layer?.shadowColor = NSColor.black.cgColor
        shadowHost.layer?.shadowOpacity = 0.4
        shadowHost.layer?.shadowRadius = 10
        shadowHost.layer?.shadowOffset = CGSize(width: 0, height: -4)

        clip.wantsLayer = true
        clip.layer?.cornerRadius = radius
        clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true
        clip.layer?.borderWidth = 2.5

        if let session {
            // Webcams mirror (like a mirror); phone screens don't — identical
            // rule to the SwiftUI bubble.
            let view = CameraPreviewNSView()
            view.mirrored = !isScreenDevice
            view.attach(session: session)
            view.translatesAutoresizingMaskIntoConstraints = false
            clip.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
                view.topAnchor.constraint(equalTo: clip.topAnchor),
                view.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
            ])
            preview = view
        } else {
            placeholder.image = NSImage(
                systemSymbolName: isScreenDevice ? "iphone" : "camera.fill",
                accessibilityDescription: nil
            )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 22, weight: .regular))
            placeholder.translatesAutoresizingMaskIntoConstraints = false
            clip.addSubview(placeholder)
            NSLayoutConstraint.activate([
                placeholder.centerXAnchor.constraint(equalTo: clip.centerXAnchor),
                placeholder.centerYAnchor.constraint(equalTo: clip.centerYAnchor),
            ])
        }

        for sub in [shadowHost, clip] { sub.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(shadowHost)
        shadowHost.addSubview(clip)
        NSLayoutConstraint.activate([
            shadowHost.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            shadowHost.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            shadowHost.topAnchor.constraint(equalTo: topAnchor, constant: padding),
            shadowHost.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding),
            clip.leadingAnchor.constraint(equalTo: shadowHost.leadingAnchor),
            clip.trailingAnchor.constraint(equalTo: shadowHost.trailingAnchor),
            clip.topAnchor.constraint(equalTo: shadowHost.topAnchor),
            clip.bottomAnchor.constraint(equalTo: shadowHost.bottomAnchor),
        ])

        toolTip = "Drag to move — snaps to corners. Right-click for size."
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func applyTheme() {
        // The bubble backing stays a neutral surface behind the live feed;
        // border/placeholder are chrome and follow the theme's ink.
        let ink: NSColor = CCTheme.isDark ? .white : .black
        shadowHost.layer?.backgroundColor = CCTheme.color.elevated.cgColor
        clip.layer?.borderColor = ink.withAlphaComponent(0.9).cgColor
        placeholder.contentTintColor = ink.withAlphaComponent(0.3)
    }

    override func rightMouseDown(with event: NSEvent) {
        CaptureCatMenuPresenter.showContextMenu(sizeMenu(), with: event, for: self)
    }

    private func sizeMenu() -> NSMenu {
        let menu = NSMenu()
        for (title, value) in [("Small", CGFloat(140)), ("Medium", CGFloat(180)), ("Large", CGFloat(240))] {
            let item = NSMenuItem(title: title, action: #selector(pickSize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            menu.addItem(item)
        }
        return menu
    }

    @objc private func pickSize(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? CGFloat else { return }
        CameraBubbleGeometry.setDiameter(value)
    }
}

// MARK: - Device monitor

/// Native twin of `DeviceMonitorView` — the floating live monitor of the
/// iPhone/iPad being recorded.
@MainActor
final class DeviceMonitorNSView: NSView {
    private let clip = NSView()
    private var themeObservation: CCThemeObservation?

    init(session: AVCaptureSession) {
        super.init(frame: .zero)
        wantsLayer = true

        let shadowHost = NSView()
        shadowHost.wantsLayer = true
        // Black backing stays: the aspect-fit letterbox bars around the device
        // feed are content, not chrome. Shadow is black in both themes.
        shadowHost.layer?.backgroundColor = NSColor.black.cgColor
        shadowHost.layer?.cornerRadius = CCTheme.radius(.xl)
        shadowHost.layer?.cornerCurve = .continuous
        shadowHost.layer?.shadowColor = NSColor.black.cgColor
        shadowHost.layer?.shadowOpacity = 0.4
        shadowHost.layer?.shadowRadius = 10
        shadowHost.layer?.shadowOffset = CGSize(width: 0, height: -4)

        clip.wantsLayer = true
        clip.layer?.cornerRadius = CCTheme.radius(.xl)
        clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true
        clip.layer?.borderWidth = 2

        let preview = CameraPreviewNSView()
        preview.mirrored = false
        preview.gravity = .resizeAspect
        preview.attach(session: session)

        for sub in [shadowHost, clip, preview] { sub.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(shadowHost)
        shadowHost.addSubview(clip)
        clip.addSubview(preview)
        NSLayoutConstraint.activate([
            shadowHost.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            shadowHost.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            shadowHost.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            shadowHost.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            clip.leadingAnchor.constraint(equalTo: shadowHost.leadingAnchor),
            clip.trailingAnchor.constraint(equalTo: shadowHost.trailingAnchor),
            clip.topAnchor.constraint(equalTo: shadowHost.topAnchor),
            clip.bottomAnchor.constraint(equalTo: shadowHost.bottomAnchor),
            preview.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            preview.topAnchor.constraint(equalTo: clip.topAnchor),
            preview.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
        ])
        toolTip = "Live device monitor — drag to move"
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    private func applyTheme() {
        let ink: NSColor = CCTheme.isDark ? .white : .black
        clip.layer?.borderColor = ink.withAlphaComponent(0.7).cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
