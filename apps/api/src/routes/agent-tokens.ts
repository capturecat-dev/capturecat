/**
 * /api/agent-tokens — manage the scoped tokens cloud agents use with the
 * remote MCP server (lib/agent-tokens.ts, src/mcp/).
 *
 *   GET    /agent-tokens          the user's tokens (hashes never leave D1)
 *   POST   /agent-tokens          { name, scopes, expiresInDays? } → the token, ONCE
 *   DELETE /agent-tokens/:id      revoke
 *   GET    /agent-tokens/audit    the most recent agent tool calls
 *
 * SESSION ONLY, like /api/screenshot/keys: a leaked agent token must not be
 * able to mint a broader token, keep itself alive, or read what other tokens
 * did. requireAuth only accepts Better Auth sessions — an agent token would
 * already fail there with a 401 — and the guard below makes that refusal
 * explicit (403) rather than an accident of the session lookup.
 */

import { Hono } from "hono";
import { createMiddleware } from "hono/factory";
import { z } from "zod";
import type { Env, Variables } from "../types";
import { requireAuth } from "../middleware/auth";
import { userRateLimit } from "../lib/entitlement";
import { parseJsonBody } from "../lib/validate";
import {
  AGENT_SCOPES,
  MAX_ACTIVE_AGENT_TOKENS,
  bearerToken,
  countActiveAgentTokens,
  createAgentToken,
  isAgentTokenShape,
  listAgentAudit,
  listAgentTokens,
  revokeAgentToken,
} from "../lib/agent-tokens";

export const agentTokenRoutes = new Hono<{ Bindings: Env; Variables: Variables }>();

/** An agent token never manages agent tokens — refused before requireAuth. */
const refuseAgentTokens = createMiddleware<{ Bindings: Env; Variables: Variables }>(async (c, next) => {
  const bearer = bearerToken(c.req.header("Authorization"));
  if (bearer && isAgentTokenShape(bearer)) {
    return c.json({ error: "Agent tokens cannot manage agent tokens. Sign in to CaptureCat instead.", code: "agent_token_forbidden" }, 403);
  }
  await next();
});

// One pattern: Hono's `/*` also matches the bare `/agent-tokens`.
agentTokenRoutes.use("/agent-tokens/*", refuseAgentTokens, requireAuth);

const CreateAgentTokenSchema = z.object({
  name: z
    .string({ error: "name is required" })
    .trim()
    .min(1, { error: "name is required" })
    .max(60, { error: "name must be at most 60 characters" }),
  scopes: z
    .array(z.enum(AGENT_SCOPES, { error: `Unknown scope. Valid scopes: ${AGENT_SCOPES.join(", ")}` }), {
      error: "scopes must be an array",
    })
    .min(1, { error: "Choose at least one scope" })
    .max(AGENT_SCOPES.length * 2, { error: "Too many scopes" }),
  /** 1–365 days; null or absent = never expires. */
  expiresInDays: z.int().min(1).max(365).nullable().optional(),
});

agentTokenRoutes.get("/agent-tokens", async (c) => {
  return c.json({
    tokens: await listAgentTokens(c.env.DB, c.get("user").uid),
    scopes: AGENT_SCOPES,
    maxActive: MAX_ACTIVE_AGENT_TOKENS,
  });
});

agentTokenRoutes.post(
  "/agent-tokens",
  userRateLimit({ limit: 10, windowSec: 60, scope: "agent-tokens" }),
  async (c) => {
    const uid = c.get("user").uid;
    const parsed = await parseJsonBody(c.req, CreateAgentTokenSchema);
    if (!parsed.ok) return c.json({ error: parsed.error }, 400);

    if ((await countActiveAgentTokens(c.env.DB, uid)) >= MAX_ACTIVE_AGENT_TOKENS) {
      return c.json(
        { error: `At most ${MAX_ACTIVE_AGENT_TOKENS} active agent tokens. Revoke one first.`, code: "too_many_tokens" },
        400,
      );
    }

    const { token, summary } = await createAgentToken(c.env.DB, {
      uid,
      name: parsed.data.name,
      scopes: parsed.data.scopes,
      expiresInDays: parsed.data.expiresInDays ?? null,
    });
    // The plaintext token appears in this response and NOWHERE else.
    return c.json({ token, ...summary }, 201);
  },
);

agentTokenRoutes.get("/agent-tokens/audit", async (c) => {
  return c.json({ entries: await listAgentAudit(c.env.DB, c.get("user").uid, 50) });
});

agentTokenRoutes.delete("/agent-tokens/:id", async (c) => {
  const id = c.req.param("id");
  if (!(await revokeAgentToken(c.env.DB, c.get("user").uid, id))) {
    return c.json({ error: "No active token with that id" }, 404);
  }
  return c.json({ id, revoked: true });
});
