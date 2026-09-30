#!/usr/bin/env node
/**
 * Export sheet + share UI gate (DEV ONLY) — the REAL editor page
 * (/editor-lab/open?id=…) over the synthetic VFR fixture from
 * `CaptureCat --export-formats-test <dir>`, with EVERY network call mocked in
 * the browser (cloud project load/save, the share API, the R2 PUT): nothing
 * reaches a real server.
 *
 *   node scripts/editor-lab/export-ui.mjs --url http://localhost:3216 \
 *        --fixture <dir>/vfr [--out <scratch dir>]
 *
 * Walks, with screenshots:
 *   video  Export Video sheet; GIF → GIF caption, share rows hidden; MP4 +
 *          "Share link after export" + comments → Export → the sheet's share
 *          rows (Uploading to share… + bar → Finalizing → link + Copy/Copied)
 *          with the API bodies checked (markers, comments, transcript);
 *          Done → the top-bar key reads "Shared"; Share Again with a failing
 *          confirm → "Share failed: …" + Retry → done (same link, replaced).
 *   still  image-treatment still: "Export Image", Type = Image (PNG), video
 *          rows hidden; Export → a real PNG download; Video (MP4) chip → the
 *          video rows return.
 */
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
const OUT = resolve(opt("out", "/tmp/capturecat-export-ui"));
const API = opt("api", "http://localhost:8787");
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

const VIDEO_ID = "0E0F0A11-5A15-4C0E-8A11-0000000000F5";
const STILL_ID = "0E0F0A11-5A15-4C0E-8A11-0000000000F6";
const base = JSON.parse(readFileSync(join(FIX, "project-60.json"), "utf8"));
const docs = {
  [VIDEO_ID]: base,
  [STILL_ID]: { ...base, id: STILL_ID, name: "Still capture", isStillCapture: true, stillTreatment: "image", zoomRegions: [] },
};

const browser = await chromium.launch({
  channel: "chrome",
  headless: true,
  args: ["--autoplay-policy=no-user-gesture-required", "--enable-gpu", "--ignore-gpu-blocklist"],
});
const context = await browser.newContext({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 1, acceptDownloads: true });
// Downloads instead of the native save panel (headless has none).
await context.addInitScript(() => {
  delete window.showSaveFilePicker;
  window.showSaveFilePicker = undefined;
});
const page = await context.newPage();
const errors = [];
page.on("pageerror", (e) => errors.push(e.message));

// ── Mocks ─────────────────────────────────────────────────────────────────
const cors = (req) => ({
  "Access-Control-Allow-Origin": req.headers()["origin"] ?? BASE,
  "Access-Control-Allow-Credentials": "true",
  "Access-Control-Allow-Methods": "GET,POST,PUT,OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, If-Match",
});
const api = { calls: [], failConfirmOnce: false, putDelayMs: 1200, revision: 1, shares: 0 };
const json = (route, status, body) =>
  route.fulfill({ status, body: JSON.stringify(body), headers: { ...cors(route.request()), "Content-Type": "application/json" } });

await context.route(`${API}/**`, async (route) => {
  const req = route.request();
  if (req.method() === "OPTIONS") return route.fulfill({ status: 204, headers: cors(req) });
  const path = new URL(req.url()).pathname.replace(/^\/api/, "");
  const body = req.postData() ? (() => { try { return JSON.parse(req.postData()); } catch { return req.postData(); } })() : undefined;
  api.calls.push({ method: req.method(), path, body });
  const project = /^\/cloud-projects\/([^/]+)$/.exec(path);
  if (project && req.method() === "GET") {
    const doc = docs[decodeURIComponent(project[1]).toUpperCase()];
    if (!doc) return json(route, 404, { error: "not found" });
    const file = (p, type) => ({ path: p, sha256: "0".repeat(64), bytes: 1, contentType: type, source: null, url: `${BASE}/__fixture/${p}` });
    return json(route, 200, {
      projectId: doc.id, name: doc.name, revision: api.revision, documentSha256: null, access: "owner", isOwner: true, orgId: null,
      updatedAt: new Date().toISOString(), document: JSON.stringify(doc),
      files: [file("recording.mp4", "video/mp4"), file("cursor.json", "application/json")],
      urlsExpireAt: new Date(Date.now() + 3600_000).toISOString(),
    });
  }
  if (/^\/cloud-projects\/[^/]+\/project$/.test(path) && req.method() === "PUT") {
    api.revision++;
    return json(route, 200, { revision: api.revision, documentSha256: "0".repeat(64), updatedAt: new Date().toISOString() });
  }
  if (path === "/upload/video") {
    api.shares++;
    return json(route, 200, { videoId: "vidA", uploadUrl: "https://r2.mock.invalid/put/vidA", r2Key: "videos/vidA.mp4" });
  }
  if (path === "/upload/video/vidA/replace") {
    return json(route, 200, { videoId: "vidA", version: 2, uploadUrl: "https://r2.mock.invalid/put/vidA-v2", r2Key: "videos/vidA/v2.mp4" });
  }
  if (path === "/upload/jobs") return json(route, 200, { job: { jobId: "jobA" } });
  if (path.startsWith("/upload/jobs/")) return json(route, 200, { job: { jobId: "jobA" } });
  if (path === "/upload/video/vidA/complete" || path === "/upload/video/vidA/replace/2/complete") {
    if (api.failConfirmOnce) {
      api.failConfirmOnce = false;
      return json(route, 500, { error: "Upload not found in storage" });
    }
    return json(route, 200, { videoId: "vidA", url: "https://capturecat.so/share/vidA", status: "ready" });
  }
  return json(route, 404, { error: `unmocked ${path}` });
});
await context.route("https://r2.mock.invalid/**", async (route) => {
  const req = route.request();
  if (req.method() === "OPTIONS") return route.fulfill({ status: 204, headers: { ...cors(req), "Access-Control-Allow-Methods": "PUT", "Access-Control-Allow-Headers": "Content-Type" } });
  api.calls.push({ method: req.method(), path: new URL(req.url()).pathname, contentType: req.headers()["content-type"], bytes: req.postDataBuffer()?.length ?? 0 });
  await new Promise((r) => setTimeout(r, api.putDelayMs));
  return route.fulfill({ status: 200, headers: cors(req), body: "" });
});
await context.route("**/__fixture/**", (route) => {
  const name = decodeURIComponent(new URL(route.request().url()).pathname.replace(/^.*\/__fixture\//, ""));
  const body = readFileSync(join(FIX, name));
  const type = name.endsWith(".mp4") ? "video/mp4" : "application/json";
  const range = /bytes=(\d+)-(\d*)/.exec(route.request().headers()["range"] ?? "");
  if (!range) return route.fulfill({ status: 200, body, headers: { "Content-Type": type, "Accept-Ranges": "bytes", "Access-Control-Allow-Origin": "*" } });
  const start = Number(range[1]);
  const end = range[2] ? Math.min(Number(range[2]), body.length - 1) : body.length - 1;
  return route.fulfill({
    status: 206,
    body: body.subarray(start, end + 1),
    headers: { "Content-Type": type, "Accept-Ranges": "bytes", "Content-Range": `bytes ${start}-${end}/${body.length}`, "Access-Control-Allow-Origin": "*" },
  });
});

const shot = (name) => page.screenshot({ path: join(OUT, `${name}.png`) });
const dialog = () => page.locator(".cc-dialog");
const text = async (loc) => ((await loc.count()) ? (await loc.first().innerText()).trim() : "");
async function openEditor(id) {
  await page.goto(`${BASE}/editor-lab/open?id=${id}`, { waitUntil: "domcontentloaded" });
  await page.getByRole("button", { name: "Export…" }).waitFor({ timeout: 60_000 });
  // Engine loaded (the stage canvas has frames): wait for the export button to be usable.
  await page.waitForTimeout(2500);
}
async function toggle(label) {
  await dialog().getByRole("switch", { name: label }).click();
  await page.waitForTimeout(250);
}
async function pickFormat(name) {
  await dialog().getByRole("button", { name: "Format" }).or(dialog().getByLabel("Format")).first().click();
  await page.getByRole("option", { name }).or(page.getByRole("menuitem", { name })).or(page.locator(".cc-float").getByText(name, { exact: true })).first().click();
}

try {
  // ── Video project ───────────────────────────────────────────────────────
  await openEditor(VIDEO_ID);
  await page.getByRole("button", { name: "Export…" }).click();
  await dialog().waitFor();
  await page.waitForTimeout(400);
  await shot("01-export-video");
  check((await text(page.locator(".cc-dialog__title"))) === "Export Video", "sheet title: Export Video");
  check((await dialog().getByText("Type", { exact: true }).count()) === 0, "no Type row for a recording");
  check((await dialog().getByText("Share link after export").count()) === 1, "Share link after export row (MP4)");

  await pickFormat("GIF");
  await page.waitForTimeout(400);
  await shot("02-export-gif");
  check((await text(page.locator(".cc-export__bitrate"))) === "GIF • 960x540 @ 20 fps • loops", `GIF caption: "${await text(page.locator(".cc-export__bitrate"))}"`);
  check((await dialog().getByText("Share link after export").count()) === 0, "GIF: no share rows (share links carry video only)");

  await pickFormat("MP4");
  await toggle("Share link after export");
  await toggle("Allow viewer comments on the share page");
  await page.waitForTimeout(300);
  await shot("03-export-share-toggles");
  const download = page.waitForEvent("download", { timeout: 120_000 });
  await dialog().getByRole("button", { name: "Export", exact: true }).click();
  const dl = await download;
  const mp4 = join(OUT, "ui-export.mp4");
  await dl.saveAs(mp4);
  check(dl.suggestedFilename() === "vfr-fast-export.mp4", `download ${dl.suggestedFilename()}`);
  await page.getByText("Uploading to share...").waitFor({ timeout: 30_000 });
  await page.waitForTimeout(300);
  await shot("04-share-uploading");
  check((await dialog().locator(".cc-share__progress").count()) === 1, "uploading: progress bar in the sheet");
  await page.getByText("https://capturecat.so/share/vidA").waitFor({ timeout: 30_000 });
  await shot("05-share-done");
  await dialog().getByRole("button", { name: "Copy" }).click();
  await dialog().getByRole("button", { name: "Copied" }).waitFor({ timeout: 5_000 });
  check(true, "done: link + Copy → Copied");
  const presign = api.calls.find((c) => c.path === "/upload/video");
  check(presign?.body?.commentsEnabled === true, "presign: commentsEnabled");
  check(JSON.stringify(presign?.body?.annotations) === JSON.stringify([{ start: 6, end: 6.3, label: "Fast export" }]), `presign: markers ${JSON.stringify(presign?.body?.annotations)}`);
  check(presign?.body?.projectId === VIDEO_ID && presign?.body?.contentType === "video/mp4", "presign: projectId + contentType");
  const put = api.calls.find((c) => c.method === "PUT" && c.path === "/put/vidA");
  check(put?.contentType === "video/mp4" && put.bytes === readFileSync(mp4).length, `PUT: the exported file (${put?.bytes} bytes, ${put?.contentType})`);
  check(api.calls.some((c) => c.path === "/upload/video/vidA/complete"), "confirm called");

  await dialog().getByRole("button", { name: "Done" }).click();
  await page.waitForTimeout(600);
  const key = page.locator(".cc-share-key");
  check((await text(key)) === "Shared", `top-bar key: "${await text(key)}"`);
  await shot("06-topbar-shared");

  // Share Again from the top bar with a failing confirm → Retry.
  api.failConfirmOnce = true;
  api.putDelayMs = 1500;
  await key.getByRole("button").click();
  await page.locator(".cc-share-pop").waitFor();
  await shot("07-topbar-popover-done");
  await page.locator(".cc-share-pop").getByRole("button", { name: "Share Again" }).click();
  await page.waitForFunction(() => /Exporting|Uploading/.test(document.querySelector(".cc-share-key")?.textContent ?? ""), null, { timeout: 30_000 });
  await page.waitForTimeout(250);
  await shot("08-topbar-exporting");
  await page.waitForFunction(() => /Uploading/.test(document.querySelector(".cc-share-key")?.textContent ?? ""), null, { timeout: 60_000 });
  await page.waitForTimeout(300);
  await shot("09-topbar-uploading");
  await page.getByText("Share failed: Upload not found in storage").waitFor({ timeout: 30_000 });
  await shot("10-topbar-failed");
  check((await text(key)) === "Share failed", "failed: key reads Share failed");
  check(api.calls.some((c) => c.path === "/upload/video/vidA/replace"), "re-share replaces in place (same video id)");
  check(api.calls.some((c) => c.path === "/upload/jobs/jobA/fail"), "failure mirrored to the job");
  const exportsBefore = api.calls.filter((c) => c.method === "PUT").length;
  await page.locator(".cc-share-pop").getByRole("button", { name: "Retry" }).click();
  await page.locator(".cc-share-pop").getByText("https://capturecat.so/share/vidA").waitFor({ timeout: 30_000 });
  await shot("11-topbar-retry-done");
  check(api.calls.filter((c) => c.method === "PUT").length === exportsBefore + 1, "Retry re-uploads the same file");
  check((await text(key)) === "Shared", "retry: done");

  // ── Still project (PNG) ─────────────────────────────────────────────────
  await openEditor(STILL_ID);
  await page.getByRole("button", { name: "Export…" }).click();
  await dialog().waitFor();
  await page.waitForTimeout(400);
  await shot("12-export-image");
  check((await text(page.locator(".cc-dialog__title"))) === "Export Image", "still: Export Image");
  const chips = dialog().getByRole("radiogroup", { name: "Type" });
  check((await chips.getByRole("radio", { name: "Image (PNG)" }).getAttribute("aria-checked")) === "true", "still: Image (PNG) selected");
  check((await dialog().getByText("Frame Rate", { exact: true }).count()) === 0, "still: no Frame Rate row");
  check((await dialog().getByText("Format", { exact: true }).count()) === 0, "still: no Format row");
  check((await dialog().getByText("Share link after export").count()) === 0, "still: no share rows");
  const pngDownload = page.waitForEvent("download", { timeout: 60_000 });
  await dialog().getByRole("button", { name: "Export", exact: true }).click();
  const pngDl = await pngDownload;
  const pngPath = join(OUT, "ui-still.png");
  await pngDl.saveAs(pngPath);
  const png = readFileSync(pngPath);
  check(pngDl.suggestedFilename() === "Still capture.png", `still: download ${pngDl.suggestedFilename()}`);
  check(png.subarray(0, 8).toString("hex") === "89504e470d0a1a0a" && png.readUInt32BE(16) === 1280 && png.readUInt32BE(20) === 720, `still: PNG ${png.readUInt32BE(16)}x${png.readUInt32BE(20)}`);
  await page.waitForTimeout(500);
  await page.getByRole("button", { name: "Export…" }).click();
  await dialog().waitFor();
  await chips.getByRole("radio", { name: "Video (MP4)" }).click();
  await page.waitForTimeout(500);
  await shot("13-export-still-as-video");
  check((await text(page.locator(".cc-dialog__title"))) === "Export Video", "still → Video (MP4): Export Video");
  check((await dialog().getByText("Frame Rate", { exact: true }).count()) === 1, "still → Video: Frame Rate row back");
} catch (e) {
  failed++;
  console.log("FAIL", e.message);
  await shot("zz-error").catch(() => {});
} finally {
  await browser.close();
}
if (errors.length) console.log("page errors:", errors.slice(0, 5));
writeFileSync(join(OUT, "api-calls.json"), JSON.stringify(api.calls, null, 2));
console.log(failed ? `EXPORT-UI FAIL (${failed})` : "EXPORT-UI PASS");
process.exit(failed ? 1 : 0);
