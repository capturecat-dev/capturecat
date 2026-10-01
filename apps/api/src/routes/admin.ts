/**
 * Admin surface for admin.capturecat.so.
 *
 * AUTHORITY is `user.role === "admin"`, supplied by Better Auth's `admin`
 * plugin, so admin can be granted from the UI via `/api/auth/admin/set-role`
 * without a redeploy. Five of that plugin's endpoints are denied at the router
 * (see DENIED_ADMIN_ENDPOINTS in src/index.ts) — notably `update-user`, whose
 * untyped `data` bag would otherwise let an admin set `tester`/`blocked`/`role`
 * directly and bypass every `input: false` guard.
 *
 * WHY THESE ROUTES STILL EXIST alongside the plugin: `/admin/list-users` cannot
 * join `subscription`, so it cannot report the paid badge, and the entitlement
 * write has to be a typed `tester`/`blocked` update rather than an arbitrary
 * row write. Those are the two things the plugin cannot safely give us.
 *
 * There is NO email allowlist. An ADMIN_EMAILS fallback would be a second
 * authority model sitting beside the plugin — a standing back door that grants
 * admin to whoever controls an env var, with no audit trail and no way to
 * revoke it from the UI.
 *
 * Bootstrapping the first admin is a one-off operator action instead, because
 * nobody can be granted a role by an admin that does not exist yet:
 *
 *   wrangler d1 execute capturecat --remote \
 *     --command "UPDATE user SET role = 'admin' WHERE email = 'you@example.com'"
 *
 * After that, admins grant each other roles through Better Auth's
 * /api/auth/admin/set-role.
 */

import { Hono } from "hono";
import type { Env, Variables } from "../types";
import { requireAuth } from "../middleware/auth";
import { PAID_SUBSCRIPTION_STATUSES } from "../lib/stripe";
import { z } from "zod";
import { parseJsonBody } from "../lib/validate";
import { registerPlanAdminRoutes } from "./admin-plans";
import { purgePlanCache } from "../lib/entitlement";

export const adminRoutes = new Hono<{ Bindings: Env; Variables: Variables }>();

adminRoutes.use("/admin/*", requireAuth, async (c, next) => {
  const user = c.get("user");
  // The role is read from D1 on every request (session.cookieCache is off on
  // purpose), so revoking admin takes effect on the very next call.
  const row = await c.env.DB.prepare(`SELECT role FROM user WHERE id = ?`)
    .bind(user.uid)
    .first<{ role: string | null }>();

  if (row?.role !== "admin") {
    // 404, not 403 — do not confirm the admin surface exists to a non-admin.
    return c.json({ error: "Not found" }, 404);
  }
  await next();
});

/**
 * GET /admin/users — the directory.
 *
 * The paid badge is an EXISTS over `subscription`, not a joined row: a
 * cancel-then-resubscribe leaves MULTIPLE rows with the same referenceId, so a
 * single-row read would report whichever the planner happened to return.
 *
 * Statuses come from `PAID_SUBSCRIPTION_STATUSES` rather than an inlined
 * literal — that list includes `past_due` on purpose for dunning grace, and
 * inlining it here would fork the dunning policy from the one the API enforces.
 */
adminRoutes.get("/admin/orgs", async (c) => {
  const { results } = await c.env.DB.prepare(
    `SELECT o."id", o."name", o."slug", o."createdAt",
            (SELECT COUNT(*) FROM "member" m WHERE m."organizationId" = o."id") AS members,
            (SELECT COUNT(*) FROM shared_videos v WHERE v.org_id = o."id" AND v.status = 'ready') AS videos,
            (SELECT u.email FROM "member" m JOIN "user" u ON u.id = m."userId"
              WHERE m."organizationId" = o."id" AND m.role = 'owner' LIMIT 1) AS owner_email
       FROM "organization" o
      ORDER BY o."createdAt" DESC`
  ).all<{ id: string; name: string; slug: string; createdAt: string; members: number; videos: number; owner_email: string | null }>();
  return c.json({
    orgs: (results ?? []).map((r) => ({
      id: r.id, name: r.name, slug: r.slug, createdAt: r.createdAt,
      members: r.members, videos: r.videos, ownerEmail: r.owner_email,
    })),
  });
});

adminRoutes.get("/admin/users", async (c) => {
  const placeholders = PAID_SUBSCRIPTION_STATUSES.map(() => "?").join(",");
  const { results } = await c.env.DB.prepare(
    `SELECT u.id, u.email, u.name, u.createdAt, u.tester, u.blocked, u.role,
            EXISTS (
              SELECT 1 FROM subscription s
               WHERE s.referenceId = u.id
                 AND s.status IN (${placeholders})
            ) AS paid
       FROM user u
      ORDER BY u.createdAt DESC
      LIMIT 500`
  )
    .bind(...PAID_SUBSCRIPTION_STATUSES)
    .all<{
      id: string;
      email: string;
      name: string | null;
      createdAt: string;
      tester: number | null;
      blocked: number | null;
      role: string | null;
      paid: number;
    }>();

  return c.json({
    users: (results ?? []).map((r) => ({
      id: r.id,
      email: r.email,
      name: r.name,
      createdAt: r.createdAt,
      tester: r.tester === 1,
      blocked: r.blocked === 1,
      role: r.role ?? "user",
      paid: r.paid === 1,
      // Derived exactly as resolveTier() does, so the panel cannot disagree
      // with what the API actually serves.
      tier: r.blocked === 1 ? "blocked" : r.paid === 1 ? "paid" : r.tester === 1 ? "tester" : "free",
    })),
  });
});

/**
 * POST /admin/users/:id/entitlement — grant or revoke.
 *
 * `paid` is NOT settable here, and that is deliberate rather than a limitation.
 * @better-auth/stripe owns the `subscription` table and writes it ONLY from the
 * webhook, so a locally-written "paid" flag would be a second source of truth
 * that Stripe never agrees with.
 *
 * To comp someone, use Stripe — they already have a `stripeCustomerId`
 * (createCustomerOnSignUp is on), so either:
 *   • give the plan a `freeTrial: { days }` and start a trial, or
 *   • create the subscription in the Stripe dashboard with a 100%-off coupon.
 * Either way the webhook writes the row and `resolveTier()` reports "paid"
 * with no bespoke code. `trialing` is already in PAID_SUBSCRIPTION_STATUSES.
 */
adminRoutes.post("/admin/users/:id/entitlement", async (c) => {
  const userId = c.req.param("id");
  type Body = { tester?: unknown; blocked?: unknown };
  const body: Body = await c.req.json<Body>().catch(() => ({}) as Body);

  if (typeof body.tester !== "boolean" || typeof body.blocked !== "boolean") {
    return c.json({ error: "tester and blocked must both be booleans" }, 400);
  }

  const res = await c.env.DB.prepare(
    `UPDATE user SET tester = ?, blocked = ? WHERE id = ?`
  )
    .bind(body.tester ? 1 : 0, body.blocked ? 1 : 0, userId)
    .run();

  if ((res.meta?.changes ?? 0) === 0) {
    return c.json({ error: "User not found" }, 404);
  }
  // The share/comment/domain paths cache the owner's plan per colo for 60 s;
  // an admin edit should show up on the next request, not the next minute.
  await purgePlanCache(userId);

  // Blocking must also end the sessions. `resolveTier()` re-reads the user row
  // on every request (session.cookieCache is off on purpose), so a `tester`
  // change lands on the very next call and needs no revoke — but a blocked user
  // holding a live session should not keep browsing until it lapses.
  //
  // Done by hand because Better Auth has no admin-scoped revoke:
  // /api/auth/revoke-sessions is self-scoped.
  if (body.blocked) {
    await c.env.DB.prepare(`DELETE FROM session WHERE userId = ?`).bind(userId).run();
  }

  return c.json({ id: userId, tester: body.tester, blocked: body.blocked });
});


/**
 * GET /admin/beta — the beta waitlist, newest first.
 *
 * Public sign-ups land in `beta_signups` via POST /api/beta, where a honeypot,
 * Cloudflare Turnstile, a per-IP rate limit and a UNIQUE(email) constraint gate
 * the writes. This read is admin-only like the rest of this router. ip /
 * user_agent / referrer are surfaced precisely so an operator can recognise and
 * delete a burst of junk that slipped through.
 */
adminRoutes.get("/admin/beta", async (c) => {
  const { results } = await c.env.DB.prepare(
    `SELECT id, email, status, ip, user_agent, referrer, country, created_at
       FROM beta_signups
      ORDER BY created_at DESC
      LIMIT 1000`
  ).all<{
    id: string;
    email: string;
    status: string;
    ip: string | null;
    user_agent: string | null;
    referrer: string | null;
    country: string | null;
    created_at: string;
  }>();

  return c.json({
    signups: (results ?? []).map((r) => ({
      id: r.id,
      email: r.email,
      status: r.status,
      ip: r.ip,
      userAgent: r.user_agent,
      referrer: r.referrer,
      country: r.country,
      createdAt: r.created_at,
    })),
  });
});

/** DELETE /admin/beta/:id — remove one sign-up (spam moderation). */
adminRoutes.delete("/admin/beta/:id", async (c) => {
  const id = c.req.param("id");
  const res = await c.env.DB.prepare(`DELETE FROM beta_signups WHERE id = ?`)
    .bind(id)
    .run();
  if ((res.meta?.changes ?? 0) === 0) {
    return c.json({ error: "Sign-up not found" }, 404);
  }
  return c.json({ id });
});


// Plans: the editor, Stripe sync on save, hide/publish, "Most popular".
registerPlanAdminRoutes(adminRoutes);
