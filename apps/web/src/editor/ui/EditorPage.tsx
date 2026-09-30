/**
 * The /editor/$projectId page: loads a project (cloud, or — on the dev
 * server — this Mac's local folder; ids are the Mac's project UUIDs) into
 * the editor STORE (state/store.ts: lossless core model, undo/redo,
 * selection, cloud autosave), mounts the WebGPU engine into the stage, and
 * wires the shell through the EditorController (state/controller.ts), which
 * routes every timeline gesture, toolbar pick and shortcut into the Mac's own
 * edit logic (state/edits.ts). The timeline is a pure selector over the
 * store (state/timeline.ts, SpeedTimeMap-retimed like the Mac).
 *
 * Cloud projects autosave with optimistic revisions; local dev projects are
 * read-only (edits live in the tab).
 */
import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { useNavigate } from "@tanstack/react-router";

import { parseProjectText, serializeProjectText, type ProjectSettings } from "../core/model";
import { presentsTimelessTimeline } from "../core/model/helpers";
import { EngineClient } from "../engine/client";
import { ExportDialog } from "./export/ExportDialog";
import type { LoadedInfo, TransportState as EngineTransport } from "../engine/protocol";
import { refsOf } from "../engine/media/assets";
import { saveCloudProject } from "../state/cloud";
import { EditorController } from "../state/controller";
import * as E from "../state/edits";
import { loadInteractionInputs } from "../state/interactionInputs";
import { loadEditorProject, type LoadedEditorProject } from "../state/projectSource";
import { EditorStore, useEditorStore, type EditorState, type Persistence } from "../state/store";
import { timelineSnapshot } from "../state/timeline";
import { buildEditorToolHandlers, registerEditorWebMCP } from "../state/webmcpHandlers";
import { UploadGate } from "../state/voiceOver";
import { REPLACE_ZOOM_BLOCKS, editorPaneActions, useInspectorRevealKey, usePendingSeek, useRecordingFacts } from "./editorPageWiring";
import { AlertHost, AlertPresenter, Button, SFIcon, ThemeRoot } from "./kit";
import { useInspectorPanes } from "./panes";
import { EditorShell } from "./shell/EditorShell";
import type { StageMount, StageViewport, TransportState } from "./shell/types";
import { UnsupportedNotice } from "./shell/UnsupportedNotice";
import { unsupportedFeatures } from "../engine/contract";
import { mountStageInteraction, type StageInteraction } from "./stage/StageInteraction";
import { engineViewport, stageCanvasAspect } from "./stage/stageLayout";
import type { TimelineRenderer } from "./timeline/TimelineRenderer";
import type { TimelineSnapshot } from "./timeline/types";
import { useTimelineMedia } from "./timeline/media/useTimelineMedia";
import { useVoiceOver } from "./voiceover/VoiceOver";

/** The editor requires WebGPU (architecture §Stack) — say so plainly. */
export function WebGPUGate({ children }: { children: ReactNode }) {
  const [supported, setSupported] = useState<boolean | null>(null);
  useEffect(() => setSupported(typeof navigator !== "undefined" && "gpu" in navigator), []);
  if (supported === false) {
    return (
      <div className="cc-gate">
        <div className="cc-gate__card">
          <SFIcon name="display" size={22} weight="regular" />
          <div className="cc-gate__title">This browser can’t run the editor</div>
          <div className="cc-gate__body">
            The CaptureCat editor renders with WebGPU. Use Chrome or Edge 113+, Safari 26+, or Firefox 141+.
          </div>
        </div>
      </div>
    );
  }
  return <>{children}</>;
}

// ── Background pane ⇄ core ProjectSettings ─────────────────────────────

const EMPTY_TIMELINE: TimelineSnapshot = { outputDuration: 0, trimStartOutput: 0, trimEndOutput: 0, effects: [], focus: [], annotate: [] };

function extrapolate(t: EngineTransport): number {
  if (!t.playing) return t.time;
  const wall = performance.timeOrigin + performance.now();
  return Math.min(t.duration, t.time + ((wall - t.wallMs) / 1000) * t.rate);
}

const selectState = (s: EditorState) => s;

// ── Page ────────────────────────────────────────────────────────────────

export function EditorPage({ projectId, pendingSeek }: { projectId: string; /** `?t=` output seconds (deep link). */ pendingSeek?: number | null }) {
  // One initializer for the pair: StrictMode double-invokes initializers, and
  // the controller registers itself as the store's playhead provider.
  const [{ store, controller, alerts }] = useState(() => {
    const s = new EditorStore();
    return { store: s, controller: new EditorController(s), alerts: new AlertPresenter() };
  });
  const state = useEditorStore(store, selectState);
  const [loaded, setLoaded] = useState<LoadedEditorProject | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [engineError, setEngineError] = useState<string | null>(null);
  const [info, setInfo] = useState<LoadedInfo | null>(null);
  const [playing, setPlaying] = useState(false);
  const [exportOpen, setExportOpen] = useState(false);
  const playhead = controller.playhead;
  const transportRef = useRef<EngineTransport | null>(null);
  const stageRef = useRef<StageInteraction | null>(null);
  const timelineRendererRef = useRef<TimelineRenderer | null>(null);
  // Media uploads in flight (a recorded voice-over): saves wait for them.
  const [uploads] = useState(() => new UploadGate());

  // Export button / ⌘E → the export sheet.
  useEffect(() => {
    controller.hooks.exportVideo = () => setExportOpen(true);
    return () => {
      controller.hooks.exportVideo = undefined;
    };
  }, [controller]);

  // DEV-only handle for the lab/perf harnesses (never in production builds).
  useEffect(() => {
    if (!import.meta.env.DEV) return;
    (window as unknown as { __editor?: unknown }).__editor = { store, controller };
    return () => {
      delete (window as unknown as { __editor?: unknown }).__editor;
    };
  }, [store, controller]);

  // Load the project (cloud first; dev server falls back to this Mac).
  useEffect(() => {
    let alive = true;
    setLoaded(null);
    setLoadError(null);
    loadEditorProject(projectId).then(
      (project) => {
        if (!alive) return;
        const persistence: Persistence | null =
          project.origin === "cloud"
            ? {
                save: async (document, baseRevision) => {
                  await uploads.idle();
                  const r = await saveCloudProject(project.id, document, baseRevision);
                  return r.ok
                    ? { ok: true, revision: r.revision }
                    : { ok: false, conflict: true, revision: r.revision, document: r.document, updatedAt: r.updatedAt };
                },
              }
            : null;
        store.load({ text: project.text, origin: project.origin, revision: project.revision, persistence });
        setLoaded(project);
      },
      (error: unknown) => alive && setLoadError(error instanceof Error ? error.message : String(error)),
    );
    return () => {
      alive = false;
    };
  }, [projectId, store, uploads]);

  // Unsaved cloud edits: flush on hide, guard unload, retry when back online.
  useEffect(() => {
    const beforeUnload = (e: BeforeUnloadEvent) => {
      if (!store.hasUnsavedChanges()) return;
      void store.flush();
      e.preventDefault();
    };
    const hidden = () => {
      if (document.visibilityState === "hidden") void store.flush();
    };
    const online = () => store.retrySave();
    window.addEventListener("beforeunload", beforeUnload);
    document.addEventListener("visibilitychange", hidden);
    window.addEventListener("online", online);
    return () => {
      window.removeEventListener("beforeunload", beforeUnload);
      document.removeEventListener("visibilitychange", hidden);
      window.removeEventListener("online", online);
    };
  }, [store]);

  // Per-frame playhead while playing: extrapolate the engine's transport
  // (it posts only discontinuities) — React never re-renders per frame.
  useEffect(() => {
    if (!playing) return;
    let frame = 0;
    const tick = () => {
      const t = transportRef.current;
      if (t) playhead.set(extrapolate(t));
      frame = requestAnimationFrame(tick);
    };
    frame = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(frame);
  }, [playing, playhead]);

  // Store → engine: the controller pushes every project change (one per frame).
  const project = state.project;

  // WebMCP: the same tools as the desktop MCP server, over the open project.
  useEffect(() => {
    if (!loaded) return;
    const ctx = { store, controller, loaded, projectId };
    if (import.meta.env.DEV) {
      // DEV-only: the same handlers for the lab's MCP parity harness.
      const w = window as unknown as { __editor?: Record<string, unknown> };
      if (w.__editor) {
        w.__editor.mcp = buildEditorToolHandlers(ctx);
        w.__editor.normalize = (text: string) => serializeProjectText(parseProjectText(text));
      }
    }
    return registerEditorWebMCP(ctx);
  }, [loaded, store, controller, projectId]);

  // The engine's slot on the stage. Rebuilt only when a different project
  // loads (the canvas can be transferred to a worker once).
  const videoRef = loaded && store.getState().project ? store.getState().project!.videoURL : null;
  const videoUrl = loaded ? loaded.mediaUrl(videoRef) : undefined;
  const stage = useMemo<StageMount | undefined>(() => {
    if (!loaded) return undefined;
    let current: StageViewport | null = null;
    return {
      mount(host, viewport) {
        current = viewport;
        let disposed = false;
        const canvas = document.createElement("canvas");
        // Size + device-pixel snap come from the stage CSS (shell.css / snapCanvas).
        canvas.style.cssText = "display:block";
        host.appendChild(canvas);
        void (async () => {
          try {
            if (!videoUrl) throw new Error("This project has no screen recording the web can load.");
            const client = await EngineClient.create(canvas, engineViewport(viewport));
            if (disposed) return client.dispose();
            controller.client = client;
            client.onError((e) => setEngineError(`${e.code}: ${e.message}`));
            client.onTransport((t) => {
              transportRef.current = t;
              setPlaying(t.playing);
              playhead.set(extrapolate(t));
            });
            const doc = store.documentJSON();
            const refs = refsOf(doc);
            const files: Record<string, string> = {};
            for (const ref of [refs.cursor, refs.keystrokes, refs.camera, ...refs.images, ...refs.audio]) {
              const url = ref ? loaded.mediaUrl(ref) : undefined;
              if (ref && url) files[ref] = url;
            }
            const loadedInfo = await client.load(doc, { video: videoUrl, files });
            if (disposed) return;
            setInfo(loadedInfo);
            if (current) client.resize(engineViewport(current));
            // Edits made while the engine loaded.
            if (store.getState().project) client.setProject(store.documentJSON());
            await client.seek(playhead.get());
            const interaction = mountStageInteraction(host, current ?? viewport, { store, controller, client });
            stageRef.current = interaction;
            controller.hooks.armBlurDraw = (style) => interaction.armBlurDraw(style);
            controller.hooks.beginInlineEdit = (id) => interaction.beginInlineEdit(id);
          } catch (error) {
            if (!disposed) setEngineError(error instanceof Error ? error.message : String(error));
          }
        })();
        return () => {
          disposed = true;
          stageRef.current?.dispose();
          stageRef.current = null;
          controller.hooks.armBlurDraw = undefined;
          controller.hooks.beginInlineEdit = undefined;
          controller.client?.dispose();
          controller.client = null;
          transportRef.current = null;
          canvas.remove();
        };
      },
      onViewport(viewport) {
        current = viewport;
        // Reference = the UNMAGNIFIED canvas: the zoom pill magnifies, it
        // never re-lays-out point sizes — and export reads this reference.
        controller.client?.resize(engineViewport(viewport));
        stageRef.current?.resize(viewport);
      },
    };
  }, [loaded, videoUrl, playhead, controller, store]);

  const navigate = useNavigate();
  controller.hooks.showProjects = () => void navigate({ to: "/app/projects" });

  // ✨ Auto Zoom / Motion — AutoZoomApplier / StillMotionApplier over the
  // recorded cursor + keys (fetched once) and the video's natural size.
  useEffect(() => {
    if (!loaded || !info) return;
    const inputs = () => {
      const p = store.getState().project;
      return p ? loadInteractionInputs(p, { mediaUrl: loaded.mediaUrl, naturalSize: info.naturalSize }) : null;
    };
    controller.hooks.autoZoom = async () => {
      const pending = inputs();
      if (!pending) return 0;
      const outcome = controller.apply(E.autoZoom(await pending));
      return outcome ? store.getState().project!.zoomRegions.filter((z) => z.isAuto === true).length : 0;
    };
    controller.hooks.stillMotion = async () => {
      const p = store.getState().project;
      // The Mac confirms before regenerating over existing zoom blocks (CCAlert).
      if (p && p.zoomRegions.length > 0 && (await alerts.present(REPLACE_ZOOM_BLOCKS)) !== 0) return 0;
      return controller.apply(E.stillMotion) ? 1 : 0;
    };
    return () => {
      controller.hooks.autoZoom = undefined;
      controller.hooks.stillMotion = undefined;
    };
  }, [loaded, info, controller, store, alerts]);

  const settings = project?.settings;
  const aspectId = settings?.aspectRatio ?? "Auto";
  // Re-letterboxed on every aspect / resolution / custom-size change, through
  // the exporter's own output-size function (ZoomScrollView.canvasAspectProvider).
  const canvasAspect = stageCanvasAspect(settings, info ? { width: info.width, height: info.height } : null);
  const hasAudio = info?.hasAudio ?? true;
  const timeline = useMemo(
    () => (project ? timelineSnapshot({ project, selection: state.selection, sliceArmed: state.sliceArmed, hasAudio }) : EMPTY_TIMELINE),
    [project, state.selection, state.sliceArmed, hasAudio],
  );
  // Filmstrip + recording/voice waveforms, decoded in the timeline media worker.
  const timelineWithMedia = useTimelineMedia(timeline, project, loaded, playing);
  // Voice over: the mic key, the live VOICE block, the "Voice Over" alert. It
  // pushes live snapshots straight into the renderer, so it gets the snapshot
  // WITH media — the filmstrip must not blink out while recording.
  const voiceOver = useVoiceOver({ store, controller, loaded, uploads, timeline: timelineWithMedia, rendererRef: timelineRendererRef, alerts });

  // Anything the web engine can't draw yet — the engine's own detection, live
  // from the document — is said over the stage, never rendered wrong silently.
  const unsupported = useMemo(() => (project ? unsupportedFeatures(store.documentJSON(project)) : []), [project, store]);

  const callbacks = useMemo(() => controller.shellCallbacks(), [controller]);
  const intents = useMemo(() => controller.timelineIntents(), [controller]);
  const paneActions = useMemo(() => editorPaneActions(controller), [controller]);
  const paneFacts = useRecordingFacts(project, loaded);
  const inspectorRevealKey = useInspectorRevealKey(store);
  usePendingSeek(store, controller, info != null, pendingSeek, projectId);
  const panes = useInspectorPanes(store, {
    onAction: (a) => controller.timelineAction(a),
    actions: { assetUrl: (fileName) => loaded?.mediaUrl(fileName), ...paneActions },
    facts: paneFacts,
  });

  if (loadError || state.parseError) {
    return (
      <ThemeRoot>
        <div className="cc-gate">
          <div className="cc-gate__card">
            <SFIcon name="exclamationmark.triangle" size={22} weight="regular" />
            <div className="cc-gate__title">Couldn’t open this project</div>
            <div className="cc-gate__body">{loadError ?? state.parseError}</div>
          </div>
        </div>
      </ThemeRoot>
    );
  }

  const transport: TransportState = {
    isPlaying: playing,
    canUndo: state.canUndo,
    canRedo: state.canRedo,
    canDelete: controller.canDelete(),
    sliceArmed: state.sliceArmed,
    isRecordingVoiceOver: voiceOver.isRecording,
    duration: timeline.outputDuration,
    hidesTime: timeline.timeless,
    timelessTimeline: project ? presentsTimelessTimeline(project) : false,
  };

  const conflict = state.conflict;
  const accessory = conflict ? (
    <span className="cc-caption" style={{ display: "inline-flex", gap: 6, alignItems: "center" }}>
      <span style={{ color: "var(--cc-destructive)" }}>Changed elsewhere</span>
      <Button size="sm" onClick={() => store.resolveConflict("keepMine")}>
        Keep mine
      </Button>
      {conflict.serverDocument ? (
        <Button size="sm" onClick={() => store.resolveConflict("takeTheirs")}>
          Load theirs
        </Button>
      ) : null}
    </span>
  ) : engineError ? (
    <span className="cc-caption" style={{ color: "var(--cc-destructive)" }} title={engineError}>
      {engineError.length > 60 ? `${engineError.slice(0, 60)}…` : engineError}
    </span>
  ) : state.origin === "local" ? (
    <span className="cc-caption" title="Opened from this Mac's project folder (dev server). Edits stay in this tab.">
      On this Mac · read-only
    </span>
  ) : undefined;

  return (
    <ThemeRoot>
      <WebGPUGate>
        <EditorShell
          project={{
            name: project?.name ?? (loaded ? "Untitled" : "Loading…"),
            aspectRatio: aspectId,
            canvasAspect,
            isImageCapture: project?.isStillCapture === true,
            stillTreatment: project?.stillTreatment,
            hasCursorData: project?.cursorDataURL != null,
            hasRecordedCamera: project?.cameraVideoURL != null,
            syncState: state.sync,
          }}
          transport={transport}
          playhead={playhead}
          callbacks={callbacks}
          timeline={timelineWithMedia}
          timelineIntents={intents}
          stage={stage}
          inspectorTab={state.inspectorTab}
          inspectorRevealKey={inspectorRevealKey}
          topBarAccessory={accessory}
          stageNotice={unsupported.length ? <UnsupportedNotice features={unsupported} /> : undefined}
          panes={panes}
          timelineRendererRef={timelineRendererRef}
        />
        <AlertHost presenter={alerts} />
        <ExportDialog
          open={exportOpen}
          onClose={() => setExportOpen(false)}
          client={controller.client}
          project={exportOpen && project ? (store.documentJSON() as Record<string, unknown>) : null}
          sourceSize={info ? { width: info.width, height: info.height } : null}
          onSettingsCommit={(s) =>
            store.updateSettings({ exportSettings: { ...(settings?.exportSettings ?? {}), ...s } } as never, "Export Settings")
          }
        />
      </WebGPUGate>
    </ThemeRoot>
  );
}
