#!/usr/bin/env node
/**
 * Stage-interaction gate (DEV ONLY) — headless system Chrome (playwright-core,
 * channel "chrome") against a running dev server.
 *
 *   node scripts/editor-lab/stage-interactions.mjs [--url http://localhost:3217]
 *        [--out <dir>] [--only camera-seek,drags,pill,edit] [--headed]
 *
 * camera-seek  /editor-lab engine + parity fixture 13 (webcam): scrub to
 *              random times and assert that, AT the moment each seek
 *              resolves, the webcam frame drawn is the one for that time
 *              (index + VideoFrame timestamp) — captured inside the worker by
 *              wrapping its postMessage, so nothing can land in between.
 * drags        the REAL editor page (/editor-lab/open) on a synthetic project
 *              (fixture 13's recording + camera, fixture 11's subtitles, a
 *              generated watermark PNG) served through request interception:
 *              real pointer drags on the camera bubble, the subtitle pill and
 *              the watermark; the saved settings must change exactly as the
 *              Mac's PreviewInteractionView writes them (fractions, corner /
 *              anchor / edge magnetism back to the enum), each drag one undo
 *              step; and every engine-reported hit rect must overlap its
 *              rendered pixels at 50%, 100% and 200% preview zoom.
 * pill         select a text annotation → the contextual pill appears above
 *              it (below when it hugs the top), hides while dragging and
 *              during playback; its controls write the annotation.
 * edit         double-click a label → the engine omits it from the raster
 *              (no doubled text); the export path is unaffected.
 *
 * Evidence (screenshots + report.json) goes to --out. Exit 1 on any failure.
 */
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { deflateSync } from "node:zlib";
import { chromium } from "playwright-core";

const args = process.argv.slice(2);
const opt = (name, fallback) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : fallback;
};
const BASE = opt("url", "http://localhost:3217");
const OUT = opt("out", "/tmp/capturecat-stage-interactions");
const ONLY = new Set(opt("only", "camera-seek,drags,pill,edit").split(","));
const FIX = new URL("../../.fixtures/parity/", import.meta.url).pathname;
mkdirSync(OUT, { recursive: true });

const report = { startedAt: new Date().toISOString(), base: BASE, results: {} };
const failures = [];
const log = (...a) => console.log(...a);
const check = (cond, msg) => {
  if (!cond) failures.push(msg);
  return cond;
};

const browser = await chromium.launch({
  channel: "chrome",
  headless: !args.includes("--headed"),
  args: ["--autoplay-policy=no-user-gesture-required", "--enable-gpu", "--ignore-gpu-blocklist"],
});
const consoleErrors = [];
const watch = (page) => {
  page.on("console", (m) => {
    if (m.type() === "error") consoleErrors.push(`console: ${m.text()}`);
  });
  page.on("pageerror", (e) => consoleErrors.push(`pageerror: ${e.message}`));
  page.on("crash", () => consoleErrors.push("page crashed"));
  page.on("worker", (w) => w.on("close", () => !page.isClosed() && consoleErrors.push(`info: worker closed (an engine client was disposed): ${w.url()}`)));
};

const rnd = (() => {
  let s = 0x51f15e;
  return () => ((s = (s * 1664525 + 1013904223) >>> 0) / 2 ** 32);
})();

/**
 * The LIVE engine worker: the lab page creates (and disposes) more than one
 * engine client, so pick the newest worker whose camera feature has its
 * stream open — never a disposed one.
 */
async function engineWorker(page) {
  for (let i = 0; i < 100; i++) {
    for (const w of [...page.workers()].reverse()) {
      const ok = await w.evaluate(() => (globalThis.__cameraFeatures ?? []).some((f) => f.debugState().open)).catch(() => false);
      if (ok) return w;
    }
    await page.waitForTimeout(100);
  }
  throw new Error("engine worker not found");
}

/** Wrap the worker's postMessage: at every `seeked`, record the preview camera feature's state. */
async function instrumentSeeks(worker) {
  await worker.evaluate(() => {
    if (globalThis.__ccSeekLog) return;
    globalThis.__ccSeekLog = [];
    const orig = self.postMessage.bind(self);
    self.postMessage = (msg, transfer) => {
      if (msg && msg.type === "seeked") {
        const f = globalThis.__cameraFeatures?.[0];
        globalThis.__ccSeekLog.push({ requestId: msg.requestId, time: msg.time, superseded: msg.superseded, frameIndex: msg.frameIndex, cam: f ? f.debugState() : null });
      }
      return orig(msg, transfer);
    };
  });
}

// ── camera-seek ─────────────────────────────────────────────────────────────
async function cameraSeek(camera) {
  const page = await (await browser.newContext({ viewport: { width: 1600, height: 1000 }, deviceScaleFactor: 1 })).newPage();
  watch(page);
  await page.goto(`${BASE}/editor-lab?autoload=0`, { waitUntil: "domcontentloaded" });
  await page.waitForFunction(() => window.__lab?.ready === true, null, { timeout: 60_000 });
  const base = "/.fixtures/parity/13-camera-bubble-layouts";
  await page.evaluate(async ([b, cam]) => {
    const client = window.__lab.client();
    const project = await (await fetch(`${b}/project.json`)).json();
    // The classic bubble for the whole take (no layout regions).
    project.cameraLayoutRegions = [];
    await client.load(project, { video: `${b}/recording.mp4`, files: { [project.cameraVideoURL]: cam } });
    client.resize({ cssWidth: 1280, cssHeight: 720, dpr: 1, pixelWidth: 1280, pixelHeight: 720, reference: null });
    await client.seek(0.2);
  }, [base, camera.url]);
  const worker = await engineWorker(page);
  await instrumentSeeks(worker);
  // Let the first camera frame land, then scrub.
  await page.waitForTimeout(400);
  const fps = camera.fps;
  const times = [];
  for (let i = 0; i < 12; i++) times.push(Math.round((0.1 + rnd() * 4.7) * 1000) / 1000);
  const rows = [];
  for (const t of times) {
    const r = await page.evaluate(async (tt) => {
      const t0 = performance.now();
      const s = await window.__lab.client().seek(tt);
      return { ...s, ms: performance.now() - t0 };
    }, t);
    const logEntry = await worker.evaluate(() => globalThis.__ccSeekLog.at(-1));
    const cam = logEntry?.cam;
    // Camera time = source time − cameraTimeOffset (0); sample i has PTS i/fps;
    // the frame shown is the last with PTS ≤ CMTime(t, 600) (truncating).
    const expected = Math.floor(Math.trunc(t * 600) / 600 * fps + 1e-6);
    const tsSec = cam?.liveTimestamp != null ? cam.liveTimestamp / 1e6 : null;
    const ok = !!cam && cam.liveIndex === expected && cam.wantedIndex === expected && tsSec != null && Math.abs(tsSec - expected / fps) < 1e-3;
    rows.push({ t, expected, liveIndex: cam?.liveIndex, wantedIndex: cam?.wantedIndex, liveTimestampSec: tsSec, seekMs: Math.round(r.ms), ok });
  }
  const bad = rows.filter((r) => !r.ok);
  check(bad.length === 0, `camera-seek ${camera.name}: ${bad.length}/${rows.length} seeks resolved with a stale webcam frame: ${JSON.stringify(bad.slice(0, 3))}`);
  await page.screenshot({ path: join(OUT, `camera-seek-${camera.name}.png`) });
  (report.results.cameraSeek ??= {})[camera.name] = rows;
  log(`camera-seek ${camera.name}: ${rows.length - bad.length}/${rows.length} exact`);
  for (const r of rows) log(`  t=${r.t.toFixed(3)} want=${r.expected} drawn=${r.liveIndex} ts=${r.liveTimestampSec?.toFixed(4)} ${r.seekMs}ms ${r.ok ? "ok" : "STALE"}`);
  await page.close();
}

// ── The real editor page on a synthetic project ─────────────────────────────

const PROJECT_ID = "5EC7A6E0-0000-4000-8000-00000000AB01";

/** A tiny RGBA PNG (the watermark logo): a rounded orange badge (unlike any fixture colour) with a dark bar. */
function logoPng(w = 240, h = 80) {
  const crcTable = new Uint32Array(256).map((_, n) => {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    return c >>> 0;
  });
  const crc = (buf) => {
    let c = 0xffffffff;
    for (const b of buf) c = crcTable[(c ^ b) & 255] ^ (c >>> 8);
    return (c ^ 0xffffffff) >>> 0;
  };
  const chunk = (type, data) => {
    const len = Buffer.alloc(4);
    len.writeUInt32BE(data.length);
    const td = Buffer.concat([Buffer.from(type, "ascii"), data]);
    const c = Buffer.alloc(4);
    c.writeUInt32BE(crc(td));
    return Buffer.concat([len, td, c]);
  };
  const raw = Buffer.alloc((w * 4 + 1) * h);
  const r = 18;
  for (let y = 0; y < h; y++) {
    raw[y * (w * 4 + 1)] = 0;
    for (let x = 0; x < w; x++) {
      const dx = Math.max(r - x, 0, x - (w - 1 - r));
      const dy = Math.max(r - y, 0, y - (h - 1 - r));
      const inside = dx * dx + dy * dy <= r * r;
      const bar = y > h * 0.4 && y < h * 0.6 && x > w * 0.15 && x < w * 0.85;
      const o = y * (w * 4 + 1) + 1 + x * 4;
      if (!inside) continue;
      raw[o] = bar ? 20 : 255;
      raw[o + 1] = bar ? 30 : 140;
      raw[o + 2] = bar ? 60 : 0;
      raw[o + 3] = 255;
    }
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0);
  ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8;
  ihdr[9] = 6;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", ihdr), chunk("IDAT", deflateSync(raw)), chunk("IEND", Buffer.alloc(0))]);
}

/** Fixture 13 (screen + webcam) + fixture 11's subtitles + a watermark + a text label. */
function syntheticProject({ zoomBlock = false } = {}) {
  const read = (d) => JSON.parse(readFileSync(join(FIX, d, "project.json"), "utf8"));
  const p = read("13-camera-bubble-layouts");
  const f11 = read("11-subtitles-ring-cursor");
  const f08 = read("08-annotations");
  p.id = PROJECT_ID;
  p.name = "stage-interactions";
  p.videoURL = "recording.mp4";
  p.cameraVideoURL = "camera.mp4";
  p.cameraLayoutRegions = [];
  p.subtitles = f11.subtitles;
  Object.assign(p.settings, {
    subtitleStyle: "Background",
    subtitleBackgroundColor: { red: 0, green: 0, blue: 0, opacity: 1 },
    showWatermark: true,
    watermarkFileName: "logo.png",
    watermarkSize: 120,
    watermarkX: 1,
    watermarkY: 0, // top-right: clear of the bottom-right bubble (the watermark hit-tests first)
    watermarkOpacity: 0.9,
  });
  const text = f08.annotations.find((a) => a.type === "text");
  Object.assign(text, { startTime: 0, endTime: 5, enterEffect: "None", exitEffect: "None", x: 0.35, y: 0.3 });
  p.annotations = [text];
  if (zoomBlock) {
    // A camera zoom block over the probe time: the subtitle (card space) is
    // drawn THROUGH the zoom; the bubble shrinks (ReactiveCameraLayout).
    const f04 = read("04-zoom-follow-motionblur");
    p.zoomRegions = [{ ...f04.zoomRegions[0], startTime: 0.5, endTime: 4.5, zoomLevel: 1.5, focalPoint: [0.5, 0.45] }];
    p.settings.motionBlur = false;
    p.settings.subtitlePosition = "Center";
  }
  return p;
}

async function openEditor({ zoom, zoomBlock = false } = {}) {
  const ctx = await browser.newContext({ viewport: { width: 1500, height: 940 }, deviceScaleFactor: 2 });
  const page = await ctx.newPage();
  watch(page);
  const project = JSON.stringify(syntheticProject({ zoomBlock }));
  const media = {
    "recording.mp4": { path: join(FIX, "13-camera-bubble-layouts/recording.mp4"), type: "video/mp4" },
    "camera.mp4": { path: join(FIX, "13-camera-bubble-layouts/camera.mp4"), type: "video/mp4" },
  };
  const logo = logoPng();
  await page.route((url) => url.pathname.includes("/api/cloud-projects"), (route) => route.fulfill({ status: 404, contentType: "application/json", body: '{"error":"not found"}' }));
  await page.route((url) => url.pathname.startsWith(`/__dev/local-projects/${PROJECT_ID}`), async (route) => {
    const url = new URL(route.request().url());
    if (url.pathname.endsWith("/project.json")) return route.fulfill({ status: 200, contentType: "application/json", body: project });
    const ref = url.searchParams.get("ref");
    if (ref === "logo.png") return route.fulfill({ status: 200, contentType: "image/png", body: logo });
    const m = media[ref];
    if (!m) return route.fulfill({ status: 404, body: "" });
    const body = readFileSync(m.path);
    const range = route.request().headers().range;
    if (range) {
      const [, a, b] = /bytes=(\d+)-(\d*)/.exec(range);
      const start = Number(a);
      const end = b ? Math.min(Number(b), body.length - 1) : body.length - 1;
      return route.fulfill({
        status: 206,
        headers: { "content-type": m.type, "content-range": `bytes ${start}-${end}/${body.length}`, "accept-ranges": "bytes", "content-length": String(end - start + 1) },
        body: body.subarray(start, end + 1),
      });
    }
    return route.fulfill({ status: 200, headers: { "content-type": m.type, "accept-ranges": "bytes" }, body });
  });
  await page.goto(`${BASE}/editor-lab/open?id=${PROJECT_ID}`, { waitUntil: "domcontentloaded" });
  await page.waitForFunction(() => !!document.querySelector("canvas[data-stage-interaction]") && window.__editor?.controller?.client?.lastFrame, null, { timeout: 60_000 });
  if (zoom) await setZoom(page, zoom);
  await seekAndSettle(page, 1.5);
  return page;
}

/** Seek + wait for the frame (and the webcam) and a stage relayout. */
async function seekAndSettle(page, t) {
  await page.evaluate(async (tt) => {
    const { controller } = window.__editor;
    controller.seek(tt);
    await controller.client.seek(tt);
    await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
  }, t);
  await page.waitForTimeout(120);
}

/** The preview zoom pill: click −/+ until the label reads `zoom`. */
async function setZoom(page, zoom) {
  const want = `${Math.round(zoom * 100)}%`;
  for (let i = 0; i < 12; i++) {
    const label = (await page.locator(".cc-zoompill button").nth(1).textContent())?.trim();
    if (label === want) break;
    const cur = Number.parseInt(label ?? "100", 10) / 100;
    await page.locator(".cc-zoompill button").nth(cur < zoom ? 2 : 0).click();
    await page.waitForTimeout(80);
  }
  // Let the slot's size transition + the engine resize settle.
  await page.waitForTimeout(600);
  await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))));
}

/** Engine frame geometry + settings + undo depth, in one read. */
async function state(page) {
  return page.evaluate(() => {
    const { store, controller } = window.__editor;
    const f = controller.client.lastFrame;
    const c = document.querySelector("canvas[data-stage-interaction]").getBoundingClientRect();
    const s = store.getState().project.settings;
    const pick = (keys) => Object.fromEntries(keys.map((k) => [k, s[k]]));
    const hist = store.history();
    return {
      frame: { target: f.target, camera: f.camera, hits: f.hits, canvasScale: f.canvasScale },
      canvas: { left: c.left, top: c.top, width: c.width, height: c.height },
      settings: pick(["cameraPosition", "cameraCustomX", "cameraCustomY", "subtitlePosition", "subtitleCustomX", "subtitleCustomY", "watermarkX", "watermarkY"]),
      undo: { depth: hist.length, label: hist.at(-1)?.label ?? null },
    };
  });
}

const applyH = (m, x, y) => {
  const w = m[6] * x + m[7] * y + m[8];
  return { x: (m[0] * x + m[1] * y + m[2]) / w, y: (m[3] * x + m[4] * y + m[5]) / w };
};

/** 3×3 row-major inverse (the card → canvas camera's canvas → card). */
function invert3(m) {
  const [a, b, c, d, e, f, g, h, i] = m;
  const A = e * i - f * h, B = -(d * i - f * g), C = d * h - e * g;
  const det = a * A + b * B + c * C;
  return [A / det, -(b * i - c * h) / det, (b * f - c * e) / det, B / det, (a * i - c * g) / det, -(a * f - c * d) / det, C / det, -(a * h - b * g) / det, (a * e - b * d) / det];
}

/** Client CSS px → engine px in the hit's space (card: through the inverse camera). */
function fromClient(st, p, space) {
  const k = st.canvas.width / st.frame.target.width;
  const q = { x: (p.x - st.canvas.left) / k, y: (p.y - st.canvas.top) / k };
  return space === "card" ? applyH(invert3(st.frame.camera), q.x, q.y) : q;
}

/** Engine px (hit space) → client CSS px. */
function toClient(st, p, space) {
  const q = space === "card" ? applyH(st.frame.camera, p.x, p.y) : p;
  const k = st.canvas.width / st.frame.target.width;
  return { x: st.canvas.left + q.x * k, y: st.canvas.top + q.y * k };
}

/** Scroll the (zoomed) stage so a client point is comfortably visible; returns the new point. */
async function bringIntoView(page, pt) {
  const dy = await page.evaluate(([x, y]) => {
    const sc = document.querySelector(".cc-stagescroll");
    const r = sc.getBoundingClientRect();
    const bx = Math.max(0, Math.min(sc.scrollWidth - sc.clientWidth, sc.scrollLeft + (x - (r.left + r.width / 2))));
    const by = Math.max(0, Math.min(sc.scrollHeight - sc.clientHeight, sc.scrollTop + (y - (r.top + r.height / 2))));
    const moved = { x: bx - sc.scrollLeft, y: by - sc.scrollTop };
    sc.scrollLeft = bx;
    sc.scrollTop = by;
    return moved;
  }, [pt.x, pt.y]);
  await page.waitForTimeout(60);
  return { x: pt.x - dy.x, y: pt.y - dy.y };
}

const clamp01 = (v) => Math.min(1, Math.max(0, v));
const CORNERS = { "Top Left": [0, 0], "Top Right": [1, 0], "Bottom Left": [0, 1], "Bottom Right": [1, 1] };

/** Independent restatement of PreviewInteractionView's drag + release for the harness. */
function macExpected(kind, before, deltaPx, usable) {
  const s = { ...before };
  let init;
  if (kind === "camera") init = s.cameraCustomX != null && s.cameraCustomY != null ? [s.cameraCustomX, s.cameraCustomY] : CORNERS[s.cameraPosition];
  else if (kind === "watermark") init = [s.watermarkX, s.watermarkY];
  else init = s.subtitleCustomX != null && s.subtitleCustomY != null ? [s.subtitleCustomX, s.subtitleCustomY] : [0.5, { Top: 0, Center: 0.5, Bottom: 1 }[s.subtitlePosition]];
  const [uw, uh] = [usable.width, usable.height];
  let fx;
  let fy;
  if (kind === "camera") {
    fx = clamp01(init[0] + deltaPx.x / Math.max(1, uw));
    fy = clamp01(init[1] + deltaPx.y / Math.max(1, uh));
  } else {
    fx = clamp01(init[0] + (uw > 0 ? deltaPx.x / uw : 0));
    fy = clamp01(init[1] + (uh > 0 ? deltaPx.y / uh : 0));
  }
  if (kind === "camera") {
    s.cameraCustomX = fx;
    s.cameraCustomY = fy;
    for (const [name, [cx, cy]] of Object.entries(CORNERS)) {
      if (Math.abs(cx - fx) < 0.06 && Math.abs(cy - fy) < 0.06) {
        s.cameraPosition = name;
        delete s.cameraCustomX;
        delete s.cameraCustomY;
        break;
      }
    }
  } else if (kind === "watermark") {
    const snap = (v) => (Math.abs(v) < 0.04 ? 0 : Math.abs(v - 1) < 0.04 ? 1 : v);
    s.watermarkX = snap(fx);
    s.watermarkY = snap(fy);
  } else {
    s.subtitleCustomX = fx;
    s.subtitleCustomY = fy;
    if (Math.abs(fx - 0.5) < 0.06) {
      for (const [name, ay] of [["Top", 0], ["Center", 0.5], ["Bottom", 1]]) {
        if (Math.abs(fy - ay) < 0.06) {
          s.subtitlePosition = name;
          delete s.subtitleCustomX;
          delete s.subtitleCustomY;
          break;
        }
      }
    }
  }
  return s;
}

const LABELS = { camera: "Move Camera", subtitle: "Move Subtitles", watermark: "Move Watermark" };

/**
 * One real pointer drag on overlay `kind`: from its hit-rect centre by
 * `toFraction` (target fraction) or `deltaCss`. Asserts the saved settings
 * equal the Mac's math (within a CSS pixel), one undo step, and that undo
 * restores the settings.
 */
async function dragOverlay(page, kind, { toFraction, deltaCss, name, keep = true }) {
  const st = await state(page);
  const hit = st.frame.hits?.[kind];
  if (!check(!!hit, `${name}: engine reported no ${kind} hit rect`)) return null;
  const k = st.canvas.width / st.frame.target.width; // CSS px per engine px
  const r = hit.rect;
  let from = toClient(st, { x: r.x + r.width / 2, y: r.y + r.height / 2 }, hit.space);
  from = await bringIntoView(page, from);
  from = { x: Math.round(from.x), y: Math.round(from.y) };
  const scrolled = await state(page); // the canvas moved if the stage scrolled
  // Card-space overlays move through the camera (local zoom ≈ m[0] for a zoom block).
  const camScale = hit.space === "card" ? Math.hypot(st.frame.camera[0], st.frame.camera[3]) : 1;
  let d = deltaCss;
  if (toFraction) {
    const init = macExpected(kind, st.settings, { x: 0, y: 0 }, { width: 1e9, height: 1e9 });
    const fx0 = kind === "camera" ? (init.cameraCustomX ?? CORNERS[init.cameraPosition][0]) : kind === "watermark" ? init.watermarkX : (init.subtitleCustomX ?? 0.5);
    const fy0 = kind === "camera" ? (init.cameraCustomY ?? CORNERS[init.cameraPosition][1]) : kind === "watermark" ? init.watermarkY : (init.subtitleCustomY ?? { Top: 0, Center: 0.5, Bottom: 1 }[init.subtitlePosition]);
    d = { x: Math.round((toFraction[0] - fx0) * hit.usable.width * camScale * k), y: Math.round((toFraction[1] - fy0) * hit.usable.height * camScale * k) };
  }
  const to = { x: from.x + d.x, y: from.y + d.y };
  await page.mouse.move(from.x, from.y);
  await page.mouse.down();
  const cursorDuring = [];
  for (let i = 1; i <= 10; i++) {
    await page.mouse.move(from.x + (d.x * i) / 10, from.y + (d.y * i) / 10);
    if (i === 5) cursorDuring.push(await page.evaluate(() => document.querySelector("canvas[data-stage-interaction]").style.cursor));
  }
  await page.mouse.up();
  await page.waitForTimeout(150);
  const after = await state(page);
  // Expected from the ACTUAL pointer delta in the hit's space (canvas px, or
  // card px through the inverse camera — computed here independently).
  const a0 = fromClient(scrolled, from, hit.space);
  const a1 = fromClient(scrolled, { x: from.x + d.x, y: from.y + d.y }, hit.space);
  const deltaPx = { x: a1.x - a0.x, y: a1.y - a0.y };
  const expected = macExpected(kind, st.settings, deltaPx, hit.usable);
  const tol = (1.01 / (k * camScale)) / Math.max(1, Math.min(hit.usable.width || Infinity, hit.usable.height || Infinity));
  const mismatches = [];
  for (const key of Object.keys({ ...expected, ...after.settings })) {
    const e = expected[key];
    const a = after.settings[key];
    if (typeof e === "number" && typeof a === "number") {
      if (Math.abs(e - a) > tol + 1e-9) mismatches.push(`${key}: ${a} ≠ ${e}`);
    } else if (e !== a) mismatches.push(`${key}: ${a} ≠ ${e}`);
  }
  check(mismatches.length === 0, `${name}: saved settings differ from the Mac's: ${mismatches.join("; ")}`);
  check(after.undo.depth === st.undo.depth + 1 && after.undo.label === LABELS[kind], `${name}: expected ONE undo step "${LABELS[kind]}", got depth ${st.undo.depth}→${after.undo.depth} "${after.undo.label}"`);
  check(cursorDuring[0] === "grabbing", `${name}: cursor during drag was "${cursorDuring[0]}"`);
  // Undo must restore the exact starting settings in one step.
  await page.evaluate(() => window.__editor.store.undo());
  const undone = await state(page);
  check(JSON.stringify(undone.settings) === JSON.stringify(st.settings), `${name}: one undo did not restore ${JSON.stringify(st.settings)} (got ${JSON.stringify(undone.settings)})`);
  if (keep) await page.evaluate(() => window.__editor.store.redo());
  await page.waitForTimeout(100);
  const row = { name, kind, space: hit.space, fromCss: from, deltaCss: d, before: st.settings, after: after.settings, expected, ok: mismatches.length === 0 };
  log(`  ${row.ok ? "ok  " : "FAIL"} ${name}: ${JSON.stringify(after.settings)}`);
  return row;
}

/** Pixels the overlay changes (shown vs hidden) vs the reported hit rect. */
async function overlapCheck(page, kind, zoomLabel) {
  const toggle = { camera: "showCamera", subtitle: "showSubtitles", watermark: "showWatermark" }[kind];
  const res = await page.evaluate(async ([key, kd]) => {
    const { store, controller } = window.__editor;
    const client = controller.client;
    const frame = () => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
    await frame();
    const hit = client.lastFrame.hits?.[kd];
    const cam = client.lastFrame.camera;
    const a = await client.snapshot();
    store.updateSettings({ [key]: false }, "harness");
    await frame();
    await new Promise((r) => setTimeout(r, 120));
    const b = await client.snapshot();
    store.undo();
    await frame();
    await new Promise((r) => setTimeout(r, 120));
    const A = new Uint8Array(a.rgba);
    const B = new Uint8Array(b.rgba);
    const W = a.width;
    const H = a.height;
    let x0 = W, y0 = H, x1 = -1, y1 = -1, n = 0;
    const changed = new Uint8Array(W * H);
    for (let i = 0; i < W * H; i++) {
      const o = i * 4;
      const d = Math.max(Math.abs(A[o] - B[o]), Math.abs(A[o + 1] - B[o + 1]), Math.abs(A[o + 2] - B[o + 2]));
      if (d > 24) {
        changed[i] = 1;
        n++;
        const x = i % W, y = (i / W) | 0;
        if (x < x0) x0 = x;
        if (y < y0) y0 = y;
        if (x > x1) x1 = x;
        if (y > y1) y1 = y;
      }
    }
    if (!hit) return { error: "no hit rect" };
    // The hit rect in canvas px (card-space rects through the camera).
    const ap = (x, y) => {
      const w = cam[6] * x + cam[7] * y + cam[8];
      return [(cam[0] * x + cam[1] * y + cam[2]) / w, (cam[3] * x + cam[4] * y + cam[5]) / w];
    };
    const r = hit.rect;
    const pts = hit.space === "card" ? [ap(r.x, r.y), ap(r.x + r.width, r.y + r.height)] : [[r.x, r.y], [r.x + r.width, r.y + r.height]];
    const hr = { x: pts[0][0], y: pts[0][1], width: pts[1][0] - pts[0][0], height: pts[1][1] - pts[0][1] };
    // Share of the hit rect's (inset 15%) core whose pixels the overlay changed.
    const inset = 0.15;
    let coreN = 0, coreChanged = 0;
    for (let y = Math.ceil(hr.y + hr.height * inset); y < hr.y + hr.height * (1 - inset); y++) {
      for (let x = Math.ceil(hr.x + hr.width * inset); x < hr.x + hr.width * (1 - inset); x++) {
        if (x < 0 || y < 0 || x >= W || y >= H) continue;
        coreN++;
        coreChanged += changed[y * W + x];
      }
    }
    // Same metric for the rect shifted by its own width (must NOT pass — the metric discriminates).
    let shiftN = 0, shiftChanged = 0;
    for (let y = Math.ceil(hr.y + hr.height * inset); y < hr.y + hr.height * (1 - inset); y++) {
      for (let x = Math.ceil(hr.x + hr.width * (1 + inset)); x < hr.x + hr.width * (2 - inset); x++) {
        if (x < 0 || y < 0 || x >= W || y >= H) continue;
        shiftN++;
        shiftChanged += changed[y * W + x];
      }
    }
    const diff = { x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1 };
    const ix = Math.max(0, Math.min(hr.x + hr.width, diff.x + diff.width) - Math.max(hr.x, diff.x));
    const iy = Math.max(0, Math.min(hr.y + hr.height, diff.y + diff.height) - Math.max(hr.y, diff.y));
    return {
      target: { width: W, height: H },
      hit: hr,
      diff,
      changedPixels: n,
      hitInsideDiff: (ix * iy) / Math.max(1, hr.width * hr.height),
      coreChanged: coreN ? coreChanged / coreN : 0,
      shiftedCoreChanged: shiftN ? shiftChanged / shiftN : 0,
    };
  }, [toggle, kind]);
  const ok = !res.error && res.hitInsideDiff > 0.97 && res.coreChanged > 0.9;
  check(ok, `overlap ${kind} @${zoomLabel}: ${JSON.stringify(res)}`);
  log(`  ${ok ? "ok  " : "FAIL"} overlap ${kind} @${zoomLabel}: hit∩drawn ${(res.hitInsideDiff * 100).toFixed(1)}%, core changed ${(res.coreChanged * 100).toFixed(1)}% (shifted rect ${(res.shiftedCoreChanged * 100).toFixed(1)}%) target ${res.target?.width}x${res.target?.height}`);
  return res;
}

async function drags() {
  const page = await openEditor();
  const rows = [];
  log("drags @100%:");
  await page.screenshot({ path: join(OUT, "drags-before.png") });
  // Camera: free drag toward the centre (stays custom), then into the top-left magnet.
  rows.push(await dragOverlay(page, "camera", { toFraction: [0.5, 0.45], name: "camera free" }));
  rows.push(await dragOverlay(page, "camera", { toFraction: [0.03, 0.02], name: "camera → Top Left magnet" }));
  // Subtitle: to (0.3, 0.3) (custom), then back near the centre anchor (→ Center enum).
  rows.push(await dragOverlay(page, "subtitle", { toFraction: [0.3, 0.3], name: "subtitle free" }));
  rows.push(await dragOverlay(page, "subtitle", { toFraction: [0.52, 0.49], name: "subtitle → Center magnet" }));
  // Watermark: free, then onto the bottom edge (y snaps to 1).
  rows.push(await dragOverlay(page, "watermark", { toFraction: [0.2, 0.3], name: "watermark free" }));
  rows.push(await dragOverlay(page, "watermark", { toFraction: [0.5, 0.975], name: "watermark → bottom edge magnet" }));
  await page.screenshot({ path: join(OUT, "drags-after.png") });
  report.results.drags = rows;

  // Hover cursor over a draggable overlay.
  const st = await state(page);
  const wm = st.frame.hits.watermark;
  const c = toClient(st, { x: wm.rect.x + wm.rect.width / 2, y: wm.rect.y + wm.rect.height / 2 }, wm.space);
  await page.mouse.move(c.x, c.y);
  await page.waitForTimeout(50);
  const hoverCursor = await page.evaluate(() => document.querySelector("canvas[data-stage-interaction]").style.cursor);
  check(hoverCursor === "grab", `hover over watermark: cursor "${hoverCursor}" (want grab)`);

  // Hit rects vs rendered pixels + a pointer drag at 50%, 100%, 200% preview zoom.
  const zooms = {};
  for (const z of [0.5, 1, 2]) {
    const label = `${z * 100}%`;
    await setZoom(page, z);
    await seekAndSettle(page, 1.5);
    log(`zoom ${label}:`);
    zooms[label] = {};
    for (const kind of ["camera", "subtitle", "watermark"]) {
      zooms[label][kind] = await overlapCheck(page, kind, label);
      zooms[label][`${kind}Drag`] = await dragOverlay(page, kind, { deltaCss: { x: Math.round(70 * z), y: Math.round(-50 * z) }, name: `${kind} drag @${label}`, keep: false });
    }
    await page.screenshot({ path: join(OUT, `zoom-${z * 100}.png`) });
  }
  report.results.zoom = zooms;
  await page.close();
}

/** A CSS delta that moves an overlay toward the canvas centre (never clamped into a no-op). */
function towardCentre(frame, kind, dx, dy) {
  const h = frame.hits?.[kind];
  if (!h) return { x: dx, y: dy };
  const c = h.space === "card" ? applyH(frame.camera, h.rect.x + h.rect.width / 2, h.rect.y + h.rect.height / 2) : { x: h.rect.x + h.rect.width / 2, y: h.rect.y + h.rect.height / 2 };
  return { x: c.x > frame.target.width / 2 ? -dx : dx, y: c.y > frame.target.height / 2 ? -dy : dy };
}

/** Under a camera zoom block: card-space hits (the subtitle) map through the camera. */
async function zoomBlockDrags() {
  const page = await openEditor({ zoomBlock: true });
  await seekAndSettle(page, 2.0);
  const st = await state(page);
  const scale = Math.hypot(st.frame.camera[0], st.frame.camera[3]);
  check(scale > 1.3, `zoom block: camera scale ${scale} — the block is not active`);
  log(`zoom block (camera scale ${scale.toFixed(3)}):`);
  const res = { scale };
  for (const kind of ["camera", "subtitle", "watermark"]) {
    res[kind] = await overlapCheck(page, kind, "zoom-block");
    res[`${kind}Drag`] = await dragOverlay(page, kind, { deltaCss: towardCentre(st.frame, kind, 60, 40), name: `${kind} drag under zoom`, keep: false });
  }
  await page.screenshot({ path: join(OUT, "zoom-block.png") });
  report.results.zoomBlock = res;
  await page.close();
}

async function pill() {
  const page = await openEditor();
  const res = {};
  const anchor = async () => {
    const st = await state(page);
    const vr = await page.evaluate(() => window.__editor.controller.client.lastFrame.videoRect);
    const a = await page.evaluate(() => window.__editor.store.getState().project.annotations[0]);
    return { st, a, pt: toClient(st, { x: vr.x + a.x * vr.width, y: vr.y + a.y * vr.height }, "card") };
  };
  const pillBox = () =>
    page.evaluate(() => {
      const el = document.querySelector(".cc-annpill");
      if (!el) return null;
      const r = el.getBoundingClientRect();
      const card = document.querySelector(".cc-stagewrap").getBoundingClientRect();
      return { visible: el.dataset.visible === "true", type: el.dataset.annotationPill, anchor: el.dataset.anchor?.split(",").map(Number), x: r.left - card.left, y: r.top - card.top, width: r.width, height: r.height, card: { width: card.width, height: card.height } };
    });
  const expectPlacement = (p) => {
    const [ax, ay, aw, ah] = p.anchor;
    const above = ay - 10 - p.height >= 8;
    const bottom = above ? ay - 10 : Math.min(p.card.height - 8, ay + ah + 10 + p.height);
    const half = p.width / 2;
    const cx = Math.min(Math.max(ax + aw / 2, half + 8), Math.max(half + 8, p.card.width - half - 8));
    return { x: cx - half, y: bottom - p.height, above };
  };

  // Nothing selected → no pill.
  check((await pillBox()) === null, "pill: shown with nothing selected");
  // Select the label with a real click.
  let { pt } = await anchor();
  await page.mouse.click(Math.round(pt.x), Math.round(pt.y));
  await page.waitForTimeout(250);
  let p = await pillBox();
  check(p?.visible === true && p.type === "text", `pill: not shown for the selected text (${JSON.stringify(p)})`);
  if (p?.visible) {
    const e = expectPlacement(p);
    check(Math.abs(e.x - p.x) <= 1 && Math.abs(e.y - p.y) <= 1 && e.above, `pill: placed at ${p.x},${p.y}, expected ${e.x},${e.y} (above)`);
    check(p.y + p.height <= p.anchor[1] - 9, "pill: not above the annotation");
    res.above = { pill: p, expected: e };
  }
  await page.screenshot({ path: join(OUT, "pill-above.png") });
  const stageShot = async (file) => {
    const box = await page.evaluate(() => {
      const r = document.querySelector(".cc-stagewrap").getBoundingClientRect();
      return { x: r.left, y: r.top, width: r.width, height: r.height };
    });
    await page.screenshot({ path: join(OUT, file), clip: box });
  };
  await stageShot("pill-above-stage.png");

  // Hidden while dragging the annotation, back after.
  ({ pt } = await anchor());
  await page.waitForTimeout(600); // past the double-click window (this is a new press, not a 2nd click)
  await page.mouse.move(Math.round(pt.x), Math.round(pt.y));
  await page.mouse.down();
  await page.mouse.move(pt.x + 30, pt.y + 10, { steps: 4 });
  const during = await pillBox();
  check(during?.visible === false, "pill: visible while dragging");
  await page.mouse.move(pt.x + 60, pt.y + 20, { steps: 4 });
  await page.mouse.up();
  await page.waitForTimeout(200);
  const afterDrag = await pillBox();
  check(afterDrag?.visible === true, "pill: did not come back after the drag");
  res.dragHidden = during?.visible === false;

  // Hidden during playback.
  await page.evaluate(() => window.__editor.controller.client.play());
  await page.waitForTimeout(300);
  const playing = await pillBox();
  check(playing?.visible === false, "pill: visible during playback");
  await page.evaluate(() => window.__editor.controller.client.pause());
  await seekAndSettle(page, 1.5);
  check((await pillBox())?.visible === true, "pill: did not come back after pausing");

  // Near the top edge → below the annotation.
  await page.evaluate(() => {
    const { store } = window.__editor;
    const a = store.getState().project.annotations[0];
    store.updateRegion("annotation", a.id, { y: 0.04 });
  });
  await page.waitForTimeout(250);
  p = await pillBox();
  if (p?.visible) {
    const e = expectPlacement(p);
    check(!e.above && Math.abs(e.y - p.y) <= 1 && p.y >= p.anchor[1] + p.anchor[3] + 9, `pill: expected BELOW the top-hugging label (${JSON.stringify(p)})`);
    res.below = { pill: p, expected: e };
  }
  await stageShot("pill-below-stage.png");
  await page.evaluate(() => window.__editor.store.undo());
  await page.waitForTimeout(200);

  // Controls write the annotation (Mac applyToolbar*).
  const ann = () => page.evaluate(() => window.__editor.store.getState().project.annotations[0]);
  const bgBefore = (await ann()).showBackground;
  await page.locator('.cc-annpill button[aria-label="Background pill on/off"]').click();
  await page.waitForTimeout(100);
  check((await ann()).showBackground === !bgBefore, "pill: background toggle did not write showBackground");
  await page.locator('.cc-annpill button[aria-label="Weight"]').click();
  await page.waitForTimeout(150);
  await page.locator(".cc-float").getByText("Heavy", { exact: true }).click();
  await page.waitForTimeout(150);
  check((await ann()).fontWeight === "Heavy", `pill: weight menu wrote ${(await ann()).fontWeight}`);
  await page.locator('.cc-annpill button[aria-label="Font"]').click();
  await page.waitForTimeout(150);
  await page.locator(".cc-float").getByText("New York", { exact: true }).click();
  await page.waitForTimeout(150);
  check((await ann()).fontName === "New York", `pill: font menu wrote ${(await ann()).fontName}`);
  await page.waitForTimeout(300);
  await stageShot("pill-after-edits-stage.png");
  res.final = await ann();
  report.results.pill = res;
  log(`pill: above ${!!res.above} below ${!!res.below} dragHidden ${res.dragHidden} → ${JSON.stringify({ showBackground: res.final.showBackground, fontWeight: res.final.fontWeight, fontName: res.final.fontName })}`);
  await page.close();
}

async function edit() {
  const page = await openEditor();
  const res = {};
  const snap = () =>
    page.evaluate(async () => {
      await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
      await new Promise((r) => setTimeout(r, 150));
      const s = await window.__editor.controller.client.snapshot();
      return { width: s.width, height: s.height, rgba: Array.from(new Uint8Array(s.rgba)) };
    });
  const diff = (a, b, box) => {
    let n = 0, sum = 0, max = 0, x0 = a.width, y0 = a.height, x1 = -1, y1 = -1;
    const bx = box ?? { x: 0, y: 0, width: a.width, height: a.height };
    for (let y = bx.y; y < bx.y + bx.height; y++) {
      for (let x = bx.x; x < bx.x + bx.width; x++) {
        const o = (y * a.width + x) * 4;
        const d = Math.max(Math.abs(a.rgba[o] - b.rgba[o]), Math.abs(a.rgba[o + 1] - b.rgba[o + 1]), Math.abs(a.rgba[o + 2] - b.rgba[o + 2]));
        sum += d;
        if (d > max) max = d;
        if (d > 24) {
          n++;
          if (x < x0) x0 = x;
          if (y < y0) y0 = y;
          if (x > x1) x1 = x;
          if (y > y1) y1 = y;
        }
      }
    }
    return { changed: n, mean: sum / (bx.width * bx.height), max, box: x1 >= 0 ? { x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1 } : null };
  };
  const A = await snap(); // label drawn
  // C: the same frame with the label removed from the project.
  await page.evaluate(() => {
    const { store } = window.__editor;
    store.transact("harness", (d) => {
      d.annotations = [];
    });
  });
  const C = await snap();
  await page.evaluate(() => window.__editor.store.undo());
  const region = diff(A, C).box;
  check(!!region, "edit: the label draws nothing?");
  // Double-click the label → in-place editor.
  const st = await state(page);
  const vr = await page.evaluate(() => window.__editor.controller.client.lastFrame.videoRect);
  const a = await page.evaluate(() => window.__editor.store.getState().project.annotations[0]);
  const pt = toClient(st, { x: vr.x + a.x * vr.width, y: vr.y + a.y * vr.height }, "card");
  await page.mouse.dblclick(Math.round(pt.x), Math.round(pt.y));
  await page.waitForTimeout(200);
  const editing = await page.evaluate(() => document.activeElement?.tagName === "INPUT" && document.activeElement.value);
  check(editing === a.text, `edit: the label editor did not open (active: ${editing})`);
  const B = await snap(); // editor open: the engine must NOT draw the label
  await page.screenshot({ path: join(OUT, "edit-open.png") });
  const box = await page.evaluate(() => {
    const r = document.querySelector(".cc-stagewrap").getBoundingClientRect();
    return { x: r.left, y: r.top, width: r.width, height: r.height };
  });
  await page.screenshot({ path: join(OUT, "edit-open-stage.png"), clip: box });
  if (region) {
    const pad = 6;
    const R = { x: Math.max(0, region.x - pad), y: Math.max(0, region.y - pad), width: Math.min(A.width - region.x + pad, region.width + 2 * pad), height: Math.min(A.height - region.y + pad, region.height + 2 * pad) };
    res.labelRegion = R;
    res.openVsRemoved = diff(B, C, R);
    res.openVsDrawn = diff(B, A, R);
    check(res.openVsRemoved.changed === 0 && res.openVsRemoved.max <= 8, `edit: engine still draws the label under the editor (vs removed: ${JSON.stringify(res.openVsRemoved)})`);
    check(res.openVsDrawn.changed > 50, `edit: editing did not change the raster (vs drawn: ${JSON.stringify(res.openVsDrawn)})`);
  }
  // Export is unaffected: one frame exported while editing == one exported after.
  const exportFrame = () =>
    page.evaluate(async () => {
      const client = window.__editor.controller.client;
      const r = await client.export({ start: 1.5, end: 1.5 + 1 / 30, width: 640, height: 360, fps: 30, captureFrames: [0], audio: false, codec: "avc" });
      return Array.from(new Uint8Array(r.captures[0].rgba));
    });
  const exportEditing = await exportFrame();
  // Type + Enter commits; the label comes back with the new text.
  await page.keyboard.press("Meta+A");
  await page.keyboard.type("Edited ✓");
  await page.keyboard.press("Enter");
  await page.waitForTimeout(200);
  const text = await page.evaluate(() => window.__editor.store.getState().project.annotations[0].text);
  check(text === "Edited ✓", `edit: commit wrote "${text}"`);
  const D = await snap();
  if (region) {
    res.committedVsRemoved = diff(D, C, res.labelRegion);
    check(res.committedVsRemoved.changed > 50, "edit: the label did not come back after the edit");
  }
  await page.screenshot({ path: join(OUT, "edit-committed.png") });
  // Re-open the editor on the committed text, export again: identical to an export with no editor.
  await page.waitForTimeout(600);
  await page.mouse.dblclick(Math.round(pt.x), Math.round(pt.y));
  await page.waitForTimeout(200);
  const exportWhileEditing2 = await exportFrame();
  await page.keyboard.press("Escape");
  await page.waitForTimeout(150);
  const exportIdle = await exportFrame();
  const exportIdle2 = await exportFrame();
  const cmp = (x, y) => {
    let max = 0, x0 = 1e9, y0 = 1e9, x1 = -1, y1 = -1;
    for (let i = 0; i < x.length; i += 4) {
      const d = Math.max(Math.abs(x[i] - y[i]), Math.abs(x[i + 1] - y[i + 1]), Math.abs(x[i + 2] - y[i + 2]));
      if (d > max) max = d;
      if (d > 0) {
        const px = (i / 4) % 640, py = Math.floor(i / 4 / 640);
        x0 = Math.min(x0, px); y0 = Math.min(y0, py); x1 = Math.max(x1, px); y1 = Math.max(y1, py);
      }
    }
    return { max, box: x1 >= 0 ? [x0, y0, x1 - x0 + 1, y1 - y0 + 1] : null };
  };
  const same = exportWhileEditing2.length === exportIdle.length;
  const vsIdle = cmp(exportWhileEditing2, exportIdle);
  res.exportIdleVsIdle = cmp(exportIdle, exportIdle2);
  const maxd = vsIdle.max;
  check(same && maxd === 0, `edit: export differs while the label editor is open (${JSON.stringify(vsIdle)}; idle vs idle ${JSON.stringify(res.exportIdleVsIdle)})`);
  res.exportIdenticalWhileEditing = same && maxd === 0;
  res.exportFirstFrameBytes = exportEditing.length;
  report.results.edit = res;
  log(`edit: while open vs removed ${JSON.stringify(res.openVsRemoved)}; vs drawn changed ${res.openVsDrawn?.changed}; after commit changed ${res.committedVsRemoved?.changed}; export identical while editing: ${res.exportIdenticalWhileEditing}`);
  await page.close();
}

try {
  if (ONLY.has("drags")) {
    await drags();
    await zoomBlockDrags();
  }
  if (ONLY.has("pill")) await pill();
  if (ONLY.has("edit")) await edit();
  if (ONLY.has("camera-seek")) {
    // The fixture's own webcam (640×480 h264, GOP 29), then a stress camera
    // (4K HEVC, GOP 120 @ 60 fps) whose mid-GOP seeks decode far slower than
    // the 1080p screen — the case where a screen-only seek showed a stale frame.
    await cameraSeek({ name: "fixture13", url: "/.fixtures/parity/13-camera-bubble-layouts/camera.mp4", fps: 30 });
    await cameraSeek({ name: "stress-hevc4k", url: "/.fixtures/hevc-4k.mp4", fps: 60 });
  }
} catch (e) {
  failures.push(`harness error: ${e?.stack ?? e}`);
} finally {
  report.consoleErrors = consoleErrors.slice(0, 50);
  report.failures = failures;
  writeFileSync(join(OUT, "report.json"), JSON.stringify(report, null, 2));
  await browser.close();
}
if (consoleErrors.length) log(`console (${consoleErrors.length}):\n  ${consoleErrors.slice(0, 10).join("\n  ")}`);
log(failures.length ? `FAIL:\n  ${failures.join("\n  ")}` : "PASS");
process.exit(failures.length ? 1 : 0);
