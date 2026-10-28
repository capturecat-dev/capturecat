/**
 * Plan-feature gates for MCP tools. /mcp itself already refuses a token whose
 * user's plan lacks `agentAccess` (routes.ts); a tool that needs more than
 * that calls one of these first thing in `run`:
 *
 *   import { requireAgentEditing } from "./gates";
 *   async run(args, ctx) {
 *     await requireAgentEditing(ctx);   // ToolError unless the plan has agentEditing
 *     …
 *   }
 *
 * The plan comes from ctx.entitlement() — resolved once per request through
 * the same entitlement code the session routes use.
 */

import type { PlanRecord } from "../lib/plans";
import { featureUnavailableMessage, type AgentFeature } from "../lib/agent-features";
import { ToolError, type ToolContext } from "./tool";

/** The plan, if it includes `feature`; otherwise a ToolError the agent can
 *  read ("… isn't included in the account's Free plan …"). */
export async function requireAgentFeature(ctx: ToolContext, feature: AgentFeature): Promise<PlanRecord> {
  const { plan } = await ctx.entitlement();
  if (plan.features[feature] !== true) throw new ToolError(featureUnavailableMessage(feature, plan));
  return plan;
}

/** Cloud-project editing tools (projects:write and friends). */
export function requireAgentEditing(ctx: ToolContext): Promise<PlanRecord> {
  return requireAgentFeature(ctx, "agentEditing");
}

/** Webhook tools (list_webhooks, create_webhook). */
export function requireAgentWebhooks(ctx: ToolContext): Promise<PlanRecord> {
  return requireAgentFeature(ctx, "agentWebhooks");
}
