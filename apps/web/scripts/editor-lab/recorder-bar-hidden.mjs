#!/usr/bin/env node
/**
 * Recorder-bar-hidden gate (DEV ONLY) — the owner's rule "output video must
 * always hide the recording bar", proven on REAL frames.
 *
 *   node scripts/editor-lab/recorder-bar-hidden.mjs [--url http://localhost:3200] [--out <dir>]
 *        [--only monitor,mediarecorder,edge,window-nopip,window-pip,tab-self,tab-other,restart,dialog,defect-no-hide]
 *        [--headed]
 *
 *   monitor        display, WebCodecs: hidden from the first frame; leave/come
 *                  back three times (one reveal spans a pause), Stop clicked
 *                  in the revealed bar → head untouched, middle cut into clips,
 *                  tail trimmed. Also exported WITHOUT its cuts (defect proof).
 *   mediarecorder  the same take on the Safari engine (forced in Chrome), ⌘⇧S
 *   edge           display, no countdown, camera on: the pointer rests on the
 *                  bottom edge (reveal), leaves (hide); Esc stops while hidden
 *   window-nopip   window share, floating controls off → as a display
 *   window-pip     window share + Document PiP: the page's UI stays hidden all
 *                  take (no reveals even on return); Stop pressed in the PiP
 *   tab-self       the REAL requestScreen() on a tab share that caught THIS tab
 *   tab-other      a tab share of another tab: the bar stays, nothing is cut
 *   restart        Restart pressed in a revealed bar: hidden again before the
 *                  new take's first frame
 *   dialog         demoing the dashboard itself, Log out mid-take: the house
 *                  "recording in progress" dialog is logged and cut; Stay
 *   defect-no-hide CSS forces the dock visible during the take: MUST fail
 *
 * Every scenario records a real take in headless Chrome on the REAL dashboard
 * (/editor-lab/dashboard?page=record: DashboardShell → RecorderProvider →
 * RecorderDock, the /app topology), publishes it through the real
 * publishTake (the cloud API and R2 are mocked in the browser — nothing
 * leaves the machine), exports the published project with the REAL web
 * exporter, and decodes both files with ffmpeg.
 *
 * What the page captures. Headless Chrome has no display of its own to share
 * (its fake "screen" is a synthetic green test card), so a display — or this
 * browser's window — is synthesized from the page itself: Chrome's own tab
 * capture of THIS tab (real composited frames, the same latency class as a
 * display capture), handed to the recorder with `displaySurface` reporting
 * "monitor"/"window" and no capture handle, exactly what a display share of
 * a screen showing this page delivers. `tab-self` runs the REAL
 * requestScreen() (`selfBrowserSurface: "exclude"`): Chrome's auto-select
 * ignores the exclusion and shares this very tab — the case the recorder
 * must catch by its capture handle. `tab-other` (a share of another tab) is
 * synthesized: an animated canvas reported as a "browser" surface carrying a
 * different tab's capture handle (headless auto-select only ever picks the
 * requesting tab).
 *
 * Test-only instrumentation (an init script; nothing in the product):
 *   marker     every recorder-UI element (`[data-rec-ui]`: bar, notices,
 *              bubble, the Record page's live badges/countdown/hint) paints
 *              solid cyan #00FFFF — a colour the default gradient background,
 *              the dashboard and the fake camera never produce (sRGB or P3)
 *   timecode   a 26-cell strip (white, black, 24 bits of performance.now()
 *              in ms) redrawn every frame at the top-left: each decoded frame
 *              says WHEN the page looked like that
 *   leave/back visibilityState / hasFocus overridden + visibilitychange,
 *              blur, focus dispatched — switching away and back to the tab
 *
 * Checks per scenario:
 *   first frame  the take's media zero (its first frame) comes after the
 *                hide was painted; the first raw frame is marker-free
 *   raw          every raw frame showing the marker was rendered while the
 *                page had logged the UI as on screen (structural: a marker
 *                blob, never a mean) — and the raw DOES show it in each
 *                reveal, which proves the gate can see the bar
 *   clock        each raw frame's pts vs the take clock's prediction from
 *                its timecode (first-frame offset, pauses) — the mapping cuts
 *                rely on
 *   cut          every raw marker frame falls where the published project
 *                shows no video (the app's own clips.ts, edge tolerance incl.)
 *   output       the exported movie: the marker in ZERO frames; and the
 *                exporter never rendered a raw marker frame (sourceIndices)
 * Defect proofs: `defect-no-hide` (CSS forces the dock visible) MUST fail,
 * and the monitor scenario's project exported WITHOUT its cuts MUST show the
 * marker — the gate fails when either half of the rule is broken.
 *
 * Exit 1 on any failed check. Frames, movies, project.json and report.json go to --out.
 */
import { execFileSync, spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { chromium } from "playwright-core";

const args = process.argv.slice(2);
const opt = (name, def) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : def;
};
const BASE = opt("url", "http://localhost:3200");
const OUT = opt("out", "/tmp/capturecat-bar-hidden");
const HEADED = args.includes("--headed");
const API = "http://localhost:8787"; // .env.development VITE_API_URL — every request to it is answered here
const ALL = ["monitor", "mediarecorder", "edge", "window-nopip", "window-pip", "tab-self", "tab-other", "restart", "dialog", "defect-no-hide"];
const ONLY = opt("only", ALL.join(",")).split(",");
mkdirSync(OUT, { recursive: true });

const SELF_TITLE = "CC-GATE-SELF";
const VIEW = { width: 1280, height: 800 };
/** Raw frames are analysed at half size: 8 px timecode cells. */
const RAW_W = 640;
const RAW_H = 400;
const CELL = 8;
const EXPORT = { width: 960, height: 540, fps: 30 };
/** barHidden.ts (REVEAL_PAD, CONCEAL_FADE_MS, PAINT_SLACK_MS) and clips.ts's clip-edge tolerance. */
const REVEAL_PAD = 0.1;
const PAINT_SLACK = 0.1;
const EDGE_TOLERANCE = 1 / 30;
const FRAME = 1 / 60;
/**
 * How far a frame's pts may sit from the take clock's prediction (its
 * timecode on the media clock) and still be cut: a frame drawn while the UI
 * was on screen lies inside [m(reveal), m(hide) + fade + 1 frame], the cut
 * spans [m(reveal) − pad, m(hide) + fade + slack + pad], and the editor shows
 * a clip's frames up to 1/30 s past its edges.
 */
const CLOCK_WINDOW = [-(REVEAL_PAD - EDGE_TOLERANCE), PAINT_SLACK - FRAME + REVEAL_PAD - EDGE_TOLERANCE];
/** A marker blob smaller than this (pixels at analysis size) is noise. */
const MIN_BLOB = 40;

const log = (...a) => console.log(...a);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const sha = (buf) => createHash("sha256").update(buf).digest("hex");

// ── scenarios ───────────────────────────────────────────────────────────────

/**
 * fake      synthesized share surface (this tab, reported as monitor/window); null = real requestScreen
 * steps     the take's script (see runSteps)
 * stop      how it ends: click Stop in the revealed bar · ⌘⇧S · Esc · Stop in the floating window
 * expect    mode the take must run in; whether reveals must happen; cuts expected
 */
const SCENARIOS = {
  monitor: { fake: "monitor", surface: "monitor", engine: "webcodecs", countdown: 1, float: false, steps: "full", stop: "click", expect: { mode: "reveal", reveals: 3, middleCut: true, tailCut: true }, noCutProof: true },
  mediarecorder: { fake: "monitor", surface: "monitor", engine: "mediarecorder", countdown: 1, float: false, steps: "full", stop: "shortcut-revealed", expect: { mode: "reveal", reveals: 3, middleCut: true, tailCut: true } },
  edge: { fake: "monitor", surface: "monitor", engine: "webcodecs", countdown: 0, camera: true, float: false, steps: "edge", stop: "escape", expect: { mode: "reveal", reveals: 1, middleCut: true, tailCut: false } },
  "window-nopip": { fake: "window", surface: "window", engine: "webcodecs", countdown: 1, float: false, steps: "short", stop: "click", expect: { mode: "reveal", reveals: 1, middleCut: false, tailCut: true } },
  "window-pip": { fake: "window", surface: "window", engine: "webcodecs", countdown: 1, float: true, steps: "away", stop: "floating", expect: { mode: "floating", reveals: 0 } },
  "tab-self": { fake: null, surface: "browser", engine: "webcodecs", countdown: 1, float: false, steps: "short", stop: "click", expect: { mode: "reveal", reveals: 1, middleCut: false, tailCut: true } },
  "tab-other": { fake: "other-tab", surface: "browser", engine: "webcodecs", countdown: 1, float: false, steps: "other", stop: "click", expect: { mode: "none", reveals: 0 } },
  dialog: { fake: "monitor", surface: "monitor", engine: "webcodecs", countdown: 1, float: false, steps: "dialog", stop: "shortcut", expect: { mode: "reveal", reveals: 1, middleCut: true, tailCut: false } },
  restart: { fake: "monitor", surface: "monitor", engine: "webcodecs", countdown: 1, float: false, steps: "restart", stop: "shortcut", expect: { mode: "reveal", reveals: 0, middleCut: false, tailCut: false } },
  "defect-no-hide": { fake: "monitor", surface: "monitor", engine: "webcodecs", countdown: 1, float: false, steps: "short", stop: "click", defect: "no-hide", expect: { mode: "reveal", reveals: 1 }, mustFail: ["raw: marker only while the UI was logged on screen", "output: marker in zero frames"] },
};

// ── the page's test instrumentation (init script) ───────────────────────────

function harnessInit(cfg) {
  if (!location.pathname.startsWith("/editor-lab/dashboard")) return;
  window.__ccRecorderProbe = [];
  if (cfg.engine === "mediarecorder") window.__ccRecorderEngine = "mediarecorder";

  // Leaving and coming back to the tab.
  let hidden = false;
  let focused = true;
  Object.defineProperty(Document.prototype, "visibilityState", { configurable: true, get: () => (hidden ? "hidden" : "visible") });
  Object.defineProperty(Document.prototype, "hidden", { configurable: true, get: () => hidden });
  Document.prototype.hasFocus = () => focused;
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

  // Another tab, shared: headless Chrome's tab auto-select only ever picks the
  // tab that asks, so the other tab is synthesized — an animated canvas
  // reported as a "browser" surface carrying a different tab's capture handle.
  if (cfg.fake === "other-tab") {
    MediaDevices.prototype.getDisplayMedia = async function () {
      const c = document.createElement("canvas");
      c.width = 1280;
      c.height = 800;
      const g = c.getContext("2d");
      const paint = (t) => {
        g.fillStyle = "#123";
        g.fillRect(0, 0, 1280, 800);
        g.fillStyle = "#ccc";
        g.fillRect((t / 4) % 1280, 300, 80, 80);
        // The same frame clock as this page's strip.
        const v = Math.round(performance.now()) & 0xffffff;
        g.fillStyle = "#fff";
        g.fillRect(0, 0, 16, 16);
        g.fillStyle = "#000";
        g.fillRect(16, 0, 16, 16);
        for (let i = 0; i < 24; i++) {
          g.fillStyle = (v >> (23 - i)) & 1 ? "#fff" : "#000";
          g.fillRect((i + 2) * 16, 0, 16, 16);
        }
        requestAnimationFrame(paint);
      };
      requestAnimationFrame(paint);
      const s = c.captureStream(60);
      const t = s.getVideoTracks()[0];
      const settings = t.getSettings.bind(t);
      t.getSettings = () => ({ ...settings(), displaySurface: "browser", width: 1280, height: 800 });
      t.getCaptureHandle = () => ({ handle: "capturecat-recorder:another-tab", origin: location.origin });
      return s;
    };
  } else if (cfg.fake) {
    // A display (or this browser's window) showing this page = this tab, captured.
    const real = MediaDevices.prototype.getDisplayMedia;
    MediaDevices.prototype.getDisplayMedia = async function () {
      const s = await real.call(this, {
        video: { displaySurface: "browser", frameRate: { ideal: 60, max: 60 } },
        audio: false,
        selfBrowserSurface: "include",
      });
      const t = s.getVideoTracks()[0];
      const settings = t.getSettings.bind(t);
      t.getSettings = () => ({ ...settings(), displaySurface: cfg.fake });
      t.getCaptureHandle = () => null; // a display share carries no tab's capture handle
      return s;
    };
  }

  const install = () => {
    const style = document.createElement("style");
    style.id = "cc-gate";
    style.textContent =
      "[data-rec-ui]{background:#00ffff !important;background-image:none !important;border-color:#00ffff !important;" +
      "box-shadow:none !important;backdrop-filter:none !important;filter:none !important;color:#00ffff !important}" +
      "[data-rec-ui]>*{opacity:0 !important}" +
      (cfg.defect === "no-hide"
        ? "[data-recorder-dock-root][data-concealed='true']{opacity:1 !important;visibility:visible !important}"
        : "");
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

// ── mock cloud (API + R2), every project id ────────────────────────────────

function corsFor(origin) {
  return {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Credentials": "true",
    "Access-Control-Allow-Headers": "Content-Type, If-Match, X-CaptureCat-History-Label, X-CaptureCat-History-Kind",
    "Access-Control-Allow-Methods": "GET, PUT, POST, PATCH, DELETE, OPTIONS",
  };
}

async function installCloud(context, seed = null) {
  const CORS = corsFor(BASE);
  const json = (route, status, body) =>
    route.fulfill({ status, headers: { ...CORS, "Content-Type": "application/json" }, body: JSON.stringify(body) });
  /** id → { revision, document, files: [{path, sha256, bytes, contentType}], staged, saves } */
  const projects = new Map();
  const objects = new Map(); // sha → Buffer
  if (seed) {
    projects.set(seed.id, { revision: 1, document: seed.document, files: seed.files, staged: null, saves: [] });
    for (const [k, v] of seed.objects) objects.set(k, v);
  }
  const filesOut = (p) =>
    p.files.map((f) => ({ ...f, source: f.source ?? null, url: `${BASE}/__mock-r2/${f.sha256}` }));

  // Anything else on the API host is answered here too: nothing reaches a real server.
  await context.route(`${API}/**`, (route) =>
    route.request().method() === "OPTIONS" ? route.fulfill({ status: 204, headers: CORS }) : json(route, 404, { error: "mock: not found" }),
  );
  await context.route(`${API}/api/cloud-projects**`, async (route) => {
    const req = route.request();
    const method = req.method();
    if (method === "OPTIONS") return route.fulfill({ status: 204, headers: CORS });
    const path = new URL(req.url()).pathname.replace(/^\/api\/cloud-projects/, "");
    if (path === "" && method === "GET") return json(route, 200, { projects: [] });
    const m = path.match(/^\/([0-9A-Fa-f-]{36})(\/.*)?$/);
    if (!m) return json(route, 404, { error: `mock: ${method} ${path}` });
    const id = m[1];
    const rest = m[2] ?? "";
    let p = projects.get(id);
    if (method === "PUT" && rest === "") {
      const body = JSON.parse(req.postData() ?? "{}");
      if (!p) projects.set(id, (p = { revision: 0, document: null, files: [], staged: null, saves: [] }));
      p.staged = body;
      const missing = body.files
        .filter((f) => !objects.has(f.sha256))
        .map((f) => ({ sha256: f.sha256, bytes: f.bytes, contentType: f.contentType, paths: [f.path], method: "PUT", uploadUrl: `${BASE}/__mock-r2/put/${f.sha256}`, headers: { "Content-Type": f.contentType } }));
      return json(route, 200, { projectId: id, revision: p.revision, documentSha256: null, missing, presentCount: body.files.length - missing.length, expiresIn: 900 });
    }
    if (!p) return json(route, 404, { error: "Project not found" });
    if (method === "POST" && rest === "/finalize") {
      const lost = (p.staged?.files ?? []).filter((f) => !objects.has(f.sha256));
      if (lost.length) return json(route, 409, { code: "objects_missing", missing: lost.map((f) => ({ sha256: f.sha256, paths: [f.path] })) });
      if (p.staged) p.files = p.staged.files;
      p.staged = null;
      return json(route, 200, { projectId: id, committed: true, revision: p.revision, fileCount: p.files.length, totalBytes: 0 });
    }
    if (method === "PUT" && rest === "/project") {
      const base = Number(String(req.headers()["if-match"] ?? "").replaceAll('"', ""));
      if (base !== p.revision) return json(route, 409, { code: "revision_conflict", revision: p.revision, document: p.document, updatedAt: new Date().toISOString() });
      p.document = req.postData() ?? "";
      p.revision += 1;
      p.saves.push(p.document);
      return json(route, 200, { revision: p.revision, documentSha256: sha(p.document), updatedAt: new Date().toISOString() });
    }
    if (method === "GET" && rest === "") {
      return json(route, 200, {
        projectId: id, name: "Gate take", revision: p.revision, documentSha256: p.document ? sha(p.document) : null,
        access: "owner", isOwner: true, orgId: null, updatedAt: new Date().toISOString(), document: p.document,
        files: filesOut(p), urlsExpireAt: new Date(Date.now() + 15 * 60_000).toISOString(),
      });
    }
    if (method === "GET" && rest === "/files") {
      return json(route, 200, { revision: p.revision, files: filesOut(p), urlsExpireAt: new Date(Date.now() + 15 * 60_000).toISOString() });
    }
    return json(route, 404, { error: `mock: ${method} ${path}` });
  });
  await context.route(`${BASE}/__mock-r2/**`, async (route) => {
    const req = route.request();
    const url = new URL(req.url());
    const put = url.pathname.match(/^\/__mock-r2\/put\/([0-9a-f]{64})$/);
    if (put && req.method() === "PUT") {
      const body = req.postDataBuffer() ?? Buffer.alloc(0);
      if (sha(body) !== put[1]) return route.fulfill({ status: 400, body: "hash mismatch" });
      objects.set(put[1], body);
      return route.fulfill({ status: 200, body: "" });
    }
    const get = url.pathname.match(/^\/__mock-r2\/([0-9a-f]{64})$/);
    return serveBytes(route, get ? objects.get(get[1]) : null);
  });
  return { projects, objects };
}

function serveBytes(route, bytes) {
  if (!bytes) return route.fulfill({ status: 404, body: "" });
  const range = route.request().headers()["range"];
  const m = range && /bytes=(\d+)-(\d*)/.exec(range);
  if (m) {
    const start = Number(m[1]);
    const end = m[2] ? Math.min(Number(m[2]), bytes.length - 1) : bytes.length - 1;
    return route.fulfill({
      status: 206,
      headers: { "Content-Range": `bytes ${start}-${end}/${bytes.length}`, "Accept-Ranges": "bytes", "Content-Type": "application/octet-stream" },
      body: bytes.subarray(start, end + 1),
    });
  }
  return route.fulfill({ status: 200, headers: { "Accept-Ranges": "bytes" }, body: bytes });
}

// ── one take ────────────────────────────────────────────────────────────────

async function launch(title) {
  return chromium.launch({
    channel: "chrome",
    headless: !HEADED,
    args: [
      "--autoplay-policy=no-user-gesture-required",
      "--enable-gpu",
      "--ignore-gpu-blocklist",
      "--use-fake-ui-for-media-stream",
      "--use-fake-device-for-media-stream",
      `--auto-select-tab-capture-source-by-title=${title}`,
    ],
  });
}

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

/** The take's script. Every step leaves the probe log a fact to check later. */
async function runSteps(page, sc, notes) {
  const sim = (fn) => page.evaluate((f) => window.__ccSim[f](), fn);
  const click = (name) => page.getByRole("button", { name, exact: true }).first().click({ timeout: 5000 });
  switch (sc.steps) {
    case "full": {
      await sleep(2000); // hidden; the page keeps focus — nothing comes back
      notes.push({ step: "hidden on the page", dom: await domState(page) });
      await sim("leave");
      await sleep(1500);
      await sim("back"); // reveal 1 (return) — spans the pause below
      await sleep(1000);
      notes.push({ step: "revealed after return", dom: await domState(page) });
      await click("Pause");
      await sleep(1000);
      await click("Resume");
      await sleep(600);
      await sim("leave");
      await sleep(2000);
      await sim("back"); // reveal 2
      await sleep(1000);
      await sim("leave");
      await sleep(1500);
      await sim("back"); // reveal 3 — came back to stop
      await sleep(800);
      break;
    }
    case "edge": {
      await sleep(1500);
      notes.push({ step: "hidden from the first frame (no countdown)", dom: await domState(page) });
      await page.mouse.move(640, 420);
      await page.mouse.move(640, VIEW.height - 1, { steps: 6 }); // rest on the bottom edge
      await sleep(1100);
      notes.push({ step: "edge reveal", dom: await domState(page) });
      await page.mouse.move(640, 260, { steps: 6 }); // leave the dock
      await sleep(1500);
      notes.push({ step: "edge hidden again", dom: await domState(page) });
      await sleep(1000);
      break;
    }
    case "short": {
      await sleep(1500);
      notes.push({ step: "hidden", dom: await domState(page) });
      await sim("leave");
      await sleep(1500);
      await sim("back"); // came back to stop
      await sleep(900);
      notes.push({ step: "revealed after return", dom: await domState(page) });
      break;
    }
    case "away": {
      await sleep(1500);
      await sim("leave");
      await sleep(1200);
      await sim("back"); // the controls float: the page's UI stays hidden
      await sleep(900);
      notes.push({ step: "back on the page, floating controls", dom: await domState(page) });
      break;
    }
    case "other": {
      await sleep(2500);
      notes.push({ step: "sharing another tab", dom: await domState(page) });
      break;
    }
    case "dialog": {
      await sleep(1500); // hidden; demoing the dashboard itself
      await page.getByRole("button", { name: "Account menu", exact: true }).click();
      await page.getByRole("menuitem", { name: "Log out" }).click(); // leaving /app mid-take → the house dialog
      await page.getByRole("alertdialog").waitFor({ timeout: 10_000 });
      await sleep(900);
      notes.push({ step: "leave-route dialog up", dom: await domState(page) });
      await page.getByRole("button", { name: "Stay", exact: true }).click();
      await sleep(1500);
      notes.push({ step: "stayed", dom: await domState(page) });
      break;
    }
    case "restart": {
      await sleep(1200);
      await sim("leave");
      await sleep(800);
      await sim("back"); // revealed — Restart is pressed in the bar
      await sleep(700);
      await click("Restart");
      await click("Restart"); // "Restart recording from beginning?"
      await page.waitForFunction(() => (window.__ccRecorderProbe ?? []).filter((e) => e.kind === "start").length >= 2, null, { timeout: 30_000 });
      await sleep(1500);
      notes.push({ step: "restarted, page still focused", dom: await domState(page) });
      break;
    }
  }
}

async function recordTake(browser, name, sc) {
  const context = await browser.newContext({ viewport: VIEW, deviceScaleFactor: 1 });
  await context.grantPermissions(["camera", "microphone"], { origin: BASE });
  await context.addInitScript(harnessInit, { engine: sc.engine, fake: sc.fake, defect: sc.defect ?? null });
  const cloud = await installCloud(context);
  const errors = [];
  const page = await context.newPage();
  page.on("pageerror", (e) => errors.push(`pageerror: ${e.message}`));
  page.on("console", (m) => {
    if (m.type() === "error" && !/status of 404|Failed to load resource/.test(m.text())) errors.push(`console: ${m.text()}`);
  });
  const url = `${BASE}/editor-lab/dashboard?page=record&cloud=network`;
  await page.goto(url, { waitUntil: "domcontentloaded" });
  // Prefs (and the fake camera's id) before the recorder mounts for real.
  const camId = sc.camera
    ? await page.evaluate(async () => {
        const s = await navigator.mediaDevices.getUserMedia({ video: true });
        s.getTracks().forEach((t) => t.stop());
        return (await navigator.mediaDevices.enumerateDevices()).find((d) => d.kind === "videoinput")?.deviceId ?? null;
      })
    : null;
  await page.evaluate(
    (p) => {
      localStorage.setItem("cc.recorder.prefs", JSON.stringify(p));
      // The camera bubble parked top-right: its default bottom-right spot can
      // sit over the Record key once the bar widens with a long source name.
      localStorage.setItem("cc.cameraBubble.position", JSON.stringify({ h: "right", dx: 12, v: "top", dy: 72 }));
    },
    { surface: sc.surface, micId: "", camId, systemAudio: false, countdown: sc.countdown, limit: 0, floatControls: sc.float },
  );
  await page.reload({ waitUntil: "domcontentloaded" });
  await page.waitForSelector("[data-recorder-dock]", { timeout: 60_000 });
  // Held (the router sets its own title): Chrome auto-selects the tab capture by it.
  await page.evaluate((t) => setInterval(() => document.title !== t && (document.title = t), 50), SELF_TITLE);
  await page.waitForFunction((t) => document.title === t, SELF_TITLE);
  await sleep(1200); // devices open, encoders warm

  await page.getByRole("button", { name: "Choose what to record", exact: true }).click();
  await page.waitForFunction(() => !document.querySelector('button[aria-label="Record"]')?.disabled, null, { timeout: 15_000 });
  const surface = await page.evaluate(() => document.querySelector("[data-recorder-dock]")?.textContent ?? "");
  await page.getByRole("button", { name: "Record", exact: true }).click();
  await waitProbe(page, "start", 30_000);
  const notes = [{ step: "recording", source: surface.slice(0, 80) }];
  let pip = null;
  if (sc.float) {
    pip = context.pages().find((p) => p !== page && !p.url().includes("/editor-lab/")) ?? null;
    notes.push({ step: "floating window", open: pip !== null, hasBar: pip ? await pip.locator('[aria-label="Recording panel"]').count() : 0 });
  }
  try {
    await runSteps(page, sc, notes);
    // Stop.
    if (sc.stop === "click") await page.getByRole("button", { name: "Stop", exact: true }).first().click({ timeout: 10_000 });
    else if (sc.stop === "shortcut-revealed") await page.keyboard.press("Meta+Shift+KeyS");
    else if (sc.stop === "escape") await page.keyboard.press("Escape");
    else if (sc.stop === "floating" && pip) await pip.getByRole("button", { name: "Stop", exact: true }).click({ timeout: 10_000 });
    else await page.keyboard.press("Meta+Shift+KeyS");
    await waitProbe(page, "take", 30_000);
  } catch (error) {
    const dir = join(OUT, name);
    mkdirSync(dir, { recursive: true });
    await page.screenshot({ path: join(dir, "FAILED-page.png") }).catch(() => undefined);
    writeFileSync(join(dir, "FAILED-probe.json"), JSON.stringify({ url: page.url(), probe: await probeOf(page).catch(() => null), notes, errors }, null, 2));
    await context.close();
    throw error;
  }
  const probe = await probeOf(page);
  const take = probe.find((e) => e.kind === "take");
  // Published: project.json saved after the files were finalized.
  const t0 = Date.now();
  while (!(cloud.projects.get(take.id)?.saves.length > 0)) {
    if (Date.now() - t0 > 60_000) throw new Error(`${name}: the take never published`);
    await sleep(200);
  }
  const p = cloud.projects.get(take.id);
  const document = p.saves.at(-1);
  const files = p.files.map((f) => ({ path: f.path, sha256: f.sha256, bytes: f.bytes, contentType: f.contentType }));
  const objects = new Map(files.map((f) => [f.sha256, cloud.objects.get(f.sha256)]));
  await context.close();
  return { id: take.id, probe, take, document, files, objects, notes, errors };
}

// ── export with the real web exporter ───────────────────────────────────────

async function exportProject(browser, rec, document, file) {
  const context = await browser.newContext({ viewport: { width: 1400, height: 900 }, deviceScaleFactor: 1 });
  await installCloud(context, { id: rec.id, document, files: rec.files, objects: rec.objects });
  const page = await context.newPage();
  await page.goto(`${BASE}/editor-lab/open?id=${rec.id}`, { waitUntil: "domcontentloaded" });
  await page.waitForFunction(() => window.__editor?.controller?.client?.info, null, { timeout: 90_000 });
  await sleep(500);
  const out = await page.evaluate(async (o) => {
    const r = await window.__editor.controller.client.export(o);
    const bytes = new Uint8Array(r.buffer);
    let s = "";
    for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    return { data: btoa(s), frames: r.frames, fps: r.fps, width: r.width, height: r.height, sourceIndices: r.sourceIndices };
  }, EXPORT);
  // The app's own visibility rule (clips.ts) for the published project, at chosen source times.
  const visibleAt = async (times) =>
    page.evaluate(
      async ({ doc, times }) => {
        const model = await import("/src/editor/core/model/index.ts");
        const clips = await import("/src/editor/core/time/clips.ts");
        const p = model.parseProjectText(doc);
        return times.map((t) => clips.hasVisibleVideo(p, t));
      },
      { doc: document, times },
    );
  writeFileSync(file, Buffer.from(out.data, "base64"));
  return { ...out, data: undefined, visibleAt, close: () => context.close() };
}

// ── frames ──────────────────────────────────────────────────────────────────

function ptsOf(file) {
  const txt = execFileSync("ffprobe", ["-v", "error", "-select_streams", "v:0", "-show_entries", "frame=best_effort_timestamp_time", "-of", "csv=p=0", file]).toString();
  return txt.trim().split("\n").filter(Boolean).map((l) => parseFloat(l.split(",")[0]));
}

/** Decode every frame (rgb24, w×h) and call `onFrame(index, frame)`. */
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

/** Largest 4-connected blob of marker pixels (#00FFFF; r ≤ 140 allows its Display-P3 encoding). */
function markerBlob(frame, w, h) {
  const mask = new Uint8Array(w * h);
  let count = 0;
  for (let i = 0, p = 0; i < w * h; i++, p += 3) {
    if (frame[p] <= 140 && frame[p + 1] >= 220 && frame[p + 2] >= 220) {
      mask[i] = 1;
      count++;
    }
  }
  if (count < MIN_BLOB) return { count, blob: 0 };
  let best = 0;
  const stack = new Int32Array(w * h);
  for (let i = 0; i < w * h; i++) {
    if (mask[i] !== 1) continue;
    let sp = 0;
    let size = 0;
    stack[sp++] = i;
    mask[i] = 2;
    while (sp) {
      const j = stack[--sp];
      size++;
      const x = j % w;
      const y = (j / w) | 0;
      if (x > 0 && mask[j - 1] === 1) (mask[j - 1] = 2), (stack[sp++] = j - 1);
      if (x < w - 1 && mask[j + 1] === 1) (mask[j + 1] = 2), (stack[sp++] = j + 1);
      if (y > 0 && mask[j - w] === 1) (mask[j - w] = 2), (stack[sp++] = j - w);
      if (y < h - 1 && mask[j + w] === 1) (mask[j + w] = 2), (stack[sp++] = j + w);
    }
    if (size > best) best = size;
  }
  return { count, blob: best };
}

/** The page's performance.now() (ms) when this frame was drawn, from the timecode strip. */
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

// ── the take clock (barHidden.ts mediaTimeAt, for the mapping check) ─────────

function mediaTimeAt(clock, wall) {
  const lo = clock.zeroMs;
  if (!(wall > lo)) return 0;
  let ms = wall - lo;
  for (const p of clock.pauses) {
    const s = Math.max(p.start, lo);
    const e = Math.min(p.end ?? wall, wall);
    if (e > s) ms -= e - s;
  }
  return Math.max(0, ms) / 1000;
}

/** When the page logged its UI on screen: [start, end] performance.now() spans. */
function revealSpans(probe) {
  const spans = [];
  const stopAt = probe.find((e) => e.kind === "take")?.t ?? Infinity;
  for (const e of probe) {
    if (e.kind === "reveal") spans.push([e.at, null, e.reason]);
    if (e.kind === "hide" && spans.length && spans.at(-1)[1] === null) spans.at(-1)[1] = e.end;
  }
  return spans.map(([a, b, reason]) => ({ start: a, end: b ?? stopAt, reason }));
}

const pct = (xs, q) => {
  if (!xs.length) return NaN;
  const s = [...xs].sort((a, b) => a - b);
  return s[Math.min(s.length - 1, Math.floor(q * s.length))];
};

// ── analysis ────────────────────────────────────────────────────────────────

async function analyse(browser, name, sc, rec) {
  const dir = join(OUT, name);
  mkdirSync(dir, { recursive: true });
  const results = [];
  const check = (ok, label, detail = "") => {
    results.push({ ok, label, detail });
    log(`${ok ? "  ok  " : "  FAIL"} ${label}${detail ? ` — ${detail}` : ""}`);
  };
  const doc = JSON.parse(rec.document);
  const rawFile = join(dir, "recording.mov");
  const recFile = rec.files.find((f) => f.path === "recording.mov");
  writeFileSync(rawFile, rec.objects.get(recFile.sha256));
  writeFileSync(join(dir, "project.json"), rec.document);
  writeFileSync(join(dir, "probe.json"), JSON.stringify({ probe: rec.probe, notes: rec.notes, errors: rec.errors }, null, 2));

  // The published take is the LAST one started (a Restart discards the first).
  const start = rec.probe.findLast((e) => e.kind === "start");
  const conceal = rec.probe.findLast((e) => e.kind === "conceal");
  const clock = rec.take.clock;
  const spans = revealSpans(rec.probe.filter((e) => !conceal || e.t >= conceal.at));
  const reveals = spans.filter((s) => s.reason !== "switch");
  log(`  take ${rec.id}: ${rec.take.engine}, ${rec.take.duration.toFixed(2)} s, mode ${start?.mode}, zero ${clock.zeroMs.toFixed(1)} ms, pauses ${JSON.stringify(clock.pauses.map((p) => [Math.round(p.start), Math.round(p.end)]))}`);
  log(`  reveals (ms): ${JSON.stringify(spans.map((s) => [Math.round(s.start), Math.round(s.end), s.reason]))}`);
  log(`  uiReveals (media s): ${JSON.stringify(rec.take.uiReveals.map(([a, b]) => [+a.toFixed(3), +b.toFixed(3)]))}`);
  log(`  project: trimStart ${doc.trimStart.toFixed(3)} trimEnd ${doc.trimEnd.toFixed(3)} clips ${JSON.stringify(doc.videoClipSegments.map((c) => [+c.startTime.toFixed(3), +c.endTime.toFixed(3)]))}`);
  check(rec.errors.length === 0, "no page errors", rec.errors.slice(0, 3).join(" | "));
  check(start?.mode === sc.expect.mode, `take runs in "${sc.expect.mode}" mode`, String(start?.mode));
  check(reveals.length === sc.expect.reveals, `${sc.expect.reveals} reveal(s) logged`, String(reveals.length));
  if (sc.float) {
    const fw = rec.notes.find((n) => n.step === "floating window");
    check(fw?.open === true && fw.hasBar > 0, "the controls float in the Picture-in-Picture window", JSON.stringify(fw));
    const back = rec.notes.find((n) => n.step === "back on the page, floating controls")?.dom;
    check(back?.concealed === "true" && back.visibility === "hidden", "the page's bar stays hidden after a return (no reveal, nothing cut)", JSON.stringify(back));
  }

  // ── first frame
  if (sc.expect.mode !== "none") {
    check(conceal != null && clock.zeroMs > conceal.painted, "the take's first frame (media zero) comes after the hide had left the screen and the capture pipeline",
      conceal ? `off screen ${conceal.offScreen.toFixed(1)} ms, pipeline clear ${conceal.painted.toFixed(1)} ms, first frame ${clock.zeroMs.toFixed(1)} ms (+${(clock.zeroMs - conceal.painted).toFixed(1)})` : "no conceal");
  } else {
    check(conceal == null, "nothing hidden: the share can't contain this page", conceal ? "concealed" : "");
    const mid = rec.notes.find((n) => n.step === "sharing another tab")?.dom;
    check(mid?.concealed === "false" && mid.opacity > 0.99 && mid.visibility === "visible", "the bar stays on the page mid-take", JSON.stringify(mid));
  }

  // ── raw frames
  const pts = ptsOf(rawFile);
  const frames = [];
  await decode(rawFile, RAW_W, RAW_H, (i, f) => frames.push({ i, pts: pts[i], wall: timecode(f, RAW_W), ...markerBlob(f, RAW_W, RAW_H) }));
  const marked = frames.filter((f) => f.blob >= MIN_BLOB);
  const inSpan = (w) => spans.some((s) => w >= s.start && w <= s.end);
  const decoded = frames.filter((f) => f.wall !== null);
  log(`  raw: ${frames.length} frames, ${decoded.length} timecoded, ${marked.length} with the marker`);
  check(decoded.length >= frames.length * 0.95, "raw frames carry the timecode", `${decoded.length}/${frames.length}`);
  const first = frames[0];
  check(first && first.blob < MIN_BLOB, "first raw frame shows no recorder UI", first ? `blob ${first.blob}` : "no frames");
  // A recorder may open on the newest frame already delivered: it must still post-date the hide.
  if (conceal && first?.wall != null) check(first.wall >= conceal.offScreen - 2 * (1000 / 60) - 1, "first raw frame was drawn after the UI left the screen", `drawn ${first.wall} ms, faded out by ${(conceal.offScreen - 2 * (1000 / 60)).toFixed(1)} ms`);
  const stray = marked.filter((f) => f.wall === null || !inSpan(f.wall));
  check(stray.length === 0, "raw: marker only while the UI was logged on screen",
    stray.length ? `${stray.length} frames, e.g. pts ${stray.slice(0, 4).map((f) => f.pts?.toFixed(3)).join(", ")} wall ${stray.slice(0, 4).map((f) => f.wall).join(", ")}` : `${marked.length} marker frames, all inside reveals`);
  if (reveals.length > 0) {
    const seen = reveals.map((s) => marked.filter((f) => f.wall >= s.start && f.wall <= s.end).length);
    check(seen.every((n) => n > 0), "raw DOES show the bar in every reveal (the gate can see it)", JSON.stringify(seen));
  } else {
    check(marked.length === 0, "raw shows no recorder UI at all", `${marked.length} marker frames`);
  }
  // Clock: pts vs the prediction from each frame's own timecode.
  const errs = decoded.filter((f) => f.wall > clock.zeroMs).map((f) => f.pts - mediaTimeAt(clock, f.wall));
  const ms = (x) => (x * 1000).toFixed(1);
  const [errMin, errMax] = [Math.min(...errs), Math.max(...errs)];
  log(`  clock: pts − predicted  median ${ms(pct(errs, 0.5))} ms, min ${ms(errMin)}, p99 ${ms(pct(errs, 0.99))}, max ${ms(errMax)} ms`);
  check(errs.length > 0 && errMin >= CLOCK_WINDOW[0] && errMax <= CLOCK_WINDOW[1], "take clock predicts every raw pts (first-frame offset, pauses) within the cut's margin",
    `${ms(errMin)} … ${ms(errMax)} ms inside ${ms(CLOCK_WINDOW[0])} … ${ms(CLOCK_WINDOW[1])} ms`);

  // Evidence: the first frame, and the bar in the raw.
  savePng(rawFile, first?.pts ?? 0, join(dir, "raw-first-frame.png"));
  if (marked.length) savePng(rawFile, marked[Math.floor(marked.length / 2)].pts, join(dir, "raw-bar-visible.png"));

  // ── shape of the cut
  if (sc.expect.mode === "reveal") {
    if (sc.expect.tailCut !== undefined) check((doc.trimEnd > 0) === sc.expect.tailCut, `tail ${sc.expect.tailCut ? "trimmed" : "untouched"} (trimEnd)`, doc.trimEnd.toFixed(3));
    if (sc.expect.middleCut !== undefined) check((doc.videoClipSegments.length >= 2) === sc.expect.middleCut, `middle ${sc.expect.middleCut ? "cut into clips" : "uncut"}`, `${doc.videoClipSegments.length} clips`);
  } else {
    check(doc.trimStart === 0 && doc.trimEnd === 0 && doc.videoClipSegments.length === 0, "project uncut", "");
  }

  // ── output: the real exporter
  const outFile = join(dir, "export.mp4");
  const ex = await exportProject(browser, rec, rec.document, outFile);
  try {
    if (marked.length) {
      const vis = await ex.visibleAt(marked.map((f) => f.pts));
      const shown = marked.filter((_, k) => vis[k]);
      check(shown.length === 0, "cut: every raw marker frame is outside the project's visible video (clips.ts)",
        shown.length ? `visible at pts ${shown.slice(0, 5).map((f) => f.pts.toFixed(3)).join(", ")}` : `${marked.length} frames hidden`);
      const markedIdx = new Set(marked.map((f) => f.i));
      const used = ex.sourceIndices.filter((s) => markedIdx.has(s));
      check(used.length === 0, "output: the exporter rendered no raw marker frame (sourceIndices)", `${used.length}`);
    }
    const outFrames = [];
    await decode(outFile, ex.width, ex.height, (i, f) => outFrames.push({ i, ...markerBlob(f, ex.width, ex.height) }));
    const outPts = ptsOf(outFile);
    const bad = outFrames.filter((f) => f.blob >= MIN_BLOB);
    log(`  output: ${outFrames.length} frames (${ex.width}×${ex.height} @ ${ex.fps}), ${new Set(ex.sourceIndices.filter((s) => s >= 0)).size} distinct source frames`);
    check(outFrames.length > 0 && Math.abs(outFrames.length - ex.frames) <= 1, "output decodes", `${outFrames.length}/${ex.frames}`);
    check(bad.length === 0, "output: marker in zero frames",
      bad.length ? `${bad.length} frames, e.g. ${bad.slice(0, 4).map((f) => outPts[f.i]?.toFixed(3)).join(", ")} s` : `0/${outFrames.length}`);
    if (bad.length) savePng(outFile, outPts[bad[0].i], join(dir, "output-bar-LEAKED.png"));
    // Evidence: output frames either side of every cut.
    const cuts = cutsOf(doc);
    let k = 0;
    for (const [a, b] of cuts) {
      for (const [t, tag] of [[a - 0.2, "before"], [b + 0.2, "after"]]) {
        const ot = outputTimeOf(doc, t);
        if (ot !== null && ot >= 0 && ot < outFrames.length / ex.fps) savePng(outFile, ot, join(dir, `output-cut${k}-${tag}.png`));
      }
      k++;
    }
  } finally {
    await ex.close();
  }

  // ── defect proof: the same take exported WITHOUT its cuts shows the bar
  if (sc.noCutProof) {
    const uncut = { ...doc, trimStart: 0, trimEnd: 0, videoClipSegments: [], splitPoints: [] };
    const text = JSON.stringify(uncut, null, 2);
    const file = join(dir, "export-NO-CUT-defect.mp4");
    const ex2 = await exportProject(browser, rec, text, file);
    try {
      const outFrames = [];
      await decode(file, ex2.width, ex2.height, (i, f) => outFrames.push({ i, ...markerBlob(f, ex2.width, ex2.height) }));
      const bad = outFrames.filter((f) => f.blob >= MIN_BLOB);
      const outPts = ptsOf(file);
      if (bad.length) savePng(file, outPts[bad[Math.floor(bad.length / 2)].i], join(dir, "export-NO-CUT-bar-visible.png"));
      check(bad.length > 0, "defect no-cut: exported without the cuts, the gate SEES the bar (it can fail)", `${bad.length}/${outFrames.length} frames`);
    } finally {
      await ex2.close();
    }
  }
  return results;
}

/** Source ranges the project hides (head trim, gaps between clips, tail trim). */
function cutsOf(doc) {
  const d = doc.duration;
  const s = doc.trimStart || 0;
  const e = doc.trimEnd > 0 ? doc.trimEnd : d;
  const out = [];
  if (s > 0) out.push([0, s]);
  const clips = [...doc.videoClipSegments].sort((a, b) => a.startTime - b.startTime);
  for (let i = 1; i < clips.length; i++) out.push([clips[i - 1].endTime, clips[i].startTime]);
  if (e < d) out.push([e, d]);
  return out;
}

/** Output time of a source time (no speed regions in a fresh take: output = source − trimStart). */
function outputTimeOf(doc, t) {
  const s = doc.trimStart || 0;
  const e = doc.trimEnd > 0 ? doc.trimEnd : doc.duration;
  return t < s || t > e ? null : t - s;
}

// ── run ─────────────────────────────────────────────────────────────────────

const report = {};
let failed = false;
const selfBrowser = await launch(SELF_TITLE);
log(`chrome ${selfBrowser.version()} → ${BASE}  (frames → ${OUT})`);
try {
  for (const name of ONLY) {
    const sc = SCENARIOS[name];
    if (!sc) throw new Error(`unknown scenario ${name}`);
    log(`\n[${name}]`);
    const browser = selfBrowser;
    let results;
    try {
      const rec = await recordTake(browser, name, sc);
      results = await analyse(selfBrowser, name, sc, rec);
    } catch (error) {
      results = [{ ok: false, label: "scenario ran", detail: String(error?.stack ?? error) }];
      log(`  FAIL scenario ran — ${error?.stack ?? error}`);
    }
    if (sc.mustFail) {
      // A defect the gate must catch: these checks have to FAIL.
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
  await selfBrowser.close();
}
writeFileSync(join(OUT, "report.json"), JSON.stringify(report, null, 2));
log(`\n${failed ? "FAILED" : "PASSED"} — ${Object.entries(report).map(([k, v]) => `${k} ${v.ok ? "ok" : "FAIL"}`).join(", ")}`);
process.exit(failed ? 1 : 0);
