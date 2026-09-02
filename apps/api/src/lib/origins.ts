import type { Env } from "../types";

/** Local web dev servers: legacy Next web on :3000 and admin on :3001;
 *  TanStack Start web on :3200 (:3201 when 3200 is taken) and admin on :3300. */
const LOCAL_DEV_ORIGINS = [
  "http://localhost:3000",
  "http://localhost:3001",
  "http://localhost:3200",
  "http://localhost:3201",
  "http://localhost:3300",
];

/** True when this Worker is itself running locally. */
export function isLocalInstance(env: Env): boolean {
  const url = env.BETTER_AUTH_URL ?? "";
  return url.startsWith("http://localhost") || url.startsWith("http://127.0.0.1");
}

/**
 * Browser origins allowed to send credentialed requests.
 *
 * Shared by the CORS policy and by `requireAuth`'s CSRF check so the two cannot
 * drift — CORS allowing one set while the CSRF gate allows another is how a
 * request ends up permitted by one layer and refused by the other.
 *
 * The localhost origins are added automatically when the Worker is running
 * locally, keyed off its OWN baseURL rather than a variable someone has to
 * remember to set. Requiring an env var meant `wrangler dev` answered every
 * preflight `204` with no `Access-Control-Allow-Origin`, so the browser silently
 * blocked the real request and the app showed only `TypeError: Load failed` —
 * a failure mode that says nothing about its cause.
 *
 * This can never widen production: a deployed Worker's BETTER_AUTH_URL is
 * https://api.capturecat.so, so `isLocalInstance` is false and localhost is
 * never trusted. BETTER_AUTH_TRUSTED_ORIGINS remains for anything else (a
 * tunnel hostname for testing Apple sign-in, say).
 */
export function webOrigins(env: Env): string[] {
  const extra = env.BETTER_AUTH_TRUSTED_ORIGINS
    ? env.BETTER_AUTH_TRUSTED_ORIGINS.split(",").map((o) => o.trim()).filter(Boolean)
    : [];
  return [
    "https://capturecat.so",
    "https://www.capturecat.so",
    // The admin console is its own app on its own host. It shares the session
    // cookie (scoped to .capturecat.so), so it must also be trusted here or
    // every admin write fails the CSRF check.
    "https://admin.capturecat.so",
    // The user dashboard subdomain — served by the web Worker, but a distinct
    // browser origin, so it needs its own CORS/CSRF entry.
    "https://app.capturecat.so",
    ...(isLocalInstance(env) ? LOCAL_DEV_ORIGINS : []),
    ...extra,
  ];
}

/**
 * Base URL share links are stamped with. A locally-running Worker writes its
 * rows into the LOCAL D1, so a capturecat.so link would 404 — the link must
 * point at the dev site that can actually resolve it.
 */
export function shareBaseURL(env: Env): string {
  // :3200 is the TanStack Start dev server (the Next app on :3000 is gone).
  return isLocalInstance(env) ? "http://localhost:3200" : "https://capturecat.so";
}
