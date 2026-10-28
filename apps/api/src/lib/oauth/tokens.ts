/**
 * Authorization codes, grants, access and refresh tokens for the MCP
 * authorization server (migration 0035).
 *
 *   code      cc_oac_…  10 min, single use, bound to client_id, redirect_uri,
 *                       the PKCE S256 challenge, scopes, resource and user.
 *                       A second exchange of the same code revokes everything
 *                       the first one issued (RFC 6749 §4.1.2).
 *   access    cc_oat_…  1 h. An agent_tokens row (oauth_client_id, grant,
 *                       resource), so /mcp authenticates it like a personal
 *                       token, audits it, and revocation is one UPDATE.
 *   refresh   cc_ort_…  30 days, ROTATED on every use. Presenting one that
 *                       was already rotated is reuse: the whole family (the
 *                       grant) is revoked — refresh and access tokens alike.
 *
 * Plan and block are checked again at every issue: a user whose plan lost
 * agentAccess, or who was blocked, gets no new tokens.
 */

import type { Env } from "../../types";
import { generateId } from "../id";
import { sha256Hex, timingSafeEqual } from "../screenshot/keys";
import {
  AGENT_SCOPES,
  OAUTH_ACCESS_TOKEN_PREFIX,
  agentTokenPrefix,
  isAgentScope,
  mintAgentToken,
  parseStoredScopes,
  randomBase62,
  type AgentScope,
} from "../agent-tokens";
import { agentPlanFor, featureUnavailableMessage } from "../agent-features";
import { ACCESS_TOKEN_TTL_SEC, AUTH_CODE_PREFIX, AUTH_CODE_TTL_MS, REFRESH_TOKEN_PREFIX, REFRESH_TOKEN_TTL_MS } from "./config";
import { touchClient, type OAuthClient } from "./clients";

const PREFIX_LENGTH = 7 + 8; // "cc_xxx_" + 8 random characters
const OPAQUE_RE = (prefix: string) => new RegExp(`^${prefix}[A-Za-z0-9]{40}$`);

async function mintOpaque(prefix: string): Promise<{ value: string; prefix: string; hash: string }> {
  const value = prefix + randomBase62(40);
  return { value, prefix: value.slice(0, PREFIX_LENGTH), hash: await sha256Hex(value) };
}

// ---------------------------------------------------------------------------
// Scopes and PKCE
// ---------------------------------------------------------------------------

/** "videos:read comments:read" → known scopes, in AGENT_SCOPES order.
 *  Unknown names are dropped (RFC 6749 §3.3 lets the AS narrow). */
export function parseScopeParam(raw: string | null | undefined): AgentScope[] {
  const asked = new Set((raw ?? "").split(/\s+/).filter(Boolean));
  return AGENT_SCOPES.filter((s) => asked.has(s));
}

export function scopeString(scopes: readonly AgentScope[]): string {
  return AGENT_SCOPES.filter((s) => scopes.includes(s)).join(" ");
}

function base64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** BASE64URL(SHA-256(ASCII(verifier))) — RFC 7636 §4.2. */
export async function pkceChallengeS256(verifier: string): Promise<string> {
  return base64Url(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier))));
}

/** 43–128 unreserved characters (RFC 7636 §4.1). */
export function isValidCodeVerifier(verifier: unknown): verifier is string {
  return typeof verifier === "string" && /^[A-Za-z0-9\-._~]{43,128}$/.test(verifier);
}

/** An S256 challenge is the 43-character base64url of a SHA-256. */
export function isValidCodeChallenge(challenge: unknown): challenge is string {
  return typeof challenge === "string" && /^[A-Za-z0-9_-]{43}$/.test(challenge);
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

export type OAuthErrorCode =
  | "invalid_request"
  | "invalid_client"
  | "invalid_grant"
  | "unauthorized_client"
  | "unsupported_grant_type"
  | "invalid_scope"
  | "invalid_target"
  | "access_denied"
  | "server_error";

export interface OAuthError {
  ok: false;
  error: OAuthErrorCode;
  description: string;
}

export const oauthError = (error: OAuthErrorCode, description: string): OAuthError => ({ ok: false, error, description });

export interface TokenResponse {
  access_token: string;
  token_type: "Bearer";
  expires_in: number;
  refresh_token: string;
  scope: string;
}

// ---------------------------------------------------------------------------
// Codes
// ---------------------------------------------------------------------------

export interface CodeRequest {
  clientId: string;
  uid: string;
  redirectUri: string;
  codeChallenge: string;
  scopes: AgentScope[];
  resource: string;
}

export async function issueAuthorizationCode(db: D1Database, req: CodeRequest, now: Date = new Date()): Promise<string> {
  const minted = await mintOpaque(AUTH_CODE_PREFIX);
  await db
    .prepare(
      `INSERT INTO oauth_codes
         (id, code_prefix, code_hash, client_id, user_id, redirect_uri, code_challenge, scopes, resource, created_at, expires_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)`,
    )
    .bind(
      generateId(16),
      minted.prefix,
      minted.hash,
      req.clientId,
      req.uid,
      req.redirectUri,
      req.codeChallenge,
      JSON.stringify(req.scopes),
      req.resource,
      now.toISOString(),
      new Date(now.getTime() + AUTH_CODE_TTL_MS).toISOString(),
    )
    .run();
  return minted.value;
}

interface CodeRow {
  id: string;
  code_hash: string;
  client_id: string;
  user_id: string;
  redirect_uri: string;
  code_challenge: string;
  scopes: string;
  resource: string;
  expires_at: string;
  used_at: string | null;
  grant_id: string | null;
}

// ---------------------------------------------------------------------------
// Grants and token issue
// ---------------------------------------------------------------------------

interface GrantRow {
  id: string;
  user_id: string;
  client_id: string;
  client_name: string;
  scopes: string;
  resource: string;
  revoked_at: string | null;
}

/** Revoke a consent and everything issued under it. Idempotent. */
export async function revokeGrant(db: D1Database, grantId: string, reason: string, now: Date = new Date()): Promise<void> {
  const nowIso = now.toISOString();
  await db.batch([
    db
      .prepare(`UPDATE oauth_grants SET revoked_at = ?1, revoked_reason = ?2 WHERE id = ?3 AND revoked_at IS NULL`)
      .bind(nowIso, reason, grantId),
    db.prepare(`UPDATE oauth_refresh_tokens SET revoked_at = ?1 WHERE grant_id = ?2 AND revoked_at IS NULL`).bind(nowIso, grantId),
    db.prepare(`UPDATE agent_tokens SET revoked_at = ?1 WHERE oauth_grant_id = ?2 AND revoked_at IS NULL`).bind(nowIso, grantId),
  ]);
}

/** The user may receive tokens: not blocked, plan includes agentAccess. */
async function userMayConnect(db: D1Database, uid: string): Promise<OAuthError | null> {
  const user = await db
    .prepare(`SELECT tester, blocked FROM "user" WHERE id = ?`)
    .bind(uid)
    .first<{ tester: number | null; blocked: number | null }>();
  if (!user) return oauthError("invalid_grant", "The account no longer exists.");
  const resolved = await agentPlanFor(db, uid, { tester: user.tester === 1, blocked: user.blocked === 1 });
  if (resolved === "blocked") return oauthError("invalid_grant", "This account is blocked.");
  if (!resolved.plan.features.agentAccess) return oauthError("invalid_grant", featureUnavailableMessage("agentAccess", resolved.plan));
  return null;
}

async function issueTokens(db: D1Database, grant: GrantRow, scopes: AgentScope[], now: Date): Promise<TokenResponse> {
  const nowIso = now.toISOString();
  const access = await mintAgentToken(OAUTH_ACCESS_TOKEN_PREFIX);
  const refresh = await mintOpaque(REFRESH_TOKEN_PREFIX);
  await db.batch([
    db
      .prepare(
        `INSERT INTO agent_tokens
           (id, user_id, name, token_hash, token_prefix, scopes, created_at, expires_at, oauth_client_id, oauth_grant_id, resource)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)`,
      )
      .bind(
        generateId(16),
        grant.user_id,
        grant.client_name.slice(0, 60),
        access.hash,
        agentTokenPrefix(access.token),
        JSON.stringify(scopes),
        nowIso,
        new Date(now.getTime() + ACCESS_TOKEN_TTL_SEC * 1000).toISOString(),
        grant.client_id,
        grant.id,
        grant.resource,
      ),
    db
      .prepare(
        `INSERT INTO oauth_refresh_tokens (id, grant_id, token_prefix, token_hash, scopes, created_at, expires_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)`,
      )
      .bind(
        generateId(16),
        grant.id,
        refresh.prefix,
        refresh.hash,
        JSON.stringify(scopes),
        nowIso,
        new Date(now.getTime() + REFRESH_TOKEN_TTL_MS).toISOString(),
      ),
    db.prepare(`UPDATE oauth_grants SET last_used_at = ?1 WHERE id = ?2`).bind(nowIso, grant.id),
  ]);
  await touchClient(db, grant.client_id, nowIso);
  return {
    access_token: access.token,
    token_type: "Bearer",
    expires_in: ACCESS_TOKEN_TTL_SEC,
    refresh_token: refresh.value,
    scope: scopeString(scopes),
  };
}

// ---------------------------------------------------------------------------
// grant_type=authorization_code
// ---------------------------------------------------------------------------

export async function exchangeAuthorizationCode(
  env: Pick<Env, "DB">,
  client: OAuthClient,
  input: { code: unknown; redirectUri: unknown; codeVerifier: unknown; resource: string | null },
  now: Date = new Date(),
): Promise<({ ok: true } & TokenResponse) | OAuthError> {
  const db = env.DB;
  if (typeof input.code !== "string" || !OPAQUE_RE(AUTH_CODE_PREFIX).test(input.code)) {
    return oauthError("invalid_grant", "The authorization code is invalid.");
  }
  if (typeof input.redirectUri !== "string" || !input.redirectUri) {
    return oauthError("invalid_request", "redirect_uri is required.");
  }
  if (!isValidCodeVerifier(input.codeVerifier)) {
    return oauthError("invalid_request", "code_verifier is required (43–128 characters).");
  }
  const row = await db
    .prepare(`SELECT * FROM oauth_codes WHERE code_prefix = ?`)
    .bind(input.code.slice(0, PREFIX_LENGTH))
    .first<CodeRow>();
  if (!row || !timingSafeEqual(await sha256Hex(input.code), row.code_hash)) {
    return oauthError("invalid_grant", "The authorization code is invalid.");
  }
  if (row.used_at) {
    // Replay: whatever the first exchange issued is now suspect.
    if (row.grant_id) await revokeGrant(db, row.grant_id, "code_reuse", now);
    return oauthError("invalid_grant", "The authorization code was already used.");
  }
  if (Date.parse(row.expires_at) <= now.getTime()) return oauthError("invalid_grant", "The authorization code expired.");
  if (row.client_id !== client.clientId) return oauthError("invalid_grant", "The authorization code was issued to another client.");
  if (row.redirect_uri !== input.redirectUri) return oauthError("invalid_grant", "redirect_uri does not match the authorization request.");
  if (input.resource !== null && input.resource !== row.resource) {
    return oauthError("invalid_target", "resource does not match the authorization request.");
  }
  if ((await pkceChallengeS256(input.codeVerifier)) !== row.code_challenge) {
    return oauthError("invalid_grant", "code_verifier does not match the code_challenge (PKCE).");
  }
  // Spend it — atomically, so two concurrent exchanges cannot both win.
  const spent = await db
    .prepare(`UPDATE oauth_codes SET used_at = ?1 WHERE id = ?2 AND used_at IS NULL`)
    .bind(now.toISOString(), row.id)
    .run();
  if ((spent.meta?.changes ?? 0) === 0) return oauthError("invalid_grant", "The authorization code was already used.");

  const refused = await userMayConnect(db, row.user_id);
  if (refused) return refused;

  const scopes = parseStoredScopes(row.scopes);
  const grant: GrantRow = {
    id: generateId(20),
    user_id: row.user_id,
    client_id: client.clientId,
    client_name: client.clientName,
    scopes: JSON.stringify(scopes),
    resource: row.resource,
    revoked_at: null,
  };
  await db.batch([
    db
      .prepare(
        `INSERT INTO oauth_grants (id, user_id, client_id, client_name, scopes, resource, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)`,
      )
      .bind(grant.id, grant.user_id, grant.client_id, grant.client_name, grant.scopes, grant.resource, now.toISOString()),
    db.prepare(`UPDATE oauth_codes SET grant_id = ?1 WHERE id = ?2`).bind(grant.id, row.id),
  ]);
  return { ok: true, ...(await issueTokens(db, grant, scopes, now)) };
}

// ---------------------------------------------------------------------------
// grant_type=refresh_token
// ---------------------------------------------------------------------------

interface RefreshRow {
  id: string;
  grant_id: string;
  token_hash: string;
  scopes: string;
  expires_at: string;
  used_at: string | null;
  revoked_at: string | null;
}

export async function refreshTokens(
  env: Pick<Env, "DB">,
  client: OAuthClient,
  input: { refreshToken: unknown; scope: string | null; resource: string | null },
  now: Date = new Date(),
): Promise<({ ok: true } & TokenResponse) | OAuthError> {
  const db = env.DB;
  if (typeof input.refreshToken !== "string" || !OPAQUE_RE(REFRESH_TOKEN_PREFIX).test(input.refreshToken)) {
    return oauthError("invalid_grant", "The refresh token is invalid.");
  }
  const row = await db
    .prepare(`SELECT * FROM oauth_refresh_tokens WHERE token_prefix = ?`)
    .bind(input.refreshToken.slice(0, PREFIX_LENGTH))
    .first<RefreshRow>();
  if (!row || !timingSafeEqual(await sha256Hex(input.refreshToken), row.token_hash)) {
    return oauthError("invalid_grant", "The refresh token is invalid.");
  }
  const grant = await db.prepare(`SELECT * FROM oauth_grants WHERE id = ?`).bind(row.grant_id).first<GrantRow>();
  if (!grant || grant.client_id !== client.clientId) return oauthError("invalid_grant", "The refresh token is invalid.");
  if (grant.revoked_at || row.revoked_at) return oauthError("invalid_grant", "The refresh token was revoked.");
  if (row.used_at) {
    // Rotated already: someone holds a copy. Kill the family.
    await revokeGrant(db, grant.id, "refresh_reuse", now);
    return oauthError("invalid_grant", "The refresh token was already used; this connection has been revoked. Sign in again.");
  }
  if (Date.parse(row.expires_at) <= now.getTime()) return oauthError("invalid_grant", "The refresh token expired. Sign in again.");
  if (input.resource !== null && input.resource !== grant.resource) {
    return oauthError("invalid_target", "resource does not match this grant.");
  }
  const held = parseStoredScopes(row.scopes);
  let scopes = held;
  if (input.scope !== null) {
    const asked = input.scope.split(/\s+/).filter(Boolean);
    if (asked.some((s) => !isAgentScope(s) || !held.includes(s))) {
      return oauthError("invalid_scope", "A refresh can only keep or narrow the scopes that were granted.");
    }
    scopes = parseScopeParam(input.scope);
    if (scopes.length === 0) return oauthError("invalid_scope", "No scopes requested.");
  }
  const spent = await db
    .prepare(`UPDATE oauth_refresh_tokens SET used_at = ?1 WHERE id = ?2 AND used_at IS NULL AND revoked_at IS NULL`)
    .bind(now.toISOString(), row.id)
    .run();
  if ((spent.meta?.changes ?? 0) === 0) {
    await revokeGrant(db, grant.id, "refresh_reuse", now);
    return oauthError("invalid_grant", "The refresh token was already used; this connection has been revoked. Sign in again.");
  }
  const refused = await userMayConnect(db, grant.user_id);
  if (refused) return refused;
  return { ok: true, ...(await issueTokens(db, grant, scopes, now)) };
}

// ---------------------------------------------------------------------------
// RFC 7009 revocation
// ---------------------------------------------------------------------------

/** Revoke a refresh token (its whole grant) or one access token. Unknown
 *  tokens are ignored — the endpoint answers 200 either way. */
export async function revokeOAuthToken(db: D1Database, client: OAuthClient, token: string, now: Date = new Date()): Promise<void> {
  if (OPAQUE_RE(REFRESH_TOKEN_PREFIX).test(token)) {
    const row = await db
      .prepare(`SELECT r.token_hash, r.grant_id, g.client_id FROM oauth_refresh_tokens r JOIN oauth_grants g ON g.id = r.grant_id WHERE r.token_prefix = ?`)
      .bind(token.slice(0, PREFIX_LENGTH))
      .first<{ token_hash: string; grant_id: string; client_id: string }>();
    if (row && row.client_id === client.clientId && timingSafeEqual(await sha256Hex(token), row.token_hash)) {
      await revokeGrant(db, row.grant_id, "client", now);
    }
    return;
  }
  if (OPAQUE_RE(OAUTH_ACCESS_TOKEN_PREFIX).test(token)) {
    const row = await db
      .prepare(`SELECT id, token_hash, oauth_client_id FROM agent_tokens WHERE token_prefix = ?`)
      .bind(agentTokenPrefix(token))
      .first<{ id: string; token_hash: string; oauth_client_id: string | null }>();
    if (row && row.oauth_client_id === client.clientId && timingSafeEqual(await sha256Hex(token), row.token_hash)) {
      await db.prepare(`UPDATE agent_tokens SET revoked_at = ?1 WHERE id = ?2 AND revoked_at IS NULL`).bind(now.toISOString(), row.id).run();
    }
  }
}

// ---------------------------------------------------------------------------
// Connected apps (Settings → Agent access)
// ---------------------------------------------------------------------------

export interface ConnectedApp {
  clientId: string;
  name: string;
  kind: "dcr" | "cimd";
  logoUri: string | null;
  clientUri: string | null;
  /** The host a metadata-document client_id is served from (verified), or null. */
  verifiedHost: string | null;
  scopes: AgentScope[];
  connectedAt: string;
  lastUsedAt: string | null;
  connections: number;
}

/**
 * Live consents grouped by client. A grant is live while it is unrevoked and
 * still holds an unexpired refresh or access token.
 */
export async function listConnectedApps(db: D1Database, uid: string, now: Date = new Date()): Promise<ConnectedApp[]> {
  const nowIso = now.toISOString();
  const { results } = await db
    .prepare(
      `SELECT g.id, g.client_id, g.client_name, g.scopes, g.created_at, g.last_used_at,
              c.kind, c.logo_uri, c.client_uri,
              (SELECT MAX(t.last_used_at) FROM agent_tokens t WHERE t.oauth_grant_id = g.id) AS token_last_used
         FROM oauth_grants g LEFT JOIN oauth_clients c ON c.client_id = g.client_id
        WHERE g.user_id = ?1 AND g.revoked_at IS NULL
          AND (EXISTS (SELECT 1 FROM oauth_refresh_tokens r
                        WHERE r.grant_id = g.id AND r.revoked_at IS NULL AND r.used_at IS NULL AND r.expires_at > ?2)
               OR EXISTS (SELECT 1 FROM agent_tokens t
                        WHERE t.oauth_grant_id = g.id AND t.revoked_at IS NULL AND t.expires_at > ?2))
        ORDER BY g.created_at`,
    )
    .bind(uid, nowIso)
    .all<{
      id: string;
      client_id: string;
      client_name: string;
      scopes: string;
      created_at: string;
      last_used_at: string | null;
      kind: "dcr" | "cimd" | null;
      logo_uri: string | null;
      client_uri: string | null;
      token_last_used: string | null;
    }>();
  const byClient = new Map<string, ConnectedApp>();
  for (const r of results ?? []) {
    const lastUsed = [r.token_last_used, r.last_used_at].filter((v): v is string => !!v).sort().at(-1) ?? null;
    const app = byClient.get(r.client_id);
    const scopes = parseStoredScopes(r.scopes);
    if (!app) {
      const kind = r.kind ?? (r.client_id.startsWith("https://") ? "cimd" : "dcr");
      byClient.set(r.client_id, {
        clientId: r.client_id,
        name: r.client_name,
        kind,
        logoUri: r.logo_uri,
        clientUri: r.client_uri,
        verifiedHost: kind === "cimd" ? new URL(r.client_id).hostname : null,
        scopes,
        connectedAt: r.created_at,
        lastUsedAt: lastUsed,
        connections: 1,
      });
    } else {
      app.scopes = AGENT_SCOPES.filter((s) => app.scopes.includes(s) || scopes.includes(s));
      app.lastUsedAt = [app.lastUsedAt, lastUsed].filter((v): v is string => !!v).sort().at(-1) ?? null;
      app.name = r.client_name;
      app.connections += 1;
    }
  }
  return [...byClient.values()].sort((a, b) => (b.lastUsedAt ?? b.connectedAt).localeCompare(a.lastUsedAt ?? a.connectedAt));
}

/** "Revoke" on a connected app: every grant this user gave that client. */
export async function revokeClientForUser(db: D1Database, uid: string, clientId: string, now: Date = new Date()): Promise<number> {
  const { results } = await db
    .prepare(`SELECT id FROM oauth_grants WHERE user_id = ?1 AND client_id = ?2 AND revoked_at IS NULL`)
    .bind(uid, clientId)
    .all<{ id: string }>();
  for (const g of results ?? []) await revokeGrant(db, g.id, "user", now);
  return results?.length ?? 0;
}
