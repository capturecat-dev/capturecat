import AVFoundation
import CoreMediaIO
import Foundation
import os

private let deviceLogger = Logger(subsystem: "so.capturecat.CaptureCat", category: "DeviceRecorder")

/// Records the screen of a connected iPhone or iPad. iOS devices surface as
/// CoreMediaIO "screen capture devices" (the same mechanism QuickTime's
/// New Movie Recording uses) once the global opt-in property is set. Frame PTS
/// are anchored to the shared host-clock origin so the device take lives on
/// the same timeline as the camera bubble and the editor pipeline.
@Observable
final class DeviceRecorder: NSObject {
    enum DeviceRecorderError: LocalizedError {
        case cannotUseDevice
        case writerFailed

        var errorDescription: String? {
            switch self {
            case .cannotUseDevice:
                return "The device can't be captured. Unlock it, keep it connected, and tap “Trust” if asked."
            case .writerFailed:
                return "Couldn't start writing the device recording."
            }
        }
    }

    private(set) var isRecording = false
    var outputURL: URL?

    /// Exposed so the recording UI can attach a live monitor preview layer.
    @ObservationIgnored private(set) var captureSession: AVCaptureSession?
    @ObservationIgnored private let sampleQueue = DispatchQueue(label: "so.capturecat.CaptureCat.deviceSamples")
    @ObservationIgnored private let sessionQueue = DispatchQueue(label: "so.capturecat.CaptureCat.deviceSession")
    @ObservationIgnored private nonisolated(unsafe) var writer: AVAssetWriter?
    @ObservationIgnored private nonisolated(unsafe) var videoInput: AVAssetWriterInput?
    @ObservationIgnored private nonisolated(unsafe) var audioInput: AVAssetWriterInput?
    @ObservationIgnored private nonisolated(unsafe) var micWriterInput: AVAssetWriterInput?
    @ObservationIgnored private nonisolated(unsafe) var lastMicTime: CMTime = .invalid
    @ObservationIgnored private nonisolated(unsafe) var wantsMicTrack = false
    /// Dedicated output for the Mac microphone — wired via an explicit
    /// connection so its samples never share (and lose) the device-audio path.
    @ObservationIgnored private var micAudioOutput: AVCaptureAudioDataOutput?
    @ObservationIgnored private nonisolated(unsafe) var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    @ObservationIgnored private nonisolated(unsafe) var recordingActive = false
    @ObservationIgnored private nonisolated(unsafe) var baseSampleTime: CMTime?
    @ObservationIgnored private nonisolated(unsafe) var lastVideoTime: CMTime = .invalid
    @ObservationIgnored private nonisolated(unsafe) var lastAudioTime: CMTime = .invalid
    @ObservationIgnored private nonisolated(unsafe) var _isPaused = false
    @ObservationIgnored private nonisolated(unsafe) var pauseStartTime: CMTime?
    @ObservationIgnored private nonisolated(unsafe) var totalPauseDuration: CMTime = .zero
    @ObservationIgnored private nonisolated(unsafe) var _sessionStartHostTimeSeconds: Double?
    /// Shared host-clock origin (see ScreenRecorder/CameraManager).
    @ObservationIgnored nonisolated(unsafe) var sharedOriginHostTime: CMTime?

    var sessionStartHostTimeSeconds: Double? { _sessionStartHostTimeSeconds }

    /// Opt in to CoreMediaIO screen-capture devices. Idempotent; devices can
    /// take a second or two to appear in discovery after the first call.
    static func enableDeviceDiscovery() {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var allow: UInt32 = 1
        let status = CMIOObjectSetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &allow
        )
        if status != kCMIOHardwareNoError {
            deviceLogger.error("enableDeviceDiscovery failed: \(status)")
        }
    }

    /// Connected iPhones/iPads. Screen-capture devices expose muxed
    /// (video+audio) media, which distinguishes them from external cameras.
    static var availableDevices: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: nil,
            position: .unspecified
        ).devices.filter { $0.hasMediaType(.muxed) }
    }

    func startRecording(
        device: AVCaptureDevice,
        sharedOrigin: CMTime?,
        microphoneDeviceID: String? = nil,
        captureMicrophone: Bool = false
    ) throws {
        guard captureSession == nil else { return }

        sharedOriginHostTime = sharedOrigin

        let newSession = AVCaptureSession()
        newSession.beginConfiguration()
        let input = try AVCaptureDeviceInput(device: device)
        guard newSession.canAddInput(input) else {
            throw DeviceRecorderError.cannotUseDevice
        }
        newSession.addInput(input)

        // Record the Mac's microphone alongside the device audio — otherwise
        // narration goes silent during phone segments. The mic gets its OWN
        // output via an explicit connection and its own writer track; sharing
        // the device-audio output would interleave two timelines and the
        // monotonicity guard would silently drop one of them.
        wantsMicTrack = false
        micAudioOutput = nil
        if captureMicrophone {
            let micDevice = microphoneDeviceID.flatMap { AVCaptureDevice(uniqueID: $0) }
                ?? AVCaptureDevice.default(for: .audio)
            if let micDevice,
               let micInput = try? AVCaptureDeviceInput(device: micDevice) {
                newSession.addInputWithNoConnections(micInput)
                let micOutput = AVCaptureAudioDataOutput()
                micOutput.setSampleBufferDelegate(self, queue: sampleQueue)
                newSession.addOutputWithNoConnections(micOutput)
                if let micPort = micInput.ports.first(where: { $0.mediaType == .audio }) {
                    let connection = AVCaptureConnection(inputPorts: [micPort], output: micOutput)
                    if newSession.canAddConnection(connection) {
                        newSession.addConnection(connection)
                        micAudioOutput = micOutput
                        wantsMicTrack = true
                    } else {
                        deviceLogger.error("mic connection rejected by device session")
                    }
                }
            } else {
                deviceLogger.error("couldn't attach microphone to device session")
            }
        }

        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.alwaysDiscardsLateVideoFrames = false
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.setSampleBufferDelegate(self, queue: sampleQueue)
        guard newSession.canAddOutput(videoOutput) else {
            throw DeviceRecorderError.cannotUseDevice
        }
        newSession.addOutput(videoOutput)

        let audioOutput = AVCaptureAudioDataOutput()
        audioOutput.setSampleBufferDelegate(self, queue: sampleQueue)
        if newSession.canAddOutput(audioOutput) {
            newSession.addOutput(audioOutput)
        }
        newSession.commitConfiguration()

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CaptureCat/Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let url = appSupport.appendingPathComponent("capturecat_recording_\(UUID().uuidString).mov")
        outputURL = url

        sampleQueue.sync {
            writer = nil
            videoInput = nil
            audioInput = nil
            micWriterInput = nil
            adaptor = nil
            baseSampleTime = nil
            lastVideoTime = .invalid
            lastAudioTime = .invalid
            lastMicTime = .invalid
            _isPaused = false
            pauseStartTime = nil
            totalPauseDuration = .zero
            _sessionStartHostTimeSeconds = nil
            recordingActive = true
        }

        captureSession = newSession
        sessionQueue.async {
            newSession.startRunning()
        }
        isRecording = true
    }

    func waitForSessionStart(timeout: TimeInterval = 3.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        while _sessionStartHostTimeSeconds == nil && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func pause() {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        sampleQueue.async { [self] in
            _isPaused = true
            pauseStartTime = now
        }
    }

    func resume() {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        sampleQueue.async { [self] in
            if let pauseStart = pauseStartTime {
                totalPauseDuration = CMTimeAdd(totalPauseDuration, CMTimeSubtract(now, pauseStart))
            }
            pauseStartTime = nil
            _isPaused = false
        }
    }

    func stopRecording() async {
        guard isRecording else { return }
        isRecording = false

        let sessionToStop = captureSession
        captureSession = nil

        // Stop sample delivery first (drains in-flight callbacks), then
        // finalize the writer; the session stops on its own queue so nothing
        // here can block on AVFoundation teardown.
        sampleQueue.sync { recordingActive = false }
        sessionQueue.async { sessionToStop?.stopRunning() }

        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        micWriterInput?.markAsFinished()
        if let writer, writer.status == .writing {
            await writer.finishWriting()
        }
        writer = nil
        videoInput = nil
        audioInput = nil
        micWriterInput = nil
        micAudioOutput = nil
        adaptor = nil
    }
}

extension DeviceRecorder: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard recordingActive, !_isPaused else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        let sampleTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let isVideo = output is AVCaptureVideoDataOutput

        if isVideo, writer == nil, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            setUpWriter(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
            baseSampleTime = sharedOriginHostTime ?? sampleTime
            _sessionStartHostTimeSeconds = sharedOriginHostTime.map { CMTimeGetSeconds($0) }
                ?? CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        }

        guard let writer, writer.status == .writing, let baseSampleTime else { return }

        var adjusted = CMTimeSubtract(CMTimeSubtract(sampleTime, baseSampleTime), totalPauseDuration)
        let adjustedSeconds = CMTimeGetSeconds(adjusted)
        guard adjustedSeconds.isFinite else { return }
        if adjusted < .zero {
            if isVideo { adjusted = .zero } else { return }
        }

        if isVideo {
            guard let videoInput, videoInput.isReadyForMoreMediaData,
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            if lastVideoTime.isValid && CMTimeCompare(adjusted, lastVideoTime) <= 0 { return }
            adaptor?.append(pixelBuffer, withPresentationTime: adjusted)
            lastVideoTime = adjusted
        } else if output === micAudioOutput {
            guard let micWriterInput, micWriterInput.isReadyForMoreMediaData else { return }
            if lastMicTime.isValid && CMTimeCompare(adjusted, lastMicTime) <= 0 { return }
            if let retimed = retime(sampleBuffer: sampleBuffer, to: adjusted) {
                micWriterInput.append(retimed)
                lastMicTime = adjusted
            }
        } else {
            guard let audioInput, audioInput.isReadyForMoreMediaData else { return }
            if lastAudioTime.isValid && CMTimeCompare(adjusted, lastAudioTime) <= 0 { return }
            if let retimed = retime(sampleBuffer: sampleBuffer, to: adjusted) {
                audioInput.append(retimed)
                lastAudioTime = adjusted
            }
        }
    }

    nonisolated private func setUpWriter(width: Int, height: Int) {
        guard let outputURL else { return }
        do {
            let newWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 16_000_000,
                    AVVideoExpectedSourceFrameRateKey: 60,
                    AVVideoAllowFrameReorderingKey: false,
                ] as [String: Any]
            ]
            let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            vInput.expectsMediaDataInRealTime = true
            guard newWriter.canAdd(vInput) else { return }
            newWriter.add(vInput)

            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ]
            let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            aInput.expectsMediaDataInRealTime = true
            if newWriter.canAdd(aInput) {
                newWriter.add(aInput)
                audioInput = aInput
            }

            if wantsMicTrack {
                let micSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 128_000,
                ]
                let mInput = AVAssetWriterInput(mediaType: .audio, outputSettings: micSettings)
                mInput.expectsMediaDataInRealTime = true
                if newWriter.canAdd(mInput) {
                    newWriter.add(mInput)
                    micWriterInput = mInput
                }
            }

            adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: vInput,
                sourcePixelBufferAttributes: nil
            )
            newWriter.startWriting()
            newWriter.startSession(atSourceTime: .zero)
            writer = newWriter
            videoInput = vInput
            deviceLogger.info("device writer started: \(width)x\(height)")
        } catch {
            deviceLogger.error("device writer setup failed: \(error.localizedDescription, privacy: .public)")
        }
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
