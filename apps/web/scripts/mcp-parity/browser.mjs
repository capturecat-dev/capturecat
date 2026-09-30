#!/usr/bin/env node
/**
 * END-TO-END WebMCP parity: the SAME tool-call sequence through
 *   (a) the real Mac MCP server (`CaptureCat --mcp`) on a throwaway copy of a
 *       synthetic parity fixture, and
 *   (b) the web editor's WebMCP handlers (state/webmcpHandlers.ts — the store,
 *       the load-normalised draft, MCP history + undo, auto-zoom inputs
 *       fetched through the page) running in the REAL editor page on another
 *       throwaway copy of the same fixture,
 * then diffs every result text and the project.json after every step (UUIDs
 * mapped by first appearance, history timestamps + the Mac-only GUI warning
 * masked, numbers within 1e-9).
 *
 *   cd apps/web && node scripts/mcp-parity/browser.mjs [--url http://localhost:3217] [--show]
 *
 * Needs a dev server (DEV exposes window.__editor.mcp) and the synthetic
 * fixtures in apps/web/.fixtures/parity. Every copy is deleted at the end.
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright-core";

import { MacServer, Sandbox } from "./mac.mjs";

const args = process.argv.slice(2);
const opt = (name, def) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 ? args[i + 1] : def;
};
const BASE = opt("url", "http://localhost:3217");
const SHOW = args.includes("--show");
const here = path.dirname(fileURLToPath(import.meta.url));
const sandbox = new Sandbox(path.join(here, "../../.fixtures/parity"));

// "$<array>.<i>" = the id of project[<array>][i] on EACH side, read just before the call.
const SCENARIOS = [
  {
    fixture: "04-zoom-follow-motionblur",
    steps: [
      ["describe_project", {}],
      ["remove_effect", { at: 1 }], // the fixture's first zoom (0.5–2.4)
      ["apply_edits", { ops: [
        { op: "add_effect", args: { type: "zoomtilt", start: 0.5, end: 2.2, zoomLevel: 2.4, focalX: 0.3, focalY: 0.6, pitch: 12 } },
        { op: "add_annotation", args: { type: "callout", start: 1, end: 3, text: "Look here", color: "#FF3B30" } },
        { op: "add_blur", args: { start: 3, end: 4.5, x: 0.1, y: 0.1, width: 0.3, height: 0.2, style: "Pixelate" } },
        { op: "set_speed", args: { start: 4.6, end: 5.8, speed: 2 } },
      ] }],
      ["update_effect", { at: 1, zoomLevel: 3.1, roll: 5, animationStyle: "Snappy", offsetX: 0.2 }],
      ["add_effect", { type: "zoom", start: 1.5, end: 3 }], // overlaps → error
      ["set_style", { patch: { backgroundPadding: 30, cursorScale: 1.4, gradientStartColor: "#112233", showKeystrokes: true, autoHideCursor: true } }],
      ["style_options", { group: "cursor" }], // autoHideCursor reads back false (decode normalisation)
      ["update_annotation", { annotationId: "$annotations.0", text: "Changed", fontSize: 30, enterEffect: "Fade", x: 1.4 }],
      ["auto_zoom", { zoomLevel: 1.8 }], // no zoom-worthy activity in this fixture → error
      ["undo", {}],
      ["describe_project", {}],
      ["cut_video", { ranges: [{ start: 2.4, end: 2.9 }] }],
      ["set_trim", { start: 0.3, end: 5.9 }],
      ["remove_speed", { at: 5 }],
      ["apply_edits", { ops: [{ op: "remove_blur", args: { blurId: "$blurRegions.0" } }, { op: "set_speed", args: { start: 1, end: 1.2, speed: 9 } }] }], // op 2 fails → nothing written
      ["add_annotation", { type: "tap", start: 2, end: 2.8, x: 0.7, y: 0.2 }],
      ["remove_annotation", { annotationId: "$annotations.0" }],
      ["undo", { steps: 2 }],
      ["get_transcript", {}],
      ["undo", { steps: 40 }], // more than recorded → error
      ["set_style", { patch: { notAKey: 1 } }], // unknown key → error
      ["add_blur", { start: 0, end: 0.5 }], // < 0.8 s → error
      ["set_speed", { start: 0.2, end: 1.5, speed: 0.5 }],
      ["remove_effect", { at: 1 }],
      ["describe_project", {}],
    ],
  },
  {
    fixture: "01-baseline-gradient",
    // A click cluster + dwell so auto_zoom has zoom-worthy activity.
    extraFiles: { "cursor.json": clickClusterCursor() },
    steps: [
      ["describe_project", {}],
      ["auto_zoom", {}],
      ["auto_zoom", { zoomLevel: 2.5 }], // regenerating replaces only the auto regions
      ["add_effect", { type: "tilt", start: 3.2, end: 3.9 }],
      ["undo", { steps: 2 }],
      ["describe_project", {}],
    ],
  },
];

/** 4 s at 60 Hz in a 960×540 space: glide to (600, 320), three clicks, glide away. */
function clickClusterCursor() {
  const events = [];
  const presses = [[1.0, 1.08], [1.6, 1.68], [2.3, 2.38]];
  for (let i = 0; i <= 240; i++) {
    const t = i / 60;
    const k = Math.min(1, t / 0.9);
    const away = Math.max(0, (t - 3.2) / 0.8);
    const x = 200 + (600 - 200) * k + 200 * away + (t > 0.9 && t < 3.2 ? 3 * Math.sin(t * 7) : 0);
    const y = 120 + (320 - 120) * k - 150 * away;
    events.push({ timestamp: t, x, y, isClick: presses.some(([a, b]) => t >= a && t <= b) });
  }
  return JSON.stringify({ version: 2, coordinateWidth: 960, coordinateHeight: 540, events });
}

// ── Normalisation ───────────────────────────────────────────────────────────
const UUID = /[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}/gi;
function mapper() {
  const seen = new Map();
  return (text) =>
    text.replace(UUID, (u) => {
      const k = u.toUpperCase();
      if (!seen.has(k)) seen.set(k, `UUID#${seen.size + 1}`);
      return seen.get(k);
    });
}
function deepDiff(a, b, p = "", out = []) {
  if (typeof a === "number" && typeof b === "number") {
    if (!(Math.abs(a - b) <= 1e-9)) out.push(`${p}: ${a} ≠ ${b}`);
    return out;
  }
  if (a === null || b === null || typeof a !== "object" || typeof b !== "object") {
    if (a !== b) out.push(`${p}: ${JSON.stringify(a)?.slice(0, 80)} ≠ ${JSON.stringify(b)?.slice(0, 80)}`);
    return out;
  }
  for (const k of new Set([...Object.keys(a), ...Object.keys(b)])) deepDiff(a[k], b[k], `${p}.${k}`, out);
  return out;
}
function scrubResult(obj) {
  if (obj && typeof obj === "object") {
    delete obj.warning; // Mac-only: "the CaptureCat app is running" note
    if (Array.isArray(obj.undone)) for (const u of obj.undone) delete u.at;
    for (const v of Object.values(obj)) scrubResult(v);
  }
  return obj;
}
function fill(value, project) {
  return JSON.parse(
    JSON.stringify(value).replace(/"\$([A-Za-z]+)\.(\d+)"/g, (_, key, i) => JSON.stringify(project?.[key]?.[Number(i)]?.id ?? `missing-${key}-${i}`)),
  );
}

// ── Run ─────────────────────────────────────────────────────────────────────
const mac = new MacServer();
let browser;
let failures = 0;
let calls = 0;
try {
  await mac.initialize();
  browser = await chromium.launch({ channel: "chrome", headless: true, args: ["--enable-gpu", "--ignore-gpu-blocklist"] });
  const page = await (await browser.newContext({ viewport: { width: 1400, height: 900 } })).newPage();
  for (const scenario of SCENARIOS) {
    console.log(`\n── ${scenario.fixture}`);
    const macCopy = sandbox.create(scenario.fixture, undefined, scenario.extraFiles ?? {});
    const webCopy = sandbox.create(scenario.fixture, undefined, scenario.extraFiles ?? {});
    await page.goto(`${BASE}/editor-lab/open?id=${webCopy.id}`, { waitUntil: "domcontentloaded" });
    await page.waitForFunction(() => window.__editor?.mcp && window.__editor.controller.client?.info, null, { timeout: 90_000 });
    const mapMac = mapper();
    const mapWeb = mapper();
    mapMac(macCopy.id);
    mapWeb(webCopy.id);
    let n = 0;
    for (const [tool, raw] of scenario.steps) {
      n++;
      calls++;
      const macProject = JSON.parse(fs.readFileSync(macCopy.projectPath, "utf8"));
      const webProject = await page.evaluate(() => JSON.parse(window.__editor.store.documentText()));
      const macRes = await mac.call(tool, { ...fill(raw, macProject), id: macCopy.id });
      const webText = await page.evaluate(
        async ([t, a]) => {
          try {
            const r = await window.__editor.mcp[t](a, new AbortController().signal);
            return typeof r === "string" ? r : JSON.stringify(r);
          } catch (e) {
            return `ERROR: ${e?.message ?? e}`;
          }
        },
        [tool, fill(raw, webProject)],
      );
      const diffs = [];
      const mt = mapMac(macRes.text);
      const wt = mapWeb(webText);
      if (mt.startsWith("ERROR:") || wt.startsWith("ERROR:")) {
        if (mt !== wt) diffs.push(`result: mac «${mt.slice(0, 200)}» web «${wt.slice(0, 200)}»`);
      } else {
        deepDiff(scrubResult(JSON.parse(mt)), scrubResult(JSON.parse(wt)), "result", diffs);
      }
      // project.json after the step, both normalised by the web's lossless model.
      const macDoc = fs.readFileSync(macCopy.projectPath, "utf8");
      const docs = await page.evaluate(
        (text) => [window.__editor.normalize(text), window.__editor.normalize(window.__editor.store.documentText())],
        macDoc,
      );
      deepDiff(JSON.parse(mapMac(docs[0])), JSON.parse(mapWeb(docs[1])), "project", diffs);
      const ok = diffs.length === 0;
      if (!ok) failures++;
      console.log(
        `${ok ? "SAME" : "DIFF"}  #${String(n).padStart(2)} ${tool.padEnd(18)} ${mt.startsWith("ERROR:") ? "(error) " : ""}${SHOW ? mt.slice(0, 150) : ""}${ok ? "" : "\n      " + diffs.slice(0, 8).join("\n      ")}`,
      );
    }
  }
  console.log(`\n${calls} tool calls through both servers; ${failures} with differences.`);
} finally {
  mac.close();
  await browser?.close();
  sandbox.cleanup();
}
process.exit(failures ? 1 : 0);
