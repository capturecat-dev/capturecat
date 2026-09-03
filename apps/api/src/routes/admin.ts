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
import { listPlans } from "../lib/plans";

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


/**
 * GET /admin/plans — every plan, including inactive ones.
 *
 * Unlike the public /api/plans this returns the feature and limit maps so the
 * console can edit them, and it does not filter to sellable rows: the free plan
 * has no price and is still very much editable.
 */
adminRoutes.get("/admin/plans", async (c) => {
  const plans = await listPlans(c.env.DB, false);
  return c.json({ plans });
});

/**
 * PUT /admin/plans/:id — edit a plan.
 *
 * `name` is NOT editable. @better-auth/stripe stores it on every `subscription`
 * row, so renaming a plan orphans existing subscribers from the tier they are
 * paying for — the row would no longer resolve and they would silently drop to
 * free. Create a new plan instead.
 */
adminRoutes.put("/admin/plans/:id", async (c) => {
  const id = c.req.param("id");
  type Body = {
    displayName?: unknown;
    description?: unknown;
    priceId?: unknown;
    annualPriceId?: unknown;
    trialDays?: unknown;
    features?: unknown;
    limits?: unknown;
    sortOrder?: unknown;
    isActive?: unknown;
  };
  const body: Body = await c.req.json<Body>().catch(() => ({}) as Body);

  const str = (v: unknown) => (typeof v === "string" ? v.trim() : null);
  const num = (v: unknown) => (typeof v === "number" && Number.isFinite(v) ? Math.trunc(v) : null);

  if (typeof body.displayName !== "string" || !body.displayName.trim()) {
    return c.json({ error: "displayName is required" }, 400);
  }
  // Objects, not strings: accepting pre-serialised JSON here would let a typo
  // write an unparseable blob that silently denies every feature at runtime.
  if (typeof body.features !== "object" || body.features === null) {
    return c.json({ error: "features must be an object" }, 400);
  }
  if (typeof body.limits !== "object" || body.limits === null) {
    return c.json({ error: "limits must be an object" }, 400);
  }
  // The free plan is the fallback tier every unpaid user resolves to —
  // hiding it would leave signed-in users with no feature set at all.
  if (body.isActive === false) {
    const target = await c.env.DB.prepare("SELECT name FROM plan WHERE id = ?")
      .bind(id)
      .first<{ name: string }>();
    if (target?.name === "free") {
      return c.json({ error: "The free plan is the fallback tier and cannot be hidden" }, 400);
    }
  }

  const res = await c.env.DB.prepare(
    `UPDATE plan
        SET display_name = ?, description = ?, price_id = ?, annual_price_id = ?,
            trial_days = ?, features = ?, limits = ?, sort_order = ?, is_active = ?,
            updated_at = datetime('now')
      WHERE id = ?`
  )
    .bind(
      body.displayName.trim(),
      str(body.description),
      str(body.priceId) || null,
      str(body.annualPriceId) || null,
      num(body.trialDays) ?? 0,
      JSON.stringify(body.features),
      JSON.stringify(body.limits),
      num(body.sortOrder) ?? 0,
      body.isActive === false ? 0 : 1,
      id
    )
    .run();

  if ((res.meta?.changes ?? 0) === 0) {
    return c.json({ error: "Plan not found" }, 404);
  }
  return c.json({ id });
});

/** POST /admin/plans — create a tier. `name` is immutable once set. */
/**
 * POST /admin/plans/:id/stripe-sync — create the Stripe product + recurring
 * price(s) for a plan and write the ids back, so "make a plan sellable" is
 * one admin click instead of a dashboard round-trip. Amounts arrive in cents;
 * a fresh product is created every sync (re-syncing mints new prices — old
 * subscriptions keep their old price, which is how Stripe wants it).
 */
adminRoutes.post("/admin/plans/:id/stripe-sync", async (c) => {
  if (!c.env.STRIPE_SECRET_KEY) {
    return c.json({ error: "STRIPE_SECRET_KEY is not configured" }, 503);
  }
  const id = c.req.param("id");
  const row = await c.env.DB.prepare("SELECT name, display_name FROM plan WHERE id = ?")
    .bind(id)
    .first<{ name: string; display_name: string }>();
  if (!row) return c.json({ error: "Plan not found" }, 404);
  if (row.name === "free") return c.json({ error: "The free plan is never sold" }, 400);

  const body: { monthlyCents?: unknown; annualCents?: unknown; currency?: unknown } =
    await c.req.json().catch(() => ({}));
  const monthly =
    typeof body.monthlyCents === "number" && Number.isInteger(body.monthlyCents) && body.monthlyCents > 0
      ? body.monthlyCents : null;
  const annual =
    typeof body.annualCents === "number" && Number.isInteger(body.annualCents) && body.annualCents > 0
      ? body.annualCents : null;
  if (!monthly && !annual) {
    return c.json({ error: "monthlyCents and/or annualCents (integer, > 0) required" }, 400);
  }
  const currency =
    typeof body.currency === "string" && /^[a-z]{3}$/.test(body.currency) ? body.currency : "usd";

  const Stripe = (await import("stripe")).default;
  const stripe = new Stripe(c.env.STRIPE_SECRET_KEY);

  const product = await stripe.products.create({
    name: `CaptureCat ${row.display_name}`,
    metadata: { plan: row.name },
  });
  let priceId: string | null = null;
  let annualPriceId: string | null = null;
  if (monthly) {
    priceId = (await stripe.prices.create({
      product: product.id,
      unit_amount: monthly,
      currency,
      recurring: { interval: "month" },
    })).id;
  }
  if (annual) {
    annualPriceId = (await stripe.prices.create({
      product: product.id,
      unit_amount: annual,
      currency,
      recurring: { interval: "year" },
    })).id;
  }

  await c.env.DB.prepare(
    `UPDATE plan SET price_id = COALESCE(?, price_id),
                     annual_price_id = COALESCE(?, annual_price_id),
                     monthly_amount_cents = COALESCE(?, monthly_amount_cents),
                     annual_amount_cents = COALESCE(?, annual_amount_cents),
                     currency = ?,
                     updated_at = datetime('now')
      WHERE id = ?`
  ).bind(priceId, annualPriceId, monthly, annual, currency, id).run();

  return c.json({ productId: product.id, priceId, annualPriceId, monthly, annual });
});

/**
 * POST /admin/plans/:id/refresh-stripe — pull the CURRENT amounts for a
 * plan's existing price ids out of Stripe and store them, for prices minted
 * before amounts were recorded (or edited directly in the Stripe dashboard).
 */
adminRoutes.post("/admin/plans/:id/refresh-stripe", async (c) => {
  if (!c.env.STRIPE_SECRET_KEY) {
    return c.json({ error: "STRIPE_SECRET_KEY is not configured" }, 503);
  }
  const id = c.req.param("id");
  const row = await c.env.DB.prepare("SELECT price_id, annual_price_id FROM plan WHERE id = ?")
    .bind(id)
    .first<{ price_id: string | null; annual_price_id: string | null }>();
  if (!row) return c.json({ error: "Plan not found" }, 404);
  if (!row.price_id && !row.annual_price_id) {
    return c.json({ error: "Plan has no Stripe prices to read" }, 400);
  }
  const Stripe = (await import("stripe")).default;
  const stripe = new Stripe(c.env.STRIPE_SECRET_KEY);
  const read = async (priceId: string | null) => {
    if (!priceId) return null;
    try {
      const p = await stripe.prices.retrieve(priceId);
      return { amount: p.unit_amount ?? null, currency: p.currency };
    } catch {
      return null;
    }
  };
  const [monthly, annual] = await Promise.all([read(row.price_id), read(row.annual_price_id)]);
  await c.env.DB.prepare(
    `UPDATE plan SET monthly_amount_cents = COALESCE(?, monthly_amount_cents),
                     annual_amount_cents = COALESCE(?, annual_amount_cents),
                     currency = COALESCE(?, currency),
                     updated_at = datetime('now')
      WHERE id = ?`
  ).bind(monthly?.amount ?? null, annual?.amount ?? null, monthly?.currency ?? annual?.currency ?? null, id).run();
  return c.json({
    monthlyAmountCents: monthly?.amount ?? null,
    annualAmountCents: annual?.amount ?? null,
  });
});

adminRoutes.post("/admin/plans", async (c) => {
  type Body = { name?: unknown; displayName?: unknown };
  const body: Body = await c.req.json<Body>().catch(() => ({}) as Body);
  const name = typeof body.name === "string" ? body.name.trim().toLowerCase() : "";
  const displayName = typeof body.displayName === "string" ? body.displayName.trim() : "";

  // The name becomes the identity @better-auth/stripe writes onto every
  // subscription row, so keep it to a slug rather than free text.
  if (!/^[a-z][a-z0-9_-]{1,31}$/.test(name)) {
    return c.json(
      { error: "name must be a lowercase slug, 2-32 chars, starting with a letter" },
      400
    );
  }
  if (!displayName) return c.json({ error: "displayName is required" }, 400);

  const exists = await c.env.DB.prepare(`SELECT 1 FROM plan WHERE name = ?`).bind(name).first();
  if (exists) return c.json({ error: `A plan named "${name}" already exists` }, 409);

  const id = `plan_${crypto.randomUUID().slice(0, 8)}`;
  await c.env.DB.prepare(
    `INSERT INTO plan (id, name, display_name, features, limits, sort_order, is_active)
     VALUES (?, ?, ?, '{}', '{}', 100, 0)`
  )
    .bind(id, name, displayName)
    .run();

  // Created INACTIVE on purpose: a new tier with no price and no features
  // should not appear on the pricing page the moment it is created.
  return c.json({ id, name, displayName, isActive: false }, 201);
});
