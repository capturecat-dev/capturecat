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
/** The API's own reason ({ message, code } from Better Auth / its Stripe plugin), for the toast and the logs. */
async function apiFailure(res: Response, what: string): Promise<TRPCError> {
  const body = (await res.json().catch(() => null)) as { message?: string; code?: string; error?: string } | null;
  const reason = body?.message ?? body?.error;
  console.error(`billing: ${what} failed`, res.status, body);
  // A 5xx is ours or Stripe's, not something the customer can fix — say so
  // plainly; a 4xx carries the API's reason (a hidden plan, one seat only…).
  if (res.status >= 500 || !reason) {
    return new TRPCError({ code: "INTERNAL_SERVER_ERROR", message: `${what}. Billing is temporarily unavailable — please try again in a moment.` });
  }
  return new TRPCError({ code: "BAD_REQUEST", message: `${what}: ${reason}` });
}

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
      if (!res.ok) throw await apiFailure(res, "Could not start checkout");
      return (await res.json()) as { url?: string; redirect?: boolean };
    }),

  portal: authedProcedure.mutation(async () => {
    const site = import.meta.env.VITE_SITE_URL ?? "https://capturecat.so";
    const res = await apiFetch("/api/auth/subscription/billing-portal", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ returnUrl: `${site}/app/billing` }),
    });
    if (!res.ok) throw await apiFailure(res, "Could not open billing portal");
    return (await res.json()) as { url?: string; redirect?: boolean };
  }),
});
