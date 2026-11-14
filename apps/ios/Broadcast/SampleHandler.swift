import ReplayKit
import UIKit

/// The ReplayKit broadcast upload extension: the whole iPhone screen, two ways.
///
/// • STREAM to a Mac on the same account and Wi-Fi ("iPhone over Wi-Fi"):
///   frames are hardware-encoded (StreamEncoder) and sent over the TLS-PSK
///   link (WirelessMacClient, role "broadcast"); the Mac records them exactly
///   like a cabled iPhone. App audio rides along; narration is the Mac's mic.
/// • RECORD on the iPhone: a local take in the App Group inbox
///   (LocalTakeWriter) that the app uploads as a cloud project.
///
/// The app chooses by writing `broadcastMode` before it opens the picker:
/// "stream" (fail clearly if no Mac turns up), "record", or "auto" — what a
/// broadcast started from Control Center gets: stream if a linked Mac answers
/// within 3 s, else record.
nonisolated final class SampleHandler: RPBroadcastSampleHandler, @unchecked Sendable {
    private enum Mode: String { case auto, stream, record }
    private enum Phase { case deciding, streaming, recording, finished }

    private let lock = NSLock()
    private var phase: Phase = .deciding
    private var client: WirelessMacClient?
    private var encoder: StreamEncoder?
    private var writer: LocalTakeWriter?
    private var sentAudioFormat: WirelessAudioFormat?
    private var refreshedLink = false
    /// Above this, frames are skipped instead of queued (Wi-Fi hiccup): the
    /// encoder simply sees fewer frames, so the stream stays decodable.
    private let inFlightBudget = 4 * 1024 * 1024

    // MARK: Lifecycle

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        let defaults = AppGroup.defaults
        let mode = Mode(rawValue: defaults.string(forKey: AppGroup.Keys.broadcastMode) ?? "") ?? .auto
        defaults.removeObject(forKey: AppGroup.Keys.broadcastMode)
        let preferred = defaults.string(forKey: AppGroup.Keys.preferredMacID)

        guard mode != .record, let link = WirelessLinkStore.cached() else {
            if mode == .stream {
                finish(error: "Sign in to CaptureCat on this iPhone and on your Mac with the same account, then try again.")
            } else {
                startRecording()
            }
            return
        }
        startStreaming(link: link, preferredMacID: preferred)
        let wait: TimeInterval = mode == .stream ? 12 : 3
        DispatchQueue.global().asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, self.currentPhase == .deciding else { return }
            if mode == .stream {
                self.finish(error: "Couldn't find your Mac. Open CaptureCat on your Mac — same Wi-Fi, same account — and try again.")
            } else {
                self.stopStreaming(reason: "no-mac")
                self.startRecording()
            }
        }
    }

    override func broadcastPaused() {
        writer?.pause()
    }

    override func broadcastResumed() {
        writer?.resume()
        encoder?.requestKeyframe()
    }

    override func broadcastFinished() {
        lock.lock()
        let wasPhase = phase
        phase = .finished
        lock.unlock()
        stopStreaming(reason: "broadcastFinished")
        if wasPhase == .recording || writer != nil, let writer {
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                await writer.finish()
                done.signal()
            }
            _ = done.wait(timeout: .now() + 10)
        }
    }

    // MARK: Samples

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        switch currentPhase {
        case .streaming:
            stream(sampleBuffer, type: sampleBufferType)
        case .recording:
            switch sampleBufferType {
            case .video: writer?.appendVideo(sampleBuffer, orientation: Self.orientation(of: sampleBuffer))
            case .audioApp: writer?.appendAudio(sampleBuffer, mic: false)
            case .audioMic: writer?.appendAudio(sampleBuffer, mic: true)
            @unknown default: break
            }
        case .deciding, .finished:
            break
        }
    }

    private func stream(_ sample: CMSampleBuffer, type: RPSampleBufferType) {
        guard let client, let encoder, client.isConnected else { return }
        switch type {
        case .video:
            guard client.bytesInFlight < inFlightBudget, let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
            encoder.encode(buffer, pts: CMSampleBufferGetPresentationTimeStamp(sample), orientation: Self.orientation(of: sample))
        case .audioApp:
            guard let packed = AppAudioPacker.pack(sample) else { return }
            lock.lock()
            let needsFormat = sentAudioFormat != packed.format
            if needsFormat { sentAudioFormat = packed.format }
            lock.unlock()
            if needsFormat { client.send(.audioFormat, WirelessJSON.encode(packed.format)) }
            client.send(.audioPCM, packed.chunk.encoded())
        case .audioMic:
            break // the Mac records its own microphone
        @unknown default:
            break
        }
    }

    // MARK: Modes

    private var currentPhase: Phase {
        lock.lock(); defer { lock.unlock() }
        return phase
    }

    private func startRecording() {
        do {
            let writer = try LocalTakeWriter()
            lock.lock()
            self.writer = writer
            if phase == .deciding { phase = .recording }
            lock.unlock()
        } catch {
            finish(error: "Couldn't start the recording: \(error.localizedDescription)")
        }
    }

    private func startStreaming(link: WirelessLink, preferredMacID: String?) {
        let encoder = StreamEncoder()
        let client = WirelessMacClient(role: WirelessDevice.roleBroadcast, hello: Self.helloSnapshot())
        encoder.onFormat = { [weak client] format in client?.send(.videoFormat, WirelessJSON.encode(format)) }
        encoder.onFrame = { [weak client] frame in client?.send(.videoFrame, frame.encoded()) }
        client.onStateChange = { [weak self, weak encoder] state in
            guard let self else { return }
            if case .connected = state {
                self.lock.lock()
                if self.phase == .deciding { self.phase = .streaming }
                self.sentAudioFormat = nil
                self.lock.unlock()
                encoder?.restartStream()
            }
        }
        client.onControl = { [weak encoder] control in
            if control.command == WirelessControl.keyframe.command { encoder?.requestKeyframe() }
        }
        client.onLinkRejected = { [weak self, weak client] in
            // The account key was rotated since we cached it: refetch once.
            guard let self, !self.refreshedLink else { return }
            self.refreshedLink = true
            Task {
                if let fresh = try? await WirelessLinkStore.refresh() {
                    client?.start(link: fresh, preferredMacID: preferredMacID)
                }
            }
        }
        lock.lock()
        self.encoder = encoder
        self.client = client
        lock.unlock()
        client.start(link: link, preferredMacID: preferredMacID)
    }

    private func stopStreaming(reason: String) {
        lock.lock()
        let client = self.client, encoder = self.encoder
        self.client = nil
        self.encoder = nil
        lock.unlock()
        client?.stop(reason: reason)
        encoder?.invalidate()
    }

    private func finish(error message: String) {
        lock.lock(); phase = .finished; lock.unlock()
        stopStreaming(reason: "error")
        finishBroadcastWithError(NSError(domain: "so.capturecat.ios.broadcast", code: 1,
                                         userInfo: [NSLocalizedDescriptionKey: message]))
    }

    // MARK: Helpers

    static func orientation(of sample: CMSampleBuffer) -> CGImagePropertyOrientation {
        guard let number = CMGetAttachment(sample, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber,
              let orientation = CGImagePropertyOrientation(rawValue: number.uint32Value) else { return .up }
        return orientation
    }

    /// Hello values that live on the main actor, captured once.
    static func helloSnapshot() -> @Sendable () -> WirelessHello {
        let read: @Sendable () -> WirelessHello = {
            MainActor.assumeIsolated {
                let screen = UIScreen.main
                let native = screen.nativeBounds.size
                return WirelessHello(
                    role: WirelessDevice.roleBroadcast,
                    deviceID: DeviceIdentity.deviceID,
                    deviceName: DeviceIdentity.name,
                    model: DeviceIdentity.model,
                    systemVersion: DeviceIdentity.systemVersion,
                    appVersion: DeviceIdentity.appVersion,
                    screenWidth: Int(min(native.width, native.height)),
                    screenHeight: Int(max(native.width, native.height)),
                    screenScale: Double(screen.nativeScale)
                )
            }
        }
        let hello = Thread.isMainThread ? read() : DispatchQueue.main.sync(execute: read)
        return { hello }
    }
}
