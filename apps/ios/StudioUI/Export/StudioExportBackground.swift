import BackgroundTasks
import UIKit

/// Keeps an export running when the user leaves the app (Studio 3d; the
/// plan's decision 2: iOS 26 `BGContinuedProcessingTask`, with the GPU where
/// the device and the app's entitlement allow it).
///
/// `begin` submits a continued-processing request under the app's permitted
/// wildcard (`<bundle id>.export.*`, Info.plist `BGTaskSchedulerPermittedIdentifiers`).
/// The system then shows the export's progress in its own UI and lets it
/// finish in the background; `report` feeds it the exporter's progress and an
/// expiry cancels the export. When the request cannot be submitted (an older
/// device, no permission, the system busy), it falls back to
/// `beginBackgroundTask` — a short grace period only — and the sheet says to
/// keep the app open.
///
/// GPU: the request asks for `.gpu` when `BGTaskScheduler.supportedResources`
/// offers it; a submission refused with it (the
/// `com.apple.developer.background-tasks.continued-processing.gpu` entitlement
/// missing) is retried without. Without background GPU the exporter's Core
/// Image work cannot run once the app is backgrounded; frames rendered that
/// way are a device measurement (plan, "On a device").
@available(iOS 26, *)
@MainActor
final class StudioExportBackground {
    enum Path: String {
        /// The system's continued-processing task: the export may leave the screen.
        case continuedProcessing = "continued-processing"
        /// Fallback: a short background-task grace period; keep the app open.
        case backgroundTask = "background-task"
        /// Nothing held (ended, or not begun).
        case none
    }

    private(set) var path: Path = .none
    /// The continued-processing request asked for (and was granted) the GPU.
    private(set) var usesGPU = false
    private(set) var identifier: String?
    private var task: BGContinuedProcessingTask?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var lastProgress: Double = 0
    private var finished: Bool?
    private var onExpire: (() -> Void)?

    /// Probe seam: every step, as a line (`--export-sheet` asserts the path
    /// was entered and ended).
    static var probeLog: ((String) -> Void)?
    #if DEBUG
    /// Probe seam — INJECTED DEFECT: the export never asks to keep running.
    static var probeSkip = false
    /// Probe seam: pretend continued processing is unavailable (exercises the fallback).
    static var probeForceFallback = false
    #endif

    /// The wildcard the app's Info.plist permits (`<bundle id>.export.*`).
    static var identifierPrefix: String { (Bundle.main.bundleIdentifier ?? "so.capturecat.ios") + ".export" }

    /// Asks the system to keep the export running; returns the path taken.
    @discardableResult
    func begin(title: String, subtitle: String, onExpire: @escaping () -> Void) -> Path {
        self.onExpire = onExpire
        #if DEBUG
        if Self.probeSkip { Self.probeLog?("background skipped (injected)"); return .none }
        #endif
        if submitContinuedProcessing(title: title, subtitle: subtitle) {
            path = .continuedProcessing
        } else {
            backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "CaptureCat export") { [weak self] in
                guard let self else { return }
                Self.probeLog?("background-task expired")
                self.onExpire?()
                self.endBackgroundTask()
            }
            path = backgroundTaskID == .invalid ? .none : .backgroundTask
        }
        Self.probeLog?("background begin path=\(path.rawValue) gpu=\(usesGPU)")
        return path
    }

    private func submitContinuedProcessing(title: String, subtitle: String) -> Bool {
        #if DEBUG
        if Self.probeForceFallback { Self.probeLog?("continued-processing unavailable (forced)"); return false }
        #endif
        let id = "\(Self.identifierPrefix).\(UUID().uuidString.prefix(8))"
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let self, let task = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.started(task)
            }
        }
        guard registered else {
            Self.probeLog?("continued-processing: \(id) not permitted (Info.plist)")
            return false
        }
        let wantsGPU = BGTaskScheduler.supportedResources.contains(.gpu)
        for gpu in wantsGPU ? [true, false] : [false] {
            let request = BGContinuedProcessingTaskRequest(identifier: id, title: title, subtitle: subtitle)
            request.strategy = .fail
            request.requiredResources = gpu ? .gpu : []
            do {
                try BGTaskScheduler.shared.submit(request)
                identifier = id
                usesGPU = gpu
                return true
            } catch {
                Self.probeLog?("continued-processing submit\(gpu ? " (gpu)" : "") refused: \(error.localizedDescription)")
            }
        }
        return false
    }

    private func started(_ task: BGContinuedProcessingTask) {
        Self.probeLog?("continued-processing task started")
        if let finished {
            // The export finished before the system started the task.
            task.progress.totalUnitCount = 1000
            task.progress.completedUnitCount = 1000
            task.setTaskCompleted(success: finished)
            return
        }
        self.task = task
        task.progress.totalUnitCount = 1000
        task.progress.completedUnitCount = Int64(lastProgress * 1000)
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                Self.probeLog?("continued-processing expired")
                self?.onExpire?()
            }
        }
    }

    /// The exporter's progress (0…1), for the system's progress UI.
    func report(_ progress: Double) {
        lastProgress = min(max(progress, 0), 1)
        task?.progress.completedUnitCount = Int64(lastProgress * 1000)
    }

    /// The export is over (finished, failed or cancelled): release whatever
    /// kept it running.
    func end(success: Bool) {
        guard finished == nil else { return }
        finished = success
        if let task {
            if success { task.progress.completedUnitCount = 1000 }
            task.setTaskCompleted(success: success)
            self.task = nil
        }
        endBackgroundTask()
        Self.probeLog?("background end path=\(path.rawValue) success=\(success)")
        onExpire = nil
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    /// What the sheet tells the user while exporting.
    var note: String {
        switch path {
        case .continuedProcessing:
            return "You can leave CaptureCat — the export keeps going and shows its progress."
        case .backgroundTask, .none:
            return "Keep CaptureCat open until the export finishes."
        }
    }
}
