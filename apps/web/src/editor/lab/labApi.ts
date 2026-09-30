/**
 * DEV-ONLY test API behind `window.__lab` — what the playwright harness
 * (scripts/editor-lab/harness.mjs) drives. Pure TS, no React.
 *
 *  seekProbe   seek → snapshot → read the burned-in frame index off the pixels
 *  perf        play N seconds, return the engine's frame/decode stats
 *  parity      GPU pixels vs the CPU reference (testing/cpuReference.ts)
 *  exportCheck export with the SAME passes, compare pre-encode frames with
 *              the live preview (must be identical) and the decoded MP4
 *              (codec loss only), and verify each output frame's source index
 */
import { ALL_FORMATS, BlobSource, Input, VideoSampleSink } from "mediabunny";
import type { EngineClient } from "../engine/client";
import { cmTime600, cardGeometry, type Size } from "../engine/layout";
import { renderProjectFromJSON } from "../engine/contract";
import type { EngineStats, LoadedInfo, SnapshotResult, ViewportSpec } from "../engine/protocol";
import { rasterizeSquircle } from "../engine/shapes";
import { pixelAt, type ReferenceScene } from "../engine/testing/cpuReference";
import { FIXTURE_GEOMETRY, stripCellCenter } from "./fixtures";

export interface LabHost {
  client(): EngineClient;
  /** Loads a fixture clip + project JSON; resolves with the engine's info. */
  load(clipId: string, project: unknown): Promise<LoadedInfo>;
  /** Forces the canvas backing store (tests); null restores the responsive stage. */
  setViewport(v: ViewportSpec | null): void;
  currentProject(): unknown;
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export function decodeStrip(
  snap: SnapshotResult,
  source: Size,
): { index: number; syncOk: boolean; bits: number[]; offCanvas: boolean } {
  const vr = snap.meta.videoRect;
  const bits: number[] = [];
  let offCanvas = false;
  for (let i = 0; i < FIXTURE_GEOMETRY.cells; i++) {
    const [u, v] = stripCellCenter(i, source.width, source.height);
    const x = Math.floor(vr.x + u * vr.width);
    const y = Math.floor(vr.y + v * vr.height);
    if (x < 0 || y < 0 || x >= snap.width || y >= snap.height) {
      offCanvas = true;
      bits.push(0);
      continue;
    }
    const o = (y * snap.width + x) * 4;
    const px = new Uint8Array(snap.rgba, o, 4);
    bits.push((px[0] + px[1] + px[2]) / 3 > 127 ? 1 : 0);
  }
  let index = 0;
  for (let i = 0; i < FIXTURE_GEOMETRY.bits; i++) index |= bits[i] << i;
  const syncOk = !offCanvas && FIXTURE_GEOMETRY.sync.every((b, k) => bits[FIXTURE_GEOMETRY.bits + k] === b);
  return { index, syncOk, bits, offCanvas };
}

function diffStats(a: Uint8Array, b: Uint8Array) {
  let max = 0;
  let sum = 0;
  let over2 = 0;
  let sq = 0;
  for (let i = 0; i < a.length; i++) {
    if ((i & 3) === 3) continue; // alpha is 255 on both (opaque backgrounds)
    const d = Math.abs(a[i] - b[i]);
    if (d > max) max = d;
    if (d > 2) over2++;
    sum += d;
    sq += d * d;
  }
  const n = (a.length / 4) * 3;
  const mse = sq / n;
  return { max, mean: sum / n, over2, psnr: mse === 0 ? Infinity : 10 * Math.log10((255 * 255) / mse) };
}

export function createLabApi(host: LabHost) {
  const api = {
    stats(): EngineStats | null {
      return host.client().lastStats;
    },

    /** Drops a forced backing size (parity) and returns to the responsive stage. */
    resetViewport(): void {
      host.setViewport(null);
    },

    async seekProbe(time: number) {
      const client = host.client();
      const info = client.info!;
      const seek = await client.seek(time);
      const snap = await client.snapshot();
      const strip = decodeStrip(snap, { width: info.width, height: info.height });
      const expected = Math.floor(cmTime600(time) * info.fps + 1e-6);
      return {
        time,
        expected,
        decoded: strip.index,
        engineFrame: seek.frameIndex,
        snapFrame: snap.meta.frameIndex,
        syncOk: strip.syncOk,
        ok: strip.syncOk && strip.index === expected && snap.meta.frameIndex === expected,
      };
    },

    /**
     * Camera path (card layer + homography): with a debug zoom about a focal
     * point, the burned-in strip must still decode when every cell centre is
     * pushed through the SAME zoom the engine applies — a structural check
     * that the layer path moves the card as one plane.
     */
    async cameraProbe(time: number, zoom: number, focalX: number, focalY: number) {
      const client = host.client();
      const info = client.info!;
      await client.seek(time);
      client.debug({ camera: { zoom, focalX, focalY } });
      await sleep(100);
      const snap = await client.snapshot();
      client.debug({ camera: null });
      const vr = snap.meta.videoRect;
      const ax = vr.x + focalX * vr.width;
      const ay = vr.y + focalY * vr.height;
      const zoomed = {
        ...snap,
        meta: {
          ...snap.meta,
          videoRect: {
            x: ax + (vr.x - ax) * zoom,
            y: ay + (vr.y - ay) * zoom,
            width: vr.width * zoom,
            height: vr.height * zoom,
          },
        },
      };
      const strip = decodeStrip(zoomed, { width: info.width, height: info.height });
      const expected = Math.floor(cmTime600(time) * info.fps + 1e-6);
      // Unzoomed decode of the same pixels must FAIL (proves the zoom is real).
      const naive = decodeStrip(snap, { width: info.width, height: info.height });
      return {
        expected,
        decoded: strip.index,
        syncOk: strip.syncOk,
        offCanvas: strip.offCanvas,
        ok: strip.syncOk && strip.index === expected,
        unzoomedDecodeWouldPass: naive.syncOk && naive.index === expected,
      };
    },

    async perf(seconds: number, opts: { rate?: number; warmup?: number } = {}) {
      const client = host.client();
      await client.seek(0);
      client.setRate(opts.rate ?? 1);
      client.setLoop(true);
      client.play();
      await sleep((opts.warmup ?? 0.5) * 1000);
      client.resetStats();
      const samples: { fps: number; late: number; queue: number }[] = [];
      const t0 = performance.now();
      while (performance.now() - t0 < seconds * 1000) {
        await sleep(1000);
        const s = client.lastStats;
        if (s) samples.push({ fps: s.fps, late: s.lateFrames, queue: s.stream?.decodeQueueSize ?? 0 });
      }
      await sleep(300); // let the last stats message land
      const final = client.lastStats!;
      client.pause();
      client.setRate(1);
      return { stats: final, perSecond: samples };
    },

    /**
     * GPU vs CPU reference at a fixed backing size. Loads `clipId` with the
     * given project, seeks to `time`, snapshots, and compares ~300 sample
     * pixels grouped by what they exercise.
     */
    async parity(spec: {
      clipId: string;
      project: unknown;
      pixelWidth: number;
      pixelHeight: number;
      reference: Size | null;
      time?: number;
      forceLayer?: boolean;
    }) {
      const info = await host.load(spec.clipId, spec.project);
      const client = host.client();
      host.setViewport({
        cssWidth: spec.pixelWidth,
        cssHeight: spec.pixelHeight,
        dpr: 1,
        pixelWidth: spec.pixelWidth,
        pixelHeight: spec.pixelHeight,
        reference: spec.reference,
      });
      client.debug({ forceLayer: !!spec.forceLayer });
      await sleep(50);
      await client.seek(spec.time ?? 0.5);
      const snap = await client.snapshot();
      client.debug({ forceLayer: false });
      const settings = renderProjectFromJSON(spec.project).settings;
      const source = { width: info.width, height: info.height };
      const target = { width: snap.width, height: snap.height };
      const geometry = cardGeometry(source, target, settings, spec.reference);
      const needsSquircle = geometry.outer.kind === "squircle" || geometry.shadow?.shape === "squircle";
      const scene: ReferenceScene = {
        settings,
        geometry,
        workingSpace: info.workingSpace,
        sourceSize: source,
        squircle: needsSquircle
          ? rasterizeSquircle(geometry.videoRect, geometry.outer.kind === "squircle" ? geometry.outer.radius : geometry.shadow!.cornerRadius)
          : null,
        videoColor: [1, 1, 1, 1],
      };

      const W = snap.width;
      const H = snap.height;
      const vr = geometry.videoRect;
      const pts: { cat: string; x: number; y: number }[] = [];
      const add = (cat: string, x: number, y: number) => {
        const xi = Math.floor(x);
        const yi = Math.floor(y);
        if (xi >= 0 && yi >= 0 && xi < W && yi < H) pts.push({ cat, x: xi, y: yi });
      };
      // Background away from the card (gradient / solid).
      for (const [fx, fy] of [[0, 0], [1, 0], [0, 1], [1, 1], [0.5, 0], [0, 0.5], [1, 0.5], [0.5, 1]]) {
        add("background", 2 + fx * (W - 5), 2 + fy * (H - 5));
      }
      // Shadow falloff around the card (strongest below: the shadow is offset down).
      for (const k of [1, 2, 4, 7, 11, 16, 22, 30, 40]) {
        for (const fx of [0.02, 0.25, 0.5, 0.75, 0.98]) add("shadow", vr.x + fx * vr.width, vr.y + vr.height + k);
        for (const fy of [0.1, 0.5, 0.9]) {
          add("shadow", vr.x - k, vr.y + fy * vr.height);
          add("shadow", vr.x + vr.width + k, vr.y + fy * vr.height);
        }
        add("shadow", vr.x + 0.5 * vr.width, vr.y - k);
      }
      // Antialiased corners (+ a block around each corner arc).
      const R = Math.max(geometry.outer.radius, geometry.inner.radius, 4);
      for (const [cx, cy, sx, sy] of [
        [vr.x, vr.y, 1, 1],
        [vr.x + vr.width, vr.y, -1, 1],
        [vr.x, vr.y + vr.height, 1, -1],
        [vr.x + vr.width, vr.y + vr.height, -1, -1],
      ]) {
        for (let d = -1; d <= R * 0.6; d += 1) add("corner", cx + sx * d, cy + sy * d);
        for (let a = 0; a < R; a += Math.max(1, R / 6)) {
          add("corner", cx + sx * a, cy + sy * (R * 0.3));
          add("corner", cx + sx * (R * 0.3), cy + sy * a);
        }
      }
      // Straight card edges and the white border band inside the card.
      const band = vr.height / 16;
      for (const f of [0.3, 0.5, 0.7]) {
        for (const d of [-1, 0, 1, 2]) {
          add("edge", vr.x + f * vr.width, vr.y + d);
          add("edge", vr.x + f * vr.width, vr.y + vr.height - 1 - d);
          add("edge", vr.x + d, vr.y + f * vr.height);
          add("edge", vr.x + vr.width - 1 - d, vr.y + f * vr.height);
        }
        add("interior", vr.x + band * 0.5, vr.y + f * vr.height);
        add("interior", vr.x + vr.width - band * 0.5, vr.y + f * vr.height);
        add("interior", vr.x + f * vr.width, vr.y + vr.height - band * 0.5);
      }

      const rgba = new Uint8Array(snap.rgba);
      const byCat: Record<string, { n: number; max: number; sum: number }> = {};
      const worst: { cat: string; x: number; y: number; gpu: number[]; cpu: number[]; d: number }[] = [];
      for (const p of pts) {
        const o = (p.y * W + p.x) * 4;
        const gpu = [rgba[o], rgba[o + 1], rgba[o + 2], rgba[o + 3]];
        const cpu = pixelAt(scene, p.x, p.y).map((v) => Math.round(v * 255));
        const d = Math.max(...gpu.map((v, i) => Math.abs(v - cpu[i])));
        const c = (byCat[p.cat] ??= { n: 0, max: 0, sum: 0 });
        c.n++;
        c.sum += d;
        c.max = Math.max(c.max, d);
        worst.push({ ...p, gpu, cpu, d });
      }
      worst.sort((a, b) => b.d - a.d);
      const categories = Object.fromEntries(
        Object.entries(byCat).map(([k, v]) => [k, { n: v.n, maxDiff: v.max, meanDiff: +(v.sum / v.n).toFixed(3) }]),
      );
      const maxDiff = Math.max(0, ...worst.map((w) => w.d));
      return {
        pass: maxDiff <= 2,
        maxDiff,
        samples: pts.length,
        categories,
        worst: worst.slice(0, 6),
        geometryMatches:
          Math.abs(snap.meta.videoRect.x - vr.x) < 1e-6 && Math.abs(snap.meta.videoRect.width - vr.width) < 1e-6,
        meta: snap.meta,
        workingSpace: info.workingSpace,
        canvasColorSpace: snap.colorSpace,
        videoPath: geometry.videoScale < 0.999 ? "lanczos-fit" : "direct-bilinear",
      };
    },

    async exportCheck(opts: { seconds?: number; captureFrames?: number[]; codec?: "hevc" | "avc" | "auto" } = {}) {
      const client = host.client();
      const info = client.info!;
      const seconds = opts.seconds ?? 2;
      const snap0 = await client.snapshot();
      const width = snap0.width;
      const height = snap0.height;
      const captureFrames = opts.captureFrames ?? [0, 1, 29, 60, 119];
      const fps = 60;
      const t0 = performance.now();
      const result = await client.export({
        start: 0,
        end: seconds,
        width,
        height,
        fps,
        // No `reference`: the engine exports with the preview's own reference
        // canvas, exactly like the Mac's previewCanvasSize-scaled export.
        captureFrames,
        codec: opts.codec ?? "auto",
      });
      const exportWallMs = performance.now() - t0;
      // 1) pre-encode export frames vs the live preview canvas: must be identical.
      const previewVsExport: { frame: number; max: number; mean: number; over2: number }[] = [];
      for (const cap of result.captures) {
        await client.seek(cap.frame / fps);
        const snap = await client.snapshot();
        const d = diffStats(new Uint8Array(snap.rgba), new Uint8Array(cap.rgba));
        previewVsExport.push({ frame: cap.frame, max: d.max, mean: +d.mean.toFixed(4), over2: d.over2 });
      }
      // 2) decode the MP4 we wrote: codec loss vs pre-encode, and the burned-in index.
      const input = new Input({ formats: ALL_FORMATS, source: new BlobSource(new Blob([result.buffer])) });
      const track = (await input.getPrimaryVideoTrack())!;
      const decodedFrames = (await track.computePacketStats()).packetCount;
      const colorSpace = await track.getColorSpace();
      const sink = new VideoSampleSink(track);
      const canvas = new OffscreenCanvas(width, height);
      const ctx = canvas.getContext("2d", { colorSpace: info.workingSpace, willReadFrequently: true })!;
      const decodedVsExport: { frame: number; psnr: number; mean: number; index: number; expectedIndex: number }[] = [];
      for (const cap of result.captures) {
        const sample = await sink.getSample(cap.frame / fps + 1e-4);
        if (!sample) continue;
        sample.draw(ctx, 0, 0, width, height);
        sample.close();
        const img = ctx.getImageData(0, 0, width, height, { colorSpace: info.workingSpace });
        const dec = new Uint8Array(img.data.buffer);
        const d = diffStats(dec, new Uint8Array(cap.rgba));
        const strip = decodeStrip(
          { width, height, rgba: dec.buffer as ArrayBuffer, colorSpace: info.workingSpace, meta: snap0.meta },
          { width: info.width, height: info.height },
        );
        decodedVsExport.push({
          frame: cap.frame,
          psnr: +d.psnr.toFixed(2),
          mean: +d.mean.toFixed(3),
          index: strip.index,
          expectedIndex: result.sourceIndices[cap.frame],
        });
      }
      input.dispose();
      const expectedIdx = result.sourceIndices.every((idx, i) => idx === Math.floor(cmTime600(i / fps) * info.fps + 1e-6));
      return {
        codec: result.codec,
        size: `${result.width}x${result.height}`,
        frames: result.frames,
        muxedPackets: decodedFrames,
        bytes: result.buffer.byteLength,
        exportMs: Math.round(result.encodeMs),
        exportWallMs: Math.round(exportWallMs),
        realtimeFactor: +((seconds * 1000) / result.encodeMs).toFixed(2),
        colorTags: colorSpace,
        sourceIndicesMatchExporterRule: expectedIdx,
        previewVsExport,
        decodedVsExport,
      };
    },
  };
  return api;
}

export type LabApi = ReturnType<typeof createLabApi>;
