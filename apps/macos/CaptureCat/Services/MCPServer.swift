import AppKit
import AVFoundation
import CryptoKit
import Foundation
import ScreenCaptureKit

/// MCP server mode: `CaptureCat --mcp` speaks Model Context Protocol over stdio —
/// newline-delimited JSON-RPC 2.0, no external runtime. This replaces the old
/// Node sidecar: tools operate directly on the app's own Codable models, so
/// validation is compile-time-true to what the app persists.
///
/// stdout purity is sacred in this mode: ONLY JSON-RPC lines are written to
/// stdout; all diagnostics go to stderr.
enum MCPServer {
    static let isMCP = CommandLine.arguments.contains("--mcp")

    private static let serverVersion = "0.2.0"
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
        // its libraries (e.g. the export engine's progress lines) can never
        // corrupt the protocol stream.
        let realStdout = dup(STDOUT_FILENO)
        if realStdout >= 0 {
            rpcOut = FileHandle(fileDescriptor: realStdout, closeOnDealloc: false)
            dup2(STDERR_FILENO, STDOUT_FILENO)
        }

        // Blocking stdin loop on its own thread; the main run loop stays free
        // for tool work that needs the main actor (export).
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

    private static func send(_ payload: [String: Any]) {
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

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("[capturecat-mcp] \(message)\n".utf8))
    }

    private static func reply(id: Any, result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func replyError(id: Any, code: Int, message: String) {
        send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
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
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "capturecat", "version": serverVersion],
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
            callTool(name: name, arguments: arguments, requestID: requestID)
        default:
            replyError(id: requestID, code: -32601, message: "method not found: \(method)")
        }
    }

    private static func callTool(name: String, arguments: [String: Any], requestID: Any) {
        do {
            let result: [String: Any]
            switch name {
            case "list_projects": result = try listProjects()
            case "list_notes": result = try listNotes()
            case "search_captures": result = try searchCaptures(arguments)
            case "describe_project": result = try describeProject(arguments)
            case "add_effect": result = try addEffect(arguments)
            case "update_effect": result = try updateEffect(arguments)
            case "remove_effect": result = try removeEffect(arguments)
            case "auto_zoom": result = try autoZoom(arguments)
            case "add_annotation": result = try addAnnotation(arguments)
            case "remove_annotation": result = try removeAnnotation(arguments)
            case "set_style": result = try setStyle(arguments)
            case "cut_video": result = try cutVideo(arguments)
            case "export_project": result = try exportProject(arguments)
            case "get_transcript": result = try getTranscript(arguments)
            case "render_frames":
                // Returns MIXED content (images + text), not a JSON blob —
                // reply directly instead of going through prettyJSON.
                let content = try renderFrames(arguments)
                reply(id: requestID, result: ["content": content, "isError": false])
                return
            case "list_capture_targets": result = try listCaptureTargets()
            case "start_recording": result = try startRecording(arguments)
            case "stop_recording": result = try stopRecording(arguments)
            default:
                replyError(id: requestID, code: -32602, message: "unknown tool: \(name)")
                return
            }
            let text = prettyJSON(result)
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

    private static func prettyJSON(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys]
              ) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Project IO (direct Codable, atomic writes, media never touched)

    private static var projectsRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CaptureCat/Projects", isDirectory: true)
    }

    private struct ToolError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
        init(_ message: String) { self.message = message }
    }

    /// Accepts a UUID under the projects root, a project folder path, or a
    /// direct project.json path (same contract as headless --export).
    private static func resolveProjectJSON(_ ref: String) throws -> URL {
        let fm = FileManager.default
        if let uuid = UUID(uuidString: ref) {
            let url = projectsRoot
                .appendingPathComponent(uuid.uuidString, isDirectory: true)
                .appendingPathComponent("project.json")
            guard fm.fileExists(atPath: url.path) else { throw ToolError("project not found: \(ref)") }
            return url
        }
        var url = URL(fileURLWithPath: (ref as NSString).expandingTildeInPath)
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ToolError("project not found: \(ref)")
        }
        if isDirectory.boolValue { url.appendPathComponent("project.json") }
        return url
    }

    private static func loadProject(_ ref: String) throws -> (url: URL, project: Project) {
        let url = try resolveProjectJSON(ref)
        let data = try Data(contentsOf: url)
        let project = try JSONDecoder().decode(Project.self, from: data)
        return (url, project)
    }

    /// Atomic write (temp + replace) with a .bak of the previous contents.
    private static func writeProject(_ project: Project, to file: URL) throws {
        let fm = FileManager.default
        let data = try JSONEncoder().encode(project)
        let bak = file.appendingPathExtension("bak")
        try? fm.removeItem(at: bak)
        try? fm.copyItem(at: file, to: bak)
        let tmp = file.deletingLastPathComponent()
            .appendingPathComponent(".project.json.tmp-\(getpid())")
        try data.write(to: tmp)
        _ = try fm.replaceItemAt(file, withItemAt: tmp)
    }

    /// Warn when the GUI is running. The GUI watches project.json for external
    /// edits and reloads clean projects (browser and open editor alike), so
    /// the only remaining clobber window is a project that is open in the
    /// editor WITH unsaved changes — there the in-app edits win.
    private static func guiRunningWarning() -> String? {
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: "so.capturecat.CaptureCat")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            .filter { $0.activationPolicy == .regular }
        guard !others.isEmpty else { return nil }
        return "CaptureCat is currently running — it picks this edit up automatically, "
            + "unless the project is open in the editor with unsaved changes, in which case "
            + "the in-app edits win and this edit may be overwritten."
    }

    private static func round3(_ value: Double) -> Double {
        (value * 1000).rounded() / 1000
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
        if let entries = try? fm.contentsOfDirectory(at: projectsRoot, includingPropertiesForKeys: nil) {
            for entry in entries {
                let file = entry.appendingPathComponent("project.json")
                guard let data = try? Data(contentsOf: file),
                      let project = try? decoder.decode(Project.self, from: data) else { continue }
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
            if let time = match.bestFrameTime { payload["bestFrameTime"] = round3(time) }
            return payload
        }
        return ["query": query, "results": results, "totalMatches": ranked.count]
    }

    // MARK: - Tool: describe_project

    private static func describeProject(_ arguments: [String: Any]) throws -> [String: Any] {
        guard let ref = arguments["id"] as? String else { throw ToolError("missing id") }
        let (url, project) = try loadProject(ref)
        let s = project.settings

        var result: [String: Any] = [
            "id": project.id.uuidString,
            "name": project.name,
            "duration": round3(project.duration),
            "trimStart": round3(project.trimStart),
            "trimEnd": round3(project.trimEnd),
            "recordingSourceKind": project.recordingSourceKind.rawValue,
            "clips": project.videoClipSegments.map {
                ["id": $0.id.uuidString, "start": round3($0.startTime), "end": round3($0.endTime)]
            },
            "splitPoints": project.splitPoints.map(round3),
            "effects": [
                "zoomRegions": project.zoomRegions.map {
                    [
                        "id": $0.id.uuidString,
                        "start": round3($0.startTime), "end": round3($0.endTime),
                        "zoomLevel": $0.zoomLevel,
                        "focalPoint": ["x": round3($0.focalPoint.x), "y": round3($0.focalPoint.y)],
                    ] as [String: Any]
                },
                "tiltRegions": project.tiltRegions.map {
                    [
                        "id": $0.id.uuidString,
                        "start": round3($0.startTime), "end": round3($0.endTime),
                        "pitch": $0.pitch, "yaw": $0.yaw, "roll": $0.roll,
                    ] as [String: Any]
                },
            ],
            "blurRegions": project.blurRegions.map {
                ["id": $0.id.uuidString, "start": round3($0.startTime), "end": round3($0.endTime)]
            },
            "highlightRegions": project.highlightRegions.map {
                ["id": $0.id.uuidString, "start": round3($0.startTime), "end": round3($0.endTime)]
            },
            "speedRegions": project.speedRegions.map {
                ["start": round3($0.startTime), "end": round3($0.endTime), "speed": $0.speed]
            },
            "settings": [
                "backgroundType": s.backgroundType.rawValue,
                "backgroundBlur": s.backgroundBlur,
                "backgroundBrightness": s.backgroundBrightness,
                "backgroundSaturation": s.backgroundSaturation,
                "backgroundTintOpacity": s.backgroundTintOpacity,
                "backgroundVignette": s.backgroundVignette,
                "backgroundPixelate": s.backgroundPixelate,
                "backgroundHalftone": s.backgroundHalftone,
                "backgroundNoise": s.backgroundNoise,
                "backgroundContrast": s.backgroundContrast,
                "backgroundHue": s.backgroundHue,
                "backgroundPadding": s.backgroundPadding,
                "videoPlacement": s.videoPlacement.rawValue,
                "cursorStyle": s.cursorStyle.rawValue,
                "cursorScale": s.cursorScale,
                "cursorTilt": s.cursorTilt,
                "cursorStretch": s.cursorStretch,
                "cursorDrag": s.cursorDrag,
                "cursorWeight": s.cursorWeight,
                "animationSpeed": s.animationSpeed.rawValue,
                "menuBarReplacement": s.menuBarReplacement.rawValue,
                "showDeviceFrame": s.showDeviceFrame,
                "showCamera": s.showCamera,
            ] as [String: Any],
        ]
        if let digest = interactionDigest(projectDir: url.deletingLastPathComponent(), project: project) {
            result["interactionDigest"] = digest
        }
        return result
    }

    /// Click clusters + idle spans from the recorded cursor stream — the
    /// evidence that lets an agent decide WHERE zooms belong. Mirrors the
    /// discrete-click collapse in ClickRippleOverlay plus a 2s cluster pass.
    private static func interactionDigest(projectDir: URL, project: Project) -> [String: Any]? {
        let fm = FileManager.default
        var cursorURL = projectDir.appendingPathComponent("cursor.json")
        if !fm.fileExists(atPath: cursorURL.path), let stored = project.cursorDataURL {
            cursorURL = stored
        }
        guard fm.fileExists(atPath: cursorURL.path),
              let recording = try? CursorTracker.loadRecording(from: cursorURL),
              !recording.events.isEmpty else { return nil }

        let events = recording.events
        let coordW = max(1, recording.coordinateWidth)
        let coordH = max(1, recording.coordinateHeight)

        // 1. Collapse mouse-down runs into discrete clicks; drop drags.
        let shortSide = min(coordW, coordH)
        let dragThreshold = max(10, min(24, shortSide * 0.006))
        var clicks: [CursorEvent] = []
        var runStart: CursorEvent?
        var maxDist: CGFloat = 0
        func finishRun() {
            if let start = runStart, maxDist <= dragThreshold { clicks.append(start) }
            runStart = nil
            maxDist = 0
        }
        for event in events {
            if event.isClick {
                if let start = runStart {
                    maxDist = max(maxDist, hypot(event.x - start.x, event.y - start.y))
                } else {
                    runStart = event
                    maxDist = 0
                }
            } else {
                finishRun()
            }
        }
        finishRun()

        // 2. Cluster clicks within 2s gaps.
        struct Cluster { var start, end: Double; var count: Int; var sumX, sumY: CGFloat }
        var clusters: [Cluster] = []
        for click in clicks {
            if var last = clusters.last, click.timestamp - last.end <= 2.0 {
                last.end = click.timestamp
                last.count += 1
                last.sumX += click.x
                last.sumY += click.y
                clusters[clusters.count - 1] = last
            } else {
                clusters.append(Cluster(
                    start: click.timestamp, end: click.timestamp,
                    count: 1, sumX: click.x, sumY: click.y
                ))
            }
        }

        // 3. Idle spans: >3s without meaningful movement or clicks.
        var idleSpans: [[String: Any]] = []
        var idleStart = events[0].timestamp
        var lastPos = events[0]
        for event in events {
            if hypot(event.x - lastPos.x, event.y - lastPos.y) > 5 || event.isClick {
                if event.timestamp - idleStart > 3.0 {
                    idleSpans.append(["start": round3(idleStart), "end": round3(event.timestamp)])
                }
                idleStart = event.timestamp
                lastPos = event
            }
        }
        if let last = events.last, last.timestamp - idleStart > 3.0 {
            idleSpans.append(["start": round3(idleStart), "end": round3(last.timestamp)])
        }

        return [
            "totalEvents": events.count,
            "coordinateSize": ["width": Double(coordW), "height": Double(coordH)],
            "clickClusters": clusters.map {
                [
                    "start": round3($0.start),
                    "end": round3($0.end),
                    "clickCount": $0.count,
                    "meanPosition": [
                        "x": round3(Double($0.sumX / CGFloat($0.count) / coordW)),
                        "y": round3(Double($0.sumY / CGFloat($0.count) / coordH)),
                    ],
                ] as [String: Any]
            },
            "idleSpans": idleSpans,
        ]
    }

    // MARK: - Tool: add_effect

    /// Patches the zoom/tilt regions whose span contains `at` (source-time
    /// seconds). Only supplied keys change.
    private static func updateEffect(_ arguments: [String: Any]) throws -> [String: Any] {
        guard let ref = arguments["id"] as? String else { throw ToolError("missing id") }
        guard let at = doubleValue(arguments["at"]) else {
            throw ToolError("'at' (a source-time inside the block) is required")
        }
        let (url, project) = try loadProject(ref)
        var touched: [String] = []

        if let index = project.zoomRegions.firstIndex(where: { at >= $0.startTime && at <= $0.endTime }) {
            if let v = doubleValue(arguments["zoomLevel"]) { project.zoomRegions[index].zoomLevel = min(6, max(0.3, v)) }
            if let x = doubleValue(arguments["focalX"]), let y = doubleValue(arguments["focalY"]) {
                project.zoomRegions[index].focalPoint = CGPoint(x: min(1, max(0, x)), y: min(1, max(0, y)))
            }
            if let s = doubleValue(arguments["start"]) { project.zoomRegions[index].startTime = max(0, s) }
            if let e = doubleValue(arguments["end"]) { project.zoomRegions[index].endTime = e }
            if let ox = doubleValue(arguments["offsetX"]) {
                project.zoomRegions[index].cardOffsetX = abs(ox) < 0.005 ? nil : ZoomFocalMath.clampCardOffset(ox)
            }
            if let oy = doubleValue(arguments["offsetY"]) {
                project.zoomRegions[index].cardOffsetY = abs(oy) < 0.005 ? nil : ZoomFocalMath.clampCardOffset(oy)
            }
            if let styleRaw = arguments["animationStyle"] as? String {
                guard let style = ZoomAnimationStyle(rawValue: styleRaw) else {
                    throw ToolError("invalid animationStyle: \(styleRaw) (allowed: "
                        + ZoomAnimationStyle.allCases.map(\.rawValue).joined(separator: ", ") + ", or omit for Default)")
                }
                project.zoomRegions[index].animationStyle = style
            }
            if let followsCursor = arguments["followsCursor"] as? Bool {
                // false = fixed focus (the block aims exactly at focalX/Y,
                // ignoring the recorded cursor); true/omit = default blend.
                project.zoomRegions[index].followsCursor = followsCursor ? nil : false
            }
            touched.append("zoom:\(project.zoomRegions[index].id.uuidString)")
        }
        if let index = project.tiltRegions.firstIndex(where: { at >= $0.startTime && at <= $0.endTime }) {
            if let v = doubleValue(arguments["pitch"]) { project.tiltRegions[index].pitch = min(60, max(-60, v)) }
            if let v = doubleValue(arguments["yaw"]) { project.tiltRegions[index].yaw = min(60, max(-60, v)) }
            if let v = doubleValue(arguments["roll"]) { project.tiltRegions[index].roll = min(30, max(-30, v)) }
            if let s = doubleValue(arguments["start"]) { project.tiltRegions[index].startTime = max(0, s) }
            if let e = doubleValue(arguments["end"]) { project.tiltRegions[index].endTime = e }
            if let styleRaw = arguments["animationStyle"] as? String,
               let style = ZoomAnimationStyle(rawValue: styleRaw) {
                project.tiltRegions[index].animationStyle = style
            }
            touched.append("tilt:\(project.tiltRegions[index].id.uuidString)")
        }
        guard !touched.isEmpty else {
            throw ToolError("no zoom/tilt region spans t=\(at)")
        }
        try writeProject(project, to: url)
        return ["updated": touched]
    }

    /// Removes the zoom/tilt regions whose span contains `at`.
    private static func removeEffect(_ arguments: [String: Any]) throws -> [String: Any] {
        guard let ref = arguments["id"] as? String else { throw ToolError("missing id") }
        guard let at = doubleValue(arguments["at"]) else {
            throw ToolError("'at' (a source-time inside the block) is required")
        }
        let (url, project) = try loadProject(ref)
        let zoomBefore = project.zoomRegions.count
        let tiltBefore = project.tiltRegions.count
        project.zoomRegions.removeAll { at >= $0.startTime && at <= $0.endTime }
        project.tiltRegions.removeAll { at >= $0.startTime && at <= $0.endTime }
        let removed = (zoomBefore - project.zoomRegions.count) + (tiltBefore - project.tiltRegions.count)
        guard removed > 0 else { throw ToolError("no zoom/tilt region spans t=\(at)") }
        try writeProject(project, to: url)
        return ["removed": removed]
    }

    /// Runs the SAME auto-zoom pipeline the app's ✨ menu uses (click
    /// clustering, context-aware depth, typing-follow) and writes the
    /// resulting zoom regions straight to disk — hands-off "make the boring
    /// zooms for me" for an agent.
    private static func autoZoom(_ arguments: [String: Any]) throws -> [String: Any] {
        guard let ref = arguments["id"] as? String else { throw ToolError("missing id") }
        let (url, project) = try loadProject(ref)

        // Image captures have no cursor data — route to Motion instead: the
        // four-corner cinematic tour, same regions the editor's Motion
        // entry generates. Earlier generated regions are
        // replaced; the user's manual blocks stay.
        if project.cursorDataURL == nil, project.isImageCapture {
            let created = StillMotionApplier.apply(to: project)
            guard created > 0 else {
                throw ToolError("could not compose a motion tour for this image")
            }
            try writeProject(project, to: url)
            var result: [String: Any] = ["created": created, "mode": "still-motion"]
            if let warning = guiRunningWarning() { result["warning"] = warning }
            return result
        }
        guard project.cursorDataURL != nil else {
            throw ToolError("project has no recorded cursor data to generate zooms from")
        }
        // Shared with the editor button and the record-stop hook: only
        // previously auto-generated regions are replaced; the user's manual
        // zoom blocks stay put and generation routes around them.
        let created = AutoZoomApplier.apply(
            to: project, zoomLevel: doubleValue(arguments["zoomLevel"]))
        guard created > 0 else {
            throw ToolError("no zoom-worthy activity found in the recorded cursor data")
        }
        try writeProject(project, to: url)
        var result: [String: Any] = ["created": created]
        if let warning = guiRunningWarning() { result["warning"] = warning }
        return result
    }

    // MARK: - Tool: add_annotation / remove_annotation

    private static func addAnnotation(_ arguments: [String: Any]) throws -> [String: Any] {
        guard let ref = arguments["id"] as? String else { throw ToolError("missing id") }
        guard let typeRaw = arguments["type"] as? String,
              let type = AnnotationType(rawValue: typeRaw), type != .drawing else {
            throw ToolError("type must be one of: "
                + AnnotationType.allCases.filter { $0 != .drawing }.map(\.rawValue).joined(separator: ", ")
                + " (drawing/freehand strokes are editor-only — not scriptable)")
        }
        guard let start = doubleValue(arguments["start"]),
              let end = doubleValue(arguments["end"]), end > start else {
            throw ToolError("start and end (seconds, end > start) are required")
        }
        let (url, project) = try loadProject(ref)

        var annotation = Annotation(type: type, startTime: start, endTime: end)
        if let x = doubleValue(arguments["x"]) { annotation.x = min(1, max(0, x)) }
        if let y = doubleValue(arguments["y"]) { annotation.y = min(1, max(0, y)) }
        if let ex = doubleValue(arguments["arrowEndX"]) { annotation.arrowEndX = min(1, max(0, ex)) }
        if let ey = doubleValue(arguments["arrowEndY"]) { annotation.arrowEndY = min(1, max(0, ey)) }
        if let text = arguments["text"] as? String { annotation.text = String(text.prefix(200)) }
        if let hex = arguments["color"] as? String {
            guard let parsed = CodableColor(hex: hex) else {
                throw ToolError("color must be a hex string, e.g. \"#FF3B30\"")
            }
            annotation.color = parsed
        }
        if let backdrop = doubleValue(arguments["backdropOpacity"]) {
            annotation.backdropOpacity = min(0.9, max(0, backdrop))
        }
        project.annotations.append(annotation)
        try writeProject(project, to: url)
        var result: [String: Any] = ["created": annotation.id.uuidString]
        if let warning = guiRunningWarning() { result["warning"] = warning }
        return result
    }

    private static func removeAnnotation(_ arguments: [String: Any]) throws -> [String: Any] {
        guard let ref = arguments["id"] as? String else { throw ToolError("missing id") }
        guard let idString = arguments["annotationId"] as? String, let annID = UUID(uuidString: idString) else {
            throw ToolError("annotationId must be a UUID string (from add_annotation's 'created')")
        }
        let (url, project) = try loadProject(ref)
        let before = project.annotations.count
        project.annotations.removeAll { $0.id == annID }
        guard project.annotations.count < before else { throw ToolError("no annotation with id \(idString)") }
        try writeProject(project, to: url)
        return ["removed": 1]
    }

    private static func addEffect(_ arguments: [String: Any]) throws -> [String: Any] {
        guard let ref = arguments["id"] as? String else { throw ToolError("missing id") }
        guard let type = arguments["type"] as? String,
              ["zoom", "tilt", "zoomtilt"].contains(type) else {
            throw ToolError("type must be zoom | tilt | zoomtilt")
        }
        guard let start = doubleValue(arguments["start"]),
              let end = doubleValue(arguments["end"]) else {
            throw ToolError("start and end (seconds) are required")
        }
        let (url, project) = try loadProject(ref)

        // Some projects persist duration 0 (metadata written before probe).
        let duration = project.duration > 0 ? project.duration : .infinity
        guard start >= 0, end > start, end <= duration + 0.001 else {
            throw ToolError("invalid span \(start)-\(end) for duration \(duration)")
        }

        // The app enforces a single no-overlap EFFECTS lane across zoom AND tilt.
        let epsilon = 0.0001
        let spans: [(start: Double, end: Double, kind: String, id: UUID)] =
            project.zoomRegions.map { ($0.startTime, $0.endTime, "zoom", $0.id) }
            + project.tiltRegions.map { ($0.startTime, $0.endTime, "tilt", $0.id) }
        for span in spans where start < span.end - epsilon && end > span.start + epsilon {
            throw ToolError(
                "span \(start)-\(end) overlaps existing \(span.kind) region \(span.id.uuidString) "
                + "(\(round3(span.start))-\(round3(span.end))) — the EFFECTS lane never overlaps. "
                + "Pick a free span or delete that region first."
            )
        }

        var style: ZoomAnimationStyle?
        if let styleRaw = arguments["animationStyle"] as? String {
            guard let parsed = ZoomAnimationStyle(rawValue: styleRaw) else {
                throw ToolError("invalid animationStyle: \(styleRaw) (allowed: "
                    + ZoomAnimationStyle.allCases.map(\.rawValue).joined(separator: ", ") + ", or omit for Default)")
            }
            style = parsed
        }

        var created: [[String: String]] = []
        if type == "zoom" || type == "zoomtilt" {
            let fx = doubleValue(arguments["focalX"]) ?? 0.5
            let fy = doubleValue(arguments["focalY"]) ?? 0.5
            var region = ZoomRegion(
                startTime: start,
                endTime: end,
                zoomLevel: doubleValue(arguments["zoomLevel"]) ?? 2.0,
                focalPoint: CGPoint(x: min(1, max(0, fx)), y: min(1, max(0, fy))),
                animationStyle: style
            )
            if let ox = doubleValue(arguments["offsetX"]) {
                region.cardOffsetX = abs(ox) < 0.005 ? nil : ZoomFocalMath.clampCardOffset(ox)
            }
            if let oy = doubleValue(arguments["offsetY"]) {
                region.cardOffsetY = abs(oy) < 0.005 ? nil : ZoomFocalMath.clampCardOffset(oy)
            }
            if let followsCursor = arguments["followsCursor"] as? Bool {
                region.followsCursor = followsCursor ? nil : false
            }
            project.zoomRegions.append(region)
            created.append(["type": "zoom", "id": region.id.uuidString])
        }
        if type == "tilt" || type == "zoomtilt" {
            let region = TiltRegion(
                startTime: start,
                endTime: end,
                pitch: doubleValue(arguments["pitch"]) ?? 20,
                yaw: doubleValue(arguments["yaw"]) ?? 0,
                roll: doubleValue(arguments["roll"]) ?? 0,
                animationStyle: style
            )
            project.tiltRegions.append(region)
            created.append(["type": "tilt", "id": region.id.uuidString])
        }

        try writeProject(project, to: url)
        var result: [String: Any] = ["created": created]
        if let warning = guiRunningWarning() { result["warning"] = warning }
        return result
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }

    // MARK: - Tool: set_style

    private static func setStyle(_ arguments: [String: Any]) throws -> [String: Any] {
        guard let ref = arguments["id"] as? String else { throw ToolError("missing id") }
        guard let patch = arguments["patch"] as? [String: Any], !patch.isEmpty else {
            throw ToolError("patch must be a non-empty object")
        }
        let (url, project) = try loadProject(ref)
        var applied: [String: Any] = [:]
        for (key, value) in patch {
            try applyStyle(key: key, value: value, to: project.settings)
            applied[key] = value
        }
        try writeProject(project, to: url)
        var result: [String: Any] = ["applied": applied]
        if let warning = guiRunningWarning() { result["warning"] = warning }
        return result
    }

    /// Whitelist validated against the REAL ProjectSettings enums/ranges —
    /// compile-time-true to what the app persists.
    private static func applyStyle(key: String, value: Any, to settings: ProjectSettings) throws {
        func enumValue<T: RawRepresentable & CaseIterable>(_ type: T.Type) throws -> T
        where T.RawValue == String {
            guard let raw = value as? String, let parsed = T(rawValue: raw) else {
                let allowed = T.allCases.map(\.rawValue).joined(separator: ", ")
                throw ToolError("invalid value for \(key): \(value) (allowed: \(allowed))")
            }
            return parsed
        }
        func number(_ range: ClosedRange<Double>) throws -> Double {
            guard let d = doubleValue(value), range.contains(d) else {
                throw ToolError("invalid value for \(key): \(value) (allowed: \(range))")
            }
            return d
        }
        func boolean() throws -> Bool {
            guard let b = value as? Bool else { throw ToolError("\(key) must be a boolean") }
            return b
        }
        func string(maxLength: Int) throws -> String {
            guard let s = value as? String, s.count <= maxLength else {
                throw ToolError("\(key) must be a string of at most \(maxLength) characters")
            }
            return s
        }
        func color() throws -> CodableColor {
            guard let hex = value as? String, let parsed = CodableColor(hex: hex) else {
                throw ToolError("\(key) must be a hex color string, e.g. \"#FF3B30\" or \"#FF3B30CC\" (RRGGBB or RRGGBBAA)")
            }
            return parsed
        }

        switch key {
        case "aspectRatio": settings.aspectRatio = try enumValue(AspectRatio.self)
        case "backgroundType": settings.backgroundType = try enumValue(ProjectSettings.BackgroundType.self)
        case "videoPlacement":
            settings.videoPlacement = try enumValue(ProjectSettings.VideoPlacement.self)
            settings.videoCustomX = nil
            settings.videoCustomY = nil
        case "frameShape": settings.frameShape = try enumValue(ProjectSettings.FrameShape.self)
        case "animationSpeed": settings.animationSpeed = try enumValue(ProjectSettings.AnimationSpeed.self)
        case "cursorStyle": settings.cursorStyle = try enumValue(ProjectSettings.CursorStyle.self)
        case "cameraPosition": settings.cameraPosition = try enumValue(ProjectSettings.CameraPosition.self)
        case "cameraShape": settings.cameraShape = try enumValue(ProjectSettings.CameraShape.self)
        case "cameraOrientation": settings.cameraOrientation = try enumValue(ProjectSettings.CameraOrientation.self)
        case "menuBarReplacement": settings.menuBarReplacement = try enumValue(ProjectSettings.MenuBarReplacement.self)
        case "menuBarTitleAlignment": settings.menuBarTitleAlignment = try enumValue(ProjectSettings.MenuBarTitleAlignment.self)
        case "backgroundPadding": settings.backgroundPadding = try number(0...300)
        case "cornerRadius": settings.cornerRadius = try number(0...20)
        case "windowCornerRadius": settings.windowCornerRadius = try number(0...20)
        case "shadowRadius": settings.shadowRadius = try number(0...60)
        case "shadowOpacity": settings.shadowOpacity = try number(0...1)
        case "gradientAngle": settings.gradientAngle = try number(0...360)
        case "backgroundBlur": settings.backgroundBlur = try number(0...1)
        case "backgroundBrightness": settings.backgroundBrightness = try number(-1...1)
        case "backgroundSaturation": settings.backgroundSaturation = try number(0...2)
        case "backgroundTintOpacity": settings.backgroundTintOpacity = try number(0...1)
        case "backgroundVignette": settings.backgroundVignette = try number(0...1)
        case "backgroundPixelate": settings.backgroundPixelate = try number(0...1)
        case "backgroundHalftone": settings.backgroundHalftone = try number(0...1)
        case "backgroundNoise": settings.backgroundNoise = try number(0...1)
        case "backgroundContrast": settings.backgroundContrast = try number(0.5...1.5)
        case "backgroundHue": settings.backgroundHue = try number(0...360)
        case "cursorScale": settings.cursorScale = try number(0.5...3)
        case "parallaxStrength": settings.parallaxStrength = try number(0...1)
        case "introSlideStyle": settings.introSlideStyle = try enumValue(IntroSlideStyle.self)
        case "introSlideDuration": settings.introSlideDuration = try number(0.3...3600)
        case "introSlideStart": settings.introSlideStart = try number(0...3600)
        case "introSlideBounce": settings.introSlideBounce = try number(0...1)
        case "introSlideSpeed": settings.introSlideSpeed = try number(1...4)
        case "curtainUnveilCorner": settings.curtainUnveilCorner = try enumValue(CurtainUnveilCorner.self)
        case "curtainUnveilDuration": settings.curtainUnveilDuration = try number(0.1...3600)
        case "curtainUnveilStart": settings.curtainUnveilStart = try number(0...3600)
        case "curtainLogoOpacity": settings.curtainLogoOpacity = try number(0...1)
        case "curtainLogoScale": settings.curtainLogoScale = try number(0.05...0.8)
        case "cursorTilt": settings.cursorTilt = try number(0...1)
        case "cursorStretch": settings.cursorStretch = try number(0...1)
        case "cursorDrag": settings.cursorDrag = try number(0...1)
        case "cursorWeight": settings.cursorWeight = try number(0.5...3)
        case "clickRippleSize": settings.clickRippleSize = try number(20...100)
        case "cameraSize": settings.cameraSize = try number(60...240)

        // Camera styling (FaceScreen-style bubble looks).
        case "cameraBrightness": settings.cameraBrightness = try number(-1...1)
        case "cameraContrast": settings.cameraContrast = try number(0.5...1.5)
        case "cameraSaturation": settings.cameraSaturation = try number(0...2)
        case "cameraHue": settings.cameraHue = try number(-180...180)
        case "cameraFilter": settings.cameraFilter = try enumValue(ProjectSettings.CameraFilterStyle.self)
        case "cameraRingLight": settings.cameraRingLight = try number(0...1)
        case "cameraCornerRadius": settings.cameraCornerRadius = try number(0...60)
        case "cameraBorderWidth": settings.cameraBorderWidth = try number(0...8)
        case "cameraBorderColor": settings.cameraBorderColor = try color()
        case "cameraOpacity": settings.cameraOpacity = try number(0.2...1)
        case "cameraTiltPitch": settings.cameraTiltPitch = try number(-25...25)
        case "cameraTiltYaw": settings.cameraTiltYaw = try number(-25...25)
        case "cameraTagText": settings.cameraTagText = try string(maxLength: 60)
        case "cameraTagSubtext": settings.cameraTagSubtext = try string(maxLength: 60)
        case "cameraTagFontName": settings.cameraTagFontName = try string(maxLength: 80)
        case "cameraTagTextColor": settings.cameraTagTextColor = try color()
        case "cameraTagBackgroundColor": settings.cameraTagBackgroundColor = try color()
        case "cameraTagPosition": settings.cameraTagPosition = try enumValue(ProjectSettings.CameraTagPosition.self)
        case "autoZoomLevel": settings.autoZoomLevel = try number(1.5...4)
        case "menuBarHeight": settings.menuBarHeight = try number(2...6)
        case "showCursor": settings.showCursor = try boolean()
        case "showClickRipple": settings.showClickRipple = try boolean()
        case "showCamera": settings.showCamera = try boolean()
        case "cameraMirrored": settings.cameraMirrored = try boolean()
        case "showDeviceFrame": settings.showDeviceFrame = try boolean()
        case "motionBlur": settings.motionBlur = try boolean()
        case "motionBlurStrength": settings.motionBlurStrength = try number(0...1)
        case "menuBarShowStatusIcons": settings.menuBarShowStatusIcons = try boolean()
        case "muteRecordedAudio": settings.muteRecordedAudio = try boolean()
        case "showSubtitles": settings.showSubtitles = try boolean()
        case "menuBarTitle": settings.menuBarTitle = try string(maxLength: 60)
        case "menuBarClock": settings.menuBarClock = try string(maxLength: 12)

        // Cursor dynamics — fluid movement, follow speed, end behavior.
        case "cursorFluidEnabled": settings.cursorFluidEnabled = try boolean()
        case "cursorTension": settings.cursorTension = try number(20...600)
        case "cursorFriction": settings.cursorFriction = try number(2...80)
        case "cursorMass": settings.cursorMass = try number(0.2...6)
        case "cameraFollowSpeed": settings.cameraFollowSpeed = try number(0...1)
        case "cursorLoopToStart":
            settings.cursorLoopToStart = try boolean()
            if settings.cursorLoopToStart { settings.cursorStopAtEnd = false }
        case "cursorStopAtEnd":
            settings.cursorStopAtEnd = try boolean()
            if settings.cursorStopAtEnd { settings.cursorLoopToStart = false }
        case "smoothCursor": settings.smoothCursor = try boolean()
        case "smoothingFactor": settings.smoothingFactor = try number(0.05...0.5)
        case "autoHideCursor": settings.autoHideCursor = try boolean()
        case "autoHideDelay": settings.autoHideDelay = try number(1...10)

        // Click / keyboard sound.
        case "clickSoundEnabled": settings.clickSoundEnabled = try boolean()
        case "clickSoundVolume": settings.clickSoundVolume = try number(0.1...1)
        case "clickSoundStyle": settings.clickSoundStyle = try enumValue(ClickSoundStyle.self)
        case "keySoundEnabled": settings.keySoundEnabled = try boolean()
        case "keySoundVolume": settings.keySoundVolume = try number(0.1...1)
        case "keySoundStyle": settings.keySoundStyle = try enumValue(KeySoundStyle.self)
        // Shortcut overlay.
        case "showKeystrokes": settings.showKeystrokes = try boolean()
        case "keystrokeOverlayScopeToRecordedApp":
            settings.keystrokeOverlayScopeToRecordedApp = try boolean()

        // Audio mix.
        case "systemAudioVolume": settings.systemAudioVolume = try number(0...1)
        case "microphoneVolume": settings.microphoneVolume = try number(0...1)
        case "voiceOverVolume": settings.voiceOverVolume = try number(0...1.5)

        // Screen tilt (global, zoomed-out mode — distinct from timeline tilt
        // blocks, which go through add_effect/update_effect).
        case "screenTiltMode": settings.screenTiltMode = try enumValue(ProjectSettings.ScreenTiltMode.self)
        case "screenTiltAngle": settings.screenTiltAngle = try number(-60...60)
        case "screenTiltYaw": settings.screenTiltYaw = try number(-60...60)
        case "screenTiltRoll": settings.screenTiltRoll = try number(-30...30)

        // Watermark / brand.
        case "showWatermark": settings.showWatermark = try boolean()
        case "watermarkOpacity": settings.watermarkOpacity = try number(0.1...1)
        case "watermarkSize": settings.watermarkSize = try number(40...400)
        case "watermarkX": settings.watermarkX = try number(0...1)
        case "watermarkY": settings.watermarkY = try number(0...1)

        // Subtitles.
        case "showSubtitles": settings.showSubtitles = try boolean()
        case "subtitleFontSize": settings.subtitleFontSize = try number(16...64)
        case "subtitlePosition": settings.subtitlePosition = try enumValue(ProjectSettings.SubtitlePosition.self)
        case "subtitleStyle": settings.subtitleStyle = try enumValue(ProjectSettings.SubtitleStyle.self)
        case "subtitleWeight": settings.subtitleWeight = try enumValue(ProjectSettings.SubtitleWeight.self)
        case "subtitleUppercase": settings.subtitleUppercase = try boolean()

        // Colors — hex strings, "#RRGGBB" or "#RRGGBBAA".
        case "gradientStartColor": settings.gradientStartColor = try color()
        case "gradientEndColor": settings.gradientEndColor = try color()
        case "solidColor": settings.solidColor = try color()
        case "backgroundTintColor": settings.backgroundTintColor = try color()
        case "clickRippleColor": settings.clickRippleColor = try color()
        case "curtainColor": settings.curtainColor = try color()
        case "curtainLogoTint": settings.curtainLogoTint = try color()

        default:
            throw ToolError("key not whitelisted: \(key)")
        }
    }

    // MARK: - Tool: cut_video

    /// Removes source-time ranges from the video lane — the exact write the
    /// editor's delete-clip performs (materialise `effectiveVideoClipSegments`,
    /// subtract, re-derive `splitPoints`). Deliberately NOT a ripple delete,
    /// matching TimelineViewController.deleteVideoClip: the span renders as
    /// background-only; nothing downstream is re-timed.
    private static func cutVideo(_ arguments: [String: Any]) throws -> [String: Any] {
        guard let ref = arguments["id"] as? String else { throw ToolError("missing id") }
        guard let rawRanges = arguments["ranges"] as? [[String: Any]], !rawRanges.isEmpty else {
            throw ToolError("ranges must be a non-empty array of {start, end} in SOURCE seconds "
                + "(get_transcript returns sourceStart/sourceEnd per segment)")
        }
        let ranges: [(start: Double, end: Double)] = try rawRanges.map { entry in
            guard let start = doubleValue(entry["start"]),
                  let end = doubleValue(entry["end"]), end > start, start >= 0 else {
                throw ToolError("each range needs start >= 0 and end > start (seconds)")
            }
            return (start, end)
        }
        let (url, project) = try loadProject(ref)

        // Mirror the editor's minimum-clip hygiene: ignore slivers < 0.05s.
        let minPiece = 0.05
        var clips = project.effectiveVideoClipSegments
        for range in ranges {
            clips = clips.flatMap { clip -> [VideoClipSegment] in
                guard range.end > clip.startTime + minPiece,
                      range.start < clip.endTime - minPiece else { return [clip] }
                var pieces: [VideoClipSegment] = []
                if range.start > clip.startTime + minPiece {
                    pieces.append(VideoClipSegment(startTime: clip.startTime, endTime: range.start))
                }
                if range.end < clip.endTime - minPiece {
                    pieces.append(VideoClipSegment(startTime: range.end, endTime: clip.endTime))
                }
                return pieces
            }
        }
        guard !clips.isEmpty else {
            throw ToolError("removing these ranges would leave no video at all — remove fewer ranges")
        }

        let removed = project.effectiveVideoClipSegments
            .reduce(0.0) { $0 + ($1.endTime - $1.startTime) }
            - clips.reduce(0.0) { $0 + ($1.endTime - $1.startTime) }
        // A range that misses every clip (already-cut span, past the trim,
        // or sub-0.1s sliver) must not report success — the caller would
        // tell the user footage was cut when nothing changed.
        guard removed > 0.001 else {
            throw ToolError("ranges removed nothing — they fall in already-cut spans, outside the "
                + "video lane, or are shorter than 0.1s. Check clip bounds via describe_project.")
        }
        project.videoClipSegments = clips
        project.splitPoints = clips.dropFirst().map(\.startTime).sorted()
        try writeProject(project, to: url)

        var result: [String: Any] = [
            "clips": clips.map { ["start": round3($0.startTime), "end": round3($0.endTime)] },
            "removedSeconds": round3(removed),
            "note": "The removed spans show the background only (no ripple) — check with render_frames.",
        ]
        if let warning = guiRunningWarning() { result["warning"] = warning }
        return result
    }

    // MARK: - Tool: export_project

    private static func exportProject(_ arguments: [String: Any]) throws -> [String: Any] {
        guard let ref = arguments["id"] as? String else { throw ToolError("missing id") }
        guard let output = arguments["output"] as? String else { throw ToolError("missing output") }

        // Export runs the signed-in entitlement check (AuthService reads the
        // session straight out of the Keychain — no SDK bootstrap needed, and
        // its logs go through os_log, not stdout, which JSON-RPC owns).

        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<(url: URL, note: String?), Error> = .failure(ToolError("export did not run"))
        Task { @MainActor in
            do {
                let result = try await HeadlessRunner.performExport(
                    ref: ref,
                    outputPath: output,
                    progress: { percent in log("export progress \(percent)%") }
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

    // MARK: - Tools: agent vision (render_frames) + transcript

    /// Timed speech segments in OUTPUT time — same payload the share page's
    /// transcript uses, so agent context and viewer context can't drift.
    private static func getTranscript(_ arguments: [String: Any]) throws -> [String: Any] {
        guard let ref = arguments["id"] as? String else { throw ToolError("missing id") }
        let (_, project) = try loadProject(ref)
        let segments = ShareIntelligence.transcriptPayload(for: project, includeSourceTimes: true)
        return [
            "segments": segments,
            "count": segments.count,
            "note": segments.isEmpty
                ? "No transcript — the project has no subtitle segments (generate captions in the editor first)."
                : "start/end (and words[].start/end) are OUTPUT seconds, the same clock render_frames "
                    + "and effects use. sourceStart/sourceEnd are ORIGINAL-RECORDING seconds — pass those "
                    + "to cut_video to remove a segment's footage.",
        ]
    }

    /// The agent's EYES: exact frames of the final render. Renders through the
    /// real exporter (preview==export is gate-enforced, so there is no lesser
    /// "preview quality" to accidentally serve) and caches the render keyed on
    /// the project file's bytes — any edit re-renders, repeat looks are free.
    private static func renderFrames(_ arguments: [String: Any]) throws -> [[String: Any]] {
        guard let ref = arguments["id"] as? String else { throw ToolError("missing id") }
        guard let rawTimes = arguments["times"] as? [Any], !rawTimes.isEmpty else {
            throw ToolError("missing times")
        }
        let times = rawTimes.compactMap { ($0 as? NSNumber)?.doubleValue }
        guard !times.isEmpty else { throw ToolError("times must be numbers") }
        guard times.count <= 8 else { throw ToolError("max 8 times per call") }
        let maxWidth = min(1600, max(100, (arguments["maxWidth"] as? NSNumber)?.doubleValue ?? 800))

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
            let semaphore = DispatchSemaphore(value: 0)
            var outcome: Result<URL, Error> = .failure(ToolError("render did not run"))
            Task { @MainActor in
                do {
                    let result = try await HeadlessRunner.performExport(
                        ref: ref,
                        outputPath: cached.path,
                        progress: { percent in log("render_frames export \(percent)%") }
                    )
                    outcome = .success(result.url)
                } catch {
                    outcome = .failure(error)
                }
                semaphore.signal()
            }
            semaphore.wait()
            let actual = try outcome.get()
            // Sandbox fallback: performExport may have written elsewhere.
            if actual.path != cached.path {
                try? FileManager.default.removeItem(at: cached)
                try FileManager.default.copyItem(at: actual, to: cached)
            }
        }

        let asset = AVURLAsset(url: cached)
        let durationSemaphore = DispatchSemaphore(value: 0)
        var duration: Double = 0
        Task {
            duration = (try? await asset.load(.duration).seconds) ?? 0
            durationSemaphore.signal()
        }
        durationSemaphore.wait()

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: maxWidth, height: maxWidth)

        var content: [[String: Any]] = [[
            "type": "text",
            "text": prettyJSON([
                "render": freshlyRendered ? "fresh export" : "cached export",
                "durationSeconds": (duration * 100).rounded() / 100,
                "frames": times.count,
            ]),
        ]]
        for t in times {
            let clamped = max(0, min(t, max(0, duration - 0.001)))
            let requested = CMTime(seconds: clamped, preferredTimescale: 600)
            var actualTime = CMTime.zero
            let cgImage = try generator.copyCGImage(at: requested, actualTime: &actualTime)
            let rep = NSBitmapImageRep(cgImage: cgImage)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                throw ToolError("PNG encode failed at t=\(clamped)")
            }
            content.append([
                "type": "text",
                "text": String(format: "frame at t=%.2fs:", CMTimeGetSeconds(actualTime)),
            ])
            content.append([
                "type": "image",
                "data": png.base64EncodedString(),
                "mimeType": "image/png",
            ])
        }
        return content
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
                + "demonstrate, then call stop_recording to get the project id.",
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
            "note": "Recording saved. Next: describe_project for the interactionDigest, auto_zoom or "
                + "add_effect for zooms, add_annotation for callouts, then export_project.",
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

    // MARK: - Tool definitions (schemas match the former Node server)

    private static let toolDefinitions: [[String: Any]] = [
        [
            "name": "list_capture_targets",
            "description": "List recordable displays and on-screen windows (app name, title, size). "
                + "Use it to pick a start_recording target, e.g. the browser window showing the page "
                + "you want to demonstrate.",
            "inputSchema": ["type": "object", "properties": [String: Any](), "required": [String]()],
        ],
        [
            "name": "start_recording",
            "description": "Start a screen recording in the CaptureCat app (launched automatically if "
                + "needed — recording is always visible: floating panel + 3-2-1 countdown). source "
                + "'chrome'/'safari' records that browser's window, launching the browser if needed; "
                + "'window' matches by app/title; 'display' records a whole screen. Optional 'url' "
                + "opens a page in the target browser first. Returns once capture is live: then drive "
                + "the screen (e.g. via your browser tools) to demonstrate, and call stop_recording.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "source": ["type": "string", "enum": ["display", "window", "chrome", "safari"],
                        "description": "Default display."],
                    "display": ["type": "integer", "minimum": 0, "description": "Display index (source=display)."],
                    "app": ["type": "string", "description": "Owning app name to match (source=window)."],
                    "title": ["type": "string", "description": "Window title substring to match (source=window)."],
                    "url": ["type": "string", "description": "http(s) page to open in the target browser before capture."],
                    "audio": ["type": "boolean", "description": "Capture system audio. Default true."],
                ],
                "required": [String](),
            ],
        ],
        [
            "name": "stop_recording",
            "description": "Stop the in-progress recording, wait for it to be saved, and return the new "
                + "projectId — feed it to describe_project / auto_zoom / add_annotation / export_project.",
            "inputSchema": ["type": "object", "properties": [String: Any](), "required": [String]()],
        ],
        [
            "name": "list_projects",
            "description": "List all CaptureCat screen-recording projects (id, name, createdAt, duration, kind, "
                + "reminderDate when set).",
            "inputSchema": ["type": "object", "properties": [String: Any](), "required": [String]()],
        ],
        [
            "name": "list_notes",
            "description": "List all CaptureCat text captures (notes) — id, title, full text, source app, "
                + "createdAt, reminderDate when set. Notes are created via the macOS Services menu "
                + "(highlight text → Services → Capture Text in CaptureCat) or File → New Note from Clipboard.",
            "inputSchema": ["type": "object", "properties": [String: Any](), "required": [String]()],
        ],
        [
            "name": "search_captures",
            "description": "Search captures by what's VISIBLE in them (on-device OCR index) plus "
                + "titles and note text. Tokens AND-match case/diacritic-insensitively ('stripe "
                + "invoice' finds captures showing both words). Returns ranked matches — title "
                + "matches first, then text matches by hit count — with a context snippet and, for "
                + "videos, the frame time of the best hit (feed it to render_frames to see it).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Search terms, e.g. 'whatsapp joshua'"],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 50,
                        "description": "Max results, default 20."],
                ],
                "required": ["query"],
            ],
        ],
        [
            "name": "describe_project",
            "description": "Full timeline + style summary of a project, including an interactionDigest "
                + "(click clusters with normalized positions, idle spans) computed from the recorded "
                + "cursor data — use it to decide WHERE zooms/effects belong.",
            "inputSchema": [
                "type": "object",
                "properties": ["id": ["type": "string", "description": "Project UUID or path"]],
                "required": ["id"],
            ],
        ],
        [
            "name": "update_effect",
            "description": "Patch the zoom/tilt block containing source-time 'at': any of zoomLevel, "
                + "focalX+focalY, pitch, yaw, roll, start, end, animationStyle, offsetX+offsetY, "
                + "followsCursor. Only supplied keys change.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string"],
                    "at": ["type": "number", "minimum": 0],
                    "zoomLevel": ["type": "number", "minimum": 0.3, "maximum": 6,
                        "description": "Below 1.0 is a scale-DOWN effect, not a zoom-in."],
                    "focalX": ["type": "number", "minimum": 0, "maximum": 1],
                    "focalY": ["type": "number", "minimum": 0, "maximum": 1],
                    "pitch": ["type": "number", "minimum": -60, "maximum": 60],
                    "yaw": ["type": "number", "minimum": -60, "maximum": 60],
                    "roll": ["type": "number", "minimum": -30, "maximum": 30],
                    "start": ["type": "number", "minimum": 0],
                    "end": ["type": "number", "exclusiveMinimum": 0],
                    "animationStyle": ["type": "string", "enum": ["Instant", "Snappy", "Smooth", "Slow Glide", "Cinematic"]],
                    "offsetX": ["type": "number", "minimum": -1.5, "maximum": 1.5,
                        "description": "Card position excursion during the block, canvas fractions."],
                    "offsetY": ["type": "number", "minimum": -1.5, "maximum": 1.5],
                    "followsCursor": ["type": "boolean",
                        "description": "false = fixed focus: the block aims exactly at focalX/Y and ignores the recorded cursor. true/omit = default cursor blend at high zoom."],
                ],
                "required": ["id", "at"],
            ],
        ], [
            "name": "remove_effect",
            "description": "Remove the zoom/tilt block containing source-time 'at'.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string"],
                    "at": ["type": "number", "minimum": 0],
                ],
                "required": ["id", "at"],
            ],
        ], [
            "name": "add_effect",
            "description": "Add an effect block to the timeline. type 'zoom' (zoomLevel, default 2.0 — "
                + "below 1.0 is a scale-down effect), 'tilt' (pitch/yaw/roll, defaults 20/0/0), or "
                + "'zoomtilt' for a linked block with both. Spans may NEVER overlap existing zoom/tilt "
                + "regions — the app enforces a single effects lane. Times are source-time seconds.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string"],
                    "type": ["type": "string", "enum": ["zoom", "tilt", "zoomtilt"]],
                    "start": ["type": "number", "minimum": 0],
                    "end": ["type": "number", "exclusiveMinimum": 0],
                    "zoomLevel": ["type": "number", "minimum": 0.3, "maximum": 6],
                    "focalX": ["type": "number", "minimum": 0, "maximum": 1, "description": "Zoom aim point, default 0.5 (centre)."],
                    "focalY": ["type": "number", "minimum": 0, "maximum": 1],
                    "pitch": ["type": "number", "minimum": -45, "maximum": 45],
                    "yaw": ["type": "number", "minimum": -45, "maximum": 45],
                    "roll": ["type": "number", "minimum": -30, "maximum": 30],
                    "animationStyle": ["type": "string", "enum": ["Instant", "Snappy", "Smooth", "Slow Glide", "Cinematic"],
                        "description": "Applies to whichever of zoom/tilt is created."],
                    "offsetX": ["type": "number", "minimum": -1.5, "maximum": 1.5,
                        "description": "Zoom-only: card position excursion during the block."],
                    "offsetY": ["type": "number", "minimum": -1.5, "maximum": 1.5],
                    "followsCursor": ["type": "boolean", "description": "Zoom-only: false = fixed focus at focalX/Y."],
                ],
                "required": ["id", "type", "start", "end"],
            ],
        ],
        [
            "name": "auto_zoom",
            "description": "Runs the app's real auto-zoom pipeline: clusters recorded clicks, picks a "
                + "context-aware depth per cluster (tight cluster = deeper zoom, spread-out = gentler), "
                + "and extends zooms through typing bursts using recorded keystroke timing. Replaces "
                + "previously auto-generated regions only — the user's manual zoom blocks stay and "
                + "generation routes around them. Requires the project to have recorded cursor data. "
                + "For image (still) captures it instead composes Motion — a cinematic four-corner "
                + "camera tour over the screenshot — as ordinary editable "
                + "zoom/tilt regions.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string"],
                    "zoomLevel": ["type": "number", "minimum": 1.5, "maximum": 4,
                        "description": "Base depth before per-cluster adjustment; default is the project's Zoom Level setting."],
                ],
                "required": ["id"],
            ],
        ],
        [
            "name": "add_annotation",
            "description": "Add an on-screen annotation: text, arrow, callout, rectangle, ellipse, or "
                + "tap (looping touch-ripple indicator for iPhone/iPad takes). Freehand drawing strokes "
                + "are editor-only and not scriptable. Coordinates are normalized 0…1 in video space, "
                + "Y-down.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string"],
                    "type": ["type": "string", "enum": ["text", "arrow", "callout", "rectangle", "ellipse", "tap"]],
                    "start": ["type": "number", "minimum": 0],
                    "end": ["type": "number", "exclusiveMinimum": 0],
                    "x": ["type": "number", "minimum": 0, "maximum": 1,
                        "description": "Text: label centre. Arrow: tail. Rectangle/ellipse: one corner."],
                    "y": ["type": "number", "minimum": 0, "maximum": 1],
                    "arrowEndX": ["type": "number", "minimum": 0, "maximum": 1,
                        "description": "Arrow: head point. Rectangle/ellipse: opposite corner. Ignored for text/tap."],
                    "arrowEndY": ["type": "number", "minimum": 0, "maximum": 1],
                    "text": ["type": "string", "description": "For text/callout, max 200 chars."],
                    "color": ["type": "string", "description": "Hex, e.g. \"#FF3B30\" — text/arrow/shape color."],
                    "backdropOpacity": ["type": "number", "minimum": 0, "maximum": 0.9,
                        "description": "Spotlight: dims everything outside this annotation. 0 = off."],
                ],
                "required": ["id", "type", "start", "end"],
            ],
        ],
        [
            "name": "remove_annotation",
            "description": "Remove an annotation by id (the 'created' value from add_annotation).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string"],
                    "annotationId": ["type": "string"],
                ],
                "required": ["id", "annotationId"],
            ],
        ],
        [
            "name": "set_style",
            "description": "Patch whitelisted project settings: background, frame, cursor (style/size/"
                + "fluid movement/loop-to-start/stop-at-end/auto-hide), camera, menu bar, motion "
                + "(speed/parallax/follow speed/slide/motion blur), click + keyboard sound, shortcut "
                + "overlay (showKeystrokes, keystrokeOverlayScopeToRecordedApp — window recordings "
                + "only show shortcuts sent to the recorded app), audio "
                + "volumes, screen tilt, watermark, subtitles, canvas aspectRatio (\"Auto\", "
                + "\"16:9\", \"4:3\", \"1:1\", \"9:16\", \"21:9\", \"4:5\" — 9:16/4:5 for vertical "
                + "social exports), and colors (hex strings). Enum keys "
                + "accept their exact display raw values (e.g. menuBarReplacement: \"Clean Dark\"). "
                + "Unknown keys are rejected.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string"],
                    "patch": ["type": "object", "description": "Partial settings; unknown keys rejected"],
                ],
                "required": ["id", "patch"],
            ],
        ],
        [
            "name": "export_project",
            "description": "Export a project to an mp4 in-process. Blocks until finished. The app is "
                + "sandboxed: if the requested path isn't writable, the result's `path` is inside the "
                + "app container and `moved` is false — copy it to the destination yourself.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string"],
                    "output": ["type": "string", "description": "Absolute destination path for the mp4"],
                ],
                "required": ["id", "output"],
            ],
        ],
        [
            "name": "render_frames",
            "description": "SEE the video: returns PNG images of the FINAL RENDER at the given "
                + "output-times — every effect, zoom, cursor, annotation and style exactly as an "
                + "export would ship them (it renders through the real exporter and caches the "
                + "result per edit-state). Use it as your eyes: render before/after edits, judge, "
                + "adjust, re-render. First call after an edit re-renders the project (slow, "
                + "roughly realtime); repeat calls at other times are instant.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string"],
                    "times": [
                        "type": "array", "items": ["type": "number"],
                        "description": "Output-video timestamps in seconds (max 8 per call)",
                    ],
                    "maxWidth": [
                        "type": "number",
                        "description": "Longest image edge in pixels, 100–1600 (default 800)",
                    ],
                ],
                "required": ["id", "times"],
            ],
        ],
        [
            "name": "get_transcript",
            "description": "Timed transcript of the project's speech (on-device captions). Segment "
                + "start/end and per-word timings ('words') are OUTPUT time — the same clock "
                + "render_frames and effects use. Each segment also carries sourceStart/sourceEnd "
                + "in original-recording seconds for cut_video. Use it to find the moments worth "
                + "zooming, annotating, chaptering — or cutting.",
            "inputSchema": [
                "type": "object",
                "properties": ["id": ["type": "string"]],
                "required": ["id"],
            ],
        ],
        [
            "name": "cut_video",
            "description": "Remove SOURCE-time ranges of footage from the video lane (e.g. a "
                + "flubbed sentence — get the range from get_transcript's sourceStart/sourceEnd). "
                + "Same operation as deleting a sliced clip in the editor: the footage is lifted "
                + "out and the span shows the background only; the timeline is NOT rippled shorter. "
                + "Verify with render_frames.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string"],
                    "ranges": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "start": ["type": "number", "minimum": 0],
                                "end": ["type": "number", "exclusiveMinimum": 0],
                            ],
                            "required": ["start", "end"],
                        ],
                        "description": "Source-time ranges (seconds) to remove, end > start each.",
                    ],
                ],
                "required": ["id", "ranges"],
            ],
        ],
    ]
}
