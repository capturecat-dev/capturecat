#!/usr/bin/env node
/**
 * Project History gate (DEV ONLY) — the REAL editor page (/editor-lab/open)
 * on a synthetic CLOUD project (parity fixture 01's recording + cursor),
 * with EVERY API call mocked in the browser (project load/save, the history
 * routes): no sign-in, nothing reaches a server. The mock is a small
 * stateful server: revisions + If-Match, versions, PATCH/DELETE/restore,
 * and scripted 409s.
 *
 *   node scripts/editor-lab/history.mjs --url http://localhost:3222 [--out <dir>] [--headed]
 *
 * Walks, with screenshots (--out):
 *   motion   History key → the pane slides in: 6 frames captured with the
 *            page's animations slowed 10× must show it MID-FLIGHT (opacity
 *            strictly between 0 and 1, translateX between 0 and 28), then
 *            settled; reduced motion → no animation at all.
 *   list     day sections, badges, "Current" row, footer.
 *   preview  click a version → stage callout "Viewing …"; the project shows
 *            that version; edits/undo are refused and NOTHING is saved.
 *   restore  callout Restore → confirm → POST restore with If-Match =
 *            current revision → one "Restore Version" undo step.
 *   name     row menu → Name This Version… → Enter → PATCH {label}.
 *   compare  row menu → Compare with Current → grouped rows; a row seeks.
 *   merge    a save answered 409 with a non-clashing server copy → exactly
 *            one merge save (X-CC-Checkpoint: merge, X-CC-Merged-From) and
 *            the callout "Merged 1 change from Ana (Web)".
 *   review   a 409 whose merge hits delete-vs-modify → Merge Review opens,
 *            nothing saves; pick Theirs → Apply → one merge save.
 *   gated    a Free owner's project: the upsell line, not a broken pane.
 *
 * Exit 1 on any failure.
 */
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { chromium } from "playwright-core";

const args = process.argv.slice(2);
const opt = (name, fallback) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : fallback;
};
const BASE = opt("url", "http://localhost:3222");
const API = opt("api", "http://localhost:8787");
const OUT = opt("out", "/tmp/capturecat-history-gate");
const FIX = new URL("../../.fixtures/parity/01-baseline-gradient/", import.meta.url).pathname;
mkdirSync(OUT, { recursive: true });

const failures = [];
const report = { startedAt: new Date().toISOString(), base: BASE, checks: [], motion: null };
const check = (ok, label) => {
  console.log(`${ok ? "PASS" : "FAIL"} ${label}`);
  report.checks.push({ ok: !!ok, label });
  if (!ok) failures.push(label);
  return ok;
};

// ── The synthetic project + its history ───────────────────────────────────
const ID = "7284D01B-35E0-46D7-B338-F1760FF5500A";
const FREE_ID = "7284D01B-35E0-46D7-B338-F1760FF55FFF";
const ZOOM_ID = "00000000-0000-4000-8000-0000000000A1";
const fixture = JSON.parse(readFileSync(join(FIX, "project.json"), "utf8"));
const docOf = (mut, id = ID) => {
  const j = structuredClone(fixture);
  j.id = id;
  j.name = "Launch walkthrough";
  j.zoomRegions = [{ animationStyle: "Snappy", endTime: 2.4, focalPoint: [0.4, 0.4], id: ZOOM_ID, startTime: 0.5, zoomLevel: 2 }];
  mut?.(j);
  return JSON.stringify(j, null, 2);
};
const NOW = Date.now();
const iso = (msAgo) => new Date(NOW - msAgo).toISOString();
const HOUR = 3600_000;
const DAY = 24 * HOUR;
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
const unb64 = (s) => {
  try {
    return JSON.parse(Buffer.from(s, "base64url").toString("utf8"));
  } catch {
    return null;
  }
};

function freshServer() {
  const v3 = docOf();
  const v2 = docOf((j) => {
    j.zoomRegions = [];
    j.settings.backgroundPadding = 40;
  });
  const v1 = docOf((j) => {
    j.name = "Launch walkthrough (first cut)";
    j.zoomRegions = [];
    j.settings.backgroundPadding = 24;
    j.settings.gradientStartColor = { red: 0.98, green: 0.45, blue: 0.1, opacity: 1 };
    j.settings.gradientEndColor = { red: 0.85, green: 0.1, blue: 0.25, opacity: 1 };
  });
  // The API's V object (docs/project-history.md §6.1); isHead is set per response.
  const version = (id, seq, revision, extra) => ({
    id, seq, kind: "edit", label: null, namedBy: null, namedAt: null, actor: { uid: "u-ana", name: "Ana" },
    client: "web", source: "human", firstRevision: revision, revision, documentBytes: 6000, documentSha256: "0".repeat(64),
    change: null, restoredFrom: null, mergedFromRevision: null, openedAt: extra.updatedAt, ...extra,
  });
  return {
    revision: 3,
    doc: v3,
    updatedAt: iso(2 * HOUR),
    docs: { v1, v2, v3 },
    versions: [
      version("v3", 3, 3, { updatedAt: iso(2 * HOUR), change: { v: 1, items: { zoomRegions: { added: [ZOOM_ID] } }, settings: { background: ["backgroundPadding"] }, fields: [] } }),
      version("v2", 2, 2, { updatedAt: iso(DAY + HOUR), actor: { uid: "u-ben", name: "Ben" }, client: "mac", source: "agent", change: { v: 1, items: {}, settings: { background: ["backgroundPadding", "gradientEndColor", "gradientStartColor"] }, fields: ["name"] } }),
      version("v1", 1, 1, { kind: "upload", updatedAt: iso(3 * DAY), actor: { uid: "u-ben", name: "Ben" }, client: "mac" }),
    ],
    nextSeq: 4,
    pinnedMediaBytes: 356 * 1024 * 1024,
    freeableBytes: 120 * 1024 * 1024,
    capBlocked: false,
    stages: 0,
    freeUps: 0,
    r2Puts: 0,
    extraFiles: [],
    puts: [],
    restores: [],
    patches: [],
    deletes: [],
    lists: 0,
    script: [], // queued PUT answers: (body, headers) => response | null
  };
}
let S = freshServer();

const cors = (req) => ({
  "Access-Control-Allow-Origin": req.headers()["origin"] ?? BASE,
  "Access-Control-Allow-Credentials": "true",
  "Access-Control-Allow-Methods": "GET,POST,PUT,PATCH,DELETE,OPTIONS",
  "Access-Control-Allow-Headers": req.headers()["access-control-request-headers"] ?? "Content-Type, If-Match",
});

const browser = await chromium.launch({
  channel: "chrome",
  headless: !args.includes("--headed"),
  args: ["--autoplay-policy=no-user-gesture-required", "--enable-gpu", "--ignore-gpu-blocklist"],
});
const context = await browser.newContext({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 1 });
const page = await context.newPage();
const pageErrors = [];
page.on("pageerror", (e) => pageErrors.push(e.message));

const json = (route, status, body) =>
  route.fulfill({ status, body: JSON.stringify(body), headers: { ...cors(route.request()), "Content-Type": "application/json" } });
const file = (p, type) => ({ path: p, sha256: "0".repeat(64), bytes: 1, contentType: type, source: null, url: `${BASE}/__fixture/${p}` });
const FILES = () => [file("recording.mp4", "video/mp4"), file("cursor.json", "application/json"), ...S.extraFiles];
const conflict = () => ({ code: "revision_conflict", error: "This project changed since your copy was loaded", revision: S.revision, documentSha256: "0".repeat(64), updatedAt: S.updatedAt, headVersionId: S.versions[0]?.id ?? null, document: S.doc });
const V = (v) => ({ ...v, isHead: v.id === S.versions[0]?.id });

await context.route(`${API}/**`, async (route) => {
  const req = route.request();
  if (req.method() === "OPTIONS") return route.fulfill({ status: 204, headers: cors(req) });
  const url = new URL(req.url());
  const path = url.pathname.replace(/^\/api/, "");
  const m = /^\/cloud-projects\/([^/]+)(\/.*)?$/.exec(path);
  if (!m) return json(route, 404, { error: `unmocked ${path}` });
  const pid = decodeURIComponent(m[1]).toUpperCase();
  const rest = m[2] ?? "";
  const free = pid === FREE_ID;
  if (pid !== ID && !free) return json(route, 404, { error: "Project not found" });
  const headers = req.headers();

  if (rest === "" && req.method() === "GET") {
    return json(route, 200, {
      projectId: pid, name: "Launch walkthrough", revision: S.revision, documentSha256: null, access: "owner", isOwner: true, orgId: null,
      updatedAt: S.updatedAt, document: free ? docOf(undefined, FREE_ID) : S.doc, files: FILES(), urlsExpireAt: new Date(Date.now() + 3600_000).toISOString(),
    });
  }
  if (rest === "/files") return json(route, 200, { revision: S.revision, files: FILES(), urlsExpireAt: new Date(Date.now() + 3600_000).toISOString() });
  // Stage / finalize (ProjectMedia uploads): at the cap while history keeps removed media → 413.
  if (rest === "" && req.method() === "PUT") {
    S.stages++;
    if (S.capBlocked) return json(route, 413, { error: "Storage limit reached (1 GB). Delete shared videos or old versions before uploading more.", code: "storage_limit_reached", usedBytes: 1e9, limitBytes: 1e9, remainingBytes: 0 });
    const manifest = JSON.parse(req.postData() ?? "{}");
    const known = new Set(FILES().map((f) => f.sha256));
    const missing = manifest.files.filter((f) => !known.has(f.sha256)).map((f) => ({ sha256: f.sha256, bytes: f.bytes, contentType: f.contentType, paths: [f.path], method: "PUT", uploadUrl: `https://r2.mock.invalid/put/${f.sha256}`, headers: {} }));
    S.staged = manifest.files;
    return json(route, 200, { projectId: pid, revision: S.revision, documentSha256: null, missing, presentCount: manifest.files.length - missing.length, expiresIn: 900 });
  }
  if (rest === "/finalize" && req.method() === "POST") {
    const known = new Set(FILES().map((f) => f.sha256));
    for (const f of S.staged ?? []) if (!known.has(f.sha256)) S.extraFiles.push({ path: f.path, sha256: f.sha256, bytes: f.bytes, contentType: f.contentType, source: null, url: `${BASE}/__fixture/cursor.json` });
    return json(route, 200, { projectId: pid, revision: S.revision, fileCount: FILES().length, totalBytes: 1 });
  }
  if (rest === "/history/free-up" && req.method() === "POST") {
    S.freeUps++;
    const victims = S.versions.slice(1).filter((v) => !v.label && v.kind !== "upload");
    S.versions = S.versions.filter((v) => !victims.includes(v));
    const released = S.freeableBytes;
    S.pinnedMediaBytes -= released;
    S.freeableBytes = 0;
    S.capBlocked = false;
    return json(route, 200, { projectId: pid, deletedVersions: victims.map((v) => v.id), releasedBytes: released, pinnedMediaBytes: S.pinnedMediaBytes, freeableBytes: 0 });
  }
  if (rest === "/project" && req.method() === "PUT") {
    const body = req.postData() ?? "";
    const rec = { at: Date.now(), ifMatch: headers["if-match"], headers: Object.fromEntries(Object.entries(headers).filter(([k]) => k.startsWith("x-cc-"))), body };
    S.puts.push(rec);
    const scripted = S.script.shift();
    if (scripted) {
      const r = scripted(body, headers);
      if (r) return json(route, r.status, r.body);
    }
    if (headers["if-match"] !== `"${S.revision}"`) {
      return json(route, 409, conflict());
    }
    S.revision++;
    S.doc = body;
    S.updatedAt = new Date().toISOString();
    const id = `v${S.nextSeq}`;
    S.docs[id] = body;
    const checkpoint = headers["x-cc-checkpoint"];
    S.versions.unshift({
      id, seq: S.nextSeq++, kind: checkpoint === "merge" || headers["x-cc-merged-from"] ? "merge" : "edit", label: null, namedBy: null, namedAt: null,
      actor: { uid: "u-me", name: "Mike" }, client: headers["x-cc-client"] ?? "unknown", source: headers["x-cc-source"] ?? "human",
      firstRevision: S.revision, revision: S.revision, documentBytes: body.length, documentSha256: "0".repeat(64),
      change: headers["x-cc-change"] ? unb64(headers["x-cc-change"]) : null, restoredFrom: null, openedAt: S.updatedAt, updatedAt: S.updatedAt,
      mergedFromRevision: headers["x-cc-merged-from"] ? Number(headers["x-cc-merged-from"]) : null,
    });
    rec.status = 200;
    return json(route, 200, { projectId: pid, revision: S.revision, documentSha256: "0".repeat(64), updatedAt: S.updatedAt, version: { id, seq: S.nextSeq - 1, extended: false } });
  }
  if (rest === "/versions" && req.method() === "GET") {
    S.lists++;
    const limit = Math.min(200, Math.max(1, Number(url.searchParams.get("limit") ?? 50)));
    if (free) {
      const head = { ...S.versions[0], id: "vfree", isHead: true };
      return json(route, 200, { projectId: pid, revision: 1, headVersionId: "vfree", access: "owner", versions: [head], nextBefore: null, retention: { maxHistoryDays: 0, maxNamedVersions: 0, namedCount: 0 }, pinnedMediaBytes: 0, freeableBytes: 0 });
    }
    return json(route, 200, {
      projectId: pid, revision: S.revision, headVersionId: S.versions[0]?.id ?? null, access: "owner",
      versions: S.versions.slice(0, limit).map(V), nextBefore: S.versions.length > limit ? S.versions[limit - 1].seq : null,
      retention: { maxHistoryDays: 30, maxNamedVersions: 25, namedCount: S.versions.filter((v) => v.label).length },
      pinnedMediaBytes: S.pinnedMediaBytes, freeableBytes: S.freeableBytes,
    });
  }
  const vm = /^\/versions\/([^/]+)(\/restore)?$/.exec(rest);
  if (vm) {
    const vid = decodeURIComponent(vm[1]);
    const v = S.versions.find((x) => x.id === vid);
    if (!v) return json(route, 404, { error: "Version not found" });
    if (vm[2] && req.method() === "POST") {
      S.restores.push({ vid, ifMatch: headers["if-match"] });
      if (headers["if-match"] !== `"${S.revision}"`) {
        return json(route, 409, conflict());
      }
      S.revision++;
      S.doc = S.docs[vid];
      S.updatedAt = new Date().toISOString();
      const id = `v${S.nextSeq}`;
      S.docs[id] = S.doc;
      S.versions.unshift({ ...v, id, seq: S.nextSeq++, revision: S.revision, firstRevision: S.revision, kind: "restore", label: null, namedBy: null, namedAt: null, restoredFrom: vid, updatedAt: S.updatedAt, actor: { uid: "u-me", name: "Mike" }, client: headers["x-cc-client"] ?? "unknown" });
      return json(route, 200, { projectId: pid, revision: S.revision, documentSha256: "0".repeat(64), updatedAt: S.updatedAt, restoredFrom: vid, version: { id, seq: S.nextSeq - 1, extended: false }, fileCount: FILES().length });
    }
    if (req.method() === "GET") {
      return json(route, 200, {
        projectId: pid, version: V(v), document: S.docs[vid], missingPaths: [],
        files: [{ ...file("recording.mp4", "video/mp4"), url: `${BASE}/__fixture/recording.mp4?version=${vid}` }, file("cursor.json", "application/json")],
        urlsExpireAt: new Date(Date.now() + 900_000).toISOString(),
      });
    }
    if (req.method() === "PATCH") {
      const { label } = JSON.parse(req.postData() ?? "{}");
      S.patches.push({ vid, label });
      v.label = label || null;
      v.namedBy = v.label ? { uid: "u-me", name: "Mike" } : null;
      return json(route, 200, { projectId: pid, version: V(v) });
    }
    if (req.method() === "DELETE") {
      S.deletes.push(vid);
      S.versions = S.versions.filter((x) => x.id !== vid);
      return json(route, 200, { projectId: pid, deleted: true, versionId: vid, releasedBytes: 0 });
    }
  }
  return json(route, 404, { error: `unmocked ${req.method()} ${rest}` });
});
await context.route("https://r2.mock.invalid/**", (route) => {
  const req = route.request();
  const h = { "Access-Control-Allow-Origin": req.headers()["origin"] ?? BASE, "Access-Control-Allow-Methods": "PUT", "Access-Control-Allow-Headers": "Content-Type" };
  if (req.method() === "OPTIONS") return route.fulfill({ status: 204, headers: h });
  S.r2Puts++;
  return route.fulfill({ status: 200, headers: h, body: "" });
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

// ── Helpers ─────────────────────────────────────────────────────────────
const shot = (name, clip) => page.screenshot({ path: join(OUT, `${name}.png`), ...(clip ? { clip } : null) });
const editorState = () => page.evaluate(() => {
  const s = window.__editor.store.getState();
  return { sync: s.sync, dirty: s.dirty, revision: s.revision, preview: s.preview, undoLabel: s.undoLabel, name: s.project?.name, padding: s.project?.settings.backgroundPadding, zooms: s.project?.zoomRegions.length, review: s.review ? s.review.conflicts.length : null };
});
const panel = () => page.locator("[data-history-panel]");
const wait = (ms) => page.waitForTimeout(ms);
async function openEditor(id) {
  await page.goto(`${BASE}/editor-lab/open?id=${id}`, { waitUntil: "domcontentloaded" });
  await page.getByRole("button", { name: "Export…" }).waitFor({ timeout: 60_000 });
  await page.waitForFunction(() => window.__editor?.store?.getState().project != null, null, { timeout: 60_000 });
  await wait(2500); // engine + first frame
}
async function rowMenu(versionId, item) {
  await page.locator(`[data-version-id="${versionId}"]`).click({ button: "right" });
  await page.locator(".cc-menu__row", { hasText: item }).first().click();
}
async function untilPuts(n, timeout = 8000) {
  const t0 = Date.now();
  while (S.puts.length < n && Date.now() - t0 < timeout) await wait(100);
  return S.puts.length >= n;
}
const historyKey = () => page.getByRole("button", { name: "History", exact: true });

try {
  await openEditor(ID);
  check((await historyKey().count()) === 1, "top bar has the History key (cloud project)");

  // ── motion: 6 frames, mid-flight ──────────────────────────────────────
  {
    const cdp = await context.newCDPSession(page);
    await cdp.send("Animation.enable");
    await cdp.send("Animation.setPlaybackRate", { playbackRate: 0.1 });
    const col = await page.locator(".cc-inspectorcol").boundingBox();
    await historyKey().click();
    const frames = [];
    for (let i = 0; i < 6; i++) {
      const sample = await page.evaluate(() => {
        const el = document.querySelector("[data-history-panel]");
        if (!el) return null;
        const cs = getComputedStyle(el);
        const m = new DOMMatrixReadOnly(cs.transform === "none" ? undefined : cs.transform);
        return { opacity: Number(cs.opacity), tx: m.m41, running: el.getAnimations().length };
      });
      await shot(`motion-${i + 1}`, col ? { x: col.x, y: col.y, width: col.width, height: Math.min(col.height, 420) } : undefined);
      frames.push(sample);
      await wait(70);
    }
    await cdp.send("Animation.setPlaybackRate", { playbackRate: 1 });
    report.motion = frames;
    console.log("  motion frames:", frames.map((f) => (f ? `o=${f.opacity.toFixed(3)} x=${f.tx.toFixed(2)}` : "none")).join(" | "));
    const mid = frames.filter((f) => f && ((f.opacity > 0.01 && f.opacity < 0.99) || (f.tx > 0.5 && f.tx < 27.5)));
    check(frames.every(Boolean), "motion: the pane exists in all 6 frames");
    check(mid.length >= 3, `motion: ${mid.length}/6 frames mid-flight (opacity ∈ (0,1) or 0 < translateX < 28)`);
    check(frames[0] && frames[5] && (frames[5].opacity >= frames[0].opacity && frames[5].tx <= frames[0].tx), "motion: moving toward rest (opacity up, offset down)");
    await wait(1500);
    const settled = await page.evaluate(() => {
      const el = document.querySelector("[data-history-panel]");
      const cs = getComputedStyle(el);
      const m = new DOMMatrixReadOnly(cs.transform === "none" ? undefined : cs.transform);
      return { opacity: Number(cs.opacity), tx: m.m41 };
    });
    check(settled.opacity === 1 && Math.abs(settled.tx) < 0.01, `motion: settled (opacity ${settled.opacity}, x ${settled.tx})`);

    // Reduced motion: no animation at all.
    await historyKey().click();
    await wait(800);
    check((await panel().count()) === 0, "close: the pane leaves");
    await page.emulateMedia({ reducedMotion: "reduce" });
    await historyKey().click();
    const instant = await page.evaluate(() => {
      const el = document.querySelector("[data-history-panel]");
      return el ? { opacity: Number(getComputedStyle(el).opacity), running: el.getAnimations().length } : null;
    });
    check(instant && instant.opacity === 1 && instant.running === 0, `reduced motion: appears without animating (${JSON.stringify(instant)})`);
    await page.emulateMedia({ reducedMotion: "no-preference" });
  }

  // ── list ───────────────────────────────────────────────────────────────
  await page.locator('[data-version-id="v3"]').waitFor({ timeout: 10_000 });
  await wait(300);
  await shot("01-history-list");
  const titles = await page.locator(".cc-hsection__title").allInnerTexts();
  check(titles[0] === "TODAY" || titles[0] === "Today", `day sections: ${titles.join(", ")}`);
  check((await page.locator('[data-version-id="v2"] .cc-hbadge', { hasText: "Mac" }).count()) === 1, "v2: Mac badge");
  check((await page.locator('[data-version-id="v2"] .cc-hbadge', { hasText: "Agent" }).count()) === 1, "v2: Agent badge");
  check((await page.locator('[data-version-id="v3"] .cc-hrow__caption').innerText()).includes("Zoom added · Background changed"), "v3: change summary caption");
  check((await page.locator(".cc-hrow[data-current]").innerText()).includes("Current"), "Current top row");
  check((await page.locator(".cc-history__foot").innerText()).includes("History keeps 356 MB of removed media"), "owner footer: pinned media");
  check((await page.locator(".cc-history__foot").getByRole("button", { name: "Free Up 120 MB" }).count()) === 1, "owner footer: Free Up shows the freeable bytes");

  // ── preview ─────────────────────────────────────────────────────────────
  const putsBefore = S.puts.length;
  await page.locator('[data-version-id="v1"]').click();
  await page.locator(".cc-callout", { hasText: "Viewing" }).waitFor({ timeout: 10_000 });
  await wait(1500);
  await shot("02-preview");
  let st = await editorState();
  check(st.preview?.versionId === "v1" && st.name === "Launch walkthrough (first cut)" && st.padding === 24, `preview shows v1 (${st.name}, padding ${st.padding})`);
  check(/Viewing .+ — Ben on Mac/.test(await page.locator(".cc-callout", { hasText: "Viewing" }).innerText()), "preview callout: “Viewing <date> — Ben on Mac”");
  // Edits are refused while previewing; nothing saves.
  await page.evaluate(() => window.__editor.store.updateSettings({ backgroundPadding: 99 }));
  await page.keyboard.press("Meta+z");
  await page.locator(".cc-stagecol").click({ position: { x: 20, y: 20 } }).catch(() => {});
  await page.keyboard.press("Delete");
  await wait(2000);
  st = await editorState();
  check(st.padding === 24 && st.dirty === false && S.puts.length === putsBefore, `preview: read-only, not dirty, no saves (puts ${S.puts.length - putsBefore})`);
  check(st.undoLabel === null, "preview: undo off");

  // ── restore ─────────────────────────────────────────────────────────────
  const revBefore = S.revision;
  await page.locator(".cc-callout", { hasText: "Viewing" }).getByRole("button", { name: "Restore" }).click();
  await page.locator(".cc-alert__card").waitFor();
  await shot("03-restore-confirm");
  check((await page.locator(".cc-alert__card").innerText()).includes("Your current version stays in History"), "restore confirm copy");
  await page.locator(".cc-alert__card").getByRole("button", { name: "Restore" }).click();
  await page.waitForFunction(() => window.__editor.store.getState().undoLabel === "Restore Version", null, { timeout: 10_000 });
  await wait(800);
  await shot("04-restored");
  st = await editorState();
  check(S.restores.length === 1 && S.restores[0].vid === "v1" && S.restores[0].ifMatch === `"${revBefore}"`, `restore: POST …/v1/restore with If-Match "${revBefore}"`);
  check(st.preview === null && st.padding === 24 && st.revision === S.revision && st.dirty === false, `restore: applied at revision ${st.revision}`);
  check(st.undoLabel === "Restore Version", "restore: one undo step, “Restore Version”");
  check(S.puts.length === putsBefore, "restore: no PUT (the API saved it)");

  // ── name ───────────────────────────────────────────────────────────────
  await page.locator('[data-version-id="v2"]').waitFor();
  await rowMenu("v2", "Name This Version…");
  const field = page.getByLabel("Version name");
  await field.waitFor();
  await field.fill("Pitch cut");
  await shot("05-naming");
  await field.press("Enter");
  await page.locator('[data-version-id="v2"] .cc-hrow__label', { hasText: "Pitch cut" }).waitFor({ timeout: 5000 });
  await shot("06-named");
  check(S.patches.length === 1 && S.patches[0].vid === "v2" && S.patches[0].label === "Pitch cut", "name: PATCH {label: \"Pitch cut\"}");
  check((await page.locator('[data-version-id="v2"] .cc-hbadge[data-tone="named"]').count()) === 1, "name: Named badge");

  // ── compare ────────────────────────────────────────────────────────────
  await rowMenu("v3", "Compare with Current");
  await page.locator("[data-history-compare] .cc-hcrow").first().waitFor({ timeout: 5000 });
  await wait(400);
  await shot("07-compare");
  const groups = await page.locator("[data-history-compare] .cc-hsection__title").allInnerTexts();
  const rows = await page.locator("[data-history-compare] .cc-hcrow").allInnerTexts();
  check(groups.map((g) => g.toUpperCase()).includes("TIMELINE") && groups.map((g) => g.toUpperCase()).includes("BACKGROUND"), `compare groups: ${groups.join(", ")}`);
  check(rows.some((r) => r.startsWith("Zoom 0:00–0:02 removed")), `compare rows: ${rows.slice(0, 4).join(" | ")}`);
  const zoomRow = page.locator("[data-history-compare] .cc-hcrow", { hasText: "Zoom" }).first();
  await page.evaluate(() => window.__editor.controller.seek(3));
  await zoomRow.click();
  await wait(300);
  const t = await page.evaluate(() => window.__editor.controller.playhead.get());
  check(Math.abs(t - 0.5) < 0.05, `compare: clicking the zoom row seeks to its start (playhead ${t.toFixed(3)})`);
  await page.getByRole("button", { name: "Back to History" }).click();

  // ── merge (clean 409) ──────────────────────────────────────────────────
  {
    const n0 = S.puts.length;
    // The server moves on (Ana renames the project on the web); our next save collides.
    S.script.push(() => {
      const theirs = JSON.parse(S.doc);
      theirs.name = "Launch walkthrough — Ana's title";
      S.revision++;
      S.doc = JSON.stringify(theirs, null, 2);
      S.updatedAt = new Date(Date.now() - 60_000).toISOString();
      S.docs[`v${S.nextSeq}`] = S.doc;
      S.versions.unshift({ id: `v${S.nextSeq}`, seq: S.nextSeq++, revision: S.revision, firstRevision: S.revision, kind: "edit", label: null, actor: { uid: "u-ana", name: "Ana" }, client: "web", source: "human", change: { v: 1, items: {}, settings: {}, fields: ["name"] }, updatedAt: S.updatedAt, openedAt: S.updatedAt });
      return { status: 409, body: { code: "revision_conflict", error: "changed", revision: S.revision, updatedAt: S.updatedAt, document: S.doc } };
    });
    await page.evaluate(() => window.__editor.store.updateSettings({ backgroundPadding: 48 }));
    check(await untilPuts(n0 + 2), `merge: two PUTs (the 409, then the merge) — got ${S.puts.length - n0}`);
    await page.locator(".cc-callout", { hasText: "Merged" }).waitFor({ timeout: 8000 });
    await page.locator(".cc-callout", { hasText: "from Ana (Web)" }).waitFor({ timeout: 8000 });
    await wait(500);
    await shot("08-merged-callout");
    await wait(2500);
    const merge = S.puts[n0 + 1];
    const body = JSON.parse(merge.body);
    check(S.puts.length === n0 + 2, "merge: exactly one merge save");
    check(merge.headers["x-cc-checkpoint"] === "merge" && merge.headers["x-cc-merged-from"] === String(S.revision - 1) && merge.ifMatch === `"${S.revision - 1}"`, `merge: X-CC-Checkpoint merge, X-CC-Merged-From ${merge.headers["x-cc-merged-from"]}, If-Match ${merge.ifMatch}`);
    check(body.name === "Launch walkthrough — Ana's title" && body.settings.backgroundPadding === 48, "merge: both edits in the saved document");
    const change = unb64(merge.headers["x-cc-change"] ?? "");
    check(change?.settings?.background?.includes("backgroundPadding") && !change?.fields?.includes("name"), `merge: X-CC-Change = theirs → merged (${JSON.stringify(change)})`);
    const first = S.puts[n0];
    check(first.headers["x-cc-client"] === "web" && /^[A-Za-z0-9_-]{8,64}$/.test(first.headers["x-cc-client-id"] ?? "") && first.headers["x-cc-source"] === "human", `save headers: client web, client id, source human (${JSON.stringify(first.headers)})`);
    const calloutText = await page.locator(".cc-callout", { hasText: "Merged" }).innerText();
    check(/Merged 1 change from Ana \(Web\)/.test(calloutText), `merge callout: “${calloutText.split("\n")[0]}”`);
    st = await editorState();
    check(st.undoLabel === "Merge Changes" && st.sync === "saved", `merge: one undo step (${st.undoLabel}), sync ${st.sync}`);
  }

  // ── review (structural conflict) ───────────────────────────────────────
  {
    // Ensure the zoom exists locally (an undo would bring it back; simpler: put it back via the store).
    await page.evaluate((zid) => {
      const store = window.__editor.store;
      if (!store.getState().project.zoomRegions.some((z) => z.id === zid)) {
        store.transact("Add Zoom", (d) => void d.zoomRegions.push({ id: zid, startTime: 0.5, endTime: 2.4, zoomLevel: 2, focalPoint: { x: 0.4, y: 0.4 }, animationStyle: "Snappy" }));
      }
    }, ZOOM_ID);
    await page.waitForFunction(() => window.__editor.store.getState().sync === "saved", null, { timeout: 8000 });
    const n0 = S.puts.length;
    S.script.push(() => {
      const theirs = JSON.parse(S.doc);
      theirs.zoomRegions = []; // Ana deleted the zoom we are about to edit
      S.revision++;
      S.doc = JSON.stringify(theirs, null, 2);
      S.updatedAt = new Date(Date.now() - 30_000).toISOString();
      S.versions.unshift({ id: `v${S.nextSeq}`, seq: S.nextSeq++, revision: S.revision, firstRevision: S.revision, kind: "edit", label: null, actor: { uid: "u-ana", name: "Ana" }, client: "web", source: "human", change: { v: 1, items: { zoomRegions: { removed: ["x"] } }, settings: {}, fields: [] }, updatedAt: S.updatedAt, openedAt: S.updatedAt });
      return { status: 409, body: { code: "revision_conflict", error: "changed", revision: S.revision, updatedAt: S.updatedAt, document: S.doc } };
    });
    // We edit that zoom (the conflict) and the padding (merges cleanly either way).
    await page.evaluate((zid) => {
      window.__editor.store.updateRegion("zoom", zid, { zoomLevel: 3 });
      window.__editor.store.updateSettings({ backgroundPadding: 52 });
    }, ZOOM_ID);
    await page.locator("[data-merge-review] [data-conflict-id]").first().waitFor({ timeout: 10_000 });
    await wait(2500);
    await shot("09-merge-review");
    st = await editorState();
    check(st.sync === "review" && st.review === 1, `review: sync ${st.sync}, ${st.review} conflict`);
    check(S.puts.length === n0 + 1, `review: nothing saves while reviewing (puts ${S.puts.length - n0})`);
    check((await page.locator(".cc-sync").innerText()).includes("Needs review"), "review: the badge reads “Needs review”");
    const card = page.locator("[data-merge-review] [data-conflict-id]").first();
    check((await card.getAttribute("data-kind")) === "deleteVsModify", "review: delete-vs-modify conflict");
    check((await card.innerText()).includes("Ana deleted it; you edited it."), "review: conflict copy names Ana");
    // Default = last writer (mine edited last) → "Mine" selected; pick Theirs.
    await card.getByRole("radio", { name: "Theirs" }).click();
    await wait(300);
    await shot("10-review-theirs");
    await page.getByRole("button", { name: "Apply Merge" }).click();
    check(await untilPuts(n0 + 2), "review: Apply → one merge save");
    await wait(1500);
    const merge = S.puts[n0 + 1];
    const body = merge ? JSON.parse(merge.body) : null;
    check(merge?.headers["x-cc-checkpoint"] === "merge" && body?.zoomRegions?.length === 0 && body?.settings?.backgroundPadding === 52, "review: saved with the merge checkpoint — their delete + our padding");
    check(S.puts.length === n0 + 2, "review: exactly one save after Apply");
    st = await editorState();
    check(st.sync === "saved" && st.review === null, `review: resolved (sync ${st.sync})`);
    await shot("11-review-resolved");
  }

  // ── storage cap: an upload history blocks → Free up history → the retry lands ──
  {
    S.capBlocked = true;
    const stages0 = S.stages;
    const outcome = page.evaluate(async () => {
      const bytes = new TextEncoder().encode("a fresh logo, not in the project yet");
      const d = await crypto.subtle.digest("SHA-256", bytes);
      const sha = [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
      try {
        await window.__editor.media.addFile({ ref: "logo-new.png", path: "logo-new.png", blob: new Blob([bytes], { type: "image/png" }), sha256: sha, contentType: "image/png" });
        return "ok";
      } catch (e) {
        return `${e.name}: ${e.message}`;
      }
    });
    check((await outcome) === "HistoryStorageError: History is keeping 120 MB of removed media — Free up history to make room.", `upload at the cap: ${await outcome}`);
    const callout = page.locator(".cc-callout", { hasText: "History is keeping 120 MB of removed media — Free up history to make room." });
    await callout.waitFor({ timeout: 5000 });
    await wait(500);
    await shot("13-storage-cap-callout");
    await callout.getByRole("button", { name: "Free Up History" }).click();
    await page.locator(".cc-alert__card").waitFor();
    check((await page.locator(".cc-alert__card").innerText()).includes("History is keeping media this project no longer uses"), "free up confirm explains the upload");
    await shot("14-free-up-confirm");
    await page.locator(".cc-alert__card").getByRole("button", { name: "Free Up" }).click();
    await page.waitForFunction(() => !window.__editor.media.historyBlock && !window.__editor.media.uploading, null, { timeout: 10_000 });
    await wait(600);
    await shot("15-freed-and-uploaded");
    check(S.freeUps === 1, "free up: POST …/history/free-up");
    check(S.stages === stages0 + 2 && S.r2Puts >= 1, `free up: the upload retried and landed (stages ${S.stages - stages0}, R2 PUTs ${S.r2Puts})`);
    check((await callout.count()) === 0, "free up: the callout is gone");
    const foot = await page.locator(".cc-history__foot").innerText().catch(() => "");
    check(!foot.includes("Free Up"), `footer after free up: “${foot.replace(/\s+/g, " ").trim()}”`);
  }

  // ── gated (Free) ───────────────────────────────────────────────────────
  await openEditor(FREE_ID);
  await historyKey().click();
  await page.locator("[data-history-upsell]").waitFor({ timeout: 10_000 });
  await wait(600);
  await shot("12-gated-upsell");
  check((await page.locator("[data-history-upsell]").innerText()).includes("Version history is part of Pro"), "Free: upsell line, not a broken pane");

  check(pageErrors.length === 0, `no page errors (${pageErrors.slice(0, 3).join(" | ")})`);
} catch (error) {
  failures.push(String(error?.stack ?? error));
  console.error(error);
  await shot("zz-failure").catch(() => {});
} finally {
  report.failures = failures;
  report.puts = S.puts.map((p) => ({ ifMatch: p.ifMatch, headers: p.headers }));
  writeFileSync(join(OUT, "report.json"), JSON.stringify(report, null, 2));
  await browser.close();
}
console.log(failures.length ? `\n${failures.length} FAILED` : "\nALL PASS");
console.log(`evidence: ${OUT}`);
process.exit(failures.length ? 1 : 0);
