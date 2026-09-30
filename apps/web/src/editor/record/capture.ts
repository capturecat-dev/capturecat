/**
 * Capture sources for the web recorder — the browser twins of the Mac
 * recording panel's source picker, devices chip and "Audio On/Off" chip
 * (RecordingPanelViewController):
 *
 *   screen   getDisplayMedia — the browser's own picker chooses the display,
 *            window or tab (`surface` only sets which list opens first)
 *   camera   getUserMedia video ("Camera Overlay"; default: none, like the Mac)
 *   mic      getUserMedia audio (default: the system's preferred mic, on)
 *
 * What a browser cannot give us (so web takes have none): cursor telemetry
 * outside the page — the system cursor is burned into the frames — and
 * keystrokes. `cursor: "always"` keeps that burned-in cursor visible.
 */

export type SurfaceKind = "monitor" | "window" | "browser";

export interface CaptureDevice {
  deviceId: string;
  label: string;
}

export interface DeviceLists {
  cameras: CaptureDevice[];
  mics: CaptureDevice[];
}

/** Device lists. Labels are empty until the page holds a permission for that kind. */
export async function listDevices(): Promise<DeviceLists> {
  const all = await navigator.mediaDevices.enumerateDevices().catch(() => [] as MediaDeviceInfo[]);
  const pick = (kind: MediaDeviceKind, fallback: string) =>
    all
      .filter((d) => d.kind === kind && d.deviceId !== "" && d.deviceId !== "communications")
      .map((d, i) => ({ deviceId: d.deviceId, label: d.label || `${fallback} ${i + 1}` }));
  return { cameras: pick("videoinput", "Camera"), mics: pick("audioinput", "Microphone") };
}

/** Ask once so device labels appear (the stream is stopped immediately). */
export async function primeDevicePermission(kind: "audio" | "video"): Promise<boolean> {
  try {
    const s = await navigator.mediaDevices.getUserMedia(kind === "audio" ? { audio: true } : { video: true });
    s.getTracks().forEach((t) => t.stop());
    return true;
  } catch {
    return false;
  }
}

export interface ScreenRequest {
  surface: SurfaceKind;
  /** The Mac's "Audio On": system (or tab) audio alongside the picture. */
  systemAudio: boolean;
  /** Capture rate the encoder samples at (the Mac records at 60). */
  fps: number;
  /**
   * Plain request (Safari): only a frame-rate hint, no audio, nothing done to
   * the track afterwards. WebKit on macOS 26 failed the share ("Invalid
   * display 0x00000000" in its GPU process → AbortError) once the live track
   * was re-constrained; it shares no system audio anyway.
   */
  plain?: boolean;
}

/**
 * The browser's share picker. Rejects with a DOMException "NotAllowedError"
 * when the person cancels it.
 */
export async function requestScreen(req: ScreenRequest): Promise<MediaStream> {
  if (req.plain) {
    return navigator.mediaDevices.getDisplayMedia({ video: { frameRate: { ideal: req.fps } }, audio: false });
  }
  const video: MediaTrackConstraints & Record<string, unknown> = {
    displaySurface: req.surface,
    frameRate: { ideal: req.fps, max: req.fps },
    width: { max: 3840 },
    height: { max: 2160 },
    cursor: "always",
  };
  const options: DisplayMediaStreamOptions & Record<string, unknown> = {
    video,
    audio: req.systemAudio
      ? ({
          echoCancellation: false,
          noiseSuppression: false,
          autoGainControl: false,
          suppressLocalAudioPlayback: false,
        } as MediaTrackConstraints)
      : false,
    // Keep this tab out of the list (recording the recorder is never wanted),
    // but offer whole screens and system audio where the platform can.
    selfBrowserSurface: "exclude",
    surfaceSwitching: "include",
    monitorTypeSurfaces: "include",
    systemAudio: req.systemAudio ? "include" : "exclude",
    preferCurrentTab: false,
  };
  return navigator.mediaDevices.getDisplayMedia(options);
}

export interface CaptureInfo {
  width: number;
  height: number;
  /** Frames per second the capture delivers (the recording can't exceed it). */
  fps: number;
  /** The most this capture says it can do, when the browser reports it. */
  maxFps: number | null;
}

/**
 * Ask the live capture for `fps` — but only when the track itself reports it
 * can (getCapabilities), and never fatally: Safari's screen capture defaults
 * to 30 fps; if it can do 60 this lifts it, if not nothing is touched.
 */
export async function preferFrameRate(stream: MediaStream, fps: number): Promise<CaptureInfo> {
  const track = stream.getVideoTracks()[0];
  const caps = (track?.getCapabilities?.() ?? {}) as MediaTrackCapabilities;
  const maxFps = typeof caps.frameRate?.max === "number" ? caps.frameRate.max : null;
  const current = track?.getSettings().frameRate ?? 0;
  if (track && maxFps !== null && maxFps >= fps - 1 && current < fps - 1) {
    await track.applyConstraints({ frameRate: { ideal: fps } }).catch(() => undefined);
  }
  const s = track?.getSettings() ?? {};
  return { width: s.width ?? 0, height: s.height ?? 0, fps: Math.round(s.frameRate ?? 0), maxFps };
}

/** The shared surface actually chosen (the picker may differ from `surface`). */
export function surfaceOf(stream: MediaStream): SurfaceKind {
  const s = stream.getVideoTracks()[0]?.getSettings() as MediaTrackSettings & { displaySurface?: string };
  return s?.displaySurface === "window" || s?.displaySurface === "browser" ? s.displaySurface : "monitor";
}

/** Human label for the in-recording source chip ("Entire Screen", a window title…). */
export function surfaceLabel(stream: MediaStream): string {
  const track = stream.getVideoTracks()[0];
  const kind = surfaceOf(stream);
  const label = track?.label ?? "";
  if (kind === "monitor") return label && !/^screen:/i.test(label) ? label : "Entire Screen";
  if (kind === "browser") return label && !/^web-contents-media-stream/i.test(label) ? label : "Browser Tab";
  return label && !/^window:/i.test(label) ? label : "Window";
}

/** Camera overlay stream (video only; the mic is its own stream). */
export async function openCamera(deviceId: string): Promise<MediaStream> {
  return navigator.mediaDevices.getUserMedia({
    video: {
      deviceId: { exact: deviceId },
      width: { ideal: 1280 },
      height: { ideal: 720 },
      frameRate: { ideal: 30 },
    },
    audio: false,
  });
}

/** Microphone. Voice processing stays on (echo cancellation matters with
 *  "Audio On" and speakers); gain is left alone so levels are honest. */
export async function openMic(deviceId: string | null): Promise<MediaStream> {
  return navigator.mediaDevices.getUserMedia({
    audio: {
      ...(deviceId ? { deviceId: { exact: deviceId } } : {}),
      echoCancellation: true,
      noiseSuppression: true,
      autoGainControl: false,
      channelCount: { ideal: 1 },
      sampleRate: { ideal: 48000 },
    },
    video: false,
  });
}

export function stopStream(stream: MediaStream | null | undefined): void {
  stream?.getTracks().forEach((t) => t.stop());
}

/** What this browser can do — the page adapts its chrome to it. */
export function recorderSupport(): { screen: boolean; encode: boolean; opfs: boolean; pip: boolean } {
  const g = globalThis as unknown as Record<string, unknown>;
  return {
    screen: typeof navigator !== "undefined" && typeof navigator.mediaDevices?.getDisplayMedia === "function",
    // WebCodecs (Chrome/Edge/Firefox) or MediaRecorder MP4 (Safari's engine).
    encode:
      (typeof g.VideoEncoder === "function" && typeof g.AudioEncoder === "function") ||
      (typeof g.MediaRecorder === "function" && MediaRecorder.isTypeSupported("video/mp4")),
    opfs: typeof navigator !== "undefined" && typeof navigator.storage?.getDirectory === "function",
    pip: "documentPictureInPicture" in g,
  };
}
