import { z } from "zod";
import { TRPCError } from "@trpc/server";

import { apiFetch } from "@/lib/session";
import { adminProcedure, createTRPCRouter } from "@/lib/trpc/init";

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
export interface Plan {
  id: string;
  name: string;
  displayName: string;
  description: string | null;
  priceId: string | null;
  annualPriceId: string | null;
  trialDays: number;
  features: Record<string, boolean>;
  limits: Record<string, number>;
  sortOrder: number;
  isActive: boolean;
  monthlyAmountCents: number | null;
  annualAmountCents: number | null;
  currency: string;
}

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

  refreshPlanStripe: adminProcedure
    .input(z.object({ planId: z.string().min(1) }))
    .mutation(async ({ input }) => {
      const res = await apiFetch(`/api/admin/plans/${encodeURIComponent(input.planId)}/refresh-stripe`, {
        method: "POST",
      });
      const data = (await res.json().catch(() => null)) as
        | { monthlyAmountCents?: number | null; annualAmountCents?: number | null; error?: string }
        | null;
      if (!res.ok) {
        throw new TRPCError({ code: "BAD_REQUEST", message: data?.error ?? "Refresh failed" });
      }
      return data!;
    }),

  syncPlanStripe: adminProcedure
    .input(
      z.object({
        planId: z.string().min(1),
        monthlyCents: z.number().int().positive().optional(),
        annualCents: z.number().int().positive().optional(),
      })
    )
    .mutation(async ({ input }) => {
      const res = await apiFetch(`/api/admin/plans/${encodeURIComponent(input.planId)}/stripe-sync`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          monthlyCents: input.monthlyCents,
          annualCents: input.annualCents,
        }),
      });
      const data = (await res.json().catch(() => null)) as
        | { productId?: string; priceId?: string | null; annualPriceId?: string | null; error?: string }
        | null;
      if (!res.ok) {
        throw new TRPCError({ code: "BAD_REQUEST", message: data?.error ?? "Stripe sync failed" });
      }
      return data!;
    }),

  listPlans: adminProcedure.query(async () => {
    const res = await apiFetch("/api/admin/plans");
    if (!res.ok) throw new TRPCError({ code: "FORBIDDEN", message: "Could not load plans" });
    return (await res.json()) as { plans: Plan[] };
  }),

  updatePlan: adminProcedure
    .input(
      z.object({
        id: z.string().min(1),
        displayName: z.string().min(1),
        description: z.string().nullable(),
        priceId: z.string().nullable(),
        annualPriceId: z.string().nullable(),
        trialDays: z.number().int().min(0),
        // Passed as objects, not JSON strings: a serialised blob with a typo
        // parses to nothing at runtime and silently denies every feature.
        features: z.record(z.string(), z.boolean()),
        limits: z.record(z.string(), z.number()),
        sortOrder: z.number().int(),
        isActive: z.boolean(),
      })
    )
    .mutation(async ({ input }) => {
      const { id, ...body } = input;
      const res = await apiFetch(`/api/admin/plans/${encodeURIComponent(id)}`, {
        method: "PUT",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(body),
      });
      if (!res.ok) {
        const detail = await res.json().catch(() => ({}) as { error?: string });
        throw new TRPCError({
          code: "BAD_REQUEST",
          message: (detail as { error?: string }).error ?? "Could not save the plan",
        });
      }
      return { ok: true };
    }),

  createPlan: adminProcedure
    .input(z.object({ name: z.string().min(2), displayName: z.string().min(1) }))
    .mutation(async ({ input }) => {
      const res = await apiFetch("/api/admin/plans", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(input),
      });
      if (!res.ok) {
        const detail = await res.json().catch(() => ({}) as { error?: string });
        throw new TRPCError({
          code: "BAD_REQUEST",
          message: (detail as { error?: string }).error ?? "Could not create the plan",
        });
      }
      return (await res.json()) as { id: string };
    }),

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
