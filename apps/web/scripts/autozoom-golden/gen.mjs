// Golden-case generator for the web Auto Zoom / Motion port.
//
// Builds synthetic projects (cursor.json / keys.json / tiny ffmpeg videos) in a
// throwaway folder inside the CaptureCat sandbox container tmp, drives the REAL
// Swift through `CaptureCat --mcp` (`auto_zoom`, single-edit path =
// AutoZoomApplier / StillMotionApplier), reads back the project.json it wrote,
// and records inputs + outputs as golden cases. Deletes the throwaway folder.
//
// Usage (from apps/web):
//   CC_BIN=<BUILT_PRODUCTS_DIR>/CaptureCat.app/Contents/MacOS/CaptureCat \
//     node scripts/autozoom-golden/gen.mjs src/editor/core/vectors/golden/autoZoom.json
// (resolve BUILT_PRODUCTS_DIR with `xcodebuild … -showBuildSettings`; needs the
// synthetic parity fixtures in apps/web/.fixtures/parity and ffmpeg.)
import { spawn, execFileSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const BIN = process.env.CC_BIN;
if (!BIN) throw new Error("set CC_BIN to the built CaptureCat binary (see header)");
const FIXTURE_PROJECT = fileURLToPath(new URL("../../.fixtures/parity/04-zoom-follow-motionblur/project.json", import.meta.url));
const CONTAINER_TMP = path.join(os.homedir(), "Library/Containers/so.capturecat.CaptureCat/Data/tmp");
const OUT = process.argv[2];
if (!OUT) throw new Error("usage: node gen.mjs <out.json>");

// ───────────────────────── shared builder (MIRRORED in autoZoom.test.ts) ─────
function mulberry32(seed) {
  let a = seed | 0;
  return () => {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function buildCursorEvents(spec) {
  const fps = spec.fps;
  const tOffset = spec.tOffset ?? 0;
  const frames = Math.floor(spec.duration * fps);
  const pts = spec.path;
  const presses = spec.presses ?? [];
  const jitter = spec.jitter ?? 0;
  const drop = spec.drop ?? 0;
  const rnd = mulberry32(spec.seed ?? 1);
  const first = pts[0];
  const last = pts[pts.length - 1];
  const out = [];
  for (let i = 0; i <= frames; i++) {
    const t = tOffset + i / fps;
    let x;
    let y;
    if (t <= first[0]) {
      x = first[1];
      y = first[2];
    } else if (t >= last[0]) {
      x = last[1];
      y = last[2];
    } else {
      x = last[1];
      y = last[2];
      for (let j = 1; j < pts.length; j++) {
        if (t <= pts[j][0]) {
          const [t0, x0, y0] = pts[j - 1];
          const [t1, x1, y1] = pts[j];
          const f = t1 > t0 ? (t - t0) / (t1 - t0) : 0;
          x = x0 + (x1 - x0) * f;
          y = y0 + (y1 - y0) * f;
          break;
        }
      }
    }
    const pressed = presses.some(([s, e]) => t >= s && t < e);
    let jx = 0;
    let jy = 0;
    if (jitter > 0) {
      jx = (rnd() - 0.5) * 2 * jitter;
      jy = (rnd() - 0.5) * 2 * jitter;
    }
    if (drop > 0 && rnd() < drop && i > 0) continue;
    out.push({ timestamp: t, x: x + jx, y: y + jy, isClick: pressed });
  }
  return out;
}

/** cyrb53 (53-bit string hash) — digest of JSON.stringify(events). */
function cyrb53(str, seed = 0) {
  let h1 = 0xdeadbeef ^ seed;
  let h2 = 0x41c6ce57 ^ seed;
  for (let i = 0; i < str.length; i++) {
    const ch = str.charCodeAt(i);
    h1 = Math.imul(h1 ^ ch, 2654435761);
    h2 = Math.imul(h2 ^ ch, 1597334677);
  }
  h1 = Math.imul(h1 ^ (h1 >>> 16), 2246822507);
  h1 ^= Math.imul(h2 ^ (h2 >>> 13), 3266489909);
  h2 = Math.imul(h2 ^ (h2 >>> 16), 2246822507);
  h2 ^= Math.imul(h1 ^ (h1 >>> 13), 3266489909);
  return 4294967296 * (2097151 & h2) + (h1 >>> 0);
}
// ─────────────────────────────────────────────────────────────────────────────

// ───────── authoring helpers (driver only — the golden stores the expansion) ─
const presses = (times, len = 0.06) => times.map((t) => [t, t + len]);
const cur = (duration, pathPts, clickTimes = [], extra = {}) => ({
  fps: 60,
  duration,
  path: pathPts,
  presses: presses(clickTimes),
  ...extra,
});
const parkedPath = (duration, p, from) =>
  from
    ? [
        [0, from[0], from[1]],
        [Math.min(0.5, duration), p[0], p[1]],
        [duration, p[0], p[1]],
      ]
    : [
        [0, p[0], p[1]],
        [duration, p[0], p[1]],
      ];
/** Hold each point through its click (the harness's "real users STOP"). */
function stopPath(start, points, times, hold = 0.2, end) {
  const w = [[0, start[0], start[1]]];
  times.forEach((t, i) => {
    w.push([t, points[i][0], points[i][1]]);
    w.push([t + hold, points[i][0], points[i][1]]);
  });
  if (end) w.push(end);
  return w;
}
const keysAt = (times, category = "key") => times.map((t) => ({ timestamp: t, category }));
const range = (n, start, step) => Array.from({ length: n }, (_, k) => start + k * step);
const keysFile = (events) => ({ version: 1, events });
const zr = (id, startTime, endTime, zoomLevel, fx, fy, extra = {}) => ({
  id,
  startTime,
  endTime,
  zoomLevel,
  focalPoint: [fx, fy],
  ...extra,
});
const tr = (id, startTime, endTime, pitch, yaw, roll, extra = {}) => ({
  id,
  startTime,
  endTime,
  pitch,
  yaw,
  roll,
  ...extra,
});
const ID = (n) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;

// A stress session: a seeded random walk of travel → hold (+clicks / drags /
// typing) stops over a screen of w×h points.
function session(seed, w, h, duration) {
  const r = mulberry32(seed);
  const pts = [[0, Math.round(r() * w), Math.round(r() * h)]];
  const pr = [];
  const keys = [];
  let t = 0;
  let [x, y] = [pts[0][1], pts[0][2]];
  while (t < duration - 1) {
    const travel = 0.3 + r() * 0.9;
    const nx = Math.round(r() * w);
    const ny = Math.round(r() * h);
    const dragging = r() < 0.12;
    if (dragging) pr.push([t + 0.05, t + travel - 0.05]);
    t += travel;
    x = nx;
    y = ny;
    pts.push([t, x, y]);
    const hold = 0.3 + r() * (r() < 0.2 ? 5 : 2.2);
    const nClicks = Math.floor(r() * 3.2);
    for (let c = 0; c < nClicks; c++) {
      const ct = t + 0.05 + (c * hold) / Math.max(1, nClicks);
      if (ct + 0.1 < t + hold) pr.push([ct, ct + 0.05 + r() * 0.07]);
    }
    if (r() < 0.25) {
      const n = 2 + Math.floor(r() * 8);
      for (let k = 0; k < n; k++) keys.push({ timestamp: t + 0.2 + k * (0.1 + r() * 0.5), category: r() < 0.1 ? "space" : "key" });
    }
    if (r() < 0.1) keys.push({ timestamp: t + r() * hold, category: r() < 0.5 ? "modifier" : "scroll" });
    t += hold;
    pts.push([t, x, y]);
  }
  if (t < duration) pts.push([duration, x, y]);
  pr.sort((a, b) => a[0] - b[0]);
  return { spec: { fps: 60, duration, path: pts, presses: pr, jitter: 1.5, seed: seed * 7 + 1, drop: 0.04 }, keys };
}

// ─────────────────────────────── scenarios ──────────────────────────────────
// video: key of VIDEOS, "missing" (file absent), "audio" (no video track), or
// null (videoURL nil). Cursor coordinates are in screen points = natural / 2.
const S = [];
const add = (s) => S.push(s);

// --- AutoZoomHarness fixtures (4K video → 1920×1080 screen) ---
{
  const points = [
    [200, 200], [1700, 900], [300, 850], [1600, 150], [950, 550], [200, 900], [1750, 500], [500, 300],
  ];
  const times = range(8, 1.0, 0.7);
  add({ name: "harness-scattered-clicks", video: "v4k", duration: 10,
    cursor: { format: "recording", spec: cur(10, stopPath(points[0], points, times), times) } });
}
add({ name: "harness-two-nearby-clusters-pan", video: "v4k", duration: 9,
  cursor: { format: "recording", spec: cur(9, [[0, 700, 500], [2.0, 700, 500], [4.2, 1050, 560], [9, 1050, 560]], [1.0, 1.5, 4.6, 5.1]) } });
add({ name: "harness-typing-burst", video: "v4k", duration: 12,
  cursor: { format: "recording", spec: cur(12, parkedPath(12, [900, 400], [100, 100]), [2.0]) },
  keys: { file: keysFile(keysAt(range(10, 2.5, 0.25))) } });
add({ name: "harness-lone-stray-click", video: "v4k", duration: 8,
  cursor: { format: "recording", spec: cur(8, [[0, 100, 100], [4, 1800, 950], [8, 200, 900]], [3.0]) } });
add({ name: "harness-edge-activity-clamped", video: "v4k", duration: 8,
  cursor: { format: "recording", spec: cur(8, parkedPath(8, [30, 25], [960, 540]), [2.0, 2.6]) } });
add({ name: "harness-manual-region-respected", video: "v4k", duration: 14,
  cursor: { format: "recording", spec: cur(14, parkedPath(14, [900, 500], [100, 100]), [1.0, 1.5, 5.0, 5.5, 9.0, 9.5]) },
  zoomRegions: [zr(ID(601), 4.0, 7.0, 1.8, 0.3, 0.3)] });
add({ name: "harness-dwell-after-travel", video: "v4k", duration: 8,
  cursor: { format: "recording", spec: cur(8, [[0, 100, 900], [2.0, 1200, 400], [4.0, 1200, 400], [5.0, 1800, 1000], [8.0, 300, 100]]) } });
add({ name: "harness-parked-idle", video: "v4k", duration: 10,
  cursor: { format: "recording", spec: cur(10, parkedPath(10, [960, 540])) } });

// --- typing ---
add({ name: "typing-without-click-anchors-at-cursor", video: "v4k", duration: 10,
  cursor: { format: "recording", spec: cur(10, [[0, 200, 900], [1.0, 1400, 300], [10, 1400, 300]]) },
  keys: { file: keysFile(keysAt(range(6, 3.0, 0.3))) } });
add({ name: "typing-before-first-cursor-sample", video: "v4k", duration: 8,
  cursor: { format: "recording", spec: cur(7, [[1.0, 600, 600], [1.5, 500, 700], [8, 500, 700]], [], { tOffset: 1.0 }) },
  keys: { file: keysFile(keysAt([0.2, 0.4, 0.6, 0.8, 1.1])) } });
{
  const ev = [
    { timestamp: 6.4, category: "key" }, { timestamp: 1.0, category: "key" }, { timestamp: 1.3, category: "space" },
    { timestamp: 1.6, category: "return" }, { timestamp: 2.4, category: "modifier", shortcut: "⌘⇧S", frontmostBundleID: "com.example.app" },
    { timestamp: 3.2, category: "delete" }, { timestamp: 3.4, category: "key" }, { timestamp: 4.6, category: "scroll" },
    { timestamp: 6.0, category: "key" }, { timestamp: 6.2, category: "key" }, { timestamp: 6.8, category: "key" },
    { timestamp: 7.2, category: "space" }, { timestamp: 7.9, category: "key" }, { timestamp: 8.0, category: "key", shortcut: null },
    { timestamp: 5.9, category: "modifier" },
  ];
  const cursorSpec = cur(12, [[0, 100, 100], [0.8, 400, 300], [2.0, 400, 300], [2.6, 1000, 800], [12, 1000, 800]], [1.2, 5.5]);
  add({ name: "typing-mixed-categories-unsorted", video: "v4k", duration: 12,
    cursor: { format: "recording", spec: cursorSpec }, keys: { file: keysFile(ev) } });
  add({ name: "keys-unreferenced-are-ignored", video: "v4k", duration: 12,
    cursor: { format: "recording", spec: cursorSpec }, keys: { file: keysFile(ev), omitRef: true } });
  const bad = [...ev.slice(0, 5), { timestamp: 3.0, category: "tab" }, ...ev.slice(5)];
  add({ name: "keys-unknown-category-rejects-whole-file", video: "v4k", duration: 12,
    cursor: { format: "recording", spec: cur(12, [[0, 100, 100], [0.8, 400, 300], [2.0, 400, 300], [2.6, 1000, 800], [12, 1000, 800]], [5.5, 6.2]) },
    keys: { file: keysFile(bad) } });
}
add({ name: "typing-two-bursts-short-burst-ignored", video: "v4k", duration: 16,
  cursor: { format: "recording", spec: cur(16, [[0, 1700, 200], [1.0, 600, 650], [7.0, 600, 650], [7.6, 620, 700], [16, 620, 700]], [1.5, 8.0]) },
  keys: { file: keysFile([...keysAt(range(5, 2.0, 0.4)), ...keysAt([4.5, 4.9]), ...keysAt(range(8, 8.5, 0.2))]) } });
add({ name: "typing-tie-with-click-time", video: "v4k", duration: 10,
  cursor: { format: "recording", spec: cur(10, [[0, 100, 100], [1.0, 1300, 450], [10, 1300, 450]], [2.0]) },
  keys: { file: keysFile(keysAt([2.0, 2.2, 2.4, 2.6])) } });

// --- clicks, drags, thresholds ---
add({ name: "drag-select-then-hold-dwell", video: "v4k", duration: 10,
  cursor: { format: "recording", spec: { fps: 60, duration: 10,
    path: [[0, 300, 300], [2.0, 400, 400], [2.6, 800, 420], [4.0, 800, 420], [4.8, 1500, 700], [10, 1500, 700]],
    presses: [[2.0, 2.6], [5.0, 5.06]] } } });
add({ name: "drags-only-no-clicks", video: "v4k", duration: 10,
  cursor: { format: "recording", spec: { fps: 60, duration: 10,
    path: [[0, 100, 100], [10, 1800, 1000]], presses: [[2.0, 2.8], [3.0, 3.9]] } } });
add({ name: "jittery-presses-below-drag-threshold", video: "v4k", duration: 8,
  cursor: { format: "recording", spec: cur(8, parkedPath(8, [1100, 300], [300, 800]), [2.0, 2.5, 3.1], { jitter: 3, seed: 5 }) } });
add({ name: "long-press-held-still-is-one-click", video: "v4k", duration: 8,
  cursor: { format: "recording", spec: { fps: 60, duration: 8, path: parkedPath(8, [700, 700], [1500, 200]),
    presses: [[2.0, 3.5], [4.0, 4.1]] } } });

// --- rhythm: merge / pan / separate ---
add({ name: "rhythm-merge-close-focals", video: "v4k", duration: 10,
  cursor: { format: "recording", spec: cur(10, stopPath([100, 100], [[900, 500], [900, 500], [960, 540], [960, 540]], [1.0, 1.4, 4.4, 4.8]), [1.0, 1.4, 4.4, 4.8]) } });
add({ name: "rhythm-whip-pan-far-within-cooldown", video: "v4k", duration: 10,
  cursor: { format: "recording", spec: cur(10, stopPath([100, 100], [[300, 300], [300, 300], [1600, 800], [1600, 800]], [1.0, 1.3, 3.3, 3.6]), [1.0, 1.3, 3.3, 3.6]) } });
add({ name: "rhythm-separate-far-mid-gap", video: "v4k", duration: 10,
  cursor: { format: "recording", spec: cur(10, stopPath([100, 100], [[300, 300], [300, 300], [1600, 800], [1600, 800]], [1.0, 1.3, 4.6, 4.9]), [1.0, 1.3, 4.6, 4.9]) } });
add({ name: "rhythm-near-slow-drift-dwell-chain", video: "v4k", duration: 14,
  cursor: { format: "recording", spec: cur(14, stopPath([100, 100], [[800, 500], [800, 500], [1000, 560], [1000, 560]], [1.0, 1.3, 6.0, 6.3]), [1.0, 1.3, 6.0, 6.3]) } });
add({ name: "rhythm-near-but-long-gap-separate", video: "v4k", duration: 14,
  cursor: { format: "recording", spec: cur(14, [[0, 100, 100], [1.0, 800, 500], [5.8, 800, 500], [6.0, 1000, 560], [14, 1000, 560]], [1.0, 1.3, 6.0, 6.3]) } });
add({ name: "rhythm-pan-too-short-dropped-at-end", video: "v4k", duration: 8.5,
  cursor: { format: "recording", spec: cur(8.5, stopPath([300, 300], [[300, 300], [300, 300], [1600, 800], [1600, 800]], [7.0, 7.3, 8.35, 8.45], 0.1), [7.0, 7.3, 8.35, 8.45]) } });
// gap between the two framed regions is EXACTLY 1.0 (= cooldown) in doubles:
// (405/60 − 0.35) − (270/60 + 0.9) === 1 — `gap < cooldown` must be false.
add({ name: "rhythm-gap-exactly-cooldown-far", video: "v4k", duration: 14,
  cursor: { format: "recording", spec: cur(14, stopPath([300, 300], [[300, 300], [300, 300], [1600, 800], [1600, 800]], [3.0, 270 / 60, 405 / 60, 7.0]), [3.0, 270 / 60, 405 / 60, 7.0]) } });
add({ name: "rhythm-gap-exactly-cooldown-near-pans", video: "v4k", duration: 14,
  cursor: { format: "recording", spec: cur(14, stopPath([300, 300], [[700, 500], [700, 500], [1000, 560], [1000, 560]], [3.0, 270 / 60, 405 / 60, 7.0]), [3.0, 270 / 60, 405 / 60, 7.0]) } });
// cluster B starts EXACTLY cooldown (1.0) after cluster A ends (360/60 − 300/60
// === 1): `startTime − endTime < cooldown` must NOT fuse them.
add({ name: "cluster-fuse-gap-exactly-cooldown", video: "v4k", duration: 12,
  cursor: { format: "recording", spec: cur(12, [[0, 300, 300], [5.2, 300, 300], [5.8, 1600, 800], [12, 1600, 800]], [4.5, 300 / 60, 360 / 60, 6.5]) } });
add({ name: "rhythm-pan-chain-three-clusters", video: "v4k", duration: 14,
  cursor: { format: "recording", spec: cur(14,
    stopPath([100, 100], [[600, 400], [600, 400], [900, 450], [900, 450], [1200, 520], [1200, 520]], [1.0, 1.3, 4.3, 4.6, 7.6, 7.9]),
    [1.0, 1.3, 4.3, 4.6, 7.6, 7.9]) } });
add({ name: "cluster-chain-1.9s-apart", video: "v4k", duration: 12,
  cursor: { format: "recording", spec: cur(12, parkedPath(12, [1000, 600], [200, 200]), range(5, 1.0, 1.9)) } });
add({ name: "cluster-2.1s-apart-lone-clicks", video: "v4k", duration: 12,
  cursor: { format: "recording", spec: cur(12, parkedPath(12, [1000, 600]), range(5, 1.0, 2.1)) } });
add({ name: "cluster-fuse-far-within-cooldown", video: "v4k", duration: 8,
  cursor: { format: "recording", spec: cur(8, stopPath([960, 540], [[300, 300], [1600, 800]], [2.0, 2.5], 0.15, [8, 1600, 800]), [2.0, 2.5]) } });

// --- depth / zoomLevel argument / settings ---
add({ name: "depth-medium-spread-arg-3", video: "v4k", duration: 10, zoomLevelArg: 3.0,
  cursor: { format: "recording", spec: cur(10, stopPath([100, 900], [[800, 400], [1000, 500], [900, 600]], [1.0, 1.6, 2.2]), [1.0, 1.6, 2.2]) } });
add({ name: "depth-broad-arg-1.5-clamps-min", video: "v4k", duration: 10, zoomLevelArg: 1.5,
  cursor: { format: "recording", spec: cur(10, stopPath([100, 900], [[500, 300], [1300, 700], [700, 800]], [1.0, 1.6, 2.2]), [1.0, 1.6, 2.2]) } });
add({ name: "depth-tight-typing-arg-4-clamps-max", video: "v4k", duration: 10, zoomLevelArg: 4,
  cursor: { format: "recording", spec: cur(10, parkedPath(10, [1200, 700], [300, 300]), [2.0]) },
  keys: { file: keysFile(keysAt(range(6, 2.3, 0.2))) } });
add({ name: "arg-below-schema-min-0.5", video: "v4k", duration: 10, zoomLevelArg: 0.5,
  cursor: { format: "recording", spec: cur(10, stopPath([100, 900], [[800, 400], [1000, 500], [900, 600]], [1.0, 1.6, 2.2]), [1.0, 1.6, 2.2]) } });
add({ name: "settings-autoZoomLevel-2.6", video: "v4k", duration: 10, settings: { autoZoomLevel: 2.6 },
  cursor: { format: "recording", spec: cur(10, stopPath([100, 900], [[800, 400], [1000, 500], [900, 600]], [1.0, 1.6, 2.2]), [1.0, 1.6, 2.2]) } });
add({ name: "arg-beats-settings-autoZoomLevel", video: "v4k", duration: 10, settings: { autoZoomLevel: 1.7 }, zoomLevelArg: 2.2,
  cursor: { format: "recording", spec: cur(10, stopPath([100, 900], [[800, 400], [1000, 500], [900, 600]], [1.0, 1.6, 2.2]), [1.0, 1.6, 2.2]) } });
add({ name: "smoothCursor-true-forced-off-on-decode", video: "v4k", duration: 9, settings: { smoothCursor: true, smoothingFactor: 0.05 },
  cursor: { format: "recording", spec: cur(9, [[0, 700, 500], [2.0, 700, 500], [4.2, 1050, 560], [9, 1050, 560]], [1.0, 1.5, 4.6, 5.1], { jitter: 4, seed: 9 }) } });

// --- manual / existing regions ---
add({ name: "replace-auto-keep-manual", video: "v4k", duration: 26,
  cursor: { format: "recording", spec: cur(26,
    stopPath([100, 100], [[500, 300], [520, 320], [1400, 700], [1420, 720]], [5.0, 5.6, 16.0, 16.8], 0.2, [26, 1420, 720]),
    [5.0, 5.6, 16.0, 16.8]) },
  zoomRegions: [
    zr(ID(701), 1.0, 3.0, 2.2, 0.4, 0.4, { isAuto: true }),
    zr(ID(702), 12.0, 14.0, 1.8, 0.7, 0.65, { animationStyle: "Snappy", cardOffsetX: 0.05, cardOffsetY: 0.1, followsCursor: false, isAuto: false }),
    zr(ID(703), 20.0, 22.0, 2.5, 0.3, 0.6, { animationStyle: "Cinematic" }),
    zr(ID(704), 8.0, 9.0, 2.0, 0.5, 0.5, { isAuto: true, animationStyle: "Smooth" }),
  ] });
add({ name: "manual-splits-generated-region", video: "v4k", duration: 16,
  cursor: { format: "recording", spec: cur(16, parkedPath(16, [800, 450], [100, 100]), [2.0]) },
  keys: { file: keysFile(keysAt(range(41, 2.3, 0.25))) },
  zoomRegions: [zr(ID(801), 6.5, 7.0, 1.6, 0.2, 0.8)] });
add({ name: "manual-leaves-too-short-piece", video: "v4k", duration: 12,
  cursor: { format: "recording", spec: cur(12, parkedPath(12, [800, 450], [100, 100]), [2.0, 2.5]) },
  zoomRegions: [zr(ID(802), 4.0, 5.0, 1.6, 0.2, 0.8)] });
add({ name: "manual-covers-all-activity", video: "v4k", duration: 12,
  cursor: { format: "recording", spec: cur(12, parkedPath(12, [800, 450], [100, 100]), [3.0, 3.5]) },
  zoomRegions: [zr(ID(803), 1.0, 6.0, 1.6, 0.2, 0.8, { isAuto: false })] });
add({ name: "manual-unsorted-multiple-blocks", video: "v4k", duration: 30,
  cursor: { format: "recording", spec: cur(30,
    stopPath([100, 100], [[400, 400], [420, 410], [1500, 300], [1480, 320], [900, 900], [910, 880]], [3.0, 3.5, 12.0, 12.4, 22.0, 22.3], 0.2, [30, 910, 880]),
    [3.0, 3.5, 12.0, 12.4, 22.0, 22.3]) },
  zoomRegions: [
    zr(ID(901), 25.0, 27.0, 2.0, 0.5, 0.5),
    zr(ID(902), 14.5, 15.0, 2.0, 0.5, 0.5, { isAuto: false }),
    zr(ID(903), 0.0, 1.0, 2.0, 0.5, 0.5),
    zr(ID(904), 18.0, 18.5, 2.0, 0.5, 0.5, { isAuto: true }),
  ] });
{
  // A malformed manual block (end < start) whose startTime equals the
  // generated region's start: the merge sort must keep manual first.
  const click = 150; // frame index → timestamp 150/60 = 2.5
  const genStart = click / 60 - 0.35;
  add({ name: "sort-stability-manual-before-generated", video: "v4k", duration: 10,
    cursor: { format: "recording", spec: cur(10, parkedPath(10, [1000, 500], [200, 200]), [click / 60, click / 60 + 0.5]) },
    zoomRegions: [zr(ID(1001), genStart, genStart - 5, 1.7, 0.4, 0.4)] });
}

// --- timeline edges ---
add({ name: "edge-activity-at-video-end", video: "v4k", duration: 10,
  cursor: { format: "recording", spec: cur(10, parkedPath(10, [1000, 500], [200, 200]), [9.5, 9.8]) } });
add({ name: "edge-activity-at-time-zero", video: "v4k", duration: 10,
  cursor: { format: "recording", spec: cur(10, parkedPath(10, [1000, 500]), [0.1, 0.3]) } });
add({ name: "cursor-longer-than-project-duration", video: "v4k", duration: 6,
  cursor: { format: "recording", spec: cur(10, parkedPath(10, [1000, 500], [200, 200]), [8.0, 8.4]) } });
add({ name: "project-duration-zero", video: "v4k", duration: 0,
  cursor: { format: "recording", spec: cur(6, parkedPath(6, [1000, 500], [200, 200]), [2.0, 2.4]) } });
add({ name: "project-duration-one-second", video: "v4k", duration: 1.0,
  cursor: { format: "recording", spec: cur(1, parkedPath(1, [1000, 500]), [0.3, 0.5]) } });

// --- dwells ---
add({ name: "dwell-variants-short-long-ok", video: "v4k", duration: 20,
  cursor: { format: "recording", spec: cur(20, [
    [0, 100, 100], [1.0, 500, 500], [1.7, 500, 500], [2.2, 1500, 300], [6.7, 1500, 300], [7.2, 800, 900],
    [8.2, 800, 900], [8.8, 1700, 900], [12.7, 1700, 900], [13.3, 200, 600], [14.1, 200, 600], [15, 900, 100], [20, 1900, 1050],
  ]) } });
add({ name: "dwell-jitter-and-dropped-frames", video: "v4k", duration: 12,
  cursor: { format: "recording", spec: cur(12, [[0, 200, 200], [1.5, 1200, 700], [4.0, 1200, 700], [5.0, 300, 900], [7.0, 300, 900], [8, 1800, 100], [12, 1000, 500]], [], { jitter: 6, seed: 42, drop: 0.08 }) } });
add({ name: "cursor-outside-screen-clamped", video: "v4k", duration: 10,
  cursor: { format: "recording", spec: cur(10, stopPath([960, 540], [[-50, 200], [-40, 210], [2000, 1200], [1990, 1190]], [1.0, 1.4, 5.0, 5.4]), [1.0, 1.4, 5.0, 5.4]) } });

// --- long realistic sessions ---
for (const [seed, video, w, h, dur] of [
  [7, "v4k", 1920, 1080, 30],
  [11, "v2880", 1440, 900, 40],
  [23, "v3024", 1512, 982, 25],
  [31, "v1080", 960, 540, 45],
]) {
  const { spec, keys } = session(seed, w, h, dur);
  add({ name: `session-seed-${seed}-${video}`, video, duration: dur, cursor: { format: "recording", spec },
    keys: { file: keysFile(keys) }, zoomRegions: [zr(ID(1100 + seed), dur * 0.5, dur * 0.5 + 1.5, 2.0, 0.5, 0.5)] });
}

// --- cursor file formats / failures ---
add({ name: "cursor-bare-array-format", video: "v4k", duration: 9,
  cursor: { format: "bare", spec: cur(9, [[0, 700, 500], [2.0, 700, 500], [4.2, 1050, 560], [9, 1050, 560]], [1.0, 1.5, 4.6, 5.1]) } });
add({ name: "cursor-recording-coordinate-size-ignored", video: "v4k", duration: 9,
  cursor: { format: "recording", coord: [1234, 567], spec: cur(9, [[0, 700, 500], [2.0, 700, 500], [4.2, 1050, 560], [9, 1050, 560]], [1.0, 1.5, 4.6, 5.1]) } });
add({ name: "cursor-invalid-isClick-number", video: "v4k", duration: 9,
  cursor: { format: "invalid", spec: cur(9, [[0, 700, 500], [2.0, 700, 500], [9, 700, 500]], [1.0, 1.5]) } });
add({ name: "cursor-empty-events", video: "v4k", duration: 9, cursor: { format: "empty" } });
add({ name: "cursor-file-missing", video: "v4k", duration: 9, cursor: { format: "missing" } });
add({ name: "no-cursorDataURL-video-project", video: "v4k", duration: 10, cursor: { format: "none" } });

// --- video natural size → screen size ---
function sizePattern(w, h) {
  // Two stops + a typing burst, placed in normalized coordinates.
  const p = (nx, ny) => [nx * w, ny * h];
  const a = p(0.42, 0.47);
  const b = p(0.45, 0.5);
  return cur(10, stopPath(p(0.1, 0.1), [a, b], [1.5, 2.0], 0.2, [10, b[0], b[1]]), [1.5, 2.0], { jitter: 0.5, seed: 3 });
}
for (const [name, video, w, h] of [
  ["size-1080p", "v1080", 960, 540],
  ["size-2880x1800", "v2880", 1440, 900],
  ["size-3024x1964", "v3024", 1512, 982],
  ["size-portrait-1080x1920", "vPortrait", 540, 960],
  ["size-720p", "v720", 640, 360],
  ["size-rotated-display-matrix", "vRot", 960, 540],
  ["size-anamorphic-sar-4-3", "vAnamorphic", 720, 540],
  ["size-audio-only-no-video-track", "audio", 1920, 1080],
  ["size-video-file-missing", "missing", 1920, 1080],
  ["size-no-videoURL", null, 1920, 1080],
]) {
  add({ name, video, duration: 10, cursor: { format: "recording", spec: sizePattern(w, h) },
    keys: { file: keysFile(keysAt(range(5, 2.6, 0.3))) } });
}

// --- Motion (still-image captures) ---
const still = (name, duration, extra = {}) =>
  add({ name, video: "v1080", duration, cursor: { format: "none" }, project: { isStillCapture: true }, ...extra });
still("still-motion-8s", 8);
still("still-motion-3s-fewer-corners", 3);
still("still-motion-1.5s", 1.5);
still("still-motion-1.2s-one-corner", 1.2);
still("still-motion-1s-empty-plan", 1.0);
still("still-motion-60s", 60);
still("still-motion-4.9s", 4.9);
still("still-motion-ignores-zoomLevel-arg", 8, { zoomLevelArg: 3.0 });
add({ name: "still-legacy-signature-8s", video: "v1080", duration: 8, cursor: { format: "none" } });
add({ name: "still-legacy-device-take-not-image", video: "v1080", duration: 8, cursor: { format: "none" }, project: { recordingSourceKind: "device" } });
still("still-motion-replaces-auto-and-mirrored-tilts", 10, {
  zoomRegions: [
    zr(ID(1201), 1.2, 3.0, 1.9, 0.3, 0.3, { isAuto: true, animationStyle: "Cinematic", followsCursor: false }),
    zr(ID(1202), 3.0, 5.0, 2.0, 0.7, 0.3, { isAuto: true }),
    zr(ID(1203), 6.0, 7.0, 2.4, 0.5, 0.5),
  ],
  tiltRegions: [
    tr(ID(1301), 1.2, 3.0, 1.5, 2.5, 0),
    tr(ID(1302), 3.0005, 4.9995, -1.5, -2.5, 0, { animationStyle: "Cinematic" }),
    tr(ID(1303), 3.0, 5.002, 5, 0, 0),
    tr(ID(1304), 0.5, 1.0, 10, 0, 0),
  ] });
add({ name: "still-capture-with-cursor-uses-auto-zoom", video: "v1080", duration: 8, project: { isStillCapture: true },
  cursor: { format: "recording", spec: cur(8, parkedPath(8, [300, 200], [800, 500]), [2.0, 2.5]) } });

// ─────────────────────────────── runner ─────────────────────────────────────
const ROOT = path.join(CONTAINER_TMP, `cc-autozoom-golden-${crypto.randomUUID().toUpperCase()}`);
const MEDIA = path.join(ROOT, "media");
const VIDEOS = {
  v4k: { file: "v4k.mp4", natural: [3840, 2160] },
  v1080: { file: "v1080.mp4", natural: [1920, 1080] },
  v2880: { file: "v2880.mp4", natural: [2880, 1800] },
  v3024: { file: "v3024.mp4", natural: [3024, 1964] },
  vPortrait: { file: "vPortrait.mp4", natural: [1080, 1920] },
  v720: { file: "v720.mp4", natural: [1280, 720] },
  vRot: { file: "vRot.mp4", natural: [1920, 1080] },
  // AVAssetTrack.naturalSize applies the pixel aspect (pasp): 1440×1080 at
  // SAR 4:3 reports 1920×1080 (proven by this case's golden focal).
  vAnamorphic: { file: "vAnamorphic.mp4", natural: [1920, 1080] },
};

function ffmpeg(args) {
  execFileSync("ffmpeg", ["-hide_banner", "-loglevel", "error", "-y", ...args]);
}

function makeMedia() {
  fs.mkdirSync(MEDIA, { recursive: true });
  const mk = (file, w, h, extraVf = "") =>
    ffmpeg(["-f", "lavfi", "-i", `color=c=gray:s=${w}x${h}:r=5:d=0.4${extraVf}`, "-c:v", "libx264", "-pix_fmt", "yuv420p", path.join(MEDIA, file)]);
  mk("v4k.mp4", 3840, 2160);
  mk("v1080.mp4", 1920, 1080);
  mk("v2880.mp4", 2880, 1800);
  mk("v3024.mp4", 3024, 1964);
  mk("vPortrait.mp4", 1080, 1920);
  mk("v720.mp4", 1280, 720);
  mk("vAnamorphic.mp4", 1440, 1080, ",setsar=4/3");
  ffmpeg(["-display_rotation", "90", "-i", path.join(MEDIA, "v1080.mp4"), "-c", "copy", path.join(MEDIA, "vRot.mp4")]);
  ffmpeg(["-f", "lavfi", "-i", "sine=d=0.5", "-c:a", "aac", path.join(MEDIA, "audio.m4a")]);
}

const PH = {
  video: "file:///golden/recording.mp4",
  cursor: "file:///golden/cursor.json",
  keys: "file:///golden/keys.json",
};

function baseProject() {
  const p = JSON.parse(fs.readFileSync(FIXTURE_PROJECT, "utf8"));
  p.id = "00000000-0000-4000-8000-00000000A200";
  p.name = "autozoom-golden";
  p.zoomRegions = [];
  p.tiltRegions = [];
  p.videoURL = PH.video;
  p.cursorDataURL = PH.cursor;
  delete p.keystrokeDataURL;
  return p;
}

class Mcp {
  constructor() {
    this.proc = spawn(BIN, ["--mcp"], { stdio: ["pipe", "pipe", "pipe"] });
    this.buf = "";
    this.waiters = new Map();
    this.nextId = 0;
    this.stderr = "";
    this.proc.stderr.on("data", (d) => (this.stderr += d));
    this.proc.stdout.on("data", (d) => {
      this.buf += d;
      let nl;
      while ((nl = this.buf.indexOf("\n")) >= 0) {
        const line = this.buf.slice(0, nl).trim();
        this.buf = this.buf.slice(nl + 1);
        if (!line) continue;
        const msg = JSON.parse(line);
        if (msg.id !== undefined && this.waiters.has(msg.id)) {
          this.waiters.get(msg.id)(msg);
          this.waiters.delete(msg.id);
        }
      }
    });
  }
  request(method, params) {
    const id = ++this.nextId;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`timeout ${method}`)), 120000);
      this.waiters.set(id, (m) => {
        clearTimeout(timer);
        resolve(m);
      });
      this.proc.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
    });
  }
  notify(method) {
    this.proc.stdin.write(JSON.stringify({ jsonrpc: "2.0", method }) + "\n");
  }
  close() {
    this.proc.stdin.end();
    return new Promise((resolve) => {
      const t = setTimeout(() => resolve(), 10000);
      this.proc.on("exit", () => {
        clearTimeout(t);
        resolve();
      });
    });
  }
}

function regionsOut(regions, inputIds) {
  return regions.map((r) => {
    const { id, ...rest } = r;
    return { idKind: inputIds.has(id) ? `kept:${id}` : "new", ...rest };
  });
}

async function main() {
  fs.mkdirSync(ROOT, { recursive: true });
  const mcp = new Mcp();
  const cases = [];
  try {
    makeMedia();
    const init = await mcp.request("initialize", {
      protocolVersion: "2025-03-26",
      capabilities: {},
      clientInfo: { name: "autozoom-golden", version: "0" },
    });
    if (init.result?.serverInfo?.name !== "capturecat") throw new Error("bad initialize: " + JSON.stringify(init).slice(0, 300));
    mcp.notify("notifications/initialized");

    const base = baseProject();
    for (const [index, s] of S.entries()) {
      const dir = path.join(ROOT, `case-${String(index).padStart(3, "0")}`);
      fs.mkdirSync(dir);
      const patch = {
        id: `00000000-0000-4000-8000-${String(0xb000 + index).padStart(12, "0")}`,
        duration: s.duration,
        zoomRegions: s.zoomRegions ?? [],
        tiltRegions: s.tiltRegions ?? [],
        ...(s.project ?? {}),
      };
      // Media references (placeholders in the golden, real files on disk).
      const real = {};
      let videoNaturalSize = null;
      if (s.video === null) {
        patch.videoURL = null;
      } else {
        patch.videoURL = PH.video;
        if (s.video === "missing") real.videoURL = "file://" + path.join(dir, "nope.mp4");
        else if (s.video === "audio") real.videoURL = "file://" + path.join(MEDIA, "audio.m4a");
        else {
          real.videoURL = "file://" + path.join(MEDIA, VIDEOS[s.video].file);
          videoNaturalSize = VIDEOS[s.video].natural;
        }
      }
      let cursorFile = null;
      let events = null;
      if (s.cursor.format === "none") {
        patch.cursorDataURL = null;
      } else {
        patch.cursorDataURL = PH.cursor;
        real.cursorDataURL = "file://" + path.join(dir, "cursor.json");
        if (s.cursor.spec) events = buildCursorEvents(s.cursor.spec);
        const coord = s.cursor.coord ?? [0, 0];
        if (s.cursor.format === "recording") {
          cursorFile = { version: 1, coordinateWidth: coord[0], coordinateHeight: coord[1], events };
        } else if (s.cursor.format === "bare") {
          cursorFile = events;
        } else if (s.cursor.format === "invalid") {
          const bad = events.map((e) => ({ ...e }));
          bad[Math.floor(bad.length / 2)].isClick = 1;
          cursorFile = { version: 1, coordinateWidth: 0, coordinateHeight: 0, events: bad };
        } else if (s.cursor.format === "empty") {
          cursorFile = { version: 1, coordinateWidth: 0, coordinateHeight: 0, events: [] };
        }
        if (cursorFile !== null) fs.writeFileSync(path.join(dir, "cursor.json"), JSON.stringify(cursorFile));
      }
      if (s.keys) {
        fs.writeFileSync(path.join(dir, "keys.json"), JSON.stringify(s.keys.file));
        if (!s.keys.omitRef) {
          patch.keystrokeDataURL = PH.keys;
          real.keystrokeDataURL = "file://" + path.join(dir, "keys.json");
        }
      }
      const settingsPatch = s.settings ?? {};
      const doc = { ...base, ...patch, ...real, settings: { ...base.settings, ...settingsPatch } };
      const projectPath = path.join(dir, "project.json");
      const before = JSON.stringify(doc, null, 2);
      fs.writeFileSync(projectPath, before);

      const args = { id: dir };
      if (s.zoomLevelArg !== undefined) args.zoomLevel = s.zoomLevelArg;
      const resp = await mcp.request("tools/call", { name: "auto_zoom", arguments: args });
      if (resp.error) throw new Error(`${s.name}: JSON-RPC error ${JSON.stringify(resp.error)}`);
      const isError = resp.result?.isError === true;
      const text = resp.result?.content?.[0]?.text ?? "";
      const after = fs.readFileSync(projectPath, "utf8");
      const written = JSON.parse(after);
      const inputIds = new Set([...(patch.zoomRegions ?? []), ...(patch.tiltRegions ?? [])].map((r) => r.id));
      let expected;
      if (isError) {
        expected = { ok: false, error: text, unchanged: after === before };
      } else {
        const result = JSON.parse(text);
        expected = {
          ok: true,
          mode: result.mode ?? "auto-zoom",
          created: result.created,
          zoomRegions: regionsOut(written.zoomRegions, inputIds),
          tiltRegions: regionsOut(written.tiltRegions, inputIds),
        };
      }
      const c = {
        name: s.name,
        projectPatch: patch,
        settingsPatch,
        videoNaturalSize,
        cursor: {
          format: s.cursor.format,
          ...(s.cursor.coord ? { coord: s.cursor.coord } : {}),
          ...(s.cursor.spec ? { spec: s.cursor.spec } : {}),
          ...(events ? { count: events.length, digest: cyrb53(JSON.stringify(events)) } : {}),
        },
        ...(s.keys ? { keys: { file: s.keys.file, referenced: !s.keys.omitRef } } : {}),
        ...(s.zoomLevelArg !== undefined ? { zoomLevelArg: s.zoomLevelArg } : {}),
        expected,
      };
      cases.push(c);
      const summary = expected.ok
        ? `${expected.mode} created=${expected.created} zooms=${expected.zoomRegions.length} tilts=${expected.tiltRegions.length}`
        : `ERROR ${text.slice(0, 80)} unchanged=${expected.unchanged}`;
      console.log(`${String(index).padStart(3)} ${s.name}: ${summary}`);
    }
  } finally {
    await mcp.close();
    fs.rmSync(ROOT, { recursive: true, force: true });
    console.log(`removed ${ROOT}: ${!fs.existsSync(ROOT)}`);
    if (mcp.stderr.trim()) console.log("stderr:", mcp.stderr.slice(0, 2000));
  }

  const golden = {
    unit: "autoZoom",
    notes:
      "Recorded from the REAL Swift: `CaptureCat --mcp` tool `auto_zoom` (single-edit path → " +
      "MCPServer.opAutoZoom → AutoZoomApplier.apply(to:zoomLevel:) / StillMotionApplier.apply(to:)) on " +
      "synthetic projects; `expected` is the project.json it wrote (ids: kept:<input id> | new). " +
      "Cursor events are rebuilt from `cursor.spec` by buildCursorEvents (digest-checked). " +
      "Placeholders file:///golden/* stand for the throwaway files. Binary built from sources of " +
      new Date().toISOString().slice(0, 10) + ".",
    baseProject: baseProject(),
    count: cases.length,
    cases,
  };
  fs.writeFileSync(OUT, JSON.stringify(golden) + "\n");
  console.log(`wrote ${cases.length} cases → ${OUT} (${fs.statSync(OUT).size} bytes)`);
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
