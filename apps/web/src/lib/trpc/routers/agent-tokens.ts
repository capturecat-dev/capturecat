import { z } from "zod";
import { TRPCError } from "@trpc/server";

import { apiFetch } from "@/lib/session";
import { authedProcedure, createTRPCRouter } from "@/lib/trpc/init";
import { AGENT_SCOPES, type AgentTokenSummary } from "@/lib/agent-access";

/**
 * Agent tokens for the remote MCP server — api.capturecat.so
 * /api/agent-tokens (apps/api/src/routes/agent-tokens.ts). The API validates,
 * hashes and stores; this router only relays with the session cookie, so
 * the rules live in one place. The plaintext token passes through `create`
 * once and is never cached here.
 */

export type AgentAuditEntry = {
  id: string;
  tokenId: string;
  tokenName: string | null;
  tokenPrefix: string | null;
  tool: string;
  videoId: string | null;
  ok: boolean;
  error: string | null;
  at: string;
};

async function fail(res: Response, fallback: string): Promise<never> {
  const body = (await res.json().catch(() => ({}))) as { error?: string };
  throw new TRPCError({
    code:
      res.status === 401
        ? "UNAUTHORIZED"
        : res.status === 403
          ? "FORBIDDEN"
          : res.status === 404
            ? "NOT_FOUND"
            : res.status === 429
              ? "TOO_MANY_REQUESTS"
              : res.status >= 500
                ? "INTERNAL_SERVER_ERROR"
                : "BAD_REQUEST",
    message: body.error ?? fallback,
  });
}

export const agentTokensRouter = createTRPCRouter({
  list: authedProcedure.query(async () => {
    const res = await apiFetch("/api/agent-tokens");
    if (!res.ok) return fail(res, "Could not load agent tokens");
    return (await res.json()) as { tokens: AgentTokenSummary[]; scopes: string[]; maxActive: number };
  }),

  create: authedProcedure
    .input(
      z.object({
        name: z.string().trim().min(1).max(60),
        scopes: z.array(z.enum(AGENT_SCOPES)).min(1),
        expiresInDays: z.number().int().min(1).max(365).nullable(),
      })
    )
    .mutation(async ({ input }) => {
      const res = await apiFetch("/api/agent-tokens", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(input),
      });
      if (!res.ok) return fail(res, "Could not create the token");
      return (await res.json()) as AgentTokenSummary & { token: string };
    }),

  revoke: authedProcedure.input(z.object({ id: z.string().min(1).max(64) })).mutation(async ({ input }) => {
    const res = await apiFetch(`/api/agent-tokens/${encodeURIComponent(input.id)}`, { method: "DELETE" });
    if (!res.ok) return fail(res, "Could not revoke the token");
    return (await res.json()) as { id: string; revoked: true };
  }),

  audit: authedProcedure.query(async () => {
    const res = await apiFetch("/api/agent-tokens/audit");
    if (!res.ok) return fail(res, "Could not load recent agent activity");
    return (await res.json()) as { entries: AgentAuditEntry[] };
  }),
});
