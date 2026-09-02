import AppKit
import AVFoundation

// Video surface driven by AVPlayerItemVideoOutput instead of AVPlayerLayer.
// AVPlayerLayer on macOS unreliably skips decoding paused frames (fresh items,
// edit-list heads, zero-tolerance seeks) which left the preview blank until
// play was pressed. Pulling pixel buffers ourselves guarantees a frame for
// every seek, pause, and scrub — the same mechanism used to warm the camera.
final class VideoOutputNSView: NSView {
    var onFrameStateChange: ((Bool) -> Void)?

    private var output: AVPlayerItemVideoOutput?
    private weak var attachedItem: AVPlayerItem?
    private weak var player: AVPlayer?
    private var pollTimer: Timer?
    private var hasFrame = false
    // The IOSurface set as layer contents is only valid while its pixel buffer
    // is retained — hold the buffer until the next frame replaces it.
    private var displayedPixelBuffer: CVPixelBuffer?

    override var isOpaque: Bool { false }

    init(gravity: CALayerContentsGravity = .resizeAspect) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.contentsGravity = gravity
        layer?.masksToBounds = true

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.pullFrame()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        pollTimer?.invalidate()
    }

    func attach(player: AVPlayer) {
        self.player = player
        attachOutputIfNeeded()
    }

    private func attachOutputIfNeeded() {
        guard let item = player?.currentItem else { return }
        guard attachedItem !== item else { return }

        if let output, let previousItem = attachedItem {
            previousItem.remove(output)
        }
        let newOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ])
        item.add(newOutput)
        output = newOutput
        attachedItem = item
        if hasFrame {
            hasFrame = false
            onFrameStateChange?(false)
        }
    }

    private func pullFrame() {
        attachOutputIfNeeded()
        guard let output, let player else { return }

        let itemTime = player.currentTime()
        guard output.hasNewPixelBuffer(forItemTime: itemTime),
              let pixelBuffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) else {
            return
        }

        if let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contents = surface
            CATransaction.commit()
            displayedPixelBuffer = pixelBuffer
            if !hasFrame {
                hasFrame = true
                onFrameStateChange?(true)
            }
        }
    }
}

