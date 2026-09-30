/**
 * DEV-ONLY: /editor-lab/shell — the real EditorShell driven by a tiny
 * in-memory stand-in for the store (selection, drag commits, undo, a rAF
 * playback clock, pickers/context actions) and fixture data. No auth, no
 * network. Mounted as a DEV-only code route (labRoutes.tsx). Query params:
 *   ?theme=dark|light|system   pin the theme (not persisted)
 *   ?perf=300                  300-block stress timeline (+ window.__ccLab)
 *   ?tab=cursor|…              initial inspector tab
 *   ?shot=1                    hide the lab-only theme switch (capture parity)
 *   ?view=picker|editor        the auth-guarded production pages, unguarded
 */
import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import { Segmented, ThemeRoot, useCCTheme, type ThemeMode } from "../ui/kit";
import type { Project, ProjectSettings } from "../core/model";
import { inspectorPanes, selectionFromTarget, type PaneSelection, type RegionKind } from "../ui/panes";
import { EditorShell } from "../ui/shell/EditorShell";
import {
  ASPECT_RATIOS,
  createPlayheadChannel,
  type EditorShellCallbacks,
  type InspectorTabId,
  type TransportState,
} from "../ui/shell/types";
import type { TimelineRenderer } from "../ui/timeline/TimelineRenderer";
import type { TimelineAction, TimelineIntents, TimelineSnapshot, TimelineTarget } from "../ui/timeline/types";
import { EditorPage } from "../ui/EditorPage";
import { ProjectPicker } from "../ui/picker/ProjectPicker";
import { placeholderStage } from "./placeholderStage";
import { paneStateProject } from "./paneFixture";
import { LAB_SENTINEL, perfModel, shellProbeModel, syntheticThumbnail, syntheticWaveform, type LabModel } from "./shellFixture";

declare global {
  interface Window {
    __ccLab?: {
      renderer: TimelineRenderer | null;
      playhead: ReturnType<typeof createPlayheadChannel>;
      sentinel: string;
    };
  }
}

function sameTarget(a: TimelineTarget | null, b: TimelineTarget): boolean {
  if (!a || a.lane !== b.lane) return false;
  switch (b.lane) {
    case "effects":
      return (a as typeof b).key === b.key;
    case "focus":
    case "annotate":
      return (a as { id: string }).id === b.id;
    case "video":
    case "voice":
      return (a as { clipId: string }).clipId === b.clipId;
    default:
      return true;
  }
}

function toSnapshot(m: LabModel, perf: boolean): TimelineSnapshot {
  const sel = m.selection;
  return {
    outputDuration: m.duration,
    trimStartOutput: 0,
    trimEndOutput: m.duration,
    effects: m.effects.map((e) => ({ ...e, selected: sameTarget(sel, { lane: "effects", key: e.key }) })),
    focus: m.focus.map((f) => ({ ...f, selected: sameTarget(sel, { lane: "focus", id: f.id, isHighlight: f.isHighlight }) })),
    annotate: m.annotate.map((a) => ({ ...a, selected: sameTarget(sel, { lane: "annotate", id: a.id }) })),
    intro: m.intro ? { ...m.intro, selected: sel?.lane === "intro" } : undefined,
    curtain: m.curtain ? { ...m.curtain, selected: sel?.lane === "curtain" } : undefined,
    video: {
      ...m.video,
      muted: m.muted,
      clips: m.video.clips.map((c) => ({ ...c, selected: sameTarget(sel, { lane: "video", clipId: c.id }) })),
    },
    voice: { clips: m.voice.map((v) => ({ ...v, selected: sameTarget(sel, { lane: "voice", clipId: v.id }) })) },
    sliceArmed: m.sliceArmed,
    assets: {
      version: 1,
      thumbnailAt: syntheticThumbnail,
      thumbnailAspect: 1280 / 800,
      audioSamples: perf ? syntheticWaveform(4000) : undefined,
      trimSourceStart: 0,
      trimSourceEnd: m.video.clips[0]?.sourceEnd ?? m.duration,
    },
  };
}

let idSeq = 100;
const nextId = (p: string) => `${p}-${++idSeq}`;

function LabShell({ perf, shot }: { perf: number | null; shot: boolean }) {
  // `?pane=<state>` loads one of the Mac `--pane-shots` fixture states.
  const paneParam = typeof window !== "undefined" ? new URLSearchParams(window.location.search).get("pane") : null;
  const [model, setModel] = useState<LabModel>(() => {
    const base = perf ? perfModel(perf) : shellProbeModel();
    if (!paneParam) return base;
    const st = paneStateProject(paneParam);
    return { ...base, project: st.project, paneSelection: st.selection };
  });
  const undo = useRef<LabModel[]>([]);
  const redo = useRef<LabModel[]>([]);
  const [, bump] = useState(0);
  const playhead = useMemo(() => createPlayheadChannel(0), []);
  const [playing, setPlaying] = useState(false);
  const rendererRef = useRef<TimelineRenderer | null>(null);
  const modelRef = useRef(model);
  modelRef.current = model;

  const commit = useCallback((next: (m: LabModel) => LabModel) => {
    setModel((m) => {
      undo.current.push(m);
      redo.current = [];
      return next(m);
    });
    bump((n) => n + 1);
  }, []);
  const live = useCallback((next: (m: LabModel) => LabModel) => setModel(next), []);

  // Playback clock (the engine's audio clock stands in here).
  useEffect(() => {
    if (!playing) return;
    let raf = 0;
    let last = performance.now();
    const tick = (now: number) => {
      const t = playhead.get() + (now - last) / 1000;
      last = now;
      if (t >= modelRef.current.duration) {
        playhead.set(modelRef.current.duration);
        setPlaying(false);
        return;
      }
      playhead.set(t);
      raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, [playing, playhead]);

  // Background settings drive the placeholder stage without re-mounting it.
  const bgListeners = useRef(new Set<() => void>());
  useEffect(() => {
    for (const l of bgListeners.current) l();
  }, [model.project.settings]);
  const stage = useMemo(
    () =>
      placeholderStage(
        () => modelRef.current.project.settings,
        (fn) => {
          bgListeners.current.add(fn);
          return () => bgListeners.current.delete(fn);
        },
      ),
    [],
  );

  const setTimes = (m: LabModel, target: TimelineTarget, start: number, end: number): LabModel => {
    switch (target.lane) {
      case "effects":
        return { ...m, effects: m.effects.map((e) => (e.key === target.key ? { ...e, start, end } : e)) };
      case "focus":
        return { ...m, focus: m.focus.map((f) => (f.id === target.id ? { ...f, start, end } : f)) };
      case "annotate":
        return { ...m, annotate: m.annotate.map((a) => (a.id === target.id ? { ...a, start, end } : a)) };
      case "voice":
        return { ...m, voice: m.voice.map((v) => (v.id === target.clipId ? { ...v, start, end } : v)) };
      default:
        return m;
    }
  };

  const remove = (m: LabModel, target: TimelineTarget): LabModel => {
    switch (target.lane) {
      case "effects":
        return { ...m, effects: m.effects.filter((e) => e.key !== target.key), selection: null };
      case "focus":
        return { ...m, focus: m.focus.filter((f) => f.id !== target.id), selection: null };
      case "annotate":
        return { ...m, annotate: m.annotate.filter((a) => a.id !== target.id), selection: null };
      case "voice":
        return { ...m, voice: m.voice.filter((v) => v.id !== target.clipId), selection: null };
      case "intro":
        return { ...m, intro: undefined, selection: null };
      case "curtain":
        return { ...m, curtain: undefined, selection: null };
      default:
        return m;
    }
  };

  const addEffect = (m: LabModel, at: number, zoomLevel = 2, tilt = false): LabModel => {
    const zoomId = nextId("zoom");
    const tiltId = tilt ? nextId("tilt") : undefined;
    const start = Math.min(at, Math.max(0, m.duration - 1));
    const key = `e:${zoomId}:${tiltId ?? "-"}`;
    return {
      ...m,
      effects: [...m.effects, { key, zoomId, tiltId, start, end: Math.min(m.duration, start + 1.5), zoomLevel, pitch: tilt ? 10 : 0, yaw: tilt ? -6 : 0, roll: tilt ? -2 : 0, selected: false }],
      selection: { lane: "effects", key, zoomId, tiltId },
    };
  };

  const act = (a: TimelineAction) => {
    const t = "time" in a ? a.time : playhead.get();
    commit((m) => {
      switch (a.type) {
        case "addZoomAt":
          return addEffect(m, t);
        case "addTiltAt":
          return addEffect(m, t, 1, true);
        case "addHighlightAt":
        case "addBlurAt": {
          const id = nextId("focus");
          const isHighlight = a.type === "addHighlightAt";
          return { ...m, focus: [...m.focus, { id, isHighlight, start: t, end: Math.min(m.duration, t + 1), label: isHighlight ? "Highlight" : "Blur", selected: false }], selection: { lane: "focus", id, isHighlight } };
        }
        case "addAnnotationAt": {
          const id = nextId("anno");
          const icon = { text: "text.bubble", arrow: "arrow.up.right", callout: "pencil.tip", drawing: "pencil.and.scribble", rectangle: "rectangle", ellipse: "oval", tap: "hand.tap" }[a.annotation];
          const label = { text: "Text", arrow: "Arrow", callout: "Text", drawing: "Drawing", rectangle: "Rectangle", ellipse: "Ellipse", tap: "Tap" }[a.annotation];
          return { ...m, annotate: [...m.annotate, { id, start: t, end: Math.min(m.duration, t + 1.5), label, icon, selected: false }], selection: { lane: "annotate", id } };
        }
        case "setZoomLevel":
          return { ...m, effects: m.effects.map((e) => (e.zoomId === a.zoomId ? { ...e, zoomLevel: a.level } : e)) };
        case "addTiltToBlock":
          return { ...m, effects: m.effects.map((e) => (e.zoomId === a.zoomId ? { ...e, tiltId: nextId("tilt"), pitch: 10 } : e)) };
        case "addZoomToBlock":
          return { ...m, effects: m.effects.map((e) => (e.tiltId === a.tiltId ? { ...e, zoomId: nextId("zoom"), zoomLevel: 2 } : e)) };
        case "removeZoom":
          return { ...m, effects: m.effects.flatMap((e) => (e.zoomId === a.zoomId ? (e.tiltId ? [{ ...e, zoomId: undefined }] : []) : [e])) };
        case "removeTilt":
          return { ...m, effects: m.effects.flatMap((e) => (e.tiltId === a.tiltId ? (e.zoomId ? [{ ...e, tiltId: undefined, pitch: 0, yaw: 0, roll: 0 }] : []) : [e])) };
        case "delete":
          return remove(m, a.target);
        case "toggleMute":
          return { ...m, muted: !m.muted };
        default:
          return m;
      }
    });
  };

  const intents: TimelineIntents = {
    scrub: (t) => playhead.set(t),
    seek: (t) => playhead.set(t),
    select: (target) => live((m) => ({ ...m, selection: target, paneSelection: undefined })),
    commitTimes: (target, start, end) => commit((m) => setTimes(m, target, start, end)),
    openChip: (chip) => live((m) => ({ ...m, selection: { lane: chip } })),
    moveChip: (chip, start) =>
      live((m) => {
        const c = chip === "intro" ? m.intro : m.curtain;
        if (!c) return m;
        const moved = { ...c, start, end: start + (c.end - c.start) };
        return chip === "intro" ? { ...m, intro: moved } : { ...m, curtain: moved };
      }),
    resizeChip: (chip, end) =>
      live((m) => {
        const c = chip === "intro" ? m.intro : m.curtain;
        if (!c) return m;
        const resized = { ...c, end: Math.max(c.start + 0.3, end) };
        return chip === "intro" ? { ...m, intro: resized } : { ...m, curtain: resized };
      }),
    trimVideo: (edge, t) =>
      commit((m) => ({
        ...m,
        video: edge === "start" ? { ...m.video, regionStart: t } : { ...m.video, regionEnd: t },
      })),
    sliceAt: (t) =>
      commit((m) => {
        const clip = m.video.clips.find((c) => t > c.outputStart && t < c.outputEnd);
        if (!clip) return { ...m, sliceArmed: false };
        const f = (t - clip.outputStart) / (clip.outputEnd - clip.outputStart);
        const cut = clip.sourceStart + f * (clip.sourceEnd - clip.sourceStart);
        const a = { ...clip, id: nextId("clip"), outputEnd: t, sourceEnd: cut };
        const b = { ...clip, id: nextId("clip"), outputStart: t, sourceStart: cut };
        return {
          ...m,
          sliceArmed: false,
          video: {
            ...m.video,
            usesWholeTrackDrag: false,
            clips: m.video.clips.flatMap((c) => (c.id === clip.id ? [a, b] : [c])),
            segments: m.video.segments.flatMap((s) => {
              if (s.clipId !== clip.id) return [s];
              const first = s.outputStart < t ? [{ ...s, id: nextId("seg"), clipId: a.id, outputEnd: Math.min(s.outputEnd, t) }] : [];
              const second = s.outputEnd > t ? [{ ...s, id: nextId("seg"), clipId: b.id, outputStart: Math.max(s.outputStart, t), startsAtSplit: s.outputStart <= t }] : [];
              return [...first, ...second];
            }),
          },
        };
      }),
    action: act,
  };

  const [tab, setTab] = useState<InspectorTabId>(() => {
    const q = typeof window !== "undefined" ? new URLSearchParams(window.location.search).get("tab") : null;
    return (q as InspectorTabId) ?? (paneParam ? paneStateProject(paneParam).tab : null) ?? "background";
  });

  const selected = model.selection;
  const callbacks: EditorShellCallbacks = {
    onShowProjects: () => window.location.assign("/editor-lab/shell"),
    onExport: () => console.info("[lab] export"),
    onShare: () => console.info("[lab] share"),
    onRename: (name) => live((m) => ({ ...m, name })),
    onAspectChange: (aspect) => commit((m) => ({ ...m, aspect })),
    onGoToStart: () => playhead.set(0),
    onGoToEnd: () => playhead.set(Math.max(0, model.duration - 0.01)),
    onTogglePlay: () => {
      if (!playing && playhead.get() >= model.duration - 0.01) playhead.set(0);
      setPlaying((p) => !p);
    },
    onUndo: () => {
      const prev = undo.current.pop();
      if (!prev) return;
      redo.current.push(modelRef.current);
      setModel(prev);
    },
    onRedo: () => {
      const next = redo.current.pop();
      if (!next) return;
      undo.current.push(modelRef.current);
      setModel(next);
    },
    onDelete: () => selected && act({ type: "delete", target: selected }),
    onEffectsPick: (pick) => {
      if (pick === "slide") {
        commit((m) => ({ ...m, intro: m.intro ?? { start: 0, end: 0.8, label: "Intro · Bottom", icon: "arrow.up.to.line", selected: false }, selection: { lane: "intro" } }));
      } else if (pick === "curtain") {
        commit((m) => ({ ...m, curtain: m.curtain ?? { start: Math.min(1, m.duration / 3), end: Math.min(m.duration, 2), label: "Curtain", icon: "book.pages", selected: false }, selection: { lane: "curtain" } }));
      } else if (pick === "tilt") act({ type: "addTiltAt", time: playhead.get() });
      else if (pick === "scaleDown") commit((m) => addEffect(m, playhead.get(), 0.85));
      else if (pick === "showcase") commit((m) => addEffect(m, playhead.get(), 1.35, true));
      else act({ type: "addZoomAt", time: playhead.get() });
    },
    onFocusPick: (pick) => act({ type: pick === "highlight" ? "addHighlightAt" : "addBlurAt", time: playhead.get() }),
    onAnnotationPick: (annotation) => act({ type: "addAnnotationAt", time: playhead.get(), annotation }),
    onToggleSlice: () => live((m) => ({ ...m, sliceArmed: !m.sliceArmed })),
    onSplitAtPlayhead: () => intents.sliceAt?.(playhead.get()),
    onToggleVoiceOver: () => console.info("[lab] voice over"),
    onStep: (d) => {
      setPlaying(false);
      playhead.set(Math.min(Math.max(0, playhead.get() + d), model.duration));
    },
    onEscape: () => live((m) => ({ ...m, selection: m.selection?.lane === "video" ? null : m.selection })),
    onInspectorTabChange: setTab,
  };

  const transport: TransportState = {
    isPlaying: playing,
    canUndo: undo.current.length > 0,
    canRedo: redo.current.length > 0,
    canDelete: !!selected && selected.lane !== "video",
    sliceArmed: model.sliceArmed,
    isRecordingVoiceOver: false,
    duration: model.duration,
  };

  const snapshot = useMemo(() => toSnapshot(model, !!perf), [model, perf]);
  const aspect = ASPECT_RATIOS.find((a) => a.id === model.aspect)?.ratio ?? 16 / 9;

  useEffect(() => {
    window.__ccLab = { renderer: rendererRef.current, playhead, sentinel: LAB_SENTINEL };
  });

  // The panes edit the lab's core project (settings + regions) in place of
  // the store; timeline actions they raise go through the lab's `act`.
  const setSettings = useCallback(
    (patch: Partial<ProjectSettings>) => live((m) => ({ ...m, project: { ...m.project, settings: { ...m.project.settings, ...patch } } })),
    [live],
  );
  const setRegion = useCallback(
    (kind: RegionKind, id: string, patch: object) =>
      live((m) => {
        const key = ({
          zoom: "zoomRegions",
          tilt: "tiltRegions",
          highlight: "highlightRegions",
          blur: "blurRegions",
          focus: "focusRegions",
          annotation: "annotations",
          subtitle: "subtitles",
          cameraLayout: "cameraLayoutRegions",
        } as const)[kind];
        const list = m.project[key] as { id: string }[];
        return { ...m, project: { ...m.project, [key]: list.map((r) => (r.id === id ? { ...r, ...patch } : r)) } as Project };
      }),
    [live],
  );
  const paneSelection: PaneSelection = model.paneSelection ?? selectionFromTarget(model.selection, model.project);

  return (
    <EditorShell
      project={{
        name: model.name,
        aspectRatio: model.aspect,
        canvasAspect: aspect,
        hasCursorData: true,
        hasRecordedCamera: false,
        syncState: "saved",
      }}
      transport={transport}
      playhead={playhead}
      callbacks={callbacks}
      timeline={snapshot}
      timelineIntents={intents}
      stage={stage}
      inspectorTab={tab}
      timelineRendererRef={rendererRef}
      topBarAccessory={shot ? undefined : <ThemeSwitch />}
      panes={inspectorPanes({
        settings: model.project.settings,
        onSettingsChange: setSettings,
        selection: paneSelection,
        project: model.project,
        onRegionChange: setRegion,
        onProjectChange: (patch) => live((m) => ({ ...m, project: { ...m.project, ...patch } })),
        actions: {
          onAction: act,
          playheadTime: () => playhead.get(),
          onAddZoomBlockAtPlayhead: () => act({ type: "addZoomAt", time: playhead.get() }),
          onAddTiltBlockAtPlayhead: () => act({ type: "addTiltAt", time: playhead.get() }),
        },
      })}
    />
  );
}

function ThemeSwitch() {
  const { mode, setMode } = useCCTheme();
  const modes: ThemeMode[] = ["dark", "light", "system"];
  return (
    <Segmented
      segments={["Dark", "Light", "Auto"]}
      selectedIndex={modes.indexOf(mode)}
      onChange={(i) => setMode(modes[i])}
      size="sm"
      chrome="plain"
      ariaLabel="Theme"
    />
  );
}

export default function ShellLab() {
  const params = typeof window !== "undefined" ? new URLSearchParams(window.location.search) : null;
  const theme = (params?.get("theme") as ThemeMode | null) ?? null;
  const perf = params?.get("perf") ? Number(params.get("perf")) : null;
  const view = params?.get("view");
  const [ready, setReady] = useState(false);
  useEffect(() => setReady(true), []);
  if (!ready) return null; // client-only lab: fixtures read the URL
  // The auth-guarded production surfaces, rendered unguarded for design checks.
  if (view === "picker") return <ProjectPicker userName="Lab" />;
  if (view === "editor") return <EditorPage projectId="demo-onboarding" />;
  return (
    <ThemeRoot initialMode={theme ?? "system"} persist={!theme}>
      <LabShell perf={perf} shot={params?.get("shot") === "1"} />
    </ThemeRoot>
  );
}
