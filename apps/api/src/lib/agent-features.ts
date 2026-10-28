/**
 * Plan gates for the agent surface — "enable by features, gate server-side".
 *
 *   agentAccess    agent tokens (create), OAuth (consent + token issue) and
 *                  EVERY /mcp request: a token whose user's plan lost it is
 *                  refused with a 403 that says why
 *   agentWebhooks  webhook endpoints (session routes + MCP tools) and every
 *                  delivery (lib/webhooks.ts)
 *   agentEditing   the cloud-project editing tools (src/mcp/gates.ts
 *                  requireAgentEditing — each tool calls it)
 *
 * Resolution is the one the session routes use: resolveEntitlement (the
 * `subscription` table + the server-owned tester/blocked columns) →
 * planForEntitlement (the `plan` row). Nothing here trusts a client or a
 * token's own claims about the plan.
 */

import type { EntitlementTier } from "../types";
import { resolveEntitlement } from "./entitlement";
import { planForEntitlement, type PlanRecord } from "./plans";

export const AGENT_FEATURES = ["agentAccess", "agentWebhooks", "agentEditing"] as const;
export type AgentFeature = (typeof AGENT_FEATURES)[number];

const FEATURE_NAME: Record<AgentFeature, string> = {
  agentAccess: "Agent access (agent tokens, connectors and the remote MCP server)",
  agentWebhooks: "Webhooks",
  agentEditing: "Agent editing of cloud projects",
};

export const UPGRADE_URL = "https://app.capturecat.so/billing";

/** The tier and plan governing `uid`, or "blocked". Never cached: a downgrade
 *  or a block applies to the very next agent request. */
export async function agentPlanFor(
  db: D1Database,
  uid: string,
  claims: { tester: boolean; blocked: boolean } | undefined,
): Promise<{ tier: EntitlementTier; plan: PlanRecord } | "blocked"> {
  const ent = await resolveEntitlement(db, uid, claims);
  if (ent === "blocked") return "blocked";
  return { tier: ent.tier, plan: await planForEntitlement(db, ent) };
}

/** The three flags, for the web's Agent access section. */
export function agentFeatureFlags(plan: PlanRecord): Record<AgentFeature, boolean> {
  return {
    agentAccess: plan.features.agentAccess === true,
    agentWebhooks: plan.features.agentWebhooks === true,
    agentEditing: plan.features.agentEditing === true,
  };
}

/** One sentence an agent or a person can act on. */
export function featureUnavailableMessage(feature: AgentFeature, plan: Pick<PlanRecord, "displayName">): string {
  return `${FEATURE_NAME[feature]} isn't included in the account's ${plan.displayName} plan. The account owner can upgrade at ${UPGRADE_URL}.`;
}

/** The 403 body every session route answers when a gate is closed. */
export function upgradeRequiredBody(feature: AgentFeature, plan: Pick<PlanRecord, "displayName" | "name">) {
  return {
    error: featureUnavailableMessage(feature, plan),
    code: "upgrade_required",
    feature,
    plan: plan.name,
  };
}
