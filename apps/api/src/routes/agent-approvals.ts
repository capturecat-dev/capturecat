/**
 * /api/agent-approvals — the account owner's side of "ask me first"
 * (lib/agent-approvals.ts, src/mcp/approval-gate.ts).
 *
 *   GET  /agent-approvals              pending requests, newest first
 *   GET  /agent-approvals/:id          one request: who asks, what exactly, which video
 *   POST /agent-approvals/:id/approve  run-once permission for that exact call
 *   POST /agent-approvals/:id/deny
 *
 * SESSION ONLY. An agent credential (cc_pat_ / cc_oat_) is refused with 403
 * before the session lookup, so no agent can approve its own request — and
 * there is no MCP tool that decides one.
 */

import { Hono } from "hono";
import type { Env, Variables } from "../types";
import { requireAuth } from "../middleware/auth";
import { refuseAgentCredentials } from "../middleware/session-only";
import { userRateLimit } from "../lib/entitlement";
import { decideApproval, getApprovalForUser, listPendingApprovals } from "../lib/agent-approvals";
import { approveUrl } from "../mcp/approval-gate";
import { shareBaseURL } from "../lib/origins";

export const agentApprovalRoutes = new Hono<{ Bindings: Env; Variables: Variables }>();

agentApprovalRoutes.use("/agent-approvals/*", refuseAgentCredentials, requireAuth);

function withLinks(env: Env, approval: { id: string; video: { id: string } | null }) {
  return {
    approveUrl: approveUrl(env, approval.id),
    videoShareUrl: approval.video ? `${shareBaseURL(env)}/share/${approval.video.id}` : null,
  };
}

agentApprovalRoutes.get("/agent-approvals", async (c) => {
  const approvals = await listPendingApprovals(c.env.DB, c.get("user").uid);
  return c.json({ approvals: approvals.map((a) => ({ ...a, ...withLinks(c.env, a) })) });
});

agentApprovalRoutes.get("/agent-approvals/:id", async (c) => {
  const approval = await getApprovalForUser(c.env.DB, c.get("user").uid, c.req.param("id"));
  if (!approval) return c.json({ error: "No such approval request" }, 404);
  return c.json({ approval: { ...approval, ...withLinks(c.env, approval) } });
});

const decide = (decision: "approved" | "denied") =>
  agentApprovalRoutes.post(
    `/agent-approvals/:id/${decision === "approved" ? "approve" : "deny"}`,
    userRateLimit({ limit: 60, windowSec: 60, scope: "agent-approvals" }),
    async (c) => {
      const uid = c.get("user").uid;
      const result = await decideApproval(c.env.DB, uid, c.req.param("id"), decision);
      if (!result.ok) return c.json({ error: result.error, status: result.approval?.status ?? null }, result.status);
      const approval = await getApprovalForUser(c.env.DB, uid, result.approval.id);
      return c.json({ approval: approval ? { ...approval, ...withLinks(c.env, approval) } : result.approval });
    },
  );
decide("approved");
decide("denied");
