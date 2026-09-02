/**
 * Public beta waitlist ingest.
 *
 * The /beta page on capturecat.so posts here directly from the browser (like
 * the analytics ingest), so `CF-Connecting-IP` is the real visitor and the
 * per-IP rate limit in src/index.ts actually bounds one person. Spam is fought
 * in four independent layers, cheapest first:
 *
 *   1. per-IP rate limit   (middleware, src/index.ts)
 *   2. honeypot            a hidden `website` field no human fills
 *   3. Cloudflare Turnstile a token the server re-verifies against siteverify
 *   4. dedupe              UNIQUE(email) + INSERT OR IGNORE, so repeats no-op
 *
 * The response is deliberately uniform: a valid submission, a duplicate, and a
 * honeypot hit all return `{ ok: true }`, so the endpoint never reveals whether
 * an address is already on the list.
 */

import { Hono } from "hono";
import type { Env } from "../types";
import { generateId } from "../lib/id";
import { isLocalInstance } from "../lib/origins";

export const betaRoutes = new Hono<{ Bindings: Env }>();

/** Same shape the honeypot-free browsers send; everything else is optional. */
interface BetaBody {
  email?: unknown;
  /** Honeypot — real users never see or fill this. */
  website?: unknown;
  turnstileToken?: unknown;
}

// A pragmatic RFC-5321-ish check: one @, no spaces, a dotted domain. The real
// validation is that a bot cleared Turnstile; this only rejects obvious junk.
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

/**
 * Verify a Turnstile token with Cloudflare's siteverify.
 *
 * Fails CLOSED: no secret in production, a missing token, a bad token, or a
 * network error all return false. The one exception is a locally-running Worker
 * with no secret configured, which skips verification so `wrangler dev` works
 * without Turnstile keys — production can never reach that branch because its
 * BETTER_AUTH_URL is https://api.capturecat.so, not localhost. (Keeping the
 * skip this narrow matters: if the prod secret ever vanished after a deploy,
 * sign-ups would start failing loudly rather than silently accepting spam.)
 */
async function verifyTurnstile(
  env: Env,
  token: string | null,
  ip: string | null
): Promise<boolean> {
  const secret = env.TURNSTILE_SECRET;
  if (!secret) return isLocalInstance(env);
  if (!token) return false;

  const form = new URLSearchParams();
  form.set("secret", secret);
  form.set("response", token);
  if (ip) form.set("remoteip", ip);

  try {
    const res = await fetch(
      "https://challenges.cloudflare.com/turnstile/v0/siteverify",
      {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: form,
      }
    );
    if (!res.ok) return false;
    const data = (await res.json()) as { success?: boolean };
    return data.success === true;
  } catch {
    return false;
  }
}

betaRoutes.post("/beta", async (c) => {
  const body: BetaBody = await c.req.json<BetaBody>().catch(() => ({}) as BetaBody);

  // (2) Honeypot: a filled `website` is a bot. Answer 200 with no trace so it
  // learns nothing and does not retry.
  if (typeof body.website === "string" && body.website.trim() !== "") {
    return c.json({ ok: true });
  }

  const email =
    typeof body.email === "string" ? body.email.trim().toLowerCase() : "";
  if (!email || email.length > 254 || !EMAIL_RE.test(email)) {
    return c.json({ error: "Enter a valid email address." }, 400);
  }

  // (3) Turnstile.
  const ip = c.req.header("CF-Connecting-IP") ?? null;
  const token =
    typeof body.turnstileToken === "string" ? body.turnstileToken : null;
  const ok = await verifyTurnstile(c.env, token, ip);
  if (!ok) {
    return c.json({ error: "Verification failed. Please try again." }, 400);
  }

  // (4) Dedupe. INSERT OR IGNORE makes a repeat address a silent no-op.
  const cf = (c.req.raw as Request & { cf?: { country?: string } }).cf;
  const referrer = c.req.header("Referer")?.slice(0, 300) ?? null;
  const userAgent = c.req.header("User-Agent")?.slice(0, 400) ?? null;

  await c.env.DB.prepare(
    `INSERT OR IGNORE INTO beta_signups
       (id, email, status, ip, user_agent, referrer, country, created_at)
     VALUES (?, ?, 'new', ?, ?, ?, ?, ?)`
  )
    .bind(
      generateId(),
      email,
      ip,
      userAgent,
      referrer,
      cf?.country ?? null,
      new Date().toISOString()
    )
    .run();

  return c.json({ ok: true });
});
