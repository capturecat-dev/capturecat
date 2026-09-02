/**
 * Server-side entitlement resolution. The client is never trusted:
 *
 *   • The Better Auth session proves WHO the caller is (requireAuth), by way
 *     of a bearer token that is looked up in D1 on every request.
 *   • The `subscription` table — written solely by @better-auth/stripe's
 *     webhook handler — is AUTHORITATIVE for paid status.
 *   • `tester` / `blocked` are columns on the server-owned `user` row. They
 *     are declared `input: false` in the Better Auth config, so no sign-up or
 *     update payload can set them.
 *
 * NOTHING in this chain originates from the client. The old "stale `paid`
 * custom claim" problem is gone by construction: there is no cached claim to
 * go stale, so a cancellation revokes access on the very next API call.
 *
 * Chain after requireAuth:  route.use(requireAuth, requireEntitlement())
 */

import { createMiddleware } from "hono/factory";
import type { Env, Variables, EntitlementTier } from "../types";
import { hasPaidSubscription } from "./stripe";

export async function resolveTier(
  db: D1Database,
  uid: string,
  claims: { tester: boolean; blocked: boolean } | undefined,
): Promise<EntitlementTier | "blocked"> {
  if (claims?.blocked) return "blocked";

  let paid = false;
  try {
    // Existence check against `subscription` WHERE referenceId = user.id AND
    // status IN ('active','trialing','past_due'). `past_due` is kept on
    // purpose — see PAID_SUBSCRIPTION_STATUSES in lib/stripe.ts for why that
    // diverges from Better Auth's own isActiveOrTrialing().
    paid = await hasPaidSubscription(db, uid);
  } catch (err) {
    // Same fail-soft posture as before: a D1 blip must not lock out paying
    // users. But there is no longer a `paid` token claim to fall back to, so
    // degrade to tester/free and shout.
    console.error("entitlement: D1 lookup failed", err);
    return claims?.tester ? "tester" : "free";
  }

  if (paid) return "paid";
  if (claims?.tester) return "tester";
  return "free";
}

export interface EntitlementOptions {
  /** Minimum tier required; "free" = any signed-in, non-blocked user. */
  minTier?: EntitlementTier;
}

const TIER_RANK: Record<EntitlementTier, number> = { free: 0, tester: 1, paid: 2 };

export function requireEntitlement(options: EntitlementOptions = {}) {
  const minTier = options.minTier ?? "free";
  return createMiddleware<{ Bindings: Env; Variables: Variables }>(
    async (c, next) => {
      const user = c.get("user");
      if (!user) {
        // Programming error — requireEntitlement must chain after requireAuth.
        return c.json({ error: "Unauthorized" }, 401);
      }

      const tier = await resolveTier(c.env.DB, user.uid, user.claims);
      if (tier === "blocked") {
        return c.json({ error: "Account blocked" }, 403);
      }
      if (TIER_RANK[tier] < TIER_RANK[minTier]) {
        return c.json(
          { error: `This feature requires a ${minTier} plan`, tier },
          403,
        );
      }

      c.set("entitlement", { uid: user.uid, tier });
      await next();
    },
  );
}

/**
 * Per-uid fixed-window rate limit backed by D1 (survives across colos,
 * unlike the per-IP Cache API limiter which stays as the outer cheap layer).
 * Chain after requireAuth. Exceeding the limit fails closed with 429.
 */
export function userRateLimit(opts: { limit: number; windowSec?: number; scope: string }) {
  const windowSec = opts.windowSec ?? 60;
  return createMiddleware<{ Bindings: Env; Variables: Variables }>(
    async (c, next) => {
      const user = c.get("user");
      if (!user) return c.json({ error: "Unauthorized" }, 401);

      const windowStart = Math.floor(Date.now() / 1000 / windowSec) * windowSec;
      const key = `${opts.scope}:${user.uid}`;

      try {
        // Upsert-and-read in one round trip; reset the counter when the
        // stored window is older than the current one.
        const row = await c.env.DB
          .prepare(
            `INSERT INTO rate_limits (key, window_start, count)
             VALUES (?1, ?2, 1)
             ON CONFLICT(key) DO UPDATE SET
               count = CASE WHEN rate_limits.window_start = ?2
                            THEN rate_limits.count + 1 ELSE 1 END,
               window_start = ?2
             RETURNING count`,
          )
          .bind(key, windowStart)
          .first<{ count: number }>();

        const count = row?.count ?? 1;
        c.header("X-RateLimit-Limit", String(opts.limit));
        c.header("X-RateLimit-Remaining", String(Math.max(0, opts.limit - count)));
        if (count > opts.limit) {
          return c.json(
            { error: "Too many requests" },
            { status: 429, headers: { "Retry-After": String(windowSec) } },
          );
        }
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        if (message.includes("no such table")) {
          // Migration not applied yet — allow but shout, don't brick prod.
          console.error("rate_limits table missing — run migrations", message);
        } else {
          // Any other failure fails CLOSED: a broken limiter must not
          // become an unlimited free-for-all.
          console.error("userRateLimit D1 error", message);
          return c.json({ error: "Too many requests" }, 429);
        }
      }

      await next();
    },
  );
}
