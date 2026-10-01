/**
 * The project-merge policy table (docs/project-history.md §Policy).
 *
 * A LITERAL in both languages — this file and
 * apps/macos/CaptureCat/Services/ProjectHistory/MergePolicy.swift. Its
 * canonical-JSON FNV-1a hash is written into the golden file by the Swift
 * harness, and the TS suite fails when its own hash differs, so the two
 * tables can never drift silently.
 *
 * Facts it encodes (verified against the Swift models, 2026-09-30):
 *   - every id collection below has a REQUIRED UUID `id` except
 *     cameraLayoutRegions, whose decoder invents `UUID()` for a missing id
 *     (so id-less legacy arrays exist in the wild and merge as one value);
 *   - splitPoints, sourceSegments and drawingStrokes have no ids → atomic;
 *   - `splitVideoClip` replaces the split clip with TWO fresh-id clips, so
 *     clip structure merges as one prompt group, never by id;
 *   - VoiceOverClip has no endTime: its timing is {startTime,
 *     sourceStartTime, duration} (what VoiceTrackEditMath edits together);
 *   - exclusive lanes come from the Mac timeline's edit guards:
 *       effects = zoom + tilt (TimelineCanvasView.effectLaneSpans; a zoom and
 *         a tilt co-spanning within EffectBlockItem.linkEpsilon are ONE
 *         linked block, paired like canvasEffectItems),
 *       focus = blur + depth focus + camera layout + highlight
 *         (focusLaneSpans / TimelineFocusItem),
 *       speed = speed regions (addSpeedRegion / duplicate guards);
 *     annotations ("Overlaps are allowed on this lane"), voice-overs
 *     (VoiceTrackEditMath has no neighbour clamp) and subtitles are NOT
 *     exclusive.
 */
import { canonicalJSON, fnv1a64Hex, type Json } from "./jsonMerge";

export interface AtomicGroupPolicy {
  readonly name: string;
  readonly keys: readonly string[];
  readonly prompt: boolean;
}

export interface CollectionPolicy {
  /** project.json key (or, nested, the element key). */
  readonly key: string;
  /** Per-element atomic groups. */
  readonly groups: readonly (readonly string[])[];
  /** Regenerated (< regenerationSurvival of base ids survive) vs edited → conflict. */
  readonly regenerationCheck: boolean;
  /** Id collections inside each element (subtitle words). */
  readonly nested: readonly CollectionPolicy[];
}

export interface LaneLinkPolicy {
  readonly primary: string;
  readonly secondary: string;
  readonly epsilon: number;
}

export interface LanePolicy {
  readonly name: string;
  readonly collections: readonly string[];
  readonly link: LaneLinkPolicy | null;
}

export interface SettingsTabPolicy {
  readonly tab: string;
  readonly keys: readonly string[];
}

export interface MergePolicy {
  readonly version: number;
  readonly rootGroups: readonly AtomicGroupPolicy[];
  readonly settingsKey: string;
  readonly settingsGroups: readonly AtomicGroupPolicy[];
  readonly collections: readonly CollectionPolicy[];
  readonly lanes: readonly LanePolicy[];
  readonly overlapEpsilon: number;
  readonly regenerationSurvival: number;
  readonly settingsTabs: readonly SettingsTabPolicy[];
}

const TIMING = ["startTime", "endTime"] as const;
const RECT = ["rectX", "rectY", "rectW", "rectH"] as const;

function collection(
  key: string,
  groups: readonly (readonly string[])[],
  extra: { regenerationCheck?: boolean; nested?: readonly CollectionPolicy[] } = {},
): CollectionPolicy {
  return { key, groups, regenerationCheck: extra.regenerationCheck ?? false, nested: extra.nested ?? [] };
}

export const MERGE_POLICY: MergePolicy = {
  version: 1,
  rootGroups: [
    { name: "clipStructure", keys: ["videoClipSegments", "splitPoints", "trimStart", "trimEnd"], prompt: true },
    {
      name: "recording",
      keys: [
        "sourceSegments",
        "duration",
        "videoURL",
        "cursorDataURL",
        "keystrokeDataURL",
        "cameraVideoURL",
        "cameraTimeOffset",
        "recordingSourceKind",
      ],
      prompt: false,
    },
  ],
  settingsKey: "settings",
  settingsGroups: [
    { name: "videoPlacement", keys: ["videoPlacement", "videoCustomX", "videoCustomY"], prompt: false },
    { name: "cameraPosition", keys: ["cameraPosition", "cameraCustomX", "cameraCustomY"], prompt: false },
    { name: "subtitlePosition", keys: ["subtitlePosition", "subtitleCustomX", "subtitleCustomY"], prompt: false },
    { name: "watermarkPosition", keys: ["watermarkX", "watermarkY"], prompt: false },
    { name: "backgroundImage", keys: ["backgroundType", "backgroundImagePath"], prompt: false },
    { name: "screenTilt", keys: ["screenTiltMode", "screenTiltAngle", "screenTiltYaw", "screenTiltRoll"], prompt: false },
    { name: "intro", keys: ["introSlideStyle", "introSlideStart", "introSlideDuration"], prompt: false },
    { name: "curtain", keys: ["curtainUnveilCorner", "curtainUnveilStart", "curtainUnveilDuration"], prompt: false },
    { name: "exportSettings", keys: ["exportSettings"], prompt: false },
  ],
  collections: [
    collection("zoomRegions", [TIMING, ["focalPoint"], ["cardOffsetX", "cardOffsetY"]]),
    collection("tiltRegions", [TIMING]),
    collection("blurRegions", [TIMING, RECT]),
    collection("highlightRegions", [TIMING, RECT]),
    collection("focusRegions", [TIMING, RECT]),
    collection("cameraLayoutRegions", [TIMING]),
    collection("annotations", [TIMING, ["x", "y", "arrowEndX", "arrowEndY"], ["drawingStrokes"]]),
    collection("voiceOverClips", [["startTime", "sourceStartTime", "duration"]]),
    collection("speedRegions", [TIMING]),
    collection("subtitles", [TIMING], { regenerationCheck: true, nested: [collection("words", [TIMING])] }),
  ],
  lanes: [
    {
      name: "effects",
      collections: ["zoomRegions", "tiltRegions"],
      link: { primary: "zoomRegions", secondary: "tiltRegions", epsilon: 0.02 },
    },
    {
      name: "focus",
      collections: ["blurRegions", "focusRegions", "cameraLayoutRegions", "highlightRegions"],
      link: null,
    },
    { name: "speed", collections: ["speedRegions"], link: null },
  ],
  overlapEpsilon: 0.0001,
  regenerationSurvival: 0.5,
  // Settings key → inspector tab, from the Mac panes that edit each key
  // (Views/Editor/InspectorKit/*PaneAppKit.swift; web ui/panes mirror them).
  // "canvas" = the aspect-ratio menu, "export" = the export sheet.
  settingsTabs: [
    {
      tab: "background",
      keys: [
        "backgroundType",
        "gradientStartColor",
        "gradientEndColor",
        "solidColor",
        "backgroundImagePath",
        "backgroundPadding",
        "videoPlacement",
        "videoCustomX",
        "videoCustomY",
        "cornerRadius",
        "windowCornerRadius",
        "frameShape",
        "shadowRadius",
        "shadowOpacity",
        "gradientAngle",
        "backgroundBlur",
        "backgroundBrightness",
        "backgroundSaturation",
        "backgroundTintColor",
        "backgroundTintOpacity",
        "backgroundVignette",
        "backgroundPixelate",
        "backgroundHalftone",
        "backgroundNoise",
        "backgroundContrast",
        "backgroundHue",
        "showDeviceFrame",
        "menuBarReplacement",
        "menuBarTitle",
        "menuBarTitleAlignment",
        "menuBarShowStatusIcons",
        "menuBarClock",
        "menuBarHeight",
      ],
    },
    {
      tab: "cursor",
      keys: [
        "showCursor",
        "cursorStyle",
        "cursorScale",
        "autoHideCursor",
        "autoHideDelay",
        "smoothCursor",
        "smoothingFactor",
        "cursorTilt",
        "cursorStretch",
        "cursorDrag",
        "cursorWeight",
        "cursorFluidEnabled",
        "cursorTension",
        "cursorFriction",
        "cursorMass",
        "showClickRipple",
        "cursorLoopToStart",
        "cursorStopAtEnd",
        "clickSoundEnabled",
        "clickSoundVolume",
        "clickSoundStyle",
        "keySoundEnabled",
        "keySoundVolume",
        "keySoundStyle",
        "showKeystrokes",
        "keystrokeOverlaySize",
        "keystrokeOverlayPosition",
        "keystrokeOverlayAnimation",
        "keystrokeOverlayScopeToRecordedApp",
        "clickRippleColor",
        "clickRippleSize",
      ],
    },
    {
      tab: "camera",
      keys: [
        "showCamera",
        "cameraPosition",
        "cameraCustomX",
        "cameraCustomY",
        "cameraSize",
        "cameraShape",
        "cameraOrientation",
        "cameraMirrored",
        "cameraBrightness",
        "cameraContrast",
        "cameraSaturation",
        "cameraHue",
        "cameraFilter",
        "cameraRingLight",
        "cameraCornerRadius",
        "cameraBorderWidth",
        "cameraBorderColor",
        "cameraOpacity",
        "cameraTiltPitch",
        "cameraTiltYaw",
        "cameraTagText",
        "cameraTagSubtext",
        "cameraTagFontName",
        "cameraTagTextColor",
        "cameraTagBackgroundColor",
        "cameraTagPosition",
      ],
    },
    { tab: "audio", keys: ["systemAudioVolume", "microphoneVolume", "voiceOverVolume", "muteRecordedAudio"] },
    {
      tab: "effects",
      keys: [
        "motionBlur",
        "motionBlurStrength",
        "parallaxStrength",
        "introSlideStyle",
        "introSlideDuration",
        "introSlideStart",
        "introSlideBounce",
        "introSlideSpeed",
        "introSlideDepth",
        "curtainUnveilCorner",
        "curtainUnveilDuration",
        "curtainUnveilStart",
        "curtainLogoFileName",
        "curtainLogoOpacity",
        "curtainLogoScale",
        "curtainLogoTint",
        "curtainColor",
        "screenTiltMode",
        "screenTiltAngle",
        "screenTiltYaw",
        "screenTiltRoll",
      ],
    },
    { tab: "motion", keys: ["animationSpeed", "autoZoomLevel", "cameraFollowSpeed"] },
    {
      tab: "subtitles",
      keys: [
        "showSubtitles",
        "subtitleFontSize",
        "subtitlePosition",
        "subtitleStyle",
        "subtitleCustomX",
        "subtitleCustomY",
        "subtitleWeight",
        "subtitleUppercase",
        "subtitleFontName",
        "subtitleColor",
        "subtitleBackgroundColor",
        "highlightWords",
        "subtitleHighlightColor",
      ],
    },
    {
      tab: "brand",
      keys: ["showWatermark", "watermarkFileName", "watermarkX", "watermarkY", "watermarkSize", "watermarkOpacity"],
    },
    { tab: "canvas", keys: ["aspectRatio"] },
    { tab: "export", keys: ["exportSettings"] },
  ],
};

/** The tab a settings key belongs to ("other" when unknown). */
export function settingsTabFor(key: string, policy: MergePolicy = MERGE_POLICY): string {
  for (const t of policy.settingsTabs) if (t.keys.includes(key)) return t.tab;
  return "other";
}

export function collectionPolicy(key: string, policy: MergePolicy = MERGE_POLICY): CollectionPolicy | undefined {
  return policy.collections.find((c) => c.key === key);
}

function groupJSON(g: AtomicGroupPolicy): Json {
  return { name: g.name, keys: [...g.keys], prompt: g.prompt };
}

function collectionJSON(c: CollectionPolicy): Json {
  return {
    key: c.key,
    groups: c.groups.map((g) => [...g]),
    regenerationCheck: c.regenerationCheck,
    nested: c.nested.map(collectionJSON),
  };
}

/** The policy as plain JSON (the hashed form; same shape in Swift). */
export function policyJSON(policy: MergePolicy = MERGE_POLICY): Json {
  return {
    version: policy.version,
    rootGroups: policy.rootGroups.map(groupJSON),
    settingsKey: policy.settingsKey,
    settingsGroups: policy.settingsGroups.map(groupJSON),
    collections: policy.collections.map(collectionJSON),
    lanes: policy.lanes.map((l) => ({
      name: l.name,
      collections: [...l.collections],
      link: l.link ? { primary: l.link.primary, secondary: l.link.secondary, epsilon: l.link.epsilon } : null,
    })),
    overlapEpsilon: policy.overlapEpsilon,
    regenerationSurvival: policy.regenerationSurvival,
    settingsTabs: policy.settingsTabs.map((t) => ({ tab: t.tab, keys: [...t.keys] })),
  };
}

/** FNV-1a 64 of the policy's canonical JSON — recorded in the golden file. */
export function policyHash(policy: MergePolicy = MERGE_POLICY): string {
  return fnv1a64Hex(canonicalJSON(policyJSON(policy)));
}
