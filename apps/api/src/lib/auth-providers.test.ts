/**
 * Social sign-in starts for every configured provider.
 *
 * Apple cannot be exercised in local dev (it rejects http:// return URLs, and
 * .dev.vars leaves it unconfigured), so this is the only check that the async
 * Apple factory in lib/auth.ts — which signs the client-secret JWT with the
 * .p8 key on demand — still produces a working provider after a Better Auth
 * upgrade. The key is a throwaway P-256 key generated here; `fetch` is
 * stubbed, and starting a sign-in makes no network call.
 */

import { describe, expect, it, vi } from "vitest";
import type { Env } from "../types";
import { createTestD1 } from "../test-support/d1-sqlite.js";
import { buildAuth } from "./auth";

vi.stubGlobal("fetch", vi.fn(async () => new Response("offline test", { status: 500 })));

async function throwawayP8(): Promise<string> {
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const der = new Uint8Array((await crypto.subtle.exportKey("pkcs8", pair.privateKey)) as ArrayBuffer);
  const b64 = btoa(String.fromCharCode(...der));
  // The single-line, escaped-\n form .dev.vars uses; lib/auth.ts normalises it.
  return `-----BEGIN PRIVATE KEY-----\\n${b64.match(/.{1,64}/g)!.join("\\n")}\\n-----END PRIVATE KEY-----`;
}

async function startSignIn(provider: "apple" | "google") {
  const env = {
    DB: createTestD1(),
    BETTER_AUTH_URL: "https://api.capturecat.so",
    BETTER_AUTH_SECRET: "test-secret-test-secret-test-secret-00",
    GOOGLE_CLIENT_ID: "google-test",
    GOOGLE_CLIENT_SECRET: "google-test-secret",
    APPLE_CLIENT_ID: "so.capturecat.signin",
    APPLE_TEAM_ID: "TEAMID1234",
    APPLE_KEY_ID: "KEYID12345",
    APPLE_PRIVATE_KEY: await throwawayP8(),
    STRIPE_SECRET_KEY: "sk_test_offline",
    STRIPE_WEBHOOK_SECRET: "whsec_offline",
    STRIPE_PRO_PRICE_ID: "price_pro_monthly",
  } as unknown as Env;
  const res = await buildAuth(env).handler(
    new Request("https://api.capturecat.so/api/auth/sign-in/social", {
      method: "POST",
      headers: { "Content-Type": "application/json", Origin: "https://capturecat.so" },
      body: JSON.stringify({ provider, callbackURL: "https://capturecat.so/app" }),
    }),
  );
  return { status: res.status, body: (await res.json()) as { url?: string } };
}

describe("social sign-in start", () => {
  it("Apple (async client-secret factory) redirects to appleid.apple.com with form_post", async () => {
    const { status, body } = await startSignIn("apple");
    expect(status).toBe(200);
    const url = new URL(body.url!);
    expect(url.origin).toBe("https://appleid.apple.com");
    expect(url.searchParams.get("client_id")).toBe("so.capturecat.signin");
    expect(url.searchParams.get("response_mode")).toBe("form_post");
    expect(url.searchParams.get("redirect_uri")).toBe("https://api.capturecat.so/api/auth/callback/apple");
  });

  it("Google redirects to accounts.google.com with PKCE", async () => {
    const { status, body } = await startSignIn("google");
    expect(status).toBe(200);
    const url = new URL(body.url!);
    expect(url.origin).toBe("https://accounts.google.com");
    expect(url.searchParams.get("code_challenge_method")).toBe("S256");
    expect(url.searchParams.get("redirect_uri")).toBe("https://api.capturecat.so/api/auth/callback/google");
  });
});
