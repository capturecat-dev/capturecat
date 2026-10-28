/**
 * Agent tokens (migration 0033) — mint, parse, resolve, list, audit.
 *
 * The Screenshot API's access keys (lib/screenshot/keys.ts) generalized to
 * the whole account: a cloud agent sends
 *
 *   Authorization: Bearer cc_pat_<40 × [A-Za-z0-9]>
 *
 * to the remote MCP server (src/mcp/). Only SHA-256(token) is stored. The
 * first 8 random characters are the public half (`token_prefix`, shown in
 * the dashboard): verification looks the row up BY PREFIX and then compares
 * hashes in constant time — the keys.ts rule, so a secret-derived value never
 * drives the index probe.
 *
 * WHAT A TOKEN CAN NEVER DO:
 *   • more than its user: scopes only narrow; plan gates are resolved per
 *     call through the same entitlement code the session routes use;
 *   • manage tokens: /api/agent-tokens is session-only (routes/agent-tokens.ts);
 *   • billing, admin or deletes: there is no scope for any of them.
 */

import { sha256Hex, timingSafeEqual } from "./screenshot/keys";
import { generateId } from "./id";

export const AGENT_TOKEN_PREFIX = "cc_pat_";
/** OAuth access tokens (lib/oauth/, migration 0035) are agent_tokens rows
 *  too, with this prefix: one resolver, one audit trail, one revoke. */
export const OAUTH_ACCESS_TOKEN_PREFIX = "cc_oat_";
/** Random characters after `cc_pat_`: 40 × log2(62) ≈ 238 bits. */
const TOKEN_RANDOM_LENGTH = 40;
/** Random characters of the public half (`cc_pat_` + these 8). */
const PREFIX_RANDOM_LENGTH = 8;
const BASE62 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
const TOKEN_RE = /^cc_(?:pat|oat)_[A-Za-z0-9]{40}$/;

/**
 * Every scope a token can hold. Deliberately NO billing, admin or delete
 * scope: a leaked agent token must never be able to spend money, touch
 * another account, or destroy media.
 */
export const AGENT_SCOPES = [
  "videos:read",
  "videos:write",
  "comments:read",
  "comments:write",
  "analytics:read",
  "playlists:read",
  "playlists:write",
  "screenshots",
  "account:read",
  "webhooks:write",
  "projects:read",
  "projects:write",
] as const;
export type AgentScope = (typeof AGENT_SCOPES)[number];

export function isAgentScope(value: unknown): value is AgentScope {
  return typeof value === "string" && (AGENT_SCOPES as readonly string[]).includes(value);
}

/** Active (unrevoked, unexpired) tokens one user may hold. */
export const MAX_ACTIVE_AGENT_TOKENS = 20;
/** `last_used_at` is written at most this often per token. */
const LAST_USED_THROTTLE_MS = 60_000;

/** Uniform base62 via rejection sampling (248 = 62 × 4): no modulo bias. */
export function randomBase62(length: number): string {
  let out = "";
  while (out.length < length) {
    const bytes = new Uint8Array(length * 2);
    crypto.getRandomValues(bytes);
    for (const b of bytes) {
      if (b < 248) out += BASE62[b % 62];
      if (out.length === length) break;
    }
  }
  return out;
}

export interface MintedAgentToken {
  /** Full plaintext token — returned to the caller ONCE, never stored. */
  token: string;
  /** `cc_pat_` + the first 8 random characters — public, the lookup key. */
  prefix: string;
  /** SHA-256(token) hex — what the D1 row stores. */
  hash: string;
}

export async function mintAgentToken(prefix: string = AGENT_TOKEN_PREFIX): Promise<MintedAgentToken> {
  const token = prefix + randomBase62(TOKEN_RANDOM_LENGTH);
  return { token, prefix: agentTokenPrefix(token), hash: await sha256Hex(token) };
}

/** True when the string is shaped like an agent token — personal (cc_pat_)
 *  or OAuth access (cc_oat_) — no D1 needed. */
export function isAgentTokenShape(token: string): boolean {
  return TOKEN_RE.test(token);
}

export function agentTokenPrefix(token: string): string {
  return token.slice(0, AGENT_TOKEN_PREFIX.length + PREFIX_RANDOM_LENGTH);
}

/** The bearer value of an Authorization header, or null. */
export function bearerToken(header: string | null | undefined): string | null {
  if (!header) return null;
  const m = /^Bearer\s+(\S+)\s*$/i.exec(header);
  return m ? m[1] : null;
}

/** Stored JSON → scope list. Unknown entries are dropped, never granted. */
export function parseStoredScopes(raw: string | null | undefined): AgentScope[] {
  try {
    const parsed: unknown = JSON.parse(raw ?? "[]");
    return Array.isArray(parsed) ? [...new Set(parsed.filter(isAgentScope))] : [];
  } catch {
    return [];
  }
}

/** Who an agent token acts for. `claims` are the user row's server-owned
 *  flags, read in the same lookup — the MCP layer refuses blocked accounts. */
export interface AgentPrincipal {
  uid: string;
  tokenId: string;
  tokenName: string;
  scopes: AgentScope[];
  claims: { tester: boolean; blocked: boolean };
  /** "personal" = a cc_pat_ the user created; "oauth" = a cc_oat_ access
   *  token issued to an OAuth client (lib/oauth/). Optional so code that
   *  builds a principal by hand keeps compiling; absent = personal. */
  kind?: "personal" | "oauth";
  /** OAuth only: the client and grant (consent) it was issued under. */
  oauthClientId?: string | null;
  oauthGrantId?: string | null;
  /** OAuth only: the audience (RFC 8707 resource) it was issued for. */
  resource?: string | null;
}

interface TokenRow {
  id: string;
  user_id: string;
  name: string;
  token_hash: string;
  scopes: string;
  expires_at: string | null;
  last_used_at: string | null;
  revoked_at: string | null;
  tester: number | null;
  blocked: number | null;
  oauth_client_id: string | null;
  oauth_grant_id: string | null;
  resource: string | null;
}

/**
 * `Authorization: Bearer cc_pat_…` → the principal, or null for anything
 * missing, malformed, unknown, revoked, expired or not matching its hash.
 * Never throws (a D1 error is a null — fail closed). Touches `last_used_at`
 * at most once a minute per token.
 */
export async function resolveAgentToken(
  db: D1Database,
  authorization: string | null | undefined,
  now: Date = new Date(),
): Promise<AgentPrincipal | null> {
  const token = bearerToken(authorization);
  if (!token || !isAgentTokenShape(token)) return null;
  let row: TokenRow | null;
  try {
    row = await db
      .prepare(
        `SELECT t.id, t.user_id, t.name, t.token_hash, t.scopes, t.expires_at,
                t.last_used_at, t.revoked_at, u.tester, u.blocked,
                t.oauth_client_id, t.oauth_grant_id, t.resource
           FROM agent_tokens t JOIN "user" u ON u.id = t.user_id
          WHERE t.token_prefix = ?1`,
      )
      .bind(agentTokenPrefix(token))
      .first<TokenRow>();
  } catch (err) {
    console.error("agent-tokens: lookup failed", err instanceof Error ? err.message : err);
    return null;
  }
  if (!row) return null;
  // Hash first, then the cheap checks — the comparison runs for every row
  // found, so a revoked token answers in the same time as a live one.
  const matches = timingSafeEqual(await sha256Hex(token), row.token_hash);
  if (!matches || row.revoked_at) return null;
  if (row.expires_at && Date.parse(row.expires_at) <= now.getTime()) return null;

  const lastUsed = row.last_used_at ? Date.parse(row.last_used_at) : 0;
  if (!(lastUsed > now.getTime() - LAST_USED_THROTTLE_MS)) {
    const iso = now.toISOString();
    // The WHERE repeats the throttle so concurrent calls write once.
    await db
      .prepare(
        `UPDATE agent_tokens SET last_used_at = ?1
          WHERE id = ?2 AND (last_used_at IS NULL OR last_used_at < ?3)`,
      )
      .bind(iso, row.id, new Date(now.getTime() - LAST_USED_THROTTLE_MS).toISOString())
      .run()
      .catch((err: unknown) => console.error("agent-tokens: last_used_at write failed", err));
  }

  return {
    uid: row.user_id,
    tokenId: row.id,
    tokenName: row.name,
    scopes: parseStoredScopes(row.scopes),
    claims: { tester: row.tester === 1, blocked: row.blocked === 1 },
    kind: row.oauth_client_id ? "oauth" : "personal",
    oauthClientId: row.oauth_client_id,
    oauthGrantId: row.oauth_grant_id,
    resource: row.resource,
  };
}

// ---------------------------------------------------------------------------
// Management (session-only routes; see routes/agent-tokens.ts)
// ---------------------------------------------------------------------------

export interface AgentTokenSummary {
  id: string;
  name: string;
  /** `cc_pat_xxxxxxxx` — enough to recognise a token, useless to use one. */
  prefix: string;
  scopes: AgentScope[];
  createdAt: string;
  expiresAt: string | null;
  lastUsedAt: string | null;
  revokedAt: string | null;
}

export async function createAgentToken(
  db: D1Database,
  input: { uid: string; name: string; scopes: AgentScope[]; expiresInDays: number | null },
  now: Date = new Date(),
): Promise<{ token: string; summary: AgentTokenSummary }> {
  const createdAt = now.toISOString();
  const expiresAt =
    input.expiresInDays === null ? null : new Date(now.getTime() + input.expiresInDays * 86_400_000).toISOString();
  const scopes = AGENT_SCOPES.filter((s) => input.scopes.includes(s));
  const id = generateId(16);
  // The prefix is unique (it is the lookup key). A collision at 62^8 is
  // vanishingly rare; on one, mint again rather than fail the request.
  for (let attempt = 0; ; attempt++) {
    const minted = await mintAgentToken();
    try {
      await db
        .prepare(
          `INSERT INTO agent_tokens (id, user_id, name, token_hash, token_prefix, scopes, created_at, expires_at)
           VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)`,
        )
        .bind(id, input.uid, input.name, minted.hash, minted.prefix, JSON.stringify(scopes), createdAt, expiresAt)
        .run();
      return {
        token: minted.token,
        summary: {
          id,
          name: input.name,
          prefix: minted.prefix,
          scopes,
          createdAt,
          expiresAt,
          lastUsedAt: null,
          revokedAt: null,
        },
      };
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      if (attempt < 2 && message.includes("UNIQUE")) continue;
      throw err;
    }
  }
}

/** Active = not revoked and not expired. Personal tokens only: OAuth access
 *  tokens are listed per connected app (lib/oauth/grants.ts). */
export async function countActiveAgentTokens(db: D1Database, uid: string, now: Date = new Date()): Promise<number> {
  const row = await db
    .prepare(
      `SELECT COUNT(*) AS n FROM agent_tokens
        WHERE user_id = ?1 AND oauth_client_id IS NULL
          AND revoked_at IS NULL AND (expires_at IS NULL OR expires_at > ?2)`,
    )
    .bind(uid, now.toISOString())
    .first<{ n: number }>();
  return row?.n ?? 0;
}

export async function listAgentTokens(db: D1Database, uid: string): Promise<AgentTokenSummary[]> {
  const { results } = await db
    .prepare(
      `SELECT id, name, token_prefix, scopes, created_at, expires_at, last_used_at, revoked_at
         FROM agent_tokens WHERE user_id = ?1 AND oauth_client_id IS NULL ORDER BY created_at DESC`,
    )
    .bind(uid)
    .all<{
      id: string;
      name: string;
      token_prefix: string;
      scopes: string;
      created_at: string;
      expires_at: string | null;
      last_used_at: string | null;
      revoked_at: string | null;
    }>();
  return (results ?? []).map((r) => ({
    id: r.id,
    name: r.name,
    prefix: r.token_prefix,
    scopes: parseStoredScopes(r.scopes),
    createdAt: r.created_at,
    expiresAt: r.expires_at,
    lastUsedAt: r.last_used_at,
    revokedAt: r.revoked_at,
  }));
}

/** Revoke one of the user's personal tokens. False when it is not theirs, is
 *  already revoked, or is an OAuth access token (those are revoked per
 *  connected app) — the route answers all of them like a missing token. */
export async function revokeAgentToken(db: D1Database, uid: string, id: string, now: Date = new Date()): Promise<boolean> {
  const result = await db
    .prepare(
      `UPDATE agent_tokens SET revoked_at = ?1
        WHERE id = ?2 AND user_id = ?3 AND revoked_at IS NULL AND oauth_client_id IS NULL`,
    )
    .bind(now.toISOString(), id, uid)
    .run();
  return (result.meta?.changes ?? 0) > 0;
}

// ---------------------------------------------------------------------------
// Audit log
// ---------------------------------------------------------------------------

export interface AgentAuditEntry {
  uid: string;
  tokenId: string;
  tool: string;
  videoId?: string | null;
  ok: boolean;
  error?: string | null;
}

/** One row per tool call. Never throws: a failed audit write is logged, and
 *  the call it describes has already happened either way. */
export async function writeAgentAudit(db: D1Database, entry: AgentAuditEntry, now: Date = new Date()): Promise<void> {
  try {
    await db
      .prepare(
        `INSERT INTO agent_audit_log (id, user_id, token_id, tool, video_id, ok, error, at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)`,
      )
      .bind(
        generateId(16),
        entry.uid,
        entry.tokenId,
        entry.tool.slice(0, 80),
        entry.videoId ? entry.videoId.slice(0, 64) : null,
        entry.ok ? 1 : 0,
        entry.error ? entry.error.slice(0, 300) : null,
        now.toISOString(),
      )
      .run();
  } catch (err) {
    console.error("agent-tokens: audit write failed", err instanceof Error ? err.message : err);
  }
}

export interface AgentAuditRow {
  id: string;
  tokenId: string;
  tokenName: string | null;
  tokenPrefix: string | null;
  tool: string;
  videoId: string | null;
  ok: boolean;
  error: string | null;
  at: string;
}

export async function listAgentAudit(db: D1Database, uid: string, limit = 50): Promise<AgentAuditRow[]> {
  const { results } = await db
    .prepare(
      `SELECT a.id, a.token_id, t.name AS token_name, t.token_prefix, a.tool, a.video_id, a.ok, a.error, a.at
         FROM agent_audit_log a LEFT JOIN agent_tokens t ON t.id = a.token_id
        WHERE a.user_id = ?1 ORDER BY a.at DESC LIMIT ?2`,
    )
    .bind(uid, limit)
    .all<{
      id: string;
      token_id: string;
      token_name: string | null;
      token_prefix: string | null;
      tool: string;
      video_id: string | null;
      ok: number;
      error: string | null;
      at: string;
    }>();
  return (results ?? []).map((r) => ({
    id: r.id,
    tokenId: r.token_id,
    tokenName: r.token_name,
    tokenPrefix: r.token_prefix,
    tool: r.tool,
    videoId: r.video_id,
    ok: r.ok === 1,
    error: r.error,
    at: r.at,
  }));
}

/** Audit rows are kept 90 days (the hourly sweep in index.ts). */
export const AGENT_AUDIT_RETENTION_DAYS = 90;
