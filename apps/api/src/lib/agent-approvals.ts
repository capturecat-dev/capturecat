/**
 * "Ask me first" (migration 0034): an agent must get the account owner's
 * approval before it makes a video viewable to more people, or posts where
 * viewers see it.
 *
 *   1. A gated MCP call (src/mcp/approval-gate.ts) without approval_id
 *      creates a PENDING row and answers `approval_required` with a link to
 *      https://app.capturecat.so/app/approvals/<id>.
 *   2. The human opens the link, signed in, and approves or denies
 *      (routes/agent-approvals.ts — SESSION ONLY: no agent credential can
 *      reach it, so an agent can never approve its own request).
 *   3. The agent repeats the SAME call with approval_id. consumeApproval runs
 *      it at most once: the row must be approved, unexpired, requested by
 *      the same token, for the same tool, with canonically equal arguments.
 *
 * Every step is written to agent_audit_log.
 */

import { generateId } from "./id";
import { sha256Hex } from "./screenshot/keys";
import { writeAgentAudit } from "./agent-tokens";

/** A request must be decided within this; an approval used within this of
 *  being given. */
export const APPROVAL_TTL_MS = 15 * 60_000;
/** Undecided requests one user may have at once — an agent looping on a
 *  gated call cannot flood the approvals list. */
export const MAX_PENDING_APPROVALS = 20;

export type StoredApprovalStatus = "pending" | "approved" | "denied" | "expired" | "used";

// ---------------------------------------------------------------------------
// Canonical arguments
// ---------------------------------------------------------------------------

/**
 * JSON with object keys sorted at every depth and `undefined` members
 * dropped, so two argument objects that mean the same thing serialize to the
 * same string whatever order the agent sent the keys in.
 */
export function canonicalJson(value: unknown): string {
  return JSON.stringify(sortDeep(value));
}

function sortDeep(value: unknown): unknown {
  if (Array.isArray(value)) return value.map((v) => (v === undefined ? null : sortDeep(v)));
  if (value && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const key of Object.keys(value as Record<string, unknown>).sort()) {
      const v = (value as Record<string, unknown>)[key];
      if (v !== undefined) out[key] = sortDeep(v);
    }
    return out;
  }
  return value;
}

/**
 * The stored form of a call's arguments: `approval_id` removed, and every
 * top-level string under `secretKeys` (a new share password) replaced by its
 * SHA-256 — the approval row must never hold a password in clear, yet the
 * repeat call must still match it exactly.
 */
export async function canonicalApprovalArgs(
  args: Record<string, unknown>,
  secretKeys: readonly string[] = [],
): Promise<string> {
  const copy: Record<string, unknown> = { ...args };
  delete copy.approval_id;
  for (const key of secretKeys) {
    if (typeof copy[key] === "string") copy[key] = `sha256:${await sha256Hex(copy[key] as string)}`;
  }
  return canonicalJson(copy);
}

// ---------------------------------------------------------------------------
// Rows
// ---------------------------------------------------------------------------

interface ApprovalRow {
  id: string;
  user_id: string;
  token_id: string;
  tool: string;
  args_json: string;
  summary: string;
  details: string | null;
  video_id: string | null;
  status: StoredApprovalStatus;
  created_at: string;
  decided_at: string | null;
  expires_at: string;
  used_at: string | null;
}

export interface ApprovalView {
  id: string;
  tokenId: string;
  tool: string;
  summary: string;
  details: string[];
  videoId: string | null;
  /** Effective: a pending or approved row past its expiry reads "expired". */
  status: StoredApprovalStatus;
  createdAt: string;
  decidedAt: string | null;
  expiresAt: string;
  usedAt: string | null;
}

export function effectiveStatus(row: Pick<ApprovalRow, "status" | "expires_at">, now: Date): StoredApprovalStatus {
  if ((row.status === "pending" || row.status === "approved") && Date.parse(row.expires_at) <= now.getTime()) {
    return "expired";
  }
  return row.status;
}

function parseDetails(raw: string | null): string[] {
  try {
    const parsed: unknown = JSON.parse(raw ?? "[]");
    return Array.isArray(parsed) ? parsed.filter((d): d is string => typeof d === "string") : [];
  } catch {
    return [];
  }
}

function toView(row: ApprovalRow, now: Date): ApprovalView {
  return {
    id: row.id,
    tokenId: row.token_id,
    tool: row.tool,
    summary: row.summary,
    details: parseDetails(row.details),
    videoId: row.video_id,
    status: effectiveStatus(row, now),
    createdAt: row.created_at,
    decidedAt: row.decided_at,
    expiresAt: row.expires_at,
    usedAt: row.used_at,
  };
}

async function getRow(db: D1Database, id: string): Promise<ApprovalRow | null> {
  if (!/^[a-z0-9]{8,64}$/.test(id)) return null;
  return db.prepare(`SELECT * FROM agent_approvals WHERE id = ?`).bind(id).first<ApprovalRow>();
}

export interface NewApproval {
  uid: string;
  tokenId: string;
  tool: string;
  argsJson: string;
  summary: string;
  details: string[];
  videoId: string | null;
}

export type CreateApprovalResult = { ok: true; approval: ApprovalView; reused: boolean } | { ok: false; error: string };

/**
 * A pending request for this exact call. An identical request from the same
 * token that is still pending is returned instead of a second row, so an
 * agent that repeats itself does not stack up links.
 */
export async function createApproval(db: D1Database, input: NewApproval, now: Date = new Date()): Promise<CreateApprovalResult> {
  const nowIso = now.toISOString();
  const existing = await db
    .prepare(
      `SELECT * FROM agent_approvals
        WHERE user_id = ?1 AND token_id = ?2 AND tool = ?3 AND args_json = ?4
          AND status = 'pending' AND expires_at > ?5
        ORDER BY created_at DESC LIMIT 1`,
    )
    .bind(input.uid, input.tokenId, input.tool, input.argsJson, nowIso)
    .first<ApprovalRow>();
  if (existing) return { ok: true, approval: toView(existing, now), reused: true };

  const pending = await db
    .prepare(`SELECT COUNT(*) AS n FROM agent_approvals WHERE user_id = ?1 AND status = 'pending' AND expires_at > ?2`)
    .bind(input.uid, nowIso)
    .first<{ n: number }>();
  if ((pending?.n ?? 0) >= MAX_PENDING_APPROVALS) {
    return {
      ok: false,
      error: `There are already ${MAX_PENDING_APPROVALS} requests waiting for the account owner's approval. Ask them to review those first (CaptureCat → Settings → Agent access).`,
    };
  }

  const row: ApprovalRow = {
    id: generateId(24),
    user_id: input.uid,
    token_id: input.tokenId,
    tool: input.tool.slice(0, 80),
    args_json: input.argsJson,
    summary: input.summary.slice(0, 500),
    details: JSON.stringify(input.details.slice(0, 20).map((d) => d.slice(0, 300))),
    video_id: input.videoId,
    status: "pending",
    created_at: nowIso,
    decided_at: null,
    expires_at: new Date(now.getTime() + APPROVAL_TTL_MS).toISOString(),
    used_at: null,
  };
  await db
    .prepare(
      `INSERT INTO agent_approvals
         (id, user_id, token_id, tool, args_json, summary, details, video_id, status, created_at, expires_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 'pending', ?9, ?10)`,
    )
    .bind(row.id, row.user_id, row.token_id, row.tool, row.args_json, row.summary, row.details, row.video_id, row.created_at, row.expires_at)
    .run();
  return { ok: true, approval: toView(row, now), reused: false };
}

/** Any approval the token itself asked for (get_approval), else null. */
export async function getApprovalForToken(
  db: D1Database,
  uid: string,
  tokenId: string,
  id: string,
  now: Date = new Date(),
): Promise<ApprovalView | null> {
  const row = await getRow(db, id);
  return row && row.user_id === uid && row.token_id === tokenId ? toView(row, now) : null;
}

// ---------------------------------------------------------------------------
// The human's side (session routes)
// ---------------------------------------------------------------------------

/** Who asked: the token's name and prefix, and the OAuth client behind it. */
export interface ApprovalRequester {
  tokenName: string | null;
  tokenPrefix: string | null;
  kind: "personal" | "oauth";
  oauthClient: { clientId: string; name: string; logoUri: string | null; clientUri: string | null } | null;
}

export interface ApprovalDetail extends ApprovalView {
  requester: ApprovalRequester;
  video: { id: string; title: string; isPrivate: boolean } | null;
}

export async function getApprovalForUser(
  db: D1Database,
  uid: string,
  id: string,
  now: Date = new Date(),
): Promise<ApprovalDetail | null> {
  const row = await getRow(db, id);
  if (!row || row.user_id !== uid) return null;
  const [token, video] = await Promise.all([
    db
      .prepare(
        `SELECT t.name, t.token_prefix, t.oauth_client_id, c.client_name, c.logo_uri, c.client_uri
           FROM agent_tokens t LEFT JOIN oauth_clients c ON c.client_id = t.oauth_client_id
          WHERE t.id = ?`,
      )
      .bind(row.token_id)
      .first<{
        name: string;
        token_prefix: string;
        oauth_client_id: string | null;
        client_name: string | null;
        logo_uri: string | null;
        client_uri: string | null;
      }>(),
    row.video_id
      ? db
          .prepare(`SELECT video_id, file_name, is_private FROM shared_videos WHERE video_id = ? AND uid = ?`)
          .bind(row.video_id, uid)
          .first<{ video_id: string; file_name: string; is_private: number }>()
      : Promise.resolve(null),
  ]);
  return {
    ...toView(row, now),
    requester: {
      tokenName: token?.name ?? null,
      tokenPrefix: token?.token_prefix ?? null,
      kind: token?.oauth_client_id ? "oauth" : "personal",
      oauthClient: token?.oauth_client_id
        ? {
            clientId: token.oauth_client_id,
            name: token.client_name ?? token.name,
            logoUri: token.logo_uri,
            clientUri: token.client_uri,
          }
        : null,
    },
    video: video ? { id: video.video_id, title: video.file_name, isPrivate: video.is_private === 1 } : null,
  };
}

/** The user's undecided, unexpired requests, newest first. */
export async function listPendingApprovals(db: D1Database, uid: string, now: Date = new Date()): Promise<ApprovalDetail[]> {
  const { results } = await db
    .prepare(
      `SELECT id FROM agent_approvals
        WHERE user_id = ?1 AND status = 'pending' AND expires_at > ?2
        ORDER BY created_at DESC LIMIT ?3`,
    )
    .bind(uid, now.toISOString(), MAX_PENDING_APPROVALS)
    .all<{ id: string }>();
  const out: ApprovalDetail[] = [];
  for (const r of results ?? []) {
    const detail = await getApprovalForUser(db, uid, r.id, now);
    if (detail) out.push(detail);
  }
  return out;
}

export type DecideResult =
  | { ok: true; approval: ApprovalView }
  | { ok: false; status: 404 | 409; error: string; approval?: ApprovalView };

/**
 * Approve or deny a pending, unexpired request of this user. Approving
 * restarts the 15-minute clock: that is the window the agent has to use it.
 * Audited under the token that asked.
 */
export async function decideApproval(
  db: D1Database,
  uid: string,
  id: string,
  decision: "approved" | "denied",
  now: Date = new Date(),
): Promise<DecideResult> {
  const row = await getRow(db, id);
  if (!row || row.user_id !== uid) return { ok: false, status: 404, error: "No such approval request" };
  const nowIso = now.toISOString();
  const expiresAt = decision === "approved" ? new Date(now.getTime() + APPROVAL_TTL_MS).toISOString() : row.expires_at;
  const result = await db
    .prepare(
      `UPDATE agent_approvals SET status = ?1, decided_at = ?2, expires_at = ?3
        WHERE id = ?4 AND user_id = ?5 AND status = 'pending' AND expires_at > ?2`,
    )
    .bind(decision, nowIso, expiresAt, id, uid)
    .run();
  if ((result.meta?.changes ?? 0) === 0) {
    const current = toView(row, now);
    const why =
      current.status === "expired"
        ? "This request expired before it was decided. The agent can ask again."
        : `This request was already ${current.status}.`;
    return { ok: false, status: 409, error: why, approval: current };
  }
  await writeAgentAudit(
    db,
    {
      uid,
      tokenId: row.token_id,
      tool: decision === "approved" ? `approval.approved:${row.tool}` : `approval.denied:${row.tool}`,
      videoId: row.video_id,
      ok: true,
      error: null,
    },
    now,
  );
  const fresh = await getRow(db, id);
  return { ok: true, approval: toView(fresh ?? { ...row, status: decision, decided_at: nowIso, expires_at: expiresAt }, now) };
}

// ---------------------------------------------------------------------------
// The agent's repeat call
// ---------------------------------------------------------------------------

export type ConsumeResult =
  | { ok: true; approval: ApprovalView }
  | { ok: false; reason: "pending"; approval: ApprovalView }
  | { ok: false; reason: "not_found" | "denied" | "expired" | "used" | "mismatch"; message: string };

/**
 * Spend an approval on the call it was given for. Exactly once: the final
 * UPDATE re-checks every condition, so two concurrent repeats cannot both win.
 */
export async function consumeApproval(
  db: D1Database,
  input: { id: string; uid: string; tokenId: string; tool: string; argsJson: string },
  now: Date = new Date(),
): Promise<ConsumeResult> {
  const row = await getRow(db, input.id);
  // Someone else's id, another token's, or nonsense: all "not found", so an
  // approval id is no oracle across tokens or accounts.
  if (!row || row.user_id !== input.uid || row.token_id !== input.tokenId) {
    return {
      ok: false,
      reason: "not_found",
      message: `No approval "${input.id}" was requested by this token. Call the tool again without approval_id to ask for one.`,
    };
  }
  const view = toView(row, now);
  if (row.tool !== input.tool) {
    return { ok: false, reason: "mismatch", message: `Approval ${row.id} was given for ${row.tool}, not ${input.tool}.` };
  }
  switch (view.status) {
    case "pending":
      return { ok: false, reason: "pending", approval: view };
    case "denied":
      return {
        ok: false,
        reason: "denied",
        message: "The account owner denied this request. Don't retry it unless they ask you to.",
      };
    case "expired":
      return {
        ok: false,
        reason: "expired",
        message: "This approval expired. Call the tool again without approval_id to ask the account owner again.",
      };
    case "used":
      return {
        ok: false,
        reason: "used",
        message: "This approval was already used — each approval runs its call once. Ask again for another.",
      };
    default:
      break;
  }
  if (row.args_json !== input.argsJson) {
    return {
      ok: false,
      reason: "mismatch",
      message:
        "These arguments differ from the ones the account owner approved. Repeat the call with exactly the approved arguments, or call without approval_id to ask for the new ones.",
    };
  }
  const nowIso = now.toISOString();
  const result = await db
    .prepare(
      `UPDATE agent_approvals SET status = 'used', used_at = ?1
        WHERE id = ?2 AND user_id = ?3 AND token_id = ?4 AND tool = ?5 AND args_json = ?6
          AND status = 'approved' AND expires_at > ?1`,
    )
    .bind(nowIso, row.id, input.uid, input.tokenId, input.tool, input.argsJson)
    .run();
  if ((result.meta?.changes ?? 0) === 0) {
    return {
      ok: false,
      reason: "used",
      message: "This approval was already used — each approval runs its call once. Ask again for another.",
    };
  }
  return { ok: true, approval: { ...view, status: "used", usedAt: nowIso } };
}
