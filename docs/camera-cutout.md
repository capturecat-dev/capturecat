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

Raw mattes (Vision, MODNet) shimmer at the soft edge and flicker ±1–3 levels
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
- **Web:** transformers.js `background-removal` (`Xenova/modnet`) in a worker
  beside the Whisper one, every decoded camera frame, written with
  `encodeCameraMask` and uploaded as a cloud project file.
  - `apps/web/src/editor/segment/` (worker + client), `state/cameraMask.ts`
    (the job). The frame is drawn at the model's working size (shortest edge
    512), matted, area-resampled to the §2 resolution, conditioned (above)
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
