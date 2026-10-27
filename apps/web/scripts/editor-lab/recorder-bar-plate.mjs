#!/usr/bin/env node
/**
 * Recorder-bar plate gate (DEV ONLY) — the owner's rules "keep the recording
 * bar visible at all times — it's the video that hides it" and "output video
 * must always hide the recording bar", proven on REAL takes.
 *
 *   node scripts/editor-lab/recorder-bar-plate.mjs [--url http://localhost:3200] [--out <dir>]
 *        [--only plate,plate-drag-live,plate-drag-stale,plate-multi,window-shown,defect-plate-off] [--headed]
 *
 *   plate             whole display, floating controls: they open AFTER the
 *                     plate, stay up all take (Stop pressed in them), and are
 *                     in ZERO recorded frames; nothing is cut
 *   plate-drag-live   the controls are dragged mid-take, their reported
 *                     position following live while the capture lags 50 ms:
 *                     still in zero frames (the rect hold covers the lag)
 *   plate-drag-stale  dragged while the reported position stays where the
 *                     drag began (macOS reports a move at its end): frames
 *                     DO show them past the paint — every one of them must be
 *                     logged and cut from the project (the beacon checks)
 *   plate-multi       two displays (`screen.isExtended`): no floating over a
 *                     display — the bar hides and cuts, and the setup says why
 *   window-shown      a window share without floating controls (Safari,
 *                     Firefox): the bar STAYS on screen while the page is in
 *                     front, and every frame showing it is cut
 *   defect-plate-off  the worker paints nothing (`__ccPlateDefect = "off"`):
 *                     MUST fail — the blob check sees the controls
 *
 * What the page captures. Headless Chrome has no real display to share (its
 * fake "screen" is a synthetic test card, and the floating window is never
 * on it), so the display is SYNTHESIZED: a canvas desktop at the screen's
 * device size (2× here) holding Chrome's own tab capture of this page (real
 * composited frames) and, while it's open, the floating window drawn where
 * its (patched) screenX/screenY/outerWidth/outerHeight put it, 50 ms late —
 * a title bar, the beacon the product renders at its top (red stripe, dark
 * band), and the controls in marker cyan. The share reports "monitor", the
 * canvas size, no capture handle. Everything after getDisplayMedia is the
 * product: the plate grab, Document PiP, the worker, mediabunny, OPFS.
 *
 * Test-only instrumentation (an init script; nothing in the product): every
 * `[data-rec-ui]` element on the page paints marker cyan #00FFFF, a timecode
 * strip (performance.now() in ms) is drawn at the page's top-left every
 * frame, visibility/focus can be overridden (leave/back), and the publish
 * API answers 404 so the take stays in OPFS, where the gate reads it.
 *
 * Checks decode recording.mov with ffmpeg and look for the marker as a
 * connected blob (structural), never a mean. Exit 1 on any failed check.
 */
import { execFileSync, spawn } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { chromium } from "playwright-core";

const args = process.argv.slice(2);
const opt = (name, def) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : def;
};
const BASE = opt("url", "http://localhost:3200");
const OUT = opt("out", "/tmp/capturecat-bar-plate");
const HEADED = args.includes("--headed");
const API = "http://localhost:8787"; // .env.development VITE_API_URL — answered 404 here, never reached
const ALL = ["plate", "plate-drag-live", "plate-drag-stale", "plate-multi", "window-shown", "defect-plate-off"];
const ONLY = opt("only", ALL.join(",")).split(",");
mkdirSync(OUT, { recursive: true });

const SELF_TITLE = "CC-PLATE-GATE";
const VIEW = { width: 1280, height: 800 };
const DPR = 2;
/** Frames are analysed at CSS-px size: the timecode's cells are 16 px. */
const AW = VIEW.width;
const AH = VIEW.height;
const CELL = 16;
const MIN_BLOB = 40;
/** The synthetic floating window (CSS px): title bar height and where it opens. */
const PIP = { x: 816, y: 672, w: 440, h: 100, title: 28 };
/** clips.ts's clip-edge tolerance: a frame this close to a kept clip still shows. */
const EDGE_TOLERANCE = 1 / 30;

const log = (...a) => console.log(...a);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const SCENARIOS = {
  plate: { fake: "desktop", surface: "monitor", float: true, countdown: 1, steps: "still", stop: "floating", expect: { mode: "plate", pip: true, cuts: false } },
  "plate-drag-live": { fake: "desktop", surface: "monitor", float: true, countdown: 1, steps: "drag-live", stop: "floating", expect: { mode: "plate", pip: true, cuts: false } },
  "plate-drag-stale": { fake: "desktop", surface: "monitor", float: true, countdown: 1, steps: "drag-stale", stop: "floating", expect: { mode: "plate", pip: true, cuts: true, rawShows: true } },
  "plate-multi": { fake: "desktop", surface: "monitor", float: true, countdown: 1, multi: true, steps: "short-away", stop: "page", expect: { mode: "reveal", pip: false, cuts: true, rawShows: true } },
  "window-shown": { fake: "window", surface: "window", float: false, countdown: 1, steps: "short-away", stop: "page", expect: { mode: "shown", pip: false, cuts: true, rawShows: true } },
  "defect-plate-off": { fake: "desktop", surface: "monitor", float: true, countdown: 1, steps: "still", stop: "floating", defect: "off", expect: { mode: "plate", pip: true, cuts: false }, mustFail: ["raw: the controls in zero frames", "project: every frame showing recorder UI is cut"] },
};

// ── the page's instrumentation (init script) ────────────────────────────────

function harnessInit(cfg) {
  if (!location.pathname.startsWith("/editor-lab/dashboard")) return;
  window.__ccRecorderProbe = [];
  if (cfg.defect) window.__ccPlateDefect = cfg.defect;
  if (cfg.multi) Object.defineProperty(Screen.prototype, "isExtended", { configurable: true, get: () => true });

  // Leaving and coming back to the tab.
  let hidden = false;
  let focused = true;
  Object.defineProperty(Document.prototype, "visibilityState", { configurable: true, get: () => (hidden ? "hidden" : "visible") });
  Object.defineProperty(Document.prototype, "hidden", { configurable: true, get: () => hidden });
  Document.prototype.hasFocus = function () {
    return this === document ? focused : true;
  };
  window.__ccSim = {
    leave() {
      focused = false;
      window.dispatchEvent(new FocusEvent("blur"));
      hidden = true;
      document.dispatchEvent(new Event("visibilitychange"));
    },
    back() {
      hidden = false;
      document.dispatchEvent(new Event("visibilitychange"));
      focused = true;
      window.dispatchEvent(new FocusEvent("focus"));
    },
  };

  // The floating window: where it really is (drawn on the desktop) and where
  // it SAYS it is (its patched screenX/screenY/outer*/inner*).
  const pip = cfg.pip;
  window.__ccPip = { actual: { ...pip }, reported: { ...pip }, history: [], openedAt: null };
  const dpip = window.documentPictureInPicture;
  if (dpip) {
    const request = dpip.requestWindow.bind(dpip);
    dpip.requestWindow = async (o) => {
      const w = await request(o);
      const st = window.__ccPip;
      st.openedAt = performance.now();
      const def = (k, get) => Object.defineProperty(w, k, { configurable: true, get });
      def("screenX", () => st.reported.x);
      def("screenY", () => st.reported.y);
      def("outerWidth", () => st.reported.w);
      def("outerHeight", () => st.reported.h);
      def("innerWidth", () => st.reported.w);
      def("innerHeight", () => st.reported.h - pip.title);
      return w;
    };
  }

  const tabCapture = (real, md) =>
    real.call(md, { video: { displaySurface: "browser", frameRate: { ideal: 60, max: 60 } }, audio: false, selfBrowserSurface: "include", preferCurrentTab: true });

  if (cfg.fake === "desktop") {
    // A whole display: this page (tab capture) at 0,0 + the floating window.
    const real = MediaDevices.prototype.getDisplayMedia;
    MediaDevices.prototype.getDisplayMedia = async function () {
      const tab = await tabCapture(real, this);
      const video = document.createElement("video");
      video.muted = true;
      video.playsInline = true;
      video.srcObject = tab;
      await video.play();
      const W = screen.width * cfg.dpr;
      const H = screen.height * cfg.dpr;
      const c = document.createElement("canvas");
      c.width = W;
      c.height = H;
      const g = c.getContext("2d");
      const st = window.__ccPip;
      const LAG = 50; // ms: a display capture shows the screen as it was a little while ago
      const paint = () => {
        const now = performance.now();
        st.history.push({ t: now, ...st.actual });
        while (st.history.length > 2 && st.history[1].t <= now - LAG) st.history.shift();
        g.fillStyle = "#1d2630";
        g.fillRect(0, 0, W, H);
        g.drawImage(video, 0, 0, innerWidth * cfg.dpr, innerHeight * cfg.dpr);
        const w = window.documentPictureInPicture?.window;
        if (w && !w.closed && st.openedAt !== null && now - st.openedAt > 120) {
          const at = st.history[0];
          const s = cfg.dpr;
          g.fillStyle = "rgba(0,0,0,0.35)"; // its shadow
          g.fillRect((at.x - 6) * s, (at.y + 4) * s, (at.w + 12) * s, (at.h + 10) * s);
          g.fillStyle = "#3a3a3c"; // title bar
          g.fillRect(at.x * s, at.y * s, at.w * s, pip.title * s);
          g.fillStyle = "#00ffff"; // the controls
          g.fillRect(at.x * s, (at.y + pip.title) * s, at.w * s, (at.h - pip.title) * s);
          g.fillStyle = "#ff3b30"; // the beacon
          g.fillRect(at.x * s, (at.y + pip.title) * s, at.w * s, 4 * s);
          g.fillStyle = "#050505";
          g.fillRect(at.x * s, (at.y + pip.title + 4) * s, at.w * s, 4 * s);
        }
        requestAnimationFrame(paint);
      };
      requestAnimationFrame(paint);
      const s = c.captureStream(60);
      const t = s.getVideoTracks()[0];
      const settings = t.getSettings.bind(t);
      t.getSettings = () => ({ ...settings(), displaySurface: "monitor", width: W, height: H });
      t.getCaptureHandle = () => null;
      t.addEventListener("ended", () => tab.getTracks().forEach((x) => x.stop()));
      return s;
    };
  } else if (cfg.fake === "window") {
    // This browser's window shared: this tab, reported as a window.
    const real = MediaDevices.prototype.getDisplayMedia;
    MediaDevices.prototype.getDisplayMedia = async function () {
      const s = await tabCapture(real, this);
      const t = s.getVideoTracks()[0];
      const settings = t.getSettings.bind(t);
      t.getSettings = () => ({ ...settings(), displaySurface: "window" });
      t.getCaptureHandle = () => null;
      return s;
    };
  }

  const install = () => {
    const style = document.createElement("style");
    style.id = "cc-gate";
    style.textContent =
      "[data-rec-ui]{background:#00ffff !important;background-image:none !important;border-color:#00ffff !important;" +
      "box-shadow:none !important;backdrop-filter:none !important;filter:none !important;color:#00ffff !important}" +
      "[data-rec-ui]>*{opacity:0 !important}";
    document.head.appendChild(style);
    const c = document.createElement("canvas");
    c.width = 26 * 16;
    c.height = 16;
    c.style.cssText = "position:fixed;left:0;top:0;width:416px;height:16px;z-index:2147483647;pointer-events:none";
    document.documentElement.appendChild(c);
    const g = c.getContext("2d");
    const draw = () => {
      const v = Math.round(performance.now()) & 0xffffff;
      g.fillStyle = "#fff";
      g.fillRect(0, 0, 16, 16);
      g.fillStyle = "#000";
      g.fillRect(16, 0, 16, 16);
      for (let i = 0; i < 24; i++) {
        g.fillStyle = (v >> (23 - i)) & 1 ? "#fff" : "#000";
        g.fillRect((i + 2) * 16, 0, 16, 16);
      }
      requestAnimationFrame(draw);
    };
    requestAnimationFrame(draw);
  };
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", install);
  else install();
}

// ── one take ────────────────────────────────────────────────────────────────

const probeOf = (page) => page.evaluate(() => window.__ccRecorderProbe ?? []);
const waitProbe = (page, kind, timeout = 20_000) =>
  page.waitForFunction((k) => (window.__ccRecorderProbe ?? []).some((e) => e.kind === k), kind, { timeout });

async function domState(page) {
  return page.evaluate(() => {
    const root = document.querySelector("[data-recorder-dock-root]");
    const cs = root ? getComputedStyle(root) : null;
    return { concealed: root?.getAttribute("data-concealed") ?? null, opacity: cs ? Number(cs.opacity) : null, visibility: cs?.visibility ?? null };
  });
}

/** Move the floating window along a path (CSS px); `live` = its reported position follows each step. */
async function drag(page, live, steps = 24, stepMs = 40) {
  await page.evaluate(
    async ({ live, steps, stepMs }) => {
      const st = window.__ccPip;
      const from = { ...st.actual };
      for (let i = 1; i <= steps; i++) {
        const k = i / steps;
        st.actual = { ...st.actual, x: Math.round(from.x - 620 * k), y: Math.round(from.y - 420 * k + 60 * Math.sin(k * Math.PI)) };
        if (live) st.reported = { ...st.actual };
        await new Promise((r) => setTimeout(r, stepMs));
      }
      st.reported = { ...st.actual }; // the move is reported (at the latest when it ends)
    },
    { live, steps, stepMs },
  );
}

async function runSteps(page, sc, notes) {
  const sim = (fn) => page.evaluate((f) => window.__ccSim[f](), fn);
  switch (sc.steps) {
    case "still":
      await sleep(1200);
      notes.push({ step: "mid-take", dom: await domState(page) });
      await sleep(1800);
      break;
    case "drag-live":
    case "drag-stale":
      await sleep(1000);
      notes.push({ step: "before the drag", dom: await domState(page) });
      await drag(page, sc.steps === "drag-live");
      await sleep(1500);
      break;
    case "short-away":
      await sleep(1200); // on the page
      notes.push({ step: "on the page", dom: await domState(page) });
      await sim("leave");
      await sleep(1500);
      notes.push({ step: "away", dom: await domState(page) });
      await sim("back"); // came back to stop
      await sleep(900);
      notes.push({ step: "back", dom: await domState(page) });
      break;
  }
}

async function recordTake(browser, name, sc) {
  const context = await browser.newContext({ viewport: VIEW, screen: VIEW, deviceScaleFactor: DPR });
  await context.grantPermissions(["camera", "microphone"], { origin: BASE });
  await context.addInitScript(harnessInit, { fake: sc.fake, defect: sc.defect ?? null, multi: !!sc.multi, pip: PIP, dpr: DPR });
  // Nothing leaves the machine: the cloud API answers 404, so the take stays in OPFS.
  await context.route(`${API}/**`, (route) =>
    route.fulfill({ status: route.request().method() === "OPTIONS" ? 204 : 404, headers: { "Access-Control-Allow-Origin": BASE, "Access-Control-Allow-Credentials": "true", "Access-Control-Allow-Headers": "*", "Access-Control-Allow-Methods": "*" }, body: "" }),
  );
  const errors = [];
  const page = await context.newPage();
  page.on("pageerror", (e) => errors.push(`pageerror: ${e.message}`));
  page.on("console", (m) => {
    if (m.type() === "error" && !/status of 404|Failed to load resource|CloudApiError|404/.test(m.text())) errors.push(`console: ${m.text()}`);
  });
  await page.goto(`${BASE}/editor-lab/dashboard?page=record&cloud=network`, { waitUntil: "domcontentloaded" });
  await page.evaluate(
    (p) => localStorage.setItem("cc.recorder.prefs", JSON.stringify(p)),
    { surface: sc.surface, micId: null, camId: null, systemAudio: false, countdown: sc.countdown, limit: 0, floatControls: sc.float },
  );
  await page.reload({ waitUntil: "domcontentloaded" });
  await page.waitForSelector("[data-recorder-dock]", { timeout: 60_000 });
  await page.evaluate((t) => setInterval(() => document.title !== t && (document.title = t), 50), SELF_TITLE);
  await page.waitForFunction((t) => document.title === t, SELF_TITLE);
  await sleep(1000);

  await page.getByRole("button", { name: "Choose what to record", exact: true }).click();
  await page.waitForFunction(() => !document.querySelector('button[aria-label="Record"]')?.disabled, null, { timeout: 15_000 });
  await sleep(300);
  const setupNotices = await page.evaluate(() => Array.from(document.querySelectorAll('[data-rec-ui="notice"]')).map((n) => n.textContent ?? ""));
  await page.getByRole("button", { name: "Record", exact: true }).click();
  await waitProbe(page, "start", 30_000);
  const notes = [{ step: "setup notices", notices: setupNotices }];
  const pip = context.pages().find((p) => p !== page && !p.url().includes("/editor-lab/")) ?? null;
  notes.push({
    step: "floating window",
    open: pip !== null,
    bar: pip ? await pip.locator('[aria-label="Recording panel"]').count() : 0,
    stop: pip ? await pip.getByRole("button", { name: "Stop", exact: true }).count() : 0,
    beacon: pip ? await pip.locator("[data-plate-beacon]").count() : 0,
  });
  try {
    await runSteps(page, sc, notes);
    if (sc.stop === "floating" && pip) await pip.getByRole("button", { name: "Stop", exact: true }).click({ timeout: 10_000 });
    else await page.getByRole("button", { name: "Stop", exact: true }).first().click({ timeout: 10_000 });
    await waitProbe(page, "take", 30_000);
  } catch (error) {
    const dir = join(OUT, name);
    mkdirSync(dir, { recursive: true });
    await page.screenshot({ path: join(dir, "FAILED-page.png") }).catch(() => undefined);
    writeFileSync(join(dir, "FAILED-probe.json"), JSON.stringify({ probe: await probeOf(page).catch(() => null), notes, errors }, null, 2));
    await context.close();
    throw error;
  }
  const probe = await probeOf(page);
  const take = probe.find((e) => e.kind === "take");
  // recording.mov, straight from OPFS (the upload 404s; the take is kept).
  const b64 = await page.evaluate(async (id) => {
    const root = await (await navigator.storage.getDirectory()).getDirectoryHandle("capturecat-recordings");
    const f = await (await (await root.getDirectoryHandle(id)).getFileHandle("recording.mov")).getFile();
    const bytes = new Uint8Array(await f.arrayBuffer());
    let s = "";
    for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    return btoa(s);
  }, take.id);
  // Which source times the project would show (the app's own cut + clips.ts).
  const visibleAt = (times) =>
    page.evaluate(
      async ({ duration, reveals, times }) => {
        const model = await import("/src/editor/core/model/index.ts");
        const clips = await import("/src/editor/core/time/clips.ts");
        const bh = await import("/src/editor/record/barHidden.ts");
        const p = model.newProject({ duration });
        bh.applyRevealCuts(p, bh.cutsForReveals(duration, reveals));
        return { visible: times.map((t) => clips.hasVisibleVideo(p, t)), trimStart: p.trimStart, trimEnd: p.trimEnd, clips: p.videoClipSegments.map((c) => [c.startTime, c.endTime]) };
      },
      { duration: take.duration, reveals: take.uiReveals, times },
    );
  return { probe, take, mov: Buffer.from(b64, "base64"), notes, errors, visibleAt, close: () => context.close() };
}

// ── frames ──────────────────────────────────────────────────────────────────

function ptsOf(file) {
  const txt = execFileSync("ffprobe", ["-v", "error", "-select_streams", "v:0", "-show_entries", "frame=best_effort_timestamp_time", "-of", "csv=p=0", file]).toString();
  return txt.trim().split("\n").filter(Boolean).map((l) => parseFloat(l.split(",")[0]));
}

async function decode(file, w, h, onFrame) {
  const ff = spawn("ffmpeg", ["-v", "error", "-i", file, "-map", "0:v:0", "-fps_mode", "passthrough", "-vf", `scale=${w}:${h}:flags=area`, "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], { stdio: ["ignore", "pipe", "inherit"] });
  const size = w * h * 3;
  const frame = Buffer.alloc(size);
  let off = 0;
  let n = 0;
  for await (const chunk of ff.stdout) {
    let p = 0;
    while (p < chunk.length) {
      const k = Math.min(size - off, chunk.length - p);
      chunk.copy(frame, off, p, p + k);
      off += k;
      p += k;
      if (off === size) {
        onFrame(n++, frame);
        off = 0;
      }
    }
  }
  return n;
}

function savePng(file, t, out) {
  execFileSync("ffmpeg", ["-v", "error", "-y", "-ss", String(Math.max(0, t)), "-i", file, "-frames:v", "1", out]);
}

/** Largest 4-connected blob of marker cyan (r ≤ 140 allows its P3 encoding). */
function markerBlob(frame, w, h) {
  const mask = new Uint8Array(w * h);
  let count = 0;
  for (let i = 0, p = 0; i < w * h; i++, p += 3) {
    if (frame[p] <= 140 && frame[p + 1] >= 220 && frame[p + 2] >= 220) {
      mask[i] = 1;
      count++;
    }
  }
  if (count < MIN_BLOB) return { count, blob: 0, box: null };
  let best = 0;
  let box = null;
  const stack = new Int32Array(w * h);
  for (let i = 0; i < w * h; i++) {
    if (mask[i] !== 1) continue;
    let sp = 0;
    let size = 0;
    let x0 = w, y0 = h, x1 = 0, y1 = 0;
    stack[sp++] = i;
    mask[i] = 2;
    while (sp) {
      const j = stack[--sp];
      size++;
      const x = j % w;
      const y = (j / w) | 0;
      x0 = Math.min(x0, x); y0 = Math.min(y0, y); x1 = Math.max(x1, x); y1 = Math.max(y1, y);
      if (x > 0 && mask[j - 1] === 1) (mask[j - 1] = 2), (stack[sp++] = j - 1);
      if (x < w - 1 && mask[j + 1] === 1) (mask[j + 1] = 2), (stack[sp++] = j + 1);
      if (y > 0 && mask[j - w] === 1) (mask[j - w] = 2), (stack[sp++] = j - w);
      if (y < h - 1 && mask[j + w] === 1) (mask[j + w] = 2), (stack[sp++] = j + w);
    }
    if (size > best) {
      best = size;
      box = [x0, y0, x1, y1];
    }
  }
  return { count, blob: best, box };
}

function timecode(frame, w) {
  const lum = (cx) => {
    let s = 0;
    for (const dy of [-1, 0, 1]) {
      for (const dx of [-1, 0, 1]) {
        const p = (((CELL >> 1) + dy) * w + cx * CELL + (CELL >> 1) + dx) * 3;
        s += 0.299 * frame[p] + 0.587 * frame[p + 1] + 0.114 * frame[p + 2];
      }
    }
    return s / 9;
  };
  const white = lum(0);
  const black = lum(1);
  if (white - black < 100) return null;
  const thr = (white + black) / 2;
  let v = 0;
  for (let i = 0; i < 24; i++) v = v * 2 + (lum(i + 2) > thr ? 1 : 0);
  return v;
}

// ── analysis ────────────────────────────────────────────────────────────────

async function analyse(name, sc, rec) {
  const dir = join(OUT, name);
  mkdirSync(dir, { recursive: true });
  const results = [];
  const check = (ok, label, detail = "") => {
    results.push({ ok, label, detail });
    log(`${ok ? "  ok  " : "  FAIL"} ${label}${detail ? ` — ${detail}` : ""}`);
  };
  const file = join(dir, "recording.mov");
  writeFileSync(file, rec.mov);
  writeFileSync(join(dir, "probe.json"), JSON.stringify({ probe: rec.probe, notes: rec.notes, errors: rec.errors }, null, 2));

  const start = rec.probe.findLast((e) => e.kind === "start");
  const plateEv = rec.probe.find((e) => e.kind === "plate");
  const pipEv = rec.probe.find((e) => e.kind === "pip");
  const lostEv = rec.probe.filter((e) => e.kind === "plate-lost");
  const stats = rec.probe.filter((e) => e.kind === "plate-stats").at(-1);
  log(`  take ${rec.take.id}: ${rec.take.duration.toFixed(2)} s, mode ${start?.mode}, uiReveals ${JSON.stringify(rec.take.uiReveals.map(([a, b]) => [+a.toFixed(3), +b.toFixed(3)]))}`);
  if (stats) log(`  plate worker: ${stats.frames} frames, ${stats.painted} painted, ${stats.checks} checks (${stats.failed} failed), draw ${stats.meanMs.toFixed(2)} ms mean / ${stats.maxMs.toFixed(2)} max`);
  if (lostEv.length) log(`  plate lost: ${JSON.stringify(lostEv.map((e) => [Math.round(e.at), e.verdict]))}`);

  check(rec.errors.length === 0, "no page errors", rec.errors.slice(0, 3).join(" | "));
  check(start?.mode === sc.expect.mode, `take runs in "${sc.expect.mode}" mode`, String(start?.mode));

  // The controls, visible to the person all take.
  const fw = rec.notes.find((n) => n.step === "floating window");
  if (sc.expect.pip) {
    check(fw?.open && fw.bar > 0 && fw.stop > 0 && fw.beacon > 0, "the controls float in Picture-in-Picture, beacon on top, Stop in reach", JSON.stringify(fw));
    check(plateEv?.ok === true && pipEv?.open === true && plateEv.at < pipEv.at, "the plate was taken BEFORE the floating window opened",
      plateEv && pipEv ? `plate ${plateEv.at.toFixed(1)} ms, window ${pipEv.at.toFixed(1)} ms` : "missing");
    const mid = rec.notes.find((n) => n.step === "mid-take" || n.step === "before the drag")?.dom;
    check(mid?.concealed === "true", "the page's own dock steps aside (its tab may be on that display)", JSON.stringify(mid));
    const tip = rec.notes.find((n) => n.step === "setup notices")?.notices ?? [];
    check(tip.some((t) => /quiet corner/.test(t)), "setup tells you to park the controls over a quiet corner", tip.join(" | ").slice(0, 120));
  } else {
    check(!fw?.open, "no floating window", JSON.stringify(fw));
  }
  if (sc.multi) {
    const tip = rec.notes.find((n) => n.step === "setup notices")?.notices ?? [];
    check(tip.some((t) => /more than one display/.test(t)), "setup says why the controls won't float (several displays)", tip.join(" | ").slice(0, 120));
  }
  if (sc.expect.mode === "shown") {
    const on = rec.notes.find((n) => n.step === "on the page")?.dom;
    const away = rec.notes.find((n) => n.step === "away")?.dom;
    const back = rec.notes.find((n) => n.step === "back")?.dom;
    check(on?.concealed === "false" && on.opacity > 0.99, "the bar is ON SCREEN while you're on the page (mid-take)", JSON.stringify(on));
    check(away?.concealed === "true", "…off when you leave", JSON.stringify(away));
    check(back?.concealed === "false", "…and back when you return", JSON.stringify(back));
  }

  // Raw frames.
  const pts = ptsOf(file);
  const frames = [];
  await decode(file, AW, AH, (i, f) => frames.push({ i, pts: pts[i], wall: timecode(f, AW), ...markerBlob(f, AW, AH) }));
  const marked = frames.filter((f) => f.blob >= MIN_BLOB);
  const timed = frames.filter((f) => f.wall !== null);
  log(`  raw: ${frames.length} frames, ${timed.length} timecoded, ${marked.length} showing recorder UI`);
  check(frames.length > 60 && timed.length >= frames.length * 0.9, "raw frames are live (timecoded)", `${timed.length}/${frames.length}`);
  if (marked.length) savePng(file, marked[0].pts, join(dir, "raw-ui-visible.png"));
  savePng(file, frames[Math.floor(frames.length / 2)]?.pts ?? 0, join(dir, "raw-mid.png"));
  if (sc.expect.rawShows) {
    check(marked.length > 0, "raw DOES show recorder UI here (the gate can see it)", `${marked.length} frames`);
  } else {
    check(marked.length === 0, "raw: the controls in zero frames",
      marked.length ? `${marked.length} frames, e.g. pts ${marked.slice(0, 4).map((f) => f.pts.toFixed(3)).join(", ")} box ${JSON.stringify(marked[0].box)}` : `0/${frames.length}`);
  }

  // The project: every frame that shows recorder UI is cut; the rest stays.
  const vis = await rec.visibleAt([...marked.map((f) => f.pts), ...frames.map((f) => f.pts)]);
  const shownMarked = marked.filter((_, k) => vis.visible[k]);
  // The editor shows a clip's frames up to EDGE_TOLERANCE past its edges.
  const nearVisible = shownMarked.length;
  check(nearVisible === 0, "project: every frame showing recorder UI is cut",
    nearVisible ? `${nearVisible} visible, e.g. pts ${shownMarked.slice(0, 4).map((f) => f.pts.toFixed(3)).join(", ")}` : `${marked.length} cut`);
  const kept = vis.visible.slice(marked.length).filter(Boolean).length;
  log(`  project: trimStart ${vis.trimStart.toFixed(3)} trimEnd ${vis.trimEnd.toFixed(3)} clips ${JSON.stringify(vis.clips.map(([a, b]) => [+a.toFixed(3), +b.toFixed(3)]))}; ${kept}/${frames.length} frames kept`);
  if (sc.expect.cuts) {
    check(rec.take.uiReveals.length > 0 && kept > frames.length * 0.25, "something is cut, most of the take is kept", `${rec.take.uiReveals.length} spans, ${kept}/${frames.length} kept`);
  } else {
    check(rec.take.uiReveals.length === 0 && kept === frames.length, "nothing cut", `${rec.take.uiReveals.length} spans, ${kept}/${frames.length} kept`);
  }
  if (stats) {
    check(stats.meanMs < 4 && stats.frames > 60, "the plate worker keeps up (mean draw time per frame)", `${stats.meanMs.toFixed(2)} ms mean over ${stats.frames} frames`);
  }
  void EDGE_TOLERANCE;
  return results;
}

// ── run ─────────────────────────────────────────────────────────────────────

const browser = await chromium.launch({
  channel: "chrome",
  headless: !HEADED,
  args: [
    "--autoplay-policy=no-user-gesture-required",
    "--enable-gpu",
    "--ignore-gpu-blocklist",
    "--use-fake-ui-for-media-stream",
    "--use-fake-device-for-media-stream",
    `--auto-select-tab-capture-source-by-title=${SELF_TITLE}`,
  ],
});
log(`chrome ${browser.version()} → ${BASE}  (frames → ${OUT})`);
const report = {};
let failed = false;
try {
  for (const name of ONLY) {
    const sc = SCENARIOS[name];
    if (!sc) throw new Error(`unknown scenario ${name}`);
    log(`\n[${name}]`);
    let results;
    let rec = null;
    try {
      rec = await recordTake(browser, name, sc);
      results = await analyse(name, sc, rec);
    } catch (error) {
      results = [{ ok: false, label: "scenario ran", detail: String(error?.stack ?? error) }];
      log(`  FAIL scenario ran — ${error?.stack ?? error}`);
    } finally {
      await rec?.close().catch(() => undefined);
    }
    if (sc.mustFail) {
      const caught = sc.mustFail.filter((l) => results.some((r) => r.label === l && !r.ok));
      const ok = caught.length === sc.mustFail.length;
      log(`  ${ok ? "ok  " : "FAIL"} defect caught by: ${caught.join("; ") || "nothing — the gate is blind"}`);
      report[name] = { defect: sc.defect, caught, ok, results };
      if (!ok) failed = true;
    } else {
      report[name] = { ok: results.every((r) => r.ok), results };
      if (!report[name].ok) failed = true;
    }
  }
} finally {
  await browser.close();
}
writeFileSync(join(OUT, "report.json"), JSON.stringify(report, null, 2));
log(`\n${failed ? "FAILED" : "PASSED"} — ${Object.entries(report).map(([k, v]) => `${k} ${v.ok ? "ok" : "FAIL"}`).join(", ")}`);
process.exit(failed ? 1 : 0);
