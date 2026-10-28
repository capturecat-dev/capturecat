/**
 * "Sign in with CaptureCat" — OAuth 2.1 for the MCP server — end to end
 * through the REAL Worker entry (index.ts: host isolation, CORS, mounting),
 * the real migrations (node:sqlite) and the real session middleware
 * (fake-session: `Authorization: Bearer <uid>` is that user's session, the
 * way the web consent page's server calls the API with the user's cookie).
 *
 * The Worker runs as production here (BETTER_AUTH_URL = api.capturecat.so),
 * so the issuer, resource and consent URLs are the real ones. `fetch` is
 * stubbed: only Client ID Metadata Documents reach it.
 */

import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Env } from "../types";
import { createTestD1, type TestD1 } from "../test-support/d1-sqlite.js";
import { MemoryBucket } from "../test-support/memory-bucket";
import { pkceChallengeS256 } from "../lib/oauth/tokens";
import { checkClientIdUrl, redirectUriAllowed } from "../lib/oauth/clients";

vi.mock("cloudflare:workers", () => ({ DurableObject: class {} }));
vi.mock("../lib/auth", () => import("../test-support/fake-session"));
vi.stubGlobal("caches", { default: { match: async () => undefined, put: async () => undefined, delete: async () => true } });
const fetchMock = vi.fn(async (..._args: unknown[]): Promise<Response> => {
  throw new Error("offline test: unexpected fetch");
});
vi.stubGlobal("fetch", fetchMock);

const { default: worker } = await import("../index");

const API = "https://api.capturecat.so";
const MCP = "https://mcp.capturecat.so";
const RESOURCE = "https://mcp.capturecat.so/mcp";
const REDIRECT = "https://claude.ai/api/mcp/auth_callback";
const OWNER = "owner"; // tester → pro
const ctx = { waitUntil() {}, passThroughOnException() {} } as unknown as ExecutionContext;

let db: TestD1;
let env: Env;
let seq = 0;

beforeEach(() => {
  seq = 0;
  fetchMock.mockReset();
  fetchMock.mockImplementation(async () => {
    throw new Error("offline test: unexpected fetch");
  });
  db = createTestD1();
  env = {
    DB: db,
    R2: new MemoryBucket(),
    BETTER_AUTH_URL: API,
    BETTER_AUTH_SECRET: "test-secret-test-secret-test-secret-00",
  } as unknown as Env;
  const now = new Date().toISOString();
  db.query(
    `INSERT INTO "user" (id, name, email, emailVerified, createdAt, updatedAt, tester, blocked) VALUES (?, 'Olive', 'o@test.local', 1, ?, ?, 1, 0)`,
    OWNER, now, now,
  );
  db.query(
    `INSERT INTO shared_videos (video_id, uid, file_name, r2_key, url, status, created_at, duration_seconds, file_size_bytes)
     VALUES ('vid1', ?, 'demo.mp4', 'k', 'u', 'ready', ?, 60, 10)`,
    OWNER, now,
  );
});

function req(method: string, url: string, init: { bearer?: string; json?: unknown; form?: Record<string, string>; headers?: Record<string, string> } = {}) {
  const headers: Record<string, string> = { ...init.headers };
  if (init.bearer) headers.Authorization = `Bearer ${init.bearer}`;
  let body: string | undefined;
  if (init.json !== undefined) {
    headers["Content-Type"] = "application/json";
    body = JSON.stringify(init.json);
  } else if (init.form) {
    headers["Content-Type"] = "application/x-www-form-urlencoded";
    body = new URLSearchParams(init.form).toString();
  }
  return worker.fetch(new Request(url, { method, headers, body, redirect: "manual" }), env, ctx);
}

const VERIFIER = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk-and-some-more";

async function register(redirectUris: string[] = [REDIRECT], extra: Record<string, unknown> = {}) {
  const res = await req("POST", `${API}/oauth/register`, { json: { client_name: "Claude", redirect_uris: redirectUris, ...extra } });
  expect(res.status, await res.clone().text()).toBe(201);
  return (await res.json()) as { client_id: string; client_secret?: string; token_endpoint_auth_method: string };
}

async function authorizeParams(clientId: string, over: Record<string, string> = {}) {
  return {
    response_type: "code",
    client_id: clientId,
    redirect_uri: REDIRECT,
    scope: "videos:read comments:read comments:write",
    state: "st4te",
    code_challenge: await pkceChallengeS256(VERIFIER),
    code_challenge_method: "S256",
    resource: RESOURCE,
    ...over,
  };
}

/** GET /oauth/authorize → the consent page → Allow → the code. */
async function consentAndCode(clientId: string, opts: { scopes?: string[]; params?: Record<string, string> } = {}) {
  const params = await authorizeParams(clientId, opts.params);
  const start = await req("GET", `${API}/oauth/authorize?${new URLSearchParams(params)}`);
  expect(start.status).toBe(302);
  const consent = new URL(start.headers.get("Location")!);
  expect(consent.origin + consent.pathname).toBe("https://app.capturecat.so/oauth/authorize");
  const forwarded = Object.fromEntries(consent.searchParams);
  const decided = await req("POST", `${API}/api/oauth/authorize/decision`, {
    bearer: OWNER,
    json: { params: forwarded, approve: true, ...(opts.scopes ? { scopes: opts.scopes } : {}) },
  });
  expect(decided.status, await decided.clone().text()).toBe(200);
  const back = new URL(((await decided.json()) as { redirect: string }).redirect);
  expect(back.origin + back.pathname).toBe(REDIRECT);
  expect(back.searchParams.get("state")).toBe("st4te");
  expect(back.searchParams.get("iss")).toBe(API);
  return back.searchParams.get("code")!;
}

async function token(form: Record<string, string>) {
  const res = await req("POST", `${API}/oauth/token`, { form });
  return { status: res.status, headers: res.headers, body: (await res.json()) as Record<string, string | number> };
}

const exchange = (clientId: string, code: string, over: Record<string, string> = {}) =>
  token({ grant_type: "authorization_code", client_id: clientId, code, redirect_uri: REDIRECT, code_verifier: VERIFIER, resource: RESOURCE, ...over });

const refresh = (clientId: string, refreshToken: string, over: Record<string, string> = {}) =>
  token({ grant_type: "refresh_token", client_id: clientId, refresh_token: refreshToken, ...over });

async function mcpCall(bearer: string, method: string, params?: unknown, host = MCP) {
  return req("POST", `${host}/mcp`, { bearer, json: { jsonrpc: "2.0", id: ++seq, method, ...(params ? { params } : {}) } });
}

// ---------------------------------------------------------------------------

describe("discovery", () => {
  it("the MCP host serves RFC 9728 protected-resource metadata at both paths, pointing at api.capturecat.so", async () => {
    for (const path of ["/.well-known/oauth-protected-resource", "/.well-known/oauth-protected-resource/mcp"]) {
      const res = await req("GET", `${MCP}${path}`, { headers: { Origin: "https://claude.ai" } });
      expect(res.status, path).toBe(200);
      expect(res.headers.get("Access-Control-Allow-Origin")).toBe("*");
      expect(await res.json()).toMatchObject({
        resource: RESOURCE,
        authorization_servers: [API],
        bearer_methods_supported: ["header"],
        scopes_supported: expect.arrayContaining(["videos:read", "comments:write", "webhooks:write"]),
      });
    }
    // The AS lives on the API host: its metadata path redirects there, and
    // nothing else of the AS exists on the MCP host.
    const as = await req("GET", `${MCP}/.well-known/oauth-authorization-server`);
    expect(as.status).toBe(307);
    expect(as.headers.get("Location")).toBe(`${API}/.well-known/oauth-authorization-server`);
    for (const path of ["/oauth/token", "/oauth/authorize", "/api/oauth/apps"]) {
      expect((await req("GET", `${MCP}${path}`)).status, path).toBe(404);
    }
  });

  it("the API host serves RFC 8414 authorization-server metadata", async () => {
    const res = await req("GET", `${API}/.well-known/oauth-authorization-server`);
    expect(res.status).toBe(200);
    expect(await res.json()).toMatchObject({
      issuer: API,
      authorization_endpoint: `${API}/oauth/authorize`,
      token_endpoint: `${API}/oauth/token`,
      registration_endpoint: `${API}/oauth/register`,
      code_challenge_methods_supported: ["S256"],
      client_id_metadata_document_supported: true,
      response_types_supported: ["code"],
      grant_types_supported: ["authorization_code", "refresh_token"],
      scopes_supported: expect.arrayContaining(["account:read", "webhooks:write"]),
      // Poppy's issuer binding for capturecat.so/.well-known/poppy.json.
      protected_resources: [RESOURCE, "https://capturecat.so"],
      poppy_domains: ["capturecat.so"],
    });
  });

  it("/mcp's 401 names the protected-resource metadata", async () => {
    const res = await req("POST", `${MCP}/mcp`, { json: { jsonrpc: "2.0", id: 1, method: "ping" } });
    expect(res.status).toBe(401);
    expect(res.headers.get("WWW-Authenticate")).toBe(
      `Bearer realm="capturecat", resource_metadata="${MCP}/.well-known/oauth-protected-resource"`,
    );
  });
});

describe("authorization code + PKCE", () => {
  it("runs the whole flow: register, consent, code, tokens, then /mcp with the OAuth token", async () => {
    const client = await register();
    expect(client.client_id).toMatch(/^cc_dcr_/);
    expect(client.token_endpoint_auth_method).toBe("none");
    const code = await consentAndCode(client.client_id);
    expect(code).toMatch(/^cc_oac_[A-Za-z0-9]{40}$/);
    const t = await exchange(client.client_id, code);
    expect(t.status, JSON.stringify(t.body)).toBe(200);
    expect(t.headers.get("Cache-Control")).toBe("no-store");
    expect(t.body).toMatchObject({ token_type: "Bearer", expires_in: 3600, scope: "videos:read comments:read comments:write" });
    expect(t.body.access_token).toMatch(/^cc_oat_[A-Za-z0-9]{40}$/);
    expect(t.body.refresh_token).toMatch(/^cc_ort_[A-Za-z0-9]{40}$/);

    // Only hashes are stored; the access token is an agent_tokens row for this client.
    const [row] = db.query<{ name: string; oauth_client_id: string; resource: string; token_hash: string; expires_at: string }>(
      "SELECT name, oauth_client_id, resource, token_hash, expires_at FROM agent_tokens",
    );
    expect(row).toMatchObject({ name: "Claude", oauth_client_id: client.client_id, resource: RESOURCE });
    expect(row.token_hash).not.toContain("cc_oat_");
    expect(JSON.stringify(db.query("SELECT * FROM oauth_refresh_tokens"))).not.toContain(String(t.body.refresh_token));

    const access = String(t.body.access_token);
    const list = await mcpCall(access, "tools/list");
    expect(list.status).toBe(200);
    const call = await mcpCall(access, "tools/call", { name: "list_videos", arguments: {} });
    const result = ((await call.json()) as { result: { structuredContent: { total: number } } }).result;
    expect(result.structuredContent.total).toBe(1);
    // The api-host alias accepts it too (same resource).
    expect((await mcpCall(access, "ping", undefined, API)).status).toBe(200);
    expect(db.query("SELECT tool, ok FROM agent_audit_log")).toEqual([{ tool: "list_videos", ok: 1 }]);

    // A scope the user did not grant: 403 insufficient_scope with a step-up hint.
    const denied = await mcpCall(access, "tools/call", { name: "get_account", arguments: {} });
    expect(denied.status).toBe(403);
    expect(denied.headers.get("WWW-Authenticate")).toBe(
      `Bearer realm="capturecat", error="insufficient_scope", scope="videos:read comments:read comments:write account:read", resource_metadata="${MCP}/.well-known/oauth-protected-resource"`,
    );
    expect(await denied.json()).toMatchObject({ error: "insufficient_scope" });
  });

  it("the consent page can only NARROW the requested scopes", async () => {
    const client = await register();
    const code = await consentAndCode(client.client_id, { scopes: ["videos:read", "account:read", "screenshots"] });
    const t = await exchange(client.client_id, code);
    expect(t.body.scope).toBe("videos:read");
  });

  it("refuses an unregistered redirect URI without redirecting to it", async () => {
    const client = await register();
    const params = await authorizeParams(client.client_id, { redirect_uri: "https://evil.test/cb" });
    const res = await req("GET", `${API}/oauth/authorize?${new URLSearchParams(params)}`);
    expect(res.status).toBe(400);
    expect(res.headers.get("Location")).toBeNull();
    expect(await res.text()).toContain("redirect_uri is not one this client registered");
    // A prefix of a registered URI is not a match either.
    const prefix = await req("GET", `${API}/oauth/authorize?${new URLSearchParams({ ...params, redirect_uri: `${REDIRECT}/x` })}`);
    expect(prefix.status).toBe(400);
    // And the consent API refuses it outright.
    const decided = await req("POST", `${API}/api/oauth/authorize/decision`, { bearer: OWNER, json: { params, approve: true } });
    expect(decided.status).toBe(400);
    expect(await decided.json()).toMatchObject({ redirect: null });
  });

  it("refuses a code exchanged with another redirect_uri, client or resource", async () => {
    const client = await register([REDIRECT, "https://claude.ai/other"]);
    const other = await register();
    const code = await consentAndCode(client.client_id);
    expect((await exchange(client.client_id, code, { redirect_uri: "https://claude.ai/other" })).body.error).toBe("invalid_grant");
    const code2 = await consentAndCode(client.client_id);
    expect((await exchange(other.client_id, code2)).body.error).toBe("invalid_grant");
    const code3 = await consentAndCode(client.client_id);
    expect((await exchange(client.client_id, code3, { resource: "https://evil.test/mcp" })).body.error).toBe("invalid_target");
  });

  it("refuses a wrong PKCE verifier, and PKCE is not optional", async () => {
    const client = await register();
    const code = await consentAndCode(client.client_id);
    const wrong = await exchange(client.client_id, code, { code_verifier: "x".repeat(43) });
    expect(wrong.status).toBe(400);
    expect(wrong.body).toMatchObject({ error: "invalid_grant", error_description: expect.stringContaining("PKCE") });
    const missing = await exchange(client.client_id, code, { code_verifier: "" });
    expect(missing.body.error).toBe("invalid_request");

    // No challenge, or a plain one: the error goes back to the (verified) redirect URI.
    for (const over of [{ code_challenge: "" }, { code_challenge_method: "plain" }] as Array<Record<string, string>>) {
      const params = await authorizeParams(client.client_id, over);
      const res = await req("GET", `${API}/oauth/authorize?${new URLSearchParams(params)}`);
      expect(res.status).toBe(302);
      const back = new URL(res.headers.get("Location")!);
      expect(back.origin + back.pathname).toBe(REDIRECT);
      expect(back.searchParams.get("error")).toBe("invalid_request");
      expect(back.searchParams.get("state")).toBe("st4te");
    }
    // Another resource: invalid_target.
    const params = await authorizeParams(client.client_id, { resource: "https://api.capturecat.so/api" });
    const res = await req("GET", `${API}/oauth/authorize?${new URLSearchParams(params)}`);
    expect(new URL(res.headers.get("Location")!).searchParams.get("error")).toBe("invalid_target");
  });

  it("a code works once; replaying it revokes what the first exchange issued", async () => {
    const client = await register();
    const code = await consentAndCode(client.client_id);
    const first = await exchange(client.client_id, code);
    expect(first.status).toBe(200);
    expect((await mcpCall(String(first.body.access_token), "ping")).status).toBe(200);
    const replay = await exchange(client.client_id, code);
    expect(replay.body).toMatchObject({ error: "invalid_grant", error_description: expect.stringContaining("already used") });
    expect((await mcpCall(String(first.body.access_token), "ping")).status).toBe(401);
    expect((await refresh(client.client_id, String(first.body.refresh_token))).body.error).toBe("invalid_grant");
  });

  it("codes expire after 10 minutes", async () => {
    const client = await register();
    const code = await consentAndCode(client.client_id);
    db.query("UPDATE oauth_codes SET expires_at = ?", new Date(Date.now() - 1000).toISOString());
    expect((await exchange(client.client_id, code)).body).toMatchObject({ error: "invalid_grant", error_description: expect.stringContaining("expired") });
  });

  it("Deny sends access_denied back to the client", async () => {
    const client = await register();
    const params = await authorizeParams(client.client_id);
    const decided = await req("POST", `${API}/api/oauth/authorize/decision`, { bearer: OWNER, json: { params, approve: false } });
    const back = new URL(((await decided.json()) as { redirect: string }).redirect);
    expect(back.searchParams.get("error")).toBe("access_denied");
    expect(back.searchParams.get("code")).toBeNull();
    expect(db.query("SELECT id FROM oauth_codes")).toHaveLength(0);
  });

  it("the consent API is session-only: an agent token can't grant itself anything", async () => {
    const client = await register();
    const code = await consentAndCode(client.client_id);
    const access = String((await exchange(client.client_id, code)).body.access_token);
    const params = await authorizeParams(client.client_id);
    for (const bearer of [access, `cc_pat_${"B".repeat(40)}`]) {
      const res = await req("POST", `${API}/api/oauth/authorize/decision`, { bearer, json: { params, approve: true } });
      expect(res.status).toBe(403);
      expect((await req("GET", `${API}/api/oauth/apps`, { bearer })).status).toBe(403);
    }
  });

  it("a plan without agentAccess can't consent, and gets no new tokens", async () => {
    const client = await register();
    const code = await consentAndCode(client.client_id);
    db.query(`UPDATE plan SET features = json_set(features, '$.agentAccess', json('false')) WHERE name = 'pro'`);
    expect((await exchange(client.client_id, code)).body).toMatchObject({ error: "invalid_grant", error_description: expect.stringContaining("isn't included") });
    const params = await authorizeParams(client.client_id);
    const info = await req("GET", `${API}/api/oauth/authorize/info?${new URLSearchParams(params)}`, { bearer: OWNER });
    expect(await info.json()).toMatchObject({ available: false, unavailableReason: expect.stringContaining("isn't included") });
    const decided = await req("POST", `${API}/api/oauth/authorize/decision`, { bearer: OWNER, json: { params, approve: true } });
    expect(decided.status).toBe(403);
  });
});

describe("refresh tokens", () => {
  it("rotate on every use; reusing an old one revokes the whole family", async () => {
    const client = await register();
    const t0 = await exchange(client.client_id, await consentAndCode(client.client_id));
    const t1 = await refresh(client.client_id, String(t0.body.refresh_token));
    expect(t1.status).toBe(200);
    expect(t1.body.refresh_token).not.toBe(t0.body.refresh_token);
    expect(t1.body.access_token).not.toBe(t0.body.access_token);
    // Narrowing on refresh is allowed; widening is not.
    expect((await refresh(client.client_id, String(t1.body.refresh_token), { scope: "videos:read account:read" })).body.error).toBe("invalid_scope");
    const t2 = await refresh(client.client_id, String(t1.body.refresh_token), { scope: "videos:read" });
    expect(t2.body.scope).toBe("videos:read");
    expect((await mcpCall(String(t2.body.access_token), "ping")).status).toBe(200);

    // t0's refresh token again: reuse → every token of this grant dies.
    const reuse = await refresh(client.client_id, String(t0.body.refresh_token));
    expect(reuse.body).toMatchObject({ error: "invalid_grant", error_description: expect.stringContaining("already used") });
    expect((await refresh(client.client_id, String(t2.body.refresh_token))).body.error).toBe("invalid_grant");
    for (const access of [t0, t1, t2].map((t) => String(t.body.access_token))) {
      expect((await mcpCall(access, "ping")).status).toBe(401);
    }
    expect(db.query<{ revoked_reason: string }>("SELECT revoked_reason FROM oauth_grants")).toEqual([{ revoked_reason: "refresh_reuse" }]);
  });

  it("are bound to their client, and expire", async () => {
    const client = await register();
    const other = await register();
    const t0 = await exchange(client.client_id, await consentAndCode(client.client_id));
    expect((await refresh(other.client_id, String(t0.body.refresh_token))).body.error).toBe("invalid_grant");
    db.query("UPDATE oauth_refresh_tokens SET expires_at = ?", new Date(Date.now() - 1000).toISOString());
    expect((await refresh(client.client_id, String(t0.body.refresh_token))).body).toMatchObject({ error: "invalid_grant", error_description: expect.stringContaining("expired") });
  });

  it("access tokens expire after an hour and are bound to the MCP resource", async () => {
    const client = await register();
    const t = await exchange(client.client_id, await consentAndCode(client.client_id));
    const access = String(t.body.access_token);
    db.query("UPDATE agent_tokens SET resource = 'https://other.test/mcp'");
    expect((await mcpCall(access, "ping")).status).toBe(401);
    db.query("UPDATE agent_tokens SET resource = ?, expires_at = ?", RESOURCE, new Date(Date.now() - 1000).toISOString());
    expect((await mcpCall(access, "ping")).status).toBe(401);
  });
});

describe("connected apps and revocation", () => {
  it("lists connected apps grouped by client, and Revoke kills every token", async () => {
    const client = await register();
    const a = await exchange(client.client_id, await consentAndCode(client.client_id));
    const b = await exchange(client.client_id, await consentAndCode(client.client_id, { scopes: ["videos:read"] }));
    const apps = (await (await req("GET", `${API}/api/oauth/apps`, { bearer: OWNER })).json()) as { apps: Array<Record<string, unknown>> };
    expect(apps.apps).toEqual([
      expect.objectContaining({ clientId: client.client_id, name: "Claude", kind: "dcr", verifiedHost: null, connections: 2 }),
    ]);
    // Personal-token list stays personal.
    const tokens = (await (await req("GET", `${API}/api/agent-tokens`, { bearer: OWNER })).json()) as { tokens: unknown[] };
    expect(tokens.tokens).toEqual([]);

    const revoked = await req("POST", `${API}/api/oauth/apps/revoke`, { bearer: OWNER, json: { clientId: client.client_id } });
    expect(await revoked.json()).toMatchObject({ revoked: 2 });
    for (const t of [a, b]) {
      expect((await mcpCall(String(t.body.access_token), "ping")).status).toBe(401);
      expect((await refresh(client.client_id, String(t.body.refresh_token))).body.error).toBe("invalid_grant");
    }
    expect(((await (await req("GET", `${API}/api/oauth/apps`, { bearer: OWNER })).json()) as { apps: unknown[] }).apps).toEqual([]);
  });

  it("RFC 7009 /oauth/revoke revokes a refresh token's grant and answers 200 for anything", async () => {
    const client = await register();
    const t = await exchange(client.client_id, await consentAndCode(client.client_id));
    expect((await req("POST", `${API}/oauth/revoke`, { form: { client_id: client.client_id, token: "nonsense" } })).status).toBe(200);
    expect((await req("POST", `${API}/oauth/revoke`, { form: { client_id: client.client_id, token: String(t.body.refresh_token) } })).status).toBe(200);
    expect((await mcpCall(String(t.body.access_token), "ping")).status).toBe(401);
  });
});

describe("registration", () => {
  it("validates redirect URIs and issues a secret only to confidential clients", async () => {
    for (const bad of ["http://evil.test/cb", "javascript:alert(1)", "https://x.test/cb#frag", "not a uri"]) {
      const res = await req("POST", `${API}/oauth/register`, { json: { redirect_uris: [bad] } });
      expect(res.status, bad).toBe(400);
      expect(((await res.json()) as { error: string }).error).toBe("invalid_redirect_uri");
    }
    // Native apps: loopback http and private-use schemes are fine.
    await register(["http://localhost:33418/callback", "http://127.0.0.1:9999/cb", "cursor://anysphere.cursor-mcp/oauth/callback"]);
    const confidential = await register([REDIRECT], { token_endpoint_auth_method: "client_secret_basic" });
    expect(confidential.client_secret).toMatch(/^cc_ocs_/);
    const code = await consentAndCode(confidential.client_id);
    // Without the secret: invalid_client (401). With Basic: tokens.
    const noSecret = await exchange(confidential.client_id, code);
    expect(noSecret.status).toBe(401);
    const basic = btoa(`${encodeURIComponent(confidential.client_id)}:${encodeURIComponent(confidential.client_secret!)}`);
    const res = await req("POST", `${API}/oauth/token`, {
      headers: { Authorization: `Basic ${basic}` },
      form: { grant_type: "authorization_code", code, redirect_uri: REDIRECT, code_verifier: VERIFIER },
    });
    expect(res.status).toBe(200);
  });
});

describe("Client ID Metadata Documents", () => {
  const CLIENT_ID = "https://chatgpt.example.com/oauth/client.json";
  const doc = (over: Record<string, unknown> = {}) => ({
    client_id: CLIENT_ID,
    client_name: "ChatGPT",
    redirect_uris: [REDIRECT],
    logo_uri: "https://chatgpt.example.com/logo.png",
    token_endpoint_auth_method: "none",
    ...over,
  });

  it("fetches the document with SSRF guards, caches it, and shows the verified host at consent", async () => {
    fetchMock.mockImplementation(async (input: unknown, init?: unknown) => {
      expect(String(input)).toBe(CLIENT_ID);
      expect((init as RequestInit).redirect).toBe("manual");
      return new Response(JSON.stringify(doc()), { headers: { "Content-Type": "application/json" } });
    });
    const params = await authorizeParams(CLIENT_ID);
    const info = await req("GET", `${API}/api/oauth/authorize/info?${new URLSearchParams(params)}`, { bearer: OWNER });
    expect(await info.json()).toMatchObject({
      client: { clientId: CLIENT_ID, name: "ChatGPT", kind: "cimd", verifiedHost: "chatgpt.example.com", redirectHost: "claude.ai" },
      scopes: ["videos:read", "comments:read", "comments:write"],
      available: true,
    });
    const code = await consentAndCode(CLIENT_ID);
    const t = await exchange(CLIENT_ID, code);
    expect(t.status).toBe(200);
    // One fetch for all of that: the document is cached.
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const apps = (await (await req("GET", `${API}/api/oauth/apps`, { bearer: OWNER })).json()) as { apps: Array<Record<string, unknown>> };
    expect(apps.apps[0]).toMatchObject({ clientId: CLIENT_ID, kind: "cimd", verifiedHost: "chatgpt.example.com" });
  });

  it("refuses a document that doesn't name itself, carries a secret, redirects, or is too big", async () => {
    const tryWith = async (response: Response) => {
      db.query("DELETE FROM oauth_clients");
      fetchMock.mockImplementation(async () => response);
      const res = await req("GET", `${API}/oauth/authorize?${new URLSearchParams(await authorizeParams(CLIENT_ID))}`);
      return { status: res.status, text: await res.text() };
    };
    expect(await tryWith(new Response(JSON.stringify(doc({ client_id: "https://other.example.com/c.json" }))))).toMatchObject({ status: 400, text: expect.stringContaining("does not match") });
    expect((await tryWith(new Response(JSON.stringify(doc({ client_secret: "x" }))))).text).toContain("must not contain a client secret");
    expect((await tryWith(new Response(null, { status: 302, headers: { Location: "http://169.254.169.254/" } }))).text).toContain("HTTP 302");
    expect((await tryWith(new Response("x".repeat(70 * 1024)))).text).toContain("larger than 64 KB");
    expect((await tryWith(new Response(JSON.stringify(doc({ redirect_uris: ["https://evil.test/cb"] }))))).text).toContain("redirect_uri is not one");
  });

  it("never fetches a private, IP-literal or plain-http client_id", async () => {
    for (const id of ["https://127.0.0.1/c.json", "https://10.0.0.8/c.json", "http://client.example.com/c.json", "https://localhost/c.json"]) {
      const res = await req("GET", `${API}/oauth/authorize?${new URLSearchParams(await authorizeParams(id))}`);
      expect(res.status, id).toBe(400);
    }
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("checkClientIdUrl: the SSRF guard on client_id URLs", () => {
    const ok = (u: string) => checkClientIdUrl(u).ok;
    expect(ok("https://claude.ai/oauth/mcp-client-metadata.json")).toBe(true);
    expect(ok("https://app.example.com/.well-known/client?x=1")).toBe(true);
    for (const bad of [
      "http://claude.ai/client.json", // https only
      "https://claude.ai", // needs a path
      "https://claude.ai/", // root path
      "https://127.0.0.1/c.json",
      "https://2130706433/c.json", // decimal 127.0.0.1
      "https://0x7f.0.0.1/c.json", // hex
      "https://[::1]/c.json",
      "https://[fd00::1]/c.json",
      "https://169.254.169.254/latest/meta-data",
      "https://192.168.1.10/c.json",
      "https://8.8.8.8/c.json", // a public IP literal is still an IP literal
      "https://localhost/c.json",
      "https://router.local/c.json",
      "https://metadata.google.internal/c.json",
      "https://intranet/c.json", // single label
      "https://user:pw@claude.ai/c.json",
      "https://claude.ai/c.json#frag",
      "https://claude.ai:8443/c.json",
      "https://claude.ai/a/../c.json",
      "https://claude.ai/a/%2e%2e/c.json",
      "https://api.capturecat.so/c.json", // our own zone
      "ftp://claude.ai/c.json",
    ]) {
      expect(ok(bad), bad).toBe(false);
    }
  });
});

describe("redirect_uri matching", () => {
  const client = { redirectUris: ["https://claude.ai/api/mcp/auth_callback", "http://localhost/callback", "http://127.0.0.1:33418/cb"] };
  it("is exact for https", () => {
    expect(redirectUriAllowed(client, "https://claude.ai/api/mcp/auth_callback")).toBe(true);
    expect(redirectUriAllowed(client, "https://claude.ai/api/mcp/auth_callback/")).toBe(false);
    expect(redirectUriAllowed(client, "https://claude.ai:444/api/mcp/auth_callback")).toBe(false);
    expect(redirectUriAllowed(client, "https://evil.example/api/mcp/auth_callback")).toBe(false);
  });
  it("lets only the PORT of an http loopback redirect vary (RFC 8252 §7.3)", () => {
    expect(redirectUriAllowed(client, "http://localhost:51234/callback")).toBe(true);
    expect(redirectUriAllowed(client, "http://127.0.0.1:9/cb")).toBe(true);
    expect(redirectUriAllowed(client, "http://localhost:51234/other")).toBe(false);
    expect(redirectUriAllowed(client, "http://localhost:51234/callback?x=1")).toBe(false);
    expect(redirectUriAllowed(client, "https://localhost:51234/callback")).toBe(false);
    expect(redirectUriAllowed(client, "http://127.0.0.1:51234/callback")).toBe(false); // a different loopback host
    expect(redirectUriAllowed(client, "http://user@localhost:5/callback")).toBe(false);
    expect(redirectUriAllowed(client, "http://localhost.evil.example:5/callback")).toBe(false);
  });
});
