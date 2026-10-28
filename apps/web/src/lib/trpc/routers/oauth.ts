import { z } from "zod";

import { apiFetch } from "@/lib/session";
import { authedProcedure, createTRPCRouter } from "@/lib/trpc/init";
import type { ConnectedApp, ConsentInfo, OAUTH_PARAMS } from "@/lib/agent-access";
import { fail } from "./agent-tokens";

/**
 * "Sign in with CaptureCat" — the consent page's API and connected apps
 * (apps/api/src/routes/oauth.ts, /api/oauth/*). The API validates the whole
 * authorization request again on every call: this router only relays.
 */
const param = z.string().max(2000).optional();
const Params = z.object({
  response_type: param,
  client_id: param,
  redirect_uri: param,
  scope: param,
  state: param,
  code_challenge: param,
  code_challenge_method: param,
  resource: param,
} satisfies Record<(typeof OAUTH_PARAMS)[number], typeof param>);

function query(params: z.infer<typeof Params>): string {
  const q = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) if (typeof v === "string") q.set(k, v);
  return q.toString();
}

export type ConsentError = { error: string; description: string; redirect: string | null };

export const oauthRouter = createTRPCRouter({
  /** What the consent page shows — or why the request can't go on. */
  info: authedProcedure.input(Params).query(async ({ input }) => {
    const res = await apiFetch(`/api/oauth/authorize/info?${query(input)}`);
    if (res.status === 400) return { ok: false as const, ...((await res.json()) as ConsentError) };
    if (!res.ok) return fail(res, "Could not load this sign-in request");
    return { ok: true as const, ...((await res.json()) as ConsentInfo) };
  }),

  /** Allow (with the scopes left ticked) or Deny → where to send the browser. */
  decide: authedProcedure
    .input(z.object({ params: Params, approve: z.boolean(), scopes: z.array(z.string().max(40)).max(40).optional() }))
    .mutation(async ({ input }) => {
      const res = await apiFetch("/api/oauth/authorize/decision", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          params: Object.fromEntries(Object.entries(input.params).filter(([, v]) => typeof v === "string")),
          approve: input.approve,
          ...(input.scopes ? { scopes: input.scopes } : {}),
        }),
      });
      const body = (await res.json().catch(() => ({}))) as { redirect?: string | null; error?: string; description?: string };
      if (res.ok && body.redirect) return { redirect: body.redirect };
      if (res.status === 400 && body.redirect) return { redirect: body.redirect };
      if (res.status === 400) return { redirect: null, error: body.description ?? body.error ?? "This request is invalid" };
      return fail(new Response(JSON.stringify(body), { status: res.status }), "Could not complete the sign-in");
    }),

  apps: authedProcedure.query(async () => {
    const res = await apiFetch("/api/oauth/apps");
    if (!res.ok) return fail(res, "Could not load connected apps");
    return (await res.json()) as { apps: ConnectedApp[] };
  }),

  revokeApp: authedProcedure.input(z.object({ clientId: z.string().min(1).max(1000) })).mutation(async ({ input }) => {
    const res = await apiFetch("/api/oauth/apps/revoke", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(input),
    });
    if (!res.ok) return fail(res, "Could not disconnect the app");
    return (await res.json()) as { clientId: string; revoked: number };
  }),
});
