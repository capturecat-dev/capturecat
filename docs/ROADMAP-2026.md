# CaptureCat 2026 Roadmap

Positioning: **the screen recorder that edits itself — and that agents can drive.**
Screen Studio owns "beautiful by default." Their known gaps (community complaints):
weak real editing, no automation/API, slow exports, single-format output, mediocre
captions, no external video import, subscription resentment. CaptureCat already beats
them on editing (clips, effects lane, focus lane) and export parity. The 2026 bets
below attack the rest, ordered by value-per-effort **against this codebase**.

## Tier 1 — ship first (each ≈ days–2 weeks)

### 1. Agentic surface (in progress)
Headless export (`CaptureCat --export`) + MCP server (`tools/capturecat-mcp`): agents list
projects, add effects, restyle, export. Nobody in the category has this.
*Leverage: projects are Codable JSON; exporter is already deterministic.*

### 2. Keystroke & click-sound overlays
Show pressed keys (⌘K pills) and optional click sounds. Cursor events are already
recorded; add a keystroke recorder + overlay renderer (preview/export pair like
the menu bar). Most-requested tutorial feature everywhere.

### 3. Brand kits / presets
Save current settings bundle (background, cursor, menu bar, frame, motion) as a
named preset; apply on new projects. Pure ProjectSettings serialization + picker
UI. This is what makes teams standardize on a tool.

### 4. Auto-reframe multi-format export
One click: 16:9 master + 9:16/1:1 cuts. The zoom focal data already says where
the action is — reuse it as the reframe center. Exporter gains an output-rect
crop pass; everything else exists.

## Tier 2 — the differentiators (each ≈ 2–6 weeks)

### 5. AI auto-edit
- Cut silences/idle spans (audio RMS + cursor idleness — both signals on disk).
- Auto speed-ramp scrolling/typing stretches (speed regions exist).
- Smarter auto-zoom: target the UI element under interaction (Vision/Accessibility
  detection on frames) instead of raw click clusters.
The demo writes itself: record, press one button, get a cut video.

### 6. Captions v2
On-device Whisper transcription → styled captions using the existing subtitle
renderer + word-highlight mode; per-language translation via the same model.
Kills a standing Screen Studio complaint.

### 7. Import external video
Run any mp4/mov through the beautifier pipeline (background, zoom, cursor-less).
Mostly relaxing recorder assumptions in Project + a file-open flow. Doubles the
addressable use cases (phone footage, Loom re-polish).

### 8. Wireless iPhone recording
AirPlay-receiver window capture flow (assessed earlier: capture the mirror
window via ScreenCaptureKit; tag as device take). Removes the cable.

## Tier 3 — bigger bets

### 9. True ripple editing
Delete a clip and re-time everything downstream (effects, subtitles, annotations,
voice-overs). Model-level change; unlocks "real editor" claims fully.

### 10. 3D device scene
SceneKit-rendered iPhone with real lighting driven by the tilt system (the faux-3D
bezel is good; this is the flagship-marketing version).

### 11. Team/cloud
Shared presets, review links, comment timestamps. Only after the above — this is
where subscription pricing becomes defensible instead of resented.

## Anti-goals for 2026
- Windows port (focus wins the Mac niche first).
- Building our own AirPlay protocol stack (use the OS receiver).
- Generic NLE feature chase (multicam, LUTs) — stay opinionated.

## Added 2026-08-02 (from Screen Studio feature-request mining)

- **Brand watermark** — SHIPPED: Brand tab, logo PNG/JPEG copied into the project
  folder, free-placement pad + on-preview drag, size/opacity, burned into export
  (83 upvotes on Screen Studio's board, "In Review" for over a year there).
- **Image overlays on the timeline** (PNG/JPEG track with timing, position,
  scale — educators' most-requested; natural extension of the watermark
  pipeline once overlay assets exist per-region rather than per-project).
- **Tap indicators for iPhone/iPad recordings** — SHIPPED (manual): a `tap`
  annotation type renders a looping, deterministic click-ripple at a chosen
  point, placed and timed on the new ANNOTATE timeline lane. AUTOMATIC tap /
  keyboard capture on iOS is not possible over wired ScreenCaptureKit capture
  (no touch events cross the cable) — it would need an iOS companion app
  streaming touch/keyboard metadata; keep as a candidate for the wireless
  iPhone recording work.
- **Annotate timeline lane** — SHIPPED: annotations are first-class timeline
  blocks (drag/resize/snap/select/delete with undo, overlaps allowed).

## AppKit migration status (2026-08-02)

Native AppKit, shipped and on: application shell/lifecycle (CaptureCatAppDelegate,
EditorWindowController), timeline canvas (ruler, playhead, EFFECTS/FOCUS/
ANNOTATE lanes, keyboard), the entire inspector column — rail, scroll, and all
eight panes including Annotate (AnnotationSettingsPaneAppKit) — project
browser, onboarding, export sheet, dock/status menus.

Built + parity-gated, flag currently OFF pending live-motion fix: the
CoreAnimation preview compositor (`useAppKitPreview`) — 17/17 static states
≤1.5/255 but spring motion must step per tick; motion-sequence tests are the
re-enable gate.

Remaining SwiftUI (in dependency order, each behind a working fallback):
1. Timeline VIDEO/VOICE rows hosted inside the native canvas —
   VideoTrackContent (~1.2k lines: thumbnails, waveform, segments, speed
   regions, splits, slice tool, trim) + VoiceOverTrackContent (~0.9k lines:
   clips, live recording waveform). Largest single conversion left; port as
   its own dedicated effort with editing-behavior tests.
2. Editor shell layout (EditorShellView/EditorWindowRootView: toolbar row,
   stage/inspector/timeline split) — requires extracting a shared
   PlaybackController from EditorView first.
3. Recording panel content (FloatingPanelController) + status-item menu
   content (MenuBarView) — recording-critical; convert with the source-switch
   flow protected by a live recording test.
4. Deliberate fallbacks retained until the above land: PreviewView (SwiftUI
   preview), legacy inspector column, SwiftUI app shell (CappdApp, since deleted).


## Keyboard sounds (shipped 2026-08-02)

Synthesized typing sounds play at the exact moments keys were pressed during
the recording — three styles (Thock, Clacky, Soft) with deterministic
per-keystroke pitch/level variation so preview and export render identical
audio. Capture stores ONLY {timestamp, coarse category (key/space/return/
delete/modifier)} — key identity (which key / what was typed) is deliberately
never recorded. A future on-screen keystroke overlay would need opt-in
key-identity capture as a separate, clearly-labelled setting.
