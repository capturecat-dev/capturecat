import { z } from "zod";

import { apiFetch } from "@/lib/session";
import { authedProcedure, createTRPCRouter } from "@/lib/trpc/init";
import { fail } from "./agent-tokens";

/**
 * The Mac app's sign-in consent (routes/connect.mac.tsx → apps/api/src/
 * routes/desktop.ts, /api/desktop/connect/*). The API decides everything —
 * whether the request is still open, the new session, the loopback redirect
 * — this router only relays the signed-in browser's calls.
 */
const Rid = z.string().uuid();

export type MacConnectInfo =
  | { ok: true; app: { name: string }; expiresAt: number }
  | { ok: false; error: string; description: string };

export const desktopConnectRouter = createTRPCRouter({
  /** What the consent page shows, or why the request can't go on. */
  info: authedProcedure.input(z.object({ rid: Rid })).query(async ({ input }): Promise<MacConnectInfo> => {
    const res = await apiFetch(`/api/desktop/connect/${input.rid}`);
    if (res.status === 400) return { ok: false, ...((await res.json()) as { error: string; description: string }) };
    if (!res.ok) return fail(res, "Could not load this sign-in request");
    return { ok: true, ...((await res.json()) as { app: { name: string }; expiresAt: number }) };
  }),

  /** Allow or Cancel → where to send the browser (the app's loopback). */
  decide: authedProcedure
    .input(z.object({ rid: Rid, approve: z.boolean() }))
    .mutation(async ({ input }): Promise<{ redirect: string } | { redirect: null; error: string }> => {
      const res = await apiFetch(`/api/desktop/connect/${input.rid}/decision`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ approve: input.approve }),
      });
      const body = (await res.json().catch(() => ({}))) as { redirect?: string; error?: string; description?: string };
      if (res.ok && body.redirect) return { redirect: body.redirect };
      if (res.status === 400) return { redirect: null, error: body.description ?? "This sign-in request can't be completed." };
      return fail(new Response(JSON.stringify(body), { status: res.status }), "Could not complete the sign-in");
    }),
});
