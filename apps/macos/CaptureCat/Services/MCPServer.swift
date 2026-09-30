import AppKit
import AVFoundation
import CoreText
import CryptoKit
import Foundation
import ScreenCaptureKit

/// MCP server mode: `CaptureCat --mcp` speaks Model Context Protocol over stdio —
/// newline-delimited JSON-RPC 2.0, no external runtime. This replaces the old
/// Node sidecar: tools operate directly on the app's own Codable models, so
/// validation is compile-time-true to what the app persists.
///
/// Layout: this file owns transport, dispatch, project IO + undo history and
/// the read/render/export/record tools. Mutating tools are pure cores in
/// MCPServer+Edits, the set_style table in MCPServer+Style, describe_project's
/// digests in MCPServer+Analysis, and tool schemas / prompts / the server
/// instructions in MCPServer+Catalog.
///
/// stdout purity is sacred in this mode: ONLY JSON-RPC lines are written to
/// stdout; all diagnostics go to stderr.
enum MCPServer {
    static let isMCP = CommandLine.arguments.contains("--mcp")

    static let serverVersion = "0.3.0"
    private static let supportedProtocolVersions: Set<String> = [
        "2024-11-05", "2025-03-26", "2025-06-18",
    ]
    private static let latestProtocolVersion = "2025-06-18"

    private static let stdoutLock = NSLock()

    /// The real stdout, captured before fd 1 is redirected to stderr. Only
    /// JSON-RPC frames go here — nothing else in the process can reach it.
    private static var rpcOut = FileHandle.standardOutput

    // MARK: - Lifecycle

    /// Called from CaptureCatApp.init when `isMCP`. Never touches UI.
    @MainActor
    private static var started = false

    @MainActor
    static func start() {
        guard !started else { return }
        started = true
        NSApplication.shared.setActivationPolicy(.prohibited)

        // Stdout purity: keep a private dup of the real stdout for JSON-RPC,
        // then point fd 1 at stderr so stray print()s anywhere in the app or
        // its libraries (e.g. the export engine's progress lines, WhisperKit)
        // can never corrupt the protocol stream.
        let realStdout = dup(STDOUT_FILENO)
        if realStdout >= 0 {
            rpcOut = FileHandle(fileDescriptor: realStdout, closeOnDealloc: false)
            dup2(STDERR_FILENO, STDOUT_FILENO)
        }

        // Blocking stdin loop on its own thread; the main run loop stays free
        // for tool work that needs the main actor (export, transcription).
        let thread = Thread {
            serverLoop()
        }
        thread.name = "capturecat-mcp-stdin"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private static func serverLoop() {
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            handle(rawMessage: trimmed)
        }
        // EOF: client closed the pipe — clean shutdown.
        exit(0)
    }

    // MARK: - Transport

    static func send(_ payload: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload) else {
            log("dropping unserializable response")
            return
        }
        stdoutLock.lock()
        rpcOut.write(data)
        rpcOut.write(Data("\n".utf8))
        stdoutLock.unlock()
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("[capturecat-mcp] \(message)\n".utf8))
    }

    private static func reply(id: Any, result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func replyError(id: Any, code: Int, message: String) {
        send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    /// `notifications/progress` for one request — only when the caller sent
    /// `params._meta.progressToken`. Progress is strictly increasing (the
    /// spec requires it), so repeated or backwards values are dropped.
    final class ProgressReporter: @unchecked Sendable {
        private let token: Any?
        private var last: Double = -1
        private let lock = NSLock()

        init(token: Any?) { self.token = token }

        func report(_ progress: Double, total: Double? = nil, message: String? = nil) {
            guard let token else { return }
            lock.lock()
            defer { lock.unlock() }
            guard progress > last else { return }
            last = progress
            var params: [String: Any] = ["progressToken": token, "progress": progress]
            if let total { params["total"] = total }
            if let message { params["message"] = message }
            MCPServer.send(["jsonrpc": "2.0", "method": "notifications/progress", "params": params])
        }
    }

    // MARK: - JSON-RPC dispatch

    private static func handle(rawMessage: String) {
        guard let data = rawMessage.data(using: .utf8),
              let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let method = message["method"] as? String else {
            // Parse error with unknown id — per spec, id null.
            send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "parse error"]])
            return
        }
        let id = message["id"]
        let params = message["params"] as? [String: Any] ?? [:]

        // Notifications (no id) never get responses.
        if id == nil {
            return // notifications/initialized, cancellations — nothing to do
        }
        let requestID = id!

        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String
            let version = (requested.map { supportedProtocolVersions.contains($0) } ?? false)
                ? requested! : latestProtocolVersion
            reply(id: requestID, result: [
                "protocolVersion": version,
                "capabilities": [
                    "tools": ["listChanged": false],
                    "prompts": ["listChanged": false],
                ],
                "serverInfo": ["name": "capturecat", "title": "CaptureCat", "version": serverVersion],
                "instructions": serverInstructions,
            ])
        case "ping":
            reply(id: requestID, result: [:])
        case "tools/list":
            reply(id: requestID, result: ["tools": toolDefinitions])
        case "tools/call":
            guard let name = params["name"] as? String else {
                replyError(id: requestID, code: -32602, message: "missing tool name")
                return
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let meta = params["_meta"] as? [String: Any]
            let progress = ProgressReporter(token: meta?["progressToken"])
            callTool(name: name, arguments: arguments, requestID: requestID, progress: progress)
        case "prompts/list":
            reply(id: requestID, result: ["prompts": promptDefinitions])
        case "prompts/get":
            guard let name = params["name"] as? String else {
                replyError(id: requestID, code: -32602, message: "missing prompt name")
                return
            }
            do {
                let arguments = params["arguments"] as? [String: Any] ?? [:]
                reply(id: requestID, result: try promptResult(name: name, arguments: arguments))
            } catch {
                replyError(id: requestID, code: -32602, message: error.localizedDescription)
            }
        default:
            replyError(id: requestID, code: -32601, message: "method not found: \(method)")
        }
    }

    private static func callTool(
        name: String, arguments: [String: Any], requestID: Any, progress: ProgressReporter
    ) {
        do {
            let result: [String: Any]
            switch name {
            case "list_projects": result = try listProjects()
            case "list_notes": result = try listNotes()
            case "search_captures": result = try searchCaptures(arguments)
            case "describe_project": result = try describeProject(arguments)
            case "style_options": result = try styleOptionsTool(arguments)
            case "get_transcript": result = try getTranscript(arguments)
            case "apply_edits": result = try applyEdits(arguments)
            case "undo": result = try undo(arguments)
            case "transcribe": result = try transcribe(arguments, progress: progress)
            case "export_project": result = try exportProject(arguments, progress: progress)
            case "render_frames":
                // Returns MIXED content (images + text), not a JSON blob —
                // reply directly instead of going through resultJSON.
                let content = try renderFrames(arguments, progress: progress)
                reply(id: requestID, result: ["content": content, "isError": false])
                return
            case "list_capture_targets": result = try listCaptureTargets()
            case "start_recording": result = try startRecording(arguments)
            case "stop_recording": result = try stopRecording(arguments)
            default:
                guard let core = editOps[name] else {
                    replyError(id: requestID, code: -32602, message: "unknown tool: \(name)")
                    return
                }
                result = try runSingleEdit(name: name, core: core, arguments: arguments)
            }
            let text = resultJSON(result)
            reply(id: requestID, result: [
                "content": [["type": "text", "text": text]],
                "isError": false,
            ])
        } catch {
            reply(id: requestID, result: [
                "content": [["type": "text", "text": "ERROR: \(error.localizedDescription)"]],
                "isError": true,
            ])
        }
    }

    /// Tool results as compact, key-sorted JSON — models read it as well as
    /// pretty-printed JSON at a fraction of the tokens.
    static func resultJSON(_ object: [String: Any]) -> String {
        let clean = jsonSafe(object)
        guard JSONSerialization.isValidJSONObject(clean),
              let data = try? JSONSerialization.data(
                withJSONObject: clean, options: [.sortedKeys, .withoutEscapingSlashes]
              ) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Floating-point numbers as their shortest round-trip decimal ("44.668",
    /// not JSONSerialization's 17-digit "44.667999999999999"); non-finite → 0.
    static func jsonSafe(_ value: Any) -> Any {
        switch value {
        case let dictionary as [String: Any]:
            return dictionary.mapValues(jsonSafe)
        case let array as [Any]:
            return array.map(jsonSafe)
        case let number as NSNumber:
            guard CFGetTypeID(number) != CFBooleanGetTypeID(), CFNumberIsFloatType(number) else { return number }
            let double = number.doubleValue
            guard double.isFinite else { return 0 }
            return NSDecimalNumber(string: "\(double)", locale: Locale(identifier: "en_US_POSIX"))
        default:
            return value
        }
    }

    // MARK: - Project IO (direct Codable, atomic writes, media never touched)

    static var projectsRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CaptureCat/Projects", isDirectory: true)
    }

    struct ToolError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
        init(_ message: String) { self.message = message }
    }

    /// Accepts a UUID under the projects root, a project folder path, or a
    /// direct project.json path (same contract as headless --export).
    static func resolveProjectJSON(_ ref: String) throws -> URL {
        let fm = FileManager.default
        if let uuid = UUID(uuidString: ref) {
            let url = projectsRoot
                .appendingPathComponent(uuid.uuidString, isDirectory: true)
                .appendingPathComponent("project.json")
            guard fm.fileExists(atPath: url.path) else {
                throw ToolError("project not found: \(ref) — list_projects shows valid ids")
            }
            return url
        }
        var url = URL(fileURLWithPath: (ref as NSString).expandingTildeInPath)
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ToolError("project not found: \(ref) — pass a project UUID from list_projects, "
                + "a project folder, or a project.json path")
        }
        if isDirectory.boolValue { url.appendPathComponent("project.json") }
        return url
    }

    static func decodeProject(_ data: Data) throws -> Project {
        try JSONDecoder().decode(Project.self, from: data)
    }

    static func loadProject(_ ref: String) throws -> (url: URL, project: Project) {
        let url = try resolveProjectJSON(ref)
        let data = try Data(contentsOf: url)
        return (url, try decodeProject(data))
    }

    /// Atomic write (temp + replace) with a .bak of the previous contents —
    /// the ONE out-of-band write contract, shared with Cloud "Pull Web Edits"
    /// (ProjectFileIO) so every external edit reaches the GUI's reload path
    /// identically.
    private static func writeData(_ data: Data, to file: URL) throws {
        try ProjectFileIO.writeProjectData(data, to: file)
    }

    // MARK: - Undo history

    /// Every MCP write snapshots the previous project.json here first; undo
    /// walks back through them. Lives INSIDE the project folder (keyed by
    /// path, not project.id — a copied project keeps its original id).
    static let historyLimit = 30
    private static let historyDirectoryName = ".mcp-history"
    private static var historySequence = 0

    private struct HistoryEntry {
        let snapshot: URL
        let metaURL: URL
        let meta: [String: Any]
        var tool: String { meta["tool"] as? String ?? "edit" }
        var summary: String { meta["summary"] as? String ?? tool }
        var at: String { meta["at"] as? String ?? "" }
    }

    private static func historyDirectory(for file: URL) -> URL {
        file.deletingLastPathComponent().appendingPathComponent(historyDirectoryName, isDirectory: true)
    }

    /// Newest first.
    private static func history(for file: URL) -> [HistoryEntry] {
        let dir = historyDirectory(for: file)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names
            .filter { $0.hasSuffix(".json") && !$0.hasSuffix(".meta.json") }
            .sorted(by: >)
            .map { name in
                let base = String(name.dropLast(".json".count))
                let metaURL = dir.appendingPathComponent(base + ".meta.json")
                let meta = (try? Data(contentsOf: metaURL))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                return HistoryEntry(snapshot: dir.appendingPathComponent(name), metaURL: metaURL, meta: meta)
            }
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The ONE write path for every mutating tool: encode, snapshot the
    /// previous file into the undo history, keep the .bak, write atomically.
    /// Returns the extras every mutating result carries (undo depth, GUI
    /// warning).
    static func commitEdit(_ project: Project, to file: URL, tool: String, summary: String) throws -> [String: Any] {
        let fm = FileManager.default
        let data = try JSONEncoder().encode(project)
        var extras: [String: Any] = [:]
        var snapshotFiles: [URL] = []
        if let previous = try? Data(contentsOf: file) {
            let dir = historyDirectory(for: file)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            historySequence = (historySequence + 1) % 10000
            let base = String(format: "%013lld-%04d", Int64(Date().timeIntervalSince1970 * 1000), historySequence)
            let snapshot = dir.appendingPathComponent(base + ".json")
            let metaURL = dir.appendingPathComponent(base + ".meta.json")
            try previous.write(to: snapshot, options: .atomic)
            let meta: [String: Any] = [
                "tool": tool,
                "summary": String(summary.prefix(300)),
                "at": ISO8601DateFormatter().string(from: Date()),
                "postSHA256": sha256Hex(data),
            ]
            try JSONSerialization.data(withJSONObject: meta).write(to: metaURL, options: .atomic)
            snapshotFiles = [snapshot, metaURL]
            let entries = history(for: file)
            for stale in entries.dropFirst(historyLimit) {
                try? fm.removeItem(at: stale.snapshot)
                try? fm.removeItem(at: stale.metaURL)
            }
            extras["undoSteps"] = min(entries.count, historyLimit)
        }
        do {
            try writeData(data, to: file)
        } catch {
            // No write, no undo step: drop the snapshot that described it.
            for url in snapshotFiles { try? fm.removeItem(at: url) }
            throw error
        }
        if let warning = guiRunningWarning() { extras["warning"] = warning }
        return extras
    }

    static func undo(_ arguments: [String: Any]) throws -> [String: Any] {
        let ref = try requireProjectRef(arguments)
        let file = try resolveProjectJSON(ref)
        var steps = 1
        if let raw = arguments["steps"] {
            guard let value = doubleValue(raw), value >= 1, value == value.rounded() else {
                throw ToolError("steps must be a whole number >= 1")
            }
            steps = Int(value)
        }
        let entries = history(for: file)
        guard !entries.isEmpty else {
            throw ToolError("nothing to undo — no MCP edits are recorded for this project "
                + "(project.json.bak, if present, holds the state before the last write)")
        }
        guard steps <= entries.count else {
            throw ToolError("only \(entries.count) MCP edit(s) can be undone (asked for \(steps))")
        }
        let current = try Data(contentsOf: file)
        if let post = entries[0].meta["postSHA256"] as? String, post != sha256Hex(current),
           arguments["force"] as? Bool != true {
            throw ToolError("project.json changed outside MCP after the last MCP edit "
                + "(\(entries[0].summary) at \(entries[0].at)) — most likely saved from the CaptureCat app. "
                + "Undoing now would also discard those changes. Pass force: true to undo anyway.")
        }
        let target = try Data(contentsOf: entries[steps - 1].snapshot)
        let restored: Project
        do { restored = try decodeProject(target) } catch {
            throw ToolError("the history snapshot is unreadable (\(error.localizedDescription)) — "
                + "project.json was left untouched")
        }
        let before = try? decodeProject(current)
        try writeData(target, to: file)
        for entry in entries.prefix(steps) {
            try? FileManager.default.removeItem(at: entry.snapshot)
            try? FileManager.default.removeItem(at: entry.metaURL)
        }

        var result: [String: Any] = [
            "undone": entries.prefix(steps).map { ["tool": $0.tool, "summary": $0.summary, "at": $0.at] },
            "remainingUndoSteps": entries.count - steps,
            "restored": timelineCounts(restored),
            "note": "project.json.bak holds the state just before this undo.",
        ]
        if let before { result["replaced"] = timelineCounts(before) }
        if let warning = guiRunningWarning() { result["warning"] = warning }
        return result
    }

    static func timelineCounts(_ p: Project) -> [String: Any] {
        var counts: [String: Any] = [
            "trim": ["start": round3(p.effectiveTrimStart), "end": round3(p.effectiveTrimEnd)],
            "clips": p.effectiveVideoClipSegments.count,
            "zoomRegions": p.zoomRegions.count,
            "tiltRegions": p.tiltRegions.count,
            "annotations": p.annotations.count,
            "blurRegions": p.blurRegions.count,
            "speedRegions": p.speedRegions.count,
            "subtitles": p.subtitles.count,
        ]
        if let output = outputDuration(of: p) { counts["outputDuration"] = round3(output) }
        return counts
    }

    /// Warn when the GUI is running. The GUI watches project.json for external
    /// edits and reloads clean projects (browser and open editor alike), so
    /// the only remaining clobber window is a project that is open in the
    /// editor WITH unsaved changes — there the in-app edits win.
    static func guiRunningWarning() -> String? {
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: "so.capturecat.CaptureCat")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            .filter { $0.activationPolicy == .regular }
        guard !others.isEmpty else { return nil }
        return "CaptureCat is currently running — it picks this edit up automatically, "
            + "unless the project is open in the editor with unsaved changes, in which case "
            + "the in-app edits win and this edit may be overwritten."
    }

    static func round3(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return (value * 1000).rounded() / 1000
    }

    static func doubleValue(_ value: Any?) -> Double? {
        if isJSONBool(value) { return nil }
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }

    // MARK: - Tool: list_projects

    private static func listProjects() throws -> [String: Any] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: projectsRoot, includingPropertiesForKeys: nil
        ) else { return ["projects": [[String: Any]]()] }

        var projects: [(createdAt: Date, payload: [String: Any])] = []
        for entry in entries {
            let file = entry.appendingPathComponent("project.json")
            guard let data = try? Data(contentsOf: file),
                  let project = try? JSONDecoder().decode(Project.self, from: data) else { continue }
            var payload: [String: Any] = [
                "id": project.id.uuidString,
                "name": project.name,
                "createdAt": ISO8601DateFormatter().string(from: project.createdAt),
                "duration": round3(project.duration),
                "recordingSourceKind": project.recordingSourceKind.rawValue,
            ]
            if let reminder = project.reminderDate {
                payload["reminderDate"] = ISO8601DateFormatter().string(from: reminder)
            }
            projects.append((project.createdAt, payload))
        }
        projects.sort { $0.createdAt > $1.createdAt }
        return ["projects": projects.map(\.payload)]
    }

    // MARK: - Tool: list_notes

    private static func listNotes() throws -> [String: Any] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: Note.notesRoot, includingPropertiesForKeys: nil
        ) else { return ["notes": [[String: Any]]()] }

        let iso = ISO8601DateFormatter()
        var notes: [(createdAt: Date, payload: [String: Any])] = []
        for entry in entries {
            let file = entry.appendingPathComponent("note.json")
            guard let data = try? Data(contentsOf: file),
                  let note = try? JSONDecoder().decode(Note.self, from: data) else { continue }
            var payload: [String: Any] = [
                "id": note.id.uuidString,
                "title": note.title,
                "text": note.text,
                "createdAt": iso.string(from: note.createdAt),
            ]
            if let app = note.sourceAppName { payload["sourceAppName"] = app }
            if let reminder = note.reminderDate { payload["reminderDate"] = iso.string(from: reminder) }
            notes.append((note.createdAt, payload))
        }
        notes.sort { $0.createdAt > $1.createdAt }
        return ["notes": notes.map(\.payload)]
    }

    // MARK: - Tool: search_captures

    /// On-device text search over captures: token AND-matching against titles
    /// and the persisted OCR index (Application Support/CaptureCat/SearchIndex),
    /// ranked exactly like the browser's search (shared CaptureSearchRanking).
    private static func searchCaptures(_ arguments: [String: Any]) throws -> [String: Any] {
        guard let query = arguments["query"] as? String,
              !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ToolError("missing query")
        }
        let limit = (arguments["limit"] as? Int).map { max(1, min(50, $0)) } ?? 20
        let fm = FileManager.default
        let decoder = JSONDecoder()

        func indexRecord(for id: UUID) -> CaptureIndexRecord? {
            guard let data = try? Data(contentsOf: CaptureTextIndex.recordURL(for: id))
            else { return nil }
            return try? decoder.decode(CaptureIndexRecord.self, from: data)
        }

        var candidates: [CaptureSearchRanking.Candidate] = []
        var projectsByID: [UUID: Project] = [:]
        if let entries = try? fm.contentsOfDirectory(at: projectsRoot, includingPropertiesForKeys: nil) {
            for entry in entries {
                let file = entry.appendingPathComponent("project.json")
                guard let data = try? Data(contentsOf: file),
                      let project = try? decoder.decode(Project.self, from: data) else { continue }
                projectsByID[project.id] = project
                let record = indexRecord(for: project.id)
                candidates.append(.init(
                    id: project.id,
                    title: project.name,
                    text: record?.fullText ?? "",
                    frames: record?.frames ?? [],
                    kind: project.isImageCapture ? "image" : "video"
                ))
            }
        }
        if let entries = try? fm.contentsOfDirectory(at: Note.notesRoot, includingPropertiesForKeys: nil) {
            for entry in entries {
                let file = entry.appendingPathComponent("note.json")
                guard let data = try? Data(contentsOf: file),
                      let note = try? decoder.decode(Note.self, from: data) else { continue }
                candidates.append(.init(id: note.id, title: note.title, text: note.text, kind: "note"))
            }
        }

        let ranked = CaptureSearchRanking.rank(query: query, candidates: candidates)
        let results: [[String: Any]] = ranked.prefix(limit).map { match in
            var payload: [String: Any] = [
                "id": match.candidate.id.uuidString,
                "title": match.candidate.title,
                "kind": match.candidate.kind,
                "matchedBy": match.titleMatched ? "title" : "text",
                "hitCount": match.hitCount,
            ]
            if let snippet = match.snippet { payload["snippet"] = snippet }
            if let time = match.bestFrameTime {
                // OCR frames are indexed on SOURCE time; render_frames wants
                // OUTPUT time — map through the same trim+speed seek math the
                // browser's ⌘K uses.
                payload["bestFrameTime"] = round3(time)
                if let project = projectsByID[match.candidate.id] {
                    payload["bestFrameOutputTime"] = round3(
                        CaptureSearchSeek.outputTime(forSource: time, project: project))
                }
            }
            return payload
        }
        return [
            "query": query, "results": results, "totalMatches": ranked.count,
            "note": "bestFrameTime is SOURCE seconds (for edit tools); bestFrameOutputTime is OUTPUT "
                + "seconds (for render_frames).",
        ]
    }

    // MARK: - Tool: style_options

    private static func styleOptionsTool(_ arguments: [String: Any]) throws -> [String: Any] {
        var project: Project?
        if let ref = arguments["id"] as? String, !ref.isEmpty {
            project = try loadProject(ref).project
        }
        return try styleOptions(for: project, group: arguments["group"] as? String)
    }

    // MARK: - Tool: export_project

    private static func exportProject(_ arguments: [String: Any], progress: ProgressReporter) throws -> [String: Any] {
        let ref = try requireProjectRef(arguments)
        guard let output = arguments["output"] as? String, !output.isEmpty else {
            throw ToolError("missing output — an absolute destination path ending in .mp4")
        }
        _ = try resolveProjectJSON(ref)

        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<(url: URL, note: String?), Error> = .failure(ToolError("export did not run"))
        Task { @MainActor in
            do {
                let result = try await HeadlessRunner.performExport(
                    ref: ref,
                    outputPath: output,
                    progress: { percent in
                        log("export progress \(percent)%")
                        progress.report(Double(percent), total: 100, message: "Exporting")
                    }
                )
                outcome = .success(result)
            } catch {
                outcome = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()

        let (actualURL, note) = try outcome.get()
        let requested = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
        var result: [String: Any] = [
            "path": actualURL.path,
            "requestedPath": requested.path,
            "moved": actualURL.path == requested.path,
        ]
        if let note {
            // Sandboxed process cannot write outside its container — the
            // caller (an agent with a shell) moves the file itself.
            result["note"] = note + " — move/copy it to the requested path yourself."
        }
        return result
    }

    // MARK: - Tool: get_transcript

    /// Timed speech segments in OUTPUT time — same payload the share page's
    /// transcript uses, so agent context and viewer context can't drift —
    /// plus SOURCE times per segment and per word for edit tools.
    private static func getTranscript(_ arguments: [String: Any]) throws -> [String: Any] {
        let ref = try requireProjectRef(arguments)
        let (_, project) = try loadProject(ref)
        let segments = ShareIntelligence.transcriptPayload(for: project, includeSourceTimes: true)
        return [
            "segments": segments,
            "count": segments.count,
            "note": segments.isEmpty
                ? (project.subtitles.isEmpty
                    ? "No transcript — the project has no subtitles yet. Run transcribe {id} to generate them "
                        + "on-device (Whisper)."
                    : "No transcript inside the trim window.")
                : "start/end (and words[].start/end) are OUTPUT seconds — the clock render_frames uses. "
                    + "sourceStart/sourceEnd (per segment and per word) are SOURCE seconds — the clock every "
                    + "edit tool uses (cut_video, set_speed, add_effect, add_annotation…).",
        ]
    }

    // MARK: - Tool: transcribe

    /// Runs the editor's TranscriptionService (on-device WhisperKit) over the
    /// project recording and stores the result exactly as the Subtitles pane's
    /// Generate button does: `project.subtitles = segments` (SOURCE time).
    private static func transcribe(_ arguments: [String: Any], progress: ProgressReporter) throws -> [String: Any] {
        let ref = try requireProjectRef(arguments)
        let (_, project) = try loadProject(ref)
        guard let videoURL = project.videoURL else {
            throw ToolError("this project has no recording video to transcribe")
        }
        guard FileManager.default.fileExists(atPath: videoURL.path) else {
            throw ToolError("the recording file is missing (\(videoURL.lastPathComponent)) — nothing to transcribe")
        }
        let replace = arguments["replace"] as? Bool ?? false
        if !project.subtitles.isEmpty && !replace {
            throw ToolError("this project already has \(project.subtitles.count) subtitle segments (possibly "
                + "hand-corrected in the editor). Read them with get_transcript, or pass replace: true to "
                + "regenerate them from the audio.")
        }
        var showSubtitles: Bool?
        if let raw = arguments["showSubtitles"] {
            guard let flag = raw as? Bool else { throw ToolError("showSubtitles must be a boolean") }
            showSubtitles = flag
        }

        let stages = ["Loading model...": 1.0, "Extracting audio...": 2.0, "Transcribing...": 3.0,
                      "Processing subtitles...": 4.0]
        progress.report(0, total: 5, message: "Starting transcription")
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<[SubtitleSegment], Error> = .failure(ToolError("transcription did not run"))
        Task { @MainActor in
            let service = TranscriptionService()
            let poll = Task { @MainActor in
                var lastStage = ""
                while !Task.isCancelled {
                    let stage = service.progress
                    if stage != lastStage {
                        lastStage = stage
                        log("transcribe: \(stage)")
                        if let step = stages[stage] { progress.report(step, total: 5, message: stage) }
                    }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
            do {
                outcome = .success(try await service.transcribe(videoURL: videoURL))
            } catch {
                outcome = .failure(error)
            }
            poll.cancel()
            semaphore.signal()
        }
        semaphore.wait()

        let segments: [SubtitleSegment]
        do {
            segments = try outcome.get()
        } catch TranscriptionError.audioExtractionFailed(let reason) {
            throw ToolError("could not read the recording's audio (\(reason)) — a recording without an audio "
                + "track has nothing to transcribe")
        } catch {
            throw ToolError("transcription failed: \(error.localizedDescription). The first run downloads the "
                + "on-device Whisper model (~150 MB, base.en) from Hugging Face — check the network connection "
                + "and retry. Nothing was written.")
        }
        progress.report(5, total: 5, message: "Done — \(segments.count) subtitles")

        // Re-read: the transcription can take minutes and the file may have
        // changed meanwhile (the GUI, another edit) — only subtitles change.
        let (url, fresh) = try loadProject(ref)
        if segments.isEmpty && fresh.subtitles.isEmpty && showSubtitles == nil {
            return ["segments": 0, "note": "No speech was detected — nothing was written."]
        }
        fresh.subtitles = segments
        if let showSubtitles { fresh.settings.showSubtitles = showSubtitles }
        var result: [String: Any] = [
            "segments": segments.count,
            "words": segments.reduce(0) { $0 + $1.words.count },
            "showSubtitles": fresh.settings.showSubtitles,
            "note": "Stored as the project's subtitles (SOURCE time). get_transcript returns them with OUTPUT "
                + "and SOURCE times. They are burned into render/export while showSubtitles is true — "
                + "set_style {showSubtitles: false} keeps them as a transcript only.",
        ]
        if let first = segments.first, let last = segments.last {
            result["sourceSpan"] = ["start": round3(first.startTime), "end": round3(last.endTime)]
        }
        let extras = try commitEdit(fresh, to: url, tool: "transcribe", summary: "transcribe (\(segments.count) segments)")
        result.merge(extras) { current, _ in current }
        return result
    }

    // MARK: - Tool: render_frames (the agent's eyes)

    /// Exact frames of the final render. Renders through the real exporter
    /// (preview==export is gate-enforced, so there is no lesser "preview
    /// quality" to accidentally serve) and caches the render keyed on the
    /// project file's bytes — any edit re-renders, repeat looks are free.
    private static func renderFrames(_ arguments: [String: Any], progress: ProgressReporter) throws -> [[String: Any]] {
        let ref = try requireProjectRef(arguments)
        let layout = (arguments["layout"] as? String) ?? "individual"
        guard layout == "individual" || layout == "contact_sheet" else {
            throw ToolError("layout must be \"individual\" (one image per time) or \"contact_sheet\" "
                + "(all frames tiled into ONE labelled image — far fewer image tokens)")
        }
        let sheet = layout == "contact_sheet"
        let maxFrames = sheet ? 16 : 8

        let formatRaw = ((arguments["format"] as? String) ?? "png").lowercased()
        guard ["png", "jpeg", "jpg"].contains(formatRaw) else {
            throw ToolError("format must be \"png\" or \"jpeg\"")
        }
        let jpeg = formatRaw != "png"
        var quality = 0.8
        if let raw = arguments["quality"] {
            guard let q = doubleValue(raw), (0.1...1).contains(q) else {
                throw ToolError("quality must be a number in 0.1...1 (jpeg only)")
            }
            quality = q
        }
        let edgeRange: ClosedRange<Double> = sheet ? 400...2400 : 100...1600
        let maxEdge = min(edgeRange.upperBound,
                          max(edgeRange.lowerBound, doubleValue(arguments["maxWidth"]) ?? (sheet ? 1568 : 800)))

        // times (explicit) or span (evenly sampled) — both OUTPUT seconds.
        let rawTimes = arguments["times"] as? [Any]
        let span = arguments["span"] as? [String: Any]
        if rawTimes != nil && span != nil {
            throw ToolError("pass either times or span, not both")
        }
        var explicitTimes: [Double]?
        var spanSpec: (start: Double, end: Double?, count: Int)?
        if let rawTimes {
            let times = rawTimes.compactMap { doubleValue($0) }
            guard !times.isEmpty, times.count == rawTimes.count else {
                throw ToolError("times must be a non-empty array of numbers (OUTPUT seconds)")
            }
            guard times.count <= maxFrames else {
                throw ToolError("max \(maxFrames) times per call for layout \(layout)"
                    + (sheet ? "" : " — use layout \"contact_sheet\" for up to 16 in one image"))
            }
            explicitTimes = times
        } else if let span {
            let count = doubleValue(span["count"]).map { Int($0) } ?? (sheet ? 12 : 4)
            guard (1...maxFrames).contains(count) else {
                throw ToolError("span.count must be 1...\(maxFrames) for layout \(layout)")
            }
            let start = doubleValue(span["start"]) ?? 0
            let end = doubleValue(span["end"])
            guard start >= 0, end.map({ $0 > start }) ?? true else {
                throw ToolError("span needs 0 <= start < end (OUTPUT seconds; end defaults to the video's end)")
            }
            spanSpec = (start, end, count)
        } else {
            throw ToolError("pass times: [OUTPUT seconds…] or span: {start?, end?, count?} to sample evenly")
        }

        // Cache keyed on the project JSON bytes — edits rewrite the file.
        let jsonURL = try resolveProjectJSON(ref)
        let jsonData = try Data(contentsOf: jsonURL)
        let digest = SHA256.hash(data: jsonData).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
        let cacheDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("capturecat-mcp-renders", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let cached = cacheDir.appendingPathComponent("\(digest).mp4")

        var freshlyRendered = false
        if !FileManager.default.fileExists(atPath: cached.path) {
            freshlyRendered = true
            progress.report(0, total: 100, message: "Rendering the project (first look after an edit)")
            let semaphore = DispatchSemaphore(value: 0)
            var outcome: Result<URL, Error> = .failure(ToolError("render did not run"))
            Task { @MainActor in
                do {
                    let result = try await HeadlessRunner.performExport(
                        ref: ref,
                        outputPath: cached.path,
                        progress: { percent in
                            log("render_frames export \(percent)%")
                            progress.report(Double(percent), total: 100, message: "Rendering")
                        }
                    )
                    outcome = .success(result.url)
                } catch {
                    outcome = .failure(error)
                }
                semaphore.signal()
            }
            semaphore.wait()
            let actual: URL
            do { actual = try outcome.get() } catch {
                try? FileManager.default.removeItem(at: cached)
                throw error
            }
            // Sandbox fallback: performExport may have written elsewhere.
            if actual.path != cached.path {
                try? FileManager.default.removeItem(at: cached)
                try FileManager.default.copyItem(at: actual, to: cached)
            }
            pruneRenderCache(cacheDir, keeping: cached)
        } else {
            // Mark as recently used so pruning keeps the renders in play.
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: cached.path)
        }

        // Source-time labels come from the very bytes that were rendered.
        let timeMap = (try? decodeProject(jsonData)).map { SpeedTimeMap(trimmedOutputOf: $0) }

        let asset = AVURLAsset(url: cached)
        let infoSemaphore = DispatchSemaphore(value: 0)
        var duration: Double = 0
        var displaySize = CGSize(width: 16, height: 9)
        Task {
            duration = (try? await asset.load(.duration).seconds) ?? 0
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let natural = try? await track.load(.naturalSize),
               let transform = try? await track.load(.preferredTransform) {
                let applied = natural.applying(transform)
                displaySize = CGSize(width: abs(applied.width), height: abs(applied.height))
            }
            infoSemaphore.signal()
        }
        infoSemaphore.wait()
        guard duration > 0 else { throw ToolError("the render has no duration — nothing to show") }

        let times: [Double]
        if let explicitTimes {
            times = explicitTimes
        } else {
            let spec = spanSpec!
            let end = min(spec.end ?? duration, duration)
            guard end > spec.start else {
                throw ToolError("span start \(fmt(spec.start))s is past the end of the output (\(fmt(duration))s)")
            }
            times = spec.count == 1
                ? [spec.start]
                : (0..<spec.count).map { spec.start + (end - spec.start) * Double($0) / Double(spec.count - 1) }
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let aspect = displaySize.height > 0 ? displaySize.width / displaySize.height : 16.0 / 9.0
        let sheetLayout = sheet ? contactSheetLayout(count: times.count, aspect: aspect, maxEdge: maxEdge) : nil
        if let sheetLayout {
            generator.maximumSize = CGSize(width: sheetLayout.tile.width.rounded(.up),
                                           height: sheetLayout.tile.height.rounded(.up))
        } else {
            generator.maximumSize = CGSize(width: maxEdge, height: maxEdge)
        }

        struct Frame { let image: CGImage; let output: Double; let source: Double? }
        var frames: [Frame] = []
        for t in times {
            let clamped = max(0, min(t, max(0, duration - 0.001)))
            let requested = CMTime(seconds: clamped, preferredTimescale: 600)
            var actualTime = CMTime.zero
            let cgImage = try generator.copyCGImage(at: requested, actualTime: &actualTime)
            let output = CMTimeGetSeconds(actualTime)
            frames.append(Frame(image: cgImage, output: output,
                                source: timeMap.map { $0.sourceTime(forOutput: output) }))
        }

        var header: [String: Any] = [
            "render": freshlyRendered ? "fresh export" : "cached export",
            "durationSeconds": (duration * 100).rounded() / 100,
            "frames": frames.count,
            "layout": layout,
        ]
        let mime = jpeg ? "image/jpeg" : "image/png"

        if let sheetLayout {
            let labelled = frames.enumerated().map { index, frame -> (CGImage, String) in
                var label = "#\(index + 1)  \(String(format: "%.2fs", frame.output))"
                if let source = frame.source { label += "  src \(String(format: "%.2f", source))" }
                return (frame.image, label)
            }
            guard let sheetImage = drawContactSheet(labelled, layout: sheetLayout) else {
                throw ToolError("could not compose the contact sheet")
            }
            header["grid"] = "\(sheetLayout.columns)x\(sheetLayout.rows)"
            header["tiles"] = frames.enumerated().map { index, frame -> [String: Any] in
                var tile: [String: Any] = ["tile": index + 1, "output": round3(frame.output)]
                if let source = frame.source { tile["source"] = round3(source) }
                return tile
            }
            header["note"] = "One image, tiles left→right then top→bottom. The caption under each tile "
                + "reads '#n <OUTPUT>s  src <SOURCE>' — use the src (SOURCE) time for edit tools."
            return [
                ["type": "text", "text": resultJSON(header)],
                ["type": "image", "data": try encodeImage(sheetImage, jpeg: jpeg, quality: quality).base64EncodedString(),
                 "mimeType": mime],
            ]
        }

        var content: [[String: Any]] = [["type": "text", "text": resultJSON(header)]]
        for (index, frame) in frames.enumerated() {
            var caption = String(format: "frame #%d at t=%.2fs", index + 1, frame.output)
            if let source = frame.source { caption += String(format: " (source %.2fs)", source) }
            content.append(["type": "text", "text": caption + ":"])
            content.append([
                "type": "image",
                "data": try encodeImage(frame.image, jpeg: jpeg, quality: quality).base64EncodedString(),
                "mimeType": mime,
            ])
        }
        return content
    }

    /// Every edit state renders a full mp4 (often 100 MB+); an agent loop of
    /// edit → look would otherwise fill the container's tmp. Keep the most
    /// recently used few.
    static let renderCacheLimit = 6

    private static func pruneRenderCache(_ directory: URL, keeping current: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let renders = files
            .filter { $0.pathExtension == "mp4" && $0.lastPathComponent != current.lastPathComponent }
            .map { url -> (URL, Date) in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return (url, date)
            }
            .sorted { $0.1 > $1.1 }
        for (url, _) in renders.dropFirst(renderCacheLimit - 1) {
            try? fm.removeItem(at: url)
        }
    }

    private static func encodeImage(_ image: CGImage, jpeg: Bool, quality: Double) throws -> Data {
        let rep = NSBitmapImageRep(cgImage: image)
        let data = jpeg
            ? rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
            : rep.representation(using: .png, properties: [:])
        guard let data else { throw ToolError("image encode failed") }
        return data
    }

    struct ContactSheetLayout {
        let columns: Int
        let rows: Int
        /// The frame area of one cell (the caption strip sits below it).
        let tile: CGSize
        let captionHeight: CGFloat
        let fontSize: CGFloat
        let gap: CGFloat
        let size: CGSize
    }

    /// Grid whose overall shape is closest to 3:2 (fits a model's image
    /// budget well), preferring few empty cells; longest edge <= maxEdge.
    /// Each cell = the frame + a caption strip below it, so labels never
    /// cover the picture being checked.
    static func contactSheetLayout(count: Int, aspect: Double, maxEdge: Double) -> ContactSheetLayout {
        let tileAspect = CGFloat(max(0.1, aspect))
        var best = (columns: 1, score: Double.infinity)
        for columns in 1...max(1, count) {
            let rows = Int(ceil(Double(count) / Double(columns)))
            // ~12% of a cell's height is caption.
            let sheetAspect = Double(columns) * aspect * 0.88 / Double(rows)
            let empty = columns * rows - count
            let score = abs(Foundation.log(sheetAspect / 1.5)) + Double(empty) * 0.12
            if score < best.score { best = (columns, score) }
        }
        let columns = best.columns
        let rows = Int(ceil(Double(count) / Double(columns)))
        let gap: CGFloat = 6
        func caption(for tileWidth: CGFloat) -> (font: CGFloat, height: CGFloat) {
            let font = max(12, min(26, tileWidth * 0.05)).rounded()
            return (font, (font * 1.6).rounded(.up))
        }
        func sheetSize(_ tileWidth: CGFloat) -> CGSize {
            let tileHeight = (tileWidth / tileAspect).rounded(.down)
            return CGSize(
                width: CGFloat(columns) * tileWidth + CGFloat(columns + 1) * gap,
                height: CGFloat(rows) * (tileHeight + caption(for: tileWidth).height) + CGFloat(rows + 1) * gap
            )
        }
        let edge = CGFloat(maxEdge)
        var tileWidth = ((edge - CGFloat(columns + 1) * gap) / CGFloat(columns)).rounded(.down)
        for _ in 0..<12 {
            let size = sheetSize(tileWidth)
            guard max(size.width, size.height) > edge else { break }
            tileWidth = (tileWidth * edge / max(size.width, size.height)).rounded(.down) - 1
        }
        tileWidth = max(40, tileWidth)
        let captionMetrics = caption(for: tileWidth)
        return ContactSheetLayout(
            columns: columns, rows: rows,
            tile: CGSize(width: tileWidth, height: (tileWidth / tileAspect).rounded(.down)),
            captionHeight: captionMetrics.height, fontSize: captionMetrics.font,
            gap: gap, size: sheetSize(tileWidth)
        )
    }

    /// Tiles `frames` into one image with each tile's label burned into a
    /// caption strip under it (white on the dark sheet — legible after a
    /// client downscales the image). Plain CoreGraphics/CoreText in pixel
    /// space (Y-up).
    static func drawContactSheet(_ frames: [(CGImage, String)], layout: ContactSheetLayout) -> CGImage? {
        let width = Int(layout.size.width), height = Int(layout.size.height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high

        let tile = layout.tile
        let cellHeight = tile.height + layout.captionHeight
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, layout.fontSize, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, layout.fontSize, nil)
        let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

        for (index, frame) in frames.enumerated() {
            let column = index % layout.columns
            let row = index / layout.columns
            let x = layout.gap + CGFloat(column) * (tile.width + layout.gap)
            let yFromTop = layout.gap + CGFloat(row) * (cellHeight + layout.gap)
            let frameRect = CGRect(x: x, y: layout.size.height - yFromTop - tile.height,
                                   width: tile.width, height: tile.height)
            let captionRect = CGRect(x: x, y: frameRect.minY - layout.captionHeight,
                                     width: tile.width, height: layout.captionHeight)

            // Aspect-fit the frame inside its cell.
            let imageAspect = CGFloat(frame.0.width) / CGFloat(max(1, frame.0.height))
            var drawRect = frameRect
            if imageAspect > frameRect.width / frameRect.height {
                drawRect.size.height = frameRect.width / imageAspect
                drawRect.origin.y = frameRect.midY - drawRect.height / 2
            } else {
                drawRect.size.width = frameRect.height * imageAspect
                drawRect.origin.x = frameRect.midX - drawRect.width / 2
            }
            ctx.draw(frame.0, in: drawRect)

            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(captionRect)
            let attributed = NSAttributedString(string: frame.1, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): white,
            ])
            let line = CTLineCreateWithAttributedString(attributed)
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            ctx.saveGState()
            ctx.clip(to: captionRect)
            ctx.textMatrix = .identity
            ctx.textPosition = CGPoint(
                x: captionRect.minX + layout.fontSize * 0.5,
                y: captionRect.midY - (ascent - descent) / 2
            )
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }

    // MARK: - Tools: recording (bridged to the GUI instance)
    //
    // This --mcp process is headless — recording happens in the GUI app, which
    // shares this sandbox container. Commands go through
    // Automation/command.json and outcomes come back via status.json (see
    // AutomationBridge). The GUI is launched on demand; recording is always
    // visible there (panel + countdown), never silent.

    private static var automationStatusURL: URL {
        AutomationBridge.automationDirectory.appendingPathComponent("status.json")
    }

    private static var automationCommandURL: URL {
        AutomationBridge.automationDirectory.appendingPathComponent("command.json")
    }

    private static func readAutomationStatus() -> [String: Any]? {
        guard let data = try? Data(contentsOf: automationStatusURL) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func sendCommand(_ command: String, nonce: String, params: [String: String]) throws {
        let payload: [String: Any] = ["command": command, "nonce": nonce, "params": params]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let dir = AutomationBridge.automationDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".command.json.tmp-\(getpid())")
        try data.write(to: tmp)
        _ = try FileManager.default.replaceItemAt(automationCommandURL, withItemAt: tmp)
    }

    /// Blocks until status.json carries our nonce and an accepted state.
    private static func awaitStatus(
        nonce: String, accept: Set<String>, timeout: TimeInterval
    ) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let status = readAutomationStatus(), status["nonce"] as? String == nonce,
               let state = status["state"] as? String {
                if accept.contains(state) { return status }
                if state == "failed" {
                    throw ToolError((status["error"] as? String) ?? "recording command failed")
                }
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw ToolError("timed out waiting for the CaptureCat app to respond — is it running and responsive?")
    }

    /// Launch the GUI instance if needed and wait until its AutomationBridge
    /// is up. LaunchServices would treat THIS headless process as "the app",
    /// so a fresh GUI needs createsNewApplicationInstance.
    private static func ensureGUIReady() throws {
        let bundleID = Bundle.main.bundleIdentifier ?? "so.capturecat.CaptureCat"
        func hasGUI() -> Bool {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .contains { $0.activationPolicy == .regular }
        }
        if hasGUI() { return }

        log("no GUI instance running — launching one")
        let launchStart = Date()
        let semaphore = DispatchSemaphore(value: 0)
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.activates = false
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, error in
            if let error { log("GUI launch error: \(error.localizedDescription)") }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 15)

        // The bridge clears stale commands on startup, then writes an "idle"
        // status — only a status written after our launch proves it's live.
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            if hasGUI(),
               let mtime = (try? FileManager.default.attributesOfItem(
                atPath: automationStatusURL.path))?[.modificationDate] as? Date,
               mtime > launchStart.addingTimeInterval(-1) {
                return
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        throw ToolError("the CaptureCat app did not become ready — open CaptureCat manually and retry")
    }

    private static func listCaptureTargets() throws -> [String: Any] {
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<SCShareableContent, Error> = .failure(ToolError("shareable content unavailable"))
        Task {
            do {
                outcome = .success(try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true))
            } catch {
                outcome = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()

        guard case .success(let content) = outcome else {
            if case .failure(let error) = outcome {
                throw ToolError("cannot enumerate capture targets (\(error.localizedDescription)) — "
                    + "grant Screen Recording permission to CaptureCat (and to the terminal hosting "
                    + "this MCP server) in System Settings > Privacy & Security")
            }
            throw ToolError("cannot enumerate capture targets")
        }

        let myPID = ProcessInfo.processInfo.processIdentifier
        let windows = content.windows
            .filter { $0.frame.width > 100 && $0.frame.height > 100 }
            .filter { $0.owningApplication?.processID != myPID }
            .sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
            .prefix(40)
            .map { window -> [String: Any] in
                [
                    "app": window.owningApplication?.applicationName ?? "",
                    "title": window.title ?? "",
                    "width": Int(window.frame.width),
                    "height": Int(window.frame.height),
                ]
            }
        return [
            "displays": content.displays.enumerated().map { index, display in
                ["index": index, "width": display.width, "height": display.height] as [String: Any]
            },
            "windows": Array(windows),
        ]
    }

    private static func startRecording(_ arguments: [String: Any]) throws -> [String: Any] {
        let source = arguments["source"] as? String ?? "display"
        guard ["display", "window", "chrome", "safari"].contains(source) else {
            throw ToolError("source must be display | window | chrome | safari")
        }
        try ensureGUIReady()

        if let status = readAutomationStatus(),
           ["preparing", "recording", "stopping"].contains(status["state"] as? String ?? "") {
            throw ToolError("a recording is already in progress — stop_recording first")
        }

        // Optionally open a page first so it's front and loaded when capture
        // begins — routed to the browser being recorded, not the default one.
        if let urlString = arguments["url"] as? String {
            guard let url = URL(string: urlString), ["http", "https"].contains(url.scheme ?? "") else {
                throw ToolError("url must be an http(s) URL")
            }
            openURL(url, preferring: source)
            Thread.sleep(forTimeInterval: 1.5)
        }

        var params: [String: String] = [
            "source": source,
            "audio": (arguments["audio"] as? Bool ?? true) ? "true" : "false",
        ]
        if let display = arguments["display"] as? Int { params["display"] = String(display) }
        if let app = arguments["app"] as? String { params["app"] = app }
        if let title = arguments["title"] as? String { params["title"] = title }

        let nonce = UUID().uuidString
        try sendCommand("start-recording", nonce: nonce, params: params)
        // Generous timeout: the bridge may still be launching the target
        // browser (up to 10s) and always runs the 3-2-1 countdown.
        _ = try awaitStatus(nonce: nonce, accept: ["recording"], timeout: 90)
        return [
            "status": "recording",
            "source": source,
            "note": "Capture is live (the on-screen countdown has finished). Perform the actions to "
                + "demonstrate — deliberately, pausing ~1s after each important click — then call "
                + "stop_recording to get the project id.",
        ]
    }

    private static func stopRecording(_ arguments: [String: Any]) throws -> [String: Any] {
        guard readAutomationStatus() != nil else {
            throw ToolError("no recording session found — start_recording first")
        }
        let nonce = UUID().uuidString
        try sendCommand("stop-recording", nonce: nonce, params: [:])
        // Finalize can stitch segments and probe durations — allow a while.
        let status = try awaitStatus(nonce: nonce, accept: ["finished"], timeout: 120)
        var result: [String: Any] = [
            "projectId": status["projectId"] ?? "",
            "projectName": status["projectName"] ?? "",
            "duration": status["duration"] ?? 0,
            "note": "Recording saved. Next: describe_project (click clusters + pacing), plan, apply_edits "
                + "(set_trim, auto_zoom/add_effect, set_speed, annotations) in one batch, render_frames "
                + "layout contact_sheet to verify, then export_project.",
        ]
        if let warning = guiRunningWarning() { result["warning"] = warning }
        return result
    }

    private static func openURL(_ url: URL, preferring source: String) {
        let browserPath: String? = switch source {
        case "chrome": "/Applications/Google Chrome.app"
        case "safari": "/System/Applications/Safari.app"
        default: nil
        }
        let semaphore = DispatchSemaphore(value: 0)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        if let browserPath, FileManager.default.fileExists(atPath: browserPath) {
            NSWorkspace.shared.open(
                [url], withApplicationAt: URL(fileURLWithPath: browserPath), configuration: config
            ) { _, _ in semaphore.signal() }
        } else {
            NSWorkspace.shared.open(url, configuration: config) { _, _ in semaphore.signal() }
        }
        _ = semaphore.wait(timeout: .now() + 10)
    }
}
