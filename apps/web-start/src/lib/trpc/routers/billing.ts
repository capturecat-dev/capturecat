import { z } from "zod";
import { TRPCError } from "@trpc/server";

import { apiFetch } from "@/lib/session";
import { authedProcedure, createTRPCRouter } from "@/lib/trpc/init";

/**
 * Billing, proxied to @better-auth/stripe on api.capturecat.so.
 *
 * The web app no longer talks to Stripe at all — its own `stripe` client and
 * checkout-session code are deleted. Two Stripe integrations would mean two
 * places creating subscriptions, and a checkout session created here would
 * produce a subscription with no `referenceId` the plugin recognises, so it
 * would never resolve to a paid tier.
 *
 * The tier itself comes from GET /api/me, which is the ONLY endpoint that runs
 * `resolveTier()`. Deliberately NOT computed from /subscription/list: that
 * endpoint filters on Better Auth's `isActiveOrTrialing()`, which EXCLUDES
 * `past_due`, while the API's own PAID_SUBSCRIPTION_STATUSES includes it for
 * dunning grace. Reading the list here would show "Subscribe" to a customer the
 * API still serves as paid.
 */
export const billingRouter = createTRPCRouter({
  status: authedProcedure.query(async () => {
    const res = await apiFetch("/api/me");
    if (!res.ok) {
      throw new TRPCError({ code: "INTERNAL_SERVER_ERROR", message: "Could not load billing status" });
    }
    return (await res.json()) as {
      uid: string;
      email: string;
      tier: "free" | "tester" | "paid";
      tester: boolean;
      blocked: boolean;
    };
  }),

  checkout: authedProcedure
    .input(z.object({ annual: z.boolean().default(false) }))
    .mutation(async ({ input }) => {
      const site = import.meta.env.VITE_SITE_URL ?? "https://capturecat.so";
      const res = await apiFetch("/api/auth/subscription/upgrade", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          plan: "pro",
          annual: input.annual,
          // Origin-checked by the plugin: must be relative or a trusted origin.
          successUrl: `${site}/app/billing?upgraded=1`,
          cancelUrl: `${site}/pricing`,
        }),
      });
      if (!res.ok) {
        throw new TRPCError({ code: "INTERNAL_SERVER_ERROR", message: "Could not start checkout" });
      }
      return (await res.json()) as { url?: string; redirect?: boolean };
    }),

  portal: authedProcedure.mutation(async () => {
    const site = import.meta.env.VITE_SITE_URL ?? "https://capturecat.so";
    const res = await apiFetch("/api/auth/subscription/billing-portal", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ returnUrl: `${site}/app/billing` }),
    });
    if (!res.ok) {
      throw new TRPCError({ code: "INTERNAL_SERVER_ERROR", message: "Could not open billing portal" });
    }
    return (await res.json()) as { url?: string; redirect?: boolean };
  }),
});
