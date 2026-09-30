# CaptureCat Web Editor — architecture contract (v1)

Owner decision (Mike, 2026-09-29): a 1:1 web version of the Mac editor at
`app.capturecat.so/editor`, protected (signed-in only), "butter smooth, every
functionality, cross-platform", WebGPU. This file is the contract every
contributor builds against. It will live at `apps/web/src/editor/ARCHITECTURE.md`.

## Non-negotiables

1. **Parity is the product.** The web preview AND web export must match the Mac
   app's exporter (`apps/macos/CaptureCat/Services/VideoExporter.swift`, whose
   preview twin is `Views/Editor/PreviewCompositor/PreviewCompositorView.swift`)
   for the same project.json + media. The Mac exporter is the reference.
2. **Never fork math silently.** Every computation ported from Swift lives in
   `apps/web/src/editor/core/` and is LOCKED to the Swift original by golden
   vectors: the Mac binary (`CaptureCat --web-vectors <dir>`) evaluates the real
   Swift function over thousands of inputs and writes JSON; a vitest suite
   asserts the TS port matches within 1e-9 (numbers) / exact (enums, ints).
   A port without vectors is not done. Render parity is gated separately by
   frames from the real exporter (`CaptureCat --web-parity-fixtures <dir>`).
3. **Lossless project.json.** The web must never corrupt a Mac project. Parse →
   edit → serialize must round-trip every key, including keys the web does not
   understand (preserve unknown keys verbatim). Swift enum raw values are
   persistence identity — use them byte-for-byte. Missing keys decode to the
   same defaults the Swift `decodeIfPresent` uses.
4. **Butter smooth.** 60 fps preview at 1080p on a MacBook Air-class GPU.
   Nothing per-frame touches the DOM or React state. Rendering runs in a Web
   Worker on an OffscreenCanvas; the timeline and stage are `<canvas>`, not
   DOM. React owns panels/forms only.
5. **No SwiftUI / no AppKit rules apply to the web**, but the LOOK is the Mac
   app's: CCKit tokens, skeuomorphic material, CCMotion curves (see Design).

## Stack

- WebGPU (required for the editor; if `navigator.gpu` is missing, show a clear
  "use Chrome/Edge 113+, Safari 26+, or Firefox 141+" screen — no silent WebGL
  path in v1).
- WebCodecs `VideoDecoder`/`VideoEncoder`/`AudioDecoder`/`AudioEncoder` for
  hardware decode/encode; demux/mux with `mediabunny` (MP4/MOV in, MP4 out).
- Frames: decode → `VideoFrame` → `GPUDevice.importExternalTexture` (zero-copy).
- WebAudio for playback mix (system audio, mic, voice-over, click/key sounds);
  the audio clock is the master clock while playing.
- React 19 + TanStack Start (existing app) for panels. Zustand-free: a tiny
  in-house store (`editor/state/store.ts`) with immutable project updates,
  selectors, and an undo stack (`apply_edits`-style batches).
- Tests: vitest (unit + golden vectors); headless system Chrome via
  `playwright-core` (`channel: "chrome"`, no browser download) for render
  parity + perf.

## Layout of `apps/web/src/editor/`

```
ARCHITECTURE.md
core/            pure TS, no DOM, no WebGPU — runs in worker AND main thread
  model/         Project + every model type, parse/serialize (lossless)
  time/          SpeedTimeMap, clip/trim math (source ↔ output)
  math/          ports: TiltMath, ReactiveCameraLayout, ZoomFocalMath,
                 CursorSpringMath, CursorPhysicsMath, CursorSmoother,
                 AnnotationEffectMath, TapRippleMath, PreviewMotionModel,
                 DeviceFrameLayout, PlacementMath, FocusMath, BlurStyleMath,
                 MotionBlurMath, IntroSlideMath, CurtainUnveilMath,
                 CameraLayoutMath, CameraStyleMath, KeystrokeOverlay math,
                 ClickRippleOverlay.discreteClickTimes, RecordingClock …
  frame/         frameStateAt(project, assets, outputTime) → FrameState: the
                 exporter's per-frame decisions (camera, cursor pose, active
                 annotations/regions, subtitles…) as plain data
  vectors/       golden-vector loader + vitest suites
engine/          the renderer (worker side)
  worker.ts      OffscreenCanvas + GPUDevice owner, message protocol
  gpu/           device, pipelines, WGSL shaders, texture/pool utils
  passes/        one pass per feature (background, card, cursor, …)
  media/         demux (mediabunny), decode, frame cache/seek, audio
  export/        VideoEncoder + mp4 mux (same passes → frame-identical)
  client.ts      main-thread proxy (typed postMessage API)
state/           store, selectors, undo, persistence (cloud + local)
ui/              React: shell, top bar, stage, transport, timeline (canvas),
                 inspector rail + panes, design tokens + primitives
webmcp/          document.modelContext tool registration (same catalog as
                 the Mac MCP server's MCPServer+Catalog)
lab/             DEV-ONLY fixture loader (never in prod bundles)
```

Routes (TanStack file routes, NOT nested under the dashboard sidebar layout):
`src/routes/app_.editor.tsx` (project picker / recent cloud projects) and
`src/routes/app_.editor.$projectId.tsx` (the editor). Both guard with the same
`fetchSession()` + redirect-to-/login the `/app` layout uses.
`src/server.ts` already maps `app.capturecat.so/*` → `/app/*`, so
`app.capturecat.so/editor` resolves to `/app/editor`. A DEV-only lab route
(`/editor-lab`, gated by `import.meta.env.DEV`) loads fixture projects with no
auth for local development — it must be absent from production builds.

## Time domains (the #1 bug source — mirror the Mac exactly)

- SOURCE seconds: position in the original recording. All regions, effects,
  annotations, clips, trim, cursor events live in source time.
- OUTPUT seconds: position in the exported video after trim + speed regions.
  Playhead, timeline ruler (check the Mac TimelineCanvasView), render/export
  frame times use OUTPUT. Convert with the `SpeedTimeMap` port
  (`Services/SpeedTimeMap.swift`, incl. `init(trimmedOutputOf:)` and
  `Project.exportedOutputDuration`).
- Coordinates: normalized 0–1 of the recorded frame, Y-DOWN, unless a Swift
  type says otherwise. CIImage space is Y-up in the exporter — port the math,
  not the coordinate accidents; keep one convention (Y-down) in TS and convert
  at the GPU boundary.

## Data flow

project.json (+ media URLs) → `core/model.parseProject` → store →
(main) selectors drive React panels; timeline canvas reads the store directly
→ (worker) engine receives project snapshots (structured clone, only on
change) + transport commands (play/pause/seek/rate) → for each vsync:
`frameStateAt(outputTime)` → passes encode GPU commands → present.
Export: the SAME engine, stepping output time at the export fps, into
`VideoEncoder` instead of the canvas. Preview == export on the web by
construction; web == Mac by the parity gate.

## Storage

Cloud projects (API worker `apps/api`, D1 + R2): the Mac app uploads a project
bundle (project.json + recording + cursor/keystroke JSON + camera/voice-over
media + referenced images) with "Open in Web Editor"; the web loads media via
short-lived presigned GETs and saves project.json with optimistic concurrency
(revision number → 409 on conflict). The Mac app can pull the web's edits back.
Storage counts against the plan quota (existing storage accounting,
migration 0025). Never deploy; never touch production secrets.

## Design (1:1 with the Mac editor)

Reference captures: run the built Mac app with `--editor-shell-shot` (writes
`~/Library/Containers/so.capturecat.CaptureCat/Data/tmp/capturecat-editor-shell/`).
Tokens from `Views/Shared/DesignKit/CCTheme.swift` (capDark / capLight),
material recipes from `CCMaterial.swift` (raised keys: top-lit 3-stop gradient
+ darker 2pt under-edge + soft top light + soft drop shadow; recessed wells:
top-shaded gradient + quiet inner shadow; NO glass sheen, ever), motion from
`CCMotion.swift`: settle `cubic-bezier(0.22,1,0.36,1)`, glide
`cubic-bezier(0.4,0,0.2,1)`, bounce `cubic-bezier(0.34,1.56,0.64,1)`; springs
snappy (response .28, damping .9), smooth (.42, 1.0), bouncy (.42, .68).
Radius law: sm 4 (row highlights), md 6 (buttons), lg 10 (menus/cards), xl 16
(dialogs), full = pill. Press = tint in place (never move/scale). No rings on
click/selection; ink-coloured focus ring on text inputs only. Slider readouts
never show px/pt.

## Hygiene

- Never commit real user media or real project.json files. Fixtures are
  synthetic (Mac `--web-parity-fixtures`, ffmpeg-generated video) and live in
  gitignored `apps/web/.fixtures/`.
- Never deploy, never run migrations against remote D1, never touch secrets.
- Dev servers: web `vite dev` on your own port (3201–3209; check
  `lsof -iTCP:<port> -sTCP:LISTEN` first — other projects squat 3000/3001/8787).
- `npm run typecheck` in apps/web must stay clean for the files you own.

## Core gates (how to run them)

1. Build the Mac app (Debug) and resolve YOUR binary with
   `xcodebuild -project apps/macos/CaptureCat.xcodeproj -scheme CaptureCat -configuration Debug -showBuildSettings | grep ' BUILT_PRODUCTS_DIR'`.
2. Golden vectors: `CaptureCat --web-vectors vectors [--only unitA,unitB]` (sandboxed: a bare
   name lands in the container tmp; the path is printed) → `apps/web/scripts/sync-vectors.sh <dir>`
   → `npm test` in apps/web. Every unit's JSON records `notes` naming the Swift it locks;
   a missing unit FAILS with these instructions.
3. Render-parity fixtures: `CaptureCat --web-parity-fixtures parity` →
   `apps/web/scripts/sync-parity-fixtures.sh <dir>`. Each fixture carries the real exporter's
   reference PNGs (decoded from its HEVC output — compare with a tolerance), its frame clock and
   its own `CAPTURECAT_DUMP_CAMERA` camera path.
4. Project round trip: `CaptureCat --web-roundtrip-check <file|dir> [--against <original|Projects root>]`
   decodes web-serialized project.json with the real Codable (prints key paths only, never
   values). Local real-project check: `CC_REAL_PROJECTS=1 [CC_REAL_PROJECTS_OUT=<container tmp dir>] npx vitest run src/editor/core/vectors/realProjects.test.ts`
   — read-only, counts only; delete the OUT dir afterwards.

Swift semantics every port must use (see core/math/swift.ts, geometry.ts, libm.ts):
`min`/`max` by comparison (NaN/-0), `rounded()` ties away from zero, `String(format:"%.Nf")`
exact half-even, `CGRect.width` absolute, Darwin `hypot` (not Math.hypot), and
`CMTime(seconds:preferredTimescale:)` TRUNCATES (exportLayout.cmTimeValue).
