import Observation
import UIKit

extension Notification.Name {
    /// Something changed the cloud library (an upload landed, a rename saved):
    /// library screens refresh.
    static let ccLibraryShouldRefresh = Notification.Name("so.capturecat.ios.libraryShouldRefresh")
}

/// Turns inbox takes (screen broadcasts, screenshots, imported videos) into
/// cloud projects, one at a time, while the app is active — with a background
/// task so a half-finished upload gets its few extra minutes when the user
/// switches apps. Screens observe `takes` and `progress`.
@MainActor
@Observable
final class UploadCenter {
    static let shared = UploadCenter()

    private(set) var takes: [PendingTake] = []
    private(set) var progress: [String: PublishProgress] = [:]
    private(set) var isRunning = false

    /// Re-read the inbox (the extensions write it behind our back).
    func reload() {
        takes = TakeInbox.all()
    }

    /// Publish every take that is ready (pending), oldest first.
    func processPending() {
        reload()
        guard !isRunning, SessionStore.load() != nil else { return }
        let ready = takes.filter { ($0.state == .pending || $0.state == .uploading) && $0.openedInStudio != true }
            .sorted { $0.createdAt < $1.createdAt }
        guard !ready.isEmpty else { return }
        isRunning = true
        let background = UIApplication.shared.beginBackgroundTask(withName: "CaptureCat upload")
        Task {
            for take in ready {
                await publish(take)
            }
            isRunning = false
            reload()
            UIApplication.shared.endBackgroundTask(background)
        }
    }

    func retry(_ id: String) {
        TakeInbox.update(id) { $0.state = .pending; $0.error = nil }
        processPending()
    }

    func discard(_ id: String) {
        TakeInbox.remove(id)
        progress[id] = nil
        reload()
    }

    /// Screenshots picked in the app (Photos) — added and uploaded.
    func importScreenshots(_ images: [(data: Data, date: Date?)]) async -> [Error] {
        var errors: [Error] = []
        for image in images {
            do { _ = try await MediaImport.screenshot(data: image.data, createdAt: image.date ?? Date()) } catch { errors.append(error) }
        }
        processPending()
        return errors
    }

    func importVideo(at url: URL, date: Date?) async throws {
        _ = try await MediaImport.video(at: url, createdAt: date ?? Date())
        processPending()
    }

    private func publish(_ take: PendingTake) async {
        progress[take.id] = PublishProgress(phase: .preparing, fraction: 0, message: String(localized: "Preparing…", comment: "Upload status"))
        reload()
        let id = take.id
        do {
            try await TakeInbox.publish(take) { [weak self] p in
                Task { @MainActor in self?.progress[id] = p }
            }
            progress[id] = nil
            NotificationCenter.default.post(name: .ccLibraryShouldRefresh, object: nil)
        } catch {
            progress[id] = nil
        }
        reload()
    }
}
