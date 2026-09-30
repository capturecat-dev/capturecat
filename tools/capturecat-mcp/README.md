# CaptureCat MCP server

The MCP server lives **inside the CaptureCat app binary** — `CaptureCat --mcp`
speaks Model Context Protocol over stdio (newline-delimited JSON-RPC 2.0).
There is no Node sidecar and no external runtime; the implementation is
`apps/macos/CaptureCat/Services/MCPServer*.swift`, operating directly on the
app's own Codable models, so validation is always in sync with what the app
persists.

| file | owns |
|---|---|
| `MCPServer.swift` | transport, dispatch, progress notifications, project IO + undo history, read/render/transcribe/export/record tools |
| `MCPServer+Edits.swift` | every mutating tool as a pure `(project, args) → result` core, and `apply_edits` |
| `MCPServer+Style.swift` | the one table behind `set_style` and `style_options` |
| `MCPServer+Analysis.swift` | `describe_project`, the interaction digest and the audio/pacing digest |
| `MCPServer+Catalog.swift` | tool schemas + annotations, prompts, the `initialize` instructions |

## Register with Claude Code

Point the registration at the built app binary (the executable inside
`CaptureCat.app/Contents/MacOS/`). The `capturecat` shim in `~/.local/bin`
resolves the current Debug build:

```sh
claude mcp add capturecat -- capturecat --mcp
```

For an installed copy, use
`/Applications/CaptureCat.app/Contents/MacOS/CaptureCat --mcp` instead.

## What the model is told (initialize → `instructions`)

The server returns a ~5 KB editing playbook in `InitializeResult.instructions`,
which Claude clients inject into the model's context. It covers:

- **The project model** — lanes: VIDEO (trim, clips, speed), EFFECTS (zoom +
  tilt, one no-overlap lane), FOCUS (blur, highlight, depth-focus, camera
  layout — one no-overlap lane), annotations (may overlap), subtitles, style.
- **Two clocks.** SOURCE seconds (original recording) are what every edit tool
  and every `describe_project` time speaks. OUTPUT seconds (after trim + speed)
  are only used by `render_frames` and `get_transcript` start/end. `cut_video`
  does not ripple — to shorten, trim and speed up.
- **Coordinates** — normalized 0–1, Y-down, of the recorded video frame.
- **The loop** — `describe_project` → plan → one `apply_edits` batch →
  `render_frames` contact sheet → fix / `undo` → `export_project`.
- **Taste defaults** — zoom depth/lead-in/hold/release read from
  `AutoZoomGenerator.Tuning`, speed-up rules, annotation restraint, privacy
  blur, vertical 9:16 cuts.
- **Safety** — undo history, the GUI-running warning, render cost, the
  first-run Whisper download, visible recording.

Numbers in the instructions and tool descriptions are interpolated from the
code that enforces them, so they can't drift.

## Tools

Every tool carries a `title` and MCP `annotations` (`readOnlyHint`,
`destructiveHint`, `idempotentHint`, `openWorldHint`) so clients can
auto-approve the read-only ones. `id` accepts a project UUID, a project folder
path, or a `project.json` path.

### Look (read-only)

| tool | input | returns |
|---|---|---|
| `list_projects` | — | `{projects: [{id, name, createdAt, duration, recordingSourceKind, reminderDate?}]}` |
| `describe_project` | `{id}` | compact timeline: `duration`, `outputDuration` (exported length — the exporter's own math), `trim`, `clips`, `effects` (zoom/tilt with ids, `auto: true` on auto-zoom blocks), `annotations` (ids, type, span, position, text, color), `blurRegions` / `highlightRegions` (rect, style, intensity), `speedRegions` (ids), `subtitles: {count, showSubtitles}`, key `settings`; `interactionDigest` `{clickClusters: [{start, end, clickCount, meanPosition}], idleSpans}` and `pacing` `{audio, silenceSpans, quietSpans, quietSeconds}`. All times SOURCE seconds |
| `get_transcript` | `{id}` | segments with OUTPUT `start`/`end` (+ per-word), and SOURCE `sourceStart`/`sourceEnd` per segment and per word |
| `render_frames` | `{id, times? \| span?: {start?, end?, count?}, layout?: individual\|contact_sheet, format?: png\|jpeg, quality?, maxWidth?}` | frames of the final render at OUTPUT times. `contact_sheet` tiles up to 16 frames into ONE image with a caption under each tile: `#n <output>s  src <source>`. Individual: up to 8 images |
| `style_options` | `{id?, group?}` | every `set_style` key by group with type, range / exact enum values and (with `id`) the current value |
| `search_captures` | `{query, limit?}` | OCR + title matches; `bestFrameTime` (SOURCE) and `bestFrameOutputTime` (OUTPUT, for `render_frames`) |
| `list_notes` | — | text captures |
| `list_capture_targets` | — | `{displays, windows}` |

`pacing.quietSpans` = spans with no cursor movement, no clicks, no
keystrokes/scrolls and no sound (audio RMS, adaptive threshold 12 dB over the
noise floor, clamped to −55…−40 dBFS) — the strongest speed-up candidates.

### Edit (all SOURCE seconds)

| tool | input | notes |
|---|---|---|
| `apply_edits` | `{id, ops: [{op, args}]}` | ops = any mutating tool below (except `transcribe`/`undo`), `args` = its arguments without `id`. Runs every op against one in-memory project with exactly the single tools' validation, writes ONCE (one undo step). Any failure → nothing written; the error names `ops[i]` and the reason |
| `add_effect` | `{id, type: zoom\|tilt\|zoomtilt, start, end, zoomLevel?, focalX?, focalY?, pitch?, yaw?, roll?, animationStyle?, offsetX?, offsetY?, followsCursor?}` | refuses spans overlapping any zoom/tilt block (single effects lane) and names the blocker |
| `update_effect` | `{id, at, …same keys, start?, end?}` | patches the block containing `at`; a new span is lane-checked |
| `remove_effect` | `{id, at}` | |
| `auto_zoom` | `{id, zoomLevel?}` | the app's real pipeline; replaces previously auto-generated blocks only, returns them |
| `add_annotation` | `{id, type: text\|arrow\|callout\|rectangle\|ellipse\|tap, start, end, x?, y?, arrowEndX?, arrowEndY?, text?, color?, backgroundColor?, showBackground?, backdropOpacity?, fontSize?, opacity?, lineWidth?, enterEffect?, exitEffect?}` | starts from the editor's per-type defaults (`Annotation.applyNewAnnotationDefaults`, shared with the toolbar) |
| `update_annotation` | `{id, annotationId, …same fields}` | same validation as add |
| `remove_annotation` | `{id, annotationId}` | |
| `add_blur` | `{id, start, end, x?, y?, width?, height?, style?: Blur\|Pixelate, intensity?, animated?, label?}` | mirrors the editor: BlurRegion defaults, strength 0.1–1, min rect side 0.04, ≥ 0.8 s, FOCUS lane never overlaps |
| `remove_blur` | `{id, blurId}` | |
| `set_speed` | `{id, start, end, speed}` | 0.5–4× (the editor's preset range), ≥ 0.8 s, no overlaps; an existing region's exact span changes its speed. Returns `outputDuration {before, after}` |
| `remove_speed` | `{id, speedId? \| at? \| all?}` | |
| `set_trim` | `{id, start?, end?, reset?}` | ≥ 0.5 s kept (editor minimum), must include a visible clip |
| `cut_video` | `{id, ranges: [{start, end}]}` | lifts footage out like deleting a sliced clip — the span shows background only, **not** a ripple delete |
| `set_style` | `{id, patch}` | whitelisted keys (see `style_options`); unknown keys get a "did you mean" |
| `transcribe` | `{id, replace?, showSubtitles?}` | runs the editor's `TranscriptionService` (on-device WhisperKit) and stores `project.subtitles` exactly like the Subtitles pane. **First run downloads the Whisper model (~150 MB).** Refuses to overwrite existing subtitles without `replace: true` |
| `undo` | `{id, steps?, force?}` | restores the state before the last N MCP writes |

Every mutating result carries `undoSteps` and, when the GUI is running, a
`warning`.

### Output and recording

| tool | input | returns |
|---|---|---|
| `export_project` | `{id, output}` | `{path, requestedPath, moved, note?}` — the real export engine in-process; the app is sandboxed, so if `output` isn't writable, `path` is inside the app container and `moved` is false |
| `start_recording` | `{source?: display\|window\|chrome\|safari, display?, app?, title?, url?, audio?}` | returns once capture is live; `url` opens a page in the target browser first |
| `stop_recording` | — | `{projectId, projectName, duration}` |

The `--mcp` process is headless; recording happens in the GUI app, which is
launched automatically when needed. Commands and status flow through
`Application Support/CaptureCat/Automation/{command,status}.json` in the shared
sandbox container (see `AutomationBridge.swift`). Recording is always visible —
floating panel plus the 3-2-1 countdown — an agent can never capture silently.

## Prompts

`prompts/list` / `prompts/get` expose workflow plans that reference the real
tools:

| prompt | arguments | plan |
|---|---|---|
| `polish_recording` | `projectId`, `goal?` | describe → one batch (trim, zooms, speed-ups, restrained callouts, privacy blur) → contact sheet → iterate → ask before export |
| `tighten_pacing` | `projectId` | trim head/tail, 2–4× on `quietSpans`, never over speech, prefer speed-ups to cuts |
| `vertical_social_cut` | `projectId` | `aspectRatio` 9:16, zooms carry the story, short output, captions |
| `record_and_edit_demo` | `url`, `goal?` | start_recording in the browser → demo → stop → polish |

## Progress

When a `tools/call` request carries `params._meta.progressToken`, the server
emits `notifications/progress` (strictly increasing) during `export_project`,
fresh `render_frames` renders (percent) and `transcribe` (stages 1–5).

## Undo and safety

- Every MCP write goes through one path: encode → snapshot the previous
  `project.json` into `<project folder>/.mcp-history/` (30 kept, with the tool,
  a summary and the SHA-256 of what was written) → `project.json.bak` →
  atomic replace. Media files are never touched.
- `undo` refuses when `project.json` no longer matches the last MCP write
  (e.g. the app saved in between) unless `force: true`, so it can't silently
  discard in-app edits. `project.json.bak` holds the pre-undo state.
- If the CaptureCat app is running it reloads MCP edits automatically, except
  for a project open in the editor with unsaved changes — there the in-app
  edits win, and mutations say so in `warning`.
- `render_frames` renders through the real exporter into the container's tmp
  (`capturecat-mcp-renders/`, keyed by the project file's bytes, the 6 most
  recently used kept).
- In `--mcp` mode stdout carries only JSON-RPC; progress and diagnostics go to
  stderr.

## Smoke test

```sh
python3 tools/capturecat-mcp/smoke.py /path/to/CaptureCat.app/Contents/MacOS/CaptureCat
python3 tools/capturecat-mcp/smoke.py <binary> --skip-render --skip-export   # fast
python3 tools/capturecat-mcp/smoke.py <binary> --transcribe                  # + real transcription
```

The script copies the most recent real project to a throwaway UUID folder and
drives initialize (instructions) → tools/list (annotations) → prompts → every
tool over stdio: an `apply_edits` batch, an all-or-nothing failure that must
leave `project.json` byte-identical, lane/overlap/range rejections,
`update_annotation`, blur, speed, trim, cut, a contact-sheet render with
progress notifications, multi-step `undo` (including the refusal after an
outside change), and an export. It prints PASS/FAIL per check and deletes the
copy. `--transcribe` is opt-in because the first run downloads the Whisper
model (~150 MB) into the app container.
