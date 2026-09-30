import Foundation

/// What a client sees: tool schemas (+ MCP 2025-06-18 titles/annotations),
/// workflow prompts, and the `initialize` instructions playbook. Numbers in
/// here are read from the code that enforces them (auto-zoom tuning, the
/// editor's speed presets, the history depth) so the text can't drift.
extension MCPServer {
    // MARK: - Instructions (InitializeResult.instructions)

    static var serverInstructions: String {
        let t = AutoZoomGenerator.Tuning.self
        let speeds = speedRange
        func n(_ v: Double) -> String { formatNumber(v) }
        return """
        CaptureCat edits screen recordings non-destructively. A project = one recording (video + recorded \
        cursor, clicks, keystrokes) + an edit list in project.json. Tools rewrite that edit list; media is never touched.

        LANES
        - VIDEO: trim window (set_trim), clips (cut_video lifts footage out), speed regions (set_speed/remove_speed).
        - EFFECTS: zoom + tilt blocks (add_effect, update_effect, remove_effect, auto_zoom). ONE lane: blocks never \
        overlap; a "zoomtilt" is a linked zoom+tilt pair on one span.
        - FOCUS: blur (add_blur), highlight, depth-focus and camera-layout regions share one lane that never overlaps.
        - ANNOTATIONS (text, arrow, callout, rectangle, ellipse, tap) may overlap. Subtitles come from transcribe. \
        The look is set_style (style_options lists every key, range and current value).

        TWO CLOCKS (the #1 mistake)
        - SOURCE seconds = position in the original recording. ALL edit tools take SOURCE time, and every \
        start/end/at in describe_project (clips, effects, interactionDigest, pacing) is SOURCE. So are \
        get_transcript's sourceStart/sourceEnd (per segment and per word) and search_captures' bestFrameTime.
        - OUTPUT seconds = position in the exported video, after trim + speed regions. Only render_frames \
        (times/span) and get_transcript start/end/words use OUTPUT.
        - With no speed regions, output = source - trimStart. Otherwise convert with get_transcript's paired times \
        or render_frames' tile captions ("src" = SOURCE). describe_project.outputDuration is the exported length.
        - Edits are anchored to content: trimming or speeding up shifts OUTPUT time, never an effect's SOURCE time.
        - cut_video does NOT ripple: the removed span shows only the background and the video keeps its length \
        (only cutting the very end shortens it). To shorten, use set_trim (head/tail) and set_speed (middle).

        COORDINATES: normalized 0-1 fractions of the recorded video frame, Y-down, (0,0) = top-left — zoom \
        focalX/focalY, annotation x/y/arrowEndX/arrowEndY, blur x/y/width/height, click-cluster meanPosition. Never pixels.

        LOOP
        1. describe_project: clips, effects and annotations with ids, interactionDigest (click clusters = where \
        attention goes), pacing (quietSpans = no motion, no input, no sound). Speech? get_transcript \
        (transcribe first if it has no subtitles).
        2. Plan the whole edit, then send it as ONE apply_edits batch (all-or-nothing, one undo step).
        3. render_frames {layout: "contact_sheet", span: {count: 12}} — one image, every tile labelled with \
        OUTPUT and SOURCE time. Check framing, focal points, text placement and anything private.
        4. Fix with apply_edits or undo; re-render only the changed range (span start/end).
        5. export_project when it looks right (ask the user where to save if they haven't said).

        TASTE (screen recordings)
        - Zoom: start from auto_zoom, then refine. Depth \(n(t.minZoom))-\(n(t.maxZoom)) \
        (auto_zoom's range; above 3 disorients). Begin ~\(n(t.leadIn))s before the action, hold at least \
        \(n(t.minDuration))s, release ~\(n(t.release))s after the last action, leave >= \(n(t.cooldown))s between \
        separate zooms. For nearby consecutive actions extend ONE block: while zoomed the camera blends toward \
        the cursor (followsCursor: false pins it to the focal point). Keep focal within [0.5/z, 1-0.5/z] on each \
        axis (auto_zoom does) or the zoomed view runs past the video's edge. Omit animationStyle to use the project pace; \
        "Smooth"/"Slow Glide" read calm, "Snappy" energetic. Re-running auto_zoom replaces every auto block \
        (describe marks them auto: true), including ones you tweaked.
        - Pacing: set_speed (\(n(speeds.lowerBound))x-\(n(speeds.upperBound))x, spans >= 0.8s, never overlapping) \
        at 2-4x on quietSpans and dead waits (loading, long typing); never speed through speech. Trim dead \
        head/tail with set_trim.
        - Annotations: restraint. One on screen at a time, 2-4s, <= 6 words, placed away from the action. \
        backdropOpacity (spotlight) sparingly. Tilt: subtle (pitch <= 20).
        - Privacy: blur (style "Pixelate" for a censor look) emails, API keys, tokens, customer data, \
        notifications. Look for them in the contact sheet.
        - Vertical: set_style {aspectRatio: "9:16"} (or "4:5" for feeds). A landscape recording becomes a small \
        card in a tall canvas, so zooms must carry most of the video, captions help, and shorter is better. \
        Always verify with render_frames.

        SAFETY
        - Every write snapshots the previous project.json into <project folder>/.mcp-history (last \
        \(historyLimit)) plus project.json.bak. undo {id, steps} walks MCP writes back; it refuses if the file \
        changed outside MCP since (force: true overrides).
        - If the CaptureCat app is running, write results carry a warning: the app reloads the edit \
        automatically unless that project is open with unsaved changes — then the app's copy wins and may \
        overwrite yours. Ask the user to save or close it first.
        - render_frames' first call after an edit re-renders the whole project (up to about the video's length); \
        later calls on the same edit state are cached — batch edits before looking. transcribe's first run downloads the on-device Whisper model (~150 MB).
        - start_recording is always visible to the user (floating panel + 3-2-1 countdown) and needs Screen \
        Recording permission.
        """
    }

    // MARK: - Tool definitions

    private static func tool(
        _ name: String, title: String, description: String,
        properties: [String: Any] = [:], required: [String] = [],
        readOnly: Bool = false, destructive: Bool = false, idempotent: Bool = false,
        openWorld: Bool = false
    ) -> [String: Any] {
        var annotations: [String: Any] = [
            "title": title,
            "readOnlyHint": readOnly,
            "openWorldHint": openWorld,
        ]
        if !readOnly {
            annotations["destructiveHint"] = destructive
            annotations["idempotentHint"] = idempotent
        }
        return [
            "name": name,
            "title": title,
            "description": description,
            "inputSchema": ["type": "object", "properties": properties, "required": required],
            "annotations": annotations,
        ]
    }

    private static let idProperty: [String: Any] = [
        "type": "string", "description": "Project UUID from list_projects (or a project folder / project.json path)",
    ]

    private static func number(_ description: String, min: Double? = nil, max: Double? = nil) -> [String: Any] {
        var schema: [String: Any] = ["type": "number", "description": description]
        if let min { schema["minimum"] = min }
        if let max { schema["maximum"] = max }
        return schema
    }

    private static var effectProperties: [String: Any] {
        let styles = ZoomAnimationStyle.allCases.map(\.rawValue)
        let limit = ZoomFocalMath.cardOffsetLimit
        return [
            "zoomLevel": number("Zoom depth (default 2.0). 1.5–2.5 reads well; below 1.0 is a scale-DOWN effect.",
                                min: 0.3, max: 6),
            "focalX": number("Zoom aim point, normalized 0–1 of the video frame (default 0.5 = centre).", min: 0, max: 1),
            "focalY": number("Zoom aim point, normalized 0–1, Y-down (default 0.5).", min: 0, max: 1),
            "pitch": number("Tilt: positive tips the top edge back (default 20 for new tilts).", min: -60, max: 60),
            "yaw": number("Tilt: positive tips the left edge back (default 0).", min: -60, max: 60),
            "roll": number("Tilt: in-plane rotation, positive = clockwise (default 0).", min: -30, max: 30),
            "animationStyle": ["type": "string", "enum": styles,
                               "description": "Transition feel for whichever of zoom/tilt the block has; omit = the project's animationSpeed (update_effect: null resets to it)."],
            "offsetX": number("Zoom only: card position excursion during the block, canvas fractions.", min: -limit, max: limit),
            "offsetY": number("Zoom only: card excursion, canvas fractions, Y-down.", min: -limit, max: limit),
            "followsCursor": ["type": "boolean",
                              "description": "Zoom only: false = fixed focus exactly at focalX/Y; true/omit = the camera blends toward the recorded cursor while zoomed."],
        ]
    }

    private static var annotationFieldProperties: [String: Any] {
        [
            "x": number("Text/tap: centre. Arrow: tail. Rectangle/ellipse: one corner. Callout: anchor. Normalized 0–1.", min: 0, max: 1),
            "y": number("Normalized 0–1, Y-down.", min: 0, max: 1),
            "arrowEndX": number("Arrow: head point. Rectangle/ellipse: opposite corner. Callout: pointer. Ignored for text/tap.", min: 0, max: 1),
            "arrowEndY": number("Normalized 0–1, Y-down.", min: 0, max: 1),
            "text": ["type": "string", "description": "text/callout content, max 200 chars — keep it to a few words."],
            "color": ["type": "string", "description": "Hex \"#RRGGBB\" or \"#RRGGBBAA\" — text/arrow/shape color."],
            "backgroundColor": ["type": "string", "description": "Hex — the text pill / shape fill color."],
            "showBackground": ["type": "boolean", "description": "Text pill / shape fill on or off."],
            "backdropOpacity": number("Spotlight: dims everything outside the annotation. 0 = off.", min: 0, max: 0.9),
            "fontSize": number("Text size 10–72; for taps it is the ripple size 20–120.", min: 10, max: 120),
            "opacity": number("Whole-annotation opacity.", min: 0.2, max: 1),
            "lineWidth": number("Arrow/shape stroke width.", min: 0, max: 12),
            "enterEffect": ["type": "string", "enum": AnnotationEffect.allCases.map(\.rawValue),
                            "description": "Build-in effect (new annotations default to Pop)."],
            "exitEffect": ["type": "string", "enum": AnnotationEffect.allCases.map(\.rawValue),
                           "description": "Build-out effect (new annotations default to Fade)."],
        ]
    }

    private static func merged(_ base: [String: Any], _ extra: [String: Any]) -> [String: Any] {
        base.merging(extra) { _, new in new }
    }

    /// Same types/ranges/enums without the prose — the update_* tools point
    /// at their add_* sibling instead of repeating it (tools/list is context).
    private static func terse(_ properties: [String: Any]) -> [String: Any] {
        properties.mapValues { schema in
            guard var schema = schema as? [String: Any] else { return schema }
            schema.removeValue(forKey: "description")
            return schema
        }
    }

    static var toolDefinitions: [[String: Any]] {
        let spanStart = number("SOURCE seconds (original recording).", min: 0)
        let spanEnd: [String: Any] = ["type": "number", "exclusiveMinimum": 0, "description": "SOURCE seconds, > start."]
        let speeds = speedRange
        let presetList = TimelineVideoRowModel.speedPresets.map { formatNumber($0) }.joined(separator: ", ")
        let annotationTypes = scriptableAnnotationTypes.map(\.rawValue)

        return [
            // MARK: Read / look
            tool("list_projects", title: "List projects",
                 description: "List all CaptureCat screen-recording projects (id, name, createdAt, duration in "
                    + "seconds, recordingSourceKind, reminderDate when set). Start here to get a project id.",
                 readOnly: true),
            tool("describe_project", title: "Describe project",
                 description: "Everything needed to plan an edit, compact: duration + outputDuration (exported "
                    + "length), trim, clips, zoom/tilt blocks, annotations, blur/highlight/speed regions (all with "
                    + "ids), subtitle count, key settings; interactionDigest (click clusters with normalized "
                    + "positions, idle cursor spans) and pacing (audio silenceSpans, plus quietSpans = no cursor "
                    + "motion, no clicks/keys/scrolls and no sound — speed-up candidates). Every time is SOURCE seconds.",
                 properties: ["id": idProperty], required: ["id"], readOnly: true),
            tool("get_transcript", title: "Get transcript",
                 description: "Timed transcript of the project's speech (its subtitles). Segment start/end and "
                    + "per-word timings are OUTPUT seconds (the render_frames clock); each segment and word also "
                    + "carries sourceStart/sourceEnd in SOURCE seconds for edit tools (cut_video, set_speed, "
                    + "add_effect…). Empty until transcribe (or the editor) has generated subtitles.",
                 properties: ["id": idProperty], required: ["id"], readOnly: true),
            tool("render_frames", title: "Render frames",
                 description: "SEE the final render: frames of the exported video at OUTPUT times with every "
                    + "effect, zoom, cursor, annotation, blur and style exactly as export ships them (the real "
                    + "exporter, cached per edit state). layout \"contact_sheet\" tiles up to 16 frames into ONE "
                    + "image, each tile labelled with its OUTPUT time and SOURCE (src) time — the cheap way to verify "
                    + "an edit. Pass span {start?, end?, count?} to sample evenly (OUTPUT seconds; end defaults to the "
                    + "video's end) or explicit times (max 8 individual / 16 contact sheet). format \"jpeg\" "
                    + "(+quality) shrinks payloads. The first call after an edit re-renders the project (up to "
                    + "about the video's length); later calls on the same edit state are instant.",
                 properties: [
                    "id": idProperty,
                    "times": ["type": "array", "items": ["type": "number", "minimum": 0], "maxItems": 16,
                              "description": "OUTPUT-video timestamps in seconds."],
                    "span": [
                        "type": "object",
                        "description": "Evenly sampled frames (inclusive of start and end) — instead of times.",
                        "properties": [
                            "start": number("OUTPUT seconds, default 0.", min: 0),
                            "end": number("OUTPUT seconds, default the video's end."),
                            "count": ["type": "integer", "minimum": 1, "maximum": 16,
                                      "description": "Frames to sample (default 12 for contact_sheet, 4 individual)."],
                        ],
                    ],
                    "layout": ["type": "string", "enum": ["individual", "contact_sheet"],
                               "description": "individual (default): one image per time. contact_sheet: one labelled grid image."],
                    "format": ["type": "string", "enum": ["png", "jpeg"], "description": "Default png."],
                    "quality": number("JPEG quality (default 0.8).", min: 0.1, max: 1),
                    "maxWidth": number("Longest edge in pixels: per image for individual (100–1600, default 800), "
                        + "of the whole sheet for contact_sheet (400–2400, default 1568)."),
                 ],
                 required: ["id"], readOnly: true),
            tool("style_options", title: "Style options",
                 description: "Every set_style key grouped (canvas, background, cursor, clicksAndKeys, camera, "
                    + "menuBar, motion, intro, audio, subtitles, watermark) with its type, range or exact enum values "
                    + "and — when id is given — the project's current value. Read it before set_style.",
                 properties: [
                    "id": ["type": "string", "description": "Optional project id to include current values."],
                    "group": ["type": "string", "enum": styleGroups, "description": "Optional: one group only."],
                 ],
                 readOnly: true),
            tool("search_captures", title: "Search captures",
                 description: "Search captures by what's VISIBLE in them (on-device OCR index) plus titles and note "
                    + "text. Tokens AND-match case/diacritic-insensitively ('stripe invoice' finds captures showing "
                    + "both words). Ranked matches — title matches first, then by hit count — with a snippet and, for "
                    + "videos, bestFrameTime (SOURCE seconds) and bestFrameOutputTime (OUTPUT seconds — pass it to "
                    + "render_frames).",
                 properties: [
                    "query": ["type": "string", "description": "Search terms, e.g. 'whatsapp joshua'"],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 50, "description": "Max results, default 20."],
                 ],
                 required: ["query"], readOnly: true),
            tool("list_notes", title: "List notes",
                 description: "List all CaptureCat text captures (notes) — id, title, full text, source app, "
                    + "createdAt, reminderDate when set. Notes are created via the macOS Services menu "
                    + "(highlight text → Services → Capture Text in CaptureCat) or File → New Note from Clipboard.",
                 readOnly: true),

            // MARK: Edit
            tool("apply_edits", title: "Apply edits (batch)",
                 description: "Apply several edits to ONE project atomically: ops run in order against one in-memory "
                    + "copy with exactly the validation of the individual tools, then the project is written once "
                    + "(one undo step). If any op fails NOTHING is written and the error names the op index and "
                    + "reason. Each op is {op, args} where args are that tool's arguments without id. Later ops see "
                    + "earlier ones (remove then re-add on the same span works). Prefer this over many single calls. "
                    + "Returns per-op results (created ids…) and outputDuration before/after.",
                 properties: [
                    "id": idProperty,
                    "ops": [
                        "type": "array", "minItems": 1, "maxItems": 200,
                        "items": [
                            "type": "object",
                            "properties": [
                                "op": ["type": "string", "enum": editOpNames],
                                "args": ["type": "object", "description": "The tool's own arguments, minus id."],
                            ],
                            "required": ["op"],
                        ],
                    ],
                 ],
                 required: ["id", "ops"], destructive: true),
            tool("add_effect", title: "Add zoom/tilt block",
                 description: "Add an EFFECTS-lane block on a SOURCE span: type \"zoom\" (zoomLevel default 2.0, "
                    + "focalX/Y default centre), \"tilt\" (pitch/yaw/roll, default 20/0/0) or \"zoomtilt\" (a linked "
                    + "pair). Zoom and tilt blocks share ONE lane and may never overlap — the error names the "
                    + "blocking region. Good zooms: start ~0.35s before the action, hold >= 1.8s.",
                 properties: merged(effectProperties, [
                    "id": idProperty,
                    "type": ["type": "string", "enum": ["zoom", "tilt", "zoomtilt"]],
                    "start": spanStart, "end": spanEnd,
                 ]),
                 required: ["id", "type", "start", "end"]),
            tool("update_effect", title: "Update zoom/tilt block",
                 description: "Patch the zoom/tilt block containing SOURCE time 'at' (both halves of a linked "
                    + "zoomtilt): zoomLevel, focalX/focalY, pitch, yaw, roll, start, end, animationStyle, "
                    + "offsetX/offsetY, followsCursor — same meanings as add_effect. Only supplied keys change; a "
                    + "new span is checked against the rest of the lane.",
                 properties: merged(terse(effectProperties), [
                    "id": idProperty,
                    "at": number("A SOURCE time inside the block (e.g. its start).", min: 0),
                    "start": spanStart, "end": spanEnd,
                 ]),
                 required: ["id", "at"], destructive: true, idempotent: true),
            tool("remove_effect", title: "Remove zoom/tilt block",
                 description: "Remove the zoom/tilt block(s) containing SOURCE time 'at'.",
                 properties: ["id": idProperty, "at": number("SOURCE seconds inside the block.", min: 0)],
                 required: ["id", "at"], destructive: true, idempotent: true),
            tool("auto_zoom", title: "Auto zoom",
                 description: "Run the app's real auto-zoom pipeline: clusters recorded clicks, typing bursts and "
                    + "dwells, picks a depth per cluster (tight = deeper, spread = gentler, 1.3–2.75), pans between "
                    + "nearby clusters. Replaces previously auto-generated blocks only — manual blocks stay and "
                    + "generation routes around them (blocks you tweaked with update_effect remain 'auto' and are "
                    + "replaced on the next run). Needs recorded cursor data; for still images it composes a "
                    + "four-corner Motion tour instead. Returns the generated blocks.",
                 properties: [
                    "id": idProperty,
                    "zoomLevel": number("Base depth before per-cluster adjustment; default the project's autoZoomLevel.",
                                        min: 1.5, max: 4),
                 ],
                 required: ["id"], destructive: true, idempotent: true),
            tool("add_annotation", title: "Add annotation",
                 description: "Add an on-screen annotation on a SOURCE span: text, arrow, callout, rectangle, "
                    + "ellipse, or tap (looping touch ripple for iPhone/iPad takes). Starts from the editor's "
                    + "per-type defaults (e.g. hollow white shapes, 'Look here' callouts). Coordinates are "
                    + "normalized 0–1, Y-down. Freehand drawing is editor-only. Returns the new id.",
                 properties: merged(annotationFieldProperties, [
                    "id": idProperty,
                    "type": ["type": "string", "enum": annotationTypes],
                    "start": spanStart, "end": spanEnd,
                 ]),
                 required: ["id", "type", "start", "end"]),
            tool("update_annotation", title: "Update annotation",
                 description: "Patch an annotation by annotationId (describe_project lists them): start/end "
                    + "(SOURCE), position, text, colors, backdropOpacity, size, opacity, effects — same meanings "
                    + "and validation as add_annotation. Only supplied keys change. Its type can't change.",
                 properties: merged(terse(annotationFieldProperties), [
                    "id": idProperty,
                    "annotationId": ["type": "string"],
                    "start": spanStart, "end": spanEnd,
                 ]),
                 required: ["id", "annotationId"], destructive: true, idempotent: true),
            tool("remove_annotation", title: "Remove annotation",
                 description: "Remove an annotation by annotationId (add_annotation's 'created' or describe_project).",
                 properties: ["id": idProperty, "annotationId": ["type": "string"]],
                 required: ["id", "annotationId"], destructive: true, idempotent: true),
            tool("add_blur", title: "Add privacy blur",
                 description: "Blur (or pixelate) a rectangle of the video over a SOURCE span — for emails, API "
                    + "keys, tokens, customer data. Rect is x/y/width/height normalized 0–1 of the video frame, "
                    + "Y-down (min side 0.04; defaults to the editor's centred 0.3/0.3/0.4/0.15). Spans are >= 0.8s "
                    + "and share the FOCUS lane with highlight/depth-focus/camera-layout regions (no overlaps). "
                    + "Cover the whole time the secret is visible, with a little margin.",
                 properties: [
                    "id": idProperty, "start": spanStart, "end": spanEnd,
                    "x": number("Left edge, 0–1.", min: 0, max: 1),
                    "y": number("Top edge, 0–1 (Y-down).", min: 0, max: 1),
                    "width": number("0.04–1.", min: 0.04, max: 1),
                    "height": number("0.04–1.", min: 0.04, max: 1),
                    "style": ["type": "string", "enum": BlurStyle.allCases.map(\.rawValue),
                              "description": "Default Blur."],
                    "intensity": number("Strength, default 0.6.", min: 0.1, max: 1),
                    "animated": ["type": "boolean", "description": "Pixelate only: jittering mosaic."],
                    "label": ["type": "string", "description": "Timeline label (default Blur / Pixelate)."],
                 ],
                 required: ["id", "start", "end"]),
            tool("remove_blur", title: "Remove blur",
                 description: "Remove a blur region by blurId (add_blur's 'created' or describe_project's blurRegions).",
                 properties: ["id": idProperty, "blurId": ["type": "string"]],
                 required: ["id", "blurId"], destructive: true, idempotent: true),
            tool("set_speed", title: "Set playback speed",
                 description: "Play a SOURCE span faster or slower (\(formatNumber(speeds.lowerBound))–"
                    + "\(formatNumber(speeds.upperBound))×; editor presets \(presetList)). Speed regions are >= 0.8s "
                    + "and never overlap; passing an existing region's exact start/end changes its speed. Audio "
                    + "keeps its pitch. Use 2–4× on dead time (describe_project pacing.quietSpans), never on speech. "
                    + "Returns outputDuration before/after.",
                 properties: [
                    "id": idProperty, "start": spanStart, "end": spanEnd,
                    "speed": number("Multiplier; 1.0 is not allowed (use remove_speed).",
                                    min: speeds.lowerBound, max: speeds.upperBound),
                 ],
                 required: ["id", "start", "end", "speed"], destructive: true, idempotent: true),
            tool("remove_speed", title: "Remove speed region",
                 description: "Clear speed regions: by speedId, by 'at' (a SOURCE time inside the region), or all: true.",
                 properties: [
                    "id": idProperty,
                    "speedId": ["type": "string"],
                    "at": number("SOURCE seconds inside the region.", min: 0),
                    "all": ["type": "boolean"],
                 ],
                 required: ["id"], destructive: true, idempotent: true),
            tool("set_trim", title: "Set trim",
                 description: "Set the trim window in SOURCE seconds — what plays from the recording. Omitted "
                    + "start/end keep their current value; reset: true restores the full recording. At least 0.5s "
                    + "must remain and the window must include a visible clip. Effects keep their SOURCE times; the "
                    + "OUTPUT timeline starts at the new trim start.",
                 properties: [
                    "id": idProperty,
                    "start": number("SOURCE seconds.", min: 0),
                    "end": number("SOURCE seconds.", min: 0),
                    "reset": ["type": "boolean"],
                 ],
                 required: ["id"], destructive: true, idempotent: true),
            tool("cut_video", title: "Cut footage",
                 description: "Remove SOURCE-time ranges of footage from the video lane (e.g. a flubbed sentence — "
                    + "take ranges from get_transcript's sourceStart/sourceEnd). Same as deleting a sliced clip in "
                    + "the editor: the footage is lifted out and the span shows the background only — the video is "
                    + "NOT shortened (no ripple). To shorten, use set_trim / set_speed. Verify with render_frames.",
                 properties: [
                    "id": idProperty,
                    "ranges": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": ["start": spanStart, "end": spanEnd],
                            "required": ["start", "end"],
                        ],
                        "description": "SOURCE-time ranges (seconds) to remove, end > start each.",
                    ],
                 ],
                 required: ["id", "ranges"], destructive: true, idempotent: true),
            tool("set_style", title: "Set style",
                 description: "Patch project settings with {key: value}. Keys are whitelisted and validated "
                    + "against the real settings types (unknown keys and bad values are rejected with the allowed "
                    + "values). Enum values are exact raw values (e.g. menuBarReplacement \"Clean Dark\", aspectRatio "
                    + "\"9:16\"); colors are hex. Groups — \(styleKeySummary). style_options lists every key with "
                    + "its range and current value.",
                 properties: [
                    "id": idProperty,
                    "patch": ["type": "object", "description": "Partial settings, e.g. {\"backgroundPadding\": 64}."],
                 ],
                 required: ["id", "patch"], destructive: true, idempotent: true),
            tool("transcribe", title: "Transcribe speech",
                 description: "Generate the project's subtitles on-device with the app's Whisper transcription "
                    + "(same as the editor's Generate button) so get_transcript and word-exact cuts work. The FIRST "
                    + "run downloads the Whisper model (~150 MB) and can take minutes; progress is reported. "
                    + "Refuses to overwrite existing subtitles unless replace: true. Captions render in the video "
                    + "while showSubtitles is on (pass showSubtitles to set it in the same write).",
                 properties: [
                    "id": idProperty,
                    "replace": ["type": "boolean", "description": "Regenerate even if subtitles exist (discards hand edits)."],
                    "showSubtitles": ["type": "boolean", "description": "Also set whether captions are burned in."],
                 ],
                 required: ["id"], destructive: true),
            tool("undo", title: "Undo MCP edits",
                 description: "Restore the project to before the last MCP write(s) — every mutating tool and "
                    + "apply_edits batch is one step (up to \(historyLimit) kept in the project's .mcp-history). "
                    + "Reports what was undone and the before/after timeline counts. Refuses if project.json was "
                    + "changed outside MCP since the last MCP edit (e.g. saved in the app) unless force: true.",
                 properties: [
                    "id": idProperty,
                    "steps": ["type": "integer", "minimum": 1, "maximum": historyLimit, "description": "Default 1."],
                    "force": ["type": "boolean"],
                 ],
                 required: ["id"], destructive: true),

            // MARK: Output
            tool("export_project", title: "Export video",
                 description: "Export the project to an mp4 with the real export engine, in-process; blocks until "
                    + "done (progress is reported). Overwrites an existing file at output. The app is sandboxed: if "
                    + "the requested path isn't writable, the result's `path` is inside the app container and "
                    + "`moved` is false — copy it to the destination yourself.",
                 properties: [
                    "id": idProperty,
                    "output": ["type": "string", "description": "Absolute destination path for the mp4."],
                 ],
                 required: ["id", "output"], destructive: true, idempotent: true),

            // MARK: Record
            tool("list_capture_targets", title: "List capture targets",
                 description: "List recordable displays and on-screen windows (app name, title, size). Use it to "
                    + "pick a start_recording target, e.g. the browser window showing the page to demonstrate.",
                 readOnly: true),
            tool("start_recording", title: "Start recording",
                 description: "Start a screen recording in the CaptureCat app (launched automatically if needed — "
                    + "recording is always visible: floating panel + 3-2-1 countdown). source 'chrome'/'safari' "
                    + "records that browser's window, launching it if needed; 'window' matches by app/title; "
                    + "'display' records a whole screen. Optional 'url' opens a page in the target browser first. "
                    + "Returns once capture is live: then drive the screen (e.g. via your browser tools) and call "
                    + "stop_recording.",
                 properties: [
                    "source": ["type": "string", "enum": ["display", "window", "chrome", "safari"],
                               "description": "Default display."],
                    "display": ["type": "integer", "minimum": 0, "description": "Display index (source=display)."],
                    "app": ["type": "string", "description": "Owning app name to match (source=window)."],
                    "title": ["type": "string", "description": "Window title substring to match (source=window)."],
                    "url": ["type": "string", "description": "http(s) page to open in the target browser before capture."],
                    "audio": ["type": "boolean", "description": "Capture system audio. Default true."],
                 ],
                 openWorld: true),
            tool("stop_recording", title: "Stop recording",
                 description: "Stop the in-progress recording, wait for it to be saved, and return the new "
                    + "projectId — feed it to describe_project and the editing tools.",
                 idempotent: false),
        ]
    }

    // MARK: - Prompts

    static let promptDefinitions: [[String: Any]] = [
        [
            "name": "polish_recording",
            "title": "Polish a recording",
            "description": "Turn a raw screen recording into a clean, watchable video: trim, zooms, pacing, "
                + "restrained callouts, privacy blur, verified with a contact sheet.",
            "arguments": [
                ["name": "projectId", "description": "Project UUID from list_projects", "required": true],
                ["name": "goal", "description": "What the video should achieve / who it's for", "required": false],
            ],
        ],
        [
            "name": "tighten_pacing",
            "title": "Tighten pacing",
            "description": "Remove dead time: trim the head/tail and speed up quiet idle stretches without touching speech.",
            "arguments": [
                ["name": "projectId", "description": "Project UUID from list_projects", "required": true],
            ],
        ],
        [
            "name": "vertical_social_cut",
            "title": "Vertical social cut",
            "description": "Re-frame a recording as a 9:16 short for TikTok / Shorts / Reels: tight zooms, fast pacing, captions.",
            "arguments": [
                ["name": "projectId", "description": "Project UUID from list_projects", "required": true],
            ],
        ],
        [
            "name": "record_and_edit_demo",
            "title": "Record and edit a demo",
            "description": "Record a browser demo of a URL, then edit it into a polished video.",
            "arguments": [
                ["name": "url", "description": "http(s) page to demonstrate", "required": true],
                ["name": "goal", "description": "What the demo should show", "required": false],
            ],
        ],
    ]

    static func promptResult(name: String, arguments: [String: Any]) throws -> [String: Any] {
        guard let definition = promptDefinitions.first(where: { $0["name"] as? String == name }) else {
            throw ToolError("unknown prompt: \(name) (available: "
                + promptDefinitions.compactMap { $0["name"] as? String }.joined(separator: ", ") + ")")
        }
        func arg(_ key: String) -> String? {
            guard let value = arguments[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        for spec in definition["arguments"] as? [[String: Any]] ?? []
        where spec["required"] as? Bool == true {
            let key = spec["name"] as? String ?? ""
            guard arg(key) != nil else { throw ToolError("prompt \(name) needs argument '\(key)'") }
        }
        let t = AutoZoomGenerator.Tuning.self
        func n(_ v: Double) -> String { formatNumber(v) }

        let text: String
        switch name {
        case "polish_recording":
            let id = arg("projectId")!
            let goal = arg("goal").map { "Goal: \($0)\n\n" } ?? ""
            text = """
            Polish the CaptureCat project \(id) into a clean, watchable screen recording.
            \(goal)Steps (all edit times are SOURCE seconds; only render_frames and get_transcript start/end are OUTPUT):
            1. describe_project {"id": "\(id)"} — note duration vs outputDuration, trim, existing effects/annotations \
            (ids), interactionDigest.clickClusters (where the action is) and pacing.quietSpans (dead air).
            2. If there is speech: get_transcript (run transcribe first if it has no subtitles). Find the key moments.
            3. Plan the whole edit, then apply it in ONE apply_edits call:
               - set_trim to drop dead time before the first and after the last meaningful action (~0.3s margin);
               - auto_zoom as a first pass (or add_effect zooms on the click clusters): depth 1.5–2.5, start \
            ~\(n(t.leadIn))s before the action, hold >= \(n(t.minDuration))s, >= \(n(t.cooldown))s between zooms, \
            focal on the cluster's meanPosition;
               - set_speed 2–4x on quietSpans longer than ~3s (never over speech);
               - at most 2–3 short annotations (<= 6 words, 2–4s) where a viewer could get lost;
               - add_blur over anything private (emails, keys, tokens, customer data);
               - set_style only if the look needs it (style_options lists keys; keep the user's style otherwise).
            4. render_frames {"id": "\(id)", "layout": "contact_sheet", "span": {"count": 12}} — check framing, \
            focal points, annotation placement and privacy.
            5. Fix with apply_edits (or undo) and re-render the affected span until it looks right.
            6. Summarize the edit (outputDuration before/after, what was added) and ask where to export \
            before calling export_project.
            """
        case "tighten_pacing":
            let id = arg("projectId")!
            text = """
            Tighten the pacing of CaptureCat project \(id) without losing anything a viewer needs.
            1. describe_project {"id": "\(id)"} — read outputDuration, trim, speedRegions, clips, \
            pacing.quietSpans / silenceSpans and interactionDigest.idleSpans (all SOURCE seconds).
            2. If there is speech, get_transcript (transcribe first if needed) and keep every spoken span at 1x.
            3. Head and tail: set_trim to ~0.3s before the first meaningful action and ~0.5s after the last.
            4. Dead air: set_speed on quietSpans of 2s or more — about 2x for 2–4s, 3x for 4–8s, 4x beyond — \
            leaving ~0.3s at normal speed on each side so cuts don't feel abrupt. Speed regions must not overlap and \
            must be >= 0.8s.
            5. Short fumbles are better sped up than cut: cut_video removes footage but leaves a background-only gap \
            (it does NOT shorten the video). Only cut what must not be seen.
            6. Apply everything in ONE apply_edits call, then report outputDuration before → after.
            7. render_frames {"id": "\(id)", "layout": "contact_sheet", "span": {"count": 12}} to confirm nothing \
            important got rushed; adjust or undo.
            """
        case "vertical_social_cut":
            let id = arg("projectId")!
            text = """
            Make a 9:16 vertical cut of CaptureCat project \(id) for TikTok / Shorts / Reels.
            1. describe_project {"id": "\(id)"} and, if there is speech, get_transcript (transcribe first if needed).
            2. In ONE apply_edits call:
               - set_style {"patch": {"aspectRatio": "9:16"}} (use "4:5" for a feed post); consider a smaller \
            backgroundPadding so the card is as large as possible;
               - a landscape recording is now a small card, so zooms carry the video: zoom blocks (about 2–2.75) \
            covering most of the timeline, focal on each click cluster's meanPosition, extending one block across \
            nearby actions instead of zooming out and back in;
               - set_trim and set_speed on quietSpans — short is the point (aim well under 60s of output);
               - with speech: captions on (set_style showSubtitles true, subtitleFontSize ~44, subtitlePosition \
            "Center" or "Bottom").
            3. render_frames {"id": "\(id)", "layout": "contact_sheet", "span": {"count": 12}} — every tile should \
            show the action large and legible, with nothing important cropped.
            4. Iterate with apply_edits / undo, then export_project to a path the user chooses.
            """
        default: // record_and_edit_demo
            let url = arg("url")!
            let goal = arg("goal").map { "Goal: \($0)\n" } ?? ""
            text = """
            Record a demo of \(url) with CaptureCat, then edit it into a polished video.
            \(goal)1. Optionally list_capture_targets to confirm the browser window.
            2. start_recording {"source": "chrome", "url": "\(url)"} (or "safari"). It returns once capture is live \
            — the user sees a floating panel and a 3-2-1 countdown.
            3. Perform the demo with your browser tools: deliberate movements, a ~1s pause after each important \
            click, no private data on screen.
            4. stop_recording → projectId.
            5. describe_project → one apply_edits batch (set_trim head/tail, auto_zoom, set_speed on \
            pacing.quietSpans, 1–3 short annotations, add_blur over anything private) → render_frames \
            {"layout": "contact_sheet", "span": {"count": 12}} → iterate → export_project.
            """
        }
        return [
            "description": definition["description"] as? String ?? "",
            "messages": [["role": "user", "content": ["type": "text", "text": text]]],
        ]
    }
}

// MARK: - Catalog export (web editor / WebMCP)

extension MCPServer {
    /// `CaptureCat --mcp-catalog-json [<file>]` — the tool + prompt catalog and
    /// the editing playbook as ONE JSON document. The web editor's WebMCP layer
    /// (`document.modelContext.registerTool`) is generated from this file, so
    /// browser agents and desktop agents read identical tool names, schemas,
    /// annotations and guidance — the two surfaces can never drift. Written to
    /// the given path when writable, else to the container tmp (sandbox); the
    /// path is printed on stdout.
    @MainActor
    static func exportCatalogJSON() -> Never {
        let args = CommandLine.arguments
        let requested = args.firstIndex(of: "--mcp-catalog-json").flatMap { i in
            i + 1 < args.count && !args[i + 1].hasPrefix("-") ? args[i + 1] : nil
        }
        let catalog: [String: Any] = [
            "generatedBy": "CaptureCat --mcp-catalog-json",
            "instructions": serverInstructions,
            "tools": toolDefinitions,
            "prompts": promptDefinitions,
        ]
        guard JSONSerialization.isValidJSONObject(catalog),
              let data = try? JSONSerialization.data(withJSONObject: catalog, options: [.prettyPrinted, .sortedKeys])
        else {
            FileHandle.standardError.write(Data("catalog is not serializable\n".utf8))
            exit(1)
        }
        var url = URL(fileURLWithPath: requested.map { ($0 as NSString).expandingTildeInPath }
            ?? NSTemporaryDirectory() + "capturecat-mcp-catalog.json")
        if (try? data.write(to: url)) == nil {
            url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("capturecat-mcp-catalog.json")
            do { try data.write(to: url) } catch {
                FileHandle.standardError.write(Data("write failed: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        let toolCount = toolDefinitions.count
        print("MCP-CATALOG \(url.path) tools=\(toolCount) prompts=\(promptDefinitions.count)")
        exit(0)
    }
}
