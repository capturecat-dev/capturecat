/// <reference lib="webworker" />
/**
 * plateWorker — a whole-display take's frames on their way to the encoder
 * (plate.ts). Created by platePipeline.ts as
 * `new Worker(new URL("./plateWorker.ts", import.meta.url), { type: "module" })`.
 *
 *   in     the share's frames (a MediaStreamTrackProcessor's readable,
 *          transferred), the plate, the floating window's geometry
 *   out    every frame drawn again on an OffscreenCanvas with the plate over
 *          the window (a MediaStreamTrackGenerator's writable, transferred) —
 *          the track mediabunny encodes
 *   check  raw frames, read back around the window (an async copyTo of a
 *          small band, at most one in flight, the newest frame waiting) and
 *          searched for the beacon. A failure posts "lost" from the last
 *          frame that passed; the page logs it on the take, which cuts it.
 *
 * Off the page's main thread so React work never delays a frame. Per frame it
 * is GPU work only (two drawImage calls and a canvas-backed VideoFrame); the
 * frame keeps its timestamp, so mediabunny's clock and first-frame zero are
 * the same as without it.
 */
import {
  RectHold,
  checkRegion,
  composite,
  plateTarget,
  toFramePixels,
  verifyPlacement,
  type Display,
  type PixelRect,
  type PlacementVerdict,
  type PlateFromWorker,
  type PlateToWorker,
  type Sized,
  type UnitRect,
  type WindowGeometry,
} from "./plate";

declare const self: DedicatedWorkerGlobalScope;

const now = () => performance.timeOrigin + performance.now();
const post = (m: PlateFromWorker) => self.postMessage(m);

/** Checks at most this often (ms) — the newest frame waits for the next slot. */
const CHECK_INTERVAL_MS = 30;
/** Read this far around the painted band (CSS px): a window just outside it is still seen. */
const CHECK_MARGIN_CSS = 24;
/** After the window closes, frames can show it for a capture latency longer (ms). */
const CLOSE_SLACK_MS = 150;

let display: Display | null = null;
let geom: WindowGeometry | null = null;
let closedAt: number | null = null;
let extended = false;
const hold = new RectHold();
let latestRect: UnitRect | null = null;
let plate: ImageBitmap | null = null;
let defect: string | null = null;
let canvas: OffscreenCanvas | null = null;
let ctx: OffscreenCanvasRenderingContext2D | null = null;
let ticker: ReturnType<typeof setInterval> | null = null;
let abort: AbortController | null = null;

interface Check {
  frame: VideoFrame;
  at: number;
  painted: PixelRect;
  geom: WindowGeometry;
  display: Display;
  size: Sized;
}
let inFlight: Promise<void> | null = null;
let pending: Check | null = null;
let pendingTimer: ReturnType<typeof setTimeout> | null = null;
let lastCheckAt = 0;
let lost = false;
let verifiedOnce = false;
let readback = new Uint8Array(0);

const stats = { frames: 0, painted: 0, checks: 0, failed: 0, maxMs: 0, sumMs: 0 };
let statsTimer: ReturnType<typeof setInterval> | null = null;

function markLost(at: number, verdict: PlacementVerdict | "unplaceable"): void {
  if (lost) return;
  lost = true;
  post({ type: "lost", at, verdict });
}

/** The first pass ever is the take's calibration; after that, only the end of a lost span. */
function markFound(at: number): void {
  if (verifiedOnce && !lost) return;
  verifiedOnce = true;
  lost = false;
  post({ type: "found", at });
}

/** Last frame that passed its check (epoch ms) — a failure is cut from just after it. */
let lastGoodAt = 0;

async function runCheck(c: Check): Promise<void> {
  try {
    const scale = c.size.width / c.display.width;
    const region = checkRegion(c.painted, c.geom, scale, CHECK_MARGIN_CSS * scale, c.size);
    if (!region) {
      markLost(lastGoodAt, "missing");
      return;
    }
    const bytes = region.w * region.h * 4;
    if (readback.byteLength < bytes) readback = new Uint8Array(bytes);
    const px = readback.subarray(0, bytes);
    await c.frame.copyTo(px, { rect: { x: region.x, y: region.y, width: region.w, height: region.h }, format: "RGBA" });
    const verdict = verifyPlacement({ px, region, painted: c.painted, frame: c.size, scale, geom: c.geom });
    stats.checks++;
    if (verdict === "ok") {
      lastGoodAt = c.at;
      markFound(c.at);
    } else {
      stats.failed++;
      markLost(lastGoodAt, verdict);
    }
  } catch {
    // A frame that can't be read can't be vouched for.
    stats.failed++;
    markLost(lastGoodAt, "missing");
  } finally {
    c.frame.close();
  }
}

function pump(): void {
  if (inFlight || !pending) return;
  const wait = CHECK_INTERVAL_MS - (now() - lastCheckAt);
  if (wait > 0) {
    pendingTimer ??= setTimeout(() => {
      pendingTimer = null;
      pump();
    }, wait);
    return;
  }
  const c = pending;
  pending = null;
  lastCheckAt = now();
  inFlight = runCheck(c).finally(() => {
    inFlight = null;
    pump();
  });
}

function queueCheck(c: Check): void {
  pending?.frame.close();
  pending = c;
  pump();
}

/** The rect painted on a frame that arrived at `at` (unit), or null. */
function rectAt(at: number): UnitRect | null {
  return defect === "no-hold" ? latestRect : hold.at(at);
}

function setGeometry(g: WindowGeometry | null, at: number, d: Display, ext: boolean): void {
  geom = g;
  display = d;
  extended = ext;
  if (!g) {
    closedAt ??= at;
    latestRect = null;
    hold.set(null, at);
    return;
  }
  closedAt = null;
  const target = plateTarget(g, d);
  // Somewhere we can't place it: keep painting where it last was (the
  // checks decide whether those frames are cut).
  if (target.kind !== "paint") return;
  latestRect = target.rect;
  hold.set(target.rect, at);
}

function draw(frame: VideoFrame, out: TransformStreamDefaultController<VideoFrame>): void {
  const t0 = performance.now();
  const at = now();
  stats.frames++;
  if (!plate) {
    out.enqueue(frame);
    return;
  }
  const size = { width: frame.displayWidth, height: frame.displayHeight };
  if (!canvas) {
    canvas = new OffscreenCanvas(size.width, size.height);
    // Keep a Display P3 capture in P3 (an sRGB canvas would clip it).
    const p3 = (frame.colorSpace?.primaries as string | null | undefined) === "smpte432";
    ctx = canvas.getContext("2d", { alpha: false, colorSpace: p3 ? "display-p3" : "srgb" });
  } else if (canvas.width !== size.width || canvas.height !== size.height) {
    canvas.width = size.width;
    canvas.height = size.height;
  }
  if (!ctx) throw new Error("No 2D canvas in this worker.");
  const unit = rectAt(at);
  const painted = unit ? toFramePixels(unit, size.width, size.height) : null;
  composite(ctx, frame, size, defect === "off" ? null : { image: plate, width: plate.width, height: plate.height }, painted);
  const output = new VideoFrame(canvas, { timestamp: frame.timestamp, duration: frame.duration ?? undefined });
  if (painted) stats.painted++;

  // Vouch for the frame.
  const placeable = geom && display && !extended && plateTarget(geom, display).kind === "paint";
  if (closedAt !== null) {
    // The window is gone; once a capture latency has passed nothing can show it.
    if (at - closedAt >= CLOSE_SLACK_MS && lost) markFound(at);
    frame.close();
  } else if (geom && !placeable) {
    markLost(lastGoodAt, "unplaceable");
    frame.close();
  } else if (geom && display && painted) {
    queueCheck({ frame, at, painted, geom, display, size });
  } else {
    frame.close();
  }
  out.enqueue(output);
  const ms = performance.now() - t0;
  stats.sumMs += ms;
  if (ms > stats.maxMs) stats.maxMs = ms;
}

function stop(): void {
  abort?.abort();
  abort = null;
  if (ticker) clearInterval(ticker);
  if (statsTimer) clearInterval(statsTimer);
  if (pendingTimer) clearTimeout(pendingTimer);
  ticker = statsTimer = pendingTimer = null;
  pending?.frame.close();
  pending = null;
  plate?.close();
  plate = null;
}

self.onmessage = (e: MessageEvent<PlateToWorker>) => {
  const m = e.data;
  switch (m.type) {
    case "start": {
      plate = m.plate;
      display = m.display;
      defect = m.defect;
      abort = new AbortController();
      // The geometry clock: the page polls the window on every tick (a
      // worker's timers aren't throttled while the page's tab is hidden).
      ticker = setInterval(() => post({ type: "tick" }), 16);
      statsTimer = setInterval(() => {
        const n = Math.max(1, stats.frames);
        post({ type: "stats", frames: stats.frames, painted: stats.painted, checks: stats.checks, failed: stats.failed, maxMs: stats.maxMs, meanMs: stats.sumMs / n });
      }, 1000);
      let faults = 0;
      m.readable
        .pipeThrough(
          new TransformStream<VideoFrame, VideoFrame>({
            transform(frame, out) {
              try {
                draw(frame, out);
                faults = 0;
              } catch (error) {
                // Never pass a raw frame on: drop it (the encoder repeats the last good one).
                frame.close();
                if (++faults > 30) throw error;
              }
            },
          }),
          { signal: abort.signal },
        )
        .pipeTo(m.writable, { signal: abort.signal })
        .catch((error: unknown) => {
          if (abort === null) return; // stopped
          post({ type: "error", message: error instanceof Error ? error.message : String(error) });
        });
      break;
    }
    case "geom":
      setGeometry(m.geom, m.at, m.display, m.extended);
      break;
    case "settle": {
      const id = m.id;
      const drain = async () => {
        for (let i = 0; i < 20 && (inFlight || pending); i++) {
          if (pendingTimer) {
            clearTimeout(pendingTimer);
            pendingTimer = null;
            lastCheckAt = 0;
            pump();
          }
          await (inFlight ?? new Promise((r) => setTimeout(r, 5)));
        }
        post({ type: "settled", id });
      };
      void drain();
      break;
    }
    case "stop":
      stop();
      self.close();
      break;
  }
};
