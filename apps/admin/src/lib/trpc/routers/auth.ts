import { baseProcedure, createTRPCRouter } from "@/lib/trpc/init";

/**
 * What is left of the auth router.
 *
 * `createAdminSession` / `createUserSession` / `destroySession` are gone. They
 * implemented a Firebase-specific shape — the browser minted an ID token and
 * the server exchanged it for a session cookie it signed itself. Better Auth
 * has no counterpart: sign-in is a full-page redirect that terminates on
 * api.capturecat.so, which is the origin that sets the cookie, and sign-out is
 * `authClient.signOut()` because only that origin can clear it.
 *
 * So there is nothing left for the server to do at sign-in time, and this
 * router keeps only the read.
 */
export const authRouter = createTRPCRouter({
  /** Current user. Deliberately does NOT return email. */
  me: baseProcedure.query(async ({ ctx }) => {
    if (!ctx.session) return null;
    return {
      uid: ctx.session.user.id,
      name: ctx.session.user.name,
      picture: ctx.session.user.image,
      role: ctx.session.user.role,
    };
  }),
});
