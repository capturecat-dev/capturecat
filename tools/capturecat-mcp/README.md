# CaptureCat MCP server

The MCP server lives **inside the CaptureCat app binary** — `CaptureCat --mcp`
speaks Model Context Protocol over stdio (newline-delimited JSON-RPC 2.0).
There is no Node sidecar and no external runtime; the implementation is
`apps/macos/CaptureCat/Services/MCPServer.swift`, operating directly on the
app's own Codable models, so validation is always in sync with what the app
persists.

## Register with Claude Code

Point the registration at the built app binary (the executable inside
`CaptureCat.app/Contents/MacOS/`). The `capturecat` shim in `~/.local/bin`
resolves the current Debug build:

```sh
claude mcp add capturecat -- capturecat --mcp
```

For an installed copy, use
`/Applications/CaptureCat.app/Contents/MacOS/CaptureCat --mcp` instead.

## Recording tools

The `--mcp` process is headless; recording happens in the GUI app, which is
launched automatically when needed. Commands and status flow through
`Application Support/CaptureCat/Automation/{command,status}.json` in the shared
sandbox container (see `AutomationBridge.swift`). Recording is always visible —
floating panel plus the 3-2-1 countdown — an agent can never capture silently.

| tool | input | returns |
|---|---|---|
| `list_capture_targets` | — | `{displays: [{index, width, height}], windows: [{app, title, width, height}]}` |
| `start_recording` | `{source?: display\|window\|chrome\|safari, display?, app?, title?, url?, audio?}` | returns once capture is live; `url` opens a page in the target browser first |
| `stop_recording` | — | `{projectId, projectName, duration}` — feed the id to the editing tools below |

Typical agent flow: `start_recording {source: "chrome", url: "https://docs.stripe.com/testing"}`
→ drive the browser to demonstrate → `stop_recording` → `auto_zoom` /
`add_annotation` → `export_project`.

## Editing tools

| tool | input | returns |
|---|---|---|
| `list_projects` | — | `{projects: [{id, name, createdAt, duration, recordingSourceKind}]}` |
| `describe_project` | `{id}` | timeline (clips, effects, blur/highlight/speed regions), key settings, and `interactionDigest`: `{totalEvents, coordinateSize, clickClusters: [{start, end, clickCount, meanPosition{x,y} (0–1)}], idleSpans: [{start, end}]}` from the recorded cursor data — this is what tells you WHERE zooms belong |
| `add_effect` | `{id, type: zoom\|tilt\|zoomtilt, start, end, zoomLevel?, focalX?, focalY?, pitch?, yaw?, roll?, animationStyle?, offsetX?, offsetY?, followsCursor?}` | `{created: [{type, id}], warning?}` — refuses spans overlapping any existing zoom/tilt region (single effects lane) |
| `update_effect` | `{id, at, ...same keys}` | patches the block containing source-time `at` |
| `remove_effect` | `{id, at}` | removes the block containing `at` |
| `auto_zoom` | `{id, zoomLevel?}` | runs the app's real auto-zoom pipeline; REPLACES all zoom regions |
| `add_annotation` | `{id, type: text\|arrow\|callout\|rectangle\|ellipse\|tap, start, end, x?, y?, arrowEndX?, arrowEndY?, text?, color?, backdropOpacity?}` | `{created}` |
| `remove_annotation` | `{id, annotationId}` | `{removed}` |
| `set_style` | `{id, patch}` | `{applied, warning?}` — whitelisted settings keys only, validated against the real `ProjectSettings` enums/ranges. Includes `aspectRatio` (`"Auto"`, `"16:9"`, `"4:3"`, `"1:1"`, `"9:16"`, `"21:9"`, `"4:5"`) for vertical/social canvases |
| `cut_video` | `{id, ranges: [{start, end}]}` | `{clips, removedSeconds, note, warning?}` — removes SOURCE-time ranges from the video lane (get the ranges from `get_transcript`'s `sourceStart`/`sourceEnd`). Same semantics as deleting a sliced clip in the editor: the span shows the background only, the timeline is not rippled shorter |
| `export_project` | `{id, output}` | `{path, requestedPath, moved, note?}` — runs the real export engine in-process; the app is sandboxed, so if `output` isn't writable, `path` is inside the app container and `moved` is false (copy it yourself) |

`id` accepts a project UUID, a project folder path, or a `project.json` path.

## Caveats

- If the CaptureCat app is running, mutations return a `warning`: the app's
  autosave can overwrite external edits to a project that is open in the
  editor. Close the project first.
- Mutations write `project.json` atomically and leave a `project.json.bak`.
  Media files are never touched.
- Export requires the signed-in export entitlement the GUI uses (the MCP
  process runs the same auth check).
- In `--mcp` mode stdout carries only JSON-RPC; progress and diagnostics go to
  stderr.

## Smoke test

```sh
python3 tools/capturecat-mcp/smoke.py       # uses the Debug build path default
python3 tools/capturecat-mcp/smoke.py /path/to/CaptureCat.app/Contents/MacOS/CaptureCat
```

The script copies the most recent real project to a throwaway UUID folder,
drives initialize → tools/list → every tool over stdio (including an export),
prints PASS/FAIL per check, and deletes the copy.
