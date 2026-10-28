import { z } from "zod";

import { apiFetch } from "@/lib/session";
import { authedProcedure, createTRPCRouter } from "@/lib/trpc/init";
import type { ApprovalDetail } from "@/lib/agent-access";
import { fail } from "./agent-tokens";

/**
 * "Ask me first" — api.capturecat.so /api/agent-approvals
 * (apps/api/src/routes/agent-approvals.ts). Session only: this router relays
 * the signed-in user's cookie, which is the ONLY way a request gets decided —
 * no agent credential can reach those routes.
 */
const Id = z.object({ id: z.string().regex(/^[a-z0-9]{8,64}$/) });

export const agentApprovalsRouter = createTRPCRouter({
  pending: authedProcedure.query(async () => {
    const res = await apiFetch("/api/agent-approvals");
    if (!res.ok) return fail(res, "Could not load approval requests");
    return (await res.json()) as { approvals: ApprovalDetail[] };
  }),

  get: authedProcedure.input(Id).query(async ({ input }) => {
    const res = await apiFetch(`/api/agent-approvals/${input.id}`);
    if (!res.ok) return fail(res, "Could not load this request");
    return (await res.json()) as { approval: ApprovalDetail };
  }),

  decide: authedProcedure
    .input(Id.extend({ decision: z.enum(["approve", "deny"]) }))
    .mutation(async ({ input }) => {
      const res = await apiFetch(`/api/agent-approvals/${input.id}/${input.decision}`, { method: "POST" });
      if (!res.ok) return fail(res, "Could not record your decision");
      return (await res.json()) as { approval: ApprovalDetail };
    }),
});
