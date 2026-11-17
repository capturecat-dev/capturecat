/**
 * Deleting an account for good — DELETE /api/me (routes/account-delete.ts).
 * App Store Guideline 5.1.1(v); the privacy policy's "if you close your
 * account we delete your personal data".
 *
 * THREE PHASES
 *
 *  1. Checks, before anything changes:
 *     - a team the user OWNS that has other members and no other owner is a
 *       409 (`team_has_members`): deleting it would take the other members'
 *       shared library with it, and handing it to someone is a choice only
 *       the owner can make (Team page → make another member an owner, or
 *       remove them). A team whose only member is the user goes with them.
 *     - Stripe: every live subscription is cancelled NOW (not at period
 *       end). Stripe is asked directly — the customer's subscriptions, plus
 *       every subscription id D1 knows — so a checkout whose webhook has not
 *       landed yet is cancelled too. Any Stripe failure is a 502 and NOTHING
 *       is deleted: an account must never be gone while its card is still
 *       being charged. The Stripe customer itself is kept — Stripe holds the
 *       invoices we must keep for tax (privacy policy §6).
 *
 *  2. One D1 batch (a transaction — all or nothing): first copy every R2 key
 *     the user's rows point at into `account_deletion_objects`, then delete
 *     every row the user owns, children before parents, ending with the
 *     `user` row (its FKs cascade the rest). From the end of this batch the
 *     account does not exist: every session is gone, shares 404, agent and
 *     OAuth tokens are dead, webhooks will not fire, pushes cannot be sent.
 *
 *  3. Background (waitUntil right after the response, then the hourly cron
 *     until done): remove the queued R2 objects (batched 1000 per call;
 *     prefixes listed page by page), Cloudflare custom hostnames, metadata
 *     cache entries and the ShareJobsDO rows. Each finished item is deleted
 *     from the queue, so an interrupted run resumes where it stopped.
 *
 * NEVER TOUCHED
 *  - Objects in a customer's OWN bucket (storage_buckets, 0029). Only the
 *    credentials row is deleted; this module never calls deleteStoredObject
 *    and only ever passes CaptureCat R2 keys (rows with storage_id IS NULL,
 *    or our own fixed prefixes) to the R2 binding.
 *  - Other people's content: comments others wrote on the user's videos go
 *    with those videos, but the user's comments on OTHER people's videos are
 *    deleted — or, when someone replied, redacted in place ("Deleted
 *    account" / "This comment was deleted.") so the replies keep their
 *    thread. Other people's cloud projects that name the user as an editor
 *    keep their history, with the user's id cleared.
 *  - Admin records: moderation_actions (the admins' audit trail) stays;
 *    open reports against the user's videos are closed as 'account_deleted'.
 */
import Stripe from "stripe";
import type { Env } from "../types";
import { createStripeClient } from "./stripe";
import { deleteCustomHostname, saasConfigured } from "./cloudflare-saas";
import { generateId } from "./id";

// ---------------------------------------------------------------------------
// Phase 1 — checks
// ---------------------------------------------------------------------------

export interface TeamBlock {
  id: string;
  name: string;
  otherMembers: number;
}

/** Better Auth stores a member's roles comma-separated ("owner,admin"). */
const IS_OWNER = `(',' || REPLACE(m.role, ' ', '') || ',') LIKE '%,owner,%'`;

/**
 * A team the user owns that would be left with members and no owner, or
 * null. (Teams where someone else is also an owner simply lose a member.)
 */
export async function blockingTeam(db: D1Database, uid: string): Promise<TeamBlock | null> {
  const row = await db
    .prepare(
      `SELECT o.id, o.name,
              (SELECT COUNT(*) FROM "member" x WHERE x."organizationId" = o.id AND x."userId" != ?1) AS others,
              (SELECT COUNT(*) FROM "member" x
                 WHERE x."organizationId" = o.id AND x."userId" != ?1
                   AND (',' || REPLACE(x.role, ' ', '') || ',') LIKE '%,owner,%') AS other_owners
         FROM "member" m JOIN "organization" o ON o.id = m."organizationId"
        WHERE m."userId" = ?1 AND ${IS_OWNER}
        ORDER BY o."createdAt"`,
    )
    .bind(uid)
    .all<{ id: string; name: string; others: number; other_owners: number }>();
  const blocked = (row.results ?? []).find((r) => r.others > 0 && r.other_owners === 0);
  return blocked ? { id: blocked.id, name: blocked.name, otherMembers: blocked.others } : null;
}

/** Subscriptions that still bill or grant access. */
const ENDED = new Set(["canceled", "incomplete_expired"]);

/**
 * Cancel every live subscription of this user, immediately. Returns the ids
 * cancelled. Throws on any Stripe failure except "no such subscription /
 * customer" (already gone is the outcome we want).
 */
export async function cancelSubscriptionsNow(
  env: Env,
  user: { id: string; stripeCustomerId: string | null },
  stripe: Stripe = createStripeClient(env),
): Promise<string[]> {
  const ids = new Set<string>();
  const { results } = await env.DB
    .prepare(
      `SELECT "stripeSubscriptionId" AS id FROM "subscription"
        WHERE "referenceId" = ? AND "stripeSubscriptionId" IS NOT NULL
          AND "status" NOT IN ('canceled', 'incomplete_expired')
       UNION
       SELECT stripe_subscription_id AS id FROM plan_grants WHERE user_id = ? AND revoked_at IS NULL`,
    )
    .bind(user.id, user.id)
    .all<{ id: string }>();
  for (const r of results ?? []) ids.add(r.id);

  const live: string[] = [];
  if (user.stripeCustomerId) {
    try {
      for await (const sub of stripe.subscriptions.list({ customer: user.stripeCustomerId, status: "all", limit: 100 })) {
        ids.delete(sub.id);
        if (!ENDED.has(sub.status)) live.push(sub.id);
      }
    } catch (err) {
      if (!isMissing(err)) throw err;
    }
  }
  // Ids D1 knows that the customer listing did not return (another customer
  // object, a grant): ask Stripe about each one.
  for (const id of ids) {
    try {
      const sub = await stripe.subscriptions.retrieve(id);
      if (!ENDED.has(sub.status)) live.push(sub.id);
    } catch (err) {
      if (!isMissing(err)) throw err;
    }
  }

  const cancelled: string[] = [];
  for (const id of live) {
    try {
      await stripe.subscriptions.cancel(
        id,
        { cancellation_details: { comment: "The customer deleted their CaptureCat account." } },
        { idempotencyKey: `capturecat-account-delete-${id}` },
      );
      cancelled.push(id);
    } catch (err) {
      if (!isMissing(err)) throw err;
    }
  }
  return cancelled;
}

function isMissing(err: unknown): boolean {
  return (err as { code?: string })?.code === "resource_missing";
}

// ---------------------------------------------------------------------------
// Phase 2 — the batch
// ---------------------------------------------------------------------------

/** Where the request came from, for the audit row. */
export type DeletionClient = "ios" | "mac" | "web" | "app";

export interface DeletionResult {
  jobId: string;
  /** False when this account had already been deleted (a raced repeat). */
  created: boolean;
  counts: Record<string, number>;
}

const COMMENT_REDACTED_NAME = "Deleted account";
const COMMENT_REDACTED_BODY = "This comment was deleted.";

/** SQL fragments over ?1 = the user id. */
const MY_VIDEOS = `SELECT video_id FROM shared_videos WHERE uid = ?1`;
const MY_PROJECTS = `SELECT id FROM cloud_projects WHERE owner_uid = ?1`;
const MY_PLAYLISTS = `SELECT playlist_id FROM video_playlists WHERE uid = ?1`;
const MY_GRANTS = `SELECT id FROM oauth_grants WHERE user_id = ?1`;
/** Teams whose only member is the user: they go with the account. */
const MY_SOLO_TEAMS = `SELECT m."organizationId" FROM "member" m
  WHERE m."userId" = ?1
    AND NOT EXISTS (SELECT 1 FROM "member" o WHERE o."organizationId" = m."organizationId" AND o."userId" != ?1)`;

export async function emailHmac(secret: string | undefined, email: string | null): Promise<string | null> {
  if (!email || !secret) return null;
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`account-deletion:${email.trim().toLowerCase()}`));
  return [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** What the user has, for the audit row (counts only — no names, no ids). */
async function countOwned(db: D1Database, uid: string): Promise<Record<string, number>> {
  const row = await db
    .prepare(
      `SELECT
         (SELECT COUNT(*) FROM shared_videos WHERE uid = ?1) AS videos,
         (SELECT COUNT(*) FROM cloud_projects WHERE owner_uid = ?1) AS projects,
         (SELECT COUNT(*) FROM video_comments WHERE author_uid = ?1) AS comments,
         (SELECT COUNT(*) FROM user_devices WHERE user_id = ?1) AS devices,
         (SELECT COUNT(*) FROM agent_tokens WHERE user_id = ?1) AS agent_tokens,
         (SELECT COUNT(*) FROM oauth_grants WHERE user_id = ?1) AS oauth_grants,
         (SELECT COUNT(*) FROM webhook_endpoints WHERE user_id = ?1) AS webhooks,
         (SELECT COUNT(*) FROM storage_buckets WHERE uid = ?1) AS storage_buckets,
         (SELECT COUNT(*) FROM custom_domains WHERE uid = ?1) AS custom_domains,
         (SELECT COUNT(*) FROM (${MY_SOLO_TEAMS})) AS teams`,
    )
    .bind(uid)
    .first<Record<string, number>>();
  return { ...(row ?? {}) };
}

/**
 * Phase 2. Deletes every D1 row the user owns, in one transaction, after
 * queueing the R2 objects (and other outside state) for phase 3. Safe to run
 * twice: a repeat finds nothing left and keeps the first audit row.
 */
export async function deleteAccountRows(
  env: Env,
  user: { id: string; email: string | null; username?: string | null },
  meta: { client: DeletionClient; cancelledSubscriptions: number },
): Promise<DeletionResult> {
  const db = env.DB;
  const uid = user.id;
  const now = new Date().toISOString();
  const counts = await countOwned(db, uid);
  const jobId = `del_${generateId(20)}`;
  const hmac = await emailHmac(env.BETTER_AUTH_SECRET, user.email);
  const email = user.email ?? "";

  const q = (sql: string, ...extra: unknown[]) => db.prepare(sql).bind(uid, ...extra);
  // Queued only while the user row exists: a raced repeat (the user already
  // gone) must not re-queue prefixes for a job that has finished.
  const queue = (kind: string, select: string, ...extra: unknown[]) =>
    q(`INSERT OR IGNORE INTO account_deletion_objects (user_id, kind, value)
       SELECT ?1, '${kind}', v FROM (${select})
        WHERE v IS NOT NULL AND v != ''
          AND EXISTS (SELECT 1 FROM "user" WHERE id = ?1)`, ...extra);

  const statements: D1PreparedStatement[] = [
    // --- the audit row / job (first, so a raced repeat keeps the original) ---
    q(
      `INSERT OR IGNORE INTO account_deletions (id, user_id, email_hmac, client, requested_at, cancelled_subscriptions, counts_json, status)
       VALUES (?2, ?1, ?3, ?4, ?5, ?6, ?7, 'pending')`,
      jobId, hmac, meta.client, now, meta.cancelledSubscriptions, JSON.stringify(counts),
    ),

    // --- phase-3 queue: CaptureCat R2 only (never storage_id rows) ---------
    // Share videos: the current file, every version, the legacy key, the
    // per-video version folder and the poster.
    queue("key", `SELECT r2_key AS v FROM shared_videos WHERE uid = ?1 AND storage_id IS NULL`),
    queue(
      "key",
      `SELECT vv.r2_key AS v FROM video_versions vv JOIN shared_videos sv ON sv.video_id = vv.video_id
        WHERE sv.uid = ?1 AND vv.storage_id IS NULL`,
    ),
    queue("key", `SELECT 'videos/' || video_id || '.mp4' AS v FROM shared_videos WHERE uid = ?1`),
    queue("prefix", `SELECT 'videos/' || video_id || '/' AS v FROM shared_videos WHERE uid = ?1`),
    queue("key", `SELECT 'thumbs/' || video_id AS v FROM shared_videos WHERE uid = ?1`),
    queue("cache_video", `SELECT video_id AS v FROM shared_videos WHERE uid = ?1`),
    // Screenshots (0016/0025) and everything under the user's own prefixes —
    // the prefixes also catch presigned uploads that never got a row.
    queue("key", `SELECT r2_key AS v FROM stored_objects WHERE uid = ?1`),
    queue("prefix", `SELECT 'screenshots/' || ?1 || '/' AS v`),
    // Cloud projects (0026/0027): media, current documents, every version's
    // snapshot, and the owner's prefix.
    queue("key", `SELECT r2_key AS v FROM cloud_project_objects WHERE owner_uid = ?1 OR project_id IN (${MY_PROJECTS})`),
    queue("key", `SELECT r2_key AS v FROM cloud_project_files WHERE project_id IN (${MY_PROJECTS})`),
    queue("key", `SELECT doc_r2_key AS v FROM cloud_projects WHERE owner_uid = ?1`),
    queue("key", `SELECT doc_r2_key AS v FROM cloud_project_versions WHERE project_id IN (${MY_PROJECTS})`),
    queue("prefix", `SELECT 'cloud-projects/' || ?1 || '/' AS v`),
    // Logos of the teams that go with the account.
    queue("key", `SELECT 'org-logos/' || t."organizationId" AS v FROM (${MY_SOLO_TEAMS}) t`),
    // Outside R2: Cloudflare custom hostnames, the profile cache, share jobs.
    queue("cf_hostname", `SELECT cf_hostname_id AS v FROM custom_domains WHERE uid = ?1`),
    queue("cache_profile", `SELECT username AS v FROM "user" WHERE id = ?1`),
    queue("share_jobs", `SELECT ?1 AS v`),

    // --- comments ---------------------------------------------------------
    // Everyone's comments on the user's videos go with the videos.
    q(`DELETE FROM video_comments WHERE video_id IN (${MY_VIDEOS})`),
    // The user's replies elsewhere, then their top-level comments that others
    // replied to are redacted in place (the thread stays readable), then the
    // rest of what they wrote.
    q(`DELETE FROM video_comments WHERE author_uid = ?1 AND parent_id IS NOT NULL`),
    q(
      `UPDATE video_comments
          SET author_name = ?2, body = ?3, annotation_json = NULL, author_uid = NULL, author_image = NULL
        WHERE author_uid = ?1
          AND EXISTS (SELECT 1 FROM video_comments r WHERE r.parent_id = video_comments.comment_id)`,
      COMMENT_REDACTED_NAME, COMMENT_REDACTED_BODY,
    ),
    q(`DELETE FROM video_comments WHERE author_uid = ?1`),

    // --- share videos and everything hanging off them ---------------------
    q(`DELETE FROM video_views WHERE video_id IN (${MY_VIDEOS})`),
    q(`DELETE FROM video_events WHERE video_id IN (${MY_VIDEOS})`),
    q(`DELETE FROM video_reactions WHERE video_id IN (${MY_VIDEOS})`),
    q(`DELETE FROM video_transcripts WHERE uid = ?1 OR video_id IN (${MY_VIDEOS})`),
    q(`DELETE FROM playlist_videos WHERE video_id IN (${MY_VIDEOS}) OR playlist_id IN (${MY_PLAYLISTS})`),
    q(`DELETE FROM video_playlists WHERE uid = ?1`),
    q(`DELETE FROM video_versions WHERE video_id IN (${MY_VIDEOS})`),
    // Reports the user filed keep their (hashed) reporter, not the account.
    q(`UPDATE video_reports SET reporter_uid = NULL WHERE reporter_uid = ?1`),
    // Open reports against the user's videos: the video is gone.
    q(
      `UPDATE video_reports SET resolved_at = ?2, resolution = 'account_deleted'
        WHERE resolved_at IS NULL AND video_id IN (${MY_VIDEOS})`,
      now,
    ),
    q(`DELETE FROM shared_videos WHERE uid = ?1`),

    // --- cloud projects + history -----------------------------------------
    q(`DELETE FROM cloud_project_versions WHERE project_id IN (${MY_PROJECTS})`),
    q(`DELETE FROM cloud_project_manifest_objects WHERE project_id IN (${MY_PROJECTS})`),
    q(`DELETE FROM cloud_project_manifests WHERE project_id IN (${MY_PROJECTS})`),
    q(`DELETE FROM cloud_project_files WHERE project_id IN (${MY_PROJECTS})`),
    q(`DELETE FROM cloud_project_objects WHERE owner_uid = ?1 OR project_id IN (${MY_PROJECTS})`),
    q(`DELETE FROM cloud_projects WHERE owner_uid = ?1`),
    // Other people's projects the user edited: history stays, the id goes.
    q(`UPDATE cloud_projects SET updated_by = NULL WHERE updated_by = ?1`),
    q(`UPDATE cloud_project_versions SET actor_uid = NULL WHERE actor_uid = ?1`),
    q(`UPDATE cloud_project_versions SET named_by = NULL WHERE named_by = ?1`),

    // --- teams the user was the only member of ----------------------------
    // (A team with other members only loses this member — the member row
    // cascades from the user row. One with members and no other owner never
    // gets here: the route refuses it with team_has_members.)
    q(`UPDATE shared_videos SET org_id = NULL WHERE org_id IN (${MY_SOLO_TEAMS})`),
    q(`UPDATE cloud_projects SET org_id = NULL WHERE org_id IN (${MY_SOLO_TEAMS})`),
    q(`UPDATE video_playlists SET org_id = NULL WHERE org_id IN (${MY_SOLO_TEAMS})`),
    q(`UPDATE "session" SET "activeOrganizationId" = NULL WHERE "activeOrganizationId" IN (${MY_SOLO_TEAMS})`),
    q(`DELETE FROM "ssoProvider" WHERE "organizationId" IN (${MY_SOLO_TEAMS}) OR "userId" = ?1`),
    q(`DELETE FROM "invitation" WHERE "organizationId" IN (${MY_SOLO_TEAMS})`),
    q(`DELETE FROM "organization" WHERE id IN (${MY_SOLO_TEAMS})`),
    // Invitations the user sent (other teams) and ones addressed to them.
    q(`DELETE FROM "invitation" WHERE "inviterId" = ?1 OR (?2 != '' AND lower("email") = lower(?2))`, email),
    q(`DELETE FROM "member" WHERE "userId" = ?1`),

    // --- storage, domains, screenshots -----------------------------------
    q(`DELETE FROM stored_objects WHERE uid = ?1`),
    q(`DELETE FROM custom_domains WHERE uid = ?1`),
    // Bring-your-own buckets: forget the credentials. The files in the
    // customer's bucket are theirs and are never deleted.
    q(`DELETE FROM storage_buckets WHERE uid = ?1`),
    q(`DELETE FROM screenshot_api_keys WHERE user_id = ?1`),
    q(`DELETE FROM screenshot_usage WHERE user_id = ?1`),

    // --- agents, OAuth, webhooks ------------------------------------------
    q(`DELETE FROM oauth_refresh_tokens WHERE grant_id IN (${MY_GRANTS})`),
    q(`DELETE FROM oauth_codes WHERE user_id = ?1`),
    q(`DELETE FROM oauth_grants WHERE user_id = ?1`),
    q(`DELETE FROM agent_approvals WHERE user_id = ?1`),
    q(`DELETE FROM agent_audit_log WHERE user_id = ?1`),
    q(`DELETE FROM agent_tokens WHERE user_id = ?1`),
    q(`DELETE FROM webhook_deliveries WHERE user_id = ?1`),
    q(`DELETE FROM webhook_endpoints WHERE user_id = ?1`),

    // --- devices, App Attest ---------------------------------------------
    q(`DELETE FROM user_devices WHERE user_id = ?1`),
    q(`DELETE FROM wireless_links WHERE user_id = ?1`),
    q(`DELETE FROM attest_keys WHERE uid = ?1`),
    q(`DELETE FROM attest_challenges WHERE uid = ?1`),
    q(`DELETE FROM attest_exemptions WHERE uid = ?1`),

    // --- billing (Stripe already cancelled in phase 1) --------------------
    q(`DELETE FROM plan_grants WHERE user_id = ?1`),
    q(`DELETE FROM "subscription" WHERE "referenceId" = ?1`),

    // --- the waitlist row for the same address (0015) ---------------------
    q(`DELETE FROM beta_signups WHERE ?2 != '' AND lower(email) = lower(?2)`, email),

    // --- identity, last ---------------------------------------------------
    q(`DELETE FROM "session" WHERE "userId" = ?1`),
    q(`DELETE FROM "account" WHERE "userId" = ?1`),
    q(`DELETE FROM "user" WHERE id = ?1`),
  ];

  await db.batch(statements);

  const row = await db
    .prepare(`SELECT id FROM account_deletions WHERE user_id = ?`)
    .bind(uid)
    .first<{ id: string }>();
  return { jobId: row?.id ?? jobId, created: row?.id === jobId, counts };
}

// ---------------------------------------------------------------------------
// Phase 3 — background cleanup
// ---------------------------------------------------------------------------

/** A failing outside call (Cloudflare API) is retried this many hourly runs. */
const MAX_ATTEMPTS = 48;
/** R2's batch delete takes up to 1000 keys. */
const R2_BATCH = 1000;

export interface CleanupReport {
  accounts: number;
  objectsDeleted: number;
  finished: number;
}

/**
 * Phase 3: work through the queue of pending deletions until it is empty or
 * the time budget runs out. Called with `userId` right after a deletion
 * (waitUntil) and without it from the hourly sweep. Every finished item is
 * removed from the queue as it completes, so a run cut short resumes.
 */
export async function processAccountDeletions(
  env: Env,
  opts: { userId?: string; budgetMs?: number; now?: () => number } = {},
): Promise<CleanupReport> {
  const clock = opts.now ?? Date.now;
  const deadline = clock() + (opts.budgetMs ?? 25_000);
  const report: CleanupReport = { accounts: 0, objectsDeleted: 0, finished: 0 };

  const pending = opts.userId
    ? await env.DB.prepare(`SELECT user_id FROM account_deletions WHERE user_id = ? AND status = 'pending'`)
        .bind(opts.userId)
        .all<{ user_id: string }>()
    : await env.DB.prepare(`SELECT user_id FROM account_deletions WHERE status = 'pending' ORDER BY requested_at LIMIT 20`)
        .all<{ user_id: string }>();

  for (const { user_id: uid } of pending.results ?? []) {
    if (clock() > deadline) break;
    report.accounts++;
    let drained = false;
    // Items that failed in THIS run are not retried until the next one, so a
    // short outage costs one attempt per run, not the whole allowance.
    const failedThisRun = new Set<string>();
    while (clock() <= deadline) {
      const { results } = await env.DB
        .prepare(
          `SELECT kind, value, attempts FROM account_deletion_objects
            WHERE user_id = ? AND attempts < ? ORDER BY attempts, kind, value LIMIT ?`,
        )
        .bind(uid, MAX_ATTEMPTS, R2_BATCH)
        .all<{ kind: string; value: string; attempts: number }>();
      const items = (results ?? []).filter((i) => !failedThisRun.has(`${i.kind}\n${i.value}`));
      if ((results ?? []).length === 0) {
        drained = true;
        break;
      }
      if (items.length === 0) break;
      const pass = await processItems(env, uid, items);
      report.objectsDeleted += pass.removed;
      for (const f of pass.failed) failedThisRun.add(f);
    }
    if (!drained) break;
    const left = await env.DB
      .prepare(`SELECT COUNT(*) AS n FROM account_deletion_objects WHERE user_id = ?`)
      .bind(uid)
      .first<{ n: number }>();
    if ((left?.n ?? 0) > 0) {
      // Only items that exhausted their attempts remain: give up on them,
      // loudly — an admin can see the account stuck in 'pending'.
      console.error(`account deletion ${uid}: ${left?.n} item(s) failed ${MAX_ATTEMPTS} times`);
      continue;
    }
    await env.DB
      .prepare(`UPDATE account_deletions SET status = 'done', completed_at = ? WHERE user_id = ? AND status = 'pending'`)
      .bind(new Date(clock()).toISOString(), uid)
      .run();
    report.finished++;
  }
  return report;
}

async function processItems(
  env: Env,
  uid: string,
  items: Array<{ kind: string; value: string; attempts: number }>,
): Promise<{ removed: number; failed: string[] }> {
  const failedKeys: string[] = [];
  const done = (kind: string, values: string[]) =>
    values.length === 0
      ? Promise.resolve()
      : env.DB.batch(
          values.map((v) =>
            env.DB.prepare(`DELETE FROM account_deletion_objects WHERE user_id = ? AND kind = ? AND value = ?`).bind(uid, kind, v),
          ),
        );
  const failed = (kind: string, value: string, err: unknown) => {
    console.error(`account deletion ${uid}: ${kind} failed`, err instanceof Error ? err.message : err);
    failedKeys.push(`${kind}\n${value}`);
    return env.DB
      .prepare(`UPDATE account_deletion_objects SET attempts = attempts + 1 WHERE user_id = ? AND kind = ? AND value = ?`)
      .bind(uid, kind, value)
      .run();
  };

  let removed = 0;
  // Keys: one R2 call per 1000.
  const keys = items.filter((i) => i.kind === "key").map((i) => i.value);
  if (keys.length > 0) {
    try {
      await env.R2.delete(keys);
      removed += keys.length;
      await done("key", keys);
    } catch (err) {
      for (const k of keys) await failed("key", k, err);
    }
  }

  for (const item of items) {
    if (item.kind === "key") continue;
    try {
      switch (item.kind) {
        case "prefix": {
          // One page per pass: the row stays until a listing comes back empty,
          // so a prefix of any size drains across passes and runs.
          const page = await env.R2.list({ prefix: item.value, limit: R2_BATCH });
          const listed = page.objects.map((o) => o.key);
          if (listed.length > 0) {
            await env.R2.delete(listed);
            removed += listed.length;
          }
          if (listed.length === 0 || !page.truncated) await done("prefix", [item.value]);
          break;
        }
        case "cf_hostname":
          if (saasConfigured(env)) await deleteCustomHostname(env, item.value);
          await done(item.kind, [item.value]);
          break;
        case "cache_video":
          await caches.default.delete(new Request(`https://meta.internal/video/${item.value}`)).catch(() => false);
          await done(item.kind, [item.value]);
          break;
        case "cache_profile":
          await caches.default.delete(new Request(`https://meta.internal/profile/${item.value}`)).catch(() => false);
          await done(item.kind, [item.value]);
          break;
        case "share_jobs":
          await env.SHARE_JOBS.getByName(item.value).purgeAll();
          await done(item.kind, [item.value]);
          break;
        default:
          // Unknown kind (a newer Worker queued it): leave it for that Worker.
          await failed(item.kind, item.value, new Error(`unknown kind ${item.kind}`));
      }
    } catch (err) {
      await failed(item.kind, item.value, err);
    }
  }
  return { removed, failed: failedKeys };
}
