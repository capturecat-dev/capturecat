import { z } from "zod";
import { TRPCError } from "@trpc/server";

import { apiFetch } from "@/lib/session";
import { authedProcedure, createTRPCRouter } from "@/lib/trpc/init";

/**
 * Public profile: username claim + bio/website. The API owns validation
 * (charset, reserved words, uniqueness) — these procedures only forward and
 * surface its error text, so the rules live in exactly one place.
 */
export const profileRouter = createTRPCRouter({
  me: authedProcedure.query(async () => {
    const res = await apiFetch("/api/profile/me");
    if (!res.ok) {
      throw new TRPCError({ code: "INTERNAL_SERVER_ERROR", message: "Could not load profile" });
    }
    return (await res.json()) as {
      name: string | null;
      image: string | null;
      username: string | null;
      bio: string | null;
      website: string | null;
    };
  }),

  checkUsername: authedProcedure
    .input(z.object({ username: z.string() }))
    .query(async ({ input }) => {
      const res = await apiFetch(
        `/api/profile/available?username=${encodeURIComponent(input.username)}`
      );
      if (!res.ok) return { available: false, error: "Could not check that username" };
      return (await res.json()) as {
        available: boolean;
        username?: string;
        error?: string;
      };
    }),

  update: authedProcedure
    .input(
      z.object({
        username: z.string().min(3).max(30).optional(),
        bio: z.string().max(200).nullable().optional(),
        website: z.string().nullable().optional(),
      })
    )
    .mutation(async ({ input }) => {
      const res = await apiFetch("/api/profile", {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(input),
      });
      const body = (await res.json().catch(() => ({}))) as {
        error?: string;
        username?: string | null;
      };
      if (!res.ok) {
        throw new TRPCError({
          code: res.status === 409 ? "CONFLICT" : "BAD_REQUEST",
          message: body.error ?? "Could not save profile",
        });
      }
      return body as { ok: boolean; username: string | null };
    }),
});
