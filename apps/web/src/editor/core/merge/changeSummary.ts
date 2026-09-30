/**
 * `formatChangeSummary(cs)` — the History row caption, e.g.
 * "Zoom added · Background changed · 3 captions edited".
 *
 * Phrase order (fixed): clip structure / trim / recording, timeline items
 * (lane order), settings by inspector tab (InspectorTab order, then aspect
 * ratio, export, other), captions, then document fields. Twinned EXACTLY in
 * Swift (Services/ProjectHistory/ChangeSummary.swift); golden-tested.
 */
import { countsOf, type ChangeSet, type CollectionChange } from "./projectDiff";

export const SUMMARY_SEPARATOR = " · ";

/** [project.json key, singular (capitalized), plural (lowercase)] in lane order. */
const TIMELINE_NOUNS: ReadonlyArray<readonly [string, string, string]> = [
  ["zoomRegions", "Zoom", "zooms"],
  ["tiltRegions", "Tilt", "tilts"],
  ["speedRegions", "Speed region", "speed regions"],
  ["blurRegions", "Blur", "blurs"],
  ["highlightRegions", "Highlight", "highlights"],
  ["focusRegions", "Depth focus", "depth focus regions"],
  ["cameraLayoutRegions", "Camera layout", "camera layouts"],
  ["annotations", "Annotation", "annotations"],
  ["voiceOverClips", "Voice-over", "voice-overs"],
];

const CAPTION_NOUN = ["subtitles", "Caption", "captions"] as const;

/** Settings tab → phrase, in InspectorTab order. */
const TAB_PHRASES: ReadonlyArray<readonly [string, string]> = [
  ["background", "Background changed"],
  ["cursor", "Cursor changed"],
  ["camera", "Camera changed"],
  ["audio", "Audio changed"],
  ["effects", "Effects changed"],
  ["motion", "Motion changed"],
  ["subtitles", "Caption style changed"],
  ["brand", "Brand changed"],
  ["canvas", "Aspect ratio changed"],
  ["export", "Export settings changed"],
];
const OTHER_SETTINGS_PHRASE = "Settings changed";

const CLIP_FIELDS = ["videoClipSegments", "splitPoints"];
const TRIM_FIELDS = ["trimStart", "trimEnd"];
const RECORDING_FIELDS = [
  "sourceSegments",
  "duration",
  "videoURL",
  "cursorDataURL",
  "keystrokeDataURL",
  "cameraVideoURL",
  "cameraTimeOffset",
  "recordingSourceKind",
];
const TRAILING_FIELDS: ReadonlyArray<readonly [string, string]> = [
  ["name", "Renamed"],
  ["stillTreatment", "Image/video mode changed"],
  ["reminderDate", "Reminder changed"],
];
const OTHER_PHRASE = "Other changes";

function capitalize(s: string): string {
  return s.length ? s[0].toUpperCase() + s.slice(1) : s;
}

function collectionPhrases(c: CollectionChange, singular: string, plural: string): string[] {
  if (c.replaced) return [`${capitalize(plural)} changed`];
  const n = countsOf(c);
  const out: string[] = [];
  const counted = (k: number, verb: string) => (k === 1 ? `${singular} ${verb}` : `${k} ${plural} ${verb}`);
  if (n.added) out.push(counted(n.added, "added"));
  if (n.removed) out.push(counted(n.removed, "removed"));
  if (n.changed) out.push(counted(n.changed, "edited"));
  if (c.reordered) out.push(`${capitalize(plural)} reordered`);
  return out;
}

function hasAny(fields: ReadonlySet<string>, keys: readonly string[]): boolean {
  return keys.some((k) => fields.has(k));
}

interface Phrases {
  leading: string[];
  items: string[];
  settings: string[];
  captions: string[];
  trailing: string[];
}

function phrases(cs: ChangeSet): Phrases {
  const fields = new Set(cs.fields);
  const leading: string[] = [];
  if (hasAny(fields, CLIP_FIELDS)) leading.push("Clips edited");
  if (hasAny(fields, TRIM_FIELDS)) leading.push("Trim changed");
  if (hasAny(fields, RECORDING_FIELDS)) leading.push("Recording replaced");

  const items: string[] = [];
  const known = new Set<string>([CAPTION_NOUN[0]]);
  for (const [key, singular, plural] of TIMELINE_NOUNS) {
    known.add(key);
    if (Object.hasOwn(cs.items, key)) items.push(...collectionPhrases(cs.items[key], singular, plural));
  }

  const settings: string[] = [];
  const knownTabs = new Set<string>();
  for (const [tab, phrase] of TAB_PHRASES) {
    knownTabs.add(tab);
    if (Object.hasOwn(cs.settings, tab) && cs.settings[tab].length) settings.push(phrase);
  }
  if (Object.keys(cs.settings).some((t) => !knownTabs.has(t) && cs.settings[t].length)) {
    settings.push(OTHER_SETTINGS_PHRASE);
  }

  const captions = Object.hasOwn(cs.items, CAPTION_NOUN[0])
    ? collectionPhrases(cs.items[CAPTION_NOUN[0]], CAPTION_NOUN[1], CAPTION_NOUN[2])
    : [];

  const trailing: string[] = [];
  const claimed = new Set<string>([...CLIP_FIELDS, ...TRIM_FIELDS, ...RECORDING_FIELDS]);
  for (const [field, phrase] of TRAILING_FIELDS) {
    claimed.add(field);
    if (fields.has(field)) trailing.push(phrase);
  }
  const otherField = cs.fields.some((f) => !claimed.has(f));
  const otherItem = Object.keys(cs.items).some((k) => !known.has(k));
  if (otherField || otherItem) trailing.push(OTHER_PHRASE);
  return { leading, items, settings, captions, trailing };
}

/**
 * "Zoom added · Background changed · 3 captions edited". With `maxParts` > 0
 * and more phrases than that, the rest collapse into "+N more".
 * An empty change-set reads "No changes".
 */
export function formatChangeSummary(cs: ChangeSet, maxParts = 0): string {
  const p = phrases(cs);
  const parts = [...p.leading, ...p.items, ...p.settings, ...p.captions, ...p.trailing];
  if (parts.length === 0) return "No changes";
  if (maxParts > 0 && parts.length > maxParts) {
    return [...parts.slice(0, maxParts), `+${parts.length - maxParts} more`].join(SUMMARY_SEPARATOR);
  }
  return parts.join(SUMMARY_SEPARATOR);
}

/**
 * How many changes a change-set carries ("Merged 2 changes from Ana"):
 * each added / removed / edited element, a reorder or a replaced legacy
 * collection counts 1, each changed settings tab 1, each field phrase 1.
 */
export function countChanges(cs: ChangeSet): number {
  let n = 0;
  for (const key of Object.keys(cs.items)) {
    const c = cs.items[key];
    if (c.replaced) {
      n += 1;
      continue;
    }
    const k = countsOf(c);
    n += k.added + k.removed + k.changed + (c.reordered ? 1 : 0);
  }
  for (const tab of Object.keys(cs.settings)) if (cs.settings[tab].length) n += 1;
  const fields = new Set(cs.fields);
  if (hasAny(fields, CLIP_FIELDS)) n += 1;
  if (hasAny(fields, TRIM_FIELDS)) n += 1;
  if (hasAny(fields, RECORDING_FIELDS)) n += 1;
  const claimed = new Set<string>([...CLIP_FIELDS, ...TRIM_FIELDS, ...RECORDING_FIELDS]);
  for (const [field] of TRAILING_FIELDS) {
    claimed.add(field);
    if (fields.has(field)) n += 1;
  }
  if (cs.fields.some((f) => !claimed.has(f))) n += 1;
  return n;
}
