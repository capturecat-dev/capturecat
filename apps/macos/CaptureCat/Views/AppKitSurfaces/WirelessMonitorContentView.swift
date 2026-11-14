import AppKit
import AVFoundation
import CoreMedia
import CoreVideo

/// The live picture of an iPhone streaming over Wi-Fi, for the floating
/// device monitor (`DeviceMonitorNSView(content:)`). Decoded frames arrive
/// from `WirelessServer.addMonitor` (≈30 per second) and are shown on an
/// `AVSampleBufferDisplayLayer`, aspect-fit — a rotation simply re-fits.
@MainActor
final class WirelessMonitorContentView: NSView {
    private let displayLayer = AVSampleBufferDisplayLayer()
    private weak var server: WirelessServer?
    private var token: UUID?
    /// Frames shown so far (harness).
    private(set) var framesShown = 0
    private(set) var lastFrameSize: CGSize = .zero

    init(server: WirelessServer, phone key: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(displayLayer)
        self.server = server
        token = server.addMonitor(for: key) { [weak self] pixelBuffer in
            // Server queue → main. CVPixelBuffer is immutable once decoded.
            nonisolated(unsafe) let frame = pixelBuffer
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.show(frame) } }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Stop receiving frames (the monitor panel is closing).
    func detach() {
        if let token { server?.removeMonitor(token) }
        token = nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { detach() }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }

    private func show(_ pixelBuffer: CVPixelBuffer) {
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &description
        ) == noErr, let description else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescription: description,
            sampleTiming: &timing, sampleBufferOut: &sample
        ) == noErr, let sample else { return }
        // Show immediately — the monitor is live, not timed playback.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)
        framesShown += 1
        lastFrameSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
    }
}
