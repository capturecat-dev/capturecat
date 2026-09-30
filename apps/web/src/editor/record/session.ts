/**
 * RecordingSession — one web take, written exactly like a Mac take so the
 * result is an ordinary CaptureCat project (ScreenRecorder / CameraManager /
 * ProjectStore.moveMediaIntoProjectFolder):
 *
 *   recording.mov      screen video (+ audio: system FIRST, then the mic —
 *                      ProjectAudioMix tells them apart by track index only:
 *                      track 0 = systemAudioVolume, the rest = microphone)
 *   camera.mov         webcam, video only, its own file
 *   camera_poster.png  a full-resolution camera still taken at start
 *
 * Encoding is WebCodecs through mediabunny's MediaStream sources, muxed as
 * QuickTime and streamed into the Origin Private File System so an hour-long
 * take never sits in memory (BufferTarget fallback where OPFS writes are
 * missing). The screen samples at a constant `fps` (the Mac: 60), no
 * B-frames, a keyframe every 2 s so the editor seeks fast; a window resized
 * mid-take is letterboxed into the first size ("contain"), never re-sized.
 *
 * Timing: each output zeroes at its first media chunk (mediabunny
 * "synced-zero"), so `cameraTimeOffset` = camera zero − screen zero on the
 * shared performance clock — the Mac's `cameraStart − screenStart`. Pause
 * drops frames on every source together; each source collapses the gap.
 */
import {
  BufferTarget,
  Input,
  ALL_FORMATS,
  BlobSource,
  MediaStreamAudioTrackSource,
  MediaStreamVideoTrackSource,
  MovOutputFormat,
  Output,
  StreamTarget,
  getFirstEncodableAudioCodec,
  getFirstEncodableVideoCodec,
  type AudioCodec,
  type VideoCodec,
} from "mediabunny";

import { stopStream, surfaceLabel, surfaceOf, type SurfaceKind } from "./capture";

export interface SessionStreams {
  screen: MediaStream;
  camera: MediaStream | null;
  mic: MediaStream | null;
}

export interface RecordedTake {
  /** The project's UUID (uppercase, Swift `uuidString`). */
  id: string;
  screen: File;
  camera: File | null;
  poster: Blob | null;
  /** Seconds, from the written file. */
  duration: number;
  cameraTimeOffset: number;
  surface: SurfaceKind;
  sourceLabel: string;
  width: number;
  height: number;
  hasSystemAudio: boolean;
  hasMic: boolean;
  /** OPFS folder holding the files (removed by `discardTakeFiles`). */
  folder: string | null;
}

export type SessionState = "idle" | "recording" | "paused" | "stopping" | "stopped" | "discarded";

/** The Mac's screen bitrate (ScreenRecorder: 20 Mbps HEVC); scaled down for small captures. */
export function screenBitrate(width: number, height: number): number {
  const px = width * height;
  if (px >= 2560 * 1440) return 20_000_000;
  if (px >= 1920 * 1080) return 14_000_000;
  return 8_000_000;
}

/** The Mac's camera bitrate (CameraManager: 6 Mbps H.264). */
export const CAMERA_BITRATE = 6_000_000;
export const AUDIO_BITRATE = 128_000;
const KEYFRAME_SECONDS = 2;

interface OutputSink {
  output: Output;
  target: BufferTarget | StreamTarget;
  writable: FileSystemWritableFileStream | null;
  handle: FileSystemFileHandle | null;
  name: string;
}

export async function recordingsRoot(): Promise<FileSystemDirectoryHandle | null> {
  try {
    const root = await navigator.storage.getDirectory();
    return await root.getDirectoryHandle("capturecat-recordings", { create: true });
  } catch {
    return null;
  }
}

/**
 * First-use stalls, measured in Chrome: the page's FIRST take dropped to
 * ~12 fps for its opening seconds (later takes: a steady 60) while the
 * hardware H.264 encoder spun up; AAC and OPFS have first-use costs too. The
 * recorder page warms all three while the person is still choosing a source;
 * `start()` awaits the same promise (free once warm).
 */
let warmed: Promise<void> | null = null;
export function warmRecorder(opts: { encoders?: boolean } = {}): Promise<void> {
  const encoders = opts.encoders ?? true;
  warmed ??= (async () => {
    const tasks: Promise<unknown>[] = [];
    tasks.push(
      (async () => {
        const root = await recordingsRoot();
        if (!root) return;
        const w = await (await root.getFileHandle(".warm", { create: true })).createWritable();
        await w.write(new Uint8Array(1));
        await w.close();
        await root.removeEntry(".warm").catch(() => undefined);
      })(),
    );
    if (encoders && typeof AudioEncoder === "function") {
      tasks.push(
        (async () => {
          const enc = new AudioEncoder({ output: () => undefined, error: () => undefined });
          enc.configure({ codec: "mp4a.40.2", sampleRate: 48000, numberOfChannels: 2, bitrate: 128_000 });
          enc.encode(new AudioData({ format: "f32", sampleRate: 48000, numberOfFrames: 1024, numberOfChannels: 2, timestamp: 0, data: new Float32Array(2048) }));
          await enc.flush();
          enc.close();
        })(),
      );
    }
    if (encoders && typeof VideoEncoder === "function") {
      tasks.push(
        (async () => {
          // Full-HD: small sizes take Chrome's software encoder; the slow
          // first start is the hardware path the real take uses.
          const enc = new VideoEncoder({ output: () => undefined, error: () => undefined });
          // Exactly what mediabunny asks for on a live source (realtime, VBR,
          // AVC framing) — a quality-mode warm-up spins up a different encoder.
          enc.configure({
            codec: "avc1.640028",
            width: 1920,
            height: 1080,
            bitrate: 14_000_000,
            bitrateMode: "variable",
            framerate: 60,
            latencyMode: "realtime",
            avc: { format: "avc" },
          });
          const canvas = new OffscreenCanvas(1920, 1080);
          canvas.getContext("2d")?.fillRect(0, 0, 1920, 1080);
          const frame = new VideoFrame(canvas, { timestamp: 0 });
          enc.encode(frame, { keyFrame: true });
          frame.close();
          await enc.flush();
          enc.close();
        })(),
      );
    }
    await Promise.allSettled(tasks);
  })();
  return warmed;
}

/**
 * Write a finished take's recovery record into its OPFS folder: the poster,
 * `take.json` (the facts the files can't carry) and — for engines that
 * produce the movies in memory — the movies themselves.
 */
export async function persistTake(
  folder: FileSystemDirectoryHandle,
  take: RecordedTake,
  opts: { movies: boolean },
): Promise<void> {
  const write = async (name: string, data: Blob | string) => {
    const w = await (await folder.getFileHandle(name, { create: true })).createWritable();
    await w.write(data);
    await w.close();
  };
  if (opts.movies) {
    await write("recording.mov", take.screen);
    if (take.camera) await write("camera.mov", take.camera);
  }
  if (take.poster) await write("camera_poster.png", take.poster);
  const { screen: _s, camera: _c, poster: _p, ...meta } = take;
  await write("take.json", JSON.stringify({ ...meta, createdAt: Date.now() } satisfies TakeMeta));
}

/** Remove a take's OPFS folder (after upload, or on discard). */
export async function discardTakeFiles(folder: string | null): Promise<void> {
  if (!folder) return;
  const root = await recordingsRoot();
  await root?.removeEntry(folder, { recursive: true }).catch(() => undefined);
}

/** What `take.json` keeps beside a finished take's files (for recovery). */
type TakeMeta = Omit<RecordedTake, "screen" | "camera" | "poster"> & { createdAt: number };

/**
 * Finished takes still on this device — left by a closed tab, a failed or
 * cancelled upload. Newest first. A folder without take.json is a take in
 * progress (maybe in another tab) or one a closed tab cut off mid-recording
 * (no index, unplayable): skipped, and removed only once a day old.
 */
export async function leftoverTakes(): Promise<RecordedTake[]> {
  const root = await recordingsRoot();
  if (!root) return [];
  const out: Array<RecordedTake & { createdAt: number }> = [];
  for await (const [name, handle] of root as unknown as AsyncIterable<[string, FileSystemHandle]>) {
    if (handle.kind !== "directory") continue;
    const dir = handle as FileSystemDirectoryHandle;
    try {
      const meta = JSON.parse(await (await (await dir.getFileHandle("take.json")).getFile()).text()) as TakeMeta;
      const file = async (n: string, type: string) => {
        const f = await (await dir.getFileHandle(n)).getFile();
        return new File([f], n, { type });
      };
      const screen = await file("recording.mov", "video/quicktime");
      const camera = await file("camera.mov", "video/quicktime").catch(() => null);
      const poster = await file("camera_poster.png", "image/png").catch(() => null);
      out.push({ ...meta, screen, camera, poster, folder: name });
    } catch {
      const touched = await dir
        .getFileHandle("recording.mov")
        .then((h) => h.getFile())
        .then((f) => f.lastModified)
        .catch(() => 0);
      if (Date.now() - touched > 24 * 3600 * 1000) await root.removeEntry(name, { recursive: true }).catch(() => undefined);
    }
  }
  return out.sort((a, b) => b.createdAt - a.createdAt);
}

async function sinkFor(folder: FileSystemDirectoryHandle | null, name: string): Promise<OutputSink> {
  if (folder) {
    try {
      const handle = await folder.getFileHandle(name, { create: true });
      const writable = await handle.createWritable();
      const target = new StreamTarget(writable as unknown as WritableStream, { chunked: true });
      return { output: new Output({ format: new MovOutputFormat(), target }), target, writable, handle, name };
    } catch {
      // Safari without createWritable, private windows: fall through to memory.
    }
  }
  const target = new BufferTarget();
  return { output: new Output({ format: new MovOutputFormat(), target }), target, writable: null, handle: null, name };
}

async function sinkFile(sink: OutputSink, type: string): Promise<File> {
  if (sink.handle) {
    const f = await sink.handle.getFile();
    return new File([f], sink.name, { type });
  }
  const buf = (sink.target as BufferTarget).buffer;
  if (!buf) throw new Error(`${sink.name}: nothing was written`);
  return new File([buf], sink.name, { type });
}

/** Full-resolution still of the camera (the Mac's camera_poster.png). */
export async function cameraPoster(stream: MediaStream): Promise<Blob | null> {
  const track = stream.getVideoTracks()[0];
  if (!track) return null;
  const video = document.createElement("video");
  video.muted = true;
  video.playsInline = true;
  video.srcObject = new MediaStream([track]);
  try {
    await video.play();
    if (video.readyState < 2) await new Promise((r) => video.addEventListener("loadeddata", r, { once: true }));
    const w = video.videoWidth;
    const h = video.videoHeight;
    if (!w || !h) return null;
    const canvas = new OffscreenCanvas(w, h);
    canvas.getContext("2d")!.drawImage(video, 0, 0, w, h);
    return await canvas.convertToBlob({ type: "image/png" });
  } catch {
    return null;
  } finally {
    video.pause();
    video.srcObject = null;
  }
}

export async function fileDuration(file: File): Promise<number> {
  const input = new Input({ formats: ALL_FORMATS, source: new BlobSource(file) });
  try {
    return await input.computeDuration();
  } finally {
    input.dispose?.();
  }
}

export class RecordingSession {
  readonly id: string;
  state: SessionState = "idle";
  /** Fired once when the screen share ends from outside (the browser's "Stop sharing"). */
  onSourceEnded: (() => void) | null = null;

  private screenSink: OutputSink | null = null;
  private cameraSink: OutputSink | null = null;
  private folderHandle: FileSystemDirectoryHandle | null = null;
  private videoSources: MediaStreamVideoTrackSource[] = [];
  private audioSources: MediaStreamAudioTrackSource[] = [];
  private poster: Promise<Blob | null> = Promise.resolve(null);
  private startedAt = 0;
  private pausedAt = 0;
  private pausedTotal = 0;
  private size = { width: 0, height: 0 };
  private hasSystemAudio = false;
  private hasMic = false;
  private readonly surface: SurfaceKind;
  private readonly label: string;

  constructor(
    private readonly streams: SessionStreams,
    private readonly fps: number,
    id: string,
  ) {
    this.id = id;
    this.surface = surfaceOf(streams.screen);
    this.label = surfaceLabel(streams.screen);
    const track = streams.screen.getVideoTracks()[0];
    track?.addEventListener("ended", () => {
      if (this.state === "recording" || this.state === "paused") this.onSourceEnded?.();
    });
  }

  /** Recording time so far (pauses excluded), seconds. */
  elapsed(now = performance.now()): number {
    if (this.state === "idle") return 0;
    const end = this.state === "paused" ? this.pausedAt : now;
    return Math.max(0, (end - this.startedAt - this.pausedTotal) / 1000);
  }

  async start(): Promise<void> {
    if (this.state !== "idle") throw new Error("Session already started");
    const screenTrack = this.streams.screen.getVideoTracks()[0];
    if (!screenTrack) throw new Error("The shared screen has no video.");
    const settings = screenTrack.getSettings();
    const width = Math.max(2, Math.round((settings.width ?? 1920) / 2) * 2);
    const height = Math.max(2, Math.round((settings.height ?? 1080) / 2) * 2);
    this.size = { width, height };

    const videoCodec: VideoCodec | null = await getFirstEncodableVideoCodec(["avc", "hevc", "vp9"], {
      width,
      height,
      bitrate: screenBitrate(width, height),
    });
    if (!videoCodec) throw new Error("This browser cannot encode video (WebCodecs H.264/HEVC/VP9 unavailable).");
    const audioCodec: AudioCodec | null = await getFirstEncodableAudioCodec(["aac", "opus"], {
      numberOfChannels: 2,
      sampleRate: 48000,
      bitrate: AUDIO_BITRATE,
    });

    await warmRecorder();
    const root = await recordingsRoot();
    this.folderHandle = root ? await root.getDirectoryHandle(this.id, { create: true }) : null;

    // ── recording.mov: screen video, then system audio (track 0), then mic.
    const screen = await sinkFor(this.folderHandle, "recording.mov");
    const video = new MediaStreamVideoTrackSource(
      screenTrack as MediaStreamVideoTrack,
      {
        codec: videoCodec,
        bitrate: screenBitrate(width, height),
        keyFrameInterval: KEYFRAME_SECONDS,
        sizeChangeBehavior: "contain",
        latencyMode: "quality",
      },
      { frameRate: this.fps },
    );
    screen.output.addVideoTrack(video, { frameRate: this.fps });
    this.videoSources.push(video);
    const systemTrack = this.streams.screen.getAudioTracks()[0];
    if (systemTrack && audioCodec) {
      const sys = new MediaStreamAudioTrackSource(systemTrack as MediaStreamAudioTrack, {
        codec: audioCodec,
        bitrate: AUDIO_BITRATE,
      });
      screen.output.addAudioTrack(sys, { name: "System Audio" });
      this.audioSources.push(sys);
      this.hasSystemAudio = true;
    }
    const micTrack = this.streams.mic?.getAudioTracks()[0];
    if (micTrack && audioCodec) {
      const mic = new MediaStreamAudioTrackSource(micTrack as MediaStreamAudioTrack, {
        codec: audioCodec,
        bitrate: AUDIO_BITRATE,
      });
      screen.output.addAudioTrack(mic, { name: "Microphone" });
      this.audioSources.push(mic);
      this.hasMic = true;
    }
    this.screenSink = screen;

    // ── camera.mov: its own file, video only (CameraManager).
    const camTrack = this.streams.camera?.getVideoTracks()[0];
    if (camTrack) {
      const camCodec = (await getFirstEncodableVideoCodec(["avc", "hevc", "vp9"], { bitrate: CAMERA_BITRATE })) ?? videoCodec;
      const cam = await sinkFor(this.folderHandle, "camera.mov");
      const camSource = new MediaStreamVideoTrackSource(
        camTrack as MediaStreamVideoTrack,
        { codec: camCodec, bitrate: CAMERA_BITRATE, keyFrameInterval: KEYFRAME_SECONDS, sizeChangeBehavior: "contain" },
        { frameRate: 30 },
      );
      cam.output.addVideoTrack(camSource, { frameRate: 30 });
      this.videoSources.push(camSource);
      this.cameraSink = cam;
      this.poster = cameraPoster(this.streams.camera!);
    }

    // Start together: both outputs zero at their first chunk on one clock.
    await Promise.all([screen.output.start(), this.cameraSink?.output.start()]);
    // The take is live once every picture source has a frame: pausing a
    // source that has none yet breaks it (mediabunny asserts its first-frame
    // timestamp), and the clock should not run over a black first second.
    await this.firstFrames(3000);
    this.startedAt = performance.now();
    this.state = "recording";
  }

  private async firstFrames(timeoutMs: number): Promise<void> {
    const t0 = performance.now();
    const seen = () =>
      this.videoSources.every((v) => (v as unknown as { _lastVideoFrame?: VideoFrame | null })._lastVideoFrame != null);
    while (!seen() && performance.now() - t0 < timeoutMs) await new Promise((r) => setTimeout(r, 10));
  }

  pause(): void {
    if (this.state !== "recording") return;
    for (const s of [...this.videoSources, ...this.audioSources]) s.pause();
    this.pausedAt = performance.now();
    this.state = "paused";
  }

  resume(): void {
    if (this.state !== "paused") return;
    this.pausedTotal += performance.now() - this.pausedAt;
    for (const s of [...this.videoSources, ...this.audioSources]) s.resume();
    this.state = "recording";
  }

  /** Finish the files. The capture streams stay open (the page releases them). */
  async stop(): Promise<RecordedTake> {
    if (this.state !== "recording" && this.state !== "paused") throw new Error("Not recording");
    this.state = "stopping";
    const screen = this.screenSink!;
    const cam = this.cameraSink;
    const firstOf = (o: Output | undefined) =>
      (o as unknown as { _firstMediaStreamTimestamp?: number | null } | undefined)?._firstMediaStreamTimestamp ?? null;
    // finalize() also closes the OPFS stream (StreamTarget holds its writer).
    await Promise.all([screen.output.finalize(), cam?.output.finalize()]);

    const screenZero = firstOf(screen.output);
    const camZero = firstOf(cam?.output);
    const cameraTimeOffset = cam && screenZero !== null && camZero !== null ? Math.max(0, camZero - screenZero) : 0;

    const screenFile = await sinkFile(screen, "video/quicktime");
    const cameraFile = cam ? await sinkFile(cam, "video/quicktime") : null;
    const duration = await fileDuration(screenFile).catch(() => this.elapsed());
    const poster = await this.poster;
    const take: RecordedTake = {
      id: this.id,
      screen: screenFile,
      camera: cameraFile,
      poster,
      duration,
      cameraTimeOffset,
      surface: this.surface,
      sourceLabel: this.label,
      width: this.size.width,
      height: this.size.height,
      hasSystemAudio: this.hasSystemAudio,
      hasMic: this.hasMic,
      folder: this.folderHandle ? this.id : null,
    };
    if (this.folderHandle) await persistTake(this.folderHandle, take, { movies: false });
    this.state = "stopped";
    return take;
  }

  /** Throw the take away (Restart / Delete). */
  async discard(): Promise<void> {
    const was = this.state;
    this.state = "discarded";
    if (was === "recording" || was === "paused" || was === "stopping") {
      await Promise.all([this.screenSink?.output.cancel(), this.cameraSink?.output.cancel()]).catch(() => undefined);
    }
    await discardTakeFiles(this.folderHandle ? this.id : null);
  }

  /** Release every capture track (the share, camera and mic indicators go away). */
  releaseStreams(): void {
    stopStream(this.streams.screen);
    stopStream(this.streams.camera);
    stopStream(this.streams.mic);
  }
}
