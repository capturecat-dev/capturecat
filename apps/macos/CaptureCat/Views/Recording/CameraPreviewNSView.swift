import AVFoundation
import AppKit

extension Notification.Name {
    /// Posted when the camera bubble's size preference changes so the live
    /// bubble panel can resize itself.
    static let cameraBubbleSizeChanged = Notification.Name("capturecat.cameraBubbleSizeChanged")
}

/// The camera preview used by the bubble and the device monitor — one preview
/// view, one mirroring rule.
///
/// Previously declared in `RecordingControlsView` alongside an
/// `NSViewRepresentable` wrapper; the view itself was always AppKit, so only
/// the wrapper was dropped.
final class CameraPreviewNSView: NSView {
    private let previewLayer = AVCaptureVideoPreviewLayer()
    var gravity: AVLayerVideoGravity = .resizeAspectFill {
        didSet { previewLayer.videoGravity = gravity }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    var mirrored = true

    func attach(session: AVCaptureSession) {
        if previewLayer.session !== session {
            previewLayer.session = session
        }
        applyMirroring()
    }

    /// Webcams mirror like a physical mirror — the standard preview convention
    /// (the recorded file stays unmirrored; the editor has its own toggle).
    /// Phone-screen devices are shown as-is.
    private func applyMirroring() {
        guard let connection = previewLayer.connection else { return }
        if connection.automaticallyAdjustsVideoMirroring {
            connection.automaticallyAdjustsVideoMirroring = false
        }
        if connection.isVideoMirroringSupported, connection.isVideoMirrored != mirrored {
            connection.isVideoMirrored = mirrored
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
        applyMirroring() // connection appears once the session starts
    }
}
