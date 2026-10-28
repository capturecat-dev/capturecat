/**
 * /api/webhooks — manage webhook endpoints (lib/webhooks.ts, migration 0036).
 *
 *   GET    /webhooks                     endpoints + the event catalogue + whether the plan has webhooks
 *   POST   /webhooks                     { url, events, description? } → the endpoint and its secret, ONCE
 *   PATCH  /webhooks/:id                 { active?, events?, url?, description? }
 *   DELETE /webhooks/:id                 the endpoint and its delivery history
 *   POST   /webhooks/:id/test            send a webhook.test event now, answer how it went
 *   GET    /webhooks/:id/deliveries      the most recent deliveries
 *
 * SESSION ONLY (agents use the MCP tools list_webhooks / create_webhook,
 * which cannot switch endpoints off, delete them or read secrets). Creating,
 * re-enabling and testing need the plan's `agentWebhooks`; listing, switching
 * off and deleting never do — a downgraded user can always clean up.
 */

import { Hono } from "hono";
import { z } from "zod";
import type { Env, Variables } from "../types";
import { requireAuth } from "../middleware/auth";
import { refuseAgentCredentials } from "../middleware/session-only";
import { userRateLimit } from "../lib/entitlement";
import { parseJsonBody } from "../lib/validate";
import { agentPlanFor, upgradeRequiredBody } from "../lib/agent-features";
import {
  MAX_WEBHOOK_ENDPOINTS,
  WEBHOOK_EVENTS,
  WEBHOOK_EVENT_INFO,
  createWebhookEndpoint,
  deleteWebhookEndpoint,
  getWebhookEndpoint,
  listWebhookDeliveries,
  listWebhookEndpoints,
  sendTestWebhook,
  updateWebhookEndpoint,
} from "../lib/webhooks";

export const webhookRoutes = new Hono<{ Bindings: Env; Variables: Variables }>();

webhookRoutes.use("/webhooks/*", refuseAgentCredentials, requireAuth);

const EventsSchema = z
  .array(z.enum(WEBHOOK_EVENTS, { error: `Unknown event. Valid events: ${WEBHOOK_EVENTS.join(", ")}` }), {
    error: "events must be an array",
  })
  .min(1, { error: "Choose at least one event" })
  .max(WEBHOOK_EVENTS.length, { error: "Too many events" });

const CreateSchema = z.object({
  url: z.string({ error: "url is required" }).trim().min(1, { error: "url is required" }).max(2048),
  events: EventsSchema,
  description: z.string().trim().max(100).nullable().optional(),
});

const PatchSchema = z
  .object({
    active: z.boolean().optional(),
    events: EventsSchema.optional(),
    url: z.string().trim().min(1).max(2048).optional(),
    description: z.string().trim().max(100).nullable().optional(),
  })
  .refine((p) => Object.values(p).some((v) => v !== undefined), { error: "Nothing to change" });

/** The caller's plan if it includes webhooks, else the 403 to answer. */
async function webhooksGate(c: { env: Env; get(key: "user"): Variables["user"] }) {
  const user = c.get("user");
  const resolved = await agentPlanFor(c.env.DB, user.uid, user.claims);
  if (resolved === "blocked") return { ok: false as const, body: { error: "Account blocked" } };
  if (!resolved.plan.features.agentWebhooks) return { ok: false as const, body: upgradeRequiredBody("agentWebhooks", resolved.plan) };
  return { ok: true as const };
}

webhookRoutes.get("/webhooks", async (c) => {
  const user = c.get("user");
  const resolved = await agentPlanFor(c.env.DB, user.uid, user.claims);
  return c.json({
    endpoints: await listWebhookEndpoints(c.env.DB, user.uid),
    events: WEBHOOK_EVENTS.map((name) => ({ name, description: WEBHOOK_EVENT_INFO[name] })),
    available: resolved !== "blocked" && resolved.plan.features.agentWebhooks === true,
    maxEndpoints: MAX_WEBHOOK_ENDPOINTS,
  });
});

webhookRoutes.post("/webhooks", userRateLimit({ limit: 20, windowSec: 60, scope: "webhooks" }), async (c) => {
  const gate = await webhooksGate(c);
  if (!gate.ok) return c.json(gate.body, 403);
  const parsed = await parseJsonBody(c.req, CreateSchema);
  if (!parsed.ok) return c.json({ error: parsed.error }, 400);
  const created = await createWebhookEndpoint(c.env, {
    uid: c.get("user").uid,
    url: parsed.data.url,
    events: parsed.data.events,
    description: parsed.data.description ?? null,
  });
  if (!created.ok) return c.json({ error: created.error }, created.status);
  // The plaintext secret appears in this response and NOWHERE else.
  return c.json({ endpoint: created.endpoint, secret: created.secret }, 201);
});

webhookRoutes.patch("/webhooks/:id", userRateLimit({ limit: 60, windowSec: 60, scope: "webhooks" }), async (c) => {
  const parsed = await parseJsonBody(c.req, PatchSchema);
  if (!parsed.ok) return c.json({ error: parsed.error }, 400);
  // Switching OFF is always allowed; anything that keeps or turns it on is
  // using the feature.
  if (parsed.data.active !== false) {
    const gate = await webhooksGate(c);
    if (!gate.ok) return c.json(gate.body, 403);
  }
  const result = await updateWebhookEndpoint(c.env.DB, c.get("user").uid, c.req.param("id"), parsed.data);
  if (!result.ok) return c.json({ error: result.error }, result.status);
  return c.json({ endpoint: result.endpoint });
});

webhookRoutes.delete("/webhooks/:id", async (c) => {
  const id = c.req.param("id");
  if (!(await deleteWebhookEndpoint(c.env.DB, c.get("user").uid, id))) {
    return c.json({ error: "No webhook endpoint with that id" }, 404);
  }
  return c.json({ id, deleted: true });
});

webhookRoutes.post("/webhooks/:id/test", userRateLimit({ limit: 10, windowSec: 60, scope: "webhook-test" }), async (c) => {
  const gate = await webhooksGate(c);
  if (!gate.ok) return c.json(gate.body, 403);
  const result = await sendTestWebhook(c.env, c.get("user").uid, c.req.param("id"));
  if (!result) return c.json({ error: "No webhook endpoint with that id" }, 404);
  return c.json(result);
});

webhookRoutes.get("/webhooks/:id/deliveries", async (c) => {
  const uid = c.get("user").uid;
  const id = c.req.param("id");
  if (!(await getWebhookEndpoint(c.env.DB, uid, id))) return c.json({ error: "No webhook endpoint with that id" }, 404);
  return c.json({ deliveries: await listWebhookDeliveries(c.env.DB, uid, id, 20) });
});
