import Foundation
import AppKit

/// Headless export mode: `CaptureCat --export <project-id-or-path> --output <file>`.
/// Runs the real VideoExporter with no windows, prints `PROGRESS n` lines and
/// a final `DONE <path>` to stdout, and exits with a proper status code. The
/// GUI path is completely untouched when the flag is absent.
enum HeadlessRunner {
    /// True when this launch is a headless export (checked in CaptureCatApp.init
    /// BEFORE any scene/AppState work).
    static let isHeadless = CommandLine.arguments.contains("--export")

    /// Flags this binary understands. Anything else starting with `--` means
    /// the user is on the CLI expecting help — print usage and exit instead
    /// of surprising them with the full GUI launching. Single-dash arguments
    /// are left alone (Xcode/macOS pass launch flags like -NSDocumentRevisions…).
    private static let knownFlags: Set<String> = ["--export", "--output", "--mcp", "--url-capture-test", "--capture-probe", "--show-onboarding", "--notes-test", "--search-test", "--browser-shot", "--export-geometry-test", "--still-image-test"]

    /// Prints usage and exits when an unknown `--flag` is present.
    /// Returns silently for a normal GUI launch.
    static func handleUnknownFlags() {
        let doubleDashed = CommandLine.arguments.dropFirst().filter { $0.hasPrefix("--") }
        guard !doubleDashed.isEmpty,
              doubleDashed.contains(where: { !knownFlags.contains($0) }) else { return }
        let usage = """
        CaptureCat command line

        usage:
          capturecat                                      launch the app
          capturecat --export <project-id|path> --output <file.mp4>
                                                     headless export (PROGRESS/DONE on stdout)
          capturecat --mcp                                run as an MCP server over stdio

        register with Claude Code:
          claude mcp add capturecat -- capturecat --mcp
        """
        FileHandle.standardError.write(Data((usage + "\n").utf8))
        exit(64)
    }

    private static func value(after flag: String) -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: flag), args.count > index + 1 else { return nil }
        return args[index + 1]
    }

    private static func emit(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    private static func fail(_ message: String, code: Int32 = 1) -> Never {
        FileHandle.standardError.write(Data("ERROR \(message)\n".utf8))
        exit(code)
    }

    /// SwiftUI may re-initialize the App struct — start() must run once.
    @MainActor
    private static var started = false

    /// Kick off the export. Called from CaptureCatApp.init when `isHeadless`.
    @MainActor
    static func start() {
        guard !started else { return }
        started = true
        // No dock icon, no windows, no activation.
        NSApplication.shared.setActivationPolicy(.prohibited)

        guard let ref = value(after: "--export"), let out = value(after: "--output") else {
            fail("usage: CaptureCat --export <project-id-or-path> --output <file.mp4>", code: 64)
        }
        let outputURL = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)

        Task { @MainActor in
            do {
                let project = try loadProject(ref: ref)
                emit("PROJECT \(project.id.uuidString) \(project.name)")
                let (actualURL, note) = try await performExport(
                    ref: ref,
                    outputPath: outputURL.path,
                    progress: { emit("PROGRESS \($0)") },
                    note: { emit("NOTE \($0)") }
                )
                _ = note
                emit("PROGRESS 100")
                emit("DONE \(actualURL.path)")
                exit(0)
            } catch {
                let ns = error as NSError
                let underlying = (ns.userInfo[NSUnderlyingErrorKey] as? NSError)
                    .map { " underlying=\($0.domain)#\($0.code) \($0.localizedDescription)" } ?? ""
                fail("\(error.localizedDescription) [\(ns.domain)#\(ns.code)]\(underlying)")
            }
        }
    }

    /// In-process export used by both the --export CLI and the --mcp server.
    /// Returns the actual output URL (which may be a sandbox-container
    /// fallback) and a human-readable note when the fallback was used.
    @MainActor
    static func performExport(
        ref: String,
        outputPath: String,
        progress: ((Int) -> Void)? = nil,
        note: ((String) -> Void)? = nil
    ) async throws -> (url: URL, note: String?) {
        let project = try loadProject(ref: ref)
        let requested = URL(fileURLWithPath: (outputPath as NSString).expandingTildeInPath)

        let exporter = VideoExporter()
        let progressTask = Task { @MainActor in
            var last = -1
            while !Task.isCancelled {
                let percent = Int((exporter.progress * 100).rounded())
                if percent != last {
                    last = percent
                    progress?(percent)
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        defer { progressTask.cancel() }

        // The app is sandboxed: a destination outside the container (e.g. an
        // arbitrary user path) is not writable from here. Probe the
        // destination directory BEFORE exporting and fall back to the
        // container's temp dir — callers move the file themselves.
        let (actualURL, fallbackNote) = writableDestination(for: requested, projectID: project.id)
        if let fallbackNote { note?(fallbackNote) }
        try await exporter.export(project: project, to: actualURL)
        return (actualURL, fallbackNote)
    }

    /// The requested URL when its directory is writable from the sandbox,
    /// otherwise a unique path in the container's temp directory plus a note.
    private static func writableDestination(for requested: URL, projectID: UUID) -> (URL, String?) {
        let fm = FileManager.default
        let dir = requested.deletingLastPathComponent()
        let probe = dir.appendingPathComponent(".capturecat-write-probe-\(UUID().uuidString)")
        if fm.createFile(atPath: probe.path, contents: Data()) {
            try? fm.removeItem(at: probe)
            return (requested, nil)
        }
        // Unique per launch: a stale partial file at a reused path makes
        // AVAssetWriter fail with a bare "operation could not be completed".
        let fallback = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("capturecat-export-\(projectID.uuidString)-\(UUID().uuidString.prefix(8)).mp4")
        return (fallback, "destination not writable from sandbox; using \(fallback.path)")
    }

    /// Accepts a project UUID (folder under the app's Projects directory), a
    /// path to a project folder, or a path to a project.json.
    static func loadProject(ref: String) throws -> Project {
        let fm = FileManager.default
        var jsonURL: URL

        let projectsRoot = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CaptureCat/Projects", isDirectory: true)

        if let uuid = UUID(uuidString: ref) {
            jsonURL = projectsRoot
                .appendingPathComponent(uuid.uuidString, isDirectory: true)
                .appendingPathComponent("project.json")
        } else {
            var url = URL(fileURLWithPath: (ref as NSString).expandingTildeInPath)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                throw HeadlessError.projectNotFound(ref)
            }
            if isDirectory.boolValue {
                url.appendPathComponent("project.json")
            }
            jsonURL = url
        }

        guard let data = try? Data(contentsOf: jsonURL) else {
            throw HeadlessError.projectNotFound(jsonURL.path)
        }
        return try JSONDecoder().decode(Project.self, from: data)
    }

    enum HeadlessError: LocalizedError {
        case projectNotFound(String)

        var errorDescription: String? {
            switch self {
            case .projectNotFound(let ref):
                return "project not found: \(ref)"
            }
        }
    }
}
