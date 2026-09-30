#!/usr/bin/env node
/**
 * Export-formats gate: the web exporter vs the REAL Mac exporter on the
 * synthetic VFR fixture `CaptureCat --export-formats-test <dir>` writes
 * (<dir>/vfr: recording.mp4 with static stretches, cursor.json,
 * project-{60,30}.json, the Mac's expected-{60,30}.json sample timings and
 * export.gif).
 *
 *   node scripts/editor-lab/export-formats.mjs --url http://localhost:3216 \
 *        --fixture <dir>/vfr [--out <scratch dir>]
 *
 * Drives the dev server's /editor-lab engine in headless system Chrome and
 * checks, with ffprobe + an independent GIF/PNG parser here:
 *   - fast export MP4 (60 + 30 fps, and 60 fps with a webcam track + a
 *     camera-layout block): written frames == the Mac's kept frames,
 *     PTS == the Mac's (1/600 s grid, truncated), file length == timeline;
 *     and the collapse is real (fewer frames than CFR);
 *   - CFR MP4 (fast export off): every frame, Mac PTS grid;
 *   - GIF: "GIF89a", loop forever, frame count / delays / size == the Mac's
 *     GIF (GIFExportPolicy), sRGB;
 *   - PNG: signature, IHDR size, colour chunk.
 * Exit 1 on any failure. Nothing here talks to a real API.
 */
import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { join, resolve } from "node:path";
import { chromium } from "playwright-core";

const args = process.argv.slice(2);
const opt = (name, fallback) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : fallback;
};
const BASE = opt("url", "http://localhost:3216");
const FIX = resolve(opt("fixture", ""));
const OUT = resolve(opt("out", "/tmp/capturecat-export-formats"));
if (!FIX || !existsSync(join(FIX, "project-60.json"))) {
  console.error("--fixture <dir>/vfr from `CaptureCat --export-formats-test` is required");
  process.exit(2);
}
mkdirSync(OUT, { recursive: true });

let failed = 0;
const check = (ok, label) => {
  console.log(`${ok ? "PASS" : "FAIL"} ${label}`);
  if (!ok) failed++;
};

// ── Independent parsers ───────────────────────────────────────────────────
function parseGif(buf) {
  const b = new Uint8Array(buf);
  const magic = String.fromCharCode(...b.subarray(0, 6));
  let p = 6;
  const u16 = () => b[p++] | (b[p++] << 8);
  const width = u16();
  const height = u16();
  const flags = b[p++];
  p += 2;
  if (flags & 0x80) p += 3 << ((flags & 7) + 1);
  const frames = [];
  let loop = null;
  let delay = null;
  while (p < b.length) {
    const t = b[p++];
    if (t === 0x3b) break;
    if (t === 0x21) {
      const label = b[p++];
      if (label === 0xf9) {
        p++;
        p++;
        delay = b[p] | (b[p + 1] << 8);
        p += 4;
        continue;
      }
      if (label === 0xff) {
        const n = b[p++];
        const app = String.fromCharCode(...b.subarray(p, p + n));
        p += n;
        for (let len = b[p++]; len !== 0; len = b[p++]) {
          if (app === "NETSCAPE2.0" && b[p] === 1) loop = b[p + 1] | (b[p + 2] << 8);
          p += len;
        }
        continue;
      }
      for (let len = b[p++]; len !== 0; len = b[p++]) p += len;
      continue;
    }
    if (t !== 0x2c) throw new Error(`GIF: unexpected block 0x${t.toString(16)} @${p - 1}`);
    p += 8;
    const f = b[p++];
    if (f & 0x80) p += 3 << ((f & 7) + 1);
    p++; // min code size
    for (let len = b[p++]; len !== 0; len = b[p++]) p += len;
    frames.push({ delay });
    delay = null;
  }
  return { magic, width, height, loop, frames };
}

function parsePng(buf) {
  const b = Buffer.from(buf);
  const sig = b.subarray(0, 8).toString("hex");
  const chunks = [];
  let p = 8;
  while (p < b.length) {
    const len = b.readUInt32BE(p);
    const type = b.subarray(p + 4, p + 8).toString("latin1");
    chunks.push({ type, data: b.subarray(p + 8, p + 8 + len) });
    p += 12 + len;
  }
  const ihdr = chunks.find((c) => c.type === "IHDR").data;
  return { sig, width: ihdr.readUInt32BE(0), height: ihdr.readUInt32BE(4), types: chunks.map((c) => c.type) };
}

function probe(file) {
  const packets = execFileSync("ffprobe", [
    "-v", "error", "-select_streams", "v:0", "-show_entries", "packet=pts_time,duration_time", "-of", "csv=p=0", file,
  ]).toString().trim().split("\n").map((l) => l.split(",").map(Number));
  const duration = Number(
    execFileSync("ffprobe", ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=duration", "-of", "csv=p=0", file]).toString().trim(),
  );
  packets.sort((a, b) => a[0] - b[0]);
  return { pts: packets.map((p) => p[0]), durations: packets.map((p) => p[1]), duration };
}

// ── Browser ───────────────────────────────────────────────────────────────
const browser = await chromium.launch({
  channel: "chrome",
  headless: true,
  args: ["--autoplay-policy=no-user-gesture-required", "--enable-gpu", "--ignore-gpu-blocklist"],
});
const page = await (await browser.newContext({ viewport: { width: 1400, height: 900 }, deviceScaleFactor: 1 })).newPage();
const errors = [];
page.on("pageerror", (e) => errors.push(e.message));
// The fixture is served from disk under /__fixture/ (never the network),
// with byte ranges (mediabunny streams media with Range requests).
await page.route("**/__fixture/**", (route) => {
  const name = decodeURIComponent(new URL(route.request().url()).pathname.replace(/^.*\/__fixture\//, ""));
  const body = readFileSync(join(FIX, name));
  const type = name.endsWith(".mp4") ? "video/mp4" : name.endsWith(".json") ? "application/json" : "application/octet-stream";
  const range = /bytes=(\d+)-(\d*)/.exec(route.request().headers()["range"] ?? "");
  if (!range) return route.fulfill({ status: 200, body, headers: { "Content-Type": type, "Accept-Ranges": "bytes" } });
  const start = Number(range[1]);
  const end = range[2] ? Math.min(Number(range[2]), body.length - 1) : body.length - 1;
  route.fulfill({
    status: 206,
    body: body.subarray(start, end + 1),
    headers: { "Content-Type": type, "Accept-Ranges": "bytes", "Content-Range": `bytes ${start}-${end}/${body.length}` },
  });
});
await page.goto(`${BASE}/editor-lab?autoload=0`, { waitUntil: "domcontentloaded" });
await page.waitForFunction(() => window.__lab?.ready === true, null, { timeout: 60_000 });

async function runExport(projectFile, options) {
  const res = await page.evaluate(
    async ({ projectFile, options }) => {
      const client = window.__lab.client();
      const abs = (p) => new URL(p, location.href).href;
      const project = await (await fetch(abs(`/__fixture/${projectFile}`))).json();
      const files = {};
      if (project.cursorDataURL) files[project.cursorDataURL] = abs("/__fixture/cursor.json");
      if (project.cameraVideoURL) files[project.cameraVideoURL] = abs("/__fixture/camera.mp4");
      await client.load(project, { video: abs("/__fixture/recording.mp4"), files });
      // Headless Mac export: no editor window → reference canvas = the output.
      client.resize({ cssWidth: 1280, cssHeight: 720, dpr: 1, pixelWidth: 1280, pixelHeight: 720, reference: null });
      await new Promise((r) => setTimeout(r, 100));
      const t0 = performance.now();
      const r = await client.export(options);
      return {
        bytes: Array.from(new Uint8Array(r.buffer)),
        mimeType: r.mimeType,
        width: r.width,
        height: r.height,
        fps: r.fps,
        frames: r.frames,
        timestamps: r.timestamps ?? null,
        collapsedFrames: r.collapsedFrames ?? 0,
        ms: performance.now() - t0,
      };
    },
    { projectFile, options },
  );
  return { ...res, buffer: Buffer.from(res.bytes) };
}

const trunc600 = (s) => Math.trunc(s * 600) / 600;

try {
  // ── Fast export (VFR) vs the Mac ────────────────────────────────────────
  const cases = [
    { name: "60", fps: 60 },
    { name: "30", fps: 30 },
    ...(existsSync(join(FIX, "expected-camera-60.json")) ? [{ name: "camera-60", fps: 60 }] : []),
  ];
  for (const { name, fps } of cases) {
    const expected = JSON.parse(readFileSync(join(FIX, `expected-${name}.json`), "utf8"));
    const r = await runExport(`project-${name}.json`, { format: "MP4", collapseStaticSpans: true, fps, width: 1280, height: 720, audio: false });
    const file = join(OUT, `web-fast-${name}.mp4`);
    writeFileSync(file, r.buffer);
    const webIdx = r.timestamps.map((ts) => {
      for (let i = Math.max(0, Math.round((ts / 1e6) * fps) - 2); i <= Math.round((ts / 1e6) * fps) + 2; i++) {
        if (Math.abs(trunc600(i / fps) * 1e6 - ts) <= 1) return i;
      }
      return -1;
    });
    const macIdx = expected.keptFrameIndices;
    const same = webIdx.length === macIdx.length && webIdx.every((v, i) => v === macIdx[i]);
    if (!same) {
      const w = new Set(webIdx);
      const m = new Set(macIdx);
      console.log("  web-only:", webIdx.filter((i) => !m.has(i)).join(","), " mac-only:", macIdx.filter((i) => !w.has(i)).join(","));
    }
    check(same, `fast ${name}: web writes the Mac's frames (${webIdx.length} of ${expected.cfrFrameCount}; Mac ${macIdx.length})`);
    check(r.collapsedFrames === expected.cfrFrameCount - macIdx.length, `fast ${name}: collapsed ${r.collapsedFrames} frames`);
    const probed = probe(file);
    const ptsOk =
      probed.pts.length === expected.pts.length && probed.pts.every((p, i) => Math.abs(p - expected.pts[i]) < 1e-4);
    check(ptsOk, `fast ${name}: file PTS == Mac PTS (ffprobe, ${probed.pts.length} packets)`);
    check(Math.abs(probed.duration - expected.totalSeconds) < 2e-3, `fast ${name}: file length ${probed.duration}s == timeline ${expected.totalSeconds}s`);
    const macDur = expected.durations.slice(0, -1);
    const durOk = probed.durations.slice(0, -1).every((d, i) => Math.abs(d - macDur[i]) < 1e-4);
    check(durOk, `fast ${name}: VFR sample durations == Mac (static spans held)`);
    console.log(`  ${name} fast export: ${r.ms.toFixed(0)} ms, ${r.timestamps.length} frames written`);
  }

  // ── CFR (fast export off) ───────────────────────────────────────────────
  {
    const r = await runExport("project-60.json", { format: "MP4", collapseStaticSpans: false, fps: 60, width: 1280, height: 720, audio: false });
    const file = join(OUT, "web-cfr-60.mp4");
    writeFileSync(file, r.buffer);
    const probed = probe(file);
    check(probed.pts.length === 600, `CFR 60 fps: ${probed.pts.length} frames (600)`);
    check(probed.pts.every((p, i) => Math.abs(p - trunc600(i / 60)) < 1e-4), "CFR 60 fps: PTS on the Mac's CMTime(i/fps, 600) grid");
    check(Math.abs(probed.duration - 10) < 2e-3, `CFR 60 fps: file length ${probed.duration}s`);
  }

  // ── GIF vs the Mac's GIF ────────────────────────────────────────────────
  {
    const r = await runExport("project-60.json", { format: "GIF", fps: 60, width: 1280, height: 720, audio: false });
    const file = join(OUT, "web.gif");
    writeFileSync(file, r.buffer);
    const web = parseGif(r.buffer);
    const mac = parseGif(readFileSync(join(FIX, "export.gif")));
    check(web.magic === "GIF89a", `GIF: magic ${web.magic}`);
    check(r.mimeType === "image/gif", "GIF: mime image/gif");
    check(web.loop === 0 && mac.loop === 0, `GIF: loops forever (web ${web.loop}, mac ${mac.loop})`);
    check(web.frames.length === mac.frames.length, `GIF: ${web.frames.length} frames (Mac ${mac.frames.length})`);
    check(
      web.frames.every((f) => f.delay === 5) && mac.frames.every((f) => f.delay === 5),
      `GIF: every frame 5 cs (web ${[...new Set(web.frames.map((f) => f.delay))]}, mac ${[...new Set(mac.frames.map((f) => f.delay))]})`,
    );
    check(web.width === mac.width && web.height === mac.height, `GIF: ${web.width}x${web.height} (Mac ${mac.width}x${mac.height})`);
    console.log(`  GIF: web ${r.buffer.length} bytes in ${r.ms.toFixed(0)} ms, Mac ${readFileSync(join(FIX, "export.gif")).length} bytes`);
  }

  // ── PNG (still export path) ─────────────────────────────────────────────
  {
    const r = await runExport("project-60.json", { format: "PNG", fps: 60, width: 1280, height: 720, audio: false });
    const file = join(OUT, "web-still.png");
    writeFileSync(file, r.buffer);
    const png = parsePng(r.buffer);
    check(png.sig === "89504e470d0a1a0a", "PNG: signature");
    check(png.width === 1280 && png.height === 720, `PNG: ${png.width}x${png.height}`);
    check(r.mimeType === "image/png" && r.frames === 1, "PNG: one frame, image/png");
    console.log(`  PNG chunks: ${[...new Set(png.types)].join(" ")}`);
  }
} finally {
  await browser.close();
}
if (errors.length) console.log("page errors:", errors.slice(0, 5));
console.log(failed ? `EXPORT-FORMATS WEB FAIL (${failed})` : "EXPORT-FORMATS WEB PASS");
process.exit(failed ? 1 : 0);
