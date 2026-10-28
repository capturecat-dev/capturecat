/**
 * Phase 2 of the agent surface, through the REAL Worker entry (index.ts),
 * the real migrations (node:sqlite) and the real session middleware
 * (fake-session: `Authorization: Bearer <uid>` is that user's session):
 *
 *   • plan gates — agentAccess on token creation and EVERY /mcp request,
 *     agentEditing via the helper the editing tools call, migration 0034;
 *   • "ask me first" — an agent token can never approve, arguments can't be
 *     swapped, an approval runs exactly once, and it expires.
 */

import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Env } from "../types";
import { createTestD1, type TestD1 } from "../test-support/d1-sqlite.js";
import { MemoryBucket } from "../test-support/memory-bucket";
import { AGENT_SCOPES, createAgentToken, type AgentScope } from "../lib/agent-tokens";
import { APPROVAL_TTL_MS, canonicalApprovalArgs, canonicalJson, decideApproval } from "../lib/agent-approvals";
import { findTool, moreVisibleChanges } from "./tools";
import { makeContext, ToolError } from "./tool";
import { requireAgentEditing } from "./gates";
import type { CallToolResult } from "./server";

vi.mock("cloudflare:workers", () => ({ DurableObject: class {} }));
vi.mock("../lib/auth", () => import("../test-support/fake-session"));
vi.stubGlobal("caches", { default: { match: async () => undefined, put: async () => undefined, delete: async () => true } });
vi.stubGlobal(
  "fetch",
  vi.fn(async () => {
    throw new Error("offline test: unexpected fetch");
  }),
);

const { default: worker } = await import("../index");

const OWNER = "owner"; // tester → pro
const OTHER = "other"; // free
const API = "http://localhost:8787";
const ctx = { waitUntil() {}, passThroughOnException() {} } as unknown as ExecutionContext;

let db: TestD1;
let env: Env;
let seq = 0;

function insertVideo(videoId: string, uid: string, extra: Record<string, unknown> = {}) {
  const row: Record<string, unknown> = {
    video_id: videoId,
    uid,
    file_name: `${videoId}.mp4`,
    r2_key: `videos/${videoId}.mp4`,
    url: `https://x.test/${videoId}`,
    status: "ready",
    created_at: new Date().toISOString(),
    duration_seconds: 120,
    file_size_bytes: 1000,
    comments_enabled: 1,
    ...extra,
  };
  const cols = Object.keys(row);
  db.query(`INSERT INTO shared_videos (${cols.join(", ")}) VALUES (${cols.map(() => "?").join(", ")})`, ...cols.map((c) => row[c]));
}

beforeEach(() => {
  seq = 0;
  db = createTestD1();
  env = {
    DB: db,
    R2: new MemoryBucket(),
    BETTER_AUTH_URL: API,
    BETTER_AUTH_SECRET: "test-secret-test-secret-test-secret-00",
  } as unknown as Env;
  const now = new Date().toISOString();
  for (const [id, tester] of [[OWNER, 1], [OTHER, 0]] as const) {
    db.query(
      `INSERT INTO "user" (id, name, email, emailVerified, image, createdAt, updatedAt, tester, blocked)
       VALUES (?, ?, ?, 1, NULL, ?, ?, ?, 0)`,
      id, id === OWNER ? "Olive Owner" : "Otto", `${id}@test.local`, now, now, tester,
    );
  }
  insertVideo("pub1", OWNER); // public, comments on
  insertVideo("priv1", OWNER, { is_private: 1, password_hash: "pbkdf2$00$00", expires_at: "2026-12-01T00:00:00.000Z", max_views: 10 });
});

async function token(scopes: readonly AgentScope[] = AGENT_SCOPES, uid = OWNER, name = "Claude") {
  const created = await createAgentToken(db, { uid, name, scopes: [...scopes], expiresInDays: null });
  return { token: created.token, id: created.summary.id };
}

function request(method: string, path: string, opts: { bearer?: string; body?: unknown } = {}) {
  return worker.fetch(
    new Request(`${API}${path}`, {
      method,
      headers: {
        "Content-Type": "application/json",
        ...(opts.bearer ? { Authorization: `Bearer ${opts.bearer}` } : {}),
      },
      ...(opts.body === undefined ? {} : { body: JSON.stringify(opts.body) }),
    }),
    env,
    ctx,
  );
}

async function mcp(tok: string, body: unknown) {
  return request("POST", "/mcp", { bearer: tok, body });
}

async function call(tok: string, name: string, args: Record<string, unknown> = {}): Promise<CallToolResult> {
  const res = await mcp(tok, { jsonrpc: "2.0", id: ++seq, method: "tools/call", params: { name, arguments: args } });
  const body = (await res.json()) as { result: CallToolResult };
  expect(res.status, JSON.stringify(body)).toBe(200);
  return body.result;
}

function asked(result: CallToolResult): { status: string; approval_id: string; approve_url: string; expires_at: string; message: string; summary: string } {
  expect(result.isError, JSON.stringify(result.content)).toBeFalsy();
  return result.structuredContent as never;
}

function errorText(result: CallToolResult): string {
  expect(result.isError).toBe(true);
  return (result.content[0] as { text: string }).text;
}

const approve = (id: string, as = OWNER) => request("POST", `/api/agent-approvals/${id}/approve`, { bearer: as });
const comments = () => db.query<{ body: string }>("SELECT body FROM video_comments WHERE video_id = 'pub1' ORDER BY created_at");
const setFeature = (plan: string, key: string, on: boolean) =>
  db.query(`UPDATE plan SET features = json_set(features, '$.${key}', json(?)) WHERE name = ?`, on ? "true" : "false", plan);

// ---------------------------------------------------------------------------
// Plan gates
// ---------------------------------------------------------------------------

describe("plan gates", () => {
  it("migration 0034 turns the three agent flags on for EVERY existing plan, custom ones included", () => {
    const old = createTestD1({ before: "0034_agent_features.sql" });
    old.query(
      `INSERT INTO plan (id, name, display_name, features, limits, sort_order, is_active) VALUES ('plan_x', 'custom', 'Custom', '{"cloudShare":true}', '{}', 50, 1)`,
    );
    old.migrate("0034_agent_features.sql");
    const rows = old.query<{ name: string; features: string }>("SELECT name, features FROM plan");
    expect(rows.length).toBeGreaterThanOrEqual(3);
    for (const r of rows) {
      const f = JSON.parse(r.features);
      expect([r.name, f.agentAccess, f.agentWebhooks, f.agentEditing]).toEqual([r.name, true, true, true]);
    }
    // Other flags are untouched.
    expect(JSON.parse(rows.find((r) => r.name === "custom")!.features).cloudShare).toBe(true);
  });

  it("token creation needs agentAccess; the list reports the flags", async () => {
    const list = await request("GET", "/api/agent-tokens", { bearer: OWNER });
    expect(((await list.json()) as { features: unknown }).features).toEqual({ agentAccess: true, agentWebhooks: true, agentEditing: true });
    setFeature("pro", "agentAccess", false);
    const refused = await request("POST", "/api/agent-tokens", { bearer: OWNER, body: { name: "x", scopes: ["videos:read"] } });
    expect(refused.status).toBe(403);
    expect(await refused.json()).toMatchObject({ code: "upgrade_required", feature: "agentAccess", plan: "pro" });
    const after = (await (await request("GET", "/api/agent-tokens", { bearer: OWNER })).json()) as { features: { agentAccess: boolean } };
    expect(after.features.agentAccess).toBe(false);
  });

  it("every /mcp request re-checks agentAccess: a downgrade cuts an existing token off with a clear 403", async () => {
    const { token: t } = await token();
    expect((await mcp(t, { jsonrpc: "2.0", id: 1, method: "ping" })).status).toBe(200);
    setFeature("pro", "agentAccess", false);
    const res = await mcp(t, { jsonrpc: "2.0", id: 1, method: "ping" });
    expect(res.status).toBe(403);
    const body = (await res.json()) as { error: string; error_description: string };
    expect(body.error).toBe("plan_feature_unavailable");
    expect(body.error_description).toContain("isn't included in the account's CaptureCat Pro plan");
    setFeature("pro", "agentAccess", true);
    expect((await mcp(t, { jsonrpc: "2.0", id: 1, method: "ping" })).status).toBe(200);
  });

  it("requireAgentEditing (for the cloud-project tools) follows the plan's agentEditing flag", async () => {
    const principal = { uid: OWNER, tokenId: "t", tokenName: "T", scopes: [...AGENT_SCOPES], claims: { tester: true, blocked: false } };
    await expect(requireAgentEditing(makeContext(env, principal))).resolves.toMatchObject({ name: "pro" });
    setFeature("pro", "agentEditing", false);
    const err = await requireAgentEditing(makeContext(env, principal)).catch((e: unknown) => e);
    expect(err).toBeInstanceOf(ToolError);
    expect((err as Error).message).toContain("Agent editing of cloud projects isn't included");
  });
});

// ---------------------------------------------------------------------------
// Ask me first
// ---------------------------------------------------------------------------

describe("ask me first", () => {
  it("post_comment answers approval_required (a normal result) and posts nothing until approved", async () => {
    const { token: t } = await token();
    const first = asked(await call(t, "post_comment", { video_id: "pub1", body: "Thanks!" }));
    expect(first).toMatchObject({ status: "approval_required" });
    expect(first.approve_url).toBe(`http://localhost:3200/app/approvals/${first.approval_id}`);
    expect(first.message).toContain(first.approve_url);
    expect(first.message).toContain("approval_id");
    expect(Date.parse(first.expires_at) - Date.now()).toBeGreaterThan(APPROVAL_TTL_MS - 5_000);
    expect(findTool("post_comment")!.output.parse(first)).toEqual(first);
    expect(comments()).toEqual([]);

    // Repeating before a decision: pending, still nothing posted, no new row.
    const again = asked(await call(t, "post_comment", { video_id: "pub1", body: "Thanks!", approval_id: first.approval_id }));
    expect(again).toMatchObject({ status: "approval_pending", approval_id: first.approval_id });
    const same = asked(await call(t, "post_comment", { video_id: "pub1", body: "Thanks!" }));
    expect(same.approval_id).toBe(first.approval_id);
    expect(db.query("SELECT id FROM agent_approvals")).toHaveLength(1);

    // The owner sees who asks and what, then approves.
    const detail = (await (await request("GET", `/api/agent-approvals/${first.approval_id}`, { bearer: OWNER })).json()) as {
      approval: Record<string, unknown>;
    };
    expect(detail.approval).toMatchObject({
      status: "pending",
      tool: "post_comment",
      requester: { tokenName: "Claude", kind: "personal", oauthClient: null },
      video: { id: "pub1", title: "pub1.mp4", isPrivate: false },
      videoShareUrl: "http://localhost:3200/share/pub1",
    });
    expect(detail.approval.details).toContain("Comment: “Thanks!”");
    const pending = (await (await request("GET", "/api/agent-approvals", { bearer: OWNER })).json()) as { approvals: unknown[] };
    expect(pending.approvals).toHaveLength(1);
    expect((await approve(first.approval_id)).status).toBe(200);

    const posted = await call(t, "post_comment", { video_id: "pub1", body: "Thanks!", approval_id: first.approval_id });
    expect(posted.isError).toBeFalsy();
    expect((posted.structuredContent as { comment: { body: string } }).comment.body).toBe("Thanks!");
    expect(comments()).toEqual([{ body: "Thanks!" }]);
  });

  it("an agent token can never approve — personal or OAuth — and there is no approving tool", async () => {
    const { token: t } = await token();
    const { approval_id } = asked(await call(t, "post_comment", { video_id: "pub1", body: "hi" }));
    for (const bearer of [t, `cc_oat_${"A".repeat(40)}`]) {
      const res = await approve(approval_id, bearer);
      expect(res.status).toBe(403);
      expect(((await res.json()) as { code: string }).code).toBe("agent_token_forbidden");
      expect((await request("GET", `/api/agent-approvals/${approval_id}`, { bearer })).status).toBe(403);
    }
    // No session at all: 401 (a cookie-style POST without a trusted Origin
    // is refused even earlier, 403). Another user's session: not theirs.
    expect((await request("GET", `/api/agent-approvals/${approval_id}`)).status).toBe(401);
    expect((await request("POST", `/api/agent-approvals/${approval_id}/approve`)).status).toBe(403);
    expect((await approve(approval_id, OTHER)).status).toBe(404);
    // Nothing on the MCP side decides one.
    const list = await mcp(t, { jsonrpc: "2.0", id: 1, method: "tools/list" });
    const names = ((await list.json()) as { result: { tools: Array<{ name: string }> } }).result.tools.map((x) => x.name);
    expect(names.filter((n) => /approv/.test(n))).toEqual(["get_approval"]);
    expect(db.query<{ status: string }>("SELECT status FROM agent_approvals")).toEqual([{ status: "pending" }]);
    expect(asked(await call(t, "post_comment", { video_id: "pub1", body: "hi", approval_id })).status).toBe("approval_pending");
    expect(comments()).toEqual([]);
  });

  it("refuses an approval used with different arguments, another tool, or another token", async () => {
    const { token: t } = await token();
    const { token: t2 } = await token(AGENT_SCOPES, OWNER, "Other agent");
    const { approval_id } = asked(await call(t, "post_comment", { video_id: "pub1", body: "Nice video" }));
    await approve(approval_id);
    expect(errorText(await call(t, "post_comment", { video_id: "pub1", body: "Buy crypto at evil.test", approval_id }))).toContain(
      "differ from the ones the account owner approved",
    );
    expect(errorText(await call(t, "post_comment", { video_id: "pub1", body: "Nice video", video_time: 5, approval_id }))).toContain("differ");
    expect(errorText(await call(t2, "post_comment", { video_id: "pub1", body: "Nice video", approval_id }))).toContain(
      "was requested by this token",
    );
    expect(errorText(await call(t, "update_share_settings", { video_id: "priv1", is_private: false, approval_id }))).toContain(
      "was given for post_comment",
    );
    expect(comments()).toEqual([]);
    // Key order is not a difference: canonical JSON.
    const ok = await call(t, "post_comment", { body: "Nice video", approval_id, video_id: "pub1" });
    expect(ok.isError).toBeFalsy();
    expect(comments()).toEqual([{ body: "Nice video" }]);
  });

  it("is single-use", async () => {
    const { token: t } = await token();
    const { approval_id } = asked(await call(t, "post_comment", { video_id: "pub1", body: "once" }));
    await approve(approval_id);
    expect((await call(t, "post_comment", { video_id: "pub1", body: "once", approval_id })).isError).toBeFalsy();
    expect(errorText(await call(t, "post_comment", { video_id: "pub1", body: "once", approval_id }))).toContain("already used");
    expect(comments()).toEqual([{ body: "once" }]);
    // The owner can't re-approve a used one either.
    expect((await approve(approval_id)).status).toBe(409);
  });

  it("expires: undecided after 15 minutes, and approved-but-unused 15 minutes after approval", async () => {
    const { token: t } = await token();
    const a = asked(await call(t, "post_comment", { video_id: "pub1", body: "late" }));
    db.query("UPDATE agent_approvals SET expires_at = ? WHERE id = ?", new Date(Date.now() - 1000).toISOString(), a.approval_id);
    const tooLate = await approve(a.approval_id);
    expect(tooLate.status).toBe(409);
    expect(((await tooLate.json()) as { error: string }).error).toContain("expired");
    expect(errorText(await call(t, "post_comment", { video_id: "pub1", body: "late", approval_id: a.approval_id }))).toContain("expired");

    const b = asked(await call(t, "post_comment", { video_id: "pub1", body: "later" }));
    await approve(b.approval_id);
    const [row] = db.query<{ expires_at: string; decided_at: string }>("SELECT expires_at, decided_at FROM agent_approvals WHERE id = ?", b.approval_id);
    expect(Date.parse(row.expires_at) - Date.parse(row.decided_at)).toBe(APPROVAL_TTL_MS);
    db.query("UPDATE agent_approvals SET expires_at = ? WHERE id = ?", new Date(Date.now() - 1000).toISOString(), b.approval_id);
    expect(errorText(await call(t, "post_comment", { video_id: "pub1", body: "later", approval_id: b.approval_id }))).toContain("expired");
    expect(comments()).toEqual([]);
  });

  it("a denial is final, and get_approval reports every state to the token that asked", async () => {
    const { token: t } = await token(["comments:write"]);
    const { token: t2 } = await token(["comments:write"]);
    const { approval_id } = asked(await call(t, "post_comment", { video_id: "pub1", body: "no" }));
    const pending = await call(t, "get_approval", { approval_id });
    expect(pending.structuredContent).toMatchObject({ approvalId: approval_id, status: "pending", tool: "post_comment" });
    expect(findTool("get_approval")!.output.parse(pending.structuredContent)).toEqual(pending.structuredContent);
    expect(errorText(await call(t2, "get_approval", { approval_id }))).toContain("No approval");
    expect((await request("POST", `/api/agent-approvals/${approval_id}/deny`, { bearer: OWNER })).status).toBe(200);
    expect((await call(t, "get_approval", { approval_id })).structuredContent).toMatchObject({ status: "denied" });
    expect(errorText(await call(t, "post_comment", { video_id: "pub1", body: "no", approval_id }))).toContain("denied");
    expect((await approve(approval_id)).status).toBe(409);
    expect(comments()).toEqual([]);
  });

  it("update_share_settings asks only when the video becomes MORE visible", async () => {
    const { token: t } = await token();
    // More private: runs at once (pub1 gets a password, an expiry, a cap).
    const tighter = await call(t, "update_share_settings", {
      video_id: "pub1",
      password: "s3cret",
      expires_at: "2026-11-30T00:00:00.000Z",
      max_views: 5,
      is_private: true,
      profile_visible: false,
    });
    expect(tighter.isError).toBeFalsy();
    expect(tighter.structuredContent).toMatchObject({ share: { isPrivate: true, hasPassword: true, maxViews: 5 } });
    expect(db.query("SELECT id FROM agent_approvals")).toHaveLength(0);

    // Going public with a new password: asks; the password is stored only as a hash.
    const ask = asked(await call(t, "update_share_settings", { video_id: "priv1", is_private: false, password: "hunter2" }));
    expect(ask.summary).toContain("make it viewable");
    const [row] = db.query<{ args_json: string; details: string }>("SELECT args_json, details FROM agent_approvals");
    expect(row.args_json).not.toContain("hunter2");
    expect(row.args_json).toContain(`"password":"sha256:`);
    expect(db.query<{ is_private: number }>("SELECT is_private FROM shared_videos WHERE video_id = 'priv1'")[0].is_private).toBe(1);
    await approve(ask.approval_id);
    expect(errorText(await call(t, "update_share_settings", { video_id: "priv1", is_private: false, password: "other", approval_id: ask.approval_id }))).toContain("differ");
    const done = await call(t, "update_share_settings", { video_id: "priv1", is_private: false, password: "hunter2", approval_id: ask.approval_id });
    expect(done.isError).toBeFalsy();
    expect(done.structuredContent).toMatchObject({ share: { isPrivate: false } });
  });

  it("moreVisibleChanges: what counts as more visible", () => {
    const doc = { isPrivate: true, passwordHash: "h", expiresAt: "2026-12-01T00:00:00.000Z", maxViews: 10, profileVisible: false };
    expect(moreVisibleChanges(doc, { is_private: true, password: "new", expires_at: "2026-11-01T00:00:00.000Z", max_views: 3 })).toEqual([]);
    expect(moreVisibleChanges(doc, { is_private: false })).toEqual(["Make it viewable: anyone with the link can watch"]);
    expect(moreVisibleChanges(doc, { password: null })).toEqual(["Remove its share-page password"]);
    expect(moreVisibleChanges(doc, { expires_at: null })).toEqual(["Remove the link's expiry"]);
    expect(moreVisibleChanges(doc, { expires_at: "2027-01-01T00:00:00.000Z" })).toEqual(["Extend the link's expiry to 2027-01-01T00:00:00.000Z"]);
    expect(moreVisibleChanges(doc, { max_views: 0 })).toEqual(["Remove the 10-viewer cap"]);
    expect(moreVisibleChanges(doc, { max_views: null })).toEqual(["Remove the 10-viewer cap"]);
    expect(moreVisibleChanges(doc, { max_views: 50 })).toEqual(["Raise the viewer cap from 10 to 50"]);
    expect(moreVisibleChanges(doc, { profile_visible: true })).toEqual(["List it on your public profile page"]);
    // Already public / no password / no expiry / no cap: nothing to widen.
    const open = { isPrivate: false, passwordHash: null, expiresAt: null, maxViews: null, profileVisible: true };
    expect(moreVisibleChanges(open, { is_private: false, password: null, expires_at: null, max_views: null, profile_visible: true })).toEqual([]);
  });

  it("audits the request, the decision and the run", async () => {
    const { token: t, id } = await token();
    const { approval_id } = asked(await call(t, "post_comment", { video_id: "pub1", body: "audited" }));
    await approve(approval_id);
    await call(t, "post_comment", { video_id: "pub1", body: "audited", approval_id });
    expect(db.query("SELECT tool, ok, error, token_id, video_id FROM agent_audit_log ORDER BY rowid")).toEqual([
      { tool: "post_comment", ok: 0, error: `approval required (${approval_id})`, token_id: id, video_id: "pub1" },
      { tool: "approval.approved:post_comment", ok: 1, error: null, token_id: id, video_id: "pub1" },
      { tool: "post_comment", ok: 1, error: null, token_id: id, video_id: "pub1" },
    ]);
  });

  it("canonical arguments ignore key order and hash secrets", async () => {
    expect(canonicalJson({ b: 1, a: { d: [1, { z: 1, y: 2 }], c: undefined } })).toBe('{"a":{"d":[1,{"y":2,"z":1}]},"b":1}');
    const one = await canonicalApprovalArgs({ video_id: "v", password: "pw", approval_id: "x" }, ["password"]);
    const two = await canonicalApprovalArgs({ password: "pw", video_id: "v" }, ["password"]);
    expect(one).toBe(two);
    expect(one).not.toContain("pw\"");
  });

  it("caps undecided requests per user", async () => {
    const { token: t } = await token();
    for (let i = 0; i < 20; i++) asked(await call(t, "post_comment", { video_id: "pub1", body: `ask ${i}` }));
    expect(errorText(await call(t, "post_comment", { video_id: "pub1", body: "ask 21" }))).toContain("already 20 requests");
    // A decision frees a slot.
    const [first] = db.query<{ id: string }>("SELECT id FROM agent_approvals ORDER BY created_at LIMIT 1");
    expect((await decideApproval(db, OWNER, first.id, "denied")).ok).toBe(true);
    asked(await call(t, "post_comment", { video_id: "pub1", body: "ask 21" }));
  });
});
