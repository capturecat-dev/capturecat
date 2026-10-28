/**
 * PlatePipeline — the page side of the clean plate (plate.ts): it puts
 * plateWorker.ts between a whole-display share and the encoder, feeds it the
 * floating window's geometry, and logs every span the worker couldn't vouch
 * for on the take (TakeRecorder.markUi, source "plate"), which the new
 * project cuts like a reveal of the bar (barHidden.ts).
 *
 *   share track ─▶ MediaStreamTrackProcessor ─▶ worker (plate over the
 *   window) ─▶ MediaStreamTrackGenerator `track` ─▶ RecordingSession
 *
 * WebCodecs engine only (Chrome, Edge — where Document Picture-in-Picture
 * exists). Safari's MediaRecorder engine never processes frames: a display
 * take there hides the bar and cuts (barHidden.ts "reveal").
 */
import { recorderProbe } from "./barHidden";
import { capturedDisplay, type Display, type PlateFromWorker, type PlateToWorker, type WindowGeometry } from "./plate";
import type { TakeRecorder } from "./takeRecorder";

/** How long the floating window gets to be seen on the shared screen where it's reported (ms). */
export const CALIBRATE_MS = 2500;
/** How long to wait for a fresh frame of the display for the plate (ms). */
const PLATE_FRAME_MS = 1500;
/** After the first fresh frame, newer ones are taken for this long (ms). */
const PLATE_DRAIN_MS = 120;

/** The browser can put a step between a track and the encoder (main-thread processor + generator). */
export function plateSupported(): boolean {
  const g = globalThis as unknown as Record<string, unknown>;
  return (
    typeof g.MediaStreamTrackProcessor === "function" &&
    typeof g.MediaStreamTrackGenerator === "function" &&
    typeof g.OffscreenCanvas === "function" &&
    typeof g.VideoFrame === "function" &&
    typeof g.Worker === "function"
  );
}

/**
 * The display a whole-screen share shows, in the coordinates the floating
 * window reports — null when that isn't certain (several displays; plate.ts).
 */
export function displayForShare(stream: MediaStream): Display | null {
  if (typeof window === "undefined") return null;
  const s = stream.getVideoTracks()[0]?.getSettings() ?? {};
  const scr = window.screen as Screen & { isExtended?: boolean };
  return capturedDisplay({ width: scr.width, height: scr.height, isExtended: scr.isExtended }, { width: s.width ?? 0, height: s.height ?? 0 });
}

/**
 * The plate: the display as it is NOW, read through a new sink on a clone of
 * the share — a new sink makes the capturer send the current screen even when
 * nothing on it is changing. Call it once the page's recorder UI has left the
 * screen and the capture pipeline (useConceal's `ready`): then no frame it
 * can return shows any of it.
 */
export async function grabPlate(track: MediaStreamTrack, timeoutMs = PLATE_FRAME_MS): Promise<{ bitmap: ImageBitmap; at: number } | null> {
  const clone = track.clone();
  const reader = new MediaStreamTrackProcessor({ track: clone as MediaStreamVideoTrack }).readable.getReader();
  const read = (ms: number) =>
    Promise.race([reader.read(), new Promise<null>((r) => setTimeout(() => r(null), ms))]).then((r) => (r && !r.done ? r.value : null));
  let newest: VideoFrame | null = null;
  try {
    const first = await read(timeoutMs);
    if (!first) return null;
    let frame: VideoFrame = first;
    newest = frame;
    // Anything newer that is already on its way is newer still.
    const until = performance.now() + PLATE_DRAIN_MS;
    for (let left = PLATE_DRAIN_MS; left > 0; left = until - performance.now()) {
      const next = await read(left);
      if (!next) break;
      frame.close();
      frame = next;
      newest = next;
    }
    const at = performance.now();
    return { bitmap: await createImageBitmap(frame), at };
  } catch {
    return null;
  } finally {
    newest?.close();
    void reader.cancel().catch(() => undefined);
    clone.stop();
  }
}

function geometryOf(win: Window): WindowGeometry {
  return {
    x: win.screenX,
    y: win.screenY,
    width: win.outerWidth,
    height: win.outerHeight,
    innerWidth: win.innerWidth,
    innerHeight: win.innerHeight,
  };
}

export class PlatePipeline {
  /** What the take encodes in place of the share's own video track. */
  readonly track: MediaStreamVideoTrackGenerator;
  /** The worker gave up: the take can't be vouched for any more (stop it). */
  onError: ((message: string) => void) | null = null;

  private readonly worker: Worker;
  private win: Window | null = null;
  private session: TakeRecorder | null = null;
  /** performance.now() ms from which frames weren't vouched for; null = all good. */
  private lostAt: number | null = null;
  private verified = false;
  private onVerified: (() => void) | null = null;
  private lastGeom = "";
  private settles = new Map<number, () => void>();
  private nextSettle = 1;
  private disposed = false;

  constructor(
    source: MediaStreamTrack,
    plate: ImageBitmap,
    private readonly display: Display,
  ) {
    this.track = new MediaStreamTrackGenerator({ kind: "video" });
    const processor = new MediaStreamTrackProcessor({ track: source as MediaStreamVideoTrack });
    this.worker = new Worker(new URL("./plateWorker.ts", import.meta.url), { type: "module", name: "capturecat-plate" });
    this.worker.onmessage = (e: MessageEvent<PlateFromWorker>) => this.receive(e.data);
    this.worker.onerror = (e) => this.fail(e.message || "The recording's frame worker stopped.");
    const defect = import.meta.env.DEV ? ((globalThis as { __ccPlateDefect?: string }).__ccPlateDefect ?? null) : null;
    const start: PlateToWorker = { type: "start", readable: processor.readable, writable: this.track.writable, plate, display, defect };
    this.worker.postMessage(start, [processor.readable, this.track.writable, plate]);
    recorderProbe("plate-start", { display, defect });
  }

  /**
   * Follow `win` (the floating controls). Resolves true once the worker has
   * found it on the shared screen exactly where it's reported — the proof the
   * mapping holds on this machine — false after `timeoutMs`.
   */
  watch(win: Window, timeoutMs = CALIBRATE_MS): Promise<boolean> {
    this.win = win;
    this.poll();
    if (this.verified) return Promise.resolve(true);
    return new Promise((resolve) => {
      const t = window.setTimeout(() => {
        this.onVerified = null;
        resolve(false);
      }, timeoutMs);
      this.onVerified = () => {
        window.clearTimeout(t);
        resolve(true);
      };
    });
  }

  /** The take whose frames this feeds (null between takes): unvouched spans are logged on it. */
  attach(session: TakeRecorder | null): void {
    this.session = session;
    if (session && this.lostAt !== null) session.markUi(true, this.lostAt, "plate");
  }

  /** Wait for the checks in flight, so a take stopped now has every span logged. */
  settle(timeoutMs = 400): Promise<void> {
    if (this.disposed) return Promise.resolve();
    const id = this.nextSettle++;
    return new Promise((resolve) => {
      const t = window.setTimeout(() => {
        this.settles.delete(id);
        resolve();
      }, timeoutMs);
      this.settles.set(id, () => {
        window.clearTimeout(t);
        resolve();
      });
      this.worker.postMessage({ type: "settle", id } satisfies PlateToWorker);
    });
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    this.win = null;
    this.session = null;
    this.onVerified = null;
    try {
      this.worker.postMessage({ type: "stop" } satisfies PlateToWorker);
    } catch {
      // already gone
    }
    window.setTimeout(() => this.worker.terminate(), 500);
    this.track.stop();
    for (const done of this.settles.values()) done();
    this.settles.clear();
  }

  private poll(): void {
    const win = this.win;
    if (!win || this.disposed) return;
    const closed = win.closed;
    const geom = closed ? null : geometryOf(win);
    // The page's screen: with one display it is the window's too; a second
    // display appearing mid-take turns `extended` on (nothing is placed then).
    const scr = window.screen as Screen & { isExtended?: boolean };
    const display: Display = { left: this.display.left, top: this.display.top, width: scr.width, height: scr.height };
    const extended = scr.isExtended !== false;
    const key = JSON.stringify([geom, display.width, display.height, extended]);
    if (key === this.lastGeom) return;
    this.lastGeom = key;
    const at = performance.timeOrigin + performance.now();
    this.worker.postMessage({ type: "geom", geom, at, display, extended } satisfies PlateToWorker);
    recorderProbe("plate-geom", { geom, at: at - performance.timeOrigin, extended });
    if (closed) this.win = null;
  }

  private receive(m: PlateFromWorker): void {
    if (this.disposed) return;
    const perf = (epoch: number) => Math.min(performance.now(), epoch - performance.timeOrigin);
    switch (m.type) {
      case "tick":
        this.poll();
        break;
      case "found": {
        const at = perf(m.at);
        if (!this.verified) {
          this.verified = true;
          this.onVerified?.();
          this.onVerified = null;
        }
        if (this.lostAt !== null) this.session?.markUi(false, at, "plate");
        this.lostAt = null;
        recorderProbe("plate-found", { at });
        break;
      }
      case "lost": {
        const at = perf(m.at);
        this.lostAt = at;
        this.session?.markUi(true, at, "plate");
        recorderProbe("plate-lost", { at, verdict: m.verdict });
        break;
      }
      case "settled":
        this.settles.get(m.id)?.();
        this.settles.delete(m.id);
        break;
      case "stats":
        recorderProbe("plate-stats", { ...m });
        break;
      case "error":
        this.fail(m.message);
        break;
    }
  }

  private fail(message: string): void {
    if (this.disposed) return;
    recorderProbe("plate-error", { message });
    this.onError?.(message);
  }
}
