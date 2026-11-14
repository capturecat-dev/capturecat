# iOS studio — Phase 0 decision record

Status: **Phase 0 done; owner decisions in §5 before Phase 1** (2026-11-14).
Plan: `docs/ios-studio-plan.md`. Spike code, scripts and raw JSON results: `apps/ios-spikes/`
(throwaway, never ships). Baseline harness: `apps/macos/scripts/render-baseline.sh`.

Every number here was measured; nothing is estimated. Where it says **Simulator**, the result
proves only that the code works (the Simulator decodes and renders on the Mac's hardware).
Performance, memory, thermal and background numbers come from the phone, or are marked
**not measured**.

| Where | What |
|---|---|
| Mac | Apple Silicon, macOS 26.7.1 (25G241), Xcode 27.0 (27A266a) |
| Phone | **iPhone 15 Pro Max** (iPhone16,2, A17 Pro, 6 cores, 7.6 GB, 120 Hz), **iOS 27.2 beta (24B5089g)** — every device number below is from this beta, not a shipping iOS 26 |
| Simulator | iPhone 17 Pro, iOS 26.2 runtime |
| iPad | **None available. Every iPad number is not measured.** |

## 0. Summary

- **The baseline works:** two snapshots of one commit compare identical (§1). It needed two
  harness-only determinism fixes. AVFoundation's audio mix turns out not to be bit-reproducible
  at all, so audio is compared with a tolerance.
- **Video surface:** the Mac's exact path works unchanged on iOS: `layer.contents = IOSurface`
  from `AVPlayerItemVideoOutput`, pulled by its 60 Hz `Timer`. Warm runs show 59.5–59.6 fps with
  0–1 source frames skipped, the same as a `CADisplayLink` driver, at ~90 MB. `CAMetalLayer`
  paces perfectly but peaks at 596 MB. **Keep the shared driver.** One cold first run stalled
  (§4).
- **Decode:** the A17 Pro decodes 5120×2880 HEVC at 1.75× realtime and 3456×2234 at 3.4×. **Edit
  proxies are not needed** on this class of device.
- **Motion blur and dissolve:** iOS CoreAnimation ignores both filters (measured on the device).
  - The dissolve has a cheap exact replacement: a CI pass over the camera stacks, 1.7 ms per frame.
  - A per-frame CI motion-blur pass costs 11.7 ms mean / 20.2 ms p95 on this phone, too much for
    60 fps. Recommendation: blur via CI only while paused or scrubbing, and accept a documented
    parity exception during playback (§3.3).
- **Fonts:** 17 of 80 family×weight pairs draw a different face on iOS. All 17 are fixable by
  sharing the Mac's resolution as a name table (§3.6).
- **Export:** 4K30 CoreImage→HEVC runs at **≈45 fps (1.5× realtime) at every pipeline depth**,
  while peak memory grows from 757 MB (depth 2) to 1,590 MB (depth 8). **Use depth 2 on iOS**;
  the Mac's 8 buys nothing on this phone.
- **WhisperKit `base.en`:** 60 s of speech in 2.2 s (≈20× realtime), 2% WER, 232 MB peak. The
  first run pays a 15 s download and 8.8 s of CoreML specialization. **Feasible.**
- **Background GPU export:** the iPhone 15 Pro Max **does not support** `.gpu` for
  `BGContinuedProcessingTask`: `supportedResources` is empty, even with the entitlement. A
  request *without* `.gpu` kept a CoreImage 4K export running in the background at full speed
  (900/900 frames, 45 fps). Whether those background frames rendered correctly is **not
  verified** (§3.8).
- **Reference canvas:** the Mac's default editor window gives a **586.7×330 pt** canvas. The Mac
  already exports differently depending on window size, and headless/MCP exports use scale 1, so
  the same project exports up to 3.3× apart in padding. This is the data for the
  `referenceCanvasSize` decision (§3.4).

## 1. Render baseline (proof of zero Mac behaviour change)

`render-baseline.sh snapshot <dir>` builds an unsandboxed Debug copy. It captures:

- the web vectors (140 units, including `projectMerge` over the committed merge fixtures);
- the exporter's lossless pre-encode tap frames for all 23 web-parity fixtures (246 frames) and
  their camera paths;
- the cursor-sprite manifest;
- the audio fixtures;
- the 63 `--preview-parity` and 32 `--raster-golden` artifacts.

`compare <a> <b>` exits 0 only when the two snapshots match. CLAUDE.md §3 now says how to use it.

Two snapshots of the same commit did **not** match at first. Every root cause was in a fixture
or below our code:

| Category | Cause | Fix |
|---|---|---|
| web-vectors `projectDecode` | `CameraLayoutRegion.init(from:)` mints a fresh `UUID()` for a region with no id (2 of 1,500 cases). The web suite already ignores that field. | **Harness only.** The vector replaces an id that appears nowhere in the input with a UUID seeded by case and region (`WebVectors+Model.swift`). Decoding is unchanged. |
| web-parity frames (fixtures 01, 17, 18, 19 — a different one each run) | `SyntheticMovie` encoded its sources with the **hardware** H.264 encoder, which intermittently encoded identical input differently during full fixture runs. Decoded sources differed from frame 1 on; frame 0 never did. Isolated runs, even under heavy encoder load, never reproduced it. | **Harness only.** `SyntheticMovie` now uses the software encoder. That gave 4 consecutive full runs bit-identical, where before about one fixture flipped per run. |
| web-audio `mix.f32` | AVFoundation's mix read-back (`AVAssetReaderAudioMixOutput`, the exporter's own path) is not reproducible. Every fixture varies by ≤2.4e-7 per sample (≈1 ULP). The `.timeDomain` time-pitch used for speed regions (`ProjectAudioMix.swift:112`) renders differently inside the region and varies the mix length by up to ~660 frames (six runs). The source audio decodes identically every run. | Cannot be made byte-exact without changing product audio code. The script compares mixes at ≤1e-6 (−120 dBFS, 30× below the 16-bit LSB the encoder receives) with equal length, and **reports but does not gate** fixtures with speed regions. |
| preview-parity `motion-tilt-*` | One pixel flips by 1/255 on the tilted card's top edge in 2 of 5 runs of one binary; settled states never move. The cause is below our code: CARenderer, or `CARendererSnapshot` reading back after a fixed 60 ms with a barrier on a *different* Metal queue. | Narrow, visible tolerance: `motion-*` frames may differ by ≤2 px at ≤1/255. |

The final proof was two fresh snapshots of commit `7bd20aa`, same binary sha256 `e8f62587…`:

```
  web-vectors        140/140   identical (diff -r)
  web-parity         246/246   identical (bytes)
  camera-paths        23/23    identical (bytes)
  cursor-sprites       1/1     identical (bytes)
  web-audio            6/11    identical, 4 within tolerance, 1 reported only (audio)
      a1-composed-mix/mix.f32: within 1e-06: 80838 samples differ, worst |Δ| 1.79e-07
      a2-speed-clips-voice/fixture.json: identical except the measured mix frame count
      a2-speed-clips-voice/mix.f32: not gated (speed-region time-pitch is not reproducible) — length 452048 vs 452168 samples, worst |Δ| 0.254
      a3-fast-path/mix.f32: within 1e-06: 66108 samples differ, worst |Δ| 2.09e-07
      manifest.json: identical except the measured mix frame count
  preview-parity      62/63    identical, 1 within tolerance, 0 reported only (pixels)
      motion-tilt-t0.30-ca.png: edge jitter tolerated — 1 px differ (0.000%), worst 1/255
  raster-golden       32/32    identical (pixels)

RENDER-BASELINE IDENTICAL
```

A snapshot takes about 8.5 minutes in Debug, about 5 of them in `--web-vectors`. It writes about
520 MB, of which 375 MB is web vectors.

## 2. Spike results

Raw JSON for every row: `apps/ios-spikes/results/<device>/`. "Phone" means the iPhone 15 Pro
Max on iOS 27.2 beta.

| Spike | Variant | Result | Where |
|---|---|---|---|
| **a** video surface | `Timer` 60 Hz → `contents = IOSurface` (the Mac's `VideoFrameLayerDriver`), 3456×2234@60 HEVC under a 3D-tilted parent | warm runs: **59.6 / 59.5 fps** shown, 0 / 1 source frames skipped, update interval p95 17.5 ms, p99 17.8 ms, 90 MB. **Cold first run: 47.9 fps, 51 skipped, max gap 248 ms** | Phone |
| | same, 5120×2880@60 | 59.3 fps, 0 skipped, p95 17.5 ms, 127 MB | Phone |
| | `CADisplayLink` 60 Hz → `contents = IOSurface` | 59.4–59.7 fps (3 runs), 0–1 skipped, p95 17.6–17.8 ms, 90–100 MB | Phone |
| | `AVSampleBufferDisplayLayer` + render synchronizer | plays (604 samples, 0 decode failures, clock drift 4 µs, 79 MB), but no per-frame introspection while playing, and `drawHierarchy` can't see its content | Phone |
| | `CAMetalLayer` blit | 59.6 fps; presentation interval sd **0.00003 ms**; encode p95 1.1 ms; **596 MB peak** | Phone |
| | all four | work | Simulator |
| **b** HEVC decode | `AVAssetReader`, 3456×2234@60 | **NV12 203 fps, BGRA 195 fps** (3.4× realtime), first frame 20–26 ms, ≤38 MB | Phone |
| | `AVAssetReader`, 5120×2880@60 | **NV12 107 fps, BGRA 105 fps** (1.75× realtime), first frame 31–41 ms, ≤64 MB | Phone |
| | `AVPlayer` 1× + video output (BGRA), both sizes | 598/596 and 593/591 frames obtained, **0 skipped**, first frame 12 / 27 ms | Phone |
| **c** 4K export (3840×2160@30, 300 frames, 3456×2234 source) | depth 2 / 3 / 5 / 8 | **44.5 / 44.6 / 44.8 / 44.9 fps** (1.48–1.50× realtime); peak footprint **757 / 1,112 / 1,272 / 1,590 MB**; min `os_proc_available_memory` 2,649 / 2,323 / 2,134 / 1,845 MB; render wait p50 13 / 17 / 21 / 24 ms; thermal nominal throughout; depth 2 repeated within 1% | Phone |
| **d** filters on iOS CA | `filters = [CIMotionBlur]`, `compositingFilter = CIAdditionCompositing`, `"plusL"` | blur **ignored** (edge step 249 → 249); CIAddition **ignored** (source-over 126,62,0); `"plusL"` **additive** (125,125,0) | Phone (and Simulator) |
| | per-frame CI cost, 2200×1240 card | motion-blur pass **11.7 ms mean / 20.2 p95 / 26.5 max**; additive dissolve pass **1.7 / 2.5 / 3.7 ms**; plain copy 2.4 ms. Budget at 60 fps: 16.7 ms | Phone |
| | visual delta vs the Mac, real compositor | see §3.3 | Mac |
| **e** fonts | 16 families × 5 `SubtitleWeight`s | **17 / 80 pairs draw a different face**: 12 because UIKit's weight matching picks a different family member than `NSFontManager` (the Mac's face exists on iOS), 5 because `SF Mono` isn't an iOS family. The system face is identical (widths equal to 0.1 pt). Same result on the phone and in the Simulator (`fonts-diff.md`) | Phone |
| **f** WhisperKit 0.15.0 `base.en` | first launch / later launch | download 15.1 s (147 MB); load + prewarm **8.8 s** first, **0.33 s** later (plus 2.4 s of Hugging Face metadata check even when cached); 60 s of speech in **2.2 s (≈20× realtime)**, WER 0.02, peak 232 MB | Phone |
| **g** background export | `BGTaskScheduler.supportedResources` | **empty — no background GPU** on this phone (and in the Simulator), with the entitlement granted | Phone |
| | request **without** `.gpu`, app backgrounded via Settings | accepted and ran at once; app `inactive` at 4.0 s, `background` after that; **900/900 frames at 45.1 fps**, no expiry, peak 1,272 MB. **Content of the background frames not verified**: the re-run with a decoded-frame check lost its result. My reading (not confirmed) is that iOS suspended the app once the task had completed, before the post-export check finished | Phone |
| **h** reference canvas | `--editor-shell-shot` at several window sizes | requested 1100×700 resolves to **1212×700 content → card 803×330 → canvas 586.7×330 pt** (16:9); 1280×800 and 1400×800 → 764.4×430; 1728×1080 and 2560×1400 (screen-limited to 949 pt high) → 1029.3×579 | Mac |

## 3. Decisions and recommendations

### 3.1 Minimum device

**Recommendation: A17 Pro / M-series with 8 GB** (iPhone 15 Pro / Pro Max and later; iPad mini
A17 Pro; iPads with M1 or later). This is the only class measured, and it has headroom
everywhere:

- 5K decode at 1.75× realtime;
- 4K export at 1.5× realtime using 757 MB of a ~3.4 GB app budget;
- Whisper at 20×.

6 GB / A15–A16 devices are **not measured**. Don't widen the floor without running
`apps/ios-spikes/run-device.sh` on one. iPads are not measured.

The plan's iOS 26 floor is still unverified on a device: these numbers are from iOS 27.2 beta.
iOS 26.2 is verified only for functionality, in the Simulator.

### 3.2 Video surface

**Keep the Mac's exact path as shared code:** `AVPlayerItemVideoOutput` (BGRA, IOSurface) →
`layer.contents = IOSurface`, pulled at 60 Hz.

- Warm, it matches a `CADisplayLink` driver to within measurement noise.
- `CAMetalLayer` is not worth 6× the memory.
- `AVSampleBufferDisplayLayer` gives up per-frame control (which the masked camera looks and the
  blur patches need).

Add a decoder pre-warm when a project opens; that addresses the one cold-start stall (§4).

### 3.3 Motion blur and camera-look dissolve

Measured on the **real Mac compositor** with the `--preview-parity` fixture. The scratch harness
is `apps/ios-spikes/mac/scratch/scratch.patch`. "Naive" strips every CA filter, which is exactly
what iOS CoreAnimation does (verified on the phone).

| Effect | State | iOS naive vs Mac preview | Gate units |
|---|---|---|---|
| Motion blur, strength 0.5 | zoom 1→2, +0.10 / 0.15 / 0.20 / 0.30 s | mean 0.5–1.4/255, worst 148–154, 1.8–5.9% of px >8/255 | fingerprint cell Δ **3 / 5 / 7 / 9** (bar 2) |
| Motion blur, strength 1.0 | same | mean 0.6–2.3/255, worst 153–186, 2.1–12.3% of px >8/255 | fingerprint cell Δ **5 / 6 / 7 / 19** |
| Dissolve bubble→cutout | w = 0.10 / 0.50 / 0.90 | naive (source-over): worst **14 / 38 / 14**, 4.5 / 20 / 4.5% of camera px >8 | the gate's `crossfade-true-dissolve` FAILS (0.657 of px == lerp; needs ≥0.95) |
| | | `"plusL"`: worst **1–2/255**, 0% >8; vs the gate's lerp reference, the same as the Mac itself (mean 0.74 vs 0.74) | passes |

Findings:

1. **The frozen goldens don't cover either effect.** With every CA filter stripped, all 31
   fingerprinted/structural states still pass; only `crossfade-true-dissolve` catches the
   dissolve. Phase 2 must add frozen motion-blur (mid-zoom) and mid-dissolve states on the Mac
   first, then score iOS against them.
2. **Dissolve: use a CI pass over the camera stacks, only while two stacks are visible** (the
   0.45 s transition). It costs 1.7 ms per frame on the phone, and it uses the exporter's own
   additive math (`compositeCamera`), so it equals export by construction. `"plusL"` measured
   within 2/255, but it is an undocumented CAFilter name; keep it as an emergency fallback only.
3. **Motion blur: no per-frame CI pass during playback.** At 11.7 ms mean / 20.2 ms p95 for the
   card alone, it overruns a 60 fps frame. Recommendation: while **paused or scrubbing**, show
   the card blurred by the exporter's own `CIMotionBlur` code (exact); during **playback**,
   accept a documented parity exception (no blur, measured cost above: blur exists only while the
   camera moves). This is the owner's call (§5). If the owner rejects the exception, the next
   thing to measure is a half-resolution blur pass (not measured).

### 3.4 Reference canvas (`referenceCanvasSize`)

The exporter scales every point-sized setting by `outputSize / previewCanvasSize`
(`VideoExporter.swift:348-360`). `previewCanvasSize` is the live editor canvas (not persisted,
`@ObservationIgnored`); headless/MCP exports use the output size, i.e. scale 1.

| Where the export was made | Canvas | 1080p scale | 48 pt padding becomes |
|---|---|---|---|
| Mac, default window (1100×700 → 1212×700 content) | 586.7×330 | 3.27× | 157 px (8.2% of width) |
| Mac, 1280×800 or 1400×800 window | 764.4×430 | 2.51× | 121 px (6.3%) |
| Mac, full screen 16"/27" (height-limited) | 1029.3×579 | 1.87× | 90 px (4.7%) |
| MCP / CLI / headless | — | 1.00× | 48 px (2.5%) |

So **the Mac already exports one project four different ways.** An iPhone stage would add more
(roughly 360–800 pt wide). Recommendation:

- Persist an optional `referenceCanvasSize`.
- When it is present, every renderer uses it: iOS (rendering at that virtual size and
  magnifying), web, headless, and the Mac exporter.
- Projects without it keep today's behaviour exactly.
- The default for a new project is the Mac's default-window card letterboxed to the project
  aspect (586.7×330 at 16:9). This is the value most existing exports already used.

Whether the Mac *preview* adopts it too, making Mac exports window-independent, is a Mac
behaviour change and the owner's call (§5).

### 3.5 Edit proxies

**Not needed** on the recommended floor. The phone decodes 5120×2880@60 HEVC at 1.75× realtime
and plays it at 1× with 0 skipped frames, and the export pipeline already reads a 3456×2234 source
at 2:1 without being decode-bound (decode 195 fps BGRA vs ≈90 source frames/s needed). Revisit
only if the floor drops below A17 Pro.

### 3.6 Fonts

All 17 gaps are fixable without changing Mac output:

- **Weight matching (12):** resolve through a shared table of family × weight → PostScript name,
  generated from today's Mac `NSFontManager` resolution and frozen. The baseline proves the Mac
  draws the same. Every face in the table exists on iOS.
- **SF Mono (5):** map to iOS's `.monospaced` system design (advance widths equal to the Mac's
  `SFMono-*` to 0.1 pt).

The system face needs nothing. Caveat: on a Mac where the user installed Apple's SF families,
"SF Pro Rounded" and "New York" resolve to real faces. On this Mac they fall back to the system
face, so neither has a measured iOS equivalent yet (iOS has `.rounded` / `.serif` designs).

### 3.7 WhisperKit

**Feasible as is** (same package version and model as the Mac): 20× realtime and 232 MB. Two
product notes:

- The first transcription on a device pays about 24 s (download plus CoreML specialization), so
  show progress.
- `WhisperKit.download` hits the network even when the model is cached (2.4 s). Load from the
  stored model folder when it exists, or transcription won't work offline (offline not measured).

### 3.8 Background export

- **Background GPU is unavailable on the iPhone 15 Pro Max** (iOS 27.2 beta):
  `BGTaskScheduler.supportedResources` is empty, with the entitlement granted by automatic
  signing. Not measured on any iPad (the API's documentation says GPU background is device
  dependent).
- **Without `.gpu`, the request still ran.** The export carried on at full speed in the
  background (45 fps, the same as the foreground). It is **not verified** whether CoreImage's
  Metal work produced correct frames there, or whether the system quietly allowed GPU access for
  the task's duration. Phase 3 must check this first: decode the background stretch of a real
  export, compared with a foreground export of the same project.
- **Do everything before `setTaskCompleted`.** In the verification re-run, the post-export frame
  check never wrote its result, consistent with iOS suspending the app once the task had completed
  (not confirmed). Saving to Photos or uploading must happen inside the task.
- Recommendation: on iPhone, plan for **foreground export with a background continuation that is
  "best effort" until verified**, and keep the user-facing promise to "keep the app open" until
  Phase 3 proves background frames correct.

## 4. Risks that changed

| Risk (plan) | Now | Why |
|---|---|---|
| 5K HEVC won't decode → proxies | **gone** on A17 Pro | 1.75× realtime decode, 0 skipped at 1× |
| IOSurface layer contents at 60 fps | **gone** | Mac path ≈ display link, ~90 MB |
| Export memory/thermal (plan: depth 3–5 on 8 GB) | **lower, but bigger numbers** | depth 2 = same throughput at 757 MB; depth 8 is 1.59 GB (the plan's 265 MB pipeline estimate was far too low) |
| Fonts differ | **lower** | all 17 gaps fixable with a name table |
| WhisperKit on iOS | **gone** | 20× realtime |
| Motion blur / dissolve | **higher for blur, solved for dissolve** | blur CI pass overruns the frame budget, so a playback parity exception (owner decision); dissolve has an exact 1.7 ms CI pass |
| Background GPU export | **higher** | unsupported on iPhone 15 Pro Max; without `.gpu` the export ran in the background, but its frames are unverified |
| Goldens cover what iOS changes | **new gap** | no frozen state exercises blur or dissolve |
| Exports reproducible across Mac/iOS/web | **new, pre-existing on the Mac** | exports depend on window size and headless vs editor (§3.4) |
| Preview↔export audio parity | **new** | AVFoundation's mix isn't bit-reproducible; only a tolerance gate is possible |
| Measurements represent shipping iOS | **new caveat** | device numbers are from iOS 27.2 beta; no iOS 26 device and no iPad measured |
| First play stalls | **new, small** | one cold run: 47.9 fps, 248 ms gap; warm runs clean. Pre-warm the decoder on project open |

## 5. Questions the owner must answer before Phase 1

1. **Minimum device.** A17 Pro / M1 with 8 GB is the only measured class. Approve it as the studio
   floor, or provide a 6 GB / A15–A16 phone (and an iPad) to measure first? Are iOS 27.2-beta
   numbers acceptable, or should one run happen on a shipping iOS 26 device?
2. **`referenceCanvasSize`** (§3.4). Persist it (optional key, absent = today's behaviour)? Is the
   default the Mac's default-window canvas (586.7×330 at 16:9)? Should the **Mac preview/export
   also adopt it**, making Mac exports window-independent? That last one is a Mac behaviour
   change.
3. **Motion blur during playback** (§3.3). Accept a documented parity exception (no blur while
   playing; exact exporter-rendered blur when paused or scrubbing), or fund measuring a
   reduced-resolution CI blur pass first?
4. **Background export** (§3.8). There is no background GPU on iPhone 15 Pro Max. Is "keep the app open" export on iPhone acceptable for the first release, with background export added only once Phase 3 verifies the frames rendered without `.gpu`?
5. **Fonts** (§3.6). Approve replacing `FontCatalog`'s live `NSFontManager` lookup with a frozen
   family×weight→PostScript table shared by both platforms (Mac output unchanged, proven by the
   baseline)?
6. **Audio.** Accept that preview↔export audio parity is gated with a tolerance (AVFoundation is
   not bit-reproducible), with the time-pitch path for speed regions not gated at all?

## 6. Found along the way (not fixed here)

- `--export-formats-test` fails one check on `main` (`f8cc6f0`): "camera-layout key: 10 fields
  (two look weights appended)". The same single failure appears with and without this branch.
- **Exported audio is not bit-reproducible** (§1). With speed regions, the sped-up stretch differs
  between two exports of the same project. This is presumably inaudible (time-domain splice
  points), but it means preview↔export audio can only ever be gated with a tolerance.
- **Exports already depend on the window** (§3.4): `previewCanvasSize` is the live window's
  canvas and is not saved, so the same project exports with different padding, corner and shadow
  proportions depending on the window size at export time, and differently again from MCP/CLI.
- **`FontCatalog` on a Mac without Apple's SF families installed** silently draws "SF Pro
  Rounded" and "New York" as the plain system face (§3.6).
