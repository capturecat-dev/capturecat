import Observation
import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// Everything the Capture tab does, minus the drawing (CaptureHubViewController
/// renders this model with the house kit):
///  • stream the iPhone screen to a Mac on the same account ("iPhone over Wi-Fi")
///  • record the screen on the phone (uploads as a cloud project)
///  • import screenshots / videos from Photos (screenshots become still-capture
///    projects with the iPhone bezel on Mac and web)
///  • react when a Mac asks for the screen (push, or the presence link).
@MainActor
@Observable
final class CaptureHubModel {
    static let shared = CaptureHubModel()

    /// The last "use this iPhone" request, for a short-lived banner.
    struct Request: Equatable {
        var macID: String?
        var macName: String
        var at: Date
    }

    private(set) var lastRequest: Request?
    private(set) var importError: String?
    private(set) var isImporting = false

    var presence: MacPresence { .shared }
    var uploads: UploadCenter { .shared }

    private static let presenceEnabledKey = "presenceEnabled"

    /// Wire push + presence requests here (call once at launch).
    func install() {
        PushRouter.shared.onBroadcastRequest = { [weak self] macID, macName in
            self?.handleRequest(macID: macID, macName: macName)
        }
        if let pending = PushRouter.shared.takePending() {
            handleRequest(macID: pending.0, macName: pending.1)
        }
    }

    /// The Capture tab appeared: from now on keep presence up while the app
    /// is active (this is also where iOS asks for Local Network access).
    func activate() {
        UserDefaults.standard.set(true, forKey: Self.presenceEnabledKey)
        Task { await MacPresence.shared.start() }
        // The moment a push matters: the Mac can wake this phone to stream.
        // iOS shows the prompt only once; later calls just re-register.
        Task { await DeviceRegistry.shared.requestPushPermission() }
        UploadCenter.shared.reload()
    }

    /// App became active / went to the background.
    func appDidBecomeActive() {
        guard UserDefaults.standard.bool(forKey: Self.presenceEnabledKey) else { return }
        Task { await MacPresence.shared.start() }
    }

    func appDidEnterBackground() {
        MacPresence.shared.stop()
    }

    // MARK: Actions

    func streamToMac(from view: UIView) {
        BroadcastLauncher.launch(.stream, preferredMacID: MacPresence.shared.connectedMacID, in: view.window)
    }

    func recordOnPhone(from view: UIView) {
        BroadcastLauncher.launch(.record, in: view.window)
    }

    /// A Mac asked for this phone's screen (it tapped the phone in its source
    /// list). The user already said yes by tapping the push or by having the
    /// app open on that Mac's network — go straight to the system sheet.
    func handleRequest(macID: String?, macName: String?) {
        lastRequest = Request(macID: macID, macName: macName ?? String(localized: "your Mac", comment: "Fallback name for a Mac that asked for the screen, used in “%@ asked for your screen”"), at: Date())
        BroadcastLauncher.launch(.stream, preferredMacID: macID, in: nil)
    }

    func dismissRequest() {
        lastRequest = nil
    }

    // MARK: Photos import

    /// Present the system photo picker for screenshots (multi-select).
    func pickScreenshots(from presenter: UIViewController) {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .screenshots
        config.selectionLimit = 0
        config.preferredAssetRepresentationMode = .current
        present(config, from: presenter) { [weak self] results in
            await self?.importScreenshots(results)
        }
    }

    /// Present the system photo picker for screen recordings and videos.
    func pickVideos(from presenter: UIViewController) {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .any(of: [.screenRecordings, .videos])
        config.selectionLimit = 0
        config.preferredAssetRepresentationMode = .current
        present(config, from: presenter) { [weak self] results in
            await self?.importVideos(results)
        }
    }

    private var pickerDelegate: PickerDelegate?

    private func present(_ config: PHPickerConfiguration, from presenter: UIViewController, onPick: @escaping (([PHPickerResult]) async -> Void)) {
        let picker = PHPickerViewController(configuration: config)
        let delegate = PickerDelegate { picker, results in
            picker.dismiss(animated: true)
            guard !results.isEmpty else { return }
            Task { await onPick(results) }
        }
        pickerDelegate = delegate
        picker.delegate = delegate
        presenter.present(picker, animated: true)
    }

    private func importScreenshots(_ results: [PHPickerResult]) async {
        isImporting = true
        importError = nil
        defer { isImporting = false }
        var images: [(data: Data, date: Date?)] = []
        for result in results {
            if let data = await Self.loadData(result.itemProvider, type: .image) {
                images.append((data, nil))
            }
        }
        let errors = await UploadCenter.shared.importScreenshots(images)
        if images.count < results.count || !errors.isEmpty {
            importError = String(localized: "Some screenshots couldn't be imported.")
        }
    }

    private func importVideos(_ results: [PHPickerResult]) async {
        isImporting = true
        importError = nil
        defer { isImporting = false }
        for result in results {
            do {
                guard let url = await Self.loadFile(result.itemProvider, type: .movie) else {
                    throw MediaImport.ImportError.unsupportedVideo
                }
                defer { try? FileManager.default.removeItem(at: url) }
                try await UploadCenter.shared.importVideo(at: url, date: nil)
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    // MARK: Item providers

    private nonisolated static func loadData(_ provider: NSItemProvider, type: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    /// Copies the picked movie somewhere we own (the provider's file is
    /// deleted as soon as the callback returns).
    private nonisolated static func loadFile(_ provider: NSItemProvider, type: UTType) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else { continuation.resume(returning: nil); return }
                let copy = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(url.pathExtension.isEmpty ? "mov" : url.pathExtension)
                do {
                    try FileManager.default.copyItem(at: url, to: copy)
                    continuation.resume(returning: copy)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

private final class PickerDelegate: NSObject, PHPickerViewControllerDelegate {
    let onFinish: (PHPickerViewController, [PHPickerResult]) -> Void

    init(onFinish: @escaping (PHPickerViewController, [PHPickerResult]) -> Void) {
        self.onFinish = onFinish
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        onFinish(picker, results)
    }
}
