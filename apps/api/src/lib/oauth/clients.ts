/**
 * OAuth clients of the MCP authorization server: how a client_id becomes a
 * name, a logo and the exact redirect URIs a code may be sent to.
 *
 *   https://…  a Client ID Metadata Document (the MCP spec's preferred way):
 *              the client_id IS the URL of a JSON document the client hosts.
 *              Fetched with SSRF guards — https only, public DNS names only
 *              (no IP literals, private, link-local or internal hosts), no
 *              redirects, 5 s timeout, 64 KB cap — and cached in
 *              oauth_clients for an hour (a stale copy is used up to a day
 *              when the host is down).
 *   anything   Dynamic Client Registration (RFC 7591, POST /oauth/register)
 *              for clients that still use it; the client_id is minted here.
 *
 * Client names are self-asserted either way. The consent page therefore
 * leads with what IS verified: the redirect host (and, for a metadata
 * document, the host serving it).
 */

import { z } from "zod";
import type { Env } from "../../types";
import { randomBase62 } from "../agent-tokens";
import { sha256Hex, timingSafeEqual } from "../screenshot/keys";
import { checkOutboundUrl, readCappedText, type OutboundUrlCheck } from "../outbound-url";
import { CIMD_CACHE_MS, CIMD_MAX_BYTES, CIMD_STALE_MS, CIMD_TIMEOUT_MS, CLIENT_SECRET_PREFIX } from "./config";

export type TokenEndpointAuthMethod = "none" | "client_secret_post" | "client_secret_basic";

export interface OAuthClient {
  clientId: string;
  kind: "dcr" | "cimd";
  clientName: string;
  clientUri: string | null;
  logoUri: string | null;
  redirectUris: string[];
  tokenEndpointAuthMethod: TokenEndpointAuthMethod;
  clientSecretHash: string | null;
  grantTypes: string[];
}

interface ClientRow {
  client_id: string;
  kind: "dcr" | "cimd";
  client_name: string;
  client_uri: string | null;
  logo_uri: string | null;
  redirect_uris: string;
  token_endpoint_auth_method: string;
  client_secret_hash: string | null;
  grant_types: string;
  software_id: string | null;
  software_version: string | null;
  created_at: string;
  fetched_at: string | null;
  last_used_at: string | null;
}

function jsonArray(raw: string | null): string[] {
  try {
    const parsed: unknown = JSON.parse(raw ?? "[]");
    return Array.isArray(parsed) ? parsed.filter((v): v is string => typeof v === "string") : [];
  } catch {
    return [];
  }
}

function toClient(row: ClientRow): OAuthClient {
  const method = row.token_endpoint_auth_method;
  return {
    clientId: row.client_id,
    kind: row.kind,
    clientName: row.client_name,
    clientUri: row.client_uri,
    logoUri: row.logo_uri,
    redirectUris: jsonArray(row.redirect_uris),
    tokenEndpointAuthMethod:
      method === "client_secret_post" || method === "client_secret_basic" ? method : "none",
    clientSecretHash: row.client_secret_hash,
    grantTypes: jsonArray(row.grant_types),
  };
}

// ---------------------------------------------------------------------------
// Redirect URIs
// ---------------------------------------------------------------------------

const LOOPBACK_HOSTS = new Set(["localhost", "127.0.0.1", "[::1]"]);
const FORBIDDEN_SCHEMES = new Set([
  "javascript:",
  "data:",
  "file:",
  "vbscript:",
  "blob:",
  "about:",
  "ftp:",
  "ws:",
  "wss:",
  "mailto:",
  "tel:",
  "sms:",
]);

/**
 * Null when `raw` may be registered as a redirect URI, else why not:
 * https anywhere; http only on a loopback host (native apps, RFC 8252 §7.3);
 * a private-use scheme such as `cursor://…` (RFC 8252 §7.1); never a
 * fragment, credentials or a script-capable scheme.
 */
export function redirectUriProblem(raw: unknown): string | null {
  if (typeof raw !== "string" || raw.length === 0) return "redirect_uris must be non-empty strings";
  if (raw.length > 2000) return "a redirect URI is too long";
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    return `${raw.slice(0, 100)} is not an absolute URI`;
  }
  if (url.hash || raw.includes("#")) return "redirect URIs must not contain a fragment";
  if (url.username || url.password) return "redirect URIs must not contain credentials";
  if (url.protocol === "https:") return null;
  if (url.protocol === "http:") {
    return LOOPBACK_HOSTS.has(url.hostname.toLowerCase()) ? null : "http redirect URIs are allowed only on localhost / 127.0.0.1";
  }
  if (FORBIDDEN_SCHEMES.has(url.protocol)) return `${url.protocol} redirect URIs are not allowed`;
  return /^[a-z][a-z0-9+.-]*:$/.test(url.protocol) ? null : "unsupported redirect URI scheme";
}

/** Exact string match against the registered list — no prefix or wildcard. */
export function redirectUriAllowed(client: Pick<OAuthClient, "redirectUris">, redirectUri: string): boolean {
  if (client.redirectUris.includes(redirectUri)) return true;
  // RFC 8252 §7.3: a native app's loopback redirect gets a fresh port each
  // run, so for http loopback hosts ONLY the port may differ — scheme, host,
  // path and query must still match a registered URI exactly.
  const asked = loopback(redirectUri);
  return asked !== null && client.redirectUris.some((registered) => loopback(registered) === asked);
}

/** `http://localhost:1234/cb?x` → `http://localhost/cb?x` (port dropped), or
 *  null for anything that isn't an http loopback URI. */
function loopback(uri: string): string | null {
  let url: URL;
  try {
    url = new URL(uri);
  } catch {
    return null;
  }
  if (url.protocol !== "http:" || !["localhost", "127.0.0.1", "[::1]"].includes(url.hostname)) return null;
  if (url.username || url.password || url.hash) return null;
  return `http://${url.hostname}${url.pathname}${url.search}`;
}

// ---------------------------------------------------------------------------
// Dynamic Client Registration (RFC 7591)
// ---------------------------------------------------------------------------

const optionalUri = z.string().max(2000).optional();

/** The metadata we read; anything else in the body is ignored (RFC 7591 §2). */
export const RegistrationSchema = z
  .object({
    redirect_uris: z.array(z.string()).min(1, { error: "redirect_uris must list at least one URI" }).max(20),
    client_name: z.string().trim().max(100).optional(),
    client_uri: optionalUri,
    logo_uri: optionalUri,
    token_endpoint_auth_method: z.enum(["none", "client_secret_post", "client_secret_basic"]).optional(),
    grant_types: z.array(z.string()).max(5).optional(),
    response_types: z.array(z.string()).max(5).optional(),
    scope: z.string().max(1000).optional(),
    software_id: z.string().max(200).optional(),
    software_version: z.string().max(100).optional(),
  })
  .loose();

const SUPPORTED_GRANTS = ["authorization_code", "refresh_token"];

/** An https URL to show (client_uri, logo_uri), or null. Display only. */
function displayUrl(raw: string | undefined | null): string | null {
  if (!raw) return null;
  try {
    const u = new URL(raw);
    return u.protocol === "https:" && !u.username && !u.password ? u.toString() : null;
  } catch {
    return null;
  }
}

export type RegisterResult =
  | { ok: true; client: OAuthClient; clientSecret: string | null; issuedAt: number }
  | { ok: false; error: "invalid_redirect_uri" | "invalid_client_metadata"; description: string };

export async function registerClient(db: D1Database, body: unknown, now: Date = new Date()): Promise<RegisterResult> {
  const parsed = RegistrationSchema.safeParse(body);
  if (!parsed.success) {
    const issue = parsed.error.issues[0];
    const path = issue?.path.map(String).join(".");
    const isRedirect = path?.startsWith("redirect_uris");
    return {
      ok: false,
      error: isRedirect ? "invalid_redirect_uri" : "invalid_client_metadata",
      description: issue ? `${path ? `${path}: ` : ""}${issue.message}` : "Invalid client metadata",
    };
  }
  const meta = parsed.data;
  for (const uri of meta.redirect_uris) {
    const problem = redirectUriProblem(uri);
    if (problem) return { ok: false, error: "invalid_redirect_uri", description: problem };
  }
  const grantTypes = meta.grant_types ?? ["authorization_code", "refresh_token"];
  if (grantTypes.some((g) => !SUPPORTED_GRANTS.includes(g)) || !grantTypes.includes("authorization_code")) {
    return { ok: false, error: "invalid_client_metadata", description: `grant_types must be drawn from ${SUPPORTED_GRANTS.join(", ")} and include authorization_code` };
  }
  if (meta.response_types && meta.response_types.some((r) => r !== "code")) {
    return { ok: false, error: "invalid_client_metadata", description: 'response_types must be ["code"]' };
  }
  // MCP clients register as public clients; a confidential one gets a secret.
  const method: TokenEndpointAuthMethod = meta.token_endpoint_auth_method ?? "none";
  const clientSecret = method === "none" ? null : CLIENT_SECRET_PREFIX + randomBase62(40);
  const clientId = `cc_dcr_${randomBase62(24)}`;
  const name = meta.client_name?.trim() || new URL(meta.redirect_uris[0]).hostname || "MCP client";
  const row: ClientRow = {
    client_id: clientId,
    kind: "dcr",
    client_name: name.slice(0, 100),
    client_uri: displayUrl(meta.client_uri),
    logo_uri: displayUrl(meta.logo_uri),
    redirect_uris: JSON.stringify([...new Set(meta.redirect_uris)]),
    token_endpoint_auth_method: method,
    client_secret_hash: clientSecret ? await sha256Hex(clientSecret) : null,
    grant_types: JSON.stringify([...new Set(grantTypes)]),
    software_id: meta.software_id ?? null,
    software_version: meta.software_version ?? null,
    created_at: now.toISOString(),
    fetched_at: null,
    last_used_at: null,
  };
  await db
    .prepare(
      `INSERT INTO oauth_clients
         (client_id, kind, client_name, client_uri, logo_uri, redirect_uris, token_endpoint_auth_method,
          client_secret_hash, grant_types, software_id, software_version, created_at)
       VALUES (?1, 'dcr', ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)`,
    )
    .bind(
      row.client_id,
      row.client_name,
      row.client_uri,
      row.logo_uri,
      row.redirect_uris,
      row.token_endpoint_auth_method,
      row.client_secret_hash,
      row.grant_types,
      row.software_id,
      row.software_version,
      row.created_at,
    )
    .run();
  return { ok: true, client: toClient(row), clientSecret, issuedAt: Math.floor(now.getTime() / 1000) };
}

// ---------------------------------------------------------------------------
// Client ID Metadata Documents
// ---------------------------------------------------------------------------

export function isMetadataDocumentClientId(clientId: string): boolean {
  return /^https:\/\//i.test(clientId);
}

/** The SSRF guard for a metadata-document client_id (unit-tested). */
export function checkClientIdUrl(clientId: string): OutboundUrlCheck {
  return checkOutboundUrl(clientId, { label: "client_id", requirePath: true, maxLength: 1000 });
}

export type MetadataDocResult = { ok: true; client: OAuthClient } | { ok: false; error: string };

/** Validate a fetched document against the URL it came from. */
export function clientFromMetadataDocument(clientId: string, doc: unknown): MetadataDocResult {
  if (!doc || typeof doc !== "object" || Array.isArray(doc)) return { ok: false, error: "client metadata is not a JSON object" };
  const d = doc as Record<string, unknown>;
  if (d.client_id !== clientId) return { ok: false, error: "client metadata client_id does not match its URL" };
  if ("client_secret" in d || "client_secret_expires_at" in d) {
    return { ok: false, error: "client metadata must not contain a client secret" };
  }
  const method = d.token_endpoint_auth_method ?? "none";
  if (method !== "none") return { ok: false, error: `token_endpoint_auth_method ${String(method)} is not supported; use none` };
  if (!Array.isArray(d.redirect_uris) || d.redirect_uris.length === 0 || d.redirect_uris.length > 20) {
    return { ok: false, error: "client metadata needs redirect_uris" };
  }
  for (const uri of d.redirect_uris) {
    const problem = redirectUriProblem(uri);
    if (problem) return { ok: false, error: problem };
  }
  // RFC 7591's default is authorization_code alone; refresh is allowed too
  // unless the document lists grant_types without it.
  const grantTypes = Array.isArray(d.grant_types)
    ? d.grant_types.filter((g): g is string => typeof g === "string")
    : ["authorization_code", "refresh_token"];
  const host = new URL(clientId).hostname;
  const name = typeof d.client_name === "string" && d.client_name.trim() ? d.client_name.trim().slice(0, 100) : host;
  return {
    ok: true,
    client: {
      clientId,
      kind: "cimd",
      clientName: name,
      clientUri: displayUrl(typeof d.client_uri === "string" ? d.client_uri : null),
      logoUri: displayUrl(typeof d.logo_uri === "string" ? d.logo_uri : null),
      redirectUris: [...new Set(d.redirect_uris as string[])],
      tokenEndpointAuthMethod: "none",
      clientSecretHash: null,
      grantTypes,
    },
  };
}

/** Fetch a metadata document under the SSRF rules. Never throws. */
export async function fetchClientMetadata(
  clientId: string,
  fetchImpl: typeof fetch = fetch,
): Promise<{ ok: true; doc: unknown } | { ok: false; error: string }> {
  const checked = checkClientIdUrl(clientId);
  if (!checked.ok) return { ok: false, error: checked.error };
  let res: Response;
  try {
    res = await fetchImpl(checked.url.toString(), {
      method: "GET",
      redirect: "manual",
      signal: AbortSignal.timeout(CIMD_TIMEOUT_MS),
      headers: { accept: "application/json", "user-agent": "CaptureCat-OAuth/1.0 (+https://capturecat.so/auth.md)" },
    });
  } catch {
    return { ok: false, error: "could not fetch the client metadata document" };
  }
  if (res.status !== 200) {
    await res.body?.cancel().catch(() => {});
    return { ok: false, error: `client metadata document answered HTTP ${res.status}` };
  }
  const text = await readCappedText(res, CIMD_MAX_BYTES).catch(() => null);
  if (text === null) return { ok: false, error: "client metadata document is larger than 64 KB" };
  try {
    return { ok: true, doc: JSON.parse(text) };
  } catch {
    return { ok: false, error: "client metadata document is not JSON" };
  }
}

async function cacheMetadataClient(db: D1Database, client: OAuthClient, nowIso: string): Promise<void> {
  await db
    .prepare(
      `INSERT INTO oauth_clients
         (client_id, kind, client_name, client_uri, logo_uri, redirect_uris, token_endpoint_auth_method, grant_types, created_at, fetched_at)
       VALUES (?1, 'cimd', ?2, ?3, ?4, ?5, 'none', ?6, ?7, ?7)
       ON CONFLICT(client_id) DO UPDATE SET
         client_name = excluded.client_name, client_uri = excluded.client_uri, logo_uri = excluded.logo_uri,
         redirect_uris = excluded.redirect_uris, grant_types = excluded.grant_types, fetched_at = excluded.fetched_at
       WHERE oauth_clients.kind = 'cimd'`,
    )
    .bind(
      client.clientId,
      client.clientName,
      client.clientUri,
      client.logoUri,
      JSON.stringify(client.redirectUris),
      JSON.stringify(client.grantTypes),
      nowIso,
    )
    .run();
}

export type ResolveClientResult = { ok: true; client: OAuthClient } | { ok: false; error: string };

/** client_id → client, from the DCR table or a (cached) metadata document. */
export async function resolveClient(
  env: Pick<Env, "DB">,
  clientId: string,
  now: Date = new Date(),
  fetchImpl: typeof fetch = fetch,
): Promise<ResolveClientResult> {
  if (typeof clientId !== "string" || clientId.length === 0 || clientId.length > 1000) {
    return { ok: false, error: "client_id is missing or invalid" };
  }
  const row = await env.DB.prepare(`SELECT * FROM oauth_clients WHERE client_id = ?`).bind(clientId).first<ClientRow>();
  if (!isMetadataDocumentClientId(clientId)) {
    return row && row.kind === "dcr" ? { ok: true, client: toClient(row) } : { ok: false, error: "unknown client_id" };
  }
  const checked = checkClientIdUrl(clientId);
  if (!checked.ok) return { ok: false, error: checked.error };
  const age = row?.fetched_at ? now.getTime() - Date.parse(row.fetched_at) : Infinity;
  if (row && row.kind === "cimd" && age < CIMD_CACHE_MS) return { ok: true, client: toClient(row) };

  const fetched = await fetchClientMetadata(clientId, fetchImpl);
  const validated = fetched.ok ? clientFromMetadataDocument(clientId, fetched.doc) : fetched;
  if (validated.ok) {
    await cacheMetadataClient(env.DB, validated.client, now.toISOString());
    return validated;
  }
  // The host is down or serving garbage: a recent good copy still stands.
  if (row && row.kind === "cimd" && age < CIMD_STALE_MS && !fetched.ok) return { ok: true, client: toClient(row) };
  return { ok: false, error: validated.error };
}

/**
 * Token-endpoint client authentication. Public clients present no secret;
 * a client registered with a secret must present it (Basic or POST body).
 */
export async function authenticateClient(client: OAuthClient, presentedSecret: string | null): Promise<boolean> {
  if (client.tokenEndpointAuthMethod === "none") return true;
  if (!presentedSecret || !client.clientSecretHash) return false;
  return timingSafeEqual(await sha256Hex(presentedSecret), client.clientSecretHash);
}

export async function touchClient(db: D1Database, clientId: string, nowIso: string): Promise<void> {
  await db
    .prepare(`UPDATE oauth_clients SET last_used_at = ?1 WHERE client_id = ?2`)
    .bind(nowIso, clientId)
    .run()
    .catch(() => {});
}
