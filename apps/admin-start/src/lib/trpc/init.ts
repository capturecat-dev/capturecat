import { initTRPC, TRPCError } from "@trpc/server";
import superjson from "superjson";

import { getSession, type Session } from "@/lib/session";

export type TRPCContext = {
  session: Session | null;
};

/** One session read per tRPC request, forwarded to api.capturecat.so. */
export const createTRPCContext = async (): Promise<TRPCContext> => {
  return { session: await getSession() };
};

const t = initTRPC.context<TRPCContext>().create({
  transformer: superjson,
});

export const createTRPCRouter = t.router;
export const createCallerFactory = t.createCallerFactory;
export const baseProcedure = t.procedure;

/**
 * Admin-only. Authority is `user.role === "admin"` from Better Auth's admin
 * plugin — not an email allowlist, and not a separate admin cookie.
 */
export const adminProcedure = t.procedure.use(async ({ ctx, next }) => {
  if (!ctx.session || ctx.session.user.role !== "admin") {
    throw new TRPCError({ code: "UNAUTHORIZED", message: "Admin access required" });
  }
  return next({ ctx: { ...ctx, session: ctx.session } });
});

/** Any authenticated, non-blocked user. */
export const authedProcedure = t.procedure.use(async ({ ctx, next }) => {
  if (!ctx.session) {
    throw new TRPCError({ code: "UNAUTHORIZED", message: "Sign in required" });
  }
  if (ctx.session.user.blocked) {
    throw new TRPCError({ code: "FORBIDDEN", message: "Account blocked" });
  }
  return next({ ctx: { ...ctx, session: ctx.session } });
});
