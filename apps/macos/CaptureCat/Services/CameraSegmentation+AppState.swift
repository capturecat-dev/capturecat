import Foundation

/// The Mac app as `CameraSegmentation`'s host — what `start(appState:)` did
/// before the scheduler moved into Studio/ (Studio 4e): projects come from
/// the open editor or the project store, and capture, export and share
/// uploads hold the job.
extension CameraSegmentation {
    func start(appState: AppState) {
        projectLookup = { [weak appState] id in
            if let current = appState?.currentProject, current.id == id { return current }
            return appState?.projectStore.projects.first { $0.id == id }
        }
        isHostBusy = { [weak appState] in
            guard let appState else { return false }
            return appState.recordingSession.isRecording
                || appState.recordingSession.isPaused
                || appState.showExport
                || appState.shareJobCenter.hasActiveJobs
        }
    }
}
