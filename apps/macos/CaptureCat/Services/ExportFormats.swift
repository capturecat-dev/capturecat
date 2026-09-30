import AppKit
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - GIF export policy

/// Animated-GIF output policy. ONE definition, shared with the web exporter
/// (apps/web/src/editor/core/export/gifPolicy.ts, locked to this file by the
/// `--export-formats-test` golden vectors):
///
///  • Frame rate. GIF frame delays are whole CENTISECONDS and browsers clamp
///    delays under 2 cs up to 10 cs, so only rates whose period is an exact
///    whole number of centiseconds ≥ 2 keep time: 50, 25, 20, 10, 5, 4, 2, 1
///    fps. A GIF runs at the fastest of those that is ≤ both the export's fps
///    and `maxFrameRate` (20 fps: smooth cursor motion at a third of 60 fps'
///    frames). The sheet's 30 / 60 fps both export 20 fps GIFs (5 cs frames).
///  • Size. The export's resolved output size, scaled down uniformly until the
///    long edge is ≤ `maxLongEdge` (960 px), each side rounded then made even
///    (ExportSettings' `sanitizedDimension` rule — the frames still render
///    through the HEVC writer). 720p / 1080p / 4K at 16:9 → 960×540.
///  • Frames. Dense: frame i is output time i / fps, count
///    `max(1, ceil(duration × fps))` — the video path's frame clock. GIFs never
///    collapse static spans. Each frame is the exporter's own pre-encode
///    render (the same compositor the MP4 path encodes), converted to sRGB
///    (GIF has no colour profile).
///  • Loops forever (NETSCAPE2.0 loop count 0).
///
/// Palette quantization is the encoder's own (ImageIO here, a median-cut
/// encoder on the web) — the one thing the two platforms do NOT share.
nonisolated enum GIFExportPolicy {
    static let maxFrameRate = 20
    static let maxLongEdge = 960
    /// Frame rates with an exact whole-centisecond period ≥ 2 cs, fastest first.
    static let frameRates = [50, 25, 20, 10, 5, 4, 2, 1]

    /// The GIF's frame rate for an export requesting `fps`.
    static func frameRate(forRequested fps: Int) -> Int {
        let limit = min(max(1, fps), maxFrameRate)
        return frameRates.first { $0 <= limit } ?? 1
    }

    /// Per-frame delay in centiseconds (exact for every `frameRates` entry).
    static func delayCentiseconds(frameRate: Int) -> Int {
        100 / max(1, frameRate)
    }

    /// The GIF's pixel size for an export whose resolved output is `size`.
    static func frameSize(for size: CGSize) -> CGSize {
        let width = max(1, size.width)
        let height = max(1, size.height)
        let scale = min(1, CGFloat(maxLongEdge) / max(width, height))
        func even(_ side: CGFloat) -> CGFloat {
            let value = max(2, Int((side * scale).rounded()))
            return CGFloat(value.isMultiple(of: 2) ? value : value + 1)
        }
        return CGSize(width: even(width), height: even(height))
    }

    /// Frames in a GIF of `duration` output seconds (the exporter's clock).
    static func frameCount(duration: TimeInterval, frameRate: Int) -> Int {
        max(1, Int(ceil(max(0, duration) * Double(max(1, frameRate)))))
    }

    /// The export sheet's caption line for a GIF ("GIF • 960x540 @ 20 fps • loops").
    static func caption(outputSize: CGSize, requestedFPS: Int) -> String {
        let size = frameSize(for: outputSize)
        return "GIF • \(Int(size.width))x\(Int(size.height)) @ \(frameRate(forRequested: requestedFPS)) fps • loops"
    }
}

// MARK: - Fast export: static-span collapse (VFR)

/// The fast-export skip predicate, as a value type the exporter steps frame by
/// frame — and that the web exporter ports 1:1
/// (apps/web/src/editor/core/export/staticSpans.ts, golden vectors from
/// `--export-formats-test`).
///
/// When NOTHING that reaches the pixels changes between two output frames, the
/// second frame is not rendered or appended — the previous sample simply lasts
/// longer (mp4 sample durations come from PTS deltas; the session end pins the
/// last). Pixels at every presentation time are IDENTICAL to the CFR output;
/// only the sample count changes. Screen recordings are mostly static, so this
/// is the difference between encoding 60 copies of a still second and one.
///
/// The predicate is deliberately conservative and built from the same inputs
/// the compositor consumes — a frame is skippable only if:
///  • the decoded source sample did not advance (ScreenCaptureKit only emits
///    frames on change, so this is the true "screen is static" signal — no
///    pixel compare needed),
///  • the camera (webcam) sample did not advance,
///  • the precomputed camera key (zoom/focal/tilt springs) is equal,
///  • the smoothed cursor position, hide-state, and backdrop dim are equal,
///    and no cursor MOTION happened in the trailing `cursorQuietWindow` (pose
///    springs + click ripples are all driven by events),
///  • the time is not inside/near any blur, focus, highlight, subtitle,
///    annotation, shortcut-pill, camera-layout or device-dip span (their
///    renders consume raw currentTime), nor the curtain / intro-slide span on
///    the OUTPUT clock,
///  • the device-segment flag is unchanged,
///  • it is neither the first nor the last frame, and the last appended frame
///    is less than `maxStaticGap` seconds old (players seek precisely).
/// Any doubt = render the frame. GIF exports never collapse.
struct StaticSpanCollapse {
    struct Span: Equatable {
        var start: Double
        var end: Double
    }

    /// A frame is forced at least this often (seconds of output).
    static let maxStaticGap: Double = 5
    /// Trailing window in which a cursor MOVEMENT can still influence pixels
    /// (pose springs, click ripples, hide fades — the longest, ripples, run
    /// 0.45s; springs settle ~1s). 2s is still generous, and the frame key's
    /// quantized cursor position independently forces a render whenever the
    /// drawn cursor is actually mid-motion. Measured on a real 5-min
    /// recording: 5s left 4% of frames collapsible, 2s makes 21% collapsible.
    static let cursorQuietWindow: Double = 2

    /// Everything the compositor reads that can change between two frames.
    struct FrameKey: Equatable {
        var videoSampleSeconds: Double
        var cameraSampleSeconds: Double
        var zoom: Double
        var focalX: Double
        var focalY: Double
        var offsetX: Double
        var offsetY: Double
        var tiltPitch: Double
        var tiltYaw: Double
        var tiltRoll: Double
        var cursorPosition: CGPoint?
        var cursorHidden: Bool
        var dimAlpha: Double
        var deviceSegment: Bool
        /// Interpolated camera-layout geometry — a morph must never be
        /// collapsed away (see `cameraLayoutKey`).
        var cameraLayout: String

        /// Springs asymptote — they never return to BIT-exact rest, so an
        /// exact compare collapses nothing after the first zoom. Quantized
        /// below visual resolution instead: 1e-6 of the canvas is ~1/250 of a
        /// 4K pixel. Comparison is always against the LAST APPENDED key (not
        /// the previous frame), so sub-quantum drift accumulates until it
        /// crosses one quantum and then a frame is appended — total positional
        /// error is bounded by the quantum itself.
        func quantized() -> FrameKey {
            func q(_ v: Double, _ s: Double) -> Double { (v * s).rounded() / s }
            var k = self
            k.videoSampleSeconds = q(videoSampleSeconds, 1e6)
            k.cameraSampleSeconds = q(cameraSampleSeconds, 1e6)
            k.zoom = q(zoom, 1e6)
            k.focalX = q(focalX, 1e6)
            k.focalY = q(focalY, 1e6)
            k.offsetX = q(offsetX, 1e6)
            k.offsetY = q(offsetY, 1e6)
            k.tiltPitch = q(tiltPitch, 1e4)
            k.tiltYaw = q(tiltYaw, 1e4)
            k.tiltRoll = q(tiltRoll, 1e4)
            if let p = cursorPosition {
                k.cursorPosition = CGPoint(x: q(Double(p.x), 1e3), y: q(Double(p.y), 1e3))
            }
            k.dimAlpha = q(dimAlpha, 1e4)
            return k
        }
    }

    /// The resolved camera layout as the key's string (`CameraLayoutMath.Resolved`).
    static func cameraLayoutKey(_ layout: CameraLayoutMath.Resolved) -> String {
        String(
            format: "%.0f,%.0f,%.0f,%.0f,%.3f,%.3f,%.4f,%.1f",
            layout.cameraRect?.minX ?? -1, layout.cameraRect?.minY ?? -1,
            layout.cameraRect?.width ?? -1, layout.cameraRect?.height ?? -1,
            layout.cameraOpacity, layout.chromeOpacity,
            layout.cardScale, layout.cardTranslationX)
    }

    let enabled: Bool
    /// SOURCE-time guard spans, sorted by start.
    let animationHotSpans: [Span]
    /// OUTPUT-time guard spans (curtain unveil, intro slide), sorted by start.
    let outputHotSpans: [Span]
    /// Cursor MOTION timestamps (see `cursorMotionTimestamps`).
    let cursorTimestamps: [TimeInterval]

    private(set) var lastAppendedKey: FrameKey?
    private(set) var lastAppendedSeconds = -Double.greatestFiniteMagnitude
    private(set) var collapsedFrameCount = 0

    init(
        enabled: Bool,
        animationHotSpans: [Span],
        outputHotSpans: [Span],
        cursorTimestamps: [TimeInterval]
    ) {
        self.enabled = enabled
        self.animationHotSpans = animationHotSpans
        self.outputHotSpans = outputHotSpans
        self.cursorTimestamps = cursorTimestamps
    }

    /// The exporter's collapser for `project` (spans are only built when enabled).
    init(
        enabled: Bool,
        project: Project,
        transitionDuration: TimeInterval,
        keystrokeDisplayEvents: [KeystrokeOverlayMath.DisplayEvent],
        deviceSegmentBoundaries: [TimeInterval]?,
        cursorEvents: [CursorEvent]
    ) {
        self.init(
            enabled: enabled,
            animationHotSpans: enabled ? Self.animationHotSpans(
                project: project,
                transitionDuration: transitionDuration,
                keystrokeTimes: keystrokeDisplayEvents.map(\.time),
                deviceSegmentBoundaries: deviceSegmentBoundaries) : [],
            outputHotSpans: enabled ? Self.outputHotSpans(settings: project.settings) : [],
            cursorTimestamps: Self.cursorMotionTimestamps(cursorEvents))
    }

    /// SOURCE-time spans whose renders read the raw clock.
    static func animationHotSpans(
        project: Project,
        transitionDuration: TimeInterval,
        keystrokeTimes: [TimeInterval],
        deviceSegmentBoundaries: [TimeInterval]?
    ) -> [Span] {
        var spans: [Span] = []
        // Layout morphs run for `transitionDuration` after every edge.
        for r in project.cameraLayoutRegions {
            let d = CameraLayoutMath.transitionDuration
            spans.append(Span(start: r.startTime - 0.1, end: r.startTime + d + 0.1))
            spans.append(Span(start: r.endTime - 0.1, end: r.endTime + d + 0.1))
        }
        for r in project.blurRegions { spans.append(Span(start: r.startTime - 1, end: r.endTime + 1)) }
        for r in project.focusRegions { spans.append(Span(start: r.startTime - 1, end: r.endTime + 1)) }
        for r in project.highlightRegions {
            spans.append(Span(start: r.startTime - transitionDuration - 1, end: r.endTime + transitionDuration + 1))
        }
        for s in project.subtitles { spans.append(Span(start: s.startTime - 0.5, end: s.endTime + 0.5)) }
        for a in project.annotations { spans.append(Span(start: a.startTime - 1, end: a.endTime + 1)) }
        // Shortcut pills animate from keyboard events, which the cursor
        // quiet-window can't see — without a hot span a pill firing in a
        // static stretch would freeze mid-fade in the export.
        let pillLife = KeystrokeOverlayMath.fadeIn + KeystrokeOverlayMath.hold + KeystrokeOverlayMath.fadeOut
        for time in keystrokeTimes {
            spans.append(Span(start: time - 0.1, end: time + pillLife + 0.1))
        }
        // Device-segment boundary dips (Gaussian, sigma 0.15s) animate on the
        // same source clock — without a span the ease halves collapse into a
        // hard pop the moment the cursor happens to be quiet.
        if let boundaries = deviceSegmentBoundaries {
            let dipHalf = DeviceSegmentDip.sigma * 4
            for boundary in boundaries {
                spans.append(Span(start: boundary - dipHalf, end: boundary + dipHalf))
            }
        }
        spans.sort { $0.start < $1.start }
        return spans
    }

    /// Curtain unveil and intro slide animate on the OUTPUT clock, so their
    /// guard spans live in a separate output-time list — appending them to the
    /// source-time spans would misplace them inside a speed-ramped timeline.
    static func outputHotSpans(settings: ProjectSettings) -> [Span] {
        var spans: [Span] = []
        if settings.curtainUnveilCorner != .off {
            spans.append(Span(start: settings.curtainUnveilStart - 0.1,
                              end: settings.curtainUnveilStart + settings.curtainUnveilDuration + 0.1))
        }
        if settings.introSlideStyle != .off {
            spans.append(Span(start: settings.introSlideStart - 0.1,
                              end: settings.introSlideStart + settings.introSlideDuration + 0.1))
        }
        spans.sort { $0.start < $1.start }
        return spans
    }

    /// The tracker appends a sample every poll tick (30 Hz) even while the
    /// mouse rests, so "any event in the window" kept whole recordings
    /// collapse-free. Pixels only move on actual MOTION or a click edge, so
    /// quietness is measured from those (> 0.5 pt from the last kept sample,
    /// or a press-state flip). Slow sub-threshold drift is still safe: the
    /// frame key's quantized cursorPosition forces a render the moment the
    /// interpolated position moves a visible amount.
    static func cursorMotionTimestamps(_ events: [CursorEvent]) -> [TimeInterval] {
        var timestamps: [TimeInterval] = []
        var anchor: CursorEvent?
        for e in events {
            if let a = anchor {
                if abs(e.x - a.x) > 0.5 || abs(e.y - a.y) > 0.5 || e.isClick != a.isClick {
                    timestamps.append(e.timestamp)
                    anchor = e
                }
            } else {
                timestamps.append(e.timestamp)
                anchor = e
            }
        }
        return timestamps
    }

    /// Spans are few (tens); linear scan with early exit over start-sorted spans.
    static func inSpans(_ spans: [Span], _ t: Double) -> Bool {
        for span in spans {
            if span.start > t { return false }
            if t <= span.end { return true }
        }
        return false
    }

    /// No cursor motion in (t − window, t]. Future events flip the key when they arrive.
    func cursorQuiet(at t: Double) -> Bool {
        guard !cursorTimestamps.isEmpty else { return true }
        var lo = 0, hi = cursorTimestamps.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if cursorTimestamps[mid] <= t - Self.cursorQuietWindow { lo = mid + 1 } else { hi = mid }
        }
        return lo >= cursorTimestamps.count || cursorTimestamps[lo] > t
    }

    /// Steps one output frame: true = skip it (the previous sample keeps
    /// playing), false = render + append it (and remember its key).
    mutating func shouldSkip(
        frameIndex: Int,
        frameCount: Int,
        outputSeconds: Double,
        sourceTime: Double,
        key: FrameKey
    ) -> Bool {
        guard enabled else { return false }
        let quantizedKey = key.quantized()
        let skippable = frameIndex > 0
            && frameIndex < frameCount - 1
            && quantizedKey == lastAppendedKey
            && outputSeconds - lastAppendedSeconds < Self.maxStaticGap
            && cursorQuiet(at: sourceTime)
            && !Self.inSpans(animationHotSpans, sourceTime)
            && !Self.inSpans(outputHotSpans, outputSeconds)
        if skippable {
            collapsedFrameCount += 1
            return true
        }
        lastAppendedKey = quantizedKey
        lastAppendedSeconds = outputSeconds
        return false
    }
}

// MARK: - GIF writer

/// Writes the exporter's rendered frames into an animated GIF with ImageIO
/// (`CGImageDestination`), in frame-index order — the export's frame Tasks
/// finish out of order, exactly like the movie path's SerialAppender.
actor GIFFrameSink {
    enum SinkError: LocalizedError {
        case destination
        case frames(written: Int, expected: Int)
        case finalize

        var errorDescription: String? {
            switch self {
            case .destination: return "Could not create the GIF file."
            case .frames(let written, let expected): return "GIF export wrote \(written) of \(expected) frames."
            case .finalize: return "Could not finish writing the GIF."
            }
        }
    }

    private let destination: CGImageDestination
    private let frameProperties: CFDictionary
    private let expectedCount: Int
    private var nextIndex = 0
    private var written = 0
    private var pending: [Int: CGImage?] = [:]

    init(url: URL, frameCount: Int, frameRate: Int) throws {
        try? FileManager.default.removeItem(at: url)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, frameCount, nil) else {
            throw SinkError.destination
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        let delay = Double(GIFExportPolicy.delayCentiseconds(frameRate: frameRate)) / 100
        frameProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay,
                kCGImagePropertyGIFUnclampedDelayTime: delay,
            ],
        ] as CFDictionary
        self.destination = destination
        self.expectedCount = frameCount
    }

    /// Queues frame `index` (nil = the render failed; the frame is dropped and
    /// `finalize` reports the shortfall).
    func add(_ image: CGImage?, index: Int) {
        pending[index] = .some(image)
        while let entry = pending.removeValue(forKey: nextIndex) {
            if let image = entry {
                CGImageDestinationAddImage(destination, image, frameProperties)
                written += 1
            }
            nextIndex += 1
        }
    }

    func finalize() throws {
        guard written == expectedCount else { throw SinkError.frames(written: written, expected: expectedCount) }
        guard CGImageDestinationFinalize(destination) else { throw SinkError.finalize }
    }

    /// An sRGB, opaque copy of a rendered BGRA export buffer in `space` (the
    /// export's render space: P3 or sRGB, per source). Made synchronously —
    /// the buffer goes back to the writer's pool right after.
    nonisolated static func sRGBImage(from buffer: CVPixelBuffer, space: CGColorSpace) -> CGImage? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard let provider = CGDataProvider(
            dataInfo: nil, data: base, size: bytesPerRow * height, releaseData: { _, _, _ in }),
              let source = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: bytesPerRow, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                    | CGImageAlphaInfo.premultipliedFirst.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: srgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .none
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
