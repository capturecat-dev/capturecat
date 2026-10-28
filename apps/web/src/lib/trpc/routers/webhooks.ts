import { z } from "zod";

import { apiFetch } from "@/lib/session";
import { authedProcedure, createTRPCRouter } from "@/lib/trpc/init";
import { WEBHOOK_EVENTS, type WebhookDelivery, type WebhookEndpointSummary } from "@/lib/agent-access";
import { fail } from "./agent-tokens";

/**
 * Webhook endpoints — api.capturecat.so /api/webhooks
 * (apps/api/src/routes/webhooks.ts). The API checks the URL (https, public
 * hosts only), the plan gate and the caps; the secret passes through
 * `create` once and is never cached here.
 */
const Id = z.object({ id: z.string().min(1).max(64) });
const Events = z.array(z.enum(WEBHOOK_EVENTS)).min(1);

export const webhooksRouter = createTRPCRouter({
  list: authedProcedure.query(async () => {
    const res = await apiFetch("/api/webhooks");
    if (!res.ok) return fail(res, "Could not load webhooks");
    return (await res.json()) as {
      endpoints: WebhookEndpointSummary[];
      events: Array<{ name: string; description: string }>;
      available: boolean;
      maxEndpoints: number;
    };
  }),

  create: authedProcedure
    .input(z.object({ url: z.string().trim().min(1).max(2048), events: Events, description: z.string().trim().max(100).optional() }))
    .mutation(async ({ input }) => {
      const res = await apiFetch("/api/webhooks", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(input),
      });
      if (!res.ok) return fail(res, "Could not add the endpoint");
      return (await res.json()) as { endpoint: WebhookEndpointSummary; secret: string };
    }),

  update: authedProcedure
    .input(Id.extend({ active: z.boolean().optional(), events: Events.optional() }))
    .mutation(async ({ input }) => {
      const { id, ...patch } = input;
      const res = await apiFetch(`/api/webhooks/${encodeURIComponent(id)}`, {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(patch),
      });
      if (!res.ok) return fail(res, "Could not update the endpoint");
      return (await res.json()) as { endpoint: WebhookEndpointSummary };
    }),

  remove: authedProcedure.input(Id).mutation(async ({ input }) => {
    const res = await apiFetch(`/api/webhooks/${encodeURIComponent(input.id)}`, { method: "DELETE" });
    if (!res.ok) return fail(res, "Could not delete the endpoint");
    return (await res.json()) as { id: string; deleted: true };
  }),

  test: authedProcedure.input(Id).mutation(async ({ input }) => {
    const res = await apiFetch(`/api/webhooks/${encodeURIComponent(input.id)}/test`, { method: "POST" });
    if (!res.ok) return fail(res, "Could not send the test event");
    return (await res.json()) as { delivery: WebhookDelivery };
  }),

  deliveries: authedProcedure.input(Id).query(async ({ input }) => {
    const res = await apiFetch(`/api/webhooks/${encodeURIComponent(input.id)}/deliveries`);
    if (!res.ok) return fail(res, "Could not load deliveries");
    return (await res.json()) as { deliveries: WebhookDelivery[] };
  }),
});
