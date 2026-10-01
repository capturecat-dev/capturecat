import { z } from "zod";
import { TRPCError } from "@trpc/server";

import { apiFetch } from "@/lib/session";
import { adminProcedure, createTRPCRouter } from "@/lib/trpc/init";
import type { AdminPlan } from "@/lib/plan-fields";

/**
 * Admin directory + entitlement writes, proxied to api.capturecat.so.
 *
 * The Firebase version called `listUsers` (paging to 5000), `getUser`,
 * `setCustomUserClaims` and `revokeRefreshTokens` directly. None of those has a
 * Better Auth equivalent, and two of them should not be ported at all:
 *
 *   custom claims  `tester`/`blocked` are columns declared `input: false`, so
 *                  no client payload can set them. The API's admin route is the
 *                  only writer.
 *   revokeRefreshTokens  Firebase needed it because claims were baked into the
 *                  token and went stale. Better Auth re-reads the user row on
 *                  every request (cookieCache is off on purpose), so a change
 *                  lands on the very next call. Porting the revoke would sign
 *                  people out for no reason.
 *
 * `paid` is absent from the mutation input on purpose — see the API route: the
 * `subscription` table is written only by the Stripe webhook, so a locally
 * granted paid flag would be a second source of truth Stripe never agrees with.
 * Comp via a plan `freeTrial` or a 100%-off coupon instead.
 */
export type Plan = AdminPlan;

/** What one save or sync did in Stripe (apps/api lib/stripe-catalog.ts). */
export interface PriceSyncResult {
  interval: "month" | "year";
  lookupKey: string;
  action: "adopted" | "created" | "reused" | "archived" | "none";
  priceId: string | null;
  amountCents: number | null;
  currency: string | null;
  archived: string | null;
  adoptedFrom?: "plan" | "env";
  coupon: { action: "created" | "reused" | "deleted" | "none"; id: string | null; replaced: string | null };
}
export interface PlanSyncSummary {
  planId: string;
  plan: string;
  changed: boolean;
  product: { id: string; action: "created" | "updated" | "unchanged" };
  monthly: PriceSyncResult;
  annual: PriceSyncResult;
  notes: string[];
}

/** The editor's body for POST/PUT /api/admin/plans (lib/plan-fields.ts
 *  `PlanInput`). The API validates it strictly; this only keeps the shape. */
const planInput = z.object({
  displayName: z.string().min(1),
  description: z.string().nullable(),
  monthlyCents: z.number().int().positive().nullable(),
  annualCents: z.number().int().positive().nullable(),
  currency: z.string().length(3),
  trialDays: z.number().int().min(0),
  // Objects, not JSON strings: a serialised blob with a typo parses to
  // nothing at runtime and silently denies every feature.
  features: z.record(z.string(), z.boolean()),
  limits: z.record(z.string(), z.number()),
  sortOrder: z.number().int().min(0),
  isActive: z.boolean(),
  popular: z.boolean(),
  saleLabel: z.string().nullable(),
  salePriceMonthlyCents: z.number().int().min(0).nullable(),
  salePriceAnnualCents: z.number().int().min(0).nullable(),
  saleStartsAt: z.string().nullable(),
  saleEndsAt: z.string().nullable(),
  saleDurationMonths: z.number().int().min(1).nullable(),
});

async function apiJson<T>(path: string, init: RequestInit | undefined, fallback: string): Promise<T> {
  const res = await apiFetch(path, init);
  const data = (await res.json().catch(() => null)) as (T & { error?: string }) | null;
  if (!res.ok) {
    // The API's own reason ("A sale needs an end date.", a Stripe message)
    // is the useful part; it carries no secret.
    throw new TRPCError({ code: "BAD_REQUEST", message: data?.error ?? fallback });
  }
  return data as T;
}

const jsonBody = (method: string, body: unknown): RequestInit => ({
  method,
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify(body),
});

export const adminRouter = createTRPCRouter({
  listUsers: adminProcedure.query(async () => {
    const res = await apiFetch("/api/admin/users");
    if (!res.ok) {
      throw new TRPCError({ code: "FORBIDDEN", message: "Could not load users" });
    }
    return (await res.json()) as {
      users: Array<{
        id: string;
        email: string;
        name: string | null;
        createdAt: string;
        tester: boolean;
        blocked: boolean;
        role: string;
        paid: boolean;
        tier: "free" | "tester" | "paid" | "blocked";
      }>;
    };
  }),

  listOrgs: adminProcedure.query(async () => {
    const res = await apiFetch("/api/admin/orgs");
    if (!res.ok) throw new TRPCError({ code: "FORBIDDEN", message: "Could not load orgs" });
    return (await res.json()) as {
      orgs: Array<{
        id: string; name: string; slug: string; createdAt: string;
        members: number; videos: number; ownerEmail: string | null;
      }>;
    };
  }),

  listPlans: adminProcedure.query(async () => {
    const res = await apiFetch("/api/admin/plans");
    if (!res.ok) throw new TRPCError({ code: "FORBIDDEN", message: "Could not load plans" });
    return (await res.json()) as { plans: Plan[]; stripeConfigured: boolean };
  }),

  /** Save IS sync: the API provisions Stripe, then writes the plan. */
  createPlan: adminProcedure
    .input(planInput.extend({ name: z.string().min(2) }))
    .mutation(({ input }) =>
      apiJson<{ plan: Plan; summary: PlanSyncSummary | null }>(
        "/api/admin/plans",
        jsonBody("POST", input),
        "Could not create the plan",
      ),
    ),

  updatePlan: adminProcedure
    .input(planInput.extend({ id: z.string().min(1) }))
    .mutation(({ input }) => {
      const { id, ...body } = input;
      return apiJson<{ plan: Plan; summary: PlanSyncSummary | null }>(
        `/api/admin/plans/${encodeURIComponent(id)}`,
        jsonBody("PUT", body),
        "Could not save the plan",
      );
    }),

  /** Hide from sale / publish. No Stripe call: works even when Stripe doesn't. */
  setPlanActive: adminProcedure
    .input(z.object({ id: z.string().min(1), isActive: z.boolean() }))
    .mutation(({ input }) =>
      apiJson<{ plan: Plan }>(
        `/api/admin/plans/${encodeURIComponent(input.id)}/active`,
        jsonBody("POST", { isActive: input.isActive }),
        "Could not change the plan",
      ),
    ),

  setPlanPopular: adminProcedure
    .input(z.object({ id: z.string().min(1), popular: z.boolean() }))
    .mutation(({ input }) =>
      apiJson<{ plan: Plan }>(
        `/api/admin/plans/${encodeURIComponent(input.id)}/popular`,
        jsonBody("POST", { popular: input.popular }),
        "Could not change the plan",
      ),
    ),

  /** Re-sync one plan without edits (the first adoption of the legacy price). */
  syncPlanStripe: adminProcedure
    .input(z.object({ planId: z.string().min(1) }))
    .mutation(({ input }) =>
      apiJson<{ summary: PlanSyncSummary }>(
        `/api/admin/plans/${encodeURIComponent(input.planId)}/stripe-sync`,
        jsonBody("POST", {}),
        "Stripe sync failed",
      ),
    ),

  syncAllPlans: adminProcedure.mutation(() =>
    apiJson<{
      results: Array<{ planId: string; plan: string; summary?: PlanSyncSummary; skipped?: string; error?: string }>;
    }>("/api/admin/plans/stripe-sync", jsonBody("POST", {}), "Stripe sync failed"),
  ),

  setEntitlement: adminProcedure
    .input(
      z.object({
        userId: z.string().min(1),
        tester: z.boolean(),
        blocked: z.boolean(),
      })
    )
    .mutation(async ({ input }) => {
      const res = await apiFetch(
        `/api/admin/users/${encodeURIComponent(input.userId)}/entitlement`,
        {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ tester: input.tester, blocked: input.blocked }),
        }
      );
      if (!res.ok) {
        throw new TRPCError({ code: "FORBIDDEN", message: "Could not update entitlement" });
      }
      return (await res.json()) as { id: string; tester: boolean; blocked: boolean };
    }),

  listBetaSignups: adminProcedure.query(async () => {
    const res = await apiFetch("/api/admin/beta");
    if (!res.ok) {
      throw new TRPCError({ code: "FORBIDDEN", message: "Could not load beta signups" });
    }
    return (await res.json()) as {
      signups: Array<{
        id: string;
        email: string;
        status: string;
        ip: string | null;
        userAgent: string | null;
        referrer: string | null;
        country: string | null;
        createdAt: string;
      }>;
    };
  }),

  deleteBetaSignup: adminProcedure
    .input(z.object({ id: z.string().min(1) }))
    .mutation(async ({ input }) => {
      const res = await apiFetch(
        `/api/admin/beta/${encodeURIComponent(input.id)}`,
        { method: "DELETE" }
      );
      if (!res.ok) {
        throw new TRPCError({ code: "BAD_REQUEST", message: "Could not delete the signup" });
      }
      return { ok: true };
    }),
});
