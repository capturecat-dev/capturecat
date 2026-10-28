/**
 * "Sign in with CaptureCat" — the OAuth 2.1 authorization server for the
 * remote MCP server (lib/oauth/*, migration 0035).
 *
 * Discovery
 *   GET /.well-known/oauth-protected-resource[/mcp]   RFC 9728 (also on mcp.capturecat.so)
 *   GET /.well-known/oauth-authorization-server       RFC 8414
 *
 * Protocol (no cookies; CORS * in index.ts)
 *   GET  /oauth/authorize    validate, then 302 to the web consent page
 *                            (app.capturecat.so/oauth/authorize)
 *   POST /oauth/token        authorization_code (+ PKCE S256) | refresh_token (rotating)
 *   POST /oauth/register     Dynamic Client Registration (RFC 7591)
 *   POST /oauth/revoke       RFC 7009
 *
 * The consent page's API (SESSION ONLY — agent credentials refused)
 *   GET  /api/oauth/authorize/info       what the page shows
 *   POST /api/oauth/authorize/decision   { params, approve, scopes? } → { redirect }
 *   GET  /api/oauth/apps                 connected apps, grouped by client
 *   POST /api/oauth/apps/revoke          { clientId } → revoke every grant to it
 */

import { Hono, type Context } from "hono";
import { z } from "zod";
import type { Env, Variables } from "../types";
import { requireAuth } from "../middleware/auth";
import { refuseAgentCredentials } from "../middleware/session-only";
import { fixedWindowAllow, userRateLimit } from "../lib/entitlement";
import { parseJsonBody } from "../lib/validate";
import { AGENT_SCOPES, writeAgentAudit } from "../lib/agent-tokens";
import { agentPlanFor, featureUnavailableMessage } from "../lib/agent-features";
import { consentPageUrl, mcpResource, oauthIssuer } from "../lib/oauth/config";
import { shareBaseURL } from "../lib/origins";
import { authenticateClient, registerClient, resolveClient, type OAuthClient } from "../lib/oauth/clients";
import {
  AUTHORIZE_PARAM_NAMES,
  buildRedirect,
  consentQuery,
  validateAuthorizeRequest,
  type AuthorizeParams,
} from "../lib/oauth/authorize";
import {
  exchangeAuthorizationCode,
  issueAuthorizationCode,
  listConnectedApps,
  oauthError,
  parseScopeParam,
  refreshTokens,
  revokeClientForUser,
  revokeOAuthToken,
  type OAuthError,
} from "../lib/oauth/tokens";

export const oauthRoutes = new Hono<{ Bindings: Env; Variables: Variables }>();

const DISCOVERY_CACHE = "public, max-age=3600";
const NO_STORE = { "Cache-Control": "no-store", Pragma: "no-cache" };

// ---------------------------------------------------------------------------
// Discovery
// ---------------------------------------------------------------------------

export function protectedResourceMetadata(env: Env) {
  return {
    resource: mcpResource(env),
    authorization_servers: [oauthIssuer(env)],
    scopes_supported: [...AGENT_SCOPES],
    bearer_methods_supported: ["header"],
    resource_name: "CaptureCat",
    resource_documentation: "https://capturecat.so/agents",
  };
}

export function authorizationServerMetadata(env: Env) {
  const issuer = oauthIssuer(env);
  const site = shareBaseURL(env);
  return {
    issuer,
    // RFC 9728 §4: the resources this server issues tokens for. The site
    // origin is listed too because the Personal Agent Protocol (Poppy,
    // capturecat.so/.well-known/poppy.json) binds a domain to its issuer
    // through this list; `poppy_domains` is the same binding as the
    // isitagentready.com scanner reads it.
    protected_resources: [mcpResource(env), site],
    poppy_domains: [new URL(site).hostname],
    authorization_endpoint: `${issuer}/oauth/authorize`,
    token_endpoint: `${issuer}/oauth/token`,
    registration_endpoint: `${issuer}/oauth/register`,
    revocation_endpoint: `${issuer}/oauth/revoke`,
    scopes_supported: [...AGENT_SCOPES],
    response_types_supported: ["code"],
    response_modes_supported: ["query"],
    grant_types_supported: ["authorization_code", "refresh_token"],
    token_endpoint_auth_methods_supported: ["none", "client_secret_post", "client_secret_basic"],
    revocation_endpoint_auth_methods_supported: ["none", "client_secret_post", "client_secret_basic"],
    code_challenge_methods_supported: ["S256"],
    client_id_metadata_document_supported: true,
    authorization_response_iss_parameter_supported: true,
    service_documentation: "https://capturecat.so/auth.md",
  };
}

for (const path of ["/.well-known/oauth-protected-resource", "/.well-known/oauth-protected-resource/mcp"]) {
  oauthRoutes.get(path, (c) => c.json(protectedResourceMetadata(c.env), 200, { "Cache-Control": DISCOVERY_CACHE }));
}
oauthRoutes.get("/.well-known/oauth-authorization-server", (c) =>
  c.json(authorizationServerMetadata(c.env), 200, { "Cache-Control": DISCOVERY_CACHE }),
);

// ---------------------------------------------------------------------------
// GET /oauth/authorize
// ---------------------------------------------------------------------------

function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, (ch) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[ch]!);
}

/** The page for an error that must not go to an unverified redirect URI. */
function errorPage(c: Context, error: string, description: string) {
  return c.html(
    `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">` +
      `<title>Can't connect — CaptureCat</title><style>body{font:15px/1.5 -apple-system,system-ui,sans-serif;max-width:32rem;margin:15vh auto;padding:0 1rem;color:#222}` +
      `@media(prefers-color-scheme:dark){body{background:#111;color:#eee}}code{font-size:13px;opacity:.7}</style></head><body>` +
      `<h1 style="font-size:20px">This app can't connect to CaptureCat</h1><p>${escapeHtml(description)}</p>` +
      `<p><code>${escapeHtml(error)}</code></p><p>Tell the developer of the app you came from.</p></body></html>`,
    400,
    { "Cache-Control": "no-store" },
  );
}

function paramsFrom(get: (name: string) => string | undefined | null): AuthorizeParams {
  const out: AuthorizeParams = {};
  for (const name of AUTHORIZE_PARAM_NAMES) {
    const v = get(name);
    if (typeof v === "string") out[name] = v;
  }
  return out;
}

oauthRoutes.get("/oauth/authorize", async (c) => {
  const v = await validateAuthorizeRequest(c.env, paramsFrom((n) => c.req.query(n)));
  if (!v.ok) {
    if (!v.redirectable) return errorPage(c, v.error, v.description);
    return c.redirect(buildRedirect(c.env, v.redirectUri, { error: v.error, error_description: v.description, state: v.state }), 302);
  }
  // The consent page re-validates all of this server-side before a code.
  return c.redirect(`${consentPageUrl(c.env)}?${consentQuery(v).toString()}`, 302);
});

// ---------------------------------------------------------------------------
// Token endpoint
// ---------------------------------------------------------------------------

/** Form (the standard) or JSON (some clients) body → flat string map. */
async function readParams(c: Context): Promise<Record<string, string>> {
  const type = c.req.header("Content-Type") ?? "";
  const text = await c.req.text().catch(() => "");
  if (text.length > 16 * 1024) return {};
  if (type.includes("application/json")) {
    try {
      const parsed: unknown = JSON.parse(text);
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return {};
      return Object.fromEntries(
        Object.entries(parsed as Record<string, unknown>).filter((e): e is [string, string] => typeof e[1] === "string"),
      );
    } catch {
      return {};
    }
  }
  return Object.fromEntries(new URLSearchParams(text));
}

function tokenError(c: Context, err: OAuthError) {
  const status = err.error === "invalid_client" ? 401 : 400;
  return c.json({ error: err.error, error_description: err.description }, status, {
    ...NO_STORE,
    ...(status === 401 ? { "WWW-Authenticate": 'Basic realm="capturecat"' } : {}),
  });
}

/** client_id (+ secret) from Basic auth or the body; then the client. */
async function authenticatedClient(
  c: Context<{ Bindings: Env; Variables: Variables }>,
  params: Record<string, string>,
): Promise<{ ok: true; client: OAuthClient } | OAuthError> {
  let clientId = params.client_id ?? null;
  let secret = params.client_secret ?? null;
  const basic = /^Basic\s+(\S+)$/i.exec(c.req.header("Authorization") ?? "");
  if (basic) {
    try {
      const [id, sec] = atob(basic[1]).split(":", 2);
      const decodedId = decodeURIComponent(id ?? "");
      if (clientId && clientId !== decodedId) return oauthError("invalid_request", "client_id differs between the body and Basic auth.");
      clientId = decodedId;
      secret = decodeURIComponent(sec ?? "");
    } catch {
      return oauthError("invalid_client", "Malformed Basic credentials.");
    }
  }
  if (!clientId) return oauthError("invalid_client", "client_id is required.");
  const resolved = await resolveClient(c.env, clientId);
  if (!resolved.ok) return oauthError("invalid_client", resolved.error);
  if (!(await authenticateClient(resolved.client, secret))) return oauthError("invalid_client", "Client authentication failed.");
  return { ok: true, client: resolved.client };
}

oauthRoutes.post("/oauth/token", async (c) => {
  const params = await readParams(c);
  const grantType = params.grant_type;
  if (grantType !== "authorization_code" && grantType !== "refresh_token") {
    return tokenError(c, oauthError("unsupported_grant_type", "grant_type must be authorization_code or refresh_token."));
  }
  const auth = await authenticatedClient(c, params);
  if (!auth.ok) return tokenError(c, auth);
  const client = auth.client;
  if (!client.grantTypes.includes(grantType)) {
    return tokenError(c, oauthError("unauthorized_client", `This client did not register the ${grantType} grant.`));
  }
  const resource = params.resource ? params.resource.replace(/\/+$/, "") : null;
  if (resource !== null && resource !== mcpResource(c.env)) {
    return tokenError(c, oauthError("invalid_target", `resource must be ${mcpResource(c.env)}.`));
  }
  const result =
    grantType === "authorization_code"
      ? await exchangeAuthorizationCode(c.env, client, {
          code: params.code,
          redirectUri: params.redirect_uri,
          codeVerifier: params.code_verifier,
          resource,
        })
      : await refreshTokens(c.env, client, { refreshToken: params.refresh_token, scope: params.scope ?? null, resource });
  if (!result.ok) return tokenError(c, result);
  const { ok: _ok, ...body } = result;
  return c.json(body, 200, NO_STORE);
});

// ---------------------------------------------------------------------------
// Dynamic Client Registration
// ---------------------------------------------------------------------------

/** New clients per IP per hour — bounds oauth_clients growth from a script
 *  while leaving room for a hosted client (ChatGPT…) registering for many
 *  users from shared egress IPs. Unused registrations are swept after 30
 *  days (index.ts). */
const REGISTRATIONS_PER_IP_HOUR = 600;

oauthRoutes.post("/oauth/register", async (c) => {
  const ip = c.req.header("CF-Connecting-IP") ?? "unknown";
  if (!(await fixedWindowAllow(c.env.DB, `oauth-register:${ip}`, REGISTRATIONS_PER_IP_HOUR, 3600))) {
    return c.json({ error: "invalid_client_metadata", error_description: "Too many registrations; try again later." }, 429, {
      "Retry-After": "3600",
    });
  }
  let body: unknown;
  try {
    const text = await c.req.text();
    if (text.length > 16 * 1024) throw new Error("too large");
    body = JSON.parse(text);
  } catch {
    return c.json({ error: "invalid_client_metadata", error_description: "The body must be a JSON object." }, 400, NO_STORE);
  }
  const result = await registerClient(c.env.DB, body);
  if (!result.ok) return c.json({ error: result.error, error_description: result.description }, 400, NO_STORE);
  const client = result.client;
  return c.json(
    {
      client_id: client.clientId,
      client_id_issued_at: result.issuedAt,
      ...(result.clientSecret ? { client_secret: result.clientSecret, client_secret_expires_at: 0 } : {}),
      client_name: client.clientName,
      redirect_uris: client.redirectUris,
      grant_types: client.grantTypes,
      response_types: ["code"],
      token_endpoint_auth_method: client.tokenEndpointAuthMethod,
      ...(client.clientUri ? { client_uri: client.clientUri } : {}),
      ...(client.logoUri ? { logo_uri: client.logoUri } : {}),
      scope: AGENT_SCOPES.join(" "),
    },
    201,
    NO_STORE,
  );
});

// ---------------------------------------------------------------------------
// RFC 7009 revocation
// ---------------------------------------------------------------------------

oauthRoutes.post("/oauth/revoke", async (c) => {
  const params = await readParams(c);
  const auth = await authenticatedClient(c, params);
  if (!auth.ok) return tokenError(c, auth);
  if (!params.token) return tokenError(c, oauthError("invalid_request", "token is required."));
  await revokeOAuthToken(c.env.DB, auth.client, params.token);
  return c.body(null, 200, NO_STORE);
});

// ---------------------------------------------------------------------------
// The consent page's API (session only)
// ---------------------------------------------------------------------------

oauthRoutes.use("/api/oauth/*", refuseAgentCredentials, requireAuth);

function clientView(client: OAuthClient, redirectUri: string) {
  let redirectHost = redirectUri;
  try {
    const u = new URL(redirectUri);
    redirectHost = u.host || `${u.protocol}//`;
  } catch {
    // keep the raw string
  }
  return {
    clientId: client.clientId,
    name: client.clientName,
    kind: client.kind,
    logoUri: client.logoUri,
    clientUri: client.clientUri,
    /** A metadata document's host is proven by serving it; a registered
     *  client's name is only its own claim. */
    verifiedHost: client.kind === "cimd" ? new URL(client.clientId).hostname : null,
    redirectUri,
    redirectHost,
  };
}

oauthRoutes.get("/api/oauth/authorize/info", async (c) => {
  const v = await validateAuthorizeRequest(c.env, paramsFrom((n) => c.req.query(n)));
  if (!v.ok) {
    return c.json(
      {
        error: v.error,
        description: v.description,
        redirect: v.redirectable ? buildRedirect(c.env, v.redirectUri, { error: v.error, error_description: v.description, state: v.state }) : null,
      },
      400,
    );
  }
  const user = c.get("user");
  const resolved = await agentPlanFor(c.env.DB, user.uid, user.claims);
  const available = resolved !== "blocked" && resolved.plan.features.agentAccess === true;
  return c.json({
    client: clientView(v.client, v.redirectUri),
    scopes: v.scopes,
    resource: v.resource,
    available,
    unavailableReason: available || resolved === "blocked" ? null : featureUnavailableMessage("agentAccess", resolved.plan),
  });
});

const DecisionSchema = z.object({
  params: z.record(z.string(), z.string().max(2000)),
  approve: z.boolean(),
  /** The scopes the user left ticked — only ever a subset of the request. */
  scopes: z.array(z.string()).max(AGENT_SCOPES.length * 2).optional(),
});

oauthRoutes.post(
  "/api/oauth/authorize/decision",
  userRateLimit({ limit: 30, windowSec: 60, scope: "oauth-consent" }),
  async (c) => {
    const parsed = await parseJsonBody(c.req, DecisionSchema);
    if (!parsed.ok) return c.json({ error: parsed.error }, 400);
    const v = await validateAuthorizeRequest(c.env, paramsFrom((n) => parsed.data.params[n]));
    if (!v.ok) {
      if (!v.redirectable) return c.json({ error: v.error, description: v.description, redirect: null }, 400);
      return c.json({
        redirect: buildRedirect(c.env, v.redirectUri, { error: v.error, error_description: v.description, state: v.state }),
      });
    }
    if (!parsed.data.approve) {
      return c.json({
        redirect: buildRedirect(c.env, v.redirectUri, {
          error: "access_denied",
          error_description: "The user denied access.",
          state: v.state,
        }),
      });
    }
    const user = c.get("user");
    const resolved = await agentPlanFor(c.env.DB, user.uid, user.claims);
    if (resolved === "blocked") return c.json({ error: "Account blocked" }, 403);
    if (!resolved.plan.features.agentAccess) {
      return c.json({ error: featureUnavailableMessage("agentAccess", resolved.plan), code: "upgrade_required", feature: "agentAccess" }, 403);
    }
    // Narrow only: a ticked box that was not requested is ignored.
    const kept = parsed.data.scopes ? parseScopeParam(parsed.data.scopes.join(" ")).filter((s) => v.scopes.includes(s)) : v.scopes;
    if (kept.length === 0) return c.json({ error: "Allow at least one permission, or choose Deny." }, 400);
    const code = await issueAuthorizationCode(c.env.DB, {
      clientId: v.client.clientId,
      uid: user.uid,
      redirectUri: v.redirectUri,
      codeChallenge: v.codeChallenge,
      scopes: kept,
      resource: v.resource,
    });
    return c.json({ redirect: buildRedirect(c.env, v.redirectUri, { code, state: v.state }) });
  },
);

oauthRoutes.get("/api/oauth/apps", async (c) => {
  return c.json({ apps: await listConnectedApps(c.env.DB, c.get("user").uid) });
});

oauthRoutes.post("/api/oauth/apps/revoke", userRateLimit({ limit: 30, windowSec: 60, scope: "oauth-apps" }), async (c) => {
  const parsed = await parseJsonBody(c.req, z.object({ clientId: z.string().min(1).max(1000) }));
  if (!parsed.ok) return c.json({ error: parsed.error }, 400);
  const uid = c.get("user").uid;
  const revoked = await revokeClientForUser(c.env.DB, uid, parsed.data.clientId);
  if (revoked === 0) return c.json({ error: "No connected app with that id" }, 404);
  // Audited under the client's latest access token, so "Recent agent
  // activity" shows when the user cut the connection.
  const token = await c.env.DB.prepare(
    `SELECT id FROM agent_tokens WHERE user_id = ?1 AND oauth_client_id = ?2 ORDER BY created_at DESC LIMIT 1`,
  )
    .bind(uid, parsed.data.clientId)
    .first<{ id: string }>();
  if (token) await writeAgentAudit(c.env.DB, { uid, tokenId: token.id, tool: "oauth.revoked", ok: true });
  return c.json({ clientId: parsed.data.clientId, revoked });
});
