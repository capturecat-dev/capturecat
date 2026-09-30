/**
 * DEV-ONLY render-engine lab (/editor-lab). Loads a synthetic fixture clip +
 * an inline project.json, with transport, a scrubber and a stats HUD.
 *
 * Per-frame values (playhead, HUD) are written straight to DOM nodes from
 * refs — never React state — so the lab measures the engine, not React.
 */
import { useCallback, useEffect, useRef, useState } from "react";
import { EngineClient, EngineError } from "../engine/client";
import { canvasAspect, letterboxRect } from "../engine/layout";
import type { EngineStats, LoadedInfo, ViewportSpec } from "../engine/protocol";
import { renderProjectFromJSON } from "../engine/contract";
import { FIXTURE_CLIPS, PROJECT_PRESETS } from "./fixtures";
import { createLabApi, type LabApi } from "./labApi";

declare global {
  interface Window {
    __lab?: LabApi & { ready: boolean; loadFixture: (clipId: string, presetId: string) => Promise<LoadedInfo>; client: () => EngineClient | null };
  }
}

const fmt = (n: number | undefined, d = 2) => (n === undefined || !Number.isFinite(n) ? "–" : n.toFixed(d));

function hudText(s: EngineStats | null, info: LoadedInfo | null): string {
  if (!s) return "…";
  const st = s.stream;
  return [
    `fps ${s.fps}  rendered ${s.rendered}`,
    `cpu frame ms  med ${fmt(s.frameMs.median)}  p99 ${fmt(s.frameMs.p99)}`,
    `gpu frame ms  ${s.gpuMs ? `med ${fmt(s.gpuMs.median)}  p99 ${fmt(s.gpuMs.p99)}` : "n/a"}`,
    `vsync ms      med ${fmt(s.intervalMs.median)}  p99 ${fmt(s.intervalMs.p99)}`,
    `late ${s.lateFrames}  skipped ${s.skippedFrames}  frame ${s.displayedIndex}/${s.targetIndex}`,
    st
      ? `decode q ${st.decodeQueueSize}  inflight ${st.inflight}  cached ${st.cached} (${(st.cacheBytes / 1048576).toFixed(0)} MB)  ahead ${st.aheadOfTarget}`
      : "decode –",
    st ? `restarts ${st.restarts}  decoded ${st.decoded}  lateOut ${st.lateOutputs}  seek ${fmt(st.lastSeekMs ?? undefined, 1)} ms` : "",
    `gpu mem ${(s.gpuResidentBytes / 1048576).toFixed(0)} MB  bake ${fmt(s.staticBakeMs, 1)} ms  sync ${fmt(s.clockSyncErrorMs, 1)} ms`,
    info ? `${info.codec} ${info.width}×${info.height}@${info.fps} → ${info.outputSize.width}×${info.outputSize.height}  ${info.workingSpace}/${info.canvasColorSpace}  hw ${info.hardwareDecode}` : "",
    info?.unsupportedFeatures.length ? `not drawn yet: ${info.unsupportedFeatures.join(", ")}` : "",
  ]
    .filter(Boolean)
    .join("\n");
}

export default function LabPage() {
  const stageRef = useRef<HTMLDivElement>(null);
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const hudRef = useRef<HTMLPreElement>(null);
  const scrubRef = useRef<HTMLInputElement>(null);
  const timeRef = useRef<HTMLSpanElement>(null);
  const clientRef = useRef<EngineClient | null>(null);
  const infoRef = useRef<LoadedInfo | null>(null);
  const forcedViewport = useRef<ViewportSpec | null>(null);
  const projectRef = useRef<unknown>(PROJECT_PRESETS[1].project);

  const [clipId, setClipId] = useState(FIXTURE_CLIPS[0].id);
  const [presetId, setPresetId] = useState(PROJECT_PRESETS[1].id);
  const [json, setJson] = useState(() => JSON.stringify(PROJECT_PRESETS[1].project.settings, null, 2));
  const [playing, setPlaying] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [status, setStatus] = useState("starting…");
  const aspectRef = useRef(16 / 9);

  // Stage layout: letterbox the canvas to the output aspect (like the Mac editor).
  const layoutStage = useCallback(() => {
    const stage = stageRef.current;
    const canvas = canvasRef.current;
    if (!stage || !canvas) return;
    const r = letterboxRect({ x: 0, y: 0, width: stage.clientWidth, height: stage.clientHeight }, aspectRef.current);
    canvas.style.left = `${r.x}px`;
    canvas.style.top = `${r.y}px`;
    canvas.style.width = `${r.width}px`;
    canvas.style.height = `${r.height}px`;
    const v: ViewportSpec = forcedViewport.current ?? {
      cssWidth: Math.round(r.width),
      cssHeight: Math.round(r.height),
      dpr: window.devicePixelRatio || 1,
    };
    clientRef.current?.resize(v);
  }, []);

  const setAspect = useCallback(
    (a: number) => {
      aspectRef.current = a;
      layoutStage();
    },
    [layoutStage],
  );

  const load = useCallback(async (id: string, project: unknown) => {
    const client = clientRef.current;
    if (!client) throw new Error("engine not ready");
    const clip = FIXTURE_CLIPS.find((c) => c.id === id);
    if (!clip) throw new Error(`unknown fixture ${id}`);
    projectRef.current = project;
    setStatus(`loading ${clip.label}…`);
    const info = await client.load(project, { video: clip.url });
    infoRef.current = info;
    const s = renderProjectFromJSON(project).settings;
    setAspect(canvasAspect(s.aspectRatio, { width: info.width, height: info.height }));
    if (scrubRef.current) scrubRef.current.max = String(info.outputDuration);
    setStatus(`${clip.label} — ${info.frameCount} frames, key every ${info.keyframeInterval.toFixed(0)}${info.hasBFrames ? ", B-frames" : ""}`);
    return info;
  }, [setAspect]);

  // Engine bring-up.
  useEffect(() => {
    let disposed = false;
    const stage = stageRef.current!;
    // A fresh canvas per effect run: control can be transferred to a worker
    // only once, and StrictMode runs this effect twice in dev.
    const canvas = document.createElement("canvas");
    canvas.style.position = "absolute";
    stage.prepend(canvas);
    canvasRef.current = canvas;
    const init = async () => {
      try {
        const r = letterboxRect({ x: 0, y: 0, width: stage.clientWidth, height: stage.clientHeight }, 16 / 9);
        const client = await EngineClient.create(canvas, {
          cssWidth: Math.round(r.width),
          cssHeight: Math.round(r.height),
          dpr: window.devicePixelRatio || 1,
        });
        if (disposed) return client.dispose();
        clientRef.current = client;
        client.onError((e) => setError(`${e.code}: ${e.message}`));
        client.onStats((s) => {
          if (hudRef.current) hudRef.current.textContent = hudText(s, infoRef.current);
        });
        client.onTransport((t) => setPlaying(t.playing));
        const api = createLabApi({
          client: () => clientRef.current!,
          load,
          setViewport: (v) => {
            forcedViewport.current = v;
            layoutStage();
          },
          currentProject: () => projectRef.current,
        });
        window.__lab = {
          ...api,
          ready: true,
          client: () => clientRef.current,
          loadFixture: (cid, pid) => {
            const preset = PROJECT_PRESETS.find((p) => p.id === pid) ?? PROJECT_PRESETS[0];
            return load(cid, preset.project);
          },
        };
        const params = new URLSearchParams(location.search);
        const cid = params.get("clip") ?? FIXTURE_CLIPS[0].id;
        const pid = params.get("preset") ?? PROJECT_PRESETS[1].id;
        setClipId(cid);
        setPresetId(pid);
        const preset = PROJECT_PRESETS.find((p) => p.id === pid) ?? PROJECT_PRESETS[1];
        setJson(JSON.stringify(preset.project.settings, null, 2));
        if (params.get("autoload") !== "0") await load(cid, preset.project);
      } catch (e) {
        setError(e instanceof EngineError ? `${e.code}: ${e.message}` : String(e));
      }
    };
    void init();
    return () => {
      disposed = true;
      clientRef.current?.dispose();
      clientRef.current = null;
      canvas.remove();
      if (canvasRef.current === canvas) canvasRef.current = null;
      delete window.__lab;
    };
  }, [load, layoutStage]);

  // Resize → engine viewport.
  useEffect(() => {
    const stage = stageRef.current!;
    const ro = new ResizeObserver(() => layoutStage());
    ro.observe(stage);
    layoutStage();
    return () => ro.disconnect();
  }, [layoutStage]);

  // Playhead readout: rAF on the main thread reads the extrapolated transport; DOM only.
  useEffect(() => {
    let raf = 0;
    const loop = () => {
      const c = clientRef.current;
      if (c && scrubRef.current && timeRef.current && document.activeElement !== scrubRef.current) {
        const t = c.currentTime();
        scrubRef.current.value = String(t);
        timeRef.current.textContent = `${t.toFixed(3)} s`;
      }
      raf = requestAnimationFrame(loop);
    };
    raf = requestAnimationFrame(loop);
    return () => cancelAnimationFrame(raf);
  }, []);

  // Scrub: coalesce input events to one seek per animation frame.
  const pendingSeek = useRef<number | null>(null);
  const onScrub = (e: React.FormEvent<HTMLInputElement>) => {
    const t = Number((e.target as HTMLInputElement).value);
    if (timeRef.current) timeRef.current.textContent = `${t.toFixed(3)} s`;
    if (pendingSeek.current === null) {
      requestAnimationFrame(() => {
        const v = pendingSeek.current;
        pendingSeek.current = null;
        if (v !== null) void clientRef.current?.seek(v);
      });
    }
    pendingSeek.current = t;
  };

  const applyJson = () => {
    try {
      const settings = JSON.parse(json);
      const preset = PROJECT_PRESETS.find((p) => p.id === presetId) ?? PROJECT_PRESETS[0];
      const project = { ...preset.project, settings: { ...preset.project.settings, ...settings } };
      projectRef.current = project;
      clientRef.current?.setProject(project);
      const info = infoRef.current;
      if (info) setAspect(canvasAspect(renderProjectFromJSON(project).settings.aspectRatio, info));
      setError(null);
    } catch (e) {
      setError(`project JSON: ${String(e)}`);
    }
  };

  const loadSelected = (cid = clipId, pid = presetId) => {
    const preset = PROJECT_PRESETS.find((p) => p.id === pid) ?? PROJECT_PRESETS[0];
    setJson(JSON.stringify(preset.project.settings, null, 2));
    load(cid, preset.project).catch((e) => setError(String(e)));
  };

  const savePng = async () => {
    const snap = await clientRef.current?.snapshot({ png: true });
    if (!snap?.png) return;
    const a = document.createElement("a");
    a.href = URL.createObjectURL(snap.png);
    a.download = `editor-lab-${snap.meta.frameIndex}.png`;
    a.click();
  };

  const runExport = async () => {
    const c = clientRef.current;
    if (!c) return;
    setStatus("exporting 2 s…");
    const r = await c.export({ start: 0, end: 2 }, (d, t) => setStatus(`exporting ${d}/${t}`));
    const url = URL.createObjectURL(new Blob([r.buffer], { type: r.mimeType }));
    const a = document.createElement("a");
    a.href = url;
    a.download = `editor-lab-export.mp4`;
    a.click();
    setStatus(`exported ${r.frames} frames ${r.width}×${r.height} ${r.codec} in ${r.encodeMs.toFixed(0)} ms`);
  };

  return (
    <div className="flex h-screen flex-col bg-[#101012] text-[13px] text-neutral-200">
      <div className="flex flex-wrap items-center gap-2 border-b border-white/10 px-4 py-2">
        <span className="font-semibold text-white">Editor lab</span>
        <span className="rounded bg-amber-500/20 px-1.5 text-[11px] text-amber-300">DEV</span>
        <select
          className="rounded bg-white/5 px-2 py-1"
          value={clipId}
          onChange={(e) => {
            setClipId(e.target.value);
            loadSelected(e.target.value, presetId);
          }}
        >
          {FIXTURE_CLIPS.map((c) => (
            <option key={c.id} value={c.id}>
              {c.label}
            </option>
          ))}
        </select>
        <select
          className="rounded bg-white/5 px-2 py-1"
          value={presetId}
          onChange={(e) => {
            setPresetId(e.target.value);
            loadSelected(clipId, e.target.value);
          }}
        >
          {PROJECT_PRESETS.map((p) => (
            <option key={p.id} value={p.id}>
              {p.label}
            </option>
          ))}
        </select>
        <button className="rounded bg-white/10 px-3 py-1 hover:bg-white/15" onClick={() => (playing ? clientRef.current?.pause() : clientRef.current?.play())}>
          {playing ? "Pause" : "Play"}
        </button>
        <select className="rounded bg-white/5 px-2 py-1" defaultValue="1" onChange={(e) => clientRef.current?.setRate(Number(e.target.value))}>
          {[0.25, 0.5, 1, 1.5, 2].map((r) => (
            <option key={r} value={r}>
              {r}×
            </option>
          ))}
        </select>
        <label className="flex items-center gap-1">
          <input type="checkbox" defaultChecked onChange={(e) => clientRef.current?.setLoop(e.target.checked)} /> loop
        </label>
        <label className="flex items-center gap-1" title="Debug: card-only zoom through the camera path">
          zoom
          <input
            type="range"
            min={1}
            max={2.5}
            step={0.01}
            defaultValue={1}
            onInput={(e) =>
              clientRef.current?.debug({ camera: { zoom: Number((e.target as HTMLInputElement).value), focalX: 0.3, focalY: 0.35 } })
            }
          />
        </label>
        <button className="rounded bg-white/10 px-3 py-1 hover:bg-white/15" onClick={savePng}>
          PNG
        </button>
        <button className="rounded bg-white/10 px-3 py-1 hover:bg-white/15" onClick={runExport}>
          Export 2 s
        </button>
        <span className="ml-auto truncate text-neutral-400">{status}</span>
      </div>
      {error && <div className="bg-red-900/50 px-4 py-2 text-red-200">{error}</div>}
      <div className="flex min-h-0 flex-1 flex-col md:flex-row">
        <div ref={stageRef} className="relative min-h-0 min-w-0 flex-1 bg-[repeating-conic-gradient(#1a1a1d_0_25%,#141416_0_50%)] bg-[length:24px_24px]">
          <pre ref={hudRef} className="pointer-events-none absolute left-3 top-3 rounded bg-black/70 px-2 py-1.5 font-mono text-[11px] leading-4 text-emerald-300">
            …
          </pre>
        </div>
        <div className="flex h-56 flex-col gap-2 border-t border-white/10 p-3 md:h-auto md:w-80 md:border-l md:border-t-0">
          <div className="text-neutral-400">project.json settings (inline)</div>
          <textarea
            className="min-h-0 flex-1 rounded bg-black/40 p-2 font-mono text-[11px]"
            spellCheck={false}
            value={json}
            onChange={(e) => setJson(e.target.value)}
          />
          <button className="rounded bg-white/10 px-3 py-1 hover:bg-white/15" onClick={applyJson}>
            Apply settings
          </button>
        </div>
      </div>
      <div className="flex items-center gap-3 border-t border-white/10 px-4 py-2">
        <input ref={scrubRef} type="range" min={0} max={10} step={1 / 600} defaultValue={0} className="flex-1" onInput={onScrub} />
        <span ref={timeRef} className="w-20 text-right font-mono tabular-nums">
          0.000 s
        </span>
      </div>
    </div>
  );
}
