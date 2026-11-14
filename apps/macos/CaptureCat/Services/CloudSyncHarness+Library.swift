import AppKit
import AVFoundation
import Foundation
import ImageIO
import Network
import UniformTypeIdentifiers

// MARK: - Cloud library (the project browser's Cloud section)

/// `--cloud-sync-test`, part 2: projects made on the iPhone or in the web
/// app show up in the Mac's project browser.
///
/// • `libraryChecks` — no network: the listing parse, the cloud-only merge
///   (local vs cloud-only vs in-flight vs still-uploading vs signed out),
///   kind/tag + preview-file rules, the thumbnail cache's id+revision keying
///   (a new revision invalidates, an unchanged one never refetches), the
///   library's quiet refresh/throttle/clear, and the thumbnailer reading ONE
///   frame of a recording over a loopback HTTP server that honors byte
///   ranges — asserting it fetched a fraction of the file, not all of it.
/// • `libraryUIChecks` — the REAL browser mounted through the editor
///   window's own content switcher (`EditorWindowContentViewController`):
///   no Cloud row signed out, the row and its cards signed in, art fading
///   in MID-FLIGHT, tags, Videos/Images filtering, the click → clone hand-off,
///   in-flight hiding, focus refresh, the 60 s timer, sign-out teardown.
extension CloudSyncHarness {
    // MARK: Stub transport

    final class StubLibraryTransport: CloudLibraryTransport {
        var items: [CloudLibraryItem] = []
        var details: [UUID: CloudRemoteProject] = [:]
        var listCalls = 0
        var detailCalls: [UUID] = []
        var failList = false

        func list() async throws -> [CloudLibraryItem] {
            listCalls += 1
            if failList { throw CloudSyncError.invalidResponse }
            return items
        }

        func detail(projectID: UUID) async throws -> CloudRemoteProject? {
            detailCalls.append(projectID)
            return details[projectID]
        }
    }

    // MARK: Fixtures

    struct LibraryFixtures {
        let root: URL
        let movie: URL          // 1.5 s, 640×360
        let still: URL          // 300×650 PNG (portrait, a phone screenshot)
    }

    static func makeLibraryFixtures() async throws -> LibraryFixtures {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("capturecat-cloud-library-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let movie = root.appendingPathComponent("recording.mov")
        try await writeMovie(to: movie, width: 640, height: 360, frames: 45, noise: false)
        let still = root.appendingPathComponent("screenshot.png")
        try writePNG(to: still, width: 300, height: 650)
        return LibraryFixtures(root: root, movie: movie, still: still)
    }

    /// H.264 movie via AVAssetWriter (moov at the END, like the app's own
    /// recordings). `noise`: high-entropy frames at a high bitrate, so the
    /// file is big enough that "read a fraction of it" means something.
    static func writeMovie(to url: URL, width: Int, height: Int, frames: Int, noise: Bool) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var compression: [String: Any] = [AVVideoMaxKeyFrameIntervalKey: 15]
        // 20 Mb/s, not more: at 40 Mb/s this machine's H.264 encoder stalls
        // (`isReadyForMoreMediaData` never returns) and the gate hung. 120
        // noise frames at 20 Mb/s still make an ~11 MB file.
        if noise { compression[AVVideoAverageBitRateKey] = 20_000_000 }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        // One noise field, read at a different offset per frame (cheap, and
        // every frame differs so the encoder can't coast).
        let rowBytes = width * 4
        var field = [UInt8](repeating: 0, count: rowBytes * height + 65_536)
        if noise {
            var state: UInt64 = 0x5EED_CA7
            for i in 0..<field.count {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                field[i] = UInt8(truncatingIfNeeded: state >> 33)
            }
        }
        for frame in 0..<frames {
            // Bounded: a stalled or failed encoder must fail the check, never
            // hang the gate.
            let deadline = Date().addingTimeInterval(10)
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing, Date() < deadline else {
                    writer.cancelWriting()
                    throw writer.error ?? CocoaError(.fileWriteUnknown)
                }
                try await Task.sleep(for: .milliseconds(2))
            }
            guard let pool = adaptor.pixelBufferPool else {
                writer.cancelWriting()
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let stride = CVPixelBufferGetBytesPerRow(buffer)
                let offset = (frame * 4_099) % 65_536
                for y in 0..<height {
                    let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                    if noise {
                        field.withUnsafeBufferPointer { src in
                            row.update(from: src.baseAddress!.advanced(by: offset + y * rowBytes), count: rowBytes)
                        }
                    } else {
                        // A warm orange field with a moving white bar — a real picture.
                        for x in 0..<width {
                            let bar = abs(x - (frame * 9) % width) < 24
                            row[x * 4 + 0] = bar ? 255 : 40    // B
                            row[x * 4 + 1] = bar ? 255 : 140   // G
                            row[x * 4 + 2] = 255               // R
                            row[x * 4 + 3] = 255
                        }
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    static func writePNG(to url: URL, width: Int, height: Int) throws {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CocoaError(.fileWriteUnknown)
        }
        ctx.setFillColor(CGColor(red: 0.2, green: 0.45, blue: 0.95, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 20, y: height - 80, width: width - 40, height: 40))
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    static func document(id: UUID, kind: CloudLibraryKind, duration: Double = 1.5) -> Data {
        var object: [String: Any] = [
            "id": id.uuidString,
            "name": "fixture",
            "duration": duration,
            "videoURL": "file:///CaptureCat/Projects/\(id.uuidString)/recording.mov",
        ]
        if kind == .device { object["recordingSourceKind"] = "device" }
        if kind == .still {
            object["isStillCapture"] = true
            object["videoURL"] = "file:///CaptureCat/Projects/\(id.uuidString)/screenshot.png"
        }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    static func remote(revision: Int, document: Data, files: [(path: String, url: URL, type: String)]) -> CloudRemoteProject {
        CloudRemoteProject(
            revision: revision, documentSHA256: nil, document: document,
            files: files.map { file in
                let bytes = ((try? FileManager.default.attributesOfItem(atPath: file.url.path)[.size]) as? NSNumber)?.int64Value ?? 0
                return CloudRemoteFile(path: file.path, sha256: String(repeating: "0", count: 64), bytes: bytes,
                                       contentType: file.type, source: nil, url: file.url)
            }
        )
    }

    static func item(_ id: UUID, _ name: String, revision: Int = 1, hasDocument: Bool = true,
                     bytes: Int64 = 12_582_912, updated: Date?) -> CloudLibraryItem {
        CloudLibraryItem(projectID: id, name: name, revision: revision, hasDocument: hasDocument,
                         totalBytes: bytes, isOwner: true, orgID: nil, createdAt: updated, updatedAt: updated)
    }

    /// Poll the main actor until `condition` holds (or `timeout`).
    @discardableResult
    static func waitUntil(_ timeout: TimeInterval, every step: Duration = .milliseconds(20),
                          _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: step)
        }
        return true
    }

    // MARK: - Pure + library checks

    static func libraryChecks(_ checks: Checks) async {
        let expect = checks.expect
        let fixtures: LibraryFixtures
        do {
            fixtures = try await makeLibraryFixtures()
        } catch {
            expect(false, "library fixtures (movie + still) write (\(error))")
            return
        }
        defer { try? FileManager.default.removeItem(at: fixtures.root) }

        // ── Listing parse ──────────────────────────────────────────────────
        print("cloud library: listing parse")
        let a = UUID(), b = UUID()
        let listJSON = """
        {"projects":[
          {"projectId":"\(a.uuidString.lowercased())","name":"Phone take","revision":3,"hasDocument":true,
           "documentSha256":"ab","totalBytes":12582912,"orgId":null,"isOwner":true,
           "createdAt":"2026-11-10T10:00:00.000Z","updatedAt":"2026-11-12 09:30:00"},
          {"projectId":"not-a-uuid","name":"broken","revision":1},
          {"projectId":"\(b.uuidString)","name":"   ","revision":0,"hasDocument":false,"totalBytes":0,
           "orgId":"org_1","isOwner":false,"createdAt":1731000000000,"updatedAt":null}
        ],"storage":{"usedBytes":1,"limitBytes":2}}
        """
        let parsed = CloudLibraryListing.parse(Data(listJSON.utf8)) ?? []
        expect(parsed.count == 2, "a row without a valid UUID is skipped, the rest parse (\(parsed.count))")
        if let first = parsed.first(where: { $0.projectID == a }) {
            expect(first.name == "Phone take" && first.revision == 3 && first.hasDocument
                   && first.totalBytes == 12_582_912 && first.isOwner && first.orgID == nil,
                   "projectSummary fields map 1:1")
            expect(first.updatedAt != nil && first.createdAt != nil && first.date == first.updatedAt
                   && first.updatedAt! > first.createdAt!,
                   "ISO + SQLite timestamps parse; the card date is updatedAt")
        } else {
            expect(false, "lower-case projectId parses to the same UUID")
        }
        if let second = parsed.first(where: { $0.projectID == b }) {
            expect(second.name == "Untitled" && !second.hasDocument && second.orgID == "org_1"
                   && !second.isOwner && second.createdAt != nil && second.updatedAt == nil,
                   "blank name → Untitled; epoch-ms createdAt; null updatedAt; team project fields")
        } else {
            expect(false, "upper-case projectId parses")
        }
        expect(CloudLibraryListing.parse(Data("[]".utf8)) == nil
               && CloudLibraryListing.parse(Data(#"{"error":"nope"}"#.utf8)) == nil
               && CloudLibraryListing.parse(Data("<html>".utf8)) == nil,
               "a body that isn't { projects: [...] } is refused, not read as empty")

        // ── Merge: local vs cloud-only vs in-flight ────────────────────────
        print("cloud library: merge")
        let now = Date()
        let local = UUID(), newest = UUID(), older = UUID(), inFlight = UUID(), uploading = UUID()
        let tieA = UUID(), tieB = UUID()
        let cloud: [CloudLibraryItem] = [
            item(local, "Already here", updated: now),
            item(older, "Older phone take", updated: now.addingTimeInterval(-3_600)),
            item(newest, "Newest phone take", updated: now.addingTimeInterval(-60)),
            item(inFlight, "Cloning now", updated: now.addingTimeInterval(-30)),
            item(uploading, "Still uploading", revision: 0, hasDocument: false, updated: now),
            item(older, "Duplicate row", updated: now),
            item(tieB, "b tie", updated: now.addingTimeInterval(-7_200)),
            item(tieA, "a tie", updated: now.addingTimeInterval(-7_200)),
        ]
        let merged = CloudLibraryListing.cloudOnly(cloud, signedIn: true, localIDs: [local], inFlight: [inFlight])
        expect(merged.map(\.projectID) == [newest, older, tieA, tieB],
               "cloud-only = not local, not in flight, has a document; newest first, ties by name (\(merged.map(\.name)))")
        expect(merged.first(where: { $0.projectID == older })?.name == "Older phone take",
               "a duplicated id is listed once (the first row wins)")
        expect(CloudLibraryListing.cloudOnly(cloud, signedIn: false, localIDs: [], inFlight: []).isEmpty,
               "signed out → nothing, whatever was listed before")
        let afterClone = CloudLibraryListing.cloudOnly(cloud, signedIn: true, localIDs: [local, inFlight], inFlight: [])
        expect(!afterClone.contains { $0.projectID == inFlight },
               "a finished clone is local → it leaves the section")
        let afterFailure = CloudLibraryListing.cloudOnly(cloud, signedIn: true, localIDs: [local], inFlight: [])
        expect(afterFailure.contains { $0.projectID == inFlight },
               "a failed clone (no longer in flight, not local) comes back")
        let upper = UUID(uuidString: local.uuidString.uppercased())!
        expect(CloudLibraryListing.cloudOnly([item(upper, "case", updated: now)], signedIn: true,
                                             localIDs: [local], inFlight: []).isEmpty,
               "id matching is case-insensitive (a parsed UUID)")

        // ── Kind / tag / preview file ──────────────────────────────────────
        print("cloud library: kind, tag, preview file")
        let docID = UUID()
        expect(CloudLibraryListing.kind(ofDocument: document(id: docID, kind: .device)) == .device
               && CloudLibraryKind.device.tag == "iPhone", #"recordingSourceKind "device" → tag "iPhone""#)
        expect(CloudLibraryListing.kind(ofDocument: document(id: docID, kind: .still)) == .still
               && CloudLibraryKind.still.tag == "Screenshot" && CloudLibraryKind.still.isImage,
               #"isStillCapture → tag "Screenshot", filed under Images"#)
        let both = try? JSONSerialization.data(withJSONObject: ["recordingSourceKind": "device", "isStillCapture": true])
        expect(CloudLibraryListing.kind(ofDocument: both) == .still, "an iPhone screenshot is a Screenshot")
        expect(CloudLibraryListing.kind(ofDocument: document(id: docID, kind: .recording)) == .recording
               && CloudLibraryKind.recording.tag == nil
               && CloudLibraryListing.kind(ofDocument: Data("garbage".utf8)) == .recording
               && CloudLibraryListing.kind(ofDocument: nil) == .recording,
               "a plain or unreadable document → no tag")
        expect(CloudLibraryListing.duration(ofDocument: document(id: docID, kind: .device, duration: 14.25)) == 14.25
               && CloudLibraryListing.duration(ofDocument: nil) == nil, "duration read from the document")
        let some = URL(string: "https://r2.stub.test/x")!
        func remoteFile(_ path: String, _ type: String) -> CloudRemoteFile {
            CloudRemoteFile(path: path, sha256: "0", bytes: 1, contentType: type, source: nil, url: some)
        }
        let files = [remoteFile("camera.mov", "video/quicktime"), remoteFile("camera_poster.png", "image/png"),
                     remoteFile("recording.mov", "video/quicktime")]
        expect(CloudLibraryListing.previewFile(in: files, document: document(id: docID, kind: .recording))?.path == "recording.mov",
               "the file the document's videoURL names (web/iPhone spelling)")
        let macDoc = try? JSONSerialization.data(withJSONObject: ["videoURL": "file:///Users/someone/Library/Application%20Support/CaptureCat/Projects/\(docID.uuidString)/recording.mov"])
        expect(CloudLibraryListing.previewFile(in: files, document: macDoc)?.path == "recording.mov",
               "the file the document's videoURL names (a Mac's absolute path)")
        expect(CloudLibraryListing.previewFile(in: files, document: nil)?.path == "recording.mov",
               "no document → the first video that isn't the camera")
        expect(CloudLibraryListing.previewFile(in: [remoteFile("screenshot.png", "image/png")], document: nil)?.path == "screenshot.png"
               && CloudLibraryListing.previewFile(in: [remoteFile("camera.mov", "video/quicktime")], document: nil) == nil,
               "image-only → the image; camera-only → nothing to draw")

        // ── Thumbnail cache keying ─────────────────────────────────────────
        print("cloud library: thumbnail cache (id + revision)")
        let cacheDir = fixtures.root.appendingPathComponent("thumbs", isDirectory: true)
        let cache = CloudThumbnailCache(directory: cacheDir)
        let p1 = UUID(), p2 = UUID(), p3 = UUID()
        let names = [CloudThumbnailCache.baseName(projectID: p1, revision: 3),
                     CloudThumbnailCache.baseName(projectID: p1, revision: 4),
                     CloudThumbnailCache.baseName(projectID: p2, revision: 3)]
        expect(Set(names).count == 3, "the key separates id AND revision")
        expect(cache.lookup(projectID: p1, revision: 3) == nil, "miss before anything is stored")
        let frame = await CloudThumbnailer.thumbnail(
            of: CloudRemoteFile(path: "recording.mov", sha256: "0", bytes: 1, contentType: "video/quicktime",
                                source: nil, url: fixtures.movie), duration: 1.5)
        expect(frame != nil && frame.map { abs(Double($0.width) / Double($0.height) - 16.0 / 9.0) < 0.02 } == true,
               "a frame of the recording, its aspect intact (\(frame.map { "\($0.width)×\($0.height)" } ?? "nil"))")
        _ = try? cache.store(projectID: p1, revision: 3, kind: .device, duration: 12.5, image: frame)
        let hit3 = cache.lookup(projectID: p1, revision: 3)
        expect(hit3?.kind == .device && hit3?.duration == 12.5 && hit3?.imageURL != nil
               && hit3.flatMap { $0.imageURL.flatMap(NSImage.init(contentsOf:)) } != nil,
               "stored → hit for that revision (kind, duration, a readable JPEG)")
        expect(cache.lookup(projectID: p1, revision: 4) == nil, "a NEW revision misses (art redrawn after an edit)")
        _ = try? cache.store(projectID: p1, revision: 4, kind: .recording, duration: 9, image: frame)
        let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: cacheDir.path)) ?? [])
            .filter { $0.hasPrefix(CloudThumbnailCache.baseName(projectID: p1, revision: 3)) }
        expect(cache.lookup(projectID: p1, revision: 3) == nil && leftovers.isEmpty
               && cache.lookup(projectID: p1, revision: 4)?.kind == .recording,
               "storing revision 4 prunes revision 3's files")
        _ = try? cache.store(projectID: p2, revision: 1, kind: .still, duration: nil, image: nil)
        let negative = cache.lookup(projectID: p2, revision: 1)
        expect(negative != nil && negative?.imageURL == nil && negative?.kind == .still,
               "nothing to draw is cached too (no art, still a hit — no refetch)")
        try? Data("{}".utf8).write(to: cache.metaURL(projectID: p3, revision: 2))
        let legacy = cache.lookup(projectID: p3, revision: 2)
        expect(legacy?.kind == .recording && legacy?.imageURL == nil, "a meta file missing every key still decodes")
        cache.prune(keeping: [p1])
        expect(cache.lookup(projectID: p2, revision: 1) == nil && cache.lookup(projectID: p3, revision: 2) == nil
               && cache.lookup(projectID: p1, revision: 4) != nil,
               "projects no longer listed lose their art; listed ones keep it")

        // ── Library: quiet refresh, throttle, clear, in-flight ─────────────
        print("cloud library: refresh")
        let stub = StubLibraryTransport()
        let deviceID = UUID(), stillID = UUID()
        stub.items = [item(deviceID, "Phone take", revision: 2, updated: now),
                      item(stillID, "Phone screenshot", revision: 5, updated: now.addingTimeInterval(-10))]
        let still = fixtures.still
        stub.details[deviceID] = remote(revision: 2, document: document(id: deviceID, kind: .device),
                                        files: [("recording.mov", fixtures.movie, "video/quicktime")])
        stub.details[stillID] = remote(revision: 5, document: document(id: stillID, kind: .still),
                                       files: [("screenshot.png", still, "image/png")])
        var session = false
        let library = CloudLibrary()
        library.transport = stub
        library.cache = CloudThumbnailCache(directory: fixtures.root.appendingPathComponent("lib-thumbs", isDirectory: true))
        library.hasSession = { session }
        library.refresh(force: true)
        await library.waitForRefresh()
        expect(stub.listCalls == 0 && library.items.isEmpty && !library.hasListed,
               "no session → no request, nothing listed")
        session = true
        library.refresh(force: true)
        await library.waitForRefresh()
        expect(stub.listCalls == 1 && library.items.count == 2 && library.hasListed, "session → one listing")
        library.refresh()
        await library.waitForRefresh()
        expect(stub.listCalls == 1, "a focus refresh inside the throttle window is skipped")
        stub.failList = true
        library.refresh(force: true)
        await library.waitForRefresh()
        expect(stub.listCalls == 2 && library.items.count == 2, "a failed listing keeps what it had, quietly")
        stub.failList = false
        library.setCloning(deviceID, true)
        expect(library.cloudOnly(signedIn: true, localIDs: []).map(\.projectID) == [stillID],
               "a project being cloned is hidden")
        library.setCloning(deviceID, false)
        expect(library.cloudOnly(signedIn: true, localIDs: []).count == 2, "…and back when the clone ends")

        print("cloud library: previews (detail → one frame → disk)")
        library.requestPreviews(for: library.items)
        let loaded = await waitUntil(10) { library.previews[deviceID] != nil && library.previews[stillID] != nil }
        expect(loaded, "both previews load")
        let devicePreview = library.previews[deviceID]
        let stillPreview = library.previews[stillID]
        expect(devicePreview?.kind == .device && devicePreview?.image != nil && devicePreview?.duration == 1.5,
               "device take: tag iPhone, a frame, its duration")
        expect(stillPreview?.kind == .still && stillPreview.flatMap { $0.image }.map { $0.size.height > $0.size.width } == true,
               "screenshot: tag Screenshot, the portrait image")
        expect(Set(stub.detailCalls) == [deviceID, stillID] && stub.detailCalls.count == 2, "one detail request each")
        library.requestPreviews(for: library.items)
        expect(stub.detailCalls.count == 2, "an unchanged revision is never fetched again (memory)")

        let second = CloudLibrary()
        let secondStub = StubLibraryTransport()
        second.transport = secondStub
        second.cache = library.cache
        second.hasSession = { true }
        second.requestPreviews(for: stub.items)
        expect(secondStub.detailCalls.isEmpty && second.previews[deviceID]?.image != nil
               && second.previews[stillID]?.kind == .still,
               "a fresh session draws from the disk cache — zero requests for unchanged revisions")
        secondStub.details[deviceID] = remote(revision: 3, document: document(id: deviceID, kind: .recording),
                                              files: [("recording.mov", fixtures.movie, "video/quicktime")])
        second.requestPreviews(for: [item(deviceID, "Phone take", revision: 3, updated: now)])
        let redrawn = await waitUntil(10) { second.previews[deviceID]?.revision == 3 }
        expect(redrawn && secondStub.detailCalls == [deviceID] && second.previews[deviceID]?.kind == .recording,
               "a new cloud revision refetches exactly that project")
        expect(second.cache.lookup(projectID: deviceID, revision: 2) == nil
               && second.cache.lookup(projectID: deviceID, revision: 3) != nil,
               "…and its old art is pruned from disk")

        library.clear()
        expect(library.items.isEmpty && library.previews.isEmpty && !library.hasListed,
               "clear (sign-out) forgets the listing and the art in memory")
        library.bind(account: "a")
        library.refresh(force: true)
        await library.waitForRefresh()
        library.bind(account: "b")
        expect(library.items.isEmpty, "another account never sees the previous one's list")

        await rangedThumbnailChecks(checks, root: fixtures.root)
    }

    // MARK: - One frame over HTTP, not the whole file

    /// Loopback HTTP that honors `Range`, counting the body bytes it handed
    /// to the socket. The thumbnailer must draw from a fraction of them.
    final class RangeServer: @unchecked Sendable {
        let payload: Data
        let contentType: String
        let listener: NWListener
        private let lock = NSLock()
        private var _served = 0
        private var _rangeRequests = 0
        var served: Int { lock.withLock { _served } }
        var rangeRequests: Int { lock.withLock { _rangeRequests } }

        init?(payload: Data, contentType: String) {
            guard let listener = try? NWListener(using: .tcp, on: .any) else { return nil }
            self.payload = payload
            self.contentType = contentType
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .global())
                self?.readHead(connection, buffer: Data())
            }
            listener.start(queue: .global())
        }

        var port: UInt16 { listener.port?.rawValue ?? 0 }

        private func readHead(_ connection: NWConnection, buffer: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
                guard let self else { return }
                var head = buffer
                if let data { head.append(data) }
                guard let end = head.range(of: Data("\r\n\r\n".utf8)) else {
                    if complete || error != nil { connection.cancel() } else { self.readHead(connection, buffer: head) }
                    return
                }
                self.respond(connection, head: String(decoding: head[..<end.lowerBound], as: UTF8.self))
            }
        }

        private func respond(_ connection: NWConnection, head: String) {
            let lines = head.components(separatedBy: "\r\n")
            let isHead = lines.first?.hasPrefix("HEAD") ?? false
            var lower = 0
            var upper = payload.count - 1
            var partial = false
            for line in lines.dropFirst() where line.lowercased().hasPrefix("range:") {
                let spec = line.split(separator: "=", maxSplits: 1).last.map {
                    String($0).trimmingCharacters(in: .whitespaces)
                } ?? ""
                let parts = spec.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 2 else { continue }
                if parts[0].isEmpty, let suffix = Int(parts[1]) {
                    lower = max(0, payload.count - suffix)
                } else {
                    lower = min(Int(parts[0]) ?? 0, payload.count - 1)
                    if let end = Int(parts[1]) { upper = min(end, payload.count - 1) }
                }
                partial = true
            }
            if partial { lock.withLock { _rangeRequests += 1 } }
            var header = partial ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n"
            header += "Content-Type: \(contentType)\r\nAccept-Ranges: bytes\r\nContent-Length: \(upper - lower + 1)\r\n"
            if partial { header += "Content-Range: bytes \(lower)-\(upper)/\(payload.count)\r\n" }
            header += "Connection: close\r\n\r\n"
            connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in })
            if isHead {
                connection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            sendBody(connection, from: lower, through: upper)
        }

        /// 64 KiB at a time; stops when the client hangs up, so a range the
        /// reader abandons isn't counted as read.
        private func sendBody(_ connection: NWConnection, from start: Int, through end: Int) {
            guard start <= end else {
                connection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            let stop = min(end, start + 65_535)
            let chunk = payload.subdata(in: start..<(stop + 1))
            connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if error != nil { connection.cancel(); return }
                self.lock.withLock { self._served += chunk.count }
                self.sendBody(connection, from: stop + 1, through: end)
            })
        }
    }

    static func rangedThumbnailChecks(_ checks: Checks, root: URL) async {
        let expect = checks.expect
        print("cloud library: one frame over HTTP, not the whole recording")
        let big = root.appendingPathComponent("big.mov")
        do {
            try await writeMovie(to: big, width: 960, height: 540, frames: 120, noise: true)
        } catch {
            expect(false, "noise movie writes (\(error))")
            return
        }
        guard let payload = try? Data(contentsOf: big), payload.count > 4 * 1024 * 1024 else {
            expect(false, "noise movie is big enough to mean something")
            return
        }
        guard let server = RangeServer(payload: payload, contentType: "video/quicktime") else {
            expect(false, "range server starts")
            return
        }
        defer { server.listener.cancel() }
        await waitUntil(2) { server.port != 0 }
        // An R2-shaped URL: no extension on the key, signature in the query.
        let url = URL(string: "http://127.0.0.1:\(server.port)/cloud-projects/u/p/objects/\(String(repeating: "a", count: 64))?X-Amz-Signature=0123")!
        let file = CloudRemoteFile(path: "recording.mov", sha256: "0", bytes: Int64(payload.count),
                                   contentType: "video/quicktime", source: nil, url: url)
        let image = await CloudThumbnailer.thumbnail(of: file, duration: 4)
        let fraction = Double(server.served) / Double(payload.count)
        expect(image != nil && image.map { abs(Double($0.width) / Double($0.height) - 16.0 / 9.0) < 0.02 } == true,
               "a frame decoded from an extension-less presigned URL (\(image.map { "\($0.width)×\($0.height)" } ?? "nil"))")
        expect(server.rangeRequests > 0, "read with byte-range requests (\(server.rangeRequests))")
        expect(fraction < 0.5,
               "fetched \(Int(fraction * 100))% of a \(payload.count / 1_048_576) MB recording — never the whole file")
    }

    // MARK: - The real browser

    static func libraryUIChecks(_ checks: Checks) async {
        let expect = checks.expect
        print("ui: project browser Cloud section (editor window content switcher)")
        let fixtures: LibraryFixtures
        do {
            fixtures = try await makeLibraryFixtures()
        } catch {
            expect(false, "ui fixtures write (\(error))")
            return
        }
        defer { try? FileManager.default.removeItem(at: fixtures.root) }

        // Seams first: nothing below may reach the real API or the real cache.
        let library = CloudLibrary.shared
        let stub = StubLibraryTransport()
        var session = false
        var opened: [UUID] = []
        library.transport = stub
        library.cache = CloudThumbnailCache(directory: fixtures.root.appendingPathComponent("ui-thumbs", isDirectory: true))
        library.hasSession = { session }
        library.opener = { id, _ in opened.append(id) }
        library.signedInOverride = false
        library.bind(account: nil)
        defer {
            library.signedInOverride = nil
            library.transport = HTTPCloudLibraryTransport()
            library.cache = CloudThumbnailCache(directory: CloudThumbnailCache.defaultDirectory)
            library.hasSession = { AuthKeychain.currentToken() != nil }
            library.opener = { id, appState in
                CloudSyncController.shared.openFromCloud(projectID: id, appState: appState, title: "Opening from the Cloud")
            }
            library.minimumRefreshInterval = 15
            library.clear()
        }

        let now = Date()
        let deviceID = UUID(), stillID = UUID(), inFlightID = UUID(), uploadingID = UUID()
        stub.items = [
            item(deviceID, "Checkout flow on iPhone", revision: 2, bytes: 48_234_496, updated: now.addingTimeInterval(-120)),
            item(stillID, "Settings screenshot", revision: 1, bytes: 812_000, updated: now.addingTimeInterval(-3_600)),
            item(inFlightID, "Being cloned", updated: now),
            item(uploadingID, "Still uploading", revision: 0, hasDocument: false, updated: now),
        ]
        stub.details[deviceID] = remote(revision: 2, document: document(id: deviceID, kind: .device),
                                        files: [("recording.mov", fixtures.movie, "video/quicktime")])
        stub.details[stillID] = remote(revision: 1, document: document(id: stillID, kind: .still),
                                       files: [("screenshot.png", fixtures.still, "image/png")])
        library.setCloning(inFlightID, true)
        defer { library.setCloning(inFlightID, false) }

        AppState.suppressAutoToolbar = true
        let appState = AppState()
        appState.hasCompletedOnboarding = true   // in-memory only
        appState.currentProject = nil
        appState.showProjectBrowser = true
        // One of this Mac's own projects, if it has any, listed in the cloud
        // too: it must NOT appear as a cloud card.
        let localTwin = appState.projectStore.projects.first
        if let localTwin {
            stub.items.append(item(localTwin.id, "Local twin", updated: now))
        }
        let typeFilterDefault = UserDefaults.standard.string(forKey: CaptureTypeFilter.defaultsKey)

        let content = EditorWindowContentViewController(appState: appState)
        let window = NSWindow(contentViewController: content)
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.setContentSize(NSSize(width: 1280, height: 800))
        window.setFrameOrigin(NSPoint(x: -20_000, y: 200))
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.close()
            if let typeFilterDefault {
                UserDefaults.standard.set(typeFilterDefault, forKey: CaptureTypeFilter.defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: CaptureTypeFilter.defaultsKey)
            }
        }
        try? await Task.sleep(for: .milliseconds(500))
        guard let browser = content.children.first as? ProjectBrowserViewController else {
            expect(false, "the editor window mounts the project browser")
            return
        }
        expect(true, "the editor window mounts the project browser")
        // The browser starts on the user's saved type filter (a real
        // install may have left it on Videos or Images, which hides cards
        // this probe counts): start from All; the defer restores theirs.
        if browser.harnessTypeFilter != .all {
            print("  · note: saved type filter was \(browser.harnessTypeFilter) — probing from All")
            browser.harnessSelectTypeFilter(.all)
            try? await Task.sleep(for: .milliseconds(100))
        }

        // Signed out: nothing new at all.
        expect(browser.harnessSidebarRow(.cloud) == nil, "signed out: no Cloud row in the sidebar")
        expect(stub.listCalls == 0, "signed out: no request (\(stub.listCalls))")

        // Sign in → the row appears and the account is listed once.
        session = true
        library.signedInOverride = true
        let listed = await waitUntil(3) { stub.listCalls >= 1 && library.hasListed }
        try? await Task.sleep(for: .milliseconds(150))
        expect(listed && stub.listCalls == 1, "sign-in lists the cloud once (\(stub.listCalls))")
        guard let row = browser.harnessSidebarRow(.cloud) else {
            expect(false, "signed in: a Cloud row in the sidebar")
            return
        }
        expect(row.window === window && row.frame.height > 20 && !row.isHiddenOrHasHiddenAncestor,
               "signed in: a Cloud row in the sidebar, laid out (\(Int(row.frame.width))×\(Int(row.frame.height)))")
        if let shared = browser.harnessSidebarRow(.shared) {
            let rowY = row.convert(NSPoint.zero, to: nil).y
            let sharedY = shared.convert(NSPoint.zero, to: nil).y
            expect(rowY < sharedY, "…right under Shared")
        }

        // Click it (the row's real mouse path).
        CloudSyncHarness.click(row)
        try? await Task.sleep(for: .milliseconds(200))
        expect(browser.harnessFilter == .cloud, "a click selects the Cloud section")
        let cards = browser.harnessCloudCards
        let cardIDs = Set(cards.compactMap(\.projectID))
        expect(cardIDs == [deviceID, stillID],
               "cards = cloud-only (in-flight and still-uploading hidden\(localTwin == nil ? "" : ", this Mac's own project hidden")) (\(cards.count))")
        if localTwin == nil { print("  · note: no local projects on this machine — local-twin exclusion covered by the merge checks only") }
        let deviceCard = cards.first { $0.projectID == deviceID }
        let stillCard = cards.first { $0.projectID == stillID }
        expect(deviceCard?.probeName == "Checkout flow on iPhone"
               && deviceCard?.probeMetaText.contains("MB") == true && deviceCard?.probeMetaText.contains("ago") == true,
               "card: name + size · date (\(deviceCard?.probeMetaText ?? "nil"))")
        expect(deviceCard.map { !$0.probeCloudBadge.isHiddenOrHasHiddenAncestor && $0.probeCloudBadge.image != nil } == true,
               "card: cloud badge drawn (kit glyph)")
        expect(browser.harnessCloudEntryIDs == [deviceID, stillID], "newest first")

        // Art arrives LIVE — sample the fade mid-flight on the real layer.
        let arrived = await waitUntil(10, every: .milliseconds(4)) { deviceCard?.probeArtView.image != nil }
        expect(arrived, "the recording's frame lands on the card")
        if arrived, let layer = deviceCard?.probeArtView.layer {
            // Sample the presentation opacity every few ms for the whole
            // ~320 ms fade (one fixed-delay sample was flaky: a busy main
            // thread overslept it past the flight). Mid-flight = some sample
            // strictly between the ends while the animation is attached, and
            // the samples never step backwards.
            var samples: [Float] = []
            let deadline = Date().addingTimeInterval(0.6)
            while Date() < deadline, layer.animation(forKey: "capmotion.alpha") != nil {
                samples.append(layer.presentation()?.opacity ?? -1)
                try? await Task.sleep(for: .milliseconds(4))
            }
            let mid = samples.filter { $0 > 0.05 && $0 < 0.95 }
            let rising = zip(samples, samples.dropFirst()).allSatisfy { $0.1 >= $0.0 - 0.001 }
            expect(!mid.isEmpty && rising,
                   "…fading in, sampled mid-flight (\(mid.count) of \(samples.count) samples between, e.g. \(String(format: "%.2f", mid.first ?? -1)), rising \(rising))")
        }
        try? await Task.sleep(for: .milliseconds(600))
        expect(deviceCard.map { $0.probeArtView.alphaValue == 1 && $0.probePlaceholder.alphaValue == 0 } == true,
               "…and settles over the faded-out placeholder")
        expect(deviceCard?.probeTagText == "iPhone", "device take tagged iPhone (\(deviceCard?.probeTagText ?? "nil"))")
        _ = await waitUntil(5) { stillCard?.probeTagText != nil }
        expect(stillCard?.probeTagText == "Screenshot", "screenshot tagged Screenshot (\(stillCard?.probeTagText ?? "nil"))")
        expect(deviceCard?.probeMetaText.hasPrefix("0:02") == true,
               "the duration joins the meta once the document is known (\(deviceCard?.probeMetaText ?? "nil"))")
        if let tag = deviceCard?.probeTag {
            let frame = tag.convert(tag.bounds, to: deviceCard?.view)
            let art = deviceCard!.probeArtView.convert(deviceCard!.probeArtView.bounds, to: deviceCard?.view)
            expect(art.contains(frame) && frame.width > 30, "tag sits inside the art, top-left (\(Int(frame.width))pt)")
        }

        // Videos / Images split by kind.
        browser.harnessSelectTypeFilter(.images)
        try? await Task.sleep(for: .milliseconds(150))
        expect(browser.harnessCloudEntryIDs == [stillID], "Images → the screenshot only")
        browser.harnessSelectTypeFilter(.videos)
        try? await Task.sleep(for: .milliseconds(150))
        expect(browser.harnessCloudEntryIDs == [deviceID], "Videos → the iPhone take only")
        browser.harnessSelectTypeFilter(.all)
        try? await Task.sleep(for: .milliseconds(150))

        // A click hands the project to the clone path.
        let grid = browser.harnessCollectionView
        if let index = browser.harnessCloudCards.firstIndex(where: { $0.projectID == deviceID }),
           let path = grid.indexPath(for: browser.harnessCloudCards[index]) {
            grid.selectItems(at: [path], scrollPosition: [])
            (grid.delegate as? NSCollectionViewDelegate)?.collectionView?(grid, didSelectItemsAt: [path])
            expect(opened == [deviceID], "a click opens it through the clone path (\(opened.count) call)")
        } else {
            expect(false, "the device card is in the grid")
        }

        // While it clones it leaves the grid; a failed clone brings it back.
        library.setCloning(deviceID, true)
        _ = await waitUntil(2) { !browser.harnessCloudEntryIDs.contains(deviceID) }
        expect(!browser.harnessCloudEntryIDs.contains(deviceID), "in flight → hidden")
        library.setCloning(deviceID, false)
        _ = await waitUntil(2) { browser.harnessCloudEntryIDs.contains(deviceID) }
        expect(browser.harnessCloudEntryIDs.contains(deviceID), "clone over, not local → back")

        // Focus refreshes; the 60 s tick runs while visible.
        library.minimumRefreshInterval = 0
        let before = stub.listCalls
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        _ = await waitUntil(2) { stub.listCalls > before }
        expect(stub.listCalls == before + 1, "window focus re-lists (\(stub.listCalls - before))")
        expect(browser.harnessCloudTimerInterval == ProjectBrowserViewController.cloudRefreshInterval
               && ProjectBrowserViewController.cloudRefreshInterval == 60,
               "a 60 s re-list timer runs while the browser is up")

        // A new phone take appears on the next listing, without a reload of
        // what's there.
        let freshID = UUID()
        stub.items.append(item(freshID, "Just recorded", updated: now.addingTimeInterval(5)))
        stub.details[freshID] = remote(revision: 1, document: document(id: freshID, kind: .device),
                                       files: [("recording.mov", fixtures.movie, "video/quicktime")])
        library.refresh(force: true)
        _ = await waitUntil(3) { browser.harnessCloudEntryIDs.contains(freshID) }
        expect(browser.harnessCloudEntryIDs.first == freshID, "a newly synced phone take appears, first")

        // Sign out: the row, the cards and the list go.
        session = false
        library.signedInOverride = false
        _ = await waitUntil(2) { browser.harnessSidebarRow(.cloud) == nil }
        try? await Task.sleep(for: .milliseconds(150))
        expect(browser.harnessSidebarRow(.cloud) == nil && browser.harnessFilter == .all,
               "sign-out removes the row and returns to All Captures")
        expect(browser.harnessCloudEntryIDs.isEmpty && library.items.isEmpty, "…and forgets the cloud list")

        writeLibraryShot(of: window)
        window.orderOut(nil)
        try? await Task.sleep(for: .milliseconds(100))
        content.view.removeFromSuperview()
        try? await Task.sleep(for: .milliseconds(100))
        expect(browser.harnessCloudTimerInterval == nil, "the timer stops when the browser leaves the window")
    }

    private static func writeLibraryShot(of window: NSWindow) {
        guard CommandLine.arguments.contains("--shot"), let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("capturecat-cloud-sync", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("cloud-library.png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("  · shot \(url.path)")
    }
}
