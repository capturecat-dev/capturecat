/**
 * DELETE /api/me — the signed-in user deletes their own account, for good.
 *
 * App Store Guideline 5.1.1(v): the iOS app (Account → Delete Account), the
 * web dashboard (Settings → Delete account) and any future client call this.
 * Everything it does is in lib/account-deletion.ts; this file is the gate.
 *
 * AUTH: requireAuth, exactly as GET /api/me — a Bearer session token from the
 * apps, or the session cookie from the web (whose requireAuth CSRF check
 * insists on a trusted Origin for any non-GET). Agent credentials (cc_pat_ /
 * cc_oat_) are refused first: no agent may ever delete its owner's account.
 * A blocked account gets requireAuth's 403 — deleting one is a support
 * decision (it may be evidence), not self-serve.
 *
 * RESPONSES
 *   200 { deleted: true, jobId, cancelledSubscriptions, cleanup: "pending" }
 *       The account no longer exists; every session (this one included) is
 *       gone. Stored files are removed in the background.
 *   401 no session — which is ALSO what a retry gets after a response that
 *       was lost on the way back: clients treat 401 here as "already deleted".
 *   409 { code: "team_has_members", team: { id, name, otherMembers } }
 *   502 { code: "billing_unavailable" } — Stripe could not cancel the
 *       subscription; nothing was deleted.
 *   500 { code: "delete_failed" } — the D1 batch failed (a transaction:
 *       nothing deleted). Billing may already be cancelled; a retry is safe.
 */
import { Hono } from "hono";
import type { Env, Variables } from "../types";
import { requireAuth } from "../middleware/auth";
import { refuseAgentCredentials } from "../middleware/session-only";
import { bearerToken } from "../lib/agent-tokens";
import { userRateLimit } from "../lib/entitlement";
import {
  blockingTeam,
  cancelSubscriptionsNow,
  deleteAccountRows,
  processAccountDeletions,
  type DeletionClient,
} from "../lib/account-deletion";

export const accountDeleteRoutes = new Hono<{ Bindings: Env; Variables: Variables }>();

/** The client that asked, for the audit row: X-CC-Client when it names one
 *  we know, else bearer = "app" and cookie = "web". */
function clientOf(header: string | undefined, bearer: boolean): DeletionClient {
  const named = header?.trim().toLowerCase();
  if (named === "ios" || named === "mac" || named === "web") return named;
  return bearer ? "app" : "web";
}

accountDeleteRoutes.delete(
  "/me",
  refuseAgentCredentials,
  requireAuth,
  userRateLimit({ limit: 5, windowSec: 600, scope: "account-delete" }),
  async (c) => {
    const uid = c.get("user").uid;
    const user = await c.env.DB
      .prepare(`SELECT id, email, username, "stripeCustomerId" FROM "user" WHERE id = ?`)
      .bind(uid)
      .first<{ id: string; email: string | null; username: string | null; stripeCustomerId: string | null }>();
    if (!user) {
      // The session resolved but the row is gone: a raced repeat.
      return c.json({ error: "Invalid or expired session" }, 401);
    }

    const team = await blockingTeam(c.env.DB, uid);
    if (team) {
      const others = team.otherMembers === 1 ? "1 other member" : `${team.otherMembers} other members`;
      return c.json(
        {
          error: `You own the team “${team.name}” with ${others}. Make another member an owner, or remove them, on the Team page — then delete your account.`,
          code: "team_has_members",
          team,
        },
        409,
      );
    }

    let cancelled: string[];
    try {
      cancelled = await cancelSubscriptionsNow(c.env, user);
    } catch (err) {
      console.error("account delete: Stripe cancel failed", err instanceof Error ? err.message : err);
      return c.json(
        {
          error: "We couldn't cancel your subscription, so nothing was deleted. Try again in a moment.",
          code: "billing_unavailable",
        },
        502,
      );
    }

    let result: Awaited<ReturnType<typeof deleteAccountRows>>;
    try {
      result = await deleteAccountRows(c.env, user, {
        client: clientOf(c.req.header("X-CC-Client"), bearerToken(c.req.header("Authorization")) !== null),
        cancelledSubscriptions: cancelled.length,
      });
    } catch (err) {
      // The batch is a transaction: nothing was deleted. Billing has already
      // stopped (that is safe to repeat — a retry finds nothing live).
      console.error("account delete: D1 batch failed", err instanceof Error ? err.message : err);
      return c.json(
        {
          error:
            cancelled.length > 0
              ? "Your subscription was cancelled, but your account couldn't be deleted. Nothing else changed — try again in a moment."
              : "Your account couldn't be deleted. Nothing changed — try again in a moment.",
          code: "delete_failed",
        },
        500,
      );
    }

    // Stored files go in the background; the hourly sweep finishes whatever
    // this run does not.
    const cleanup = processAccountDeletions(c.env, { userId: uid }).catch((err) =>
      console.error("account delete: background cleanup failed", err),
    );
    try {
      c.executionCtx.waitUntil(cleanup);
    } catch {
      // No ExecutionContext (unit tests): the promise still runs.
    }

    return c.json({
      deleted: true,
      jobId: result.jobId,
      cancelledSubscriptions: cancelled.length,
      cleanup: "pending",
    });
  },
);
