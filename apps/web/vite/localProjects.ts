/// <reference types="node" />
/**
 * DEV-ONLY Vite middleware: serves the Mac app's LOCAL projects to the web
 * editor on localhost, read-only, so `vite dev` can open real recordings
 * without a cloud upload (and without R2 CORS):
 *
 *   GET /__dev/local-projects                     list (newest first)
 *   GET /__dev/local-projects/<UUID>/project.json  the document, byte-exact
 *   GET /__dev/local-projects/<UUID>/media?ref=…   a file the project REFERENCES
 *                                                  (Range requests supported)
 *
 * Registered only for `vite serve` (see vite.config.ts) — never part of a
 * build. Reads the sandbox container the Mac app writes to. Media is served
 * ONLY when it lives inside that project's folder or is exactly one of the
 * files project.json references (videoURL, cursorDataURL, keystrokeDataURL,
 * cameraVideoURL, backgroundImagePath, voice-over clips) — never an
 * arbitrary path. Nothing is ever written into the project folders.
 *
 * Images Chrome cannot decode (macOS wallpapers are HEIC; TIFF/BMP/HEIF show
 * up as backgrounds) are transcoded on the fly to PNG with macOS `sips`
 * (colour profile kept, like the Mac's CloudImageTranscoder does for cloud
 * sync) into a CONTENT-KEYED cache under the OS temp dir
 * (`$TMPDIR/capturecat-dev-images/<sha256>.png`) — the original is only read.
 */
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { createReadStream, promises as fs } from "node:fs";
import { homedir, tmpdir } from "node:os";
import path from "node:path";
import type { IncomingMessage, ServerResponse } from "node:http";
import type { Plugin } from "vite";

const PROJECTS_ROOT = path.join(
  homedir(),
  "Library/Containers/so.capturecat.CaptureCat/Data/Library/Application Support/CaptureCat/Projects",
);

const UUID_RE = /^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$/;
/** Swift's JSONEncoder default: Date as seconds since 2001-01-01T00:00:00Z. */
const APPLE_EPOCH_MS = Date.UTC(2001, 0, 1);

const CONTENT_TYPES: Record<string, string> = {
  mov: "video/quicktime",
  mp4: "video/mp4",
  m4v: "video/mp4",
  m4a: "audio/mp4",
  aac: "audio/aac",
  mp3: "audio/mpeg",
  wav: "audio/wav",
  caf: "audio/x-caf",
  png: "image/png",
  jpg: "image/jpeg",
  jpeg: "image/jpeg",
  heic: "image/heic",
  webp: "image/webp",
  gif: "image/gif",
  json: "application/json",
};

type Json = Record<string, unknown>;

async function readProject(id: string): Promise<{ dir: string; text: string; doc: Json } | null> {
  if (!UUID_RE.test(id)) return null;
  const dir = path.join(PROJECTS_ROOT, id);
  try {
    const text = await fs.readFile(path.join(dir, "project.json"), "utf8");
    return { dir, text, doc: JSON.parse(text) as Json };
  } catch {
    return null;
  }
}

/** A project.json reference (file:// URL, absolute path, or folder-relative name) → absolute path. */
function refToPath(ref: string, dir: string): string | null {
  try {
    if (ref.startsWith("file://")) return decodeURIComponent(new URL(ref).pathname);
  } catch {
    return null;
  }
  return path.isAbsolute(ref) ? ref : path.join(dir, ref);
}

/** Files the document references, as absolute paths (the allowlist beyond the folder). */
function referencedPaths(doc: Json, dir: string): Set<string> {
  const out = new Set<string>();
  const add = (ref: unknown) => {
    if (typeof ref !== "string" || !ref) return;
    const p = refToPath(ref, dir);
    if (p) out.add(path.resolve(p));
  };
  for (const key of ["videoURL", "cursorDataURL", "keystrokeDataURL", "cameraVideoURL"]) add(doc[key]);
  const settings = (doc.settings ?? {}) as Json;
  add(settings.backgroundImagePath);
  for (const clip of (doc.voiceOverClips as Json[] | undefined) ?? []) add(clip.fileName ?? clip.fileURL);
  return out;
}

async function listProjects(): Promise<Json[]> {
  let entries: string[] = [];
  try {
    entries = await fs.readdir(PROJECTS_ROOT);
  } catch {
    return [];
  }
  const rows = await Promise.all(
    entries.filter((e) => UUID_RE.test(e)).map(async (id) => {
      const project = await readProject(id);
      if (!project) return null;
      const { doc, dir } = project;
      const settings = (doc.settings ?? {}) as Json;
      const createdAt = typeof doc.createdAt === "number" ? new Date(APPLE_EPOCH_MS + doc.createdAt * 1000) : null;
      const stat = await fs.stat(path.join(dir, "project.json")).catch(() => null);
      const hasThumb = await fs.stat(path.join(dir, "thumbnail.jpg")).then(() => true, () => false);
      return {
        id,
        name: typeof doc.name === "string" ? doc.name : "Untitled",
        duration: typeof doc.duration === "number" ? doc.duration : 0,
        createdAt: createdAt?.toISOString() ?? null,
        updatedAt: stat?.mtime.toISOString() ?? createdAt?.toISOString() ?? null,
        aspectRatio: typeof settings.aspectRatio === "string" ? settings.aspectRatio : "Auto",
        isStillCapture: doc.isStillCapture === true,
        hasVideo: typeof doc.videoURL === "string",
        thumbnail: hasThumb ? `/__dev/local-projects/${id}/media?ref=thumbnail.jpg` : null,
      };
    }),
  );
  return rows
    .filter((r): r is NonNullable<typeof r> => r !== null)
    .sort((a, b) => String(b.updatedAt).localeCompare(String(a.updatedAt)));
}

/** Extensions a browser cannot decode reliably (mirrors CloudImageTranscoder.transcodedExtensions). */
const TRANSCODED = new Set(["heic", "heif", "tif", "tiff", "bmp"]);
const TRANSCODE_DIR = path.join(tmpdir(), "capturecat-dev-images");
const inflight = new Map<string, Promise<string>>();

/** sips gets this long before the request fails over to the engine's fallback. */
const TRANSCODE_TIMEOUT_MS = 30_000;

/**
 * A browser-decodable PNG of `file`, cached by the SHA-256 of its bytes.
 *
 * sips never opens `file` itself: the Mac app's wallpapers live in its
 * sandbox container, and a separate binary opening a path in another app's
 * container blocks in open() on a macOS privacy prompt (2026-09-30: the
 * editor stage stayed blank behind a hung sips). Node reads the bytes (the
 * dev server already can), sips converts a private copy.
 */
async function transcodedCopy(file: string): Promise<string> {
  const bytes = await fs.readFile(file);
  const key = createHash("sha256").update(bytes).digest("hex").slice(0, 32);
  const out = path.join(TRANSCODE_DIR, `${key}.png`);
  if (await fs.stat(out).then((s) => s.size > 0, () => false)) return out;
  let job = inflight.get(key);
  if (!job) {
    job = (async () => {
      await fs.mkdir(TRANSCODE_DIR, { recursive: true });
      const stem = path.join(TRANSCODE_DIR, `.${key}.${process.pid}`);
      const src = `${stem}.src${path.extname(file).toLowerCase()}`;
      const tmp = `${stem}.tmp.png`;
      await fs.writeFile(src, bytes);
      try {
        await new Promise<void>((resolve, reject) =>
          execFile(
            "/usr/bin/sips",
            ["-s", "format", "png", src, "--out", tmp],
            { timeout: TRANSCODE_TIMEOUT_MS, killSignal: "SIGKILL" },
            (err) => (err ? reject(err) : resolve()),
          ),
        );
        await fs.rename(tmp, out); // atomic publish: never a torn cache hit
      } finally {
        await fs.rm(src, { force: true });
        await fs.rm(tmp, { force: true });
      }
      return out;
    })().finally(() => inflight.delete(key));
    inflight.set(key, job);
  }
  return job;
}

function send(res: ServerResponse, status: number, body: string, type = "application/json") {
  res.statusCode = status;
  res.setHeader("Content-Type", type);
  res.setHeader("Cache-Control", "no-store");
  res.end(body);
}

async function serveFile(req: IncomingMessage, res: ServerResponse, original: string) {
  let file = original;
  const stat0 = await fs.stat(file).catch(() => null);
  if (!stat0?.isFile()) return send(res, 404, JSON.stringify({ error: "not found" }));
  if (TRANSCODED.has(path.extname(file).slice(1).toLowerCase())) {
    try {
      file = await transcodedCopy(file);
    } catch (error) {
      return send(res, 415, JSON.stringify({ error: `could not transcode image: ${String(error)}` }));
    }
  }
  const stat = await fs.stat(file).catch(() => null);
  if (!stat?.isFile()) return send(res, 404, JSON.stringify({ error: "not found" }));
  const ext = path.extname(file).slice(1).toLowerCase();
  res.setHeader("Content-Type", CONTENT_TYPES[ext] ?? "application/octet-stream");
  res.setHeader("Accept-Ranges", "bytes");
  res.setHeader("Cache-Control", "no-store");
  const range = /^bytes=(\d*)-(\d*)$/.exec(req.headers.range ?? "");
  if (range && (range[1] || range[2])) {
    let start = range[1] ? Number(range[1]) : Math.max(0, stat.size - Number(range[2]));
    let end = range[1] && range[2] ? Number(range[2]) : stat.size - 1;
    end = Math.min(end, stat.size - 1);
    if (start > end || start >= stat.size) {
      res.statusCode = 416;
      res.setHeader("Content-Range", `bytes */${stat.size}`);
      return res.end();
    }
    start = Math.max(0, start);
    res.statusCode = 206;
    res.setHeader("Content-Range", `bytes ${start}-${end}/${stat.size}`);
    res.setHeader("Content-Length", String(end - start + 1));
    if (req.method === "HEAD") return res.end();
    return createReadStream(file, { start, end }).pipe(res);
  }
  res.statusCode = 200;
  res.setHeader("Content-Length", String(stat.size));
  if (req.method === "HEAD") return res.end();
  createReadStream(file).pipe(res);
}

export function localProjectsPlugin(): Plugin {
  return {
    name: "capturecat-local-projects",
    apply: "serve",
    configureServer(server) {
      server.middlewares.use(async (req, res, next) => {
        const url = new URL(req.url ?? "/", "http://localhost");
        if (!url.pathname.startsWith("/__dev/local-projects")) return next();
        if (req.method !== "GET" && req.method !== "HEAD") return send(res, 405, JSON.stringify({ error: "read-only" }));
        try {
          const parts = url.pathname.split("/").filter(Boolean); // __dev, local-projects, id?, leaf?
          if (parts.length === 2) return send(res, 200, JSON.stringify({ projects: await listProjects(), root: PROJECTS_ROOT }));
          const project = parts[2] ? await readProject(parts[2]) : null;
          if (!project) return send(res, 404, JSON.stringify({ error: "project not found" }));
          if (parts[3] === "project.json") return send(res, 200, project.text);
          if (parts[3] === "media") {
            const ref = url.searchParams.get("ref") ?? "";
            const file = refToPath(ref, project.dir);
            if (!file) return send(res, 400, JSON.stringify({ error: "bad ref" }));
            const resolved = path.resolve(file);
            const inFolder = resolved.startsWith(path.resolve(project.dir) + path.sep);
            if (!inFolder && !referencedPaths(project.doc, project.dir).has(resolved)) {
              return send(res, 403, JSON.stringify({ error: "not a file this project references" }));
            }
            return serveFile(req, res, resolved);
          }
          return send(res, 404, JSON.stringify({ error: "unknown route" }));
        } catch (error) {
          return send(res, 500, JSON.stringify({ error: String(error) }));
        }
      });
    },
  };
}
