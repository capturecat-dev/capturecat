#!/usr/bin/env node
/**
 * MCP parity runner — proves the web editor's WebMCP tool cores
 * (src/editor/webmcp/ops) behave EXACTLY like the Mac MCP server.
 *
 * For every scenario in scenarios.mjs it makes a throwaway copy of a
 * synthetic parity fixture inside the app container's Projects folder, then
 * runs the SAME op sequence through
 *   (a) the real Mac server  (`CaptureCat --mcp`, JSON-RPC over stdio), and
 *   (b) the TS cores          (webServer.ts, bundled here with esbuild),
 * and compares after every step:
 *   - the tool result JSON (or the exact `ERROR: …` text),
 *   - the resulting project.json, SEMANTICALLY: both sides are decoded with
 *     the TS `parseProject` and re-encoded with `serializeProject`; freshly
 *     generated UUIDs are mapped by order of first appearance; numbers must
 *     agree within 1e-9.
 * A failing call must leave project.json byte-identical on the Mac.
 *
 * Usage (from apps/web):
 *   node scripts/mcp-parity/run.mjs [--binary <CaptureCat>] [--only <name,…>] [--verbose] [--show]
 *
 * Needs: the built Debug app (see mac.mjs DEFAULT_BINARY), .fixtures/parity
 * (scripts/sync-parity-fixtures.sh), ffmpeg/ffprobe on PATH (audio fixture).
 * Every folder it creates is deleted at the end, pass or fail.
 */
import { spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import { DEFAULT_BINARY, MacServer, Sandbox } from "./mac.mjs";
import { buildScenarios, syntheticAudioSamples } from "./scenarios.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const webRoot = path.resolve(here, "../..");
const fixturesRoot = path.join(webRoot, ".fixtures/parity");

const argv = process.argv.slice(2);
const option = (name) => {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : undefined;
};
const binary = option("--binary") ?? DEFAULT_BINARY;
const only = option("--only")?.split(",");
const verbose = argv.includes("--verbose");
const show = argv.includes("--show"); // print the Mac server's full reply per step

// ── Bundle the TS side ──────────────────────────────────────────────────────

async function loadWeb(tmpDir) {
  const { build } = await import("esbuild");
  const autoZoomPath = path.join(webRoot, "src/editor/core/edit/autoZoom.ts");
  const hasAutoZoom = fs.existsSync(autoZoomPath);
  const entry =
    `export * from ${JSON.stringify(path.join(here, "webServer.ts"))};\n` +
    (hasAutoZoom
      ? `export { applyAutoZoom, applyStillMotion } from ${JSON.stringify(autoZoomPath)};\n`
      : "export const applyAutoZoom = null; export const applyStillMotion = null;\n");
  const outfile = path.join(tmpDir, "web-parity-bundle.mjs");
  await build({
    stdin: { contents: entry, resolveDir: webRoot, loader: "ts", sourcefile: "entry.ts" },
    bundle: true,
    format: "esm",
    platform: "node",
    target: "node20",
    outfile,
    logLevel: "error",
  });
  return { web: await import(pathToFileURL(outfile).href), hasAutoZoom };
}

// ── Media probes for the web host ───────────────────────────────────────────

function run(cmd, args, options = {}) {
  const result = spawnSync(cmd, args, { maxBuffer: 1 << 28, ...options });
  if (result.error) throw result.error;
  return result;
}

const silenceCache = new Map();
function silenceFor(web, videoPath) {
  if (!videoPath || !fs.existsSync(videoPath)) return null;
  if (silenceCache.has(videoPath)) return silenceCache.get(videoPath);
  const probe = run("ffprobe", ["-v", "error", "-select_streams", "a", "-show_entries", "stream=index", "-of", "csv=p=0", videoPath]);
  const tracks = probe.stdout.toString().trim().split("\n").filter(Boolean).length;
  let outcome;
  if (tracks === 0) {
    outcome = { kind: "noAudio" };
  } else {
    const mix = tracks > 1 ? ["-filter_complex", `amix=inputs=${tracks}:normalize=0`] : ["-map", "0:a:0"];
    const pcm = run("ffmpeg", ["-v", "error", "-i", videoPath, ...mix, "-ac", "1", "-ar", "8000", "-f", "f32le", "-"]);
    const buf = pcm.stdout;
    const samples = new Float32Array(buf.buffer, buf.byteOffset, Math.floor(buf.length / 4));
    outcome = web.analyzeSilence(Float32Array.from(samples), tracks);
  }
  silenceCache.set(videoPath, outcome);
  return outcome;
}

function videoNaturalSize(videoPath) {
  if (!videoPath || !fs.existsSync(videoPath)) return null;
  const probe = run("ffprobe", ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height", "-of", "csv=p=0", videoPath]);
  const [w, h] = probe.stdout.toString().trim().split(",").map(Number);
  return Number.isFinite(w) && Number.isFinite(h) ? { width: w, height: h } : null;
}

const filePath = (url) => (typeof url === "string" && url.startsWith("file:") ? fileURLToPath(url) : null);

function readJSON(p) {
  try {
    return JSON.parse(fs.readFileSync(p, "utf8"));
  } catch {
    return null;
  }
}

function makeHost(web, dir, hasAutoZoom) {
  const cursorFor = (project) => {
    // Mac: projectDir/cursor.json first, else project.cursorDataURL.
    let p = path.join(dir, "cursor.json");
    if (!fs.existsSync(p)) p = filePath(project.cursorDataURL);
    const json = p ? readJSON(p) : null;
    if (json === null) return null;
    if (Array.isArray(json)) return { events: json, size: { width: 0, height: 0 } };
    return { events: json.events ?? [], size: { width: json.coordinateWidth ?? 0, height: json.coordinateHeight ?? 0 } };
  };
  const keysFor = (project) => {
    const p = filePath(project.keystrokeDataURL);
    const json = p ? readJSON(p) : null;
    return Array.isArray(json?.events) ? json.events : [];
  };
  const autoZoomCursor = (project) => {
    const p = filePath(project.cursorDataURL);
    const json = p ? readJSON(p) : null;
    if (json === null) return null;
    return Array.isArray(json) ? json : json.events ?? null;
  };
  return {
    newId: () => randomUUID().toUpperCase(),
    autoZoom: hasAutoZoom
      ? (project, zoomLevel, newId) =>
          web.applyAutoZoom(
            project,
            {
              cursor: autoZoomCursor(project),
              keystrokes: keysFor(project),
              videoNaturalSize: videoNaturalSize(filePath(project.videoURL)),
            },
            zoomLevel,
            newId,
          )
      : null,
    stillMotion: hasAutoZoom ? (project, newId) => web.applyStillMotion(project, newId) : null,
    readCursor: cursorFor,
    readKeystrokes: keysFor,
    silence: (project) => silenceFor(web, filePath(project.videoURL)),
  };
}

// ── Audio fixture (8 kHz mono PCM in a .mov — no resampling on either side) ─

function makeAudioMovie(tmpDir) {
  const raw = path.join(tmpDir, "audio.s16le");
  const samples = syntheticAudioSamples(30, 8000);
  fs.writeFileSync(raw, Buffer.from(samples.buffer));
  const out = path.join(tmpDir, "recording-audio.mov");
  const r = run("ffmpeg", [
    "-v", "error", "-y",
    "-f", "lavfi", "-i", "color=c=gray:s=320x180:d=30:r=10",
    "-f", "s16le", "-ar", "8000", "-ac", "1", "-i", raw,
    "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "pcm_s16le", "-shortest", out,
  ]);
  if (r.status !== 0) throw new Error(`ffmpeg failed: ${r.stderr}`);
  return fs.readFileSync(out);
}

// ── Canonicalisation + comparison ───────────────────────────────────────────

const UUID_RE = /[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/g;

/** Maps freshly generated (random, v4) UUIDs to NEW#n by first appearance.
 * Ids present in the starting project and deterministic ids (e.g. the v5
 * stable legacy clip ids) are kept verbatim — they must match exactly. */
class Canon {
  constructor(known) {
    this.known = known;
    this.map = new Map();
  }
  str(s) {
    return s.replace(UUID_RE, (m) => {
      const u = m.toUpperCase();
      if (this.known.has(u) || u[14] !== "4") return u;
      if (!this.map.has(u)) this.map.set(u, `NEW#${this.map.size + 1}`);
      return this.map.get(u);
    });
  }
  apply(value) {
    if (typeof value === "string") return this.str(value);
    if (Array.isArray(value)) return value.map((v) => this.apply(v));
    if (value && typeof value === "object") {
      const out = {};
      for (const key of Object.keys(value).sort()) out[this.str(key)] = this.apply(value[key]);
      return out;
    }
    return value;
  }
}

function numbersEqual(a, b) {
  if (Object.is(a, b) || a === b) return true;
  return Math.abs(a - b) <= 1e-9 * Math.max(1, Math.abs(a), Math.abs(b));
}

function diff(a, b, at = "$", out = []) {
  if (out.length >= 12) return out;
  if (typeof a === "number" && typeof b === "number") {
    if (!numbersEqual(a, b)) out.push(`${at}: mac=${a} web=${b}`);
    return out;
  }
  if (Array.isArray(a) && Array.isArray(b)) {
    if (a.length !== b.length) out.push(`${at}: length mac=${a.length} web=${b.length}`);
    for (let i = 0; i < Math.min(a.length, b.length); i++) diff(a[i], b[i], `${at}[${i}]`, out);
    return out;
  }
  if (a && b && typeof a === "object" && typeof b === "object" && !Array.isArray(a) && !Array.isArray(b)) {
    const keys = new Set([...Object.keys(a), ...Object.keys(b)]);
    for (const key of [...keys].sort()) {
      if (!(key in a)) out.push(`${at}.${key}: missing on mac (web=${JSON.stringify(b[key])?.slice(0, 120)})`);
      else if (!(key in b)) out.push(`${at}.${key}: missing on web (mac=${JSON.stringify(a[key])?.slice(0, 120)})`);
      else diff(a[key], b[key], `${at}.${key}`, out);
    }
    return out;
  }
  if (a !== b) out.push(`${at}: mac=${JSON.stringify(a)?.slice(0, 300)} web=${JSON.stringify(b)?.slice(0, 300)}`);
  return out;
}

/** A tool reply as comparable data: JSON object, or {error: text}. */
function replyValue(reply) {
  if (reply.isError) return { error: reply.text };
  try {
    const value = JSON.parse(reply.text);
    if (value && typeof value === "object") {
      delete value.warning; // Mac only: "CaptureCat is currently running…"
      if (Array.isArray(value.undone)) for (const u of value.undone) u.at = "<at>";
    }
    return value;
  } catch {
    return { unparsable: reply.text };
  }
}

function normalizedProject(web, json) {
  return web.serializeProject(web.parseProject(structuredClone(json)));
}

// ── Main ────────────────────────────────────────────────────────────────────

async function main() {
  if (!fs.existsSync(fixturesRoot)) throw new Error(`missing ${fixturesRoot} — run scripts/sync-parity-fixtures.sh`);
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "capturecat-mcp-parity-"));
  const sandbox = new Sandbox(fixturesRoot);
  let server = null;
  const report = { scenarios: 0, steps: 0, compared: 0, skipped: [], diffs: [], byTool: {} };
  try {
    const { web, hasAutoZoom } = await loadWeb(tmpDir);
    server = new MacServer(binary);
    await server.initialize();
    let audioMovie = null;

    for (const scenario of buildScenarios()) {
      if (only && !only.includes(scenario.name)) continue;
      report.scenarios += 1;
      const extra = scenario.extraFiles ? scenario.extraFiles() : {};
      if (scenario.audio) extra["recording-audio.mov"] = audioMovie ??= makeAudioMovie(tmpDir);
      const copy = sandbox.create(scenario.fixture, scenario.mutate, extra);
      const initialText = fs.readFileSync(copy.projectPath, "utf8");
      const known = new Set((initialText.match(UUID_RE) ?? []).map((u) => u.toUpperCase()));
      const macCanon = new Canon(known);
      const webCanon = new Canon(known);
      const webServer = new web.WebServer(JSON.parse(initialText), makeHost(web, copy.dir, hasAutoZoom));

      for (const [index, [tool, rawArgs]] of scenario.steps.entries()) {
        const args = { id: copy.id, ...rawArgs };
        const label = `${scenario.name}#${index} ${tool}`;
        report.steps += 1;
        const macBefore = fs.readFileSync(copy.projectPath);
        const webBefore = JSON.stringify(webServer.projectJSON());

        const webReply = webServer.call(tool, structuredClone(args));
        if (webReply.skipped) {
          report.skipped.push(`${label}: ${webReply.skipped}`);
          continue; // do not run it on the Mac either: the states would fork
        }
        const macReply = await server.call(tool, args);
        const macAfterBytes = fs.readFileSync(copy.projectPath);
        report.byTool[tool] = (report.byTool[tool] ?? 0) + 1;
        report.compared += 1;

        const problems = [];
        if (macReply.isError !== webReply.isError) {
          problems.push(`isError mac=${macReply.isError} web=${webReply.isError}`);
        }
        const macValue = macCanon.apply(replyValue(macReply));
        const webValue = webCanon.apply(replyValue(webReply));
        problems.push(...diff(macValue, webValue, "result"));

        const macProject = macCanon.apply(normalizedProject(web, JSON.parse(macAfterBytes.toString("utf8"))));
        const webProject = webCanon.apply(normalizedProject(web, webServer.projectJSON()));
        problems.push(...diff(macProject, webProject, "project"));

        if (macReply.isError) {
          if (!macBefore.equals(macAfterBytes)) problems.push("mac: a failing call changed project.json");
          if (JSON.stringify(webServer.projectJSON()) !== webBefore) problems.push("web: a failing call changed the project");
        }
        if (problems.length > 0) {
          report.diffs.push({ step: label, args: JSON.stringify(rawArgs).slice(0, 300), problems });
          console.log(`DIFF  ${label}\n      ${problems.join("\n      ")}`);
        }
        if (show) {
          console.log(`---- ${label}\n${macReply.text}`);
        } else if (problems.length === 0 && verbose) {
          console.log(`ok    ${label}  ${(macReply.isError ? macReply.text : macReply.text.slice(0, 100)).slice(0, 160)}`);
        }
      }
    }
  } finally {
    server?.close();
    sandbox.cleanup();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }

  console.log("\n── MCP parity (Mac server vs web TS cores) ──");
  console.log(`scenarios ${report.scenarios}, steps ${report.steps}, compared ${report.compared}`);
  console.log(
    "by tool: " +
      Object.entries(report.byTool)
        .map(([k, v]) => `${k} ${v}`)
        .join(", "),
  );
  if (report.skipped.length) console.log(`skipped (${report.skipped.length}):\n  ${report.skipped.join("\n  ")}`);
  console.log(report.diffs.length === 0 ? "PASS — no differences" : `FAIL — ${report.diffs.length} step(s) differ`);
  process.exitCode = report.diffs.length === 0 ? 0 : 1;
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 2;
});
