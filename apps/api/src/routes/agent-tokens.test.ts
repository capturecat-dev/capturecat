/**
 * Agent-token management (/api/agent-tokens, migration 0033) through the
 * REAL requireAuth and the real migrations (node:sqlite), plus the token
 * resolver the MCP server authenticates with.
 *
 * Mocked: the Better Auth session store (`Authorization: Bearer <uid>` names
 * the caller — test-support/fake-session).
 */

import { beforeEach, describe, expect, it, vi } from "vitest";
import { Hono } from "hono";
import type { Env, Variables } from "../types";
import { createTestD1, type TestD1 } from "../test-support/d1-sqlite.js";
import { sha256Hex } from "../lib/screenshot/keys";
import {
  AGENT_SCOPES,
  MAX_ACTIVE_AGENT_TOKENS,
  isAgentTokenShape,
  mintAgentToken,
  parseStoredScopes,
  resolveAgentToken,
  writeAgentAudit,
} from "../lib/agent-tokens";

vi.mock("../lib/auth", () => import("../test-support/fake-session"));
vi.stubGlobal("caches", {
  default: { match: async () => undefined, put: async () => undefined, delete: async () => true },
});

const { agentTokenRoutes } = await import("./agent-tokens");

const ALICE = "alice";
const BOB = "bob";
let db: TestD1;
let env: Env;
let app: Hono<{ Bindings: Env; Variables: Variables }>;

beforeEach(() => {
  db = createTestD1();
  env = { DB: db, BETTER_AUTH_URL: "http://localhost:8787" } as unknown as Env;
  const now = new Date().toISOString();
  for (const [id, blocked] of [[ALICE, 0], [BOB, 0], ["blocked", 1]] as const) {
    db.query(
      `INSERT INTO "user" (id, name, email, emailVerified, createdAt, updatedAt, tester, blocked)
       VALUES (?, ?, ?, 1, ?, ?, 0, ?)`,
      id, id, `${id}@test.local`, now, now, blocked,
    );
  }
  app = new Hono<{ Bindings: Env; Variables: Variables }>();
  app.route("/api", agentTokenRoutes);
});

function call(method: string, path: string, body?: unknown, auth: string | null = ALICE) {
  return app.request(
    `/api${path}`,
    {
      method,
      headers: {
        ...(auth ? { Authorization: `Bearer ${auth}` } : {}),
        "Content-Type": "application/json",
      },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    },
    env,
  );
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any -- asserted field by field
async function ok<T = any>(res: Response | Promise<Response>, status = 200): Promise<T> {
  const r = await res;
  const body = await r.json();
  expect(r.status, JSON.stringify(body)).toBe(status);
  return body as T;
}

async function create(body: Record<string, unknown> = {}, as = ALICE) {
  return ok(call("POST", "/agent-tokens", { name: "Claude", scopes: ["videos:read"], ...body }, as), 201);
}

describe("create / list / revoke", () => {
  it("creates a token, returns it once, and lists it without the secret", async () => {
    const created = await create({ scopes: ["videos:read", "comments:read", "videos:read"], expiresInDays: 30 });
    expect(isAgentTokenShape(created.token)).toBe(true);
    expect(created.token.startsWith(created.prefix)).toBe(true);
    expect(created.prefix).toMatch(/^cc_pat_[A-Za-z0-9]{8}$/);
    // Deduplicated, in the canonical scope order.
    expect(created.scopes).toEqual(["videos:read", "comments:read"]);
    const days = (Date.parse(created.expiresAt) - Date.parse(created.createdAt)) / 86_400_000;
    expect(Math.round(days)).toBe(30);

    const list = await ok(call("GET", "/agent-tokens"));
    expect(list.scopes).toEqual([...AGENT_SCOPES]);
    expect(list.tokens).toHaveLength(1);
    expect(list.tokens[0]).toEqual({
      id: created.id,
      name: "Claude",
      prefix: created.prefix,
      scopes: ["videos:read", "comments:read"],
      createdAt: created.createdAt,
      expiresAt: created.expiresAt,
      lastUsedAt: null,
      revokedAt: null,
    });
    expect(JSON.stringify(list)).not.toContain(created.token);
  });

  it("no expiry means expiresAt null", async () => {
    expect((await create()).expiresAt).toBeNull();
  });

  it("revokes, and a revoked token resolves to nothing", async () => {
    const created = await create();
    expect(await resolveAgentToken(db, `Bearer ${created.token}`)).not.toBeNull();
    expect(await ok(call("DELETE", `/agent-tokens/${created.id}`))).toEqual({ id: created.id, revoked: true });
    expect(await resolveAgentToken(db, `Bearer ${created.token}`)).toBeNull();
    // Twice is a 404, and the list keeps it with revokedAt set.
    await ok(call("DELETE", `/agent-tokens/${created.id}`), 404);
    const [row] = (await ok(call("GET", "/agent-tokens"))).tokens;
    expect(row.revokedAt).toBeTruthy();
  });

  it("one user can neither list nor revoke another user's tokens", async () => {
    const created = await create();
    expect((await ok(call("GET", "/agent-tokens", undefined, BOB))).tokens).toEqual([]);
    await ok(call("DELETE", `/agent-tokens/${created.id}`, undefined, BOB), 404);
    expect(await resolveAgentToken(db, `Bearer ${created.token}`)).not.toBeNull();
  });

  it("validates the body", async () => {
    expect((await ok(call("POST", "/agent-tokens", { name: "x", scopes: ["billing:write"] }), 400)).error).toContain("Unknown scope");
    expect((await ok(call("POST", "/agent-tokens", { name: "x", scopes: [] }), 400)).error).toContain("at least one scope");
    expect((await ok(call("POST", "/agent-tokens", { name: "  ", scopes: ["videos:read"] }), 400)).error).toContain("name");
    await ok(call("POST", "/agent-tokens", { name: "x", scopes: ["videos:read"], expiresInDays: 0 }), 400);
    await ok(call("POST", "/agent-tokens", { name: "x", scopes: ["videos:read"], expiresInDays: 366 }), 400);
    expect(db.query("SELECT * FROM agent_tokens")).toHaveLength(0);
  });

  it("caps active tokens; revoking frees a slot", async () => {
    // Bypass the per-user mint limiter: insert directly, then try one more.
    for (let i = 0; i < MAX_ACTIVE_AGENT_TOKENS; i++) {
      const m = await mintAgentToken();
      db.query(
        `INSERT INTO agent_tokens (id, user_id, name, token_hash, token_prefix, scopes, created_at)
         VALUES (?, ?, ?, ?, ?, '["videos:read"]', ?)`,
        `t${i}`, ALICE, `t${i}`, m.hash, m.prefix, new Date().toISOString(),
      );
    }
    expect((await ok(call("POST", "/agent-tokens", { name: "x", scopes: ["videos:read"] }), 400)).code).toBe("too_many_tokens");
    await ok(call("DELETE", "/agent-tokens/t0"));
    await create();
  });

  it("requires a session", async () => {
    await ok(call("GET", "/agent-tokens", undefined, null), 401);
    // Without a bearer it is a cookie request, and a write needs a trusted Origin first.
    await ok(call("POST", "/agent-tokens", { name: "x", scopes: ["videos:read"] }, null), 403);
    await ok(call("GET", "/agent-tokens", undefined, "blocked"), 403);
  });

  it("an agent token can never manage agent tokens", async () => {
    const { token, id } = await create({ scopes: [...AGENT_SCOPES] });
    for (const [method, path, body] of [
      ["GET", "/agent-tokens", undefined],
      ["POST", "/agent-tokens", { name: "escalate", scopes: [...AGENT_SCOPES] }],
      ["DELETE", `/agent-tokens/${id}`, undefined],
      ["GET", "/agent-tokens/audit", undefined],
    ] as const) {
      const body2 = await ok(call(method, path, body, token), 403);
      expect(body2.code).toBe("agent_token_forbidden");
    }
    expect(db.query("SELECT * FROM agent_tokens")).toHaveLength(1);
  });
});

describe("storage", () => {
  it("stores only the SHA-256 of the token, never the token", async () => {
    const created = await create();
    const [row] = db.query<Record<string, unknown>>("SELECT * FROM agent_tokens");
    expect(row.token_hash).toBe(await sha256Hex(created.token));
    expect(row.token_prefix).toBe(created.prefix);
    for (const value of Object.values(row)) {
      expect(String(value)).not.toContain(created.token);
    }
    expect(parseStoredScopes(String(row.scopes))).toEqual(["videos:read"]);
  });
});

describe("resolveAgentToken", () => {
  it("resolves a live token to its user, token and scopes, and throttles last_used_at", async () => {
    const created = await create({ scopes: ["videos:read", "account:read"] });
    const t0 = new Date("2026-10-28T10:00:00.000Z");
    const p = await resolveAgentToken(db, `Bearer ${created.token}`, t0);
    expect(p).toEqual({
      uid: ALICE,
      tokenId: created.id,
      tokenName: "Claude",
      scopes: ["videos:read", "account:read"],
      claims: { tester: false, blocked: false },
      kind: "personal",
      oauthClientId: null,
      oauthGrantId: null,
      resource: null,
    });
    const lastUsed = () => db.query<{ last_used_at: string }>("SELECT last_used_at FROM agent_tokens")[0].last_used_at;
    expect(lastUsed()).toBe(t0.toISOString());
    await resolveAgentToken(db, `Bearer ${created.token}`, new Date(t0.getTime() + 30_000));
    expect(lastUsed()).toBe(t0.toISOString()); // within the minute: no write
    const t2 = new Date(t0.getTime() + 61_000);
    await resolveAgentToken(db, `Bearer ${created.token}`, t2);
    expect(lastUsed()).toBe(t2.toISOString());
  });

  it("refuses malformed, unknown, wrong-secret and expired tokens", async () => {
    const created = await create({ expiresInDays: 1 });
    expect(await resolveAgentToken(db, null)).toBeNull();
    expect(await resolveAgentToken(db, "Bearer")).toBeNull();
    expect(await resolveAgentToken(db, `Basic ${created.token}`)).toBeNull();
    expect(await resolveAgentToken(db, "Bearer cc_pat_short")).toBeNull();
    expect(await resolveAgentToken(db, `Bearer ${(await mintAgentToken()).token}`)).toBeNull();
    // Right prefix, wrong secret.
    const forged = created.prefix + "A".repeat(created.token.length - created.prefix.length);
    expect(await resolveAgentToken(db, `Bearer ${forged}`)).toBeNull();
    // Expired: one day and a second later.
    const later = new Date(Date.parse(created.expiresAt) + 1000);
    expect(await resolveAgentToken(db, `Bearer ${created.token}`, later)).toBeNull();
    expect(await resolveAgentToken(db, `Bearer ${created.token}`)).not.toBeNull();
  });

  it("minted tokens are 40 base62 characters after cc_pat_ and distinct", async () => {
    const seen = new Set<string>();
    for (let i = 0; i < 50; i++) {
      const { token, prefix, hash } = await mintAgentToken();
      expect(token).toMatch(/^cc_pat_[A-Za-z0-9]{40}$/);
      expect(prefix).toBe(token.slice(0, 15));
      expect(hash).toMatch(/^[0-9a-f]{64}$/);
      seen.add(token);
    }
    expect(seen.size).toBe(50);
  });
});

describe("audit", () => {
  it("lists the user's own recent entries, newest first, with the token's name", async () => {
    const created = await create();
    await writeAgentAudit(db, { uid: ALICE, tokenId: created.id, tool: "list_videos", ok: true }, new Date("2026-10-01T00:00:00Z"));
    await writeAgentAudit(
      db,
      { uid: ALICE, tokenId: created.id, tool: "get_video", videoId: "vid1", ok: false, error: "nope" },
      new Date("2026-10-02T00:00:00Z"),
    );
    await writeAgentAudit(db, { uid: BOB, tokenId: "x", tool: "get_account", ok: true });
    const { entries } = await ok(call("GET", "/agent-tokens/audit"));
    expect(entries.map((e: { tool: string }) => e.tool)).toEqual(["get_video", "list_videos"]);
    expect(entries[0]).toMatchObject({
      tokenId: created.id,
      tokenName: "Claude",
      tokenPrefix: created.prefix,
      videoId: "vid1",
      ok: false,
      error: "nope",
    });
  });
});
