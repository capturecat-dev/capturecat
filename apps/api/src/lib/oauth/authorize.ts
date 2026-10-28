/**
 * The authorization request, validated the same way at every step:
 *
 *   GET  api.capturecat.so/oauth/authorize          → 302 to the web consent page
 *   GET  /api/oauth/authorize/info   (session)      → what the consent page shows
 *   POST /api/oauth/authorize/decision (session)    → the code, or access_denied
 *
 * The web page is never trusted with the request: the decision endpoint
 * re-validates everything (client, exact redirect_uri, PKCE challenge,
 * resource) before a code is issued.
 *
 * Errors about the client or the redirect URI are NEVER sent to the
 * redirect URI (it is unverified — RFC 6749 §4.1.2.1); everything else is.
 */

import type { Env } from "../../types";
import type { AgentScope } from "../agent-tokens";
import { AGENT_SCOPES } from "../agent-tokens";
import { mcpResource, oauthIssuer } from "./config";
import { redirectUriAllowed, resolveClient, type OAuthClient } from "./clients";
import { isValidCodeChallenge, parseScopeParam } from "./tokens";

export interface AuthorizeParams {
  response_type?: string | null;
  client_id?: string | null;
  redirect_uri?: string | null;
  scope?: string | null;
  state?: string | null;
  code_challenge?: string | null;
  code_challenge_method?: string | null;
  resource?: string | null;
}

export const AUTHORIZE_PARAM_NAMES = [
  "response_type",
  "client_id",
  "redirect_uri",
  "scope",
  "state",
  "code_challenge",
  "code_challenge_method",
  "resource",
] as const;

export interface ValidAuthorizeRequest {
  ok: true;
  client: OAuthClient;
  redirectUri: string;
  state: string | null;
  codeChallenge: string;
  /** What the client asked for (all scopes when it named none). */
  scopes: AgentScope[];
  resource: string;
}

export type AuthorizeValidation =
  | ValidAuthorizeRequest
  /** Show an error page; never redirect (unknown client / redirect URI). */
  | { ok: false; redirectable: false; error: string; description: string }
  /** Send the error back to the client's (verified) redirect URI. */
  | { ok: false; redirectable: true; redirectUri: string; state: string | null; error: string; description: string };

export async function validateAuthorizeRequest(
  env: Env,
  params: AuthorizeParams,
  now: Date = new Date(),
  fetchImpl: typeof fetch = fetch,
): Promise<AuthorizeValidation> {
  const clientId = params.client_id ?? "";
  if (!clientId) return { ok: false, redirectable: false, error: "invalid_request", description: "client_id is required." };
  const resolved = await resolveClient(env, clientId, now, fetchImpl);
  if (!resolved.ok) return { ok: false, redirectable: false, error: "invalid_client", description: resolved.error };
  const client = resolved.client;

  let redirectUri = params.redirect_uri ?? "";
  if (!redirectUri) {
    // OAuth 2.1 requires redirect_uri; tolerate its absence only when the
    // client has exactly one registered (RFC 6749 §3.1.2.3).
    if (client.redirectUris.length !== 1) {
      return { ok: false, redirectable: false, error: "invalid_request", description: "redirect_uri is required." };
    }
    redirectUri = client.redirectUris[0];
  }
  if (!redirectUriAllowed(client, redirectUri)) {
    return {
      ok: false,
      redirectable: false,
      error: "invalid_request",
      description: "redirect_uri is not one this client registered (it must match exactly).",
    };
  }

  const state = params.state ?? null;
  const fail = (error: string, description: string): AuthorizeValidation => ({
    ok: false,
    redirectable: true,
    redirectUri,
    state,
    error,
    description,
  });
  if (state !== null && state.length > 1000) return fail("invalid_request", "state is too long.");
  if (params.response_type !== "code") return fail("unsupported_response_type", "response_type must be code.");
  if (!client.grantTypes.includes("authorization_code")) {
    return fail("unauthorized_client", "This client did not register the authorization_code grant.");
  }
  if (!params.code_challenge) return fail("invalid_request", "PKCE is required: send code_challenge with code_challenge_method=S256.");
  if (params.code_challenge_method !== "S256") return fail("invalid_request", "code_challenge_method must be S256.");
  if (!isValidCodeChallenge(params.code_challenge)) return fail("invalid_request", "code_challenge must be a base64url SHA-256 (43 characters).");

  // RFC 8707: the one resource here is the MCP endpoint. A client that
  // names none gets it; one that names anything else is refused.
  const resource = mcpResource(env);
  if (params.resource && params.resource.replace(/\/+$/, "") !== resource) {
    return fail("invalid_target", `resource must be ${resource}.`);
  }

  const scopes = params.scope && params.scope.trim() ? parseScopeParam(params.scope) : [...AGENT_SCOPES];
  if (scopes.length === 0) return fail("invalid_scope", `Request one or more of: ${AGENT_SCOPES.join(" ")}.`);

  return { ok: true, client, redirectUri, state, codeChallenge: params.code_challenge, scopes, resource };
}

/** redirect_uri + the response parameters (code or error, state, iss —
 *  RFC 9207 so a client can tell which server answered). */
export function buildRedirect(env: Env, redirectUri: string, params: Record<string, string | null | undefined>): string {
  const url = new URL(redirectUri);
  for (const [key, value] of Object.entries(params)) {
    if (value !== null && value !== undefined) url.searchParams.set(key, value);
  }
  url.searchParams.set("iss", oauthIssuer(env));
  return url.toString();
}

/** The validated request as query parameters for the consent page. */
export function consentQuery(req: ValidAuthorizeRequest): URLSearchParams {
  const q = new URLSearchParams({
    response_type: "code",
    client_id: req.client.clientId,
    redirect_uri: req.redirectUri,
    scope: req.scopes.join(" "),
    code_challenge: req.codeChallenge,
    code_challenge_method: "S256",
    resource: req.resource,
  });
  if (req.state !== null) q.set("state", req.state);
  return q;
}
