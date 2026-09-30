/**
 * Render-parity gate: web engine vs the REAL Mac exporter.
 *
 *   node scripts/editor-lab/parity.mjs [--url http://localhost:3200] [--only 05-tilt-regions,01-…]
 *        [--out <dir>] [--all-sides]
 *
 * For each fixture in apps/web/.fixtures/parity (written by `CaptureCat
 * --web-parity-fixtures`, synced by scripts/sync-parity-fixtures.sh): load
 * its project.json + recording in the engine lab at the Mac's export size
 * (reference canvas = none → canvasScale 1, like the headless export), seek
 * to every manifest frame, snapshot, and diff against the exporter's PNG.
 * Prints max / mean / p99 and the share of pixels off by > 8/255, and writes
 * web | mac | ×4-diff PNGs to --out (first frame per fixture; every frame
 * with --all-sides). Exit 1 if any frame exceeds the
 * thresholds (mean ≤ 1.5/255, p99 ≤ 12/255 — AA/text slack).
 */
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { chromium } from "playwright-core";

const args = process.argv.slice(2);
const opt = (name, fallback) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : fallback;
};
const BASE = opt("url", "http://localhost:3200");
const OUT = opt("out", "/tmp/capturecat-parity");
const ALL_SIDES = args.includes("--all-sides");
const ONLY = opt("only", "") ? new Set(opt("only").split(",")) : null;
const FIX = new URL("../../.fixtures/parity/", import.meta.url).pathname;
mkdirSync(OUT, { recursive: true });

const manifest = JSON.parse(readFileSync(join(FIX, "manifest.json"), "utf8"));
const browser = await chromium.launch({
  channel: "chrome",
  headless: true,
  args: ["--autoplay-policy=no-user-gesture-required", "--enable-gpu", "--ignore-gpu-blocklist"],
});
const page = await (await browser.newContext({ viewport: { width: 1600, height: 1000 }, deviceScaleFactor: 1 })).newPage();
const errors = [];
page.on("pageerror", (e) => errors.push(e.message));
await page.goto(`${BASE}/editor-lab`, { waitUntil: "domcontentloaded" });
await page.waitForFunction(() => window.__lab?.ready === true, null, { timeout: 60_000 });

let failed = 0;
for (const fx of manifest.fixtures) {
  if (ONLY && !ONLY.has(fx.name)) continue;
  const base = `/.fixtures/parity/${fx.dir}`;
  const result = await page.evaluate(
    async ({ base, fx, allSides }) => {
      window.__paritySides = [];
      const client = window.__lab.client();
      const project = await (await fetch(`${base}/${fx.project}`)).json();
      const files = {};
      if (fx.media.cursor && project.cursorDataURL) files[project.cursorDataURL] = `${base}/${fx.media.cursor}`;
      if (fx.media.camera && project.cameraVideoURL) files[project.cameraVideoURL] = `${base}/${fx.media.camera}`;
      for (const k of ["keystrokeDataURL"]) if (project[k]) files[project[k]] = `${base}/${project[k].split("/").pop()}`;
      const s = project.settings ?? {};
      for (const ref of [s.backgroundImagePath, s.watermarkFileName, s.curtainLogoFileName]) {
        if (ref) files[ref] = `${base}/${String(ref).split("/").pop()}`;
      }
      await client.load(project, { video: `${base}/${fx.media.video}`, files });
      const W = fx.outputSize.width;
      const H = fx.outputSize.height;
      client.resize({ cssWidth: W, cssHeight: H, dpr: 1, pixelWidth: W, pixelHeight: H, reference: null });
      await new Promise((r) => setTimeout(r, 150));
      const rows = [];
      for (const f of fx.frames) {
        await client.seek(f.outputTime);
        await new Promise((r) => setTimeout(r, 60));
        const snap = await client.snapshot({ png: false });
        const web = new Uint8ClampedArray(snap.rgba);
        const img = await createImageBitmap(await (await fetch(`${base}/${f.png}`)).blob(), { colorSpaceConversion: "none" });
        const c = new OffscreenCanvas(img.width, img.height);
        const g = c.getContext("2d", { colorSpace: snap.colorSpace });
        g.drawImage(img, 0, 0);
        const ref = g.getImageData(0, 0, img.width, img.height, { colorSpace: snap.colorSpace }).data;
        if (img.width !== snap.width || img.height !== snap.height) {
          rows.push({ t: f.outputTime, error: `size ${snap.width}x${snap.height} vs ref ${img.width}x${img.height}` });
          continue;
        }
        const diffs = new Float64Array(256);
        let sum = 0;
        let max = 0;
        let over8 = 0;
        const n = img.width * img.height;
        let bx0 = Infinity, by0 = Infinity, bx1 = -1, by1 = -1;
        for (let i = 0; i < n; i++) {
          const o = i * 4;
          const d = Math.max(Math.abs(web[o] - ref[o]), Math.abs(web[o + 1] - ref[o + 1]), Math.abs(web[o + 2] - ref[o + 2]));
          diffs[d]++;
          sum += d;
          if (d > max) max = d;
          if (d > 8) {
            over8++;
            const x = i % img.width, y = (i / img.width) | 0;
            if (x < bx0) bx0 = x; if (y < by0) by0 = y; if (x > bx1) bx1 = x; if (y > by1) by1 = y;
          }
        }
        if (allSides || f === fx.frames[0]) {
          // Side-by-side (web | mac | diff×4) for the first frame of each fixture.
          const W2 = img.width;
          const out = new OffscreenCanvas(W2 * 3, img.height);
          const og = out.getContext("2d");
          const put = (data, x) => og.putImageData(new ImageData(new Uint8ClampedArray(data), W2, img.height), x, 0);
          put(web, 0);
          put(ref, W2);
          const dd = new Uint8ClampedArray(n * 4);
          for (let i = 0; i < n; i++) {
            const o = i * 4;
            const d = Math.min(255, 4 * Math.max(Math.abs(web[o] - ref[o]), Math.abs(web[o + 1] - ref[o + 1]), Math.abs(web[o + 2] - ref[o + 2])));
            dd[o] = d; dd[o + 1] = d; dd[o + 2] = d; dd[o + 3] = 255;
          }
          put(dd, W2 * 2);
          const blob = await out.convertToBlob({ type: "image/png" });
          window.__paritySides.push({ t: f.outputTime, png: Array.from(new Uint8Array(await blob.arrayBuffer())) });
        }
        let acc = 0;
        let p99 = 0;
        for (let d = 0; d < 256; d++) {
          acc += diffs[d];
          if (acc >= n * 0.99) {
            p99 = d;
            break;
          }
        }
        rows.push({ t: f.outputTime, max, mean: sum / n, p99, over8: over8 / n, bbox: bx1 >= 0 ? [bx0, by0, bx1 - bx0 + 1, by1 - by0 + 1] : null });
      }
      return rows;
    },
    { base, fx, allSides: ALL_SIDES },
  );
  const sides = await page.evaluate(() => window.__paritySides ?? []);
  for (const side of sides) {
    const suffix = ALL_SIDES ? `-t${side.t.toFixed(3)}` : "";
    writeFileSync(join(OUT, `${fx.name}${suffix}-side.png`), Buffer.from(side.png));
  }
  for (const r of result) {
    const bad = r.error || r.mean > 1.5 || r.p99 > 12;
    if (bad) failed++;
    console.log(
      `${bad ? "FAIL" : "ok  "} ${fx.name} t=${r.t.toFixed(3)} ` +
        (r.error ?? `mean=${r.mean.toFixed(2)} p99=${r.p99} max=${r.max} >8:${(r.over8 * 100).toFixed(2)}% bbox=${JSON.stringify(r.bbox)}`),
    );
  }
}
if (errors.length) console.log("page errors:", errors.slice(0, 5));
await browser.close();
console.log(failed ? `PARITY FAIL (${failed} frames)` : "PARITY PASS");
process.exit(failed ? 1 : 0);
