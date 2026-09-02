import AppKit
import Foundation

/// File-based automation channel between the GUI app and `CaptureCat --mcp`.
///
/// The MCP server is a second, headless instance of this same bundle, so it
/// shares the sandbox container — but LaunchServices can't reliably route a
/// `capturecat://` URL between two instances of one bundle. Instead the MCP
/// process writes `Automation/command.json` and polls `Automation/status.json`;
/// this bridge (GUI instance only) executes commands and publishes status,
/// including the project id once a recording finishes — feedback deep links
/// can never give.
///
/// Recording started this way is deliberately visible: it goes through the
/// exact same `AppState.startRecording` path as a manual take — recording
/// panel, countdown overlay and all — so an agent can never capture the screen
/// silently.
@MainActor
final class AutomationBridge {
    nonisolated static var automationDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CaptureCat/Automation", isDirectory: true)
    }

    private static var commandURL: URL { automationDirectory.appendingPathComponent("command.json") }
    private static var statusURL: URL { automationDirectory.appendingPathComponent("status.json") }

    private weak var appState: AppState?
    private var timer: Timer?
    /// Nonce of the most recent automation command — echoed into every status
    /// write so the MCP side can correlate request → outcome.
    private var lastNonce: String?

    init(appState: AppState) {
        self.appState = appState
    }

    func start() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.automationDirectory, withIntermediateDirectories: true)
        // A command left over from a previous run must not fire on launch.
        try? fm.removeItem(at: Self.commandURL)
        writeStatus(state: "idle")

        appState?.onRecordingFinished = { [weak self] project in
            self?.writeStatus(state: "finished", extra: [
                "projectId": project.id.uuidString,
                "projectName": project.name,
                "duration": project.duration,
            ])
        }

        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func poll() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Self.commandURL.path) else { return }
        // Claim the command by renaming it first — a crash mid-execution must
        // not leave it behind to re-fire on next launch.
        let claimed = Self.automationDirectory.appendingPathComponent(".command-claimed.json")
        try? fm.removeItem(at: claimed)
        do {
            try fm.moveItem(at: Self.commandURL, to: claimed)
        } catch { return }
        defer { try? fm.removeItem(at: claimed) }

        guard let data = try? Data(contentsOf: claimed),
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let command = payload["command"] as? String else { return }
        lastNonce = payload["nonce"] as? String
        let params = (payload["params"] as? [String: String]) ?? [:]
        print("[Automation] command=\(command) params=\(params)")
        execute(command: command, params: params)
    }

    private func execute(command: String, params: [String: String]) {
        guard let appState else { return }

        // Same policy as deep links: automation always works, onboarding or not.
        if appState.needsOnboarding {
            appState.completeOnboarding(acceptedTerms: true)
        }

        switch command {
        case "start-recording":
            guard !appState.recordingSession.isRecording, !appState.recordingSession.isPaused else {
                writeStatus(state: "failed", extra: ["error": "already recording"])
                return
            }
            let captureAudio = (params["audio"] ?? "true") == "true"
            let sourceType = params["source"] ?? "display"
            writeStatus(state: "preparing")
            appState.recordingSession.reset()
            Task { @MainActor in
                guard let source = await CaptureSourceResolver.resolve(type: sourceType, params: params) else {
                    self.writeStatus(state: "failed", extra: [
                        "error": "could not resolve capture source '\(sourceType)' \(params)",
                    ])
                    return
                }
                let started = await appState.startRecording(source: source, captureAudio: captureAudio)
                if started {
                    self.writeStatus(state: "recording", extra: ["source": sourceType])
                } else {
                    self.writeStatus(state: "failed", extra: [
                        "error": appState.recordingError ?? "recording failed to start",
                    ])
                }
            }

        case "stop-recording":
            guard appState.recordingSession.isRecording || appState.recordingSession.isPaused else {
                writeStatus(state: "failed", extra: ["error": "not recording"])
                return
            }
            writeStatus(state: "stopping")
            appState.stopRecordingInProgress()
            // "finished" + projectId arrives via onRecordingFinished.

        default:
            writeStatus(state: "failed", extra: ["error": "unknown command: \(command)"])
        }
    }

    private func writeStatus(state: String, extra: [String: Any] = [:]) {
        var payload: [String: Any] = [
            "state": state,
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        if let lastNonce { payload["nonce"] = lastNonce }
        for (key, value) in extra { payload[key] = value }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
        let tmp = Self.automationDirectory.appendingPathComponent(".status.json.tmp")
        try? data.write(to: tmp)
        _ = try? FileManager.default.replaceItemAt(Self.statusURL, withItemAt: tmp)
    }
}
