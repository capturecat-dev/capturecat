/**
 * POST /mcp — the remote MCP endpoint, served at https://mcp.capturecat.so/mcp
 * (its own custom domain on this Worker; index.ts lets that host reach
 * nothing else) and, as an alias, at api.capturecat.so/mcp — which is also
 * what `wrangler dev` serves on localhost.
 *
 * AUTH is an agent credential only (lib/agent-tokens.ts): a personal token
 * (`Bearer cc_pat_…`) or an OAuth access token (`Bearer cc_oat_…`, issued by
 * "Sign in with CaptureCat" — lib/oauth/ — for THIS resource only: a token
 * minted for another audience is refused). No cookies are read, so the
 * endpoint needs no CSRF defence and its CORS policy can be `*` without
 * credentials. A missing, malformed, unknown, revoked or expired token is 401
 * with an RFC 6750 challenge naming the RFC 9728 metadata, which is how an
 * MCP client discovers the OAuth flow.
 *
 * PLAN: every request re-checks the user's plan for `agentAccess` (a 403
 * that says why when it is off) — the same entitlement path as the session
 * routes, resolved once per request and handed to the tools.
 *
 * SCOPES: an OAuth token calling a tool outside its scopes gets HTTP 403
 * `insufficient_scope` with a `scope=` hint, so the client can step up
 * (re-authorize with more). A personal token can't step up — the owner
 * makes a new one — so for it a missing scope stays a readable tool error.
 *
 * RATE LIMITS are per TOKEN, in D1: cloud agents (a Claude.ai connector,
 * ChatGPT) reach us from a few shared egress IPs, so a per-IP limit here
 * would throttle every user of a platform together — the lesson of the
 * Stripe webhook limiter in index.ts. Individual tools add their own
 * per-token limits where the session route has one (comments, screenshots).
 */

import { Hono } from "hono";
import type { Env, Variables } from "../types";
import { resolveAgentToken, bearerToken, writeAgentAudit, type AgentPrincipal } from "../lib/agent-tokens";
import { fixedWindowAllow } from "../lib/entitlement";
import { agentPlanFor, featureUnavailableMessage } from "../lib/agent-features";
import { mcpResource, protectedResourceMetadataUrl } from "../lib/oauth/config";
import {
  RPC,
  handleMessage,
  isSupportedProtocolVersion,
  missingScope,
  rpcError,
  SUPPORTED_PROTOCOL_VERSIONS,
  type JsonRpcResponse,
  type RequestScope,
} from "./server";
import { findTool } from "./tools";

export const mcpRoutes = new Hono<{ Bindings: Env; Variables: Variables }>();

/** RFC 6750 §3 + RFC 9728 §5.1: no `error` when no credential was sent;
 *  `resource_metadata` always, so an MCP client can find the OAuth server. */
export function wwwAuthenticate(env: Env, error?: "invalid_token" | "insufficient_scope", scope?: string): string {
  return [
    'Bearer realm="capturecat"',
    ...(error ? [`error="${error}"`] : []),
    ...(scope ? [`scope="${scope}"`] : []),
    `resource_metadata="${protectedResourceMetadataUrl(env)}"`,
  ].join(", ");
}

/** A single tools/call this OAuth token's scopes don't cover: the scope the
 *  client should add (with the ones it holds, for one re-authorization). */
function stepUpScope(principal: AgentPrincipal, body: unknown): { tool: string; needed: string; hint: string } | null {
  if (principal.kind !== "oauth" || !body || typeof body !== "object" || Array.isArray(body)) return null;
  const msg = body as { method?: unknown; params?: { name?: unknown } };
  if (msg.method !== "tools/call" || typeof msg.params?.name !== "string") return null;
  const tool = findTool(msg.params.name);
  if (!tool) return null;
  const needed = missingScope(principal, tool);
  if (!needed) return null;
  return { tool: tool.name, needed, hint: [...new Set([...principal.scopes, needed])].join(" ") };
}
/** A comment with the largest drawing is < 96 KB; anything near this is not
 *  a real MCP message. */
const MAX_BODY_BYTES = 256 * 1024;
/** POSTs per token per minute (each may carry a batch). */
export const MCP_TOKEN_RATE_LIMIT = 120;
/** Where the card lives; the MCP host redirects its well-known path there. */
const SERVER_CARD_URL = "https://capturecat.so/.well-known/mcp/server-card.json";

mcpRoutes.post("/mcp", async (c) => {
  const sent = bearerToken(c.req.header("Authorization"));
  let principal = await resolveAgentToken(c.env.DB, c.req.header("Authorization"));
  // RFC 8707: an OAuth token is good only for the resource it was issued for.
  if (principal?.kind === "oauth" && principal.resource !== mcpResource(c.env)) principal = null;
  if (!principal) {
    return c.json(
      {
        error: sent ? "invalid_token" : "unauthorized",
        error_description:
          "Connect with OAuth (\"Sign in with CaptureCat\" — discovered from the resource_metadata in WWW-Authenticate) or send a CaptureCat agent token: Authorization: Bearer cc_pat_… — create one in CaptureCat → Settings → Agent access (https://app.capturecat.so/settings). Tokens that are revoked or expired stop working immediately.",
      },
      401,
      { "WWW-Authenticate": wwwAuthenticate(c.env, sent ? "invalid_token" : undefined) },
    );
  }
  // Same rule as requireAuth: a blocked account is refused everywhere.
  if (principal.claims.blocked) {
    return c.json({ error: "account_blocked", error_description: "This account is blocked." }, 403);
  }
  // Plan gate, on EVERY request: a downgrade cuts agents off at once.
  const resolved = await agentPlanFor(c.env.DB, principal.uid, principal.claims);
  if (resolved === "blocked") {
    return c.json({ error: "account_blocked", error_description: "This account is blocked." }, 403);
  }
  if (!resolved.plan.features.agentAccess) {
    return c.json(
      {
        error: "plan_feature_unavailable",
        feature: "agentAccess",
        error_description: featureUnavailableMessage("agentAccess", resolved.plan),
      },
      403,
    );
  }

  const version = c.req.header("MCP-Protocol-Version");
  if (version && !isSupportedProtocolVersion(version)) {
    return c.json(
      rpcError(null, RPC.INVALID_REQUEST, `Unsupported MCP-Protocol-Version "${version}". Supported: ${SUPPORTED_PROTOCOL_VERSIONS.join(", ")}.`),
      400,
    );
  }

  if (!(await fixedWindowAllow(c.env.DB, `mcp:${principal.tokenId}`, MCP_TOKEN_RATE_LIMIT, 60))) {
    return c.json(
      { error: "rate_limited", error_description: `At most ${MCP_TOKEN_RATE_LIMIT} requests a minute per token.` },
      429,
      { "Retry-After": "60" },
    );
  }

  if (Number(c.req.header("Content-Length") ?? "0") > MAX_BODY_BYTES) {
    return c.json(rpcError(null, RPC.INVALID_REQUEST, "Request body too large"), 413);
  }
  const raw = await c.req.text().catch(() => "");
  if (raw.length > MAX_BODY_BYTES) {
    return c.json(rpcError(null, RPC.INVALID_REQUEST, "Request body too large"), 413);
  }
  let body: unknown;
  try {
    body = JSON.parse(raw);
  } catch {
    return c.json(rpcError(null, RPC.PARSE_ERROR, "Parse error: the body must be JSON"), 400);
  }

  const scope: RequestScope = {
    plan: resolved,
    waitUntil: (promise) => {
      try {
        c.executionCtx.waitUntil(promise);
      } catch {
        // No ExecutionContext (a test calling app.request): let it run detached.
      }
    },
  };

  // OAuth step-up: HTTP 403 insufficient_scope instead of a tool error.
  const stepUp = stepUpScope(principal, body);
  if (stepUp) {
    await writeAgentAudit(c.env.DB, {
      uid: principal.uid,
      tokenId: principal.tokenId,
      tool: stepUp.tool,
      ok: false,
      error: `missing scope ${stepUp.needed}`,
    });
    return c.json(
      {
        error: "insufficient_scope",
        error_description: `${stepUp.tool} needs the "${stepUp.needed}" scope, which this connection was not granted. Re-authorize with scope "${stepUp.hint}".`,
        scope: stepUp.hint,
      },
      403,
      { "WWW-Authenticate": wwwAuthenticate(c.env, "insufficient_scope", stepUp.hint) },
    );
  }

  // Batches run in order, one at a time: each tool call is one audit row
  // and a handful of D1 statements, and order is what the client sent.
  if (Array.isArray(body)) {
    if (body.length === 0) return c.json(rpcError(null, RPC.INVALID_REQUEST, "Invalid Request: empty batch"), 400);
    const responses: JsonRpcResponse[] = [];
    for (const message of body.slice(0, 50)) {
      const response = await handleMessage(c.env, principal, message, scope);
      if (response) responses.push(response);
    }
    if (body.length > 50) responses.push(rpcError(null, RPC.INVALID_REQUEST, "Batch truncated at 50 messages"));
    return responses.length > 0 ? c.json(responses) : c.body(null, 202);
  }

  const response = await handleMessage(c.env, principal, body, scope);
  return response ? c.json(response) : c.body(null, 202);
});

// No server-initiated stream and no sessions to end: only POST is served.
mcpRoutes.on(["GET", "DELETE"], "/mcp", (c) =>
  c.json(
    { error: "method_not_allowed", error_description: "This MCP endpoint is stateless Streamable HTTP: POST JSON-RPC messages to it." },
    405,
    { Allow: "POST, OPTIONS" },
  ),
);

// The server card is published by the website with the rest of the
// discovery files; the MCP host's well-known path points there.
mcpRoutes.get("/.well-known/mcp/server-card.json", (c) => c.redirect(SERVER_CARD_URL, 302));
