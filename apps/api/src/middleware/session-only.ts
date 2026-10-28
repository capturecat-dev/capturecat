import { createMiddleware } from "hono/factory";
import type { Env, Variables } from "../types";
import { bearerToken, isAgentTokenShape } from "../lib/agent-tokens";

/**
 * Refuse every agent credential — a personal agent token (cc_pat_) or an
 * OAuth access token (cc_oat_) — with an explicit 403, before requireAuth.
 *
 * requireAuth only accepts Better Auth sessions, so such a token would fail
 * there anyway (401). This makes the refusal deliberate rather than an
 * accident of the session lookup, on every route an agent must never reach:
 * token management, approving its own "ask me first" requests, OAuth consent
 * and connected-app management, webhook management.
 */
export const refuseAgentCredentials = createMiddleware<{ Bindings: Env; Variables: Variables }>(async (c, next) => {
  const bearer = bearerToken(c.req.header("Authorization"));
  if (bearer && isAgentTokenShape(bearer)) {
    return c.json(
      {
        error: "Agent credentials can't be used here. The account owner must do this while signed in to CaptureCat.",
        code: "agent_token_forbidden",
      },
      403,
    );
  }
  await next();
});
