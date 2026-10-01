/**
 * MediaRecorderSession — the web recorder's engine for Safari.
 *
 * Why not WebCodecs there: Safari has no main-thread MediaStreamTrackProcessor,
 * so mediabunny reads frames in a worker and posts them to the page, and
 * WebKit crashes encoding those transferred frames (EXC_BREAKPOINT in
 * `SharedVideoFrameWriter::writeBuffer` under `VideoEncoder.encode`, macOS
 * 26.2 — two crash reports, 2026-09-30). Safari's MediaRecorder is its
 * native, hardware H.264/AAC path and never hands frames between threads.
 *
 * Same take as the WebCodecs engine (RecordingSession):
 *   recording.mov   screen + ONE audio track — the mic, or system audio, or
 *                   both mixed (Safari shares no system audio; a mic-only
 *                   take has the mic at track 0, exactly like the Mac's)
 *   camera.mov      the webcam, its own file, video only
 *   camera_poster.png
 * MediaRecorder writes (often fragmented) MP4; each file is REMUXED into
 * QuickTime by mediabunny — packets copied, nothing re-encoded — so the
 * editor gets a normal indexed movie. `cameraTimeOffset` = camera start −
 * screen start (the recorders' `start` events on one clock).
 */
import {
  ALL_FORMATS,
  BlobSource,
  BufferTarget,
  EncodedAudioPacketSource,
  EncodedPacketSink,
  EncodedVideoPacketSource,
  Input,
  MovOutputFormat,
  Output,
  type InputAudioTrack,
  type InputVideoTrack,
} from "mediabunny";

import { TakeTimeline, type TakeClock } from "./barHidden";
import { stopStream, surfaceLabel, surfaceOf, type SurfaceKind } from "./capture";
import {
  AUDIO_BITRATE,
  CAMERA_BITRATE,
  cameraPoster,
  fileDuration,
  persistTake,
  recordingsRoot,
  screenBitrate,
  type RecordedTake,
  type SessionState,
  type SessionStreams,
} from "./session";

// HEVC first (the Mac records HEVC; roughly twice the quality per bit of
// Safari's default Constrained-Baseline H.264), then High-profile H.264.
const SCREEN_MIMES = [
  "video/mp4;codecs=hvc1.1.6.L153.B0,mp4a.40.2",
  "video/mp4;codecs=hvc1,mp4a.40.2",
  "video/mp4;codecs=avc1.640033,mp4a.40.2",
  "video/mp4;codecs=avc1.640028,mp4a.40.2",
  "video/mp4;codecs=avc1,mp4a.40.2",
  "video/mp4",
];
const CAMERA_MIMES = [
  "video/mp4;codecs=hvc1.1.6.L123.B0",
  "video/mp4;codecs=hvc1",
  "video/mp4;codecs=avc1.640028",
  "video/mp4;codecs=avc1",
  "video/mp4",
];

function pickMime(candidates: string[]): string | null {
  if (typeof MediaRecorder === "undefined") return null;
  return candidates.find((m) => MediaRecorder.isTypeSupported(m)) ?? null;
}

/** Whether this browser can record MP4 with MediaRecorder at all. */
export function mediaRecorderMp4Supported(): boolean {
  return pickMime(SCREEN_MIMES) !== null;
}

/**
 * MP4 (fragmented or not) → an indexed QuickTime movie, packets COPIED (no
 * decode, no encode — WebKit's WebCodecs encoder is exactly what this engine
 * avoids). Every timestamp shifts so the FIRST VIDEO FRAME lands on 0, like
 * a Mac recording: Safari's first frame arrives ~40 ms after its audio, and a
 * movie whose picture starts late shows only the background at 0:00 (the
 * exporter shows no frame before the first sample). Audio packets that would
 * fall before 0 are dropped (≤ one 21 ms AAC packet of silence at the start).
 * Returns the shift so the camera offset can follow it.
 */
export async function remuxToMov(blob: Blob, name: string): Promise<{ file: File; shift: number }> {
  const input = new Input({ formats: ALL_FORMATS, source: new BlobSource(blob) });
  try {
    const video = (await input.getPrimaryVideoTrack()) as InputVideoTrack | null;
    const audio = (await input.getPrimaryAudioTrack()) as InputAudioTrack | null;
    if (!video?.codec) throw new Error(`${name}: the recording has no video.`);
    const shift = await video.getFirstTimestamp();
    const target = new BufferTarget();
    const output = new Output({ format: new MovOutputFormat(), target });
    const videoOut = new EncodedVideoPacketSource(video.codec);
    output.addVideoTrack(videoOut, { rotation: video.rotation });
    const audioOut = audio?.codec ? new EncodedAudioPacketSource(audio.codec) : null;
    if (audioOut) output.addAudioTrack(audioOut);
    await output.start();

    const copy = async (
      track: InputVideoTrack | InputAudioTrack,
      out: EncodedVideoPacketSource | EncodedAudioPacketSource,
      decoderConfig: VideoDecoderConfig | AudioDecoderConfig | null,
    ) => {
      let first = true;
      for await (const packet of new EncodedPacketSink(track).packets()) {
        const t = packet.timestamp - shift;
        if (t < -1e-6) continue; // audio ahead of the first picture
        const moved = packet.clone({ timestamp: Math.max(0, t) });
        const meta = first && decoderConfig ? { decoderConfig } : undefined;
        await (out as EncodedVideoPacketSource).add(moved, meta as EncodedVideoChunkMetadata | undefined);
        first = false;
      }
      out.close();
    };
    await Promise.all([
      copy(video, videoOut, await video.getDecoderConfig()),
      audio && audioOut ? copy(audio, audioOut, await audio.getDecoderConfig()) : Promise.resolve(),
    ]);
    await output.finalize();
    if (!target.buffer) throw new Error(`${name}: nothing was recorded.`);
    return { file: new File([target.buffer], name, { type: "video/quicktime" }), shift };
  } finally {
    input.dispose?.();
  }
}

interface Track {
  recorder: MediaRecorder;
  chunks: Blob[];
  started: Promise<number>;
  stopped: Promise<void>;
}

function record(stream: MediaStream, mimeType: string, videoBitsPerSecond: number, audio: boolean): Track {
  const recorder = new MediaRecorder(stream, {
    mimeType,
    videoBitsPerSecond,
    ...(audio ? { audioBitsPerSecond: AUDIO_BITRATE } : {}),
  });
  const chunks: Blob[] = [];
  recorder.ondataavailable = (e) => {
    if (e.data.size > 0) chunks.push(e.data);
  };
  const started = new Promise<number>((resolve, reject) => {
    recorder.onstart = () => resolve(performance.now());
    recorder.onerror = (e) => reject((e as unknown as { error?: Error }).error ?? new Error("Recording failed."));
  });
  const stopped = new Promise<void>((resolve) => {
    recorder.onstop = () => resolve();
  });
  return { recorder, chunks, started, stopped };
}

export class MediaRecorderSession {
  readonly id: string;
  state: SessionState = "idle";
  onSourceEnded: (() => void) | null = null;

  private screenRec: Track | null = null;
  private cameraRec: Track | null = null;
  private mixer: AudioContext | null = null;
  private poster: Promise<Blob | null> = Promise.resolve(null);
  private startedAt = 0;
  private pausedAt = 0;
  private pausedTotal = 0;
  private screenStart = 0;
  private cameraStart = 0;
  /** performance.now() when the screen recorder was told to start. */
  private screenCalledAt = 0;
  private size = { width: 0, height: 0 };
  private hasSystemAudio = false;
  private hasMic = false;
  private readonly timeline = new TakeTimeline();
  private readonly surface: SurfaceKind;
  private readonly label: string;

  constructor(
    private readonly streams: SessionStreams,
    _fps: number,
    id: string,
  ) {
    this.id = id;
    this.surface = surfaceOf(streams.screen);
    this.label = surfaceLabel(streams.screen);
    streams.screen.getVideoTracks()[0]?.addEventListener("ended", () => {
      if (this.state === "recording" || this.state === "paused") this.onSourceEnded?.();
    });
  }

  elapsed(now = performance.now()): number {
    if (this.state === "idle") return 0;
    const end = this.state === "paused" ? this.pausedAt : now;
    return Math.max(0, (end - this.startedAt - this.pausedTotal) / 1000);
  }

  /** One audio track: system audio and the mic mixed when both exist. */
  private audioTrack(): MediaStreamTrack | null {
    const sys = this.streams.screen.getAudioTracks()[0] ?? null;
    const mic = this.streams.mic?.getAudioTracks()[0] ?? null;
    this.hasSystemAudio = sys !== null;
    this.hasMic = mic !== null;
    if (!sys || !mic) return sys ?? mic;
    const ctx = new AudioContext({ sampleRate: 48000 });
    const dest = ctx.createMediaStreamDestination();
    ctx.createMediaStreamSource(new MediaStream([sys])).connect(dest);
    ctx.createMediaStreamSource(new MediaStream([mic])).connect(dest);
    this.mixer = ctx;
    return dest.stream.getAudioTracks()[0];
  }

  async start(): Promise<void> {
    if (this.state !== "idle") throw new Error("Session already started");
    const video = this.streams.screen.getVideoTracks()[0];
    if (!video) throw new Error("The shared screen has no video.");
    const settings = video.getSettings();
    this.size = { width: settings.width ?? 1920, height: settings.height ?? 1080 };
    const screenMime = pickMime(SCREEN_MIMES);
    if (!screenMime) throw new Error("This browser can't record MP4 video.");

    const audio = this.audioTrack();
    const screenStream = new MediaStream(audio ? [video, audio] : [video]);
    this.screenRec = record(screenStream, screenMime, screenBitrate(this.size.width, this.size.height), audio !== null);

    const camVideo = this.streams.camera?.getVideoTracks()[0];
    const camMime = camVideo ? pickMime(CAMERA_MIMES) : null;
    if (camVideo && camMime) {
      this.cameraRec = record(new MediaStream([camVideo]), camMime, CAMERA_BITRATE, false);
      this.poster = cameraPoster(this.streams.camera!);
    }

    // 1 s slices: data leaves the recorder steadily instead of all at stop.
    this.screenCalledAt = performance.now();
    this.screenRec.recorder.start(1000);
    this.cameraRec?.recorder.start(1000);
    [this.screenStart, this.cameraStart] = await Promise.all([
      this.screenRec.started,
      this.cameraRec?.started ?? Promise.resolve(0),
    ]);
    this.startedAt = performance.now();
    // Provisional media zero; stop() moves it to the first frame once the
    // file says where that is.
    this.timeline.zeroMs = this.screenCalledAt;
    this.state = "recording";
  }

  /** The page's recorder UI came on screen (true) or left it (false) at `at` (performance.now ms). */
  markUi(visible: boolean, at = performance.now()): void {
    if (visible) this.timeline.reveals.reveal(at);
    else this.timeline.reveals.conceal(at);
  }

  clock(now = performance.now()): TakeClock | null {
    return this.timeline.zeroMs === null ? null : this.timeline.clock(now, this.timeline.zeroMs);
  }

  pause(): void {
    if (this.state !== "recording") return;
    this.screenRec?.recorder.pause();
    this.cameraRec?.recorder.pause();
    this.pausedAt = performance.now();
    this.timeline.pause(this.pausedAt);
    this.state = "paused";
  }

  resume(): void {
    if (this.state !== "paused") return;
    const now = performance.now();
    this.pausedTotal += now - this.pausedAt;
    this.screenRec?.recorder.resume();
    this.cameraRec?.recorder.resume();
    this.timeline.resume(now);
    this.state = "recording";
  }

  async stop(): Promise<RecordedTake> {
    if (this.state !== "recording" && this.state !== "paused") throw new Error("Not recording");
    // No frame captured after this instant reaches the file.
    const stopAt = performance.now();
    this.state = "stopping";
    const screen = this.screenRec!;
    const cam = this.cameraRec;
    screen.recorder.stop();
    cam?.recorder.stop();
    await Promise.all([screen.stopped, cam?.stopped]);
    void this.mixer?.close();

    const screenMov = await remuxToMov(new Blob(screen.chunks, { type: screen.recorder.mimeType }), "recording.mov");
    const cameraMov = cam ? await remuxToMov(new Blob(cam.chunks, { type: cam.recorder.mimeType }), "camera.mov") : null;
    const screenFile = screenMov.file;
    const cameraFile = cameraMov?.file ?? null;
    // Each file's 0 moved to its first frame: camera 0 sits at
    // (cameraStart + cameraShift) − (screenStart + screenShift) on the screen's clock.
    const cameraTimeOffset = cameraMov
      ? Math.max(0, (this.cameraStart - this.screenStart) / 1000 + cameraMov.shift - screenMov.shift)
      : 0;
    const duration = await fileDuration(screenFile).catch(() => this.elapsed());
    // The remux put the first frame at 0. The recorder takes frames from its
    // start() call (its `start` event fires tens of ms later — measured in
    // Chrome: the file's first frame was drawn ~68 ms before it), so media
    // zero = that call + the first frame's offset in the file.
    this.timeline.zeroMs = this.screenCalledAt + screenMov.shift * 1000;
    const take: RecordedTake = {
      id: this.id,
      screen: screenFile,
      camera: cameraFile,
      poster: await this.poster,
      duration,
      cameraTimeOffset,
      surface: this.surface,
      sourceLabel: this.label,
      width: this.size.width,
      height: this.size.height,
      hasSystemAudio: this.hasSystemAudio,
      hasMic: this.hasMic,
      folder: null,
      uiReveals: this.timeline.mediaReveals(stopAt, this.screenCalledAt),
    };
    // Recovery copy on this device, where the browser allows OPFS writes.
    try {
      const root = await recordingsRoot();
      const folder = root ? await root.getDirectoryHandle(this.id, { create: true }) : null;
      if (folder) {
        await persistTake(folder, take, { movies: true });
        take.folder = this.id;
      }
    } catch {
      // No OPFS writes here (older Safari): the take lives in memory until uploaded.
    }
    this.state = "stopped";
    return take;
  }

  async discard(): Promise<void> {
    const was = this.state;
    this.state = "discarded";
    if (was === "recording" || was === "paused") {
      for (const r of [this.screenRec, this.cameraRec]) {
        if (r && r.recorder.state !== "inactive") r.recorder.stop();
      }
    }
    void this.mixer?.close();
  }

  releaseStreams(): void {
    stopStream(this.streams.screen);
    stopStream(this.streams.camera);
    stopStream(this.streams.mic);
  }
}
