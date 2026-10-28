/**
 * POST /mcp — the remote MCP endpoint, served at https://mcp.capturecat.so/mcp
 * (its own custom domain on this Worker; index.ts lets that host reach
 * nothing else) and, as an alias, at api.capturecat.so/mcp — which is also
 * what `wrangler dev` serves on localhost.
 *
 * AUTH is an agent token only (lib/agent-tokens.ts): `Authorization: Bearer
 * cc_pat_…`. No cookies are read, so the endpoint needs no CSRF defence and
 * its CORS policy can be `*` without credentials. A missing, malformed,
 * unknown, revoked or expired token is 401 with an RFC 6750 challenge.
 *
 * RATE LIMITS are per TOKEN, in D1: cloud agents (a Claude.ai connector,
 * ChatGPT) reach us from a few shared egress IPs, so a per-IP limit here
 * would throttle every user of a platform together — the lesson of the
 * Stripe webhook limiter in index.ts. Individual tools add their own
 * per-token limits where the session route has one (comments, screenshots).
 */

import { Hono } from "hono";
import type { Env, Variables } from "../types";
import { resolveAgentToken } from "../lib/agent-tokens";
import { fixedWindowAllow } from "../lib/entitlement";
import {
  RPC,
  handleMessage,
  isSupportedProtocolVersion,
  rpcError,
  SUPPORTED_PROTOCOL_VERSIONS,
  type JsonRpcResponse,
} from "./server";

export const mcpRoutes = new Hono<{ Bindings: Env; Variables: Variables }>();

export const WWW_AUTHENTICATE = 'Bearer realm="capturecat", error="invalid_token"';
/** A comment with the largest drawing is < 96 KB; anything near this is not
 *  a real MCP message. */
const MAX_BODY_BYTES = 256 * 1024;
/** POSTs per token per minute (each may carry a batch). */
export const MCP_TOKEN_RATE_LIMIT = 120;
/** Where the card lives; the MCP host redirects its well-known path there. */
const SERVER_CARD_URL = "https://capturecat.so/.well-known/mcp/server-card.json";

mcpRoutes.post("/mcp", async (c) => {
  const principal = await resolveAgentToken(c.env.DB, c.req.header("Authorization"));
  if (!principal) {
    return c.json(
      {
        error: "invalid_token",
        error_description:
          "Send a valid CaptureCat agent token: Authorization: Bearer cc_pat_… — create one in CaptureCat → Settings → Agent access (https://app.capturecat.so/app/settings). Tokens that are revoked or expired stop working immediately.",
      },
      401,
      { "WWW-Authenticate": WWW_AUTHENTICATE },
    );
  }
  // Same rule as requireAuth: a blocked account is refused everywhere.
  if (principal.claims.blocked) {
    return c.json({ error: "account_blocked", error_description: "This account is blocked." }, 403);
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

  // Batches run in order, one at a time: each tool call is one audit row
  // and a handful of D1 statements, and order is what the client sent.
  if (Array.isArray(body)) {
    if (body.length === 0) return c.json(rpcError(null, RPC.INVALID_REQUEST, "Invalid Request: empty batch"), 400);
    const responses: JsonRpcResponse[] = [];
    for (const message of body.slice(0, 50)) {
      const response = await handleMessage(c.env, principal, message);
      if (response) responses.push(response);
    }
    if (body.length > 50) responses.push(rpcError(null, RPC.INVALID_REQUEST, "Batch truncated at 50 messages"));
    return responses.length > 0 ? c.json(responses) : c.body(null, 202);
  }

  const response = await handleMessage(c.env, principal, body);
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
