import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreGraphics
import CoreImage
import AppKit
import os

nonisolated private let recorderLogger = Logger(
    subsystem: "so.capturecat.CaptureCat",
    category: "ScreenRecorder"
)

@Observable
final class ScreenRecorder: NSObject {
    /// The live on-screen rect of the pixels in a cropped window recording.
    ///
    /// This comes from `SCStreamFrameInfo.screenRect`, not `SCWindow.frame` or
    /// `SCContentFilter.contentRect`: both of those can include the transparent
    /// window-shadow surface that ScreenCaptureKit later writes as black. The
    /// cursor tracker reads this same rect, so video pixels and pointer samples
    /// share one coordinate space.
    nonisolated var capturedContentRect: CGRect? {
        capturedContentRectLock.lock()
        defer { capturedContentRectLock.unlock() }
        return _capturedContentRect
    }

    private enum DefaultsKey {
        static let hasVerifiedScreenRecordingAccess = "hasVerifiedScreenRecordingAccess"
        static let suppressAutomaticScreenCaptureProbe = "suppressAutomaticScreenCaptureProbe"
    }

    private(set) var isRecording = false
    private var stream: SCStream?
    @ObservationIgnored private nonisolated(unsafe) var assetWriter: AVAssetWriter?
    @ObservationIgnored private nonisolated(unsafe) var videoInput: AVAssetWriterInput?
    @ObservationIgnored private nonisolated(unsafe) var audioInput: AVAssetWriterInput?
    @ObservationIgnored private nonisolated(unsafe) var micAudioInput: AVAssetWriterInput?
    @ObservationIgnored private nonisolated(unsafe) var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    @ObservationIgnored private nonisolated(unsafe) var isWindowCapture = false
    @ObservationIgnored private nonisolated(unsafe) var windowOutputSize: CGSize = .zero
    @ObservationIgnored private nonisolated(unsafe) var _capturedContentRect: CGRect?
    @ObservationIgnored private nonisolated let capturedContentRectLock = NSLock()
    /// Metadata-rect → pixel-tightened rect cache; only touched on writerQueue.
    @ObservationIgnored private nonisolated(unsafe) var lastPaddingTighten: (metadata: CGRect, tight: CGRect)?
    @ObservationIgnored private nonisolated let windowCropContext = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
    ])
    @ObservationIgnored private nonisolated(unsafe) var startTime: CMTime?
    @ObservationIgnored private nonisolated(unsafe) var sessionStarted = false
    @ObservationIgnored private nonisolated(unsafe) var _isPaused = false
    @ObservationIgnored private nonisolated(unsafe) var pauseStartTime: CMTime?
    @ObservationIgnored private nonisolated(unsafe) var totalPauseDuration: CMTime = .zero
    @ObservationIgnored private nonisolated(unsafe) var lastVideoTime: CMTime = .invalid
    @ObservationIgnored private nonisolated(unsafe) var lastAudioTime: CMTime = .invalid
    @ObservationIgnored private nonisolated(unsafe) var lastMicTime: CMTime = .invalid
    @ObservationIgnored private nonisolated(unsafe) var streamConfig: SCStreamConfiguration?
    @ObservationIgnored private var captureSource: CaptureSource?
    @ObservationIgnored private nonisolated(unsafe) var _micLevel: Float = 0
    @ObservationIgnored private nonisolated(unsafe) var _sessionStartHostTimeSeconds: Double?
    @ObservationIgnored private nonisolated(unsafe) var _audioStartHostTimeSeconds: Double?
    @ObservationIgnored private nonisolated(unsafe) var _microphoneStartHostTimeSeconds: Double?
    /// External shared host-clock origin. When set before recording starts, all
    /// frame PTS are computed as `sampleTime − sharedOriginHostTime` instead of
    /// being anchored to the first sample. Camera + screen + cursor all share
    /// this origin so their timelines line up by construction (Screen Studio
    /// approach — `cameraTimeOffset` is structurally 0 in this mode).
    @ObservationIgnored nonisolated(unsafe) var sharedOriginHostTime: CMTime?
    @ObservationIgnored private nonisolated(unsafe) var micOutputAttached = false
    var micLevel: Float { _micLevel }
    var sessionStartHostTimeSeconds: Double? { _sessionStartHostTimeSeconds }
    var audioStartHostTimeSeconds: Double? { _audioStartHostTimeSeconds }
    var microphoneStartHostTimeSeconds: Double? { _microphoneStartHostTimeSeconds }
    @ObservationIgnored private let writerQueue = DispatchQueue(label: "so.capturecat.assetwriter")

    var outputURL: URL?
    var recordingSourceKind: RecordingSourceKind {
        switch captureSource {
        case .window:
            return .window
        case .area:
            return .area
        case .iosDevice:
            return .device
        case .display, .none:
            return .display
        }
    }

    static var hasVerifiedScreenRecordingAccess: Bool {
        UserDefaults.standard.bool(forKey: DefaultsKey.hasVerifiedScreenRecordingAccess)
    }

    static var shouldSuppressAutomaticScreenCaptureProbe: Bool {
        UserDefaults.standard.bool(forKey: DefaultsKey.suppressAutomaticScreenCaptureProbe)
    }

    static func clearAutomaticProbeSuppression() {
        UserDefaults.standard.set(false, forKey: DefaultsKey.suppressAutomaticScreenCaptureProbe)
    }

    func availableContent() async throws -> SCShareableContent {
        let preflight = CGPreflightScreenCaptureAccess()
        let windowListProbe = Self.hasScreenRecordingViaWindowList()
        recorderLogger.info("availableContent: preflight=\(preflight), windowList=\(windowListProbe)")
        do {
            // onScreenWindowsOnly must be FALSE here: the source picker uses
            // this list, and `true` silently drops every window on another
            // Space and every fullscreen app — "why isn't Chrome in the
            // list?" was exactly that. The panel filters layers/sizes itself.
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            UserDefaults.standard.set(true, forKey: DefaultsKey.hasVerifiedScreenRecordingAccess)
            UserDefaults.standard.set(false, forKey: DefaultsKey.suppressAutomaticScreenCaptureProbe)
            recorderLogger.info("availableContent: success displays=\(content.displays.count) windows=\(content.windows.count)")
            return content
        } catch {
            let nsError = error as NSError
            if nsError.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain", nsError.code == -3801 {
                UserDefaults.standard.set(false, forKey: DefaultsKey.hasVerifiedScreenRecordingAccess)
                UserDefaults.standard.set(true, forKey: DefaultsKey.suppressAutomaticScreenCaptureProbe)
            }
            recorderLogger.error("availableContent failed: domain=\(nsError.domain, privacy: .public) code=\(nsError.code) desc=\(nsError.localizedDescription, privacy: .public)")
            throw error
        }
    }

    static func hasScreenRecordingViaWindowList() -> Bool {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] else {
            return false
        }
        let myPID = ProcessInfo.processInfo.processIdentifier
        for entry in windowList {
            guard let pid = entry[kCGWindowOwnerPID] as? pid_t, pid != myPID else { continue }
            if let name = entry[kCGWindowName] as? String, !name.isEmpty {
                return true
            }
        }
        return false
    }

    func startRecording(
        source: CaptureSource,
        excludingWindows: [SCWindow] = [],
        captureAudio: Bool = true,
        captureMicrophone: Bool = false,
        microphoneDeviceID: String? = nil
    ) async throws {
        setCapturedContentRect(nil)
        isWindowCapture = false
        windowOutputSize = .zero
        assetWriter = nil
        videoInput = nil
        audioInput = nil
        micAudioInput = nil
        adaptor = nil

        let filter: SCContentFilter
        var captureWidth: Int
        var captureHeight: Int
        var sourceRect: CGRect? = nil
        let shareableContent: SCShareableContent?

        switch source {
        case .display, .area:
            shareableContent = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        case .window, .iosDevice:
            shareableContent = nil
        }

        switch source {
        case .display(let display):
            let displayScale = scaleFactor(for: display)
            filter = displayFilter(
                for: display,
                shareableContent: shareableContent,
                fallbackExcludedWindows: excludingWindows
            )
            captureWidth = max(2, Int(CGFloat(display.width) * displayScale))
            captureHeight = max(2, Int(CGFloat(display.height) * displayScale))

        case .window(let window):
            let latestWindow = try await resolveWindow(window)
            filter = SCContentFilter(desktopIndependentWindow: latestWindow)
            if #available(macOS 14.2, *) {
                // 14.2+ property. Earlier Sonoma never includes the menu bar in
                // desktop-independent window capture, so skipping it there is
                // the same result, not a behavior fork.
                filter.includeMenuBar = false
            }
            isWindowCapture = true

            // Configure SCK for the selected window, not `filter.contentRect`.
            // On the Chrome repro the filter rect described the 1492x949 display
            // surface, which is why the 1369x872 window arrived at global offset
            // (123,46) inside a black frame. Per-frame metadata below remains the
            // source of truth and crops any surface padding SCK still supplies.
            let windowScale = max(1, CGFloat(filter.pointPixelScale))
            captureWidth = max(2, Int((latestWindow.frame.width * windowScale).rounded()))
            captureHeight = max(2, Int((latestWindow.frame.height * windowScale).rounded()))
            print("[ScreenRecorder] Window request: \(captureWidth)x\(captureHeight) scale=\(windowScale) frame=\(latestWindow.frame) filterRect=\(filter.contentRect)")

        case .area(let display, let rect):
            let displayScale = scaleFactor(for: display)
            filter = displayFilter(
                for: display,
                shareableContent: shareableContent,
                fallbackExcludedWindows: excludingWindows
            )
            sourceRect = rect
            captureWidth = max(2, Int(rect.width * displayScale))
            captureHeight = max(2, Int(rect.height * displayScale))

        case .iosDevice:
            // Device capture goes through DeviceRecorder, never SCK.
            throw NSError(domain: "ScreenRecorder", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "iOS devices are recorded by DeviceRecorder."
            ])
        }

        let config = SCStreamConfiguration()
        config.width = captureWidth
        config.height = captureHeight
        if let sourceRect {
            config.sourceRect = sourceRect
        }
        if case .window = source {
            config.ignoreShadowsSingleWindow = true
        }
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = false  // We track cursor separately
        // Capture in Display P3 and tag the file to match (see writer settings
        // below, via VideoColorTags). Modern Mac panels are P3: forcing sRGB
        // here made SCK gamut-clip every saturated color at capture time, so
        // recordings (and therefore exports) looked duller than the screen.
        // P3 shares the sRGB transfer curve, so gamma is unchanged — only the
        // wider primaries are preserved. The explicit space also keeps SCK from
        // delivering untagged display-space pixels that the writer would tag
        // BT.709 by default (the original dull-export gamma bug).
        config.colorSpaceName = CGColorSpace.displayP3
        config.capturesAudio = captureAudio
        // SCK-integrated mic capture is macOS 15+. On Sonoma the recording
        // proceeds without the mic — see `supportsMicrophoneCapture`, which the
        // UI uses to disable the toggle rather than silently drop audio.
        if #available(macOS 15.0, *) {
            config.captureMicrophone = captureMicrophone
            if let microphoneDeviceID, captureMicrophone {
                config.microphoneCaptureDeviceID = microphoneDeviceID
            }
        }
        config.sampleRate = 48000
        config.channelCount = 2

        // Set up output file in Application Support/CaptureCat/Recordings/
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CaptureCat/Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let fileName = "capturecat_recording_\(UUID().uuidString).mov"
        let url = appSupport.appendingPathComponent(fileName)
        outputURL = url

        // AVAssetWriter
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        // Display/area dimensions are known up front. A window's encoded size
        // is deliberately deferred until the first complete frame, because only
        // its per-frame metadata tells us which part of the SCK surface contains
        // actual window pixels.
        if !isWindowCapture {
            guard let configured = Self.makeVideoInput(
                for: writer,
                width: config.width,
                height: config.height
            ) else {
                throw NSError(domain: "ScreenRecorder", code: 11, userInfo: [
                    NSLocalizedDescriptionKey: "The video encoder rejected the capture dimensions."
                ])
            }
            videoInput = configured.input
            adaptor = configured.adaptor
        }

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128000,
        ]

        if captureAudio {
            let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            aInput.expectsMediaDataInRealTime = true
            writer.add(aInput)
            audioInput = aInput
        }

        // Always create the mic writer input — inputs can't be added after
        // `startWriting()`, and without one a mid-recording mic enable via
        // `setMicrophone(enabled:)` silently records nothing. When the mic
        // stays off no samples arrive and the track finalizes empty.
        let micSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000, // 64k was audibly mushy for voice
        ]
        let mInput = AVAssetWriterInput(mediaType: .audio, outputSettings: micSettings)
        mInput.expectsMediaDataInRealTime = true
        writer.add(mInput)
        micAudioInput = mInput

        assetWriter = writer
        if !isWindowCapture, !writer.startWriting() {
            throw writer.error ?? NSError(domain: "ScreenRecorder", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "The video encoder could not start."
            ])
        }

        // Store config for mid-recording updates
        streamConfig = config

        // SCStream — use serial queue to prevent race conditions
        let scStream = SCStream(filter: filter, configuration: config, delegate: self)
        try scStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: writerQueue)
        if captureAudio {
            try scStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: writerQueue)
        }
        // Only attach the mic output when the mic is on — an attached output
        // that never delivers samples can wedge `stopCapture()` forever.
        // Mid-recording enable attaches it on demand (see `setMicrophone`).
        if #available(macOS 15.0, *), captureMicrophone {
            try scStream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: writerQueue)
            micOutputAttached = true
        } else {
            micOutputAttached = false
        }

        // Reset state BEFORE starting capture — frames arrive on writerQueue immediately
        startTime = nil
        sessionStarted = false
        _sessionStartHostTimeSeconds = nil
        _audioStartHostTimeSeconds = nil
        _microphoneStartHostTimeSeconds = nil
        _isPaused = false
        totalPauseDuration = .zero
        lastVideoTime = .invalid
        lastAudioTime = .invalid
        lastMicTime = .invalid
        _micLevel = 0

        captureSource = source

        try await scStream.startCapture()
        stream = scStream
        isRecording = true
    }

    func waitForSessionStart(timeout: TimeInterval = 1.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        while _sessionStartHostTimeSeconds == nil && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func pause() {
        // Mutate pause state on the sample-handler queue so an in-flight frame
        // never reads a half-updated pause window.
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        writerQueue.async { [self] in
            _isPaused = true
            pauseStartTime = now
        }
    }

    func resume() {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        writerQueue.async { [self] in
            if let pauseStart = pauseStartTime {
                totalPauseDuration = CMTimeAdd(totalPauseDuration, CMTimeSubtract(now, pauseStart))
            }
            pauseStartTime = nil
            _isPaused = false
        }
    }

    /// Re-query our app's windows and update the stream filter to exclude them.
    /// Call this after new app windows appear (e.g. camera preview panel).
    func refreshExcludedWindows() async {
        guard let stream, let source = captureSource else { return }

        // Only display and area modes use excludingWindows
        let display: SCDisplay?
        switch source {
        case .display(let d): display = d
        case .area(let d, _): display = d
        case .window, .iosDevice: return // No display exclusions needed
        }
        guard let display else { return }

        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return }
        let myWindows = excludedWindows(from: content)
        let newFilter = displayFilter(
            for: display,
            shareableContent: content,
            fallbackExcludedWindows: myWindows
        )
        try? await stream.updateContentFilter(newFilter)
    }

    private func displayFilter(
        for display: SCDisplay,
        shareableContent: SCShareableContent?,
        fallbackExcludedWindows: [SCWindow]
    ) -> SCContentFilter {
        guard let shareableContent else {
            return SCContentFilter(display: display, excludingWindows: fallbackExcludedWindows)
        }

        let excludedApplications = excludedApplications(from: shareableContent)
        if !excludedApplications.isEmpty {
            return SCContentFilter(
                display: display,
                excludingApplications: excludedApplications,
                exceptingWindows: []
            )
        }

        return SCContentFilter(display: display, excludingWindows: fallbackExcludedWindows)
    }

    private func excludedApplications(from content: SCShareableContent) -> [SCRunningApplication] {
        let myPID = ProcessInfo.processInfo.processIdentifier
        return content.applications.filter { $0.processID == myPID }
    }

    private func excludedWindows(from content: SCShareableContent) -> [SCWindow] {
        let myPID = ProcessInfo.processInfo.processIdentifier
        return content.windows.filter { $0.owningApplication?.processID == myPID }
    }

    private func resolveWindow(_ selectedWindow: SCWindow) async throws -> SCWindow {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return content.windows.first(where: { $0.windowID == selectedWindow.windowID }) ?? selectedWindow
    }

    private func scaleFactor(for display: SCDisplay) -> CGFloat {
        let fallback: CGFloat = 2
        guard let screen = NSScreen.screens.first(where: {
            guard let screenNumber = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                return false
            }
            return screenNumber == display.displayID
        }) else {
            return fallback
        }
        return max(1, screen.backingScaleFactor)
    }

    nonisolated private static func makeVideoInput(
        for writer: AVAssetWriter,
        width: Int,
        height: Int
    ) -> (input: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor)? {
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            // Tag exactly what SCK supplies: Display P3 pixels (P3-D65
            // primaries + sRGB transfer). The exporter detects these tags and
            // matches them, so preview and export don't shift gamma or gamut.
            AVVideoColorPropertiesKey: VideoColorTags.colorProperties(p3: true),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 20_000_000,
                AVVideoExpectedSourceFrameRateKey: 60,
                // Screen frames don't benefit enough from B-frames to justify
                // their out-of-order PTS at the file head.
                AVVideoAllowFrameReorderingKey: false,
            ] as [String: Any]
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { return nil }
        writer.add(input)

        // Explicit attributes are required here. Passing nil can leave the
        // adaptor without a pool, which would make the CI-cropped window frames
        // impossible to allocate.
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: attributes
        )
        return (input, adaptor)
    }

    /// SCK-integrated mic capture (`SCStreamConfiguration.captureMicrophone`)
    /// is macOS 15+. On Sonoma recordings run without the mic; the UI reads
    /// this to disable the toggle instead of silently dropping audio.
    static var supportsMicrophoneCapture: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    func setMicrophone(enabled: Bool, deviceID: String? = nil) async throws {
        guard #available(macOS 15.0, *) else { return }
        guard let stream, let config = streamConfig else { return }
        if enabled && !micOutputAttached {
            // Attach the mic output on demand; the writer input already exists
            // (created up front — writer inputs can't be added after start).
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: writerQueue)
            micOutputAttached = true
        }
        config.captureMicrophone = enabled
        if let deviceID, enabled {
            config.microphoneCaptureDeviceID = deviceID
        }
        try await stream.updateConfiguration(config)
    }

    func stopRecording() async throws {
        guard let stream else { return }
        self.stream = nil

        // A dead stream (display unplugged, permission revoked) throws here,
        // and a wedged stream can hang forever — either way the writer must
        // still be finalized or the file has no moov atom and is unplayable.
        // Bound the wait so Stop can never leave a headless recording running.
        await Self.stopCapture(stream, timeout: 3)

        await finalizeWriter()
        isRecording = false
    }

    private static func stopCapture(_ stream: SCStream, timeout: TimeInterval) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                do {
                    try await stream.stopCapture()
                } catch {
                    recorderLogger.error("stopCapture failed (finalizing anyway): \(error.localizedDescription, privacy: .public)")
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                if !Task.isCancelled {
                    recorderLogger.error("stopCapture timed out after \(timeout, privacy: .public)s — finalizing anyway")
                }
            }
            _ = await group.next()
            group.cancelAll()
        }
    }

    /// Finalizes the asset writer exactly once, after draining any in-flight
    /// sample callbacks so no append races `markAsFinished`.
    private func finalizeWriter() async {
        writerQueue.sync { }
        guard let writer = assetWriter else { return }
        assetWriter = nil
        guard writer.status == .writing else {
            if writer.status == .unknown { writer.cancelWriting() }
            return
        }

        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        micAudioInput?.markAsFinished()
        await writer.finishWriting()
    }

    nonisolated private func setCapturedContentRect(_ rect: CGRect?) {
        capturedContentRectLock.lock()
        _capturedContentRect = rect
        capturedContentRectLock.unlock()
    }
}

extension ScreenRecorder: SCStreamDelegate, SCStreamOutput {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        recorderLogger.error("stream stopped with error: \(error.localizedDescription, privacy: .public)")
        Task { @MainActor in
            // Finalize immediately so the partial take is playable; the later
            // user-initiated stop becomes a no-op (stream is nil, writer done).
            self.stream = nil
            await self.finalizeWriter()
            self.isRecording = false
        }
    }

    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        // All callbacks arrive on the serial writerQueue — no race conditions
        guard !_isPaused else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let writer = assetWriter else { return }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let hostNow = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))

        switch type {
        case .screen:
            guard let pixelBuffer = sampleBuffer.imageBuffer else { return }
            var bufferToWrite = pixelBuffer

            if isWindowCapture {
                guard let attachments = frameAttachments(from: sampleBuffer),
                      frameIsComplete(attachments),
                      let cropRect = windowSurfaceCropRect(
                        attachments: attachments,
                        pixelBuffer: pixelBuffer
                      ) else { return }

                // `screenRect` is the global, on-screen rect of exactly the
                // content described by the cropped pixels. Publish it before
                // starting the writer session so CursorTracker can never begin
                // with the old SCWindow/filter geometry.
                if var screenRect = frameRect(.screenRect, in: attachments),
                   screenRect.width > 0, screenRect.height > 0 {
                    // If the pixel scan tightened the crop past the metadata
                    // rect, the on-screen rect of the WRITTEN pixels shrinks by
                    // the same margins — publish the adjusted rect or every
                    // cursor sample lands offset by exactly the trimmed band.
                    if let t = lastPaddingTighten, t.tight != t.metadata {
                        let scale = max(0.01, frameCGFloat(.scaleFactor, in: attachments) ?? 1)
                        screenRect.origin.x += (t.tight.minX - t.metadata.minX) / scale
                        screenRect.origin.y += (t.tight.minY - t.metadata.minY) / scale
                        screenRect.size.width -= (t.metadata.width - t.tight.width) / scale
                        screenRect.size.height -= (t.metadata.height - t.tight.height) / scale
                    }
                    setCapturedContentRect(screenRect)
                }

                // A window writer is configured from the first real frame.
                // SCK surfaces can be larger than their visible content, so an
                // up-front filter/window size would bake the black padding into
                // every encoded frame.
                if videoInput == nil {
                    let width = evenDimension(cropRect.width)
                    let height = evenDimension(cropRect.height)
                    guard let configured = Self.makeVideoInput(
                        for: writer,
                        width: width,
                        height: height
                    ) else {
                        recorderLogger.error("Window video input rejected \(width)x\(height)")
                        return
                    }
                    videoInput = configured.input
                    adaptor = configured.adaptor
                    windowOutputSize = CGSize(width: width, height: height)

                    guard writer.startWriting() else {
                        let message = writer.error?.localizedDescription ?? "unknown error"
                        recorderLogger.error("Window writer failed to start: \(message, privacy: .public)")
                        return
                    }

                    let content = frameRect(.contentRect, in: attachments) ?? .zero
                    let bounds = frameRect(.boundingRect, in: attachments) ?? .zero
                    let scale = frameCGFloat(.scaleFactor, in: attachments) ?? 1
                    let contentScale = frameCGFloat(.contentScale, in: attachments) ?? 1
                    recorderLogger.info("Window geometry surface=\(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer)) content=\(String(describing: content), privacy: .public) bounds=\(String(describing: bounds), privacy: .public) scale=\(scale, privacy: .public) contentScale=\(contentScale, privacy: .public) crop=\(String(describing: cropRect), privacy: .public) output=\(width)x\(height)")
                }

                guard let cropped = croppedWindowPixelBuffer(
                    pixelBuffer,
                    cropRect: cropRect
                ) else { return }
                bufferToWrite = cropped
            }

            guard writer.status == .writing else { return }

            // The SCREEN frame owns the session origin. Audio can arrive first,
            // but allowing it to start a lazy window writer races cursor setup
            // against the frame metadata needed for exact geometry.
            if !sessionStarted {
                startTime = sharedOriginHostTime ?? timestamp
                _sessionStartHostTimeSeconds = sharedOriginHostTime.map { CMTimeGetSeconds($0) } ?? hostNow
                writer.startSession(atSourceTime: .zero)
                sessionStarted = true
            }

            guard let adjustedTime = adjustedTime(for: timestamp),
                  let videoInput,
                  videoInput.isReadyForMoreMediaData else { return }
            // Ensure monotonically increasing timestamps
            if lastVideoTime.isValid && CMTimeCompare(adjustedTime, lastVideoTime) <= 0 { return }
            if adaptor?.append(bufferToWrite, withPresentationTime: adjustedTime) == true {
                lastVideoTime = adjustedTime
            }

        case .audio:
            guard sessionStarted, writer.status == .writing,
                  let adjustedTime = adjustedTime(for: timestamp),
                  let audioInput, audioInput.isReadyForMoreMediaData else { return }
            if _audioStartHostTimeSeconds == nil {
                _audioStartHostTimeSeconds = hostNow
            }
            if lastAudioTime.isValid && CMTimeCompare(adjustedTime, lastAudioTime) <= 0 { return }
            if let retimed = retime(sampleBuffer: sampleBuffer, to: adjustedTime) {
                audioInput.append(retimed)
                lastAudioTime = adjustedTime
            }

        case .microphone:
            _micLevel = rmsLevel(from: sampleBuffer)
            guard sessionStarted, writer.status == .writing,
                  let adjustedTime = adjustedTime(for: timestamp),
                  let micAudioInput, micAudioInput.isReadyForMoreMediaData else { return }
            if _microphoneStartHostTimeSeconds == nil {
                _microphoneStartHostTimeSeconds = hostNow
            }
            if lastMicTime.isValid && CMTimeCompare(adjustedTime, lastMicTime) <= 0 { return }
            if let retimed = retime(sampleBuffer: sampleBuffer, to: adjustedTime) {
                micAudioInput.append(retimed)
                lastMicTime = adjustedTime
            }
        @unknown default:
            break
        }
    }

    nonisolated private func adjustedTime(for timestamp: CMTime) -> CMTime? {
        guard let start = startTime else { return nil }
        let time = CMTimeSubtract(CMTimeSubtract(timestamp, start), totalPauseDuration)
        return CMTimeGetSeconds(time) >= 0 ? time : nil
    }

    nonisolated private func frameAttachments(
        from sampleBuffer: CMSampleBuffer
    ) -> [SCStreamFrameInfo: Any]? {
        guard let array = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]] else { return nil }
        return array.first
    }

    nonisolated private func frameIsComplete(
        _ attachments: [SCStreamFrameInfo: Any]
    ) -> Bool {
        let raw = (attachments[.status] as? NSNumber)?.intValue
            ?? attachments[.status] as? Int
        guard let raw, let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }

    nonisolated private func frameRect(
        _ key: SCStreamFrameInfo,
        in attachments: [SCStreamFrameInfo: Any]
    ) -> CGRect? {
        guard let value = attachments[key] else { return nil }
        if let value = value as? NSValue {
            return value.rectValue
        }
        if let dictionary = value as? NSDictionary {
            return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
        }
        return nil
    }

    nonisolated private func frameCGFloat(
        _ key: SCStreamFrameInfo,
        in attachments: [SCStreamFrameInfo: Any]
    ) -> CGFloat? {
        if let number = attachments[key] as? NSNumber {
            return CGFloat(number.doubleValue)
        }
        return attachments[key] as? CGFloat
    }

    /// Returns the actual window pixels inside SCK's IOSurface.
    ///
    /// `boundingRect`/`contentRect` are expressed in surface points. Multiplying
    /// both their origins and sizes by the per-frame scale factor converts them
    /// into CVPixelBuffer coordinates. For a single-window capture, boundingRect
    /// is the tightest description and avoids the global-origin padding seen in
    /// Chrome; contentRect remains the fallback for older frames.
    nonisolated private func windowSurfaceCropRect(
        attachments: [SCStreamFrameInfo: Any],
        pixelBuffer: CVPixelBuffer
    ) -> CGRect? {
        let scale = max(0.01, frameCGFloat(.scaleFactor, in: attachments) ?? 1)
        let metadataRects = [
            frameRect(.boundingRect, in: attachments),
            frameRect(.contentRect, in: attachments),
        ].compactMap { $0 }
        guard let metadataCrop = Self.windowSurfaceCropRect(
            metadataRects: metadataRects,
            scaleFactor: scale,
            surfaceSize: CGSize(
                width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer)
            )
        ) else { return nil }

        // The metadata has lied before (Chrome: a "content" rect describing
        // the whole padded surface — black frame in the file, cursor offset by
        // exactly the band). Pixels cannot lie: tighten the rect by trimming
        // uniform PADDING borders (transparent, or pure black — real UI edges,
        // even dark themes, are neither). Scanned only when the metadata rect
        // changes; all frame callbacks arrive on the serial writerQueue.
        if let cached = lastPaddingTighten, cached.metadata == metadataCrop {
            return cached.tight
        }
        let tight = Self.tightenCropToOpaqueContent(pixelBuffer, within: metadataCrop)
        lastPaddingTighten = (metadataCrop, tight)
        if tight != metadataCrop {
            recorderLogger.info("window crop tightened \(String(describing: metadataCrop), privacy: .public) -> \(String(describing: tight), privacy: .public)")
        }
        return tight
    }

    /// Shrinks `rect` until no edge row/column is entirely padding.
    ///
    /// Padding = alpha < 8 (SCK's independent-window surround is transparent)
    /// or r+g+b < 6 at full alpha (the encoded-black variant). A full edge
    /// line must be padding to trim, sampled every 4th pixel; trimming is
    /// capped at 40% per side so a pathological frame can never collapse the
    /// crop.
    nonisolated static func tightenCropToOpaqueContent(
        _ buffer: CVPixelBuffer,
        within rect: CGRect
    ) -> CGRect {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return rect }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return rect }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let bufferWidth = CVPixelBufferGetWidth(buffer)
        let bufferHeight = CVPixelBufferGetHeight(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)

        var minX = max(0, Int(rect.minX)), maxX = min(bufferWidth, Int(rect.maxX))
        var minY = max(0, Int(rect.minY)), maxY = min(bufferHeight, Int(rect.maxY))
        guard maxX - minX >= 4, maxY - minY >= 4 else { return rect }

        func isPadding(_ x: Int, _ y: Int) -> Bool {
            let p = bytes + y * bytesPerRow + x * 4  // B,G,R,A
            if p[3] < 8 { return true }
            return Int(p[0]) + Int(p[1]) + Int(p[2]) < 6
        }
        func rowIsPadding(_ y: Int) -> Bool {
            var x = minX
            while x < maxX {
                if !isPadding(x, y) { return false }
                x += 4
            }
            return true
        }
        func columnIsPadding(_ x: Int) -> Bool {
            var y = minY
            while y < maxY {
                if !isPadding(x, y) { return false }
                y += 4
            }
            return true
        }

        let capX = Int(rect.width * 0.4), capY = Int(rect.height * 0.4)
        let x0 = minX, x1 = maxX, y0 = minY, y1 = maxY
        while minY < y1 - 4, minY - y0 < capY, rowIsPadding(minY) { minY += 1 }
        while maxY > minY + 4, y1 - maxY < capY, rowIsPadding(maxY - 1) { maxY -= 1 }
        while minX < x1 - 4, minX - x0 < capX, columnIsPadding(minX) { minX += 1 }
        while maxX > minX + 4, x1 - maxX < capX, columnIsPadding(maxX - 1) { maxX -= 1 }

        let tightened = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        return tightened.width >= 2 && tightened.height >= 2 ? tightened : rect
    }

    /// Pure geometry seam used by `--preview-parity` with the captured Chrome
    /// repro dimensions. Keeping this calculation executable in the gate is
    /// important: a static compositor fixture cannot exercise SCK metadata.
    nonisolated static func windowSurfaceCropRectForTesting(
        metadataRects: [CGRect],
        scaleFactor: CGFloat,
        surfaceSize: CGSize
    ) -> CGRect? {
        windowSurfaceCropRect(
            metadataRects: metadataRects,
            scaleFactor: scaleFactor,
            surfaceSize: surfaceSize
        )
    }

    nonisolated static func coreImageCropRectForTesting(
        surfaceCropRect: CGRect,
        sourceHeight: CGFloat
    ) -> CGRect {
        coreImageCropRect(
            surfaceCropRect: surfaceCropRect,
            sourceHeight: sourceHeight
        )
    }

    nonisolated private static func windowSurfaceCropRect(
        metadataRects: [CGRect],
        scaleFactor: CGFloat,
        surfaceSize: CGSize
    ) -> CGRect? {
        let scale = max(0.01, scaleFactor)
        let surface = CGRect(origin: .zero, size: surfaceSize)
        for metadataRect in metadataRects where metadataRect.width > 0 && metadataRect.height > 0 {
            let proposed = metadataRect.applying(
                CGAffineTransform(scaleX: scale, y: scale)
            )
            let clipped = proposed.standardized.intersection(surface).integral
            if !clipped.isNull, clipped.width >= 2, clipped.height >= 2 {
                return clipped
            }
        }
        return nil
    }

    nonisolated private func evenDimension(_ value: CGFloat) -> Int {
        let rounded = max(2, Int(value.rounded()))
        return rounded.isMultiple(of: 2) ? rounded : rounded - 1
    }

    nonisolated private func croppedWindowPixelBuffer(
        _ source: CVPixelBuffer,
        cropRect: CGRect
    ) -> CVPixelBuffer? {
        guard let adaptor, let pool = adaptor.pixelBufferPool,
              windowOutputSize.width >= 2, windowOutputSize.height >= 2 else { return nil }

        var destination: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destination) == kCVReturnSuccess,
              let destination else { return nil }

        // SCK frame metadata uses a top-left origin; Core Image uses bottom-left.
        let sourceHeight = CGFloat(CVPixelBufferGetHeight(source))
        let ciCrop = Self.coreImageCropRect(
            surfaceCropRect: cropRect,
            sourceHeight: sourceHeight
        )
        let outputBounds = CGRect(origin: .zero, size: windowOutputSize)
        let translate = CGAffineTransform(translationX: -ciCrop.minX, y: -ciCrop.minY)
        let scale = CGAffineTransform(
            scaleX: outputBounds.width / ciCrop.width,
            y: outputBounds.height / ciCrop.height
        )
        let image = CIImage(cvPixelBuffer: source)
            .cropped(to: ciCrop)
            .transformed(by: translate)
            .transformed(by: scale)
        windowCropContext.render(
            image,
            to: destination,
            bounds: outputBounds,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )
        return destination
    }

    nonisolated private static func coreImageCropRect(
        surfaceCropRect: CGRect,
        sourceHeight: CGFloat
    ) -> CGRect {
        CGRect(
            x: surfaceCropRect.minX,
            y: sourceHeight - surfaceCropRect.maxY,
            width: surfaceCropRect.width,
            height: surfaceCropRect.height
        )
    }

    nonisolated private func rmsLevel(from sampleBuffer: CMSampleBuffer) -> Float {
        guard let dataBuffer = sampleBuffer.dataBuffer else { return 0 }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
        guard let data = dataPointer else { return 0 }
        let samples = data.withMemoryRebound(to: Float32.self, capacity: length / MemoryLayout<Float32>.size) { ptr in
            UnsafeBufferPointer(start: ptr, count: length / MemoryLayout<Float32>.size)
        }
        guard !samples.isEmpty else { return 0 }
        var sumOfSquares: Float = 0
        for sample in samples { sumOfSquares += sample * sample }
        return sqrt(sumOfSquares / Float(samples.count))
    }

    nonisolated private func retime(sampleBuffer: CMSampleBuffer, to newTime: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: sampleBuffer.duration,
            presentationTimeStamp: newTime,
            decodeTimeStamp: .invalid
        )
        var newBuffer: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &newBuffer
        )
        return newBuffer
    }
}
