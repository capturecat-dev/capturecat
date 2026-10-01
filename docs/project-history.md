# Project history — merge, change-set and wire contract

Status: Phase 0 (contract + fixtures) and Phase 2 (pure merge core in TS and
Swift) landed 2026-09-30. The API (1A/1B), web UI (3A), Mac sync (3B) and Mac
History UI (3C) build on this document.

| Piece | TypeScript (`apps/web/src/editor/core/merge/`) | Swift (`apps/macos/CaptureCat/Services/ProjectHistory/`) |
|---|---|---|
| Raw JSON, canonical JSON, hash | `jsonMerge.ts` | `JSONValue.swift` |
| Policy table | `policy.ts` (`MERGE_POLICY`) | `MergePolicy.swift` (`MergePolicy.standard`) |
| Three-way merge | `projectMerge.ts` (`merge`) | `ProjectMerge.swift` (`ProjectMerge.merge`) |
| Change-sets, compose, header | `projectDiff.ts` | `ProjectDiff.swift` |
| Summary captions | `changeSummary.ts` | `ChangeSummary.swift` |
| Fixtures (the contract) | `fixtures/*.json` (56 triples) | read by `WebVectors+Merge.swift` |
| Golden (written by Swift) | `golden/{mergePolicy,mergeRandom,projectMerge}.json` | `--web-vectors … --only mergePolicy,mergeRandom,projectMerge` |

## Owner decisions (final)

1. Team members EDIT the document and every save is attributed to the real
   actor uid. Only the OWNER adds or replaces media (uploads count against the
   owner's storage).
2. Same-field clashes: the MOST RECENT EDIT wins automatically, logged in
   History (both input documents are kept as versions). Structural clashes ask
   the user: clip structure changed on both sides, delete-vs-modify, subtitles
   regenerated on one side while edited on the other, and new exclusive-lane
   overlaps.
3. Old media: versions pin everything, and pinned media counts toward storage.
   History shows "History keeps X of removed media [Free up]", which deletes
   the unnamed versions pinning it.
4. Retention: Pro 30 days + 25 named versions; Business 365 days + 500 named.
   Free has no cloud history; the Mac-only local history (Phase 5) is for Free
   and offline projects.
5. This is async version control, not real-time co-editing.

## 1. Merge

```ts
merge(base, mine, theirs, mineWins, choices = {}) → { merged, conflicts[], autoResolved[] }
```
```swift
ProjectMerge.merge(base:mine:theirs:mineWins:choices:) -> MergeResult
```

- Inputs are RAW project.json values (`Json` / `JSONValue`), never decoded
  models: decoding drops unknown keys, and an id-less `CameraLayoutRegion`
  gets a fresh random `UUID()` on every decode (web `parseProject` does the
  same), so a merge on models could neither preserve unknown data nor match
  elements.
- `mineWins` is decided by the CALLER: last local edit time vs the server's
  `updated_at`, ties → theirs. The function has no clock, so it is golden-testable.
- `choices` maps conflict `id` → `"mine" | "theirs"`. Every conflict is
  already resolved in `merged` (choice, else the last writer); Merge Review
  flips one by re-merging with a different choice. Ids are stable across
  re-merges.
- The merge is pure, deterministic and total. Identity laws hold exactly
  (canonical JSON, no conflicts, nothing auto-resolved) for either
  `mineWins`: `merge(b,x,b)=x`, `merge(b,b,y)=y`, `merge(b,x,x)=x`.

### 1.1 Algorithm

Absent keys are distinct from `null`. Equality is structural: objects as
maps (order-insensitive), numbers with IEEE `==` (so `-0 == 0`), strings by
UTF-16 code units (JavaScript `===`; the Swift twin does NOT use Swift's
canonical-equivalence `String ==`).

**Three-way of one value** (`threeWay`): mine == theirs → mine; mine == base →
theirs; theirs == base → mine; else both changed → the last writer's value,
logged `{path, kind: "field", winner}`.

**Objects the policy opens** — the root, `settings`, and each id-collection
element — merge per key (every other object value, e.g. a colour,
`exportSettings`, `focalPoint`, an unknown nested object, is ONE value):
1. atomic groups first, in policy order: a group "changed" on a side when any
   of its keys (presence included) differs from base. One side changed → all
   its keys from that side; both changed identically → mine; both differently
   → the last writer, logged `{path: "<obj>.{k1,k2,…}", kind: "group"}` — or,
   for a PROMPT group, a conflict;
2. every other key in UTF-16-sorted order, through its child merger
   (`settings` → per key, id collections → §1.2, else `threeWay`);
3. output key order: mine's keys, then keys only theirs has; absent results
   are dropped.

The log order (autoResolved, conflicts) is exactly this traversal order, then
lane-overlap conflicts (§1.3).

### 1.2 Id collections

A collection merges by id when all three sides are arrays of objects each
with a non-empty string `id`, ids unique (an absent key counts as `[]`).
Otherwise — a legacy element without an id, a duplicate id, a non-array — the
whole collection is ONE value (`threeWay`).

Per id (visited in output order):

| base | mine | theirs | result |
|---|---|---|---|
| any | ✓ | ✓ | element merge (per key with the element's groups; nested id collections recurse) |
| – | ✓ | – | added by mine → kept |
| – | – | ✓ | added by theirs → kept |
| ✓ | = base | – | theirs deleted → deleted |
| ✓ | ≠ base | – | **deleteVsModify** conflict (`deletedBy: "theirs"`); `mine` keeps mine's element, `theirs` deletes |
| ✓ | – | = base | mine deleted → deleted |
| ✓ | – | ≠ base | **deleteVsModify** conflict (`deletedBy: "mine"`); `theirs` keeps theirs', `mine` deletes |
| ✓ | – | – | deleted by both |

Output order: mine's order with theirs-only ids appended — annotation order is
z-order and is never re-sorted. Refinement: when ONLY theirs changed the
relative order of the ids all three share, theirs' order is the backbone (and
mine-only ids are appended); when both reordered differently, the last
writer's order wins, logged `{path: "<collection>", kind: "order"}`.

**Subtitles regenerated** (policy `regenerationCheck`): when both sides
changed `subtitles` and on at least one side fewer than 50 % of the base ids
survive, the whole array is one choice — **subtitlesRegenerated** conflict
(`regeneratedBy: mine | theirs | both`), default last writer. A base with no
captions never counts as regenerated.

### 1.3 Exclusive lanes

After the per-key merge, each exclusive lane's overlapping pairs are computed
on merged, mine and theirs (two spans overlap when
`a.start < b.end − 0.0001 && b.start < a.end − 0.0001`, the timeline's drag
clamp). A pair overlapping in merged but in NEITHER input is a
**laneOverlap** conflict (`lane`, `elements: [a, b]`, sorted). Its
resolution puts BOTH elements back to the chosen side's version (removing one
that side does not have) — that pair never overlapped there. Detection runs
once on the merged document; resolutions apply in conflict order (an element
an earlier resolution removed stays removed). Pre-existing overlaps (legacy
projects) are never conflicts.

| Lane | Collections | Source of the rule |
|---|---|---|
| `effects` | `zoomRegions`, `tiltRegions` | `TimelineCanvasView.effectLaneSpans`, `TimelineViewController.effectLaneSpans`. A zoom and a tilt co-spanning within 0.02 s (`EffectBlockItem.linkEpsilon`) are ONE linked block, paired like `canvasEffectItems` (each zoom claims the first unclaimed co-spanning tilt, array order) and never overlap each other. |
| `focus` | `blurRegions`, `focusRegions`, `cameraLayoutRegions`, `highlightRegions` | `focusLaneSpans` (drag clamp over `TimelineFocusItem`s). Note: `addBlurRegion` / `addHighlightRegion` only look at their own collection when placing, but the lane's drag clamp covers all four. |
| `speed` | `speedRegions` | `addSpeedRegion` / duplicate guards |
| not exclusive | `annotations`, `voiceOverClips`, `subtitles` | annotate lane: "Overlaps are allowed on this lane"; `VoiceTrackEditMath` has no neighbour clamp; subtitles have no timeline lane |

### 1.4 Conflicts

| kind | id | path | extra fields |
|---|---|---|---|
| `clipStructure` | `clipStructure:{videoClipSegments,splitPoints,trimStart,trimEnd}` | the group path | – |
| `deleteVsModify` | `deleteVsModify:<path>` | `annotations[<id>]`, `subtitles[<id>].words[<id>]`, … | `deletedBy` |
| `subtitlesRegenerated` | `subtitlesRegenerated:subtitles` | `subtitles` | `regeneratedBy` |
| `laneOverlap` | `laneOverlap:<a>|<b>` | `<a>|<b>` (element paths, sorted) | `lane`, `elements` |

Every conflict carries `resolution` (applied) and `defaultResolution` (the last
writer). Canonical JSON of a conflict omits absent extra fields.

## 2. Policy table

The literal lives in both languages; `policyHash()` / `MergePolicy.hash`
(FNV-1a 64 of the canonical JSON, currently `4e0210e162794288`) is recorded
in `golden/mergePolicy.json` and the TS suite fails on any drift.

**Merged by id** (element groups in brackets):

| Collection | Atomic groups per element |
|---|---|
| `zoomRegions` | {startTime, endTime}, {focalPoint}, {cardOffsetX, cardOffsetY} |
| `tiltRegions` | {startTime, endTime} |
| `blurRegions`, `highlightRegions`, `focusRegions` | {startTime, endTime}, {rectX, rectY, rectW, rectH} |
| `cameraLayoutRegions` | {startTime, endTime} |
| `annotations` | {startTime, endTime}, {x, y, arrowEndX, arrowEndY}, {drawingStrokes} |
| `voiceOverClips` | {startTime, sourceStartTime, duration} |
| `speedRegions` | {startTime, endTime} |
| `subtitles` (+ regeneration check) | {startTime, endTime}; nested `words` by id with {startTime, endTime} |

**Root atomic groups:** `clipStructure` {videoClipSegments, splitPoints,
trimStart, trimEnd} — PROMPT; `recording` {sourceSegments, duration,
videoURL, cursorDataURL, keystrokeDataURL, cameraVideoURL, cameraTimeOffset,
recordingSourceKind}.

**Settings atomic groups:** {videoPlacement, videoCustomX, videoCustomY},
{cameraPosition, cameraCustomX, cameraCustomY}, {subtitlePosition,
subtitleCustomX, subtitleCustomY}, {watermarkX, watermarkY},
{backgroundType, backgroundImagePath}, {screenTiltMode, screenTiltAngle,
screenTiltYaw, screenTiltRoll}, {introSlideStyle, introSlideStart,
introSlideDuration}, {curtainUnveilCorner, curtainUnveilStart,
curtainUnveilDuration}, {exportSettings}.

**Everything else:** per key three-way; both changed → last writer, logged.

**Settings → inspector tab** (`settingsTabs`, from the Mac pane that edits each
key — `Views/Editor/InspectorKit/*PaneAppKit.swift`): `background`,
`cursor`, `camera`, `audio` (incl. `muteRecordedAudio`), `effects` (motion
blur, parallax, intro, curtain, legacy screen tilt), `motion`
(`animationSpeed`, `autoZoomLevel`, `cameraFollowSpeed`), `subtitles`,
`brand`, `canvas` (`aspectRatio`), `export` (`exportSettings`); unknown keys →
`other`. A test asserts all 139 `ProjectSettings` keys map to exactly one tab.

### 2.1 Model facts, verified against the code (2026-09-30)

- Required `UUID` ids (`decode(UUID.self, …)` or synthesized `let id`):
  zoom, tilt, blur, highlight, focus, annotation, voice-over, subtitle,
  subtitle word, speed, and also `VideoClipSegment`. Confirmed.
- `CameraLayoutRegion` decodes a missing id as `UUID()` — and the web's
  `decodeCameraLayoutRegion` does the same (`newUUID()`). Consequence: the
  first client that re-saves an id-less project gives its regions fresh
  RANDOM ids, so base (id-less) vs mine (ids) is a mixed collection → one
  value, last writer (fixture `legacy-idless-mixed`). After that save, merges
  are by id.
- `TimelineViewController.splitVideoClip` removes the split clip and inserts
  TWO new clips with fresh ids (neither half keeps the old id), and appends
  the split to `splitPoints`. Hence clip structure is one prompt group.
- `splitPoints`, `sourceSegments`, `drawingStrokes` have no ids → atomic.
- **Correction:** `VoiceOverClip` has no `endTime`; its timing group is
  {startTime, sourceStartTime, duration} (what `VoiceTrackEditMath.resizeLeft`
  moves together).
- **Additions** (same reasoning as the design's position triples): the
  watermark position pair {watermarkX, watermarkY} and the zoom card offset
  pair {cardOffsetX, cardOffsetY}.
- **Tightened:** only the root, `settings` and elements merge per key; any
  other object value is atomic — merging a colour's `red` from one side and
  `blue` from the other makes a colour nobody chose (fixture
  `settings-color-atomic`).

## 3. Canonical JSON and hashing

Used for every comparison and every golden string; identical bytes in both
languages:

- objects: keys sorted by UTF-16 code units, `{"k":v,…}`, no whitespace;
- numbers: ECMAScript `Number::toString` (`String(n)` in JS; Swift rebuilds it
  from the shortest round-trip digits), `-0` → `0`; non-finite numbers are not
  JSON (throw / precondition);
- strings: escape `"` `\` and U+0000–U+001F only (`\b \f \n \r \t`, else
  `\u00xx` lowercase); everything else literal;
- hash: FNV-1a 64 over the UTF-8 bytes, 16 lowercase hex digits.

## 4. Change-set

```jsonc
{
  "v": 1,
  "items": {                                   // id collections, by project.json key
    "zoomRegions": {
      "added":   ["<id>", …],                  // sorted; omitted when empty
      "removed": ["<id>", …],
      "changed": { "<id>": ["zoomLevel", …] }, // element keys that differ, sorted
      "reordered": true                         // shared ids changed relative order (z-order)
    },
    "subtitles": { "counts": { "added": 180, "removed": 172, "changed": 0 } }, // truncated form
    "cameraLayoutRegions": { "replaced": true } // legacy id-less / malformed collection changed
  },
  "settings": { "background": ["backgroundPadding"], "other": ["futureKey"] }, // keys by tab, sorted
  "fields": ["name", "trimEnd"]                  // other root keys that differ, sorted ("*" = non-object documents)
}
```

- `diff(a, b)` (a → b). A collection entry has exactly one form: exact, or
  truncated (`counts` + optional `reordered`), or `replaced`. Entries with no
  change are omitted; `settings` tabs with no keys are omitted.
- `composeChangeSets(x, y)` (a→b then b→c): per id, add+change = add,
  add+remove = nothing, change+remove = remove, remove+add = change (with no
  field detail), change+change = union of fields. If either side of a
  collection is truncated, counts are summed (an upper bound); if either is
  `replaced`, the result is `replaced`. Settings keys and fields: sorted union.
- `countChanges(cs)`: each added/removed/edited element, reorder or replaced
  collection 1, each changed settings tab 1, each field phrase 1.

### 4.1 `X-CC-Change` header

Value: base64url (no padding) of the change-set's canonical JSON, at most
8192 characters. Over the budget, the exact collection with the most ids
(ties → first key in sorted order) degrades to its counts, repeatedly; then
every settings tab collapses to `["*"]`; if it still does not fit, send no
header. `decodeChangeHeader` validates (`v` = 1, string lists, non-negative
safe-integer counts), ignores unknown keys, normalizes (sorts, dedupes) and
returns null on anything malformed. The API may import
`jsonMerge.ts` + `policy.ts` + `projectDiff.ts` (no model dependency) or copy
them; `golden/mergePolicy.json` has compose / header / decode vectors to test
a copy against.

## 5. Change summary

`formatChangeSummary(cs, maxParts = 0)` / `ChangeSummary.format(_:maxParts:)`,
joined with " · " (U+00B7). Fixed phrase order:

1. fields: "Clips edited" (videoClipSegments / splitPoints), "Trim changed"
   (trimStart / trimEnd), "Recording replaced" (any recording-group key);
2. timeline items in lane order — zoom, tilt, speed region, blur, highlight,
   depth focus, camera layout, annotation, voice-over: "Zoom added",
   "3 zooms removed", "Zoom edited", "Annotations reordered",
   "Camera layouts changed" (replaced);
3. settings tabs in InspectorTab order: "Background changed",
   "Cursor changed", "Camera changed", "Audio changed", "Effects changed",
   "Motion changed", "Caption style changed", "Brand changed", then
   "Aspect ratio changed", "Export settings changed", "Settings changed"
   (other / unknown tabs, once);
4. captions: "Caption added", "3 captions edited", …;
5. fields: "Renamed", "Image/video mode changed", "Reminder changed",
   "Other changes" (any other root key or unknown item key, once).

Empty → "No changes". `maxParts > 0` keeps the first `maxParts` phrases and
appends "+N more". Example: "Zoom added · Background changed · 3 captions edited".

## 6. Wire contract (Phase 1A/1B own the server side)

`PUT /cloud-projects/:id/project` gains optional request headers; old clients
send none and keep working:

| Header | Value | Meaning |
|---|---|---|
| `X-CC-Client` | `mac` \| `web` | stored as `client_kind`; anything else → `unknown` |
| `X-CC-Client-Id` | opaque install/browser id, ≤ 64 chars `[A-Za-z0-9_-]` | coalescing key |
| `X-CC-Source` | `human` \| `agent` \| `mixed` | Mac: `agent` when the `.mcp-history` postSHA256 chain covers base→current exactly, else `mixed`; web: from the undo entries' `source` |
| `X-CC-Change` | §4.1 | base → new change-set; malformed → ignored (the save still succeeds) |
| `X-CC-Checkpoint` | `merge` \| `restore` \| `push` \| `upload` \| `named` | force a NEW version; honoured at most once per minute per project |
| `X-CC-Merged-From` | integer revision | the server revision (theirs) this save merged; version kind `merge` |

Response adds `version: { id, seq, extended }`.

Coalescing: a save EXTENDS the head version when all hold — same
`actor_uid` + `client_id` + `source`; head unnamed and of kind `edit`; head
opened < 10 min ago and updated < 3 min ago; no `X-CC-Checkpoint`. Otherwise
it opens a new version. Mac push, merge, restore and first upload always open
a new version. An extended version's `change_json` =
`composeChangeSets(head.change_json, X-CC-Change)` (canonical JSON, ≤ 32 KB).

Routes (design §4): `GET …/:id/head`, `GET …/:id/versions?before=&limit=50`,
`GET …/:id/versions/:vid`, `GET …/:id/revisions/:rev/document`,
`PATCH …/versions/:vid {label}`, `POST …/versions/:vid/restore` (+ If-Match),
`DELETE …/versions/:vid` (owner only).

## 7. Merge bases (Phase 3)

- **Web:** base = `JSON.parse(store.documentText(savedProject))`, mine =
  `store.documentJSON()`, theirs = `JSON.parse(conflict.serverDocument)`.
  Clean → `parseProject(merged)` applied as ONE undo entry, revision =
  serverRevision, `savedProject` = theirs, then save with
  `X-CC-Checkpoint: merge`, `X-CC-Merged-From`, and
  `X-CC-Change = encodeChangeHeader(diff(theirs, merged))`. Conflicts →
  `sync: "review"`, nothing saved until resolved.
- **Mac:** `.cloudsync.json` gains `baseFile: ".cloudsync-base.json"` (exact
  bytes at the last agreed revision). Parse with `JSONValue.parse(data:)`,
  merge, decode `Project` from `merged.canonical` (proven to decode by the
  gate below). Caveat: `Project`'s Codable drops keys the Mac does not know,
  so a merged document written THROUGH the model loses web-only keys — write
  the merged raw JSON when preserving them matters.

## 8. Gates

- `cd apps/web && npx vitest run src/editor/core/merge` —
  `merge.golden.test.ts` (TS == Swift, exact strings: 56 fixtures × default /
  every-conflict-flipped / last-writer-reversed merges, diffs, compose,
  headers, summaries; 32 Swift-generated random triples; 263 policy / number /
  string / compose / summary / header vectors; stale-fixture and policy-hash
  checks) and `merge.properties.test.ts` (identity laws on 400 random triples +
  every fixture, unknown keys never dropped, diff/compose/header invariants,
  every settings key mapped to one tab).
- `apps/web/scripts/merge-vectors.sh` — stages the fixtures into the app
  sandbox, regenerates the golden from the REAL Swift (the unit FAILS unless
  every input and merged output decodes with `Project`'s Codable and the
  identity laws hold in Swift), then runs `--web-roundtrip-check` on every
  web-serialized merged output (`--against` the raw merge; id-less camera
  layouts get decode + fixpoint only, since both decoders invent random ids).
- Fixtures are authored by `apps/web/scripts/merge-fixtures.mjs`; edit a
  scenario there, regenerate the fixtures, then the golden. Never hand-edit
  golden files.
