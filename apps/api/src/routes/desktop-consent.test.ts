/**
 * The Mac app's sign-in consent (app.capturecat.so/connect/mac) through the
 * REAL Worker entry: /desktop/authorize records the request and sends the
 * browser to the consent page; the page's session-only API shows it, and
 * Allow mints a one-time code for a NEW session (never the browser's own),
 * bound to the request's PKCE challenge and loopback redirect; Cancel burns
 * it and tells the app access_denied. Better Auth's session and one-time-token
 * calls are faked (createSession / generate / verify), the rows are real.
 * `Authorization: Bearer <uid>` is that user's browser session.
 */
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Env } from "../types";
import { createTestD1, type TestD1 } from "../test-support/d1-sqlite.js";

const fake = vi.hoisted(() => ({
  /** Desktop sessions made by createSession: token → uid. */
  sessions: new Map<string, string>(),
  /** One-time codes: code → the session token it was minted for. */
  codes: new Map<string, string>(),
  n: 0,
}));

vi.mock("cloudflare:workers", () => ({ DurableObject: class {} }));
vi.mock("../lib/auth", () => ({
  hasAppleConfig: () => true,
  hasGoogleConfig: () => true,
  getAuth: (env: Env) => ({
    $context: Promise.resolve({
      internalAdapter: {
        createSession: async (uid: string) => {
          const token = `desktop-session-${++fake.n}`;
          fake.sessions.set(token, uid);
          return { token };
        },
        deleteSession: async (token: string) => void fake.sessions.delete(token),
      },
    }),
    api: {
      getSession: async ({ headers }: { headers: Headers }) => {
        const uid = headers.get("Authorization")?.replace(/^Bearer /, "");
        if (!uid) return null;
        const user = await env.DB.prepare(`SELECT id, email FROM "user" WHERE id = ?`).bind(uid).first<{ id: string; email: string }>();
        return user
          ? { session: { expiresAt: new Date(Date.now() + 86_400_000) }, user: { id: user.id, email: user.email, tester: false, blocked: false } }
          : null;
      },
      generateOneTimeToken: async ({ headers }: { headers: Headers }) => {
        const token = `code-${++fake.n}`;
        fake.codes.set(token, headers.get("Authorization")!.replace(/^Bearer /, ""));
        return { token };
      },
      verifyOneTimeToken: async ({ body }: { body: { token: string } }) => {
        const session = fake.codes.get(body.token);
        if (!session) throw new Error("invalid one-time token");
        fake.codes.delete(body.token);
        return {
          session: { token: session, expiresAt: new Date(Date.now() + 86_400_000) },
          user: { id: fake.sessions.get(session), email: "mike@test.local", name: "Mike", image: null },
        };
      },
    },
  }),
}));
vi.stubGlobal("caches", { default: { match: async () => undefined, put: async () => undefined, delete: async () => true } });
vi.stubGlobal("fetch", vi.fn(async () => {
  throw new Error("offline test: unexpected fetch");
}));

const { default: worker } = await import("../index");

const API = "https://api.capturecat.so";
const USER = "user-1";
const REDIRECT = "http://127.0.0.1:51234/capturecat-auth/callback";
const VERIFIER = "v".repeat(43) + "erifier-for-the-desktop-consent-test";
const ctx = { waitUntil() {}, passThroughOnException() {} } as unknown as ExecutionContext;

let db: TestD1;
let env: Env;

async function challengeFor(verifier: string): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier)));
  return btoa(String.fromCharCode(...digest)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

beforeEach(() => {
  db = createTestD1();
  env = { DB: db, BETTER_AUTH_URL: API, BETTER_AUTH_SECRET: "test-secret-test-secret-test-secret-00" } as unknown as Env;
  const now = new Date().toISOString();
  db.query(
    `INSERT INTO "user" (id, name, email, emailVerified, createdAt, updatedAt, tester, blocked, role, username)
     VALUES (?, 'Mike', 'mike@test.local', 1, ?, ?, 0, 0, 'user', 'mike')`,
    USER, now, now,
  );
  fake.sessions.clear();
  fake.codes.clear();
});

function req(method: string, path: string, init: { as?: string; body?: unknown } = {}) {
  const headers: Record<string, string> = { "CF-Connecting-IP": "203.0.113.7" };
  if (init.as) headers.Authorization = `Bearer ${init.as}`;
  if (init.body !== undefined) headers["Content-Type"] = "application/json";
  return worker.fetch(
    new Request(`${API}${path}`, { method, headers, redirect: "manual", body: init.body === undefined ? undefined : JSON.stringify(init.body) }),
    env,
    ctx,
  );
}

/** The app's "Sign In": authorize → the consent page's rid. */
async function startSignIn(): Promise<string> {
  const q = new URLSearchParams({
    redirect_uri: REDIRECT,
    code_challenge: await challengeFor(VERIFIER),
    code_challenge_method: "S256",
    state: "app-state-1",
  });
  const res = await req("GET", `/api/desktop/authorize?${q}`);
  expect(res.status).toBe(302);
  const to = new URL(res.headers.get("Location")!);
  expect(`${to.origin}${to.pathname}`).toBe("https://app.capturecat.so/connect/mac");
  return to.searchParams.get("rid")!;
}

const decide = (rid: string, approve: boolean) =>
  req("POST", `/api/desktop/connect/${rid}/decision`, { as: USER, body: { approve } });

describe("Mac sign-in consent", () => {
  it("sends the app's Sign In to the consent page with a recorded request", async () => {
    const rid = await startSignIn();
    const row = db.query(`SELECT provider, redirect_uri, client_state, consumed FROM desktop_auth_requests WHERE id = ?`, rid)[0];
    expect(row).toMatchObject({ provider: "consent", redirect_uri: REDIRECT, client_state: "app-state-1", consumed: 0 });
  });

  it("rejects a non-loopback redirect before recording anything", async () => {
    const q = new URLSearchParams({
      redirect_uri: "https://evil.example/capturecat-auth/callback",
      code_challenge: await challengeFor(VERIFIER),
      code_challenge_method: "S256",
    });
    expect((await req("GET", `/api/desktop/authorize?${q}`)).status).toBe(400);
    expect(db.query(`SELECT COUNT(*) AS n FROM desktop_auth_requests`)[0]).toMatchObject({ n: 0 });
  });

  it("shows the request only to a signed-in browser", async () => {
    const rid = await startSignIn();
    expect((await req("GET", `/api/desktop/connect/${rid}`)).status).toBe(401);
    const info = await req("GET", `/api/desktop/connect/${rid}`, { as: USER });
    expect(info.status).toBe(200);
    expect(await info.json()).toMatchObject({ app: { name: "CaptureCat for Mac" } });
    const unknown = await req("GET", "/api/desktop/connect/00000000-0000-4000-8000-000000000000", { as: USER });
    expect(unknown.status).toBe(400);
    expect(await unknown.json()).toMatchObject({ error: "unknown_request" });
  });

  it("Allow hands the app a code for a NEW session, bound to its PKCE challenge", async () => {
    const rid = await startSignIn();
    const res = await decide(rid, true);
    expect(res.status).toBe(200);
    const back = new URL(((await res.json()) as { redirect: string }).redirect);
    expect(`${back.origin}${back.pathname}`).toBe(REDIRECT);
    expect(back.searchParams.get("state")).toBe("app-state-1");
    const code = back.searchParams.get("code")!;

    // A wrong verifier is refused (and burns nothing it shouldn't).
    const wrong = await req("POST", "/api/desktop/token", {
      body: { code, code_verifier: "w".repeat(64), redirect_uri: REDIRECT },
    });
    expect(wrong.status).toBe(400);
  });

  it("the redeemed token is the Mac's own session, never the browser's", async () => {
    const rid = await startSignIn();
    const back = new URL(((await (await decide(rid, true)).json()) as { redirect: string }).redirect);
    const token = await req("POST", "/api/desktop/token", {
      body: { code: back.searchParams.get("code"), code_verifier: VERIFIER, redirect_uri: REDIRECT },
    });
    expect(token.status).toBe(200);
    const body = (await token.json()) as { token: string; user: { id: string } };
    expect(body.token).toMatch(/^desktop-session-/);
    expect(body.token).not.toBe(USER);
    expect(fake.sessions.get(body.token)).toBe(USER);
    expect(body.user.id).toBe(USER);
    // Single use.
    const again = await req("POST", "/api/desktop/token", {
      body: { code: back.searchParams.get("code"), code_verifier: VERIFIER, redirect_uri: REDIRECT },
    });
    expect(again.status).toBe(400);
  });

  it("Cancel tells the app access_denied and burns the request", async () => {
    const rid = await startSignIn();
    const res = await decide(rid, false);
    const back = new URL(((await res.json()) as { redirect: string }).redirect);
    expect(back.searchParams.get("error")).toBe("access_denied");
    expect(back.searchParams.get("state")).toBe("app-state-1");
    expect(back.searchParams.has("code")).toBe(false);
    const after = await req("GET", `/api/desktop/connect/${rid}`, { as: USER });
    expect(await after.json()).toMatchObject({ error: "answered" });
    expect((await decide(rid, true)).status).toBe(400);
    expect(fake.sessions.size).toBe(0);
  });

  it("a request answers once: a second Allow mints nothing and leaves no session behind", async () => {
    const rid = await startSignIn();
    expect((await decide(rid, true)).status).toBe(200);
    expect(fake.sessions.size).toBe(1);
    const second = await decide(rid, true);
    expect(second.status).toBe(400);
    expect(await second.json()).toMatchObject({ error: "answered" });
    expect(fake.sessions.size).toBe(1);
  });

  it("an expired request can't be shown or answered", async () => {
    const rid = await startSignIn();
    db.query(`UPDATE desktop_auth_requests SET expires_at = 1 WHERE id = ?`, rid);
    const info = await req("GET", `/api/desktop/connect/${rid}`, { as: USER });
    expect(await info.json()).toMatchObject({ error: "expired" });
    expect((await decide(rid, true)).status).toBe(400);
    expect(fake.sessions.size).toBe(0);
  });

  it("the decision needs a real body", async () => {
    const rid = await startSignIn();
    expect((await req("POST", `/api/desktop/connect/${rid}/decision`, { as: USER, body: { approve: "yes" } })).status).toBe(400);
    // No session: refused (the cookie-CSRF gate answers before requireAuth's 401).
    expect([401, 403]).toContain((await req("POST", `/api/desktop/connect/${rid}/decision`, { body: { approve: true } })).status);
    expect(fake.sessions.size).toBe(0);
  });
});
