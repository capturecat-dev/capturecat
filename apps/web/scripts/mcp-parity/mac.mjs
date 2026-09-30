/**
 * The REAL Mac MCP server (`CaptureCat --mcp`, JSON-RPC over stdio) plus the
 * sandbox plumbing the parity runner needs: throwaway copies of the synthetic
 * parity fixtures inside the app container's Projects folder (fresh id,
 * media copied, file:// URLs rewritten) and their cleanup.
 *
 * Never touches real user projects: every folder this module creates is a
 * fresh UUID, and `cleanup()` deletes exactly the folders it created.
 */
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";
import { pathToFileURL } from "node:url";

export const DEFAULT_BINARY =
  "/Users/mike/Library/Developer/Xcode/DerivedData/CaptureCat-disivhtfsylsyoccbprgxlcxjghz/" +
  "Build/Products/Debug/CaptureCat.app/Contents/MacOS/CaptureCat";

export const PROJECTS_ROOT = path.join(
  os.homedir(),
  "Library/Containers/so.capturecat.CaptureCat/Data/Library/Application Support/CaptureCat/Projects",
);

export class MacServer {
  constructor(binary = DEFAULT_BINARY) {
    if (!fs.existsSync(binary)) throw new Error(`Mac binary not found: ${binary}`);
    this.proc = spawn(binary, ["--mcp"], { stdio: ["pipe", "pipe", "pipe"] });
    this.pending = new Map();
    this.nextId = 0;
    this.closed = false;
    const rl = readline.createInterface({ input: this.proc.stdout });
    rl.on("line", (line) => {
      if (!line.trim()) return;
      let msg;
      try {
        msg = JSON.parse(line);
      } catch {
        this.fail(new Error(`non-JSON on the server's stdout: ${line.slice(0, 200)}`));
        return;
      }
      if (msg.id != null && this.pending.has(msg.id)) {
        this.pending.get(msg.id).resolve(msg);
        this.pending.delete(msg.id);
      }
    });
    this.proc.stderr.on("data", () => {});
    this.proc.on("exit", () => {
      this.closed = true;
      this.fail(new Error("Mac MCP server exited"));
    });
  }

  fail(error) {
    for (const { reject } of this.pending.values()) reject(error);
    this.pending.clear();
  }

  request(method, params, timeoutMs = 120_000) {
    if (this.closed) return Promise.reject(new Error("Mac MCP server is closed"));
    const id = ++this.nextId;
    this.proc.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`timeout waiting for ${method}`));
      }, timeoutMs);
      this.pending.set(id, {
        resolve: (msg) => {
          clearTimeout(timer);
          resolve(msg);
        },
        reject: (error) => {
          clearTimeout(timer);
          reject(error);
        },
      });
    });
  }

  async initialize() {
    const response = await this.request("initialize", {
      protocolVersion: "2025-06-18",
      capabilities: {},
      clientInfo: { name: "mcp-parity", version: "1" },
    });
    this.proc.stdin.write(JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }) + "\n");
    return response.result;
  }

  /** tools/call → { isError, text } (the first text content item). */
  async call(name, args) {
    const response = await this.request("tools/call", { name, arguments: args });
    if (response.error) return { isError: true, text: `RPC ${response.error.code}: ${response.error.message}` };
    const result = response.result ?? {};
    const text = result.content?.[0]?.text ?? "";
    return { isError: result.isError === true, text };
  }

  close() {
    if (this.closed) return;
    try {
      this.proc.stdin.end(); // EOF → the server exits cleanly
    } catch {
      /* already gone */
    }
  }
}

/**
 * Throwaway sandbox copies of parity fixtures. Each `create()` makes
 * Projects/<NEW-UUID>/ with project.json (fresh id, media URLs rewritten to
 * the copies) — the Mac server edits it in place.
 */
export class Sandbox {
  constructor(fixturesRoot) {
    this.fixturesRoot = fixturesRoot;
    this.created = [];
  }

  /**
   * @param fixture   fixture folder name under .fixtures/parity
   * @param mutate    optional (projectJSON, dir) => void to derive a variant
   * @param extraFiles optional { name: Buffer|string } written into the folder
   * @returns { id, dir, projectPath, json }
   */
  create(fixture, mutate, extraFiles = {}) {
    const source = path.join(this.fixturesRoot, fixture);
    const json = JSON.parse(fs.readFileSync(path.join(source, "project.json"), "utf8"));
    const id = randomUUID().toUpperCase();
    const dir = path.join(PROJECTS_ROOT, id);
    if (fs.existsSync(dir)) throw new Error(`refusing to reuse existing folder ${dir}`);
    fs.mkdirSync(dir, { recursive: false });
    this.created.push(dir);
    const media = ["recording.mp4", "cursor.json", "camera.mp4"];
    for (const name of media) {
      const from = path.join(source, name);
      if (fs.existsSync(from)) fs.copyFileSync(from, path.join(dir, name));
    }
    for (const [name, content] of Object.entries(extraFiles)) {
      fs.writeFileSync(path.join(dir, name), content);
    }
    const url = (name) => pathToFileURL(path.join(dir, name)).href;
    json.id = id;
    if (json.videoURL) json.videoURL = url("recording.mp4");
    if (json.cursorDataURL) json.cursorDataURL = url("cursor.json");
    if (json.cameraVideoURL) json.cameraVideoURL = url("camera.mp4");
    if (mutate) mutate(json, dir, url);
    const projectPath = path.join(dir, "project.json");
    fs.writeFileSync(projectPath, JSON.stringify(json, null, 2));
    return { id, dir, projectPath, json };
  }

  cleanup() {
    for (const dir of this.created.splice(0)) {
      // Only ever a folder this sandbox created (fresh UUID under the root).
      if (path.dirname(dir) !== PROJECTS_ROOT) continue;
      fs.rmSync(dir, { recursive: true, force: true });
    }
  }
}
