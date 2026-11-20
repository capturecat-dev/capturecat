import AVFoundation
import Foundation
import ImageIO

/// "Record on iPhone": the broadcast written to an inbox take
/// (`Inbox/<ID>/recording.mp4`) — screen video, app audio and microphone on
/// separate tracks, the way the Mac's recorders lay a take out. The app
/// uploads it as a cloud project when it next runs.
///
/// The video track keeps ReplayKit's native buffers and carries the take's
/// starting orientation as its transform (AVAssetWriter cannot change a
/// track's size mid-file); a phone turned mid-take plays sideways for that
/// stretch rather than corrupting the file.
nonisolated final class LocalTakeWriter: @unchecked Sendable {
    let take: PendingTake
    private let writer: AVAssetWriter
    private var video: AVAssetWriterInput?
    private var appAudio: AVAssetWriterInput?
    private var micAudio: AVAssetWriterInput?
    private var started = false
    private var firstPTS: CMTime = .invalid
    private var lastPTS: CMTime = .invalid
    private var pixelSize = (0, 0)
    private let lock = NSLock()

    /// Time to subtract from every sample (broadcast pauses).
    private var pausedTotal: CMTime = .zero
    private var pausedAt: CMTime?
    private var lastSeen: CMTime = .invalid

    init() throws {
        let id = UUID().uuidString
        let folder = try TakeInbox.makeFolder(id: id)
        let url = folder.appendingPathComponent("recording.mp4")
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let now = Date()
        take = PendingTake(id: id, kind: .screenRecording, name: MediaImport.defaultName(for: .screenRecording, date: now),
                           createdAt: now, mediaFile: "recording.mp4", contentType: "video/mp4", duration: 0,
                           pixelWidth: 0, pixelHeight: 0, state: .recording, error: nil)
        try TakeInbox.save(take)
    }

    func pause() {
        lock.lock(); defer { lock.unlock() }
        if pausedAt == nil { pausedAt = lastSeen }
    }

    func resume() {
        // The gap is measured at the first sample after resuming.
    }

    private func retime(_ sample: CMSampleBuffer) -> CMSampleBuffer? {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        if let pausedAt, pausedAt.isValid {
            pausedTotal = pausedTotal + (pts - pausedAt)
            self.pausedAt = nil
        }
        lastSeen = pts
        guard pausedTotal > .zero else { return sample }
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sample),
                                        presentationTimeStamp: pts - pausedTotal,
                                        decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: 1,
                                              sampleTimingArray: &timing, sampleBufferOut: &out)
        return out
    }

    func appendVideo(_ sample: CMSampleBuffer, orientation: CGImagePropertyOrientation) {
        lock.lock(); defer { lock.unlock() }
        guard let sample = retime(sample), let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
        if !started {
            let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
            let bitrate = min(20_000_000, max(6_000_000, Int(Double(w * h) * 30 * 0.15)))
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: w,
                AVVideoHeightKey: h,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitrate,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoMaxKeyFrameIntervalDurationKey: 2,
                ],
            ])
            input.expectsMediaDataInRealTime = true
            input.transform = Self.transform(for: orientation, width: w, height: h)
            let upright = orientation == .left || orientation == .right || orientation == .leftMirrored || orientation == .rightMirrored
            pixelSize = upright ? (h, w) : (w, h)
            guard writer.canAdd(input) else { return }
            writer.add(input)
            video = input
            for kind in ["app", "mic"] {
                let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: kind == "app" ? 2 : 1,
                    AVEncoderBitRateKey: kind == "app" ? 160_000 : 96_000,
                ])
                audio.expectsMediaDataInRealTime = true
                if writer.canAdd(audio) {
                    writer.add(audio)
                    if kind == "app" { appAudio = audio } else { micAudio = audio }
                }
            }
            guard writer.startWriting() else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            writer.startSession(atSourceTime: pts)
            firstPTS = pts
            started = true
        }
        if let video, video.isReadyForMoreMediaData, video.append(sample) {
            lastPTS = CMSampleBufferGetPresentationTimeStamp(sample)
        }
    }

    func appendAudio(_ sample: CMSampleBuffer, mic: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard started, let sample = retime(sample) else { return }
        guard CMSampleBufferGetPresentationTimeStamp(sample) >= firstPTS else { return }
        let input = mic ? micAudio : appAudio
        if let input, input.isReadyForMoreMediaData { input.append(sample) }
    }

    /// Finish the file and hand the take to the app (state → pending). A take
    /// with no frames is removed.
    func finish() async {
        lock.lock()
        let wasStarted = started
        let duration = (lastPTS.isValid && firstPTS.isValid) ? (lastPTS - firstPTS).seconds : 0
        let size = pixelSize
        video?.markAsFinished()
        appAudio?.markAsFinished()
        micAudio?.markAsFinished()
        lock.unlock()
        guard wasStarted, duration > 0.2 else {
            writer.cancelWriting()
            TakeInbox.remove(take.id)
            return
        }
        await writer.finishWriting()
        if writer.status == .completed {
            TakeInbox.update(take.id) {
                $0.state = .pending
                $0.duration = duration
                $0.pixelWidth = size.0
                $0.pixelHeight = size.1
            }
        } else {
            TakeInbox.update(take.id) {
                $0.state = .failed
                $0.error = self.writer.error?.localizedDescription ?? String(localized: "The recording couldn't be saved.")
            }
        }
    }

    static func transform(for orientation: CGImagePropertyOrientation, width: Int, height: Int) -> CGAffineTransform {
        switch orientation {
        case .right, .rightMirrored: return CGAffineTransform(rotationAngle: .pi / 2)
        case .left, .leftMirrored: return CGAffineTransform(rotationAngle: -.pi / 2)
        case .down, .downMirrored: return CGAffineTransform(rotationAngle: .pi)
        default: return .identity
        }
    }
}
