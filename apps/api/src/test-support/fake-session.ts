/**
 * TEST-ONLY stand-in for `lib/auth`'s `getAuth`, for route tests that want the
 * REAL requireAuth (its blocked gate and cookie-CSRF gate) without building
 * Better Auth: `Authorization: Bearer <uid>` names the caller, and the user
 * row — tester, blocked — is read from the test D1 exactly as Better Auth
 * would return it. Anything without a known bearer uid has no session.
 *
 *   vi.mock("../lib/auth", () => import("../test-support/fake-session"));
 *
 * Never imported by Worker code.
 */

import type { Env } from "../types";

export function getAuth(env: Env) {
  return {
    api: {
      getSession: async ({ headers }: { headers: Headers }) => {
        const token = headers.get("Authorization")?.replace(/^Bearer /, "");
        if (!token) return null;
        const user = await env.DB.prepare(`SELECT id, email, tester, blocked FROM "user" WHERE id = ?`)
          .bind(token)
          .first<{ id: string; email: string; tester: number | null; blocked: number | null }>();
        if (!user) return null;
        return {
          session: { expiresAt: new Date(Date.now() + 86_400_000) },
          user: { id: user.id, email: user.email, tester: user.tester === 1, blocked: user.blocked === 1 },
        };
      },
    },
  };
}
