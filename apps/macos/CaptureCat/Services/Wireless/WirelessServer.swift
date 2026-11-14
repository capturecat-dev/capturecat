import CoreMedia
import CoreVideo
import Foundation
import Network
import os

nonisolated private let serverLogger = Logger(subsystem: "so.capturecat.CaptureCat", category: "WirelessServer")

/// Where a recording phone's media goes. Called on the server's queue, in
/// arrival order; `hostTime` is already mapped onto THIS Mac's host clock
/// (the clock `sharedOriginHostTime` and DeviceRecorder's samples use).
nonisolated protocol WirelessMediaSink: AnyObject, Sendable {
    func wirelessDidDecode(_ pixelBuffer: CVPixelBuffer, hostTime: CMTime, isKeyframe: Bool)
    func wirelessDidReceiveAudio(_ chunk: WirelessAudioChunk, format: WirelessAudioFormat, hostTime: CMTime)
}

/// One phone as the UI sees it — merged over its "app" and "broadcast"
/// connections (same deviceID = one phone).
nonisolated struct WirelessPhoneSnapshot: Equatable, Sendable {
    /// Lowercase device id (the phone sends uppercase; the API lowercase).
    var key: String
    var deviceID: String
    var name: String
    var model: String
    var hasApp: Bool
    var hasBroadcast: Bool
    /// Broadcasting AND at least one keyframe decoded — recordable.
    var isStreaming: Bool
    /// Current decoded (upright) dimensions, 0 until a format arrives.
    var width: Int
    var height: Int
    var screenWidth: Int
    var screenHeight: Int
}

/// The Mac end of "iPhone over Wi-Fi": a TLS-PSK `NWListener` advertising
/// `_ccwireless._tcp`, the per-connection conversation (hello → macHello →
/// formats/frames/audio, controls back), VideoToolbox decoding, clock
/// mapping, and fan-out of decoded frames to the live monitor and to the
/// recorder of the phone being recorded.
///
/// Everything runs on ONE serial queue (`queue`). The main-actor model
/// (`WirelessDeviceHub`) hears about phones through `onPhonesChanged`.
nonisolated final class WirelessServer: @unchecked Sendable {
    let link: WirelessLink
    let macID: String
    let macName: String
    let queue = DispatchQueue(label: "so.capturecat.CaptureCat.wireless", qos: .userInitiated)

    /// Server queue. The full phone list after every change worth showing.
    var onPhonesChanged: (@Sendable ([WirelessPhoneSnapshot]) -> Void)?
    /// Server queue. Listener ready (port) / failed (nil).
    var onListenerState: (@Sendable (UInt16?) -> Void)?
    /// Server queue. A phone asked to continue a cloud project on this Mac
    /// ("Continue on Mac"): the uppercase project id and the phone's name.
    var onOpenProject: (@Sendable (_ projectID: String, _ phoneName: String) -> Void)?

    private var listener: NWListener?
    private var peers: [ObjectIdentifier: Peer] = [:]
    private var phones: [String: Phone] = [:]
    private var lastPublished: [WirelessPhoneSnapshot] = []
    private(set) var stats = Stats()

    struct Stats: Sendable {
        var accepted = 0
        var rejectedHello = 0
        var framesDecoded = 0
        var decodeErrors = 0
        var keyframeRequests = 0
        var formatChanges = 0
    }

    /// Harness: everything the gate reads from the server, read on its queue.
    func snapshotStats() -> Stats { queue.sync { stats } }

    init(link: WirelessLink, macID: String, macName: String) {
        self.link = link
        self.macID = macID.lowercased()
        self.macName = macName
    }

    // MARK: - Listener

    /// Start listening. `advertise` publishes the Bonjour service (the app);
    /// the gate passes false and `loopbackOnly`, so it never touches the LAN
    /// (and never raises the Local Network prompt).
    func start(port: NWEndpoint.Port = .any, advertise: Bool, loopbackOnly: Bool = false) throws {
        let params = WirelessDevice.parameters(link: link)
        params.allowLocalEndpointReuse = true
        if loopbackOnly {
            params.requiredInterfaceType = .loopback
            params.includePeerToPeer = false
        }
        let listener = try NWListener(using: params, on: port)
        if advertise {
            listener.service = NWListener.Service(
                name: macName, type: WirelessDevice.serviceType, domain: nil,
                txtRecord: WirelessDevice.txtRecord(macID: macID, link: link)
            )
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onListenerState?(listener?.port?.rawValue)
            case .failed(let error):
                serverLogger.error("listener failed: \(error.localizedDescription, privacy: .public)")
                self.onListenerState?(nil)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    /// Stop listening and drop every phone (orderly `bye` first).
    func stop(reason: String = "mac stopped") {
        queue.sync {
            listener?.cancel()
            listener = nil
            for peer in peers.values {
                peer.connection.sendWireless(.bye, WirelessJSON.encode(WirelessBye(reason: reason)))
                peer.connection.cancel()
            }
            peers.removeAll()
            phones.removeAll()
            publishLocked()
        }
    }

    var port: UInt16? { queue.sync { listener?.port?.rawValue } }

    // MARK: - Recording / monitor hooks

    /// Route a phone's media to `sink` (the recorder), and ask the phone for
    /// a keyframe + tell it it is being recorded. Survives reconnects: a new
    /// broadcast connection from the same phone feeds the same sink.
    func attach(sink: WirelessMediaSink, to key: String) {
        let key = WirelessIdentity.key(key)
        queue.async { [self] in
            let phone = phones[key] ?? makePhoneLocked(key: key)
            phone.sink = sink
            if let broadcast = phone.broadcastPeer {
                send(.state(recording: true), to: broadcast)
                requestKeyframeLocked(phone, force: true)
            }
        }
    }

    func detach(sink: WirelessMediaSink) {
        queue.sync {
            for phone in phones.values where phone.sink === sink {
                phone.sink = nil
                if let broadcast = phone.broadcastPeer { send(.state(recording: false), to: broadcast) }
            }
            pruneLocked()
        }
    }

    /// Live monitor frames (server queue, at most ~30 per second).
    @discardableResult
    func addMonitor(for key: String, _ handler: @escaping @Sendable (CVPixelBuffer) -> Void) -> UUID {
        let token = UUID()
        let key = WirelessIdentity.key(key)
        queue.async { [self] in
            let phone = phones[key] ?? makePhoneLocked(key: key)
            phone.monitors[token] = handler
            if let frame = phone.latestFrame { handler(frame) }
        }
        return token
    }

    func removeMonitor(_ token: UUID) {
        queue.async { [self] in
            for phone in phones.values { phone.monitors[token] = nil }
            pruneLocked()
        }
    }

    /// "requestBroadcast" on the phone's APP connection. false = no app
    /// connection (use push instead).
    func requestBroadcast(from key: String) -> Bool {
        let key = WirelessIdentity.key(key)
        return queue.sync {
            guard let app = phones[key]?.appPeer else { return false }
            send(.requestBroadcast, to: app)
            return true
        }
    }

    func latestFrame(for key: String) -> CVPixelBuffer? {
        queue.sync { phones[WirelessIdentity.key(key)]?.latestFrame }
    }

    func snapshots() -> [WirelessPhoneSnapshot] { queue.sync { makeSnapshotsLocked() } }

    // MARK: - Connections

    private final class Peer {
        let connection: NWConnection
        var hello: WirelessHello?
        var key: String?
        var isBroadcast = false
        init(connection: NWConnection) { self.connection = connection }
    }

    private final class Phone {
        let key: String
        var hello: WirelessHello?
        var appPeer: Peer?
        var broadcastPeer: Peer?
        var format: WirelessVideoFormat?
        var decoder: WirelessVideoDecoder?
        var clock = WirelessClockMapper()
        var decodedKeyframe = false
        var audioFormat: WirelessAudioFormat?
        var latestFrame: CVPixelBuffer?
        weak var sink: WirelessMediaSink?
        var monitors: [UUID: @Sendable (CVPixelBuffer) -> Void] = [:]
        var lastMonitorFrame: UInt64 = 0
        var lastKeyframeRequest: UInt64 = 0
        init(key: String) { self.key = key }
    }

    private func makePhoneLocked(key: String) -> Phone {
        let phone = Phone(key: key)
        phones[key] = phone
        return phone
    }

    private func accept(_ connection: NWConnection) {
        let peer = Peer(connection: connection)
        let id = ObjectIdentifier(peer)
        peers[id] = peer
        stats.accepted += 1
        connection.stateUpdateHandler = { [weak self, weak peer] state in
            guard let self, let peer else { return }
            switch state {
            case .failed, .cancelled:
                self.closed(peer)
            default:
                break
            }
        }
        connection.start(queue: queue)
        // Nothing but a hello may come first; a peer that never says hello
        // is dropped after 10 s.
        queue.asyncAfter(deadline: .now() + 10) { [weak peer] in
            guard let peer, peer.hello == nil else { return }
            peer.connection.cancel()
        }
        connection.receiveWireless({ [weak self, weak peer] type, payload in
            guard let self, let peer else { return false }
            return self.handle(type, payload, from: peer)
        }, onEnd: { [weak self, weak peer] _ in
            guard let self, let peer else { return }
            peer.connection.cancel()
            self.closed(peer)
        })
    }

    private func closed(_ peer: Peer) {
        guard peers.removeValue(forKey: ObjectIdentifier(peer)) != nil else { return }
        guard let key = peer.key, let phone = phones[key] else { return }
        if phone.appPeer === peer { phone.appPeer = nil }
        if phone.broadcastPeer === peer {
            // Like a cable unplug: the recorder keeps its writer open and
            // simply gets no more frames until the phone comes back.
            phone.broadcastPeer = nil
            phone.decoder = nil
            phone.format = nil
            phone.decodedKeyframe = false
            phone.clock.reset()
        }
        pruneLocked()
        publishLocked()
    }

    /// false stops receiving (connection is being closed).
    private func handle(_ type: WirelessMessageType?, _ payload: Data, from peer: Peer) -> Bool {
        guard peer.hello != nil else {
            guard type == .hello, let hello = WirelessJSON.decode(WirelessHello.self, from: payload),
                  hello.protocolVersion == WirelessDevice.protocolVersion,
                  hello.role == WirelessDevice.roleApp || hello.role == WirelessDevice.roleBroadcast,
                  !hello.deviceID.isEmpty else {
                stats.rejectedHello += 1
                peer.connection.sendWireless(.bye, WirelessJSON.encode(WirelessBye(reason: "hello required (protocol \(WirelessDevice.protocolVersion))")))
                peer.connection.cancel()
                return false
            }
            register(peer, hello: hello)
            return true
        }
        guard let key = peer.key, let phone = phones[key] else { return false }
        switch type {
        case .videoFormat:
            guard peer.isBroadcast, let format = WirelessJSON.decode(WirelessVideoFormat.self, from: payload) else { break }
            applyFormat(format, to: phone)
        case .videoFrame:
            guard peer.isBroadcast, phone.broadcastPeer === peer,
                  let frame = WirelessVideoFrame(decoding: payload) else { break }
            handleFrame(frame, phone: phone)
        case .audioFormat:
            guard peer.isBroadcast, let format = WirelessJSON.decode(WirelessAudioFormat.self, from: payload),
                  format.sampleRate > 0, (1...8).contains(format.channels) else { break }
            phone.audioFormat = format
        case .audioPCM:
            guard peer.isBroadcast, phone.broadcastPeer === peer, let format = phone.audioFormat,
                  let chunk = WirelessAudioChunk(decoding: payload) else { break }
            let now = WirelessDevice.hostTimeNanos()
            phone.clock.observe(remotePTS: chunk.pts, localReceipt: now)
            if let sink = phone.sink, let local = phone.clock.localTime(forRemote: chunk.pts) {
                sink.wirelessDidReceiveAudio(chunk, format: format, hostTime: CMTime(value: local, timescale: 1_000_000_000))
            }
        case .openProject:
            // "Continue on Mac". Answer at once (the clone may take a while;
            // the phone only needs to know this Mac took it), then hand the id
            // to the app, which runs the same path as capturecat://open-project.
            guard let request = WirelessJSON.decode(WirelessOpenProject.self, from: payload) else { break }
            let id = request.projectId.uppercased()
            let valid = UUID(uuidString: id) != nil
            peer.connection.sendWireless(.control, WirelessJSON.encode(WirelessControl.opened(projectId: id, ok: valid)))
            if valid { onOpenProject?(id, phone.hello?.deviceName ?? "iPhone") }
        case .bye:
            peer.connection.cancel()
            return false
        case .hello, .macHello, .control:
            break // not expected from a phone; ignored
        case nil:
            break // a newer peer's message type: skippable by design
        }
        return true
    }

    private func register(_ peer: Peer, hello: WirelessHello) {
        let key = WirelessIdentity.key(hello.deviceID)
        peer.hello = hello
        peer.key = key
        peer.isBroadcast = hello.role == WirelessDevice.roleBroadcast
        let phone = phones[key] ?? makePhoneLocked(key: key)
        // Prefer the broadcast's identity, but any hello fills a gap.
        if phone.hello == nil || peer.isBroadcast { phone.hello = hello }
        if peer.isBroadcast {
            if let old = phone.broadcastPeer, old !== peer { old.connection.cancel() }
            phone.broadcastPeer = peer
            phone.decoder = nil
            phone.format = nil
            phone.decodedKeyframe = false
            phone.clock.reset()
        } else {
            if let old = phone.appPeer, old !== peer { old.connection.cancel() }
            phone.appPeer = peer
        }
        let reply = WirelessMacHello(
            macID: macID, macName: macName,
            appVersion: WirelessIdentity.appVersion,
            recording: phone.sink != nil
        )
        peer.connection.sendWireless(.macHello, WirelessJSON.encode(reply))
        if peer.isBroadcast, phone.sink != nil {
            // Reconnected mid-take: resume the segment from a keyframe.
            send(.state(recording: true), to: peer)
            requestKeyframeLocked(phone, force: true)
        }
        publishLocked()
    }

    private func applyFormat(_ format: WirelessVideoFormat, to phone: Phone) {
        guard format != phone.format || phone.decoder == nil else { return }
        stats.formatChanges += 1
        phone.format = format
        do {
            phone.decoder = try WirelessVideoDecoder(format: format)
        } catch {
            serverLogger.error("decoder for \(format.codec, privacy: .public) \(format.width)x\(format.height) failed: \(String(describing: error), privacy: .public)")
            phone.decoder = nil
        }
        publishLocked()
    }

    private func handleFrame(_ frame: WirelessVideoFrame, phone: Phone) {
        let now = WirelessDevice.hostTimeNanos()
        phone.clock.observe(remotePTS: frame.pts, localReceipt: now)
        guard let decoder = phone.decoder, let image = decoder.decode(frame) else {
            stats.decodeErrors += 1
            // Lost sync (no decoder yet, a dropped reference frame…): ask
            // for an IDR, at most once a second.
            requestKeyframeLocked(phone, force: false)
            return
        }
        stats.framesDecoded += 1
        phone.latestFrame = image
        if frame.isKeyframe, !phone.decodedKeyframe {
            phone.decodedKeyframe = true
            publishLocked()
        }
        if let sink = phone.sink, let local = phone.clock.localTime(forRemote: frame.pts) {
            sink.wirelessDidDecode(image, hostTime: CMTime(value: local, timescale: 1_000_000_000), isKeyframe: frame.isKeyframe)
        }
        if !phone.monitors.isEmpty {
            let ticks = UInt64(now)
            if ticks &- phone.lastMonitorFrame >= 30_000_000 || frame.isKeyframe {
                phone.lastMonitorFrame = ticks
                for handler in phone.monitors.values { handler(image) }
            }
        }
    }

    private func requestKeyframeLocked(_ phone: Phone, force: Bool) {
        guard let broadcast = phone.broadcastPeer else { return }
        let now = UInt64(WirelessDevice.hostTimeNanos())
        if !force, now &- phone.lastKeyframeRequest < 1_000_000_000 { return }
        phone.lastKeyframeRequest = now
        stats.keyframeRequests += 1
        send(.keyframe, to: broadcast)
    }

    private func send(_ control: WirelessControl, to peer: Peer) {
        peer.connection.sendWireless(.control, WirelessJSON.encode(control))
    }

    /// Drop phones with no connection, no recorder and no monitor.
    private func pruneLocked() {
        for (key, phone) in phones where phone.appPeer == nil && phone.broadcastPeer == nil
            && phone.sink == nil && phone.monitors.isEmpty {
            phones[key] = nil
        }
    }

    private func makeSnapshotsLocked() -> [WirelessPhoneSnapshot] {
        phones.values.compactMap { phone -> WirelessPhoneSnapshot? in
            guard let hello = phone.hello, phone.appPeer != nil || phone.broadcastPeer != nil else { return nil }
            return WirelessPhoneSnapshot(
                key: phone.key, deviceID: hello.deviceID, name: hello.deviceName.isEmpty ? "iPhone" : hello.deviceName,
                model: hello.model, hasApp: phone.appPeer != nil, hasBroadcast: phone.broadcastPeer != nil,
                isStreaming: phone.broadcastPeer != nil && phone.decodedKeyframe,
                width: phone.format?.width ?? 0, height: phone.format?.height ?? 0,
                screenWidth: hello.screenWidth, screenHeight: hello.screenHeight
            )
        }
        .sorted { $0.key < $1.key }
    }

    private func publishLocked() {
        let snapshot = makeSnapshotsLocked()
        guard snapshot != lastPublished else { return }
        lastPublished = snapshot
        onPhonesChanged?(snapshot)
    }
}
