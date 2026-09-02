/**
 * Server-side session reads against the Better Auth instance on
 * api.capturecat.so — the TanStack Start port of apps/web/lib/session.ts.
 *
 * The web app holds no signing key: it forwards the browser's cookie to the
 * API and asks. Better Auth issues the cookie on `.capturecat.so`
 * (`advanced.crossSubDomainCookies`), which is why this host can read it.
 *
 * These helpers run only on the server — inside server functions, server
 * route handlers, and tRPC procedures — where the Start request context
 * (getRequestHeader) is available.
 */
import { getRequestHeader } from "@tanstack/react-start/server";

import { API_URL, SITE_URL } from "./api-url";

export { API_URL };

export interface SessionUser {
  id: string;
  email: string;
  name: string | null;
  image: string | null;
  role: string | null;
  tester: boolean;
  blocked: boolean;
}

export interface Session {
  user: SessionUser;
  expiresAt: string;
}

function forwardedCookieHeader(): string | null {
  return getRequestHeader("cookie") ?? null;
}

/**
 * The current session, or null. Never throws — an API outage signs everyone
 * out rather than 500ing every page.
 */
export async function getSession(): Promise<Session | null> {
  const cookie = forwardedCookieHeader();
  if (!cookie) return null;

  try {
    const res = await fetch(`${API_URL}/api/auth/get-session`, {
      headers: { cookie },
    });
    if (!res.ok) return null;
    const body = (await res.json()) as {
      user?: SessionUser;
      session?: { expiresAt?: string };
    } | null;
    if (!body?.user) return null;
    return {
      user: {
        id: body.user.id,
        email: body.user.email,
        name: body.user.name ?? null,
        image: body.user.image ?? null,
        role: body.user.role ?? null,
        tester: body.user.tester === true,
        blocked: body.user.blocked === true,
      },
      expiresAt: body.session?.expiresAt ?? "",
    };
  } catch (err) {
    console.error("session: get-session failed", (err as Error).message);
    return null;
  }
}

/**
 * Calls the API as the current user, forwarding the session cookie.
 *
 * Every state-changing call must carry Origin: the API's `requireAuth` rejects
 * cookie-authenticated non-GET requests whose Origin is not trusted.
 */
export async function apiFetch(
  path: string,
  init: RequestInit = {}
): Promise<Response> {
  const cookie = forwardedCookieHeader();
  return fetch(`${API_URL}${path}`, {
    ...init,
    headers: {
      ...(init.headers ?? {}),
      ...(cookie ? { cookie } : {}),
      origin: SITE_URL,
    },
  });
}
