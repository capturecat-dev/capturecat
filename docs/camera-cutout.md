# Camera cutout and pop-out card

Two new camera looks, built on the Mac and in the web editor at the same
time so both render the same project identically (CLAUDE.md §2, web
`ARCHITECTURE.md` non-negotiables 1–3). This file is the contract both sides
implement; change it before changing either side.

- **Cutout** — the webcam with its background removed, standing directly over
  the screen recording. No card, ring or stroke.
- **Pop-out card** — the cut-out person on a rounded gradient card; the head
  breaks out above the card's top edge.

Owner decision (Mike, 2026-10-27): both platforms together, from day one.

## 1. Model — an optional `look` on a Bubble region

Old builds throw on an unknown `CameraLayoutMode` raw value and the whole
project disappears from their library (CameraLayoutRegion.swift:62 →
Project decode → `ProjectStore.loadAll` skips it). So the looks are **not**
new modes. A region keeps `mode: "bubble"` and gains an optional key:

| key | type | values (raw = persistence identity) | default |
|---|---|---|---|
| `look` | string? | `"cutout"`, `"popOut"` | absent = the plain bubble |

- Decode leniently: a missing or unknown `look` is `nil`. Encode only when
  non-nil, so untouched projects stay byte-identical.
- `look` only takes effect while the region's `mode` is `bubble`; on any other
  mode it is ignored (kept, not dropped).
- Old builds ignore the key and draw a plain bubble — a safe fallback.
- Same change, both sides: an unknown `mode` raw value now decodes to `bubble`
  (missing still decodes to `cameraOnly`, as today), so a future mode can never
  drop a project again. Web `core/model` mirrors both rules exactly.
  - Exactly: decode the raw value as a STRING (`decodeIfPresent(String.self)`);
    missing or null → `cameraOnly`; a string that is not a raw value →
    `bubble`; a non-string (e.g. `5`) still throws, as today. `look` is
    `(try? decodeIfPresent(CameraLook.self)) ?? nil` (missing, null, unknown or
    mistyped → nil, never throws).
  - Consequence for the vectors: the existing `projectDecode` case with the
    mutation `badEnum ["cameraLayoutRegions", 0, "mode"]` flips from
    `{error: true}` to a decoded project; it changes once, regenerated from the
    Mac binary (web is already on the new rule).

## 1a. The whole-video look — `settings.cameraLook`

Owner decision (Mike, 2026-10-28): background removal must be a Camera-panel
choice for the whole video, not only a timeline block.

| key | type | values | default |
|---|---|---|---|
| `settings.cameraLook` | string? | `"cutout"`, `"popOut"` (raw values = `look`'s) | absent = the plain bubble |

- Same lenient rules as `look`: missing, null, unknown or mistyped → absent;
  written only when set, right after `cameraMirrored`.
- `look(at:)` gains the default: outside every region → `cameraLook`; inside a
  `bubble` region → its own `look`, else `cameraLook`; any other mode → none.
  Blocks therefore still override it for their span and §4's edge easing
  applies unchanged (no intro morph, so it is settled from frame one).
- "Uses a look" (segmentation queue, mask fetch, export mask gate) counts
  `cameraLook` too.
- Surfaces: Mac Camera pane and web `CameraPane` — "Background: None / Cutout /
  Pop-out card", first row under the pad; MCP / WebMCP `set_style` key
  `cameraLook` (`"none"` clears it). It never adds a timeline block.
- Vectors: `cameraLookWeights` cases carry an optional `defaultLook`;
  `exportCameraFrame` settings carry `cameraLook` when set.

## 2. The mask track — `camera-mask.ccmask`

The shared source of truth for "where is the person". Format and codec:
`apps/web/src/editor/core/mask/cameraMaskCodec.ts` (spec in its header) and its
twin `apps/macos/CaptureCat/Services/CameraMaskTrack.swift`.

- Lossless: per-frame 8-bit alpha, raw DEFLATE, key frames + XOR deltas (the
  encoder keeps whichever is smaller; a key at least every `keyframeInterval`).
  Decoded bytes are identical whoever wrote the file.
- **Resolution (producer rule):** `height = 192`, `width = round(192 ×
  cameraAspect)` capped at 341 (16:9 → 341×192, 4:3 → 256×192, 9:16 →
  108×192; a non-finite or non-positive aspect counts as 1). Changed from
  288/512 on 2026-10-27 for size (§6, producer alpha conditioning) — 192 rows
  show no edge loss at bubble sizes. The DECODER takes width/height from the
  header, so a 288-row file written earlier still renders; only producers
  use this rule (Mac `CameraMaskTrack.maskSize`, web
  `core/mask/conditionAlpha.ts producerMaskSize`; web
  `core/math/cameraCutoutMath.ts maskSize` still carries the old 288/512 and
  is no longer called by the producer — update or delete it). Row 0 is the TOP of the camera image as decoded, before
  any mirroring.
- **Time:** frame times are camera-source PTS seconds (raw, not trimmed or
  normalized). The mask for a camera sample at PTS `t` is `frameIndexAt(t)`:
  the last frame with time ≤ t, clamped to frame 0.
  - Look up by the PTS of the camera frame actually DRAWN, never the target
    time, or an edge can pair a frame with its neighbour's mask. (Web: the
    demuxed sample PTS + the demuxer's 1e-6 s tolerance, so float noise in a
    container timescale can never land on the previous mask frame.)
  - "PTS" means the presentation time of the DECODED sample, i.e. with the
    track's edit list applied (Mac: an `AVAssetReaderTrackOutput` with
    decoding output settings — what the exporter's camera reader and the
    segmentation job use). A passthrough (`outputSettings: nil`) read is NOT
    it: for an H.264 file with B-frames it returns every PTS shifted by the
    composition offset (measured: +2 frames on the synthetic 30 fps camera),
    which would pair each frame with its neighbour's mask. Web: confirmed
    post-edit-list — mediabunny's packet timestamps for `16-camera-looks`'
    camera.mp4 (H.264, has_b_frames=2, DTS from −0.0667 s) are 0, 1/30, …,
    5.9667 s, identical to the mask's frame times and to ffprobe's display
    PTS; the renderer's lookup (`DemuxedVideo.frames[i].pts`) and the web
    segmentation worker (sample PTS mapped through the same index) use them.
  - Mac export: `currentCameraSampleTime`. Mac preview: the player item time
    `+ trimmedLeadIn` (the preview plays a normalized asset). Web: the drawn
    frame (`plan.source.frame`) timestamp; mask decode is async, so it joins
    the camera's prefetch and seek-wait gate (`prefetch`, `previewWait`).
  - Before the camera starts, both sides show the poster; a look draws the
    poster through mask frame 0.
- **Where:** beside the camera file, i.e. the project folder
  (`camera.mov` → `camera-mask.ccmask`; Mac `CameraMaskTrack.url(besideCamera:)`).
- **keyframeInterval:** both producers write 30 (any value decodes).
- **Staleness:** usable only when `sourceByteSize` equals the camera file's byte
  size and `|sourceDuration − camera duration| ≤ 0.05 s` (Mac: camera duration
  = the asset duration). A missing or stale
  mask renders every look as the plain bubble (both sides, same rule) and
  queues segmentation.

## 3. Geometry — `CameraCutoutMath` (Swift original, TS port, golden vectors)

Input: the bubble rect `B` that `ReactiveCameraLayout` already produces (size,
position, orientation unchanged), the camera image aspect `a` (width ÷ height
after orientation), the card corner radius rule.

- **Person rect** `P = aspectFill(a, B)`: the camera image scaled to cover `B`,
  centred. The mask is scaled to exactly the same rect. Exactly the exporter's
  `compositeCamera` fill with `camExtent = (0, 0, a, 1)`:
  `fillScale = max(B.width / a, B.height / 1)`, size `(a·fillScale, fillScale)`,
  origin `(B.minX − (w − B.width)/2, B.minY − (h − B.height)/2)`.
- **Cutout:** clip `P` to `B` (square corners). No other shape.
- **Pop-out card:**
  - `headroom = 0.22 × B.height`
  - card `C = B` with its TOP edge moved down by `headroom` (Y-down terms)
  - card corner radius `r = 0.16 × min(C.width, C.height)`
  - person clip = `B` with the two BOTTOM corners rounded by `r` (top corners
    square, so the head can rise into the headroom)
  - card fill: vertical linear gradient, sRGB, top `(1.00, 0.58, 0.34)` →
    bottom `(0.42, 0.33, 0.96)`, opaque
  - card shadow: the bubble's shadow (radius `6 × sizeFactor`, opacity 0.33,
    `sizeFactor = B.width / base bubble width`) on the card's rounded rect. In EXPORT terms (what the web matches): the
    exporter's bubble shadow (`cameraShapeShadowImage`: black at alpha 0.45,
    `CIGaussianBlur` σ = `6 × canvasScale` at the base bubble) scaled with the
    bubble like the baked assets — σ = `6 × canvasScale × B.width /
    baseRect.width` — on `C` with radius `r`, no offset, cropped to `C` outset by
    `4σ + 4`.
  - rects in the vector unit are returned as built: `clipRect` is `B` exactly as
    passed (not standardized); `cardRect` is
    `(B.minX, B.minY + headroom, B.width, B.height − headroom)`.
- Y: everything above is stated Y-down; the CI path flips with the frame
  height like every other camera rect.

## 4. Cross-fades — `lookWeights`

`CameraLayoutMath` gains `lookWeights(at:regions:) -> (cutout, popOut)`, each
0…1 and summing to ≤ 1. The look at time `t` is the containing region's
`look` when its mode is `bubble`, else none. At each region edge the weights
ease from the look just before the edge to the look after it, over
`transitionDuration` (0.45 s) with the existing `ease` (smootherstep), and the
existing "no morph at edges ≤ 0.05 s" rule applies. No intro morph at t = 0.

Renderers draw, wherever `resolve` puts the camera (`cameraRect` — plain bubble
or mid-morph tile):

```
existing camera drawing × (1 − cutout − popOut)
+ cutout look          × cutout
+ pop-out look         × popOut
```

so bubble ↔ look ↔ look and mode morphs all cross-fade, and a settled look
draws only the look.

Reference algorithm (the same shape as `resolve`; web
`core/math/cameraLayoutMath.ts lookWeights`):

```
look(t)     = region(at: t) where mode == .bubble → its look, else nil
target(l)   = cutout → (1, 0), popOut → (0, 1), nil → (0, 0)
regions empty                        → (0, 0)
boundary    = last of the sorted region edges (start and end) ≤ t
no boundary, boundary ≤ 0.05, or t − boundary ≥ 0.45 → target(look(t))
previous    = look(boundary − 0.001); previous == look(t) → target(look(t))
p           = ease((t − boundary) / 0.45)
            → lerp(target(previous), target(look(t)), p) per component
```

The weights join the fast-export static-span key on both
sides (Mac `ExportFormats.cameraLayoutKey`, web `core/export/staticSpans.ts`
`cameraLayoutKey`) so a span with a fading look is never collapsed.

## 5. Render order (identical on both sides)

```
camera frame → mirror (if mirrored) → CameraStyleMath adjustments
  → × mask alpha (mask scaled to the frame's extent, mirrored with it, bilinear)
  → place into P → clip (cutout: B; pop-out: B with rounded bottom corners)
  → pop-out only: over the card (shadow, gradient) → × weight (summed with the other stacks)
  → same placement/tilt/fade stage as the bubble (it rides what the bubble rides)
```

No ring and no stroke on either look. The name tag draws as it does for the
bubble, relative to `B`.

Compositing, pinned for pixel parity (everything inside `compositeCamera`'s
group, over TRANSPARENT, before the tilt and the opacity fade):

```
bubbleStack = shadow → ring → shape-masked camera → stroke   (today's, minus the tag)
cutoutStack = masked camera, scaledCamera.cropped(to: B)     (ONE crop, no shape mask)
popStack    = card shadow → card → masked camera clipped by personClip
overlay     = scale(bubbleStack, 1 − c − p)                   (omitted when 1 − c − p ≤ 0)
            + scale(cutoutStack, c)                           (only when c > 0)
            + scale(popStack, p)                              (only when p > 0)
            → tag.composited(over:)                           (the tag is NOT weighted)
```

- The weighted stacks are a true cross-dissolve, the SUM of §4's formula:
  `scale(x, w)` multiplies premultiplied RGBA by `w` (CIColorMatrix with only
  the A vector scaled, `(0, 0, 0, w)` — NOT `fadeImage`, whose RGB × w² would
  darken mid-fade), and `+` is `CIAdditionCompositing`. Where both stacks are
  opaque the sum stays opaque, so a cross-fade never dips see-through or
  dark. Each stack is composed over transparent first, then scaled as a
  whole. `scale(x, 1)` is the identity: a settled look (or no look) renders
  byte-for-byte without any extra pass. (The bubble's own opacity fade after
  the tilt keeps using `fadeImage`, unchanged.)
- "masked camera" = the camera (mirror → adjustments) × mask alpha, aspect-
  filled into `B` with the same transform as today.
- `personClip` (pop-out) = `CIRoundedRectangleGenerator(extent: B extended UP
  by r (Y-down: y − r, height + r; Y-up: height + r), radius: r, white)`
  `.cropped(to: B)` used through `CIBlendWithMask` and the result
  `.cropped(to: B)` like today's shape mask — the top corners fall outside `B`,
  so only the bottom two are rounded.
- card = `CILinearGradient` (top colour at `C`'s top edge → bottom colour at its
  bottom edge, interpolated in the working space as stored) through
  `CIBlendWithMask` with `CIRoundedRectangleGenerator(C, r)`, `.cropped(to: C)`.
- On the override (cardTop) path mid-morph the look's `B` is `resolve`'s
  `cameraRect`; the tag keeps today's chrome fade there.

Mac preview: apply the mask in `VideoFrameLayerDriver` (the per-frame CI step,
a second IOSurface beside the adjusted one) through the shared
`CameraStyleMath.maskedImage`. The existing bubble layers moved into their own
group (`cameraBubbleStack`, which keeps its 20 % black clip background — a look
stack has none); the cutout and pop-out stacks are sibling groups. The sum is
done in CoreAnimation: while two stacks share a frame their parent
(`cameraStacksGroup`) renders isolated (`shouldRasterize`) and the look stacks
carry `compositingFilter = CIAdditionCompositing`, each group's `opacity` being
its weight (CA scales premultiplied RGBA by group opacity — the same
`scale(x, w)`); a settled look, or none, is one stack at weight 1 with no
filter and no rasterization. `--preview-parity` verifies it per pixel: a
mid-fade frame equals `(1 − w)·F_bubble + w·F_cutout` (source-over would miss
≈ 1 250 of the probe's pixels). Card: a `CAGradientLayer` with the §3 colours,
rounded by `cornerRadius`; person clip: a `CAShapeLayer` mask of the rounded
rect over B extended up by r, cut to B by `masksToBounds`. Mac export: the
same `maskedImage` before `compositeCamera`, which builds the stacks above
(`VideoExporter.scaleStack`, `popOutCardStack`). Web: the camera pass (`engine/gpu/cameraShaders.ts`
`cameraLiveWGSL` / `cameraPosterWGSL`) samples an `r8unorm` mask texture with a
linear sampler at the same `camPoint` (so it follows fill and mirror) and
multiplies alpha; the person clip is its own crop rect, separate from the card
rect, so the head can rise above the card.

Stage: a look is drawn wherever the existing camera path draws — the plain
bubble's overlay stage after the warp, or the override tile's card stage
mid-morph — at `resolve`'s `cameraRect`.

## 6. Producing masks

### Producer alpha conditioning (both producers, byte-identical)

Raw mattes (Vision, and the web's segmenter) shimmer at the soft edge and flicker ±1–3 levels
everywhere, so every frame encodes as a fresh key: measured on a real 15.6 s
1080p webcam take with Vision `.balanced`, the raw track cost **12.2 MB per
minute** at 512×288. Producers therefore condition every resampled frame
before `CameraMaskEncoder.add` / `Encoder.append`. The decoder and the format
are unchanged — this only fixes which alpha values a producer writes.

Constants: `deadZone = 16`, `levels = 8`, `hold = 32`, keyframeInterval 30,
resolution per §2 (192 rows). Per pixel, integers throughout, `prev` = the
previous frame's CONDITIONED value (none on the first frame):

```
v = raw
v < 16 → 0;  v > 239 → 255                                  (dead zone)
prev exists and |v − prev| ≤ 32 → out = prev                (hold / hysteresis)
else level = (v·7 + 127) ÷ 255;  out = (level·255 + 3) ÷ 7  (8 levels:
     0, 36, 73, 109, 146, 182, 219, 255; ÷ = integer division)
```

The hold compares the dead-zoned RAW value with the previous OUTPUT, so a
pixel only changes level when the matte really moved (32 < one level, 36.4):
still regions repeat byte-for-byte and the XOR deltas win. Implementations:
Mac `CameraMaskConditioning` (Services/CameraMaskConditioning.swift, used by
the segmentation job and the parity fixture), web
`core/mask/conditionAlpha.ts` (used by `segment/worker.ts`). Both are tested
against the same three-frame fixture (`--cameralayout-test`,
`conditionAlpha.test.ts`).

Measured (`CaptureCat --camera-mask-bench <camera.mov> --variants`, same real
take, 460 frames; error = |Δα| against the raw 288-row matte at a settled
frame, upsampled where smaller; every candidate was also checked visually —
bubble-sized cutout + 2× zoom on the hair edge):

| producer variant | size | MB/min | deltas | mean / p99 \|Δα\| | visual |
|---|---|---|---|---|---|
| raw (old rule), kfi 15 | 512×288 | 12.21 | 338/460 | 0 / 0 | reference |
| dead zone 12 | 512×288 | 8.43 | 276 | 0.08 / 2 | = raw |
| 32 levels | 512×288 | 6.47 | 205 | 0.09 / 3 | = raw |
| 16 levels | 512×288 | 4.81 | 274 | 0.15 / 6 | = raw |
| hold 8 | 512×288 | 8.08 | 429 | 0.38 / 7 | = raw |
| 216 rows | 384×216 | 7.70 | 353 | 0.15 / 4 | = raw at bubble size |
| 192 rows | 341×192 | 6.29 | 349 | 0.21 / 6 | = raw at bubble size |
| dz12 + 16 lv + hold 12 | 512×288 | 4.35 | 318 | 0.17 / 6 | = raw |
| dz12 + 8 lv + hold 24, kfi 30 | 512×288 | 2.96 | 376 | 0.30 / 11 | = raw |
| dz16 + 8 lv + hold 32, kfi 30 | 512×288 | 2.71 | 392 | 0.33 / 13 | = raw |
| dz16 + 4 lv + hold 40, kfi 30 | 512×288 | 2.24 | 328 | 0.53 / 22 | slightly harder edge |
| dz16 + 8 lv + hold 32, kfi 30 | 427×240 | 2.07 | 404 | 0.30 / 11 | = raw |
| dz16 + 8 lv + hold 32, kfi 30 | 384×216 | 1.77 | 418 | 0.32 / 11 | = raw at bubble size |
| **dz16 + 8 lv + hold 32, kfi 30 (chosen)** | **341×192** | **1.48** | 421 | 0.35 / 12 | = raw at bubble size; 2× full-res zoom a touch softer |
| dz16 + 8 lv + hold 32, kfi 60 | 341×192 | 1.47 | 427 | 0.35 / 12 | — |
| dz12 + 16 lv + hold 24, kfi 30 | 284×160 | 1.41 | 443 | 0.86 / 19 | softer, faint halo |

No 288-row combination reached 2 MB/min without coarsening the edge to 4
levels; 192 rows leaves ~25 % headroom for livelier takes (this one is a
talking head). Hold larger than one level (16 levels + hold 24) made values
sticky (p99 17) for little gain.

### Producers

- **Mac:** `VNGeneratePersonSegmentationRequest` (quality `.balanced`, output
  `OneComponent8`) on every camera frame, resampled to the mask resolution and
  conditioned (above). A
  background job modelled on `CaptureTextIndex` (utility priority, paused while
  recording/exporting/sharing, one project at a time, atomic write), queued
  when a look is first applied to a project without a fresh mask, and after
  recording when the project already uses a look.
- **Web:** MediaPipe's multiclass selfie segmenter (`selfie_multiclass_256x256`,
  float32, `@mediapipe/tasks-vision` ImageSegmenter, GPU delegate else CPU)
  in a worker beside the Whisper one, every decoded camera frame, written
  with `encodeCameraMask` and uploaded as a cloud project file.
  - Replaced MODNet (transformers.js `Xenova/modnet`) on 2026-10-28. On a
    real take lit by one red lamp, MODNet took the plant and the wall for the
    person (fp32) or kept almost nothing (its int8 build, what WASM ran), so
    the cutout came out as scattered shapes. This model kept the head, hair
    and shoulders cleanly, at ~11 ms a frame on the GPU delegate.
  - Its person alpha is 1 − the background confidence, through a smoothstep
    from 0.2 to 0.8 (`segment/model.ts personAlpha`) before the shared
    conditioning: its background never reaches 0 (≈ 0.1 on that take, a 14 %
    ghost of the room otherwise).
  - `apps/web/src/editor/segment/` (worker + client), `state/cameraMask.ts`
    (the job). The frame is drawn at shortest edge 360 (the model resizes to
    256×256), segmented, area-resampled to the §2 resolution, conditioned (above)
    and appended to the streaming `CameraMaskEncoder` (keyframeInterval 30);
    frame time = the
    demuxed sample PTS; `sourceByteSize` = the camera file's size as read,
    `sourceDuration` = the end of its last frame (PTS + duration).
  - The worker first reads the existing mask's header and stops when it is
    fresh. Owner only: a team member's editor only checks, and says the owner
    has to open the project. The engine draws the new mask at once
    (`EngineClient.setCameraMask`); the upload (`ProjectMedia.addFile`,
    `application/octet-stream`) follows.
  - The engine fetches `camera-mask.ccmask` only while a region carries a
    `look` (`refsOf`), so projects without looks never download it.

## 7. Sync

`camera-mask.ccmask` joins the derived files that cloud sync carries:

- Mac `CloudProjectMedia.derivedFiles`, `CloudPath` extensions, `--cloud-sync-test`
- web `state/cloud.ts` (`resolveMediaRef`), `engine/media/assets.ts`
  (`refsOf`, like `camera_poster.png`) and `state/projectMedia.ts`
  (`engineMedia`; upload through `addFile`)
- API `CLOUD_FILE_TYPES`: `ccmask: { kind: "data", types: ["application/octet-stream"] }`

## 8. Gates

- Codec: TS tests; Mac `--web-vectors` writes a `.ccmask` fixture plus the
  SHA-256 of every decoded frame, and the TS suite decodes it and compares.
- Math: new vector units for `lookWeights` and `CameraCutoutMath`.
- Render: `--web-parity-fixtures` gains `16-camera-looks` (synthetic camera +
  synthetic mask, regions bubble → cutout → popOut → bubble → popOut →
  cameraOnly) exported by the real exporter; `apps/web/scripts/editor-lab/parity.mjs` (add the mask to its
  `files` map) renders it and compares (mean ≤ 1.5/255, p99 ≤ 12/255).
  - (Web side, done) parity.mjs maps `camera-mask.ccmask` (or the manifest's
    `media.mask`) for any fixture whose project carries a `look`, applies the
    structural blob guard to it (features `cameraLook.*` / `camera.look*` or a
    name containing `camera-looks`), and FAILS when the engine reports the
    mask stale. So the fixture's mask must be written against the fixture's
    OWN camera file: `sourceByteSize` = the byte size of the camera file the
    manifest lists, `sourceDuration` within 0.05 s of it. Name collision: a
    `14-source-segments-dip` fixture already exists — any free number works,
    the web keys on the name containing `camera-looks`.
  - `core/vectors/parityFixtures.test.ts` asserts a look fixture ships a
    `.ccmask`.
  - Include at least one frame mid cross-fade (bubble → cutout and
    cutout → popOut) so the summed-dissolve compositing is gated, not only
    settled looks.
  - (Mac side, done) `16-camera-looks`: mask written with the Mac encoder
    as a producer writes it (§2 resolution — 256×192 for the 4:3 synthetic
    camera — and §6 producer alpha conditioning, keyframeInterval 30)
    against the fixture's own `camera.mp4` (decoded PTS; sourceDuration = end
    of the last frame = 6.0 s = the asset duration; manifest `media.mask`);
    frames 0 (bubble), 30, 37 (mid bubble→cutout), 45 / 60 (settled cutout),
    72, 79 (mid cutout→popOut), 90 (settled popOut), 102, 109 (mid
    popOut→bubble), 117, 127 (mid bubble→popOut), 140, 154 (mid
    popOut→cameraOnly, override path), 170, 179. The fixture build also
    exports a camera-less twin and asserts the settled cutout (frame 45) is
    pixel-identical to it outside the silhouette and covered inside, with the
    plain-bubble frame as the must-fail self-test (`fixture.json`
    `cameraLookCheck`).
- Mac: `--cameralayout-test` covers `look` round-trip, legacy decode, unknown
  mode → bubble, and mid-morph weights strictly between endpoints; a preview
  probe asserts pixels outside the silhouette are transparent (the structural
  check a mean diff would miss).

## 9. Where it surfaces

- Mac: the timeline's camera-layout popover (TimelineViewController
  `showZoomMenu`) gains "Cutout" and "Pop-out card" rows → a 4 s Bubble region
  with that `look`; labels from the look's display name. The camera inspector
  pane shows the segmentation state ("Removing background… 42%").
- Web: the Effects picker (`ui/shell/TransportBar.tsx`, `EffectsPick`) gains the
  same two rows → `state/edits.ts addCameraLayoutRegion` with the look; timeline
  labels in `state/timeline.ts`; segmentation progress beside it.
- Display names: "Cutout", "Pop-out card".

## 10. Golden-vector units (shapes both sides build against)

Same file shape as every unit: `{ unit, notes, count, cases: [{ input, output }] }`,
written by `CaptureCat --web-vectors`, checked by `checkUnit` in
`apps/web/src/editor/core/vectors/`. Rects use the encoding the existing
camera units already use. Names are final.

- `cameraLookWeights`
  - input `{ regions: CameraLayoutRegion[] /* as project.json, look optional */, queries: number[] }`
  - output `{ results: Array<{ cutout: number, popOut: number }> }` (one per query)
  - cases: random region sets (some regions with `look`, some non-bubble modes
    carrying a `look`), edges ≤ 0.05 s apart, t = 0, mid-morph and settled queries.
- `cameraCutoutGeometry`
  - input `{ look: "cutout" | "popOut", bubbleRect: Rect, cameraAspect: number }`
  - output `{ personRect: Rect, clipRect: Rect, clipBottomCornerRadius: number,
    cardRect: Rect | null, cardCornerRadius: number }` (Y-down; cutout:
    cardRect null, radii 0)
- `cameraMaskCodec`
  - input `{ base64: string /* a .ccmask written by the Swift encoder */, queries: number[] }`
  - output `{ header: { width, height, keyframeInterval, frameCount, sourceDuration, sourceByteSize },
    frames: Array<{ time: number, delta: boolean, sha256: string /* hex of decoded alpha */ }>,
    lookups: number[] /* frameIndexAt per query */ }`
  - the fixture has ≥ 40 frames at 64×36, a moving soft silhouette plus a
    still stretch (so both key and delta frames occur), keyframeInterval 8.

## 11. Static-span key

Both `cameraLayoutKey`s (Mac `StaticSpanCollapse.cameraLayoutKey` in
ExportFormats.swift, web `core/export/staticSpans.ts`) append two fields to the
existing eight, `%.3f` like the opacities, in this order:
`…,<cardTranslationX %.1f>,<cutout %.3f>,<popOut %.3f>`. A key without any
look therefore ends in `,0.000,0.000` — the existing vector units that record
keys change once, regenerated from the Mac binary.

## 12. Camera styles — pop-out amount, card fill, blur, border, edges, split side

Owner request (Mike, 2026-11-02): a full set of camera layout and style
controls, Mac and web together (same rule as §1). This section is the
contract; §1–§11 stay in force except where this section says otherwise.

| Control | CaptureCat |
|---|---|
| Default / Camera only / Split screen | Bubble / Camera Only / Side by Side (+ §12.6 camera side) |
| Frame style, Pop-out amount | Pop-out card + `cameraPopOutAmount` (§12.2) |
| Background: blur, none, color, gradient, wallpaper, image | card fill + `cameraBackgroundBlur` (§12.3) |
| Border presets, thickness, colour | card border (§12.2, §12.3) |
| Cutout style: edge softness, edge inset | mask edge processing (§12.4), both looks |
| Shrink during zoom | `cameraShrinkOnZoom` (§12.5) |
| Copy / paste layout effects | timeline Copy / Paste Layout (§12.7) |

Not taken: a full-height camera "tower" split — CaptureCat tried and
rejected that composition (see `CameraLayoutMath.sideBySideScreenFraction`).

### 12.1 Model

Whole-video keys on `settings` (same pattern as `cameraLook`, §1a). Every key
is optional: missing, null, unknown, mistyped or non-finite → absent
(`(try? decodeIfPresent(T.self)) ?? nil`; web `parse.ts` mirrors it). Written
only when set, in this order, right after `cameraLook`. Numbers are stored as
given and clamped to their range where they are USED, never at decode.

| key | type | values | absent = |
|---|---|---|---|
| `cameraPopOutAmount` | number | 0…1 | 0.5 (= today's headroom) |
| `cameraCardFill` | string | `"gradient"`, `"camera"`, `"color"`, `"image"` | `"gradient"` |
| `cameraCardGradientStart` | color | `{red, green, blue, opacity}` like every CodableColor | §3 top colour |
| `cameraCardGradientEnd` | color | | §3 bottom colour |
| `cameraCardColor` | color | | `(0.11, 0.11, 0.13, 1)` |
| `cameraCardImagePath` | string | a path, exactly like `backgroundImagePath` | none |
| `cameraBackgroundBlur` | number | 0…1 | 0 |
| `cameraEdgeSoftness` | number | 0…1 | 0 |
| `cameraEdgeInset` | number | 0…1 | 0 |
| `cameraCardBorder` | string | `"solid"`, `"aurora"`, `"gold"` | none (no border) |
| `cameraCardBorderWidth` | number | 0…1 | 0.5 |
| `cameraCardBorderColor` | color | | white `(1, 1, 1, 1)` |
| `cameraShrinkOnZoom` | bool | | true |

Region key (on `CameraLayoutRegion`, like `look`): `cameraSide`, string,
`"leading"` | `"trailing"` | absent (= trailing, today's). Lenient decode, encode only when
set, only takes effect while `mode == sideBySide` (kept, ignored otherwise).
Old builds ignore every new key and draw today's render — a safe fallback.

Projects that set none of these keys render byte-for-byte as before on both
sides (no extra pass, no changed constant).

### 12.2 Geometry — `CameraCutoutMath` additions

- `headroom = 0.44 × clamp(cameraPopOutAmount ?? 0.5, 0, 1) × B.height`
  (0.44 × 0.5 is exactly today's 0.22). Amount 0 → the card is B: no head
  breakout. The card rect, corner radius and person clip follow from the
  headroom exactly as §3 states.
- Card border (only while `cameraCardBorder` is set and the look is pop-out):
  `w = clamp(cameraCardBorderWidth ?? 0.5, 0, 1) × 0.08 × min(C.width, C.height)`.
  The border is an INNER ring: the region inside the rounded rect `(C, r)` and
  outside the rounded rect `(C inset by w on all sides, max(0, r − w))`. w ≤ 0,
  or an inner rect with no area → no ring at all.
- `Geometry` gains `cardBorderWidth` (w, 0 when no border or for the cutout).
  `geometry(look:bubbleRect:cameraAspect:popOutAmount:cardBorderWidth:yAxisIsUp:)`
  — `popOutAmount` nil = 0.5, `cardBorderWidth` = the 0…1 thickness or nil
  for no border.

### 12.3 The pop-out stack, revised

```
popStack = card shadow → card fill → card border ring → masked person (personClip)
```

All fills are drawn through the card's rounded-rect mask `(C, r)`, cropped to
C, exactly where §5 draws today's gradient.

- `gradient` (default): today's `CILinearGradient`, colours =
  `cameraCardGradientStart/End` when set, else §3's. Absent keys →
  byte-identical to today.
- `color`: `cameraCardColor ?? (0.11, 0.11, 0.13)`, alpha forced to 1, flat.
- `image`: the file at `cameraCardImagePath` decoded once (EXIF orientation
  applied, converted to sRGB 8-bit), aspect-filled into C — `s = max(C.width /
  iw, C.height / ih)`, centred on C — through the card mask. Path absent, file
  missing or unreadable → the `gradient` fill.
- `camera`: the camera frame after mirror + adjustments and NOT masked (the
  plain bubble's pixels), placed with the SAME transform as the person
  (aspect-fill into B, §3 `P`), through the card mask. Inside the card the
  person (drawn next) lands on its own pixels, so the seam is invisible; above
  the card only the masked person shows.
  - `cameraBackgroundBlur` b > 0: that card camera image is blurred in
    CAMERA-PIXEL space before placement: `σ = b × 0.03 × H` where H is the
    camera frame's height in its own decoded pixels; clamp to extent →
    Gaussian σ → crop to the frame (Mac: `clampedToExtent()`, `CIGaussianBlur`
    radius σ, `cropped(to:)`; web: a separable Gaussian, kernel radius
    `ceil(3σ)`, weights `exp(−x² / 2σ²)` normalised, clamp-to-edge sampling).
    The person stays sharp, so b reads as a portrait-mode background blur.
  - b is ignored by the other fills.
- Border ring, filled with:
  - `solid`: `cameraCardBorderColor ?? white`, alpha forced to 1.
  - `aurora`: vertical linear gradient across C, top `(0.36, 0.91, 1.00)` →
    bottom `(0.29, 0.40, 1.00)`, sRGB.
  - `gold`: top `(1.00, 0.89, 0.52)` → bottom `(0.85, 0.55, 0.16)`, sRGB.
  Gradients run from C's top edge to its bottom edge (CI: maxY → minY), the
  same construction as the card gradient.
- The head that pops out draws OVER the ring (person last).

### 12.4 Edge softness and inset — `CameraMaskEdge`

One integer algorithm, byte-identical in Swift (`Services/CameraMaskEdge.swift`)
and TS (`core/mask/maskEdge.ts`), applied to every decoded mask frame
(including frame 0 under the poster) before it is used as alpha, wherever a
look draws. It changes the person's edge for BOTH looks.

```
k     = height / 192                                    (mask rows → radius scale)
i     = round(clamp(cameraEdgeInset, 0, 1) × 6 × k)     (round half up; inputs ≥ 0)
s     = round(clamp(cameraEdgeSoftness, 0, 1) × 6 × k)
i = 0 and s = 0 → the frame unchanged
erode (i > 0):  rows then columns, out[x] = min(in[clamp(x + d)]) for d ∈ [−i, i]
soften (s > 0): box blur rows, columns, rows, columns (two passes each way),
                out[x] = (Σ in[clamp(x + d)] for d ∈ [−s, s] + s) ÷ (2s + 1)
                (integer division)
clamp(j) = min(max(j, 0), n − 1)  — clamp-to-edge along the pass
order: erode, then soften
```

Swift `Double.rounded()` and JS `Math.round` agree for non-negative inputs.
Cache the processed frame by (frame index, i, s); the cost is small (≤ 341×192).

### 12.5 Shrink during zoom

`cameraShrinkOnZoom == false` → the bubble keeps its base size at every zoom:
every `ReactiveCameraLayout.cameraRect` caller passes zoom 1 (helper
`ReactiveCameraLayout.layoutZoom(_ zoom:, shrinkOnZoom:)` → `shrinkOnZoom ?
zoom : 1`, web the same name). Nothing else changes.

### 12.6 Camera side in Side by Side

- `columns(in:side:)`: trailing (default) is today's. Leading mirrors it:
  camera `(videoRect.minX, tileY, cameraWidth, tileHeight)`, screen
  `(videoRect.maxX − screenWidth, tileY, screenWidth, tileHeight)`.
- `target(.sideBySide)` uses the containing region's side, so
  `cardTranslationX = cols.screen.midX − videoRect.midX` is positive for
  leading.
- Morph identity: `resolve` compares ARRANGEMENTS, not modes —
  `(mode, mode == sideBySide ? side : trailing)`. Adjacent Side by Side blocks
  with different sides morph (the camera slides across); everything else is
  unchanged.
- The static-span key needs nothing new: the side reaches it through
  `cardTranslationX`.

### 12.7 Copy / Paste Layout

UI only, no model change: copies a camera-layout block's `mode`, `look` and
`cameraSide`; pasting onto another block replaces those three and keeps its
id, start and end. One undo step. In-app clipboard (not the system pasteboard).
Mac: the block's context menu; web: the timeline block menu.

### 12.8 Surfaces

- Camera pane (Mac `CameraSettingsPaneAppKit`, web `CameraPane`), under the
  Background chips:
  - Cutout or Pop-out card: "Edge softness", "Edge inset" (0–100 %).
  - Pop-out card: "Pop-out" (0–100 %); "Card" chips Gradient / Camera / Color /
    Image, then per fill: two colour wells / "Background blur" / a colour well /
    the wallpaper grid + "Choose Image…"; "Border" chips None / Solid / Aurora /
    Gold, "Thickness", and a colour well for Solid.
  - "Shrink during zoom" switch beside Size.
- Camera-layout popover / Effects picker: a Side by Side block can be set to
  camera left or right (Mac: context menu "Camera on Left/Right"; web: the
  block menu).
- MCP `set_style` / WebMCP `set_style`: every §12.1 settings key by name
  (colours as `#RRGGBB`, `"none"` clears a string key); `style_options` lists
  them with ranges. Camera-layout region tools accept `cameraSide`.

### 12.9 Sync and merge

`cameraCardImagePath` travels exactly like `backgroundImagePath`: Mac
`CloudProjectMedia` key list and `CloudProjectSync` upload + relink, web
`state/projectMedia.ts` and `state/cloud.ts`. `MergePolicy` / web merge
policy: atomic group `cameraCard = [cameraCardFill, cameraCardImagePath]`.

### 12.10 Gates

- Vectors (regenerated from the Mac binary):
  - `cameraCutoutGeometry`: input gains optional `popOutAmount` and
    `cardBorderWidth` (0…1 thickness); output gains `cardBorderWidth`.
  - new `cameraMaskEdge`: input `{ width, height, base64, softness, inset }`
    (masks ≤ 64×36 plus one 288-row case), output `{ base64 }`; cases cover
    identity, inset only, softness only, both, 0 and 1, and the k scaling.
  - `cameraLayoutMathBasics` gains `columnsLeading`; `cameraLayoutResolve`
    region sets carry `cameraSide` (including adjacent leading/trailing).
  - model decode/encode cases with every new key, plus garbage values.
- Parity fixtures (exported by the real Mac exporter, names contain
  `camera-looks` so parity.mjs maps the mask):
  - `17-camera-looks-frame`: pop-out, `camera` fill, blur 0.6, amount 0.8,
    `aurora` border, softness 0.4, inset 0.3; regions bubble → popOut →
    cutout → sideBySide leading → bubble; `cameraShrinkOnZoom` false with a
    zoom over a bubble span; frames mid every edge and settled in every block.
  - `18-camera-looks-card`: pop-out `image` fill (a synthetic PNG shipped in
    the fixture), `solid` red border; then `color` fill is covered by the
    preview gate only.
- Mac `--preview-parity` looks checks (structural, not mean-diff): camera fill
  shows the camera's background inside the card and only the person above it;
  blur lowers high-frequency energy inside the card versus b = 0; the border
  ring pixels carry the preset colour; inset shrinks the silhouette area and
  softness widens its edge; amount moves the card's top edge; each with an
  injected defect that must fail.
- Mac `--cameralayout-test`: round-trip and lenient decode of every key,
  `cameraSide` morph mid-flight strictly between endpoints.

### 12.11 Full-height split ("Split Screen")

Owner request (Mike, 2026-11-02): a split in two full-height
columns. The composition rejected earlier was a full-height camera beside a
SHRUNKEN, floating screen card; here the screen FILLS its column (cropped,
not letterboxed), so both columns are full height and nothing floats.

- Region key `splitStyle`, string: `"tiles"` | `"full"` | absent (= tiles,
  today's equal-height row). Same rules as `cameraSide`: lenient decode,
  encode only when set, only takes effect while `mode == sideBySide`.
  Display names: tiles = "Side by Side", full = "Split Screen".
- `columns(in:side:style:)`, full: `gap = W × 0.03`, `screenWidth = W × 0.60`,
  `cameraWidth = W − screenWidth − gap`, both tiles at `y = videoRect.minY`,
  `height = videoRect.height`; side places them exactly as §12.6.
- `target(.sideBySide, full)`: `cardScale = 1`, `cardTranslationX =
  screen.midX − videoRect.midX` (the screen's CENTRE shows in its column; a
  zoom still steers what is centred), `cameraRect = camera tile`,
  `cameraCornerRadius = cardCornerRadius`, and the new clip below `= screen
  tile`, radius `cardCornerRadius`.
- `Resolved` gains `cardClip: CGRect?` and `cardClipCornerRadius` (caller's
  space, same as `videoRect`). nil everywhere except a settled full split and
  any morph with a full split at either end; there the clip lerps (same `p`)
  from/to `transformedCard(r) = cardTransform(r) applied to videoRect` with
  radius `cardCornerRadius × r.cardScale` for the end that has no clip.
  Arrangement identity adds `splitStyle` (sideBySide only).
- Renderers, while `cardClip` is non-nil, at the card-over-transparency seam
  right after the card transform (the cursor, ripples, highlights, blur,
  annotations and curtain ride the card there and are clipped with it; the
  camera tile composites after, unclipped):
  1. keep only what lies inside the rounded rect `(cardClip, radius)`;
  2. draw a TILE shadow under it: the card's own drop-shadow recipe (Mac
     export `makeFrameShadow`, preview `cardShadow`: black × 0.45 ×
     shadowOpacity, offset `(0, radius/3)` Y-down) on the rounded clip rect,
     with shadow radius `shadowRadius × cardScale` (× canvasScale in export),
     so the switch from the scaled card's own shadow is seamless.
  With `cardClip` nil nothing changes (byte-identical).
- Mac preview: the card riders (overlayClip, annotations, cursor, ripples,
  curtain) now sit with the card in one group that takes the layout
  transform, as the exporter has always done — before this, the preview left
  them unsqueezed in Side by Side.
- Static-span key: nothing new (the clip is a function of the transform
  fields already in it).
- Surfaces: picker row "Split Screen" (a Side by Side block with `full`),
  block menu "Full Height" / "Tiles" on Side by Side blocks, Copy / Paste
  Layout carries `splitStyle`, MCP `describe_project` reports it.
- Gates: vectors (`cameraLayoutMathBasics.columnsFull[Leading]`,
  `cameraLayoutResolve` regions with `splitStyle`, `resolved.cardClip`),
  `--cameralayout-test` (geometry, clip lerp mid-flight, round trip),
  `--preview-parity` (settled full split: screen fills its column top to
  bottom, nothing drawn in the gutter, the cursor stays inside the screen
  column), parity fixture `19-camera-split-full` WITH a cursor (bubble → full
  → full leading → tiles → bubble).

### 12.12 Vertical stack — camera on top in a portrait frame

Owner request (Mike, 2026-11-02): in a 9:16 video the camera goes on top
automatically, the screen below, and the camera's height is draggable (a notch
on hover) and set in the sidebar.

- Settings (same rules as §12.1, written right after `cameraShrinkOnZoom`):
  - `cameraPortraitStack`, bool, absent = false. The UI turns it on when a
    project with a camera is switched to a portrait aspect (it never changes
    on its own in the renderer, so existing projects render as before).
  - `cameraStackRatio`, number, the camera row's share of the stack height,
    clamped to 0.25…0.7 at use, absent = 0.42.
- Active when `cameraPortraitStack` is true, the project shows a camera, and
  the OUTPUT canvas is portrait (height > width: 9:16, 4:5, or Auto on a
  portrait recording). Shared helper
  `CameraLayoutMath.stackRows(area:ratio:yAxisIsUp:)` → `(camera, screen)`,
  where `area` is the content rect (the canvas inside the frame padding — Mac
  preview `contentRect`, exporter `FrameLayout.contentRect`):
  `gap = 0.02 × area.height`, `h = (area.height − gap) × ratio`; camera row
  `(area.minX, top, area.width, h)` at the TOP (Y-down `area.minY`, Y-up
  `area.maxY − h`); screen row the rest, `area.height − h − gap` tall, at
  the bottom.
- Arrangement (stack active): outside every region → stacked; a Side by
  Side region (either side or split style) → stacked; Bubble, Camera Only and
  Screen Only regions → as today. Morph identity adds `stacked`, so entering
  or leaving a Bubble block morphs.
- `target(stacked)`: `cameraRect = camera row`, `cameraCornerRadius =
  cardCornerRadius`, `chromeOpacity 0`; the card aspect-FILLS the screen row:
  `cardScale = max(screen.w / videoRect.w, screen.h / videoRect.h)`,
  `cardTranslationX = screen.midX − videoRect.midX`, new `cardTranslationY =
  screen.midY − videoRect.midY` (caller space, so it is correct in Y-down
  and Y-up alike because the rows are), `cardClip = screen row`, radius
  `cardCornerRadius`.
- `Resolved.cardTranslationY` (default 0); `cardTransform` translates by
  `(tx, ty)` about videoRect's centre. Everything that transforms the card
  applies both (the preview's layout group scales about videoRect's centre
  in content space — Mac preview `layoutGroup`).
- Tile shadow (§12.11) radius is `shadowRadius × min(1, cardScale)` (a filled
  row scales the card UP; its shadow stays card-sized). §12.11 never exceeds
  scale 1, so it is unchanged there.
- Looks (cutout, pop-out) draw on the stack's camera row: `look(at:)` returns
  `defaultLook` outside regions (stacked or not) and, while the stack is
  active, on a Side by Side region too (it stacks, so it wears the same look).
  B is the camera row, so the pop-out card is the row minus its headroom and
  the head rises into the top of the row. (Until 2026-11-02 looks were off
  while stacked; Mike: "pop out doesnt work".)
- Static-span key: append `,<cardTranslationY %.1f>` after `cardTranslationX`.
- Surfaces: Camera pane "Stack on top in vertical videos" switch and a
  "Camera height" slider (25–70 %); the aspect picker turns the switch on when
  it moves a camera project to a portrait aspect; on the preview, hovering the
  seam between the rows shows a notch you drag up and down (writes
  `cameraStackRatio`, one undo step per drag; never exported). MCP / WebMCP
  `set_style` keys `cameraPortraitStack`, `cameraStackRatio`.
- Gates: `cameraStackRows` vector unit; `cameraLayoutResolve` cases with a
  stack; `--cameralayout-test` (rows in both Y conventions, settled stack,
  morph into a Bubble block, the whole-video look on the stacked row); `--preview-parity` (camera fills the
  top row, screen fills the bottom row, background in the gap); parity
  fixture `20-camera-stack-vertical` (9:16, cursor, a Bubble block mid-way).

### 12.13 Zoom inside the vertical stack

Owner request (Mike, 2026-11-02): "zoom in doesnt make it go smaller? think of
an apple way style of handling in 9:16". Until then the whole stack sat inside
the card zoom: a 2.4× zoom magnified the camera row with the screen and pushed
it off the top of the frame, about the wrong point (the unstacked focal).

The rule: the screen row is a WINDOW. The zoom happens inside it; the camera
row never zooms. With Shrink During Zoom on, the camera row yields height the
way the bubble shrinks, so the seam glides up and the screen gets the room —
one curve, one moving edge, nothing flies off the frame.

- Yield: `CameraLayoutMath.stackYield(zoom:)` =
  `ReactiveCameraLayout.sizeFactor(forZoom:)` (`1 − 0.25 × envelope`, the
  bubble's own shrink; `cameraRect` now calls the same helper). Callers pass
  `layoutZoom(rawZoom, shrinkOnZoom)`, so the switch off keeps the row.
  `stackRows(area:ratio:yAxisIsUp:yield:)` multiplies the camera row's height
  by it (top edge fixed); the screen row takes the rest, gap unchanged.
- Zoom in the row: `resolve(…, stack:, stackZoom: StackZoom(zoom, focalX,
  focalY))` — the RAW smoothed zoom and the path's focal (0…1, Y-down). The
  stacked target becomes `cardScale = fill × z` with `z = max(1, zoom)` and the
  translation that maps the focal point P (on the filled card) to
  `Q = P + (Qd − P) × envelope(z)`, where `Qd` is the same fraction of the
  ROW (Y-up callers mirror the fraction; the row order — camera on top — tells
  the convention). At full envelope the focal sits where it would in an
  unstacked card, so a focal the fill cropped away pans into view; both ends
  cover the row, so every blend does. `z == 1` is exactly the old fill.
- The layout owns EVERY zoom-in while the stack is on (it, a camera, a
  portrait canvas): stacked as above; in a Bubble / Camera Only / Screen Only
  block the plain zoom about the focal on the card (`cardScale × z`, the
  focal fixed — the classic picture, folded into the card transform). The
  card zoom stage after the layout applies `outerZoom(zoom, stacking:)` =
  `stacking && zoom > 1 ? 1 : zoom`, so a scale-down still shrinks the whole
  composition. Both morph ends are zoomed layouts, so a morph into a Bubble
  block while zoomed only blends them: the camera tile (composited before
  that stage) never rides a zoom, and nothing pops when the morph ends. (A
  first cut blended the outer zoom by a stack weight through the morph — it
  flew the tile off the frame and read as motion blur; parity fixture 22
  caught it.) The cover zoom, background parallax and both motion-blur samples use
  the outer zoom, so a zoom the layout owns never blurs the camera.
- Mac: preview `cameraStacking` + `resolveCameraLayout`, exporter per-frame
  `stackRows`; web: `exportFrameCamera` (focal from the camera key), the
  camera pass's `cameraStacking` hook → `FrameGraph.cameraStacking()` →
  `cameraStateAt(…, stacking)` (the exporter re-derives it after `prefetch`,
  once the camera stream is open).
- The seam notch hides while the row is yielding (a drag would write the
  yielded height).
- Gates: `cameraStackRows` (yield cases), `cameraStackZoom` (yield, outer),
  `cameraLayoutResolve` stack-zoom cases; `--cameralayout-test` (yield in
  both Y conventions, coverage, the focal landing in the row, outer zoom, the
  Bubble block's zoom, no jump at either end of its morph); `--preview-parity` `stack-zoom` (row
  yielded and unzoomed, padding bare, screen clipped) with a self-test that
  the old whole-stack zoom fails, and `stack-zoom-glide` (the seam caught
  mid-glide, tracking the zoom); parity fixture `22-camera-stack-zoom`.

### 12.14 Gap between the stacked rows

Owner request (Mike, 2026-11-02): "what if usr wnt to rmve cap between cam and
screen". The gap was a fixed 2% of the stack height.

- Setting `cameraStackGap`, number, the gap as a share of the stack height,
  clamped to 0…0.08 at use, absent = 0.02 (today's rows exactly). Written
  right after `cameraStackRatio`; same lenient rules. Shared
  `CameraLayoutMath.stackGap(_:)`; `stackRows(area:ratio:yAxisIsUp:yield:gap:)`
  takes the stored value.
- Gap 0 JOINS the rows into one card. `target(stacked)` sees the rows touch
  (seam ≤ 1e-6 × the rows' heights) and returns:
  - `cameraShapeRect` = the camera row run past the seam by
    `cardCornerRadius`, `cardClipShapeRect` = the screen row run past it the
    other way (nil when the radius is 0). Every mask takes its corners from
    the SHAPE and is cropped to the visible rect, so the seam corners are
    square and the outer ones stay round: exporter
    `CIRoundedRectangleGenerator(inputExtent: shape, radius clamped to the
    shape).cropped(to: rect)` for the camera tile and the card clip; Mac
    preview the shape path ∩ the rect; web tile shader mode 1 with `mCrop` =
    the shape, card-clip shader `shape` uniform.
  - `seamJoin` = 1 (0 otherwise; morphs lerp it, and the shapes lerp to the
    other end's outline). The camera tile's card shadow is drawn with
    `× (1 − seamJoin)` over the card as before, and with `× seamJoin × the
    camera opacity` UNDER the card (after the tile shadow, before the camera
    tile — Mac preview `cameraSeamShadow` below `layoutClipGroup`, web the
    "cardSeam" stage `under` shadow), so the screen covers what would land on
    it and the two shadows read as one silhouette.
- Surfaces: Camera pane "Gap" slider under Camera Height (0–8 %, None at 0)
  on Mac and web; MCP / WebMCP `set_style` key `cameraStackGap`. The seam
  notch still drags at Gap 0 (its hit band is padded).
- Gates: `cameraStackRows` gap cases, `cameraLayoutResolve` joined cases
  (resolved now carries `cameraShapeRect`, `cardClipShapeRect`, `seamJoin`),
  `projectDecode` key; `--cameralayout-test` (clamp, rows touch, shapes in
  both Y conventions, square radius 0, morph eases the join); `--preview-parity`
  `stack-joined` (the old gap band covered, the real mask paths square at the
  seam and round outside) with a self-test that ignoring the shapes fails;
  parity fixture `23-camera-stack-joined` (radius 40, strong shadow, a Bubble
  block).
