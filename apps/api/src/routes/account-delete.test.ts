/**
 * DELETE /api/me — account deletion (migration 0043) through the REAL Worker
 * entry (routing, requireAuth's cookie CSRF gate, the agent-token refusal),
 * the real migrations (node:sqlite) and the real `stripe` SDK talking to an
 * in-memory Stripe behind a stubbed `fetch`. Nothing leaves the process: no
 * Stripe, no R2, no Cloudflare API.
 *
 * Two users share content: Alice deletes her account; everything she owns
 * must be gone (a scan of EVERY table and EVERY R2 key for her ids proves
 * it), Bob's content must be untouched, and Alice's own S3 bucket must never
 * be called.
 *
 * Mocked: Better Auth's session lookup — `Authorization: Bearer <uid>` is
 * that user's app session, the cookie `cc_session=<uid>` a browser session.
 */
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Env } from "../types";
import { createTestD1, type TestD1 } from "../test-support/d1-sqlite.js";
import { MemoryBucket } from "../test-support/memory-bucket";

vi.mock("cloudflare:workers", () => ({ DurableObject: class {} }));
vi.mock("../lib/auth", () => ({
  hasAppleConfig: () => true,
  hasGoogleConfig: () => true,
  getAuth: (env: Env) => {
    const lookup = (uid: string | null | undefined) =>
      uid
        ? env.DB.prepare(
            `SELECT u.id, u.email, u.tester, u.blocked FROM "user" u
               JOIN "session" s ON s."userId" = u.id WHERE u.id = ? LIMIT 1`,
          )
            .bind(uid)
            .first<{ id: string; email: string; tester: number; blocked: number }>()
        : Promise.resolve(null);
    return {
      api: {
        // A session exists only while a `session` row does — so deleting the
        // account really does sign the caller out.
        getSession: async ({ headers }: { headers: Headers }) => {
          const bearer = /^Bearer\s+(\S+)$/i.exec(headers.get("Authorization") ?? "")?.[1];
          const cookie = /(?:^|;\s*)cc_session=([^;]+)/.exec(headers.get("Cookie") ?? "")?.[1];
          const user = (await lookup(bearer)) ?? (await lookup(cookie));
          return user
            ? {
                session: { expiresAt: new Date(Date.now() + 86_400_000) },
                user: { id: user.id, email: user.email, tester: user.tester === 1, blocked: user.blocked === 1 },
              }
            : null;
        },
      },
    };
  },
}));

// ---------------------------------------------------------------------------
// In-memory Stripe (subscriptions only) + every outbound call recorded
// ---------------------------------------------------------------------------
type FakeSub = { id: string; object: "subscription"; customer: string; status: string; metadata: Record<string, string> };
const stripe = vi.hoisted(() => ({
  subs: new Map<string, FakeSub>(),
  fail: false,
  calls: [] as Array<{ method: string; url: string }>,
}));
const cacheDeletes: string[] = [];
vi.stubGlobal("caches", {
  default: {
    match: async () => undefined,
    put: async () => undefined,
    delete: async (req: Request) => {
      cacheDeletes.push(req.url);
      return true;
    },
  },
});
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
vi.stubGlobal(
  "fetch",
  vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = new URL(typeof input === "string" ? input : input instanceof URL ? input.href : input.url);
    const method = init?.method ?? "GET";
    stripe.calls.push({ method, url: url.href });
    if (url.hostname !== "api.stripe.com") return json({ error: "unexpected outbound call" }, 599);
    if (stripe.fail) return json({ error: { type: "api_error", message: "stripe is down" } }, 500);
    const missing = (id: string) =>
      json({ error: { type: "invalid_request_error", code: "resource_missing", message: `No such subscription: '${id}'` } }, 404);
    if (url.pathname === "/v1/subscriptions" && method === "GET") {
      const customer = url.searchParams.get("customer");
      const data = [...stripe.subs.values()].filter((s) => s.customer === customer);
      return json({ object: "list", data, has_more: false, url: "/v1/subscriptions" });
    }
    const m = /^\/v1\/subscriptions\/([^/]+)$/.exec(url.pathname);
    if (m) {
      const sub = stripe.subs.get(m[1]);
      if (!sub) return missing(m[1]);
      if (method === "DELETE") sub.status = "canceled";
      return json(sub);
    }
    return json({ error: { message: `fake stripe: unhandled ${method} ${url.pathname}` } }, 500);
  }),
);

const { default: worker } = await import("../index");
const { deleteAccountRows, processAccountDeletions } = await import("../lib/account-deletion");

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------
const API = "https://api.capturecat.so";
const WEB = "https://app.capturecat.so";
const ALICE = "alice";
const BOB = "bob";
const CAROL = "carol";
const CUSTOMER_BUCKET_ENDPOINT = "https://s3.alice-own-bucket.example";

/** R2 with `list` (prefix pages) and an injectable failure. */
class ListingBucket extends MemoryBucket {
  failDeletes = 0;
  deleteCalls = 0;
  async delete(keys: string | string[]) {
    this.deleteCalls++;
    if (this.failDeletes > 0) {
      this.failDeletes--;
      throw new Error("R2 unavailable");
    }
    return super.delete(keys);
  }
  async list(opts: { prefix?: string; limit?: number }) {
    const all = [...this.objects.keys()].filter((k) => k.startsWith(opts.prefix ?? "")).sort();
    const limit = opts.limit ?? 1000;
    return { objects: all.slice(0, limit).map((key) => ({ key })), truncated: all.length > limit, delimitedPrefixes: [] };
  }
}

let db: TestD1;
let r2: ListingBucket;
let env: Env;
let waits: Promise<unknown>[];
let purgedShareJobs: string[];
const ctx = () =>
  ({ waitUntil: (p: Promise<unknown>) => waits.push(p), passThroughOnException() {} }) as unknown as ExecutionContext;

function ins(table: string, row: Record<string, unknown>) {
  const cols = Object.keys(row);
  db.query(
    `INSERT INTO "${table}" (${cols.map((c) => `"${c}"`).join(", ")}) VALUES (${cols.map(() => "?").join(", ")})`,
    ...cols.map((c) => row[c]),
  );
}

const now = new Date().toISOString();
const later = new Date(Date.now() + 86_400_000).toISOString();

function addUser(id: string, customer: string | null) {
  ins("user", {
    id, name: id, email: `${id}@test.local`, emailVerified: 1, createdAt: now, updatedAt: now,
    tester: 0, blocked: 0, role: "user", username: `${id}_handle`, stripeCustomerId: customer,
    signupCountry: "GB", signupVia: "web",
  });
  ins("session", { id: `sess-${id}`, expiresAt: later, token: `tok-${id}`, createdAt: now, updatedAt: now, userId: id });
  ins("account", { id: `acct-${id}`, accountId: `google-${id}`, providerId: "google", userId: id, createdAt: now, updatedAt: now });
}

function addVideo(uid: string, videoId: string, opts: { storageId?: string } = {}) {
  const key = opts.storageId ? `prefix/videos/${videoId}.mp4` : `videos/${videoId}.mp4`;
  ins("shared_videos", {
    video_id: videoId, uid, file_name: `${videoId}.mp4`, r2_key: key, url: `https://capturecat.so/share/${videoId}`,
    status: "ready", created_at: now, storage_id: opts.storageId ?? null, current_version: 2,
  });
  ins("video_versions", { version_id: `v1-${videoId}`, video_id: videoId, version_number: 1, r2_key: key, status: "ready", created_at: now, storage_id: opts.storageId ?? null });
  const v2 = opts.storageId ? `prefix/videos/${videoId}/v2.mp4` : `videos/${videoId}/v2.mp4`;
  ins("video_versions", { version_id: `v2-${videoId}`, video_id: videoId, version_number: 2, r2_key: v2, status: "ready", created_at: now, storage_id: opts.storageId ?? null });
  if (!opts.storageId) {
    r2.put(key, "mp4");
    r2.put(v2, "mp4 v2");
  }
  r2.put(`thumbs/${videoId}`, "jpg");
  for (const [i, sess] of ["s1", "s2"].entries()) {
    ins("video_views", { view_id: `view-${videoId}-${i}`, video_id: videoId, session_id: sess, created_at: now });
    ins("video_events", { event_id: `ev-${videoId}-${i}`, video_id: videoId, session_id: sess, type: "play", created_at: now });
    ins("video_reactions", { reaction_id: `re-${videoId}-${i}`, video_id: videoId, session_id: sess, emoji: "🎉", created_at: now });
  }
  ins("video_transcripts", { video_id: videoId, uid, segments_json: "[]", full_text: "hello", created_at: now });
}

function addProject(uid: string, id: string) {
  const base = `cloud-projects/${uid}/${id}`;
  ins("cloud_projects", { id, owner_uid: uid, name: `${id} project`, doc_r2_key: `${base}/doc/1-a.json`, created_at: now, updated_at: now });
  ins("cloud_project_objects", { project_id: id, sha256: `sha-${id}`, owner_uid: uid, bytes: 3, content_type: "video/mp4", r2_key: `${base}/objects/sha-${id}`, status: "ready", created_at: now });
  ins("cloud_project_files", { project_id: id, path: "recording.mp4", sha256: `sha-${id}`, bytes: 3, content_type: "video/mp4", r2_key: `${base}/objects/sha-${id}`, uploaded_at: now });
  ins("cloud_project_manifests", { project_id: id, manifest_sha: `man-${id}`, files_json: "[]", created_at: now });
  ins("cloud_project_manifest_objects", { project_id: id, manifest_sha: `man-${id}`, sha256: `sha-${id}` });
  ins("cloud_project_versions", {
    id: `ver-${id}`, project_id: id, seq: 1, first_revision: 1, revision: 1, doc_r2_key: `${base}/doc/0-z.json`,
    doc_bytes: 2, stored_bytes: 2, doc_sha256: "d", kind: "auto", opened_at: now, updated_at: now, actor_uid: uid,
  });
  r2.put(`${base}/doc/1-a.json`, "{}");
  r2.put(`${base}/doc/0-z.json`, "{}");
  r2.put(`${base}/objects/sha-${id}`, "mp4");
}

/** Alice owns a lot; Bob and Carol share content with her. */
function seed() {
  addUser(ALICE, "cus_alice");
  addUser(BOB, "cus_bob");
  addUser(CAROL, null);

  // --- share videos -------------------------------------------------------
  addVideo(ALICE, "vid-alice-1");
  // In Alice's OWN bucket: its bytes must never be touched (and are not in R2).
  ins("storage_buckets", {
    id: "bucket-alice", uid: ALICE, provider: "s3", endpoint: CUSTOMER_BUCKET_ENDPOINT, region: "us-east-1", bucket: "alice-bucket",
    path_prefix: "prefix/", access_key_id: "AKIAALICE", secret_ciphertext: "sealed", created_at: now, updated_at: now,
  });
  addVideo(ALICE, "vid-alice-own-bucket", { storageId: "bucket-alice" });
  addVideo(BOB, "vid-bob-1");

  // --- comments -----------------------------------------------------------
  // On Alice's video (all go with it), including Bob's.
  ins("video_comments", { comment_id: "cm-on-alice-by-bob", video_id: "vid-alice-1", author_name: "Bob", body: "nice", created_at: now, author_uid: BOB });
  ins("video_comments", { comment_id: "cm-on-alice-by-alice", video_id: "vid-alice-1", author_name: "Alice", body: "thanks", created_at: now, author_uid: ALICE });
  // On Bob's video: Alice's top-level with Bob's reply (redacted), Alice's
  // top-level without replies (deleted), Alice's reply to Bob (deleted),
  // Bob's own comment (kept), an anonymous comment (kept).
  ins("video_comments", { comment_id: "cm-replied", video_id: "vid-bob-1", author_name: "Alice", body: "alice's words", created_at: now, author_uid: ALICE, author_image: "https://img/alice.png", annotation_json: '{"x":1}' });
  ins("video_comments", { comment_id: "cm-bob-reply", video_id: "vid-bob-1", author_name: "Bob", body: "reply to her", created_at: now, author_uid: BOB, parent_id: "cm-replied" });
  ins("video_comments", { comment_id: "cm-alice-lonely", video_id: "vid-bob-1", author_name: "Alice", body: "alone", created_at: now, author_uid: ALICE });
  ins("video_comments", { comment_id: "cm-bob-top", video_id: "vid-bob-1", author_name: "Bob", body: "bob top", created_at: now, author_uid: BOB });
  ins("video_comments", { comment_id: "cm-alice-reply-to-bob", video_id: "vid-bob-1", author_name: "Alice", body: "alice reply", created_at: now, author_uid: ALICE, parent_id: "cm-bob-top" });
  ins("video_comments", { comment_id: "cm-anon", video_id: "vid-bob-1", author_name: "Guest", body: "anon", created_at: now });

  // --- playlists, reports, moderation ----------------------------------------
  ins("video_playlists", { playlist_id: "pl-alice", uid: ALICE, name: "Alice's", created_at: now });
  ins("playlist_videos", { playlist_id: "pl-alice", video_id: "vid-alice-1", created_at: now });
  ins("video_playlists", { playlist_id: "pl-bob", uid: BOB, name: "Bob's", created_at: now });
  ins("playlist_videos", { playlist_id: "pl-bob", video_id: "vid-bob-1", created_at: now });
  ins("video_reports", { id: "rep-filed-by-her", video_id: "vid-bob-1", reason: "spam", reporter_hash: "h1", reporter_uid: ALICE, created_at: now });
  ins("video_reports", { id: "rep-about-her-video", video_id: "vid-alice-1", reason: "spam", reporter_hash: "h2", reporter_uid: BOB, created_at: now });
  ins("moderation_actions", { id: "mod-1", video_id: "vid-alice-1", video_owner: ALICE, admin_uid: "admin", action: "restore", created_at: now });

  // --- cloud projects -------------------------------------------------------
  addProject(ALICE, "proj-alice");
  addProject(BOB, "proj-bob");
  // Alice edited Bob's project: his history stays, her id goes.
  db.query(`UPDATE cloud_projects SET updated_by = ? WHERE id = 'proj-bob'`, ALICE);
  db.query(`UPDATE cloud_project_versions SET actor_uid = ?, named_by = ? WHERE id = 'ver-proj-bob'`, ALICE, ALICE);
  // A presigned upload that never got a row — found by the prefix listing.
  r2.put(`cloud-projects/${ALICE}/proj-alice/objects/stray`, "x");

  // --- screenshots ---------------------------------------------------------
  ins("stored_objects", { r2_key: `screenshots/${ALICE}/abc.png`, uid: ALICE, kind: "screenshot", bytes: 3, created_at: now });
  r2.put(`screenshots/${ALICE}/abc.png`, "png");
  r2.put(`screenshots/${ALICE}/orphan`, "png");
  r2.put(`screenshots/${BOB}/bob.png`, "png");
  ins("screenshot_api_keys", { id: "sk-alice", user_id: ALICE, key_hash: "h", created_at: now });
  ins("screenshot_usage", { user_id: ALICE, yyyymm: "202611", count: 3 });

  // --- domains, attest ----------------------------------------------------
  ins("custom_domains", { domain: "videos.alice.example", uid: ALICE, verified: 1, created_at: now, cf_hostname_id: "cfh-alice" });
  ins("attest_keys", { key_id: "ak-alice", uid: ALICE, public_key: "pk", created_at: now });
  ins("attest_challenges", { uid: ALICE, nonce: "n", expires_at: 1 });
  ins("attest_exemptions", { uid: ALICE, reason: "r", created_at: now });

  // --- agents, OAuth, webhooks -------------------------------------------
  ins("agent_tokens", { id: "at-alice", user_id: ALICE, name: "Claude", token_hash: "h", token_prefix: "cc_pat_alice", scopes: "[]", created_at: now });
  ins("agent_audit_log", { id: "aud-alice", user_id: ALICE, token_id: "at-alice", tool: "list", ok: 1, at: now });
  ins("agent_approvals", { id: "appr-alice", user_id: ALICE, token_id: "at-alice", tool: "share", args_json: "{}", summary: "s", created_at: now, expires_at: later });
  ins("oauth_clients", { client_id: "client-shared", kind: "dcr", client_name: "Some MCP client", redirect_uris: "[]", grant_types: "[]", created_at: now });
  ins("oauth_grants", { id: "grant-alice", user_id: ALICE, client_id: "client-shared", client_name: "Some MCP client", scopes: "[]", resource: "r", created_at: now });
  ins("oauth_grants", { id: "grant-bob", user_id: BOB, client_id: "client-shared", client_name: "Some MCP client", scopes: "[]", resource: "r", created_at: now });
  ins("oauth_codes", { id: "code-alice", code_prefix: "cp-alice", code_hash: "h", client_id: "client-shared", user_id: ALICE, redirect_uri: "x", code_challenge: "c", scopes: "[]", resource: "r", created_at: now, expires_at: later });
  ins("oauth_refresh_tokens", { id: "rt-1", grant_id: "grant-alice", token_prefix: "rtp-1", token_hash: "h", scopes: "[]", created_at: now, expires_at: later });
  ins("oauth_refresh_tokens", { id: "rt-2", grant_id: "grant-bob", token_prefix: "rtp-2", token_hash: "h", scopes: "[]", created_at: now, expires_at: later });
  ins("webhook_endpoints", { id: "wh-alice", user_id: ALICE, url: "https://hooks.example/a", secret: "s", events: "[]", created_at: now, updated_at: now });
  ins("webhook_deliveries", { id: "whd-alice", endpoint_id: "wh-alice", user_id: ALICE, event: "video.ready", payload: "{}", created_at: now });

  // --- devices -------------------------------------------------------------
  ins("user_devices", { user_id: ALICE, device_id: "phone-alice", platform: "ios", name: "Alice's iPhone", created_at: now, updated_at: now, last_seen_at: now, apns_token: "ab".repeat(32), apns_env: "production" });
  ins("wireless_links", { user_id: ALICE, key_ciphertext: "sealed", key_id: "kid", created_at: now });
  ins("user_devices", { user_id: BOB, device_id: "phone-bob", platform: "ios", name: "Bob's iPhone", created_at: now, updated_at: now, last_seen_at: now });

  // --- billing -------------------------------------------------------------
  ins("subscription", { id: "subrow-alice", plan: "pro", referenceId: ALICE, stripeCustomerId: "cus_alice", stripeSubscriptionId: "sub_alice", status: "active", periodEnd: later });
  ins("plan_grants", { id: "grant-row-alice", user_id: ALICE, plan: "pro", stripe_subscription_id: "sub_alice_grant", granted_by: "admin", granted_at: now });
  stripe.subs.set("sub_alice", { id: "sub_alice", object: "subscription", customer: "cus_alice", status: "active", metadata: {} });
  stripe.subs.set("sub_alice_old", { id: "sub_alice_old", object: "subscription", customer: "cus_alice", status: "canceled", metadata: {} });
  stripe.subs.set("sub_alice_grant", { id: "sub_alice_grant", object: "subscription", customer: "cus_alice_comp", status: "active", metadata: {} });
  stripe.subs.set("sub_bob", { id: "sub_bob", object: "subscription", customer: "cus_bob", status: "active", metadata: {} });
  ins("subscription", { id: "subrow-bob", plan: "pro", referenceId: BOB, stripeCustomerId: "cus_bob", stripeSubscriptionId: "sub_bob", status: "active", periodEnd: later });

  // --- teams ---------------------------------------------------------------
  // Alice's solo team goes with her; in Bob's team she's only a member.
  ins("organization", { id: "org-alice-solo", name: "Alice Solo", slug: "alice-solo", createdAt: now, logo: "x" });
  ins("member", { id: "mem-1", organizationId: "org-alice-solo", userId: ALICE, role: "owner", createdAt: now });
  ins("invitation", { id: "inv-solo", organizationId: "org-alice-solo", email: "someone@test.local", status: "pending", expiresAt: later, createdAt: now, inviterId: ALICE });
  r2.put("org-logos/org-alice-solo", "png");
  ins("organization", { id: "org-bob", name: "Bob Co", slug: "bob-co", createdAt: now });
  ins("member", { id: "mem-2", organizationId: "org-bob", userId: BOB, role: "owner", createdAt: now });
  ins("member", { id: "mem-3", organizationId: "org-bob", userId: ALICE, role: "member", createdAt: now });
  ins("invitation", { id: "inv-to-alice", organizationId: "org-bob", email: "alice@test.local", status: "pending", expiresAt: later, createdAt: now, inviterId: BOB });
  r2.put("org-logos/org-bob", "png");

  ins("beta_signups", { id: "beta-alice", email: "Alice@Test.local", created_at: now });
  ins("beta_signups", { id: "beta-bob", email: "bob@test.local", created_at: now });
}

beforeEach(() => {
  db = createTestD1();
  r2 = new ListingBucket();
  waits = [];
  purgedShareJobs = [];
  stripe.subs.clear();
  stripe.fail = false;
  stripe.calls.length = 0;
  cacheDeletes.length = 0;
  env = {
    DB: db,
    R2: r2 as unknown as R2Bucket,
    SHARE_JOBS: { getByName: (name: string) => ({ purgeAll: async () => void purgedShareJobs.push(name) }) },
    BETTER_AUTH_URL: API,
    BETTER_AUTH_SECRET: "test-secret-test-secret-test-secret-00",
    STRIPE_SECRET_KEY: "sk_test_offline",
    STRIPE_WEBHOOK_SECRET: "whsec_offline",
  } as unknown as Env;
  seed();
});

function del(init: { as?: string | null; cookie?: string; origin?: string; authorization?: string; client?: string } = {}) {
  const headers: Record<string, string> = { "CF-Connecting-IP": "203.0.113.9" };
  const as = init.as === undefined ? ALICE : init.as;
  if (init.authorization) headers.Authorization = init.authorization;
  else if (as) headers.Authorization = `Bearer ${as}`;
  if (init.cookie) headers.Cookie = init.cookie;
  if (init.origin) headers.Origin = init.origin;
  if (init.client) headers["X-CC-Client"] = init.client;
  return worker.fetch(new Request(`${API}/api/me`, { method: "DELETE", headers }), env, ctx());
}

async function settle() {
  await Promise.all(waits);
  waits = [];
}

/** Every row in every table whose text mentions `needle`, as "table.column". */
function rowsMentioning(needle: string, ignore: string[] = []): string[] {
  const found: string[] = [];
  const tables = db.query<{ name: string }>(`SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'`);
  for (const { name } of tables) {
    for (const col of db.query<{ name: string }>(`PRAGMA table_info("${name}")`)) {
      const ref = `${name}.${col.name}`;
      if (ignore.includes(ref) || ignore.includes(name)) continue;
      const n = db.query<{ n: number }>(`SELECT COUNT(*) AS n FROM "${name}" WHERE lower(CAST("${col.name}" AS TEXT)) LIKE ?`, `%${needle}%`)[0].n;
      if (n > 0) found.push(`${ref} (${n})`);
    }
  }
  return found;
}

/** Every row (as "table JSON") with any column mentioning `needle`. */
function rowsInvolving(needle: string): string[] {
  const out: string[] = [];
  const tables = db.query<{ name: string }>(`SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'`);
  for (const { name } of tables) {
    for (const row of db.query<Record<string, unknown>>(`SELECT * FROM "${name}"`)) {
      const text = JSON.stringify(row);
      if (text.toLowerCase().includes(needle)) out.push(`${name} ${text}`);
    }
  }
  return out.sort();
}

const count = (sql: string, ...p: unknown[]) => (db.query<{ n: number }>(sql, ...p)[0]?.n ?? 0);
const stripeWrites = () => stripe.calls.filter((c) => c.method !== "GET").map((c) => `${c.method} ${new URL(c.url).pathname}`);

// ---------------------------------------------------------------------------

describe("DELETE /api/me", () => {
  it("deletes everything Alice owns, leaves Bob untouched, cancels Stripe, never touches her own bucket", async () => {
    // Every row of Bob's that does not involve Alice, byte for byte.
    const bobBefore = rowsInvolving("bob").filter((r) => !r.includes("alice"));
    const bobKeysBefore = [...r2.objects.keys()].filter((k) => k.includes("bob")).sort();
    // The scan below is not vacuous: before deletion it finds her in ~40
    // table columns (every table the fixture seeds).
    const SCAN_IGNORE = ["account_deletions.user_id", "moderation_actions", "rate_limits", "video_reports.video_id"];
    expect(rowsMentioning("alice", SCAN_IGNORE).length).toBeGreaterThan(40);

    const res = await del({ client: "ios" });
    const body = (await res.json()) as Record<string, unknown>;
    expect(res.status, JSON.stringify(body)).toBe(200);
    expect(body).toMatchObject({ deleted: true, cancelledSubscriptions: 2, cleanup: "pending" });
    expect(String(body.jobId)).toMatch(/^del_/);

    // Stripe: both live subscriptions (the customer's and the grant D1 knew)
    // cancelled immediately; the already-cancelled one and Bob's untouched.
    expect(stripeWrites().sort()).toEqual(["DELETE /v1/subscriptions/sub_alice", "DELETE /v1/subscriptions/sub_alice_grant"]);
    expect(stripe.subs.get("sub_alice")!.status).toBe("canceled");
    expect(stripe.subs.get("sub_bob")!.status).toBe("active");

    // Rows: gone the moment the response is sent — before any background work.
    expect(count(`SELECT COUNT(*) AS n FROM "user" WHERE id = ?`, ALICE)).toBe(0);
    expect(count(`SELECT COUNT(*) AS n FROM "session" WHERE "userId" = ?`, ALICE)).toBe(0);
    expect(count(`SELECT COUNT(*) AS n FROM shared_videos WHERE uid = ?`, ALICE)).toBe(0);

    await settle();

    // THE structural check: no row anywhere still names Alice — her id, her
    // email, her handle, her videos, projects, devices, tokens. Allowed:
    // the audit row (pseudonymous id only), the admins' moderation trail and
    // the per-uid rate-limit counter (swept within a day).
    // (video_reports.video_id: a closed report keeps the id of the video it
    // was about — a random id in production, "vid-alice-1" only here.)
    expect(
      rowsMentioning("alice", ["account_deletions.user_id", "moderation_actions", "rate_limits", "video_reports.video_id"]),
    ).toEqual([]);
    // Nothing of Bob's that did not involve Alice changed.
    const bobAfter = new Set(rowsInvolving("bob"));
    expect(bobBefore.filter((r) => !bobAfter.has(r))).toEqual([]);
    expect(bobBefore.length).toBeGreaterThan(20);

    // R2: no object of Alice's left — the prefix listing caught the strays —
    // and every one of Bob's still there.
    expect([...r2.objects.keys()].filter((k) => k.includes("alice"))).toEqual([]);
    expect([...r2.objects.keys()].filter((k) => k.includes("bob")).sort()).toEqual(bobKeysBefore);

    // Her OWN bucket: never called. The only outbound calls were to Stripe.
    expect(stripe.calls.every((c) => new URL(c.url).hostname === "api.stripe.com")).toBe(true);
    expect(stripe.calls.some((c) => c.url.startsWith(CUSTOMER_BUCKET_ENDPOINT))).toBe(false);

    // Comments: Bob's thread under Alice's redacted comment survives.
    expect(db.query(`SELECT comment_id, author_name, body, author_uid, author_image, annotation_json FROM video_comments WHERE video_id = 'vid-bob-1' ORDER BY comment_id`)).toEqual([
      { comment_id: "cm-anon", author_name: "Guest", body: "anon", author_uid: null, author_image: null, annotation_json: null },
      { comment_id: "cm-bob-reply", author_name: "Bob", body: "reply to her", author_uid: BOB, author_image: null, annotation_json: null },
      { comment_id: "cm-bob-top", author_name: "Bob", body: "bob top", author_uid: BOB, author_image: null, annotation_json: null },
      { comment_id: "cm-replied", author_name: "Deleted account", body: "This comment was deleted.", author_uid: null, author_image: null, annotation_json: null },
    ]);

    // Teams: the solo team is gone; Bob's team lost only Alice.
    expect(count(`SELECT COUNT(*) AS n FROM "organization" WHERE id = 'org-alice-solo'`)).toBe(0);
    expect(db.query(`SELECT "userId" FROM "member" WHERE "organizationId" = 'org-bob'`)).toEqual([{ userId: BOB }]);

    // Shared things that are not hers stay: the OAuth client registration,
    // Bob's grant + refresh token, Bob's project history (her id cleared).
    expect(count(`SELECT COUNT(*) AS n FROM oauth_clients`)).toBe(1);
    expect(db.query(`SELECT id FROM oauth_refresh_tokens`)).toEqual([{ id: "rt-2" }]);
    expect(db.query(`SELECT actor_uid, named_by FROM cloud_project_versions WHERE id = 'ver-proj-bob'`)).toEqual([{ actor_uid: null, named_by: null }]);
    // Reports: hers anonymised, the open one against her video closed.
    expect(db.query(`SELECT id, reporter_uid, resolution FROM video_reports ORDER BY id`)).toEqual([
      { id: "rep-about-her-video", reporter_uid: BOB, resolution: "account_deleted" },
      { id: "rep-filed-by-her", reporter_uid: null, resolution: null },
    ]);

    // Background state: queue drained, audit row done, outside state purged.
    expect(count(`SELECT COUNT(*) AS n FROM account_deletion_objects`)).toBe(0);
    const [audit] = db.query<Record<string, unknown>>(`SELECT * FROM account_deletions`);
    expect(audit).toMatchObject({ user_id: ALICE, client: "ios", status: "done", cancelled_subscriptions: 2 });
    expect(audit.email_hmac).toMatch(/^[0-9a-f]{64}$/);
    expect(JSON.stringify(audit)).not.toContain("alice@test.local");
    expect(JSON.parse(String(audit.counts_json))).toMatchObject({ videos: 2, projects: 1, comments: 4, devices: 1, teams: 1 });
    expect(purgedShareJobs).toEqual([ALICE]);
    expect(cacheDeletes).toEqual(
      expect.arrayContaining([
        "https://meta.internal/video/vid-alice-1",
        "https://meta.internal/video/vid-alice-own-bucket",
        "https://meta.internal/profile/alice_handle",
      ]),
    );
  });

  it("is idempotent: the retry after a lost response is a 401, and a raced repeat changes nothing", async () => {
    expect((await del()).status).toBe(200);
    await settle();
    const writes = stripeWrites().length;

    // The session died with the account.
    const again = await del();
    expect(again.status).toBe(401);
    expect(stripeWrites().length).toBe(writes);

    // A repeat that got past auth before the first finished: harmless, and
    // the original audit row is kept.
    const [first] = db.query<{ id: string }>(`SELECT id FROM account_deletions`);
    const repeat = await deleteAccountRows(env, { id: ALICE, email: "alice@test.local" }, { client: "web", cancelledSubscriptions: 0 });
    expect(repeat).toMatchObject({ jobId: first.id, created: false });
    expect(db.query(`SELECT id, client FROM account_deletions`)).toEqual([{ id: first.id, client: "app" }]);
    expect(await processAccountDeletions(env)).toMatchObject({ accounts: 0 });
    expect(count(`SELECT COUNT(*) AS n FROM "user" WHERE id = ?`, BOB)).toBe(1);
  });

  it("requires a session; agent tokens are refused", async () => {
    // No credentials at all: a non-GET without Origin is the CSRF gate's 403.
    expect((await del({ as: null })).status).toBe(403);
    expect((await del({ authorization: "Bearer not-a-session" })).status).toBe(401);
    const agent = await del({ authorization: `Bearer cc_pat_${"a".repeat(40)}` });
    expect(agent.status).toBe(403);
    expect(await agent.json()).toMatchObject({ code: "agent_token_forbidden" });
    expect(count(`SELECT COUNT(*) AS n FROM "user" WHERE id = ?`, ALICE)).toBe(1);
    expect(stripe.calls).toEqual([]);
  });

  it("cookie sessions need a trusted Origin (CSRF); with one, the web can delete", async () => {
    const noOrigin = await del({ as: null, cookie: `cc_session=${ALICE}` });
    expect(noOrigin.status).toBe(403);
    const evil = await del({ as: null, cookie: `cc_session=${ALICE}`, origin: "https://evil.example" });
    expect(evil.status).toBe(403);
    expect(count(`SELECT COUNT(*) AS n FROM "user" WHERE id = ?`, ALICE)).toBe(1);

    const ok = await del({ as: null, cookie: `cc_session=${ALICE}`, origin: WEB });
    expect(ok.status).toBe(200);
    expect(count(`SELECT COUNT(*) AS n FROM "user" WHERE id = ?`, ALICE)).toBe(0);
    await settle();
    expect(db.query(`SELECT client FROM account_deletions`)).toEqual([{ client: "web" }]);
  });

  it("refuses to orphan a team: an owner with other members and no co-owner gets 409 and nothing changes", async () => {
    ins("organization", { id: "org-alice-team", name: "Acme", slug: "acme", createdAt: now });
    ins("member", { id: "mem-4", organizationId: "org-alice-team", userId: ALICE, role: "owner", createdAt: now });
    ins("member", { id: "mem-5", organizationId: "org-alice-team", userId: BOB, role: "member", createdAt: now });
    ins("member", { id: "mem-6", organizationId: "org-alice-team", userId: CAROL, role: "admin", createdAt: now });

    const res = await del();
    expect(res.status).toBe(409);
    const body = (await res.json()) as Record<string, unknown>;
    expect(body).toMatchObject({ code: "team_has_members", team: { id: "org-alice-team", name: "Acme", otherMembers: 2 } });
    expect(String(body.error)).toContain("Acme");
    expect(stripe.calls).toEqual([]);
    expect(count(`SELECT COUNT(*) AS n FROM "user" WHERE id = ?`, ALICE)).toBe(1);
    expect(count(`SELECT COUNT(*) AS n FROM account_deletions`)).toBe(0);

    // With a co-owner the team survives her leaving.
    db.query(`UPDATE "member" SET role = 'admin,owner' WHERE id = 'mem-6'`);
    expect((await del()).status).toBe(200);
    expect(db.query(`SELECT "userId" FROM "member" WHERE "organizationId" = 'org-alice-team' ORDER BY "userId"`)).toEqual([
      { userId: BOB },
      { userId: CAROL },
    ]);
    await settle();
  });

  it("when Stripe cannot cancel, nothing is deleted (502)", async () => {
    stripe.fail = true;
    const res = await del();
    expect(res.status).toBe(502);
    expect(await res.json()).toMatchObject({ code: "billing_unavailable" });
    expect(count(`SELECT COUNT(*) AS n FROM "user" WHERE id = ?`, ALICE)).toBe(1);
    expect(count(`SELECT COUNT(*) AS n FROM shared_videos WHERE uid = ?`, ALICE)).toBe(2);
    expect(count(`SELECT COUNT(*) AS n FROM account_deletions`)).toBe(0);
    expect(r2.objects.has("videos/vid-alice-1.mp4")).toBe(true);

    stripe.fail = false;
    expect((await del()).status).toBe(200);
    await settle();
  });

  it("a user with no Stripe customer and no subscription deletes without any Stripe call", async () => {
    const res = await del({ as: CAROL });
    expect(res.status).toBe(200);
    expect(await res.json()).toMatchObject({ cancelledSubscriptions: 0 });
    expect(stripe.calls).toEqual([]);
    await settle();
    expect(rowsMentioning("carol", ["account_deletions.user_id", "rate_limits"])).toEqual([]);
  });

  it("a failing batch (e.g. a Worker deployed ahead of 0043) deletes nothing and says so", async () => {
    db.query(`DROP TABLE account_deletion_objects`);
    const res = await del();
    expect(res.status).toBe(500);
    expect(await res.json()).toMatchObject({ code: "delete_failed", error: expect.stringContaining("subscription was cancelled") });
    // All-or-nothing: every row is still there.
    expect(count(`SELECT COUNT(*) AS n FROM "user" WHERE id = ?`, ALICE)).toBe(1);
    expect(count(`SELECT COUNT(*) AS n FROM "session" WHERE "userId" = ?`, ALICE)).toBe(1);
    expect(count(`SELECT COUNT(*) AS n FROM shared_videos WHERE uid = ?`, ALICE)).toBe(2);
    expect(count(`SELECT COUNT(*) AS n FROM account_deletions`)).toBe(0);
  });
});

describe("background cleanup", () => {
  it("survives R2 failures and interrupted runs; the hourly sweep finishes the job", async () => {
    // Lots of strays under one prefix: more than one 1000-key page.
    for (let i = 0; i < 2500; i++) r2.put(`cloud-projects/${ALICE}/proj-alice/objects/bulk-${i}`, "x");
    // R2 is down for the request's own background run: every delete fails.
    r2.failDeletes = 1_000;
    const res = await del();
    expect(res.status).toBe(200);
    await settle();
    expect(db.query(`SELECT status FROM account_deletions`)).toEqual([{ status: "pending" }]);
    expect(count(`SELECT COUNT(*) AS n FROM account_deletion_objects WHERE kind IN ('key', 'prefix') AND attempts = 1`)).toBeGreaterThan(0);
    // ...and the outside state that did not need R2 is already done.
    expect(count(`SELECT COUNT(*) AS n FROM account_deletion_objects WHERE kind NOT IN ('key', 'prefix')`)).toBe(0);
    expect(r2.objects.has("videos/vid-alice-1.mp4")).toBe(true);

    // R2 is back, but the next run is cut short after two passes.
    r2.failDeletes = 0;
    let t = 0;
    const tick = () => (t += 1);
    await processAccountDeletions(env, { userId: ALICE, budgetMs: 3, now: tick });
    expect(count(`SELECT COUNT(*) AS n FROM account_deletion_objects`)).toBeGreaterThan(0);
    expect(db.query(`SELECT status FROM account_deletions`)).toEqual([{ status: "pending" }]);
    // Already gone from D1, so nothing is reachable meanwhile.
    expect(count(`SELECT COUNT(*) AS n FROM shared_videos WHERE uid = ?`, ALICE)).toBe(0);

    // The hourly cron's sweep picks it up and drains it.
    const sweepWaits: Promise<unknown>[] = [];
    await worker.scheduled!(
      { cron: "17 * * * *", scheduledTime: Date.now(), noRetry() {} } as unknown as ScheduledController,
      env,
      { waitUntil: (p: Promise<unknown>) => sweepWaits.push(p), passThroughOnException() {} } as unknown as ExecutionContext,
    );
    await Promise.all(sweepWaits);
    await Promise.all(waits);

    expect(count(`SELECT COUNT(*) AS n FROM account_deletion_objects`)).toBe(0);
    expect(db.query(`SELECT status FROM account_deletions`)).toEqual([{ status: "done" }]);
    expect([...r2.objects.keys()].filter((k) => k.includes("alice"))).toEqual([]);
    expect(r2.objects.has(`cloud-projects/${BOB}/proj-bob/objects/sha-proj-bob`)).toBe(true);
  });

  it("a failing item is retried once per run, not burned in a loop", async () => {
    // Only the custom hostname is outstanding, and Cloudflare is down.
    env.CF_ZONE_ID = "zone";
    env.CF_SAAS_API_TOKEN = "token";
    db.query(
      `INSERT INTO account_deletions (id, user_id, client, requested_at, status) VALUES ('del_x', 'gone-user', 'app', ?, 'pending')`,
      now,
    );
    db.query(`INSERT INTO account_deletion_objects (user_id, kind, value) VALUES ('gone-user', 'cf_hostname', 'cfh-1')`);
    await processAccountDeletions(env);
    await processAccountDeletions(env);
    expect(db.query(`SELECT attempts FROM account_deletion_objects`)).toEqual([{ attempts: 2 }]);
    expect(db.query(`SELECT status FROM account_deletions WHERE id = 'del_x'`)).toEqual([{ status: "pending" }]);
  });
});
