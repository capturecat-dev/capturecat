/**
 * App Review sign-in: ONE allowlisted email + password, nothing else.
 *
 * CaptureCat is social-only (Google, Apple, SSO). Apple's reviewers need a
 * username and password they can type, and a fresh Google account trips
 * "Verify it's you" phone codes when they sign in from Apple's network — the
 * classic "unable to sign in" rejection. So this endpoint accepts exactly the
 * address in REVIEW_LOGIN_EMAIL with the password in REVIEW_LOGIN_PASSWORD
 * (both Worker secrets) and issues the same session cookie a social sign-in
 * would. It is not a password system: no sign-up, no reset, no stored hash,
 * and any other email is refused exactly like a wrong password.
 *
 * Off unless BOTH secrets are set — then the endpoint answers 404, so removing
 * either secret switches it off without a deploy. The password must be long
 * (>= 24 chars) or the endpoint stays off: it sits behind the per-IP
 * credential limiter on /api/auth/*, but length is the real guard.
 */

import type { BetterAuthPlugin } from "better-auth";
import { APIError, createAuthEndpoint } from "better-auth/api";
import { setSessionCookie } from "better-auth/cookies";

export const REVIEW_LOGIN_MIN_PASSWORD = 24;

export type ReviewLoginConfig = { email?: string; password?: string };

function normalizeEmail(value: string): string {
  return value.trim().toLowerCase();
}

/** Constant-time compare of two strings (digests first, so length leaks nothing). */
async function sameSecret(a: string, b: string): Promise<boolean> {
  const enc = new TextEncoder();
  const [da, db] = await Promise.all([
    crypto.subtle.digest("SHA-256", enc.encode(a)),
    crypto.subtle.digest("SHA-256", enc.encode(b)),
  ]);
  const x = new Uint8Array(da);
  const y = new Uint8Array(db);
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}

export function reviewLoginEnabled(cfg: ReviewLoginConfig): boolean {
  return Boolean(cfg.email?.includes("@") && cfg.password && cfg.password.length >= REVIEW_LOGIN_MIN_PASSWORD);
}

export function reviewLogin(cfg: ReviewLoginConfig) {
  return {
    id: "review-login",
    endpoints: {
      reviewSignIn: createAuthEndpoint(
        "/review/sign-in",
        { method: "POST", requireHeaders: true },
        async (ctx) => {
          if (!reviewLoginEnabled(cfg)) throw new APIError("NOT_FOUND");
          const body = (ctx.body ?? {}) as { email?: unknown; password?: unknown };
          const email = typeof body.email === "string" ? normalizeEmail(body.email) : "";
          const password = typeof body.password === "string" ? body.password : "";
          // Both checks always run, so a wrong email and a wrong password look
          // (and take) the same.
          const emailOk = await sameSecret(email, normalizeEmail(cfg.email!));
          const passwordOk = await sameSecret(password, cfg.password!);
          if (!emailOk || !passwordOk) {
            throw new APIError("UNAUTHORIZED", { message: "Wrong email or password." });
          }

          const internal = ctx.context.internalAdapter;
          let user = (await internal.findUserByEmail(email))?.user ?? null;
          if (!user) {
            user = await internal.createUser(
              { email, name: "App Review", emailVerified: true },
              { method: "email-password" },
            );
          }
          if ((user as { blocked?: boolean | null }).blocked === true) {
            throw new APIError("FORBIDDEN", { message: "Account blocked" });
          }
          const session = await internal.createSession(user.id);
          await setSessionCookie(ctx, { session, user });
          return ctx.json({ ok: true });
        },
      ),
    },
  } satisfies BetterAuthPlugin;
}
