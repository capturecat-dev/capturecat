import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import os

nonisolated private let wirelessRecLogger = Logger(subsystem: "so.capturecat.CaptureCat", category: "WirelessDeviceRecorder")

/// Records an iPhone streaming over Wi-Fi — the wireless twin of
/// `DeviceRecorder`, with the same surface so AppState treats both alike:
/// one `.device` segment per take/switch, PTS anchored to the shared
/// host-clock origin, the Mac microphone on its own track.
///
/// Track order matches DeviceRecorder exactly — video, then the phone's
/// audio (app audio from `audioPCM`, or silence when the phone sends none),
/// then the mic — because RecordingStitcher and ProjectAudioMix take audio
/// tracks BY POSITION (index 0 = system/device audio, 1 = microphone). A
/// missing first audio track would put the narration in the system lane.
@Observable
final class WirelessDeviceRecorder: NSObject {
    enum RecorderError: LocalizedError {
        case notStreaming
        case writerFailed

        var errorDescription: String? {
            switch self {
            case .notStreaming:
                return "The iPhone isn't streaming. Tap Start Broadcast in CaptureCat on your iPhone."
            case .writerFailed:
                return "Couldn't start writing the iPhone recording."
            }
        }
    }

    /// Where the Mac microphone comes from: a capture session (the app) or
    /// buffers the gate injects (`injectMicrophone`) — same writer path.
    enum MicrophoneFeed {
        case capture
        case injected
    }

    /// Always a device segment — the editor and exporter draw the bezel.
    let recordingSourceKind: RecordingSourceKind = .device

    private(set) var isRecording = false
    /// The segment file. nil after `stopRecording` when the phone never
    /// delivered a frame (nothing to stitch — the take's other segments stand).
    var outputURL: URL?
    /// Lowercase device id of the phone being recorded.
    private(set) var phoneKey: String?

    @ObservationIgnored nonisolated(unsafe) var sharedOriginHostTime: CMTime?
    @ObservationIgnored private var segment: WirelessSegmentWriter?
    @ObservationIgnored private weak var server: WirelessServer?
    @ObservationIgnored private var micSession: AVCaptureSession?
    @ObservationIgnored private let sessionQueue = DispatchQueue(label: "so.capturecat.CaptureCat.wirelessMicSession")
    /// The last finished segment's numbers (harness).
    @ObservationIgnored private(set) var lastStats: WirelessSegmentWriter.Stats?

    var sessionStartHostTimeSeconds: Double? { segment?.sessionStartHostTimeSeconds }

    /// Begin a segment for the phone `key` on `server`. Asks the phone for a
    /// keyframe; the first written frame is that keyframe (a 2 s fallback
    /// accepts any decoded frame from a sender that never sends one).
    func startRecording(
        phone key: String,
        server: WirelessServer,
        sharedOrigin: CMTime?,
        microphoneDeviceID: String? = nil,
        captureMicrophone: Bool = false,
        microphoneFeed: MicrophoneFeed = .capture,
        directory: URL? = nil
    ) throws {
        guard segment == nil else { return }
        sharedOriginHostTime = sharedOrigin

        let folder = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CaptureCat/Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("capturecat_recording_\(UUID().uuidString).mov")
        outputURL = url

        var micOutput: AVCaptureAudioDataOutput?
        var session: AVCaptureSession?
        var wantsMic = false
        if captureMicrophone {
            switch microphoneFeed {
            case .injected:
                wantsMic = true
            case .capture:
                // The Mac mic on its own session and its own track, exactly as
                // DeviceRecorder records it during a cabled phone segment.
                let micDevice = microphoneDeviceID.flatMap { AVCaptureDevice(uniqueID: $0) }
                    ?? AVCaptureDevice.default(for: .audio)
                if let micDevice, let input = try? AVCaptureDeviceInput(device: micDevice) {
                    let newSession = AVCaptureSession()
                    newSession.beginConfiguration()
                    let output = AVCaptureAudioDataOutput()
                    if newSession.canAddInput(input), newSession.canAddOutput(output) {
                        newSession.addInput(input)
                        newSession.addOutput(output)
                        micOutput = output
                        session = newSession
                        wantsMic = true
                    }
                    newSession.commitConfiguration()
                } else {
                    wirelessRecLogger.error("couldn't attach the microphone to the wireless segment")
                }
            }
        }

        let writer = WirelessSegmentWriter(outputURL: url, sharedOrigin: sharedOrigin, wantsMicTrack: wantsMic)
        if let micOutput { micOutput.setSampleBufferDelegate(writer, queue: writer.sampleQueue) }
        segment = writer
        self.server = server
        phoneKey = WirelessIdentity.key(key)
        server.attach(sink: writer, to: key)
        if let session {
            micSession = session
            sessionQueue.async { session.startRunning() }
        }
        isRecording = true
    }

    /// Waits for the first written frame (the keyframe), like DeviceRecorder.
    func waitForSessionStart(timeout: TimeInterval = 3.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        while segment?.sessionStartHostTimeSeconds == nil && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func pause() {
        segment?.pause(at: CMClockGetTime(CMClockGetHostTimeClock()))
    }

    func resume() {
        segment?.resume(at: CMClockGetTime(CMClockGetHostTimeClock()))
    }

    /// Harness: feed a microphone buffer through the real mic path.
    func injectMicrophone(_ sample: CMSampleBuffer) {
        segment?.appendMicrophone(sample)
    }

    func stopRecording() async {
        guard isRecording, let writer = segment else { return }
        isRecording = false
        server?.detach(sink: writer)
        let session = micSession
        micSession = nil
        sessionQueue.async { session?.stopRunning() }
        let result = await writer.finish()
        lastStats = result.stats
        if !result.wroteFrames {
            // The phone never delivered a frame: no segment to stitch.
            if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
            outputURL = nil
        }
        segment = nil
        server = nil
        phoneKey = nil
    }
}

// MARK: - Segment writer

/// The writer behind one wireless segment. All state lives on `sampleQueue`
/// (decoded frames and audio hop there from the server queue; mic buffers
/// arrive there from AVFoundation), mirroring DeviceRecorder's model.
nonisolated final class WirelessSegmentWriter: NSObject, WirelessMediaSink, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    struct Stats: Sendable {
        var canvas: CGSize = .zero
        var framesWritten = 0
        var framesSkippedAwaitingKeyframe = 0
        var firstWrittenWasKeyframe = false
        /// Frames whose size differed from the canvas (rotation) — written
        /// aspect-fit (letterboxed), never stretched.
        var letterboxedFrames = 0
        var appAudioChunks = 0
        var silenceSeconds: Double = 0
        var micBuffers = 0
        var nonMonotonicDropped = 0
        var writerError: String?
    }

    /// `--wireless-device-test --inject-defect`: stretch instead of
    /// letterbox, and no phone-audio track (the mic slides to index 0) —
    /// the gate must fail on both.
    nonisolated(unsafe) static var debugInjectStretch = false
    nonisolated(unsafe) static var debugInjectNoPhoneTrack = false

    let sampleQueue = DispatchQueue(label: "so.capturecat.CaptureCat.wirelessSamples")
    private let outputURL: URL
    private let sharedOrigin: CMTime?
    private let wantsMicTrack: Bool

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?
    private var transfer: VTPixelTransferSession?
    private var canvas: CGSize = .zero

    private var active = true
    private var paused = false
    private var pauseStart: CMTime?
    private var totalPause: CMTime = .zero
    private var baseSampleTime: CMTime?
    private var lastVideoTime: CMTime = .invalid
    private var lastMicTime: CMTime = .invalid
    /// End of the last appended phone-audio buffer (silence or app audio):
    /// the next one never starts before it.
    private var nextAudioTime: CMTime = .zero
    private var appAudioSeen = false
    private let keyframeDeadline: Date
    private var audioConverter: WirelessAudioConverter?
    private var stats = Stats()
    private var _sessionStart: Double?

    /// The phone track's internal format: everything (silence, any phone
    /// rate/channel count) is converted to this before it reaches the writer,
    /// so the input never sees a format change mid-segment.
    static let audioSampleRate: Double = 48_000
    static let audioChannels: AVAudioChannelCount = 2

    var sessionStartHostTimeSeconds: Double? { sampleQueue.sync { _sessionStart } }

    init(outputURL: URL, sharedOrigin: CMTime?, wantsMicTrack: Bool, keyframeGrace: TimeInterval = 2.0) {
        self.outputURL = outputURL
        self.sharedOrigin = sharedOrigin
        self.wantsMicTrack = wantsMicTrack
        keyframeDeadline = Date().addingTimeInterval(keyframeGrace)
        super.init()
    }

    // MARK: Pause

    func pause(at now: CMTime) {
        sampleQueue.async { [self] in
            paused = true
            pauseStart = now
        }
    }

    func resume(at now: CMTime) {
        sampleQueue.async { [self] in
            if let pauseStart { totalPause = CMTimeAdd(totalPause, CMTimeSubtract(now, pauseStart)) }
            pauseStart = nil
            paused = false
        }
    }

    // MARK: WirelessMediaSink (server queue → sample queue)

    func wirelessDidDecode(_ pixelBuffer: CVPixelBuffer, hostTime: CMTime, isKeyframe: Bool) {
        sampleQueue.async { [self] in appendVideo(pixelBuffer, hostTime: hostTime, isKeyframe: isKeyframe) }
    }

    func wirelessDidReceiveAudio(_ chunk: WirelessAudioChunk, format: WirelessAudioFormat, hostTime: CMTime) {
        sampleQueue.async { [self] in appendAppAudio(chunk, format: format, hostTime: hostTime) }
    }

    // MARK: Microphone

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        appendMicrophoneOnQueue(sampleBuffer)
    }

    func appendMicrophone(_ sample: CMSampleBuffer) {
        sampleQueue.async { [self] in appendMicrophoneOnQueue(sample) }
    }

    private func appendMicrophoneOnQueue(_ sample: CMSampleBuffer) {
        guard active, !paused, CMSampleBufferDataIsReady(sample) else { return }
        guard let writer, writer.status == .writing, let micInput, let baseSampleTime else { return }
        let adjusted = CMTimeSubtract(CMTimeSubtract(sample.presentationTimeStamp, baseSampleTime), totalPause)
        guard CMTimeGetSeconds(adjusted).isFinite, adjusted >= .zero, micInput.isReadyForMoreMediaData else { return }
        if lastMicTime.isValid && CMTimeCompare(adjusted, lastMicTime) <= 0 { return }
        if let retimed = Self.retime(sample, to: adjusted), micInput.append(retimed) {
            lastMicTime = adjusted
            stats.micBuffers += 1
        }
    }

    // MARK: Video

    private func appendVideo(_ pixelBuffer: CVPixelBuffer, hostTime: CMTime, isKeyframe: Bool) {
        guard active, !paused else { return }
        if writer == nil {
            // Start on a keyframe (the one we asked for at segment start).
            if !isKeyframe && Date() < keyframeDeadline {
                stats.framesSkippedAwaitingKeyframe += 1
                return
            }
            guard setUpWriter(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer)) else { return }
            baseSampleTime = sharedOrigin ?? hostTime
            _sessionStart = sharedOrigin.map { CMTimeGetSeconds($0) }
                ?? CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
            stats.firstWrittenWasKeyframe = isKeyframe
        }
        guard let writer, writer.status == .writing, let videoInput, let adaptor, let baseSampleTime else { return }

        var adjusted = CMTimeSubtract(CMTimeSubtract(hostTime, baseSampleTime), totalPause)
        guard CMTimeGetSeconds(adjusted).isFinite else { return }
        if adjusted < .zero { adjusted = .zero }
        if lastVideoTime.isValid && CMTimeCompare(adjusted, lastVideoTime) <= 0 {
            stats.nonMonotonicDropped += 1
            return
        }
        guard videoInput.isReadyForMoreMediaData else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let frame: CVPixelBuffer
        if CGFloat(width) == canvas.width && CGFloat(height) == canvas.height {
            frame = pixelBuffer
        } else {
            // Rotated (or resized) mid-segment: aspect-fit into the canvas
            // fixed at segment start, black bars around it. Never stretch.
            guard let fitted = letterbox(pixelBuffer, pool: adaptor.pixelBufferPool) else { return }
            frame = fitted
            stats.letterboxedFrames += 1
        }
        if adaptor.append(frame, withPresentationTime: adjusted) {
            lastVideoTime = adjusted
            stats.framesWritten += 1
        }
        // No app audio from the phone (yet): keep the phone-audio track
        // filled with silence up to this frame so the track exists and the
        // mic stays the SECOND audio track.
        if !appAudioSeen { appendSilence(until: adjusted) }
    }

    private func letterbox(_ source: CVPixelBuffer, pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var destination: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destination)
        guard let destination else { return nil }
        if transfer == nil {
            var session: VTPixelTransferSession?
            VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session)
            if let session {
                VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_ScalingMode,
                                     value: Self.debugInjectStretch ? kVTScalingMode_Normal : kVTScalingMode_Letterbox)
            }
            transfer = session
        }
        guard let transfer else { return nil }
        // Letterbox mode leaves the bars untouched: clear to black first.
        Self.fillBlack(destination)
        let status = VTPixelTransferSessionTransferImage(transfer, from: source, to: destination)
        return status == noErr ? destination : nil
    }

    private static func fillBlack(_ buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        // BGRA bytes 00 00 00 FF: black, opaque.
        var pattern: [UInt8] = [0, 0, 0, 0xFF]
        memset_pattern4(base, &pattern, rowBytes * height)
    }

    // MARK: Phone audio

    private func appendAppAudio(_ chunk: WirelessAudioChunk, format: WirelessAudioFormat, hostTime: CMTime) {
        guard active, !paused, let writer, writer.status == .writing, let audioInput, let baseSampleTime else { return }
        appAudioSeen = true
        if audioConverter?.source != format {
            audioConverter = WirelessAudioConverter(source: format, sampleRate: Self.audioSampleRate, channels: Self.audioChannels)
        }
        guard let converter = audioConverter, let pcm = converter.convert(chunk) else { return }
        let adjusted = CMTimeSubtract(CMTimeSubtract(hostTime, baseSampleTime), totalPause)
        guard CMTimeGetSeconds(adjusted).isFinite else { return }
        // Never overlap the previous buffer; a gap (dropped chunk) is fine.
        let start = adjusted < nextAudioTime ? nextAudioTime : adjusted
        guard let sample = Self.makeAudioSample(pcm, at: start), audioInput.isReadyForMoreMediaData else { return }
        if audioInput.append(sample) {
            nextAudioTime = CMTimeAdd(start, CMTime(value: CMTimeValue(pcm.frameLength), timescale: CMTimeScale(Self.audioSampleRate)))
            stats.appAudioChunks += 1
        }
    }

    private func appendSilence(until end: CMTime) {
        guard let audioInput, end > nextAudioTime else { return }
        let rate = Self.audioSampleRate
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate,
                                         channels: Self.audioChannels, interleaved: true) else { return }
        while end > nextAudioTime, audioInput.isReadyForMoreMediaData {
            let remaining = CMTimeGetSeconds(CMTimeSubtract(end, nextAudioTime))
            let frames = AVAudioFrameCount(min(rate, max(1, (remaining * rate).rounded(.up))))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
            buffer.frameLength = frames
            if let data = buffer.int16ChannelData { memset(data[0], 0, Int(frames) * Int(Self.audioChannels) * 2) }
            guard let sample = Self.makeAudioSample(buffer, at: nextAudioTime), audioInput.append(sample) else { return }
            nextAudioTime = CMTimeAdd(nextAudioTime, CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(rate)))
            stats.silenceSeconds += Double(frames) / rate
        }
    }

    private static func makeAudioSample(_ buffer: AVAudioPCMBuffer, at time: CMTime) -> CMSampleBuffer? {
        let asbd = buffer.format.streamDescription
        var description: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description
        ) == noErr, let description else { return nil }
        var sample: CMSampleBuffer?
        let timescale = CMTimeScale(buffer.format.sampleRate)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: timescale),
            presentationTimeStamp: CMTimeConvertScale(time, timescale: timescale, method: .roundHalfAwayFromZero),
            decodeTimeStamp: .invalid
        )
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: description,
            sampleCount: CMItemCount(buffer.frameLength), sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &sample
        ) == noErr, let sample else { return nil }
        guard CMSampleBufferSetDataBufferFromAudioBufferList(
            sample, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, bufferList: buffer.audioBufferList
        ) == noErr else { return nil }
        return sample
    }

    // MARK: Writer

    private func setUpWriter(width: Int, height: Int) -> Bool {
        do {
            let newWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
            let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 16_000_000,
                    AVVideoExpectedSourceFrameRateKey: 60,
                    AVVideoAllowFrameReorderingKey: false,
                ] as [String: Any],
            ])
            video.expectsMediaDataInRealTime = true
            guard newWriter.canAdd(video) else { return false }
            newWriter.add(video)

            // Phone audio FIRST (index 0 — the system/device lane), always.
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: Self.audioSampleRate,
                AVNumberOfChannelsKey: Int(Self.audioChannels),
                AVEncoderBitRateKey: 128_000,
            ])
            audio.expectsMediaDataInRealTime = true
            if !Self.debugInjectNoPhoneTrack {
                guard newWriter.canAdd(audio) else { return false }
                newWriter.add(audio)
                audioInput = audio
            }

            // Then the Mac microphone (index 1), as DeviceRecorder does.
            if wantsMicTrack {
                let mic = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 128_000,
                ])
                mic.expectsMediaDataInRealTime = true
                if newWriter.canAdd(mic) {
                    newWriter.add(mic)
                    micInput = mic
                }
            }

            adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ])
            guard newWriter.startWriting() else {
                stats.writerError = newWriter.error?.localizedDescription
                return false
            }
            newWriter.startSession(atSourceTime: .zero)
            writer = newWriter
            videoInput = video
            canvas = CGSize(width: width, height: height)
            stats.canvas = canvas
            wirelessRecLogger.info("wireless writer started: \(width)x\(height)")
            return true
        } catch {
            stats.writerError = error.localizedDescription
            wirelessRecLogger.error("wireless writer setup failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    struct Finish: Sendable {
        let wroteFrames: Bool
        let stats: Stats
    }

    /// Stop taking samples and finalize. Drains everything already queued.
    func finish() async -> Finish {
        let (writer, inputs, wrote): (AVAssetWriter?, [AVAssetWriterInput], Bool) = sampleQueue.sync {
            active = false
            // A segment that never heard app audio still gets a full-length
            // silent phone track (index 0), so the mic stays index 1.
            if !appAudioSeen, lastVideoTime.isValid, audioInput != nil {
                let tail = CMTimeAdd(lastVideoTime, CMTime(value: 1, timescale: 60))
                var spins = 0
                while tail > nextAudioTime, spins < 200 {
                    appendSilence(until: tail)
                    if tail > nextAudioTime { usleep(2_000); spins += 1 }
                }
            }
            let inputs = [videoInput, audioInput, micInput].compactMap { $0 }
            return (self.writer, inputs, stats.framesWritten > 0)
        }
        for input in inputs { input.markAsFinished() }
        if let writer, writer.status == .writing {
            await writer.finishWriting()
            if writer.status != .completed {
                sampleQueue.sync { stats.writerError = writer.error?.localizedDescription ?? "status \(writer.status.rawValue)" }
            }
        } else if let writer {
            sampleQueue.sync { stats.writerError = writer.error?.localizedDescription ?? "status \(writer.status.rawValue)" }
        }
        let finalStats = sampleQueue.sync { stats }
        let ok = wrote && (writer?.status == .completed)
        return Finish(wroteFrames: ok, stats: finalStats)
    }

    private static func retime(_ sample: CMSampleBuffer, to time: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(duration: sample.duration, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleBufferOut: &out
        )
        return out
    }
}

// MARK: - App audio conversion

/// Interleaved Int16 phone audio (any rate, 1–8 channels) → the segment's
/// fixed 48 kHz stereo Int16, so silence and real audio share one format.
nonisolated final class WirelessAudioConverter {
    let source: WirelessAudioFormat
    private let input: AVAudioFormat
    private let output: AVAudioFormat
    private let converter: AVAudioConverter

    init?(source: WirelessAudioFormat, sampleRate: Double, channels: AVAudioChannelCount) {
        guard let input = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: source.sampleRate,
                                        channels: AVAudioChannelCount(source.channels), interleaved: true),
              let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate,
                                         channels: channels, interleaved: true),
              let converter = AVAudioConverter(from: input, to: output) else { return nil }
        if source.channels == 1, channels == 2 { converter.channelMap = [0, 0] }
        self.source = source
        self.input = input
        self.output = output
        self.converter = converter
    }

    func convert(_ chunk: WirelessAudioChunk) -> AVAudioPCMBuffer? {
        let bytesPerFrame = source.channels * 2
        let frames = min(Int(chunk.frameCount), chunk.samples.count / max(1, bytesPerFrame))
        guard frames > 0, let inBuffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        inBuffer.frameLength = AVAudioFrameCount(frames)
        chunk.samples.withUnsafeBytes { raw in
            if let dst = inBuffer.int16ChannelData?[0], let src = raw.baseAddress {
                memcpy(dst, src, frames * bytesPerFrame)
            }
        }
        if input == output { return inBuffer }
        let ratio = output.sampleRate / input.sampleRate
        let capacity = AVAudioFrameCount((Double(frames) * ratio).rounded(.up) + 64)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return inBuffer
        }
        guard status != .error, outBuffer.frameLength > 0 else { return nil }
        return outBuffer
    }
}
