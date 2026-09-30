import AppKit
import Foundation

/// Mutating MCP tools as PURE cores: `(project, args) throws -> result`.
/// No load, no write — a single tool is load → core → commit, and
/// `apply_edits` runs any number of cores against ONE in-memory project and
/// commits once, so a batch validates exactly like the individual tools.
///
/// Every time in here is SOURCE seconds (original-recording time), the clock
/// the model, the preview and the exporter all key effects on.
extension MCPServer {
    typealias EditCore = (Project, [String: Any]) throws -> [String: Any]

    /// Batchable ops, in schema order.
    static let editOpNames: [String] = [
        "add_effect", "update_effect", "remove_effect", "auto_zoom",
        "add_annotation", "update_annotation", "remove_annotation",
        "add_blur", "remove_blur",
        "set_speed", "remove_speed", "set_trim", "cut_video",
        "set_style",
    ]

    static let editOps: [String: EditCore] = [
        "add_effect": opAddEffect,
        "update_effect": opUpdateEffect,
        "remove_effect": opRemoveEffect,
        "auto_zoom": opAutoZoom,
        "add_annotation": opAddAnnotation,
        "update_annotation": opUpdateAnnotation,
        "remove_annotation": opRemoveAnnotation,
        "add_blur": opAddBlur,
        "remove_blur": opRemoveBlur,
        "set_speed": opSetSpeed,
        "remove_speed": opRemoveSpeed,
        "set_trim": opSetTrim,
        "cut_video": opCutVideo,
        "set_style": opSetStyle,
    ]

    // MARK: - Runners

    /// A single mutating tool: load → core → commit (history + .bak + atomic).
    static func runSingleEdit(name: String, core: EditCore, arguments: [String: Any]) throws -> [String: Any] {
        let ref = try requireProjectRef(arguments)
        let (url, project) = try loadProject(ref)
        var result = try core(project, arguments)
        let extras = try commitEdit(project, to: url, tool: name, summary: name)
        result.merge(extras) { current, _ in current }
        return result
    }

    /// Ordered ops against ONE in-memory project, written once. Any failure
    /// throws before the write, so the file is untouched (all-or-nothing).
    static func applyEdits(_ arguments: [String: Any]) throws -> [String: Any] {
        let ref = try requireProjectRef(arguments)
        guard let rawOps = arguments["ops"] as? [Any], !rawOps.isEmpty else {
            throw ToolError("ops must be a non-empty array of {op, args} — e.g. "
                + "[{\"op\": \"add_effect\", \"args\": {\"type\": \"zoom\", \"start\": 2, \"end\": 5}}]")
        }
        guard rawOps.count <= 200 else {
            throw ToolError("at most 200 ops per apply_edits call (got \(rawOps.count)) — split the batch")
        }
        let (url, project) = try loadProject(ref)
        let outputBefore = outputDuration(of: project)

        var results: [[String: Any]] = []
        var names: [String] = []
        for (index, raw) in rawOps.enumerated() {
            guard let entry = raw as? [String: Any], let name = entry["op"] as? String else {
                throw ToolError("apply_edits: ops[\(index)] must be an object {\"op\": <tool name>, "
                    + "\"args\": {...}}. Nothing was written.")
            }
            guard let core = editOps[name] else {
                throw ToolError("apply_edits: ops[\(index)] op '\(name)' is not batchable (allowed: "
                    + editOpNames.joined(separator: ", ") + "). Nothing was written.")
            }
            // `args` is the tool's own arguments minus `id`; a flat
            // {op, ...fields} entry is accepted too.
            var args: [String: Any]
            if let nested = entry["args"] as? [String: Any] {
                args = nested
            } else {
                args = entry
                args.removeValue(forKey: "op")
            }
            args.removeValue(forKey: "id")
            do {
                let result = try core(project, args)
                results.append(["index": index, "op": name, "result": result])
                names.append(name)
            } catch {
                throw ToolError("apply_edits: ops[\(index)] (\(name)) failed — \(error.localizedDescription) "
                    + "Nothing was written (the batch is all-or-nothing): fix that op and resend the whole batch.")
            }
        }

        let summary = "apply_edits: " + names.joined(separator: ", ")
        var response: [String: Any] = [
            "applied": results.count,
            "results": results,
        ]
        if let before = outputBefore, let after = outputDuration(of: project) {
            response["outputDuration"] = ["before": round3(before), "after": round3(after)]
        }
        let extras = try commitEdit(project, to: url, tool: "apply_edits", summary: summary)
        response.merge(extras) { current, _ in current }
        return response
    }

    // MARK: - Shared validation

    static func requireProjectRef(_ arguments: [String: Any]) throws -> String {
        guard let ref = arguments["id"] as? String, !ref.isEmpty else {
            throw ToolError("missing id — pass the project UUID from list_projects (or a project folder path)")
        }
        return ref
    }

    /// Some projects persist duration 0 (metadata written before probe) —
    /// treat that as unbounded rather than rejecting every span.
    static func durationLimit(_ project: Project) -> Double {
        project.duration > 0 ? project.duration : .infinity
    }

    static func requiredSpan(_ args: [String: Any], _ project: Project, what: String) throws -> (Double, Double) {
        guard let start = doubleValue(args["start"]), let end = doubleValue(args["end"]) else {
            throw ToolError("\(what) needs start and end (SOURCE seconds, end > start)")
        }
        try validateSpan(start, end, project, what: what)
        return (start, end)
    }

    static func validateSpan(_ start: Double, _ end: Double, _ project: Project, what: String) throws {
        let duration = durationLimit(project)
        guard start.isFinite, end.isFinite, start >= 0, end > start else {
            throw ToolError("\(what): invalid span \(fmt(start))–\(fmt(end)) — need 0 <= start < end (SOURCE seconds)")
        }
        guard end <= duration + 0.001 else {
            throw ToolError("\(what): span \(fmt(start))–\(fmt(end)) runs past the recording's end "
                + "(\(fmt(duration))s SOURCE). Times are SOURCE seconds — if you read them off render_frames "
                + "or get_transcript start/end, those are OUTPUT seconds; convert first.")
        }
    }

    static func fmt(_ value: Double) -> String {
        value.isFinite ? String(format: "%.3f", value).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression) : "∞"
    }

    static func uuidArgument(_ args: [String: Any], _ key: String, hint: String) throws -> UUID {
        guard let raw = args[key] as? String, let uuid = UUID(uuidString: raw) else {
            throw ToolError("\(key) must be a UUID string (\(hint))")
        }
        return uuid
    }

    static func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }

    static func isJSONBool(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// The single no-overlap EFFECTS lane (zoom + tilt), SOURCE time.
    static func effectLaneConflict(
        _ project: Project, start: Double, end: Double, ignoring: Set<UUID> = []
    ) -> String? {
        let epsilon = 0.0001
        let spans: [(start: Double, end: Double, kind: String, id: UUID)] =
            project.zoomRegions.map { ($0.startTime, $0.endTime, "zoom", $0.id) }
            + project.tiltRegions.map { ($0.startTime, $0.endTime, "tilt", $0.id) }
        for span in spans where !ignoring.contains(span.id)
            && start < span.end - epsilon && end > span.start + epsilon {
            return "span \(fmt(start))–\(fmt(end)) overlaps existing \(span.kind) region \(span.id.uuidString) "
                + "(\(fmt(span.start))–\(fmt(span.end))) — the EFFECTS lane never overlaps. "
                + "Pick a free span, shorten this one, or remove/move that region first (same batch is fine)."
        }
        return nil
    }

    /// The FOCUS lane: blur, highlight, depth-focus and camera-layout regions
    /// share one no-overlap lane in the editor (addBlurRegion's slot search).
    static func focusLaneConflict(
        _ project: Project, start: Double, end: Double, ignoring: Set<UUID> = []
    ) -> String? {
        let epsilon = 0.0001
        let spans: [(start: Double, end: Double, kind: String, id: UUID)] =
            project.blurRegions.map { ($0.startTime, $0.endTime, "blur", $0.id) }
            + project.highlightRegions.map { ($0.startTime, $0.endTime, "highlight", $0.id) }
            + project.focusRegions.map { ($0.startTime, $0.endTime, "depth-focus", $0.id) }
            + project.cameraLayoutRegions.map { ($0.startTime, $0.endTime, "camera-layout", $0.id) }
        for span in spans where !ignoring.contains(span.id)
            && start < span.end - epsilon && end > span.start + epsilon {
            return "span \(fmt(start))–\(fmt(end)) overlaps the \(span.kind) region \(span.id.uuidString) "
                + "(\(fmt(span.start))–\(fmt(span.end))) — blur, highlight, depth-focus and camera-layout "
                + "regions share one FOCUS lane that never overlaps. Pick a free span or remove that region first."
        }
        return nil
    }

    static func parseAnimationStyle(_ args: [String: Any]) throws -> ZoomAnimationStyle?? {
        guard let raw = args["animationStyle"] else { return .none }
        if raw is NSNull { return .some(nil) }
        guard let string = raw as? String, let style = ZoomAnimationStyle(rawValue: string) else {
            throw ToolError("invalid animationStyle: \(raw) (allowed: "
                + ZoomAnimationStyle.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
                + ", or null/omit for the project's animationSpeed)")
        }
        return .some(style)
    }

    // MARK: - Effects (zoom / tilt)

    static func opAddEffect(_ project: Project, _ args: [String: Any]) throws -> [String: Any] {
        guard let type = args["type"] as? String, ["zoom", "tilt", "zoomtilt"].contains(type) else {
            throw ToolError("type must be \"zoom\", \"tilt\" or \"zoomtilt\" (a linked zoom+tilt pair on one span)")
        }
        let (start, end) = try requiredSpan(args, project, what: "add_effect")
        let style = try parseAnimationStyle(args) ?? nil
        if let conflict = effectLaneConflict(project, start: start, end: end) {
            throw ToolError(conflict)
        }

        var created: [[String: Any]] = []
        if type == "zoom" || type == "zoomtilt" {
            let fx = doubleValue(args["focalX"]) ?? 0.5
            let fy = doubleValue(args["focalY"]) ?? 0.5
            var region = ZoomRegion(
                startTime: start,
                endTime: end,
                zoomLevel: min(6, max(0.3, doubleValue(args["zoomLevel"]) ?? 2.0)),
                focalPoint: CGPoint(x: clamp01(fx), y: clamp01(fy)),
                animationStyle: style
            )
            if let ox = doubleValue(args["offsetX"]) {
                region.cardOffsetX = abs(ox) < 0.005 ? nil : ZoomFocalMath.clampCardOffset(ox)
            }
            if let oy = doubleValue(args["offsetY"]) {
                region.cardOffsetY = abs(oy) < 0.005 ? nil : ZoomFocalMath.clampCardOffset(oy)
            }
            if let followsCursor = args["followsCursor"] as? Bool {
                region.followsCursor = followsCursor ? nil : false
            }
            project.zoomRegions.append(region)
            created.append(["type": "zoom", "id": region.id.uuidString,
                            "zoomLevel": round3(region.zoomLevel)])
        }
        if type == "tilt" || type == "zoomtilt" {
            let region = TiltRegion(
                startTime: start,
                endTime: end,
                pitch: min(60, max(-60, doubleValue(args["pitch"]) ?? 20)),
                yaw: min(60, max(-60, doubleValue(args["yaw"]) ?? 0)),
                roll: min(30, max(-30, doubleValue(args["roll"]) ?? 0)),
                animationStyle: style
            )
            project.tiltRegions.append(region)
            created.append(["type": "tilt", "id": region.id.uuidString])
        }
        return ["created": created, "span": ["start": round3(start), "end": round3(end)]]
    }

    /// The EFFECTS-lane block at SOURCE time `at`: a zoom, a tilt, or both
    /// halves of a linked zoomtilt (identical spans). Blocks may TOUCH, so a
    /// boundary time can hit two different blocks — then the one `at` is
    /// strictly inside wins (else the earlier-listed zoom), never both.
    static func effectBlock(at: Double, in project: Project) -> (zoom: Int?, tilt: Int?) {
        func pick(_ spans: [(start: Double, end: Double)]) -> Int? {
            let hits = spans.indices.filter { at >= spans[$0].start && at <= spans[$0].end }
            return hits.first { at > spans[$0].start && at < spans[$0].end } ?? hits.first
        }
        var zoom = pick(project.zoomRegions.map { ($0.startTime, $0.endTime) })
        var tilt = pick(project.tiltRegions.map { ($0.startTime, $0.endTime) })
        if let z = zoom, let t = tilt {
            let zr = project.zoomRegions[z], tr = project.tiltRegions[t]
            let linked = abs(zr.startTime - tr.startTime) < 0.0005 && abs(zr.endTime - tr.endTime) < 0.0005
            if !linked {
                let insideTilt = at > tr.startTime && at < tr.endTime
                let insideZoom = at > zr.startTime && at < zr.endTime
                // Both strictly inside = a legacy project whose tilt track
                // overlapped zooms: keep both, as before the single lane.
                if insideTilt && !insideZoom { zoom = nil } else if !(insideZoom && insideTilt) { tilt = nil }
            }
        }
        return (zoom, tilt)
    }

    /// Patches the zoom/tilt block containing SOURCE time `at` (both halves of
    /// a linked zoomtilt pair).
    static func opUpdateEffect(_ project: Project, _ args: [String: Any]) throws -> [String: Any] {
        guard let at = doubleValue(args["at"]) else {
            throw ToolError("'at' (a SOURCE time inside the block — e.g. its start) is required")
        }
        let (zoomIndex, tiltIndex) = effectBlock(at: at, in: project)
        guard zoomIndex != nil || tiltIndex != nil else {
            throw ToolError("no zoom/tilt block spans SOURCE t=\(fmt(at)) — describe_project lists "
                + "effects.zoomRegions/tiltRegions with their start/end")
        }
        let style = try parseAnimationStyle(args)

        // New span (validated once, against every OTHER block on the lane).
        let current = zoomIndex.map { (project.zoomRegions[$0].startTime, project.zoomRegions[$0].endTime) }
            ?? (project.tiltRegions[tiltIndex!].startTime, project.tiltRegions[tiltIndex!].endTime)
        let newStart = doubleValue(args["start"]) ?? current.0
        let newEnd = doubleValue(args["end"]) ?? current.1
        let spanChanged = args["start"] != nil || args["end"] != nil
        if spanChanged {
            try validateSpan(newStart, newEnd, project, what: "update_effect")
            var mine: Set<UUID> = []
            if let zoomIndex { mine.insert(project.zoomRegions[zoomIndex].id) }
            if let tiltIndex { mine.insert(project.tiltRegions[tiltIndex].id) }
            if let conflict = effectLaneConflict(project, start: newStart, end: newEnd, ignoring: mine) {
                throw ToolError(conflict)
            }
        }

        var touched: [String] = []
        if let index = zoomIndex {
            if let v = doubleValue(args["zoomLevel"]) { project.zoomRegions[index].zoomLevel = min(6, max(0.3, v)) }
            let fx = doubleValue(args["focalX"]), fy = doubleValue(args["focalY"])
            if fx != nil || fy != nil {
                let old = project.zoomRegions[index].focalPoint
                project.zoomRegions[index].focalPoint = CGPoint(
                    x: clamp01(fx ?? Double(old.x)), y: clamp01(fy ?? Double(old.y)))
            }
            if spanChanged {
                project.zoomRegions[index].startTime = newStart
                project.zoomRegions[index].endTime = newEnd
            }
            if let ox = doubleValue(args["offsetX"]) {
                project.zoomRegions[index].cardOffsetX = abs(ox) < 0.005 ? nil : ZoomFocalMath.clampCardOffset(ox)
            }
            if let oy = doubleValue(args["offsetY"]) {
                project.zoomRegions[index].cardOffsetY = abs(oy) < 0.005 ? nil : ZoomFocalMath.clampCardOffset(oy)
            }
            if let style { project.zoomRegions[index].animationStyle = style }
            if let followsCursor = args["followsCursor"] as? Bool {
                // false = fixed focus (aims exactly at focalX/Y, ignoring the
                // recorded cursor); true = default cursor blend.
                project.zoomRegions[index].followsCursor = followsCursor ? nil : false
            }
            touched.append("zoom:\(project.zoomRegions[index].id.uuidString)")
        }
        if let index = tiltIndex {
            if let v = doubleValue(args["pitch"]) { project.tiltRegions[index].pitch = min(60, max(-60, v)) }
            if let v = doubleValue(args["yaw"]) { project.tiltRegions[index].yaw = min(60, max(-60, v)) }
            if let v = doubleValue(args["roll"]) { project.tiltRegions[index].roll = min(30, max(-30, v)) }
            if spanChanged {
                project.tiltRegions[index].startTime = newStart
                project.tiltRegions[index].endTime = newEnd
            }
            if let style { project.tiltRegions[index].animationStyle = style }
            touched.append("tilt:\(project.tiltRegions[index].id.uuidString)")
        }
        return ["updated": touched, "span": ["start": round3(newStart), "end": round3(newEnd)]]
    }

    static func opRemoveEffect(_ project: Project, _ args: [String: Any]) throws -> [String: Any] {
        guard let at = doubleValue(args["at"]) else {
            throw ToolError("'at' (a SOURCE time inside the block) is required")
        }
        let (zoomIndex, tiltIndex) = effectBlock(at: at, in: project)
        guard zoomIndex != nil || tiltIndex != nil else {
            throw ToolError("no zoom/tilt block spans SOURCE t=\(fmt(at)) — describe_project lists them")
        }
        var removed: [String] = []
        if let zoomIndex { removed.append("zoom:\(project.zoomRegions.remove(at: zoomIndex).id.uuidString)") }
        if let tiltIndex { removed.append("tilt:\(project.tiltRegions.remove(at: tiltIndex).id.uuidString)") }
        return ["removed": removed.count, "blocks": removed]
    }

    /// Runs the SAME auto-zoom pipeline the app's ✨ menu uses; only earlier
    /// auto-generated regions are replaced — manual blocks stay put.
    static func opAutoZoom(_ project: Project, _ args: [String: Any]) throws -> [String: Any] {
        // Image captures have no cursor data — route to Motion: the
        // four-corner cinematic tour the editor's Motion entry generates.
        if project.cursorDataURL == nil, project.isImageCapture {
            let created = StillMotionApplier.apply(to: project)
            guard created > 0 else {
                throw ToolError("could not compose a motion tour for this image")
            }
            return ["created": created, "mode": "still-motion"]
        }
        guard project.cursorDataURL != nil else {
            throw ToolError("project has no recorded cursor data to generate zooms from — "
                + "place zooms by hand with add_effect")
        }
        let created = AutoZoomApplier.apply(to: project, zoomLevel: doubleValue(args["zoomLevel"]))
        guard created > 0 else {
            throw ToolError("no zoom-worthy activity found in the recorded cursor data "
                + "(auto_zoom needs 2+ clicks close together, a typing burst or a dwell)")
        }
        let auto = project.zoomRegions.filter { $0.isAuto == true }
        return [
            "created": created,
            "zoomRegions": auto.map { region -> [String: Any] in
                [
                    "id": region.id.uuidString,
                    "start": round3(region.startTime), "end": round3(region.endTime),
                    "zoomLevel": round3(region.zoomLevel),
                    "focalPoint": ["x": round3(region.focalPoint.x), "y": round3(region.focalPoint.y)],
                ]
            },
        ]
    }

    // MARK: - Annotations

    static let scriptableAnnotationTypes: [AnnotationType] = AnnotationType.allCases.filter { $0 != .drawing }

    /// Field patch shared by add_annotation and update_annotation — one set of
    /// ranges (the inspector's) for both.
    static func applyAnnotationFields(_ args: [String: Any], to annotation: inout Annotation) throws {
        if let x = doubleValue(args["x"]) { annotation.x = clamp01(x) }
        if let y = doubleValue(args["y"]) { annotation.y = clamp01(y) }
        if let ex = doubleValue(args["arrowEndX"]) { annotation.arrowEndX = clamp01(ex) }
        if let ey = doubleValue(args["arrowEndY"]) { annotation.arrowEndY = clamp01(ey) }
        if let raw = args["text"] {
            guard let text = raw as? String else { throw ToolError("text must be a string (max 200 chars)") }
            annotation.text = String(text.prefix(200))
        }
        if let raw = args["color"] {
            guard let hex = raw as? String, let parsed = CodableColor(hex: hex) else {
                throw ToolError("color must be a hex string, e.g. \"#FF3B30\" (RRGGBB or RRGGBBAA)")
            }
            annotation.color = parsed
        }
        if let raw = args["backgroundColor"] {
            guard let hex = raw as? String, let parsed = CodableColor(hex: hex) else {
                throw ToolError("backgroundColor must be a hex string, e.g. \"#000000B3\" (RRGGBB or RRGGBBAA)")
            }
            annotation.backgroundColor = parsed
        }
        if let show = args["showBackground"] as? Bool { annotation.showBackground = show }
        if let backdrop = doubleValue(args["backdropOpacity"]) {
            annotation.backdropOpacity = min(0.9, max(0, backdrop))
        }
        if let size = doubleValue(args["fontSize"]) {
            // Taps reuse fontSize as the ripple size (inspector: 20…120).
            annotation.fontSize = annotation.type == .tap ? min(120, max(20, size)) : min(72, max(10, size))
        }
        if let opacity = doubleValue(args["opacity"]) { annotation.opacity = min(1, max(0.2, opacity)) }
        if let width = doubleValue(args["lineWidth"]) { annotation.lineWidth = min(12, max(0, width)) }
        for key in ["enterEffect", "exitEffect"] {
            guard let raw = args[key] else { continue }
            guard let string = raw as? String, let effect = AnnotationEffect(rawValue: string) else {
                throw ToolError("invalid \(key): \(raw) (allowed: "
                    + AnnotationEffect.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ") + ")")
            }
            if key == "enterEffect" { annotation.enterEffect = effect } else { annotation.exitEffect = effect }
        }
    }

    static func opAddAnnotation(_ project: Project, _ args: [String: Any]) throws -> [String: Any] {
        guard let typeRaw = args["type"] as? String,
              let type = AnnotationType(rawValue: typeRaw), type != .drawing else {
            throw ToolError("type must be one of: "
                + scriptableAnnotationTypes.map(\.rawValue).joined(separator: ", ")
                + " (drawing/freehand strokes are editor-only — not scriptable)")
        }
        let (start, end) = try requiredSpan(args, project, what: "add_annotation")
        var annotation = Annotation(type: type, startTime: start, endTime: end)
        annotation.applyNewAnnotationDefaults()
        try applyAnnotationFields(args, to: &annotation)
        project.annotations.append(annotation)
        return ["created": annotation.id.uuidString, "type": type.rawValue]
    }

    static func opUpdateAnnotation(_ project: Project, _ args: [String: Any]) throws -> [String: Any] {
        let annID = try uuidArgument(args, "annotationId",
                                     hint: "from add_annotation's 'created' or describe_project's annotations[].id")
        guard let index = project.annotations.firstIndex(where: { $0.id == annID }) else {
            throw ToolError("no annotation with id \(annID.uuidString) — describe_project lists annotations with ids")
        }
        var annotation = project.annotations[index]
        if let raw = args["type"] as? String, raw != annotation.type.rawValue {
            throw ToolError("an annotation's type can't change (it is \(annotation.type.rawValue)) — "
                + "remove_annotation and add_annotation instead")
        }
        let start = doubleValue(args["start"]) ?? annotation.startTime
        let end = doubleValue(args["end"]) ?? annotation.endTime
        if args["start"] != nil || args["end"] != nil {
            try validateSpan(start, end, project, what: "update_annotation")
        }
        annotation.startTime = start
        annotation.endTime = end
        try applyAnnotationFields(args, to: &annotation)
        project.annotations[index] = annotation
        return ["updated": annID.uuidString, "span": ["start": round3(start), "end": round3(end)]]
    }

    static func opRemoveAnnotation(_ project: Project, _ args: [String: Any]) throws -> [String: Any] {
        let annID = try uuidArgument(args, "annotationId",
                                     hint: "from add_annotation's 'created' or describe_project's annotations[].id")
        let before = project.annotations.count
        project.annotations.removeAll { $0.id == annID }
        guard project.annotations.count < before else {
            throw ToolError("no annotation with id \(annID.uuidString) — describe_project lists annotations with ids")
        }
        return ["removed": 1]
    }

    // MARK: - Privacy blur (FOCUS lane)

    /// Mirrors the editor: BlurRegion's model defaults (rect, intensity 0.6,
    /// style Blur), the style-derived label createBlurRegion uses, the
    /// inspector's strength range (0.1…1), the canvas' minimum rect side
    /// (0.04) and the FOCUS lane's no-overlap + 0.8s slot minimum.
    static func opAddBlur(_ project: Project, _ args: [String: Any]) throws -> [String: Any] {
        let (start, end) = try requiredSpan(args, project, what: "add_blur")
        guard end - start >= 0.8 - 0.0001 else {
            throw ToolError("add_blur: span \(fmt(start))–\(fmt(end)) is shorter than 0.8s, the editor's minimum "
                + "region length — extend it (a blur should cover the whole time the secret is visible)")
        }
        var style = BlurStyle.blur
        if let raw = args["style"] {
            guard let string = raw as? String, let parsed = BlurStyle(rawValue: string) else {
                throw ToolError("invalid style: \(raw) (allowed: "
                    + BlurStyle.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ") + ")")
            }
            style = parsed
        }
        let defaults = BlurRegion(startTime: start, endTime: end)
        let x = doubleValue(args["x"]) ?? Double(defaults.rect.origin.x)
        let y = doubleValue(args["y"]) ?? Double(defaults.rect.origin.y)
        let width = doubleValue(args["width"]) ?? Double(defaults.rect.width)
        let height = doubleValue(args["height"]) ?? Double(defaults.rect.height)
        let minSide = 0.04
        guard x >= 0, y >= 0, width >= minSide, height >= minSide,
              x + width <= 1.0001, y + height <= 1.0001 else {
            throw ToolError("add_blur: rect x=\(fmt(x)) y=\(fmt(y)) width=\(fmt(width)) height=\(fmt(height)) is "
                + "invalid — x/y/width/height are normalized 0–1 fractions of the video frame (Y-down, not pixels), "
                + "width/height >= \(minSide), and the rect must stay inside the frame (x+width <= 1, y+height <= 1)")
        }
        var intensity = defaults.intensity
        if let raw = args["intensity"] {
            guard let v = doubleValue(raw), (0.1...1).contains(v) else {
                throw ToolError("intensity must be a number in 0.1...1 (the editor's Strength slider)")
            }
            intensity = v
        }
        // Lane check last: argument mistakes (pixels, bad style) first.
        if let conflict = focusLaneConflict(project, start: start, end: end) {
            throw ToolError(conflict)
        }
        let label = (args["label"] as? String).map { String($0.prefix(60)) }
            ?? (style == .pixelate ? "Pixelate" : "Blur")
        let region = BlurRegion(
            startTime: start, endTime: end, label: label,
            rect: CGRect(x: x, y: y, width: min(width, 1 - x), height: min(height, 1 - y)),
            intensity: intensity, style: style,
            animated: args["animated"] as? Bool ?? false
        )
        project.blurRegions.append(region)
        return ["created": region.id.uuidString, "style": style.rawValue]
    }

    static func opRemoveBlur(_ project: Project, _ args: [String: Any]) throws -> [String: Any] {
        let blurID = try uuidArgument(args, "blurId", hint: "from add_blur's 'created' or describe_project's blurRegions[].id")
        let before = project.blurRegions.count
        project.blurRegions.removeAll { $0.id == blurID }
        guard project.blurRegions.count < before else {
            throw ToolError("no blur region with id \(blurID.uuidString) — describe_project lists blurRegions with ids")
        }
        return ["removed": 1]
    }

    // MARK: - Speed regions

    /// The editor's speed presets span 0.5×…4× (TimelineVideoRowModel.speedPresets).
    static var speedRange: ClosedRange<Double> {
        let presets = TimelineVideoRowModel.speedPresets
        return (presets.min() ?? 0.5)...(presets.max() ?? 4)
    }

    /// Mirrors the editor's speed rules: regions live on SOURCE spans inside
    /// the recording, never overlap each other, are at least 0.8s long (the
    /// slot search's minimum), and a pick on an existing region changes its
    /// speed in place (changeSpeedRegion).
    static func opSetSpeed(_ project: Project, _ args: [String: Any]) throws -> [String: Any] {
        let range = speedRange
        guard let speed = doubleValue(args["speed"]), speed.isFinite else {
            throw ToolError("speed is required: a multiplier in \(formatNumber(range.lowerBound))...\(formatNumber(range.upperBound)) "
                + "(editor presets: " + TimelineVideoRowModel.speedPresets.map { formatNumber($0) }.joined(separator: ", ") + ")")
        }
        guard range.contains(speed) else {
            throw ToolError("speed \(fmt(speed)) is outside \(formatNumber(range.lowerBound))...\(formatNumber(range.upperBound)) "
                + "(the editor's range)")
        }
        guard abs(speed - 1) > 0.01 else {
            throw ToolError("speed 1.0 is normal playback — use remove_speed to clear a region instead")
        }
        let (start, end) = try requiredSpan(args, project, what: "set_speed")
        let before = outputDuration(of: project)
        let tolerance = 0.01

        if let index = project.speedRegions.firstIndex(where: {
            abs($0.startTime - start) < tolerance && abs($0.endTime - end) < tolerance
        }) {
            project.speedRegions[index].speed = speed
            return speedResult(project, region: project.speedRegions[index], action: "changed", before: before)
        }
        guard end - start >= 0.8 - 0.0001 else {
            throw ToolError("set_speed: span \(fmt(start))–\(fmt(end)) is shorter than 0.8s, the editor's minimum "
                + "speed-region length — widen it")
        }
        let epsilon = 0.0001
        let overlapping = project.speedRegions.filter { start < $0.endTime - epsilon && end > $0.startTime + epsilon }
        if !overlapping.isEmpty {
            let list = overlapping.map {
                "\($0.id.uuidString) (\(fmt($0.startTime))–\(fmt($0.endTime)) at \(formatNumber($0.speed))×)"
            }.joined(separator: ", ")
            throw ToolError("set_speed: span \(fmt(start))–\(fmt(end)) overlaps speed region(s) \(list). Speed regions "
                + "never overlap: pass that region's exact start/end to change its speed, remove_speed it first, "
                + "or pick a span outside it.")
        }
        let region = VideoSpeedRegion(startTime: start, endTime: end, speed: speed)
        project.speedRegions.append(region)
        var result = speedResult(project, region: region, action: "created", before: before)
        let trimStart = project.effectiveTrimStart, trimEnd = project.effectiveTrimEnd
        if start < trimStart - 0.001 || end > trimEnd + 0.001 {
            result["note"] = "part of this span lies outside the trim window "
                + "(\(fmt(trimStart))–\(fmt(trimEnd))); only the part inside it plays"
        }
        return result
    }

    private static func speedResult(
        _ project: Project, region: VideoSpeedRegion, action: String, before: Double?
    ) -> [String: Any] {
        var result: [String: Any] = [
            action: [
                "id": region.id.uuidString,
                "start": round3(region.startTime), "end": round3(region.endTime),
                "speed": region.speed,
            ],
        ]
        if let before, let after = outputDuration(of: project) {
            result["outputDuration"] = ["before": round3(before), "after": round3(after)]
        }
        return result
    }

    static func opRemoveSpeed(_ project: Project, _ args: [String: Any]) throws -> [String: Any] {
        let before = outputDuration(of: project)
        var removed: [VideoSpeedRegion] = []
        if args["all"] as? Bool == true {
            removed = project.speedRegions
            project.speedRegions.removeAll()
        } else if let raw = args["speedId"] {
            guard let string = raw as? String, let id = UUID(uuidString: string) else {
                throw ToolError("speedId must be a UUID string (describe_project's speedRegions[].id)")
            }
            removed = project.speedRegions.filter { $0.id == id }
            project.speedRegions.removeAll { $0.id == id }
        } else if let at = doubleValue(args["at"]) {
            removed = project.speedRegions.filter { at >= $0.startTime && at <= $0.endTime }
            project.speedRegions.removeAll { at >= $0.startTime && at <= $0.endTime }
        } else {
            throw ToolError("remove_speed needs one of: speedId (UUID), at (a SOURCE time inside the region), or all: true")
        }
        guard !removed.isEmpty else {
            throw ToolError("no matching speed region — describe_project lists speedRegions with ids and spans")
        }
        var result: [String: Any] = ["removed": removed.map(\.id.uuidString)]
        if let before, let after = outputDuration(of: project) {
            result["outputDuration"] = ["before": round3(before), "after": round3(after)]
        }
        return result
    }

    // MARK: - Trim

    /// Mirrors the editor's whole-track trim: 0 <= start, end <= duration and
    /// at least 0.5s kept (VideoTrackCommits.minDuration). Refuses a window
    /// that would hide every visible clip.
    static func opSetTrim(_ project: Project, _ args: [String: Any]) throws -> [String: Any] {
        guard project.duration > 0 else {
            throw ToolError("this project has no probed duration yet — open it once in CaptureCat, then retry")
        }
        let before = outputDuration(of: project)
        let previous = (project.trimStart, project.trimEnd)
        if args["reset"] as? Bool == true {
            project.trimStart = 0
            project.trimEnd = 0
        } else {
            guard args["start"] != nil || args["end"] != nil else {
                throw ToolError("set_trim needs start and/or end (SOURCE seconds), or reset: true for the full recording")
            }
            let start = doubleValue(args["start"]) ?? project.effectiveTrimStart
            let end = doubleValue(args["end"]) ?? project.effectiveTrimEnd
            guard start >= 0, end <= project.duration + 0.001, start.isFinite, end.isFinite else {
                throw ToolError("set_trim: \(fmt(start))–\(fmt(end)) must lie within 0–\(fmt(project.duration)) "
                    + "(SOURCE seconds of the original recording)")
            }
            guard end - start >= 0.5 else {
                throw ToolError("set_trim: keep at least 0.5s (the editor's minimum); got \(fmt(start))–\(fmt(end))")
            }
            project.trimStart = start
            project.trimEnd = min(end, project.duration)
        }
        let clips = project.effectiveVideoClipSegments
        guard !clips.isEmpty else {
            let window = "\(fmt(project.effectiveTrimStart))–\(fmt(project.effectiveTrimEnd))"
            project.trimStart = previous.0
            project.trimEnd = previous.1
            throw ToolError("set_trim: the window \(window) contains no visible video clip (cut_video removed that "
                + "footage) — describe_project lists clips; pick a window that overlaps one")
        }
        var result: [String: Any] = [
            "trim": ["start": round3(project.effectiveTrimStart), "end": round3(project.effectiveTrimEnd)],
            "clips": clips.map { ["start": round3($0.startTime), "end": round3($0.endTime)] },
            "note": "Effects keep their SOURCE times; only the OUTPUT timeline shifts "
                + "(output 0 = source \(fmt(project.effectiveTrimStart))).",
        ]
        if let before, let after = outputDuration(of: project) {
            result["outputDuration"] = ["before": round3(before), "after": round3(after)]
        }
        return result
    }

    // MARK: - Cut

    /// Removes SOURCE ranges from the video lane — the exact write the
    /// editor's delete-clip performs (materialise effectiveVideoClipSegments,
    /// subtract, re-derive splitPoints). NOT a ripple delete, matching
    /// TimelineViewController.deleteVideoClip: the span renders as
    /// background-only; nothing downstream is re-timed.
    static func opCutVideo(_ project: Project, _ args: [String: Any]) throws -> [String: Any] {
        guard let rawRanges = args["ranges"] as? [[String: Any]], !rawRanges.isEmpty else {
            throw ToolError("ranges must be a non-empty array of {start, end} in SOURCE seconds "
                + "(get_transcript returns sourceStart/sourceEnd per segment and per word)")
        }
        let ranges: [(start: Double, end: Double)] = try rawRanges.map { entry in
            guard let start = doubleValue(entry["start"]),
                  let end = doubleValue(entry["end"]), end > start, start >= 0 else {
                throw ToolError("each range needs start >= 0 and end > start (SOURCE seconds)")
            }
            return (start, end)
        }

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
        // or sub-0.1s sliver) must not report success.
        guard removed > 0.001 else {
            throw ToolError("ranges removed nothing — they fall in already-cut spans, outside the "
                + "video lane, or are shorter than 0.1s. Check clip bounds via describe_project.")
        }
        project.videoClipSegments = clips
        project.splitPoints = clips.dropFirst().map(\.startTime).sorted()

        return [
            "clips": clips.map { ["start": round3($0.startTime), "end": round3($0.endTime)] },
            "removedSeconds": round3(removed),
            "note": "The removed spans show the background only — the video is NOT shorter (no ripple). "
                + "To shorten, use set_trim (head/tail) or set_speed (middle). Check with render_frames.",
        ]
    }

    // MARK: - Style

    static func opSetStyle(_ project: Project, _ args: [String: Any]) throws -> [String: Any] {
        guard let patch = args["patch"] as? [String: Any], !patch.isEmpty else {
            throw ToolError("patch must be a non-empty object of settings, e.g. {\"backgroundPadding\": 64} "
                + "— style_options lists every key")
        }
        var applied: [String: Any] = [:]
        for key in patch.keys.sorted() {
            try applyStyle(key: key, value: patch[key]!, to: project.settings)
            applied[key] = patch[key]
        }
        return ["applied": applied]
    }
}
