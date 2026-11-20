/**
 * LOCAL TEST API — the real Worker entrypoint (src/index.ts: every route, the
 * remote MCP server at /mcp, the editor's op layer, the version rules) served
 * over HTTP on 127.0.0.1, with the doubles the API's own tests use:
 *
 *   D1    in-memory node:sqlite with the repo's real migrations
 *   R2    in-memory MemoryBucket (presigned URLs come back here: /__r2/…)
 *   auth  fake-session — `Authorization: Bearer <uid>` is that user's session
 *   APNs  a throwaway key; pushes are captured (GET /__pushes), never sent
 *
 * Nothing reaches Cloudflare, Apple or production data: any other outbound
 * fetch fails. For device gates (apps/ios/scripts/ios-agent-edit.sh).
 *
 *   npx vite-node --config scripts/local-test-api/vite.config.ts \
 *       scripts/local-test-api/server.ts -- --port 8790 --media <dir>
 *
 * Users: "owner" (tester → Pro: agentEditing) and "free" (Free plan, with
 *        agentEditing switched off here — an owner's admin setting).
 * Seed:  POST /__seed { projectId, name } → { projectId, agentToken, revision }
 *        a cloud project (stage → upload → finalize → first save, through
 *        the session routes) from <media>/recording.mov (+ thumbnail.jpg),
 *        an OAuth-connected "Claude" whose access token is `agentToken`, a
 *        personal token "Claude Code on my Mac", and an iOS device row with
 *        an APNs token (so agent-edit pushes are produced).
 * State: GET /__pushes → { pushes: [{ url, headers, payload }] }
 *        GET /__versions/:projectId → the History rows (kind, source, revision, restored_from)
 */

import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { createHash } from "node:crypto";
import type { Env } from "../../src/types";
import { createTestD1 } from "../../src/test-support/d1-sqlite.js";
import { MemoryBucket } from "../../src/test-support/memory-bucket";
import { createAgentToken, AGENT_SCOPES } from "../../src/lib/agent-tokens";
import { registerClient } from "../../src/lib/oauth/clients";
import { mcpResource } from "../../src/lib/oauth/config";
import { exchangeAuthorizationCode, issueAuthorizationCode, pkceChallengeS256 } from "../../src/lib/oauth/tokens";
import { objectKey } from "../../src/lib/cloud-projects";
import { newProject, serializeProjectText } from "../../../web/src/editor/core/model";

const args = process.argv.slice(2);
const arg = (name: string, fallback: string) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : fallback;
};
const PORT = Number(arg("port", "8790"));
const MEDIA = arg("media", "");
const ORIGIN = `http://127.0.0.1:${PORT}`;
process.env.LOCAL_TEST_API_ORIGIN = ORIGIN;

// ---------------------------------------------------------------------------
// Outbound: APNs captured, everything else refused.
// ---------------------------------------------------------------------------

const pushes: { url: string; headers: Record<string, string>; payload: unknown; at: string }[] = [];
const realFetch = globalThis.fetch;
globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
  const url = String(input instanceof Request ? input.url : input);
  if (/^https:\/\/api(\.sandbox)?\.push\.apple\.com\//.test(url)) {
    pushes.push({
      url,
      headers: (init?.headers ?? {}) as Record<string, string>,
      payload: JSON.parse(String(init?.body ?? "null")),
      at: new Date().toISOString(),
    });
    console.log(`[local-test-api] APNs push captured → ${url.split("/").pop()?.slice(0, 8)}…`);
    return new Response(null, { status: 200, headers: { "apns-id": `local-${pushes.length}` } });
  }
  if (url.startsWith(ORIGIN)) return realFetch(input, init);
  throw new Error(`local test API: outbound fetch refused (${url})`);
}) as typeof fetch;
(globalThis as { caches?: unknown }).caches = {
  default: { match: async () => undefined, put: async () => undefined, delete: async () => true },
};

// ---------------------------------------------------------------------------
// The Worker and its environment
// ---------------------------------------------------------------------------

const { default: worker } = await import("../../src/index");
const db = createTestD1();
const bucket = new MemoryBucket();

async function throwawayApnsKey(): Promise<string> {
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const pkcs8 = Buffer.from((await crypto.subtle.exportKey("pkcs8", pair.privateKey)) as ArrayBuffer).toString("base64");
  return `-----BEGIN PRIVATE KEY-----\n${pkcs8}\n-----END PRIVATE KEY-----\n`;
}

const env = {
  DB: db,
  R2: bucket,
  BETTER_AUTH_URL: ORIGIN,
  BETTER_AUTH_SECRET: "local-test-secret-local-test-secret-0",
  R2_ENDPOINT: "https://account.r2.invalid",
  R2_ACCESS_KEY_ID: "local",
  R2_SECRET_ACCESS_KEY: "local",
  APNS_KEY: await throwawayApnsKey(),
  APNS_KEY_ID: "LOCALKEY01",
  APNS_TEAM_ID: "LOCALTEAM1",
  AGENT_EDIT_PUSH_DELAY_MS: arg("push-delay-ms", "1500"),
} as unknown as Env;

const pending = new Set<Promise<unknown>>();
const ctx = {
  waitUntil(p: Promise<unknown>) {
    pending.add(p);
    p.finally(() => pending.delete(p)).catch(() => {});
  },
  passThroughOnException() {},
} as unknown as ExecutionContext;

const now = () => new Date().toISOString();
// Plan gates are the owner's per-plan switches (admin console; migration 0034
// turned every flag on). Here the Free plan has AI editing switched OFF so a
// gate can see the upgrade path; Pro (testers) keeps it.
db.query(`UPDATE plan SET features = json_set(features, '$.agentEditing', json('false')) WHERE name = 'free' AND json_valid(features)`);
for (const [id, name, tester] of [["owner", "Olive Owner", 1], ["free", "Fran Free", 0]] as const) {
  db.query(
    `INSERT INTO "user" (id, name, email, emailVerified, createdAt, updatedAt, tester, blocked) VALUES (?, ?, ?, 1, ?, ?, ?, 0)`,
    id, name, `${id}@local.test`, now(), now(), tester,
  );
}

// ---------------------------------------------------------------------------
// Seed
// ---------------------------------------------------------------------------

const sha256 = (bytes: Uint8Array) => createHash("sha256").update(bytes).digest("hex");

function session(uid: string, method: string, path: string, body?: string | object, headers: Record<string, string> = {}) {
  const h: Record<string, string> = { Authorization: `Bearer ${uid}`, ...headers };
  let payload: string | undefined;
  if (typeof body === "string") payload = body;
  else if (body !== undefined) {
    payload = JSON.stringify(body);
    h["Content-Type"] = "application/json";
  }
  return worker.fetch(new Request(`${ORIGIN}/api${path}`, { method, headers: h, body: payload }), env, ctx);
}

async function seed(projectId: string, name: string, duration: number) {
  const uid = "owner";
  const files: { path: string; contentType: string; bytes: Uint8Array }[] = [];
  const movie = join(MEDIA, "recording.mov");
  if (!existsSync(movie)) throw new Error(`no ${movie} (pass --media <dir>)`);
  files.push({ path: "recording.mov", contentType: "video/quicktime", bytes: new Uint8Array(readFileSync(movie)) });
  const thumb = join(MEDIA, "thumbnail.jpg");
  if (existsSync(thumb)) files.push({ path: "thumbnail.jpg", contentType: "image/jpeg", bytes: new Uint8Array(readFileSync(thumb)) });

  const manifest = { name, files: files.map((f) => ({ path: f.path, sha256: sha256(f.bytes), bytes: f.bytes.byteLength, contentType: f.contentType })) };
  const stage = await session(uid, "PUT", `/cloud-projects/${projectId}`, manifest);
  if (stage.status !== 200) throw new Error(`stage ${stage.status}: ${await stage.text()}`);
  for (const f of files) await bucket.put(objectKey(uid, projectId, sha256(f.bytes)), f.bytes, { httpMetadata: { contentType: f.contentType } });
  const fin = await session(uid, "POST", `/cloud-projects/${projectId}/finalize`);
  if (fin.status !== 200) throw new Error(`finalize ${fin.status}: ${await fin.text()}`);
  const dir = `file:///Users/test/Library/Application%20Support/CaptureCat/Projects/${projectId}`;
  const doc = serializeProjectText(newProject({ id: projectId, name, duration, createdAt: 785_000_000, videoURL: `${dir}/recording.mov` }));
  const saved = await session(uid, "PUT", `/cloud-projects/${projectId}/project`, doc, { "If-Match": '"0"', "X-CC-Client": "mac" });
  if (saved.status !== 200) throw new Error(`save ${saved.status}: ${await saved.text()}`);

  // "Claude" connected the way the connector does: dynamic client
  // registration, then "Sign in with CaptureCat" (code + PKCE → tokens).
  // The access token (cc_oat_…) is what the gate's agent calls /mcp with.
  const registered = await registerClient(db, { client_name: "Claude", redirect_uris: ["https://claude.ai/api/mcp/auth_callback"] });
  if (!registered.ok) throw new Error(`register: ${registered.description}`);
  const verifier = "local-test-verifier-".padEnd(64, "x");
  const code = await issueAuthorizationCode(db, {
    clientId: registered.client.clientId, uid, redirectUri: "https://claude.ai/api/mcp/auth_callback",
    codeChallenge: await pkceChallengeS256(verifier), scopes: [...AGENT_SCOPES], resource: mcpResource(env),
  });
  const tokens = await exchangeAuthorizationCode(env, registered.client, {
    code, redirectUri: "https://claude.ai/api/mcp/auth_callback", codeVerifier: verifier, resource: mcpResource(env),
  });
  if (!tokens.ok) throw new Error(`token: ${tokens.description}`);
  const oauth = { token: tokens.access_token };
  const personal = await createAgentToken(db, { uid, name: "Claude Code on my Mac", scopes: ["projects:read", "projects:write"], expiresInDays: null });

  db.query(
    `INSERT OR REPLACE INTO user_devices (user_id, device_id, platform, name, apns_token, apns_env, created_at, updated_at, last_seen_at)
     VALUES (?, '6f1c2c3e-8d4b-4c47-9f0e-2a7b9d1e5c11', 'ios', 'iPhone', ?, 'sandbox', ?, ?, ?)`,
    uid, "ab".repeat(32), now(), now(), now(),
  );
  const head = (await saved.json()) as { revision: number };
  return { projectId, agentToken: oauth.token, personalTokenId: personal.summary.id, revision: head.revision };
}

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------

async function readBody(req: IncomingMessage): Promise<Buffer> {
  const chunks: Buffer[] = [];
  for await (const chunk of req) chunks.push(chunk as Buffer);
  return Buffer.concat(chunks);
}

function json(res: ServerResponse, status: number, body: unknown) {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify(body));
}

async function handle(req: IncomingMessage, res: ServerResponse) {
  const url = new URL(req.url ?? "/", ORIGIN);
  const body = req.method === "GET" || req.method === "HEAD" ? undefined : await readBody(req);

  if (url.pathname.startsWith("/__r2/")) {
    const key = decodeURIComponent(url.pathname.slice("/__r2/".length));
    if (req.method === "PUT") {
      await bucket.put(key, new Uint8Array(body ?? Buffer.alloc(0)), { httpMetadata: { contentType: req.headers["content-type"] } });
      res.writeHead(200, { ETag: `"${sha256(new Uint8Array(body ?? Buffer.alloc(0)))}"` });
      return res.end();
    }
    const object = bucket.objects.get(key);
    if (!object) return json(res, 404, { error: "NoSuchKey" });
    const range = /^bytes=(\d+)-(\d*)$/.exec(String(req.headers.range ?? ""));
    if (range) {
      const start = Number(range[1]);
      const end = range[2] ? Math.min(Number(range[2]), object.bytes.byteLength - 1) : object.bytes.byteLength - 1;
      res.writeHead(206, {
        "Content-Type": object.contentType ?? "application/octet-stream",
        "Content-Range": `bytes ${start}-${end}/${object.bytes.byteLength}`,
        "Content-Length": end - start + 1,
        "Accept-Ranges": "bytes",
      });
      return res.end(Buffer.from(object.bytes.subarray(start, end + 1)));
    }
    res.writeHead(200, { "Content-Type": object.contentType ?? "application/octet-stream", "Content-Length": object.bytes.byteLength, "Accept-Ranges": "bytes" });
    return res.end(req.method === "HEAD" ? undefined : Buffer.from(object.bytes));
  }
  if (url.pathname === "/__health") return json(res, 200, { ok: true });
  if (url.pathname === "/__seed" && req.method === "POST") {
    const input = JSON.parse(String(body ?? "{}")) as { projectId?: string; name?: string; duration?: number };
    try {
      return json(res, 200, await seed((input.projectId ?? crypto.randomUUID()).toUpperCase(), input.name ?? "Agent demo", input.duration ?? 4));
    } catch (err) {
      return json(res, 500, { error: err instanceof Error ? err.message : String(err) });
    }
  }
  if (url.pathname === "/__pushes") {
    await Promise.allSettled([...pending]);
    return json(res, 200, { pushes });
  }
  if (url.pathname.startsWith("/__versions/")) {
    const id = url.pathname.slice("/__versions/".length).toUpperCase();
    return json(res, 200, {
      versions: db.query(`SELECT id, seq, kind, source, revision, first_revision, restored_from, client_kind FROM cloud_project_versions WHERE project_id = ? ORDER BY seq`, id),
      revision: db.query<{ revision: number }>(`SELECT revision FROM cloud_projects WHERE id = ?`, id)[0]?.revision ?? null,
    });
  }

  const headers = new Headers();
  for (const [name, value] of Object.entries(req.headers)) {
    if (value === undefined) continue;
    headers.set(name, Array.isArray(value) ? value.join(", ") : value);
  }
  headers.set("CF-Connecting-IP", "127.0.0.1");
  const request = new Request(url.toString(), { method: req.method, headers, body: body && body.byteLength ? body : undefined });
  const response = await worker.fetch(request, env, ctx);
  const out: Record<string, string> = {};
  response.headers.forEach((value, name) => { out[name] = value; });
  res.writeHead(response.status, out);
  res.end(Buffer.from(await response.arrayBuffer()));
}

createServer((req, res) => {
  handle(req, res).catch((err) => {
    console.error("[local-test-api]", err);
    if (!res.headersSent) json(res, 500, { error: String(err) });
    else res.end();
  });
}).listen(PORT, "127.0.0.1", () => console.log(`[local-test-api] listening on ${ORIGIN}`));
