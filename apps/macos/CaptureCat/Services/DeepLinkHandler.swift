import Foundation
import ScreenCaptureKit
import AppKit

/// Handles `capturecat://` URL scheme deep links for external automation.
///
/// Supported URLs:
/// - `capturecat://start-recording?source=display&audio=true`
/// - `capturecat://stop-recording`
/// - `capturecat://export?project=UUID`
/// - `capturecat://pause-recording`
/// - `capturecat://resume-recording`
/// - `capturecat://list-projects`
/// - `capturecat://open-project?id=UUID`
@MainActor
final class DeepLinkHandler {
    private weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
    }

    func handle(_ url: URL) {
        guard url.scheme == "capturecat" else { return }
        let command = url.host ?? ""
        let params = parseQueryParams(url)
        print("[DeepLink] Handling: \(url) → command=\(command) params=\(params)")

        // A web page can fire these (after the browser's one-time "Open
        // CaptureCat?" prompt), so a deep link must never accept the Terms or
        // skip the permissions walkthrough on the user's behalf. Until
        // onboarding is done, links only bring the app forward.
        if let appState, appState.needsOnboarding {
            print("[DeepLink] Ignored \(command): onboarding not complete")
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        switch command {
        case "start-recording":
            handleStartRecording(params: params)
        case "stop-recording":
            handleStopRecording()
        case "pause-recording":
            handlePauseRecording()
        case "resume-recording":
            handleResumeRecording()
        case "export":
            handleExport(params: params)
        case "list-projects":
            handleListProjects()
        case "open-project":
            handleOpenProject(params: params)
        case "browse-projects":
            appState?.openProjectBrowser()
            NSApplication.shared.activate(ignoringOtherApps: true)
        default:
            print("[DeepLink] Unknown command: \(command)")
        }
    }

    // MARK: - Start Recording

    private func handleStartRecording(params: [String: String]) {
        guard let appState else { return }

        // Don't start if already recording
        guard !appState.recordingSession.isRecording, !appState.recordingSession.isPaused else {
            print("[DeepLink] Already recording, ignoring start-recording")
            return
        }

        let captureAudio = (params["audio"] ?? "true") == "true"
        let sourceType = params["source"] ?? "display"

        // Reset session state for a fresh recording
        appState.recordingSession.reset()

        Task {
            let source = await CaptureSourceResolver.resolve(type: sourceType, params: params)
            guard let source else {
                print("[DeepLink] Could not resolve capture source: \(sourceType)")
                return
            }
            let _ = await appState.startRecording(source: source, captureAudio: captureAudio)
            print("[DeepLink] Recording started (source=\(sourceType), audio=\(captureAudio))")
        }
    }

    // MARK: - Stop Recording

    private func handleStopRecording() {
        guard let appState else { return }
        guard appState.recordingSession.isRecording || appState.recordingSession.isPaused else {
            print("[DeepLink] Not recording, ignoring stop-recording")
            return
        }
        appState.stopRecordingInProgress()
        print("[DeepLink] Recording stopped")
    }

    // MARK: - Pause / Resume

    private func handlePauseRecording() {
        guard let appState else { return }
        guard appState.recordingSession.isRecording else {
            print("[DeepLink] Not recording, ignoring pause")
            return
        }
        appState.recorder.pause()
        appState.recordingSession.phase = .paused
        print("[DeepLink] Recording paused")
    }

    private func handleResumeRecording() {
        guard let appState else { return }
        guard appState.recordingSession.isPaused else {
            print("[DeepLink] Not paused, ignoring resume")
            return
        }
        appState.recorder.resume()
        appState.recordingSession.phase = .recording
        appState.recordingSession.startTimer()
        print("[DeepLink] Recording resumed")
    }

    // MARK: - Export

    private func handleExport(params: [String: String]) {
        guard let appState else { return }

        // Find project by UUID
        guard let uuidString = params["project"],
              let uuid = UUID(uuidString: uuidString) else {
            print("[DeepLink] export requires ?project=UUID")
            return
        }

        guard let project = appState.projectStore.projects.first(where: { $0.id == uuid }) else {
            print("[DeepLink] Project not found: \(uuidString)")
            return
        }

        // Open the project in the editor and trigger export
        appState.openEditor(with: project)
        appState.showExport = true
        NSApplication.shared.activate(ignoringOtherApps: true)
        print("[DeepLink] Opened export for project: \(project.name)")
    }

    // MARK: - List Projects

    private func handleListProjects() {
        guard let appState else { return }
        let projects = appState.projectStore.projects
        print("[DeepLink] Projects (\(projects.count)):")
        for project in projects {
            print("  - \(project.id.uuidString): \(project.name) (\(project.duration.formattedTimecode))")
        }
        // No temp-file dump: a web page could trigger this write. External
        // tools use the MCP `list_projects` tool instead.
    }

    // MARK: - Open Project

    private func handleOpenProject(params: [String: String]) {
        guard let appState else { return }

        guard let uuidString = params["id"],
              let uuid = UUID(uuidString: uuidString) else {
            print("[DeepLink] open-project requires ?id=UUID")
            return
        }

        guard let project = appState.projectStore.projects.first(where: { $0.id == uuid }) else {
            print("[DeepLink] Project not found: \(uuidString)")
            return
        }

        // Optional &t= — output-time seconds (e.g. a dashboard comment's
        // timestamp); the timeline consumes it once the editor is up.
        if let tString = params["t"], let t = Double(tString), t >= 0 {
            appState.pendingSeekOutputTime = t
        }
        appState.openEditor(with: project)
        NSApplication.shared.activate(ignoringOtherApps: true)
        print("[DeepLink] Opened project: \(project.name)")
    }

    // MARK: - Helpers

    private func parseQueryParams(_ url: URL) -> [String: String] {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            return [:]
        }
        var params: [String: String] = [:]
        for item in queryItems {
            params[item.name] = item.value ?? ""
        }
        return params
    }
}
