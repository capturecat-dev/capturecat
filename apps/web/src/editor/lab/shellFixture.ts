/**
 * DEV-ONLY fixture for the editor-shell lab (/editor-lab/shell). Never
 * imported by production code: the only importer is the lab route, behind
 * `import.meta.env.DEV`.
 *
 * `shellProbeModel()` mirrors the Mac `--editor-shell-shot` probe project
 * (EditorShellProbeHarness.makeProject): 4 s recording, zoom 0.5–1.5 s,
 * speed region 2.0–3.0 s at 2×, a text annotation "Probe label" 1.0–2.5 s,
 * gradient background — so the web shell can be compared 1:1 against
 * shell-native.png. `perfModel(n)` builds an n-block stress timeline.
 *
 * Times are OUTPUT seconds (the lab has no store / SpeedTimeMap port yet; the
 * probe's single 2× region is folded in by hand).
 */
import type { Project } from "../core/model";
import type { PaneSelection } from "../ui/panes/types";
import { paneProbeProject } from "./paneFixture";
import type {
  AnnotateBlock,
  EffectBlock,
  FocusBlock,
  SettingsChip,
  TimelineTarget,
  VideoRow,
  VoiceClip,
} from "../ui/timeline/types";

export const LAB_SENTINEL = "cc-editor-lab-fixture-v1";

export interface LabModel {
  name: string;
  aspect: string;
  duration: number;
  effects: EffectBlock[];
  focus: FocusBlock[];
  annotate: AnnotateBlock[];
  voice: VoiceClip[];
  video: VideoRow;
  intro?: SettingsChip;
  curtain?: SettingsChip;
  selection: TimelineTarget | null;
  /** Core project the inspector panes edit (paneFixture.ts). */
  project: Project;
  /** A `?pane=` fixture selection; cleared by the first timeline pick. */
  paneSelection?: PaneSelection | null;
  sliceArmed: boolean;
  muted: boolean;
}

export function shellProbeModel(): LabModel {
  return {
    name: "Shell Probe",
    aspect: "16:9",
    duration: 3.5,
    effects: [{ key: "e:zoom-1:-", zoomId: "zoom-1", start: 0.5, end: 1.5, zoomLevel: 2, pitch: 0, yaw: 0, roll: 0, selected: false }],
    focus: [],
    annotate: [{ id: "anno-1", start: 1.0, end: 2.25, label: "Probe label", icon: "text.bubble", selected: false }],
    voice: [],
    video: {
      regionStart: 0,
      regionEnd: 3.5,
      usesWholeTrackDrag: true,
      clips: [{ id: "clip-1", outputStart: 0, outputEnd: 3.5, sourceStart: 0, sourceEnd: 4, selected: false }],
      segments: [
        { id: "s1", clipId: "clip-1", outputStart: 0, outputEnd: 2, sourceStart: 0, sourceEnd: 2, speed: 1, label: "2s · 1x", showsLeadingDivider: false, startsAtSplit: false },
        { id: "s2", clipId: "clip-1", outputStart: 2, outputEnd: 2.5, sourceStart: 2, sourceEnd: 3, speed: 2, regionId: "speed-1", label: "1s · 2x", showsLeadingDivider: true, startsAtSplit: false },
        { id: "s3", clipId: "clip-1", outputStart: 2.5, outputEnd: 3.5, sourceStart: 3, sourceEnd: 4, speed: 1, label: "1s · 1x", showsLeadingDivider: true, startsAtSplit: false },
      ],
      muted: true,
      hasAudio: false,
    },
    selection: null,
    project: paneProbeProject(),
    sliceArmed: false,
    muted: true,
  };
}

/** Deterministic PRNG so perf runs are comparable. */
function rng(seed: number) {
  let s = seed >>> 0;
  return () => {
    s = (s * 1664525 + 1013904223) >>> 0;
    return s / 4294967296;
  };
}

/** n blocks spread over EFFECTS (3 stacked rows), FOCUS and ANNOTATE. */
export function perfModel(n: number): LabModel {
  const rand = rng(7);
  const duration = Math.max(120, n * 1.2);
  const effects: EffectBlock[] = [];
  const focus: FocusBlock[] = [];
  const annotate: AnnotateBlock[] = [];
  const per = Math.ceil(n / 3);
  for (let i = 0; i < per; i++) {
    const start = (i / per) * (duration - 4) + rand() * 0.5;
    const len = 1 + rand() * 3;
    const zoomId = `z${i}`;
    const tilt = i % 4 === 0;
    effects.push({
      key: `e:${zoomId}:${tilt ? `t${i}` : "-"}`,
      zoomId,
      tiltId: tilt ? `t${i}` : undefined,
      start,
      end: Math.min(duration, start + len),
      zoomLevel: 1.5 + (i % 5) * 0.5,
      pitch: tilt ? 10 : 0,
      yaw: tilt ? -6 : 0,
      roll: 0,
      selected: false,
    });
  }
  for (let i = 0; i < per; i++) {
    const start = (i / per) * (duration - 3) + rand();
    focus.push({ id: `f${i}`, isHighlight: i % 2 === 0, start, end: Math.min(duration, start + 0.8 + rand() * 1.2), label: i % 2 ? "Blur" : "Highlight", selected: false });
  }
  const icons = ["text.bubble", "arrow.up.right", "pencil.tip", "rectangle", "oval", "hand.tap"];
  const labels = ["Label", "Arrow", "Callout", "Rectangle", "Ellipse", "Tap"];
  for (let i = 0; i < n - per * 2; i++) {
    const start = (i / (n - per * 2)) * (duration - 4) + rand() * 2;
    annotate.push({ id: `a${i}`, start, end: Math.min(duration, start + 1 + rand() * 4), label: labels[i % 6], icon: icons[i % 6], selected: false });
  }
  const base = shellProbeModel();
  return {
    ...base,
    name: `Perf ${n} blocks`,
    duration,
    effects,
    focus,
    annotate,
    voice: Array.from({ length: 12 }, (_, i) => ({
      id: `v${i}`,
      start: (i / 12) * duration,
      end: (i / 12) * duration + 5,
      label: "Voice Over",
      selected: false,
      waveform: Array.from({ length: 40 }, () => rand()),
    })),
    video: {
      regionStart: 0,
      regionEnd: duration,
      usesWholeTrackDrag: true,
      clips: [{ id: "clip-1", outputStart: 0, outputEnd: duration, sourceStart: 0, sourceEnd: duration, selected: false }],
      segments: [{ id: "s1", clipId: "clip-1", outputStart: 0, outputEnd: duration, sourceStart: 0, sourceEnd: duration, speed: 1, label: "", showsLeadingDivider: false, startsAtSplit: false }],
      muted: false,
      hasAudio: true,
    },
  };
}

// ── Synthetic filmstrip (the probe's synthetic grey frames) ─────────────

/** The grey levels the Mac probe's filmstrip shows, by source time
 *  (read off shell-native.png): <0.35 s 79, <1.4 115, <2.44 104, <3.5 88, else 124. */
function probeGrey(t: number): number {
  const s = t < 4.5 ? t : t % 4;
  if (s < 0.35) return 79;
  if (s < 1.4) return 115;
  if (s < 2.44) return 104;
  if (s < 3.5) return 88;
  return 124;
}
const tileCache = new Map<number, HTMLCanvasElement>();

/** Grey 1280×800-aspect frames like the probe's synthesized recording. */
export function syntheticThumbnail(sourceSeconds: number): HTMLCanvasElement {
  const grey = probeGrey(Math.max(0, sourceSeconds));
  let c = tileCache.get(grey);
  if (!c) {
    c = document.createElement("canvas");
    c.width = 16;
    c.height = 10;
    const ctx = c.getContext("2d")!;
    ctx.fillStyle = `rgb(${grey},${grey},${grey})`;
    ctx.fillRect(0, 0, 16, 10);
    tileCache.set(grey, c);
  }
  return c;
}

export function syntheticWaveform(count: number): number[] {
  const rand = rng(3);
  return Array.from({ length: count }, (_, i) => 0.25 + 0.6 * Math.abs(Math.sin(i / 7)) * rand());
}
