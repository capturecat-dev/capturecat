/**
 * "Sign in with CaptureCat" — OAuth 2.1 for the remote MCP server, per the
 * MCP authorization spec:
 *
 *   authorization server (issuer)  https://api.capturecat.so          RFC 8414 metadata
 *   protected resource             https://mcp.capturecat.so/mcp      RFC 9728 metadata
 *   PKCE                           S256 only, always required          RFC 7636 / OAuth 2.1
 *   audience                       resource indicators                 RFC 8707
 *   clients                        Client ID Metadata Documents (an https client_id)
 *                                  or Dynamic Client Registration      RFC 7591
 *
 * A locally running Worker (`wrangler dev`) is its own issuer and resource,
 * so the whole flow can be exercised against localhost.
 */

import type { Env } from "../../types";
import { appBaseURL, isLocalInstance } from "../origins";

export const PROD_ISSUER = "https://api.capturecat.so";
export const MCP_HOST_ORIGIN = "https://mcp.capturecat.so";
/** = MCP_URL in src/mcp/server.ts (kept literal here: no import cycle). */
export const MCP_RESOURCE = "https://mcp.capturecat.so/mcp";

/** The authorization server's issuer identifier. */
export function oauthIssuer(env: Env): string {
  return isLocalInstance(env) ? env.BETTER_AUTH_URL.replace(/\/+$/, "") : PROD_ISSUER;
}

/** The one resource tokens are issued for: the MCP endpoint. */
export function mcpResource(env: Env): string {
  return isLocalInstance(env) ? `${env.BETTER_AUTH_URL.replace(/\/+$/, "")}/mcp` : MCP_RESOURCE;
}

/** RFC 9728 metadata URL /mcp names in its 401 challenge. */
export function protectedResourceMetadataUrl(env: Env): string {
  return isLocalInstance(env)
    ? `${env.BETTER_AUTH_URL.replace(/\/+$/, "")}/.well-known/oauth-protected-resource`
    : `${MCP_HOST_ORIGIN}/.well-known/oauth-protected-resource`;
}

/** The web consent page (apps/web src/routes/oauth.authorize.tsx). */
export function consentPageUrl(env: Env): string {
  return `${appBaseURL(env)}/oauth/authorize`;
}

export const AUTH_CODE_TTL_MS = 10 * 60_000;
export const ACCESS_TOKEN_TTL_SEC = 3600;
export const REFRESH_TOKEN_TTL_MS = 30 * 86_400_000;
/** A fetched Client ID Metadata Document is reused this long… */
export const CIMD_CACHE_MS = 60 * 60_000;
/** …and, if a refetch fails, still trusted up to this age. */
export const CIMD_STALE_MS = 24 * 60 * 60_000;
export const CIMD_TIMEOUT_MS = 5_000;
export const CIMD_MAX_BYTES = 64 * 1024;

export const AUTH_CODE_PREFIX = "cc_oac_";
export const REFRESH_TOKEN_PREFIX = "cc_ort_";
export const CLIENT_SECRET_PREFIX = "cc_ocs_";
