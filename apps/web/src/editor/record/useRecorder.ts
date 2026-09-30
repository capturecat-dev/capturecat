/**
 * useRecorder — the web recorder's state machine, UI-free. The dashboard's
 * Record page renders it; the floating controls window renders the live
 * half of it. Semantics are the Mac recording panel's
 * (RecordingPanelViewController + AppState):
 *
 *   defaults   mic ON (preferred device), camera OFF, system audio ON,
 *              3 s countdown, no duration limit — persisted per browser
 *   setup      choose a source first; Record exists only once one is chosen
 *   live       timer (M:SS / H:MM:SS; "-M:SS" under a limit, warn ≤ 10 s),
 *              pause/resume, restart (discard + start over), stop, delete
 *   after      stop → upload as a cloud project → onSaved(projectId)
 *
 * A share ended from outside (the browser's "Stop sharing") stops and saves
 * the take, like the Mac when its source disappears.
 */
import { useCallback, useEffect, useRef, useState } from "react";

import { newUUID } from "../core/model";
import { CloudApiError } from "../state/cloud";
import {
  listDevices,
  preferFrameRate,
  openCamera,
  openMic,
  primeDevicePermission,
  recorderSupport,
  requestScreen,
  stopStream,
  surfaceLabel,
  surfaceOf,
  type CaptureInfo,
  type DeviceLists,
  type SurfaceKind,
} from "./capture";
import { BUBBLE_EXIT_MS } from "./cameraBubble";
import { closeControlsWindow, openControlsWindow, pipSupported } from "./pip";
import { publishTake, type PublishProgress } from "./publish";
import { discardTakeFiles, leftoverTakes, warmRecorder, type RecordedTake } from "./session";
import { createTakeRecorder, recorderEngine, type TakeRecorder } from "./takeRecorder";

export const RECORD_FPS = 60;
export const COUNTDOWN_CHOICES = [0, 3, 5, 10] as const;
export const LIMIT_CHOICES = [0, 15, 30, 60, 120, 300, 600] as const;

export interface RecorderPrefs {
  surface: SurfaceKind;
  /** null = "No Microphone"; "" = the system default device. */
  micId: string | null;
  /** null = "No Overlay" (the Mac default). */
  camId: string | null;
  systemAudio: boolean;
  countdown: number;
  limit: number;
  /** Float the live controls above other windows (window/tab shares). */
  floatControls: boolean;
}

const PREFS_KEY = "cc.recorder.prefs";
export const DEFAULT_RECORDER_PREFS: RecorderPrefs = {
  surface: "monitor",
  micId: "",
  camId: null,
  systemAudio: true,
  countdown: 3,
  limit: 0,
  floatControls: true,
};

function loadPrefs(): RecorderPrefs {
  try {
    return { ...DEFAULT_RECORDER_PREFS, ...(JSON.parse(localStorage.getItem(PREFS_KEY) ?? "{}") as Partial<RecorderPrefs>) };
  } catch {
    return DEFAULT_RECORDER_PREFS;
  }
}

function savePrefs(p: RecorderPrefs): void {
  try {
    localStorage.setItem(PREFS_KEY, JSON.stringify(p));
  } catch {
    // private mode: settings just don't persist
  }
}

/** The Mac panel's clock: M:SS, or H:MM:SS past an hour. */
export function formatClock(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const ss = String(s % 60).padStart(2, "0");
  return h > 0 ? `${h}:${String(m).padStart(2, "0")}:${ss}` : `${m}:${ss}`;
}

export function limitTitle(limit: number): string {
  if (limit === 0) return "No Limit";
  return limit < 60 ? `${limit}s` : `${limit / 60} min`;
}

export type RecorderPhase =
  | { kind: "setup" }
  | { kind: "countdown"; left: number }
  | { kind: "recording" }
  | { kind: "saving"; take: RecordedTake; progress: PublishProgress | null }
  | { kind: "failed"; take: RecordedTake; message: string };

/** Mic input level 0…1 (RMS in dB, eased) — the devices meter. */
export function useInputLevel(stream: MediaStream | null): number {
  const [level, setLevel] = useState(0);
  useEffect(() => {
    const track = stream?.getAudioTracks()[0];
    if (!track) {
      setLevel(0);
      return;
    }
    const ctx = new AudioContext();
    const src = ctx.createMediaStreamSource(new MediaStream([track]));
    const an = ctx.createAnalyser();
    an.fftSize = 1024;
    src.connect(an);
    const buf = new Float32Array(an.fftSize);
    let raf = 0;
    let eased = 0;
    const tick = () => {
      an.getFloatTimeDomainData(buf);
      let sum = 0;
      for (const v of buf) sum += v * v;
      const rms = Math.sqrt(sum / buf.length);
      const target = Math.min(1, Math.max(0, (20 * Math.log10(rms + 1e-6) + 60) / 60));
      eased += (target - eased) * (target > eased ? 0.5 : 0.12);
      setLevel(eased);
      raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    return () => {
      cancelAnimationFrame(raf);
      src.disconnect();
      void ctx.close();
    };
  }, [stream]);
  return level;
}

export function useRecorder({ onSaved }: { onSaved: (projectId: string) => void }) {
  // Capabilities are client facts: null through SSR + hydration, set after mount.
  const [support, setSupport] = useState<ReturnType<typeof recorderSupport> | null>(null);
  const [engine, setEngine] = useState<ReturnType<typeof recorderEngine>>("webcodecs");
  useEffect(() => {
    setSupport(recorderSupport());
    setEngine(recorderEngine());
  }, []);
  const [prefs, setPrefsState] = useState<RecorderPrefs>(DEFAULT_RECORDER_PREFS);
  const [devices, setDevices] = useState<DeviceLists>({ cameras: [], mics: [] });
  const [screen, setScreen] = useState<MediaStream | null>(null);
  const [captureInfo, setCaptureInfo] = useState<CaptureInfo | null>(null);
  const [camStream, setCamStream] = useState<MediaStream | null>(null);
  const [micStream, setMicStream] = useState<MediaStream | null>(null);
  const [phase, setPhase] = useState<RecorderPhase>({ kind: "setup" });
  /** Record pressed, take not live yet (the floating window / countdown / start). */
  const [starting, setStarting] = useState(false);
  const [paused, setPaused] = useState(false);
  const [busy, setBusy] = useState(false);
  const [elapsed, setElapsed] = useState(0);
  const [notice, setNotice] = useState<string | null>(null);
  const [leftovers, setLeftovers] = useState<RecordedTake[]>([]);
  const [floating, setFloating] = useState<{ win: Window; mount: HTMLElement } | null>(null);
  const [name, setName] = useState("");
  /**
   * Devices open only once the recorder is ARMED — the bar is on every
   * dashboard page, and a mic light (and permission prompt) on the Library
   * would be wrong. Touching the bar or opening the Record page arms it; the
   * bar's close key disarms (the Mac panel's ×: devices released).
   */
  const [armed, setArmed] = useState(false);
  const sessionRef = useRef<TakeRecorder | null>(null);
  const abortRef = useRef<AbortController | null>(null);

  const setPrefs = useCallback((patch: Partial<RecorderPrefs>) => {
    setPrefsState((p) => {
      const next = { ...p, ...patch };
      savePrefs(next);
      return next;
    });
  }, []);

  const refreshDevices = useCallback(() => void listDevices().then(setDevices), []);

  useEffect(() => {
    setPrefsState(loadPrefs());
    refreshDevices();
    navigator.mediaDevices?.addEventListener?.("devicechange", refreshDevices);
    void leftoverTakes().then(setLeftovers);
    // Safari records with MediaRecorder — never poke its WebCodecs encoders.
    void warmRecorder({ encoders: recorderEngine() === "webcodecs" });
    return () => navigator.mediaDevices?.removeEventListener?.("devicechange", refreshDevices);
  }, [refreshDevices]);

  // Live mic: the level meter now, the take's mic track later.
  useEffect(() => {
    if (!armed || prefs.micId === null || !support?.screen) {
      setMicStream(null);
      return;
    }
    let stream: MediaStream | null = null;
    let alive = true;
    void openMic(prefs.micId || null)
      .then((s) => {
        if (!alive) return stopStream(s);
        stream = s;
        setMicStream(s);
        refreshDevices(); // labels appear after the grant
      })
      .catch(() => {
        if (alive) setNotice("Microphone unavailable — allow microphone access for this site in the browser.");
      });
    return () => {
      alive = false;
      stopStream(stream);
    };
  }, [armed, prefs.micId, support?.screen, refreshDevices]);

  // Live camera: the preview bubble now, the take's camera track later.
  useEffect(() => {
    if (!armed || !prefs.camId) {
      setCamStream(null);
      return;
    }
    let stream: MediaStream | null = null;
    let alive = true;
    void openCamera(prefs.camId)
      .then((s) => {
        if (!alive) return stopStream(s);
        stream = s;
        setCamStream(s);
      })
      .catch(() => {
        if (alive) {
          setNotice("Camera unavailable — it may be in use by another app.");
          setPrefs({ camId: null });
        }
      });
    return () => {
      alive = false;
      stopStream(stream);
    };
  }, [armed, prefs.camId, setPrefs]);

  useEffect(() => () => stopStream(screen), [screen]);

  useEffect(() => {
    if (phase.kind !== "recording") return;
    let raf = 0;
    const tick = () => {
      setElapsed(sessionRef.current?.elapsed() ?? 0);
      raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, [phase.kind]);

  const allowDevices = useCallback(async () => {
    await Promise.all([primeDevicePermission("video"), primeDevicePermission("audio")]);
    refreshDevices();
  }, [refreshDevices]);

  // ── source ────────────────────────────────────────────────────────────────

  const arm = useCallback(() => setArmed(true), []);

  const chooseSource = useCallback(async () => {
    setNotice(null);
    const asked = performance.now();
    try {
      // The share FIRST, devices after: Safari aborts a pending
      // getDisplayMedia when another capture request (the mic/camera that
      // arming opens) starts while its picker is up — "The operation was
      // aborted." on any page that wasn't armed yet.
      const stream = await requestScreen({
        surface: prefs.surface,
        systemAudio: prefs.systemAudio,
        fps: RECORD_FPS,
        plain: recorderEngine() === "mediarecorder",
      });
      stream.getVideoTracks()[0]?.addEventListener("ended", () => setScreen((cur) => (cur === stream ? null : cur)));
      setCaptureInfo(await preferFrameRate(stream, RECORD_FPS));
      setScreen(stream);
      setArmed(true);
      const chosen = surfaceOf(stream);
      if (chosen !== prefs.surface) setPrefs({ surface: chosen });
      // (Safari never shares system audio — its bar says so; no notice.)
      if (prefs.systemAudio && stream.getAudioTracks().length === 0 && recorderEngine() !== "mediarecorder") {
        setNotice(
          chosen === "browser"
            ? "No audio from that tab — tick “Also share tab audio” in the picker to record it."
            : "This platform doesn't share system audio for that source — only your microphone will be recorded.",
        );
      }
    } catch (error) {
      if (error instanceof DOMException && error.name === "NotAllowedError") {
        // A person closing the picker takes seconds; a refusal in well under a
        // second never showed one — the browser or macOS is blocking the site
        // (Safari 26.2 probe: NotAllowedError after ~0.5 s, no prompt).
        if (performance.now() - asked > 1200) return; // picker cancelled
        setNotice(
          recorderEngine() === "mediarecorder"
            ? "Safari is blocking screen sharing for this site. In Safari → Settings → Websites → Screen Sharing, set this site to Ask; and in System Settings → Privacy & Security → Screen & System Audio Recording, allow Safari. Then choose again."
            : "Screen sharing is blocked for this site. Allow it in the browser's site settings (and the system's screen recording privacy settings), then choose again.",
        );
        return;
      }
      // Keep the browser's own words: they are the only diagnosis there is.
      const raw = error instanceof Error ? `${error.name}: ${error.message}` : String(error);
      if (error instanceof DOMException && error.name === "AbortError" && recorderEngine() === "mediarecorder") {
        // Safari gave up before its picker (no Screen Recording check even
        // runs) — after one share has worked, its sharing session can stay
        // stuck until Safari restarts (macOS 26.2, 2026-09-30).
        setNotice(`Safari couldn't start screen sharing (${raw}). Quit Safari (⌘Q), reopen it and try again — or record in Chrome.`);
        return;
      }
      setNotice(`Screen sharing failed (${raw}). Choose again.`);
    }
  }, [prefs.surface, prefs.systemAudio, setPrefs]);

  const clearSource = useCallback(() => setScreen(null), []);

  /** The bar's close key: release the source, camera and mic (idle only). */
  const disarm = useCallback(() => {
    setScreen(null);
    setArmed(false);
    setNotice(null);
  }, []);

  // ── recording ─────────────────────────────────────────────────────────────

  const closeFloating = useCallback(() => {
    setFloating((cur) => {
      closeControlsWindow(cur?.win ?? null);
      return null;
    });
  }, []);

  const publish = useCallback(
    async (take: RecordedTake) => {
      closeFloating();
      setPhase({ kind: "saving", take, progress: null });
      const abort = new AbortController();
      abortRef.current = abort;
      try {
        const id = await publishTake(take, {
          name,
          signal: abort.signal,
          onProgress: (progress) => setPhase({ kind: "saving", take, progress }),
        });
        await discardTakeFiles(take.folder);
        setLeftovers((l) => l.filter((t) => t.id !== take.id));
        setArmed(false);
        setPhase({ kind: "setup" });
        onSaved(id);
      } catch (error) {
        if (abort.signal.aborted) {
          setPhase({ kind: "setup" });
          void leftoverTakes().then(setLeftovers);
          return;
        }
        const message = error instanceof CloudApiError || error instanceof Error ? error.message : String(error);
        setPhase({ kind: "failed", take, message });
      } finally {
        abortRef.current = null;
      }
    },
    [closeFloating, name, onSaved],
  );

  const cancelUpload = useCallback(() => abortRef.current?.abort(), []);

  const stop = useCallback(async () => {
    const session = sessionRef.current;
    if (!session || busy) return;
    setBusy(true);
    try {
      const take = await session.stop();
      session.releaseStreams();
      sessionRef.current = null;
      setScreen(null);
      setPaused(false);
      await publish(take);
    } catch (error) {
      setNotice(error instanceof Error ? error.message : String(error));
      setPhase({ kind: "setup" });
    } finally {
      setBusy(false);
    }
  }, [busy, publish]);
  const stopRef = useRef(stop);
  stopRef.current = stop;

  const begin = useCallback(async () => {
    if (!screen) return;
    const session = createTakeRecorder({ screen, camera: camStream, mic: micStream }, RECORD_FPS, newUUID());
    session.onSourceEnded = () => void stopRef.current();
    sessionRef.current = session;
    try {
      await session.start();
      setPaused(false);
      setElapsed(0);
      setPhase({ kind: "recording" });
    } catch (error) {
      sessionRef.current = null;
      await session.discard();
      closeFloating();
      setNotice(error instanceof Error ? error.message : String(error));
      setPhase({ kind: "setup" });
    }
  }, [screen, camStream, micStream, closeFloating]);

  useEffect(() => {
    if (phase.kind === "recording" && prefs.limit > 0 && elapsed >= prefs.limit) void stop();
  }, [phase.kind, elapsed, prefs.limit, stop]);

  /** The red Record button. Must run inside the click (floating controls need its activation). */
  const record = useCallback(async () => {
    if (!screen || phase.kind !== "setup") return;
    setNotice(null);
    setStarting(true);
    const pressed = performance.now();
    try {
      if (prefs.floatControls && pipSupported() && surfaceOf(screen) !== "monitor") {
        const opened = await openControlsWindow({ width: 440, height: prefs.camId ? 280 : 72 }, () => setFloating(null));
        if (opened) setFloating(opened);
      }
      for (let left = prefs.countdown; left > 0; left--) {
        setPhase({ kind: "countdown", left });
        await new Promise((r) => setTimeout(r, 1000));
      }
      // A whole-screen share records this page, so the camera bubble steps
      // aside from the Record press (cameraBubble.ts bubblePolicy). Without a
      // countdown, let its exit finish before the first frame is captured.
      if (prefs.camId && surfaceOf(screen) === "monitor") {
        const wait = BUBBLE_EXIT_MS + 50 - (performance.now() - pressed);
        if (wait > 0) await new Promise((r) => setTimeout(r, wait));
      }
      await begin();
    } finally {
      setStarting(false);
    }
  }, [screen, phase.kind, prefs.floatControls, prefs.countdown, prefs.camId, begin]);

  const pauseResume = useCallback(() => {
    const s = sessionRef.current;
    if (!s) return;
    if (s.state === "paused") s.resume();
    else s.pause();
    setPaused(s.state === "paused");
  }, []);

  const restart = useCallback(async () => {
    const s = sessionRef.current;
    if (!s) return;
    setBusy(true);
    sessionRef.current = null;
    await s.discard();
    setBusy(false);
    await begin();
  }, [begin]);

  const remove = useCallback(async () => {
    const s = sessionRef.current;
    if (!s) return;
    setBusy(true);
    sessionRef.current = null;
    await s.discard();
    setBusy(false);
    closeFloating();
    setPaused(false);
    setPhase({ kind: "setup" });
  }, [closeFloating]);

  const deleteLeftover = useCallback(async (take: RecordedTake) => {
    await discardTakeFiles(take.folder);
    setLeftovers((l) => l.filter((t) => t.id !== take.id));
  }, []);

  // Leaving mid-take or mid-upload: the browser asks first.
  useEffect(() => {
    if (phase.kind !== "recording" && phase.kind !== "saving" && phase.kind !== "countdown") return;
    const guard = (e: BeforeUnloadEvent) => e.preventDefault();
    window.addEventListener("beforeunload", guard);
    return () => window.removeEventListener("beforeunload", guard);
  }, [phase.kind]);

  const remaining = prefs.limit > 0 ? prefs.limit - elapsed : null;

  return {
    support,
    /** Which engine records here ("mediarecorder" = Safari). */
    engine,
    armed,
    arm,
    disarm,
    prefs,
    setPrefs,
    devices,
    allowDevices,
    screen,
    sourceLabel: screen ? surfaceLabel(screen) : "",
    /** What the chosen capture really delivers (size, fps) — shown on the Record page. */
    captureInfo: screen ? captureInfo : null,
    sourceSurface: screen ? surfaceOf(screen) : null,
    starting,
    chooseSource,
    clearSource,
    camStream,
    micStream,
    phase,
    paused,
    busy,
    elapsed,
    clock: remaining !== null ? `-${formatClock(Math.ceil(Math.max(0, remaining)))}` : formatClock(elapsed),
    clockWarn: remaining !== null && remaining <= 10,
    notice,
    setNotice,
    name,
    setName,
    record,
    pauseResume,
    restart,
    stop,
    remove,
    publish,
    cancelUpload,
    leftovers,
    deleteLeftover,
    floating,
    pipSupported: pipSupported(),
  };
}

export type Recorder = ReturnType<typeof useRecorder>;
