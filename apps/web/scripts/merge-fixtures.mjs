#!/usr/bin/env node
/**
 * Writes the synthetic merge triples in
 * apps/web/src/editor/core/merge/fixtures/ (one <name>.json per fixture):
 *
 *   { name, description, covers: [...], mineWins, base, mine, theirs }
 *
 * The committed JSON files are the contract (docs/project-history.md); this
 * script is only how they were authored. Edit a scenario here, run
 * `node apps/web/scripts/merge-fixtures.mjs`, then regenerate the golden with
 * `apps/web/scripts/merge-vectors.sh` (the TS suite fails on a stale golden).
 *
 * Every document is a MINIMAL project the Mac decodes (the 21 required
 * settings keys + exportSettings); ids are fixed uppercase UUIDs so the
 * outputs are deterministic. Synthetic data only.
 */
import { mkdirSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const outDir = join(here, "../src/editor/core/merge/fixtures");

// ── ids ──────────────────────────────────────────────────────────────────

const PREFIX = {
  project: "F0",
  zoom: "21",
  tilt: "22",
  blur: "23",
  highlight: "24",
  focus: "25",
  layout: "26",
  annotation: "27",
  voice: "28",
  speed: "29",
  caption: "2A",
  word: "2B",
  clip: "2C",
};
const uuid = (kind, n) => `${PREFIX[kind]}000000-0000-4000-8000-${String(n).padStart(12, "0")}`;

// ── documents ────────────────────────────────────────────────────────────

const color = (red, green, blue, opacity = 1) => ({ red, green, blue, opacity });

function project(n) {
  return {
    id: uuid("project", n),
    name: "Merge fixture",
    createdAt: 780000000,
    videoURL: "file:///merge-fixture/recording.mov",
    cursorDataURL: null,
    cameraVideoURL: null,
    cameraTimeOffset: 0,
    settings: {
      backgroundType: "Gradient",
      gradientStartColor: color(0.5, 0.2, 0.9),
      gradientEndColor: color(0.1, 0.4, 1),
      solidColor: color(0, 0, 0),
      backgroundPadding: 48,
      cornerRadius: 12,
      shadowRadius: 20,
      shadowOpacity: 0.5,
      cursorScale: 1.5,
      autoHideDelay: 3,
      smoothingFactor: 0.15,
      showCamera: false,
      cameraPosition: "Bottom Right",
      cameraSize: 120,
      cameraShape: "Circle",
      systemAudioVolume: 1,
      microphoneVolume: 1,
      animationSpeed: "Mellow",
      motionBlur: false,
      aspectRatio: "16:9",
      exportSettings: {
        format: "MP4",
        resolution: "1080p",
        fps: 60,
        quality: 0.85,
        customWidth: 1920,
        customHeight: 1080,
        collapseStaticSpans: true,
      },
    },
    zoomRegions: [],
    tiltRegions: [],
    blurRegions: [],
    highlightRegions: [],
    focusRegions: [],
    cameraLayoutRegions: [],
    annotations: [],
    voiceOverClips: [],
    subtitles: [],
    speedRegions: [],
    splitPoints: [],
    videoClipSegments: [],
    duration: 30,
    trimStart: 0,
    trimEnd: 0,
    recordingSourceKind: "display",
    sourceSegments: [],
    isStillCapture: false,
    stillTreatment: "video",
  };
}

const zoom = (n, s, e, extra = {}) => ({
  id: uuid("zoom", n),
  startTime: s,
  endTime: e,
  zoomLevel: 2,
  focalPoint: [0.5, 0.5],
  ...extra,
});
const tilt = (n, s, e, extra = {}) => ({ id: uuid("tilt", n), startTime: s, endTime: e, pitch: 20, yaw: 0, roll: 0, ...extra });
const blur = (n, s, e, extra = {}) => ({
  id: uuid("blur", n),
  startTime: s,
  endTime: e,
  label: "Blur",
  intensity: 0.6,
  style: "Blur",
  animated: false,
  rectX: 0.3,
  rectY: 0.3,
  rectW: 0.4,
  rectH: 0.15,
  ...extra,
});
const highlight = (n, s, e, extra = {}) => ({
  id: uuid("highlight", n),
  startTime: s,
  endTime: e,
  label: "Highlight",
  opacity: 0.55,
  rectX: 0.2,
  rectY: 0.18,
  rectW: 0.42,
  rectH: 0.2,
  ...extra,
});
const focus = (n, s, e, extra = {}) => ({
  id: uuid("focus", n),
  startTime: s,
  endTime: e,
  label: "Focus",
  intensity: 0.7,
  falloff: 0.45,
  style: "Area",
  angle: 0,
  cornerRadius: 24,
  rectX: 0.28,
  rectY: 0.3,
  rectW: 0.44,
  rectH: 0.34,
  ...extra,
});
const layout = (n, s, e, mode = "cameraOnly", extra = {}) => ({ id: uuid("layout", n), startTime: s, endTime: e, mode, ...extra });
const annotation = (n, s, e, extra = {}) => ({
  id: uuid("annotation", n),
  type: "text",
  startTime: s,
  endTime: e,
  x: 0.5,
  y: 0.38,
  arrowEndX: 0.65,
  arrowEndY: 0.55,
  text: "Label",
  fontSize: 18,
  showBackground: true,
  color: color(1, 1, 1),
  backgroundColor: color(0, 0, 0, 0.55),
  lineWidth: 4,
  drawingStrokes: [],
  ...extra,
});
const voice = (n, s, duration, extra = {}) => ({
  id: uuid("voice", n),
  fileName: `voice-${n}.m4a`,
  startTime: s,
  sourceStartTime: 0,
  duration,
  sourceDuration: duration,
  gain: 1,
  label: "Voice Over",
  ...extra,
});
const speed = (n, s, e, value = 2, extra = {}) => ({ id: uuid("speed", n), startTime: s, endTime: e, speed: value, ...extra });
const word = (n, s, e, text) => ({ id: uuid("word", n), startTime: s, endTime: e, text });
const caption = (n, s, e, text, words = []) => ({ id: uuid("caption", n), startTime: s, endTime: e, text, words });
const clip = (n, s, e) => ({ id: uuid("clip", n), startTime: s, endTime: e });

// ── fixture DSL ──────────────────────────────────────────────────────────

const clone = (v) => structuredClone(v);
const fixtures = [];

/**
 * fixture(name, description, covers, { mineWins, base(doc), mine(doc), theirs(doc) })
 * base(doc) mutates a fresh project; mine/theirs mutate deep clones of base.
 */
function fixture(name, description, covers, spec) {
  const n = fixtures.length + 1;
  const base = project(n);
  spec.base?.(base);
  const mine = clone(base);
  spec.mine?.(mine);
  const theirs = clone(base);
  spec.theirs?.(theirs);
  fixtures.push({ name, description, covers, mineWins: spec.mineWins ?? true, base, mine, theirs });
}

const find = (arr, kind, n) => arr.find((e) => e.id === uuid(kind, n));
const remove = (arr, kind, n) => arr.splice(arr.findIndex((e) => e.id === uuid(kind, n)), 1);

// ── Identity / trivial ───────────────────────────────────────────────────

fixture("identical-edits", "Both sides made the exact same edits (zoom level + padding): no conflict, nothing auto-resolved.", ["policy:three-way-same-change"], {
  base: (d) => d.zoomRegions.push(zoom(1, 2, 5)),
  mine: (d) => {
    find(d.zoomRegions, "zoom", 1).zoomLevel = 2.5;
    d.settings.backgroundPadding = 64;
  },
  theirs: (d) => {
    find(d.zoomRegions, "zoom", 1).zoomLevel = 2.5;
    d.settings.backgroundPadding = 64;
  },
});

// ── Everything else: per key, last writer on a clash ─────────────────────

fixture("settings-disjoint-keys", "Mine changes backgroundPadding, theirs changes cursorScale: both kept.", ["policy:settings-per-key"], {
  mine: (d) => (d.settings.backgroundPadding = 72),
  theirs: (d) => (d.settings.cursorScale = 2.25),
});

fixture("settings-same-key-mine-wins", "Both change cornerRadius; mine is the last writer.", ["policy:field-lww", "autoResolved"], {
  mineWins: true,
  mine: (d) => (d.settings.cornerRadius = 20),
  theirs: (d) => (d.settings.cornerRadius = 4),
});

fixture("settings-same-key-theirs-wins", "Both change cornerRadius and shadowOpacity; theirs is the last writer.", ["policy:field-lww", "autoResolved"], {
  mineWins: false,
  mine: (d) => {
    d.settings.cornerRadius = 20;
    d.settings.shadowOpacity = 0.8;
  },
  theirs: (d) => {
    d.settings.cornerRadius = 4;
    d.settings.shadowOpacity = 0.2;
  },
});

fixture("settings-color-atomic", "Mine edits gradientStartColor.red, theirs .blue: a colour is ONE value (last writer), never a blend nobody picked.", ["policy:nested-objects-atomic"], {
  mine: (d) => (d.settings.gradientStartColor.red = 0.9),
  theirs: (d) => (d.settings.gradientStartColor.blue = 0.1),
});

fixture("root-scalar-lww", "Both rename the project, theirs last; mine also toggles stillTreatment.", ["policy:field-lww", "summary:renamed"], {
  mineWins: false,
  mine: (d) => {
    d.name = "Mine's title";
    d.stillTreatment = "image";
  },
  theirs: (d) => (d.name = "Theirs' title"),
});

// ── Settings atomic groups ───────────────────────────────────────────────

fixture("settings-group-video-placement", "Mine picks placement Left, theirs drags a custom X/Y: the placement triple is atomic (last writer).", ["policy:group-videoPlacement"], {
  mine: (d) => (d.settings.videoPlacement = "Left"),
  theirs: (d) => {
    d.settings.videoCustomX = 0.3;
    d.settings.videoCustomY = 0.6;
  },
});

fixture("settings-group-camera-position", "Mine sets cameraPosition, theirs a custom camera X/Y; theirs wins the triple.", ["policy:group-cameraPosition"], {
  mineWins: false,
  mine: (d) => (d.settings.cameraPosition = "Top Left"),
  theirs: (d) => {
    d.settings.cameraCustomX = 0.8;
    d.settings.cameraCustomY = 0.2;
  },
});

fixture("settings-group-subtitle-position", "Subtitle position triple: mine moves to Top, theirs sets custom Y only.", ["policy:group-subtitlePosition"], {
  mine: (d) => (d.settings.subtitlePosition = "Top"),
  theirs: (d) => (d.settings.subtitleCustomY = 0.7),
});

fixture("settings-group-background-image", "Mine switches to an image background (type + path), theirs to a solid colour (type) and a new solid colour (outside the group).", ["policy:group-backgroundImage"], {
  mineWins: false,
  mine: (d) => {
    d.settings.backgroundType = "Image";
    d.settings.backgroundImagePath = "backgrounds/beach.jpg";
  },
  theirs: (d) => {
    d.settings.backgroundType = "Solid Color";
    d.settings.solidColor = color(0.2, 0.2, 0.25);
  },
});

fixture("settings-group-screen-tilt-and-watermark", "Screen-tilt quad (mine mode, theirs angle) and watermark X/Y pair (mine X, theirs Y).", ["policy:group-screenTilt", "policy:group-watermarkPosition"], {
  mine: (d) => {
    d.settings.screenTiltMode = "Intro";
    d.settings.watermarkX = 0.1;
  },
  theirs: (d) => {
    d.settings.screenTiltAngle = 35;
    d.settings.watermarkY = 0.1;
  },
});

fixture("settings-group-intro-curtain", "Intro triple (mine duration, theirs style) and curtain triple (mine corner, theirs start); theirs is the last writer.", ["policy:group-intro", "policy:group-curtain"], {
  mineWins: false,
  base: (d) => {
    d.settings.introSlideStyle = "Bottom";
    d.settings.introSlideDuration = 0.9;
    d.settings.introSlideStart = 0;
  },
  mine: (d) => {
    d.settings.introSlideDuration = 1.4;
    d.settings.curtainUnveilCorner = "Top Left";
  },
  theirs: (d) => {
    d.settings.introSlideStyle = "Left";
    d.settings.curtainUnveilStart = 2;
  },
});

fixture("settings-export-atomic", "Mine changes exportSettings.fps, theirs .format: the whole exportSettings is one value.", ["policy:group-exportSettings"], {
  mine: (d) => (d.settings.exportSettings.fps = 30),
  theirs: (d) => (d.settings.exportSettings.format = "GIF"),
});

fixture("settings-group-one-side", "Only mine touches the placement triple; theirs edits an unrelated key: mine's triple taken whole, no log.", ["policy:group-one-side"], {
  base: (d) => {
    d.settings.videoCustomX = 0.4;
    d.settings.videoCustomY = 0.4;
  },
  mine: (d) => {
    d.settings.videoPlacement = "Right";
    delete d.settings.videoCustomX;
    delete d.settings.videoCustomY;
  },
  theirs: (d) => (d.settings.shadowRadius = 32),
});

// ── Root atomic groups ───────────────────────────────────────────────────

fixture("recording-group", "Mine re-records (videoURL + duration), theirs nudges cameraTimeOffset: the recording group is atomic (last writer).", ["policy:group-recording", "summary:recording"], {
  mineWins: false,
  mine: (d) => {
    d.videoURL = "file:///merge-fixture/retake.mov";
    d.duration = 42;
  },
  theirs: (d) => (d.cameraTimeOffset = 0.25),
});

fixture("clip-structure-both-changed", "Mine splits the clip (splitVideoClip: two FRESH clip ids + a split point), theirs trims the end: PROMPT conflict, mine is the default.", ["conflict:clipStructure", "fact:split-regenerates-clip-ids"], {
  base: (d) => d.videoClipSegments.push(clip(1, 0, 30)),
  mine: (d) => {
    d.videoClipSegments = [clip(2, 0, 12), clip(3, 12, 30)];
    d.splitPoints = [12];
  },
  theirs: (d) => (d.trimEnd = 27.5),
});

fixture("clip-structure-both-changed-theirs-wins", "Both edit clip structure (mine trims start, theirs deletes a clip): PROMPT conflict, theirs is the default.", ["conflict:clipStructure"], {
  mineWins: false,
  base: (d) => {
    d.videoClipSegments = [clip(1, 0, 10), clip(2, 10, 30)];
    d.splitPoints = [10];
  },
  mine: (d) => (d.trimStart = 1.5),
  theirs: (d) => (d.videoClipSegments = [clip(1, 0, 10)]),
});

fixture("clip-structure-one-side", "Mine splits a clip; theirs edits a zoom: clip structure taken from mine, no conflict.", ["policy:group-one-side", "summary:clips"], {
  base: (d) => {
    d.videoClipSegments.push(clip(1, 0, 30));
    d.zoomRegions.push(zoom(1, 3, 6));
  },
  mine: (d) => {
    d.videoClipSegments = [clip(2, 0, 20), clip(3, 20, 30)];
    d.splitPoints = [20];
  },
  theirs: (d) => (find(d.zoomRegions, "zoom", 1).zoomLevel = 3),
});

// ── Id collections ───────────────────────────────────────────────────────

fixture("zoom-add-both-sides", "Each side adds a different, non-overlapping zoom: both kept, mine's order then theirs' additions.", ["policy:id-add", "policy:id-order"], {
  base: (d) => d.zoomRegions.push(zoom(1, 1, 3)),
  mine: (d) => d.zoomRegions.push(zoom(2, 5, 7)),
  theirs: (d) => d.zoomRegions.push(zoom(3, 10, 12, { zoomLevel: 1.8 })),
});

fixture("zoom-remove-one-side", "Theirs removes an untouched zoom, mine edits another: removal taken.", ["policy:id-remove"], {
  base: (d) => d.zoomRegions.push(zoom(1, 1, 3), zoom(2, 5, 7)),
  mine: (d) => (find(d.zoomRegions, "zoom", 2).zoomLevel = 1.6),
  theirs: (d) => remove(d.zoomRegions, "zoom", 1),
});

fixture("zoom-modify-disjoint-fields", "Same zoom: mine changes zoomLevel, theirs animationStyle + followsCursor: merged per field.", ["policy:id-per-field"], {
  base: (d) => d.zoomRegions.push(zoom(1, 2, 6)),
  mine: (d) => (find(d.zoomRegions, "zoom", 1).zoomLevel = 2.75),
  theirs: (d) => Object.assign(find(d.zoomRegions, "zoom", 1), { animationStyle: "Snappy", followsCursor: false }),
});

fixture("zoom-modify-same-field", "Same zoom, same field (zoomLevel) on both sides: last writer (theirs), logged.", ["policy:id-field-lww", "autoResolved"], {
  mineWins: false,
  base: (d) => d.zoomRegions.push(zoom(1, 2, 6)),
  mine: (d) => (find(d.zoomRegions, "zoom", 1).zoomLevel = 3),
  theirs: (d) => (find(d.zoomRegions, "zoom", 1).zoomLevel = 1.5),
});

fixture("element-timing-group", "Mine resizes a tilt's left edge (startTime), theirs its right edge (endTime): {startTime,endTime} is atomic, so no frankenspan.", ["policy:group-element-timing"], {
  base: (d) => d.tiltRegions.push(tilt(1, 4, 8)),
  mine: (d) => (find(d.tiltRegions, "tilt", 1).startTime = 3),
  theirs: (d) => (find(d.tiltRegions, "tilt", 1).endTime = 10),
});

fixture("blur-rect-group", "Mine moves a blur (rectX/rectY), theirs resizes it (rectW/rectH) and changes intensity: rect atomic, intensity merges.", ["policy:group-element-rect"], {
  mineWins: false,
  base: (d) => d.blurRegions.push(blur(1, 2, 6)),
  mine: (d) => Object.assign(find(d.blurRegions, "blur", 1), { rectX: 0.1, rectY: 0.5 }),
  theirs: (d) => Object.assign(find(d.blurRegions, "blur", 1), { rectW: 0.6, rectH: 0.3, intensity: 0.9 }),
});

fixture("zoom-focal-point-card-offset", "focalPoint ([x,y]) is one value; cardOffsetX/Y is a pair. Mine moves the focal x and card X, theirs the focal y and card Y.", ["policy:group-element-focalPoint", "policy:group-element-cardOffset"], {
  base: (d) => d.zoomRegions.push(zoom(1, 2, 6, { cardOffsetX: 0, cardOffsetY: 0 })),
  mine: (d) => Object.assign(find(d.zoomRegions, "zoom", 1), { focalPoint: [0.2, 0.5], cardOffsetX: 0.1 }),
  theirs: (d) => Object.assign(find(d.zoomRegions, "zoom", 1), { focalPoint: [0.5, 0.8], cardOffsetY: -0.1 }),
});

fixture("annotation-geometry-group", "Arrow: mine drags the tail (x,y), theirs the head (arrowEndX/Y) and edits text: geometry atomic, text merges.", ["policy:group-annotation-geometry"], {
  base: (d) => d.annotations.push(annotation(1, 1, 5, { type: "arrow" })),
  mine: (d) => Object.assign(find(d.annotations, "annotation", 1), { x: 0.2, y: 0.25 }),
  theirs: (d) => Object.assign(find(d.annotations, "annotation", 1), { arrowEndX: 0.9, arrowEndY: 0.9, text: "Look" }),
});

fixture("annotation-drawing-strokes", "Both sides draw on the same drawing annotation: drawingStrokes (no ids) is one value; theirs wins.", ["policy:group-drawingStrokes", "fact:drawingStrokes-no-ids"], {
  mineWins: false,
  base: (d) =>
    d.annotations.push(
      annotation(1, 1, 5, { type: "drawing", drawingStrokes: [[{ x: 0.1, y: 0.1 }, { x: 0.2, y: 0.2 }]], enterEffect: "Fade", exitEffect: "Fade" }),
    ),
  mine: (d) => find(d.annotations, "annotation", 1).drawingStrokes.push([{ x: 0.5, y: 0.5 }, { x: 0.6, y: 0.4 }]),
  theirs: (d) => find(d.annotations, "annotation", 1).drawingStrokes.push([{ x: 0.7, y: 0.7 }, { x: 0.8, y: 0.9 }]),
});

fixture("voice-timing-group", "Voice-over has no endTime: mine trims its left edge (startTime + sourceStartTime + duration), theirs moves it (startTime) and changes gain.", ["policy:group-voice-timing", "fact:voice-no-endTime"], {
  base: (d) => d.voiceOverClips.push(voice(1, 4, 6)),
  mine: (d) => Object.assign(find(d.voiceOverClips, "voice", 1), { startTime: 5, sourceStartTime: 1, duration: 5 }),
  theirs: (d) => Object.assign(find(d.voiceOverClips, "voice", 1), { startTime: 8, gain: 0.5 }),
});

fixture("both-added-same-id", "Both sides re-add the same zoom id with different fields (e.g. both undid a delete then edited): merged per field.", ["policy:id-both-added"], {
  mine: (d) => d.zoomRegions.push(zoom(1, 2, 5, { zoomLevel: 2.5 })),
  theirs: (d) => d.zoomRegions.push(zoom(1, 2, 5, { animationStyle: "Smooth" })),
});

fixture("delete-both-sides", "Both sides delete the same highlight: gone, no conflict.", ["policy:id-remove"], {
  base: (d) => d.highlightRegions.push(highlight(1, 2, 4), highlight(2, 8, 9)),
  mine: (d) => remove(d.highlightRegions, "highlight", 1),
  theirs: (d) => {
    remove(d.highlightRegions, "highlight", 1);
    find(d.highlightRegions, "highlight", 2).opacity = 0.3;
  },
});

// ── Delete vs modify ─────────────────────────────────────────────────────

fixture("delete-vs-modify-theirs-deleted", "Theirs deletes an annotation mine edited: conflict; mine is the last writer, so it is kept.", ["conflict:deleteVsModify"], {
  base: (d) => d.annotations.push(annotation(1, 1, 4), annotation(2, 5, 8)),
  mine: (d) => (find(d.annotations, "annotation", 1).text = "Edited by mine"),
  theirs: (d) => remove(d.annotations, "annotation", 1),
});

fixture("delete-vs-modify-mine-deleted", "Mine deletes a zoom theirs edited, mine is the last writer: conflict, deleted by default.", ["conflict:deleteVsModify"], {
  base: (d) => d.zoomRegions.push(zoom(1, 2, 5), zoom(2, 8, 11)),
  mine: (d) => remove(d.zoomRegions, "zoom", 2),
  theirs: (d) => (find(d.zoomRegions, "zoom", 2).zoomLevel = 1.4),
});

fixture("delete-vs-modify-theirs-wins", "Mine deletes a speed region theirs edited; theirs is the last writer: kept by default.", ["conflict:deleteVsModify"], {
  mineWins: false,
  base: (d) => d.speedRegions.push(speed(1, 10, 14)),
  mine: (d) => remove(d.speedRegions, "speed", 1),
  theirs: (d) => (find(d.speedRegions, "speed", 1).speed = 4),
});

// ── Subtitles ────────────────────────────────────────────────────────────

const threeCaptions = (d) =>
  d.subtitles.push(
    caption(1, 0, 2, "Hello there", [word(1, 0, 1, "Hello"), word(2, 1, 2, "there")]),
    caption(2, 2, 4, "This is", [word(3, 2, 3, "This"), word(4, 3, 4, "is")]),
    caption(3, 4, 6, "CaptureCat", [word(5, 4, 6, "CaptureCat")]),
  );

fixture("subtitles-regenerated-mine-vs-edited", "Mine regenerates every caption (new ids), theirs fixes a caption's text: conflict; mine (last writer) by default.", ["conflict:subtitlesRegenerated"], {
  base: threeCaptions,
  mine: (d) => {
    d.subtitles = [
      caption(11, 0, 2.1, "Hello there,", [word(11, 0, 1, "Hello"), word(12, 1, 2.1, "there,")]),
      caption(12, 2.1, 6, "this is CaptureCat.", [word(13, 2.1, 3, "this"), word(14, 3, 4, "is"), word(15, 4, 6, "CaptureCat.")]),
    ];
  },
  theirs: (d) => (find(d.subtitles, "caption", 3).text = "Capture Cat"),
});

fixture("subtitles-regenerated-theirs-vs-edited", "Theirs regenerates (1 of 3 base ids survive < 50%), mine edits caption timing; theirs is the last writer.", ["conflict:subtitlesRegenerated"], {
  mineWins: false,
  base: threeCaptions,
  mine: (d) => Object.assign(find(d.subtitles, "caption", 2), { startTime: 2.2, endTime: 4.2 }),
  theirs: (d) => {
    d.subtitles = [find(d.subtitles, "caption", 1), caption(21, 2, 6, "This is CaptureCat", [word(21, 2, 6, "This is CaptureCat")])];
  },
});

fixture("subtitles-regenerated-only", "Mine regenerates the captions; theirs only changes caption style: regenerated captions taken, no conflict.", ["policy:regenerated-one-side"], {
  base: threeCaptions,
  mine: (d) => (d.subtitles = [caption(31, 0, 6, "Hello there, this is CaptureCat.")]),
  theirs: (d) => (d.settings.subtitleFontSize = 40),
});

fixture("subtitles-partial-survival", "Mine deletes 1 of 3 captions (67% survive: not a regeneration), theirs edits another: ordinary merge by id.", ["policy:regeneration-threshold"], {
  base: threeCaptions,
  mine: (d) => remove(d.subtitles, "caption", 1),
  theirs: (d) => (find(d.subtitles, "caption", 3).text = "CaptureCat!"),
});

fixture("subtitle-words-nested", "Nested words merge by id: mine retimes word 3, theirs retexts word 4 and the caption text.", ["policy:nested-words"], {
  base: threeCaptions,
  mine: (d) => Object.assign(find(find(d.subtitles, "caption", 2).words, "word", 3), { startTime: 2.1, endTime: 2.9 }),
  theirs: (d) => {
    const c = find(d.subtitles, "caption", 2);
    c.text = "This IS";
    find(c.words, "word", 4).text = "IS";
  },
});

fixture("subtitle-word-delete-vs-modify", "Mine deletes a word theirs retimed: nested delete-vs-modify conflict (theirs last writer → kept).", ["conflict:deleteVsModify", "policy:nested-words"], {
  mineWins: false,
  base: threeCaptions,
  mine: (d) => {
    const c = find(d.subtitles, "caption", 1);
    c.text = "Hello";
    remove(c.words, "word", 2);
  },
  theirs: (d) => Object.assign(find(find(d.subtitles, "caption", 1).words, "word", 2), { startTime: 1.2 }),
});

// ── Exclusive lanes ──────────────────────────────────────────────────────

fixture("lane-overlap-effects-zoom", "Mine adds zoom 5–8 s, theirs adds zoom 7–10 s: a NEW overlap on the effects lane → conflict; mine wins, theirs' zoom is dropped by default.", ["conflict:laneOverlap", "lane:effects"], {
  mine: (d) => d.zoomRegions.push(zoom(1, 5, 8)),
  theirs: (d) => d.zoomRegions.push(zoom(2, 7, 10)),
});

fixture("lane-overlap-effects-linked-block", "Mine adds a LINKED zoom+tilt block 5–8 s (not an overlap with itself); theirs adds a tilt 6–9 s → two new overlaps; theirs wins.", ["conflict:laneOverlap", "lane:effects-link"], {
  mineWins: false,
  mine: (d) => {
    d.zoomRegions.push(zoom(1, 5, 8));
    d.tiltRegions.push(tilt(1, 5.01, 8));
  },
  theirs: (d) => d.tiltRegions.push(tilt(2, 6, 9)),
});

fixture("lane-overlap-focus-lane", "Mine adds a blur 2–5 s, theirs a camera layout 4–6 s: blur, depth focus, camera layout and highlight share the FOCUS lane → conflict.", ["conflict:laneOverlap", "lane:focus"], {
  mine: (d) => d.blurRegions.push(blur(1, 2, 5)),
  theirs: (d) => d.cameraLayoutRegions.push(layout(1, 4, 6, "sideBySide")),
});

fixture("lane-overlap-speed", "Speed regions are exclusive: mine adds 10–14 s, theirs 12–16 s; theirs wins.", ["conflict:laneOverlap", "lane:speed"], {
  mineWins: false,
  mine: (d) => d.speedRegions.push(speed(1, 10, 14, 2)),
  theirs: (d) => d.speedRegions.push(speed(2, 12, 16, 0.5)),
});

fixture("lane-overlap-by-move", "Mine moves zoom A right, theirs moves zoom B left: each side alone is clean, the merge overlaps → conflict; theirs wins, both zooms take theirs' spans.", ["conflict:laneOverlap", "lane:effects"], {
  mineWins: false,
  base: (d) => d.zoomRegions.push(zoom(1, 1, 4), zoom(2, 8, 11)),
  mine: (d) => Object.assign(find(d.zoomRegions, "zoom", 1), { startTime: 4, endTime: 7 }),
  theirs: (d) => Object.assign(find(d.zoomRegions, "zoom", 2), { startTime: 6, endTime: 9 }),
});

fixture("lane-overlap-preexisting", "An overlap already present in mine (legacy grace) is not a new overlap: no conflict.", ["lane:preexisting"], {
  base: (d) => d.highlightRegions.push(highlight(1, 2, 6), highlight(2, 5, 9)),
  mine: (d) => (find(d.highlightRegions, "highlight", 1).label = "Legacy overlap"),
  theirs: (d) => (find(d.highlightRegions, "highlight", 2).opacity = 0.8),
});

fixture("non-exclusive-lanes", "Annotations, voice-overs and captions may overlap: both sides add overlapping ones, no conflict.", ["lane:non-exclusive"], {
  mine: (d) => {
    d.annotations.push(annotation(1, 2, 6));
    d.voiceOverClips.push(voice(1, 3, 4));
  },
  theirs: (d) => {
    d.annotations.push(annotation(2, 4, 8, { type: "rectangle" }));
    d.voiceOverClips.push(voice(2, 5, 4));
  },
});

// ── Annotation z-order ───────────────────────────────────────────────────

const fourAnnotations = (d) => d.annotations.push(annotation(1, 0, 5), annotation(2, 0, 5), annotation(3, 0, 5), annotation(4, 0, 5));

fixture("annotation-z-order-theirs", "Theirs brings annotation 1 to front (reorder), mine edits annotation 3's text: theirs' z-order + mine's edit.", ["policy:z-order", "summary:reordered"], {
  base: fourAnnotations,
  mine: (d) => (find(d.annotations, "annotation", 3).text = "Mine"),
  theirs: (d) => d.annotations.push(d.annotations.shift()),
});

fixture("annotation-z-order-both", "Both reorder differently (mine sends 4 to back, theirs brings 1 to front): last writer's order (mine), logged.", ["policy:z-order-lww", "autoResolved"], {
  base: fourAnnotations,
  mine: (d) => d.annotations.unshift(d.annotations.pop()),
  theirs: (d) => d.annotations.push(d.annotations.shift()),
});

fixture("annotation-z-order-additions", "Both add annotations; theirs also reorders the shared ones: theirs' order is the backbone, mine's addition is appended on top.", ["policy:z-order", "policy:id-add"], {
  base: (d) => d.annotations.push(annotation(1, 0, 5), annotation(2, 0, 5)),
  mine: (d) => d.annotations.push(annotation(3, 0, 5, { type: "ellipse" })),
  theirs: (d) => {
    d.annotations.reverse();
    d.annotations.push(annotation(4, 0, 5, { type: "tap" }));
  },
});

// ── Legacy id-less collections ───────────────────────────────────────────

const idless = (s, e, mode) => ({ startTime: s, endTime: e, mode });

fixture("legacy-idless-camera-layout", "Camera layout regions WITHOUT ids (legacy; the decoder invents UUID() per decode): the collection is one value; both edit → last writer.", ["policy:legacy-idless", "fact:cameraLayout-optional-id"], {
  base: (d) => (d.cameraLayoutRegions = [idless(0, 4, "cameraOnly"), idless(10, 14, "sideBySide")]),
  mine: (d) => (d.cameraLayoutRegions[0].endTime = 5),
  theirs: (d) => (d.cameraLayoutRegions[1].mode = "screenOnly"),
});

fixture("legacy-idless-mixed", "Base is id-less; mine re-saved it (fresh ids, as parse+serialize does) and added a region; theirs edited the id-less array. Mixed → one value; theirs wins.", ["policy:legacy-idless"], {
  mineWins: false,
  base: (d) => (d.cameraLayoutRegions = [idless(0, 4, "cameraOnly")]),
  mine: (d) => (d.cameraLayoutRegions = [layout(1, 0, 4, "cameraOnly"), layout(2, 20, 24, "screenOnly")]),
  theirs: (d) => (d.cameraLayoutRegions[0].mode = "sideBySide"),
});

// ── Unknown keys ─────────────────────────────────────────────────────────

fixture("unknown-keys-root", "Keys this build does not know are merged per key and never dropped: mine adds a root object, theirs a root scalar.", ["policy:unknown-keys"], {
  mine: (d) => (d.futureFeature = { enabled: true, level: 3 }),
  theirs: (d) => (d.anotherFutureKey = "from a newer web build"),
});

fixture("unknown-keys-settings-and-elements", "Unknown keys inside settings (theirs) and inside a zoom element (mine) survive the merge.", ["policy:unknown-keys"], {
  base: (d) => d.zoomRegions.push(zoom(1, 2, 5)),
  mine: (d) => (find(d.zoomRegions, "zoom", 1).futureEasing = "spring(0.4)"),
  theirs: (d) => (d.settings.futureSetting = [1, 2, 3]),
});

fixture("unknown-key-both-changed", "An unknown nested object changed on both sides is ONE value (last writer), logged.", ["policy:unknown-keys", "policy:nested-objects-atomic"], {
  base: (d) => (d.futureFeature = { enabled: false, level: 1 }),
  mine: (d) => (d.futureFeature.level = 2),
  theirs: (d) => (d.futureFeature.enabled = true),
});

fixture("unknown-key-removed", "Theirs removes an unknown key mine left alone: removal taken; mine's unknown element key is kept.", ["policy:unknown-keys"], {
  base: (d) => {
    d.legacyKey = "obsolete";
    d.blurRegions.push(blur(1, 1, 2, { legacyFlag: true }));
  },
  mine: (d) => (find(d.blurRegions, "blur", 1).legacyFlag = false),
  theirs: (d) => delete d.legacyKey,
});

fixture("missing-collection-key", "Base predates focusRegions (key absent); theirs adds depth focus regions, mine leaves the key absent: the addition is taken.", ["policy:absent-collection"], {
  base: (d) => delete d.focusRegions,
  mine: (d) => (d.settings.motionBlur = true),
  theirs: (d) => (d.focusRegions = [focus(1, 3, 7)]),
});

// ── write ────────────────────────────────────────────────────────────────

/** Pretty JSON that keeps short objects/arrays on one line (readable diffs, small files). */
function compactJSON(value, indent = "") {
  const flat = JSON.stringify(value);
  if (flat.length + indent.length <= 160 || value === null || typeof value !== "object") return flat;
  const inner = indent + "  ";
  if (Array.isArray(value)) {
    return `[\n${value.map((v) => inner + compactJSON(v, inner)).join(",\n")}\n${indent}]`;
  }
  const entries = Object.entries(value).map(([k, v]) => `${inner}${JSON.stringify(k)}: ${compactJSON(v, inner)}`);
  return `{\n${entries.join(",\n")}\n${indent}}`;
}

mkdirSync(outDir, { recursive: true });
for (const f of readdirSync(outDir)) if (f.endsWith(".json")) rmSync(join(outDir, f));
const names = new Set();
for (const f of fixtures) {
  if (names.has(f.name)) throw new Error(`duplicate fixture ${f.name}`);
  names.add(f.name);
  writeFileSync(join(outDir, `${f.name}.json`), compactJSON(f) + "\n");
}
console.log(`merge-fixtures: wrote ${fixtures.length} fixtures to ${outDir}`);
