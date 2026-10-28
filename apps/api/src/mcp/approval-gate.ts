/**
 * "Ask me first" for MCP tools (lib/agent-approvals.ts holds the rows).
 *
 * A tool opts in with `approval: (args, ctx) => need | null` on its
 * definition: null = this call may run now (it makes nothing more visible),
 * otherwise a summary of what the account owner must approve. callTool
 * (server.ts) runs the gate after the arguments are valid and before the
 * tool does anything:
 *
 *   no approval_id        → a pending request; the tool answers a NORMAL
 *                           result {status:"approval_required", approval_id,
 *                           approve_url, expires_at, message}
 *   approval_id, pending  → {status:"approval_pending", …} (same shape)
 *   approval_id, approved → the call runs, and the approval is spent
 *   denied / expired / used / other arguments / another token → a tool error
 *
 * Tools with a gate declare `approval_id` in their input and wrap their
 * output schema with `withApproval`, so the approval answer is valid
 * structuredContent for clients that validate it.
 */

import { z } from "zod";
import { canonicalApprovalArgs, consumeApproval, createApproval, type ApprovalView } from "../lib/agent-approvals";
import { appBaseURL } from "../lib/origins";
import type { Env } from "../types";
import { ToolError, type ToolContext, type ToolDefinition, type ToolOutput } from "./tool";

export const ApprovalIdSchema = z
  .string()
  .trim()
  .regex(/^[a-z0-9]{8,64}$/, { error: "approval_id is the id an approval_required answer returned" })
  .describe(
    "Only when repeating a call that answered approval_required: the approval_id it returned, after the account owner approved it. The other arguments must be exactly the same.",
  );

export const ApprovalAnswer = z
  .object({
    status: z
      .enum(["approval_required", "approval_pending"])
      .describe("approval_required: just asked. approval_pending: asked earlier, not decided yet."),
    approval_id: z.string(),
    approve_url: z.string().describe("Show this link to the account owner; they approve or deny there, signed in."),
    expires_at: z.string().describe("ISO-8601. Undecided requests expire then; ask again after."),
    summary: z.string().describe("What the account owner is being asked to approve."),
    message: z.string(),
  })
  .describe("Returned instead of the result when the account owner must approve this call first.");

/** The tool's own output, or the approval answer. */
export function withApproval<S extends z.ZodType>(schema: S) {
  return z.union([schema, ApprovalAnswer]);
}

export function approveUrl(env: Env, id: string): string {
  return `${appBaseURL(env)}/app/approvals/${id}`;
}

function answer(env: Env, tool: string, approval: ApprovalView, status: "approval_required" | "approval_pending"): ToolOutput<z.input<typeof ApprovalAnswer>> {
  const url = approveUrl(env, approval.id);
  const message =
    status === "approval_required"
      ? `This needs the account owner's approval first: ${approval.summary}. Show them this link and wait for them to approve it: ${url} — it expires at ${approval.expiresAt}. ` +
        `Then call ${tool} again with exactly the same arguments plus approval_id "${approval.id}". Use get_approval to check whether they have decided.`
      : `Still waiting for the account owner to approve: ${approval.summary}. Ask them to open ${url} (expires ${approval.expiresAt}), then repeat this call.`;
  return {
    text: message,
    videoId: approval.videoId,
    structured: {
      status,
      approval_id: approval.id,
      approve_url: url,
      expires_at: approval.expiresAt,
      summary: approval.summary,
      message,
    },
  };
}

export type GateOutcome =
  | { kind: "run" }
  | { kind: "answer"; output: ToolOutput<z.input<typeof ApprovalAnswer>>; auditError: string };

/** Decide whether `tool` may run with `args` now. Throws ToolError for a
 *  denied, expired, used or mismatched approval. */
export async function runApprovalGate(
  tool: ToolDefinition,
  args: Record<string, unknown>,
  ctx: ToolContext,
): Promise<GateOutcome> {
  if (!tool.approval) return { kind: "run" };
  const need = await tool.approval(args, ctx);
  if (!need) return { kind: "run" };

  const argsJson = await canonicalApprovalArgs(args, need.secretKeys ?? []);
  const approvalId = typeof args.approval_id === "string" ? args.approval_id : null;
  const { env, principal } = ctx;

  if (!approvalId) {
    const created = await createApproval(env.DB, {
      uid: principal.uid,
      tokenId: principal.tokenId,
      tool: tool.name,
      argsJson,
      summary: need.summary,
      details: need.details,
      videoId: need.videoId,
    });
    if (!created.ok) throw new ToolError(created.error, need.videoId);
    return {
      kind: "answer",
      output: answer(env, tool.name, created.approval, "approval_required"),
      auditError: `approval required (${created.approval.id})`,
    };
  }

  const spent = await consumeApproval(env.DB, {
    id: approvalId,
    uid: principal.uid,
    tokenId: principal.tokenId,
    tool: tool.name,
    argsJson,
  });
  if (spent.ok) return { kind: "run" };
  if (spent.reason === "pending") {
    return {
      kind: "answer",
      output: answer(env, tool.name, spent.approval, "approval_pending"),
      auditError: `approval pending (${spent.approval.id})`,
    };
  }
  throw new ToolError(spent.message, need.videoId);
}
