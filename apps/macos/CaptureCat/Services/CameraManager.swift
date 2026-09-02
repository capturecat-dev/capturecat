import Foundation
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

@Observable
final class CameraManager: NSObject {
    private(set) var captureSession: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private(set) var activeDeviceID: String?
    @ObservationIgnored private let captureQueue = DispatchQueue(label: "so.capturecat.CaptureCat.camera")
    /// AVCaptureSession start/stop are synchronous and can block for hundreds
    /// of ms (or deadlock against a preview layer teardown) — run them here so
    /// the UI and the recording stop-path never wait on the session.
    @ObservationIgnored private let sessionQueue = DispatchQueue(label: "so.capturecat.CaptureCat.cameraSession")
    @ObservationIgnored private let posterContext = CIContext(options: nil)
    @ObservationIgnored private nonisolated(unsafe) var assetWriter: AVAssetWriter?
    @ObservationIgnored private nonisolated(unsafe) var videoInput: AVAssetWriterInput?
    @ObservationIgnored private nonisolated(unsafe) var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    @ObservationIgnored private nonisolated(unsafe) var recordingBaseSampleTime: CMTime?
    @ObservationIgnored private nonisolated(unsafe) var lastFrameTime: CMTime = .invalid
    @ObservationIgnored private nonisolated(unsafe) var recordingActive = false
    @ObservationIgnored private nonisolated(unsafe) var _recordingURL: URL?
    @ObservationIgnored private nonisolated(unsafe) var _posterURL: URL?
    /// Most recent camera frame — written on the capture queue, read for
    /// poster snapshots. Not observable: the live preview renders through an
    /// AVCaptureVideoPreviewLayer, so per-frame UI updates aren't needed.
    @ObservationIgnored private nonisolated(unsafe) var latestFrame: CIImage?
    private(set) var isRunning = false
    private(set) var isRecording = false
    var recordingURL: URL? { _recordingURL }
    var posterURL: URL? { _posterURL }
    @ObservationIgnored private nonisolated(unsafe) var _recordingStartHostTimeSeconds: Double?
    @ObservationIgnored private nonisolated(unsafe) var awaitingRecordingStartSample = false
    @ObservationIgnored private nonisolated(unsafe) var _isPaused = false
    @ObservationIgnored private nonisolated(unsafe) var pauseStartTime: CMTime?
    @ObservationIgnored private nonisolated(unsafe) var totalPauseDuration: CMTime = .zero
    /// External shared host-clock origin. When set before recording starts,
    /// camera frame PTS are computed as `sampleTime − sharedOriginHostTime`
    /// instead of being anchored to the first sample. This puts the camera
    /// asset on the same timeline as the screen recorder when both are given
    /// the same origin.
    @ObservationIgnored nonisolated(unsafe) var sharedOriginHostTime: CMTime?

    var recordingStartHostTimeSeconds: Double? { _recordingStartHostTimeSeconds }

    /// Webcams plus connected iPhones/iPads (muxed screen-capture devices) —
    /// a phone can be used as the overlay "camera", Screen Studio-style.
    var availableDevices: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: nil,
            position: .unspecified
        ).devices.filter { $0.hasMediaType(.video) || $0.hasMediaType(.muxed) }
    }

    /// True when the given device is an iOS screen (muxed), not a camera.
    func isScreenDevice(deviceID: String?) -> Bool {
        guard let deviceID else { return false }
        return availableDevices.first { $0.uniqueID == deviceID }?.hasMediaType(.muxed) ?? false
    }

    func start(deviceID: String? = nil) throws {
        if isRunning {
            if activeDeviceID == deviceID || (activeDeviceID == nil && deviceID == nil) {
                return
            }
            stop()
        }

        _recordingStartHostTimeSeconds = nil
        awaitingRecordingStartSample = false
        let session = AVCaptureSession()

        let cam = availableDevices.first(where: { $0.uniqueID == deviceID }) ?? AVCaptureDevice.default(for: .video)
        guard let cam else { return }

        // Webcams downscale to .medium for the overlay; iOS screen devices
        // don't support camera presets — keep their native format.
        if !cam.hasMediaType(.muxed), session.canSetSessionPreset(.medium) {
            session.sessionPreset = .medium
        }

        let input = try AVCaptureDeviceInput(device: cam)
        guard session.canAddInput(input) else { return }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: captureQueue)
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        videoOutput = output

        captureSession = session
        activeDeviceID = cam.uniqueID
        sessionQueue.async {
            session.startRunning()
        }
        isRunning = true
    }

    func stop() {
        stopRecording()
        let session = captureSession
        captureSession = nil
        activeDeviceID = nil
        isRunning = false
        latestFrame = nil
        sessionQueue.async {
            session?.stopRunning()
        }
    }

    func startRecording() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CaptureCat/Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let recordingID = UUID().uuidString
        let baseURL = appSupport.appendingPathComponent("capturecat_camera_\(recordingID)")
        let url = baseURL.appendingPathExtension("mov")
        let posterURL = baseURL.appendingPathExtension("png")
        _recordingURL = url
        _posterURL = posterURL
        if let latestFrame {
            writePosterImage(latestFrame, to: posterURL)
        } else {
            try? FileManager.default.removeItem(at: posterURL)
        }
        captureQueue.sync {
            assetWriter = nil
            videoInput = nil
            adaptor = nil
            recordingBaseSampleTime = nil
            lastFrameTime = .invalid
            recordingActive = true
            _recordingStartHostTimeSeconds = nil
            awaitingRecordingStartSample = true
            _isPaused = false
            pauseStartTime = nil
            totalPauseDuration = .zero
        }
        isRecording = true
    }

    /// Pause/resume mirror ScreenRecorder's PTS shift so the camera stays on
    /// the shared timeline across pauses instead of drifting ahead of it.
    func pause() {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        captureQueue.async { [self] in
            _isPaused = true
            pauseStartTime = now
        }
    }

    func resume() {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        captureQueue.async { [self] in
            if let pauseStart = pauseStartTime {
                totalPauseDuration = CMTimeAdd(totalPauseDuration, CMTimeSubtract(now, pauseStart))
            }
            pauseStartTime = nil
            _isPaused = false
        }
    }

    func stopRecording() {
        if let latestFrame,
           let posterURL = _posterURL,
           !FileManager.default.fileExists(atPath: posterURL.path) {
            writePosterImage(latestFrame, to: posterURL)
        }
        var writer: AVAssetWriter?
        var input: AVAssetWriterInput?
        captureQueue.sync {
            recordingActive = false
            awaitingRecordingStartSample = false
            writer = assetWriter
            input = videoInput
            assetWriter = nil
            videoInput = nil
            adaptor = nil
            recordingBaseSampleTime = nil
            lastFrameTime = .invalid
        }
        input?.markAsFinished()
        if let writer {
            writer.finishWriting { }
        }
        isRecording = false
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let hostNow = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        if awaitingRecordingStartSample {
            _recordingStartHostTimeSeconds = hostNow
            awaitingRecordingStartSample = false
        }
        appendRecordingFrame(from: sampleBuffer, hostNow: hostNow)
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Keep only the newest frame for poster snapshots — no main-thread hop,
        // no SwiftUI invalidation per frame (30/s) while recording.
        latestFrame = CIImage(cvPixelBuffer: pixelBuffer)
    }

    nonisolated private func appendRecordingFrame(from sampleBuffer: CMSampleBuffer, hostNow: Double) {
        guard recordingActive, !_isPaused,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let recordingURL = _recordingURL else { return }

        if let posterURL = _posterURL,
           !FileManager.default.fileExists(atPath: posterURL.path) {
            writePosterImage(CIImage(cvPixelBuffer: pixelBuffer), to: posterURL)
        }

        let sampleTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if assetWriter == nil {
            do {
                let writer = try AVAssetWriter(outputURL: recordingURL, fileType: .mov)
                let width = CVPixelBufferGetWidth(pixelBuffer)
                let height = CVPixelBufferGetHeight(pixelBuffer)
                let settings: [String: Any] = [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: width,
                    AVVideoHeightKey: height,
                    AVVideoCompressionPropertiesKey: [
                        AVVideoAverageBitRateKey: 6_000_000,
                        AVVideoExpectedSourceFrameRateKey: 30,
                    ] as [String: Any]
                ]
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
                input.expectsMediaDataInRealTime = true
                guard writer.canAdd(input) else { return }
                writer.add(input)
                let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                    assetWriterInput: input,
                    sourcePixelBufferAttributes: [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                        kCVPixelBufferWidthKey as String: width,
                        kCVPixelBufferHeightKey as String: height,
                    ]
                )
                writer.startWriting()
                writer.startSession(atSourceTime: .zero)
                assetWriter = writer
                videoInput = input
                self.adaptor = adaptor
                // Anchor PTS to the shared host-clock origin if one was set —
                // this aligns the camera asset with the screen recording on a
                // single timeline. Otherwise fall back to first-sample anchor.
                recordingBaseSampleTime = sharedOriginHostTime ?? sampleTime
                lastFrameTime = .zero
                _recordingStartHostTimeSeconds = sharedOriginHostTime.map { CMTimeGetSeconds($0) } ?? hostNow
            } catch {
                return
            }
        }

        guard let recordingBaseSampleTime,
              let videoInput,
              videoInput.isReadyForMoreMediaData else { return }

        var presentationTime = CMTimeSubtract(CMTimeSubtract(sampleTime, recordingBaseSampleTime), totalPauseDuration)
        let presentationSeconds = CMTimeGetSeconds(presentationTime)
        if presentationSeconds.isNaN || presentationSeconds.isInfinite {
            return
        }
        if presentationTime < .zero {
            presentationTime = .zero
        }
        if lastFrameTime.isValid && CMTimeCompare(presentationTime, lastFrameTime) <= 0 {
            return
        }
        guard adaptor?.append(pixelBuffer, withPresentationTime: presentationTime) == true else { return }
        lastFrameTime = presentationTime
    }

    nonisolated private func writePosterImage(_ image: CIImage, to url: URL) {
        guard let cgImage = posterContext.createCGImage(image, from: image.extent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        CGImageDestinationFinalize(destination)
    }
}
